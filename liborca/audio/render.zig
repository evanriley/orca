const std = @import("std");
const buffer = @import("buffer.zig");
const spsc = @import("spsc.zig");

/// One prepared block handed to the render callback.
///
/// `epoch` and `entry_serial` answer two different questions and must never be
/// collapsed back into one field:
///
/// * `epoch` — "is this audio still wanted?" It is **compared** by the callback
///   and bumped by seek, stop and hard skip, so blocks prepared before a
///   transport discontinuity are discarded without queue surgery.
/// * `entry_serial` — "which queue entry did this come from?" It is **never**
///   compared, because gapless transitions deliberately append the successor
///   track's blocks under the same `epoch`. The callback publishes it so the
///   control lane can report accurate now-playing even though the decode cursor
///   leads the render cursor by the whole render-ahead depth.
pub const ReadyBlock = struct {
    index: u32,
    frames: u32,
    epoch: u32,
    entry_serial: u32 = 0,
};

pub fn RenderPipe(comptime capacity: usize) type {
    return struct {
        ready: spsc.Queue(ReadyBlock, capacity) = .{},
        returned: spsc.Queue(u32, capacity) = .{},
        current: ?ReadyBlock = null,
        current_frame: u32 = 0,
        underruns: std.atomic.Value(u64) = .init(0),
        /// `entry_serial` of the block most recently rendered from. Published
        /// by the callback, read by the control lane; never compared here.
        rendered_entry_serial: std.atomic.Value(u32) = .init(0),
        dropped_returns: std.atomic.Value(u64) = .init(0),
        invalid_blocks: std.atomic.Value(u64) = .init(0),

        const Self = @This();

        pub fn submit(self: *Self, block: ReadyBlock) bool {
            return self.ready.push(block);
        }

        pub fn reclaim(self: *Self, pool: *buffer.BlockPool) void {
            while (self.returned.pop()) |index| pool.release(index);
        }

        /// Hard-callback operation: no allocation, locks, I/O, or waiting.
        pub fn render(
            self: *Self,
            pool: *const buffer.BlockPool,
            channels: u16,
            epoch: u32,
            output: []f32,
        ) usize {
            @memset(output, 0);
            if (channels == 0 or output.len % channels != 0) return 0;
            var output_frame: usize = 0;
            const requested_frames = output.len / channels;
            while (output_frame < requested_frames) {
                if (self.current == null) {
                    self.current = self.ready.pop();
                    self.current_frame = 0;
                    if (self.current == null) break;
                }
                const block = self.current.?;
                const block_capacity = pool.samples_per_block / channels;
                if (block.frames > block_capacity) {
                    _ = self.invalid_blocks.fetchAdd(1, .monotonic);
                    self.returnBlock(block.index);
                    self.current = null;
                    continue;
                }
                if (block.epoch != epoch) {
                    self.returnBlock(block.index);
                    self.current = null;
                    continue;
                }
                self.rendered_entry_serial.store(block.entry_serial, .monotonic);
                const available = block.frames - self.current_frame;
                const take: usize = @min(available, requested_frames - output_frame);
                const source_start = @as(usize, self.current_frame) * channels;
                const destination_start = output_frame * channels;
                @memcpy(
                    output[destination_start .. destination_start + take * channels],
                    pool.samplesConst(block.index)[source_start .. source_start + take * channels],
                );
                output_frame += take;
                self.current_frame += @intCast(take);
                if (self.current_frame == block.frames) {
                    self.returnBlock(block.index);
                    self.current = null;
                }
            }
            if (output_frame < requested_frames) _ = self.underruns.fetchAdd(1, .monotonic);
            return output_frame;
        }

        fn returnBlock(self: *Self, index: u32) void {
            if (!self.returned.push(index)) _ = self.dropped_returns.fetchAdd(1, .monotonic);
        }
    };
}

/// Bits reserved for frames-since-epoch inside a packed position sample.
/// 48 bits is roughly 180 years at 48 kHz, so it never wraps in practice.
pub const position_frame_bits = 48;
pub const position_frame_mask: u64 = (@as(u64, 1) << position_frame_bits) - 1;

/// Rendered position is published as **one** `u64` so the control lane can never
/// observe a frame count from one epoch paired with another epoch's identity.
/// High 16 bits are `epoch & 0xffff`; the low 48 are frames rendered since that
/// epoch. The callback writes it with a single store and the control lane reads
/// it with a single load, discarding any sample whose epoch does not match the
/// one it is asking about. Wait-free: no seqlock, no `u128`, no retry.
pub fn packPosition(epoch: u32, frames: u64) u64 {
    const stamp: u64 = @as(u16, @truncate(epoch));
    return (stamp << position_frame_bits) | (frames & position_frame_mask);
}

pub fn positionEpoch(sample: u64) u16 {
    return @truncate(sample >> position_frame_bits);
}

pub fn positionFrames(sample: u64) u64 {
    return sample & position_frame_mask;
}

/// Typed context connecting a backend's real-time callback to Orca's wait-free
/// render pipe.
///
/// Every pointer here must be owned by the **Zone**, never by the Player: an
/// output session can outlive a Player detach, and the real-time thread has no
/// way to re-resolve a generational handle. The producer publishes the Player's
/// epoch into the Zone-owned `epoch` atomic immediately before submitting blocks
/// under it, so the callback only ever dereferences Zone memory.
pub fn RenderContext(comptime capacity: usize) type {
    return struct {
        pool: *const buffer.BlockPool,
        pipe: *RenderPipe(capacity),
        /// Transport epoch. Blocks prepared under a different epoch are stale
        /// and discarded; track identity is not carried here.
        epoch: *const std.atomic.Value(u32),
        channels: u16,
        /// When set, the callback emits silence. One atomic load plus a memset
        /// — no locks, allocation or I/O, so it stays within the RT rules.
        silenced: ?*const std.atomic.Value(bool) = null,
        /// Packed epoch + frames-since-epoch; see `packPosition`.
        position: ?*std.atomic.Value(u64) = null,
        /// Receives the `entry_serial` of the block the callback last rendered
        /// from, so the control lane can report accurate now-playing while the
        /// decode cursor leads the render cursor.
        rendered_entry_serial: ?*std.atomic.Value(u32) = null,
        format_mismatches: std.atomic.Value(u64) = .init(0),
        silenced_callbacks: std.atomic.Value(u64) = .init(0),

        const Self = @This();

        pub fn callback(
            opaque_context: ?*anyopaque,
            samples: [*]f32,
            frames: u32,
            channels: u32,
        ) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(opaque_context.?));
            const output = samples[0 .. frames * channels];
            if (channels != self.channels) {
                @memset(output, 0);
                _ = self.format_mismatches.fetchAdd(1, .monotonic);
                return;
            }
            if (self.silenced) |silenced| {
                if (silenced.load(.acquire)) {
                    // Paused or stopped: emit silence, keep every prepared block
                    // queued, do not advance position, and do not count an
                    // underrun — nothing was missing, nothing was wanted.
                    @memset(output, 0);
                    _ = self.silenced_callbacks.fetchAdd(1, .monotonic);
                    return;
                }
            }
            const epoch = self.epoch.load(.monotonic);
            const rendered = self.pipe.render(self.pool, self.channels, epoch, output);
            if (self.position) |position| {
                const previous = position.load(.monotonic);
                const base: u64 = if (positionEpoch(previous) == @as(u16, @truncate(epoch)))
                    positionFrames(previous)
                else
                    0;
                position.store(packPosition(epoch, base + rendered), .monotonic);
            }
            if (self.rendered_entry_serial) |serial|
                serial.store(self.pipe.rendered_entry_serial.load(.monotonic), .monotonic);
        }

        pub fn userdata(self: *Self) *anyopaque {
            return @ptrCast(self);
        }
    };
}

test "a packed position sample never mixes epochs with frame counts" {
    const sample = packPosition(0x1_0007, 12_345);
    try std.testing.expectEqual(@as(u16, 7), positionEpoch(sample));
    try std.testing.expectEqual(@as(u64, 12_345), positionFrames(sample));
    // The control lane discards a sample stamped with a different epoch rather
    // than reporting frames that belong to audio it already retired.
    try std.testing.expect(positionEpoch(sample) != @as(u16, @truncate(@as(u32, 8))));
}

test "render callback copies prepared PCM and underruns to silence" {
    var pool = try buffer.BlockPool.init(std.testing.allocator, 2, 4, 2);
    defer pool.deinit();
    var pipe: RenderPipe(2) = .{};
    const index = pool.acquire().?;
    @memset(pool.samples(index), 0.5);
    try std.testing.expect(pipe.submit(.{ .index = index, .frames = 4, .epoch = 1 }));

    var output: [8]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 4), pipe.render(&pool, 2, 1, &output));
    for (output) |sample| try std.testing.expectEqual(@as(f32, 0.5), sample);
    pipe.reclaim(&pool);
    try std.testing.expectEqual(@as(usize, 2), pool.free_len);

    try std.testing.expectEqual(@as(usize, 0), pipe.render(&pool, 2, 1, &output));
    for (output) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    try std.testing.expectEqual(@as(u64, 1), pipe.underruns.load(.monotonic));
}

test "a new epoch discards stale prepared audio" {
    var pool = try buffer.BlockPool.init(std.testing.allocator, 1, 2, 1);
    defer pool.deinit();
    var pipe: RenderPipe(1) = .{};
    const index = pool.acquire().?;
    @memset(pool.samples(index), 1);
    try std.testing.expect(pipe.submit(.{ .index = index, .frames = 2, .epoch = 4 }));
    var output: [2]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), pipe.render(&pool, 1, 5, &output));
    try std.testing.expectEqualSlices(f32, &.{ 0, 0 }, &output);
    pipe.reclaim(&pool);
    try std.testing.expectEqual(@as(usize, 1), pool.free_len);
}

test "blocks from different queue entries render under a single epoch" {
    var pool = try buffer.BlockPool.init(std.testing.allocator, 2, 2, 1);
    defer pool.deinit();
    var pipe: RenderPipe(2) = .{};
    const first = pool.acquire().?;
    @memset(pool.samples(first), 0.25);
    const second = pool.acquire().?;
    @memset(pool.samples(second), 0.5);
    // A gapless transition: same epoch, successive queue entries.
    try std.testing.expect(pipe.submit(.{
        .index = first,
        .frames = 2,
        .epoch = 3,
        .entry_serial = 7,
    }));
    try std.testing.expect(pipe.submit(.{
        .index = second,
        .frames = 2,
        .epoch = 3,
        .entry_serial = 8,
    }));

    var output: [2]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), pipe.render(&pool, 1, 3, &output));
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.25 }, &output);
    try std.testing.expectEqual(@as(u32, 7), pipe.rendered_entry_serial.load(.monotonic));

    try std.testing.expectEqual(@as(usize, 2), pipe.render(&pool, 1, 3, &output));
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.5 }, &output);
    try std.testing.expectEqual(@as(u32, 8), pipe.rendered_entry_serial.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), pipe.underruns.load(.monotonic));
}
