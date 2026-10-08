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
    successor: Successor = .{},

    fn serialAt(self: ReadyBlock, frame: u32) u32 {
        if (self.successor.serial != 0 and frame >= self.successor.frame) return self.successor.serial;
        return self.entry_serial;
    }

    fn entryEnd(self: ReadyBlock, frame: u32) u32 {
        if (self.successor.serial != 0 and frame < self.successor.frame) return self.successor.frame;
        return self.frames;
    }
};

pub const Successor = struct {
    /// Zero when every frame of the block belongs to one entry.
    serial: u32 = 0,
    frame: u32 = 0,
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
        /// Render-lane-private mirror of `rendered_entry_serial`. Only the
        /// callback writes the atomic, so a plain copy is exact and lets the
        /// entry boundary be detected without a second atomic load.
        published_entry_serial: u32 = 0,
        /// Set by `render` when the audible entry changed during that call, with
        /// the output-frame offset at which the new entry's first sample landed.
        /// The callback turns that offset into an absolute frames-since-epoch
        /// anchor; nothing else may read them.
        entry_started: bool = false,
        entry_start_offset: u32 = 0,

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
            self.entry_started = false;
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
                if (block.frames > block_capacity or block.successor.frame > block.frames) {
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
                const serial = block.serialAt(self.current_frame);
                if (serial != self.published_entry_serial) {
                    // The audible entry changed *here*, at this output frame.
                    // Position has to re-anchor to it: the epoch deliberately
                    // does not move across a gapless transition, so frames
                    // since the epoch keep counting through the whole queue.
                    self.published_entry_serial = serial;
                    self.rendered_entry_serial.store(serial, .monotonic);
                    self.entry_started = true;
                    self.entry_start_offset = @intCast(output_frame);
                }
                const available = block.entryEnd(self.current_frame) - self.current_frame;
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

/// Anchor of the entry currently being rendered, packed exactly like a position
/// sample so it is written and read with one store and one load.
///
/// The epoch is the wrong anchor for *per-entry* position: a gapless
/// auto-advance deliberately keeps one epoch, so frames-since-epoch runs
/// straight through the whole queue. The callback therefore also publishes the
/// frames-since-epoch value at which the audible entry started, stamped with the
/// low 16 bits of that entry's serial. The control lane pairs it with the full
/// serial from `rendered_entry_serial`: if the stamps disagree, the two came
/// from different moments and the sample is discarded, exactly as a mismatched
/// epoch is. Consecutive entries take consecutive serials, so a 16-bit stamp
/// cannot alias inside a torn read.
pub fn packEntryAnchor(serial: u32, frames: u64) u64 {
    const stamp: u64 = @as(u16, @truncate(serial));
    return (stamp << position_frame_bits) | (frames & position_frame_mask);
}

pub fn entryAnchorStamp(sample: u64) u16 {
    return @truncate(sample >> position_frame_bits);
}

pub fn entryAnchorFrames(sample: u64) u64 {
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
        /// Packed serial stamp + frames-since-epoch at which the audible entry
        /// started; see `packEntryAnchor`. This is what re-anchors position to
        /// the entry actually being heard.
        entry_anchor: ?*std.atomic.Value(u64) = null,
        format_mismatches: std.atomic.Value(u64) = .init(0),
        silenced_callbacks: std.atomic.Value(u64) = .init(0),
        callbacks: std.atomic.Value(u64) = .init(0),
        /// Callback-private timeline state. Only the render callback reads or
        /// writes these, and only while an output is open, so they need no
        /// synchronization: `published_position` is an exact mirror of what was
        /// last stored into `position`, and `entry_start_frames` is the absolute
        /// frames-since-epoch anchor mirrored into `entry_anchor`.
        published_position: u64 = 0,
        entry_start_frames: u64 = 0,

        const Self = @This();

        pub fn callback(
            opaque_context: ?*anyopaque,
            samples: [*]f32,
            frames: u32,
            channels: u32,
        ) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(opaque_context.?));
            _ = self.callbacks.fetchAdd(1, .monotonic);
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
            const same_epoch = positionEpoch(self.published_position) == @as(u16, @truncate(epoch));
            // A new epoch restarts the frame counter, so whatever entry is
            // audible under it starts from zero too. The seek base the control
            // lane stamped alongside the epoch supplies the offset inside that
            // entry.
            const base: u64 = if (same_epoch) positionFrames(self.published_position) else 0;
            if (!same_epoch) {
                self.entry_start_frames = 0;
                // The retired entry's serial must not be published under the
                // new epoch: the engine would adopt it over the hard load's.
                self.pipe.published_entry_serial = 0;
            }

            const rendered = self.pipe.render(self.pool, self.channels, epoch, output);
            if (self.pipe.entry_started)
                self.entry_start_frames = base + self.pipe.entry_start_offset;
            self.published_position = packPosition(epoch, base + rendered);

            // Publication order is load-bearing. The anchor and the serial are
            // written *before* the position, and the position is released last,
            // so a control lane that loads the position first and the other two
            // afterwards can only ever see an anchor at least as new as the
            // frame count it is subtracting from — which it detects as an
            // underflow and discards, rather than reporting a wrong position.
            const serial = self.pipe.published_entry_serial;
            if (self.entry_anchor) |anchor|
                anchor.store(packEntryAnchor(serial, self.entry_start_frames), .monotonic);
            if (self.rendered_entry_serial) |published|
                published.store(serial, .monotonic);
            if (self.position) |position| position.store(self.published_position, .release);
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

test "an entry anchor can never pair one entry's serial with another's frames" {
    const anchor = packEntryAnchor(0x2_0009, 96_000);
    try std.testing.expectEqual(@as(u16, 9), entryAnchorStamp(anchor));
    try std.testing.expectEqual(@as(u64, 96_000), entryAnchorFrames(anchor));
    // The control lane pairs the anchor with the full serial published beside
    // it. Consecutive entries take consecutive serials, so a stamp that does
    // not match the serial proves the two were read at different moments.
    try std.testing.expect(entryAnchorStamp(anchor) != @as(u16, @truncate(@as(u32, 10))));
}

test "the render pipe reports the frame at which a new queue entry became audible" {
    var pool = try buffer.BlockPool.init(std.testing.allocator, 2, 4, 1);
    defer pool.deinit();
    var pipe: RenderPipe(2) = .{};
    const first = pool.acquire().?;
    @memset(pool.samples(first), 0.25);
    const second = pool.acquire().?;
    @memset(pool.samples(second), 0.5);
    // One gapless epoch, two successive entries of four frames each.
    try std.testing.expect(pipe.submit(.{
        .index = first,
        .frames = 4,
        .epoch = 3,
        .entry_serial = 7,
    }));
    try std.testing.expect(pipe.submit(.{
        .index = second,
        .frames = 4,
        .epoch = 3,
        .entry_serial = 8,
    }));

    var output: [8]f32 = undefined;
    // A single callback that spans the boundary reports where it fell, so the
    // successor's position re-anchors mid-callback rather than at its edge.
    try std.testing.expectEqual(@as(usize, 8), pipe.render(&pool, 1, 3, &output));
    try std.testing.expect(pipe.entry_started);
    try std.testing.expectEqual(@as(u32, 4), pipe.entry_start_offset);
    try std.testing.expectEqual(@as(u32, 8), pipe.published_entry_serial);

    // A callback that stays inside one entry re-anchors nothing.
    pipe.reclaim(&pool);
    const third = pool.acquire().?;
    @memset(pool.samples(third), 0.75);
    try std.testing.expect(pipe.submit(.{
        .index = third,
        .frames = 4,
        .epoch = 3,
        .entry_serial = 8,
    }));
    try std.testing.expectEqual(@as(usize, 4), pipe.render(&pool, 1, 3, output[0..4]));
    try std.testing.expect(!pipe.entry_started);
}

test "a block holding a gapless boundary switches entry at the successor's first frame" {
    var pool = try buffer.BlockPool.init(std.testing.allocator, 2, 4, 1);
    defer pool.deinit();
    var pipe: RenderPipe(2) = .{};
    const index = pool.acquire().?;
    @memcpy(pool.samples(index), &[_]f32{ 0.25, 0.25, 0.25, 0.5 });
    try std.testing.expect(pipe.submit(.{
        .index = index,
        .frames = 4,
        .epoch = 3,
        .entry_serial = 7,
        .successor = .{ .serial = 8, .frame = 3 },
    }));

    var output: [2]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), pipe.render(&pool, 1, 3, &output));
    try std.testing.expectEqual(@as(u32, 7), pipe.rendered_entry_serial.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), pipe.entry_start_offset);

    try std.testing.expectEqual(@as(usize, 2), pipe.render(&pool, 1, 3, &output));
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.5 }, &output);
    try std.testing.expect(pipe.entry_started);
    try std.testing.expectEqual(@as(u32, 1), pipe.entry_start_offset);
    try std.testing.expectEqual(@as(u32, 8), pipe.rendered_entry_serial.load(.monotonic));
    pipe.reclaim(&pool);
    try std.testing.expectEqual(@as(usize, 2), pool.free_len);
}

test "a block whose successor starts past its end is rejected, not overrun" {
    var pool = try buffer.BlockPool.init(std.testing.allocator, 1, 4, 1);
    defer pool.deinit();
    var pipe: RenderPipe(1) = .{};
    const index = pool.acquire().?;
    @memset(pool.samples(index), 1);
    try std.testing.expect(pipe.submit(.{
        .index = index,
        .frames = 2,
        .epoch = 3,
        .entry_serial = 7,
        .successor = .{ .serial = 8, .frame = 3 },
    }));

    var output: [4]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), pipe.render(&pool, 1, 3, &output));
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &output);
    try std.testing.expectEqual(@as(u64, 1), pipe.invalid_blocks.load(.monotonic));
    pipe.reclaim(&pool);
    try std.testing.expectEqual(@as(usize, 1), pool.free_len);
}
