const std = @import("std");
const kernels = @import("kernels.zig");

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

/// How a Player chooses the loudness correction for the entry it loads.
///
/// Album-level ReplayGain is deliberately not a third value here. An album
/// gain is one figure measured across a whole release, which needs both a
/// release-scoped measurement `analysis/` does not compute and a notion of
/// "the release this queue entry belongs to" the playback queue does not
/// carry. Adding the name without either would apply track gain under an
/// album label, which is worse than not offering it.
pub const ReplayGainMode = enum(u8) {
    /// No correction at all. Every entry plays at the volume the user set.
    off,
    /// Each entry is corrected by its own measured loudness, if the Library
    /// holds one that still describes the file.
    track,
};

/// The linear multiplier a stored ReplayGain figure asks for.
///
/// `peak` is the entry's measured sample peak. Boosting a track whose peak is
/// already near full scale would clip it, so the gain is capped at `1 / peak`:
/// quiet tracks come up only as far as their headroom allows. That is a
/// deliberate quietening of the correction rather than a limiter, because a
/// limiter would change the audio rather than its level.
pub fn replayGainMultiplier(decibels: f32, peak: ?f32) f32 {
    var linear = std.math.pow(f32, 10, decibels / 20);
    if (peak) |value| {
        if (value > 0) linear = @min(linear, 1 / value);
    }
    return linear;
}

/// User volume, as one ramped multiplier applied to canonical PCM.
///
/// Loudness correction deliberately does **not** live here. It was a second
/// input to this node, multiplied into `linear` when the control lane loaded a
/// queue entry — which cannot be right during a gapless transition, because the
/// pipe then holds prepared blocks belonging to two entries at once and this is
/// one value for the whole Player. The correction is a property of the audio,
/// so it is applied by the `SourceSession` that decodes that audio and travels
/// with it; see `source_session.SourceSession.replay_gain`. What is left here
/// is what a host's volume control means, and nothing else can discard it.
pub const Gain = struct {
    /// The multiplier the render path applies. Ramped toward on a change.
    linear: std.atomic.Value(f32) = .init(1),
    ramp_frames: std.atomic.Value(u32) = .init(0),
    command_generation: std.atomic.Value(u64) = .init(0),
    current: f32 = 1,
    initialized: bool = false,
    remaining_frames: u32 = 0,
    step: f32 = 0,
    seen_generation: u64 = 0,

    pub fn setLinear(self: *Gain, linear: f32, ramp_frames: u32) void {
        self.linear.store(linear, .release);
        self.ramp_frames.store(ramp_frames, .release);
        _ = self.command_generation.fetchAdd(1, .release);
    }

    /// The multiplier applied to the last frame processed. Call it only from
    /// the engine lane, or while the engine is quiesced.
    pub fn applied(self: *const Gain) f32 {
        return if (self.initialized) self.current else self.linear.load(.acquire);
    }

    pub fn processor(self: *Gain) Processor {
        if (!self.initialized) {
            self.current = self.linear.load(.monotonic);
            self.seen_generation = self.command_generation.load(.monotonic);
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
        const generation = self.command_generation.load(.acquire);
        const target = self.linear.load(.monotonic);
        if (!self.initialized) {
            self.current = target;
            self.initialized = true;
        }
        if (generation != self.seen_generation) {
            const requested_ramp = self.ramp_frames.load(.monotonic);
            self.seen_generation = generation;
            if (requested_ramp > 0) {
                self.remaining_frames = requested_ramp;
                self.step = (target - self.current) / @as(f32, @floatFromInt(requested_ramp));
            } else {
                self.remaining_frames = 0;
                self.current = target;
            }
        }
        if (self.remaining_frames == 0) {
            kernels.gain(samples[0 .. @as(usize, frames) * channels], self.current);
            return;
        }
        for (0..frames) |frame| {
            if (self.remaining_frames > 0) {
                self.remaining_frames -= 1;
                self.current = if (self.remaining_frames == 0) target else self.current + self.step;
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
        const levels = kernels.levelsVector(samples);
        self.peak.store(levels.peak, .release);
        self.rms.store(if (samples.len == 0) 0 else @floatCast(@sqrt(levels.square_sum /
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

    gain.setLinear(1, 0);
    var interrupted = [_]f32{1};
    chain.processor().process(&interrupted, 1, 1);
    try std.testing.expectEqual(@as(f32, 1), interrupted[0]);
}

test "a volume change is the only thing that moves the gain node" {
    // Loudness correction travels with the audio (see `SourceSession`), so
    // this node has exactly one input.
    var gain: Gain = .{};
    gain.setLinear(0.5, 0);
    try std.testing.expectEqual(@as(f32, 0.5), gain.linear.load(.acquire));

    var samples = [_]f32{ 1, 1 };
    gain.processor().process(&samples, 2, 1);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.5 }, &samples);

    gain.setLinear(1, 0);
    try std.testing.expectEqual(@as(f32, 1), gain.linear.load(.acquire));
}

test "a ramp ending on a block boundary lands exactly on its target" {
    var gain: Gain = .{};
    gain.setLinear(0.73, 0);
    var block: [256 * 2]f32 = @splat(1);
    gain.processor().process(&block, 256, 2);

    gain.setLinear(1, 512);
    for (0..2) |_| {
        block = @splat(1);
        gain.processor().process(&block, 256, 2);
    }
    try std.testing.expectEqual(@as(f32, 1), gain.current);
    try std.testing.expectEqual(@as(f32, 1), gain.applied());

    var samples: [256 * 2]f32 = undefined;
    for (&samples, 0..) |*sample, index| sample.* = @as(f32, @floatFromInt(index)) / 512 - 0.5;
    const original = samples;
    gain.processor().process(&samples, 256, 2);
    try std.testing.expectEqualSlices(f32, &original, &samples);
}

test "a boost is capped by the peak it would clip" {
    // +6 dB on a track already peaking at 0.9 would drive it to 1.8. The gain
    // is capped at 1/peak instead, so the correction is quietened rather than
    // the audio being clipped or limited on the way out.
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0 / 0.9),
        replayGainMultiplier(6, 0.9),
        0.0001,
    );

    // With headroom to spare the full correction applies.
    try std.testing.expectApproxEqAbs(@as(f32, 1.9953), replayGainMultiplier(6, 0.2), 0.001);

    // An attenuation is never capped: it cannot clip, and a measurement with
    // no peak beside it has nothing to cap against.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5012), replayGainMultiplier(-6, 0.9), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.9953), replayGainMultiplier(6, null), 0.001);
    try std.testing.expectEqual(@as(f32, 1), replayGainMultiplier(0, null));
}
