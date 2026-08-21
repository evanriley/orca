const std = @import("std");
const processing = @import("processing.zig");

pub const PeakingBand = struct {
    frequency_hz: f64,
    gain_db: f64,
    q: f64,
};

const Coefficients = struct {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
};

const State = struct {
    z1: f64 = 0,
    z2: f64 = 0,
};

/// Fixed-capacity cascade of RBJ peaking biquads. Configure it on the control
/// lane before publishing its Processor; processing and reset are allocation-
/// free and safe for a direct RT chain.
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

        pub fn appendPeaking(self: *Self, band: PeakingBand) !void {
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
    };
}

fn peakingCoefficients(sample_rate: u32, band: PeakingBand) Coefficients {
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
