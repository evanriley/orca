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
pub const ZoneRuntime = struct {
    allocator: std.mem.Allocator,
    zone: zone_model.Zone,
    pool: buffer.BlockPool,
    pipe: Pipe = .{},
    context: Context = undefined,

    // ---- Zone-owned atomics read by the render callback ----
    /// Epoch the producer last submitted blocks under. Published *before* the
    /// blocks themselves, so the callback never discards audio it should keep.
    epoch: std.atomic.Value(u32) = .init(0),
    silenced: std.atomic.Value(bool) = .init(true),
    /// Packed epoch + frames-since-epoch; see `render.packPosition`.
    position: std.atomic.Value(u64) = .init(0),
    rendered_entry_serial: std.atomic.Value(u32) = .init(0),

    // ---- Control lane -> engine requests ----
    output_requested: std.atomic.Value(bool) = .init(false),
    requested_device_id: std.atomic.Value(u64) = .init(0),

    // ---- Engine -> control lane published state ----
    published_output_state: std.atomic.Value(u8) = .init(@backingInt(zone_model.OutputState.closed)),
    published_recovery_attempts: std.atomic.Value(u32) = .init(0),
    published_quantum_frames: std.atomic.Value(u32) = .init(0),
    published_device_delay_frames: std.atomic.Value(u64) = .init(0),

    // ---- Engine-thread-only state ----
    output: ?output_api.Output = null,
    channels: u16 = 0,
    /// Consecutive engine passes during which this Zone accepted no PCM while
    /// its output claimed to be active. A backend that stops consuming must not
    /// be able to stall the shared decode cursor for every other Zone.
    stalled_passes: u32 = 0,
    recovery_wait_ns: u64 = 0,
    /// Negotiated backend quantum, refreshed from the open output. A device
    /// asks for a whole quantum per callback, so it is a hard floor on how far
    /// ahead the producer has to stay regardless of the Zone's policy target.
    quantum_frames: u32 = 0,

    /// Consecutive stalled passes tolerated before the Zone is treated as lost.
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
        return @fromBackingInt(@intCast(self.published_output_state.load(.acquire)));
    }

    pub fn publishState(self: *ZoneRuntime) void {
        self.published_output_state.store(@backingInt(self.zone.output_state), .release);
        self.published_recovery_attempts.store(self.zone.recovery_attempts, .release);
        self.published_quantum_frames.store(self.zone.latency.backend_quantum_frames, .release);
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

    pub fn hasRoom(self: *ZoneRuntime) bool {
        return self.pipe.ready.len() < self.blockBudget();
    }

    /// True once every block handed to the callback has come back. Producer-side
    /// state only, so it never races the callback's private cursor.
    pub fn quiescent(self: *const ZoneRuntime) bool {
        return self.pool.free_len == block_count;
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
            .format = .{
                .sample_format = .float_32,
                .channels = format.channels,
                .sample_rate = format.sample_rate,
                .bits_per_sample = 32,
                .bytes_per_frame = try std.math.mul(u16, format.channels, 4),
            },
            .policy = self.zone.policy,
            // Orca's own render-ahead is the Zone budget; the device is asked
            // for one block so the two do not compound into a large latency.
            .requested_latency_frames = frames_per_block,
        };
        self.output = try factory.open(request, Context.callback, self.context.userdata());
    }

    /// Engine thread, or the control lane once the Zone is unpublished.
    pub fn closeOutput(self: *ZoneRuntime) void {
        if (self.output) |active| {
            active.close();
            self.output = null;
        }
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
}

test "closing an output lets a Zone reclaim every prepared block" {
    var runtime_zone = try ZoneRuntime.create(std.testing.allocator);
    defer runtime_zone.destroy();
    runtime_zone.channels = 1;
    runtime_zone.context.channels = 1;

    const sink = runtime_zone.sink(1);
    var samples: [frames_per_block]f32 = @splat(0.5);
    try std.testing.expect(sink.submitCopy(&samples, frames_per_block, 3, 1));
    try std.testing.expect(!runtime_zone.quiescent());

    runtime_zone.resetPipe();
    try std.testing.expect(runtime_zone.quiescent());
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
