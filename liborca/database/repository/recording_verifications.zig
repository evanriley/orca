const std = @import("std");
const sqlite = @import("../sqlite.zig");
const metadata = @import("../../metadata/model.zig");
const columns = @import("../columns.zig");
const identification = @import("identification.zig");
const tracks = @import("tracks.zig");

const max_page = columns.max_page;
const effectiveRecordingMbid = tracks.effectiveRecordingMbid;
const track_play_file = tracks.track_play_file;
const MatchScope = identification.MatchScope;
const ProposalState = identification.ProposalState;
const WriteLane = @import("write_lane.zig").WriteLane;

/// Stored by number in `recording_verifications.outcome`.
pub const VerificationOutcome = enum(u8) {
    agrees,
    disagrees,
    unconfirmed,
    no_fingerprint,
};

/// A recording AcoustID matched a file's fingerprint to, with its score from
/// 0 to 1.
pub const HeardRecording = struct {
    mbid: []const u8,
    score: f32,
};

pub const max_heard = 8;

/// One file's verification as it is stored. `heard` is strongest first.
pub const Verification = struct {
    file_id: i64,
    quick_hash: ?[]const u8,
    recording_mbid: []const u8,
    outcome: VerificationOutcome,
    heard: []const HeardRecording,
};

/// A Track's stored verification. Caller-owned: release with `deinit`.
pub const TrackVerification = struct {
    arena: *std.heap.ArenaAllocator,
    outcome: VerificationOutcome,
    /// Unix seconds.
    verified_at: i64,
    /// The recording ID in effect when the file was verified.
    recording_mbid: []const u8,
    heard: []const HeardRecording,
    /// The file's bytes or its recording ID in effect changed since.
    stale: bool,
    /// The strongest recording heard has a dismissed proposal on the file.
    dismissed: bool,

    pub fn deinit(self: TrackVerification) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

/// A play file a verification pass checks: one with a recording ID in effect
/// whose verification is missing or stale, or one that `disagrees` beside
/// such a file of its Release or asked about alone.
pub const VerifiableFile = struct {
    track_id: i64,
    file_id: i64,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    duration_ms: ?i64,
    /// Where the file is, or null when no location of it is present.
    path: ?[]const u8,
    quick_hash: ?[]const u8,
    recording_mbid: []const u8,
    /// The recording ID in effect is the user's own locked edit.
    user_locked: bool,
    /// What the stored verification heard, when the file's bytes have not
    /// changed since.
    heard_before: ?[]const HeardRecording,
};

pub const VerifiableFilePage = struct {
    arena: *std.heap.ArenaAllocator,
    items: []VerifiableFile,

    pub fn deinit(self: VerifiableFilePage) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

/// Which play files `unitPage` reads.
pub const VerificationUnit = union(enum) {
    /// A Release's stale and unverified files and those that `disagrees`, for
    /// a Release `isReleaseDue` found due before its first page.
    release: i64,
    /// Tracks with no Release.
    loose,
    track: i64,
};

pub const RecordingVerificationRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// The unit's verifiable play files after Track `cursor`, by Track id.
    pub fn unitPage(
        self: *const RecordingVerificationRepository,
        allocator: std.mem.Allocator,
        unit: VerificationUnit,
        cursor: i64,
        limit: u32,
    ) !VerifiableFilePage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(switch (unit) {
            .release => verifiable_release_page_sql,
            .loose => verifiable_loose_page_sql,
            .track => verifiable_track_page_sql,
        });
        defer statement.deinit();
        switch (unit) {
            .release, .track => |id| try statement.bindInt64(1, id),
            .loose => {},
        }
        try statement.bindInt64(2, cursor);
        try statement.bindInt64(3, limit);

        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        const page: VerifiableFilePage = .{ .arena = arena, .items = &.{} };
        errdefer page.deinit();
        const owned = arena.allocator();
        var items: std.ArrayList(VerifiableFile) = .empty;
        while (try statement.step() == .row) {
            try items.append(owned, .{
                .track_id = statement.columnInt64(0),
                .file_id = statement.columnInt64(1),
                .title = try owned.dupe(u8, statement.columnText(2)),
                .artist = try owned.dupe(u8, statement.columnText(3)),
                .album = try owned.dupe(u8, statement.columnText(4)),
                .duration_ms = columns.optionalInt64(statement, 5),
                .path = try columns.duplicateNullableColumn(owned, statement, 6),
                .quick_hash = if (statement.columnIsNull(7)) null else try owned.dupe(u8, statement.columnBlob(7)),
                .recording_mbid = try owned.dupe(u8, statement.columnText(8)),
                .user_locked = statement.columnInt64(9) != 0,
                .heard_before = if (statement.columnIsNull(10)) null else try parseHeard(owned, statement.columnText(10)),
            });
        }
        return .{ .arena = arena, .items = items.items };
    }

    /// Releases after `cursor`, by id, with a verifiable play file.
    pub fn releasesToVerify(self: *const RecordingVerificationRepository, cursor: i64, buffer: []i64) ![]i64 {
        var statement = try self.db.prepare(verifiable_releases_sql);
        defer statement.deinit();
        try statement.bindInt64(1, cursor);
        try statement.bindInt64(2, @intCast(buffer.len));
        var count: usize = 0;
        while (try statement.step() == .row) : (count += 1) buffer[count] = statement.columnInt64(0);
        return buffer[0..count];
    }

    /// How many verifiable play files the scope holds, at most `limit`.
    pub fn verifiableCount(self: *const RecordingVerificationRepository, scope: MatchScope, limit: ?u32) !u64 {
        var statement = try self.db.prepare(switch (scope) {
            .library => verifiable_count_sql,
            .release => verifiable_release_count_sql,
            .track => verifiable_track_count_sql,
        });
        defer statement.deinit();
        switch (scope) {
            .release, .track => |id| try statement.bindInt64(1, id),
            .library => {},
        }
        try statement.bindInt64(2, 0);
        try statement.bindInt64(3, if (limit) |bound| bound else -1);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// Whether the Release has a verifiable play file that is stale or
    /// unverified, so its files that `disagrees` are verified again with it.
    pub fn isReleaseDue(self: *const RecordingVerificationRepository, release_id: i64) !bool {
        var statement = try self.db.prepare(verifiable_release_due_sql);
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0) != 0;
    }

    /// Whether the Release has more Tracks than one album group may hold.
    pub fn isLargeRelease(self: *const RecordingVerificationRepository, release_id: i64) !bool {
        var statement = try self.db.prepare("SELECT count(*) FROM (SELECT 1 FROM tracks WHERE release_id = ?1 LIMIT ?2);");
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        try statement.bindInt64(2, max_page + 1);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0) > max_page;
    }

    /// The Release's tagged MusicBrainz release ID, when it is one.
    pub fn releaseTag(self: *const RecordingVerificationRepository, release_id: i64, buffer: *[36]u8) !?[]const u8 {
        var statement = try self.db.prepare("SELECT musicbrainz_release_id FROM releases WHERE id = ?1;");
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        if (try statement.step() != .row) return null;
        const tag = statement.columnText(0);
        if (!metadata.isMusicBrainzId(tag)) return null;
        buffer.* = tag[0..36].*;
        return buffer;
    }

    pub fn forTrack(
        self: *const RecordingVerificationRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
    ) !?TrackVerification {
        var statement = try self.db.prepare(comptime "SELECT verification.file_id, verification.outcome, verification.verified_at,\n" ++
            "       verification.recording_mbid, verification.heard,\n" ++
            "       verification.quick_hash IS NOT files.quick_hash\n" ++
            "       OR verification.recording_mbid IS NOT " ++ effectiveRecordingMbid("verification.file_id") ++ "\n" ++
            "FROM recording_verifications AS verification JOIN files ON files.id = verification.file_id\n" ++
            "WHERE verification.file_id = (SELECT " ++ track_play_file ++ " FROM tracks WHERE tracks.id = ?1);");
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return null;
        const outcome = std.enums.fromInt(VerificationOutcome, statement.columnInt64(1)) orelse
            return error.InvalidStoredVerification;

        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        const owned = arena.allocator();
        const file_id = statement.columnInt64(0);
        const heard: []const HeardRecording = if (statement.columnIsNull(4)) &.{} else try parseHeard(owned, statement.columnText(4));
        return .{
            .arena = arena,
            .outcome = outcome,
            .verified_at = statement.columnInt64(2),
            .recording_mbid = try owned.dupe(u8, statement.columnText(3)),
            .heard = heard,
            .stale = statement.columnInt64(5) != 0,
            .dismissed = if (heard.len == 0) false else try self.isDismissed(file_id, heard[0].mbid),
        };
    }

    fn isDismissed(self: *const RecordingVerificationRepository, file_id: i64, recording_mbid: []const u8) !bool {
        var statement = try self.db.prepare(
            "SELECT 1 FROM identification_proposals WHERE file_id = ?1 AND provider_id = ?2 AND state = ?3 LIMIT 1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindText(2, recording_mbid);
        try statement.bindInt64(3, @backingInt(ProposalState.dismissed));
        return try statement.step() == .row;
    }
};

/// Stores or replaces one file's verification inside the caller's
/// transaction.
pub fn putLocked(db: sqlite.Database, verification: Verification) !void {
    var buffer: [max_heard * 80]u8 = undefined;
    var heard: std.Io.Writer = .fixed(&buffer);
    if (verification.outcome != .no_fingerprint) try writeHeard(&heard, verification.heard);
    var statement = try db.prepare(
        \\INSERT INTO recording_verifications(file_id, quick_hash, recording_mbid, outcome, heard, verified_at)
        \\VALUES (?1, ?2, ?3, ?4, ?5, unixepoch())
        \\ON CONFLICT(file_id) DO UPDATE SET quick_hash=excluded.quick_hash,
        \\    recording_mbid=excluded.recording_mbid, outcome=excluded.outcome,
        \\    heard=excluded.heard, verified_at=excluded.verified_at;
    );
    defer statement.deinit();
    try statement.bindInt64(1, verification.file_id);
    try statement.bindOptionalBlob(2, verification.quick_hash);
    try statement.bindText(3, verification.recording_mbid);
    try statement.bindInt64(4, @backingInt(verification.outcome));
    try statement.bindOptionalText(5, if (verification.outcome == .no_fingerprint) null else heard.buffered());
    if (try statement.step() != .done) return error.SqlFailed;
}

fn writeHeard(writer: *std.Io.Writer, heard: []const HeardRecording) !void {
    try writer.writeByte('[');
    for (heard[0..@min(heard.len, max_heard)], 0..) |recording, index| {
        if (index != 0) try writer.writeByte(',');
        if (!metadata.isMusicBrainzId(recording.mbid)) return error.InvalidVerification;
        try writer.print("{{\"mbid\":\"{s}\",\"score\":{d:.3}}}", .{ recording.mbid, std.math.clamp(recording.score, 0, 1) });
    }
    try writer.writeByte(']');
}

fn parseHeard(allocator: std.mem.Allocator, text: []const u8) ![]const HeardRecording {
    const parsed = std.json.parseFromSliceLeaky([]const HeardRecording, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return &.{},
    };
    return parsed;
}

const recording_mbid_field = std.fmt.comptimePrint("{d}", .{@backingInt(metadata.Field.musicbrainz_recording_id)});
const user_provenance = std.fmt.comptimePrint("{d}", .{@backingInt(metadata.Provenance.user)});
const disagrees_outcome = std.fmt.comptimePrint("{d}", .{@backingInt(VerificationOutcome.disagrees)});

/// Which fresh `disagrees` files `verifiable` selects besides the stale and
/// unverified ones.
const Disputes = enum {
    excluded,
    /// Those of a Release that has a stale or unverified file, so its album
    /// group can form again without every rerun asking about files that
    /// still disagree.
    with_due_release,
    included,
};

/// The names one `verifiable` selection gives its tables, so one can nest
/// inside another.
const Aliases = struct {
    track: []const u8,
    candidate: []const u8,
    file: []const u8,
    verification: []const u8,
};

const outer: Aliases = .{ .track = "track", .candidate = "candidate", .file = "files", .verification = "verification" };
const sibling: Aliases = .{ .track = "sibling_track", .candidate = "sibling", .file = "sibling_file", .verification = "sibling_verification" };

/// The play files of the Tracks `track_filter` picks that have a recording
/// ID in effect and no verification or a stale one, and fresh `disagrees`
/// ones as `disputes` says. Stale: the file's bytes or its recording ID in
/// effect changed since.
fn verifiable(comptime names: Aliases, comptime track_filter: []const u8, comptime disputes: Disputes) []const u8 {
    const track = names.track;
    const candidate = names.candidate;
    const file = names.file;
    const verification = names.verification;
    return "(SELECT " ++ track ++ ".id, " ++ track ++ ".release_id, " ++ track ++ ".file_id, " ++ track ++ ".title, " ++ track ++ ".artist,\n" ++
        "        " ++ track ++ ".album, " ++ track ++ ".duration_ms, " ++ effectiveRecordingMbid(track ++ ".file_id") ++ " AS recording_mbid\n" ++
        "    FROM (SELECT tracks.id, tracks.release_id, " ++ track_play_file ++ " AS file_id,\n" ++
        "                 tracks.title, tracks.artist, tracks.album, tracks.duration_ms\n" ++
        "          FROM tracks WHERE " ++ track_filter ++ ") AS " ++ track ++ "\n" ++
        "    WHERE " ++ track ++ ".file_id IS NOT NULL) AS " ++ candidate ++ "\n" ++
        "JOIN files AS " ++ file ++ " ON " ++ file ++ ".id = " ++ candidate ++ ".file_id\n" ++
        "LEFT JOIN recording_verifications AS " ++ verification ++ " ON " ++ verification ++ ".file_id = " ++ candidate ++ ".file_id\n" ++
        "WHERE " ++ candidate ++ ".recording_mbid IS NOT NULL\n" ++
        "  AND (" ++ verification ++ ".file_id IS NULL OR " ++ verification ++ ".quick_hash IS NOT " ++ file ++ ".quick_hash\n" ++
        "       OR " ++ verification ++ ".recording_mbid IS NOT " ++ candidate ++ ".recording_mbid" ++
        switch (disputes) {
            .excluded => "",
            .included => "\n       OR " ++ verification ++ ".outcome = " ++ disagrees_outcome,
            .with_due_release => "\n       OR (" ++ verification ++ ".outcome = " ++ disagrees_outcome ++ " AND EXISTS (SELECT 1 FROM " ++
                verifiable(sibling, "tracks.release_id = " ++ candidate ++ ".release_id", .excluded) ++ "))",
        } ++ ")";
}

/// ?1 is the Release or Track, ?2 the Track cursor, ?3 the page size.
fn verifiablePageSql(comptime track_filter: []const u8, comptime disputes: Disputes) [:0]const u8 {
    return "SELECT candidate.id, candidate.file_id, candidate.title, candidate.artist, candidate.album,\n" ++
        "       candidate.duration_ms,\n" ++
        "       (SELECT locations.uri FROM locations\n" ++
        "        WHERE locations.file_id = candidate.file_id AND locations.state = 'present'\n" ++
        "        ORDER BY locations.id LIMIT 1),\n" ++
        "       files.quick_hash, candidate.recording_mbid,\n" ++
        "       EXISTS (SELECT 1 FROM orca_metadata_values AS edit\n" ++
        "               WHERE edit.file_id = candidate.file_id AND edit.field = " ++ recording_mbid_field ++ "\n" ++
        "                 AND edit.locked = 1 AND edit.provenance = " ++ user_provenance ++ "),\n" ++
        "       CASE WHEN verification.quick_hash = files.quick_hash THEN verification.heard END\n" ++
        "FROM " ++ verifiable(outer, track_filter, disputes) ++ "\nORDER BY candidate.id LIMIT ?3;";
}

fn verifiableCountSql(comptime track_filter: []const u8, comptime disputes: Disputes) [:0]const u8 {
    return "SELECT count(*) FROM (SELECT 1 FROM " ++ verifiable(outer, track_filter, disputes) ++ " LIMIT ?3);";
}

const release_tracks = "tracks.release_id = ?1 AND tracks.id > ?2";
const loose_tracks = "tracks.release_id IS NULL AND tracks.id > ?2";
const one_track = "tracks.id = ?1 AND tracks.id > ?2";
const every_track = "tracks.id > ?2";

pub const verifiable_release_page_sql = verifiablePageSql(release_tracks, .included);
pub const verifiable_loose_page_sql = verifiablePageSql(loose_tracks, .excluded);
pub const verifiable_track_page_sql = verifiablePageSql(one_track, .included);
pub const verifiable_count_sql = verifiableCountSql(every_track, .with_due_release);
pub const verifiable_release_count_sql = verifiableCountSql(release_tracks, .with_due_release);
pub const verifiable_track_count_sql = verifiableCountSql(one_track, .included);
pub const verifiable_release_due_sql: [:0]const u8 =
    "SELECT EXISTS (SELECT 1 FROM " ++ verifiable(outer, "tracks.release_id = ?1", .excluded) ++ ");";
pub const verifiable_releases_sql: [:0]const u8 =
    "SELECT DISTINCT candidate.release_id FROM " ++ verifiable(outer, "tracks.release_id > ?1", .excluded) ++
    "\nORDER BY candidate.release_id LIMIT ?2;";

const testing = std.testing;

test "a stored heard list keeps at most eight recordings, strongest first, and reads back" {
    const mbid = "aaaaaaaa-0000-4000-8000-000000000000";
    var heard: [max_heard + 2]HeardRecording = undefined;
    for (&heard, 0..) |*recording, index| recording.* = .{ .mbid = mbid, .score = 1 - @as(f32, @floatFromInt(index)) / 20 };
    var written: std.Io.Writer.Allocating = .init(testing.allocator);
    defer written.deinit();
    try writeHeard(&written.writer, &heard);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const read = try parseHeard(arena.allocator(), written.written());
    try testing.expectEqual(@as(usize, max_heard), read.len);
    try testing.expectEqualStrings(mbid, read[0].mbid);
    try testing.expectApproxEqAbs(@as(f32, 1), read[0].score, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.65), read[max_heard - 1].score, 0.001);
    try testing.expectEqual(@as(usize, 0), (try parseHeard(arena.allocator(), "not json")).len);
}
