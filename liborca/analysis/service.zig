const std = @import("std");
const codec = @import("../codec/root.zig");
const database = @import("../database/root.zig");
const scanner = @import("../library/scanner.zig");
const quick_hash = @import("../storage/quick_hash.zig");
const storage = @import("../storage/root.zig");
const chromaprint = @import("chromaprint.zig");
const diagnostics = @import("diagnostics.zig");
const encoding = @import("encoding.zig");
const fingerprint = @import("fingerprint.zig");

pub const diagnostics_cache_kind: u8 = 1;
pub const fingerprint_cache_kind: u8 = 2;
pub const diagnostics_algorithm_id = "orca.audio-diagnostics";
/// The version covers the *input* a measurement was taken from as much as the
/// arithmetic taken over it: bump it whenever a decoder's samples change, so
/// stored figures are re-measured.
pub const diagnostics_algorithm_version: u32 = 4;
pub const fingerprint_algorithm_id = "orca.temporal-fingerprint";
/// Bumped whenever a decoder's samples or the audio hash's definition change,
/// as the diagnostics version is. The fingerprint carries `audio_hash`, which
/// becomes `files.audio_hash` and is compared for equality: a hash of subtly
/// wrong samples, or of another definition, cannot match one of correct
/// samples, so every stored fingerprint has to be retaken.
pub const fingerprint_algorithm_version: u32 = 3;

/// The cache key one diagnostics measurement is stored under.
///
/// Public because three callers must agree on it exactly: this Service, the
/// library-wide pass that decides which files still owe an analysis, and the
/// playback path that looks a correction up. Two of them derive the key from
/// the *stored* identity of a file rather than from an open one, so the shape
/// has to exist independently of a `Service`.
pub fn diagnosticsKey(
    file_id: i64,
    source_identity: quick_hash.Digest,
    parameters: diagnostics.Parameters,
) database.AnalysisCacheKey {
    return .{
        .file_id = file_id,
        .kind = diagnostics_cache_kind,
        .algorithm_id = diagnostics_algorithm_id,
        .algorithm_version = diagnostics_algorithm_version,
        .parameter_hash = encoding.parameterHash(parameters),
        .source_identity = source_identity,
    };
}

/// The diagnostics measurement, without a file or an identity: what a
/// library-wide pass selects on and what a Player looks a correction up under.
///
/// Same source as `diagnosticsKey`, so "which files still owe a measurement",
/// "what was written" and "what playback adopts" cannot drift apart.
pub fn diagnosticsSelector(
    parameters: diagnostics.Parameters,
) database.repository.AnalysisSelector {
    return .{
        .kind = diagnostics_cache_kind,
        .algorithm_id = diagnostics_algorithm_id,
        .algorithm_version = diagnostics_algorithm_version,
        .parameter_hash = encoding.parameterHash(parameters),
    };
}

/// The fingerprint measurement, without a file or an identity, as
/// `diagnosticsSelector` is for diagnostics.
pub fn fingerprintSelector() database.repository.AnalysisSelector {
    return .{
        .kind = fingerprint_cache_kind,
        .algorithm_id = fingerprint_algorithm_id,
        .algorithm_version = fingerprint_algorithm_version,
        .parameter_hash = @splat(0),
    };
}

/// Every measurement `Service.analyzeFile` stores, for selecting the files
/// that still owe any of them.
pub fn analysisSelectors(
    parameters: diagnostics.Parameters,
) database.repository.AnalysisSelectors {
    return .{ diagnosticsSelector(parameters), fingerprintSelector() };
}

/// The fingerprint's key. Its parameter hash is zero because the fingerprint
/// analyzer takes no parameters: giving it a hash of the *diagnostics*
/// parameters would invalidate a fingerprint whenever an unrelated waveform
/// resolution changed.
pub fn fingerprintKey(
    file_id: i64,
    source_identity: quick_hash.Digest,
) database.AnalysisCacheKey {
    return .{
        .file_id = file_id,
        .kind = fingerprint_cache_kind,
        .algorithm_id = fingerprint_algorithm_id,
        .algorithm_version = fingerprint_algorithm_version,
        .parameter_hash = @splat(0),
        .source_identity = source_identity,
    };
}

pub const Progress = struct {
    completed_frames: u64,
    total_frames: ?u64,
};

pub const ProgressCallback = struct {
    context: ?*anyopaque = null,
    update: *const fn (?*anyopaque, Progress) void,
};

pub const Analysis = struct {
    diagnostics: diagnostics.Result,
    fingerprint: fingerprint.Result,
    /// The AcoustID fingerprint under the default `chromaprint.Parameters`.
    /// Null when the audio is too short to fingerprint, when Chromaprint
    /// failed, or on a cache hit that stored none.
    chromaprint: ?chromaprint.Fingerprint,
    cache_hit: bool,
    /// Frames decoded, or null on a cache hit, which decodes nothing.
    decoded_frames: ?u64,
    /// The identity of the bytes this measurement describes, as the Service
    /// observed them. A caller that stores the result itself keys on this
    /// rather than on what a database row claims, so a measurement can never
    /// be filed under an identity it was not taken from.
    source_identity: quick_hash.Digest,

    pub fn deinit(self: Analysis) void {
        self.diagnostics.deinit();
        self.fingerprint.deinit();
        if (self.chromaprint) |value| value.deinit();
    }
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    codecs: *const codec.CodecRegistry,
    cache: ?*database.AnalysisCacheRepository = null,
    cancellation: ?*const scanner.CancellationToken = null,
    progress: ?ProgressCallback = null,
    /// Analysis is background work: yield after each bounded I/O/decode chunk
    /// so transport and render threads remain schedulable on constrained hosts.
    yield_between_chunks: bool = true,

    /// Analyze one file, caching against `file_id` and the file's quick hash.
    ///
    /// Passing no `file_id` analyzes without touching the cache — the honest
    /// answer for a source the Library has no identity for yet. Keying on the
    /// quick hash rather than size and mtime is what lets a loudness
    /// measurement survive Orca writing a tag into the same file.
    pub fn analyzeFile(
        self: Service,
        file_id: ?i64,
        path: []const u8,
        parameters: diagnostics.Parameters,
    ) !Analysis {
        if (self.cancelled()) return error.Cancelled;
        var local = try storage.LocalFileSource.open(self.io, path);
        defer local.close();
        const initial_identity = local.readable().identity();
        const source_identity = try quick_hash.fromSource(local.readable());
        const diagnostics_key = diagnosticsKey(file_id orelse 0, source_identity, parameters);
        const fingerprint_key = fingerprintKey(file_id orelse 0, source_identity);
        const chromaprint_key = chromaprint.cacheKey(file_id orelse 0, source_identity, .{});
        if (if (file_id == null) null else self.cache) |cache| {
            const cached_diagnostics = try self.loadDiagnostics(cache, diagnostics_key);
            const cached_fingerprint = try self.loadFingerprint(cache, fingerprint_key);
            if (cached_diagnostics != null and cached_fingerprint != null) {
                errdefer cached_diagnostics.?.deinit();
                errdefer cached_fingerprint.?.deinit();
                const cached_chromaprint = try self.loadChromaprint(cache, chromaprint_key);
                errdefer if (cached_chromaprint) |value| value.deinit();
                if (self.cancelled()) return error.Cancelled;
                try self.verifyIdentity(path, initial_identity);
                return .{
                    .diagnostics = cached_diagnostics.?,
                    .fingerprint = cached_fingerprint.?,
                    .chromaprint = cached_chromaprint,
                    .cache_hit = true,
                    .decoded_frames = null,
                    .source_identity = source_identity,
                };
            }
            if (cached_diagnostics) |result| result.deinit();
            if (cached_fingerprint) |result| result.deinit();
        }

        var decoder = try self.codecs.openDetected(self.allocator, local.readable());
        defer decoder.deinit();
        var analyzer = try diagnostics.Analyzer.init(
            self.allocator,
            decoder.format.sample_rate,
            decoder.format.channels,
            decoder.frame_count,
            parameters,
        );
        defer analyzer.deinit();
        const integer_source = decoder.hasIntegerSamples();
        var fingerprinter = try fingerprint.Analyzer.init(
            self.allocator,
            decoder.format.sample_rate,
            decoder.format.channels,
            if (integer_source) .lossless_integer else .decoded_float,
        );
        defer fingerprinter.deinit();
        // This analyzer never reads the source, so none of its errors is a
        // decode error: each costs the AcoustID fingerprint, never the file.
        var acoustid: ?chromaprint.Analyzer = chromaprint.Analyzer.init(
            self.allocator,
            decoder.format.sample_rate,
            decoder.format.channels,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        defer if (acoustid) |*value| value.deinit();
        const chunk_samples = 4096 * @as(usize, decoder.format.channels);
        const samples = try self.allocator.alloc(f32, chunk_samples);
        defer self.allocator.free(samples);
        const integers = try self.allocator.alloc(i32, if (integer_source) chunk_samples else 0);
        defer self.allocator.free(integers);
        var completed_frames: u64 = 0;
        while (true) {
            if (self.cancelled()) return error.Cancelled;
            const frames = if (integer_source)
                try decoder.readFramesI32(integers)
            else
                try decoder.readFrames(samples);
            if (frames == 0) break;
            const chunk = samples[0 .. frames * decoder.format.channels];
            if (integer_source) {
                const integer_chunk = integers[0..chunk.len];
                for (chunk, integer_chunk) |*sample, integer|
                    sample.* = codec.decoder.integerSampleToFloat(integer);
                try fingerprinter.processIntegers(integer_chunk);
            } else {
                try fingerprinter.process(chunk);
            }
            try analyzer.process(chunk);
            if (acoustid) |*value| value.process(chunk) catch {
                value.deinit();
                acoustid = null;
            };
            completed_frames += frames;
            if (self.progress) |callback| callback.update(callback.context, .{
                .completed_frames = completed_frames,
                .total_frames = decoder.frame_count,
            });
            if (self.yield_between_chunks) std.Thread.yield() catch {};
        }
        if (self.cancelled()) return error.Cancelled;
        const result = try analyzer.finish();
        errdefer result.deinit();
        const fingerprint_result = try fingerprinter.finish();
        errdefer fingerprint_result.deinit();
        const acoustid_result: ?chromaprint.Fingerprint = if (acoustid) |*value|
            value.finish(completed_frames, decoder.frame_count) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            }
        else
            null;
        errdefer if (acoustid_result) |value| value.deinit();

        try self.verifyIdentity(path, initial_identity);
        if (if (file_id == null) null else self.cache) |cache| {
            const bytes = try encoding.encode(self.allocator, result);
            defer self.allocator.free(bytes);
            try cache.put(diagnostics_key, bytes);
            const fingerprint_bytes = try fingerprint.encode(self.allocator, fingerprint_result);
            defer self.allocator.free(fingerprint_bytes);
            try cache.put(fingerprint_key, fingerprint_bytes);
            if (acoustid_result) |value| {
                const chromaprint_bytes = try value.encode(self.allocator);
                defer self.allocator.free(chromaprint_bytes);
                try cache.put(chromaprint_key, chromaprint_bytes);
            }
        }
        return .{
            .diagnostics = result,
            .fingerprint = fingerprint_result,
            .chromaprint = acoustid_result,
            .cache_hit = false,
            .decoded_frames = completed_frames,
            .source_identity = source_identity,
        };
    }

    fn cancelled(self: Service) bool {
        return if (self.cancellation) |token| token.checkpoint() else false;
    }

    fn verifyIdentity(self: Service, path: []const u8, expected: storage.StorageIdentity) !void {
        var identity_check = try storage.LocalFileSource.open(self.io, path);
        defer identity_check.close();
        if (!sameIdentity(expected, identity_check.readable().identity()))
            return error.SourceChangedDuringAnalysis;
    }

    fn loadDiagnostics(
        self: Service,
        cache: *database.AnalysisCacheRepository,
        key: database.AnalysisCacheKey,
    ) !?diagnostics.Result {
        const bytes = (try cache.get(self.allocator, key)) orelse return null;
        defer self.allocator.free(bytes);
        return encoding.decode(self.allocator, bytes) catch null;
    }

    fn loadFingerprint(
        self: Service,
        cache: *database.AnalysisCacheRepository,
        key: database.AnalysisCacheKey,
    ) !?fingerprint.Result {
        const bytes = (try cache.get(self.allocator, key)) orelse return null;
        defer self.allocator.free(bytes);
        return fingerprint.decode(self.allocator, bytes) catch null;
    }

    fn loadChromaprint(
        self: Service,
        cache: *database.AnalysisCacheRepository,
        key: database.AnalysisCacheKey,
    ) !?chromaprint.Fingerprint {
        const bytes = (try cache.get(self.allocator, key)) orelse return null;
        defer self.allocator.free(bytes);
        return chromaprint.Fingerprint.decode(self.allocator, bytes) catch null;
    }
};

fn sameIdentity(first: storage.StorageIdentity, second: storage.StorageIdentity) bool {
    return first.inode == second.inode and
        first.size == second.size and
        first.modified_ns == second.modified_ns;
}

test "service streams codecs into cache and cancellation publishes nothing" {
    const allocator = std.testing.allocator;
    var library = try database.LibraryDatabase.open(
        allocator,
        std.testing.io,
        "file:orca-analysis-service?mode=memory&cache=shared",
    );
    defer library.close();
    const codecs = codec.CodecRegistry.builtins();
    const service: Service = .{
        .allocator = allocator,
        .io = std.testing.io,
        .codecs = &codecs,
        .cache = &library.analysis_cache,
    };
    const binding = try library.resolveOrCreateFile(
        std.testing.io,
        "fixtures/audio/generated-reference.flac",
        .{ .stable_key = "test:analysis" },
    );
    var first = try service.analyzeFile(
        binding.file_id,
        "fixtures/audio/generated-reference.flac",
        .{ .waveform_buckets = 16 },
    );
    defer first.deinit();
    try std.testing.expect(!first.cache_hit);
    var second = try service.analyzeFile(
        binding.file_id,
        "fixtures/audio/generated-reference.flac",
        .{ .waveform_buckets = 16 },
    );
    defer second.deinit();
    try std.testing.expect(second.cache_hit);
    try std.testing.expectEqual(first.diagnostics.sample_peak, second.diagnostics.sample_peak);
    try std.testing.expect(first.fingerprint.audio_hash.eql(second.fingerprint.audio_hash));

    var cancellation: scanner.CancellationToken = .{};
    cancellation.cancel();
    var cancelled_service = service;
    cancelled_service.cancellation = &cancellation;
    try std.testing.expectError(error.Cancelled, cancelled_service.analyzeFile(
        null,
        "fixtures/audio/generated-reference.qoa",
        .{ .waveform_buckets = 16 },
    ));
}

test "the library keeps the integrated loudness a default analysis stores, as the stored float" {
    const allocator = std.testing.allocator;
    var library = try database.LibraryDatabase.open(
        allocator,
        std.testing.io,
        "file:orca-analysis-loudness?mode=memory&cache=shared",
    );
    defer library.close();
    const codecs = codec.CodecRegistry.builtins();
    const service: Service = .{
        .allocator = allocator,
        .io = std.testing.io,
        .codecs = &codecs,
        .cache = &library.analysis_cache,
    };
    const binding = try library.resolveOrCreateFile(
        std.testing.io,
        "fixtures/audio/fingerprint-reference.mp3",
        .{ .stable_key = "test:loudness" },
    );
    var analysis = try service.analyzeFile(binding.file_id, "fixtures/audio/fingerprint-reference.mp3", .{});
    defer analysis.deinit();
    const expected = analysis.diagnostics.integrated_lufs.?;

    var statement = try library.database.prepare("SELECT integrated_lufs FROM file_loudness WHERE file_id = ?1;");
    defer statement.deinit();
    try statement.bindInt64(1, binding.file_id);
    try std.testing.expectEqual(database.sqlite.Step.row, try statement.step());
    try std.testing.expectEqual(expected, @as(f32, @floatCast(statement.columnDouble(0))));
}

test "the AcoustID fingerprint taken in the analysis decode is the one a standalone fingerprint takes" {
    const allocator = std.testing.allocator;
    const codecs = codec.CodecRegistry.builtins();
    const service: Service = .{
        .allocator = allocator,
        .io = std.testing.io,
        .codecs = &codecs,
    };
    const analysis = try service.analyzeFile(null, "fixtures/audio/fingerprint-reference.mp3", .{});
    defer analysis.deinit();
    const fingerprinter: chromaprint.Fingerprinter = .{
        .allocator = allocator,
        .io = std.testing.io,
        .codecs = &codecs,
    };
    const standalone = try fingerprinter.fingerprintFile(null, "fixtures/audio/fingerprint-reference.mp3");
    defer standalone.fingerprint.deinit();

    const measured = analysis.chromaprint.?;
    try std.testing.expectEqualStrings(standalone.fingerprint.encoded, measured.encoded);
    try std.testing.expectEqual(standalone.fingerprint.duration_ms, measured.duration_ms);
}

test "audio too short to fingerprint is still measured, without an AcoustID fingerprint" {
    const allocator = std.testing.allocator;
    const codecs = codec.CodecRegistry.builtins();
    const service: Service = .{
        .allocator = allocator,
        .io = std.testing.io,
        .codecs = &codecs,
    };
    const analysis = try service.analyzeFile(null, "fixtures/audio/generated-reference.qoa", .{});
    defer analysis.deinit();
    try std.testing.expect(analysis.chromaprint == null);
    try std.testing.expect(analysis.fingerprint.signatures.len > 0);
}

const TestFiles = struct {
    directory: std.testing.TmpDir,

    fn init() TestFiles {
        return .{ .directory = std.testing.tmpDir(.{}) };
    }

    fn deinit(self: *TestFiles) void {
        self.directory.cleanup();
    }

    fn writeWav(
        self: *TestFiles,
        name: []const u8,
        sample_rate: u32,
        channels: u16,
        bits: u16,
        samples: []const i32,
    ) ![]u8 {
        const allocator = std.testing.allocator;
        const width: usize = bits / 8;
        const data_len = samples.len * width;
        const bytes = try allocator.alloc(u8, 44 + data_len);
        defer allocator.free(bytes);
        @memcpy(bytes[0..4], "RIFF");
        std.mem.writeInt(u32, bytes[4..8], @intCast(36 + data_len), .little);
        @memcpy(bytes[8..16], "WAVEfmt ");
        std.mem.writeInt(u32, bytes[16..20], 16, .little);
        std.mem.writeInt(u16, bytes[20..22], 1, .little);
        std.mem.writeInt(u16, bytes[22..24], channels, .little);
        std.mem.writeInt(u32, bytes[24..28], sample_rate, .little);
        std.mem.writeInt(u32, bytes[28..32], @intCast(sample_rate * channels * width), .little);
        std.mem.writeInt(u16, bytes[32..34], @intCast(channels * width), .little);
        std.mem.writeInt(u16, bytes[34..36], bits, .little);
        @memcpy(bytes[36..40], "data");
        std.mem.writeInt(u32, bytes[40..44], @intCast(data_len), .little);
        for (samples, 0..) |sample, index| {
            const encoded: u32 = @bitCast(sample);
            for (0..width) |byte|
                bytes[44 + index * width + byte] = @truncate(encoded >> @intCast(8 * byte));
        }
        try self.directory.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
        return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ self.directory.sub_path, name });
    }
};

test "two 32-bit integer WAVs one LSB apart hash differently" {
    const allocator = std.testing.allocator;
    var files = TestFiles.init();
    defer files.deinit();
    var samples: [4800]i32 = undefined;
    for (&samples, 0..) |*sample, index|
        sample.* = @intCast(@as(i64, @intCast(index)) * 400_000 - 960_000_000);
    const original = try files.writeWav("original.wav", 48_000, 1, 32, &samples);
    defer allocator.free(original);
    samples[4000] += 1;
    const nudged = try files.writeWav("nudged.wav", 48_000, 1, 32, &samples);
    defer allocator.free(nudged);
    const codecs = codec.CodecRegistry.builtins();
    const service: Service = .{ .allocator = allocator, .io = std.testing.io, .codecs = &codecs };
    const first = try service.analyzeFile(null, original, .{});
    defer first.deinit();
    const second = try service.analyzeFile(null, nudged, .{});
    defer second.deinit();
    try std.testing.expectEqual(fingerprint.AudioHashTier.lossless_integer, first.fingerprint.audio_hash.tier);
    try std.testing.expect(!first.fingerprint.audio_hash.eql(second.fingerprint.audio_hash));
}

const DecodedIntegers = struct {
    source_bits: u16,
    sample_rate: u32,
    channels: u16,
    samples: []i32,

    fn deinit(self: DecodedIntegers) void {
        std.testing.allocator.free(self.samples);
    }
};

fn decodeIntegers(path: []const u8) !DecodedIntegers {
    const allocator = std.testing.allocator;
    var file = try storage.LocalFileSource.open(std.testing.io, path);
    defer file.close();
    const codecs = codec.CodecRegistry.builtins();
    var decoder = try codecs.openDetected(allocator, file.readable());
    defer decoder.deinit();
    var samples: std.ArrayList(i32) = .empty;
    errdefer samples.deinit(allocator);
    var buffer: [1024]i32 = undefined;
    const usable = buffer[0 .. buffer.len - buffer.len % decoder.format.channels];
    while (true) {
        const frames = try decoder.readFramesI32(usable);
        if (frames == 0) break;
        try samples.appendSlice(allocator, usable[0 .. frames * decoder.format.channels]);
    }
    return .{
        .source_bits = decoder.source_format.?.bits_per_sample,
        .sample_rate = decoder.format.sample_rate,
        .channels = decoder.format.channels,
        .samples = try samples.toOwnedSlice(allocator),
    };
}

fn analyzeUncached(path: []const u8) !Analysis {
    const codecs = codec.CodecRegistry.builtins();
    const service: Service = .{ .allocator = std.testing.allocator, .io = std.testing.io, .codecs = &codecs };
    return service.analyzeFile(null, path, .{});
}

fn rightJustified(allocator: std.mem.Allocator, samples: []const i32, bits: u16) ![]i32 {
    const shifted = try allocator.alloc(i32, samples.len);
    for (shifted, samples) |*target, sample| target.* = sample >> @intCast(32 - bits);
    return shifted;
}

test "the same 16-bit samples in FLAC, WAV, AIFC and 24-bit WAV and AIFF hash equally at width 16" {
    const allocator = std.testing.allocator;
    var files = TestFiles.init();
    defer files.deinit();
    const flac = try decodeIntegers("fixtures/audio/generated-reference.flac");
    defer flac.deinit();
    try std.testing.expectEqual(@as(u16, 16), flac.source_bits);
    const plain_samples = try rightJustified(allocator, flac.samples, 16);
    defer allocator.free(plain_samples);
    const plain_path = try files.writeWav("plain.wav", flac.sample_rate, flac.channels, 16, plain_samples);
    defer allocator.free(plain_path);
    const padded_samples = try rightJustified(allocator, flac.samples, 24);
    defer allocator.free(padded_samples);
    const padded_path = try files.writeWav("padded.wav", flac.sample_rate, flac.channels, 24, padded_samples);
    defer allocator.free(padded_path);
    const paths = [_][]const u8{
        plain_path,
        padded_path,
        "fixtures/audio/extensible-reference.wav",
        "fixtures/audio/generated-reference-24.aiff",
        "fixtures/audio/sowt-reference.aifc",
    };
    const container_bits = [_]u16{ 16, 24, 24, 24, 16 };
    for (paths, container_bits) |path, bits| {
        const decoded = try decodeIntegers(path);
        defer decoded.deinit();
        try std.testing.expectEqual(bits, decoded.source_bits);
        try std.testing.expectEqualSlices(i32, flac.samples, decoded.samples);
    }

    const reference = try analyzeUncached("fixtures/audio/generated-reference.flac");
    defer reference.deinit();
    try std.testing.expectEqual(fingerprint.AudioHashTier.lossless_integer, reference.fingerprint.audio_hash.tier);
    try std.testing.expectEqual(@as(u8, 16), reference.fingerprint.audio_hash.effective_bits);
    for (paths) |path| {
        const analysis = try analyzeUncached(path);
        defer analysis.deinit();
        try std.testing.expectEqual(@as(u8, 16), analysis.fingerprint.audio_hash.effective_bits);
        try std.testing.expect(reference.fingerprint.audio_hash.eql(analysis.fingerprint.audio_hash));
        try std.testing.expectEqual(
            fingerprint.DuplicateKind.exact_audio,
            fingerprint.classifyDuplicate(reference.fingerprint, analysis.fingerprint, 0.9),
        );
    }
}

test "a mid-side FLAC hashes equal to a WAV of its decoded samples" {
    const allocator = std.testing.allocator;
    var files = TestFiles.init();
    defer files.deinit();
    const flac = try decodeIntegers("fixtures/audio/midside-reference.flac");
    defer flac.deinit();
    try std.testing.expectEqual(@as(u16, 2), flac.channels);
    const container_bits: u16 = (flac.source_bits + 7) / 8 * 8;
    const stored = try rightJustified(allocator, flac.samples, flac.source_bits);
    defer allocator.free(stored);
    for (stored) |*sample| sample.* <<= @intCast(container_bits - flac.source_bits);
    const path = try files.writeWav("midside.wav", flac.sample_rate, flac.channels, container_bits, stored);
    defer allocator.free(path);
    const wav = try decodeIntegers(path);
    defer wav.deinit();
    try std.testing.expectEqualSlices(i32, flac.samples, wav.samples);

    const flac_analysis = try analyzeUncached("fixtures/audio/midside-reference.flac");
    defer flac_analysis.deinit();
    const wav_analysis = try analyzeUncached(path);
    defer wav_analysis.deinit();
    try std.testing.expectEqual(fingerprint.AudioHashTier.lossless_integer, flac_analysis.fingerprint.audio_hash.tier);
    try std.testing.expect(flac_analysis.fingerprint.audio_hash.eql(wav_analysis.fingerprint.audio_hash));
}

test "ALAC in MP4 hashes equal to the FLAC of the same samples" {
    const alac = try decodeIntegers("fixtures/audio/tagged-reference-alac.m4a");
    defer alac.deinit();
    const flac = try decodeIntegers("fixtures/audio/tagged-reference.flac");
    defer flac.deinit();
    try std.testing.expectEqualSlices(i32, flac.samples, alac.samples);

    const alac_analysis = try analyzeUncached("fixtures/audio/tagged-reference-alac.m4a");
    defer alac_analysis.deinit();
    const flac_analysis = try analyzeUncached("fixtures/audio/tagged-reference.flac");
    defer flac_analysis.deinit();
    try std.testing.expectEqual(fingerprint.AudioHashTier.lossless_integer, alac_analysis.fingerprint.audio_hash.tier);
    try std.testing.expect(alac_analysis.fingerprint.audio_hash.eql(flac_analysis.fingerprint.audio_hash));
}

test "a QOA encoding of a WAV is at most a likely duplicate of it" {
    const qoa = try analyzeUncached("fixtures/audio/stereo-reference.qoa");
    defer qoa.deinit();
    const wav = try analyzeUncached("fixtures/audio/generated-reference.wav");
    defer wav.deinit();
    try std.testing.expectEqual(fingerprint.AudioHashTier.decoded_float, qoa.fingerprint.audio_hash.tier);
    try std.testing.expectEqual(fingerprint.AudioHashTier.lossless_integer, wav.fingerprint.audio_hash.tier);
    try std.testing.expect(!qoa.fingerprint.audio_hash.eql(wav.fingerprint.audio_hash));
    try std.testing.expect(fingerprint.classifyDuplicate(qoa.fingerprint, wav.fingerprint, 0.0) != .exact_audio);
}

test "the same samples at another rate or as duplicated stereo hash differently" {
    const allocator = std.testing.allocator;
    var files = TestFiles.init();
    defer files.deinit();
    var mono: [4800]i32 = undefined;
    for (&mono, 0..) |*sample, index| sample.* = @intCast(@as(i32, @intCast(index % 200)) * 100 - 10_000);
    var stereo: [mono.len * 2]i32 = undefined;
    for (mono, 0..) |sample, index| {
        stereo[index * 2] = sample;
        stereo[index * 2 + 1] = sample;
    }
    const at_48k = try files.writeWav("mono-48k.wav", 48_000, 1, 16, &mono);
    defer allocator.free(at_48k);
    const at_44k = try files.writeWav("mono-44k.wav", 44_100, 1, 16, &mono);
    defer allocator.free(at_44k);
    const doubled = try files.writeWav("stereo-48k.wav", 48_000, 2, 16, &stereo);
    defer allocator.free(doubled);

    const first = try analyzeUncached(at_48k);
    defer first.deinit();
    const resampled = try analyzeUncached(at_44k);
    defer resampled.deinit();
    const widened = try analyzeUncached(doubled);
    defer widened.deinit();
    try std.testing.expect(!first.fingerprint.audio_hash.eql(resampled.fingerprint.audio_hash));
    try std.testing.expect(!first.fingerprint.audio_hash.eql(widened.fingerprint.audio_hash));
}
