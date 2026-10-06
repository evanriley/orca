const buffer = @import("buffer.zig");
const processing = @import("processing.zig");
const render = @import("render.zig");
const zone = @import("zone.zig");

/// Producer-side destination for one independently buffered Zone. A Player's
/// canonical PCM is copied so every Zone owns its callback lifetime and
/// backpressure; one full Zone never blocks another.
pub fn ZoneSink(comptime capacity: usize) type {
    return struct {
        pool: *buffer.BlockPool,
        pipe: *render.RenderPipe(capacity),
        channels: u16,
        zone_processor: ?processing.Processor = null,
        max_queued_blocks: usize = capacity,

        const Self = @This();

        pub fn init(
            pool: *buffer.BlockPool,
            pipe: *render.RenderPipe(capacity),
            channels: u16,
            strategy: zone.RenderStrategy,
        ) Self {
            const frames_per_block: u32 = @intCast(pool.samples_per_block / channels);
            return .{
                .pool = pool,
                .pipe = pipe,
                .channels = channels,
                .max_queued_blocks = strategy.blockBudget(frames_per_block, capacity),
            };
        }

        pub fn submitCopy(
            self: Self,
            samples: []const f32,
            frames: u32,
            epoch: u32,
            entry_serial: u32,
            successor: render.Successor,
            processed: bool,
        ) bool {
            self.pipe.reclaim(self.pool);
            if (self.pipe.ready.len() >= self.max_queued_blocks) return false;
            const sample_count = @as(usize, frames) * self.channels;
            if (sample_count != samples.len or sample_count > self.pool.samples_per_block)
                return false;
            const index = self.pool.acquire() orelse return false;
            const destination = self.pool.samples(index)[0..sample_count];
            @memcpy(destination, samples);
            var changed = processed;
            if (self.zone_processor) |processor| {
                processor.process(destination, frames, self.channels);
                changed = changed or processor.changedSamples();
            }
            if (changed) self.pool.markProcessed(index);
            if (!self.pipe.submit(.{
                .index = index,
                .frames = frames,
                .epoch = epoch,
                .entry_serial = entry_serial,
                .successor = successor,
            })) {
                self.pool.release(index);
                return false;
            }
            return true;
        }
    };
}

pub fn submit(
    comptime capacity: usize,
    sinks: []ZoneSink(capacity),
    samples: []const f32,
    frames: u32,
    epoch: u32,
    entry_serial: u32,
    successor: render.Successor,
    processed: bool,
) usize {
    var accepted: usize = 0;
    for (sinks) |sink| {
        if (sink.submitCopy(samples, frames, epoch, entry_serial, successor, processed)) accepted += 1;
    }
    return accepted;
}

test "full Zone does not prevent fanout to another Zone" {
    const std = @import("std");
    var full_pool = try buffer.BlockPool.init(std.testing.allocator, 1, 2, 1);
    defer full_pool.deinit();
    var healthy_pool = try buffer.BlockPool.init(std.testing.allocator, 1, 2, 1);
    defer healthy_pool.deinit();
    var full_pipe: render.RenderPipe(1) = .{};
    var healthy_pipe: render.RenderPipe(1) = .{};
    const FullSink = ZoneSink(1);
    const full: FullSink = .{ .pool = &full_pool, .pipe = &full_pipe, .channels = 1 };
    const healthy: FullSink = .{ .pool = &healthy_pool, .pipe = &healthy_pipe, .channels = 1 };
    try std.testing.expect(full.submitCopy(&.{ 0.1, 0.2 }, 2, 4, 1, .{}, false));

    var sinks = [_]FullSink{ full, healthy };
    try std.testing.expectEqual(@as(usize, 1), submit(1, &sinks, &.{ 0.5, 0.75 }, 2, 4, 1, .{}, false));
    var output: [2]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), healthy_pipe.render(&healthy_pool, 1, 4, &output));
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.75 }, &output);
}

test "Zone strategy bounds independent render-ahead depth" {
    const std = @import("std");
    var pool = try buffer.BlockPool.init(std.testing.allocator, 4, 2, 1);
    defer pool.deinit();
    var pipe: render.RenderPipe(4) = .{};
    const Sink = ZoneSink(4);
    const sink = Sink.init(&pool, &pipe, 1, .direct_rt);
    try std.testing.expect(sink.submitCopy(&.{ 0, 0 }, 2, 1, 1, .{}, false));
    try std.testing.expect(!sink.submitCopy(&.{ 1, 1 }, 2, 1, 1, .{}, false));
    try std.testing.expectEqual(@as(usize, 1), pipe.ready.len());
}

test "a processed copy stays marked in its Zone's pool until the pool has it back" {
    const std = @import("std");
    var pool = try buffer.BlockPool.init(std.testing.allocator, 3, 2, 1);
    defer pool.deinit();
    var pipe: render.RenderPipe(4) = .{};
    var gain: processing.Gain = .{};
    gain.setLinear(0.5, 0);
    const Sink = ZoneSink(4);
    const plain: Sink = .{ .pool = &pool, .pipe = &pipe, .channels = 1 };
    try std.testing.expect(plain.submitCopy(&.{ 1, 1 }, 2, 1, 1, .{}, false));
    try std.testing.expect(!pool.holdsProcessed());
    var with_gain = plain;
    with_gain.zone_processor = gain.processor();
    try std.testing.expect(with_gain.submitCopy(&.{ 1, 1 }, 2, 1, 1, .{}, false));
    try std.testing.expect(pool.holdsProcessed());

    var output: [2]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), pipe.render(&pool, 1, 1, &output));
    pipe.reclaim(&pool);
    try std.testing.expect(pool.holdsProcessed());
    try std.testing.expectEqual(@as(usize, 2), pipe.render(&pool, 1, 1, &output));
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.5 }, &output);
    try std.testing.expect(pool.holdsProcessed());
    pipe.reclaim(&pool);
    try std.testing.expect(!pool.holdsProcessed());

    try std.testing.expect(plain.submitCopy(&.{ 1, 1 }, 2, 1, 1, .{}, true));
    try std.testing.expect(pool.holdsProcessed());
}
