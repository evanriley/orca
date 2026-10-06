const std = @import("std");

pub const BlockPool = struct {
    allocator: std.mem.Allocator,
    storage: []f32,
    free_indices: []u32,
    free_len: usize,
    samples_per_block: usize,
    /// Producer-side only; the render callback never reads it.
    processed: []bool,
    processed_held: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        block_count: u32,
        frames_per_block: u32,
        channels: u16,
    ) !BlockPool {
        if (block_count == 0 or frames_per_block == 0 or channels == 0) {
            return error.InvalidPoolSize;
        }
        const samples_per_block = try std.math.mul(usize, frames_per_block, channels);
        const sample_count = try std.math.mul(usize, block_count, samples_per_block);
        const storage = try allocator.alloc(f32, sample_count);
        errdefer allocator.free(storage);
        const free_indices = try allocator.alloc(u32, block_count);
        errdefer allocator.free(free_indices);
        for (free_indices, 0..) |*index, value| index.* = @intCast(value);
        const processed = try allocator.alloc(bool, block_count);
        @memset(processed, false);
        return .{
            .allocator = allocator,
            .storage = storage,
            .free_indices = free_indices,
            .free_len = block_count,
            .samples_per_block = samples_per_block,
            .processed = processed,
        };
    }

    pub fn deinit(self: *BlockPool) void {
        self.allocator.free(self.processed);
        self.allocator.free(self.free_indices);
        self.allocator.free(self.storage);
        self.* = undefined;
    }

    /// Producer-side only. No allocation occurs after pool initialization.
    pub fn acquire(self: *BlockPool) ?u32 {
        if (self.free_len == 0) return null;
        self.free_len -= 1;
        return self.free_indices[self.free_len];
    }

    /// Producer-side only; callback returns arrive through `RenderPipe`.
    pub fn release(self: *BlockPool, index: u32) void {
        std.debug.assert(index < self.free_indices.len);
        std.debug.assert(self.free_len < self.free_indices.len);
        self.free_indices[self.free_len] = index;
        self.free_len += 1;
        if (self.processed[index]) {
            self.processed[index] = false;
            self.processed_held -= 1;
        }
    }

    /// Producer-side only.
    pub fn markProcessed(self: *BlockPool, index: u32) void {
        if (self.processed[index]) return;
        self.processed[index] = true;
        self.processed_held += 1;
    }

    /// Producer-side only.
    pub fn holdsProcessed(self: *const BlockPool) bool {
        return self.processed_held != 0;
    }

    pub fn samples(self: *BlockPool, index: u32) []f32 {
        const start = @as(usize, index) * self.samples_per_block;
        return self.storage[start .. start + self.samples_per_block];
    }

    pub fn samplesConst(self: *const BlockPool, index: u32) []const f32 {
        const start = @as(usize, index) * self.samples_per_block;
        return self.storage[start .. start + self.samples_per_block];
    }
};

test "a processed block is held until it is released" {
    var pool = try BlockPool.init(std.testing.allocator, 2, 4, 1);
    defer pool.deinit();
    const plain = pool.acquire().?;
    const processed = pool.acquire().?;
    pool.markProcessed(processed);
    pool.markProcessed(processed);
    try std.testing.expect(pool.holdsProcessed());
    pool.release(plain);
    try std.testing.expect(pool.holdsProcessed());
    pool.release(processed);
    try std.testing.expect(!pool.holdsProcessed());
    try std.testing.expect(!pool.processed[pool.acquire().?]);
}
