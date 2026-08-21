const std = @import("std");
const liborca = @import("liborca");

fn silence(
    _: ?*anyopaque,
    samples: [*]f32,
    frames: u32,
    channels: u32,
) callconv(.c) void {
    @memset(samples[0 .. frames * channels], 0);
}

pub fn main() !void {
    var backend: liborca.audio.backends.native.Backend = .{};
    backend.init();
    defer backend.deinit();

    var output = try liborca.audio.backends.native.OutputSession.open(
        48_000,
        2,
        silence,
        null,
    );
    defer output.close();
    const duration: std.c.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&duration, null);
}
