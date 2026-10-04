const std = @import("std");
const sqlite = @import("../sqlite.zig");
const columns = @import("../columns.zig");

const optionalInt64 = columns.optionalInt64;
const enqueueScrobbleLocked = @import("scrobble_queue.zig").enqueueScrobbleLocked;
const effectiveRecordingMbid = @import("tracks.zig").effectiveRecordingMbid;
const track_play_file = @import("tracks.zig").track_play_file;
const WriteLane = @import("write_lane.zig").WriteLane;

pub const ListenInput = struct {
    file_id: i64,
    started_at: i64,
    listened_ms: u64,
    duration_ms: ?u64 = null,
    title: []const u8,
    artist: []const u8,
    album: []const u8 = "",
    recording_mbid: ?[]const u8 = null,
    player_client: []const u8 = "",
    syncable: bool = true,
};

pub const PlayStats = struct {
    play_count: u64,
    last_played_at: ?i64,
};

pub const ListenSubject = struct {
    allocator: std.mem.Allocator,
    file_id: ?i64,
    recording_id: ?i64,
    title: []u8,
    artist: []u8,
    album: []u8,
    duration_ms: ?i64,
    track_number: ?i64,
    recording_mbid: ?[]u8,
    release_mbid: ?[]u8,
    artist_mbid: ?[]u8,

    pub fn deinit(self: ListenSubject) void {
        self.allocator.free(self.title);
        self.allocator.free(self.artist);
        self.allocator.free(self.album);
        if (self.recording_mbid) |value| self.allocator.free(value);
        if (self.release_mbid) |value| self.allocator.free(value);
        if (self.artist_mbid) |value| self.allocator.free(value);
    }
};

pub const ListenRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Records a listen, or returns null when this file already has one that
    /// started at the same second.
    pub fn record(self: *ListenRepository, input: ListenInput) !?i64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        const id = try self.insertLocked(input);
        try self.db.exec("COMMIT;");
        return id;
    }

    /// Records a listen and queues `payload` for `service` in one transaction,
    /// so a listen is never stored without its delivery or the reverse. A
    /// listen that already existed queues nothing.
    pub fn recordAndQueue(
        self: *ListenRepository,
        input: ListenInput,
        service: []const u8,
        payload: []const u8,
    ) !?i64 {
        if (service.len == 0 or payload.len == 0) return error.InvalidScrobbleEvent;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        const id = try self.insertLocked(input);
        if (id) |listen_id| {
            var key_buffer: [32]u8 = undefined;
            const event_key = std.fmt.bufPrint(&key_buffer, "listen:{d}", .{listen_id}) catch unreachable;
            try enqueueScrobbleLocked(self.db, service, event_key, payload);
        }
        try self.db.exec("COMMIT;");
        return id;
    }

    fn insertLocked(self: *ListenRepository, input: ListenInput) !?i64 {
        const listened_ms = std.math.cast(i64, input.listened_ms) orelse return error.InvalidListen;
        const duration_ms = if (input.duration_ms) |value|
            std.math.cast(i64, value) orelse return error.InvalidListen
        else
            null;
        var statement = try self.db.prepare(
            \\INSERT INTO listens(
            \\    file_id, recording_id, started_at, listened_ms, duration_ms,
            \\    title, artist, album, recording_mbid, player_client, syncable)
            \\VALUES (?1, (SELECT recording_id FROM files WHERE id = ?1), ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            \\ON CONFLICT(file_id, started_at) DO NOTHING
            \\RETURNING id, recording_id;
        );
        defer statement.deinit();
        try statement.bindInt64(1, input.file_id);
        try statement.bindInt64(2, input.started_at);
        try statement.bindInt64(3, listened_ms);
        try statement.bindOptionalInt64(4, duration_ms);
        try statement.bindText(5, input.title);
        try statement.bindText(6, input.artist);
        try statement.bindText(7, input.album);
        try statement.bindOptionalText(8, input.recording_mbid);
        try statement.bindText(9, input.player_client);
        try statement.bindInt64(10, @intFromBool(input.syncable));
        if (try statement.step() != .row) return null;
        const id = statement.columnInt64(0);
        const recording_id = optionalInt64(statement, 1);
        if (try statement.step() != .done) return error.SqlFailed;
        if (recording_id) |recording| try countPlayLocked(self.db, recording, input.started_at);
        return id;
    }

    /// Counts a listen in the transaction that inserts it. The other writer of
    /// `recording_play_stats` is the `files_recording_moves_listens` trigger.
    fn countPlayLocked(db: sqlite.Database, recording_id: i64, started_at: i64) !void {
        var statement = try db.prepare(
            \\INSERT INTO recording_play_stats(recording_id, play_count, last_played_at)
            \\VALUES (?1, 1, ?2)
            \\ON CONFLICT(recording_id) DO UPDATE SET
            \\    play_count = play_count + 1,
            \\    last_played_at = max(last_played_at, excluded.last_played_at);
        );
        defer statement.deinit();
        try statement.bindInt64(1, recording_id);
        try statement.bindInt64(2, started_at);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Raises a recorded listen's `listened_ms` to `listened_ms`; a smaller
    /// value leaves it. No listen for this file and start is not an error.
    pub fn updateListened(self: *ListenRepository, file_id: i64, started_at: i64, listened_ms: u64) !void {
        const value = std.math.cast(i64, listened_ms) orelse return error.InvalidListen;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            "UPDATE listens SET listened_ms = max(listened_ms, ?3) WHERE file_id = ?1 AND started_at = ?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, started_at);
        try statement.bindInt64(3, value);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// `updateListened` for a listen that now meets ListenBrainz's rule:
    /// marks it syncable and, when `payload` is given and it was not syncable
    /// before, queues it for `service` in the same transaction. Returns
    /// whether it queued.
    pub fn finishSyncable(
        self: *ListenRepository,
        file_id: i64,
        started_at: i64,
        listened_ms: u64,
        service: []const u8,
        payload: ?[]const u8,
    ) !bool {
        const value = std.math.cast(i64, listened_ms) orelse return error.InvalidListen;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var statement = try self.db.prepare(
            \\UPDATE listens SET listened_ms = max(listened_ms, ?3), syncable = 1
            \\WHERE file_id = ?1 AND started_at = ?2 AND syncable = 0
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, started_at);
        try statement.bindInt64(3, value);
        var queued = false;
        if (try statement.step() == .row) {
            const listen_id = statement.columnInt64(0);
            if (try statement.step() != .done) return error.SqlFailed;
            if (payload) |bytes| {
                var key_buffer: [32]u8 = undefined;
                const event_key = std.fmt.bufPrint(&key_buffer, "listen:{d}", .{listen_id}) catch unreachable;
                try enqueueScrobbleLocked(self.db, service, event_key, bytes);
                queued = true;
            }
        } else {
            var update = try self.db.prepare(
                "UPDATE listens SET listened_ms = max(listened_ms, ?3) WHERE file_id = ?1 AND started_at = ?2;",
            );
            defer update.deinit();
            try update.bindInt64(1, file_id);
            try update.bindInt64(2, started_at);
            try update.bindInt64(3, value);
            if (try update.step() != .done) return error.SqlFailed;
        }
        try self.db.exec("COMMIT;");
        return queued;
    }

    /// Deletes every listen, every delivery of one, sent or not, and the
    /// play counts drawn from them, in one transaction. Ratings, loves and
    /// feedback stay. Returns how many listens went.
    pub fn clear(self: *ListenRepository) !u64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        // Listen ids restart at 1 once the table is empty, and a delivery
        // left keyed `listen:<id>` would silently swallow the new listen's.
        try self.db.exec("DELETE FROM scrobble_queue WHERE event_key LIKE 'listen:%';");
        try self.db.exec("DELETE FROM listens;");
        const removed = self.db.changes();
        try self.db.exec("DELETE FROM recording_play_stats;");
        try self.db.exec("COMMIT;");
        return removed;
    }

    pub fn count(self: *const ListenRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM listens;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// Plays of the Track's recording, from every file of it. Keyed on the
    /// recording, so the count survives an edit that reprojects the Track
    /// under a new id.
    pub fn trackPlayStats(self: *const ListenRepository, track_id: i64) !PlayStats {
        var statement = try self.db.prepare(
            \\SELECT COALESCE(recording_play_stats.play_count, 0), recording_play_stats.last_played_at
            \\FROM tracks LEFT JOIN recording_play_stats
            \\    ON recording_play_stats.recording_id = tracks.recording_id
            \\WHERE tracks.id = ?1
            \\UNION ALL SELECT 0, NULL
            \\LIMIT 1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        return readPlayStats(statement);
    }

    pub fn filePlayStats(self: *const ListenRepository, file_id: i64) !PlayStats {
        var statement = try self.db.prepare(
            "SELECT count(*), max(started_at) FROM listens WHERE file_id = ?1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        return readPlayStats(statement);
    }

    fn readPlayStats(statement: sqlite.Statement) !PlayStats {
        if (try statement.step() != .row) return error.SqlFailed;
        return .{
            .play_count = @intCast(statement.columnInt64(0)),
            .last_played_at = if (statement.columnIsNull(1)) null else statement.columnInt64(1),
        };
    }

    /// What a listen of this Track needs: the metadata the library shows for
    /// it and the MusicBrainz ids recorded for the file it plays. Null when the
    /// Track does not exist.
    pub fn listenSubject(
        self: *const ListenRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
    ) !?ListenSubject {
        var statement = try self.db.prepare(
            "WITH subject AS (\n" ++
                "    SELECT " ++ track_play_file ++ " AS file_id, tracks.recording_id,\n" ++
                "           tracks.title, tracks.artist, tracks.album,\n" ++
                "           tracks.duration_ms, tracks.track_number\n" ++
                "    FROM tracks WHERE tracks.id = ?1)\n" ++
                "SELECT subject.file_id, subject.recording_id, subject.title, subject.artist,\n" ++
                "       subject.album, subject.duration_ms, subject.track_number,\n" ++
                "       " ++ comptime effectiveRecordingMbid("subject.file_id") ++ ",\n" ++
                "       observed_file_tags.musicbrainz_release_id,\n" ++
                "       observed_file_tags.musicbrainz_artist_id\n" ++
                "FROM subject LEFT JOIN observed_file_tags ON observed_file_tags.file_id = subject.file_id;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return null;
        const title = try allocator.dupe(u8, statement.columnText(2));
        errdefer allocator.free(title);
        const artist = try allocator.dupe(u8, statement.columnText(3));
        errdefer allocator.free(artist);
        const album = try allocator.dupe(u8, statement.columnText(4));
        errdefer allocator.free(album);
        const recording_mbid = try dupeNonEmpty(allocator, statement, 7);
        errdefer if (recording_mbid) |value| allocator.free(value);
        const release_mbid = try dupeNonEmpty(allocator, statement, 8);
        errdefer if (release_mbid) |value| allocator.free(value);
        const artist_mbid = try dupeNonEmpty(allocator, statement, 9);
        errdefer if (artist_mbid) |value| allocator.free(value);
        return .{
            .allocator = allocator,
            .file_id = optionalInt64(statement, 0),
            .recording_id = optionalInt64(statement, 1),
            .title = title,
            .artist = artist,
            .album = album,
            .duration_ms = optionalInt64(statement, 5),
            .track_number = optionalInt64(statement, 6),
            .recording_mbid = recording_mbid,
            .release_mbid = release_mbid,
            .artist_mbid = artist_mbid,
        };
    }

    fn dupeNonEmpty(allocator: std.mem.Allocator, statement: sqlite.Statement, column: c_int) !?[]u8 {
        if (statement.columnIsNull(column)) return null;
        const value = statement.columnText(column);
        if (value.len == 0) return null;
        return try allocator.dupe(u8, value);
    }
};
