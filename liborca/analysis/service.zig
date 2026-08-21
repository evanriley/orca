const std = @import("std");
const codec = @import("../codec/root.zig");
const database = @import("../database/root.zig");
const scanner = @import("../library/scanner.zig");
const storage = @import("../storage/root.zig");
const diagnostics = @import("diagnostics.zig");
const encoding = @import("encoding.zig");

const cache_kind: u8 = 1;
const algorithm_id = "orca.audio-diagnostics";
const algorithm_version: u32 = 1;

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
    cache_hit: bool,

    pub fn deinit(self: Analysis) void {
        self.diagnostics.deinit();
    }
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    codecs: *const codec.CodecRegistry,
    cache: ?*database.AnalysisCacheRepository = null,
    cancellation: ?*const scanner.CancellationToken = null,
    progress: ?ProgressCallback = null,

    pub fn analyzeFile(self: Service, path: []const u8, parameters: diagnostics.Parameters) !Analysis {
        if (self.cancelled()) return error.Cancelled;
        var local = try storage.LocalFileSource.open(self.io, path);
        defer local.close();
        const initial_identity = local.readable().identity();
        const modified_ns = std.math.cast(i64, initial_identity.modified_ns) orelse
            return error.SourceTimestampOutOfRange;
        const key: database.AnalysisCacheKey = .{
            .path = path,
            .kind = cache_kind,
            .algorithm_id = algorithm_id,
            .algorithm_version = algorithm_version,
            .parameter_hash = encoding.parameterHash(parameters),
            .source_size = initial_identity.size,
            .source_modified_ns = modified_ns,
        };
        if (self.cache) |cache| {
            if (try cache.get(self.allocator, key)) |cached| {
                defer self.allocator.free(cached);
                if (encoding.decode(self.allocator, cached)) |result| {
                    errdefer result.deinit();
                    if (self.cancelled()) return error.Cancelled;
                    try self.verifyIdentity(path, initial_identity);
                    return .{ .diagnostics = result, .cache_hit = true };
                } else |_| {}
            }
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
        const samples = try self.allocator.alloc(f32, 4096 * @as(usize, decoder.format.channels));
        defer self.allocator.free(samples);
        var completed_frames: u64 = 0;
        while (true) {
            if (self.cancelled()) return error.Cancelled;
            const frames = try decoder.readFrames(samples);
            if (frames == 0) break;
            try analyzer.process(samples[0 .. frames * decoder.format.channels]);
            completed_frames += frames;
            if (self.progress) |callback| callback.update(callback.context, .{
                .completed_frames = completed_frames,
                .total_frames = decoder.frame_count,
            });
        }
        if (self.cancelled()) return error.Cancelled;
        const result = try analyzer.finish();
        errdefer result.deinit();

        try self.verifyIdentity(path, initial_identity);
        if (self.cache) |cache| {
            const bytes = try encoding.encode(self.allocator, result);
            defer self.allocator.free(bytes);
            try cache.put(key, bytes);
        }
        return .{ .diagnostics = result, .cache_hit = false };
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
    var first = try service.analyzeFile("fixtures/audio/generated-reference.flac", .{
        .waveform_buckets = 16,
    });
    defer first.deinit();
    try std.testing.expect(!first.cache_hit);
    var second = try service.analyzeFile("fixtures/audio/generated-reference.flac", .{
        .waveform_buckets = 16,
    });
    defer second.deinit();
    try std.testing.expect(second.cache_hit);
    try std.testing.expectEqual(first.diagnostics.sample_peak, second.diagnostics.sample_peak);

    var cancellation: scanner.CancellationToken = .{};
    cancellation.cancel();
    var cancelled_service = service;
    cancelled_service.cancellation = &cancellation;
    try std.testing.expectError(error.Cancelled, cancelled_service.analyzeFile(
        "fixtures/audio/generated-reference.qoa",
        .{ .waveform_buckets = 16 },
    ));
}
