const buffer = @import("buffer.zig");
const render = @import("render.zig");

/// Producer-side destination for one independently buffered Zone. A Player's
/// canonical PCM is copied so every Zone owns its callback lifetime and
/// backpressure; one full Zone never blocks another.
pub fn ZoneSink(comptime capacity: usize) type {
    return struct {
        pool: *buffer.BlockPool,
        pipe: *render.RenderPipe(capacity),
        channels: u16,

        const Self = @This();

        pub fn submitCopy(
            self: Self,
            samples: []const f32,
            frames: u32,
            generation: u64,
        ) bool {
            self.pipe.reclaim(self.pool);
            const sample_count = @as(usize, frames) * self.channels;
            if (sample_count != samples.len or sample_count > self.pool.samples_per_block)
                return false;
            const index = self.pool.acquire() orelse return false;
            @memcpy(self.pool.samples(index)[0..sample_count], samples);
            if (!self.pipe.submit(.{
                .index = index,
                .frames = frames,
                .generation = generation,
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
    generation: u64,
) usize {
    var accepted: usize = 0;
    for (sinks) |sink| {
        if (sink.submitCopy(samples, frames, generation)) accepted += 1;
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
    try std.testing.expect(full.submitCopy(&.{ 0.1, 0.2 }, 2, 4));

    var sinks = [_]FullSink{ full, healthy };
    try std.testing.expectEqual(@as(usize, 1), submit(1, &sinks, &.{ 0.5, 0.75 }, 2, 4));
    var output: [2]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), healthy_pipe.render(&healthy_pool, 1, 4, &output));
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.75 }, &output);
}
