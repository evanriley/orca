const std = @import("std");
const processing = @import("processing.zig");

pub const Band = struct {
    frequency_hz: f64,
    /// Ignored by the pass and notch designs.
    gain_db: f64 = 0,
    q: f64,
};

/// The highest centre frequency a shelf, pass or notch design accepts, as a
/// fraction of the sample rate. Above it the bilinear transform's warping
/// leaves a design far from its analog prototype.
pub const max_frequency_ratio: f64 = 0.45;
pub const max_gain_db: f64 = 24;

pub fn frequencyInRange(sample_rate: u32, frequency_hz: f64) bool {
    return frequency_hz > 0 and
        frequency_hz < max_frequency_ratio * @as(f64, @floatFromInt(sample_rate));
}

pub const Coefficients = struct {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,

    /// |H| at `frequency_hz`, in decibels, floored at -120 dB so a notch's
    /// zero stays finite.
    pub fn magnitudeDb(self: Coefficients, sample_rate: u32, frequency_hz: f64) f64 {
        const omega = 2 * std.math.pi * frequency_hz / @as(f64, @floatFromInt(sample_rate));
        const cos1 = @cos(omega);
        const sin1 = @sin(omega);
        const cos2 = @cos(2 * omega);
        const sin2 = @sin(2 * omega);
        const numerator_real = self.b0 + self.b1 * cos1 + self.b2 * cos2;
        const numerator_imaginary = self.b1 * sin1 + self.b2 * sin2;
        const denominator_real = 1 + self.a1 * cos1 + self.a2 * cos2;
        const denominator_imaginary = self.a1 * sin1 + self.a2 * sin2;
        const power = (numerator_real * numerator_real + numerator_imaginary * numerator_imaginary) /
            (denominator_real * denominator_real + denominator_imaginary * denominator_imaginary);
        return 10 * std.math.log10(@max(power, 1e-12));
    }
};

const State = struct {
    z1: f64 = 0,
    z2: f64 = 0,
};

/// Fixed-capacity cascade of RBJ biquads. Configure it on the control lane
/// before publishing its Processor; processing and reset are allocation-free
/// and safe for a direct RT chain.
pub fn ParametricEq(comptime max_bands: usize, comptime max_channels: usize) type {
    return struct {
        sample_rate: u32,
        coefficients: [max_bands]Coefficients = undefined,
        states: [max_bands][max_channels]State = @splat(@splat(.{})),
        band_count: usize = 0,

        const Self = @This();

        pub fn init(sample_rate: u32) !Self {
            if (sample_rate == 0 or max_bands == 0 or max_channels == 0)
                return error.InvalidEqualizerConfiguration;
            return .{ .sample_rate = sample_rate };
        }

        pub fn appendPeaking(self: *Self, band: Band) !void {
            if (self.band_count == max_bands) return error.EqualizerBandCapacity;
            if (!std.math.isFinite(band.frequency_hz) or
                !std.math.isFinite(band.gain_db) or
                !std.math.isFinite(band.q) or
                band.frequency_hz <= 0 or
                band.frequency_hz >= @as(f64, @floatFromInt(self.sample_rate)) / 2 or
                band.q <= 0)
                return error.InvalidEqualizerBand;
            self.coefficients[self.band_count] = peakingCoefficients(self.sample_rate, band);
            self.band_count += 1;
        }

        /// A peaking band held to the limits of the other designs: below
        /// `max_frequency_ratio` of the rate and within `max_gain_db`.
        pub fn appendPeak(self: *Self, band: Band) !void {
            return self.appendDesigned(band, peakingCoefficients);
        }

        /// Q form, as EqualizerAPO's `LSC`: the gain is half its value at
        /// `frequency_hz`.
        pub fn appendLowShelf(self: *Self, band: Band) !void {
            return self.appendDesigned(band, lowShelfCoefficients);
        }

        /// Q form, as EqualizerAPO's `HSC`.
        pub fn appendHighShelf(self: *Self, band: Band) !void {
            return self.appendDesigned(band, highShelfCoefficients);
        }

        pub fn appendLowPass(self: *Self, band: Band) !void {
            return self.appendDesigned(band, lowPassCoefficients);
        }

        pub fn appendHighPass(self: *Self, band: Band) !void {
            return self.appendDesigned(band, highPassCoefficients);
        }

        pub fn appendNotch(self: *Self, band: Band) !void {
            return self.appendDesigned(band, notchCoefficients);
        }

        fn appendDesigned(
            self: *Self,
            band: Band,
            comptime design: fn (u32, Band) Coefficients,
        ) !void {
            if (self.band_count == max_bands) return error.EqualizerBandCapacity;
            if (!std.math.isFinite(band.frequency_hz) or
                !std.math.isFinite(band.gain_db) or
                !std.math.isFinite(band.q) or
                !frequencyInRange(self.sample_rate, band.frequency_hz) or
                band.q <= 0 or
                @abs(band.gain_db) > max_gain_db)
                return error.InvalidEqualizerBand;
            self.coefficients[self.band_count] = design(self.sample_rate, band);
            self.band_count += 1;
        }

        pub fn processor(self: *Self) processing.Processor {
            return .{
                .context = self,
                .process_fn = process,
                .reset_fn = reset,
                .metadata = .{
                    .name = "parametric EQ",
                    .changes_samples = true,
                    .realtime_safe = true,
                },
            };
        }

        fn process(context: *anyopaque, samples: []f32, frames: u32, channels: u16) void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (channels == 0 or channels > max_channels or samples.len < frames * channels) return;
            for (0..frames) |frame| {
                const frame_start = frame * channels;
                for (0..channels) |channel| {
                    var value: f64 = samples[frame_start + channel];
                    for (0..self.band_count) |band| {
                        const coefficient = self.coefficients[band];
                        const state = &self.states[band][channel];
                        const output = coefficient.b0 * value + state.z1;
                        state.z1 = coefficient.b1 * value - coefficient.a1 * output + state.z2;
                        state.z2 = coefficient.b2 * value - coefficient.a2 * output;
                        value = output;
                    }
                    samples[frame_start + channel] = @floatCast(value);
                }
            }
        }

        fn reset(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.states = @splat(@splat(.{}));
        }

        pub fn resetBand(self: *Self, index: usize) void {
            self.states[index] = @splat(.{});
        }
    };
}

pub fn peakingCoefficients(sample_rate: u32, band: Band) Coefficients {
    const amplitude = std.math.pow(f64, 10, band.gain_db / 40);
    const omega = 2 * std.math.pi * band.frequency_hz /
        @as(f64, @floatFromInt(sample_rate));
    const alpha = @sin(omega) / (2 * band.q);
    const cosine = @cos(omega);
    const a0 = 1 + alpha / amplitude;
    return .{
        .b0 = (1 + alpha * amplitude) / a0,
        .b1 = (-2 * cosine) / a0,
        .b2 = (1 - alpha * amplitude) / a0,
        .a1 = (-2 * cosine) / a0,
        .a2 = (1 - alpha / amplitude) / a0,
    };
}

const Design = struct {
    amplitude: f64,
    cosine: f64,
    alpha: f64,

    fn of(sample_rate: u32, band: Band) Design {
        const omega = 2 * std.math.pi * band.frequency_hz /
            @as(f64, @floatFromInt(sample_rate));
        return .{
            .amplitude = std.math.pow(f64, 10, band.gain_db / 40),
            .cosine = @cos(omega),
            .alpha = @sin(omega) / (2 * band.q),
        };
    }
};

fn normalized(b0: f64, b1: f64, b2: f64, a0: f64, a1: f64, a2: f64) Coefficients {
    return .{ .b0 = b0 / a0, .b1 = b1 / a0, .b2 = b2 / a0, .a1 = a1 / a0, .a2 = a2 / a0 };
}

pub fn lowShelfCoefficients(sample_rate: u32, band: Band) Coefficients {
    const d: Design = .of(sample_rate, band);
    const a = d.amplitude;
    const root_alpha = 2 * @sqrt(a) * d.alpha;
    return normalized(
        a * ((a + 1) - (a - 1) * d.cosine + root_alpha),
        2 * a * ((a - 1) - (a + 1) * d.cosine),
        a * ((a + 1) - (a - 1) * d.cosine - root_alpha),
        (a + 1) + (a - 1) * d.cosine + root_alpha,
        -2 * ((a - 1) + (a + 1) * d.cosine),
        (a + 1) + (a - 1) * d.cosine - root_alpha,
    );
}

pub fn highShelfCoefficients(sample_rate: u32, band: Band) Coefficients {
    const d: Design = .of(sample_rate, band);
    const a = d.amplitude;
    const root_alpha = 2 * @sqrt(a) * d.alpha;
    return normalized(
        a * ((a + 1) + (a - 1) * d.cosine + root_alpha),
        -2 * a * ((a - 1) + (a + 1) * d.cosine),
        a * ((a + 1) + (a - 1) * d.cosine - root_alpha),
        (a + 1) - (a - 1) * d.cosine + root_alpha,
        2 * ((a - 1) - (a + 1) * d.cosine),
        (a + 1) - (a - 1) * d.cosine - root_alpha,
    );
}

pub fn lowPassCoefficients(sample_rate: u32, band: Band) Coefficients {
    const d: Design = .of(sample_rate, band);
    return normalized(
        (1 - d.cosine) / 2,
        1 - d.cosine,
        (1 - d.cosine) / 2,
        1 + d.alpha,
        -2 * d.cosine,
        1 - d.alpha,
    );
}

pub fn highPassCoefficients(sample_rate: u32, band: Band) Coefficients {
    const d: Design = .of(sample_rate, band);
    return normalized(
        (1 + d.cosine) / 2,
        -(1 + d.cosine),
        (1 + d.cosine) / 2,
        1 + d.alpha,
        -2 * d.cosine,
        1 - d.alpha,
    );
}

pub fn notchCoefficients(sample_rate: u32, band: Band) Coefficients {
    const d: Design = .of(sample_rate, band);
    return normalized(1, -2 * d.cosine, 1, 1 + d.alpha, -2 * d.cosine, 1 - d.alpha);
}

test "zero-gain parametric EQ is transparent and reset is deterministic" {
    var equalizer = try ParametricEq(4, 2).init(48_000);
    try equalizer.appendPeaking(.{ .frequency_hz = 1000, .gain_db = 0, .q = 0.707 });
    const processor = equalizer.processor();
    const input = [_]f32{ 1, 0, 0.5, -0.5, 0, 0 };
    var first = input;
    processor.process(&first, 3, 2);
    for (input, first) |expected, actual|
        try std.testing.expectApproxEqAbs(expected, actual, 0.000_001);

    processor.reset();
    var second = input;
    processor.process(&second, 3, 2);
    try std.testing.expectEqualSlices(f32, &first, &second);
}

test "parametric EQ keeps channel histories independent" {
    var equalizer = try ParametricEq(1, 2).init(48_000);
    try equalizer.appendPeaking(.{ .frequency_hz = 2000, .gain_db = 6, .q = 1 });
    var samples = [_]f32{ 1, 0, 0, 0, 0, 0, 0, 0 };
    equalizer.processor().process(&samples, 4, 2);
    for (samples[1..], 1..) |sample, index| {
        if (index % 2 == 1) try std.testing.expectEqual(@as(f32, 0), sample);
    }
}

const TestCascade = ParametricEq(1, 1);

fn measuredGainDb(cascade: *TestCascade, frequency_hz: f64) f64 {
    const sample_rate = cascade.sample_rate;
    const amplitude = 0.25;
    var block: [256]f32 = undefined;
    var square_sum: f64 = 0;
    var measured: usize = 0;
    var frame: usize = 0;
    cascade.processor().reset();
    while (frame < sample_rate) {
        const frames: usize = @min(block.len, sample_rate - frame);
        for (block[0..frames], 0..) |*sample, index| {
            const phase = 2 * std.math.pi * frequency_hz *
                @as(f64, @floatFromInt(frame + index)) / @as(f64, @floatFromInt(sample_rate));
            sample.* = @floatCast(amplitude * @sin(phase));
        }
        cascade.processor().process(block[0..frames], @intCast(frames), 1);
        for (block[0..frames], 0..) |sample, index| {
            if (frame + index < sample_rate / 2) continue;
            square_sum += @as(f64, sample) * sample;
            measured += 1;
        }
        frame += frames;
    }
    const rms = @sqrt(square_sum / @as(f64, @floatFromInt(measured)));
    return 20 * std.math.log10(rms / (amplitude / @sqrt(2.0)));
}

fn designed(
    comptime append: fn (*TestCascade, Band) anyerror!void,
    band: Band,
) !TestCascade {
    var cascade = try TestCascade.init(48_000);
    try append(&cascade, band);
    return cascade;
}

test "each design has its defining gain at its centre frequency, measured and computed alike" {
    const centre = 1000;
    const cases = [_]struct {
        cascade: TestCascade,
        at_centre_db: f64,
        at_10_hz_db: f64,
        at_10_khz_db: f64,
    }{
        .{
            .cascade = try designed(TestCascade.appendPeak, .{ .frequency_hz = centre, .gain_db = 6, .q = 1 }),
            .at_centre_db = 6,
            .at_10_hz_db = 0.0006,
            .at_10_khz_db = 0.0476,
        },
        .{
            .cascade = try designed(TestCascade.appendLowShelf, .{ .frequency_hz = centre, .gain_db = 6, .q = 0.707 }),
            .at_centre_db = 3,
            .at_10_hz_db = 6,
            .at_10_khz_db = 0.0004,
        },
        .{
            .cascade = try designed(TestCascade.appendHighShelf, .{ .frequency_hz = centre, .gain_db = -6, .q = 0.707 }),
            .at_centre_db = -3,
            .at_10_hz_db = 0,
            .at_10_khz_db = -5.9996,
        },
        .{
            .cascade = try designed(TestCascade.appendLowPass, .{ .frequency_hz = centre, .q = 0.707 }),
            .at_centre_db = -3.01,
            .at_10_hz_db = 0,
            .at_10_khz_db = -42.7383,
        },
        .{
            .cascade = try designed(TestCascade.appendHighPass, .{ .frequency_hz = centre, .q = 0.707 }),
            .at_centre_db = -3.01,
            .at_10_hz_db = -80.0248,
            .at_10_khz_db = -0.0003,
        },
    };
    for (cases) |case| {
        var cascade = case.cascade;
        const coefficients = cascade.coefficients[0];
        try std.testing.expectApproxEqAbs(case.at_centre_db, measuredGainDb(&cascade, centre), 0.05);
        try std.testing.expectApproxEqAbs(case.at_centre_db, coefficients.magnitudeDb(48_000, centre), 0.05);
        try std.testing.expectApproxEqAbs(case.at_10_hz_db, coefficients.magnitudeDb(48_000, 10), 0.001);
        try std.testing.expectApproxEqAbs(case.at_10_khz_db, coefficients.magnitudeDb(48_000, 10_000), 0.001);
    }

    var notch = try designed(TestCascade.appendNotch, .{ .frequency_hz = centre, .q = 0.707 });
    try std.testing.expect(measuredGainDb(&notch, centre) < -60);
    try std.testing.expect(notch.coefficients[0].magnitudeDb(48_000, centre) < -100);
    try std.testing.expectApproxEqAbs(@as(f64, 0), notch.coefficients[0].magnitudeDb(48_000, 10), 0.01);
}

test "the designs reject a centre at or above 0.45 of the rate, a Q of zero, a gain past 24 dB and non-finite values" {
    const appends = [_]*const fn (*TestCascade, Band) anyerror!void{
        TestCascade.appendPeak,
        TestCascade.appendLowShelf,
        TestCascade.appendHighShelf,
        TestCascade.appendLowPass,
        TestCascade.appendHighPass,
        TestCascade.appendNotch,
    };
    const rejected = [_]Band{
        .{ .frequency_hz = 0.45 * 48_000, .gain_db = 3, .q = 1 },
        .{ .frequency_hz = 30_000, .gain_db = 3, .q = 1 },
        .{ .frequency_hz = 0, .gain_db = 3, .q = 1 },
        .{ .frequency_hz = 1000, .gain_db = 3, .q = 0 },
        .{ .frequency_hz = 1000, .gain_db = 25, .q = 1 },
        .{ .frequency_hz = 1000, .gain_db = -25, .q = 1 },
        .{ .frequency_hz = std.math.nan(f64), .gain_db = 3, .q = 1 },
        .{ .frequency_hz = 1000, .gain_db = std.math.inf(f64), .q = 1 },
        .{ .frequency_hz = 1000, .gain_db = 3, .q = std.math.nan(f64) },
    };
    for (appends) |append| {
        var cascade = try TestCascade.init(48_000);
        for (rejected) |band|
            try std.testing.expectError(error.InvalidEqualizerBand, append(&cascade, band));
        try std.testing.expectEqual(@as(usize, 0), cascade.band_count);
        try append(&cascade, .{ .frequency_hz = 0.45 * 48_000 - 1, .gain_db = 24, .q = 1 });
        try std.testing.expectError(
            error.EqualizerBandCapacity,
            append(&cascade, .{ .frequency_hz = 1000, .q = 1 }),
        );
    }
}
