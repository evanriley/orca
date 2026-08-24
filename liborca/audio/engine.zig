const std = @import("std");
const control = @import("../core/control.zig");
const object = @import("../core/object.zig");
const work = @import("../core/work.zig");
const output_api = @import("output.zig");
const pcm = @import("pcm.zig");
const player_api = @import("player.zig");
const processing = @import("processing.zig");
const render = @import("render.zig");
const zone_model = @import("zone.zig");
const zone_runtime = @import("zone_runtime.zig");

pub const ZoneRuntime = zone_runtime.ZoneRuntime;
pub const block_count = zone_runtime.block_count;
pub const frames_per_block = zone_runtime.frames_per_block;
pub const max_channels = zone_runtime.max_channels;

/// Zones one Player may fan out to. Bounded like everything else on this lane:
/// the engine's sink array and both publication slots are fixed-capacity.
pub const max_zones: usize = 8;

/// Engine wake interval. Short enough that play/pause/seek take effect within
/// one device quantum, long enough that an idle Player costs nothing.
pub const park_ns: u64 = 2 * std.time.ns_per_ms;
pub const telemetry_interval_ns: u64 = 100 * std.time.ns_per_ms;
pub const recovery_backoff_ns: u64 = 100 * std.time.ns_per_ms;
/// How often an active output's negotiated latency is re-read.
pub const latency_refresh_passes: u64 = 16;

pub const Options = struct {
    player: *player_api.Player,
    handle: object.PlayerHandle,
    telemetry: ?*control.TelemetryChannel = null,
    factory: ?output_api.Factory = null,
};

/// The one decode producer for a Player.
///
/// **One thread per Player, never per Zone.** The SPSC queues each Zone owns
/// require exactly one producer, and fanout is one-producer-many-consumers by
/// construction: the Player decodes canonical PCM once, runs Player-scope
/// processing on it, and copies it into each Zone's independently owned pool.
///
/// The engine thread never touches a `handle.Pool`. `core/handle.zig` performs
/// no locking, so generational handles protect *handles*, not a `*ZoneRuntime`
/// a worker already dereferenced. Instead the control lane publishes an
/// immutable `[]*ZoneRuntime` into an unclaimed slot and the engine adopts it at
/// a pass boundary and acknowledges it; the control lane only frees a Zone once
/// it has observed that acknowledgement. This is the same acknowledged
/// double-buffering `docs/audio-engine.md` describes for processing chains.
pub const PlayerEngine = struct {
    allocator: std.mem.Allocator,
    player: *player_api.Player,
    handle: object.PlayerHandle,
    telemetry: ?*control.TelemetryChannel,
    factory: ?output_api.Factory,
    registration: ?*work.Registration = null,
    player_processor: ?processing.Processor = null,

    // ---- Acknowledged double-buffered zone-set publication ----
    /// Two slots, only one of which the engine can be referencing at a time.
    slots: [2][max_zones]*ZoneRuntime = undefined,
    slot_lens: [2]usize = .{ 0, 0 },
    /// `sequence << 32 | slot`, written with a single release store so the
    /// engine can never read a sequence from one publication and a slot from
    /// another.
    published: std.atomic.Value(u64) = .init(0),
    /// Highest sequence the engine has adopted. The control lane waits for this
    /// before reusing a slot or freeing a Zone.
    ack: std.atomic.Value(u64) = .init(0),
    running: std.atomic.Value(bool) = .init(false),
    wake: std.atomic.Value(bool) = .init(false),
    drained: std.atomic.Value(bool) = .init(false),
    /// Set by the control lane while it needs exclusive access to the Player's
    /// `SourceQueue`. The engine is the only decoder, so loading or seeking a
    /// source has to stop it first: `sources` is a plain field, not an atomic.
    suspend_requested: std.atomic.Value(bool) = .init(false),
    /// Incremented at the end of every loop iteration, idle ones included.
    pass_epoch: std.atomic.Value(u64) = .init(0),
    /// Control-lane mirrors of the publication state.
    control_sequence: u64 = 0,
    control_slot: u32 = 0,

    // ---- Engine-thread-only state ----
    adopted: []*ZoneRuntime = &.{},
    adopted_sequence: u64 = 0,
    clock_zone: ?*ZoneRuntime = null,
    scratch: [frames_per_block * max_channels]f32 = undefined,
    elapsed_ns: u64 = 0,
    last_telemetry_ns: u64 = 0,
    passes: u64 = 0,

    pub fn create(allocator: std.mem.Allocator, options: Options) !*PlayerEngine {
        const self = try allocator.create(PlayerEngine);
        self.* = .{
            .allocator = allocator,
            .player = options.player,
            .handle = options.handle,
            .telemetry = options.telemetry,
            .factory = options.factory,
        };
        self.adopted = self.slots[0][0..0];
        return self;
    }

    /// Control lane. Only legal once the engine thread has been joined.
    pub fn destroy(self: *PlayerEngine) void {
        std.debug.assert(!self.running.load(.acquire));
        self.allocator.destroy(self);
    }

    // ---------------------------------------------------------------- control

    /// Control lane. Hands the engine a new immutable zone set and does not
    /// return until the engine is provably using it, which is what makes it safe
    /// for the caller to then close an output or free a `ZoneRuntime`.
    pub fn publishZones(self: *PlayerEngine, zones: []const *ZoneRuntime) !void {
        if (zones.len > max_zones) return error.TooManyZones;
        // The engine may still be reading the slot published last time, so wait
        // for its acknowledgement before writing the other one.
        self.awaitAcknowledgement();
        const slot: u32 = 1 - self.control_slot;
        @memcpy(self.slots[slot][0..zones.len], zones);
        self.slot_lens[slot] = zones.len;
        self.control_sequence += 1;
        self.control_slot = slot;
        self.published.store((self.control_sequence << 32) | slot, .release);
        self.wakeUp();
        // And wait again: on return the engine has adopted this exact set, so
        // any Zone missing from it can no longer be reached from the RT lane.
        self.awaitAcknowledgement();
    }

    pub fn wakeUp(self: *PlayerEngine) void {
        self.wake.store(true, .release);
    }

    /// Control lane. Blocks until the engine is provably outside its pass body,
    /// so the caller may mutate the Player's SourceQueue.
    ///
    /// Two completed iterations are the proof: the second of them must have
    /// started after `suspend_requested` was published, so it took the idle
    /// branch, and every later iteration does the same while the flag is set.
    pub fn quiesce(self: *PlayerEngine) void {
        self.suspend_requested.store(true, .release);
        if (!self.running.load(.acquire)) return;
        const target = self.pass_epoch.load(.acquire) + 2;
        while (self.running.load(.acquire) and self.pass_epoch.load(.acquire) < target) {
            self.wakeUp();
            std.Thread.yield() catch {};
        }
    }

    pub fn release(self: *PlayerEngine) void {
        self.suspend_requested.store(false, .release);
        self.wakeUp();
    }

    pub fn isDrained(self: *const PlayerEngine) bool {
        return self.drained.load(.acquire);
    }

    fn awaitAcknowledgement(self: *PlayerEngine) void {
        while (self.running.load(.acquire) and
            self.ack.load(.acquire) != self.control_sequence)
        {
            self.wakeUp();
            std.Thread.yield() catch {};
        }
    }

    // ----------------------------------------------------------------- engine

    /// Engine thread entry point. Registered with `work.Registry`, so shutdown
    /// and `destroyPlayer` cancel and join it rather than abandoning it.
    pub fn run(self: *PlayerEngine) void {
        const registration = self.registration.?;
        self.running.store(true, .release);
        while (!registration.cancellationRequested()) {
            if (!self.suspend_requested.load(.acquire)) self.pass();
            _ = self.pass_epoch.fetchAdd(1, .acq_rel);
            self.park();
        }
        // A final adopt releases a control lane blocked in awaitAcknowledgement,
        // and silencing leaves any still-open output emitting zeros rather than
        // whatever it last had queued.
        self.adoptZones();
        for (self.adopted) |runtime_zone| runtime_zone.silenced.store(true, .release);
        self.running.store(false, .release);
        registration.finish();
    }

    /// One engine pass. Exposed so tests can drive the whole loop body
    /// deterministically, with no thread and no sleeping.
    pub fn pass(self: *PlayerEngine) void {
        self.passes += 1;
        self.adoptZones();
        const zones = self.adopted;
        const silenced = self.player.silenced.load(.acquire);
        for (zones) |runtime_zone| {
            runtime_zone.pipe.reclaim(&runtime_zone.pool);
            runtime_zone.silenced.store(silenced, .release);
        }
        const format = self.player.format();
        self.pump(zones, format);
        self.serviceOutputs(zones, format);
        self.publishPosition(zones);
        self.publishDrained(zones);
    }

    fn adoptZones(self: *PlayerEngine) void {
        const published = self.published.load(.acquire);
        const sequence = published >> 32;
        if (sequence == self.adopted_sequence) return;
        const slot: usize = @intCast(published & 0xffff_ffff);
        self.adopted = self.slots[slot][0..self.slot_lens[slot]];
        self.adopted_sequence = sequence;
        self.ack.store(sequence, .release);
    }

    /// Decode once, process once, copy into every participating Zone.
    fn pump(self: *PlayerEngine, zones: []*ZoneRuntime, format: ?pcm.Format) void {
        const format_value = format orelse return;
        if (self.player.state.load(.acquire) != .playing) return;
        if (format_value.channels == 0 or format_value.channels > max_channels) return;

        var storage: [max_zones]zone_runtime.Sink = undefined;
        var participants: [max_zones]*ZoneRuntime = undefined;
        var count: usize = 0;
        for (zones) |runtime_zone| {
            if (!runtime_zone.output_requested.load(.acquire)) continue;
            if (runtime_zone.zone.output_state == .failed) continue;
            if (runtime_zone.hasRoom())
                runtime_zone.stalled_passes = 0
            else if (runtime_zone.stalled_passes >= ZoneRuntime.stall_limit)
                // This Zone has not drained for long enough that it is treated
                // as broken. Excluding it is what keeps the shared decode
                // cursor moving for every other Zone.
                continue;
            storage[count] = runtime_zone.sink(format_value.channels);
            participants[count] = runtime_zone;
            count += 1;
        }
        if (count == 0) return;

        // The canonical decode cursor is shared, so a block is only produced
        // when every participating Zone can take it. A Zone that stops draining
        // is dropped from the set below rather than being allowed to hold the
        // cursor still for the others.
        const epoch = self.player.epoch.load(.acquire);
        for (zones) |runtime_zone| runtime_zone.epoch.store(epoch, .release);
        const scratch = self.scratch[0 .. frames_per_block * format_value.channels];

        var produced: usize = 0;
        while (produced < block_count) {
            var room = true;
            for (participants[0..count]) |runtime_zone| {
                if (!runtime_zone.hasRoom()) room = false;
            }
            if (!room) break;
            const result = self.player.decodeProcessAndFanoutUnderEpoch(
                block_count,
                scratch,
                self.player_processor,
                storage[0..count],
                epoch,
            ) catch break;
            if (result.frames == 0) break;
            produced += 1;
        }

        if (produced == 0 and !self.player.finishedDecoding()) {
            for (participants[0..count]) |runtime_zone| {
                if (!runtime_zone.hasRoom()) runtime_zone.stalled_passes +|= 1;
            }
        }
    }

    /// Opens, polls and recovers each Zone's output. Stream creation and
    /// destruction stay on this control-side lane; the render callback only ever
    /// consumes prepared blocks.
    fn serviceOutputs(self: *PlayerEngine, zones: []*ZoneRuntime, format: ?pcm.Format) void {
        const factory = self.factory orelse return;
        for (zones) |runtime_zone| {
            if (!runtime_zone.output_requested.load(.acquire)) {
                if (runtime_zone.output != null) {
                    runtime_zone.closeOutput();
                    runtime_zone.resetPipe();
                    runtime_zone.zone.close();
                    runtime_zone.stalled_passes = 0;
                    runtime_zone.publishState();
                }
                continue;
            }
            if (runtime_zone.output) |active| {
                switch (active.status()) {
                    .active => {
                        // The negotiated quantum is only knowable after the
                        // stream has actually run, and it can change under us,
                        // so it is refreshed rather than read once at open.
                        if (runtime_zone.zone.output_state != .active or
                            self.passes % latency_refresh_passes == 0)
                        {
                            if (active.latency(
                                @intCast(runtime_zone.blockBudget() * frames_per_block),
                                0,
                            )) |latency| {
                                if (latency.backend_quantum_frames != 0)
                                    runtime_zone.quantum_frames = latency.backend_quantum_frames;
                                runtime_zone.zone.opened(latency);
                            } else |_| {
                                runtime_zone.zone.output_state = .active;
                            }
                            runtime_zone.publishState();
                        }
                    },
                    .connecting => {},
                    // A lost output is closed but the prepared render path is
                    // deliberately kept: the Player epoch and every queued block
                    // survive the reopen.
                    .lost => self.loseOutput(runtime_zone),
                }
            }
            if (runtime_zone.output != null) continue;
            const format_value = format orelse continue;

            if (runtime_zone.zone.output_state == .lost or
                runtime_zone.zone.output_state == .failed)
            {
                if (runtime_zone.zone.recovery_attempts >= zone_runtime.max_recovery_attempts) {
                    if (runtime_zone.zone.output_state != .failed) {
                        runtime_zone.zone.output_state = .failed;
                        runtime_zone.publishState();
                    }
                    continue;
                }
                if (runtime_zone.recovery_wait_ns > 0) {
                    runtime_zone.recovery_wait_ns -|= park_ns;
                    continue;
                }
                runtime_zone.zone.beginRecovery();
            } else if (runtime_zone.zone.output_state != .opening) {
                runtime_zone.zone.beginOpen(runtime_zone.requested_device_id.load(.acquire));
            }
            runtime_zone.publishState();

            runtime_zone.openOutput(
                factory,
                format_value,
                runtime_zone.requested_device_id.load(.acquire),
            ) catch {
                if (runtime_zone.zone.output_state == .recovering)
                    runtime_zone.zone.recoveryFailed()
                else
                    runtime_zone.zone.deviceLost();
                runtime_zone.recovery_wait_ns = recovery_backoff_ns;
                runtime_zone.publishState();
                continue;
            };
            runtime_zone.stalled_passes = 0;
            if (runtime_zone.output.?.latency(
                @intCast(runtime_zone.blockBudget() * frames_per_block),
                0,
            )) |latency| {
                if (latency.backend_quantum_frames != 0)
                    runtime_zone.quantum_frames = latency.backend_quantum_frames;
                runtime_zone.zone.opened(latency);
            } else |_| {
                runtime_zone.zone.output_state = .active;
            }
            runtime_zone.publishState();
        }
    }

    fn loseOutput(self: *PlayerEngine, runtime_zone: *ZoneRuntime) void {
        _ = self;
        runtime_zone.closeOutput();
        runtime_zone.zone.deviceLost();
        runtime_zone.recovery_wait_ns = recovery_backoff_ns;
        runtime_zone.stalled_passes = 0;
        runtime_zone.publishState();
    }

    /// Derives authoritative position from the clock Zone and publishes a
    /// coalesced hint. Snapshots stay authoritative; this channel is a hint.
    fn publishPosition(self: *PlayerEngine, zones: []*ZoneRuntime) void {
        const had_clock_zone = self.clock_zone != null;
        if (self.clock_zone) |current| {
            var still_valid = false;
            for (zones) |runtime_zone| {
                if (runtime_zone == current and runtime_zone.output != null and
                    runtime_zone.zone.output_state == .active) still_valid = true;
            }
            if (!still_valid) self.clock_zone = null;
        }
        if (self.clock_zone == null) {
            for (zones) |runtime_zone| {
                if (runtime_zone.output != null and runtime_zone.zone.output_state == .active) {
                    self.clock_zone = runtime_zone;
                    // Promotion only: the newly promoted Zone's frame counter
                    // starts at zero, so the timeline is rebased under a fresh
                    // epoch. The first Zone to open needs no rebase.
                    if (had_clock_zone) _ = self.player.stampEpoch();
                    break;
                }
            }
        }
        const clock_zone = self.clock_zone orelse return;
        const epoch = self.player.epoch.load(.acquire);
        const sample = clock_zone.position.load(.monotonic);
        if (render.positionEpoch(sample) != @as(u16, @truncate(epoch))) return;
        const frames = self.player.epoch_base_frames.load(.acquire) +
            render.positionFrames(sample);
        // Drop the sample if a seek landed while it was being assembled; the
        // next pass reports the new epoch's position instead of a stale one.
        if (self.player.epoch.load(.acquire) != epoch) return;
        self.player.position_frames.store(frames, .release);

        if (self.elapsed_ns -| self.last_telemetry_ns < telemetry_interval_ns) return;
        self.last_telemetry_ns = self.elapsed_ns;
        const telemetry = self.telemetry orelse return;
        telemetry.publish(.{ .player_position = .{
            .player = self.handle,
            .frames = frames,
        } }) catch {};
    }

    fn publishDrained(self: *PlayerEngine, zones: []*ZoneRuntime) void {
        if (self.player.sources == null) {
            self.drained.store(false, .monotonic);
            return;
        }
        if (!self.player.finishedDecoding()) {
            self.drained.store(false, .monotonic);
            return;
        }
        for (zones) |runtime_zone| {
            if (!runtime_zone.output_requested.load(.acquire)) continue;
            if (!runtime_zone.quiescent()) {
                self.drained.store(false, .monotonic);
                return;
            }
        }
        self.drained.store(true, .release);
    }

    fn park(self: *PlayerEngine) void {
        if (self.wake.swap(false, .acq_rel)) return;
        sleepNanoseconds(park_ns);
        // Wall-clock is only needed for cadence, so it is accumulated from the
        // parks actually taken rather than reading a clock every pass.
        self.elapsed_ns += park_ns;
    }
};

fn sleepNanoseconds(nanoseconds: u64) void {
    const duration: std.c.timespec = .{
        .sec = @intCast(nanoseconds / std.time.ns_per_s),
        .nsec = @intCast(nanoseconds % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&duration, null);
}

// ---------------------------------------------------------------------- tests

const source_session = @import("source_session.zig");

const RampDecoder = struct {
    position: u64 = 0,
    total: u64,
    channels: u16 = 1,

    fn decoder(self: *RampDecoder) @import("../codec/decoder.zig").Decoder {
        return .{
            .context = self,
            .vtable = &.{ .read_frames = read, .seek = seekTo, .deinit = release },
            .format = .{
                .sample_format = .float_32,
                .channels = self.channels,
                .sample_rate = 48_000,
                .bits_per_sample = 32,
                .bytes_per_frame = self.channels * 4,
            },
            .frame_count = self.total,
        };
    }

    fn read(context: *anyopaque, output: []f32) !usize {
        const self: *RampDecoder = @ptrCast(@alignCast(context));
        const frames = @min(output.len / self.channels, self.total - self.position);
        for (0..frames) |frame| {
            const value: f32 = @floatFromInt((self.position + frame) % 100);
            for (0..self.channels) |channel|
                output[frame * self.channels + channel] = value;
        }
        self.position += frames;
        return frames;
    }

    fn seekTo(context: *anyopaque, frame: u64) !void {
        const self: *RampDecoder = @ptrCast(@alignCast(context));
        self.position = frame;
    }

    fn release(_: *anyopaque) void {}
};

const Harness = struct {
    allocator: std.mem.Allocator,
    backend: output_api.TestBackend,
    player: player_api.Player = .{},
    engine: *PlayerEngine = undefined,
    registration: work.Registration = .{},

    fn init(allocator: std.mem.Allocator) !*Harness {
        const self = try allocator.create(Harness);
        self.* = .{ .allocator = allocator, .backend = .{ .allocator = allocator } };
        self.engine = try PlayerEngine.create(allocator, .{
            .player = &self.player,
            .handle = .{ .index = 0, .generation = 1 },
            .factory = self.backend.factory(),
        });
        self.engine.registration = &self.registration;
        return self;
    }

    fn deinit(self: *Harness) void {
        const allocator = self.allocator;
        self.engine.destroy();
        self.player.deinit();
        self.backend.deinit();
        allocator.destroy(self);
    }
};

fn liveStreamFor(
    backend: *output_api.TestBackend,
    runtime_zone: *ZoneRuntime,
) ?*output_api.TestBackend.Stream {
    var index = backend.stream_count;
    while (index > 0) {
        index -= 1;
        if (backend.streams[index]) |stream| {
            if (!stream.closed and stream.userdata == runtime_zone.context.userdata())
                return stream;
        }
    }
    return null;
}

fn openZone(allocator: std.mem.Allocator) !*ZoneRuntime {
    const runtime_zone = try ZoneRuntime.create(allocator);
    runtime_zone.output_requested.store(true, .release);
    return runtime_zone;
}

test "two Zones fed by one Player receive independent audio" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit();
    var decoder: RampDecoder = .{ .total = 4096 };
    try harness.player.loadSource(source_session.SourceSession.init(decoder.decoder()));

    const first = try openZone(allocator);
    defer first.destroy();
    const second = try openZone(allocator);
    defer second.destroy();
    try harness.engine.publishZones(&.{ first, second });
    harness.player.play();

    harness.engine.pass();
    harness.engine.pass();

    // Each Zone holds its own copy in its own pool.
    try std.testing.expect(first.output != null);
    try std.testing.expect(second.output != null);
    try std.testing.expect(first.pool.free_len < block_count);
    try std.testing.expect(second.pool.free_len < block_count);
    try std.testing.expect(first.pool.storage.ptr != second.pool.storage.ptr);

    var first_output: [frames_per_block]f32 = @splat(-1);
    var second_output: [frames_per_block]f32 = @splat(-1);
    liveStreamFor(&harness.backend, first).?.pump(&first_output, frames_per_block);
    liveStreamFor(&harness.backend, second).?.pump(&second_output, frames_per_block);
    try std.testing.expectEqualSlices(f32, &first_output, &second_output);
    try std.testing.expect(first_output[1] == 1);
}

test "a Zone that stops draining does not stall the other Zone" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit();
    var decoder: RampDecoder = .{ .total = 1_000_000 };
    try harness.player.loadSource(source_session.SourceSession.init(decoder.decoder()));

    const healthy = try openZone(allocator);
    defer healthy.destroy();
    const stuck = try openZone(allocator);
    defer stuck.destroy();
    try harness.engine.publishZones(&.{ healthy, stuck });
    harness.player.play();

    // Only the healthy Zone's callback ever runs, so the stuck Zone fills and
    // stays full. It must not hold the shared decode cursor still forever.
    var scratch: [frames_per_block]f32 = undefined;
    var pass: usize = 0;
    while (pass < ZoneRuntime.stall_limit + 8) : (pass += 1) {
        harness.engine.pass();
        if (liveStreamFor(&harness.backend, healthy)) |stream|
            stream.pump(&scratch, frames_per_block);
    }
    try std.testing.expectEqual(@as(u32, ZoneRuntime.stall_limit), stuck.stalled_passes);
    try std.testing.expectEqual(@as(u32, 0), healthy.stalled_passes);

    // Once the stuck Zone is out of the way the healthy one stops starving.
    const underruns_before = healthy.pipe.underruns.load(.monotonic);
    pass = 0;
    while (pass < 32) : (pass += 1) {
        harness.engine.pass();
        liveStreamFor(&harness.backend, healthy).?.pump(&scratch, frames_per_block);
    }
    try std.testing.expectEqual(underruns_before, healthy.pipe.underruns.load(.monotonic));
    try std.testing.expect(scratch[1] != 0);
    // Both outputs are still open: one Zone's backpressure failed neither.
    try std.testing.expectEqual(zone_model.OutputState.active, healthy.outputState());
    try std.testing.expectEqual(zone_model.OutputState.active, stuck.outputState());
}

test "a lost output recovers within bounded attempts and then stays failed" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit();
    var decoder: RampDecoder = .{ .total = 1_000_000 };
    try harness.player.loadSource(source_session.SourceSession.init(decoder.decoder()));

    const runtime_zone = try openZone(allocator);
    defer runtime_zone.destroy();
    try harness.engine.publishZones(&.{runtime_zone});
    harness.player.play();
    harness.engine.pass();
    try std.testing.expectEqual(zone_model.OutputState.active, runtime_zone.outputState());
    const prepared_before_loss = block_count - runtime_zone.pool.free_len;
    try std.testing.expect(prepared_before_loss > 0);

    liveStreamFor(&harness.backend, runtime_zone).?.markLost();
    runtime_zone.recovery_wait_ns = 0;
    harness.engine.pass();
    try std.testing.expectEqual(zone_model.OutputState.lost, runtime_zone.outputState());
    // The prepared render path survives the loss: no queue surgery happened.
    try std.testing.expectEqual(
        prepared_before_loss,
        block_count - runtime_zone.pool.free_len,
    );

    runtime_zone.recovery_wait_ns = 0;
    harness.engine.pass();
    try std.testing.expectEqual(zone_model.OutputState.active, runtime_zone.outputState());
    try std.testing.expectEqual(@as(u32, 0), runtime_zone.published_recovery_attempts.load(.acquire));

    // Now make every reopen fail: recovery is bounded, not infinite.
    harness.backend.fail_next_open = true;
    var pass: usize = 0;
    while (pass < 16) : (pass += 1) {
        if (liveStreamFor(&harness.backend, runtime_zone)) |stream| stream.markLost();
        runtime_zone.recovery_wait_ns = 0;
        harness.engine.pass();
    }
    try std.testing.expectEqual(zone_model.OutputState.failed, runtime_zone.outputState());
    try std.testing.expectEqual(
        zone_runtime.max_recovery_attempts,
        runtime_zone.published_recovery_attempts.load(.acquire),
    );
}

test "pausing silences a Zone without discarding its prepared blocks" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit();
    var decoder: RampDecoder = .{ .total = 1_000_000 };
    try harness.player.loadSource(source_session.SourceSession.init(decoder.decoder()));

    const runtime_zone = try openZone(allocator);
    defer runtime_zone.destroy();
    try harness.engine.publishZones(&.{runtime_zone});
    harness.player.play();
    harness.engine.pass();
    const stream = liveStreamFor(&harness.backend, runtime_zone).?;

    harness.player.pause();
    harness.engine.pass();
    const queued_while_paused = runtime_zone.pipe.ready.len();
    try std.testing.expect(queued_while_paused > 0);

    var samples: [frames_per_block]f32 = @splat(1);
    stream.pump(&samples, frames_per_block);
    for (samples) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    // Nothing was consumed and nothing was counted as missing.
    try std.testing.expectEqual(queued_while_paused, runtime_zone.pipe.ready.len());
    try std.testing.expectEqual(@as(u64, 0), runtime_zone.pipe.underruns.load(.monotonic));

    harness.player.play();
    harness.engine.pass();
    stream.pump(&samples, frames_per_block);
    try std.testing.expect(samples[1] != 0);
}

test "a seek discards stale-epoch blocks without touching the queue" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit();
    var decoder: RampDecoder = .{ .total = 1_000_000 };
    try harness.player.loadSource(source_session.SourceSession.init(decoder.decoder()));

    const runtime_zone = try openZone(allocator);
    defer runtime_zone.destroy();
    try harness.engine.publishZones(&.{runtime_zone});
    harness.player.play();
    harness.engine.pass();
    const stream = liveStreamFor(&harness.backend, runtime_zone).?;
    const queued_before = runtime_zone.pipe.ready.len();
    try std.testing.expect(queued_before > 0);

    _ = try harness.player.seek(50_000);
    // The stale blocks are still physically queued — no surgery took place.
    try std.testing.expectEqual(queued_before, runtime_zone.pipe.ready.len());

    harness.engine.pass();
    var samples: [frames_per_block]f32 = @splat(-1);
    stream.pump(&samples, frames_per_block);
    // The callback discarded every stale-epoch block and filled with silence.
    for (samples) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    try std.testing.expectEqual(@as(usize, 0), runtime_zone.pipe.ready.len());

    harness.engine.pass();
    stream.pump(&samples, frames_per_block);
    // 50_000 % 100 == 0, so post-seek audio starts at 0 and ramps.
    try std.testing.expectEqual(@as(f32, 0), samples[0]);
    try std.testing.expectEqual(@as(f32, 1), samples[1]);

    harness.engine.pass();
    try std.testing.expectEqual(
        @as(u64, 50_000 + frames_per_block),
        harness.player.snapshot().position_frames,
    );
}

test "an engine thread delays shutdown until it has actually stopped" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit();
    var decoder: RampDecoder = .{ .total = 1_000_000 };
    try harness.player.loadSource(source_session.SourceSession.init(decoder.decoder()));

    const runtime_zone = try openZone(allocator);
    defer runtime_zone.destroy();
    harness.registration.thread = try std.Thread.spawn(.{}, PlayerEngine.run, .{harness.engine});
    while (!harness.engine.running.load(.acquire)) std.Thread.yield() catch {};
    try harness.engine.publishZones(&.{runtime_zone});
    harness.player.play();

    // The engine is live and holds the Zone. Cancelling must join, not abandon.
    harness.registration.requestCancellation();
    harness.registration.awaitCompletion();
    try std.testing.expect(harness.registration.isFinished());
    try std.testing.expect(!harness.engine.running.load(.acquire));
    // Only now is closing the Zone's output safe.
    runtime_zone.closeOutput();
    runtime_zone.resetPipe();
}

test "unpublishing a Zone is acknowledged before the control lane frees it" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit();
    var decoder: RampDecoder = .{ .total = 1_000_000 };
    try harness.player.loadSource(source_session.SourceSession.init(decoder.decoder()));

    const keep = try openZone(allocator);
    defer keep.destroy();
    const remove = try openZone(allocator);
    harness.registration.thread = try std.Thread.spawn(.{}, PlayerEngine.run, .{harness.engine});
    while (!harness.engine.running.load(.acquire)) std.Thread.yield() catch {};
    try harness.engine.publishZones(&.{ keep, remove });
    harness.player.play();

    try harness.engine.publishZones(&.{keep});
    // publishZones returned, so the engine has adopted a set without `remove`
    // and can never dereference it again: freeing it here is safe.
    try std.testing.expectEqual(
        harness.engine.control_sequence,
        harness.engine.ack.load(.acquire),
    );
    remove.closeOutput();
    remove.destroy();

    harness.registration.requestCancellation();
    harness.registration.awaitCompletion();
    keep.closeOutput();
    keep.resetPipe();
}
