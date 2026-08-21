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
    ramp_frames: std.atomic.Value(u32) = .init(0),
    current: f32 = 1,
    initialized: bool = false,
    remaining_frames: u32 = 0,
    step: f32 = 0,

    pub fn setLinear(self: *Gain, linear: f32, ramp_frames: u32) void {
        self.linear.store(linear, .release);
        self.ramp_frames.store(ramp_frames, .release);
    }

    pub fn setReplayGain(self: *Gain, decibels: f32, peak: ?f32, ramp_frames: u32) void {
        var linear = std.math.pow(f32, 10, decibels / 20);
        if (peak) |value| {
            if (value > 0) linear = @min(linear, 1 / value);
        }
        self.setLinear(linear, ramp_frames);
    }

    pub fn processor(self: *Gain) Processor {
        if (!self.initialized) {
            self.current = self.linear.load(.monotonic);
            self.initialized = true;
        }
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

    fn process(context: *anyopaque, samples: []f32, frames: u32, channels: u16) void {
        const self: *Gain = @ptrCast(@alignCast(context));
        const target = self.linear.load(.acquire);
        if (!self.initialized) {
            self.current = target;
            self.initialized = true;
        }
        const requested_ramp = self.ramp_frames.swap(0, .acq_rel);
        if (requested_ramp > 0) {
            self.remaining_frames = requested_ramp;
            self.step = (target - self.current) / @as(f32, @floatFromInt(requested_ramp));
        } else if (self.remaining_frames == 0) {
            self.current = target;
        }
        for (0..frames) |frame| {
            if (self.remaining_frames > 0) {
                self.current += self.step;
                self.remaining_frames -= 1;
            } else {
                self.current = target;
            }
            const start = frame * channels;
            for (samples[start .. start + channels]) |*sample| sample.* *= self.current;
        }
    }
};

pub const Meter = struct {
    peak: std.atomic.Value(f32) = .init(0),
    rms: std.atomic.Value(f32) = .init(0),

    pub const Snapshot = struct { peak: f32, rms: f32 };

    pub fn processor(self: *Meter) Processor {
        return .{
            .context = self,
            .process_fn = process,
            .metadata = .{
                .name = "peak/RMS meter",
                .changes_samples = false,
                .realtime_safe = true,
            },
        };
    }

    pub fn snapshot(self: *const Meter) Snapshot {
        return .{ .peak = self.peak.load(.acquire), .rms = self.rms.load(.acquire) };
    }

    fn process(context: *anyopaque, samples: []f32, _: u32, _: u16) void {
        const self: *Meter = @ptrCast(@alignCast(context));
        var peak: f32 = 0;
        var squares: f64 = 0;
        for (samples) |sample| {
            peak = @max(peak, @abs(sample));
            squares += @as(f64, sample) * sample;
        }
        self.peak.store(peak, .release);
        self.rms.store(if (samples.len == 0) 0 else @floatCast(@sqrt(squares /
            @as(f64, @floatFromInt(samples.len)))), .release);
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

test "gain ramps without discontinuity and meter does not change samples" {
    var gain: Gain = .{};
    var meter: Meter = .{};
    var chain: Chain(2) = .{};
    try chain.append(gain.processor());
    try chain.append(meter.processor());
    gain.setLinear(0, 4);
    var samples = [_]f32{ 1, 1, 1, 1 };
    chain.processor().process(&samples, 4, 1);
    try std.testing.expectEqualSlices(f32, &.{ 0.75, 0.5, 0.25, 0 }, &samples);
    const levels = meter.snapshot();
    try std.testing.expectEqual(@as(f32, 0.75), levels.peak);
    try std.testing.expectApproxEqAbs(@as(f32, 0.467_707), levels.rms, 0.000_001);
}
