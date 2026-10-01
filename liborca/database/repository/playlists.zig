const std = @import("std");
const sqlite = @import("../sqlite.zig");
const columns = @import("../columns.zig");
const text_key = @import("../text_key.zig");
const tracks = @import("tracks.zig");

const max_page = columns.max_page;
const optionalInt64 = columns.optionalInt64;
const TrackSummary = tracks.TrackSummary;
const WriteLane = @import("write_lane.zig").WriteLane;

pub const max_playlist_entries = 10_000;
const info_tolerance_ms = 2 * std.time.ms_per_s;

pub const PlaylistSummary = struct {
    id: i64,
    name: []u8,
    entries: u32,
    available: u32,
    duration_ms: i64,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: PlaylistSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const PlaylistPage = struct {
    allocator: std.mem.Allocator,
    items: []PlaylistSummary,

    pub fn deinit(self: PlaylistPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const PlaylistEntry = struct {
    position: u32,
    recording_id: i64,
    track: ?TrackSummary,

    pub fn deinit(self: PlaylistEntry, allocator: std.mem.Allocator) void {
        if (self.track) |track| track.deinit(allocator);
    }
};

pub const PlaylistEntryPage = struct {
    allocator: std.mem.Allocator,
    items: []PlaylistEntry,

    pub fn deinit(self: PlaylistEntryPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const PlaylistInsertion = struct {
    added: u32 = 0,
    skipped: u32 = 0,
};

pub const PlaylistExportRow = struct {
    title: []u8,
    artist: []u8,
    duration_ms: ?i64,
    uri: []u8,

    pub fn deinit(self: PlaylistExportRow, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.artist);
        allocator.free(self.uri);
    }
};

pub const PlaylistExportRows = struct {
    allocator: std.mem.Allocator,
    items: []PlaylistExportRow,
    unavailable: u32,

    pub fn deinit(self: PlaylistExportRows) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

const entry_track =
    "(SELECT min(candidate.id) FROM tracks AS candidate " ++
    "WHERE candidate.recording_id = playlist_entries.recording_id)";

const summary_sql =
    "SELECT playlists.id, playlists.name, playlists.created_at, playlists.updated_at,\n" ++
    "       (SELECT count(*) FROM playlist_entries WHERE playlist_entries.playlist_id = playlists.id),\n" ++
    "       (SELECT count(*) FROM playlist_entries WHERE playlist_entries.playlist_id = playlists.id\n" ++
    "          AND EXISTS (SELECT 1 FROM tracks WHERE tracks.recording_id = playlist_entries.recording_id)),\n" ++
    "       (SELECT COALESCE(sum(tracks.duration_ms), 0) FROM playlist_entries\n" ++
    "          JOIN tracks ON tracks.id = " ++ entry_track ++ "\n" ++
    "          WHERE playlist_entries.playlist_id = playlists.id)\n" ++
    "FROM playlists\n";

pub const PlaylistRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn create(self: *PlaylistRepository, name: []const u8) !i64 {
        const trimmed = try playlistName(name);
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        if (try self.nameTaken(trimmed, null)) return error.PlaylistNameTaken;
        var statement = try self.db.prepare(
            \\INSERT INTO playlists(name, created_at, updated_at) VALUES (?1, unixepoch(), unixepoch())
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindText(1, trimmed);
        if (try statement.step() != .row) return error.SqlFailed;
        const id = statement.columnInt64(0);
        if (try statement.step() != .done) return error.SqlFailed;
        try self.db.exec("COMMIT;");
        return id;
    }

    pub fn rename(self: *PlaylistRepository, playlist_id: i64, name: []const u8) !void {
        const trimmed = try playlistName(name);
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try self.requirePlaylist(playlist_id);
        if (try self.nameTaken(trimmed, playlist_id)) return error.PlaylistNameTaken;
        var update = try self.db.prepare("UPDATE playlists SET name=?2, updated_at=unixepoch() WHERE id=?1;");
        defer update.deinit();
        try update.bindInt64(1, playlist_id);
        try update.bindText(2, trimmed);
        if (try update.step() != .done) return error.SqlFailed;
        try self.db.exec("COMMIT;");
    }

    pub fn delete(self: *PlaylistRepository, playlist_id: i64) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare("DELETE FROM playlists WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() == 0) return error.UnknownPlaylist;
    }

    pub fn list(self: *const PlaylistRepository, allocator: std.mem.Allocator, limit: u32, offset: u32) !PlaylistPage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(summary_sql ++
            "ORDER BY playlists.name COLLATE NOCASE, playlists.id\n" ++
            "LIMIT ?1 OFFSET ?2;");
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        try statement.bindInt64(2, offset);
        var results: std.ArrayList(PlaylistSummary) = .empty;
        errdefer {
            for (results.items) |item| item.deinit(allocator);
            results.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const name = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(name);
            try results.append(allocator, .{
                .id = statement.columnInt64(0),
                .name = name,
                .created_at = statement.columnInt64(2),
                .updated_at = statement.columnInt64(3),
                .entries = std.math.cast(u32, statement.columnInt64(4)) orelse return error.InvalidStoredPlaylist,
                .available = std.math.cast(u32, statement.columnInt64(5)) orelse return error.InvalidStoredPlaylist,
                .duration_ms = statement.columnInt64(6),
            });
        }
        return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
    }

    pub fn entries(
        self: *const PlaylistRepository,
        allocator: std.mem.Allocator,
        playlist_id: i64,
        limit: u32,
        offset: u32,
    ) !PlaylistEntryPage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        try self.requirePlaylist(playlist_id);
        var statement = try self.db.prepare(tracks.track_columns ++
            ", playlist_entries.position, playlist_entries.recording_id\n" ++
            "FROM playlist_entries\n" ++
            "LEFT JOIN tracks ON tracks.id = " ++ entry_track ++ "\n" ++
            tracks.recording_joins ++
            "WHERE playlist_entries.playlist_id = ?1\n" ++
            "ORDER BY playlist_entries.position\n" ++
            "LIMIT ?2 OFFSET ?3;");
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        try statement.bindInt64(2, limit);
        try statement.bindInt64(3, offset);
        var results: std.ArrayList(PlaylistEntry) = .empty;
        errdefer {
            for (results.items) |item| item.deinit(allocator);
            results.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const track: ?TrackSummary = if (statement.columnIsNull(0))
                null
            else
                try tracks.readTrackSummary(allocator, statement);
            errdefer if (track) |value| value.deinit(allocator);
            try results.append(allocator, .{
                .position = std.math.cast(u32, statement.columnInt64(14)) orelse return error.InvalidStoredPlaylist,
                .recording_id = statement.columnInt64(15),
                .track = track,
            });
        }
        return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
    }

    pub fn trackIds(self: *const PlaylistRepository, allocator: std.mem.Allocator, playlist_id: i64) ![]i64 {
        try self.requirePlaylist(playlist_id);
        var statement = try self.db.prepare(
            "SELECT " ++ entry_track ++ " FROM playlist_entries\n" ++
                "WHERE playlist_entries.playlist_id = ?1\n" ++
                "ORDER BY playlist_entries.position\n" ++
                "LIMIT ?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        try statement.bindInt64(2, max_playlist_entries);
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row) {
            if (optionalInt64(statement, 0)) |track_id| try ids.append(allocator, track_id);
        }
        return ids.toOwnedSlice(allocator);
    }

    pub fn insert(self: *PlaylistRepository, playlist_id: i64, track_ids: []const i64, at: ?u32) !PlaylistInsertion {
        if (track_ids.len > max_page) return error.PageOutOfRange;
        var recordings: [max_page]i64 = undefined;
        var insertion: PlaylistInsertion = .{};
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try self.requirePlaylist(playlist_id);
        const count = try self.entryCount(playlist_id);
        const position = at orelse count;
        if (position > count) return error.PositionOutOfRange;
        {
            var find = try self.db.prepare("SELECT recording_id FROM tracks WHERE id=?1;");
            defer find.deinit();
            for (track_ids) |track_id| {
                try find.bindInt64(1, track_id);
                const recording_id = if (try find.step() == .row) optionalInt64(find, 0) else null;
                try find.reset();
                if (recording_id) |recording| {
                    recordings[insertion.added] = recording;
                    insertion.added += 1;
                } else insertion.skipped += 1;
            }
        }
        if (count + insertion.added > max_playlist_entries) return error.PlaylistFull;
        if (insertion.added != 0) {
            try self.shiftRange(playlist_id, position, count, insertion.added);
            var add = try self.db.prepare(
                "INSERT INTO playlist_entries(playlist_id, position, recording_id, added_at) VALUES (?1, ?2, ?3, unixepoch());",
            );
            defer add.deinit();
            for (recordings[0..insertion.added], position..) |recording, entry_position| {
                try add.bindInt64(1, playlist_id);
                try add.bindInt64(2, @intCast(entry_position));
                try add.bindInt64(3, recording);
                if (try add.step() != .done) return error.SqlFailed;
                try add.reset();
            }
            try self.touch(playlist_id);
        }
        try self.db.exec("COMMIT;");
        return insertion;
    }

    pub fn remove(self: *PlaylistRepository, playlist_id: i64, positions: []const u32) !u32 {
        if (positions.len > max_page) return error.PageOutOfRange;
        var buffer: [max_page]u32 = undefined;
        const sorted = buffer[0..positions.len];
        @memcpy(sorted, positions);
        std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
        var unique: usize = 0;
        for (sorted) |position| {
            if (unique != 0 and sorted[unique - 1] == position) continue;
            sorted[unique] = position;
            unique += 1;
        }
        const removed = sorted[0..unique];
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try self.requirePlaylist(playlist_id);
        const count = try self.entryCount(playlist_id);
        if (removed.len != 0 and removed[removed.len - 1] >= count) return error.PositionOutOfRange;
        {
            var drop = try self.db.prepare("DELETE FROM playlist_entries WHERE playlist_id=?1 AND position=?2;");
            defer drop.deinit();
            for (removed) |position| {
                try drop.bindInt64(1, playlist_id);
                try drop.bindInt64(2, position);
                if (try drop.step() != .done) return error.SqlFailed;
                try drop.reset();
            }
        }
        for (removed, 0..) |position, index| {
            const end = if (index + 1 < removed.len) removed[index + 1] else count;
            try self.shiftRange(playlist_id, position + 1, end, -@as(i64, @intCast(index + 1)));
        }
        if (removed.len != 0) try self.touch(playlist_id);
        try self.db.exec("COMMIT;");
        return @intCast(removed.len);
    }

    pub fn move(self: *PlaylistRepository, playlist_id: i64, from: u32, to: u32) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try self.requirePlaylist(playlist_id);
        const count = try self.entryCount(playlist_id);
        if (from >= count or to >= count) return error.PositionOutOfRange;
        if (from != to) {
            const parked = -@as(i64, count) - 1;
            try self.setPosition(playlist_id, from, parked);
            if (from < to)
                try self.shiftRange(playlist_id, from + 1, to + 1, -1)
            else
                try self.shiftRange(playlist_id, to, from, 1);
            try self.setPosition(playlist_id, parked, to);
            try self.touch(playlist_id);
        }
        try self.db.exec("COMMIT;");
    }

    /// The recording of the file at `uri`, preferring a present location,
    /// then an unverified one, then a missing one.
    pub fn resolvePath(self: *const PlaylistRepository, uri: []const u8) !?i64 {
        var statement = try self.db.prepare(
            \\SELECT files.recording_id FROM locations
            \\JOIN files ON files.id = locations.file_id
            \\WHERE locations.uri = ?1 AND files.recording_id IS NOT NULL
            \\ORDER BY CASE locations.state
            \\    WHEN 'present' THEN 0 WHEN 'unverified' THEN 1 ELSE 2 END, locations.id
            \\LIMIT 1;
        );
        defer statement.deinit();
        try statement.bindText(1, uri);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    /// The one recording with a Track whose folded title and artist equal
    /// these and whose length is within two seconds of `seconds`; null when
    /// none or several match.
    pub fn resolveInfo(
        self: *const PlaylistRepository,
        allocator: std.mem.Allocator,
        artist: []const u8,
        title: []const u8,
        seconds: u32,
    ) !?i64 {
        const artist_key = try text_key.normalizeKey(allocator, artist);
        defer allocator.free(artist_key);
        const title_key = try text_key.normalizeKey(allocator, title);
        defer allocator.free(title_key);
        var statement = try self.db.prepare(
            \\SELECT recording_id, title, artist FROM tracks
            \\WHERE recording_id IS NOT NULL AND duration_ms BETWEEN ?1 AND ?2;
        );
        defer statement.deinit();
        const center_ms = @as(i64, seconds) * std.time.ms_per_s;
        try statement.bindInt64(1, center_ms - info_tolerance_ms);
        try statement.bindInt64(2, center_ms + info_tolerance_ms);
        var found: ?i64 = null;
        while (try statement.step() == .row) {
            const recording_id = statement.columnInt64(0);
            if (found == recording_id) continue;
            if (!try foldsTo(allocator, statement.columnText(1), title_key)) continue;
            if (!try foldsTo(allocator, statement.columnText(2), artist_key)) continue;
            if (found != null) return null;
            found = recording_id;
        }
        return found;
    }

    /// Every Track's folded artist and title mapped to its recording, read in
    /// one pass, for matching credits that carry no length.
    pub fn recordingsByCredit(self: *const PlaylistRepository, allocator: std.mem.Allocator) !RecordingsByCredit {
        var index: RecordingsByCredit = .{ .allocator = allocator, .keys = .init(allocator) };
        errdefer index.deinit();
        var statement = try self.db.prepare("SELECT recording_id, title, artist FROM tracks WHERE recording_id IS NOT NULL;");
        defer statement.deinit();
        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(allocator);
        while (try statement.step() == .row) {
            const recording_id = statement.columnInt64(0);
            try creditKey(allocator, &key, statement.columnText(2), statement.columnText(1));
            const slot = try index.recordings.getOrPut(allocator, key.items);
            if (!slot.found_existing) {
                slot.key_ptr.* = try index.keys.allocator().dupe(u8, key.items);
                slot.value_ptr.* = .{ .unique = recording_id };
            } else switch (slot.value_ptr.*) {
                .unique => |existing| if (existing != recording_id) {
                    slot.value_ptr.* = .ambiguous;
                },
                .ambiguous => {},
            }
        }
        return index;
    }

    /// Creates a playlist holding `recording_ids` in order, named `name` or,
    /// when that is taken, `name (2)`, `name (3)` and so on.
    pub fn createWithRecordings(
        self: *PlaylistRepository,
        allocator: std.mem.Allocator,
        name: []const u8,
        recording_ids: []const i64,
    ) !i64 {
        if (recording_ids.len > max_playlist_entries) return error.PlaylistFull;
        const trimmed = try playlistName(name);
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var candidate = try allocator.dupe(u8, trimmed);
        defer allocator.free(candidate);
        var suffix: u32 = 1;
        while (try self.nameTaken(candidate, null)) {
            suffix += 1;
            const next = try std.fmt.allocPrint(allocator, "{s} ({d})", .{ trimmed, suffix });
            allocator.free(candidate);
            candidate = next;
        }
        var create_statement = try self.db.prepare(
            \\INSERT INTO playlists(name, created_at, updated_at) VALUES (?1, unixepoch(), unixepoch())
            \\RETURNING id;
        );
        defer create_statement.deinit();
        try create_statement.bindText(1, candidate);
        if (try create_statement.step() != .row) return error.SqlFailed;
        const playlist_id = create_statement.columnInt64(0);
        if (try create_statement.step() != .done) return error.SqlFailed;
        var add = try self.db.prepare(
            "INSERT INTO playlist_entries(playlist_id, position, recording_id, added_at) VALUES (?1, ?2, ?3, unixepoch());",
        );
        defer add.deinit();
        for (recording_ids, 0..) |recording_id, position| {
            try add.bindInt64(1, playlist_id);
            try add.bindInt64(2, @intCast(position));
            try add.bindInt64(3, recording_id);
            if (try add.step() != .done) return error.SqlFailed;
            try add.reset();
        }
        try self.db.exec("COMMIT;");
        return playlist_id;
    }

    /// Each entry's Track and the location `TrackRepository.playableLocation`
    /// picks, in order; entries with no Track or no location are counted as
    /// unavailable.
    pub fn exportRows(self: *const PlaylistRepository, allocator: std.mem.Allocator, playlist_id: i64) !PlaylistExportRows {
        try self.requirePlaylist(playlist_id);
        var statement = try self.db.prepare(
            "SELECT tracks.id, tracks.title, tracks.artist, tracks.duration_ms FROM playlist_entries\n" ++
                "LEFT JOIN tracks ON tracks.id = " ++ entry_track ++ "\n" ++
                "WHERE playlist_entries.playlist_id = ?1\n" ++
                "ORDER BY playlist_entries.position\n" ++
                "LIMIT ?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        try statement.bindInt64(2, max_playlist_entries);
        const track_repository: tracks.TrackRepository = .{ .db = self.db, .write_lane = self.write_lane };
        var rows: std.ArrayList(PlaylistExportRow) = .empty;
        errdefer {
            for (rows.items) |row| row.deinit(allocator);
            rows.deinit(allocator);
        }
        var unavailable: u32 = 0;
        while (try statement.step() == .row) {
            const track_id = optionalInt64(statement, 0) orelse {
                unavailable += 1;
                continue;
            };
            const location = try track_repository.playableLocation(allocator, track_id) orelse {
                unavailable += 1;
                continue;
            };
            defer location.deinit();
            const uri = try allocator.dupe(u8, location.uri);
            errdefer allocator.free(uri);
            const title = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(title);
            const artist = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(artist);
            try rows.append(allocator, .{
                .title = title,
                .artist = artist,
                .duration_ms = optionalInt64(statement, 3),
                .uri = uri,
            });
        }
        return .{ .allocator = allocator, .items = try rows.toOwnedSlice(allocator), .unavailable = unavailable };
    }

    fn requirePlaylist(self: *const PlaylistRepository, playlist_id: i64) !void {
        var statement = try self.db.prepare("SELECT 1 FROM playlists WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        if (try statement.step() != .row) return error.UnknownPlaylist;
    }

    fn nameTaken(self: *const PlaylistRepository, name: []const u8, except: ?i64) !bool {
        var statement = try self.db.prepare("SELECT 1 FROM playlists WHERE name=?1 AND id IS NOT ?2;");
        defer statement.deinit();
        try statement.bindText(1, name);
        try statement.bindOptionalInt64(2, except);
        return try statement.step() == .row;
    }

    fn entryCount(self: *const PlaylistRepository, playlist_id: i64) !u32 {
        var statement = try self.db.prepare("SELECT count(*) FROM playlist_entries WHERE playlist_id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        if (try statement.step() != .row) return error.SqlFailed;
        return std.math.cast(u32, statement.columnInt64(0)) orelse error.InvalidStoredPlaylist;
    }

    fn touch(self: *PlaylistRepository, playlist_id: i64) !void {
        var statement = try self.db.prepare("UPDATE playlists SET updated_at=unixepoch() WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    fn setPosition(self: *PlaylistRepository, playlist_id: i64, from: i64, to: i64) !void {
        var statement = try self.db.prepare("UPDATE playlist_entries SET position=?3 WHERE playlist_id=?1 AND position=?2;");
        defer statement.deinit();
        try statement.bindInt64(1, playlist_id);
        try statement.bindInt64(2, from);
        try statement.bindInt64(3, to);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    fn shiftRange(self: *PlaylistRepository, playlist_id: i64, start: u32, end: u32, delta: i64) !void {
        if (start >= end) return;
        // The primary key is checked row by row, so a shift in place collides
        // with a neighbour that has not moved yet; park the range on negative
        // positions first.
        var park = try self.db.prepare(
            \\UPDATE playlist_entries SET position = -(position + 1)
            \\WHERE playlist_id=?1 AND position >= ?2 AND position < ?3;
        );
        defer park.deinit();
        try park.bindInt64(1, playlist_id);
        try park.bindInt64(2, start);
        try park.bindInt64(3, end);
        if (try park.step() != .done) return error.SqlFailed;
        var land = try self.db.prepare(
            \\UPDATE playlist_entries SET position = -position - 1 + ?4
            \\WHERE playlist_id=?1 AND position <= -(?2 + 1) AND position >= -?3;
        );
        defer land.deinit();
        try land.bindInt64(1, playlist_id);
        try land.bindInt64(2, start);
        try land.bindInt64(3, end);
        try land.bindInt64(4, delta);
        if (try land.step() != .done) return error.SqlFailed;
    }
};

const CreditCandidate = union(enum) {
    unique: i64,
    ambiguous,
};

pub const RecordingsByCredit = struct {
    allocator: std.mem.Allocator,
    keys: std.heap.ArenaAllocator,
    recordings: std.StringHashMapUnmanaged(CreditCandidate) = .empty,

    pub fn deinit(self: *RecordingsByCredit) void {
        self.recordings.deinit(self.allocator);
        self.keys.deinit();
    }

    /// The one recording credited to this artist and title; null when none
    /// or several are.
    pub fn lookup(self: *const RecordingsByCredit, allocator: std.mem.Allocator, artist: []const u8, title: []const u8) !?i64 {
        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(allocator);
        try creditKey(allocator, &key, artist, title);
        return switch (self.recordings.get(key.items) orelse return null) {
            .unique => |recording_id| recording_id,
            .ambiguous => null,
        };
    }
};

fn creditKey(allocator: std.mem.Allocator, key: *std.ArrayList(u8), artist: []const u8, title: []const u8) !void {
    const artist_key = try text_key.normalizeKey(allocator, artist);
    defer allocator.free(artist_key);
    const title_key = try text_key.normalizeKey(allocator, title);
    defer allocator.free(title_key);
    key.clearRetainingCapacity();
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, artist_key.len, .little);
    try key.appendSlice(allocator, &length);
    try key.appendSlice(allocator, artist_key);
    try key.appendSlice(allocator, title_key);
}

fn foldsTo(allocator: std.mem.Allocator, text: []const u8, key: []const u8) !bool {
    const folded = try text_key.normalizeKey(allocator, text);
    defer allocator.free(folded);
    return std.mem.eql(u8, folded, key);
}

fn playlistName(name: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
    if (trimmed.len == 0) return error.InvalidPlaylistName;
    return trimmed;
}
