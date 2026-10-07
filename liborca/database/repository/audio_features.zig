const std = @import("std");
const sqlite = @import("../sqlite.zig");
const track_play_file = @import("tracks.zig").track_play_file;
const measurableChannels = @import("analysis.zig").measurableChannels;

/// What the analysis estimated of the audio a Track plays. Every estimate is
/// approximate; a frontend presents none of them as exact.
pub const AudioFeatures = struct {
    tempo: ?Tempo,
    key: ?Key,
    /// Detected note onsets per second.
    onset_rate: ?f64,
    /// Mean spectral centroid in hertz: the brightness of the sound.
    centroid_hz: ?f64,
    /// 0 to 1: the mean of the file's percentile ranks in this Library by
    /// integrated loudness, onset rate and spectral centroid, over those it
    /// has. It moves as the Library changes.
    energy: ?f64,

    pub const Tempo = struct {
        bpm: f64,
        /// 0 to 1.
        confidence: f64,
    };

    pub const Key = struct {
        /// Pitch class of the tonic, C = 0 through B = 11.
        pitch: u8,
        mode: Mode,
        /// 0 to 1.
        confidence: f64,
    };

    pub const Mode = enum(u8) { major = 0, minor = 1 };
};

pub const AudioFeatureRepository = struct {
    db: sqlite.Database,

    /// The features stored for the bytes the Track's file holds now, or null
    /// when the Track does not exist or those bytes were not measured.
    pub fn trackFeatures(self: *const AudioFeatureRepository, track_id: i64) !?AudioFeatures {
        var statement = try self.db.prepare(track_features_sql);
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return null;
        const tempo: ?AudioFeatures.Tempo = if (statement.columnIsNull(0)) null else .{
            .bpm = statement.columnDouble(0),
            .confidence = statement.columnDouble(1),
        };
        const key: ?AudioFeatures.Key = if (statement.columnIsNull(2)) null else .{
            .pitch = std.math.cast(u8, statement.columnInt64(2)) orelse return error.InvalidStoredFeatures,
            .mode = std.enums.fromInt(AudioFeatures.Mode, statement.columnInt64(3)) orelse
                return error.InvalidStoredFeatures,
            .confidence = statement.columnDouble(4),
        };
        const onset_rate = optionalDouble(statement, 5);
        const centroid_hz = optionalDouble(statement, 6);
        const integrated_lufs = optionalDouble(statement, 7);

        var ranks: [3]f64 = undefined;
        var ranked: usize = 0;
        if (integrated_lufs) |value| if (try self.rank(rank_lufs_sql, value)) |r| {
            ranks[ranked] = r;
            ranked += 1;
        };
        if (onset_rate) |value| if (try self.rank(rank_onset_rate_sql, value)) |r| {
            ranks[ranked] = r;
            ranked += 1;
        };
        if (centroid_hz) |value| if (try self.rank(rank_centroid_sql, value)) |r| {
            ranks[ranked] = r;
            ranked += 1;
        };
        var sum: f64 = 0;
        for (ranks[0..ranked]) |r| sum += r;
        return .{
            .tempo = tempo,
            .key = key,
            .onset_rate = onset_rate,
            .centroid_hz = centroid_hz,
            .energy = if (ranked == 0) null else sum / @as(f64, @floatFromInt(ranked)),
        };
    }

    fn rank(self: *const AudioFeatureRepository, comptime sql: [:0]const u8, value: f64) !?f64 {
        var statement = try self.db.prepare(sql);
        defer statement.deinit();
        try statement.bindDouble(1, value);
        if (try statement.step() != .row) return error.SqlFailed;
        const below: f64 = @floatFromInt(statement.columnInt64(0));
        const equal: f64 = @floatFromInt(statement.columnInt64(1));
        const total: f64 = @floatFromInt(statement.columnInt64(2));
        if (total == 0) return null;
        return std.math.clamp((below + equal / 2) / total, 0, 1);
    }
};

const track_features_sql =
    "SELECT features.tempo_bpm, features.tempo_confidence, features.key_pitch, features.key_mode,\n" ++
    "       features.key_confidence, features.onset_rate, features.centroid_hz,\n" ++
    "       (SELECT file_loudness.integrated_lufs FROM file_loudness\n" ++
    "        WHERE file_loudness.file_id = play_file.id\n" ++
    "          AND file_loudness.source_identity = play_file.content_hash)\n" ++
    "FROM tracks\n" ++
    "JOIN files AS play_file ON play_file.id = " ++ track_play_file ++ "\n" ++
    "JOIN file_audio_features AS features ON features.file_id = play_file.id\n" ++
    "    AND features.source_identity = play_file.content_hash\n" ++
    "WHERE tracks.id = ?1 AND play_file.content_hash_algorithm = 1\n" ++
    "  AND " ++ measurableChannels("play_file") ++ ";";

fn rankSql(comptime table: []const u8, comptime column: []const u8) [:0]const u8 {
    return "SELECT (SELECT count(*) FROM " ++ table ++ " WHERE " ++ column ++ " < ?1),\n" ++
        "       (SELECT count(*) FROM " ++ table ++ " WHERE " ++ column ++ " = ?1),\n" ++
        "       (SELECT count(*) FROM " ++ table ++ " WHERE " ++ column ++ " IS NOT NULL);";
}

pub const rank_lufs_sql = rankSql("file_loudness", "integrated_lufs");
pub const rank_onset_rate_sql = rankSql("file_audio_features", "onset_rate");
pub const rank_centroid_sql = rankSql("file_audio_features", "centroid_hz");

fn optionalDouble(statement: sqlite.Statement, column: c_int) ?f64 {
    return if (statement.columnIsNull(column)) null else statement.columnDouble(column);
}

fn openTestLibrary(comptime name: []const u8) !@import("../library.zig").LibraryDatabase {
    return @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-audio-features-" ++ name ++ "?mode=memory&cache=shared",
    );
}

test "a Track reads the features of the bytes its file holds now, and energy ranks them in the Library" {
    var library = try openTestLibrary("track");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'r'), (2, 'r'), (3, 'r'), (4, 'r'), (5, 'r');
        \\INSERT INTO files(id, recording_id, size_bytes, quick_hash, content_hash, content_hash_algorithm, channels) VALUES
        \\    (1, 1, 1, x'01', x'01', 1, 2), (2, 2, 1, x'02', x'02', 1, 2), (3, 3, 1, x'03', x'03', 1, 2),
        \\    (4, 4, 1, x'04', x'04', 1, 2), (5, 5, 1, x'05', x'05', 1, 6);
        \\INSERT INTO tracks(id, recording_id, title, preferred_file_id) VALUES
        \\    (1, 1, 't', 1), (2, 2, 't', 2), (3, 3, 't', 3), (4, 4, 't', NULL), (5, 5, 't', 5);
        \\INSERT INTO file_loudness(file_id, source_identity, integrated_lufs) VALUES
        \\    (1, x'01', -8.0), (2, x'02', -14.0), (4, x'04', -20.0);
        \\INSERT INTO file_audio_features(file_id, source_identity, tempo_bpm, tempo_confidence,
        \\    key_pitch, key_mode, key_confidence, onset_rate, centroid_hz) VALUES
        \\    (1, x'01', 128.0, 0.75, 9, 1, 0.5, 4.0, 3000.0),
        \\    (2, x'02', NULL, NULL, NULL, NULL, NULL, 1.0, NULL),
        \\    (3, x'ff', 90.0, 0.5, 0, 0, 0.5, 2.0, 1000.0),
        \\    (4, x'04', NULL, NULL, NULL, NULL, NULL, NULL, NULL),
        \\    (5, x'05', 90.0, 0.5, 0, 0, 0.5, 2.0, 1000.0);
    );

    const first = (try library.audio_features.trackFeatures(1)).?;
    try std.testing.expectEqual(@as(f64, 128.0), first.tempo.?.bpm);
    try std.testing.expectEqual(@as(f64, 0.75), first.tempo.?.confidence);
    try std.testing.expectEqual(@as(u8, 9), first.key.?.pitch);
    try std.testing.expectEqual(AudioFeatures.Mode.minor, first.key.?.mode);
    try std.testing.expectEqual(@as(f64, 4.0), first.onset_rate.?);
    try std.testing.expectEqual(@as(f64, 3000.0), first.centroid_hz.?);
    const lufs_rank = 2.5 / 3.0;
    const onset_rank = 3.5 / 4.0;
    const centroid_rank = 2.5 / 3.0;
    try std.testing.expectApproxEqAbs((lufs_rank + onset_rank + centroid_rank) / 3.0, first.energy.?, 1e-12);

    const second = (try library.audio_features.trackFeatures(2)).?;
    try std.testing.expectEqual(@as(?AudioFeatures.Tempo, null), second.tempo);
    try std.testing.expectEqual(@as(?AudioFeatures.Key, null), second.key);
    try std.testing.expectEqual(@as(?f64, null), second.centroid_hz);
    try std.testing.expectApproxEqAbs((1.5 / 3.0 + 0.5 / 4.0) / 2.0, second.energy.?, 1e-12);

    try std.testing.expectEqual(@as(?AudioFeatures, null), try library.audio_features.trackFeatures(3));
    const fourth = (try library.audio_features.trackFeatures(4)).?;
    try std.testing.expectEqual(@as(?f64, null), fourth.onset_rate);
    try std.testing.expectApproxEqAbs(0.5 / 3.0, fourth.energy.?, 1e-12);
    try std.testing.expectEqual(@as(?AudioFeatures, null), try library.audio_features.trackFeatures(5));
    try std.testing.expectEqual(@as(?AudioFeatures, null), try library.audio_features.trackFeatures(99));

    try library.database.exec("UPDATE file_audio_features SET onset_rate = NULL, centroid_hz = NULL; DELETE FROM file_loudness;");
    try std.testing.expectEqual(@as(?f64, null), (try library.audio_features.trackFeatures(1)).?.energy);
}

test "energy's ranks count from the features' and loudness's indexes" {
    var library = try openTestLibrary("plans");
    defer library.close();
    inline for (.{ rank_lufs_sql, rank_onset_rate_sql, rank_centroid_sql }) |sql| {
        var statement = try library.database.prepare("EXPLAIN QUERY PLAN " ++ sql);
        defer statement.deinit();
        while (try statement.step() == .row) {
            const detail = statement.columnText(3);
            if (std.mem.indexOf(u8, detail, " file_") != null)
                try std.testing.expect(std.mem.indexOf(u8, detail, "COVERING INDEX") != null);
        }
    }
}
