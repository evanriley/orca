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
    /// Transport epoch. Bumped by seek and stop; compared by the render
    /// callback so audio prepared before a discontinuity is discarded.
    epoch: u32,
    position_frames: u64,
};

pub const FanoutResult = struct {
    frames: usize,
    zones_accepted: usize,
};

pub const Player = struct {
    state: std.atomic.Value(TransportState) = .init(.stopped),
    /// Transport epoch: bumped on seek and stop, carried on every prepared
    /// block, and the only field the render callback compares. Track identity
    /// travels separately as `ReadyBlock.entry_serial`.
    epoch: std.atomic.Value(u32) = .init(1),
    position_frames: std.atomic.Value(u64) = .init(0),
    /// Frame the current epoch started at. Authoritative position is derived on
    /// the control lane as `epoch_base_frames + clock zone frames-since-epoch`,
    /// which is why the two halves are stamped together by every discontinuity.
    epoch_base_frames: std.atomic.Value(u64) = .init(0),
    /// Read by the render callback on the real-time lane. When set, the
    /// callback emits silence without consuming blocks or counting underruns.
    /// A freshly constructed Player is stopped, so it starts silenced.
    silenced: std.atomic.Value(bool) = .init(true),
    sources: ?source_session.SourceQueue = null,
    /// Highest entry serial this Player has ever handed out. A `SourceQueue`
    /// numbers entries from its own base, so without carrying the counter
    /// across a replacement two different queue entries could share a serial
    /// and now-playing would resolve to the wrong track.
    serial_counter: u32 = 0,

    pub fn deinit(self: *Player) void {
        if (self.sources) |*sources| sources.deinit();
        self.* = undefined;
    }

    pub fn loadSource(self: *Player, source: source_session.SourceSession) !void {
        if (self.sources != null) return error.PlayerSourceAlreadyLoaded;
        self.sources = source_session.SourceQueue.init(source);
        self.sources.?.rebaseSerials(self.serial_counter);
        self.resetTimeline();
    }

    /// Replaces the whole SourceQueue and retires the prepared audio that
    /// belonged to it. Bumping the epoch is what makes this safe without any
    /// queue surgery: blocks already handed to a callback under the old epoch
    /// are discarded there rather than being chased down and removed.
    pub fn replaceSource(self: *Player, source: source_session.SourceSession) void {
        self.releaseSources();
        self.sources = source_session.SourceQueue.init(source);
        self.sources.?.rebaseSerials(self.serial_counter);
        self.resetTimeline();
        _ = self.epoch.fetchAdd(1, .acq_rel);
    }

    /// Drops every decoder without touching the playback queue above it. This
    /// is what `stop` means: the transport stops and its sources are released,
    /// while the entries and cursor the user assembled survive.
    pub fn releaseSources(self: *Player) void {
        if (self.sources) |*sources| {
            self.serial_counter = sources.entry_serial_counter;
            sources.deinit();
        }
        self.sources = null;
    }

    /// Frames in the currently loaded source, when its decoder knows.
    pub fn frameCount(self: *const Player) ?u64 {
        if (self.sources) |*sources| return sources.current.decoder.frame_count;
        return null;
    }

    fn resetTimeline(self: *Player) void {
        self.position_frames.store(0, .release);
        self.epoch_base_frames.store(0, .release);
    }

    pub fn primeNextSource(self: *Player, source: source_session.SourceSession) !void {
        if (self.sources) |*sources| return sources.primeNext(source);
        return error.PlayerHasNoSource;
    }

    /// Single-Zone convenience that primes straight into one pool. Kept for
    /// tests and benchmarks only: the runtime path decodes once and fans out
    /// into independently owned Zone pools via `decodeProcessAndFanout`.
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
                self.epoch.load(.acquire),
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
        return self.decodeProcessAndFanoutUnderEpoch(
            capacity,
            scratch,
            player_processor,
            sinks,
            self.epoch.load(.acquire),
        );
    }

    /// Same fanout, under an epoch the caller has already published into every
    /// Zone's own atomic. The engine loads the epoch once, publishes it, and
    /// submits under it, so a Zone can never hold blocks stamped with an epoch
    /// its callback has not been told about.
    pub fn decodeProcessAndFanoutUnderEpoch(
        self: *Player,
        comptime capacity: usize,
        scratch: []f32,
        player_processor: ?processing.Processor,
        sinks: []fanout.ZoneSink(capacity),
        epoch: u32,
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
                    epoch,
                    self.entrySerial(),
                ),
        };
    }

    /// Queue entry whose PCM the producer is currently emitting. Zero when no
    /// source is loaded. Never compared by the render callback.
    pub fn entrySerial(self: *const Player) u32 {
        return if (self.sources) |*sources| sources.current_entry_serial else 0;
    }

    pub fn finishedDecoding(self: *const Player) bool {
        return if (self.sources) |*sources| sources.finishedDecoding() else true;
    }

    pub fn play(self: *Player) void {
        // Unsilence before publishing the state so the callback never observes
        // "playing" while still emitting silence.
        self.silenced.store(false, .release);
        self.state.store(.playing, .release);
    }

    /// Takes effect inside the very next render callback: prepared blocks stay
    /// queued, position stops advancing, and no underrun is recorded.
    pub fn pause(self: *Player) void {
        self.silenced.store(true, .release);
        self.state.store(.paused, .release);
    }

    pub fn stop(self: *Player) void {
        self.silenced.store(true, .release);
        self.state.store(.stopped, .release);
        self.position_frames.store(0, .release);
        self.epoch_base_frames.store(0, .release);
        _ = self.epoch.fetchAdd(1, .acq_rel);
    }

    pub fn seek(self: *Player, frame: u64) !u32 {
        if (self.sources) |*sources| try sources.seek(frame);
        self.position_frames.store(frame, .release);
        self.epoch_base_frames.store(frame, .release);
        return self.epoch.fetchAdd(1, .acq_rel) +% 1;
    }

    /// Retires prepared audio without moving the source. Used when the clock
    /// Zone is replaced: the promoted Zone's frame counter starts from zero, so
    /// the timeline has to be rebased onto the position already reported.
    pub fn stampEpoch(self: *Player) u32 {
        self.epoch_base_frames.store(self.position_frames.load(.acquire), .release);
        return self.epoch.fetchAdd(1, .acq_rel) +% 1;
    }

    pub fn snapshot(self: *const Player) Snapshot {
        return .{
            .state = self.state.load(.acquire),
            .epoch = self.epoch.load(.acquire),
            .position_frames = self.position_frames.load(.acquire),
        };
    }
};

test "seek advances the transport epoch instead of editing queues" {
    var player: Player = .{};
    const epoch = try player.seek(48_000);
    const current = player.snapshot();
    try std.testing.expectEqual(epoch, current.epoch);
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

    const seek_epoch = try player.seek(1);
    try std.testing.expectEqual(@as(usize, 1), test_decoder.position);
    const after_seek = try player.decodeAndFanout(1, &scratch, &sinks);
    try std.testing.expectEqual(@as(usize, 2), after_seek.frames);
    try std.testing.expectEqual(
        @as(usize, 2),
        first_pipe.render(&first_pool, 1, seek_epoch, &first_output),
    );
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.75 }, &first_output);
}

test "pausing silences output without discarding prepared audio" {
    var player: Player = .{};
    try std.testing.expect(player.silenced.load(.acquire));

    player.play();
    try std.testing.expect(!player.silenced.load(.acquire));
    const playing_epoch = player.snapshot().epoch;

    player.pause();
    try std.testing.expect(player.silenced.load(.acquire));
    try std.testing.expectEqual(TransportState.paused, player.snapshot().state);
    // Pause must not invalidate queued blocks: resuming continues where the
    // callback left off, so the epoch is unchanged.
    try std.testing.expectEqual(playing_epoch, player.snapshot().epoch);

    player.play();
    try std.testing.expect(!player.silenced.load(.acquire));
    try std.testing.expectEqual(playing_epoch, player.snapshot().epoch);

    // Stop is a discontinuity: it silences output *and* retires the epoch.
    player.stop();
    try std.testing.expect(player.silenced.load(.acquire));
    try std.testing.expect(player.snapshot().epoch != playing_epoch);
}
