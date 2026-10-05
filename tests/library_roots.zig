const std = @import("std");
const liborca = @import("liborca");
const integration_options = @import("integration_options");

const database = liborca.internal.database;

const Scratch = struct {
    temporary: std.testing.TmpDir,
    path: []u8,
    database_path: [:0]u8,

    fn init(io: std.Io) !Scratch {
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        const working_directory = try std.process.currentPathAlloc(io, std.testing.allocator);
        defer std.testing.allocator.free(working_directory);
        const path = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}/.zig-cache/tmp/{s}",
            .{ working_directory, temporary.sub_path },
        );
        errdefer std.testing.allocator.free(path);
        const database_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/library.db", .{path}, 0);
        return .{ .temporary = temporary, .path = path, .database_path = database_path };
    }

    fn deinit(self: *Scratch) void {
        std.testing.allocator.free(self.database_path);
        std.testing.allocator.free(self.path);
        self.temporary.cleanup();
    }

    fn copyFixture(self: *Scratch, io: std.Io, fixture: []const u8, destination: []const u8) !void {
        if (std.fs.path.dirname(destination)) |directory| try self.temporary.dir.createDirPath(io, directory);
        try std.Io.Dir.cwd().copyFile(fixture, self.temporary.dir, destination, io, .{});
    }

    fn child(self: *const Scratch, comptime format: []const u8, args: anytype) ![]u8 {
        return std.fmt.allocPrint(std.testing.allocator, "{s}/" ++ format, .{self.path} ++ args);
    }
};

fn cli(io: std.Io, cwd: ?[]const u8, argv: []const []const u8) ![]u8 {
    const working_directory = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(working_directory);
    const executable = try std.fs.path.resolve(std.testing.allocator, &.{ working_directory, integration_options.orca_cli });
    defer std.testing.allocator.free(executable);
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(std.testing.allocator);
    try full.append(std.testing.allocator, executable);
    try full.appendSlice(std.testing.allocator, argv);
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = full.items,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
    });
    defer std.testing.allocator.free(result.stderr);
    errdefer std.testing.allocator.free(result.stdout);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) {
        std.debug.print("orca-cli {s} failed: {s}\n", .{ argv[0], result.stderr });
        return error.CliFailed;
    }
    return result.stdout;
}

fn cliDiscard(io: std.Io, argv: []const []const u8) !void {
    std.testing.allocator.free(try cli(io, null, argv));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected {s} in:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedEqual;
    }
}

fn scalar(library: *database.LibraryDatabase, sql: [:0]const u8) !i64 {
    return database.columns.scalar(library.database, sql);
}

test "orca-cli add-root and relocate-root store a relative path as an absolute one" {
    const io = std.testing.io;
    var scratch = try Scratch.init(io);
    defer scratch.deinit();
    try scratch.temporary.dir.createDirPath(io, "music");
    try scratch.temporary.dir.createDirPath(io, "moved");

    std.testing.allocator.free(try cli(io, scratch.path, &.{ "add-root", scratch.database_path, "./music/../music/" }));
    const music = try scratch.child("music\t", .{});
    defer std.testing.allocator.free(music);
    const roots = try cli(io, null, &.{ "roots", scratch.database_path });
    defer std.testing.allocator.free(roots);
    try expectContains(roots, music);

    const relocated = try cli(io, scratch.path, &.{ "relocate-root", scratch.database_path, "1", "moved" });
    defer std.testing.allocator.free(relocated);
    const moved = try scratch.child("moved\t", .{});
    defer std.testing.allocator.free(moved);
    const relocated_roots = try cli(io, null, &.{ "roots", scratch.database_path });
    defer std.testing.allocator.free(relocated_roots);
    try expectContains(relocated_roots, moved);
}

test "orca-cli remove-root forgets a recording only its files held, with its user data, and keeps its listens" {
    const io = std.testing.io;
    var scratch = try Scratch.init(io);
    defer scratch.deinit();
    try scratch.copyFixture(io, "fixtures/audio/tagged-reference.flac", "first/only.flac");
    try scratch.copyFixture(io, "fixtures/audio/generated-reference.flac", "first/shared.flac");
    try scratch.copyFixture(io, "fixtures/audio/generated-reference.flac", "second/shared.flac");
    const first = try scratch.child("first", .{});
    defer std.testing.allocator.free(first);
    const second = try scratch.child("second", .{});
    defer std.testing.allocator.free(second);
    for ([_][]const u8{ first, second }) |root| {
        try cliDiscard(io, &.{ "add-root", scratch.database_path, root });
        try cliDiscard(io, &.{ "scan", scratch.database_path, root });
    }

    var only_track: i64 = 0;
    var shared_track: i64 = 0;
    {
        var library = try database.LibraryDatabase.open(std.testing.allocator, io, scratch.database_path);
        defer library.close();
        try std.testing.expectEqual(@as(i64, 2), try scalar(&library, "SELECT count(*) FROM files;"));
        try std.testing.expectEqual(@as(i64, 2), try scalar(&library, "SELECT count(*) FROM recordings;"));
        only_track = try scalar(&library, "SELECT id FROM tracks WHERE title = 'Reference Tone';");
        shared_track = try scalar(&library, "SELECT id FROM tracks WHERE title <> 'Reference Tone';");
        for ([_]i64{ only_track, shared_track }) |track| {
            const files = try library.tracks.fileIds(std.testing.allocator, track);
            defer std.testing.allocator.free(files);
            for ([_]i64{ 1_700_000_000, 1_700_000_100, 1_700_000_200 }) |started_at| {
                _ = try library.listens.record(.{
                    .file_id = files[0],
                    .started_at = started_at,
                    .listened_ms = 1_000,
                    .title = "Listened title",
                    .artist = "Listened artist",
                });
            }
        }
    }
    const ids = try std.fmt.allocPrint(std.testing.allocator, "{d},{d}", .{ only_track, shared_track });
    defer std.testing.allocator.free(ids);
    try cliDiscard(io, &.{ "feedback", scratch.database_path, ids, "--love" });
    try cliDiscard(io, &.{ "rate", scratch.database_path, ids, "--stars=4" });
    try cliDiscard(io, &.{ "playlist-create", scratch.database_path, "Kept" });
    try cliDiscard(io, &.{ "playlist-add", scratch.database_path, "1", ids });

    {
        var library = try database.LibraryDatabase.open(std.testing.allocator, io, scratch.database_path);
        defer library.close();
        try std.testing.expectEqual(@as(i64, 2), try scalar(&library, "SELECT count(*) FROM feedback WHERE score = 1;"));
        try std.testing.expectEqual(@as(i64, 2), try scalar(&library, "SELECT count(*) FROM ratings;"));
        try std.testing.expectEqual(@as(i64, 2), try scalar(&library, "SELECT count(*) FROM playlist_entries;"));
        try std.testing.expectEqual(@as(i64, 6), try scalar(&library, "SELECT sum(play_count) FROM recording_play_stats;"));
        try library.database.exec("INSERT INTO recordings(id, title) VALUES (1000, 'Already orphaned');");
    }

    const removed = try cli(io, null, &.{ "remove-root", scratch.database_path, "1" });
    defer std.testing.allocator.free(removed);

    var library = try database.LibraryDatabase.open(std.testing.allocator, io, scratch.database_path);
    defer library.close();
    try std.testing.expectEqual(@as(i64, 2), try scalar(&library, "SELECT count(*) FROM recordings;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&library, "SELECT count(*) FROM recordings WHERE id = 1000;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&library, "SELECT count(*) FROM tracks;"));
    const kept_recording = try scalar(&library, "SELECT recording_id FROM tracks;");
    try std.testing.expectEqual(kept_recording, try scalar(&library, "SELECT recording_id FROM feedback WHERE score = 1;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&library, "SELECT count(*) FROM feedback;"));
    try std.testing.expectEqual(kept_recording, try scalar(&library, "SELECT recording_id FROM ratings;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&library, "SELECT count(*) FROM ratings;"));
    try std.testing.expectEqual(kept_recording, try scalar(&library, "SELECT recording_id FROM playlist_entries;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&library, "SELECT count(*) FROM playlist_entries;"));
    try std.testing.expectEqual(kept_recording, try scalar(&library, "SELECT recording_id FROM recording_play_stats;"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(&library, "SELECT play_count FROM recording_play_stats;"));
    try std.testing.expectEqual(@as(i64, 6), try scalar(&library, "SELECT count(*) FROM listens WHERE title = 'Listened title';"));
    try std.testing.expectEqual(@as(i64, 3), try scalar(&library, "SELECT count(*) FROM listens WHERE recording_id IS NULL;"));
    try std.testing.expectEqualStrings("removed root 1: 1 files, 1 tracks, 1 recordings\n", removed);
}

test "orca-cli analyze then scan shows the analyzed file's tags, and a second scan finds it unchanged" {
    const io = std.testing.io;
    var scratch = try Scratch.init(io);
    defer scratch.deinit();
    try scratch.copyFixture(io, "fixtures/audio/tagged-reference.flac", "music/song.flac");
    const song = try scratch.child("music/song.flac", .{});
    defer std.testing.allocator.free(song);
    const music = try scratch.child("music", .{});
    defer std.testing.allocator.free(music);

    try cliDiscard(io, &.{ "analyze", scratch.database_path, song });
    try cliDiscard(io, &.{ "add-root", scratch.database_path, music });
    const first_scan = try cli(io, null, &.{ "scan", scratch.database_path, music });
    defer std.testing.allocator.free(first_scan);
    const tracks = try cli(io, null, &.{ "tracks", scratch.database_path });
    defer std.testing.allocator.free(tracks);
    try expectContains(tracks, "Reference Tone");
    try expectContains(first_scan, "seen=1 changed=1 unchanged=0");

    const second_scan = try cli(io, null, &.{ "scan", scratch.database_path, music });
    defer std.testing.allocator.free(second_scan);
    try expectContains(second_scan, "seen=1 changed=0 unchanged=1");
}
