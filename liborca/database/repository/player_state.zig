const std = @import("std");
const sqlite = @import("../sqlite.zig");
const WriteLane = @import("write_lane.zig").WriteLane;
const scalar = @import("../columns.zig").scalar;

/// How many queue entries a saved state keeps: the playback queue's capacity.
pub const max_saved_entries: usize = 10_000;

/// One saved queue entry, in playback order.
pub const SavedQueueEntry = struct {
    /// Its place in the queue's list order, which differs from its place in
    /// playback order while the queue is shuffled.
    entry: u32,
    track_id: i64,
};

pub const SavedPlayerState = struct {
    /// Playback position of the entry that was playing.
    cursor: u32,
    position_ms: u64,
    /// `RepeatMode` tag value: 0 off, 1 all, 2 one.
    repeat: u8,
    shuffle: bool,
};

/// A saved entry as a restore resolves it: the Track to play, or null when
/// neither the saved Track nor another Track of its Recording is left.
pub const RestoredQueueEntry = struct {
    entry: u32,
    track_id: ?i64,
};

/// Caller-owned; `deinit` frees `entries`.
pub const RestoredPlayerState = struct {
    allocator: std.mem.Allocator,
    state: SavedPlayerState,
    saved_at: i64,
    /// In playback order.
    entries: []RestoredQueueEntry,

    pub fn deinit(self: RestoredPlayerState) void {
        self.allocator.free(self.entries);
    }
};

/// The queue a Player resumes from, and where long Tracks were left.
pub const PlayerStateRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Replaces the saved state in one transaction. Each entry keeps its
    /// Track's Recording beside it, so a Track a later projection replaces is
    /// found again through its Recording. An entry whose Track is already
    /// gone when it is saved is stored as a null row that resolves to nothing
    /// and is skipped on restore; a Track deleted after the save is cleared
    /// from its row by the foreign key and the entry then resolves to
    /// nothing too.
    pub fn save(
        self: *PlayerStateRepository,
        state: SavedPlayerState,
        entries: []const SavedQueueEntry,
        saved_at: i64,
    ) !void {
        if (entries.len > max_saved_entries) return error.PlaybackQueueFull;
        if (entries.len != 0 and state.cursor >= entries.len) return error.PositionOutOfRange;
        if (state.repeat > 2) return error.InvalidRepeatMode;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var insert = try self.db.prepare(
            \\INSERT INTO player_queue_entries(position, entry, track_id, recording_id)
            \\SELECT ?1, ?2, id, recording_id FROM tracks WHERE id = ?3;
        );
        defer insert.deinit();
        var insert_missing = try self.db.prepare(
            \\INSERT INTO player_queue_entries(position, entry, track_id, recording_id)
            \\VALUES (?1, ?2, NULL, NULL);
        );
        defer insert_missing.deinit();
        var head = try self.db.prepare(
            \\INSERT INTO player_state(id, cursor, position_ms, repeat, shuffle, saved_at)
            \\VALUES (1, ?1, ?2, ?3, ?4, ?5)
            \\ON CONFLICT(id) DO UPDATE SET cursor = excluded.cursor, position_ms = excluded.position_ms,
            \\    repeat = excluded.repeat, shuffle = excluded.shuffle, saved_at = excluded.saved_at;
        );
        defer head.deinit();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try self.db.exec("DELETE FROM player_queue_entries;");
        for (entries, 0..) |entry, position| {
            try insert.bindInt64(1, @intCast(position));
            try insert.bindInt64(2, entry.entry);
            try insert.bindInt64(3, entry.track_id);
            if (try insert.step() != .done) return error.SqlFailed;
            if (self.db.changes() == 0) {
                try insert_missing.bindInt64(1, @intCast(position));
                try insert_missing.bindInt64(2, entry.entry);
                if (try insert_missing.step() != .done) return error.SqlFailed;
                try insert_missing.reset();
            }
            try insert.reset();
        }
        try head.bindInt64(1, state.cursor);
        try head.bindInt64(2, @intCast(@min(state.position_ms, std.math.maxInt(i64))));
        try head.bindInt64(3, state.repeat);
        try head.bindInt64(4, @intFromBool(state.shuffle));
        try head.bindInt64(5, saved_at);
        if (try head.step() != .done) return error.SqlFailed;
        try self.db.exec("COMMIT;");
    }

    /// The saved state with each entry resolved, or null when nothing was
    /// saved. An entry resolves to its saved Track while that Track still
    /// belongs to the saved Recording, otherwise to the lowest-numbered
    /// Track of that Recording, otherwise to null. A null entry is one whose
    /// Track was gone when saved or deleted afterwards.
    pub fn load(self: *const PlayerStateRepository, allocator: std.mem.Allocator) !?RestoredPlayerState {
        var head = try self.db.prepare(
            "SELECT cursor, position_ms, repeat, shuffle, saved_at FROM player_state WHERE id = 1;",
        );
        defer head.deinit();
        if (try head.step() != .row) return null;
        const state: SavedPlayerState = .{
            .cursor = std.math.cast(u32, head.columnInt64(0)) orelse 0,
            .position_ms = std.math.cast(u64, head.columnInt64(1)) orelse 0,
            .repeat = std.math.cast(u8, head.columnInt64(2)) orelse 0,
            .shuffle = head.columnInt64(3) != 0,
        };
        const saved_at = head.columnInt64(4);

        var rows = try self.db.prepare(
            \\SELECT q.entry, COALESCE(
            \\    (SELECT t.id FROM tracks t WHERE t.id = q.track_id
            \\        AND (q.recording_id IS NULL OR t.recording_id = q.recording_id)),
            \\    (SELECT min(t.id) FROM tracks t WHERE t.recording_id = q.recording_id))
            \\FROM player_queue_entries q ORDER BY q.position LIMIT 10000;
        );
        defer rows.deinit();
        var entries: std.ArrayList(RestoredQueueEntry) = .empty;
        errdefer entries.deinit(allocator);
        while (try rows.step() == .row) {
            try entries.append(allocator, .{
                .entry = std.math.cast(u32, rows.columnInt64(0)) orelse 0,
                .track_id = if (rows.columnIsNull(1)) null else rows.columnInt64(1),
            });
        }
        return .{
            .allocator = allocator,
            .state = state,
            .saved_at = saved_at,
            .entries = try entries.toOwnedSlice(allocator),
        };
    }

    /// Where a long Track was left, or null.
    pub fn trackPosition(self: *const PlayerStateRepository, track_id: i64) !?u64 {
        var statement = try self.db.prepare("SELECT position_ms FROM track_positions WHERE track_id = ?1;");
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return null;
        return std.math.cast(u64, statement.columnInt64(0));
    }

    /// Keeps where a long Track was left; zero forgets it. A Track that is
    /// gone is ignored.
    pub fn rememberTrackPosition(self: *PlayerStateRepository, track_id: i64, position_ms: u64) !void {
        if (position_ms == 0) return self.forgetTrackPosition(track_id);
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO track_positions(track_id, position_ms, updated_at)
            \\SELECT ?1, ?2, unixepoch() WHERE EXISTS (SELECT 1 FROM tracks WHERE id = ?1)
            \\ON CONFLICT(track_id) DO UPDATE SET position_ms = excluded.position_ms, updated_at = excluded.updated_at;
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        try statement.bindInt64(2, @intCast(@min(position_ms, std.math.maxInt(i64))));
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Takes the write lane only when there is a position to forget, because
    /// every Track that ends asks.
    pub fn forgetTrackPosition(self: *PlayerStateRepository, track_id: i64) !void {
        if (try self.trackPosition(track_id) == null) return;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare("DELETE FROM track_positions WHERE track_id = ?1;");
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }
};

const LibraryDatabase = @import("../library.zig").LibraryDatabase;

fn seedTracks(library: *LibraryDatabase) !void {
    try library.database.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'One'), (2, 'Two'), (3, 'Three');
        \\INSERT INTO releases(id, title, release_key) VALUES (1, 'Mix', 'mix');
        \\INSERT INTO tracks(id, release_id, title, recording_id) VALUES
        \\    (10, 1, 'One', 1), (11, 1, 'Two', 2), (12, 1, 'Three', 3), (13, 1, 'Loose', NULL);
    );
}

test "a saved queue loads back in playback order with its cursor, position and modes" {
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, "file:orca-test-player-state-round-trip?mode=memory&cache=shared");
    defer library.close();
    try seedTracks(&library);
    try std.testing.expectEqual(null, try library.player_state.load(std.testing.allocator));

    try library.player_state.save(
        .{ .cursor = 1, .position_ms = 5000, .repeat = 1, .shuffle = true },
        &.{ .{ .entry = 2, .track_id = 12 }, .{ .entry = 0, .track_id = 10 }, .{ .entry = 1, .track_id = 13 } },
        1_800_000_000,
    );
    try library.player_state.save(
        .{ .cursor = 2, .position_ms = 7000, .repeat = 2, .shuffle = true },
        &.{ .{ .entry = 2, .track_id = 12 }, .{ .entry = 0, .track_id = 10 }, .{ .entry = 1, .track_id = 13 } },
        1_800_000_030,
    );

    const loaded = (try library.player_state.load(std.testing.allocator)).?;
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 2), loaded.state.cursor);
    try std.testing.expectEqual(@as(u64, 7000), loaded.state.position_ms);
    try std.testing.expectEqual(@as(u8, 2), loaded.state.repeat);
    try std.testing.expect(loaded.state.shuffle);
    try std.testing.expectEqual(@as(i64, 1_800_000_030), loaded.saved_at);
    try std.testing.expectEqualSlices(RestoredQueueEntry, &.{
        .{ .entry = 2, .track_id = 12 },
        .{ .entry = 0, .track_id = 10 },
        .{ .entry = 1, .track_id = 13 },
    }, loaded.entries);
}

test "a saved entry whose track is gone resolves through its recording, or to null without one" {
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, "file:orca-test-player-state-resolve?mode=memory&cache=shared");
    defer library.close();
    try seedTracks(&library);
    try library.player_state.save(
        .{ .cursor = 0, .position_ms = 0, .repeat = 0, .shuffle = false },
        &.{ .{ .entry = 0, .track_id = 10 }, .{ .entry = 1, .track_id = 11 }, .{ .entry = 2, .track_id = 13 } },
        0,
    );
    try library.database.exec(
        \\DELETE FROM tracks WHERE id IN (10, 11, 13);
        \\INSERT INTO tracks(id, release_id, title, recording_id) VALUES (20, 1, 'One again', 1), (11, 1, 'Reused', 3);
    );

    const loaded = (try library.player_state.load(std.testing.allocator)).?;
    defer loaded.deinit();
    try std.testing.expectEqualSlices(RestoredQueueEntry, &.{
        .{ .entry = 0, .track_id = 20 },
        .{ .entry = 1, .track_id = null },
        .{ .entry = 2, .track_id = null },
    }, loaded.entries);
}

test "a loose entry whose reused Track id is taken by a new song resolves to null" {
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, "file:orca-test-player-state-reused-track?mode=memory&cache=shared");
    defer library.close();
    try seedTracks(&library);
    try library.player_state.save(
        .{ .cursor = 0, .position_ms = 0, .repeat = 0, .shuffle = false },
        &.{.{ .entry = 0, .track_id = 13 }},
        0,
    );
    try library.database.exec(
        \\DELETE FROM tracks WHERE id = 13;
        \\INSERT INTO tracks(release_id, title, recording_id) VALUES (1, 'New song', NULL);
    );

    const loaded = (try library.player_state.load(std.testing.allocator)).?;
    defer loaded.deinit();
    try std.testing.expectEqualSlices(RestoredQueueEntry, &.{
        .{ .entry = 0, .track_id = null },
    }, loaded.entries);
}

test "an entry whose reused Recording id is taken by a new song resolves to null" {
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, "file:orca-test-player-state-reused-recording?mode=memory&cache=shared");
    defer library.close();
    try seedTracks(&library);
    try library.player_state.save(
        .{ .cursor = 0, .position_ms = 0, .repeat = 0, .shuffle = false },
        &.{.{ .entry = 0, .track_id = 12 }},
        0,
    );
    try library.database.exec(
        \\DELETE FROM tracks WHERE id = 12;
        \\DELETE FROM recordings WHERE id = 3;
        \\INSERT INTO recordings(title) VALUES ('New recording');
        \\INSERT INTO tracks(release_id, title, recording_id) VALUES (1, 'New song', 3);
    );

    const loaded = (try library.player_state.load(std.testing.allocator)).?;
    defer loaded.deinit();
    try std.testing.expectEqualSlices(RestoredQueueEntry, &.{
        .{ .entry = 0, .track_id = null },
    }, loaded.entries);
}

test "a save with a Track that is already gone stores the null entry and load returns it" {
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, "file:orca-test-player-state-missing-at-save?mode=memory&cache=shared");
    defer library.close();
    try seedTracks(&library);
    try library.player_state.save(
        .{ .cursor = 1, .position_ms = 0, .repeat = 0, .shuffle = false },
        &.{ .{ .entry = 0, .track_id = 10 }, .{ .entry = 1, .track_id = 99 } },
        0,
    );
    try std.testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT count(*) FROM player_queue_entries;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM player_queue_entries WHERE position = 1 AND track_id IS NULL AND recording_id IS NULL;"));

    const loaded = (try library.player_state.load(std.testing.allocator)).?;
    defer loaded.deinit();
    try std.testing.expectEqualSlices(RestoredQueueEntry, &.{
        .{ .entry = 0, .track_id = 10 },
        .{ .entry = 1, .track_id = null },
    }, loaded.entries);
}

test "a saved queue past the playback queue's capacity or with its cursor outside it is refused" {
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, "file:orca-test-player-state-bounds?mode=memory&cache=shared");
    defer library.close();
    const too_many = try std.testing.allocator.alloc(SavedQueueEntry, max_saved_entries + 1);
    defer std.testing.allocator.free(too_many);
    for (too_many, 0..) |*entry, index| entry.* = .{ .entry = @intCast(index), .track_id = 1 };
    try std.testing.expectError(error.PlaybackQueueFull, library.player_state.save(
        .{ .cursor = 0, .position_ms = 0, .repeat = 0, .shuffle = false },
        too_many,
        0,
    ));
    try std.testing.expectError(error.PositionOutOfRange, library.player_state.save(
        .{ .cursor = 1, .position_ms = 0, .repeat = 0, .shuffle = false },
        too_many[0..1],
        0,
    ));
    try std.testing.expectEqual(null, try library.player_state.load(std.testing.allocator));
}

test "a long track's position is kept until forgotten and never for a track that is gone" {
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, "file:orca-test-player-state-positions?mode=memory&cache=shared");
    defer library.close();
    try seedTracks(&library);
    try library.player_state.rememberTrackPosition(10, 1_500_000);
    try library.player_state.rememberTrackPosition(10, 1_600_000);
    try library.player_state.rememberTrackPosition(99, 1_600_000);
    try std.testing.expectEqual(@as(?u64, 1_600_000), try library.player_state.trackPosition(10));
    try std.testing.expectEqual(null, try library.player_state.trackPosition(99));

    try library.player_state.rememberTrackPosition(10, 0);
    try std.testing.expectEqual(null, try library.player_state.trackPosition(10));
    try library.player_state.rememberTrackPosition(11, 1_000);
    try library.player_state.forgetTrackPosition(11);
    try library.player_state.forgetTrackPosition(11);
    try std.testing.expectEqual(null, try library.player_state.trackPosition(11));
}
