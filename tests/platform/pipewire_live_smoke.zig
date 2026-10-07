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

const silent_sink_name = "Orca Silent Test Sink";

const usage_hint = "pipewire-live-smoke: no silent output given; refusing to open the " ++
    "default or first output, which may be audible. Pass the device id printed by " ++
    "scripts/silent-sink.sh as `zig build pipewire-live-smoke -- ID` or ORCA_TEST_DEVICE=ID";

fn requestedDeviceId(init: std.process.Init) !u64 {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const text = if (args.len > 1)
        args[1]
    else
        init.environ_map.get("ORCA_TEST_DEVICE") orelse "";
    if (text.len == 0) {
        std.debug.print("{s}\n", .{usage_hint});
        return error.NoSilentOutputGiven;
    }
    return std.fmt.parseInt(u64, text, 10) catch {
        std.debug.print(
            "pipewire-live-smoke: device id \"{s}\" is not a decimal id; expected the id printed by scripts/silent-sink.sh\n",
            .{text},
        );
        return error.InvalidDeviceId;
    };
}

pub fn main(init: std.process.Init) !void {
    const device_id = try requestedDeviceId(init);

    var backend: liborca.internal.audio.backends.native.Backend = .{};
    backend.init();
    defer backend.deinit();

    var devices: [16]liborca.internal.audio.backend.Device = undefined;
    const device_count = try backend.discover(&devices, .capabilities);
    var selected: ?*const liborca.internal.audio.backend.Device = null;
    for (devices[0..device_count]) |*device| {
        std.debug.print("PipeWire output {d}: {s}\n", .{ device.id, device.nameSlice() });
        if (device.id == device_id) selected = device;
    }
    const device = selected orelse {
        std.debug.print(
            "pipewire-live-smoke: device {d} is not listed by discovery; expected the id printed by scripts/silent-sink.sh\n",
            .{device_id},
        );
        return error.DeviceNotFound;
    };
    if (device.kind != .virtual) {
        std.debug.print(
            "pipewire-live-smoke: device {d} (\"{s}\") is not a virtual sink; refusing to open possibly audible hardware. Use the id printed by scripts/silent-sink.sh\n",
            .{ device_id, device.nameSlice() },
        );
        return error.DeviceNotVirtual;
    }
    if (!std.mem.startsWith(u8, device.nameSlice(), silent_sink_name)) {
        std.debug.print(
            "pipewire-live-smoke: device {d} is named \"{s}\", expected \"{s}\"; use the id printed by scripts/silent-sink.sh\n",
            .{ device_id, device.nameSlice(), silent_sink_name },
        );
        return error.DeviceNotSilentSink;
    }
    std.debug.print("Opening device {d}: {s}\n", .{ device_id, device.nameSlice() });

    var output = try liborca.internal.audio.backends.native.OutputSession.open(
        .{
            .device_id = device_id,
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
    if (output.status() != .active) return error.PipeWireStreamNotActive;
    if (timing.backend_quantum_frames == 0) return error.NoPipeWireQuantum;
    std.debug.print(
        "PipeWire timing: quantum={d} delay={?d} queued={d} frames\n",
        .{ timing.backend_quantum_frames, timing.device_delay_frames, timing.queued_frames },
    );
}
