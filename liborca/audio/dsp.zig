const std = @import("std");
const backend = @import("backend.zig");
const codec_id = @import("../codec/decoder.zig").codec_id;
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

pub const max_parametric_filters = 16;
pub const min_filter_frequency_hz: f32 = 20;
pub const max_filter_frequency_hz: f32 = 20_000;
pub const max_filter_gain_db: f32 = 24;
pub const min_filter_q: f32 = 0.1;
pub const max_filter_q: f32 = 20;
pub const min_shelf_q: f32 = 0.3;
pub const max_shelf_q: f32 = 2;
pub const min_parametric_preamp_db: f32 = -24;
pub const max_parametric_preamp_db: f32 = 6;

pub const FilterKind = enum(u8) { peak, low_shelf, high_shelf, low_pass, high_pass, notch };

/// One biquad of a parametric equalizer. `gain_db` applies to the peak and
/// shelves only; the pass and notch filters ignore it.
pub const Filter = struct {
    kind: FilterKind,
    frequency_hz: f32,
    gain_db: f32 = 0,
    q: f32 = 0.707,
    enabled: bool = true,

    pub fn usesGain(self: Filter) bool {
        return switch (self.kind) {
            .peak, .low_shelf, .high_shelf => true,
            .low_pass, .high_pass, .notch => false,
        };
    }

    pub fn validate(self: Filter) !void {
        if (!std.math.isFinite(self.frequency_hz) or
            self.frequency_hz < min_filter_frequency_hz or self.frequency_hz > max_filter_frequency_hz)
            return error.FilterFrequencyOutOfRange;
        if (!std.math.isFinite(self.gain_db) or @abs(self.gain_db) > max_filter_gain_db)
            return error.FilterGainOutOfRange;
        const shelf = self.kind == .low_shelf or self.kind == .high_shelf;
        const min_q = if (shelf) min_shelf_q else min_filter_q;
        const max_q = if (shelf) max_shelf_q else max_filter_q;
        if (!std.math.isFinite(self.q) or self.q < min_q or self.q > max_q)
            return error.FilterQOutOfRange;
    }

    fn changesSamples(self: Filter) bool {
        return self.enabled and (!self.usesGain() or self.gain_db != 0);
    }

    fn band(self: Filter) equalizer.Band {
        return .{ .frequency_hz = self.frequency_hz, .gain_db = self.gain_db, .q = self.q };
    }

    fn coefficients(self: Filter, sample_rate: u32) equalizer.Coefficients {
        return switch (self.kind) {
            .peak => equalizer.peakingCoefficients(sample_rate, self.band()),
            .low_shelf => equalizer.lowShelfCoefficients(sample_rate, self.band()),
            .high_shelf => equalizer.highShelfCoefficients(sample_rate, self.band()),
            .low_pass => equalizer.lowPassCoefficients(sample_rate, self.band()),
            .high_pass => equalizer.highPassCoefficients(sample_rate, self.band()),
            .notch => equalizer.notchCoefficients(sample_rate, self.band()),
        };
    }
};

/// Up to sixteen filters in order, and a preamp. Exclusive with `Equalizer`:
/// a Player runs one or the other.
///
/// The limits hold at every sample rate. A filter at or above 0.45 of the
/// rate of the audio playing is left out of the cascade and of `response`,
/// as the ten-band equalizer leaves out bands at or above Nyquist.
pub const ParametricEqualizer = struct {
    filters: [max_parametric_filters]Filter = undefined,
    count: u8 = 0,
    preamp_db: f32 = 0,

    pub fn filterList(self: *const ParametricEqualizer) []const Filter {
        return self.filters[0..self.count];
    }

    pub fn validate(self: ParametricEqualizer) !void {
        if (self.count > max_parametric_filters) return error.TooManyFilters;
        if (!std.math.isFinite(self.preamp_db) or
            self.preamp_db < min_parametric_preamp_db or self.preamp_db > max_parametric_preamp_db)
            return error.ParametricPreampOutOfRange;
        for (self.filterList()) |filter| try filter.validate();
    }

    /// Whether no sample changes: a zero preamp, and every enabled filter a
    /// peak or shelf at zero gain.
    pub fn isIdentity(self: ParametricEqualizer) bool {
        if (self.preamp_db != 0) return false;
        for (self.filterList()) |filter| {
            if (filter.changesSamples()) return false;
        }
        return true;
    }

    /// Minus the largest boost of an enabled peak or shelf, or zero when none
    /// boosts.
    pub fn suggestedPreamp(self: ParametricEqualizer) f32 {
        var largest: f32 = 0;
        for (self.filterList()) |filter| {
            if (filter.enabled and filter.usesGain()) largest = @max(largest, filter.gain_db);
        }
        return if (largest > 0) -largest else 0;
    }

    /// The gain in decibels at each of `frequencies`, preamp included, as the
    /// cascade built at `sample_rate` would apply it. `out` is as long as
    /// `frequencies`. Pure: it computes, and touches no Player.
    pub fn response(
        self: ParametricEqualizer,
        sample_rate: u32,
        frequencies: []const f32,
        out: []f32,
    ) void {
        var designs: [max_parametric_filters]equalizer.Coefficients = undefined;
        var design_count: usize = 0;
        for (self.filterList()) |filter| {
            if (!filter.enabled or !equalizer.frequencyInRange(sample_rate, filter.frequency_hz)) continue;
            designs[design_count] = filter.coefficients(sample_rate);
            design_count += 1;
        }
        for (frequencies, out) |frequency_hz, *gain_db| {
            var total: f64 = self.preamp_db;
            for (designs[0..design_count]) |design|
                total += design.magnitudeDb(sample_rate, frequency_hz);
            gain_db.* = @floatCast(total);
        }
    }
};

pub fn validateCrossfeed(amount: f32) !void {
    if (!std.math.isFinite(amount) or amount < 0 or amount > 1)
        return error.CrossfeedAmountOutOfRange;
}

pub const Settings = struct {
    /// Null whenever `parametric` is set.
    equalizer: ?Equalizer = null,
    /// Null whenever `equalizer` is set.
    parametric: ?ParametricEqualizer = null,
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
    slot_sources: [max_slots]u8 = @splat(0),
    slot_kinds: [max_slots]FilterKind = @splat(.peak),
    preamp_linear: f32 = 1,
    active_equalizer: ActiveEqualizer = .none,
    crossfeed: nodes.StereoCrossfeed = .{ .amount = 0 },
    crossfeed_active: bool = false,
    prepared: bool = false,
    prepared_generation: u64 = 0,
    prepared_sample_rate: u32 = 0,
    prepared_channels: u16 = 0,
    prepared_epoch: u32 = 0,

    const max_slots = @max(band_count, max_parametric_filters);
    const Cascade = equalizer.ParametricEq(max_slots, zone_runtime.max_channels);
    const ActiveEqualizer = enum { none, ten_band, parametric };

    pub fn init(gain: *processing.Gain) PlayerDsp {
        return .{ .gain = gain };
    }

    /// Control lane. The engine reads `settings` without synchronization, so
    /// the caller must have quiesced it; a torn read would apply half of one
    /// equalizer and half of another. Turning it on turns the parametric
    /// equalizer off.
    pub fn setEqualizer(self: *PlayerDsp, value: ?Equalizer) !void {
        if (value) |candidate| try candidate.validate();
        self.settings.equalizer = value;
        if (value != null) self.settings.parametric = null;
        self.generation += 1;
    }

    /// Control lane, under the same quiesce requirement as `setEqualizer`.
    /// Turning it on turns the ten-band equalizer off.
    pub fn setParametricEqualizer(self: *PlayerDsp, value: ?ParametricEqualizer) !void {
        if (value) |candidate| try candidate.validate();
        self.settings.parametric = value;
        if (value != null) self.settings.equalizer = null;
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
    /// the transport epoch or channel count changed. A rebuild clears a
    /// filter's history when the filter is new or of another kind, or the
    /// other equalizer was in use. History follows the filter, by its index in
    /// the setting, not its slot in the cascade: turning another filter off or
    /// on, or a change of gain, frequency or Q alone, keeps it, so neither
    /// clicks.
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
        const previous_equalizer = self.active_equalizer;
        const previous_count = self.filter.band_count;
        var sources: [max_slots]u8 = undefined;
        var kinds: [max_slots]FilterKind = undefined;
        self.filter.sample_rate = sample_rate;
        self.filter.band_count = 0;
        self.preamp_linear = 1;
        self.active_equalizer = .none;
        if (self.settings.equalizer) |setting| {
            if (setting.isActive()) {
                const nyquist_hz = @as(f64, @floatFromInt(sample_rate)) / 2;
                for (band_frequencies_hz, setting.gains_db, 0..) |frequency_hz, gain_db, index| {
                    if (gain_db == 0 or frequency_hz >= nyquist_hz) continue;
                    self.filter.appendPeaking(.{
                        .frequency_hz = frequency_hz,
                        .gain_db = gain_db,
                        .q = band_q,
                    }) catch unreachable;
                    sources[self.filter.band_count - 1] = @intCast(index);
                    kinds[self.filter.band_count - 1] = .peak;
                }
                if (setting.preamp_db != 0)
                    self.preamp_linear = std.math.pow(f32, 10, setting.preamp_db / 20);
                self.active_equalizer = .ten_band;
            }
        }
        if (self.settings.parametric) |setting| {
            if (!setting.isIdentity()) {
                for (setting.filterList(), 0..) |filter, index| {
                    if (!filter.changesSamples()) continue;
                    const band = filter.band();
                    const appended = switch (filter.kind) {
                        .peak => self.filter.appendPeak(band),
                        .low_shelf => self.filter.appendLowShelf(band),
                        .high_shelf => self.filter.appendHighShelf(band),
                        .low_pass => self.filter.appendLowPass(band),
                        .high_pass => self.filter.appendHighPass(band),
                        .notch => self.filter.appendNotch(band),
                    };
                    appended catch continue;
                    sources[self.filter.band_count - 1] = @intCast(index);
                    kinds[self.filter.band_count - 1] = filter.kind;
                }
                if (setting.preamp_db != 0)
                    self.preamp_linear = std.math.pow(f32, 10, setting.preamp_db / 20);
                self.active_equalizer = .parametric;
            }
        }
        const count = self.filter.band_count;
        const saved = self.filter.states;
        var previous_slot: usize = 0;
        for (sources[0..count], kinds[0..count], 0..) |source, kind, slot| {
            while (previous_slot < previous_count and self.slot_sources[previous_slot] < source)
                previous_slot += 1;
            const kept = self.active_equalizer == previous_equalizer and
                previous_slot < previous_count and
                self.slot_sources[previous_slot] == source and
                self.slot_kinds[previous_slot] == kind;
            if (kept)
                self.filter.states[slot] = saved[previous_slot]
            else
                self.filter.resetBand(slot);
        }
        @memcpy(self.slot_sources[0..count], sources[0..count]);
        @memcpy(self.slot_kinds[0..count], kinds[0..count]);
        const amount = self.settings.crossfeed orelse 0;
        self.crossfeed.amount = amount;
        self.crossfeed_active = amount > 0;
    }

    fn process(context: *anyopaque, samples: []f32, frames: u32, channels: u16) void {
        const self: *PlayerDsp = @ptrCast(@alignCast(context));
        if (self.active_equalizer != .none) {
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
    /// False when the decoder declared no source format: `source` then holds
    /// the canonical format, and only its rate and channels are meaningful.
    source_declared: bool = false,
    /// Canonical codec identifier of the source, from `codec_id`.
    codec: ?[]const u8 = null,
    /// The correction applied to the audible entry, or null when it is 1.
    replay_gain_db: ?f32 = null,
    /// Which of the audible entry's corrections `replay_gain_db` is.
    replay_gain_source: processing.ReplayGainSource = .none,
    /// The audible entry's own track correction in dB when its album
    /// correction replaced it; null otherwise.
    replay_gain_track_db: ?f32 = null,
    /// Added to every measured correction before the peak cap.
    preamp_db: f32 = 0,
    /// Whether corrections are capped at `1 / peak`.
    peak_protection: bool = true,
    /// What an entry with no usable measurement plays at.
    fallback: processing.UntaggedFallback = .as_is,
    /// The peak cap lowered the audible entry's correction.
    peak_limited: bool = false,
    equalizer: ?Equalizer = null,
    parametric: ?ParametricEqualizer = null,
    crossfeed: ?f32 = null,
    volume: f32 = 1,
    /// What the output stream was opened with; null while no output is open.
    output: ?pcm.Format = null,
    /// The rate the output device is running at, as reported by the backend;
    /// null while unknown. It differs from `output.sample_rate` when the
    /// backend resamples.
    device_rate: ?u32 = null,
    /// Frames the output device asks for per period, as the backend last
    /// reported it; null while unknown.
    device_quantum_frames: ?u32 = null,
    device_format: ?backend.DeviceFormat = null,
    /// How the output device is attached. Unknown while no output is open,
    /// when the platform does not say, and for the server's default device.
    output_kind: backend.DeviceKind = .unknown,
    /// False as soon as any reason applies. With no source or no output the
    /// format conversions cannot be judged, so only sample processing counts.
    bit_perfect_eligible: bool = true,
    /// The integer source reaches float32 unchanged, which is not a reason.
    widened_exactly: bool = false,
    reasons: [max_reasons]signal_path.Reason = undefined,
    reason_count: usize = 0,

    pub const max_reasons = signal_path.max_reasons;

    pub fn reasonList(self: *const SignalPath) []const signal_path.Reason {
        return self.reasons[0..self.reason_count];
    }

    /// `replay_gain` is the linear correction; a value of exactly 1 is no
    /// correction and, like a volume of exactly 1, is not sample processing.
    /// `replay_gain_track` is the entry's own linear track correction.
    pub fn describe(inputs: struct {
        source: ?pcm.Format,
        source_declared: bool,
        codec: ?[]const u8,
        replay_gain: f32,
        replay_gain_source: processing.ReplayGainSource = .none,
        replay_gain_track: ?f32 = null,
        replay_gain_settings: processing.ReplayGainSettings = .{},
        replay_gain_limited: bool = false,
        equalizer: ?Equalizer,
        parametric: ?ParametricEqualizer = null,
        crossfeed: ?f32,
        volume: f32,
        output: ?pcm.Format,
        device_rate: ?u32,
        device_quantum_frames: ?u32 = null,
        device_format: ?backend.DeviceFormat = null,
    }) SignalPath {
        var result: SignalPath = .{
            .source = inputs.source,
            .source_declared = inputs.source_declared,
            .codec = inputs.codec,
            .replay_gain_db = if (inputs.replay_gain == 1)
                null
            else
                20 * std.math.log10(inputs.replay_gain),
            .replay_gain_source = inputs.replay_gain_source,
            .replay_gain_track_db = if (inputs.replay_gain_source == .album)
                if (inputs.replay_gain_track) |track| 20 * std.math.log10(track) else null
            else
                null,
            .preamp_db = inputs.replay_gain_settings.preamp_db,
            .peak_protection = inputs.replay_gain_settings.peak_protection,
            .fallback = inputs.replay_gain_settings.fallback,
            .peak_limited = inputs.replay_gain_limited,
            .equalizer = inputs.equalizer,
            .parametric = inputs.parametric,
            .crossfeed = inputs.crossfeed,
            .volume = inputs.volume,
            .output = inputs.output,
            .device_rate = inputs.device_rate,
            .device_quantum_frames = inputs.device_quantum_frames,
            .device_format = inputs.device_format,
        };
        const stereo = if (inputs.output) |output| output.channels == 2 else true;
        const equalizer_changes = if (inputs.equalizer) |setting| setting.isActive() else false;
        const parametric_changes = if (inputs.parametric) |setting| !setting.isIdentity() else false;
        const crossfeed_changes = stereo and (inputs.crossfeed orelse 0) > 0;
        if (equalizer_changes or parametric_changes or crossfeed_changes or
            inputs.volume != 1 or inputs.replay_gain != 1)
        {
            result.reasons[0] = .sample_processing;
            result.reason_count = 1;
        }
        if (inputs.source) |source| {
            if (inputs.output) |output| {
                const report = signal_path.inspect(max_reasons, source, output, &.{}, &.{});
                result.widened_exactly = report.widened_exactly;
                for (report.reasons[0..report.reason_count]) |reason| {
                    result.reasons[result.reason_count] = reason;
                    result.reason_count += 1;
                }
            }
        }
        if (inputs.output) |output| {
            if (inputs.device_rate) |device_rate| {
                if (device_rate != output.sample_rate) result.addReason(.sample_rate_conversion);
            }
            if (inputs.device_format) |device| {
                if (!deviceCarries(device.sample_format, output.sample_format))
                    result.addReason(.sample_format_conversion);
                if (device.sample_rate != output.sample_rate) result.addReason(.sample_rate_conversion);
            }
        }
        if (inputs.codec) |codec| {
            if (!codec_id.isLossless(codec)) {
                result.reasons[result.reason_count] = .lossy_source;
                result.reason_count += 1;
            }
        }
        result.bit_perfect_eligible = result.reason_count == 0;
        return result;
    }

    fn addReason(self: *SignalPath, reason: signal_path.Reason) void {
        if (std.mem.indexOfScalar(signal_path.Reason, self.reasonList(), reason) != null) return;
        self.reasons[self.reason_count] = reason;
        self.reason_count += 1;
    }
};

fn deviceCarries(device: backend.DeviceSampleFormat, stream: pcm.SampleFormat) bool {
    return switch (device) {
        .signed_16 => stream == .signed_16,
        .signed_24, .signed_24_32 => stream == .signed_24,
        .signed_32 => stream == .signed_32,
        .float_32 => stream == .float_32,
    };
}

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
    inline for (@typeInfo(Preset).@"enum".field_names) |name| {
        const value = Equalizer.preset(@field(Preset, name));
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
        .source_declared = true,
        .codec = "pcm_float",
        .replay_gain = 1,
        .equalizer = null,
        .crossfeed = null,
        .volume = 1,
        .output = test_float_format,
        .device_rate = null,
    });
    try std.testing.expect(path.bit_perfect_eligible);
    try std.testing.expectEqual(@as(usize, 0), path.reasonList().len);
    try std.testing.expectEqual(@as(?f32, null), path.replay_gain_db);
}

test "a 16-bit source widened to float32 is exact and stays bit-perfect eligible" {
    const path = SignalPath.describe(.{
        .source = test_flac_format,
        .source_declared = true,
        .codec = "flac",
        .replay_gain = 1,
        .equalizer = null,
        .crossfeed = null,
        .volume = 1,
        .output = test_float_format,
        .device_rate = null,
    });
    try std.testing.expect(path.bit_perfect_eligible);
    try std.testing.expect(path.widened_exactly);
    try std.testing.expectEqual(@as(usize, 0), path.reasonList().len);
}

test "a 32-bit integer source reaching a float output is a sample format conversion" {
    var source = test_flac_format;
    source.sample_format = .signed_32;
    source.bits_per_sample = 32;
    source.bytes_per_frame = 8;
    const path = SignalPath.describe(.{
        .source = source,
        .source_declared = true,
        .codec = "pcm",
        .replay_gain = 1,
        .equalizer = null,
        .crossfeed = null,
        .volume = 1,
        .output = test_float_format,
        .device_rate = null,
    });
    try std.testing.expect(!path.bit_perfect_eligible);
    try std.testing.expect(!path.widened_exactly);
    try std.testing.expectEqualSlices(
        signal_path.Reason,
        &.{.sample_format_conversion},
        path.reasonList(),
    );
}

test "a lossy source that declares no source format is only a lossy source" {
    const path = SignalPath.describe(.{
        .source = test_float_format,
        .source_declared = false,
        .codec = "mp3",
        .replay_gain = 1,
        .equalizer = null,
        .crossfeed = null,
        .volume = 1,
        .output = test_float_format,
        .device_rate = null,
    });
    try std.testing.expect(!path.bit_perfect_eligible);
    try std.testing.expect(!path.source_declared);
    try std.testing.expectEqualSlices(
        signal_path.Reason,
        &.{.lossy_source},
        path.reasonList(),
    );
}

test "a lossy codec declaring an integer source format is still a lossy source" {
    const path = SignalPath.describe(.{
        .source = test_flac_format,
        .source_declared = true,
        .codec = "qoa",
        .replay_gain = 1,
        .equalizer = null,
        .crossfeed = null,
        .volume = 1,
        .output = test_float_format,
        .device_rate = null,
    });
    try std.testing.expect(!path.bit_perfect_eligible);
    try std.testing.expectEqualSlices(
        signal_path.Reason,
        &.{.lossy_source},
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
            .source_declared = true,
            .codec = null,
            .replay_gain = case.replay_gain,
            .equalizer = case.equalizer,
            .crossfeed = case.crossfeed,
            .volume = case.volume,
            .output = test_float_format,
            .device_rate = null,
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
        .source_declared = true,
        .codec = null,
        .replay_gain = 1,
        .equalizer = .{},
        .crossfeed = 0,
        .volume = 1,
        .output = test_float_format,
        .device_rate = null,
    });
    try std.testing.expect(transparent.bit_perfect_eligible);
}

test "a device running at another rate than the output stream is a sample rate conversion" {
    const path = SignalPath.describe(.{
        .source = test_float_format,
        .source_declared = true,
        .codec = null,
        .replay_gain = 1,
        .equalizer = null,
        .crossfeed = null,
        .volume = 1,
        .output = test_float_format,
        .device_rate = 48_000,
    });
    try std.testing.expect(!path.bit_perfect_eligible);
    try std.testing.expectEqual(@as(?u32, 48_000), path.device_rate);
    try std.testing.expectEqualSlices(
        signal_path.Reason,
        &.{.sample_rate_conversion},
        path.reasonList(),
    );
}

test "a device running at the output stream rate, or at an unknown rate, adds no reason" {
    for ([_]?u32{ 44_100, null }) |device_rate| {
        const path = SignalPath.describe(.{
            .source = test_float_format,
            .source_declared = true,
            .codec = null,
            .replay_gain = 1,
            .equalizer = null,
            .crossfeed = null,
            .volume = 1,
            .output = test_float_format,
            .device_rate = device_rate,
        });
        try std.testing.expect(path.bit_perfect_eligible);
        try std.testing.expectEqual(@as(usize, 0), path.reasonList().len);
    }
}

test "a device rate mismatch is one reason even when the source rate already differs" {
    var source = test_float_format;
    source.sample_rate = 96_000;
    const path = SignalPath.describe(.{
        .source = source,
        .source_declared = true,
        .codec = null,
        .replay_gain = 1,
        .equalizer = null,
        .crossfeed = null,
        .volume = 1,
        .output = test_float_format,
        .device_rate = 48_000,
    });
    try std.testing.expectEqualSlices(
        signal_path.Reason,
        &.{.sample_rate_conversion},
        path.reasonList(),
    );
}

test "a float output stream reaching an integer device is a sample format conversion" {
    const device: backend.DeviceFormat = .{
        .sample_format = .signed_24_32,
        .sample_rate = 44_100,
        .channels = 2,
    };
    const path = SignalPath.describe(.{
        .source = test_flac_format,
        .source_declared = true,
        .codec = "flac",
        .replay_gain = 1,
        .equalizer = null,
        .crossfeed = null,
        .volume = 1,
        .output = test_float_format,
        .device_rate = 44_100,
        .device_format = device,
    });
    try std.testing.expect(!path.bit_perfect_eligible);
    try std.testing.expectEqual(device, path.device_format.?);
    try std.testing.expectEqualSlices(
        signal_path.Reason,
        &.{.sample_format_conversion},
        path.reasonList(),
    );
}

test "a device format at another rate is one sample rate conversion beside the format conversion" {
    const path = SignalPath.describe(.{
        .source = test_flac_format,
        .source_declared = true,
        .codec = "flac",
        .replay_gain = 1,
        .equalizer = null,
        .crossfeed = null,
        .volume = 1,
        .output = test_float_format,
        .device_rate = 96_000,
        .device_format = .{ .sample_format = .signed_32, .sample_rate = 96_000, .channels = 2 },
    });
    try std.testing.expectEqualSlices(
        signal_path.Reason,
        &.{ .sample_rate_conversion, .sample_format_conversion },
        path.reasonList(),
    );
}

test "a float device at the stream rate, or an unknown device format, leaves the verdict alone" {
    const float_device: backend.DeviceFormat = .{
        .sample_format = .float_32,
        .sample_rate = 44_100,
        .channels = 2,
    };
    for ([_]?backend.DeviceFormat{ float_device, null }) |device_format| {
        const path = SignalPath.describe(.{
            .source = test_flac_format,
            .source_declared = true,
            .codec = "flac",
            .replay_gain = 1,
            .equalizer = null,
            .crossfeed = null,
            .volume = 1,
            .output = test_float_format,
            .device_rate = 44_100,
            .device_format = device_format,
        });
        try std.testing.expect(path.bit_perfect_eligible);
        try std.testing.expect(path.widened_exactly);
        try std.testing.expectEqual(device_format, path.device_format);
        try std.testing.expectEqual(@as(usize, 0), path.reasonList().len);
    }
}

test "crossfeed on a layout it does not apply to is not sample processing" {
    var surround = test_float_format;
    surround.channels = 6;
    surround.bytes_per_frame = 24;
    const path = SignalPath.describe(.{
        .source = surround,
        .source_declared = true,
        .codec = null,
        .replay_gain = 1,
        .equalizer = null,
        .crossfeed = 0.3,
        .volume = 1,
        .output = surround,
        .device_rate = null,
    });
    try std.testing.expect(path.bit_perfect_eligible);
}

test "replay gain is reported in decibels" {
    const path = SignalPath.describe(.{
        .source = null,
        .source_declared = false,
        .codec = null,
        .replay_gain = 0.5,
        .equalizer = null,
        .crossfeed = null,
        .volume = 1,
        .output = null,
        .device_rate = null,
    });
    try std.testing.expectApproxEqAbs(@as(f32, -6.0206), path.replay_gain_db.?, 0.001);
}

test "an album correction reports the track correction it replaced" {
    const album = SignalPath.describe(.{
        .source = null,
        .source_declared = false,
        .codec = null,
        .replay_gain = 0.5,
        .replay_gain_source = .album,
        .replay_gain_track = 0.25,
        .equalizer = null,
        .crossfeed = null,
        .volume = 1,
        .output = null,
        .device_rate = null,
    });
    try std.testing.expectEqual(processing.ReplayGainSource.album, album.replay_gain_source);
    try std.testing.expectApproxEqAbs(@as(f32, -6.0206), album.replay_gain_db.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -12.0412), album.replay_gain_track_db.?, 0.001);

    const fallback = SignalPath.describe(.{
        .source = null,
        .source_declared = false,
        .codec = null,
        .replay_gain = 0.25,
        .replay_gain_source = .track_fallback,
        .replay_gain_track = 0.25,
        .equalizer = null,
        .crossfeed = null,
        .volume = 1,
        .output = null,
        .device_rate = null,
    });
    try std.testing.expectEqual(processing.ReplayGainSource.track_fallback, fallback.replay_gain_source);
    try std.testing.expectEqual(@as(?f32, null), fallback.replay_gain_track_db);
}

fn testParametric(filters: []const Filter, preamp_db: f32) ParametricEqualizer {
    var value: ParametricEqualizer = .{ .count = @intCast(filters.len), .preamp_db = preamp_db };
    @memcpy(value.filters[0..filters.len], filters);
    return value;
}

const test_parametric_filters = [_]Filter{
    .{ .kind = .low_shelf, .frequency_hz = 105, .gain_db = 3, .q = 0.71 },
    .{ .kind = .peak, .frequency_hz = 1000, .gain_db = -2, .q = 1.41 },
    .{ .kind = .peak, .frequency_hz = 3000, .gain_db = 2.5, .q = 2 },
    .{ .kind = .high_shelf, .frequency_hz = 10_000, .gain_db = -1.5, .q = 0.71 },
};

test "the parametric cascade applies what its response reports, preamp included" {
    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    const setting = testParametric(&test_parametric_filters, -3);
    try dsp.setParametricEqualizer(setting);
    const frequencies = [_]f32{ 60, 105, 1000, 3000, 10_000 };
    var expected: [frequencies.len]f32 = undefined;
    setting.response(44_100, &frequencies, &expected);
    for (frequencies, expected) |frequency_hz, expected_db|
        try std.testing.expectApproxEqAbs(@as(f64, expected_db), measureGainDb(&dsp, 44_100, frequency_hz), 0.05);
    try std.testing.expectEqual(@as(usize, 4), dsp.filter.band_count);
}

test "filters run in order, and disabled ones and those at zero gain are not built" {
    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    var filters = test_parametric_filters;
    filters[1].enabled = false;
    filters[2].gain_db = 0;
    try dsp.setParametricEqualizer(testParametric(&filters, 0));
    dsp.prepare(48_000, 2, 1);
    try std.testing.expectEqual(@as(usize, 2), dsp.filter.band_count);
    try std.testing.expectEqual(
        equalizer.lowShelfCoefficients(48_000, filters[0].band()),
        dsp.filter.coefficients[0],
    );
    try std.testing.expectEqual(
        equalizer.highShelfCoefficients(48_000, filters[3].band()),
        dsp.filter.coefficients[1],
    );
}

test "a parametric filter at or above 0.45 of the rate is left out of the cascade and the response" {
    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    const filters = [_]Filter{
        .{ .kind = .peak, .frequency_hz = 1000, .gain_db = 4, .q = 1 },
        .{ .kind = .high_shelf, .frequency_hz = 20_000, .gain_db = -6, .q = 0.7 },
    };
    const setting = testParametric(&filters, 0);
    try dsp.setParametricEqualizer(setting);
    dsp.prepare(44_100, 2, 1);
    try std.testing.expectEqual(@as(usize, 1), dsp.filter.band_count);
    dsp.prepare(48_000, 2, 1);
    try std.testing.expectEqual(@as(usize, 2), dsp.filter.band_count);

    const frequencies = [_]f32{ 1000, 15_000 };
    var with_both: [2]f32 = undefined;
    var peak_only: [2]f32 = undefined;
    setting.response(44_100, &frequencies, &with_both);
    testParametric(filters[0..1], 0).response(44_100, &frequencies, &peak_only);
    try std.testing.expectEqualSlices(f32, &peak_only, &with_both);
}

test "a parametric equalizer that changes nothing leaves the volume path untouched" {
    var reference_gain: processing.Gain = .{};
    var dsp_gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&dsp_gain);
    var filters = test_parametric_filters;
    for (&filters) |*filter| filter.gain_db = 0;
    filters[1].kind = .notch;
    filters[1].enabled = false;
    const setting = testParametric(&filters, 0);
    try std.testing.expect(setting.isIdentity());
    try dsp.setParametricEqualizer(setting);

    var expected: [16]f32 = @splat(0.5);
    var actual = expected;
    reference_gain.processor().process(&expected, 8, 2);
    dsp.prepare(44_100, 2, 1);
    dsp.processor().process(&actual, 8, 2);
    try std.testing.expectEqualSlices(f32, &expected, &actual);

    filters[1].enabled = true;
    try std.testing.expect(!testParametric(&filters, 0).isIdentity());
    try std.testing.expect(!testParametric(&.{}, -1).isIdentity());
}

test "the parametric and ten-band equalizers exclude each other" {
    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    const parametric = testParametric(&test_parametric_filters, -3);
    try dsp.setEqualizer(Equalizer.preset(.bass));
    try dsp.setParametricEqualizer(parametric);
    try std.testing.expectEqual(@as(?Equalizer, null), dsp.settings.equalizer);
    try std.testing.expectEqualSlices(Filter, parametric.filterList(), dsp.settings.parametric.?.filterList());

    try dsp.setEqualizer(Equalizer.preset(.treble));
    try std.testing.expectEqual(@as(?ParametricEqualizer, null), dsp.settings.parametric);
    try std.testing.expectEqual(@as(?Equalizer, Equalizer.preset(.treble)), dsp.settings.equalizer);

    try dsp.setParametricEqualizer(null);
    try std.testing.expectEqual(@as(?Equalizer, Equalizer.preset(.treble)), dsp.settings.equalizer);
    try dsp.setParametricEqualizer(parametric);
    try dsp.setEqualizer(null);
    try std.testing.expect(dsp.settings.parametric != null);

    try std.testing.expectApproxEqAbs(@as(f64, -4.92), measureGainDb(&dsp, 44_100, 1000), 0.05);
    try dsp.setEqualizer(.{ .gains_db = gainsWithBand(5, 6) });
    try std.testing.expectApproxEqAbs(@as(f64, 6), measureGainDb(&dsp, 44_100, 1000), 0.1);
}

fn processConstant(dsp: *PlayerDsp, value: f32) [test_block_frames * 2]f32 {
    var block: [test_block_frames * 2]f32 = @splat(value);
    dsp.prepare(48_000, 2, 1);
    dsp.processor().process(&block, test_block_frames, 2);
    return block;
}

const test_silence: [test_block_frames * 2]f32 = @splat(0);
const test_shelf_boost: Filter = .{ .kind = .low_shelf, .frequency_hz = 200, .gain_db = 24, .q = 0.71 };

test "a filter retyped in its slot starts without the old filter's history" {
    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    try dsp.setParametricEqualizer(testParametric(&.{test_shelf_boost}, 0));
    var steady: [test_block_frames * 2]f32 = undefined;
    for (0..16) |_| steady = processConstant(&dsp, 0.5);
    try std.testing.expect(steady[steady.len - 1] > 7.5);

    const high_pass: Filter = .{ .kind = .high_pass, .frequency_hz = 1000, .q = 0.71 };
    try dsp.setParametricEqualizer(testParametric(&.{high_pass}, 0));
    const retyped = processConstant(&dsp, 0.5);
    for (retyped) |sample| try std.testing.expect(@abs(sample) <= 0.5);

    var fresh_gain: processing.Gain = .{};
    var fresh: PlayerDsp = .init(&fresh_gain);
    try fresh.setParametricEqualizer(testParametric(&.{high_pass}, 0));
    try std.testing.expectEqualSlices(f32, &processConstant(&fresh, 0.5), &retyped);
}

test "switching between the equalizers clears the cascade history" {
    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    const peak: Filter = .{ .kind = .peak, .frequency_hz = 1000, .gain_db = 6, .q = 1 };

    try dsp.setEqualizer(.{ .gains_db = gainsWithBand(0, 12) });
    for (0..4) |_| _ = processConstant(&dsp, 0.5);
    try dsp.setParametricEqualizer(testParametric(&.{peak}, 0));
    try std.testing.expectEqualSlices(f32, &test_silence, &processConstant(&dsp, 0));

    for (0..4) |_| _ = processConstant(&dsp, 0.5);
    try dsp.setEqualizer(.{ .gains_db = gainsWithBand(0, 12) });
    try std.testing.expectEqualSlices(f32, &test_silence, &processConstant(&dsp, 0));
}

test "a filter added back to an emptied slot starts without the slot's old history" {
    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    try dsp.setParametricEqualizer(testParametric(&.{test_shelf_boost}, 0));
    for (0..16) |_| _ = processConstant(&dsp, 0.5);
    try dsp.setParametricEqualizer(testParametric(&.{}, -1));
    _ = processConstant(&dsp, 0.5);
    try dsp.setParametricEqualizer(testParametric(&.{test_shelf_boost}, 0));
    try std.testing.expectEqualSlices(f32, &test_silence, &processConstant(&dsp, 0));
}

test "moving a filter's gain, frequency and Q keeps its history, so the move does not click" {
    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    try dsp.setParametricEqualizer(testParametric(&.{test_shelf_boost}, 0));
    var steady: [test_block_frames * 2]f32 = undefined;
    for (0..16) |_| steady = processConstant(&dsp, 0.5);

    var moved = test_shelf_boost;
    moved.gain_db = 23;
    moved.frequency_hz = 250;
    moved.q = 0.8;
    try dsp.setParametricEqualizer(testParametric(&.{moved}, 0));
    const after = processConstant(&dsp, 0.5);
    try std.testing.expectApproxEqAbs(steady[steady.len - 1], after[0], 1);
}

test "turning one filter off keeps the history of the filters after it" {
    const first: Filter = .{ .kind = .low_shelf, .frequency_hz = 100, .gain_db = 12, .q = 0.71 };
    const second: Filter = .{ .kind = .low_shelf, .frequency_hz = 200, .gain_db = 6, .q = 0.71 };
    const third: Filter = .{ .kind = .low_shelf, .frequency_hz = 400, .gain_db = -6, .q = 0.71 };

    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    try dsp.setParametricEqualizer(testParametric(&.{ first, second, third }, 0));
    for (0..16) |_| _ = processConstant(&dsp, 0.5);
    var disabled = first;
    disabled.enabled = false;
    try dsp.setParametricEqualizer(testParametric(&.{ disabled, second, third }, 0));
    const after = processConstant(&dsp, 0.5);

    var reference_gain: processing.Gain = .{};
    var reference: PlayerDsp = .init(&reference_gain);
    try reference.setParametricEqualizer(testParametric(&.{ second, third }, 0));
    var steady: [test_block_frames * 2]f32 = undefined;
    for (0..16) |_| steady = processConstant(&reference, 0.5);
    try std.testing.expectApproxEqAbs(steady[steady.len - 1], after[0], 0.02);
}

test "turning a ten-band band on keeps the history of the bands after it" {
    var gains_db = gainsWithBand(8, 12);
    gains_db[9] = -12;
    var turned_on = gains_db;
    turned_on[0] = 0.01;

    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    try dsp.setEqualizer(.{ .gains_db = gains_db });
    for (0..16) |_| _ = processConstant(&dsp, 0.5);
    try dsp.setEqualizer(.{ .gains_db = turned_on });
    const after = processConstant(&dsp, 0.5);

    var reference_gain: processing.Gain = .{};
    var reference: PlayerDsp = .init(&reference_gain);
    try reference.setEqualizer(.{ .gains_db = turned_on });
    var steady: [test_block_frames * 2]f32 = undefined;
    for (0..16) |_| steady = processConstant(&reference, 0.5);
    try std.testing.expectApproxEqAbs(steady[steady.len - 1], after[0], 0.02);
}

test "parametric validation rejects out-of-range and non-finite values and keeps the last setting" {
    const peak: Filter = .{ .kind = .peak, .frequency_hz = 1000, .gain_db = 3, .q = 1 };
    const Case = struct { filter: Filter, err: anyerror };
    const cases = [_]Case{
        .{ .filter = .{ .kind = .peak, .frequency_hz = 1000, .gain_db = 3, .q = 0 }, .err = error.FilterQOutOfRange },
        .{ .filter = .{ .kind = .peak, .frequency_hz = 1000, .gain_db = 3, .q = 20.5 }, .err = error.FilterQOutOfRange },
        .{ .filter = .{ .kind = .low_shelf, .frequency_hz = 100, .gain_db = 3, .q = 2.5 }, .err = error.FilterQOutOfRange },
        .{ .filter = .{ .kind = .high_shelf, .frequency_hz = 8000, .gain_db = 3, .q = 0.2 }, .err = error.FilterQOutOfRange },
        .{ .filter = .{ .kind = .peak, .frequency_hz = 1000, .gain_db = 25, .q = 1 }, .err = error.FilterGainOutOfRange },
        .{ .filter = .{ .kind = .low_pass, .frequency_hz = 1000, .gain_db = -25, .q = 1 }, .err = error.FilterGainOutOfRange },
        .{ .filter = .{ .kind = .peak, .frequency_hz = 19.9, .gain_db = 3, .q = 1 }, .err = error.FilterFrequencyOutOfRange },
        .{ .filter = .{ .kind = .peak, .frequency_hz = 20_001, .gain_db = 3, .q = 1 }, .err = error.FilterFrequencyOutOfRange },
        .{ .filter = .{ .kind = .peak, .frequency_hz = std.math.nan(f32), .gain_db = 3, .q = 1 }, .err = error.FilterFrequencyOutOfRange },
        .{ .filter = .{ .kind = .peak, .frequency_hz = 1000, .gain_db = std.math.inf(f32), .q = 1 }, .err = error.FilterGainOutOfRange },
        .{ .filter = .{ .kind = .notch, .frequency_hz = 1000, .q = std.math.nan(f32) }, .err = error.FilterQOutOfRange },
    };
    for (cases) |case| {
        var disabled = case.filter;
        disabled.enabled = false;
        try std.testing.expectError(case.err, testParametric(&.{ peak, case.filter }, 0).validate());
        try std.testing.expectError(case.err, testParametric(&.{disabled}, 0).validate());
    }
    try std.testing.expectError(error.ParametricPreampOutOfRange, testParametric(&.{peak}, 7).validate());
    try std.testing.expectError(error.ParametricPreampOutOfRange, testParametric(&.{peak}, -24.5).validate());
    try std.testing.expectError(error.ParametricPreampOutOfRange, testParametric(&.{peak}, std.math.nan(f32)).validate());
    var too_many = testParametric(&.{peak}, 0);
    too_many.count = max_parametric_filters + 1;
    try std.testing.expectError(error.TooManyFilters, too_many.validate());

    try testParametric(&.{
        .{ .kind = .peak, .frequency_hz = 20, .gain_db = -24, .q = 0.1 },
        .{ .kind = .peak, .frequency_hz = 20_000, .gain_db = 24, .q = 20 },
        .{ .kind = .low_shelf, .frequency_hz = 100, .gain_db = 3, .q = 0.3 },
        .{ .kind = .high_shelf, .frequency_hz = 8000, .gain_db = 3, .q = 2 },
    }, 6).validate();
    try testParametric(&.{}, -24).validate();

    var gain: processing.Gain = .{};
    var dsp: PlayerDsp = .init(&gain);
    const kept = testParametric(&.{peak}, -3);
    try dsp.setParametricEqualizer(kept);
    const generation = dsp.generation;
    try std.testing.expectError(
        error.ParametricPreampOutOfRange,
        dsp.setParametricEqualizer(testParametric(&.{peak}, 7)),
    );
    try std.testing.expectEqual(generation, dsp.generation);
    try std.testing.expectEqualSlices(Filter, kept.filterList(), dsp.settings.parametric.?.filterList());
}

test "the suggested preamp is minus the largest boost of an enabled peak or shelf" {
    var filters = test_parametric_filters;
    try std.testing.expectEqual(@as(f32, -3), testParametric(&filters, 0).suggestedPreamp());
    filters[0].enabled = false;
    try std.testing.expectEqual(@as(f32, -2.5), testParametric(&filters, 0).suggestedPreamp());
    const cuts = [_]Filter{
        .{ .kind = .peak, .frequency_hz = 1000, .gain_db = -4, .q = 1 },
        .{ .kind = .low_pass, .frequency_hz = 1000, .gain_db = 9, .q = 1 },
    };
    try std.testing.expectEqual(@as(f32, 0), testParametric(&cuts, 0).suggestedPreamp());
    try std.testing.expectEqual(@as(f32, 0), testParametric(&.{}, 0).suggestedPreamp());
}

test "a parametric equalizer counts as sample processing unless it changes nothing" {
    const identity = testParametric(&.{.{ .kind = .peak, .frequency_hz = 1000, .gain_db = 0, .q = 1 }}, 0);
    const Case = struct { parametric: ParametricEqualizer, processing: bool };
    for ([_]Case{
        .{ .parametric = testParametric(&test_parametric_filters, -3), .processing = true },
        .{ .parametric = testParametric(&.{}, -1), .processing = true },
        .{ .parametric = identity, .processing = false },
    }) |case| {
        const path = SignalPath.describe(.{
            .source = test_float_format,
            .source_declared = true,
            .codec = null,
            .replay_gain = 1,
            .equalizer = null,
            .parametric = case.parametric,
            .crossfeed = null,
            .volume = 1,
            .output = test_float_format,
            .device_rate = null,
        });
        try std.testing.expectEqual(!case.processing, path.bit_perfect_eligible);
        const reasons: []const signal_path.Reason = if (case.processing) &.{.sample_processing} else &.{};
        try std.testing.expectEqualSlices(signal_path.Reason, reasons, path.reasonList());
        try std.testing.expectEqual(case.parametric.count, path.parametric.?.count);
    }
}
