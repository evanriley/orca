const std = @import("std");
const backend_contract = @import("../backend.zig");
const buffer = @import("../buffer.zig");
const loaded_source = @import("../loaded_source.zig");
const player = @import("../player.zig");
const render = @import("../render.zig");
const zone = @import("../zone.zig");
const pipewire = @import("pipewire.zig");
const registry_api = @import("../../codec/registry.zig");

const block_count = 8;
const frames_per_block = 1024;

pub const Report = struct {
    frames_played: u64,
    underruns: u64,
    recoveries: u32,
    timing: backend_contract.TimingSnapshot,
    latency: zone.Latency,
};

/// Initial end-to-end registered-codec path. File reads and conversion remain
/// on this producer/control lane; PipeWire's callback only consumes prepared
/// blocks.
pub fn playFileBlocking(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    device_id: u64,
    policy: zone.RenderPolicy,
) !Report {
    // The session owns the opened file, so nothing backing the decoder lives in
    // this frame — the same lifetime a runtime-owned Player will rely on.
    var initial_source = try loaded_source.LoadedSource.open(
        allocator,
        io,
        registry_api.CodecRegistry.builtins(),
        path,
    );
    const format = initial_source.decoder.format;
    const frame_count = initial_source.decoder.frame_count orelse {
        initial_source.deinit();
        return error.UnknownTrackLength;
    };
    var transport: player.Player = .{};
    transport.loadSource(initial_source) catch |err| {
        initial_source.deinit();
        return err;
    };
    defer transport.deinit();

    var pool = try buffer.BlockPool.init(
        allocator,
        block_count,
        frames_per_block,
        format.channels,
    );
    defer pool.deinit();
    var pipe: render.RenderPipe(block_count) = .{};

    _ = try transport.prime(
        block_count,
        &pipe,
        &pool,
    );

    var backend: pipewire.Backend = .{};
    backend.init();
    defer backend.deinit();
    // Superseded by the runtime graph (`audio/engine.zig`); kept only until the
    // last caller of this stack-local path is gone.
    var rendered_position: std.atomic.Value(u64) = .init(0);
    var context: pipewire.RenderContext(block_count) = .{
        .pool = &pool,
        .pipe = &pipe,
        .epoch = &transport.epoch,
        .channels = format.channels,
        .silenced = &transport.silenced,
        .position = &rendered_position,
    };
    const output_format = @import("../pcm.zig").Format{
        .sample_format = .float_32,
        .channels = format.channels,
        .sample_rate = format.sample_rate,
        .bits_per_sample = 32,
        .bytes_per_frame = try std.math.mul(u16, format.channels, 4),
    };
    const open_request: backend_contract.OpenRequest = .{
        .device_id = device_id,
        .format = output_format,
        .policy = policy,
        .requested_latency_frames = 0,
    };
    var output: ?pipewire.OutputSession = try pipewire.OutputSession.open(
        open_request,
        pipewire.RenderContext(block_count).callback,
        context.userdata(),
    );
    defer if (output) |*active| active.close();
    transport.play();

    const track_ms = frame_count / format.sample_rate * 1000 +
        (frame_count % format.sample_rate) * 1000 / format.sample_rate;
    const iteration_limit = (track_ms + 5000) / 10 + 1;
    var iterations: u64 = 0;
    var recoveries: u32 = 0;
    while (true) {
        if (output.?.status() == .lost) {
            output.?.close();
            output = null;
            var attempts: u8 = 0;
            while (output == null and attempts < 3) {
                attempts += 1;
                sleepMilliseconds(100);
                output = pipewire.OutputSession.open(
                    open_request,
                    pipewire.RenderContext(block_count).callback,
                    context.userdata(),
                ) catch null;
            }
            if (output == null) return error.OutputRecoveryFailed;
            recoveries += 1;
        }
        _ = try transport.prime(
            block_count,
            &pipe,
            &pool,
        );
        if (transport.finishedDecoding() and pool.free_len == block_count) break;
        if (iterations >= iteration_limit) return error.PlaybackStalled;
        iterations += 1;
        sleepMilliseconds(10);
    }
    transport.pause();

    return .{
        .frames_played = render.positionFrames(rendered_position.load(.acquire)),
        .underruns = pipe.underruns.load(.acquire),
        .recoveries = recoveries,
        .timing = try output.?.timing(),
        .latency = try output.?.latency(0, 0),
    };
}

fn sleepMilliseconds(milliseconds: u32) void {
    const duration: std.c.timespec = .{
        .sec = milliseconds / 1000,
        .nsec = @as(c_long, milliseconds % 1000) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&duration, null);
}
