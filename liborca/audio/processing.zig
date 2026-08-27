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

/// The render lane's single multiplier, and the two independent things that
/// decide it.
///
/// User volume and replay gain are separate inputs deliberately. They were one
/// value, `linear`, which meant whichever was written last silently discarded
/// the other: applying replay gain would have moved the host's volume slider,
/// and the next volume change would have thrown the loudness correction away.
/// The render lane still reads exactly one number, `linear`, which is their
/// product, so nothing in the real-time path pays for the distinction.
pub const Gain = struct {
    /// The effective multiplier: `volume * replay_gain`. Read by the render
    /// lane; written only by `republish`.
    linear: std.atomic.Value(f32) = .init(1),
    /// What a host's volume control means. This is what `playerVolume`
    /// reports, so replay gain never moves a slider the user set.
    volume: std.atomic.Value(f32) = .init(1),
    /// Loudness correction for the entry being played, already converted from
    /// decibels and clamped against its peak. 1 when unknown, which is the
    /// honest answer for a library that has not been analyzed.
    replay_gain: std.atomic.Value(f32) = .init(1),
    ramp_frames: std.atomic.Value(u32) = .init(0),
    command_generation: std.atomic.Value(u64) = .init(0),
    current: f32 = 1,
    initialized: bool = false,
    remaining_frames: u32 = 0,
    step: f32 = 0,
    seen_generation: u64 = 0,

    fn republish(self: *Gain, ramp_frames: u32) void {
        const effective = self.volume.load(.acquire) * self.replay_gain.load(.acquire);
        self.linear.store(effective, .release);
        self.ramp_frames.store(ramp_frames, .release);
        _ = self.command_generation.fetchAdd(1, .release);
    }

    pub fn setLinear(self: *Gain, linear: f32, ramp_frames: u32) void {
        self.volume.store(linear, .release);
        self.republish(ramp_frames);
    }

    /// Apply the loudness correction for one entry.
    ///
    /// `peak` is the entry's measured sample peak. Boosting a track whose peak
    /// is already near full scale would clip it, so the gain is capped at
    /// `1 / peak`: quiet tracks come up only as far as their headroom allows.
    /// That is a deliberate quietening of the correction rather than a
    /// limiter, because a limiter in the render lane would change the audio.
    pub fn setReplayGain(self: *Gain, decibels: f32, peak: ?f32, ramp_frames: u32) void {
        var linear = std.math.pow(f32, 10, decibels / 20);
        if (peak) |value| {
            if (value > 0) linear = @min(linear, 1 / value);
        }
        self.replay_gain.store(linear, .release);
        self.republish(ramp_frames);
    }

    /// Return to no loudness correction, for an entry that has never been
    /// analyzed. Leaving the previous entry's correction in place would apply
    /// one track's loudness to another.
    pub fn clearReplayGain(self: *Gain, ramp_frames: u32) void {
        self.replay_gain.store(1, .release);
        self.republish(ramp_frames);
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

test "volume and replay gain survive each other" {
    // They were one stored value, so whichever was written last discarded the
    // other: applying a track's loudness correction would have moved the host's
    // volume slider, and the next volume change would have thrown the
    // correction away.
    var gain: Gain = .{};

    gain.setLinear(0.5, 0);
    try std.testing.expectEqual(@as(f32, 0.5), gain.volume.load(.acquire));
    try std.testing.expectEqual(@as(f32, 0.5), gain.linear.load(.acquire));

    // -6 dB is a factor of about 0.501.
    gain.setReplayGain(-6, null, 0);
    try std.testing.expectEqual(@as(f32, 0.5), gain.volume.load(.acquire));
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.2509),
        gain.linear.load(.acquire),
        0.001,
    );

    // Changing the volume keeps the correction.
    gain.setLinear(1, 0);
    try std.testing.expectEqual(@as(f32, 1), gain.volume.load(.acquire));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5012), gain.linear.load(.acquire), 0.001);

    // An entry with no analysis must not inherit the previous entry's gain.
    gain.clearReplayGain(0);
    try std.testing.expectEqual(@as(f32, 1), gain.linear.load(.acquire));
    try std.testing.expectEqual(@as(f32, 1), gain.volume.load(.acquire));
}

test "a boost is capped by the peak it would clip" {
    // +6 dB on a track already peaking at 0.9 would drive it to 1.8. The gain
    // is capped at 1/peak instead, so the correction is quietened rather than
    // the audio being clipped or limited in the render lane.
    var gain: Gain = .{};
    gain.setReplayGain(6, 0.9, 0);
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0 / 0.9),
        gain.linear.load(.acquire),
        0.0001,
    );

    // With headroom to spare the full correction applies.
    gain.setReplayGain(6, 0.2, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.9953), gain.linear.load(.acquire), 0.001);
}
