//! AcoustID fingerprints: the first two minutes of a file, decoded by Orca,
//! resampled to 11025 Hz by libsamplerate and fingerprinted by Chromaprint
//! behind `chromaprint_shim.c`.

const std = @import("std");
const codec = @import("../codec/root.zig");
const database = @import("../database/root.zig");
const resampler = @import("../audio/resampler.zig");
const scanner = @import("../library/scanner.zig");
const content_hash = @import("../storage/content_hash.zig");
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
    std.mem.writeInt(i32, encoded[0..4], @backingInt(parameters.algorithm), .little);
    std.mem.writeInt(i32, encoded[4..8], @backingInt(parameters.converter), .little);
    std.mem.writeInt(u32, encoded[8..12], parameters.max_seconds, .little);
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(&encoded, &digest, .{});
    return digest;
}

/// A row of this kind records that the bytes whose quick hash is its
/// `source_identity` could not be fingerprinted. The matching job's selection
/// compares it with `files.quick_hash`, so it is never keyed by content hash.
pub const failure_kind: u8 = 5;

pub fn failureSelector(parameters: Parameters) database.AnalysisSelector {
    return .{
        .kind = failure_kind,
        .algorithm_id = algorithm_id,
        .algorithm_version = algorithm_version,
        .parameter_hash = parameterHash(parameters),
    };
}

pub fn cacheKey(
    file_id: i64,
    source_identity: content_hash.Digest,
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

/// Fingerprints interleaved audio fed to it a chunk at a time, so a caller
/// already decoding a file for something else takes its fingerprint in the
/// same pass. Frames past the window are ignored.
pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    context: *anyopaque,
    converter: ?resampler.SampleRate,
    channels: usize,
    sample_rate: u32,
    window_frames: u64,
    frames_fed: u64 = 0,
    mono: []f32,
    resampled: []f32,
    samples: []i16,

    pub fn init(
        allocator: std.mem.Allocator,
        sample_rate: u32,
        channels: u16,
        parameters: Parameters,
    ) !Analyzer {
        if (channels == 0 or sample_rate == 0) return error.InvalidAudioFormat;
        const target_rate = orca_chromaprint_sample_rate;

        const context = orca_chromaprint_create(@backingInt(parameters.algorithm)) orelse
            return error.FingerprinterUnavailable;
        errdefer orca_chromaprint_destroy(context);
        if (orca_chromaprint_start(context, 1) != 0) return error.FingerprinterUnavailable;

        var converter: ?resampler.SampleRate = if (sample_rate == target_rate)
            null
        else
            try resampler.SampleRate.init(parameters.converter, sample_rate, target_rate, 1);
        errdefer if (converter) |*value| value.deinit();

        const mono = try allocator.alloc(f32, chunk_frames);
        errdefer allocator.free(mono);
        const resampled_capacity = chunk_frames * @as(usize, target_rate) / sample_rate + 64;
        const resampled = try allocator.alloc(f32, resampled_capacity);
        errdefer allocator.free(resampled);
        const samples = try allocator.alloc(i16, resampled_capacity);
        return .{
            .allocator = allocator,
            .context = context,
            .converter = converter,
            .channels = channels,
            .sample_rate = sample_rate,
            .window_frames = @as(u64, parameters.max_seconds) * sample_rate,
            .mono = mono,
            .resampled = resampled,
            .samples = samples,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        if (self.converter) |*value| value.deinit();
        orca_chromaprint_destroy(self.context);
        self.allocator.free(self.samples);
        self.allocator.free(self.resampled);
        self.allocator.free(self.mono);
        self.* = undefined;
    }

    fn windowFull(self: *const Analyzer) bool {
        return self.frames_fed >= self.window_frames;
    }

    pub fn process(self: *Analyzer, interleaved: []const f32) !void {
        if (interleaved.len % self.channels != 0) return error.IncompleteAudioFrame;
        const frames = interleaved.len / self.channels;
        var offset: usize = 0;
        while (offset < frames and !self.windowFull()) {
            const take: usize = @intCast(@min(chunk_frames, frames - offset, self.window_frames - self.frames_fed));
            const mono = self.mono[0..take];
            downmix(interleaved[offset * self.channels ..][0 .. take * self.channels], self.channels, mono);
            if (self.converter) |*value| {
                try resampleInto(self.context, value, mono, self.resampled, self.samples, false);
            } else {
                try feed(self.context, mono, self.samples);
            }
            self.frames_fed += take;
            offset += take;
        }
    }

    /// `total_frames` is how many frames the caller has counted in the whole
    /// stream and `declared_frames` what the container declares. Below a full
    /// window the frames fed are the whole stream; past it the length is the
    /// larger of the two, or the count alone when nothing is declared.
    pub fn finish(self: *Analyzer, total_frames: u64, declared_frames: ?u64) !Fingerprint {
        if (self.converter) |*value| try resampleInto(self.context, value, &.{}, self.resampled, self.samples, true);
        if (orca_chromaprint_finish(self.context) != 0) return error.FingerprintFailed;

        const length_frames = if (!self.windowFull())
            self.frames_fed
        else if (declared_frames) |declared|
            @max(declared, total_frames)
        else
            total_frames;
        const duration_ms = length_frames * 1000 / self.sample_rate;
        if ((duration_ms + 500) / 1000 == 0) return error.AudioTooShortToFingerprint;

        var encoded: ?[*:0]u8 = null;
        var raw_size: u32 = 0;
        if (orca_chromaprint_fingerprint(self.context, &encoded, &raw_size) != 0) return error.FingerprintFailed;
        defer orca_chromaprint_release(encoded);
        if (raw_size == 0) return error.AudioTooShortToFingerprint;
        return .{
            .allocator = self.allocator,
            .encoded = try self.allocator.dupe(u8, std.mem.span(encoded.?)),
            .duration_ms = duration_ms,
        };
    }
};

/// Fingerprints what `decoder` produces from its current position. Any decode
/// error fails the whole fingerprint: a partial one is never returned.
pub fn fingerprintDecoder(
    allocator: std.mem.Allocator,
    decoder: codec.Decoder,
    parameters: Parameters,
    cancellation: ?*const scanner.CancellationToken,
) !Fingerprint {
    const channels: usize = decoder.format.channels;
    var analyzer = try Analyzer.init(allocator, decoder.format.sample_rate, decoder.format.channels, parameters);
    defer analyzer.deinit();
    const decoded = try allocator.alloc(f32, chunk_frames * channels);
    defer allocator.free(decoded);

    while (!analyzer.windowFull()) {
        if (isCancelled(cancellation)) return error.Cancelled;
        const wanted: usize = @intCast(@min(chunk_frames, analyzer.window_frames - analyzer.frames_fed));
        const frames = try decoder.readFrames(decoded[0 .. wanted * channels]);
        if (frames == 0) break;
        try analyzer.process(decoded[0 .. frames * channels]);
    }
    const total_frames = if (!analyzer.windowFull() or decoder.frame_count != null)
        analyzer.frames_fed
    else
        analyzer.frames_fed + try countRemaining(decoder, decoded, cancellation);
    return analyzer.finish(total_frames, decoder.frame_count);
}

fn isCancelled(cancellation: ?*const scanner.CancellationToken) bool {
    return if (cancellation) |token| token.checkpoint() else false;
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
    converter: *resampler.SampleRate,
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

    /// Without a `file_id` nothing is cached. With one, the file is read
    /// whole first, because a cached fingerprint is reused only for the
    /// bytes it was taken from.
    pub fn fingerprintFile(self: Fingerprinter, file_id: ?i64, path: []const u8) !Outcome {
        var local = try storage.LocalFileSource.open(self.io, path);
        defer local.close();
        const initial_identity = local.readable().identity();
        const cache = if (file_id == null) null else self.cache;
        const key: ?database.AnalysisCacheKey = if (cache == null) null else key: {
            const source_identity = content_hash.fromFileCancellable(self.io, local.file, local.stat.size, self) catch |err|
                return switch (err) {
                    error.UnexpectedEndOfFile => error.SourceChangedDuringAnalysis,
                    else => err,
                };
            break :key cacheKey(file_id.?, source_identity, self.parameters);
        };
        if (cache) |repository| {
            if (try repository.get(self.allocator, key.?)) |bytes| {
                defer self.allocator.free(bytes);
                if (Fingerprint.decode(self.allocator, bytes)) |cached| {
                    errdefer cached.deinit();
                    try verifyIdentity(self.io, path, initial_identity);
                    return .{ .fingerprint = cached, .cache_hit = true };
                } else |_| {}
            }
        }
        var watched: WatchedSource = .{ .inner = local.readable() };
        const fingerprint = self.decode(watched.readable()) catch |err| {
            if (cache) |repository| if (watched.contentFailure(err))
                self.recordFailure(repository, file_id.?, &local, path, initial_identity, err) catch {};
            return err;
        };
        errdefer fingerprint.deinit();
        try verifyIdentity(self.io, path, initial_identity);
        if (cache) |repository| {
            const bytes = try fingerprint.encode(self.allocator);
            defer self.allocator.free(bytes);
            try repository.put(key.?, bytes);
            const failure = failureSelector(self.parameters);
            try repository.forget(file_id.?, &failure);
        }
        return .{ .fingerprint = fingerprint, .cache_hit = false };
    }

    fn decode(self: Fingerprinter, source: storage.ReadableSource) !Fingerprint {
        var decoder = try self.codecs.openDetected(self.allocator, source);
        defer decoder.deinit();
        return fingerprintDecoder(self.allocator, decoder, self.parameters, self.cancellation);
    }

    fn recordFailure(
        self: Fingerprinter,
        repository: *database.AnalysisCacheRepository,
        file_id: i64,
        local: *const storage.LocalFileSource,
        path: []const u8,
        initial_identity: storage.StorageIdentity,
        err: anyerror,
    ) !void {
        const identity = try storage.quick_hash.fromFile(self.io, local.file, local.stat.size);
        try verifyIdentity(self.io, path, initial_identity);
        try repository.replace(.{
            .file_id = file_id,
            .kind = failure_kind,
            .algorithm_id = algorithm_id,
            .algorithm_version = algorithm_version,
            .parameter_hash = parameterHash(self.parameters),
            .source_identity = identity,
        }, @errorName(err));
    }

    pub fn cancelled(self: Fingerprinter) bool {
        return if (self.cancellation) |token| token.checkpoint() else false;
    }
};

/// A source that remembers whether any read of it failed, so a decode error
/// caused by the storage under it is not taken for one caused by the bytes.
const WatchedSource = struct {
    inner: storage.ReadableSource,
    read_failed: bool = false,

    const vtable: storage.ReadableSource.VTable = .{ .read_at = readAt, .size = size, .identity = identity };

    fn readable(self: *WatchedSource) storage.ReadableSource {
        return .{ .context = self, .vtable = &vtable };
    }

    /// Whether `err`, returned by a decode of this source, is the bytes'
    /// fault: every read succeeded, and the decode was not stopped and did
    /// not fail for want of memory, a fingerprinter, a codec or a stable file.
    fn contentFailure(self: *const WatchedSource, err: anyerror) bool {
        if (self.read_failed) return false;
        return switch (err) {
            error.Cancelled,
            error.OutOfMemory,
            error.FingerprinterUnavailable,
            error.CodecUnavailable,
            error.SourceChangedDuringAnalysis,
            => false,
            else => true,
        };
    }

    fn readAt(context: *anyopaque, offset: u64, buffer: []u8) anyerror!usize {
        const self: *WatchedSource = @ptrCast(@alignCast(context));
        return self.inner.readAt(offset, buffer) catch |err| {
            self.read_failed = true;
            return err;
        };
    }

    fn size(context: *anyopaque) u64 {
        const self: *WatchedSource = @ptrCast(@alignCast(context));
        return self.inner.size();
    }

    fn identity(context: *anyopaque) storage.StorageIdentity {
        const self: *WatchedSource = @ptrCast(@alignCast(context));
        return self.inner.identity();
    }
};

fn verifyIdentity(io: std.Io, path: []const u8, expected: storage.StorageIdentity) !void {
    var identity_check = try storage.LocalFileSource.open(io, path);
    defer identity_check.close();
    const final_identity = identity_check.readable().identity();
    if (expected.inode != final_identity.inode or expected.size != final_identity.size or
        expected.modified_ns != final_identity.modified_ns)
        return error.SourceChangedDuringAnalysis;
}

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

const parity_audio = "fixtures/audio/fingerprint-reference.mp3";
const parity_reference = "fixtures/audio/fingerprint-reference.fpcalc.txt";

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

test "Orca's fingerprint of the generated reference recording agrees with fpcalc's on at least 95% of its bits" {
    const reference = try readReference(testing.allocator);
    defer testing.allocator.free(reference.raw);
    const codecs = codec.CodecRegistry.builtins();
    const fingerprinter: Fingerprinter = .{ .allocator = testing.allocator, .io = testing.io, .codecs = &codecs };

    const outcome = try fingerprinter.fingerprintFile(null, parity_audio);
    defer outcome.fingerprint.deinit();
    const raw = try Raw.decode(outcome.fingerprint.encoded);
    defer raw.deinit();

    try testing.expectEqual(reference.duration_s, outcome.fingerprint.durationSeconds());
    try testing.expectEqual(@as(i32, @backingInt(Algorithm.test2)), raw.algorithm);
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

test "bytes that cannot be fingerprinted are recorded under their quick hash, and a later fingerprint of the file forgets them" {
    var library = try database.LibraryDatabase.open(testing.allocator, testing.io, "file:orca-chromaprint-failure?mode=memory&cache=shared");
    defer library.close();
    const silent = "fixtures/audio/generated-reference.qoa";
    const binding = try library.resolveOrCreateFile(testing.io, silent, .{ .stable_key = "test:chromaprint" });
    const codecs = codec.CodecRegistry.builtins();
    const fingerprinter: Fingerprinter = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .codecs = &codecs,
        .cache = &library.analysis_cache,
    };
    const markers = "SELECT count(*) FROM analysis_results JOIN files ON files.id = analysis_results.file_id " ++
        "WHERE analysis_results.kind = 5 AND analysis_results.source_identity = files.quick_hash;";

    if (fingerprinter.fingerprintFile(binding.file_id, silent)) |outcome| {
        outcome.fingerprint.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    try testing.expectEqual(@as(i64, 1), try database.columns.scalar(library.database, markers));

    const audible = try library.resolveOrCreateFile(testing.io, parity_audio, .{ .stable_key = "test:chromaprint" });
    try library.analysis_cache.replace(.{
        .file_id = audible.file_id,
        .kind = failure_kind,
        .algorithm_id = algorithm_id,
        .algorithm_version = algorithm_version,
        .parameter_hash = parameterHash(fingerprinter.parameters),
        .source_identity = @splat(0),
    }, "AudioTooShortToFingerprint");
    const taken = try fingerprinter.fingerprintFile(audible.file_id, parity_audio);
    defer taken.fingerprint.deinit();
    try testing.expectEqual(@as(i64, 1), try database.columns.scalar(library.database, "SELECT count(*) FROM analysis_results WHERE kind = 5;"));
    try testing.expectEqual(@as(i64, 1), try database.columns.scalar(library.database, markers));
}

test "a decode error is the bytes' fault only when every read succeeded and nothing else stopped the decode" {
    var memory: storage.MemorySource = .{ .bytes = "" };
    const readable: WatchedSource = .{ .inner = memory.readable() };
    try testing.expect(readable.contentFailure(error.InvalidFlac));
    try testing.expect(!readable.contentFailure(error.Cancelled));
    try testing.expect(!readable.contentFailure(error.OutOfMemory));
    try testing.expect(!readable.contentFailure(error.SourceChangedDuringAnalysis));

    const Failing = struct {
        fn readAt(_: *anyopaque, _: u64, _: []u8) anyerror!usize {
            return error.InputOutput;
        }
        fn size(_: *anyopaque) u64 {
            return 4096;
        }
        fn identity(_: *anyopaque) storage.StorageIdentity {
            return .{ .inode = 0, .size = 4096, .modified_ns = 0 };
        }
        const vtable: storage.ReadableSource.VTable = .{ .read_at = readAt, .size = size, .identity = identity };
    };
    var unreadable: WatchedSource = .{ .inner = .{ .context = undefined, .vtable = &Failing.vtable } };
    var buffer: [16]u8 = undefined;
    try testing.expectError(error.InputOutput, unreadable.readable().readAt(0, &buffer));
    try testing.expect(!unreadable.contentFailure(error.InvalidFlac));
}
