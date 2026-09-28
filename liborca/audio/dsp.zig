const std = @import("std");
const equalizer = @import("equalizer.zig");
const kernels = @import("kernels.zig");
const nodes = @import("nodes.zig");
const pcm = @import("pcm.zig");
const processing = @import("processing.zig");
const signal_path = @import("signal_path.zig");
const zone_runtime = @import("zone_runtime.zig");

pub const band_count = 10;
pub const band_frequencies_hz = [band_count]f64{ 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 };

/// One octave between the centres of neighbouring bands.
pub const band_q: f64 = 1.41;
pub const max_band_gain_db: f32 = 12;
pub const min_preamp_db: f32 = -24;
pub const max_preamp_db: f32 = 12;

pub const Preset = enum { flat, bass, treble, vocal, loudness };

/// Ten peaking bands and the preamp that keeps them from clipping.
pub const Equalizer = struct {
    gains_db: [band_count]f32 = @splat(0),
    preamp_db: f32 = 0,

    pub fn validate(self: Equalizer) !void {
        for (self.gains_db) |gain_db| {
            if (!std.math.isFinite(gain_db) or @abs(gain_db) > max_band_gain_db)
                return error.EqualizerGainOutOfRange;
        }
        if (!std.math.isFinite(self.preamp_db) or
            self.preamp_db < min_preamp_db or self.preamp_db > max_preamp_db)
            return error.EqualizerPreampOutOfRange;
    }

    /// Whether the equalizer changes any sample. An equalizer with every band
    /// and the preamp at zero is on but transparent.
    pub fn isActive(self: Equalizer) bool {
        if (self.preamp_db != 0) return true;
        for (self.gains_db) |gain_db| {
            if (gain_db != 0) return true;
        }
        return false;
    }

    /// The preamp that leaves headroom for the largest boost: minus that boost,
    /// or zero when no band boosts.
    pub fn defaultPreamp(gains_db: [band_count]f32) f32 {
        var largest: f32 = 0;
        for (gains_db) |gain_db| largest = @max(largest, gain_db);
        return -largest;
    }

    pub fn preset(kind: Preset) Equalizer {
        const gains_db: [band_count]f32 = switch (kind) {
            .flat => @splat(0),
            .bass => .{ 6, 5, 4, 2, 0, 0, 0, 0, 0, 0 },
            .treble => .{ 0, 0, 0, 0, 0, 1, 2, 4, 5, 6 },
            .vocal => .{ -2, -2, -1, 1, 3, 4, 4, 2, 0, -1 },
            .loudness => .{ 6, 4, 2, 0, -1, -1, 0, 2, 4, 5 },
        };
        return .{ .gains_db = gains_db, .preamp_db = defaultPreamp(gains_db) };
    }
};

pub fn validateCrossfeed(amount: f32) !void {
    if (!std.math.isFinite(amount) or amount < 0 or amount > 1)
        return error.CrossfeedAmountOutOfRange;
}

pub const Settings = struct {
    equalizer: ?Equalizer = null,
    /// Amount in [0, 1].
    crossfeed: ?f32 = null,
};

/// The Player-scope sample path, applied to canonical PCM on the engine thread
/// before fanout: preamp, equalizer, crossfeed, then the volume `Gain`. With
/// the equalizer and crossfeed off it is exactly the volume gain.
pub const PlayerDsp = struct {
    gain: *processing.Gain,
    settings: Settings = .{},
    generation: u64 = 0,

    filter: Cascade = .{ .sample_rate = 0 },
    preamp_linear: f32 = 1,
    equalizer_active: bool = false,
    crossfeed: nodes.StereoCrossfeed = .{ .amount = 0 },
    crossfeed_active: bool = false,
    prepared: bool = false,
    prepared_generation: u64 = 0,
    prepared_sample_rate: u32 = 0,
    prepared_channels: u16 = 0,
    prepared_epoch: u32 = 0,

    const Cascade = equalizer.ParametricEq(band_count, zone_runtime.max_channels);

    pub fn init(gain: *processing.Gain) PlayerDsp {
        return .{ .gain = gain };
    }

    /// Control lane. The engine reads `settings` without synchronization, so
    /// the caller must have quiesced it; a torn read would apply half of one
    /// equalizer and half of another.
    pub fn setEqualizer(self: *PlayerDsp, value: ?Equalizer) !void {
        if (value) |candidate| try candidate.validate();
        self.settings.equalizer = value;
        self.generation += 1;
    }

    /// Control lane, under the same quiesce requirement as `setEqualizer`.
    pub fn setCrossfeed(self: *PlayerDsp, amount: ?f32) !void {
        if (amount) |candidate| try validateCrossfeed(candidate);
        self.settings.crossfeed = amount;
        self.generation += 1;
    }

    /// Engine thread, before it processes a pass. Rebuilds coefficients when
    /// the settings or the sample rate changed, and clears filter history when
    /// the transport epoch or channel count changed.
    pub fn prepare(self: *PlayerDsp, sample_rate: u32, channels: u16, epoch: u32) void {
        if (!self.prepared or self.prepared_generation != self.generation or
            self.prepared_sample_rate != sample_rate)
            self.rebuild(sample_rate);
        if (!self.prepared or self.prepared_epoch != epoch or self.prepared_channels != channels)
            self.filter.processor().reset();
        self.prepared = true;
        self.prepared_generation = self.generation;
        self.prepared_sample_rate = sample_rate;
        self.prepared_channels = channels;
        self.prepared_epoch = epoch;
    }

    pub fn processor(self: *PlayerDsp) processing.Processor {
        return .{
            .context = self,
            .process_fn = process,
            .reset_fn = reset,
            .metadata = .{
                .name = "player DSP",
                .changes_samples = true,
                .realtime_safe = true,
            },
        };
    }

    fn rebuild(self: *PlayerDsp, sample_rate: u32) void {
        const was_active = self.equalizer_active;
        self.filter.sample_rate = sample_rate;
        self.filter.band_count = 0;
        self.preamp_linear = 1;
        self.equalizer_active = false;
        if (self.settings.equalizer) |setting| {
            if (setting.isActive()) {
                const nyquist_hz = @as(f64, @floatFromInt(sample_rate)) / 2;
                for (band_frequencies_hz, setting.gains_db) |frequency_hz, gain_db| {
                    if (gain_db == 0 or frequency_hz >= nyquist_hz) continue;
                    self.filter.appendPeaking(.{
                        .frequency_hz = frequency_hz,
                        .gain_db = gain_db,
                        .q = band_q,
                    }) catch unreachable;
                }
                if (setting.preamp_db != 0)
                    self.preamp_linear = std.math.pow(f32, 10, setting.preamp_db / 20);
                self.equalizer_active = true;
            }
        }
        if (self.equalizer_active and !was_active) self.filter.processor().reset();
        const amount = self.settings.crossfeed orelse 0;
        self.crossfeed.amount = amount;
        self.crossfeed_active = amount > 0;
    }

    fn process(context: *anyopaque, samples: []f32, frames: u32, channels: u16) void {
        const self: *PlayerDsp = @ptrCast(@alignCast(context));
        if (self.equalizer_active) {
            if (self.preamp_linear != 1)
                kernels.gain(samples[0 .. @as(usize, frames) * channels], self.preamp_linear);
            if (self.filter.band_count > 0)
                self.filter.processor().process(samples, frames, channels);
        }
        if (self.crossfeed_active)
            self.crossfeed.processor().process(samples, frames, channels);
        self.gain.processor().process(samples, frames, channels);
    }

    fn reset(context: *anyopaque) void {
        const self: *PlayerDsp = @ptrCast(@alignCast(context));
        self.filter.processor().reset();
    }
};

/// What the audio reaching the output has been through, as plain values.
pub const SignalPath = struct {
    /// The decoder's source format, before conversion to canonical float32.
    source: ?pcm.Format = null,
    /// Canonical codec identifier of the source, from `codec_id`.
    codec: ?[]const u8 = null,
    /// The correction applied to the audible entry, or null when it is 1.
    replay_gain_db: ?f32 = null,
    equalizer: ?Equalizer = null,
    crossfeed: ?f32 = null,
    volume: f32 = 1,
    /// What the output stream was opened with; null while no output is open.
    output: ?pcm.Format = null,
    /// False as soon as any reason applies. With no source or no output the
    /// format conversions cannot be judged, so only sample processing counts.
    bit_perfect_eligible: bool = true,
    reasons: [max_reasons]signal_path.Reason = undefined,
    reason_count: usize = 0,

    pub const max_reasons = 4;

    pub fn reasonList(self: *const SignalPath) []const signal_path.Reason {
        return self.reasons[0..self.reason_count];
    }

    /// `replay_gain` is the linear correction; a value of exactly 1 is no
    /// correction and, like a volume of exactly 1, is not sample processing.
    pub fn describe(inputs: struct {
        source: ?pcm.Format,
        codec: ?[]const u8,
        replay_gain: f32,
        equalizer: ?Equalizer,
        crossfeed: ?f32,
        volume: f32,
        output: ?pcm.Format,
    }) SignalPath {
        var result: SignalPath = .{
            .source = inputs.source,
            .codec = inputs.codec,
            .replay_gain_db = if (inputs.replay_gain == 1)
                null
            else
                20 * std.math.log10(inputs.replay_gain),
            .equalizer = inputs.equalizer,
            .crossfeed = inputs.crossfeed,
            .volume = inputs.volume,
            .output = inputs.output,
        };
        const stereo = if (inputs.output) |output| output.channels == 2 else true;
        const equalizer_changes = if (inputs.equalizer) |setting| setting.isActive() else false;
        const crossfeed_changes = stereo and (inputs.crossfeed orelse 0) > 0;
        if (equalizer_changes or crossfeed_changes or inputs.volume != 1 or inputs.replay_gain != 1) {
            result.reasons[0] = .sample_processing;
            result.reason_count = 1;
        }
        if (inputs.source) |source| {
            if (inputs.output) |output| {
                const report = signal_path.inspect(max_reasons, source, output, &.{}, &.{});
                for (report.reasons[0..report.reason_count]) |reason| {
                    result.reasons[result.reason_count] = reason;
                    result.reason_count += 1;
                }
            }
        }
        result.bit_perfect_eligible = result.reason_count == 0;
        return result;
    }
};

const test_block_frames = 256;

fn gainsWithBand(index: usize, gain_db: f32) [band_count]f32 {
    var gains_db: [band_count]f32 = @splat(0);
    gains_db[index] = gain_db;
    return gains_db;
}

fn measureGainDb(dsp: *PlayerDsp, sample_rate: u32, frequency_hz: f64) f64 {
    const amplitude = 0.25;
    var block: [test_block_frames * 2]f32 = undefined;
    const settle_frames = sample_rate / 2;
    var square_sum: f64 = 0;
    var measured: usize = 0;
    var frame: usize = 0;
    while (frame < sample_rate) {
        const frames: usize = @min(test_block_frames, sample_rate - frame);
        for (0..frames) |index| {
            const phase = 2 * std.math.pi * frequency_hz *
                @as(f64, @floatFromInt(frame + index)) / @as(f64, @floatFromInt(sample_rate));
            const value: f32 = @floatCast(amplitude * @sin(phase));
            block[index * 2] = value;
            block[index * 2 + 1] = value;
        }
        dsp.prepare(sample_rate, 2, 1);
        dsp.processor().process(block[0 .. frames * 2], @intCast(frames), 2);
        for (0..frames) |index| {
            if (frame + index < settle_frames) continue;
            square_sum += @as(f64, block[index * 2]) * block[index * 2];
            measured += 1;
        }
        frame += frames;
    }
    const rms = @sqrt(square_sum / @as(f64, @floatFromInt(measured)));
    return 20 * std.math.log10(rms / (amplitude / @sqrt(2.0)));
}

test "equalizer at plus six decibels on one band lifts that band and leaves a distant one" {
    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    try dsp.setEqualizer(.{ .gains_db = gainsWithBand(5, 6) });
    try std.testing.expectApproxEqAbs(@as(f64, 6), measureGainDb(&dsp, 48_000, 1000), 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 0), measureGainDb(&dsp, 48_000, 100), 0.5);
}

test "coefficients are rebuilt when the sample rate changes" {
    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    try dsp.setEqualizer(.{ .gains_db = gainsWithBand(5, 6) });
    try std.testing.expectApproxEqAbs(@as(f64, 6), measureGainDb(&dsp, 44_100, 1000), 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 6), measureGainDb(&dsp, 96_000, 1000), 0.1);
}

test "a settings change is picked up at the next prepare" {
    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    try dsp.setEqualizer(.{ .gains_db = gainsWithBand(5, 6) });
    try std.testing.expectApproxEqAbs(@as(f64, 6), measureGainDb(&dsp, 48_000, 1000), 0.1);
    try dsp.setEqualizer(.{ .gains_db = gainsWithBand(5, -6) });
    try std.testing.expectApproxEqAbs(@as(f64, -6), measureGainDb(&dsp, 48_000, 1000), 0.1);
    try dsp.setEqualizer(null);
    try std.testing.expectApproxEqAbs(@as(f64, 0), measureGainDb(&dsp, 48_000, 1000), 0.001);
}

test "bands at or above Nyquist and bands at zero are not built" {
    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    var gains_db = gainsWithBand(9, 6);
    gains_db[0] = 3;
    try dsp.setEqualizer(.{ .gains_db = gains_db });
    dsp.prepare(32_000, 2, 1);
    try std.testing.expectEqual(@as(usize, 1), dsp.filter.band_count);
    dsp.prepare(44_100, 2, 1);
    try std.testing.expectEqual(@as(usize, 2), dsp.filter.band_count);
}

test "with equalizer and crossfeed off the output is bit-identical to the volume gain" {
    var reference_gain: processing.Gain = .{};
    var dsp_gain: processing.Gain = .{};
    reference_gain.setLinear(0.37, 0);
    dsp_gain.setLinear(0.37, 0);
    var dsp: PlayerDsp = .init(&dsp_gain);

    var random = std.Random.DefaultPrng.init(0x0ca);
    var expected: [test_block_frames * 2]f32 = undefined;
    for (&expected) |*sample| sample.* = random.random().float(f32) * 2 - 1;
    var actual = expected;

    reference_gain.processor().process(&expected, test_block_frames, 2);
    dsp.prepare(44_100, 2, 1);
    dsp.processor().process(&actual, test_block_frames, 2);
    try std.testing.expectEqualSlices(f32, &expected, &actual);
}

test "a transparent equalizer and a zero crossfeed leave the volume path untouched" {
    var reference_gain: processing.Gain = .{};
    var dsp_gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&dsp_gain);
    try dsp.setEqualizer(.{});
    try dsp.setCrossfeed(0);

    var expected: [16]f32 = @splat(0.5);
    var actual = expected;
    reference_gain.processor().process(&expected, 8, 2);
    dsp.prepare(44_100, 2, 1);
    dsp.processor().process(&actual, 8, 2);
    try std.testing.expectEqualSlices(f32, &expected, &actual);
}

test "crossfeed leaves mono and multichannel buffers untouched" {
    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    try dsp.setCrossfeed(0.5);

    var mono = [_]f32{ 1, -0.5, 0.25, 0 };
    const mono_input = mono;
    dsp.prepare(48_000, 1, 1);
    dsp.processor().process(&mono, 4, 1);
    try std.testing.expectEqualSlices(f32, &mono_input, &mono);

    var surround = [_]f32{ 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 };
    const surround_input = surround;
    dsp.prepare(48_000, 6, 1);
    dsp.processor().process(&surround, 2, 6);
    try std.testing.expectEqualSlices(f32, &surround_input, &surround);

    var stereo = [_]f32{ 1, 0 };
    dsp.prepare(48_000, 2, 1);
    dsp.processor().process(&stereo, 1, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 1) / 1.5, stereo[0], 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5) / 1.5, stereo[1], 0.000_001);
}

test "an epoch change resets filter history" {
    var noise: [test_block_frames * 2]f32 = undefined;
    var random = std.Random.DefaultPrng.init(7);
    for (&noise) |*sample| sample.* = random.random().float(f32) * 2 - 1;
    var probe: [test_block_frames * 2]f32 = @splat(0);
    probe[0] = 1;
    probe[1] = 1;

    var used_gain: processing.Gain = .{};
    var used: PlayerDsp = .init(&used_gain);
    var fresh_gain: processing.Gain = .{};
    var fresh: PlayerDsp = .init(&fresh_gain);
    const setting: Equalizer = .{ .gains_db = gainsWithBand(3, 9) };
    try used.setEqualizer(setting);
    try fresh.setEqualizer(setting);

    var scratch = noise;
    used.prepare(48_000, 2, 1);
    used.processor().process(&scratch, test_block_frames, 2);

    var continued = probe;
    used.prepare(48_000, 2, 1);
    used.processor().process(&continued, test_block_frames, 2);

    var after_seek = probe;
    scratch = noise;
    used.prepare(48_000, 2, 1);
    used.processor().process(&scratch, test_block_frames, 2);
    used.prepare(48_000, 2, 2);
    used.processor().process(&after_seek, test_block_frames, 2);

    var expected = probe;
    fresh.prepare(48_000, 2, 2);
    fresh.processor().process(&expected, test_block_frames, 2);

    try std.testing.expectEqualSlices(f32, &expected, &after_seek);
    try std.testing.expect(!std.mem.eql(f32, &expected, &continued));
}

test "preamp scales the signal by its decibel value" {
    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    try dsp.setEqualizer(.{ .preamp_db = -6 });
    var samples = [_]f32{ 1, 1 };
    dsp.prepare(48_000, 2, 1);
    dsp.processor().process(&samples, 1, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.501_187), samples[0], 0.000_01);
    try std.testing.expectApproxEqAbs(samples[0], samples[1], 0);
}

test "equalizer validation rejects out-of-range and non-finite values" {
    try std.testing.expectError(
        error.EqualizerGainOutOfRange,
        (Equalizer{ .gains_db = gainsWithBand(2, 12.5) }).validate(),
    );
    try std.testing.expectError(
        error.EqualizerGainOutOfRange,
        (Equalizer{ .gains_db = gainsWithBand(2, -13) }).validate(),
    );
    try std.testing.expectError(
        error.EqualizerGainOutOfRange,
        (Equalizer{ .gains_db = gainsWithBand(2, std.math.nan(f32)) }).validate(),
    );
    try std.testing.expectError(
        error.EqualizerPreampOutOfRange,
        (Equalizer{ .preamp_db = 12.5 }).validate(),
    );
    try std.testing.expectError(
        error.EqualizerPreampOutOfRange,
        (Equalizer{ .preamp_db = -24.5 }).validate(),
    );
    try (Equalizer{ .gains_db = gainsWithBand(2, 12), .preamp_db = -24 }).validate();
    try std.testing.expectError(error.CrossfeedAmountOutOfRange, validateCrossfeed(1.5));
    try std.testing.expectError(error.CrossfeedAmountOutOfRange, validateCrossfeed(-0.1));
    try std.testing.expectError(error.CrossfeedAmountOutOfRange, validateCrossfeed(std.math.inf(f32)));

    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    try std.testing.expectError(
        error.EqualizerGainOutOfRange,
        dsp.setEqualizer(.{ .gains_db = gainsWithBand(0, 20) }),
    );
    try std.testing.expectEqual(@as(?Equalizer, null), dsp.settings.equalizer);
    try std.testing.expectEqual(@as(u64, 0), dsp.generation);
}

test "every preset is valid and carries the preamp its largest boost needs" {
    inline for (@typeInfo(Preset).@"enum".fields) |field| {
        const value = Equalizer.preset(@enumFromInt(field.value));
        try value.validate();
        try std.testing.expectEqual(Equalizer.defaultPreamp(value.gains_db), value.preamp_db);
    }
    try std.testing.expect(!Equalizer.preset(.flat).isActive());
    try std.testing.expectEqual(@as(f32, -6), Equalizer.preset(.bass).preamp_db);
}

const test_flac_format: pcm.Format = .{
    .sample_format = .signed_16,
    .channels = 2,
    .sample_rate = 44_100,
    .bits_per_sample = 16,
    .bytes_per_frame = 4,
};

const test_float_format: pcm.Format = .{
    .sample_format = .float_32,
    .channels = 2,
    .sample_rate = 44_100,
    .bits_per_sample = 32,
    .bytes_per_frame = 8,
};

test "a signal path with no processing over matching formats is bit-perfect eligible" {
    const path = SignalPath.describe(.{
        .source = test_float_format,
        .codec = "pcm_float",
        .replay_gain = 1,
        .equalizer = null,
        .crossfeed = null,
        .volume = 1,
        .output = test_float_format,
    });
    try std.testing.expect(path.bit_perfect_eligible);
    try std.testing.expectEqual(@as(usize, 0), path.reasonList().len);
    try std.testing.expectEqual(@as(?f32, null), path.replay_gain_db);
}

test "an integer source reaching a float output is a sample format conversion" {
    const path = SignalPath.describe(.{
        .source = test_flac_format,
        .codec = "flac",
        .replay_gain = 1,
        .equalizer = null,
        .crossfeed = null,
        .volume = 1,
        .output = test_float_format,
    });
    try std.testing.expect(!path.bit_perfect_eligible);
    try std.testing.expectEqualSlices(
        signal_path.Reason,
        &.{.sample_format_conversion},
        path.reasonList(),
    );
}

test "equalizer, crossfeed, volume and replay gain each count as sample processing" {
    const base: struct {
        replay_gain: f32 = 1,
        equalizer: ?Equalizer = null,
        crossfeed: ?f32 = null,
        volume: f32 = 1,
    } = .{};
    const cases = [_]@TypeOf(base){
        .{ .equalizer = Equalizer.preset(.bass) },
        .{ .equalizer = .{ .preamp_db = -3 } },
        .{ .crossfeed = 0.3 },
        .{ .volume = 0.5 },
        .{ .replay_gain = 0.5 },
    };
    for (cases) |case| {
        const path = SignalPath.describe(.{
            .source = test_float_format,
            .codec = null,
            .replay_gain = case.replay_gain,
            .equalizer = case.equalizer,
            .crossfeed = case.crossfeed,
            .volume = case.volume,
            .output = test_float_format,
        });
        try std.testing.expect(!path.bit_perfect_eligible);
        try std.testing.expectEqualSlices(
            signal_path.Reason,
            &.{.sample_processing},
            path.reasonList(),
        );
    }
    const transparent = SignalPath.describe(.{
        .source = test_float_format,
        .codec = null,
        .replay_gain = 1,
        .equalizer = .{},
        .crossfeed = 0,
        .volume = 1,
        .output = test_float_format,
    });
    try std.testing.expect(transparent.bit_perfect_eligible);
}

test "crossfeed on a layout it does not apply to is not sample processing" {
    var surround = test_float_format;
    surround.channels = 6;
    surround.bytes_per_frame = 24;
    const path = SignalPath.describe(.{
        .source = surround,
        .codec = null,
        .replay_gain = 1,
        .equalizer = null,
        .crossfeed = 0.3,
        .volume = 1,
        .output = surround,
    });
    try std.testing.expect(path.bit_perfect_eligible);
}

test "replay gain is reported in decibels" {
    const path = SignalPath.describe(.{
        .source = null,
        .codec = null,
        .replay_gain = 0.5,
        .equalizer = null,
        .crossfeed = null,
        .volume = 1,
        .output = null,
    });
    try std.testing.expectApproxEqAbs(@as(f32, -6.0206), path.replay_gain_db.?, 0.001);
}
