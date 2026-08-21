const std = @import("std");
const migrations = @import("migrations.zig");
const repository = @import("repository.zig");
const sqlite = @import("sqlite.zig");

/// One independently openable Library and its serialized write connection.
pub const LibraryDatabase = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    database: sqlite.Database,
    write_lane: *repository.WriteLane,
    tracks: repository.TrackRepository,
    observed_files: repository.ObservedFileRepository,
    orca_metadata: repository.OrcaMetadataRepository,
    mutation_journal: repository.MutationJournalRepository,

    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) !LibraryDatabase {
        const owned_path = try allocator.dupeSentinel(u8, path, 0);
        errdefer allocator.free(owned_path);
        const database = try sqlite.Database.open(path);
        errdefer database.close();
        const write_lane = try allocator.create(repository.WriteLane);
        errdefer allocator.destroy(write_lane);
        write_lane.* = .{};
        try database.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;");
        try migrations.apply(database);
        return .{
            .allocator = allocator,
            .path = owned_path,
            .database = database,
            .write_lane = write_lane,
            .tracks = .{ .db = database, .write_lane = write_lane },
            .observed_files = .{ .db = database, .write_lane = write_lane },
            .orca_metadata = .{ .db = database, .write_lane = write_lane },
            .mutation_journal = .{ .db = database, .write_lane = write_lane },
        };
    }

    pub fn close(self: *LibraryDatabase) void {
        self.database.close();
        self.allocator.destroy(self.write_lane);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    /// Opens an independent read connection suitable for a bounded query or
    /// snapshot. The caller owns the returned connection.
    pub fn openReader(self: *const LibraryDatabase) !sqlite.Database {
        return sqlite.Database.openReadOnly(self.path);
    }
};

test "independent libraries retain separate state and FTS indexes" {
    var first = try LibraryDatabase.open(
        std.testing.allocator,
        "file:orca-test-first?mode=memory&cache=shared",
    );
    defer first.close();
    var second = try LibraryDatabase.open(
        std.testing.allocator,
        "file:orca-test-second?mode=memory&cache=shared",
    );
    defer second.close();

    try first.tracks.insertBatch(&.{.{
        .title = "Northern Sky",
        .album = "Bryter Layter",
        .album_artist = "Nick Drake",
    }});
    try second.tracks.insertBatch(&.{.{
        .title = "Orca",
        .album = "Promises",
        .album_artist = "Floating Points",
    }});

    var page = try first.tracks.search(std.testing.allocator, "Northern", 25, 0);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqualStrings("Northern Sky", page.items[0].title);
    try std.testing.expectEqual(@as(u64, 1), try first.tracks.count());
    try std.testing.expectEqual(@as(u64, 1), try second.tracks.count());
}

test "ten thousand ratings update in one transaction" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        "file:orca-test-batch?mode=memory&cache=shared",
    );
    defer library.close();

    var tracks: [10_000]repository.TrackInput = undefined;
    for (&tracks) |*track| track.* = .{ .title = "Batch track" };
    try library.tracks.insertBatch(&tracks);

    var ids: [10_000]i64 = undefined;
    for (&ids, 1..) |*id, value| id.* = @intCast(value);
    try library.tracks.setRatings(&ids, 80);
    try std.testing.expectEqual(
        @as(u64, 10_000),
        try library.tracks.countWithRating(80),
    );
}

test "WAL readers remain available while write submissions serialize" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/library.db",
        .{temporary.sub_path},
        0,
    );
    defer std.testing.allocator.free(path);

    var library = try LibraryDatabase.open(std.testing.allocator, path);
    defer library.close();
    const reader = try library.openReader();
    defer reader.close();

    {
        var journal_mode = try reader.prepare("PRAGMA journal_mode;");
        defer journal_mode.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try journal_mode.step());
        try std.testing.expectEqualStrings("wal", journal_mode.columnText(0));
    }

    const Writer = struct {
        fn run(tracks: *repository.TrackRepository, failed: *std.atomic.Value(bool)) void {
            var batch: [250]repository.TrackInput = undefined;
            for (&batch) |*track| track.* = .{ .title = "Concurrent track" };
            tracks.insertBatch(&batch) catch failed.store(true, .release);
        }
    };
    var failed: std.atomic.Value(bool) = .init(false);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Writer.run, .{ &library.tracks, &failed });
    }

    const read_repository = repository.TrackRepository{
        .db = reader,
        .write_lane = library.write_lane,
    };
    _ = try read_repository.count();
    for (threads) |thread| thread.join();

    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1000), try read_repository.count());
}

test "Orca metadata persists provenance and user locks separately from observations" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        "file:orca-test-metadata?mode=memory&cache=shared",
    );
    defer library.close();
    try library.observed_files.upsertBatch(&.{.{
        .path = "/music/example.flac",
        .inode = 1,
        .size_bytes = 100,
        .modified_ns = 200,
        .audio_format = 2,
        .title = "Observed title",
    }});
    try library.orca_metadata.upsert(.{
        .path = "/music/example.flac",
        .field = .title,
        .value = "Curated title",
        .provenance = .user,
        .locked = true,
    });
    try library.orca_metadata.upsert(.{
        .path = "/music/example.flac",
        .field = .title,
        .value = "Provider refresh",
        .provenance = .provider,
    });
    const value = (try library.orca_metadata.get(
        std.testing.allocator,
        "/music/example.flac",
        .title,
    )).?;
    defer value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Curated title", value.text);
    try std.testing.expectEqual(@import("../metadata/model.zig").Provenance.user, value.provenance);
    try std.testing.expect(value.locked);
    const observed = (try library.observed_files.title(
        std.testing.allocator,
        "/music/example.flac",
    )).?;
    defer std.testing.allocator.free(observed);
    try std.testing.expectEqualStrings("Observed title", observed);
}

test "mutation journal preserves recoverable staged state across reopen" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/mutation-journal.db",
        .{temporary.sub_path},
        0,
    );
    defer std.testing.allocator.free(path);
    var library = try LibraryDatabase.open(std.testing.allocator, path);
    const operation = try library.mutation_journal.prepare(.{
        .plan_id = 9,
        .group_id = 3,
        .action_index = 0,
        .kind = .write_tags,
        .source_path = "/music/generated.mp3",
        .expected_size = 1024,
        .expected_modified_ns = 55,
    });
    try library.mutation_journal.transition(operation, .planned, .staged, null);
    library.close();

    library = try LibraryDatabase.open(std.testing.allocator, path);
    defer library.close();
    try std.testing.expectEqual(
        repository.MutationState.staged,
        try library.mutation_journal.state(operation),
    );
    try library.mutation_journal.transition(operation, .staged, .rolled_back, "recovered");
    try std.testing.expectError(
        error.StaleMutationOperation,
        library.mutation_journal.transition(operation, .staged, .committed, null),
    );
}
