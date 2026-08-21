const std = @import("std");

const vector_width = 8;
const Vector = @Vector(vector_width, f32);
const AccumulatorVector = @Vector(vector_width, f64);

pub fn gainScalar(samples: []f32, linear: f32) void {
    for (samples) |*sample| sample.* *= linear;
}

pub fn gainVector(samples: []f32, linear: f32) void {
    const multiplier: Vector = @splat(linear);
    var index: usize = 0;
    while (index + vector_width <= samples.len) : (index += vector_width) {
        const chunk: *[vector_width]f32 = samples[index..][0..vector_width];
        const values: Vector = chunk.*;
        chunk.* = values * multiplier;
    }
    gainScalar(samples[index..], linear);
}

pub fn gain(samples: []f32, linear: f32) void {
    if (samples.len >= vector_width) return gainVector(samples, linear);
    gainScalar(samples, linear);
}

pub const Levels = struct { peak: f32, square_sum: f64 };

pub fn levelsScalar(samples: []const f32) Levels {
    var result: Levels = .{ .peak = 0, .square_sum = 0 };
    for (samples) |sample| {
        result.peak = @max(result.peak, @abs(sample));
        result.square_sum += @as(f64, sample) * sample;
    }
    return result;
}

pub fn levelsVector(samples: []const f32) Levels {
    var peak: Vector = @splat(0);
    var squares: AccumulatorVector = @splat(0);
    var index: usize = 0;
    while (index + vector_width <= samples.len) : (index += vector_width) {
        const chunk: *const [vector_width]f32 = samples[index..][0..vector_width];
        const values: Vector = chunk.*;
        peak = @max(peak, @abs(values));
        const precise: AccumulatorVector = @floatCast(values);
        squares += precise * precise;
    }
    const tail = levelsScalar(samples[index..]);
    return .{
        .peak = @max(@reduce(.Max, peak), tail.peak),
        .square_sum = @reduce(.Add, squares) + tail.square_sum,
    };
}

test "vector gain matches scalar reference including tail" {
    var scalar: [37]f32 = undefined;
    for (&scalar, 0..) |*sample, index| sample.* = @as(f32, @floatFromInt(index)) / 37 - 0.5;
    var vector = scalar;
    gainScalar(&scalar, 0.713);
    gainVector(&vector, 0.713);
    try std.testing.expectEqualSlices(f32, &scalar, &vector);
}

test "vector levels match scalar reference" {
    var samples: [37]f32 = undefined;
    for (&samples, 0..) |*sample, index| sample.* = @as(f32, @floatFromInt(index)) / 11 - 1.5;
    const scalar = levelsScalar(&samples);
    const vector = levelsVector(&samples);
    try std.testing.expectEqual(scalar.peak, vector.peak);
    try std.testing.expectApproxEqAbs(scalar.square_sum, vector.square_sum, 0.000_01);
}
