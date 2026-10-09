const std = @import("std");
const sqlite = @import("../sqlite.zig");
const optionalInt64 = @import("../columns.zig").optionalInt64;

/// The size of a Library at a glance.
pub const LibraryStats = struct {
    /// Every Artist, as the unfiltered artists listing counts them.
    artists: u64,
    /// Every Release, as the unfiltered releases listing counts them.
    releases: u64,
    /// Every Track, as the unfiltered tracks listing counts them.
    tracks: u64,
    /// The files with a location that is not missing.
    files: u64,
    /// The bytes of those files.
    total_bytes: u64,
    /// The Tracks' summed duration, a Track with none counting as zero.
    total_duration_ms: u64,
    /// When the latest completed scan run finished, in Unix seconds; null
    /// before any scan completed.
    last_scan_finished_at: ?i64,
    /// When the latest analysis measurement was stored, in Unix seconds; null
    /// before any analysis.
    last_analysis_at: ?i64,
    /// When the latest duplicate scan a host started succeeded, in Unix
    /// seconds, as the Job history records it; null when it records none.
    last_duplicate_scan_at: ?i64,
    /// Every listen kept in the local play history.
    listens: u64,
};

/// `last_analysis_at` counts only the analysis pass's three measurements:
/// diagnostics (kind 1, `analysis.service.diagnostics_cache_kind`), temporal
/// fingerprint (kind 2, `analysis.service.fingerprint_cache_kind`) and audio
/// features (kind 6, `analysis.audio_features.cache_kind`). Kind 3 (AcoustID,
/// also stored by matching and submission), kind 4 (an undecodable verdict)
/// and kind 5 (an unfingerprintable note) hold no measurement and do not
/// count. The numbers are hard-coded because the database layer does not
/// import the analysis layer.
pub const library_stats_sql =
    \\SELECT (SELECT count(*) FROM artists),
    \\       (SELECT count(*) FROM releases),
    \\       (SELECT count(*) FROM tracks),
    \\       present.files, present.bytes,
    \\       (SELECT COALESCE(sum(max(duration_ms, 0)), 0) FROM tracks),
    \\       (SELECT max(finished_at) FROM scan_runs WHERE state = 'completed'),
    \\       (SELECT max(created_at) FROM analysis_results WHERE kind IN (1, 2, 6)),
    \\       (SELECT max(finished_at) FROM job_history WHERE kind = 'duplicate_scan' AND state = 'succeeded'),
    \\       (SELECT count(*) FROM listens)
    \\FROM (SELECT count(*) AS files, COALESCE(sum(max(files.size_bytes, 0)), 0) AS bytes
    \\      FROM (SELECT DISTINCT file_id FROM locations NOT INDEXED
    \\            WHERE state <> 'missing' ORDER BY file_id) AS located
    \\      JOIN files ON files.id = located.file_id) AS present;
;

pub const LibraryStatsRepository = struct {
    db: sqlite.Database,

    pub fn stats(self: *const LibraryStatsRepository) !LibraryStats {
        var statement = try self.db.prepare(library_stats_sql);
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return .{
            .artists = @intCast(statement.columnInt64(0)),
            .releases = @intCast(statement.columnInt64(1)),
            .tracks = @intCast(statement.columnInt64(2)),
            .files = @intCast(statement.columnInt64(3)),
            .total_bytes = @intCast(statement.columnInt64(4)),
            .total_duration_ms = @intCast(statement.columnInt64(5)),
            .last_scan_finished_at = optionalInt64(statement, 6),
            .last_analysis_at = optionalInt64(statement, 7),
            .last_duplicate_scan_at = optionalInt64(statement, 8),
            .listens = @intCast(statement.columnInt64(9)),
        };
    }
};

const LibraryDatabase = @import("../library.zig").LibraryDatabase;

fn openStatsLibrary(comptime name: []const u8) !LibraryDatabase {
    return LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-library-stats-" ++ name ++ "?mode=memory&cache=shared",
    );
}

fn addFile(library: *LibraryDatabase, uri: []const u8, size_bytes: i64, state: @import("locations.zig").LocationState) !i64 {
    const file_id = try library.files.create(.{ .size_bytes = size_bytes });
    _ = try library.locations.upsert(.{ .file_id = file_id, .volume_id = LibraryDatabase.null_volume, .uri = uri, .state = state });
    return file_id;
}

test "library stats count what the unfiltered artists, releases and tracks listings count, and sum Track durations" {
    var library = try openStatsLibrary("browse");
    defer library.close();
    const drake = (try library.artists.ensure(.{ .key = "nick drake", .name = "Nick Drake", .sort_name = "nick drake" })).?;
    _ = try library.artists.ensure(.{ .key = "john cale", .name = "John Cale", .sort_name = "john cale" });
    const first = try library.releases.upsert(.{ .release_key = "nick drake|pink moon", .title = "Pink Moon" });
    const second = try library.releases.upsert(.{ .release_key = "nick drake|bryter layter", .title = "Bryter Layter" });
    try library.tracks.upsertTracks(&.{
        .{ .title = "Pink Moon", .artist_id = drake, .release_id = first, .duration_ms = 125_000, .track_number = 1 },
        .{ .title = "Place to Be", .artist_id = drake, .release_id = first, .duration_ms = 163_000, .track_number = 2 },
        .{ .title = "Hazey Jane II", .artist_id = drake, .release_id = second, .track_number = 1 },
    });

    const stats = try library.stats.stats();
    try std.testing.expectEqual(try library.artists.countMatching(.{}), stats.artists);
    try std.testing.expectEqual(try library.releases.countMatching(.{}), stats.releases);
    try std.testing.expectEqual(try library.tracks.countMatching(.{}), stats.tracks);
    try std.testing.expectEqual(@as(u64, 2), stats.artists);
    try std.testing.expectEqual(@as(u64, 2), stats.releases);
    try std.testing.expectEqual(@as(u64, 3), stats.tracks);
    try std.testing.expectEqual(@as(u64, 288_000), stats.total_duration_ms);
}

test "library stats count and size only files with a location that is not missing" {
    var library = try openStatsLibrary("missing");
    defer library.close();
    _ = try addFile(&library, "music/present.flac", 1_000, .present);
    _ = try addFile(&library, "music/unverified.flac", 200, .unverified);
    _ = try addFile(&library, "music/gone.flac", 30_000, .missing);
    const moved = try addFile(&library, "music/old.flac", 4_000, .missing);
    _ = try library.locations.upsert(.{ .file_id = moved, .volume_id = LibraryDatabase.null_volume, .uri = "music/new.flac" });

    const stats = try library.stats.stats();
    try std.testing.expectEqual(@as(u64, 3), stats.files);
    try std.testing.expectEqual(@as(u64, 5_200), stats.total_bytes);
}

test "an empty library has zero counts and no scan or analysis time" {
    var library = try openStatsLibrary("empty");
    defer library.close();
    try std.testing.expectEqual(LibraryStats{
        .artists = 0,
        .releases = 0,
        .tracks = 0,
        .files = 0,
        .total_bytes = 0,
        .total_duration_ms = 0,
        .last_scan_finished_at = null,
        .last_analysis_at = null,
        .last_duplicate_scan_at = null,
        .listens = 0,
    }, try library.stats.stats());
}

test "the last analysis time is null before any measurement and the latest measurement after" {
    var library = try openStatsLibrary("analysis");
    defer library.close();
    const file_id = try addFile(&library, "music/measured.flac", 100, .present);
    try std.testing.expectEqual(@as(?i64, null), (try library.stats.stats()).last_analysis_at);

    var sql: [2048]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(&sql,
        \\INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result, created_at)
        \\VALUES ({d}, 1, 'orca.diagnostics', 1, x'00', x'01', x'00', 1700000000),
        \\       ({d}, 2, 'orca.temporal-fingerprint', 2, x'00', x'01', x'00', 1700000300),
        \\       ({d}, 3, 'orca.acoustid', 1, x'00', x'02', x'00', 1700000600),
        \\       ({d}, 4, 'orca.decoder-set', 1, x'00', x'03', x'00', 1700000900),
        \\       ({d}, 5, 'orca.acoustid', 1, x'00', x'04', x'00', 1700001200);
    , .{ file_id, file_id, file_id, file_id, file_id }, 0));
    try std.testing.expectEqual(@as(?i64, 1_700_000_300), (try library.stats.stats()).last_analysis_at);
}

test "the last analysis time ignores rows that hold no measurement" {
    var library = try openStatsLibrary("analysis-without-measurement");
    defer library.close();
    const file_id = try addFile(&library, "music/matched.flac", 100, .present);
    var sql: [1024]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(&sql,
        \\INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result, created_at)
        \\VALUES ({d}, 3, 'orca.acoustid', 1, x'00', x'01', x'00', 1700000000),
        \\       ({d}, 4, 'orca.decoder-set', 1, x'00', x'02', x'00', 1700000100),
        \\       ({d}, 5, 'orca.acoustid', 1, x'00', x'03', x'00', 1700000200);
    , .{ file_id, file_id, file_id }, 0));
    try std.testing.expectEqual(@as(?i64, null), (try library.stats.stats()).last_analysis_at);
}

test "the last scan time is when the latest completed scan run finished" {
    var library = try openStatsLibrary("scan");
    defer library.close();
    const root = try library.library_roots.add(LibraryDatabase.null_volume, "/music");
    try library.database.exec("DELETE FROM scan_runs;");
    var sql: [320]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(&sql,
        \\INSERT INTO scan_runs(root_id, generation, finished_at, state) VALUES
        \\    ({d}, 1, 1700000000, 'completed'), ({d}, 2, 1700000500, 'cancelled'),
        \\    ({d}, 3, 1700000200, 'completed'), ({d}, 4, NULL, 'running');
    , .{ root, root, root, root }, 0));
    try std.testing.expectEqual(@as(?i64, 1_700_000_200), (try library.stats.stats()).last_scan_finished_at);
}

test "the last duplicate scan time is when the latest succeeded duplicate scan in the Job history finished" {
    var library = try openStatsLibrary("duplicates");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO job_history(kind, started_at, finished_at, state, completed_units) VALUES
        \\    ('duplicate_scan', 1700000000, 1700000100, 'succeeded', 1),
        \\    ('duplicate_scan', 1700000200, 1700000900, 'cancelled', 0),
        \\    ('analysis', 1700000300, 1700000800, 'succeeded', 1),
        \\    ('duplicate_scan', 1700000300, 1700000400, 'succeeded', 1);
    );
    try std.testing.expectEqual(@as(?i64, 1_700_000_400), (try library.stats.stats()).last_duplicate_scan_at);
}

test "library stats count every listen in the local play history" {
    var library = try openStatsLibrary("listens");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO listens(file_id, started_at, listened_ms, title, artist, syncable) VALUES
        \\    (NULL, 1700000000, 31000, 'One', 'Artist', 0), (NULL, 1700000500, 200000, 'Two', 'Artist', 1);
    );
    try std.testing.expectEqual(@as(u64, 2), (try library.stats.stats()).listens);
}
