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
pub const ReplayGainMode = enum(u8) {
    /// No correction at all. Every entry plays at the volume the user set.
    off,
    /// Each entry is corrected by its own measured loudness, if the Library
    /// holds one that still describes the file.
    track,
    /// Each entry is corrected by the loudness of its whole Release, so the
    /// album's own dynamics survive. An entry whose Release cannot be measured
    /// as a whole plays at its track correction instead, and says so.
    album,
    /// Album correction while the entry sits next to another entry of its
    /// Release in playback order, track correction otherwise: an album played
    /// through keeps its dynamics, a shuffled mix is levelled per track.
    smart,
};

/// What an entry with no usable measurement plays at while correction is on.
pub const UntaggedFallback = enum(u8) {
    /// Six decibels down, close to where measured modern masters land.
    minus_6_db,
    /// Unity: the entry plays as it is.
    as_is,

    pub fn multiplier(self: UntaggedFallback) f32 {
        return switch (self) {
            .minus_6_db => 0.5011872,
            .as_is => 1,
        };
    }
};

pub const max_preamp_db: f32 = 15;

/// Every Player-level ReplayGain choice in one word, so the decode lane reads
/// a consistent set with a single atomic load on every block.
pub const ReplayGainSettings = packed struct(u64) {
    mode: ReplayGainMode = .track,
    fallback: UntaggedFallback = .as_is,
    /// Caps each correction at `1 / peak` so a boost never drives the
    /// entry's measured peak past full scale.
    peak_protection: bool = true,
    reserved: u15 = 0,
    /// Added to every measured correction, before the peak cap.
    preamp_db: f32 = 0,

    pub fn clampPreamp(decibels: f32) f32 {
        if (std.math.isNan(decibels)) return 0;
        return std.math.clamp(decibels, -max_preamp_db, max_preamp_db);
    }

    pub fn pack(self: ReplayGainSettings) u64 {
        return @bitCast(self);
    }

    pub fn unpack(bits: u64) ReplayGainSettings {
        return @bitCast(bits);
    }
};

pub const ReplayGainSource = enum(u8) {
    /// None: correction is off, or the entry has no usable measurement and
    /// plays at the untagged fallback.
    none,
    track,
    album,
    /// Album was asked for, but the entry has no Release or not every Track
    /// of it is measured, so its own track correction applies.
    track_fallback,
};

/// One measured correction: the uncapped linear gain toward the target and
/// the sample peak it would be capped against.
pub const Correction = struct {
    gain: f32,
    peak: ?f32 = null,
};

/// The corrections one entry carries. Null is "no usable measurement".
pub const EntryReplayGain = struct {
    track: ?Correction = null,
    album: ?Correction = null,
    /// An entry beside this one in playback order belongs to the same
    /// Release. Only `smart` reads it.
    shares_release: bool = false,

    pub const Applied = struct {
        multiplier: f32,
        source: ReplayGainSource,
        /// The peak cap lowered the correction below what was asked for.
        limited: bool = false,
    };

    pub fn applied(self: EntryReplayGain, settings: ReplayGainSettings) Applied {
        const album_first = switch (settings.mode) {
            .off => return .{ .multiplier = 1, .source = .none },
            .track => false,
            .album => true,
            .smart => self.shares_release,
        };
        const correction: Correction, const source: ReplayGainSource = if (album_first and self.album != null)
            .{ self.album.?, .album }
        else if (self.track) |track|
            .{ track, if (album_first) .track_fallback else .track }
        else
            return .{ .multiplier = settings.fallback.multiplier(), .source = .none };
        var linear = correction.gain * replayGainLinear(settings.preamp_db);
        var limited = false;
        if (settings.peak_protection) if (correction.peak) |peak| if (peak > 0 and linear > 1 / peak) {
            linear = 1 / peak;
            limited = true;
        };
        return .{ .multiplier = linear, .source = source, .limited = limited };
    }

    pub const Packed = [3]u64;

    /// A gain and a peak are always positive, so zero bits stand for null.
    pub fn pack(self: EntryReplayGain) Packed {
        return .{
            packCorrection(self.track),
            packCorrection(self.album),
            @intFromBool(self.shares_release),
        };
    }

    pub fn unpack(words: Packed) EntryReplayGain {
        return .{
            .track = unpackCorrection(words[0]),
            .album = unpackCorrection(words[1]),
            .shares_release = words[2] != 0,
        };
    }

    fn packCorrection(correction: ?Correction) u64 {
        const value = correction orelse return 0;
        const gain: u64 = @as(u32, @bitCast(value.gain));
        const peak: u64 = if (value.peak) |peak| @as(u32, @bitCast(peak)) else 0;
        return gain | peak << 32;
    }

    fn unpackCorrection(bits: u64) ?Correction {
        const gain: u32 = @truncate(bits);
        if (gain == 0) return null;
        const peak: u32 = @truncate(bits >> 32);
        return .{ .gain = @bitCast(gain), .peak = if (peak == 0) null else @bitCast(peak) };
    }
};

/// The linear gain a stored ReplayGain figure asks for, before any peak cap.
pub fn replayGainLinear(decibels: f32) f32 {
    return std.math.pow(f32, 10, decibels / 20);
}
/// The linear multiplier a stored ReplayGain figure asks for.
///
/// `peak` is the entry's measured sample peak. Boosting a track whose peak is
/// already near full scale would clip it, so the gain is capped at `1 / peak`:
/// quiet tracks come up only as far as their headroom allows. That is a
/// deliberate quietening of the correction rather than a limiter, because a
/// limiter would change the audio rather than its level.
pub fn replayGainMultiplier(decibels: f32, peak: ?f32) f32 {
    var linear = replayGainLinear(decibels);
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

test "the preamp is clamped to fifteen decibels either way" {
    try std.testing.expectEqual(@as(f32, 15), ReplayGainSettings.clampPreamp(40));
    try std.testing.expectEqual(@as(f32, -15), ReplayGainSettings.clampPreamp(-40));
    try std.testing.expectEqual(@as(f32, 3.5), ReplayGainSettings.clampPreamp(3.5));
    try std.testing.expectEqual(@as(f32, 0), ReplayGainSettings.clampPreamp(std.math.nan(f32)));
}

test "the preamp scales a measured correction but not the untagged fallback" {
    const measured: EntryReplayGain = .{ .track = .{ .gain = 0.5 } };
    const settings: ReplayGainSettings = .{ .preamp_db = 6 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5 * 1.9953), measured.applied(settings).multiplier, 0.001);

    const untagged: EntryReplayGain = .{};
    try std.testing.expectEqual(@as(f32, 1), untagged.applied(settings).multiplier);
    const minus_six = untagged.applied(.{ .preamp_db = 6, .fallback = .minus_6_db });
    try std.testing.expectApproxEqAbs(@as(f32, 0.5012), minus_six.multiplier, 0.0001);
    try std.testing.expectEqual(ReplayGainSource.none, minus_six.source);
    try std.testing.expectEqual(@as(f32, 1), untagged.applied(.{ .mode = .off, .fallback = .minus_6_db }).multiplier);
}

test "turning peak protection off lets a boost pass the peak cap" {
    const entry: EntryReplayGain = .{ .track = .{ .gain = 2, .peak = 0.8 } };
    const capped = entry.applied(.{});
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), capped.multiplier, 0.0001);
    try std.testing.expect(capped.limited);

    const uncapped = entry.applied(.{ .peak_protection = false });
    try std.testing.expectEqual(@as(f32, 2), uncapped.multiplier);
    try std.testing.expect(!uncapped.limited);

    const headroom: EntryReplayGain = .{ .track = .{ .gain = 1.1, .peak = 0.5 } };
    try std.testing.expect(!headroom.applied(.{}).limited);
}

test "smart mode takes album gain only while a neighbour shares the Release" {
    var entry: EntryReplayGain = .{ .track = .{ .gain = 0.25 }, .album = .{ .gain = 0.5 } };
    const smart: ReplayGainSettings = .{ .mode = .smart };
    try std.testing.expectEqual(ReplayGainSource.track, entry.applied(smart).source);
    try std.testing.expectEqual(@as(f32, 0.25), entry.applied(smart).multiplier);
    entry.shares_release = true;
    try std.testing.expectEqual(ReplayGainSource.album, entry.applied(smart).source);
    try std.testing.expectEqual(@as(f32, 0.5), entry.applied(smart).multiplier);
    entry.album = null;
    try std.testing.expectEqual(ReplayGainSource.track_fallback, entry.applied(smart).source);
}

test "an entry's corrections survive packing for another lane" {
    const entry: EntryReplayGain = .{
        .track = .{ .gain = 0.25, .peak = 0.9 },
        .album = .{ .gain = 0.5 },
        .shares_release = true,
    };
    const round_trip = EntryReplayGain.unpack(entry.pack());
    try std.testing.expectEqual(entry.track.?.gain, round_trip.track.?.gain);
    try std.testing.expectEqual(entry.track.?.peak, round_trip.track.?.peak);
    try std.testing.expectEqual(entry.album.?.gain, round_trip.album.?.gain);
    try std.testing.expectEqual(@as(?f32, null), round_trip.album.?.peak);
    try std.testing.expect(round_trip.shares_release);
    try std.testing.expectEqual(@as(?Correction, null), EntryReplayGain.unpack((EntryReplayGain{}).pack()).track);
}
