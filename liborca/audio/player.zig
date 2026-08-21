const std = @import("std");
const buffer = @import("buffer.zig");
const fanout = @import("fanout.zig");
const pcm = @import("pcm.zig");
const processing = @import("processing.zig");
const render = @import("render.zig");
const source_session = @import("source_session.zig");

pub const TransportState = enum(u8) { stopped, playing, paused };

pub const Snapshot = struct {
    state: TransportState,
    generation: u64,
    position_frames: u64,
};

pub const FanoutResult = struct {
    frames: usize,
    zones_accepted: usize,
};

pub const Player = struct {
    state: std.atomic.Value(TransportState) = .init(.stopped),
    generation: std.atomic.Value(u64) = .init(1),
    position_frames: std.atomic.Value(u64) = .init(0),
    sources: ?source_session.SourceQueue = null,

    pub fn deinit(self: *Player) void {
        if (self.sources) |*sources| sources.deinit();
        self.* = undefined;
    }

    pub fn loadSource(self: *Player, source: source_session.SourceSession) !void {
        if (self.sources != null) return error.PlayerSourceAlreadyLoaded;
        self.sources = source_session.SourceQueue.init(source);
    }

    pub fn primeNextSource(self: *Player, source: source_session.SourceSession) !void {
        if (self.sources) |*sources| return sources.primeNext(source);
        return error.PlayerHasNoSource;
    }

    pub fn prime(
        self: *Player,
        comptime queue_capacity: usize,
        pipe: *render.RenderPipe(queue_capacity),
        pool: *buffer.BlockPool,
    ) !usize {
        if (self.sources) |*sources| {
            return sources.prime(
                queue_capacity,
                pipe,
                pool,
                self.generation.load(.acquire),
            );
        }
        return error.PlayerHasNoSource;
    }

    /// Producer/control-lane decode used by multi-Zone fanout. Decoder and
    /// source I/O never run on an output callback.
    pub fn decodeFrames(self: *Player, samples: []f32) !usize {
        if (self.sources) |*sources| return sources.readFrames(samples);
        return error.PlayerHasNoSource;
    }

    pub fn format(self: *const Player) ?pcm.Format {
        return if (self.sources) |*sources| sources.format() else null;
    }

    pub fn sourceFormat(self: *const Player) ?pcm.Format {
        return if (self.sources) |*sources| sources.sourceFormat() else null;
    }

    pub fn decodeAndFanout(
        self: *Player,
        comptime capacity: usize,
        scratch: []f32,
        sinks: []fanout.ZoneSink(capacity),
    ) !FanoutResult {
        return self.decodeProcessAndFanout(capacity, scratch, null, sinks);
    }

    pub fn decodeProcessAndFanout(
        self: *Player,
        comptime capacity: usize,
        scratch: []f32,
        player_processor: ?processing.Processor,
        sinks: []fanout.ZoneSink(capacity),
    ) !FanoutResult {
        const format_value = self.format() orelse return error.PlayerHasNoSource;
        const frames = try self.decodeFrames(scratch);
        const samples = scratch[0 .. frames * format_value.channels];
        if (player_processor) |processor|
            processor.process(samples, @intCast(frames), format_value.channels);
        return .{
            .frames = frames,
            .zones_accepted = if (frames == 0)
                0
            else
                fanout.submit(
                    capacity,
                    sinks,
                    samples,
                    @intCast(frames),
                    self.generation.load(.acquire),
                ),
        };
    }

    pub fn finishedDecoding(self: *const Player) bool {
        return if (self.sources) |*sources| sources.finishedDecoding() else true;
    }

    pub fn play(self: *Player) void {
        self.state.store(.playing, .release);
    }

    pub fn pause(self: *Player) void {
        self.state.store(.paused, .release);
    }

    pub fn stop(self: *Player) void {
        self.state.store(.stopped, .release);
        self.position_frames.store(0, .release);
        _ = self.generation.fetchAdd(1, .acq_rel);
    }

    pub fn seek(self: *Player, frame: u64) !u64 {
        if (self.sources) |*sources| try sources.seek(frame);
        self.position_frames.store(frame, .release);
        return self.generation.fetchAdd(1, .acq_rel) +% 1;
    }

    pub fn snapshot(self: *const Player) Snapshot {
        return .{
            .state = self.state.load(.acquire),
            .generation = self.generation.load(.acquire),
            .position_frames = self.position_frames.load(.acquire),
        };
    }
};

test "seek advances generation instead of editing queues" {
    var player: Player = .{};
    const generation = try player.seek(48_000);
    const current = player.snapshot();
    try std.testing.expectEqual(generation, current.generation);
    try std.testing.expectEqual(@as(u64, 48_000), current.position_frames);
}

const TestDecoder = struct {
    position: usize = 0,

    fn decoder(self: *TestDecoder) @import("../codec/decoder.zig").Decoder {
        return .{
            .context = self,
            .vtable = &.{
                .read_frames = read,
                .seek = seek,
                .deinit = deinit,
            },
            .format = .{
                .sample_format = .float_32,
                .channels = 1,
                .sample_rate = 48_000,
                .bits_per_sample = 32,
                .bytes_per_frame = 4,
            },
            .frame_count = 4,
        };
    }

    fn read(context: *anyopaque, output: []f32) !usize {
        const self: *TestDecoder = @ptrCast(@alignCast(context));
        const values = [_]f32{ 0.25, 0.5, 0.75, 1.0 };
        const count = @min(output.len, values.len - self.position);
        @memcpy(output[0..count], values[self.position .. self.position + count]);
        self.position += count;
        return count;
    }

    fn seek(context: *anyopaque, frame: u64) !void {
        const self: *TestDecoder = @ptrCast(@alignCast(context));
        self.position = @intCast(frame);
    }

    fn deinit(_: *anyopaque) void {}
};

test "Player decodes once into independently owned Zone pipelines" {
    var test_decoder: TestDecoder = .{};
    var player: Player = .{};
    defer player.deinit();
    try player.loadSource(source_session.SourceSession.init(test_decoder.decoder()));
    var first_pool = try buffer.BlockPool.init(std.testing.allocator, 1, 2, 1);
    defer first_pool.deinit();
    var second_pool = try buffer.BlockPool.init(std.testing.allocator, 1, 2, 1);
    defer second_pool.deinit();
    var first_pipe: render.RenderPipe(1) = .{};
    var second_pipe: render.RenderPipe(1) = .{};
    var player_gain: processing.Gain = .{ .linear = .init(0.5) };
    var zone_gain: processing.Gain = .{ .linear = .init(0.5) };
    const Sink = fanout.ZoneSink(1);
    var sinks = [_]Sink{
        .{ .pool = &first_pool, .pipe = &first_pipe, .channels = 1 },
        .{
            .pool = &second_pool,
            .pipe = &second_pipe,
            .channels = 1,
            .zone_processor = zone_gain.processor(),
        },
    };
    var scratch: [2]f32 = undefined;
    const result = try player.decodeProcessAndFanout(
        1,
        &scratch,
        player_gain.processor(),
        &sinks,
    );
    try std.testing.expectEqual(@as(usize, 2), result.frames);
    try std.testing.expectEqual(@as(usize, 2), result.zones_accepted);

    var first_output: [2]f32 = undefined;
    var second_output: [2]f32 = undefined;
    try std.testing.expectEqual(
        @as(usize, 2),
        first_pipe.render(&first_pool, 1, 1, &first_output),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        second_pipe.render(&second_pool, 1, 1, &second_output),
    );
    try std.testing.expectEqualSlices(f32, &.{ 0.125, 0.25 }, &first_output);
    try std.testing.expectEqualSlices(f32, &.{ 0.0625, 0.125 }, &second_output);

    const seek_generation = try player.seek(1);
    try std.testing.expectEqual(@as(usize, 1), test_decoder.position);
    const after_seek = try player.decodeAndFanout(1, &scratch, &sinks);
    try std.testing.expectEqual(@as(usize, 2), after_seek.frames);
    try std.testing.expectEqual(
        @as(usize, 2),
        first_pipe.render(&first_pool, 1, seek_generation, &first_output),
    );
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.75 }, &first_output);
}
