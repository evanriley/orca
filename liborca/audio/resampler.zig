const std = @import("std");

pub const Result = struct {
    input_frames_consumed: usize,
    output_frames_produced: usize,
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
    };

    pub fn init(converter: Converter, input_rate: u32, output_rate: u32, channels: u16) !SampleRate {
        if (input_rate == 0 or output_rate == 0 or channels == 0)
            return error.InvalidResamplerFormat;
        const ratio = ratioOf(input_rate, output_rate);
        if (ratio < 1.0 / 256.0 or ratio > 256.0) return error.InvalidResamplerFormat;
        const native = orca_samplerate_create(@backingInt(converter), channels) orelse
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

    fn ratioOf(input_rate: u32, output_rate: u32) f64 {
        return @as(f64, @floatFromInt(output_rate)) / @as(f64, @floatFromInt(input_rate));
    }

    pub fn process(
        self: *SampleRate,
        input: []const f32,
        output: []f32,
        end_of_input: bool,
    ) !Result {
        if (input.len % self.channels != 0 or output.len % self.channels != 0)
            return error.UnalignedResamplerBuffer;
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

    pub fn reset(self: *SampleRate) void {
        _ = orca_samplerate_reset(self.native);
    }
};

test "libsamplerate converts a whole stream to the new rate and keeps a tone's level" {
    var converter = try SampleRate.init(.sinc_fastest, 44_100, 11_025, 1);
    defer converter.deinit();

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
        const result = try converter.process(input[consumed..], output[produced..], true);
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
    var input: [9600]f32 = @splat(0.25);
    var output: [64]f32 = undefined;
    var consumed: usize = 0;
    var produced: usize = 0;
    while (true) {
        const result = try converter.process(input[consumed * 2 ..], &output, true);
        try std.testing.expect(result.output_frames_produced <= output.len / 2);
        consumed += result.input_frames_consumed;
        produced += result.output_frames_produced;
        if (result.output_frames_produced == 0) break;
    }
    try std.testing.expectEqual(input.len / 2, consumed);
    try std.testing.expect(produced >= 1100 and produced <= 1105);
    try std.testing.expectError(error.UnalignedResamplerBuffer, converter.process(input[0..3], &output, false));
    try std.testing.expectError(error.InvalidResamplerFormat, SampleRate.init(.linear, 11_025, 3_000_000, 1));
}
