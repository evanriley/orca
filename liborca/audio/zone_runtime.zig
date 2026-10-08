const std = @import("std");
const buffer = @import("buffer.zig");
const contract = @import("backend.zig");
const fanout = @import("fanout.zig");
const output_api = @import("output.zig");
const pcm = @import("pcm.zig");
const processing = @import("processing.zig");
const render = @import("render.zig");
const zone_model = @import("zone.zig");

/// Fixed render-path geometry. Blocks are small enough that the smallest
/// `RenderStrategy` budget is still several device quanta deep, and the pool is
/// allocated once at Zone creation so no lane ever allocates while an output is
/// open.
pub const block_count: usize = 32;
pub const frames_per_block: u32 = 256;
/// Pools are sized for the widest layout Orca decodes, so a format change never
/// requires reallocating storage the render callback is reading.
pub const max_channels: u16 = 8;
/// Attempts before a Zone's output is declared permanently failed. Bounded by
/// design: another Zone must stay active when reopening ultimately fails.
pub const max_recovery_attempts: u32 = 3;
/// Floor on render-ahead before a device has reported its quantum.
pub const minimum_budget_blocks: usize = 2;

pub const Pipe = render.RenderPipe(block_count);
pub const Context = render.RenderContext(block_count);
pub const Sink = fanout.ZoneSink(block_count);

fn discoverDeviceKind(factory: output_api.Factory, device_id: u64) contract.DeviceKind {
    if (device_id == 0) return .unknown;
    var devices: [64]contract.Device = undefined;
    const count = factory.discover(&devices, .identity) catch return .unknown;
    for (devices[0..count]) |device| {
        if (device.id == device_id) return device.kind;
    }
    return .unknown;
}

/// A runtime Zone: policy plus the whole private render path.
///
/// `docs/audio-engine.md` requires each Zone to own its buffering so one Zone's
/// backpressure or failure cannot consume another's render capacity. That is
/// why the pool, pipe, render context and output session live here rather than
/// on a stack frame or on the Player.
///
/// Threading:
/// * `pool`, `pipe`, `output`, `zone` and `channels` belong to whichever
///   **single** lane currently owns the Zone. Before a Zone is published to a
///   `PlayerEngine` that is the control lane; afterwards it is the engine
///   thread, until the control lane publishes a set without this Zone and
///   observes the engine's acknowledgement.
/// * The atomics below are the only fields the real-time callback touches, and
///   they are all owned *here* — never by a Player. A Player can therefore be
///   destroyed or detached while an output is still open without the render
///   thread ever dereferencing freed memory.
/// The format a Zone opens its stream with for a canonical `format`: float32
/// at the canonical rate and channel count. `format.channels` must not exceed
/// `max_channels`.
pub fn streamFormat(format: pcm.Format) pcm.Format {
    return .{
        .sample_format = .float_32,
        .channels = format.channels,
        .sample_rate = format.sample_rate,
        .bits_per_sample = 32,
        .bytes_per_frame = format.channels * 4,
    };
}

fn packDeviceFormat(format: ?contract.DeviceFormat) u64 {
    const value = format orelse return 0;
    return @as(u64, value.sample_rate) << 32 |
        @as(u64, value.channels) << 8 |
        (@as(u64, @backingInt(value.sample_format)) + 1);
}

fn unpackDeviceFormat(bits: u64) ?contract.DeviceFormat {
    const tag: u8 = @truncate(bits);
    if (tag == 0) return null;
    return .{
        .sample_format = std.enums.fromInt(contract.DeviceSampleFormat, tag - 1) orelse return null,
        .sample_rate = @truncate(bits >> 32),
        .channels = @truncate(bits >> 8),
    };
}

pub const ZoneRuntime = struct {
    allocator: std.mem.Allocator,
    zone: zone_model.Zone,
    pool: buffer.BlockPool,
    pipe: Pipe = .{},
    context: Context = undefined,

    // Read by the render callback.
    /// Epoch the producer last submitted blocks under. Published *before* the
    /// blocks themselves, so the callback never discards audio it should keep.
    epoch: std.atomic.Value(u32) = .init(0),
    silenced: std.atomic.Value(bool) = .init(true),
    /// Packed epoch + frames-since-epoch; see `render.packPosition`.
    position: std.atomic.Value(u64) = .init(0),
    rendered_entry_serial: std.atomic.Value(u32) = .init(0),
    /// Packed serial stamp + frames-since-epoch at which the audible entry
    /// started; see `render.packEntryAnchor`. Position within a queue entry is
    /// `frames since epoch - this`, because a gapless advance keeps the epoch.
    entry_anchor: std.atomic.Value(u64) = .init(0),

    // Written by the control lane, read by the engine.
    output_requested: std.atomic.Value(bool) = .init(false),
    requested_device_id: std.atomic.Value(u64) = .init(0),

    // Written by the engine, read by the control lane.
    published_output_state: std.atomic.Value(u8) = .init(@backingInt(zone_model.OutputState.closed)),
    published_recovery_attempts: std.atomic.Value(u32) = .init(0),
    published_quantum_frames: std.atomic.Value(u32) = .init(0),
    published_graph_rate_hz: std.atomic.Value(u32) = .init(0),
    published_device_format: std.atomic.Value(u64) = .init(0),

    // Engine-thread-only state.
    output: ?output_api.Output = null,
    channels: u16 = 0,
    /// Canonical format the open stream was negotiated for. `RenderContext`
    /// channel count and the negotiated rate are fixed when a stream opens, so
    /// a queue entry in a different format needs the output reopened rather
    /// than resampled — see `docs/audio-engine.md` on the resampler.
    open_format: ?pcm.Format = null,
    open_device_id: u64 = 0,
    open_device_kind: contract.DeviceKind = .unknown,
    /// Consecutive playing passes in which this Zone held prepared blocks and
    /// its active output handed none back. A backend that stops consuming must
    /// neither stall the shared decode cursor for every other Zone nor keep its
    /// Player from draining.
    stalled_passes: u32 = 0,
    stall_started_ns: u64 = 0,
    recovery_wait_ns: u64 = 0,
    stable_blocks: u32 = 0,
    /// Negotiated backend quantum, refreshed from the open output. A device
    /// asks for a whole quantum per callback, so it is a hard floor on how far
    /// ahead the producer has to stay regardless of the Zone's policy target.
    quantum_frames: u32 = 0,

    /// Consecutive stalled passes after which the Zone stops holding the shared
    /// decode cursor.
    pub const stall_limit: u32 = 64;

    pub fn create(allocator: std.mem.Allocator) !*ZoneRuntime {
        const self = try allocator.create(ZoneRuntime);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .zone = .{
                .policy = .robust,
                .latency = .{
                    .requested_frames = 0,
                    .backend_quantum_frames = 0,
                    .render_ahead_frames = 0,
                    .dsp_frames = 0,
                    .hardware_frames = null,
                    .graph_rate_hz = null,
                },
            },
            .pool = try buffer.BlockPool.init(
                allocator,
                @intCast(block_count),
                frames_per_block,
                max_channels,
            ),
        };
        // Wired only after the Zone has its final heap address: the callback
        // receives these pointers and must never see a moved copy.
        self.context = .{
            .pool = &self.pool,
            .pipe = &self.pipe,
            .epoch = &self.epoch,
            .channels = 0,
            .silenced = &self.silenced,
            .position = &self.position,
            .rendered_entry_serial = &self.rendered_entry_serial,
            .entry_anchor = &self.entry_anchor,
        };
        return self;
    }

    /// Control lane. Only legal once no engine can still reach this Zone.
    pub fn destroy(self: *ZoneRuntime) void {
        const allocator = self.allocator;
        self.closeOutput();
        self.pool.deinit();
        allocator.destroy(self);
    }

    pub fn outputState(self: *const ZoneRuntime) zone_model.OutputState {
        return @fromBackingInt(@intCast(@as(std.meta.Tag(zone_model.OutputState), @intCast(self.published_output_state.load(.acquire)))));
    }

    pub fn publishState(self: *ZoneRuntime) void {
        _ = self.publishStateChanged();
    }

    pub fn publishStateChanged(self: *ZoneRuntime) bool {
        const output_state = @backingInt(self.zone.output_state);
        const recovery_attempts = self.zone.recovery_attempts;
        const quantum_frames = self.zone.latency.backend_quantum_frames;
        const graph_rate_hz = if (self.zone.output_state == .active)
            self.zone.latency.graph_rate_hz orelse 0
        else
            0;
        var changed = self.published_output_state.swap(output_state, .release) != output_state;
        changed = self.published_recovery_attempts.swap(recovery_attempts, .release) != recovery_attempts or changed;
        changed = self.published_quantum_frames.swap(quantum_frames, .release) != quantum_frames or changed;
        changed = self.published_graph_rate_hz.swap(graph_rate_hz, .release) != graph_rate_hz or changed;
        const device_format = if (self.zone.output_state == .active)
            packDeviceFormat(self.zone.latency.device_format)
        else
            0;
        changed = self.published_device_format.swap(device_format, .release) != device_format or changed;
        return changed;
    }

    pub fn publishedDeviceFormat(self: *const ZoneRuntime) ?contract.DeviceFormat {
        return unpackDeviceFormat(self.published_device_format.load(.acquire));
    }

    /// Producer-side view of this Zone for one fanout pass. The render-ahead
    /// budget comes from the Zone's own policy, so an interactive Zone stays a
    /// one-block handoff while a robust Zone buffers ahead.
    pub fn sink(self: *ZoneRuntime, channels: u16) Sink {
        return .{
            .pool = &self.pool,
            .pipe = &self.pipe,
            .channels = channels,
            .max_queued_blocks = self.blockBudget(),
        };
    }

    /// Blocks this Zone may keep prepared. The Zone's policy sets the intent;
    /// the device quantum sets the floor, because a render-ahead shallower than
    /// one callback's demand underruns on every single callback no matter how
    /// promptly the producer runs.
    pub fn blockBudget(self: *const ZoneRuntime) usize {
        const policy_blocks = self.zone.renderStrategy().blockBudget(
            frames_per_block,
            block_count,
        );
        const quantum_blocks: usize = if (self.quantum_frames == 0)
            minimum_budget_blocks
        else
            (2 * @as(usize, self.quantum_frames) + frames_per_block - 1) / frames_per_block;
        return @min(block_count, @max(policy_blocks, quantum_blocks, minimum_budget_blocks));
    }

    pub fn reclaim(self: *ZoneRuntime) usize {
        const free_before = self.pool.free_len;
        self.pipe.reclaim(&self.pool);
        return self.pool.free_len - free_before;
    }

    pub fn hasRoom(self: *ZoneRuntime) bool {
        return self.pipe.ready.len() < self.blockBudget() and self.pool.free_len > 0;
    }

    /// True once every block handed to the callback has come back. Producer-side
    /// state only, so it never races the callback's private cursor.
    pub fn quiescent(self: *const ZoneRuntime) bool {
        return self.pool.free_len == block_count;
    }

    pub fn recoveryExhausted(self: *const ZoneRuntime) bool {
        return self.zone.output_state == .failed and
            self.zone.recovery_attempts >= max_recovery_attempts;
    }

    /// Engine thread. Opening allocates and blocks, so it is deliberately on
    /// this lane and never inside a render callback.
    pub fn openOutput(
        self: *ZoneRuntime,
        factory: output_api.Factory,
        format: pcm.Format,
        device_id: u64,
    ) !void {
        std.debug.assert(self.output == null);
        if (format.channels == 0 or format.channels > max_channels)
            return error.UnsupportedChannelCount;
        self.channels = format.channels;
        self.context.channels = format.channels;
        const request: contract.OpenRequest = .{
            .device_id = device_id,
            .format = streamFormat(format),
            .policy = self.zone.policy,
            // Orca's own render-ahead is the Zone budget; absent an explicit
            // request the device is asked for one block, so the two do not
            // compound into a large latency.
            .requested_latency_frames = if (self.zone.latency.requested_frames != 0)
                self.zone.latency.requested_frames
            else
                frames_per_block,
        };
        self.output = try factory.open(request, Context.callback, self.context.userdata());
        self.open_format = format;
        self.open_device_id = device_id;
        self.open_device_kind = discoverDeviceKind(factory, device_id);
    }

    /// True when the open stream cannot carry `format` — the two properties
    /// fixed at open time are the channel count and the sample rate.
    pub fn outputFormatChanged(self: *const ZoneRuntime, format: pcm.Format) bool {
        const open = self.open_format orelse return false;
        return open.channels != format.channels or open.sample_rate != format.sample_rate;
    }

    /// Engine thread, or the control lane once the Zone is unpublished.
    pub fn closeOutput(self: *ZoneRuntime) void {
        if (self.output) |active| {
            active.close();
            self.output = null;
        }
        self.open_format = null;
        self.open_device_id = 0;
        self.open_device_kind = .unknown;
    }

    /// Reclaims every block still held by the render path. Legal only while no
    /// callback can be running — i.e. after `closeOutput`.
    pub fn resetPipe(self: *ZoneRuntime) void {
        std.debug.assert(self.output == null);
        self.pipe.reclaim(&self.pool);
        while (self.pipe.ready.pop()) |block| self.pool.release(block.index);
        if (self.pipe.current) |block| {
            self.pool.release(block.index);
            self.pipe.current = null;
        }
        self.pipe.current_frame = 0;
    }

    /// Clears what the callback published and its private mirrors of it, so a
    /// later Player never reads them as its own. Legal only while no callback
    /// can be running and no engine can reach this Zone.
    pub fn forgetTimeline(self: *ZoneRuntime) void {
        std.debug.assert(self.output == null);
        self.pipe.published_entry_serial = 0;
        self.pipe.entry_started = false;
        self.pipe.entry_start_offset = 0;
        self.pipe.rendered_entry_serial.store(0, .monotonic);
        self.context.published_position = 0;
        self.context.entry_start_frames = 0;
        self.epoch.store(0, .monotonic);
        self.position.store(0, .monotonic);
        self.rendered_entry_serial.store(0, .monotonic);
        self.entry_anchor.store(0, .monotonic);
    }

    /// Control lane, once no engine can reach this Zone.
    pub fn retire(self: *ZoneRuntime) void {
        self.silenced.store(true, .release);
        self.closeOutput();
        self.resetPipe();
        self.forgetTimeline();
        self.zone.close();
        self.stalled_passes = 0;
        self.recovery_wait_ns = 0;
        self.publishState();
    }
};

test "a Zone owns the atomics its render callback reads" {
    var runtime_zone = try ZoneRuntime.create(std.testing.allocator);
    defer runtime_zone.destroy();

    // Every pointer the callback follows must land inside the Zone allocation.
    try std.testing.expectEqual(&runtime_zone.pool, runtime_zone.context.pool);
    try std.testing.expectEqual(&runtime_zone.pipe, runtime_zone.context.pipe);
    try std.testing.expectEqual(&runtime_zone.epoch, runtime_zone.context.epoch);
    try std.testing.expectEqual(&runtime_zone.silenced, runtime_zone.context.silenced.?);
    try std.testing.expectEqual(&runtime_zone.position, runtime_zone.context.position.?);
    try std.testing.expectEqual(
        &runtime_zone.entry_anchor,
        runtime_zone.context.entry_anchor.?,
    );
}

test "a Zone publishes its device format only while its output is active" {
    var runtime_zone = try ZoneRuntime.create(std.testing.allocator);
    defer runtime_zone.destroy();
    const format: contract.DeviceFormat = .{
        .sample_format = .signed_24_32,
        .sample_rate = 96_000,
        .channels = 2,
    };
    runtime_zone.zone.latency.device_format = format;

    runtime_zone.zone.output_state = .active;
    try std.testing.expect(runtime_zone.publishStateChanged());
    try std.testing.expectEqual(format, runtime_zone.publishedDeviceFormat().?);

    runtime_zone.zone.output_state = .failed;
    try std.testing.expect(runtime_zone.publishStateChanged());
    try std.testing.expectEqual(null, runtime_zone.publishedDeviceFormat());

    runtime_zone.zone.output_state = .active;
    runtime_zone.zone.latency.device_format = null;
    _ = runtime_zone.publishStateChanged();
    try std.testing.expectEqual(null, runtime_zone.publishedDeviceFormat());
}

test "closing an output lets a Zone reclaim every prepared block" {
    var runtime_zone = try ZoneRuntime.create(std.testing.allocator);
    defer runtime_zone.destroy();
    runtime_zone.channels = 1;
    runtime_zone.context.channels = 1;

    const sink = runtime_zone.sink(1);
    var samples: [frames_per_block]f32 = @splat(0.5);
    try std.testing.expect(sink.submitCopy(&samples, frames_per_block, 3, 1, .{}, true));
    try std.testing.expect(!runtime_zone.quiescent());
    try std.testing.expect(runtime_zone.pool.holdsProcessed());

    runtime_zone.resetPipe();
    try std.testing.expect(runtime_zone.quiescent());
    try std.testing.expect(!runtime_zone.pool.holdsProcessed());
}

test "Zone render-ahead follows policy but never falls under the device quantum" {
    var interactive = try ZoneRuntime.create(std.testing.allocator);
    defer interactive.destroy();
    var robust = try ZoneRuntime.create(std.testing.allocator);
    defer robust.destroy();
    interactive.zone.policy = .interactive;

    // Before a device has reported anything, both sit on the floor/policy value.
    try std.testing.expectEqual(minimum_budget_blocks, interactive.blockBudget());
    try std.testing.expectEqual(@as(usize, 4), robust.blockBudget());

    // A device that asks for 1024 frames per callback raises both: a
    // render-ahead below one callback's demand underruns every callback.
    interactive.quantum_frames = 1024;
    robust.quantum_frames = 1024;
    try std.testing.expectEqual(@as(usize, 8), interactive.blockBudget());
    try std.testing.expectEqual(@as(usize, 8), robust.blockBudget());
}
