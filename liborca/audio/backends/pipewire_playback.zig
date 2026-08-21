const std = @import("std");
const backend_contract = @import("../backend.zig");
const buffer = @import("../buffer.zig");
const player = @import("../player.zig");
const render = @import("../render.zig");
const source_session = @import("../source_session.zig");
const zone = @import("../zone.zig");
const pipewire = @import("pipewire.zig");
const registry_api = @import("../../codec/registry.zig");
const storage = @import("../../storage/source.zig");

const block_count = 8;
const frames_per_block = 1024;

pub const Report = struct {
    frames_played: u64,
    underruns: u64,
    timing: backend_contract.TimingSnapshot,
    latency: zone.Latency,
};

/// Initial end-to-end WAV path. File reads and conversion remain on this
/// producer/control lane; PipeWire's callback only consumes prepared blocks.
pub fn playWavBlocking(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    device_id: u64,
    policy: zone.RenderPolicy,
) !Report {
    var local = try storage.LocalFileSource.open(io, path);
    defer local.close();
    const registry = registry_api.CodecRegistry.builtins();
    var decoder = try registry.openDetected(allocator, local.readable());
    const format = decoder.format;
    const frame_count = decoder.frame_count orelse {
        decoder.deinit();
        return error.UnknownTrackLength;
    };
    var source = source_session.SourceSession.init(decoder);
    defer source.deinit();

    var pool = try buffer.BlockPool.init(
        allocator,
        block_count,
        frames_per_block,
        format.channels,
    );
    defer pool.deinit();
    var pipe: render.RenderPipe(block_count) = .{};
    var transport: player.Player = .{};

    _ = try source.prime(
        block_count,
        &pipe,
        &pool,
        transport.generation.load(.acquire),
    );

    var backend: pipewire.Backend = .{};
    backend.init();
    defer backend.deinit();
    var context: pipewire.RenderContext(block_count) = .{
        .pool = &pool,
        .pipe = &pipe,
        .generation = &transport.generation,
        .channels = format.channels,
        .rendered_position = &transport.position_frames,
    };
    const output_format = @import("../pcm.zig").Format{
        .sample_format = .float_32,
        .channels = format.channels,
        .sample_rate = format.sample_rate,
        .bits_per_sample = 32,
        .bytes_per_frame = try std.math.mul(u16, format.channels, 4),
    };
    var output = try pipewire.OutputSession.open(.{
        .device_id = device_id,
        .format = output_format,
        .policy = policy,
        .requested_latency_frames = 0,
    }, pipewire.RenderContext(block_count).callback, context.userdata());
    defer output.close();
    transport.play();

    const track_ms = frame_count / format.sample_rate * 1000 +
        (frame_count % format.sample_rate) * 1000 / format.sample_rate;
    const iteration_limit = (track_ms + 5000) / 10 + 1;
    var iterations: u64 = 0;
    while (true) {
        _ = try source.prime(
            block_count,
            &pipe,
            &pool,
            transport.generation.load(.acquire),
        );
        if (source.eof and pool.free_len == block_count) break;
        if (iterations >= iteration_limit) return error.PlaybackStalled;
        iterations += 1;
        sleepMilliseconds(10);
    }
    transport.pause();

    return .{
        .frames_played = transport.position_frames.load(.acquire),
        .underruns = pipe.underruns.load(.acquire),
        .timing = try output.timing(),
        .latency = try output.latency(0, 0),
    };
}

fn sleepMilliseconds(milliseconds: u32) void {
    const duration: std.c.timespec = .{
        .sec = milliseconds / 1000,
        .nsec = @as(c_long, milliseconds % 1000) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&duration, null);
}
