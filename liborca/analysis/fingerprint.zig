const std = @import("std");
const decoder = @import("../codec/decoder.zig");

/// What a decoded-audio hash was taken over. Only two `lossless_integer`
/// hashes can establish that two files hold identical audio; a
/// `decoded_float` hash is one decoder's rendering of a lossy or float source.
/// Hashes of different tiers never compare equal.
pub const AudioHashTier = enum(u8) {
    lossless_integer = 1,
    decoded_float = 2,
};

pub const AudioHash = struct {
    digest: [32]u8,
    tier: AudioHashTier,
    /// Bits in use once samples are left-justified in 32: 16 for 16-bit audio
    /// stored in a 24-bit container. Zero for a `decoded_float` hash or
    /// all-silent audio.
    effective_bits: u8,

    pub fn eql(self: AudioHash, other: AudioHash) bool {
        return self.tier == other.tier and std.mem.eql(u8, &self.digest, &other.digest);
    }
};

pub const audio_hash_version: u16 = 2;

/// ORAH version 2: BLAKE3 over a 21-byte header followed by the 32-byte
/// BLAKE3 digest of the interleaved little-endian samples. The header is
/// "ORAH", u16 version, u8 tier, u32 sample rate, u8 channels, u8 layout (0,
/// interleaved in source order) and u64 frames, all little-endian. The frame
/// count is known only once the stream ends, so the header commits to the
/// sample digest rather than prefixing the samples. A `lossless_integer` hash
/// takes each sample as an i32 left-justified in 32 bits; a `decoded_float`
/// hash takes each f32's bits.
pub const AudioHasher = struct {
    tier: AudioHashTier,
    sample_rate: u32,
    channels: u8,
    frames: u64 = 0,
    used_bits: u32 = 0,
    samples: std.crypto.hash.Blake3 = .init(.{}),

    const chunk_samples = 256;

    pub fn init(tier: AudioHashTier, sample_rate: u32, channels: u16) !AudioHasher {
        if (sample_rate == 0 or channels == 0) return error.InvalidAudioFormat;
        return .{
            .tier = tier,
            .sample_rate = sample_rate,
            .channels = std.math.cast(u8, channels) orelse return error.InvalidAudioFormat,
        };
    }

    pub fn updateIntegers(self: *AudioHasher, samples: []const i32) !void {
        if (self.tier != .lossless_integer) return error.AudioHashTierMismatch;
        if (samples.len % self.channels != 0) return error.IncompleteAudioFrame;
        var encoded: [chunk_samples * 4]u8 = undefined;
        var index: usize = 0;
        while (index < samples.len) {
            const chunk = samples[index..@min(samples.len, index + chunk_samples)];
            for (chunk, 0..) |sample, offset| {
                self.used_bits |= @bitCast(sample);
                std.mem.writeInt(i32, encoded[offset * 4 ..][0..4], sample, .little);
            }
            self.samples.update(encoded[0 .. chunk.len * 4]);
            index += chunk.len;
        }
        self.frames += samples.len / self.channels;
    }

    pub fn updateFloats(self: *AudioHasher, samples: []const f32) !void {
        if (self.tier != .decoded_float) return error.AudioHashTierMismatch;
        if (samples.len % self.channels != 0) return error.IncompleteAudioFrame;
        var encoded: [chunk_samples * 4]u8 = undefined;
        var index: usize = 0;
        while (index < samples.len) {
            const chunk = samples[index..@min(samples.len, index + chunk_samples)];
            for (chunk, 0..) |sample, offset|
                std.mem.writeInt(u32, encoded[offset * 4 ..][0..4], @bitCast(sample), .little);
            self.samples.update(encoded[0 .. chunk.len * 4]);
            index += chunk.len;
        }
        self.frames += samples.len / self.channels;
    }

    pub fn finish(self: *AudioHasher) AudioHash {
        var header: [21]u8 = undefined;
        @memcpy(header[0..4], "ORAH");
        std.mem.writeInt(u16, header[4..6], audio_hash_version, .little);
        header[6] = @backingInt(self.tier);
        std.mem.writeInt(u32, header[7..11], self.sample_rate, .little);
        header[11] = self.channels;
        header[12] = 0;
        std.mem.writeInt(u64, header[13..21], self.frames, .little);
        var sample_digest: [32]u8 = undefined;
        self.samples.final(&sample_digest);
        var outer = std.crypto.hash.Blake3.init(.{});
        outer.update(&header);
        outer.update(&sample_digest);
        var digest: [32]u8 = undefined;
        outer.final(&digest);
        return .{
            .digest = digest,
            .tier = self.tier,
            .effective_bits = if (self.tier != .lossless_integer or self.used_bits == 0)
                0
            else
                @intCast(32 - @as(u32, @ctz(self.used_bits))),
        };
    }
};

/// A compact, provider-independent temporal fingerprint. The signatures are
/// deliberately retained alongside their digest so likely matches can be
/// ranked rather than treated as exact identifiers.
pub const Result = struct {
    allocator: std.mem.Allocator,
    signatures: []u16,
    digest: [32]u8,
    audio_hash: AudioHash,

    pub fn deinit(self: Result) void {
        self.allocator.free(self.signatures);
    }
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    channels: u16,
    frames_per_block: u32,
    signatures: std.ArrayList(u16) = .empty,
    audio_hasher: AudioHasher,
    frames_in_block: u32 = 0,
    energy: f64 = 0,
    difference_energy: f64 = 0,
    peak: f32 = 0,
    zero_crossings: u32 = 0,
    previous: f32 = 0,
    has_previous: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        sample_rate: u32,
        channels: u16,
        tier: AudioHashTier,
    ) !Analyzer {
        return .{
            .allocator = allocator,
            .channels = channels,
            .frames_per_block = @max(1, sample_rate / 20),
            .audio_hasher = try AudioHasher.init(tier, sample_rate, channels),
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.signatures.deinit(self.allocator);
        self.* = undefined;
    }

    /// Samples from a `decoded_float` source.
    pub fn process(self: *Analyzer, samples: []const f32) !void {
        try self.audio_hasher.updateFloats(samples);
        try self.measure(f32, samples);
    }

    /// Samples from a `lossless_integer` source, left-justified in 32 bits.
    pub fn processIntegers(self: *Analyzer, samples: []const i32) !void {
        try self.audio_hasher.updateIntegers(samples);
        try self.measure(i32, samples);
    }

    fn measure(self: *Analyzer, comptime T: type, samples: []const T) !void {
        var index: usize = 0;
        while (index < samples.len) {
            var mono: f32 = 0;
            for (0..self.channels) |_| {
                const sample: f32 = if (T == i32)
                    decoder.integerSampleToFloat(samples[index])
                else
                    samples[index];
                index += 1;
                mono += sample / @as(f32, @floatFromInt(self.channels));
            }
            self.energy += @as(f64, mono) * mono;
            self.peak = @max(self.peak, @abs(mono));
            if (self.has_previous) {
                const difference = mono - self.previous;
                self.difference_energy += @as(f64, difference) * difference;
                if ((mono < 0) != (self.previous < 0)) self.zero_crossings += 1;
            }
            self.previous = mono;
            self.has_previous = true;
            self.frames_in_block += 1;
            if (self.frames_in_block == self.frames_per_block) try self.flushBlock();
        }
    }

    pub fn finish(self: *Analyzer) !Result {
        if (self.frames_in_block > 0) try self.flushBlock();
        if (self.signatures.items.len == 0) return error.NoAudioSamples;
        const owned = try self.signatures.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned);
        var fingerprint_hasher = std.crypto.hash.Blake3.init(.{});
        for (owned) |signature| {
            var encoded: [2]u8 = undefined;
            std.mem.writeInt(u16, &encoded, signature, .little);
            fingerprint_hasher.update(&encoded);
        }
        var digest: [32]u8 = undefined;
        fingerprint_hasher.final(&digest);
        return .{
            .allocator = self.allocator,
            .signatures = owned,
            .digest = digest,
            .audio_hash = self.audio_hasher.finish(),
        };
    }

    fn flushBlock(self: *Analyzer) !void {
        const frames = @as(f64, @floatFromInt(self.frames_in_block));
        const mean_energy = self.energy / frames;
        const energy_db = if (mean_energy > 0) 10 * @log10(mean_energy) else -120;
        const energy_bin = quantize((energy_db + 90) / 6);
        const crossing_bin = quantize(64 * @as(f64, @floatFromInt(self.zero_crossings)) / frames);
        const roughness = if (mean_energy > 0)
            @sqrt(self.difference_energy / frames / mean_energy)
        else
            0;
        const roughness_bin = quantize(roughness * 4);
        const crest = if (mean_energy > 0) self.peak / @sqrt(mean_energy) else 0;
        const crest_bin = quantize(crest * 2);
        try self.signatures.append(
            self.allocator,
            @as(u16, energy_bin) |
                (@as(u16, crossing_bin) << 4) |
                (@as(u16, roughness_bin) << 8) |
                (@as(u16, crest_bin) << 12),
        );
        self.frames_in_block = 0;
        self.energy = 0;
        self.difference_energy = 0;
        self.peak = 0;
        self.zero_crossings = 0;
    }
};

const encoded_header_size = 108;
const encoded_version: u16 = 2;

/// ORFP version 2: the version-1 layout with the audio hash's tier at byte 76
/// and its effective width at byte 77. Version 1 carried an untiered hash and
/// is refused.
pub fn encode(allocator: std.mem.Allocator, result: Result) ![]u8 {
    const bytes = try allocator.alloc(u8, encoded_header_size + result.signatures.len * 2);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "ORFP");
    std.mem.writeInt(u16, bytes[4..6], encoded_version, .little);
    std.mem.writeInt(u32, bytes[8..12], @intCast(result.signatures.len), .little);
    @memcpy(bytes[12..44], &result.digest);
    @memcpy(bytes[44..76], &result.audio_hash.digest);
    bytes[76] = @backingInt(result.audio_hash.tier);
    bytes[77] = result.audio_hash.effective_bits;
    for (result.signatures, 0..) |signature, index|
        std.mem.writeInt(u16, bytes[encoded_header_size + index * 2 ..][0..2], signature, .little);
    return bytes;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Result {
    if (bytes.len < encoded_header_size or !std.mem.eql(u8, bytes[0..4], "ORFP"))
        return error.InvalidFingerprintResult;
    if (std.mem.readInt(u16, bytes[4..6], .little) != encoded_version)
        return error.UnsupportedFingerprintResultVersion;
    const tier = std.enums.fromInt(AudioHashTier, bytes[76]) orelse
        return error.InvalidFingerprintResult;
    const effective_bits = bytes[77];
    if (effective_bits > 32 or (tier == .decoded_float and effective_bits != 0))
        return error.InvalidFingerprintResult;
    const count = std.mem.readInt(u32, bytes[8..12], .little);
    if (count > 10_000_000 or bytes.len != encoded_header_size + @as(usize, count) * 2)
        return error.InvalidFingerprintResult;
    const signatures = try allocator.alloc(u16, count);
    errdefer allocator.free(signatures);
    var hasher = std.crypto.hash.Blake3.init(.{});
    for (signatures, 0..) |*signature, index| {
        const encoded = bytes[encoded_header_size + index * 2 ..][0..2];
        signature.* = std.mem.readInt(u16, encoded, .little);
        hasher.update(encoded);
    }
    var computed_digest: [32]u8 = undefined;
    hasher.final(&computed_digest);
    if (!std.mem.eql(u8, &computed_digest, bytes[12..44])) return error.InvalidFingerprintResult;
    return .{
        .allocator = allocator,
        .signatures = signatures,
        .digest = bytes[12..44].*,
        .audio_hash = .{
            .digest = bytes[44..76].*,
            .tier = tier,
            .effective_bits = effective_bits,
        },
    };
}

pub fn similarity(first: []const u16, second: []const u16) f32 {
    if (first.len == 0 or second.len == 0) return 0;
    const compared = @min(first.len, second.len);
    const longer = @max(first.len, second.len);
    var distance: u64 = 0;
    for (first[0..compared], second[0..compared]) |a, b| {
        inline for (0..4) |shift| {
            const a_value = (a >> (shift * 4)) & 0xf;
            const b_value = (b >> (shift * 4)) & 0xf;
            distance += if (a_value > b_value) a_value - b_value else b_value - a_value;
        }
    }
    distance += (longer - compared) * 60;
    return @floatCast(1 - @as(f64, @floatFromInt(distance)) /
        @as(f64, @floatFromInt(longer * 60)));
}

pub const DuplicateKind = enum { none, likely_recording, exact_audio };

/// The one pairwise duplicate comparison in the codebase.
///
/// Finding the pairs worth comparing is an indexing problem rather than a
/// comparison one, so it lives in `library/duplicate_pass.zig`, which bucks
/// candidates by decoded-audio hash and by duration and calls this only inside
/// a bucket bounded by a constant.
///
/// Equal `lossless_integer` hashes are the only proof of identical audio.
/// Equal `decoded_float` hashes say one decoder rendered both files alike,
/// which makes them a likely recording and nothing more.
pub fn classifyDuplicate(first: Result, second: Result, likely_threshold: f32) DuplicateKind {
    if (first.audio_hash.eql(second.audio_hash)) return switch (first.audio_hash.tier) {
        .lossless_integer => .exact_audio,
        .decoded_float => .likely_recording,
    };
    if (similarity(first.signatures, second.signatures) >= likely_threshold)
        return .likely_recording;
    return .none;
}

fn quantize(value: f64) u4 {
    return @intFromFloat(std.math.clamp(@round(value), 0, 15));
}

fn toneResult(
    allocator: std.mem.Allocator,
    tier: AudioHashTier,
    sample_rate: u32,
    channels: u16,
    frames: usize,
) !Result {
    var analyzer = try Analyzer.init(allocator, sample_rate, channels, tier);
    defer analyzer.deinit();
    var integers: [64]i32 = undefined;
    var floats: [64]f32 = undefined;
    var frame: usize = 0;
    while (frame < frames) {
        const count = @min(frames - frame, integers.len / channels);
        for (0..count) |offset| {
            const value: i16 = @intFromFloat(12_000 * @sin(2 * std.math.pi * 440 *
                @as(f32, @floatFromInt(frame + offset)) / 48_000));
            for (0..channels) |channel| {
                integers[offset * channels + channel] = @as(i32, value) << 16;
                floats[offset * channels + channel] = @as(f32, @floatFromInt(value)) / 32768;
            }
        }
        switch (tier) {
            .lossless_integer => try analyzer.processIntegers(integers[0 .. count * channels]),
            .decoded_float => try analyzer.process(floats[0 .. count * channels]),
        }
        frame += count;
    }
    return analyzer.finish();
}

test "temporal fingerprints are streaming-stable and rank nearby audio" {
    const allocator = std.testing.allocator;
    const sample_rate = 48_000;
    var samples: [sample_rate]f32 = undefined;
    var perturbed: [sample_rate]f32 = undefined;
    for (&samples, &perturbed, 0..) |*sample, *nearby, frame| {
        const value: f32 = 0.4 * @sin(2 * std.math.pi * 440 *
            @as(f32, @floatFromInt(frame)) / sample_rate);
        sample.* = value;
        nearby.* = value * 0.99;
    }
    var first = try Analyzer.init(allocator, sample_rate, 1, .decoded_float);
    defer first.deinit();
    try first.process(samples[0..12_345]);
    try first.process(samples[12_345..]);
    const first_result = try first.finish();
    defer first_result.deinit();
    var second = try Analyzer.init(allocator, sample_rate, 1, .decoded_float);
    defer second.deinit();
    try second.process(&samples);
    const second_result = try second.finish();
    defer second_result.deinit();
    try std.testing.expectEqualSlices(u16, first_result.signatures, second_result.signatures);
    try std.testing.expectEqual(first_result.audio_hash, second_result.audio_hash);
    const encoded = try encode(allocator, first_result);
    defer allocator.free(encoded);
    const decoded = try decode(allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u16, first_result.signatures, decoded.signatures);
    try std.testing.expectEqual(first_result.audio_hash, decoded.audio_hash);
    var nearby = try Analyzer.init(allocator, sample_rate, 1, .decoded_float);
    defer nearby.deinit();
    try nearby.process(&perturbed);
    const nearby_result = try nearby.finish();
    defer nearby_result.deinit();
    try std.testing.expect(similarity(first_result.signatures, nearby_result.signatures) > 0.95);
    try std.testing.expectEqual(
        DuplicateKind.likely_recording,
        classifyDuplicate(first_result, nearby_result, 0.95),
    );
}

test "only equal lossless integer hashes classify as exact audio" {
    const allocator = std.testing.allocator;
    const lossless = try toneResult(allocator, .lossless_integer, 48_000, 2, 4800);
    defer lossless.deinit();
    const lossless_again = try toneResult(allocator, .lossless_integer, 48_000, 2, 4800);
    defer lossless_again.deinit();
    const decoded = try toneResult(allocator, .decoded_float, 48_000, 2, 4800);
    defer decoded.deinit();
    const decoded_again = try toneResult(allocator, .decoded_float, 48_000, 2, 4800);
    defer decoded_again.deinit();
    try std.testing.expectEqual(@as(u8, 16), lossless.audio_hash.effective_bits);
    try std.testing.expectEqual(@as(u8, 0), decoded.audio_hash.effective_bits);
    try std.testing.expectEqual(DuplicateKind.exact_audio, classifyDuplicate(lossless, lossless_again, 0.95));
    try std.testing.expectEqual(DuplicateKind.likely_recording, classifyDuplicate(decoded, decoded_again, 0.95));
    try std.testing.expect(!lossless.audio_hash.eql(decoded.audio_hash));
    try std.testing.expect(!std.mem.eql(u8, &lossless.audio_hash.digest, &decoded.audio_hash.digest));
    try std.testing.expectEqual(DuplicateKind.likely_recording, classifyDuplicate(lossless, decoded, 0.95));
}

test "the audio hash commits to sample rate, channel layout and frame count" {
    var mono: [480]i32 = undefined;
    var stereo: [960]i32 = undefined;
    for (&mono, 0..) |*sample, index| {
        sample.* = (@as(i32, @intCast(index * 37 % 2001)) - 1000) << 16;
        stereo[index * 2] = sample.*;
        stereo[index * 2 + 1] = sample.*;
    }
    var at_44100 = try AudioHasher.init(.lossless_integer, 44_100, 1);
    try at_44100.updateIntegers(&mono);
    var at_48000 = try AudioHasher.init(.lossless_integer, 48_000, 1);
    try at_48000.updateIntegers(&mono);
    var as_stereo = try AudioHasher.init(.lossless_integer, 48_000, 2);
    try as_stereo.updateIntegers(&stereo);
    var shorter = try AudioHasher.init(.lossless_integer, 48_000, 1);
    try shorter.updateIntegers(mono[0..478]);
    const hashes = [_]AudioHash{ at_44100.finish(), at_48000.finish(), as_stereo.finish(), shorter.finish() };
    for (hashes, 0..) |first, i| for (hashes[i + 1 ..]) |second|
        try std.testing.expect(!std.mem.eql(u8, &first.digest, &second.digest));
    for (hashes) |hash| try std.testing.expectEqual(@as(u8, 16), hash.effective_bits);

    var integer = try AudioHasher.init(.lossless_integer, 48_000, 1);
    try std.testing.expectError(error.AudioHashTierMismatch, integer.updateFloats(&.{0}));
    try std.testing.expectError(error.InvalidAudioFormat, AudioHasher.init(.decoded_float, 48_000, 256));
}

test "a version 1 fingerprint result is refused and a corrupt tier is invalid" {
    const allocator = std.testing.allocator;
    const result = try toneResult(allocator, .lossless_integer, 48_000, 1, 2400);
    defer result.deinit();
    const encoded = try encode(allocator, result);
    defer allocator.free(encoded);
    std.mem.writeInt(u16, encoded[4..6], 1, .little);
    try std.testing.expectError(error.UnsupportedFingerprintResultVersion, decode(allocator, encoded));
    std.mem.writeInt(u16, encoded[4..6], 2, .little);
    encoded[76] = 3;
    try std.testing.expectError(error.InvalidFingerprintResult, decode(allocator, encoded));
    encoded[76] = @backingInt(AudioHashTier.decoded_float);
    try std.testing.expectError(error.InvalidFingerprintResult, decode(allocator, encoded));
    encoded[76] = @backingInt(AudioHashTier.lossless_integer);
    const decoded = try decode(allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(result.audio_hash, decoded.audio_hash);
}
