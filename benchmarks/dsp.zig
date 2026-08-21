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
    for (0..iterations) |_| liborca.audio.kernels.gainScalar(scalar, 0.999_99);
    const scalar_ns = scalar_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
    std.mem.doNotOptimizeAway(scalar);

    const vector_start = std.Io.Clock.awake.now(init.io);
    for (0..iterations) |_| liborca.audio.kernels.gainVector(vector, 0.999_99);
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
}
