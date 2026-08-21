const std = @import("std");
const liborca = @import("liborca");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (args.len > 1 and std.mem.eql(u8, args[1], "--version")) {
        try stdout.print("orca-cli {f}\n", .{liborca.version});
    } else if (args.len > 1 and std.mem.eql(u8, args[1], "demo")) {
        var runtime = liborca.OrcaRuntime.init(allocator);
        defer runtime.deinit();

        const request_id = try runtime.submit(.create_player);
        _ = runtime.processNextCommand();
        const event = runtime.pollEvent() orelse return error.MissingCompletionEvent;
        if (event.request_id != request_id) return error.UnexpectedCompletionEvent;
        switch (event.outcome) {
            .player_created => |player| try stdout.print(
                "created Player handle {d}:{d}\n",
                .{ player.index, player.generation },
            ),
            else => return error.PlayerCreationFailed,
        }
    } else if (args.len == 4 and std.mem.eql(u8, args[1], "scan")) {
        const database_path = try allocator.dupeSentinel(u8, args[2], 0);
        var runtime = liborca.OrcaRuntime.init(allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(database_path);
        const library_database = try runtime.libraryDatabase(library_handle);
        var scanner = liborca.library.Scanner{
            .allocator = allocator,
            .io = init.io,
            .observed_files = &library_database.observed_files,
        };
        const result = try scanner.scan(args[3]);
        try stdout.print(
            "seen={d} changed={d} unchanged={d} unsupported={d} errors={d} batches={d}\n",
            .{
                result.files_seen,
                result.changed,
                result.unchanged,
                result.unsupported,
                result.errors,
                result.batches_committed,
            },
        );
    } else {
        try stdout.writeAll(
            \\Usage: orca-cli [--version | demo | scan DATABASE ROOT]
            \\
            \\The host-independent Orca control client.
            \\
        );
    }

    try stdout.flush();
}
