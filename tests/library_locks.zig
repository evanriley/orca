const std = @import("std");
const builtin = @import("builtin");
const liborca = @import("liborca");
const integration_options = @import("integration_options");

fn listPlaylistsInChild(io: std.Io, database_path: []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ integration_options.orca_cli, "playlists", database_path },
    });
    defer std.testing.allocator.free(result.stderr);
    errdefer std.testing.allocator.free(result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    return result.stdout;
}

fn expectChildListsPlaylist(io: std.Io, database_path: []const u8, name: []const u8) !void {
    const stdout = try listPlaylistsInChild(io, database_path);
    defer std.testing.allocator.free(stdout);
    try std.testing.expect(std.mem.indexOf(u8, stdout, name) != null);
}

test "a second Orca process cannot delete the WAL under a live Library" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const working_directory = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(working_directory);
    const database_path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "{s}/.zig-cache/tmp/{s}/library.db",
        .{ working_directory, temporary.sub_path },
        0,
    );
    defer std.testing.allocator.free(database_path);
    const wal_path = try std.fmt.allocPrint(std.testing.allocator, "{s}-wal", .{database_path});
    defer std.testing.allocator.free(wal_path);
    const shm_path = try std.fmt.allocPrint(std.testing.allocator, "{s}-shm", .{database_path});
    defer std.testing.allocator.free(shm_path);

    var runtime = liborca.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(io, database_path);
    _ = try runtime.libraryCreatePlaylist(library, "before");
    const wal_inode = (try std.Io.Dir.cwd().statFile(io, wal_path, .{})).inode;

    for ([_][]const u8{ database_path, shm_path }) |path| {
        const foreign = try std.Io.Dir.cwd().openFile(io, path, .{});
        foreign.close(io);
    }

    try expectChildListsPlaylist(io, database_path, "before");
    try std.testing.expectEqual(wal_inode, (try std.Io.Dir.cwd().statFile(io, wal_path, .{})).inode);

    _ = try runtime.libraryCreatePlaylist(library, "after");
    try expectChildListsPlaylist(io, database_path, "after");
}
