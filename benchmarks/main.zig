const std = @import("std");
const liborca = @import("liborca");

pub fn main(_: std.process.Init) !void {
    std.debug.print(
        "Orca {f}: no subsystem benchmarks registered yet.\n",
        .{liborca.version},
    );
}
