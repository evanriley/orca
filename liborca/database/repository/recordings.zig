const std = @import("std");
const sqlite = @import("../sqlite.zig");

const WriteLane = @import("write_lane.zig").WriteLane;

/// A performance, distinct from the Track position that presents it and from
/// the files that encode it.
pub const RecordingInput = struct {
    title: []const u8,
    duration_ms: ?i64 = null,
};

pub const RecordingSummary = struct {
    id: i64,
    title: []u8,
    artist: []u8,
    artist_id: ?i64,

    pub fn deinit(self: RecordingSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.artist);
    }
};

/// Recordings — performances — which files encode and tracks position.
///
/// The schema carries no key column for a recording, so the projection keeps
/// the mapping itself and reuses whatever `files.recording_id` already says.
/// This repository therefore inserts and updates; it never resolves.
pub const RecordingRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn insertLocked(self: *RecordingRepository, input: RecordingInput) !i64 {
        var statement = try self.db.prepare(
            "INSERT INTO recordings(title, duration_ms) VALUES (?1, ?2) RETURNING id;",
        );
        defer statement.deinit();
        try statement.bindText(1, input.title);
        try statement.bindOptionalInt64(2, input.duration_ms);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    pub fn updateLocked(self: *RecordingRepository, id: i64, input: RecordingInput) !void {
        var statement = try self.db.prepare(
            "UPDATE recordings SET title=?1, duration_ms=COALESCE(?2, duration_ms) WHERE id=?3;",
        );
        defer statement.deinit();
        try statement.bindText(1, input.title);
        try statement.bindOptionalInt64(2, input.duration_ms);
        try statement.bindInt64(3, id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    pub fn summary(self: *const RecordingRepository, allocator: std.mem.Allocator, id: i64) !?RecordingSummary {
        var statement = try self.db.prepare(
            \\SELECT recordings.title, COALESCE(NULLIF(tracks.artist, ''), artists.name, ''), tracks.artist_id
            \\FROM recordings
            \\LEFT JOIN tracks ON tracks.id = (SELECT min(id) FROM tracks WHERE recording_id = recordings.id)
            \\LEFT JOIN artists ON artists.id = tracks.artist_id
            \\WHERE recordings.id = ?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, id);
        if (try statement.step() != .row) return null;
        const title = try allocator.dupe(u8, statement.columnText(0));
        errdefer allocator.free(title);
        const artist = try allocator.dupe(u8, statement.columnText(1));
        return .{
            .id = id,
            .title = title,
            .artist = artist,
            .artist_id = if (statement.columnIsNull(2)) null else statement.columnInt64(2),
        };
    }

    pub fn count(self: *const RecordingRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM recordings;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

test "a Recording summary carries its first Track's artist credit and is null when unknown" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-recording-summary?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES (1, 'Credited', 'Credited', 'credited');
        \\INSERT INTO recordings(id, title) VALUES (1, 'Song'), (2, 'Bare'), (3, 'Named');
        \\INSERT INTO tracks(id, recording_id, title, artist, artist_id) VALUES
        \\    (1, 1, 'Song', '', 1), (2, 1, 'Song', 'Later', NULL), (3, 3, 'Named', 'Tag Credit', NULL);
    );
    const credited = (try library.recordings.summary(std.testing.allocator, 1)).?;
    defer credited.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Song", credited.title);
    try std.testing.expectEqualStrings("Credited", credited.artist);
    try std.testing.expectEqual(@as(?i64, 1), credited.artist_id);
    const bare = (try library.recordings.summary(std.testing.allocator, 2)).?;
    defer bare.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", bare.artist);
    try std.testing.expectEqual(@as(?i64, null), bare.artist_id);
    const named = (try library.recordings.summary(std.testing.allocator, 3)).?;
    defer named.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Tag Credit", named.artist);
    try std.testing.expectEqual(@as(?RecordingSummary, null), try library.recordings.summary(std.testing.allocator, 4));
}
