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
    /// marked as reviewed because it left no Track alone and no value
    /// differing; null otherwise.
    reviewed_release_id: ?i64 = null,

    pub fn deinit(self: ReleaseApplyOutcome) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

/// The fields Mark as Reviewed requires an Apply to leave unchanged.
pub const stored_fields: database.ReleaseFieldSet = .initMany(&.{ .album, .album_artist, .release_date, .release_id, .track_titles });

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
    }, fields, false, written);
    try library.database.exec("COMMIT;");
    return outcome;
}

/// Records that a person found the Release equal to `release_mbid`, else its
/// best candidate. Refused with `error.ReleaseNotPlaced` unless every Track
/// has a play file and is placed, and with `error.ReleaseDiffers` when an
/// Apply of every field would change a value in effect. The review holds
/// while that release stays the best candidate and the Release's Tracks,
/// their values and the snapshot stay as they were.
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
/// null when the files now lie on several Releases or marking is refused for
/// an unplaced Track or a differing value.
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
        error.ReleaseNotPlaced, error.ReleaseDiffers => {
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
    const differing = try library.identification_proposals.applyReleasePlanLocked(allocator, &.{
        .tracklist = &planned.tracklist.record,
        .tracks = planned.apply_tracks.items,
    }, stored_fields, true, null);
    if (differing != 0) return error.ReleaseDiffers;
    const compared = planned.tracklist.record.release_mbid;
    const digest = try database.repository.releaseReviewDigest(library.database, release_id, compared) orelse
        return error.NoReleaseTracklist;
    try library.reviewed_releases.markLocked(release_id, compared, digest);
}

/// How many of the Release's Tracks the alignment with `release_mbid`'s
/// snapshot places; null without a snapshot or for a Release of more than
/// `max_page` Tracks. One view read, one snapshot read, one pairings read.
pub fn placementCounts(
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    release_id: i64,
    release_mbid: []const u8,
) !?database.ReleasePlacementCounts {
    const view = try library.identification_proposals.releaseMatchView(allocator, release_id, false);
    defer view.deinit();
    if (view.track_count > database.repository.max_page) return null;
    var tracklist = try library.release_tracklists.get(allocator, release_mbid) orelse return null;
    defer tracklist.deinit();
    var pairings = try library.release_track_pairings.list(allocator, release_id, release_mbid);
    defer pairings.deinit();
    const alignment = try release_alignment.alignRelease(allocator, release_id, view.tracks, &tracklist.record, pairings.items);
    defer alignment.deinit();
    var placed: u32 = 0;
    for (alignment.rows) |row| {
        if (row.track != null and isPlacing(row.status)) placed += 1;
    }
    return .{ .placed = placed, .needs_pairing = @intCast(view.tracks.len - placed) };
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
        for (self.apply_tracks.items) |track| {
            if (track.track_id == track_id) return track.placed != null;
        }
        return false;
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
