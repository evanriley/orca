const std = @import("std");
const sqlite = @import("../sqlite.zig");
const WriteLane = @import("write_lane.zig").WriteLane;

pub const lyrics_digest_bytes = 32;

pub const LyricsRecord = struct {
    lrclib_id: ?i64 = null,
    synced: ?[]const u8 = null,
    plain: ?[]const u8 = null,
    instrumental: bool = false,

    pub fn isMiss(self: LyricsRecord) bool {
        return self.synced == null and self.plain == null and !self.instrumental;
    }
};

pub const StoredLyrics = struct {
    allocator: std.mem.Allocator,
    query_digest: [lyrics_digest_bytes]u8,
    record: LyricsRecord,
    fetched_at: i64,

    pub fn deinit(self: StoredLyrics) void {
        if (self.record.synced) |text| self.allocator.free(text);
        if (self.record.plain) |text| self.allocator.free(text);
    }
};

pub const TrackLyricsRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn get(self: *const TrackLyricsRepository, allocator: std.mem.Allocator, track_id: i64) !?StoredLyrics {
        var statement = try self.db.prepare(
            "SELECT query_digest, lrclib_id, synced, plain, instrumental, fetched_at FROM track_lyrics WHERE track_id=?1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return null;
        const digest = statement.columnBlob(0);
        if (digest.len != lyrics_digest_bytes) return null;
        const synced = try dupeOptional(allocator, statement, 2);
        errdefer if (synced) |text| allocator.free(text);
        const plain = try dupeOptional(allocator, statement, 3);
        return .{
            .allocator = allocator,
            .query_digest = digest[0..lyrics_digest_bytes].*,
            .record = .{
                .lrclib_id = if (statement.columnIsNull(1)) null else statement.columnInt64(1),
                .synced = synced,
                .plain = plain,
                .instrumental = statement.columnInt64(4) != 0,
            },
            .fetched_at = statement.columnInt64(5),
        };
    }

    /// False when the Track no longer exists, and nothing is stored.
    pub fn put(
        self: *TrackLyricsRepository,
        track_id: i64,
        query_digest: *const [lyrics_digest_bytes]u8,
        record: LyricsRecord,
        fetched_at: i64,
    ) !bool {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var statement = try self.db.prepare(
            \\INSERT INTO track_lyrics(track_id, query_digest, lrclib_id, synced, plain, instrumental, fetched_at)
            \\SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7 WHERE EXISTS (SELECT 1 FROM tracks WHERE id=?1)
            \\ON CONFLICT(track_id) DO UPDATE SET query_digest=excluded.query_digest,
            \\    lrclib_id=excluded.lrclib_id, synced=excluded.synced, plain=excluded.plain,
            \\    instrumental=excluded.instrumental, fetched_at=excluded.fetched_at;
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        try statement.bindBlob(2, query_digest);
        try statement.bindOptionalInt64(3, record.lrclib_id);
        try statement.bindOptionalText(4, record.synced);
        try statement.bindOptionalText(5, record.plain);
        try statement.bindInt64(6, @intFromBool(record.instrumental));
        try statement.bindInt64(7, fetched_at);
        if (try statement.step() != .done) return error.SqlFailed;
        const stored = self.db.changes() != 0;
        try self.db.exec("COMMIT;");
        return stored;
    }
};

fn dupeOptional(allocator: std.mem.Allocator, statement: sqlite.Statement, index: c_int) !?[]u8 {
    if (statement.columnIsNull(index)) return null;
    return try allocator.dupe(u8, statement.columnText(index));
}
