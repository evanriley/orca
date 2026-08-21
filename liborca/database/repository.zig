const std = @import("std");
const sqlite = @import("sqlite.zig");

pub const WriteLane = struct {
    lock: std.atomic.Mutex = .unlocked,

    pub fn acquire(self: *WriteLane) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn release(self: *WriteLane) void {
        self.lock.unlock();
    }
};

pub const TrackInput = struct {
    title: []const u8,
    album: []const u8 = "",
    album_artist: []const u8 = "",
    duration_ms: ?i64 = null,
    track_number: ?i64 = null,
    disc_number: ?i64 = null,
};

pub const ObservedFileInput = struct {
    path: []const u8,
    inode: i64,
    size_bytes: i64,
    modified_ns: i64,
    audio_format: u8,
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    track_number: ?i64 = null,
};

pub const TrackSummary = struct {
    id: i64,
    title: []u8,
    album: []u8,
    album_artist: []u8,

    pub fn deinit(self: TrackSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.album);
        allocator.free(self.album_artist);
    }
};

pub const TrackPage = struct {
    allocator: std.mem.Allocator,
    items: []TrackSummary,

    pub fn deinit(self: TrackPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const TrackRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn insertBatch(self: *TrackRepository, tracks: []const TrackInput) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};

        var statement = try self.db.prepare(
            \\INSERT INTO tracks(
            \\    title, album, album_artist, duration_ms, track_number, disc_number
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6);
        );
        defer statement.deinit();
        for (tracks) |track| {
            try statement.bindText(1, track.title);
            try statement.bindText(2, track.album);
            try statement.bindText(3, track.album_artist);
            try statement.bindOptionalInt64(4, track.duration_ms);
            try statement.bindOptionalInt64(5, track.track_number);
            try statement.bindOptionalInt64(6, track.disc_number);
            if (try statement.step() != .done) return error.SqlFailed;
            try statement.reset();
        }
        try self.db.exec("COMMIT;");
    }

    pub fn setRatings(self: *TrackRepository, ids: []const i64, rating: u8) !void {
        if (rating > 100) return error.InvalidRating;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var statement = try self.db.prepare("UPDATE tracks SET rating=?1 WHERE id=?2;");
        defer statement.deinit();
        for (ids) |id| {
            try statement.bindInt64(1, rating);
            try statement.bindInt64(2, id);
            if (try statement.step() != .done) return error.SqlFailed;
            try statement.reset();
        }
        try self.db.exec("COMMIT;");
    }

    pub fn search(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: u32,
        offset: u32,
    ) !TrackPage {
        var statement = try self.db.prepare(
            \\SELECT tracks.id, tracks.title, tracks.album, tracks.album_artist
            \\FROM track_search
            \\JOIN tracks ON tracks.id = track_search.rowid
            \\WHERE track_search MATCH ?1
            \\ORDER BY rank
            \\LIMIT ?2 OFFSET ?3;
        );
        defer statement.deinit();
        try statement.bindText(1, query);
        try statement.bindInt64(2, limit);
        try statement.bindInt64(3, offset);

        var results: std.ArrayList(TrackSummary) = .empty;
        errdefer {
            for (results.items) |item| item.deinit(allocator);
            results.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const title = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(title);
            const album = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(album);
            const album_artist = try allocator.dupe(u8, statement.columnText(3));
            errdefer allocator.free(album_artist);
            try results.append(allocator, .{
                .id = statement.columnInt64(0),
                .title = title,
                .album = album,
                .album_artist = album_artist,
            });
        }
        return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
    }

    pub fn count(self: *const TrackRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM tracks;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn countWithRating(self: *const TrackRepository, rating: u8) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM tracks WHERE rating=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, rating);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

pub const ObservedFileRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn isUnchanged(self: *const ObservedFileRepository, input: ObservedFileInput) !bool {
        var statement = try self.db.prepare(
            \\SELECT EXISTS(
            \\    SELECT 1 FROM observed_files
            \\    WHERE path=?1 AND inode=?2 AND size_bytes=?3 AND modified_ns=?4
            \\);
        );
        defer statement.deinit();
        try bindIdentity(statement, input);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0) != 0;
    }

    pub fn upsertBatch(self: *ObservedFileRepository, files: []const ObservedFileInput) !void {
        if (files.len == 0) return;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var statement = try self.db.prepare(
            \\INSERT INTO observed_files(
            \\    path, inode, size_bytes, modified_ns, audio_format, observed_at
            \\) VALUES (?1, ?2, ?3, ?4, ?5, unixepoch())
            \\ON CONFLICT(path) DO UPDATE SET
            \\    inode=excluded.inode,
            \\    size_bytes=excluded.size_bytes,
            \\    modified_ns=excluded.modified_ns,
            \\    audio_format=excluded.audio_format,
            \\    observed_at=excluded.observed_at;
        );
        defer statement.deinit();
        var metadata_statement = try self.db.prepare(
            \\INSERT INTO observed_file_metadata(path, title, artist, album, track_number)
            \\VALUES (?1, ?2, ?3, ?4, ?5)
            \\ON CONFLICT(path) DO UPDATE SET
            \\    title=excluded.title,
            \\    artist=excluded.artist,
            \\    album=excluded.album,
            \\    track_number=excluded.track_number;
        );
        defer metadata_statement.deinit();
        for (files) |file| {
            try bindIdentity(statement, file);
            try statement.bindInt64(5, file.audio_format);
            if (try statement.step() != .done) return error.SqlFailed;
            try statement.reset();
            try metadata_statement.bindText(1, file.path);
            try metadata_statement.bindOptionalText(2, file.title);
            try metadata_statement.bindOptionalText(3, file.artist);
            try metadata_statement.bindOptionalText(4, file.album);
            try metadata_statement.bindOptionalInt64(5, file.track_number);
            if (try metadata_statement.step() != .done) return error.SqlFailed;
            try metadata_statement.reset();
        }
        try self.db.exec("COMMIT;");
    }

    pub fn count(self: *const ObservedFileRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM observed_files;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn title(
        self: *const ObservedFileRepository,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !?[]u8 {
        var statement = try self.db.prepare(
            "SELECT title FROM observed_file_metadata WHERE path=?1;",
        );
        defer statement.deinit();
        try statement.bindText(1, path);
        if (try statement.step() != .row) return null;
        return try allocator.dupe(u8, statement.columnText(0));
    }

    fn bindIdentity(statement: sqlite.Statement, input: ObservedFileInput) !void {
        try statement.bindText(1, input.path);
        try statement.bindInt64(2, input.inode);
        try statement.bindInt64(3, input.size_bytes);
        try statement.bindInt64(4, input.modified_ns);
    }
};
