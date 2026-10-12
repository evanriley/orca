const std = @import("std");
const sqlite = @import("../sqlite.zig");
const optionalInt64 = @import("../columns.zig").optionalInt64;

pub const Model = @import("../../analysis/audio_embedding.zig").ModelId;
pub const max_page_rows = 4096;

pub fn Vector(comptime model: Model) type {
    return [model.spec().embedding_size]i8;
}

pub fn AudioEmbeddingRow(comptime model: Model) type {
    return struct {
        file_id: i64,
        recording_id: ?i64,
        vector: Vector(model),
    };
}

pub const AudioEmbeddingRepository = struct {
    db: sqlite.Database,

    pub fn fileEmbedding(self: *const AudioEmbeddingRepository, comptime model: Model, file_id: i64) !?Vector(model) {
        var statement = try self.db.prepare(file_embedding_sql);
        defer statement.deinit();
        try statement.bindInt64(1, @backingInt(model));
        try statement.bindInt64(2, file_id);
        if (try statement.step() != .row) return null;
        return try readVector(model, statement, 0);
    }

    pub fn embeddingsAfter(
        self: *const AudioEmbeddingRepository,
        comptime model: Model,
        after_file_id: i64,
        out: []AudioEmbeddingRow(model),
    ) !usize {
        if (out.len == 0) return 0;
        var statement = try self.db.prepare(embeddings_after_sql);
        defer statement.deinit();
        try statement.bindInt64(1, @backingInt(model));
        try statement.bindInt64(2, after_file_id);
        try statement.bindInt64(3, @intCast(out.len));
        var filled: usize = 0;
        while (filled < out.len and try statement.step() == .row) : (filled += 1) {
            out[filled] = .{
                .file_id = statement.columnInt64(0),
                .recording_id = optionalInt64(statement, 1),
                .vector = try readVector(model, statement, 2),
            };
        }
        return filled;
    }
};

fn readVector(comptime model: Model, statement: sqlite.Statement, column: c_int) error{InvalidStoredEmbedding}!Vector(model) {
    const bytes = statement.columnBlob(column);
    if (bytes.len != @sizeOf(Vector(model))) return error.InvalidStoredEmbedding;
    return @bitCast(bytes[0..@sizeOf(Vector(model))].*);
}

const file_embedding_sql =
    "SELECT embeddings.vector FROM file_audio_embeddings AS embeddings\n" ++
    "JOIN files ON files.id = embeddings.file_id\n" ++
    "    AND files.content_hash_algorithm = 1 AND files.content_hash = embeddings.source_identity\n" ++
    "WHERE embeddings.model = ?1 AND embeddings.file_id = ?2;";

const embeddings_after_sql =
    "SELECT embeddings.file_id, files.recording_id, embeddings.vector FROM file_audio_embeddings AS embeddings\n" ++
    "JOIN files ON files.id = embeddings.file_id\n" ++
    "    AND files.content_hash_algorithm = 1 AND files.content_hash = embeddings.source_identity\n" ++
    "WHERE embeddings.model = ?1 AND embeddings.file_id > ?2\n" ++
    "ORDER BY embeddings.file_id\n" ++
    "LIMIT ?3;";

fn openTestLibrary(comptime name: []const u8) !@import("../library.zig").LibraryDatabase {
    return @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-audio-embeddings-" ++ name ++ "?mode=memory&cache=shared",
    );
}

fn expectedVector(comptime model: Model, seed: u8) Vector(model) {
    var vector: Vector(model) = undefined;
    for (&vector, 0..) |*value, index| value.* = @bitCast(@as(u8, @truncate(index *% 3 +% seed)));
    return vector;
}

fn insertEmbedding(
    library: *@import("../library.zig").LibraryDatabase,
    comptime model: Model,
    file_id: i64,
    seed: u8,
    identity: u8,
) !void {
    var statement = try library.database.prepare(
        "INSERT INTO file_audio_embeddings(model, file_id, source_identity, vector) VALUES (?1, ?2, ?3, ?4);",
    );
    defer statement.deinit();
    const vector = expectedVector(model, seed);
    try statement.bindInt64(1, @backingInt(model));
    try statement.bindInt64(2, file_id);
    try statement.bindBlob(3, &.{identity});
    try statement.bindBlob(4, std.mem.asBytes(&vector));
    try std.testing.expectEqual(sqlite.Step.done, try statement.step());
}

const clap: Model = .clap_htsat_unfused;
const maest: Model = .discogs_maest;

test "a file reads the embedding of the bytes it holds now" {
    var library = try openTestLibrary("file");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'r'), (2, 'r'), (3, 'r'), (4, 'r');
        \\INSERT INTO files(id, recording_id, size_bytes, quick_hash, content_hash, content_hash_algorithm) VALUES
        \\    (1, 1, 1, x'01', x'01', 1), (2, 2, 1, x'02', x'ff', 1), (3, 3, 1, x'03', x'03', 2), (4, 4, 1, x'04', NULL, NULL);
    );
    try insertEmbedding(&library, clap, 1, 7, 0x01);
    try insertEmbedding(&library, clap, 2, 8, 0x02);
    try insertEmbedding(&library, clap, 3, 9, 0x03);
    try insertEmbedding(&library, clap, 4, 10, 0x04);

    try std.testing.expectEqual(@as(?Vector(clap), expectedVector(clap, 7)), try library.audio_embeddings.fileEmbedding(clap, 1));
    try std.testing.expectEqual(@as(?Vector(clap), null), try library.audio_embeddings.fileEmbedding(clap, 2));
    try std.testing.expectEqual(@as(?Vector(clap), null), try library.audio_embeddings.fileEmbedding(clap, 3));
    try std.testing.expectEqual(@as(?Vector(clap), null), try library.audio_embeddings.fileEmbedding(clap, 4));
    try std.testing.expectEqual(@as(?Vector(clap), null), try library.audio_embeddings.fileEmbedding(clap, 99));
}

test "embeddings page in file order across more rows than one buffer and skip changed files" {
    var library = try openTestLibrary("page");
    defer library.close();
    try library.database.exec(
        \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 10)
        \\INSERT INTO files(id, size_bytes, quick_hash, content_hash, content_hash_algorithm)
        \\SELECT i * 2, 1, x'01', x'01', 1 FROM n;
    );
    var id: i64 = 2;
    while (id <= 20) : (id += 2) try insertEmbedding(&library, clap, id, @intCast(id), 0x01);
    try library.database.exec("UPDATE files SET content_hash = x'aa' WHERE id = 8;");

    var buffer: [4]AudioEmbeddingRow(clap) = undefined;
    var seen: std.ArrayList(i64) = .empty;
    defer seen.deinit(std.testing.allocator);
    var after: i64 = 0;
    while (true) {
        const filled = try library.audio_embeddings.embeddingsAfter(clap, after, &buffer);
        for (buffer[0..filled]) |row| {
            try seen.append(std.testing.allocator, row.file_id);
            try std.testing.expectEqual(expectedVector(clap, @intCast(row.file_id)), row.vector);
        }
        if (filled < buffer.len) break;
        after = buffer[filled - 1].file_id;
    }
    try std.testing.expectEqualSlices(i64, &.{ 2, 4, 6, 10, 12, 14, 16, 18, 20 }, seen.items);
    try std.testing.expectEqual(@as(usize, 0), try library.audio_embeddings.embeddingsAfter(clap, 20, &buffer));
    try std.testing.expectEqual(@as(usize, 0), try library.audio_embeddings.embeddingsAfter(clap, 0, buffer[0..0]));
}

test "fileEmbedding_andEmbeddingsAfter_filesHoldingBothModels_returnOnlyTheAskedModel" {
    var library = try openTestLibrary("models");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO files(id, size_bytes, quick_hash, content_hash, content_hash_algorithm) VALUES
        \\    (1, 1, x'01', x'01', 1), (2, 1, x'02', x'01', 1), (3, 1, x'03', x'01', 1), (4, 1, x'04', x'01', 1);
    );
    try insertEmbedding(&library, clap, 1, 11, 0x01);
    try insertEmbedding(&library, maest, 1, 21, 0x01);
    try insertEmbedding(&library, maest, 2, 22, 0x01);
    try insertEmbedding(&library, clap, 3, 13, 0x01);
    try insertEmbedding(&library, clap, 4, 14, 0x01);
    try insertEmbedding(&library, maest, 4, 24, 0x01);

    try std.testing.expectEqual(@as(?Vector(clap), expectedVector(clap, 11)), try library.audio_embeddings.fileEmbedding(clap, 1));
    try std.testing.expectEqual(@as(?Vector(maest), expectedVector(maest, 21)), try library.audio_embeddings.fileEmbedding(maest, 1));
    try std.testing.expectEqual(@as(?Vector(clap), null), try library.audio_embeddings.fileEmbedding(clap, 2));
    try std.testing.expectEqual(@as(?Vector(maest), null), try library.audio_embeddings.fileEmbedding(maest, 3));

    var clap_rows: [8]AudioEmbeddingRow(clap) = undefined;
    try std.testing.expectEqual(@as(usize, 3), try library.audio_embeddings.embeddingsAfter(clap, 0, &clap_rows));
    for (clap_rows[0..3], [_]i64{ 1, 3, 4 }) |row, file_id| {
        try std.testing.expectEqual(file_id, row.file_id);
        try std.testing.expectEqual(expectedVector(clap, @intCast(10 + file_id)), row.vector);
    }
    var maest_rows: [8]AudioEmbeddingRow(maest) = undefined;
    try std.testing.expectEqual(@as(usize, 3), try library.audio_embeddings.embeddingsAfter(maest, 0, &maest_rows));
    for (maest_rows[0..3], [_]i64{ 1, 2, 4 }) |row, file_id| {
        try std.testing.expectEqual(file_id, row.file_id);
        try std.testing.expectEqual(expectedVector(maest, @intCast(20 + file_id)), row.vector);
    }
    try std.testing.expectEqual(@as(usize, 1), try library.audio_embeddings.embeddingsAfter(maest, 2, &maest_rows));
}

test "embeddings page by the model and file id key and look each file up by key, with no sort" {
    var library = try openTestLibrary("plan");
    defer library.close();
    var statement = try library.database.prepare("EXPLAIN QUERY PLAN " ++ embeddings_after_sql);
    defer statement.deinit();
    var plan: std.ArrayList(u8) = .empty;
    defer plan.deinit(std.testing.allocator);
    while (try statement.step() == .row) {
        try plan.appendSlice(std.testing.allocator, statement.columnText(3));
        try plan.append(std.testing.allocator, '\n');
    }
    try std.testing.expectEqualStrings(
        "SEARCH embeddings USING PRIMARY KEY (model=? AND file_id>?)\n" ++
            "SEARCH files USING INTEGER PRIMARY KEY (rowid=?)\n",
        plan.items,
    );
}
