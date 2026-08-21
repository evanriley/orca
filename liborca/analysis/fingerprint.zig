const std = @import("std");

/// A compact, provider-independent temporal fingerprint. The signatures are
/// deliberately retained alongside their digest so likely matches can be
/// ranked rather than treated as exact identifiers.
pub const Result = struct {
    allocator: std.mem.Allocator,
    signatures: []u16,
    digest: [32]u8,
    decoded_audio_hash: [32]u8,
    source_hash: ?[32]u8 = null,

    pub fn deinit(self: Result) void {
        self.allocator.free(self.signatures);
    }
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    channels: u16,
    frames_per_block: u32,
    signatures: std.ArrayList(u16) = .empty,
    decoded_hasher: std.crypto.hash.Blake3 = .init(.{}),
    frames_in_block: u32 = 0,
    energy: f64 = 0,
    difference_energy: f64 = 0,
    peak: f32 = 0,
    zero_crossings: u32 = 0,
    previous: f32 = 0,
    has_previous: bool = false,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channels: u16) !Analyzer {
        if (sample_rate == 0 or channels == 0) return error.InvalidAudioFormat;
        return .{
            .allocator = allocator,
            .channels = channels,
            .frames_per_block = @max(1, sample_rate / 20),
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.signatures.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn process(self: *Analyzer, samples: []const f32) !void {
        if (samples.len % self.channels != 0) return error.IncompleteAudioFrame;
        var index: usize = 0;
        while (index < samples.len) {
            var mono: f32 = 0;
            for (0..self.channels) |_| {
                const sample = samples[index];
                index += 1;
                mono += sample / @as(f32, @floatFromInt(self.channels));
                var encoded: [4]u8 = undefined;
                std.mem.writeInt(u32, &encoded, @bitCast(sample), .little);
                self.decoded_hasher.update(&encoded);
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
        var decoded_hash: [32]u8 = undefined;
        self.decoded_hasher.final(&decoded_hash);
        return .{
            .allocator = self.allocator,
            .signatures = owned,
            .digest = digest,
            .decoded_audio_hash = decoded_hash,
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

pub fn encode(allocator: std.mem.Allocator, result: Result) ![]u8 {
    const bytes = try allocator.alloc(u8, encoded_header_size + result.signatures.len * 2);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "ORFP");
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    std.mem.writeInt(u16, bytes[6..8], if (result.source_hash != null) 1 else 0, .little);
    std.mem.writeInt(u32, bytes[8..12], @intCast(result.signatures.len), .little);
    @memcpy(bytes[12..44], &result.digest);
    @memcpy(bytes[44..76], &result.decoded_audio_hash);
    if (result.source_hash) |source_hash| @memcpy(bytes[76..108], &source_hash);
    for (result.signatures, 0..) |signature, index|
        std.mem.writeInt(u16, bytes[encoded_header_size + index * 2 ..][0..2], signature, .little);
    return bytes;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Result {
    if (bytes.len < encoded_header_size or !std.mem.eql(u8, bytes[0..4], "ORFP"))
        return error.InvalidFingerprintResult;
    if (std.mem.readInt(u16, bytes[4..6], .little) != 1)
        return error.UnsupportedFingerprintResultVersion;
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
        .decoded_audio_hash = bytes[44..76].*,
        .source_hash = if (std.mem.readInt(u16, bytes[6..8], .little) & 1 != 0)
            bytes[76..108].*
        else
            null,
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

pub const DuplicateKind = enum { none, likely_recording, exact_audio, exact_file };

pub fn classifyDuplicate(first: Result, second: Result, likely_threshold: f32) DuplicateKind {
    if (first.source_hash != null and second.source_hash != null and
        std.mem.eql(u8, &first.source_hash.?, &second.source_hash.?)) return .exact_file;
    if (std.mem.eql(u8, &first.decoded_audio_hash, &second.decoded_audio_hash)) return .exact_audio;
    if (similarity(first.signatures, second.signatures) >= likely_threshold)
        return .likely_recording;
    return .none;
}

pub const Candidate = struct {
    path: []const u8,
    fingerprint: *const Result,
};

pub const Match = struct {
    first_index: usize,
    second_index: usize,
    kind: DuplicateKind,
    similarity_score: f32,
};

pub fn findDuplicates(
    allocator: std.mem.Allocator,
    candidates: []const Candidate,
    likely_threshold: f32,
) ![]Match {
    if (likely_threshold < 0 or likely_threshold > 1) return error.InvalidSimilarityThreshold;
    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(allocator);
    for (candidates, 0..) |first, first_index| {
        for (candidates[first_index + 1 ..], first_index + 1..) |second, second_index| {
            const kind = classifyDuplicate(first.fingerprint.*, second.fingerprint.*, likely_threshold);
            if (kind == .none) continue;
            try matches.append(allocator, .{
                .first_index = first_index,
                .second_index = second_index,
                .kind = kind,
                .similarity_score = similarity(
                    first.fingerprint.signatures,
                    second.fingerprint.signatures,
                ),
            });
        }
    }
    return matches.toOwnedSlice(allocator);
}

fn quantize(value: f64) u4 {
    return @intFromFloat(std.math.clamp(@round(value), 0, 15));
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
    var first = try Analyzer.init(allocator, sample_rate, 1);
    defer first.deinit();
    try first.process(samples[0..12_345]);
    try first.process(samples[12_345..]);
    const first_result = try first.finish();
    defer first_result.deinit();
    var second = try Analyzer.init(allocator, sample_rate, 1);
    defer second.deinit();
    try second.process(&samples);
    const second_result = try second.finish();
    defer second_result.deinit();
    try std.testing.expectEqualSlices(u16, first_result.signatures, second_result.signatures);
    try std.testing.expectEqual(first_result.decoded_audio_hash, second_result.decoded_audio_hash);
    const encoded = try encode(allocator, first_result);
    defer allocator.free(encoded);
    const decoded = try decode(allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u16, first_result.signatures, decoded.signatures);
    var nearby = try Analyzer.init(allocator, sample_rate, 1);
    defer nearby.deinit();
    try nearby.process(&perturbed);
    const nearby_result = try nearby.finish();
    defer nearby_result.deinit();
    try std.testing.expect(similarity(first_result.signatures, nearby_result.signatures) > 0.95);
    const matches = try findDuplicates(allocator, &.{
        .{ .path = "first.flac", .fingerprint = &first_result },
        .{ .path = "nearby.qoa", .fingerprint = &nearby_result },
    }, 0.95);
    defer allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(DuplicateKind.likely_recording, matches[0].kind);
}
