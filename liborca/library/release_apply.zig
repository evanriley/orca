const std = @import("std");
const database = @import("../database/root.zig");
const matching = @import("matching.zig");
const release_alignment = @import("release_alignment.zig");

/// Why an Apply gave a Track none of its release track's values.
pub const LeftAloneReason = enum {
    /// The alignment places it on no release track, or only suggests one.
    not_placed,
    /// It has no file to store values on.
    no_play_file,
};

pub const LeftAloneTrack = struct {
    track_id: i64,
    title: []const u8,
    reason: LeftAloneReason,
};

/// What an Apply of a Release's best candidate stored.
pub const ReleaseApplyOutcome = struct {
    arena: *std.heap.ArenaAllocator,
    release_mbid: []const u8,
    values_written: u32,
    /// Tracks with a play file placed by recording ID or by a pairing.
    track_values: u32,
    /// Tracks with a play file the alignment does not place; they took the
    /// release's own values only.
    release_values_only: u32,
    /// Every Track not given its release track's values, in the alignment's
    /// Track order.
    left_alone: []const LeftAloneTrack,
    /// The snapshot predates Orca keeping the release's artist IDs, so the
    /// album artist ID and compilation flag were left alone; the next lookup
    /// of the release replaces it.
    artist_ids_unknown: bool,
    /// The Release, under its ID after the reprojection, that the Apply
    /// marked as reviewed because it left no Track alone; null otherwise.
    reviewed_release_id: ?i64 = null,

    pub fn deinit(self: ReleaseApplyOutcome) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

/// Stores `fields` of the Release's best candidate's snapshot, as
/// `IdentificationProposalRepository.applyReleasePlanLocked` describes, on
/// the Tracks the alignment with it places and the release's own values on
/// every other Track with a play file, in one transaction. Appends each file
/// whose values changed to `written`.
pub fn apply(
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    release_id: i64,
    fields: database.ReleaseFieldSet,
    written: *std.ArrayList(i64),
) !ReleaseApplyOutcome {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    var outcome: ReleaseApplyOutcome = .{
        .arena = arena,
        .release_mbid = "",
        .values_written = 0,
        .track_values = 0,
        .release_values_only = 0,
        .left_alone = &.{},
        .artist_ids_unknown = false,
    };
    errdefer outcome.deinit();
    const owned = arena.allocator();

    library.write_lane.acquire();
    defer library.write_lane.release();
    try library.database.exec("BEGIN IMMEDIATE;");
    errdefer library.database.exec("ROLLBACK;") catch {};

    var planned = try plan(allocator, library, release_id, null);
    defer planned.deinit();
    outcome.release_mbid = try owned.dupe(u8, planned.tracklist.record.release_mbid);
    outcome.artist_ids_unknown = planned.tracklist.record.artist_credit_mbids == null;
    var left_alone: std.ArrayList(LeftAloneTrack) = .empty;
    for (planned.view.tracks) |track| {
        const reason: LeftAloneReason = if (track.play_file == null)
            .no_play_file
        else if (planned.isPlaced(track.track_id))
            continue
        else
            .not_placed;
        try left_alone.append(owned, .{ .track_id = track.track_id, .title = try owned.dupe(u8, track.title), .reason = reason });
    }
    outcome.left_alone = left_alone.items;
    for (planned.apply_tracks.items) |track| {
        if (track.placed == null) outcome.release_values_only += 1 else outcome.track_values += 1;
    }

    outcome.values_written = try library.identification_proposals.applyReleasePlanLocked(allocator, &.{
        .tracklist = &planned.tracklist.record,
        .tracks = planned.apply_tracks.items,
    }, fields, false, null, written);
    try library.database.exec("COMMIT;");
    return outcome;
}

/// Records that a person found the Release equal to `release_mbid`, else its
/// best candidate, whatever values still differ from it. Refused with
/// `error.ReleaseNotPlaced` unless every Track has a play file and is
/// placed. The review holds while that release stays the best candidate and
/// the Release's Tracks, their values and the snapshot stay as they were.
pub fn markReviewed(
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    release_id: i64,
    release_mbid: ?[]const u8,
) !void {
    library.write_lane.acquire();
    defer library.write_lane.release();
    try library.database.exec("BEGIN IMMEDIATE;");
    errdefer library.database.exec("ROLLBACK;") catch {};
    try markReviewedLocked(allocator, library, release_id, release_mbid);
    try library.database.exec("COMMIT;");
}

/// Marks as reviewed against `release_mbid` the one Release that, after an
/// Apply that left no Track alone was reprojected, holds the files the Apply
/// wrote, or `release_id` when it wrote none. Returns that Release's ID, or
/// null when the files now lie on several Releases or a Track of it is not
/// placed.
pub fn reviewApplied(
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    release_id: i64,
    written: []const i64,
    release_mbid: []const u8,
) !?i64 {
    library.write_lane.acquire();
    defer library.write_lane.release();
    try library.database.exec("BEGIN IMMEDIATE;");
    errdefer library.database.exec("ROLLBACK;") catch {};
    const reviewed = if (written.len == 0) release_id else try soleReleaseOf(allocator, library, written) orelse {
        try library.database.exec("COMMIT;");
        return null;
    };
    markReviewedLocked(allocator, library, reviewed, release_mbid) catch |err| switch (err) {
        error.ReleaseNotPlaced => {
            try library.database.exec("COMMIT;");
            return null;
        },
        else => |other| return other,
    };
    try library.database.exec("COMMIT;");
    return reviewed;
}

fn soleReleaseOf(allocator: std.mem.Allocator, library: *database.LibraryDatabase, files: []const i64) !?i64 {
    var ids: std.ArrayList(u8) = .empty;
    defer ids.deinit(allocator);
    try ids.append(allocator, '[');
    for (files, 0..) |file_id, index| try ids.print(allocator, "{s}{d}", .{ if (index == 0) "" else ",", file_id });
    try ids.append(allocator, ']');
    var statement = try library.database.prepare("SELECT DISTINCT release_id FROM tracks WHERE preferred_file_id IN (SELECT value FROM json_each(?1)) LIMIT 2;");
    defer statement.deinit();
    try statement.bindText(1, ids.items);
    if (try statement.step() != .row) return null;
    const release_id = statement.columnInt64(0);
    if (try statement.step() == .row) return null;
    return release_id;
}

fn markReviewedLocked(
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    release_id: i64,
    release_mbid: ?[]const u8,
) !void {
    var planned = try plan(allocator, library, release_id, release_mbid);
    defer planned.deinit();
    if (planned.view.tracks.len == 0) return error.ReleaseNotPlaced;
    for (planned.view.tracks) |track| {
        if (track.play_file == null or !planned.isPlaced(track.track_id)) return error.ReleaseNotPlaced;
    }
    const compared = planned.tracklist.record.release_mbid;
    const digest = try database.repository.releaseReviewDigest(library.database, release_id, compared) orelse
        return error.NoReleaseTracklist;
    try library.reviewed_releases.markLocked(release_id, compared, digest);
}

/// Replaces what `diff` says of its release with what an Apply of the
/// release's snapshot would store, when the release has one: the album,
/// album artist, date and release ID come from the snapshot, each Track
/// placed on it takes its release track's position, title, artist credit
/// and length, and a stored field differs exactly when an Apply of that
/// field alone would change a value in effect. Without a snapshot, or for a
/// Release of more than `max_page` Tracks, `diff` is left as it is.
pub fn applySnapshotToDiff(
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    release_id: i64,
    diff: *matching.ReleaseMatchDiff,
) !void {
    var planned = plan(allocator, library, release_id, diff.release_mbid) catch |err| switch (err) {
        error.NoReleaseTracklist, error.ReleaseTooLarge => return,
        else => |other| return other,
    };
    defer planned.deinit();
    const owned = diff.arena.allocator();
    const record = &planned.tracklist.record;

    var placed: u32 = 0;
    var titles_differ: u32 = 0;
    for (diff.tracks, 0..) |*row, index| {
        const track = planned.viewTrack(row.track_id) orelse continue;
        const apply_track = planned.applyTrack(row.track_id);
        const release_track = if (apply_track) |entry| entry.placed else null;
        row.position = fallbackPosition(track, index);
        row.candidate_title = "";
        row.local_artist = try owned.dupe(u8, track.artist);
        row.candidate_artist = "";
        row.differs = false;
        row.delta_ms = null;
        const on_release = release_track orelse continue;
        placed += 1;
        row.position = on_release.position;
        row.candidate_title = try owned.dupe(u8, on_release.title);
        row.candidate_artist = try owned.dupe(u8, on_release.artist_credit);
        row.delta_ms = lengthDelta(track.duration_ms, on_release.length_ms);
        row.differs = try differingValues(allocator, library, &planned, &.{apply_track.?}, .initOne(.track_titles), null) != 0;
        if (row.differs) titles_differ += 1;
    }
    diff.aligned = placed;

    for (diff.fields) |*field_diff| {
        const candidate: []const u8 = switch (field_diff.field) {
            .album => record.title,
            .album_artist => record.artist_credit,
            .release_date => record.release_date orelse "",
            .release_id => record.release_mbid,
            .track_titles => {
                field_diff.local = try std.fmt.allocPrint(owned, "{d} of {d} differ", .{ titles_differ, diff.tracks.len });
                field_diff.candidate = try std.fmt.allocPrint(owned, "{d} of {d} on the release", .{ placed, diff.tracks.len });
                field_diff.differs = titles_differ != 0;
                continue;
            },
            .release_type, .genre, .artwork => continue,
        };
        field_diff.candidate = try owned.dupe(u8, candidate);
        field_diff.differs = try differingValues(
            allocator,
            library,
            &planned,
            planned.apply_tracks.items,
            .initOne(field_diff.field),
            if (field_diff.field == .release_id) &field_diff.identity else null,
        ) != 0;
    }
}

/// The evidence for the Release against `release_mbid`, else its best
/// candidate, with the release's values and the placed Tracks' durations
/// taken from its snapshot when it has one.
pub fn releaseMatchEvidence(
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    release_id: i64,
    release_mbid: ?[]const u8,
) !matching.MatchEvidence {
    var planned = plan(allocator, library, release_id, release_mbid) catch |err| switch (err) {
        error.NoReleaseTracklist, error.ReleaseTooLarge => {
            const view = try library.identification_proposals.releaseMatchView(allocator, release_id, false);
            defer view.deinit();
            const compared = try matching.comparedRelease(&view, allocator, release_mbid);
            return matching.releaseMatchEvidence(allocator, &view, compared, null);
        },
        else => |other| return other,
    };
    defer planned.deinit();
    const record = &planned.tracklist.record;
    var compared: u32 = 0;
    var within: u32 = 0;
    for (planned.apply_tracks.items) |entry| {
        const on_release = entry.placed orelse continue;
        const track = planned.viewTrack(entry.track_id) orelse continue;
        const delta = lengthDelta(track.duration_ms, on_release.length_ms) orelse continue;
        compared += 1;
        if (@abs(delta) <= matching.duration_agreement_ms) within += 1;
    }
    return matching.releaseMatchEvidence(allocator, &planned.view, record.release_mbid, .{
        .title = record.title,
        .artist = record.artist_credit,
        .date = record.release_date orelse "",
        .durations_compared = compared,
        .durations_within_1s = within,
    });
}

fn differingValues(
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    planned: *const Plan,
    tracks: []const database.ReleaseApplyTrack,
    fields: database.ReleaseFieldSet,
    identity: ?*database.ReleaseIdentity,
) !u32 {
    return library.identification_proposals.applyReleasePlanLocked(allocator, &.{
        .tracklist = &planned.tracklist.record,
        .tracks = tracks,
    }, fields, true, identity, null);
}

fn fallbackPosition(track: *const database.ReleaseMatchTrack, index: usize) u32 {
    return track.track_number orelse std.math.cast(u32, index + 1) orelse std.math.maxInt(u32);
}

fn lengthDelta(local_ms: ?i64, release_ms: ?u64) ?i64 {
    const local = local_ms orelse return null;
    const release = std.math.cast(i64, release_ms orelse return null) orelse return null;
    if (local <= 0 or release <= 0) return null;
    return release - local;
}

/// Gives the item's best candidate the title and date of that release's
/// snapshot, allocated with `owned`, and fills its placement counts: how
/// many of the Release's Tracks the alignment with the snapshot places.
/// Left as it is without a snapshot; no counts for a Release of more than
/// `max_page` Tracks. One snapshot read, then one view read and one
/// pairings read.
pub fn describeBest(
    allocator: std.mem.Allocator,
    owned: std.mem.Allocator,
    library: *database.LibraryDatabase,
    item: *database.ReleaseMatchItem,
) !void {
    const best = if (item.best) |*candidate| candidate else return;
    var tracklist = try library.release_tracklists.get(allocator, best.release_mbid) orelse return;
    defer tracklist.deinit();
    best.title = try owned.dupe(u8, tracklist.record.title);
    best.date = if (tracklist.record.release_date) |date| try owned.dupe(u8, date) else null;

    const view = try library.identification_proposals.releaseMatchView(allocator, item.release_id, false);
    defer view.deinit();
    if (view.track_count > database.repository.max_page) return;
    var pairings = try library.release_track_pairings.list(allocator, item.release_id, best.release_mbid);
    defer pairings.deinit();
    const alignment = try release_alignment.alignRelease(allocator, item.release_id, view.tracks, &tracklist.record, pairings.items);
    defer alignment.deinit();
    var placed: u32 = 0;
    for (alignment.rows) |row| {
        if (row.track != null and isPlacing(row.status)) placed += 1;
    }
    item.placement = .{ .placed = placed, .needs_pairing = @intCast(view.tracks.len - placed) };
}

fn isPlacing(status: release_alignment.PlacementStatus) bool {
    return status == .automatic or status == .paired;
}

const Plan = struct {
    view: database.ReleaseMatchView,
    tracklist: database.ReleaseTracklist,
    alignment: release_alignment.ReleaseAlignment,
    apply_tracks: std.ArrayList(database.ReleaseApplyTrack),
    allocator: std.mem.Allocator,

    fn deinit(self: *Plan) void {
        self.apply_tracks.deinit(self.allocator);
        self.alignment.deinit();
        self.tracklist.deinit();
        self.view.deinit();
    }

    fn isPlaced(self: *const Plan, track_id: i64) bool {
        const track = self.applyTrack(track_id) orelse return false;
        return track.placed != null;
    }

    fn applyTrack(self: *const Plan, track_id: i64) ?database.ReleaseApplyTrack {
        for (self.apply_tracks.items) |track| {
            if (track.track_id == track_id) return track;
        }
        return null;
    }

    fn viewTrack(self: *const Plan, track_id: i64) ?*const database.ReleaseMatchTrack {
        for (self.view.tracks) |*track| {
            if (track.track_id == track_id) return track;
        }
        return null;
    }
};

fn plan(
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    release_id: i64,
    release_mbid: ?[]const u8,
) !Plan {
    const view = try library.identification_proposals.releaseMatchView(allocator, release_id, false);
    errdefer view.deinit();
    if (view.track_count > database.repository.max_page) return error.ReleaseTooLarge;
    const compared = try matching.comparedRelease(&view, allocator, release_mbid);
    var tracklist = try library.release_tracklists.get(allocator, compared) orelse return error.NoReleaseTracklist;
    errdefer tracklist.deinit();
    var pairings = try library.release_track_pairings.list(allocator, release_id, compared);
    defer pairings.deinit();
    const alignment = try release_alignment.alignRelease(allocator, release_id, view.tracks, &tracklist.record, pairings.items);
    errdefer alignment.deinit();

    var apply_tracks: std.ArrayList(database.ReleaseApplyTrack) = .empty;
    errdefer apply_tracks.deinit(allocator);
    for (view.tracks) |*track| {
        const play_file = track.play_file orelse continue;
        var entry: database.ReleaseApplyTrack = .{ .track_id = track.track_id, .play_file = play_file };
        for (alignment.rows) |row| {
            const shown = row.track orelse continue;
            if (shown.track_id != track.track_id or !isPlacing(row.status)) continue;
            entry.placed = .{
                .disc = row.disc,
                .position = row.position,
                .title = row.title,
                .artist_credit = row.artist_credit,
                .length_ms = row.length_ms,
                .recording_mbid = row.recording_mbid,
                .release_track_mbid = row.release_track_mbid,
            };
            if (row.evidence.recording_source == .pending_match) entry.accept = acceptable(track, row.recording_mbid, compared);
            break;
        }
        try apply_tracks.append(allocator, entry);
    }
    return .{ .view = view, .tracklist = tracklist, .alignment = alignment, .apply_tracks = apply_tracks, .allocator = allocator };
}

/// The pending proposal of `recording_mbid` an Apply accepts: one enriched
/// for the release first, and never one in an album group or a correction.
fn acceptable(track: *const database.ReleaseMatchTrack, recording_mbid: []const u8, release_mbid: []const u8) ?i64 {
    var fallback: ?i64 = null;
    for (track.proposals) |proposal| {
        if (proposal.state != .pending or proposal.in_album_group or proposal.corrects) continue;
        if (!std.mem.eql(u8, proposal.recording_mbid, recording_mbid)) continue;
        const release = proposal.payload.release_mbid orelse {
            fallback = fallback orelse proposal.id;
            continue;
        };
        if (std.mem.eql(u8, release, release_mbid)) return proposal.id;
        fallback = fallback orelse proposal.id;
    }
    return fallback;
}
