const std = @import("std");

pub const BlockConstraint = union(enum) {
    any,
    preferred: u32,
    fixed: u32,
};

pub const Metadata = struct {
    name: []const u8,
    changes_samples: bool,
    changes_sample_rate: bool = false,
    changes_channel_layout: bool = false,
    algorithmic_latency_frames: u32 = 0,
    lookahead_frames: u32 = 0,
    tail_frames: u32 = 0,
    block_constraint: BlockConstraint = .any,
    realtime_safe: bool,
};

/// RT-callable, non-owning processing boundary. Implementations must not
/// allocate, lock, wait, perform I/O, or retain the sample slice.
pub const Processor = struct {
    context: *anyopaque,
    process_fn: *const fn (*anyopaque, []f32, u32, u16) void,
    reset_fn: ?*const fn (*anyopaque) void = null,
    metadata: Metadata,

    pub fn process(self: Processor, samples: []f32, frames: u32, channels: u16) void {
        self.process_fn(self.context, samples, frames, channels);
    }

    pub fn reset(self: Processor) void {
        if (self.reset_fn) |reset_fn| reset_fn(self.context);
    }
};

pub const Summary = struct {
    node_count: usize = 0,
    changes_samples: bool = false,
    changes_sample_rate: bool = false,
    changes_channel_layout: bool = false,
    algorithmic_latency_frames: u32 = 0,
    lookahead_frames: u32 = 0,
    tail_frames: u32 = 0,
    realtime_safe: bool = true,
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
            const chain_summary = self.summary();
            return .{
                .context = self,
                .process_fn = process,
                .reset_fn = reset,
                .metadata = .{
                    .name = "ordered chain",
                    .changes_samples = chain_summary.changes_samples,
                    .changes_sample_rate = chain_summary.changes_sample_rate,
                    .changes_channel_layout = chain_summary.changes_channel_layout,
                    .algorithmic_latency_frames = chain_summary.algorithmic_latency_frames,
                    .lookahead_frames = chain_summary.lookahead_frames,
                    .tail_frames = chain_summary.tail_frames,
                    .realtime_safe = chain_summary.realtime_safe,
                },
            };
        }

        pub fn summary(self: *const Self) Summary {
            var result: Summary = .{ .node_count = self.len };
            for (self.processors[0..self.len]) |entry| {
                result.changes_samples = result.changes_samples or entry.metadata.changes_samples;
                result.changes_sample_rate = result.changes_sample_rate or
                    entry.metadata.changes_sample_rate;
                result.changes_channel_layout = result.changes_channel_layout or
                    entry.metadata.changes_channel_layout;
                result.algorithmic_latency_frames +|= entry.metadata.algorithmic_latency_frames;
                result.lookahead_frames = @max(result.lookahead_frames, entry.metadata.lookahead_frames);
                result.tail_frames = @max(result.tail_frames, entry.metadata.tail_frames);
                result.realtime_safe = result.realtime_safe and entry.metadata.realtime_safe;
            }
            return result;
        }

        fn process(context: *anyopaque, samples: []f32, frames: u32, channels: u16) void {
            const self: *Self = @ptrCast(@alignCast(context));
            for (self.processors[0..self.len]) |entry| entry.process(samples, frames, channels);
        }

        fn reset(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            for (self.processors[0..self.len]) |entry| entry.reset();
        }
    };
}

pub const Gain = struct {
    linear: std.atomic.Value(f32) = .init(1),

    pub fn processor(self: *Gain) Processor {
        return .{
            .context = self,
            .process_fn = process,
            .metadata = .{
                .name = "gain",
                .changes_samples = true,
                .realtime_safe = true,
            },
        };
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
    const summary = chain.summary();
    try std.testing.expectEqual(@as(usize, 2), summary.node_count);
    try std.testing.expect(summary.changes_samples);
    try std.testing.expect(summary.realtime_safe);
}
