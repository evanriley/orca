const std = @import("std");

pub const Quality = enum { draft, standard, high };

pub const Metadata = struct {
    name: []const u8,
    input_rate: u32,
    output_rate: u32,
    channels: u16,
    quality: Quality,
    algorithmic_latency_frames: u32,
    realtime_safe: bool,
};

pub const Result = struct {
    input_frames_consumed: usize,
    output_frames_produced: usize,
};

/// Size-changing DSP boundary. Input and output are caller-owned interleaved
/// buffers; implementations report partial consumption instead of allocating.
pub const Resampler = struct {
    context: *anyopaque,
    process_fn: *const fn (*anyopaque, []const f32, []f32, bool) anyerror!Result,
    reset_fn: *const fn (*anyopaque) void,
    metadata: Metadata,

    pub fn process(
        self: Resampler,
        input: []const f32,
        output: []f32,
        end_of_input: bool,
    ) !Result {
        if (input.len % self.metadata.channels != 0 or
            output.len % self.metadata.channels != 0)
            return error.UnalignedResamplerBuffer;
        return self.process_fn(self.context, input, output, end_of_input);
    }

    pub fn reset(self: Resampler) void {
        self.reset_fn(self.context);
    }
};

/// Numerically simple streaming reference implementation. It is useful for
/// correctness, previews, and drift-control scaffolding; a production-quality
/// band-limited implementation can replace it behind `Resampler`.
pub const Linear = struct {
    input_rate: u32,
    output_rate: u32,
    channels: u16,
    phase: f64 = 0,

    pub fn init(input_rate: u32, output_rate: u32, channels: u16) !Linear {
        if (input_rate == 0 or output_rate == 0 or channels == 0)
            return error.InvalidResamplerFormat;
        return .{ .input_rate = input_rate, .output_rate = output_rate, .channels = channels };
    }

    pub fn resampler(self: *Linear) Resampler {
        return .{
            .context = self,
            .process_fn = process,
            .reset_fn = reset,
            .metadata = .{
                .name = "linear reference resampler",
                .input_rate = self.input_rate,
                .output_rate = self.output_rate,
                .channels = self.channels,
                .quality = .draft,
                .algorithmic_latency_frames = 1,
                .realtime_safe = true,
            },
        };
    }

    fn process(
        context: *anyopaque,
        input: []const f32,
        output: []f32,
        end_of_input: bool,
    ) !Result {
        const self: *Linear = @ptrCast(@alignCast(context));
        const input_frames = input.len / self.channels;
        const output_capacity = output.len / self.channels;
        const step = @as(f64, @floatFromInt(self.input_rate)) /
            @as(f64, @floatFromInt(self.output_rate));
        var produced: usize = 0;
        while (produced < output_capacity) {
            const first: usize = @intFromFloat(@floor(self.phase));
            if (first >= input_frames) break;
            const second = first + 1;
            if (second >= input_frames and !end_of_input) break;
            const fraction: f32 = @floatCast(self.phase - @as(f64, @floatFromInt(first)));
            for (0..self.channels) |channel| {
                const a = input[first * self.channels + channel];
                const b = input[@min(second, input_frames - 1) * self.channels + channel];
                output[produced * self.channels + channel] = a + (b - a) * fraction;
            }
            produced += 1;
            self.phase += step;
        }
        const consumed = @min(@as(usize, @intFromFloat(@floor(self.phase))), input_frames);
        self.phase -= @floatFromInt(consumed);
        return .{ .input_frames_consumed = consumed, .output_frames_produced = produced };
    }

    fn reset(context: *anyopaque) void {
        const self: *Linear = @ptrCast(@alignCast(context));
        self.phase = 0;
    }
};

test "linear reference resampler reports bounded partial consumption" {
    var linear = try Linear.init(24_000, 48_000, 1);
    const resampler = linear.resampler();
    var output: [4]f32 = undefined;
    const result = try resampler.process(&.{ 0, 1, 2 }, &output, false);
    try std.testing.expectEqual(@as(usize, 2), result.input_frames_consumed);
    try std.testing.expectEqual(@as(usize, 4), result.output_frames_produced);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0.5, 1, 1.5 }, &output);
    resampler.reset();
    try std.testing.expectEqual(@as(f64, 0), linear.phase);
}
