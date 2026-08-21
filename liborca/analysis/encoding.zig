const std = @import("std");
const diagnostics = @import("diagnostics.zig");

const magic = "ORAD";
const version: u16 = 1;
const header_size = 64;

pub fn encode(allocator: std.mem.Allocator, result: diagnostics.Result) ![]u8 {
    const bytes = try allocator.alloc(u8, header_size + result.waveform.len * 8);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], magic);
    writeInt(u16, bytes[4..6], version);
    writeInt(u16, bytes[6..8], if (result.integrated_lufs != null) 1 else 0);
    writeFloat(bytes[8..12], result.integrated_lufs orelse 0);
    writeFloat(bytes[12..16], result.replay_gain_db orelse 0);
    writeFloat(bytes[16..20], result.sample_peak);
    writeFloat(bytes[20..24], result.rms);
    writeInt(u64, bytes[24..32], result.clipped_samples);
    writeInt(u64, bytes[32..40], result.silent_frames);
    writeInt(u64, bytes[40..48], result.leading_silence_frames);
    writeInt(u64, bytes[48..56], result.trailing_silence_frames);
    writeInt(u32, bytes[56..60], @intCast(result.waveform.len));
    for (result.waveform, 0..) |bucket, index| {
        const offset = header_size + index * 8;
        writeFloat(bytes[offset..][0..4], bucket.minimum);
        writeFloat(bytes[offset + 4 ..][0..4], bucket.maximum);
    }
    return bytes;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !diagnostics.Result {
    if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..4], magic))
        return error.InvalidAnalysisResult;
    if (readInt(u16, bytes[4..6]) != version) return error.UnsupportedAnalysisResultVersion;
    const bucket_count = readInt(u32, bytes[56..60]);
    if (bucket_count > 1_000_000 or bytes.len != header_size + @as(usize, bucket_count) * 8)
        return error.InvalidAnalysisResult;
    const waveform = try allocator.alloc(diagnostics.WaveformBucket, bucket_count);
    errdefer allocator.free(waveform);
    for (waveform, 0..) |*bucket, index| {
        const offset = header_size + index * 8;
        bucket.* = .{
            .minimum = readFloat(bytes[offset..][0..4]),
            .maximum = readFloat(bytes[offset + 4 ..][0..4]),
        };
    }
    const has_loudness = readInt(u16, bytes[6..8]) & 1 != 0;
    return .{
        .allocator = allocator,
        .integrated_lufs = if (has_loudness) readFloat(bytes[8..12]) else null,
        .replay_gain_db = if (has_loudness) readFloat(bytes[12..16]) else null,
        .sample_peak = readFloat(bytes[16..20]),
        .rms = readFloat(bytes[20..24]),
        .clipped_samples = readInt(u64, bytes[24..32]),
        .silent_frames = readInt(u64, bytes[32..40]),
        .leading_silence_frames = readInt(u64, bytes[40..48]),
        .trailing_silence_frames = readInt(u64, bytes[48..56]),
        .waveform = waveform,
    };
}

pub fn parameterHash(parameters: diagnostics.Parameters) [32]u8 {
    var encoded: [12]u8 = undefined;
    writeFloat(encoded[0..4], parameters.silence_threshold);
    writeFloat(encoded[4..8], parameters.replay_gain_target_lufs);
    writeInt(u32, encoded[8..12], parameters.waveform_buckets);
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(&encoded, &digest, .{});
    return digest;
}

fn writeFloat(destination: []u8, value: f32) void {
    writeInt(u32, destination, @bitCast(value));
}

fn readFloat(source: []const u8) f32 {
    return @bitCast(readInt(u32, source));
}

fn writeInt(comptime T: type, destination: []u8, value: T) void {
    std.mem.writeInt(T, destination[0..@sizeOf(T)], value, .little);
}

fn readInt(comptime T: type, source: []const u8) T {
    return std.mem.readInt(T, source[0..@sizeOf(T)], .little);
}

test "diagnostic result encoding is versioned and portable" {
    const allocator = std.testing.allocator;
    const waveform = try allocator.dupe(diagnostics.WaveformBucket, &.{
        .{ .minimum = -0.75, .maximum = 0.5 },
        .{ .minimum = -0.25, .maximum = 1 },
    });
    const original: diagnostics.Result = .{
        .allocator = allocator,
        .integrated_lufs = -14.2,
        .replay_gain_db = -3.8,
        .sample_peak = 1,
        .rms = 0.25,
        .clipped_samples = 4,
        .silent_frames = 5,
        .leading_silence_frames = 2,
        .trailing_silence_frames = 3,
        .waveform = waveform,
    };
    defer original.deinit();
    const bytes = try encode(allocator, original);
    defer allocator.free(bytes);
    const restored = try decode(allocator, bytes);
    defer restored.deinit();
    try std.testing.expectEqual(original.clipped_samples, restored.clipped_samples);
    try std.testing.expectEqual(original.integrated_lufs, restored.integrated_lufs);
    try std.testing.expectEqualSlices(
        diagnostics.WaveformBucket,
        original.waveform,
        restored.waveform,
    );
}
