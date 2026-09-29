//! AcoustID fingerprints: the first two minutes of a file, decoded by Orca,
//! resampled to 11025 Hz by libsamplerate and fingerprinted by Chromaprint
//! behind `chromaprint_shim.c`.

const std = @import("std");
const codec = @import("../codec/root.zig");
const database = @import("../database/root.zig");
const resampler = @import("../audio/resampler.zig");
const scanner = @import("../library/scanner.zig");
const quick_hash = @import("../storage/quick_hash.zig");
const storage = @import("../storage/root.zig");

extern const orca_chromaprint_sample_rate: u32;
extern fn orca_chromaprint_create(algorithm: i32) ?*anyopaque;
extern fn orca_chromaprint_destroy(context: ?*anyopaque) void;
extern fn orca_chromaprint_start(context: ?*anyopaque, channels: u32) i32;
extern fn orca_chromaprint_feed(context: ?*anyopaque, samples: [*]const i16, count: u32) i32;
extern fn orca_chromaprint_finish(context: ?*anyopaque) i32;
extern fn orca_chromaprint_fingerprint(context: ?*anyopaque, encoded: *?[*:0]u8, raw_size: *u32) i32;
extern fn orca_chromaprint_decode(
    encoded: [*]const u8,
    encoded_length: u32,
    raw: *?[*]u32,
    raw_size: *u32,
    algorithm: *i32,
) i32;
extern fn orca_chromaprint_release(pointer: ?*anyopaque) void;

pub const cache_kind: u8 = 3;
pub const algorithm_id = "orca.chromaprint";
pub const algorithm_version: u32 = 1;

/// Chromaprint's algorithms. AcoustID indexes `test2`, Chromaprint's default.
pub const Algorithm = enum(i32) { test1 = 0, test2 = 1, test3 = 2, test4 = 3, test5 = 4 };

/// Everything besides the bytes that decides a fingerprint, so a change to any
/// of it files a new cache entry rather than reusing one taken another way.
pub const Parameters = struct {
    algorithm: Algorithm = .test2,
    converter: resampler.SampleRate.Converter = .sinc_fastest,
    /// How much of the start of the file is fingerprinted, as `fpcalc` does.
    max_seconds: u32 = 120,
};

pub fn parameterHash(parameters: Parameters) [32]u8 {
    var encoded: [12]u8 = undefined;
    std.mem.writeInt(i32, encoded[0..4], @intFromEnum(parameters.algorithm), .little);
    std.mem.writeInt(i32, encoded[4..8], @intFromEnum(parameters.converter), .little);
    std.mem.writeInt(u32, encoded[8..12], parameters.max_seconds, .little);
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(&encoded, &digest, .{});
    return digest;
}

pub fn cacheKey(
    file_id: i64,
    source_identity: quick_hash.Digest,
    parameters: Parameters,
) database.AnalysisCacheKey {
    return .{
        .file_id = file_id,
        .kind = cache_kind,
        .algorithm_id = algorithm_id,
        .algorithm_version = algorithm_version,
        .parameter_hash = parameterHash(parameters),
        .source_identity = source_identity,
    };
}

pub const Fingerprint = struct {
    allocator: std.mem.Allocator,
    /// Chromaprint's compressed, base64 form, which AcoustID accepts.
    encoded: []u8,
    /// The whole file's length, not only the part fingerprinted.
    duration_ms: u64,

    /// What AcoustID's `duration` parameter takes.
    pub fn durationSeconds(self: Fingerprint) u32 {
        return @intCast(@min((self.duration_ms + 500) / 1000, std.math.maxInt(u32)));
    }

    pub fn deinit(self: Fingerprint) void {
        self.allocator.free(self.encoded);
    }

    pub fn encode(self: Fingerprint, allocator: std.mem.Allocator) ![]u8 {
        const bytes = try allocator.alloc(u8, 8 + self.encoded.len);
        std.mem.writeInt(u64, bytes[0..8], self.duration_ms, .little);
        @memcpy(bytes[8..], self.encoded);
        return bytes;
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Fingerprint {
        if (bytes.len <= 8) return error.InvalidStoredFingerprint;
        return .{
            .allocator = allocator,
            .encoded = try allocator.dupe(u8, bytes[8..]),
            .duration_ms = std.mem.readInt(u64, bytes[0..8], .little),
        };
    }
};

const chunk_frames = 4096;

/// Fingerprints what `decoder` produces from its current position. Any decode
/// error fails the whole fingerprint: a partial one is never returned.
pub fn fingerprintDecoder(
    allocator: std.mem.Allocator,
    decoder: codec.Decoder,
    parameters: Parameters,
    cancellation: ?*const scanner.CancellationToken,
) !Fingerprint {
    const channels: usize = decoder.format.channels;
    const input_rate = decoder.format.sample_rate;
    if (channels == 0 or input_rate == 0) return error.InvalidAudioFormat;
    const target_rate = orca_chromaprint_sample_rate;

    const context = orca_chromaprint_create(@intFromEnum(parameters.algorithm)) orelse
        return error.FingerprinterUnavailable;
    defer orca_chromaprint_destroy(context);
    if (orca_chromaprint_start(context, 1) != 0) return error.FingerprinterUnavailable;

    var converter: ?resampler.SampleRate = if (input_rate == target_rate)
        null
    else
        try resampler.SampleRate.init(parameters.converter, input_rate, target_rate, 1);
    defer if (converter) |*value| value.deinit();

    const decoded = try allocator.alloc(f32, chunk_frames * channels);
    defer allocator.free(decoded);
    var mono: [chunk_frames]f32 = undefined;
    const resampled_capacity = chunk_frames * @as(usize, target_rate) / input_rate + 64;
    const resampled = try allocator.alloc(f32, resampled_capacity);
    defer allocator.free(resampled);
    const samples = try allocator.alloc(i16, resampled_capacity);
    defer allocator.free(samples);

    const window_frames = @as(u64, parameters.max_seconds) * input_rate;
    var frames_read: u64 = 0;
    while (frames_read < window_frames) {
        if (isCancelled(cancellation)) return error.Cancelled;
        const wanted: usize = @intCast(@min(chunk_frames, window_frames - frames_read));
        const frames = try decoder.readFrames(decoded[0 .. wanted * channels]);
        if (frames == 0) break;
        frames_read += frames;
        downmix(decoded[0 .. frames * channels], channels, mono[0..frames]);
        if (converter) |*value| {
            try resampleInto(context, value.resampler(), mono[0..frames], resampled, samples, false);
        } else {
            try feed(context, mono[0..frames], samples);
        }
    }
    if (converter) |*value| try resampleInto(context, value.resampler(), &.{}, resampled, samples, true);
    if (orca_chromaprint_finish(context) != 0) return error.FingerprintFailed;

    const total_frames = if (frames_read < window_frames)
        frames_read
    else if (decoder.frame_count) |declared|
        @max(declared, frames_read)
    else
        frames_read + try countRemaining(decoder, decoded, cancellation);
    const duration_ms = total_frames * 1000 / input_rate;
    if ((duration_ms + 500) / 1000 == 0) return error.AudioTooShortToFingerprint;

    var encoded: ?[*:0]u8 = null;
    var raw_size: u32 = 0;
    if (orca_chromaprint_fingerprint(context, &encoded, &raw_size) != 0) return error.FingerprintFailed;
    defer orca_chromaprint_release(encoded);
    if (raw_size == 0) return error.AudioTooShortToFingerprint;
    return .{
        .allocator = allocator,
        .encoded = try allocator.dupe(u8, std.mem.span(encoded.?)),
        .duration_ms = duration_ms,
    };
}

fn isCancelled(cancellation: ?*const scanner.CancellationToken) bool {
    return if (cancellation) |token| token.isCancelled() else false;
}

fn downmix(interleaved: []const f32, channels: usize, mono: []f32) void {
    const scale = 1.0 / @as(f32, @floatFromInt(channels));
    for (mono, 0..) |*sample, frame| {
        var sum: f32 = 0;
        for (interleaved[frame * channels ..][0..channels]) |value| sum += value;
        sample.* = sum * scale;
    }
}

fn resampleInto(
    context: ?*anyopaque,
    converter: resampler.Resampler,
    input: []const f32,
    resampled: []f32,
    samples: []i16,
    end_of_input: bool,
) !void {
    var consumed: usize = 0;
    while (true) {
        const result = try converter.process(input[consumed..], resampled, end_of_input);
        consumed += result.input_frames_consumed;
        try feed(context, resampled[0..result.output_frames_produced], samples);
        if (end_of_input) {
            if (result.output_frames_produced == 0) return;
        } else if (consumed == input.len) return;
    }
}

fn feed(context: ?*anyopaque, audio: []const f32, samples: []i16) !void {
    if (audio.len == 0) return;
    for (audio, samples[0..audio.len]) |value, *sample| {
        const scaled = @round(std.math.clamp(value, -1.0, 1.0) * 32768.0);
        sample.* = @intFromFloat(std.math.clamp(scaled, -32768.0, 32767.0));
    }
    if (orca_chromaprint_feed(context, samples.ptr, @intCast(audio.len)) != 0) return error.FingerprintFailed;
}

fn countRemaining(
    decoder: codec.Decoder,
    buffer: []f32,
    cancellation: ?*const scanner.CancellationToken,
) !u64 {
    var remaining: u64 = 0;
    while (true) {
        if (isCancelled(cancellation)) return error.Cancelled;
        const frames = try decoder.readFrames(buffer);
        if (frames == 0) return remaining;
        remaining += frames;
    }
}

/// A fingerprint's 32-bit sub-fingerprints, for comparing two fingerprints.
pub const Raw = struct {
    items: []u32,
    algorithm: i32,

    pub fn decode(encoded: []const u8) !Raw {
        var raw: ?[*]u32 = null;
        var size: u32 = 0;
        var algorithm: i32 = 0;
        if (orca_chromaprint_decode(encoded.ptr, @intCast(encoded.len), &raw, &size, &algorithm) != 0)
            return error.InvalidFingerprint;
        return .{ .items = if (raw) |items| items[0..size] else &.{}, .algorithm = algorithm };
    }

    pub fn deinit(self: Raw) void {
        if (self.items.len != 0) orca_chromaprint_release(self.items.ptr);
    }
};

/// The share of bits two sub-fingerprint sequences agree on, over the length
/// they share.
pub fn bitAgreement(first: []const u32, second: []const u32) f64 {
    const shared = @min(first.len, second.len);
    if (shared == 0) return 0;
    var differing: u64 = 0;
    for (first[0..shared], second[0..shared]) |a, b| differing += @popCount(a ^ b);
    return 1 - @as(f64, @floatFromInt(differing)) / @as(f64, @floatFromInt(shared * 32));
}

/// Fingerprints files, keeping each result in `analysis_results` under the
/// identity of the bytes it was taken from.
pub const Fingerprinter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    codecs: *const codec.CodecRegistry,
    cache: ?*database.AnalysisCacheRepository = null,
    cancellation: ?*const scanner.CancellationToken = null,
    parameters: Parameters = .{},

    pub const Outcome = struct {
        fingerprint: Fingerprint,
        cache_hit: bool,
    };

    /// Without a `file_id` nothing is cached.
    pub fn fingerprintFile(self: Fingerprinter, file_id: ?i64, path: []const u8) !Outcome {
        var local = try storage.LocalFileSource.open(self.io, path);
        defer local.close();
        const initial_identity = local.readable().identity();
        const source_identity = try quick_hash.fromSource(local.readable());
        const key = cacheKey(file_id orelse 0, source_identity, self.parameters);
        const cache = if (file_id == null) null else self.cache;
        if (cache) |repository| {
            if (try repository.get(self.allocator, key)) |bytes| {
                defer self.allocator.free(bytes);
                if (Fingerprint.decode(self.allocator, bytes)) |cached| {
                    return .{ .fingerprint = cached, .cache_hit = true };
                } else |_| {}
            }
        }
        var decoder = try self.codecs.openDetected(self.allocator, local.readable());
        defer decoder.deinit();
        const fingerprint = try fingerprintDecoder(self.allocator, decoder, self.parameters, self.cancellation);
        errdefer fingerprint.deinit();
        var identity_check = try storage.LocalFileSource.open(self.io, path);
        defer identity_check.close();
        const final_identity = identity_check.readable().identity();
        if (initial_identity.inode != final_identity.inode or initial_identity.size != final_identity.size or
            initial_identity.modified_ns != final_identity.modified_ns)
            return error.SourceChangedDuringAnalysis;
        if (cache) |repository| {
            const bytes = try fingerprint.encode(self.allocator);
            defer self.allocator.free(bytes);
            try repository.put(key, bytes);
        }
        return .{ .fingerprint = fingerprint, .cache_hit = false };
    }
};

const testing = std.testing;

const SyntheticDecoder = struct {
    total_frames: u64,
    fail_after: ?u64 = null,
    declare_length: bool = true,
    position: u64 = 0,
    seed: u32 = 1,

    const vtable: codec.Decoder.VTable = .{ .read_frames = readFrames, .seek = seek, .deinit = deinitDecoder };

    fn decoder(self: *SyntheticDecoder) codec.Decoder {
        return .{
            .context = self,
            .vtable = &vtable,
            .codec = codec.decoder.codec_id.pcm_float,
            .format = .{
                .sample_format = .float_32,
                .channels = 1,
                .sample_rate = 11_025,
                .bits_per_sample = 32,
                .bytes_per_frame = 4,
            },
            .frame_count = if (self.declare_length) self.total_frames else null,
        };
    }

    fn readFrames(context: *anyopaque, output: []f32) anyerror!usize {
        const self: *SyntheticDecoder = @ptrCast(@alignCast(context));
        if (self.fail_after) |limit| if (self.position >= limit) return error.CorruptFrame;
        const frames: usize = @intCast(@min(output.len, self.total_frames - self.position));
        for (output[0..frames], 0..) |*sample, index| {
            const time = @as(f32, @floatFromInt(self.position + index)) / 11_025.0;
            self.seed = self.seed *% 1_103_515_245 +% 12_345;
            const noise = @as(f32, @floatFromInt(self.seed >> 16 & 0x7fff)) / 32_768.0 - 0.5;
            sample.* = 0.3 * @sin(2.0 * std.math.pi * (220.0 + 30.0 * @floor(time)) * time) + 0.1 * noise;
        }
        self.position += frames;
        return frames;
    }

    fn seek(_: *anyopaque, _: u64) anyerror!void {}
    fn deinitDecoder(_: *anyopaque) void {}
};

test "only the first two minutes are decoded, and the duration is the whole file's" {
    var synthetic: SyntheticDecoder = .{ .total_frames = 200 * 11_025 };
    const fingerprint = try fingerprintDecoder(testing.allocator, synthetic.decoder(), .{}, null);
    defer fingerprint.deinit();

    try testing.expectEqual(@as(u64, 120 * 11_025), synthetic.position);
    try testing.expectEqual(@as(u64, 200_000), fingerprint.duration_ms);
    try testing.expectEqual(@as(u32, 200), fingerprint.durationSeconds());
    try testing.expect(std.mem.startsWith(u8, fingerprint.encoded, "AQAD"));
}

test "a stream with no declared length is counted to its end" {
    var synthetic: SyntheticDecoder = .{ .total_frames = 130 * 11_025 + 6_000, .declare_length = false };
    const fingerprint = try fingerprintDecoder(testing.allocator, synthetic.decoder(), .{}, null);
    defer fingerprint.deinit();
    try testing.expectEqual(@as(u32, 131), fingerprint.durationSeconds());
}

test "a decode error anywhere in the window yields no fingerprint" {
    var synthetic: SyntheticDecoder = .{ .total_frames = 60 * 11_025, .fail_after = 30 * 11_025 };
    try testing.expectError(error.CorruptFrame, fingerprintDecoder(testing.allocator, synthetic.decoder(), .{}, null));
}

test "a cancelled fingerprint stops before decoding" {
    var synthetic: SyntheticDecoder = .{ .total_frames = 60 * 11_025 };
    var token: scanner.CancellationToken = .{};
    token.cancel();
    try testing.expectError(error.Cancelled, fingerprintDecoder(testing.allocator, synthetic.decoder(), .{}, &token));
    try testing.expectEqual(@as(u64, 0), synthetic.position);
}

const parity_audio = "fixtures/audio/chromaprint-test.mp3";
const parity_reference = "fixtures/audio/chromaprint-test.fpcalc.txt";

fn readReference(allocator: std.mem.Allocator) !struct { duration_s: u32, raw: []u32 } {
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, parity_reference, allocator, .limited(1 << 20));
    defer allocator.free(text);
    var duration_s: ?u32 = null;
    var raw: std.ArrayList(u32) = .empty;
    errdefer raw.deinit(allocator);
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "DURATION=")) {
            duration_s = try std.fmt.parseInt(u32, line["DURATION=".len..], 10);
        } else if (std.mem.startsWith(u8, line, "FINGERPRINT=")) {
            var values = std.mem.tokenizeScalar(u8, line["FINGERPRINT=".len..], ',');
            while (values.next()) |value| try raw.append(allocator, try std.fmt.parseInt(u32, value, 10));
        }
    }
    return .{ .duration_s = duration_s orelse return error.InvalidReference, .raw = try raw.toOwnedSlice(allocator) };
}

test "Orca's fingerprint of Chromaprint's test recording agrees with fpcalc's on at least 95% of its bits" {
    const reference = try readReference(testing.allocator);
    defer testing.allocator.free(reference.raw);
    const codecs = codec.CodecRegistry.builtins();
    const fingerprinter: Fingerprinter = .{ .allocator = testing.allocator, .io = testing.io, .codecs = &codecs };

    const outcome = try fingerprinter.fingerprintFile(null, parity_audio);
    defer outcome.fingerprint.deinit();
    const raw = try Raw.decode(outcome.fingerprint.encoded);
    defer raw.deinit();

    try testing.expectEqual(reference.duration_s, outcome.fingerprint.durationSeconds());
    try testing.expectEqual(@as(i32, @intFromEnum(Algorithm.test2)), raw.algorithm);
    try testing.expect(raw.items.len * 10 >= reference.raw.len * 9);
    try testing.expect(bitAgreement(raw.items, reference.raw) >= 0.95);
}

test "a fingerprint is cached under the bytes it was taken from and reused" {
    var library = try database.LibraryDatabase.open(testing.allocator, testing.io, "file:orca-chromaprint-cache?mode=memory&cache=shared");
    defer library.close();
    const binding = try library.resolveOrCreateFile(testing.io, parity_audio, .{ .stable_key = "test:chromaprint" });
    const codecs = codec.CodecRegistry.builtins();
    const fingerprinter: Fingerprinter = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .codecs = &codecs,
        .cache = &library.analysis_cache,
    };

    const first = try fingerprinter.fingerprintFile(binding.file_id, parity_audio);
    defer first.fingerprint.deinit();
    const second = try fingerprinter.fingerprintFile(binding.file_id, parity_audio);
    defer second.fingerprint.deinit();

    try testing.expect(!first.cache_hit);
    try testing.expect(second.cache_hit);
    try testing.expectEqualStrings(first.fingerprint.encoded, second.fingerprint.encoded);
    try testing.expectEqual(first.fingerprint.duration_ms, second.fingerprint.duration_ms);
    var faster = fingerprinter;
    faster.parameters.converter = .linear;
    const retaken = try faster.fingerprintFile(binding.file_id, parity_audio);
    defer retaken.fingerprint.deinit();
    try testing.expect(!retaken.cache_hit);
}
