const std = @import("std");
const codec = @import("../codec/root.zig");
const database = @import("../database/root.zig");
const scanner = @import("../library/scanner.zig");
const content_hash = @import("../storage/content_hash.zig");
const storage = @import("../storage/root.zig");
const audio_features = @import("audio_features.zig");
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
    source_identity: content_hash.Digest,
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
/// that still owe any of them, and the verdict that excuses a file `codecs`
/// cannot decode.
pub fn analysisSelectors(
    parameters: diagnostics.Parameters,
    codecs: *const codec.CodecRegistry,
) database.repository.AnalysisSelectors {
    return .{
        .measurements = .{ diagnosticsSelector(parameters), fingerprintSelector(), featuresSelector() },
        .undecodable = undecodableSelector(codecs),
    };
}

/// The audio features measurement under the default
/// `audio_features.Parameters`, the only parameters the Library's
/// `file_audio_features` triggers recognise.
pub fn featuresSelector() database.repository.AnalysisSelector {
    return .{
        .kind = audio_features.cache_kind,
        .algorithm_id = audio_features.algorithm_id,
        .algorithm_version = audio_features.algorithm_version,
        .parameter_hash = audio_features.parameterHash(.{}),
    };
}

pub fn featuresKey(
    file_id: i64,
    source_identity: content_hash.Digest,
) database.AnalysisCacheKey {
    const selector = featuresSelector();
    return .{
        .file_id = file_id,
        .kind = selector.kind,
        .algorithm_id = selector.algorithm_id,
        .algorithm_version = selector.algorithm_version,
        .parameter_hash = selector.parameter_hash,
        .source_identity = source_identity,
    };
}

pub const undecodable_cache_kind: u8 = 4;
pub const undecodable_algorithm_id = "orca.decoder-set";
/// Bump whenever a decoder starts accepting content it used to refuse without
/// its format or name changing, or analysis starts taking more than
/// `codec.decoder.max_supported_channels` channels, so files refused for
/// either are examined again.
pub const undecodable_algorithm_version: u32 = 1;

/// Which decoders judged a file: each registered format and decoder name, in
/// format order. Registering a decoder for a new format, or renaming one,
/// changes it.
pub fn decoderSetHash(codecs: *const codec.CodecRegistry) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    for (std.enums.values(storage.AudioFormat)) |format| {
        for (codecs.entries[0..codecs.count]) |entry| {
            if (entry.format != format) continue;
            var length: [4]u8 = undefined;
            std.mem.writeInt(u32, &length, @intCast(entry.name.len), .little);
            hasher.update(&.{@backingInt(format)});
            hasher.update(&length);
            hasher.update(entry.name);
        }
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

/// The verdict that `codecs` cannot decode a file's bytes, without a file or
/// an identity, as `diagnosticsSelector` is for diagnostics.
pub fn undecodableSelector(codecs: *const codec.CodecRegistry) database.repository.AnalysisSelector {
    return .{
        .kind = undecodable_cache_kind,
        .algorithm_id = undecodable_algorithm_id,
        .algorithm_version = undecodable_algorithm_version,
        .parameter_hash = decoderSetHash(codecs),
    };
}

/// The key a verdict that `codecs` cannot decode the bytes with
/// `source_identity` is stored under. Its result is the decoder's error name.
pub fn undecodableKey(
    file_id: i64,
    source_identity: content_hash.Digest,
    codecs: *const codec.CodecRegistry,
) database.AnalysisCacheKey {
    const selector = undecodableSelector(codecs);
    return .{
        .file_id = file_id,
        .kind = selector.kind,
        .algorithm_id = selector.algorithm_id,
        .algorithm_version = selector.algorithm_version,
        .parameter_hash = selector.parameter_hash,
        .source_identity = source_identity,
    };
}

/// The fingerprint's key. Its parameter hash is zero because the fingerprint
/// analyzer takes no parameters: giving it a hash of the *diagnostics*
/// parameters would invalidate a fingerprint whenever an unrelated waveform
/// resolution changed.
pub fn fingerprintKey(
    file_id: i64,
    source_identity: content_hash.Digest,
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
    /// failed, or when none was stored and this call did not decode.
    chromaprint: ?chromaprint.Fingerprint,
    /// Tempo, key, onset rate and centroid under the default
    /// `audio_features.Parameters`. Null only when the analyzer failed.
    features: ?audio_features.Features,
    /// Which results this call measured rather than took from storage.
    measured: Measured,
    cache_hit: bool,
    /// Frames decoded, or null on a cache hit, which decodes nothing.
    decoded_frames: ?u64,
    /// The content hash of the bytes this measurement describes, read by the
    /// Service itself. A caller that stores the result itself keys on this
    /// rather than on what a database row claims, so a measurement can never
    /// be filed under an identity it was not taken from.
    source_identity: content_hash.Digest,
    /// The file's storage identity when it was opened, which it still had
    /// once the measurement was taken.
    storage_identity: storage.StorageIdentity,
    channels: u16,

    pub const Measured = struct {
        diagnostics: bool = false,
        fingerprint: bool = false,
        chromaprint: bool = false,
        features: bool = false,
    };

    pub fn deinit(self: Analysis) void {
        self.diagnostics.deinit();
        self.fingerprint.deinit();
        if (self.chromaprint) |value| value.deinit();
    }
};

/// Results already stored for one file's bytes, each null when none is.
/// `examineFile` reuses them only when `source_identity` is the content hash
/// of the bytes it opens.
pub const StoredResults = struct {
    source_identity: content_hash.Digest,
    diagnostics: ?[]const u8 = null,
    fingerprint: ?[]const u8 = null,
    chromaprint: ?[]const u8 = null,
    features: ?[]const u8 = null,

    /// Whether these hold every result a decode would otherwise be needed
    /// for. A missing AcoustID fingerprint never forces a decode: audio too
    /// short for one never has one.
    pub fn complete(self: StoredResults) bool {
        return self.diagnostics != null and self.fingerprint != null and self.features != null;
    }
};

/// Results reused rather than measured, decoded and owned.
const Reused = struct {
    diagnostics: ?diagnostics.Result = null,
    fingerprint: ?fingerprint.Result = null,
    chromaprint: ?chromaprint.Fingerprint = null,
    features: ?audio_features.Features = null,

    fn complete(self: Reused) bool {
        return self.diagnostics != null and self.fingerprint != null and self.features != null;
    }

    fn deinit(self: Reused) void {
        if (self.diagnostics) |value| value.deinit();
        if (self.fingerprint) |value| value.deinit();
        if (self.chromaprint) |value| value.deinit();
    }
};

/// The decoders refused bytes that were all read without error.
pub const Refusal = struct {
    /// The decoder's error. `error.UnsupportedAudioFormat` and
    /// `error.CodecUnavailable` mean no decoder takes the encoding, and
    /// `error.UnsupportedChannelCount` that analysis does not take its channel
    /// count; anything else means the content is damaged.
    reason: anyerror,
    source_identity: content_hash.Digest,
    storage_identity: storage.StorageIdentity,
};

pub const Examination = union(enum) {
    analyzed: Analysis,
    undecodable: Refusal,
};

/// Tells a decoder refusing the bytes from a read failing underneath it. A
/// decoder sees a failed read through its own error set, often as a decode
/// error, so the failure is recorded where it happens.
const ReadWatch = struct {
    source: storage.ReadableSource,
    read_failed: bool = false,
    refused: bool = false,

    fn readable(self: *ReadWatch) storage.ReadableSource {
        return .{ .context = self, .vtable = &vtable };
    }

    /// Returns `err`, a decoder's, and records it as a refusal of the content
    /// when every read so far succeeded.
    fn decoderFailed(self: *ReadWatch, err: anyerror) anyerror {
        if (!self.read_failed and err != error.OutOfMemory) self.refused = true;
        return err;
    }

    fn readAt(context: *anyopaque, offset: u64, buffer: []u8) anyerror!usize {
        const self: *ReadWatch = @ptrCast(@alignCast(context));
        return self.source.readAt(offset, buffer) catch |err| {
            self.read_failed = true;
            return err;
        };
    }

    fn size(context: *anyopaque) u64 {
        const self: *ReadWatch = @ptrCast(@alignCast(context));
        return self.source.size();
    }

    fn identity(context: *anyopaque) storage.StorageIdentity {
        const self: *ReadWatch = @ptrCast(@alignCast(context));
        return self.source.identity();
    }

    const vtable: storage.ReadableSource.VTable = .{
        .read_at = readAt,
        .size = size,
        .identity = identity,
    };
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

    /// Analyze one file, caching against `file_id` and the content hash of
    /// the file's bytes, which it reads whole after opening the decoder.
    /// The decoder opens first so a file with more than two channels is
    /// refused even when a stored result for its bytes exists.
    ///
    /// Passing no `file_id` analyzes without touching the cache — the honest
    /// answer for a source the Library has no identity for yet. A stored
    /// result is reused only for exactly the bytes it was measured from, so
    /// any write into the file, a tag included, takes a new measurement.
    pub fn analyzeFile(
        self: Service,
        file_id: ?i64,
        path: []const u8,
        parameters: diagnostics.Parameters,
    ) !Analysis {
        if (self.cancelled()) return error.Cancelled;
        var local = try storage.LocalFileSource.open(self.io, path);
        defer local.close();
        var watch: ReadWatch = .{ .source = local.readable() };
        var source_identity: ?content_hash.Digest = null;
        return self.analyzeOpen(file_id, path, parameters, null, &local, &watch, &source_identity);
    }

    /// `analyzeFile`, except that bytes the decoders refuse are an answer
    /// rather than an error, with the content hash they were refused for.
    /// A read that fails, cancellation and a file that changes underneath the
    /// analysis are still errors: none of them says anything about the bytes.
    ///
    /// Each of `stored` that decodes is reused instead of measured when the
    /// bytes opened are the ones it names, and the file is decoded only for
    /// what is missing.
    pub fn examineFile(
        self: Service,
        file_id: ?i64,
        path: []const u8,
        parameters: diagnostics.Parameters,
        stored: ?*const StoredResults,
    ) !Examination {
        if (self.cancelled()) return error.Cancelled;
        var local = try storage.LocalFileSource.open(self.io, path);
        defer local.close();
        var watch: ReadWatch = .{ .source = local.readable() };
        var source_identity: ?content_hash.Digest = null;
        const analysis = self.analyzeOpen(file_id, path, parameters, stored, &local, &watch, &source_identity) catch |err| {
            if (!watch.refused) return err;
            const storage_identity = local.readable().identity();
            const refused_identity = source_identity orelse try self.hashSource(&local);
            try self.verifyIdentity(path, storage_identity);
            return .{ .undecodable = .{
                .reason = err,
                .source_identity = refused_identity,
                .storage_identity = storage_identity,
            } };
        };
        return .{ .analyzed = analysis };
    }

    fn hashSource(self: Service, local: *const storage.LocalFileSource) !content_hash.Digest {
        return content_hash.fromFileCancellable(self.io, local.file, local.stat.size, self) catch |err|
            switch (err) {
                error.UnexpectedEndOfFile => error.SourceChangedDuringAnalysis,
                else => err,
            };
    }

    fn analyzeOpen(
        self: Service,
        file_id: ?i64,
        path: []const u8,
        parameters: diagnostics.Parameters,
        stored: ?*const StoredResults,
        local: *const storage.LocalFileSource,
        watch: *ReadWatch,
        hashed: *?content_hash.Digest,
    ) !Analysis {
        const initial_identity = watch.readable().identity();
        var decoder = self.codecs.openDetected(self.allocator, watch.readable()) catch |err|
            return watch.decoderFailed(err);
        defer decoder.deinit();
        decoder.requireSupportedChannels() catch |err| return watch.decoderFailed(err);
        const source_identity = try self.hashSource(local);
        hashed.* = source_identity;
        const diagnostics_key = diagnosticsKey(file_id orelse 0, source_identity, parameters);
        const fingerprint_key = fingerprintKey(file_id orelse 0, source_identity);
        const chromaprint_key = chromaprint.cacheKey(file_id orelse 0, source_identity, .{});
        const features_key = featuresKey(file_id orelse 0, source_identity);
        const cache = if (file_id == null) null else self.cache;

        var from_cache: StoredResults = .{ .source_identity = source_identity };
        defer self.freeStored(from_cache);
        if (cache) |value| {
            from_cache.diagnostics = try value.get(self.allocator, diagnostics_key);
            from_cache.fingerprint = try value.get(self.allocator, fingerprint_key);
            from_cache.chromaprint = try value.get(self.allocator, chromaprint_key);
            from_cache.features = try value.get(self.allocator, features_key);
        }
        var reused: Reused = .{};
        errdefer reused.deinit();
        if (if (cache == null) stored else &from_cache) |results| {
            if (std.mem.eql(u8, &results.source_identity, &source_identity))
                reused = self.decodeStored(results);
        }
        if (reused.complete()) {
            if (self.cancelled()) return error.Cancelled;
            try self.verifyIdentity(path, initial_identity);
            return .{
                .diagnostics = reused.diagnostics.?,
                .fingerprint = reused.fingerprint.?,
                .chromaprint = reused.chromaprint,
                .features = reused.features,
                .measured = .{},
                .cache_hit = true,
                .decoded_frames = null,
                .source_identity = source_identity,
                .storage_identity = initial_identity,
                .channels = decoder.format.channels,
            };
        }

        const measured: Analysis.Measured = .{
            .diagnostics = reused.diagnostics == null,
            .fingerprint = reused.fingerprint == null,
            .chromaprint = reused.chromaprint == null,
            .features = reused.features == null,
        };
        var analyzer: ?diagnostics.Analyzer = if (measured.diagnostics) try diagnostics.Analyzer.init(
            self.allocator,
            decoder.format.sample_rate,
            decoder.format.channels,
            decoder.frame_count,
            parameters,
        ) else null;
        defer if (analyzer) |*value| value.deinit();
        const integer_source = decoder.hasIntegerSamples();
        var fingerprinter: ?fingerprint.Analyzer = if (measured.fingerprint) try fingerprint.Analyzer.init(
            self.allocator,
            decoder.format.sample_rate,
            decoder.format.channels,
            if (integer_source) .lossless_integer else .decoded_float,
        ) else null;
        defer if (fingerprinter) |*value| value.deinit();
        // Neither analyzer reads the source, so none of their errors is a
        // decode error: each costs its own result, never the file.
        var acoustid: ?chromaprint.Analyzer = if (!measured.chromaprint) null else chromaprint.Analyzer.init(
            self.allocator,
            decoder.format.sample_rate,
            decoder.format.channels,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        defer if (acoustid) |*value| value.deinit();
        var features: ?audio_features.Analyzer = if (!measured.features) null else audio_features.Analyzer.init(
            self.allocator,
            decoder.format.sample_rate,
            decoder.format.channels,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        defer if (features) |*value| value.deinit();
        const chunk_samples = 4096 * @as(usize, decoder.format.channels);
        const samples = try self.allocator.alloc(f32, chunk_samples);
        defer self.allocator.free(samples);
        const integers = try self.allocator.alloc(i32, if (integer_source) chunk_samples else 0);
        defer self.allocator.free(integers);
        var completed_frames: u64 = 0;
        while (true) {
            if (self.cancelled()) return error.Cancelled;
            const frames = (if (integer_source)
                decoder.readFramesI32(integers)
            else
                decoder.readFrames(samples)) catch |err| return watch.decoderFailed(err);
            if (frames == 0) break;
            const chunk = samples[0 .. frames * decoder.format.channels];
            if (integer_source) {
                const integer_chunk = integers[0..chunk.len];
                for (chunk, integer_chunk) |*sample, integer|
                    sample.* = codec.decoder.integerSampleToFloat(integer);
                if (fingerprinter) |*value| try value.processIntegers(integer_chunk);
            } else {
                if (fingerprinter) |*value| try value.process(chunk);
            }
            if (analyzer) |*value| try value.process(chunk);
            if (acoustid) |*value| value.process(chunk) catch {
                value.deinit();
                acoustid = null;
            };
            if (features) |*value| value.process(chunk) catch {
                value.deinit();
                features = null;
            };
            completed_frames += frames;
            if (self.progress) |callback| callback.update(callback.context, .{
                .completed_frames = completed_frames,
                .total_frames = decoder.frame_count,
            });
            if (self.yield_between_chunks) std.Thread.yield() catch {};
        }
        if (self.cancelled()) return error.Cancelled;
        if (decoder.damage()) |damage| return watch.decoderFailed(damage);
        if (analyzer) |*value| reused.diagnostics = try value.finish();
        if (fingerprinter) |*value| reused.fingerprint = try value.finish();
        if (acoustid) |*value| reused.chromaprint = value.finish(completed_frames, decoder.frame_count) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        if (features) |*value| reused.features = value.finish() catch null;

        try self.verifyIdentity(path, initial_identity);
        if (cache) |value| {
            if (measured.diagnostics) {
                const bytes = try encoding.encode(self.allocator, reused.diagnostics.?);
                defer self.allocator.free(bytes);
                try value.put(diagnostics_key, bytes);
            }
            if (measured.fingerprint) {
                const bytes = try fingerprint.encode(self.allocator, reused.fingerprint.?);
                defer self.allocator.free(bytes);
                try value.put(fingerprint_key, bytes);
            }
            if (measured.chromaprint) if (reused.chromaprint) |result| {
                const bytes = try result.encode(self.allocator);
                defer self.allocator.free(bytes);
                try value.put(chromaprint_key, bytes);
            };
            if (measured.features) if (reused.features) |result| try value.put(features_key, &result.encode());
        }
        return .{
            .diagnostics = reused.diagnostics.?,
            .fingerprint = reused.fingerprint.?,
            .chromaprint = reused.chromaprint,
            .features = reused.features,
            .measured = measured,
            .cache_hit = false,
            .decoded_frames = completed_frames,
            .source_identity = source_identity,
            .storage_identity = initial_identity,
            .channels = decoder.format.channels,
        };
    }

    pub fn cancelled(self: Service) bool {
        return if (self.cancellation) |token| token.checkpoint() else false;
    }

    fn verifyIdentity(self: Service, path: []const u8, expected: storage.StorageIdentity) !void {
        var identity_check = try storage.LocalFileSource.open(self.io, path);
        defer identity_check.close();
        if (!sameIdentity(expected, identity_check.readable().identity()))
            return error.SourceChangedDuringAnalysis;
    }

    fn freeStored(self: Service, results: StoredResults) void {
        inline for (.{ results.diagnostics, results.fingerprint, results.chromaprint, results.features }) |bytes| {
            if (bytes) |value| self.allocator.free(value);
        }
    }

    fn decodeStored(self: Service, results: *const StoredResults) Reused {
        var reused: Reused = .{};
        if (results.diagnostics) |bytes| reused.diagnostics = encoding.decode(self.allocator, bytes) catch null;
        if (results.fingerprint) |bytes| reused.fingerprint = fingerprint.decode(self.allocator, bytes) catch null;
        if (results.chromaprint) |bytes| reused.chromaprint = chromaprint.Fingerprint.decode(self.allocator, bytes) catch null;
        if (results.features) |bytes| reused.features = audio_features.Features.decode(bytes) catch null;
        return reused;
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

test "the library keeps the audio features a default analysis stores, under the hash its triggers recognise" {
    const allocator = std.testing.allocator;
    var library = try database.LibraryDatabase.open(
        allocator,
        std.testing.io,
        "file:orca-analysis-features?mode=memory&cache=shared",
    );
    defer library.close();
    const binding = try library.resolveOrCreateFile(
        std.testing.io,
        "fixtures/audio/generated-reference.flac",
        .{ .stable_key = "test:features" },
    );
    const features: audio_features.Features = .{
        .analysed_ms = 30_000,
        .tempo = .{ .bpm = 121.5, .confidence = 0.5 },
        .key = .{ .pitch = 4, .mode = .major, .confidence = 0.25 },
        .onset_rate = 1.5,
        .centroid_hz = 900.25,
    };
    try library.analysis_cache.put(featuresKey(binding.file_id, @splat(0x11)), &features.encode());

    var statement = try library.database.prepare(
        "SELECT tempo_bpm, key_pitch, key_mode, onset_rate, centroid_hz FROM file_audio_features WHERE file_id = ?1;",
    );
    defer statement.deinit();
    try statement.bindInt64(1, binding.file_id);
    try std.testing.expectEqual(database.sqlite.Step.row, try statement.step());
    try std.testing.expectEqual(@as(f64, 121.5), statement.columnDouble(0));
    try std.testing.expectEqual(@as(i64, 4), statement.columnInt64(1));
    try std.testing.expectEqual(@as(i64, 0), statement.columnInt64(2));
    try std.testing.expectEqual(@as(f64, 1.5), statement.columnDouble(3));
    try std.testing.expectEqual(@as(f64, 900.25), statement.columnDouble(4));
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

test "stored results for the same bytes are reused and only the missing ones are measured" {
    const allocator = std.testing.allocator;
    const path = "fixtures/audio/fingerprint-reference.mp3";
    const codecs = codec.CodecRegistry.builtins();
    const service: Service = .{ .allocator = allocator, .io = std.testing.io, .codecs = &codecs };
    const full = (try service.examineFile(null, path, .{}, null)).analyzed;
    defer full.deinit();
    try std.testing.expectEqual(Analysis.Measured{
        .diagnostics = true,
        .fingerprint = true,
        .chromaprint = true,
        .features = true,
    }, full.measured);

    const diagnostics_bytes = try encoding.encode(allocator, full.diagnostics);
    defer allocator.free(diagnostics_bytes);
    const fingerprint_bytes = try fingerprint.encode(allocator, full.fingerprint);
    defer allocator.free(fingerprint_bytes);
    const chromaprint_bytes = try full.chromaprint.?.encode(allocator);
    defer allocator.free(chromaprint_bytes);
    const features_bytes = full.features.?.encode();
    var stored: StoredResults = .{
        .source_identity = full.source_identity,
        .diagnostics = diagnostics_bytes,
        .fingerprint = fingerprint_bytes,
        .chromaprint = chromaprint_bytes,
    };

    const partial = (try service.examineFile(null, path, .{}, &stored)).analyzed;
    defer partial.deinit();
    try std.testing.expectEqual(Analysis.Measured{ .features = true }, partial.measured);
    try std.testing.expect(!partial.cache_hit);
    try std.testing.expectEqual(full.decoded_frames, partial.decoded_frames);
    try std.testing.expectEqual(full.diagnostics.integrated_lufs, partial.diagnostics.integrated_lufs);
    try std.testing.expect(full.fingerprint.audio_hash.eql(partial.fingerprint.audio_hash));
    try std.testing.expectEqualStrings(full.chromaprint.?.encoded, partial.chromaprint.?.encoded);
    try std.testing.expectEqual(features_bytes, partial.features.?.encode());

    stored.features = &features_bytes;
    const complete = (try service.examineFile(null, path, .{}, &stored)).analyzed;
    defer complete.deinit();
    try std.testing.expectEqual(Analysis.Measured{}, complete.measured);
    try std.testing.expect(complete.cache_hit);
    try std.testing.expectEqual(@as(?u64, null), complete.decoded_frames);

    stored.source_identity = @splat(0x5a);
    const other_bytes = (try service.examineFile(null, path, .{}, &stored)).analyzed;
    defer other_bytes.deinit();
    try std.testing.expectEqual(full.measured, other_bytes.measured);
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

test "examining bytes the decoders refuse is a verdict on them, and a failed read is an error" {
    const allocator = std.testing.allocator;
    var files = TestFiles.init();
    defer files.deinit();
    try files.directory.dir.writeFile(std.testing.io, .{ .sub_path = "song.wv", .data = "wvpk\x18\x00\x00\x00\x10\x04\x00\x00" });
    try files.directory.dir.writeFile(std.testing.io, .{ .sub_path = "broken.flac", .data = "fLaC but not a stream at all" });
    try files.directory.dir.createDir(std.testing.io, "folder.flac", .default_dir);
    const codecs = codec.CodecRegistry.builtins();
    const service: Service = .{ .allocator = allocator, .io = std.testing.io, .codecs = &codecs };

    const wavpack_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/song.wv", .{files.directory.sub_path});
    defer allocator.free(wavpack_path);
    const wavpack = try service.examineFile(null, wavpack_path, .{}, null);
    try std.testing.expectEqual(error.CodecUnavailable, wavpack.undecodable.reason);
    try std.testing.expectEqual(try content_hash.fromPath(std.testing.io, wavpack_path), wavpack.undecodable.source_identity);

    const broken_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/broken.flac", .{files.directory.sub_path});
    defer allocator.free(broken_path);
    const broken = try service.examineFile(null, broken_path, .{}, null);
    try std.testing.expect(broken.undecodable.reason != error.CodecUnavailable);
    try std.testing.expect(broken.undecodable.reason != error.UnsupportedAudioFormat);

    const folder_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/folder.flac", .{files.directory.sub_path});
    defer allocator.free(folder_path);
    try std.testing.expectError(error.IsDir, service.examineFile(null, folder_path, .{}, null));
}

test "the decoder set's hash changes when a decoder is registered for another format" {
    const without: codec.CodecRegistry = .{};
    const builtins = codec.CodecRegistry.builtins();
    var with_wavpack = builtins;
    try with_wavpack.register(.{ .name = "WavPack", .format = .wavpack, .open = builtins.entries[0].open });
    try std.testing.expect(!std.mem.eql(u8, &decoderSetHash(&without), &decoderSetHash(&builtins)));
    try std.testing.expect(!std.mem.eql(u8, &decoderSetHash(&builtins), &decoderSetHash(&with_wavpack)));
    try std.testing.expectEqual(decoderSetHash(&builtins), decoderSetHash(&codec.CodecRegistry.builtins()));
}
