const std = @import("std");
const buffer = @import("buffer.zig");
const spsc = @import("spsc.zig");

pub const ReadyBlock = struct {
    index: u32,
    frames: u32,
    generation: u64,
};

pub fn RenderPipe(comptime capacity: usize) type {
    return struct {
        ready: spsc.Queue(ReadyBlock, capacity) = .{},
        returned: spsc.Queue(u32, capacity) = .{},
        current: ?ReadyBlock = null,
        current_frame: u32 = 0,
        underruns: std.atomic.Value(u64) = .init(0),
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
            generation: u64,
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
                if (block.generation != generation) {
                    self.returnBlock(block.index);
                    self.current = null;
                    continue;
                }
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

test "render callback copies prepared PCM and underruns to silence" {
    var pool = try buffer.BlockPool.init(std.testing.allocator, 2, 4, 2);
    defer pool.deinit();
    var pipe: RenderPipe(2) = .{};
    const index = pool.acquire().?;
    @memset(pool.samples(index), 0.5);
    try std.testing.expect(pipe.submit(.{ .index = index, .frames = 4, .generation = 1 }));

    var output: [8]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 4), pipe.render(&pool, 2, 1, &output));
    for (output) |sample| try std.testing.expectEqual(@as(f32, 0.5), sample);
    pipe.reclaim(&pool);
    try std.testing.expectEqual(@as(usize, 2), pool.free_len);

    try std.testing.expectEqual(@as(usize, 0), pipe.render(&pool, 2, 1, &output));
    for (output) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    try std.testing.expectEqual(@as(u64, 1), pipe.underruns.load(.monotonic));
}

test "generation changes discard stale prepared audio" {
    var pool = try buffer.BlockPool.init(std.testing.allocator, 1, 2, 1);
    defer pool.deinit();
    var pipe: RenderPipe(1) = .{};
    const index = pool.acquire().?;
    @memset(pool.samples(index), 1);
    try std.testing.expect(pipe.submit(.{ .index = index, .frames = 2, .generation = 4 }));
    var output: [2]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), pipe.render(&pool, 1, 5, &output));
    try std.testing.expectEqualSlices(f32, &.{ 0, 0 }, &output);
    pipe.reclaim(&pool);
    try std.testing.expectEqual(@as(usize, 1), pool.free_len);
}
