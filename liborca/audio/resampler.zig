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

extern fn orca_samplerate_create(converter: i32, channels: u32) ?*anyopaque;
extern fn orca_samplerate_destroy(state: ?*anyopaque) void;
extern fn orca_samplerate_process(
    state: ?*anyopaque,
    input: [*]const f32,
    input_frames: u64,
    output: [*]f32,
    output_frames: u64,
    ratio: f64,
    end_of_input: i32,
    input_used: *u64,
    output_generated: *u64,
) i32;
extern fn orca_samplerate_reset(state: ?*anyopaque) i32;

/// libsamplerate behind `samplerate_shim.c`: band-limited conversion between
/// any two rates libsamplerate accepts, a ratio within 1/256 to 256.
pub const SampleRate = struct {
    native: *anyopaque,
    converter: Converter,
    input_rate: u32,
    output_rate: u32,
    channels: u16,

    /// libsamplerate's converters, fastest last. The values are the shim's.
    pub const Converter = enum(i32) {
        sinc_best = 0,
        sinc_medium = 1,
        sinc_fastest = 2,
        zero_order_hold = 3,
        linear = 4,

        pub fn name(self: Converter) []const u8 {
            return switch (self) {
                .sinc_best => "libsamplerate sinc best",
                .sinc_medium => "libsamplerate sinc medium",
                .sinc_fastest => "libsamplerate sinc fastest",
                .zero_order_hold => "libsamplerate zero-order hold",
                .linear => "libsamplerate linear",
            };
        }

        pub fn quality(self: Converter) Quality {
            return switch (self) {
                .sinc_best => .high,
                .sinc_medium, .sinc_fastest => .standard,
                .zero_order_hold, .linear => .draft,
            };
        }
    };

    pub fn init(converter: Converter, input_rate: u32, output_rate: u32, channels: u16) !SampleRate {
        if (input_rate == 0 or output_rate == 0 or channels == 0)
            return error.InvalidResamplerFormat;
        const ratio = ratioOf(input_rate, output_rate);
        if (ratio < 1.0 / 256.0 or ratio > 256.0) return error.InvalidResamplerFormat;
        const native = orca_samplerate_create(@intFromEnum(converter), channels) orelse
            return error.ResamplerUnavailable;
        return .{
            .native = native,
            .converter = converter,
            .input_rate = input_rate,
            .output_rate = output_rate,
            .channels = channels,
        };
    }

    pub fn deinit(self: *SampleRate) void {
        orca_samplerate_destroy(self.native);
        self.* = undefined;
    }

    pub fn resampler(self: *SampleRate) Resampler {
        return .{
            .context = self,
            .process_fn = process,
            .reset_fn = reset,
            .metadata = .{
                .name = self.converter.name(),
                .input_rate = self.input_rate,
                .output_rate = self.output_rate,
                .channels = self.channels,
                .quality = self.converter.quality(),
                .algorithmic_latency_frames = 0,
                .realtime_safe = false,
            },
        };
    }

    fn ratioOf(input_rate: u32, output_rate: u32) f64 {
        return @as(f64, @floatFromInt(output_rate)) / @as(f64, @floatFromInt(input_rate));
    }

    fn process(
        context: *anyopaque,
        input: []const f32,
        output: []f32,
        end_of_input: bool,
    ) !Result {
        const self: *SampleRate = @ptrCast(@alignCast(context));
        var input_used: u64 = 0;
        var output_generated: u64 = 0;
        if (orca_samplerate_process(
            self.native,
            input.ptr,
            input.len / self.channels,
            output.ptr,
            output.len / self.channels,
            ratioOf(self.input_rate, self.output_rate),
            @intFromBool(end_of_input),
            &input_used,
            &output_generated,
        ) != 0) return error.ResamplingFailed;
        return .{
            .input_frames_consumed = @intCast(input_used),
            .output_frames_produced = @intCast(output_generated),
        };
    }

    fn reset(context: *anyopaque) void {
        const self: *SampleRate = @ptrCast(@alignCast(context));
        _ = orca_samplerate_reset(self.native);
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

test "libsamplerate converts a whole stream to the new rate and keeps a tone's level" {
    var converter = try SampleRate.init(.sinc_fastest, 44_100, 11_025, 1);
    defer converter.deinit();
    const resampler = converter.resampler();
    try std.testing.expectEqualStrings("libsamplerate sinc fastest", resampler.metadata.name);

    const input = try std.testing.allocator.alloc(f32, 44_100);
    defer std.testing.allocator.free(input);
    for (input, 0..) |*sample, index| {
        const time = @as(f32, @floatFromInt(index)) / 44_100.0;
        sample.* = 0.5 * @sin(2.0 * std.math.pi * 1000.0 * time);
    }
    var output: [12_000]f32 = undefined;
    var consumed: usize = 0;
    var produced: usize = 0;
    while (true) {
        const result = try resampler.process(input[consumed..], output[produced..], true);
        consumed += result.input_frames_consumed;
        produced += result.output_frames_produced;
        if (result.output_frames_produced == 0) break;
    }
    try std.testing.expectEqual(input.len, consumed);
    try std.testing.expect(produced >= 11_020 and produced <= 11_030);
    var energy: f64 = 0;
    for (output[1000..10_000]) |sample| energy += sample * sample;
    const rms = @sqrt(energy / 9000.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5 / @sqrt(2.0)), rms, 0.01);
}

test "libsamplerate fills no more than the output it is given, and refuses an impossible ratio" {
    var converter = try SampleRate.init(.sinc_medium, 48_000, 11_025, 2);
    defer converter.deinit();
    const resampler = converter.resampler();
    var input: [9600]f32 = @splat(0.25);
    var output: [64]f32 = undefined;
    var consumed: usize = 0;
    var produced: usize = 0;
    while (true) {
        const result = try resampler.process(input[consumed * 2 ..], &output, true);
        try std.testing.expect(result.output_frames_produced <= output.len / 2);
        consumed += result.input_frames_consumed;
        produced += result.output_frames_produced;
        if (result.output_frames_produced == 0) break;
    }
    try std.testing.expectEqual(input.len / 2, consumed);
    try std.testing.expect(produced >= 1100 and produced <= 1105);
    try std.testing.expectError(error.UnalignedResamplerBuffer, resampler.process(input[0..3], &output, false));
    try std.testing.expectError(error.InvalidResamplerFormat, SampleRate.init(.linear, 11_025, 3_000_000, 1));
}
