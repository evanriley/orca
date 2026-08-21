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

    var devices: [16]liborca.audio.backend.Device = undefined;
    const device_count = try backend.discover(&devices);
    if (device_count == 0) return error.NoPipeWireOutputs;
    for (devices[0..device_count]) |*device| {
        std.debug.print("PipeWire output {d}: {s}\n", .{ device.id, device.nameSlice() });
    }

    var output = try liborca.audio.backends.native.OutputSession.open(
        .{
            .device_id = devices[0].id,
            .format = .{
                .sample_format = .float_32,
                .channels = 2,
                .sample_rate = 48_000,
                .bits_per_sample = 32,
                .bytes_per_frame = 8,
            },
            .policy = .interactive,
            .requested_latency_frames = 256,
        },
        silence,
        null,
    );
    defer output.close();
    const duration: std.c.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&duration, null);
    const timing = try output.timing();
    if (timing.backend_quantum_frames == 0) return error.NoPipeWireQuantum;
    std.debug.print(
        "PipeWire timing: quantum={d} delay={?d} queued={d} frames\n",
        .{ timing.backend_quantum_frames, timing.device_delay_frames, timing.queued_frames },
    );
}
