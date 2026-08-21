const std = @import("std");
const processing = @import("processing.zig");

/// Simple symmetric stereo crossfeed for headphone listening. Configuration is
/// immutable after publication, avoiding unsmoothed RT parameter changes.
pub const StereoCrossfeed = struct {
    amount: f32,

    pub fn init(amount: f32) !StereoCrossfeed {
        if (!std.math.isFinite(amount) or amount < 0 or amount > 1)
            return error.InvalidCrossfeedAmount;
        return .{ .amount = amount };
    }

    pub fn processor(self: *StereoCrossfeed) processing.Processor {
        return .{
            .context = self,
            .process_fn = process,
            .metadata = .{
                .name = "stereo crossfeed",
                .changes_samples = true,
                .realtime_safe = true,
            },
        };
    }

    fn process(context: *anyopaque, samples: []f32, frames: u32, channels: u16) void {
        if (channels != 2 or samples.len < @as(usize, frames) * 2) return;
        const self: *StereoCrossfeed = @ptrCast(@alignCast(context));
        const normalization = 1 / (1 + self.amount);
        for (0..frames) |frame| {
            const index = frame * 2;
            const left = samples[index];
            const right = samples[index + 1];
            samples[index] = (left + right * self.amount) * normalization;
            samples[index + 1] = (right + left * self.amount) * normalization;
        }
    }
};

/// First-order DC blocker with f64 state and coefficients. State is separate
/// per channel and reset on seeks/discontinuities through the node contract.
pub fn DcBlocker(comptime max_channels: usize) type {
    return struct {
        coefficient: f64,
        previous_input: [max_channels]f64 = @splat(0),
        previous_output: [max_channels]f64 = @splat(0),

        const Self = @This();

        pub fn init(sample_rate: u32, cutoff_hz: f64) !Self {
            if (sample_rate == 0 or max_channels == 0 or !std.math.isFinite(cutoff_hz) or
                cutoff_hz <= 0 or cutoff_hz >= @as(f64, @floatFromInt(sample_rate)) / 2)
                return error.InvalidDcBlockerConfiguration;
            return .{
                .coefficient = @exp(-2 * std.math.pi * cutoff_hz /
                    @as(f64, @floatFromInt(sample_rate))),
            };
        }

        pub fn processor(self: *Self) processing.Processor {
            return .{
                .context = self,
                .process_fn = process,
                .reset_fn = reset,
                .metadata = .{
                    .name = "DC blocker",
                    .changes_samples = true,
                    .realtime_safe = true,
                },
            };
        }

        fn process(context: *anyopaque, samples: []f32, frames: u32, channels: u16) void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (channels == 0 or channels > max_channels or
                samples.len < @as(usize, frames) * channels) return;
            for (0..frames) |frame| {
                for (0..channels) |channel| {
                    const index = frame * channels + channel;
                    const input: f64 = samples[index];
                    const output = input - self.previous_input[channel] +
                        self.coefficient * self.previous_output[channel];
                    self.previous_input[channel] = input;
                    self.previous_output[channel] = output;
                    samples[index] = @floatCast(output);
                }
            }
        }

        fn reset(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.previous_input = @splat(0);
            self.previous_output = @splat(0);
        }
    };
}

test "stereo crossfeed preserves centered material" {
    var crossfeed = try StereoCrossfeed.init(0.25);
    var samples = [_]f32{ 1, 1, 1, -1 };
    crossfeed.processor().process(&samples, 2, 2);
    try std.testing.expectEqualSlices(f32, &.{ 1, 1, 0.6, -0.6 }, &samples);
}

test "DC blocker removes a constant offset and resets history" {
    var blocker = try DcBlocker(2).init(48_000, 20);
    const processor = blocker.processor();
    var samples: [1024]f32 = @splat(0.5);
    processor.process(&samples, 512, 2);
    try std.testing.expect(@abs(samples[samples.len - 1]) < 0.14);
    processor.reset();
    var impulse = [_]f32{ 0.5, 0.5 };
    processor.process(&impulse, 1, 2);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.5 }, &impulse);
}
