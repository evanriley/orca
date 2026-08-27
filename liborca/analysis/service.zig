const std = @import("std");
const codec = @import("../codec/root.zig");
const database = @import("../database/root.zig");
const scanner = @import("../library/scanner.zig");
const quick_hash = @import("../storage/quick_hash.zig");
const storage = @import("../storage/root.zig");
const diagnostics = @import("diagnostics.zig");
const encoding = @import("encoding.zig");
const fingerprint = @import("fingerprint.zig");

pub const diagnostics_cache_kind: u8 = 1;
pub const fingerprint_cache_kind: u8 = 2;
pub const diagnostics_algorithm_id = "orca.audio-diagnostics";
pub const diagnostics_algorithm_version: u32 = 1;
pub const fingerprint_algorithm_id = "orca.temporal-fingerprint";
pub const fingerprint_algorithm_version: u32 = 1;

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
    cache_hit: bool,
    /// The identity of the bytes this measurement describes, as the Service
    /// observed them. A caller that stores the result itself keys on this
    /// rather than on what a database row claims, so a measurement can never
    /// be filed under an identity it was not taken from.
    source_identity: quick_hash.Digest,

    pub fn deinit(self: Analysis) void {
        self.diagnostics.deinit();
        self.fingerprint.deinit();
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
        if (if (file_id == null) null else self.cache) |cache| {
            const cached_diagnostics = try self.loadDiagnostics(cache, diagnostics_key);
            const cached_fingerprint = try self.loadFingerprint(cache, fingerprint_key);
            if (cached_diagnostics != null and cached_fingerprint != null) {
                errdefer cached_diagnostics.?.deinit();
                errdefer cached_fingerprint.?.deinit();
                if (self.cancelled()) return error.Cancelled;
                try self.verifyIdentity(path, initial_identity);
                return .{
                    .diagnostics = cached_diagnostics.?,
                    .fingerprint = cached_fingerprint.?,
                    .cache_hit = true,
                    .source_identity = source_identity,
                };
            }
            if (cached_diagnostics) |result| result.deinit();
            if (cached_fingerprint) |result| result.deinit();
        }

        const source_hash = try self.hashSource(local.readable());
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
        var fingerprinter = try fingerprint.Analyzer.init(
            self.allocator,
            decoder.format.sample_rate,
            decoder.format.channels,
        );
        defer fingerprinter.deinit();
        const samples = try self.allocator.alloc(f32, 4096 * @as(usize, decoder.format.channels));
        defer self.allocator.free(samples);
        var completed_frames: u64 = 0;
        while (true) {
            if (self.cancelled()) return error.Cancelled;
            const frames = try decoder.readFrames(samples);
            if (frames == 0) break;
            try analyzer.process(samples[0 .. frames * decoder.format.channels]);
            try fingerprinter.process(samples[0 .. frames * decoder.format.channels]);
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
        var fingerprint_result = try fingerprinter.finish();
        errdefer fingerprint_result.deinit();
        fingerprint_result.source_hash = source_hash;

        try self.verifyIdentity(path, initial_identity);
        if (if (file_id == null) null else self.cache) |cache| {
            const bytes = try encoding.encode(self.allocator, result);
            defer self.allocator.free(bytes);
            try cache.put(diagnostics_key, bytes);
            const fingerprint_bytes = try fingerprint.encode(self.allocator, fingerprint_result);
            defer self.allocator.free(fingerprint_bytes);
            try cache.put(fingerprint_key, fingerprint_bytes);
        }
        return .{
            .diagnostics = result,
            .fingerprint = fingerprint_result,
            .cache_hit = false,
            .source_identity = source_identity,
        };
    }

    fn cancelled(self: Service) bool {
        return if (self.cancellation) |token| token.isCancelled() else false;
    }

    fn verifyIdentity(self: Service, path: []const u8, expected: storage.StorageIdentity) !void {
        var identity_check = try storage.LocalFileSource.open(self.io, path);
        defer identity_check.close();
        if (!sameIdentity(expected, identity_check.readable().identity()))
            return error.SourceChangedDuringAnalysis;
    }

    fn hashSource(self: Service, source: storage.ReadableSource) ![32]u8 {
        var hasher = std.crypto.hash.Blake3.init(.{});
        var buffer: [64 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (offset < source.size()) {
            if (self.cancelled()) return error.Cancelled;
            const read = try source.readAt(offset, &buffer);
            if (read == 0) return error.UnexpectedEndOfSource;
            hasher.update(buffer[0..read]);
            offset += read;
            if (self.yield_between_chunks) std.Thread.yield() catch {};
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        return digest;
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
    try std.testing.expectEqual(first.fingerprint.source_hash.?, second.fingerprint.source_hash.?);

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
