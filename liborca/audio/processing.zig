const std = @import("std");

/// RT-callable, non-owning processing boundary. Implementations must not
/// allocate, lock, wait, perform I/O, or retain the sample slice.
pub const Processor = struct {
    context: *anyopaque,
    process_fn: *const fn (*anyopaque, []f32, u32, u16) void,

    pub fn process(self: Processor, samples: []f32, frames: u32, channels: u16) void {
        self.process_fn(self.context, samples, frames, channels);
    }
};

pub fn Chain(comptime capacity: usize) type {
    return struct {
        processors: [capacity]Processor = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn append(self: *Self, entry: Processor) !void {
            if (self.len == capacity) return error.ProcessingChainFull;
            self.processors[self.len] = entry;
            self.len += 1;
        }

        pub fn processor(self: *Self) Processor {
            return .{ .context = self, .process_fn = process };
        }

        fn process(context: *anyopaque, samples: []f32, frames: u32, channels: u16) void {
            const self: *Self = @ptrCast(@alignCast(context));
            for (self.processors[0..self.len]) |entry| entry.process(samples, frames, channels);
        }
    };
}

pub const Gain = struct {
    linear: std.atomic.Value(f32) = .init(1),

    pub fn processor(self: *Gain) Processor {
        return .{ .context = self, .process_fn = process };
    }

    fn process(context: *anyopaque, samples: []f32, _: u32, _: u16) void {
        const self: *Gain = @ptrCast(@alignCast(context));
        const linear = self.linear.load(.monotonic);
        for (samples) |*sample| sample.* *= linear;
    }
};

test "fixed processing chain runs in insertion order" {
    var first: Gain = .{ .linear = .init(0.5) };
    var second: Gain = .{ .linear = .init(0.25) };
    var chain: Chain(2) = .{};
    try chain.append(first.processor());
    try chain.append(second.processor());
    var samples = [_]f32{ 1, -1 };
    chain.processor().process(&samples, 2, 1);
    try std.testing.expectEqualSlices(f32, &.{ 0.125, -0.125 }, &samples);
}
