const std = @import("std");
const database = @import("../database/root.zig");
const sqlite = database.sqlite;
const track_play_file = @import("../database/repository/tracks.zig").track_play_file;
const optionalInt64 = @import("../database/columns.zig").optionalInt64;

const audio_embeddings = @import("../database/repository/audio_embeddings.zig");
const AudioEmbeddingRepository = audio_embeddings.AudioEmbeddingRepository;
const AudioEmbeddingRow = audio_embeddings.AudioEmbeddingRow;
const Vector = audio_embeddings.Vector;

pub const Model = audio_embeddings.Model;
pub const max_neighbours = 1000;

pub const max_embedding_size = @import("../analysis/audio_embedding.zig").max_embedding_size;
const max_page_rows = audio_embeddings.max_page_rows;
const dot_lanes = 16;

comptime {
    for (std.enums.values(Model)) |model| std.debug.assert(embeddingSize(model) % dot_lanes == 0);
}

fn embeddingSize(comptime model: Model) usize {
    return @sizeOf(Vector(model));
}

pub const Neighbour = struct {
    recording_id: i64,
    file_id: i64,
    similarity: f32,
};

pub const RecordingSimilarities = std.AutoHashMapUnmanaged(i64, f32);

pub const Query = struct {
    model: Model,
    values: [max_embedding_size]f32,

    pub fn ofUnit(model: Model, unit_vector: []const f32) Query {
        std.debug.assert(unit_vector.len == model.spec().embedding_size);
        var values: [max_embedding_size]f32 = @splat(0);
        @memcpy(values[0..unit_vector.len], unit_vector);
        return .{ .model = model, .values = values };
    }

    pub fn ofStored(comptime model: Model, vector: *const Vector(model)) ?Query {
        const unit_vector = unitVector(embeddingSize(model), vector) orelse return null;
        return .ofUnit(model, &unit_vector);
    }

    pub fn ofFile(embeddings: *const AudioEmbeddingRepository, model: Model, file_id: i64) !?Query {
        switch (model) {
            inline else => |stored_model| {
                const stored = try embeddings.fileEmbedding(stored_model, file_id) orelse return null;
                return ofStored(stored_model, &stored);
            },
        }
    }

    pub fn unit(self: *const Query) []const f32 {
        return self.values[0..self.model.spec().embedding_size];
    }
};

pub fn nearestRecordings(
    allocator: std.mem.Allocator,
    embeddings: *const AudioEmbeddingRepository,
    query: *const Query,
    excluded_recordings: []const i64,
    out: []Neighbour,
) !usize {
    if (out.len == 0) return 0;
    return search(allocator, embeddings, query, excluded_recordings, out, null);
}

pub fn nearestRecordingsWithSimilarities(
    allocator: std.mem.Allocator,
    embeddings: *const AudioEmbeddingRepository,
    query: *const Query,
    out: []Neighbour,
    similarities: *RecordingSimilarities,
) !usize {
    return search(allocator, embeddings, query, &.{}, out, similarities);
}

fn search(
    allocator: std.mem.Allocator,
    embeddings: *const AudioEmbeddingRepository,
    query: *const Query,
    excluded_recordings: []const i64,
    out: []Neighbour,
    similarities: ?*RecordingSimilarities,
) !usize {
    if (out.len > max_neighbours) return error.SimilarLimitTooLarge;
    switch (query.model) {
        inline else => |model| return searchModel(
            model,
            allocator,
            embeddings,
            query.values[0..comptime embeddingSize(model)],
            excluded_recordings,
            out,
            similarities,
        ),
    }
}

fn searchModel(
    comptime model: Model,
    allocator: std.mem.Allocator,
    embeddings: *const AudioEmbeddingRepository,
    query: *const [embeddingSize(model)]f32,
    excluded_recordings: []const i64,
    out: []Neighbour,
    similarities: ?*RecordingSimilarities,
) !usize {
    const page = try allocator.alloc(AudioEmbeddingRow(model), max_page_rows);
    defer allocator.free(page);
    var found: usize = 0;
    var after_file_id: i64 = std.math.minInt(i64);
    while (true) {
        const filled = try embeddings.embeddingsAfter(model, after_file_id, page);
        for (page[0..filled]) |*row| {
            const candidate: Neighbour = .{
                .recording_id = row.recording_id orelse continue,
                .file_id = row.file_id,
                .similarity = cosine(embeddingSize(model), query, &row.vector) orelse continue,
            };
            if (similarities) |nearest_of| {
                const entry = try nearest_of.getOrPut(allocator, candidate.recording_id);
                if (!entry.found_existing or candidate.similarity > entry.value_ptr.*) entry.value_ptr.* = candidate.similarity;
            }
            if (out.len > 0) found = offer(out, found, candidate, excluded_recordings);
        }
        if (filled < page.len) return found;
        after_file_id = page[filled - 1].file_id;
    }
}

fn unitVector(comptime size: usize, vector: *const [size]i8) ?[size]f32 {
    const length = storedLength(size, vector) orelse return null;
    var unit: [size]f32 = undefined;
    for (&unit, vector) |*value, stored| value.* = @as(f32, @floatFromInt(stored)) / length;
    return unit;
}

fn storedLength(comptime size: usize, vector: *const [size]i8) ?f32 {
    const wide: @Vector(size, i32) = @as(@Vector(size, i8), vector.*);
    const squared = @reduce(.Add, wide * wide);
    return if (squared == 0) null else @sqrt(@as(f32, @floatFromInt(squared)));
}

fn cosine(comptime size: usize, query: *const [size]f32, vector: *const [size]i8) ?f32 {
    const length = storedLength(size, vector) orelse return null;
    const Lanes = @Vector(dot_lanes, f32);
    var sums: Lanes = @splat(0);
    var offset: usize = 0;
    while (offset < size) : (offset += dot_lanes) {
        const stored: @Vector(dot_lanes, i8) = vector[offset..][0..dot_lanes].*;
        sums += @as(Lanes, query[offset..][0..dot_lanes].*) * @as(Lanes, @floatFromInt(stored));
    }
    return @reduce(.Add, sums) / length;
}

fn ranksBefore(a: Neighbour, b: Neighbour) bool {
    if (a.similarity != b.similarity) return a.similarity > b.similarity;
    return a.recording_id < b.recording_id;
}

fn offer(out: []Neighbour, found: usize, candidate: Neighbour, excluded_recordings: []const i64) usize {
    if (found == out.len and !ranksBefore(candidate, out[found - 1])) return found;
    if (std.mem.indexOfScalar(i64, excluded_recordings, candidate.recording_id) != null) return found;
    var kept = found;
    for (out[0..found], 0..) |held, index| {
        if (held.recording_id != candidate.recording_id) continue;
        if (!ranksBefore(candidate, held)) return found;
        std.mem.copyForwards(Neighbour, out[index .. found - 1], out[index + 1 .. found]);
        kept -= 1;
        break;
    } else if (kept == out.len) {
        kept -= 1;
    }
    var position = kept;
    while (position > 0 and ranksBefore(candidate, out[position - 1])) : (position -= 1) {
        out[position] = out[position - 1];
    }
    out[position] = candidate;
    return kept + 1;
}

pub const SimilarTrack = struct {
    track_id: i64,
    similarity: f32,
};

pub const SimilarTracks = struct {
    allocator: std.mem.Allocator,
    items: []SimilarTrack,

    pub fn deinit(self: *SimilarTracks) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn similarTracks(
    allocator: std.mem.Allocator,
    connection: sqlite.Database,
    model: Model,
    track_id: i64,
    limit: usize,
) !SimilarTracks {
    if (limit > max_neighbours) return error.SimilarLimitTooLarge;
    const embeddings: AudioEmbeddingRepository = .{ .db = connection };

    var seed = try connection.prepare(seed_sql);
    defer seed.deinit();
    try seed.bindInt64(1, track_id);
    if (try seed.step() != .row) return error.TrackNotFound;
    const seed_recording = optionalInt64(seed, 0);
    const play_file = optionalInt64(seed, 1) orelse return error.NoAudioEmbedding;
    const query = try Query.ofFile(&embeddings, model, play_file) orelse return error.NoAudioEmbedding;

    const neighbours = try allocator.alloc(Neighbour, limit);
    defer allocator.free(neighbours);
    const own_recording: [1]i64 = .{seed_recording orelse 0};
    const excluded = own_recording[0..@intFromBool(seed_recording != null)];
    const found = try nearestRecordings(allocator, &embeddings, &query, excluded, neighbours);

    var tracks: std.ArrayList(SimilarTrack) = try .initCapacity(allocator, found);
    errdefer tracks.deinit(allocator);
    var track_of = try connection.prepare(recording_track_sql);
    defer track_of.deinit();
    for (neighbours[0..found]) |neighbour| {
        try track_of.reset();
        try track_of.bindInt64(1, neighbour.recording_id);
        if (try track_of.step() != .row) continue;
        const similar_track = optionalInt64(track_of, 0) orelse continue;
        tracks.appendAssumeCapacity(.{ .track_id = similar_track, .similarity = neighbour.similarity });
    }
    return .{ .allocator = allocator, .items = try tracks.toOwnedSlice(allocator) };
}

const seed_sql = "SELECT tracks.recording_id, " ++ track_play_file ++ " FROM tracks WHERE tracks.id = ?1;";
const recording_track_sql = "SELECT min(tracks.id) FROM tracks WHERE tracks.recording_id = ?1;";

const testing = std.testing;

fn openTestLibrary(comptime name: []const u8) !database.LibraryDatabase {
    return database.LibraryDatabase.open(
        testing.allocator,
        testing.io,
        "file:orca-test-audio-similarity-" ++ name ++ "?mode=memory&cache=shared",
    );
}

const clap: Model = .clap_htsat_unfused;
const maest: Model = .discogs_maest;

fn planeVectorOf(comptime model: Model, x: i8, y: i8) Vector(model) {
    var vector: Vector(model) = @splat(0);
    vector[0] = x;
    vector[1] = y;
    return vector;
}

fn planeVector(x: i8, y: i8) Vector(clap) {
    return planeVectorOf(clap, x, y);
}

const along_x = Query.ofStored(clap, &planeVector(1, 0)).?;

const TestFile = struct {
    id: i64,
    recording_id: ?i64,
    vector: Vector(clap),
    maest_vector: ?Vector(maest) = null,
    content_hash: u8 = 1,
    embedded_hash: u8 = 1,
};

fn insertFiles(library: *database.LibraryDatabase, files: []const TestFile) !void {
    var recording = try library.database.prepare("INSERT OR IGNORE INTO recordings(id, title) VALUES (?1, 'r');");
    defer recording.deinit();
    var file = try library.database.prepare(
        "INSERT INTO files(id, recording_id, size_bytes, quick_hash, content_hash, content_hash_algorithm) VALUES (?1, ?2, 1, x'01', ?3, 1);",
    );
    defer file.deinit();
    var embedding = try library.database.prepare(
        "INSERT INTO file_audio_embeddings(model, file_id, source_identity, vector) VALUES (?1, ?2, ?3, ?4);",
    );
    defer embedding.deinit();
    try library.database.exec("BEGIN;");
    for (files) |row| {
        if (row.recording_id) |recording_id| {
            try recording.reset();
            try recording.bindInt64(1, recording_id);
            try testing.expectEqual(sqlite.Step.done, try recording.step());
        }
        try file.reset();
        try file.bindInt64(1, row.id);
        try file.bindOptionalInt64(2, row.recording_id);
        try file.bindBlob(3, &.{row.content_hash});
        try testing.expectEqual(sqlite.Step.done, try file.step());
        const vectors = [_]struct { Model, ?[]const u8 }{
            .{ clap, std.mem.asBytes(&row.vector) },
            .{ maest, if (row.maest_vector) |*vector| std.mem.asBytes(vector) else null },
        };
        for (vectors) |stored| {
            try embedding.reset();
            try embedding.bindInt64(1, @backingInt(stored[0]));
            try embedding.bindInt64(2, row.id);
            try embedding.bindBlob(3, &.{row.embedded_hash});
            try embedding.bindBlob(4, stored[1] orelse continue);
            try testing.expectEqual(sqlite.Step.done, try embedding.step());
        }
    }
    try library.database.exec("COMMIT;");
}

fn expectNeighbours(
    library: *database.LibraryDatabase,
    excluded_recordings: []const i64,
    comptime limit: usize,
    expected_recordings: []const i64,
    expected_files: []const i64,
) !void {
    var out: [limit]Neighbour = undefined;
    const found = try nearestRecordings(testing.allocator, &library.audio_embeddings, &along_x, excluded_recordings, &out);
    var recordings: [limit]i64 = undefined;
    var files: [limit]i64 = undefined;
    for (out[0..found], recordings[0..found], files[0..found]) |neighbour, *recording_id, *file_id| {
        recording_id.* = neighbour.recording_id;
        file_id.* = neighbour.file_id;
    }
    try testing.expectEqualSlices(i64, expected_recordings, recordings[0..found]);
    try testing.expectEqualSlices(i64, expected_files, files[0..found]);
    for (out[0..found], 0..) |neighbour, index| {
        if (index > 0) try testing.expect(out[index - 1].similarity >= neighbour.similarity);
    }
}

test "nearestRecordings_differentAndEqualVectors_ordersBySimilarityThenRecordingId" {
    var library = try openTestLibrary("order");
    defer library.close();
    try insertFiles(&library, &.{
        .{ .id = 1, .recording_id = 50, .vector = planeVector(60, 80) },
        .{ .id = 2, .recording_id = 40, .vector = planeVector(100, 0) },
        .{ .id = 3, .recording_id = 30, .vector = planeVector(-100, 0) },
        .{ .id = 4, .recording_id = 20, .vector = planeVector(60, 80) },
        .{ .id = 5, .recording_id = 10, .vector = planeVector(0, 100) },
        .{ .id = 6, .recording_id = 60, .vector = planeVector(30, 40) },
    });

    try expectNeighbours(&library, &.{}, 8, &.{ 40, 20, 50, 60, 10, 30 }, &.{ 2, 4, 1, 6, 5, 3 });

    var out: [8]Neighbour = undefined;
    _ = try nearestRecordings(testing.allocator, &library.audio_embeddings, &along_x, &.{}, &out);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0].similarity, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.6), out[1].similarity, 1e-6);
    try testing.expectEqual(out[1].similarity, out[3].similarity);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[4].similarity, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1.0), out[5].similarity, 1e-6);
}

test "nearestRecordings_smallerBufferEmptyBufferAndOverTheMaximum_returnsTheNearestNoneAndRefuses" {
    var library = try openTestLibrary("limit");
    defer library.close();
    try insertFiles(&library, &.{
        .{ .id = 1, .recording_id = 1, .vector = planeVector(0, 100) },
        .{ .id = 2, .recording_id = 2, .vector = planeVector(60, 80) },
        .{ .id = 3, .recording_id = 3, .vector = planeVector(100, 0) },
        .{ .id = 4, .recording_id = 4, .vector = planeVector(80, 60) },
    });

    try expectNeighbours(&library, &.{}, 2, &.{ 3, 4 }, &.{ 3, 4 });
    try testing.expectEqual(@as(usize, 0), try nearestRecordings(testing.allocator, &library.audio_embeddings, &along_x, &.{}, &.{}));

    const at_maximum = try testing.allocator.alloc(Neighbour, max_neighbours + 1);
    defer testing.allocator.free(at_maximum);
    try testing.expectEqual(@as(usize, 4), try nearestRecordings(testing.allocator, &library.audio_embeddings, &along_x, &.{}, at_maximum[0..max_neighbours]));
    try testing.expectError(error.SimilarLimitTooLarge, nearestRecordings(testing.allocator, &library.audio_embeddings, &along_x, &.{}, at_maximum));
}

test "nearestRecordings_moreVectorsThanOnePage_findsTheNearestOnEveryPage" {
    var library = try openTestLibrary("pages");
    defer library.close();
    const file_count = max_page_rows + 904;
    const files = try testing.allocator.alloc(TestFile, file_count);
    defer testing.allocator.free(files);
    for (files, 1..) |*file, id| file.* = .{
        .id = @intCast(id),
        .recording_id = @intCast(file_count + 1 - id),
        .vector = planeVector(10, 100),
    };
    files[2].vector = planeVector(100, 10);
    files[max_page_rows - 1].vector = planeVector(100, 30);
    files[max_page_rows].vector = planeVector(100, 0);
    files[file_count - 2].vector = planeVector(100, 20);
    try insertFiles(&library, files);

    try expectNeighbours(
        &library,
        &.{},
        6,
        &.{ file_count - max_page_rows, file_count - 2, 2, file_count + 1 - max_page_rows, 1, 3 },
        &.{ max_page_rows + 1, 3, file_count - 1, max_page_rows, file_count, file_count - 2 },
    );
}

test "nearestRecordings_excludedRecordings_fillsTheCountFromTheRest" {
    var library = try openTestLibrary("excluded");
    defer library.close();
    try insertFiles(&library, &.{
        .{ .id = 1, .recording_id = 1, .vector = planeVector(100, 0) },
        .{ .id = 2, .recording_id = 2, .vector = planeVector(80, 60) },
        .{ .id = 3, .recording_id = 3, .vector = planeVector(60, 80) },
        .{ .id = 4, .recording_id = 4, .vector = planeVector(0, 100) },
        .{ .id = 5, .recording_id = 1, .vector = planeVector(90, 10) },
    });

    try expectNeighbours(&library, &.{}, 2, &.{ 1, 2 }, &.{ 1, 2 });
    try expectNeighbours(&library, &.{1}, 2, &.{ 2, 3 }, &.{ 2, 3 });
    try expectNeighbours(&library, &.{ 3, 1 }, 3, &.{ 2, 4 }, &.{ 2, 4 });
}

test "nearestRecordings_severalFilesOfOneRecording_returnsItOnceByItsNearestFile" {
    var library = try openTestLibrary("files");
    defer library.close();
    try insertFiles(&library, &.{
        .{ .id = 1, .recording_id = 7, .vector = planeVector(0, 100) },
        .{ .id = 2, .recording_id = 8, .vector = planeVector(80, 60) },
        .{ .id = 3, .recording_id = 7, .vector = planeVector(100, 0) },
        .{ .id = 4, .recording_id = 7, .vector = planeVector(60, 80) },
        .{ .id = 5, .recording_id = 9, .vector = planeVector(60, 80) },
        .{ .id = 6, .recording_id = 8, .vector = planeVector(80, 60) },
    });

    try expectNeighbours(&library, &.{}, 4, &.{ 7, 8, 9 }, &.{ 3, 2, 5 });
    try expectNeighbours(&library, &.{}, 1, &.{7}, &.{3});
}

test "nearestRecordings_changedFileFileWithoutRecordingAndZeroVector_leavesThemOut" {
    var library = try openTestLibrary("skipped");
    defer library.close();
    try insertFiles(&library, &.{
        .{ .id = 1, .recording_id = 1, .vector = planeVector(100, 0), .content_hash = 2 },
        .{ .id = 2, .recording_id = null, .vector = planeVector(100, 0) },
        .{ .id = 3, .recording_id = 3, .vector = planeVector(0, 0) },
        .{ .id = 4, .recording_id = 4, .vector = planeVector(0, 100) },
    });

    try expectNeighbours(&library, &.{}, 4, &.{4}, &.{4});
    try library.database.exec("UPDATE files SET content_hash = x'01' WHERE id = 1;");
    try expectNeighbours(&library, &.{}, 4, &.{ 1, 4 }, &.{ 1, 4 });
}

test "similarTracks_trackWithAnEmbedding_returnsOneTrackPerOtherRecording" {
    var library = try openTestLibrary("tracks");
    defer library.close();
    try insertFiles(&library, &.{
        .{ .id = 1, .recording_id = 1, .vector = planeVector(100, 0) },
        .{ .id = 2, .recording_id = 2, .vector = planeVector(60, 80) },
        .{ .id = 3, .recording_id = 3, .vector = planeVector(80, 60) },
        .{ .id = 4, .recording_id = 1, .vector = planeVector(99, 1) },
        .{ .id = 5, .recording_id = 5, .vector = planeVector(100, 0), .content_hash = 2 },
    });
    try library.database.exec(
        \\INSERT INTO tracks(id, recording_id, title) VALUES
        \\    (11, 1, 'seed'), (12, 2, 'far'), (13, 3, 'near'), (14, 3, 'near again'), (15, 5, 'changed'), (16, NULL, 'no file');
    );

    var similar = try similarTracks(testing.allocator, library.queryDatabase(), clap, 11, 10);
    defer similar.deinit();
    try testing.expectEqual(@as(usize, 2), similar.items.len);
    try testing.expectEqual(@as(i64, 13), similar.items[0].track_id);
    try testing.expectApproxEqAbs(@as(f32, 0.8), similar.items[0].similarity, 1e-6);
    try testing.expectEqual(@as(i64, 12), similar.items[1].track_id);
    try testing.expectApproxEqAbs(@as(f32, 0.6), similar.items[1].similarity, 1e-6);

    var nearest = try similarTracks(testing.allocator, library.queryDatabase(), clap, 11, 1);
    defer nearest.deinit();
    try testing.expectEqual(@as(usize, 1), nearest.items.len);
    try testing.expectEqual(@as(i64, 13), nearest.items[0].track_id);

    try testing.expectError(error.TrackNotFound, similarTracks(testing.allocator, library.queryDatabase(), clap, 99, 10));
    try testing.expectError(error.NoAudioEmbedding, similarTracks(testing.allocator, library.queryDatabase(), clap, 15, 10));
    try testing.expectError(error.NoAudioEmbedding, similarTracks(testing.allocator, library.queryDatabase(), clap, 16, 10));
    try testing.expectError(error.SimilarLimitTooLarge, similarTracks(testing.allocator, library.queryDatabase(), clap, 11, max_neighbours + 1));
}

fn expectRecordings(library: *database.LibraryDatabase, query: *const Query, expected: []const i64) !void {
    var out: [8]Neighbour = undefined;
    const found = try nearestRecordings(testing.allocator, &library.audio_embeddings, query, &.{}, &out);
    var recordings: [8]i64 = undefined;
    for (out[0..found], recordings[0..found]) |neighbour, *recording_id| recording_id.* = neighbour.recording_id;
    try testing.expectEqualSlices(i64, expected, recordings[0..found]);
}

test "nearestRecordings_filesHoldingVectorsOfBothModels_ranksByTheQueryModelOnly" {
    var library = try openTestLibrary("models");
    defer library.close();
    var beyond_clap = planeVectorOf(maest, 0, 0);
    beyond_clap[embeddingSize(clap)] = 100;
    try insertFiles(&library, &.{
        .{ .id = 1, .recording_id = 1, .vector = planeVector(100, 0), .maest_vector = planeVectorOf(maest, 0, 100) },
        .{ .id = 2, .recording_id = 2, .vector = planeVector(80, 60), .maest_vector = planeVectorOf(maest, 60, 80) },
        .{ .id = 3, .recording_id = 3, .vector = planeVector(0, 100), .maest_vector = planeVectorOf(maest, 100, 0) },
        .{ .id = 4, .recording_id = 4, .vector = planeVector(60, 80) },
        .{ .id = 5, .recording_id = 5, .vector = planeVector(0, 0), .maest_vector = beyond_clap },
    });
    try library.database.exec(
        \\INSERT INTO tracks(id, recording_id, title) VALUES (11, 1, 'one'), (12, 2, 'two'), (13, 3, 'three'), (14, 4, 'four'), (15, 5, 'five');
    );

    try expectRecordings(&library, &along_x, &.{ 1, 2, 4, 3 });
    try expectRecordings(&library, &Query.ofStored(maest, &planeVectorOf(maest, 1, 0)).?, &.{ 3, 2, 1, 5 });
    try expectRecordings(&library, &Query.ofStored(maest, &beyond_clap).?, &.{ 5, 1, 2, 3 });

    try testing.expectEqual(clap, (try Query.ofFile(&library.audio_embeddings, clap, 1)).?.model);
    try testing.expectEqual(@as(usize, 768), (try Query.ofFile(&library.audio_embeddings, maest, 1)).?.unit().len);
    try testing.expectEqual(@as(?Query, null), try Query.ofFile(&library.audio_embeddings, maest, 4));
    try testing.expectEqual(@as(?Query, null), try Query.ofFile(&library.audio_embeddings, clap, 5));

    var by_clap = try similarTracks(testing.allocator, library.queryDatabase(), clap, 11, 10);
    defer by_clap.deinit();
    try testing.expectEqual(@as(usize, 3), by_clap.items.len);
    try testing.expectEqual(@as(i64, 12), by_clap.items[0].track_id);
    try testing.expectEqual(@as(i64, 14), by_clap.items[1].track_id);
    try testing.expectEqual(@as(i64, 13), by_clap.items[2].track_id);

    var by_maest = try similarTracks(testing.allocator, library.queryDatabase(), maest, 11, 10);
    defer by_maest.deinit();
    try testing.expectEqual(@as(usize, 3), by_maest.items.len);
    try testing.expectEqual(@as(i64, 12), by_maest.items[0].track_id);
    try testing.expectApproxEqAbs(@as(f32, 0.8), by_maest.items[0].similarity, 1e-6);
    try testing.expectEqual(@as(i64, 13), by_maest.items[1].track_id);
    try testing.expectEqual(@as(i64, 15), by_maest.items[2].track_id);

    try testing.expectError(error.NoAudioEmbedding, similarTracks(testing.allocator, library.queryDatabase(), maest, 14, 10));
    try testing.expectError(error.NoAudioEmbedding, similarTracks(testing.allocator, library.queryDatabase(), clap, 15, 10));
}
