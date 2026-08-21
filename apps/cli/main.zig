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
    } else {
        try stdout.writeAll(
            \\Usage: orca-cli [--version]
            \\
            \\The host-independent Orca control client.
            \\
        );
    }

    try stdout.flush();
}
