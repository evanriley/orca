const std = @import("std");
const liborca = @import("liborca");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const iterations = if (args.len > 1)
        try std.fmt.parseInt(usize, args[1], 10)
    else
        100;
    const sample_count = 1 << 20;
    const scalar = try allocator.alloc(f32, sample_count);
    const vector = try allocator.alloc(f32, sample_count);
    for (scalar, vector, 0..) |*scalar_sample, *vector_sample, index| {
        const value = @as(f32, @floatFromInt(index % 2048)) / 1024 - 1;
        scalar_sample.* = value;
        vector_sample.* = value;
    }

    const scalar_start = std.Io.Clock.awake.now(init.io);
    for (0..iterations) |_| liborca.internal.audio.kernels.gainScalar(scalar, 0.999_99);
    const scalar_ns = scalar_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
    std.mem.doNotOptimizeAway(scalar);

    const vector_start = std.Io.Clock.awake.now(init.io);
    for (0..iterations) |_| liborca.internal.audio.kernels.gainVector(vector, 0.999_99);
    const vector_ns = vector_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
    std.mem.doNotOptimizeAway(vector);

    if (!std.mem.eql(f32, scalar, vector)) return error.DspKernelMismatch;
    const samples_processed = sample_count * iterations;
    std.debug.print(
        "Orca {f} DSP gain benchmark: {d} samples, scalar {d} ps/sample, vector {d} ps/sample, {d:.2}x\n",
        .{
            liborca.version,
            samples_processed,
            @divTrunc(scalar_ns * 1000, samples_processed),
            @divTrunc(vector_ns * 1000, samples_processed),
            @as(f64, @floatFromInt(scalar_ns)) / @as(f64, @floatFromInt(vector_ns)),
        },
    );

    const graphic: liborca.Equalizer = .{
        .gains_db = .{ 3, -2, 4, -3, 2, -4, 3, -2, 4, -3 },
        .preamp_db = -4,
    };
    var parametric: liborca.ParametricEqualizer = .{ .count = liborca.max_parametric_filters, .preamp_db = -6 };
    for (parametric.filters[0..parametric.count], 0..) |*filter, index| {
        const fraction = @as(f32, @floatFromInt(index)) / (liborca.max_parametric_filters - 1);
        filter.* = .{
            .kind = .peak,
            .frequency_hz = 25 * std.math.pow(f32, 640, fraction),
            .gain_db = if (index % 2 == 0) 4 else -3,
            .q = 1.41,
        };
    }
    const graphic_ns = try timeEqualizer(init.io, scalar, iterations, graphic, null);
    const parametric_ns = try timeEqualizer(init.io, scalar, iterations, null, parametric);
    const blocks = (sample_count / (block_frames * channels)) * iterations;
    std.debug.print(
        "Orca {f} DSP equalizer benchmark: {d} blocks of {d} stereo frames, graphic 10-band {d} ns/block, parametric 16-filter {d} ns/block, {d:.2}x\n",
        .{
            liborca.version,
            blocks,
            block_frames,
            @divTrunc(graphic_ns, blocks),
            @divTrunc(parametric_ns, blocks),
            @as(f64, @floatFromInt(parametric_ns)) / @as(f64, @floatFromInt(graphic_ns)),
        },
    );
}

const block_frames = 256;
const channels = 2;

fn timeEqualizer(
    io: std.Io,
    input: []const f32,
    iterations: usize,
    graphic: ?liborca.Equalizer,
    parametric: ?liborca.ParametricEqualizer,
) !i96 {
    const audio = liborca.internal.audio;
    var gain: audio.processing.Gain = .{};
    var dsp: audio.dsp.PlayerDsp = .init(&gain);
    try dsp.setEqualizer(graphic);
    try dsp.setParametricEqualizer(parametric);
    const block_samples = block_frames * channels;
    var block: [block_samples]f32 = undefined;
    const start = std.Io.Clock.awake.now(io);
    for (0..iterations) |_| {
        var offset: usize = 0;
        while (offset + block_samples <= input.len) : (offset += block_samples) {
            @memcpy(&block, input[offset..][0..block_samples]);
            dsp.prepare(48_000, channels, 1);
            dsp.processor().process(&block, block_frames, channels);
            std.mem.doNotOptimizeAway(&block);
        }
    }
    return start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
}
