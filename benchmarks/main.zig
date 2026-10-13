const std = @import("std");
const liborca = @import("liborca");

const default_runs = 3;

var runs: usize = default_runs;
var model_path: ?[]const u8 = null;
var failed_checks: usize = 0;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var positional: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--runs=")) {
            runs = try std.fmt.parseInt(usize, arg["--runs=".len..], 10);
            if (runs == 0) return error.NoRuns;
        } else if (std.mem.startsWith(u8, arg, "--model=")) {
            model_path = arg["--model=".len..];
        } else try positional.append(allocator, arg);
    }
    const track_count = if (positional.items.len > 0)
        try std.fmt.parseInt(usize, positional.items[0], 10)
    else
        500_000;
    const path = if (positional.items.len > 1)
        try allocator.dupeSentinel(u8, positional.items[1], 0)
    else
        try allocator.dupeSentinel(u8, "file:orca-benchmark?mode=memory&cache=shared", 0);
    const persistent = positional.items.len > 1;
    std.debug.print("each timing is the minimum of {d} runs (--runs=N)\n", .{runs});
    try timeAnalysisPass(allocator, init.io);
    try timeModelMemory(allocator, init.io);
    try timeWakeups(allocator, init.io);

    var library = try liborca.internal.database.LibraryDatabase.open(allocator, init.io, path);
    defer library.close();
    try library.database.exec("DELETE FROM tracks;");

    var batch: [1000]liborca.internal.database.TrackInput = undefined;
    for (&batch, 0..) |*track, index| track.* = .{
        .title = "Synthetic benchmark track",
        .album = "Synthetic benchmark album",
        .album_artist = "Orca benchmark",
        .duration_ms = 180_000,
        .track_number = @intCast(index + 1),
        .disc_number = 1,
    };

    const insert_start = std.Io.Clock.awake.now(init.io);
    var inserted: usize = 0;
    while (inserted < track_count) {
        const count = @min(batch.len, track_count - inserted);
        try library.tracks.upsertTracks(batch[0..count]);
        inserted += count;
    }
    const insert_ns = insert_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;

    var open_ns: i96 = 0;
    if (persistent) {
        library.close();
        const open_start = std.Io.Clock.awake.now(init.io);
        library = try liborca.internal.database.LibraryDatabase.open(allocator, init.io, path);
        open_ns = open_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
    }

    const search_start = std.Io.Clock.awake.now(init.io);
    var page = try library.tracks.search(allocator, "Synthetic", .{ .limit = 100 });
    defer page.deinit();
    const search_ns = search_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;

    try library.database.exec(
        \\INSERT OR IGNORE INTO recordings(id, title) SELECT id, title FROM tracks;
        \\UPDATE tracks SET recording_id = id;
        \\INSERT OR REPLACE INTO recording_play_stats(recording_id, play_count, last_played_at)
        \\    SELECT id, id % 97 + 1, 1700000000 + id FROM tracks WHERE id % 3 = 0;
        \\INSERT OR REPLACE INTO ratings(recording_id, rating, updated_at)
        \\    SELECT id, id % 100 + 1, 1700000000 FROM tracks WHERE id % 5 = 0;
        \\INSERT OR REPLACE INTO feedback(recording_id, score, updated_at)
        \\    SELECT id, 1, 1700000000 + id FROM tracks WHERE id % 7 = 0;
        \\INSERT OR REPLACE INTO files(id, recording_id, first_seen_at, codec, sample_rate, bit_depth)
        \\    SELECT id, id, 1700000000 + (id * 7919) % 1000003,
        \\           CASE WHEN (id - 1) / 1000 % 4 = 0 THEN 'mp3' ELSE 'flac' END,
        \\           CASE WHEN (id - 1) / 1000 % 10 = 0 THEN 96000 ELSE 44100 END,
        \\           CASE WHEN (id - 1) / 1000 % 4 = 0 THEN NULL WHEN (id - 1) / 1000 % 10 = 0 THEN 24 ELSE 16 END
        \\    FROM tracks;
        \\INSERT INTO identification_proposals(file_id, provider, provider_id, confidence, payload)
        \\    SELECT id, 'musicbrainz', 'benchmark-' || id, 0.9, x'' FROM tracks WHERE id % 7001 = 0;
        \\INSERT OR REPLACE INTO releases(id, title, release_date)
        \\    WITH RECURSIVE numbers(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM numbers WHERE value < 5000)
        \\    SELECT value, 'Synthetic benchmark album', printf('%04d-01-01', 1950 + value % 75) FROM numbers;
        \\UPDATE tracks SET preferred_file_id = id, release_id = (id - 1) / 1000 % 5000 + 1;
    );

    std.debug.print(
        "Orca {f} SQLite/FTS benchmark: {d} tracks, insert {d} ms, open {d} ms, search {d} ms, {d} results\n",
        .{
            liborca.version,
            track_count,
            @divTrunc(insert_ns, std.time.ns_per_ms),
            @divTrunc(open_ns, std.time.ns_per_ms),
            @divTrunc(search_ns, std.time.ns_per_ms),
            page.items.len,
        },
    );
    for ([_]liborca.internal.database.TrackSort{
        .title, .play_count, .last_played, .rating, .loved, .year, .date_added,
    }) |sort| {
        std.debug.print("{t} page", .{sort});
        for ([_]u32{ 0, 50_000, 250_000 }) |offset| {
            const page_ns = try timePage(&library, allocator, init.io, sort, null, offset);
            std.debug.print(", offset {d}: {d} ms", .{ offset, @divTrunc(page_ns, std.time.ns_per_ms) });
        }
        std.debug.print("\n", .{});
    }
    try library.database.exec("UPDATE tracks SET explicit = 2 WHERE id % 11 = 0;");
    const track_filters = [_]struct { []const u8, liborca.internal.database.TrackQuery }{
        .{ "years", .{ .year_min = 1990, .year_max = 1999 } },
        .{ "lossless", .{ .lossless = true } },
        .{ "lossy", .{ .lossless = false } },
        .{ "min_rate", .{ .min_sample_rate = 96_000 } },
        .{ "explicit", .{ .explicit_only = true } },
        .{ "combined", .{ .lossless = true, .min_sample_rate = 96_000, .year_min = 1990 } },
        .{ "loved_lossy", .{ .loved_only = true, .lossless = false } },
        .{ "codec", .{ .codec = "FLAC" } },
        .{ "max_rate", .{ .max_sample_rate = 44_100 } },
        .{ "added", .{ .added_after = 1_700_900_000 } },
    };
    for (track_filters) |filter| {
        std.debug.print("track {s}", .{filter[0]});
        for ([_]liborca.internal.database.TrackSort{ .title, .play_count, .year }) |sort| {
            for ([_]u32{ 0, 10_000 }) |offset| {
                var query = filter[1];
                query.sort = sort;
                query.direction = .descending;
                query.limit = 100;
                query.offset = offset;
                var page_ns: i96 = std.math.maxInt(i96);
                for (0..runs) |_| {
                    const start = std.Io.Clock.awake.now(init.io);
                    var result = try library.tracks.page(allocator, query);
                    result.deinit();
                    page_ns = @min(page_ns, start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
                }
                std.debug.print(", {t} {d}: {d} ms", .{ sort, offset, @divTrunc(page_ns, std.time.ns_per_ms) });
            }
        }
        const count_start = std.Io.Clock.awake.now(init.io);
        const matching = try library.tracks.countMatching(filter[1]);
        const count_ns = count_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        const totals_start = std.Io.Clock.awake.now(init.io);
        _ = try library.tracks.totals(filter[1]);
        const totals_ns = totals_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        var search_query = filter[1];
        search_query.limit = 100;
        const filtered_search_start = std.Io.Clock.awake.now(init.io);
        var found = try library.tracks.search(allocator, "Synthetic", search_query);
        found.deinit();
        const filtered_search_ns = filtered_search_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        std.debug.print(", count {d} in {d} ms, totals {d} ms, search {d} ms\n", .{
            matching,
            @divTrunc(count_ns, std.time.ns_per_ms),
            @divTrunc(totals_ns, std.time.ns_per_ms),
            @divTrunc(filtered_search_ns, std.time.ns_per_ms),
        });
    }
    for ([_]liborca.internal.database.ReleaseSort{ .title, .artist, .year, .recently_added }) |sort| {
        std.debug.print("release {t} page", .{sort});
        for ([_]u32{ 0, 2_500 }) |offset| {
            const page_ns = try timeReleasePage(&library, allocator, init.io, .{ .sort = sort, .limit = 100, .offset = offset });
            std.debug.print(", offset {d}: {d} ms", .{ offset, @divTrunc(page_ns, std.time.ns_per_ms) });
        }
        std.debug.print("\n", .{});
    }
    const release_filters = [_]struct { []const u8, liborca.internal.database.ReleaseQuery }{
        .{ "most_played", .{ .sort = .most_played } },
        .{ "high_resolution", .{ .high_resolution_only = true } },
        .{ "needs_review", .{ .needs_review_only = true } },
        .{ "lossless", .{ .lossless_only = true } },
        .{ "years", .{ .year_min = 1990, .year_max = 1999 } },
        .{ "artwork", .{ .has_artwork = false } },
        .{ "added", .{ .added_after = 1_700_000_100 } },
    };
    for (release_filters) |filter| {
        var query = filter[1];
        query.limit = 100;
        const page_ns = try timeReleasePage(&library, allocator, init.io, query);
        const count_start = std.Io.Clock.awake.now(init.io);
        const matching = try library.releases.countMatching(query);
        const count_ns = count_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        std.debug.print("release {s}: page {d} ms, count {d} in {d} ms\n", .{
            filter[0],
            @divTrunc(page_ns, std.time.ns_per_ms),
            matching,
            @divTrunc(count_ns, std.time.ns_per_ms),
        });
    }

    try timeReleaseIndex(&library, allocator, init.io);

    try seedGenres(&library, init.io);
    try timeGenreListing(&library, allocator, init.io);
    for (benchmark_genres) |genre_id| try timeGenreFilters(&library, allocator, init.io, genre_id);
    try timeSmartPlaylists(&library, allocator, init.io);
    try timeLibrarySearch(&library, allocator, init.io);
    try timeFolders(&library, allocator, init.io);
    try timeLibraryStats(&library, allocator, init.io);
    try timeFileSorts(&library, allocator, init.io);
    try timeAudioSimilarity(&library, allocator, init.io);
    try timePickRadio(&library, allocator, init.io);
    try timeScanWrites(allocator, init.io);
    try timeGenreReprojection(&library, init.io);
    if (failed_checks != 0) {
        std.debug.print("{d} benchmark checks failed\n", .{failed_checks});
        return error.BenchmarkCheckFailed;
    }
}

const audio_similarity = liborca.internal.library.audio_similarity;
const similarity_vectors = 100_000;
const similarity_neighbours = 300;

fn timeAudioSimilarity(library: *liborca.internal.database.LibraryDatabase, allocator: std.mem.Allocator, io: std.Io) !void {
    for (std.enums.values(audio_similarity.Model)) |model| {
        const seed_start = std.Io.Clock.awake.now(io);
        var sql: [512]u8 = undefined;
        try library.database.exec(try std.fmt.bufPrintSentinel(&sql,
            \\INSERT OR REPLACE INTO file_audio_embeddings(model, file_id, source_identity, vector)
            \\    SELECT {d}, id, CASE WHEN id % 97 = 0 THEN x'00' ELSE content_hash END, zeroblob({d})
            \\    FROM files ORDER BY id LIMIT {d};
        , .{ @backingInt(model), model.spec().embedding_size, similarity_vectors }, 0));
        const seeded: usize = @intCast(library.database.changes());
        try fillEmbeddings(library, model, seeded);
        std.debug.print("audio similarity {t}: {d} vectors of {d} values seeded in {d} ms\n", .{
            model,
            seeded,
            model.spec().embedding_size,
            millisecondsSince(io, seed_start),
        });

        const query = try firstStoredQuery(library, model) orelse return error.NoEmbeddingForTheBenchmark;
        std.debug.print("  nearest {d} with similarities:", .{similarity_neighbours});
        var fastest: i96 = std.math.maxInt(i96);
        for (0..runs) |_| {
            const run_ns = try timeSimilaritySearch(library, allocator, io, &query);
            fastest = @min(fastest, run_ns);
            std.debug.print(" {d}", .{@divTrunc(run_ns, std.time.ns_per_us)});
        }
        std.debug.print(" us, fastest {d} us\n", .{@divTrunc(fastest, std.time.ns_per_us)});
    }
}

fn firstStoredQuery(library: *liborca.internal.database.LibraryDatabase, model: audio_similarity.Model) !?audio_similarity.Query {
    var files = try library.database.prepare("SELECT id FROM files ORDER BY id LIMIT 64;");
    defer files.deinit();
    while (try files.step() == .row) {
        if (try audio_similarity.Query.ofFile(&library.audio_embeddings, model, files.columnInt64(0))) |query| return query;
    }
    return null;
}

fn timeSimilaritySearch(
    library: *liborca.internal.database.LibraryDatabase,
    allocator: std.mem.Allocator,
    io: std.Io,
    query: *const audio_similarity.Query,
) !i96 {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    var nearest: [similarity_neighbours]audio_similarity.Neighbour = undefined;
    var similarities: audio_similarity.RecordingSimilarities = .empty;
    const start = std.Io.Clock.awake.now(io);
    _ = try audio_similarity.nearestRecordingsWithSimilarities(arena_state.allocator(), &library.audio_embeddings, query, &nearest, &similarities);
    return start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
}

const sorts_copy_path = ".zig-cache/orca-bench-sorts.db";
const first_page_budget_ms = 75;
const candidate_page_budget_ms = 400;
const snapshot_page_budget_ms = 10;
const TrackSort = liborca.internal.database.TrackSort;
const DeepSort = struct { sort: TrackSort, fill_budget_ms: i96 };
const deep_sorts = [_]DeepSort{
    .{ .sort = .path, .fill_budget_ms = 3000 },
    .{ .sort = .loudness, .fill_budget_ms = 1000 },
    .{ .sort = .genre, .fill_budget_ms = 1000 },
    .{ .sort = .bitrate, .fill_budget_ms = 1000 },
};

fn withinBudget(milliseconds: i96, budget_ms: i96) []const u8 {
    if (milliseconds < budget_ms) return "";
    failed_checks += 1;
    return " OVER BUDGET";
}

fn timeOnePage(
    tracks: *const liborca.internal.database.TrackRepository,
    allocator: std.mem.Allocator,
    io: std.Io,
    sort: TrackSort,
    offset: u32,
) !i96 {
    const start = std.Io.Clock.awake.now(io);
    var result = try tracks.page(allocator, .{ .sort = sort, .direction = .descending, .limit = 100, .offset = offset });
    result.deinit();
    return start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
}

fn timeFileSorts(library: *liborca.internal.database.LibraryDatabase, allocator: std.mem.Allocator, io: std.Io) !void {
    const seed_start = std.Io.Clock.awake.now(io);
    try library.database.exec(
        \\UPDATE files SET duration_ms = 120000 + (id * 7919) % 240000, channels = 2, quick_hash = CAST(id AS BLOB),
        \\    content_hash = CAST(id AS BLOB), content_hash_algorithm = 1;
        \\INSERT INTO file_loudness(file_id, source_identity, integrated_lufs)
        \\    SELECT id, content_hash, -6.0 - ((id * 104729) % 1000003) / 50000.0 FROM files WHERE id % 3 <> 0;
        \\DELETE FROM locations;
        \\INSERT INTO locations(file_id, volume_id, uri, state)
        \\    SELECT id, 1, printf('/bench/%03d/%07d.flac', (id * 31) % 1000, id), 'present' FROM files;
        \\UPDATE tracks SET album_artist = printf('Album Artist %05d', (id * 31) % 25000),
        \\    album = printf('Album %d', id % 7);
    );
    std.debug.print("file sorts seeded: {d} ms\n", .{millisecondsSince(io, seed_start)});
    std.debug.print("pages on the writer connection (budgets: offset 0 {d} ms, offset 50000 {d} ms):\n", .{ first_page_budget_ms, candidate_page_budget_ms });
    for ([_]TrackSort{ .title, .date_added, .loudness, .bitrate, .path, .album_artist, .genre }) |sort| {
        std.debug.print("  {t} page", .{sort});
        const first_ms = @divTrunc(try timePage(library, allocator, io, sort, null, 0), std.time.ns_per_ms);
        std.debug.print(", offset 0: {d} ms{s}", .{ first_ms, withinBudget(first_ms, first_page_budget_ms) });
        const candidate_ms = @divTrunc(try timePage(library, allocator, io, sort, null, 50_000), std.time.ns_per_ms);
        std.debug.print(", offset 50000: {d} ms{s}", .{ candidate_ms, withinBudget(candidate_ms, candidate_page_budget_ms) });
        const deep_ms = @divTrunc(try timePage(library, allocator, io, sort, null, 250_000), std.time.ns_per_ms);
        std.debug.print(", offset 250000: {d} ms\n", .{deep_ms});
    }

    std.Io.Dir.cwd().deleteFile(io, sorts_copy_path) catch {};
    try library.database.exec("VACUUM INTO '" ++ sorts_copy_path ++ "';");
    defer std.Io.Dir.cwd().deleteFile(io, sorts_copy_path) catch {};
    var copy = try liborca.internal.database.LibraryDatabase.open(allocator, io, sorts_copy_path);
    defer copy.close();
    std.debug.print(
        "pages on a read connection of a file copy (budgets: offset 0 {d} ms, offset 50000 {d} ms, first offset 250000 with the snapshot fill per sort, then {d} ms):\n",
        .{ first_page_budget_ms, candidate_page_budget_ms, snapshot_page_budget_ms },
    );
    for (deep_sorts) |deep| {
        var first_ms: i96 = std.math.maxInt(i96);
        var candidate_ms = first_ms;
        var fill_ms = first_ms;
        var hit_ms = first_ms;
        for (0..runs) |_| {
            var reader = try copy.openReader();
            defer reader.close();
            const reading: liborca.internal.database.TrackRepository = .{ .db = reader, .write_lane = copy.write_lane };
            first_ms = @min(first_ms, @divTrunc(try timeOnePage(&reading, allocator, io, deep.sort, 0), std.time.ns_per_ms));
            candidate_ms = @min(candidate_ms, @divTrunc(try timeOnePage(&reading, allocator, io, deep.sort, 50_000), std.time.ns_per_ms));
            fill_ms = @min(fill_ms, @divTrunc(try timeOnePage(&reading, allocator, io, deep.sort, 250_000), std.time.ns_per_ms));
            hit_ms = @min(hit_ms, @divTrunc(try timeOnePage(&reading, allocator, io, deep.sort, 250_000), std.time.ns_per_ms));
        }
        std.debug.print("  {t} page, offset 0: {d} ms{s}, offset 50000: {d} ms{s}, offset 250000 with fill: {d} ms{s}, snapshot hit: {d} ms{s}\n", .{
            deep.sort,
            first_ms,
            withinBudget(first_ms, first_page_budget_ms),
            candidate_ms,
            withinBudget(candidate_ms, candidate_page_budget_ms),
            fill_ms,
            withinBudget(fill_ms, deep.fill_budget_ms),
            hit_ms,
            withinBudget(hit_ms, snapshot_page_budget_ms),
        });
    }
    try library.database.exec(
        \\INSERT INTO locations(file_id, volume_id, uri, state)
        \\    SELECT id, 1, printf('/other/%03d/%07d.flac', (id * 17) % 1000, id), 'present' FROM files;
        \\INSERT INTO locations(file_id, volume_id, uri, state)
        \\    SELECT id, 1, printf('/third/%03d/%07d.flac', (id * 13) % 1000, id), 'present' FROM files;
    );
    const crowded_ms = @divTrunc(try timePage(library, allocator, io, .path, null, 0), std.time.ns_per_ms);
    std.debug.print("  path offset 0, 3 locations/file (informational): {d} ms\n", .{crowded_ms});
}

fn timeFolders(library: *liborca.internal.database.LibraryDatabase, allocator: std.mem.Allocator, io: std.Io) !void {
    const start = std.Io.Clock.awake.now(io);
    try library.database.exec(
        \\INSERT INTO volumes(id, stable_key, label) VALUES (9000, 'benchmark', 'Benchmark');
        \\INSERT INTO library_roots(id, volume_id, path) VALUES (9000, 9000, '/bench/Music');
        \\UPDATE files SET duration_ms = 180000;
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state)
        \\    SELECT id, 9000, 9000,
        \\           printf('/bench/Music/Artist %05d/Album %d/%02d Track.flac',
        \\                  (id - 1) / 20 + 1, (id - 1) / 10 % 2 + 1, (id - 1) % 10 + 1),
        \\           CASE WHEN id % 101 = 0 THEN 'missing' ELSE 'present' END
        \\    FROM files;
    );
    std.debug.print("folders seeded: {d} ms", .{millisecondsSince(io, start)});
    const cases = [_]struct { []const u8, []const u8, u32 }{
        .{ "root", "", 0 },
        .{ "root offset 24000", "", 24_000 },
        .{ "artist", "Artist 00042", 0 },
        .{ "album", "Artist 00042/Album 2", 0 },
    };
    for (cases) |case| {
        const page_start = std.Io.Clock.awake.now(io);
        var page = try library.locations.folderPage(allocator, 9000, case[1], 512, case[2]);
        defer page.deinit();
        std.debug.print(", {s} page of {d}: {d} ms", .{ case[0], page.items.len, millisecondsSince(io, page_start) });
    }
    const play_start = std.Io.Clock.awake.now(io);
    const track_ids = try library.locations.folderTrackIds(allocator, 9000, "Artist 00042");
    defer allocator.free(track_ids);
    std.debug.print(", artist tracks {d}: {d} ms\n", .{ track_ids.len, millisecondsSince(io, play_start) });
}

fn timeLibraryStats(library: *liborca.internal.database.LibraryDatabase, allocator: std.mem.Allocator, io: std.Io) !void {
    const seed_start = std.Io.Clock.awake.now(io);
    const volume = liborca.internal.database.LibraryDatabase.null_volume;
    var sql: [2048]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(&sql,
        \\UPDATE files SET size_bytes = 20000000 + id % 997;
        \\INSERT INTO locations(file_id, volume_id, uri, state)
        \\    SELECT id, {d}, 'benchmark/' || id || '.flac', CASE WHEN id % 101 = 0 THEN 'missing' ELSE 'present' END
        \\    FROM files;
        \\INSERT INTO library_roots(volume_id, path) VALUES ({d}, '/benchmark');
        \\INSERT INTO scan_runs(root_id, generation, finished_at, state)
        \\    WITH RECURSIVE numbers(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM numbers WHERE value < 1000)
        \\    SELECT (SELECT max(id) FROM library_roots), value, 1700000000 + value,
        \\           CASE WHEN value % 10 = 0 THEN 'cancelled' ELSE 'completed' END FROM numbers;
        \\INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result, created_at)
        \\    SELECT id, 1, 'orca.diagnostics', 1, x'00', x'01', zeroblob(1500), 1700000000 + id FROM files;
        \\INSERT INTO library_health_issues(file_id, kind, severity, related_file_id)
        \\    SELECT id, 1, 0, NULL FROM files WHERE id % 10 = 5;
        \\INSERT INTO library_health_issues(file_id, kind, severity, related_file_id)
        \\    SELECT id, 5, 1, NULL FROM files WHERE id % 50 = 7;
        \\INSERT INTO library_health_issues(file_id, kind, severity, related_file_id)
        \\    SELECT id, 9, 1, CASE WHEN id % 100 = 1 THEN id + 1 ELSE id - 1 END FROM files WHERE id % 100 IN (1, 2, 3);
        \\INSERT INTO library_health_issues(file_id, kind, severity, related_file_id)
        \\    SELECT id, 10, 0, CASE WHEN id % 200 = 11 THEN id + 1 ELSE id - 1 END FROM files WHERE id % 200 IN (11, 12);
        \\INSERT INTO health_dismissals(file_id, kind, quick_hash, dismissed_at)
        \\    SELECT file_id, kind, NULL, 1700000000 FROM library_health_issues WHERE file_id % 1000 = 5;
    , .{ volume, volume }, 0));
    std.debug.print("stats seeded: {d} ms", .{millisecondsSince(io, seed_start)});

    const stats_start = std.Io.Clock.awake.now(io);
    const stats = try library.stats.stats();
    std.debug.print(", library stats {d} files {d} bytes in {d} ms", .{
        stats.files,
        stats.total_bytes,
        millisecondsSince(io, stats_start),
    });
    const warm_stats_start = std.Io.Clock.awake.now(io);
    _ = try library.stats.stats();
    std.debug.print(", again in {d} ms", .{millisecondsSince(io, warm_stats_start)});
    const summary_start = std.Io.Clock.awake.now(io);
    const summary = try library.health_issues.summary(allocator);
    std.debug.print(", health summary of {d} kinds in {d} ms\n", .{ summary.len, millisecondsSince(io, summary_start) });
    for (summary.items()) |entry| std.debug.print("  {t}: {d} files, {d} bytes\n", .{ entry.kind, entry.files, entry.bytes });
}

const typical_smart_rules =
    \\{"v":1,"match":"all","rules":[
    \\  {"field":"genre","op":"is","value":"Benchmark genre 001"},
    \\  {"field":"year","op":"between","value":[1990,1999]},
    \\  {"field":"rating","op":"gte","value":60}
    \\],"sort":{"field":"title"},"limit":1000}
;

fn timeSmartPlaylists(library: *liborca.internal.database.LibraryDatabase, allocator: std.mem.Allocator, io: std.Io) !void {
    const every_operator = try std.Io.Dir.cwd().readFileAlloc(io, "fixtures/fuzz/smart-playlist/every-operator.json", allocator, .limited(1 << 16));
    const now = 1_700_600_000;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "every operator", every_operator },
        .{ "genre year rating", typical_smart_rules },
    };
    for (cases) |case| {
        const count_start = std.Io.Clock.awake.now(io);
        const matching = try library.playlists.smartCount(allocator, case[1], .{ .now = now, .seed = 0 });
        const count_ms = millisecondsSince(io, count_start);
        const playlist_id = try library.playlists.createSmart(allocator, case[0], case[1]);
        const page_start = std.Io.Clock.awake.now(io);
        var page = try library.playlists.entries(allocator, playlist_id, 100, 0, .{ .now = now, .seed = 0 });
        defer page.deinit();
        std.debug.print("smart playlist {s}: count {d} in {d} ms, first page of {d} in {d} ms\n", .{
            case[0],
            matching,
            count_ms,
            page.items.len,
            millisecondsSince(io, page_start),
        });
    }
}

fn timeLibrarySearch(library: *liborca.internal.database.LibraryDatabase, allocator: std.mem.Allocator, io: std.Io) !void {
    const retitle_start = std.Io.Clock.awake.now(io);
    try library.database.exec(
        \\UPDATE tracks SET title = CASE id % 7
        \\    WHEN 0 THEN 'The Long Road ' || id WHEN 1 THEN 'Amber Light ' || id
        \\    WHEN 2 THEN 'American Night ' || id WHEN 3 THEN 'Gamma Rays ' || id
        \\    WHEN 4 THEN 'Theory of Sound ' || id WHEN 5 THEN 'Quiet Hours ' || id
        \\    ELSE 'Northern Lights ' || id END;
        \\UPDATE releases SET title = CASE id % 4
        \\    WHEN 0 THEN 'The Album ' || id WHEN 1 THEN 'Amsterdam ' || id
        \\    WHEN 2 THEN 'Seasons ' || id ELSE 'Atlas ' || id END;
    );
    const retitle_ns = retitle_start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    std.debug.print("search retitle: {d} ms", .{@divTrunc(retitle_ns, std.time.ns_per_ms)});
    for ([_][]const u8{ "am", "the", "amber light 7" }) |text| {
        const start = std.Io.Clock.awake.now(io);
        var results = try library.search.find(allocator, text, .{});
        const hits = results.hits.len;
        results.deinit();
        const search_ns = start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        std.debug.print(", \"{s}\" {d} hits in {d} ms", .{ text, hits, @divTrunc(search_ns, std.time.ns_per_ms) });
    }
    for ([_]liborca.internal.database.ReleaseQuery{
        .{ .release_kind = .ep_or_single, .sort = .title, .limit = 100 },
        .{ .appearing_artist_id = 7, .sort = .title, .limit = 100 },
        .{ .appearing_artist_id = 7, .release_kind = .album, .sort = .recently_added, .limit = 100 },
    }) |query| {
        const page_ns = try timeReleasePage(library, allocator, io, query);
        const count_start = std.Io.Clock.awake.now(io);
        const matching = try library.releases.countMatching(query);
        std.debug.print(", release kind {?t} appears {?d} page {d} ms, count {d} in {d} ms", .{
            query.release_kind,
            query.appearing_artist_id,
            @divTrunc(page_ns, std.time.ns_per_ms),
            matching,
            millisecondsSince(io, count_start),
        });
    }
    const totals_start = std.Io.Clock.awake.now(io);
    const totals = (try library.artists.totals(7)).?;
    std.debug.print(", artist totals {d} tracks {d} appearances in {d} ms", .{
        totals.track_count,
        totals.appearance_count,
        millisecondsSince(io, totals_start),
    });
    for ([_]liborca.internal.database.ReleaseSort{ .title, .year }) |sort| {
        const query: liborca.internal.database.ReleaseQuery = .{ .text = "am", .sort = sort, .limit = 100 };
        const page_ns = try timeReleasePage(library, allocator, io, query);
        const count_start = std.Io.Clock.awake.now(io);
        const matching = try library.releases.countMatching(query);
        const count_ns = count_start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        std.debug.print(", release text {t} page {d} ms, count {d} in {d} ms", .{
            sort,
            @divTrunc(page_ns, std.time.ns_per_ms),
            matching,
            @divTrunc(count_ns, std.time.ns_per_ms),
        });
    }
    std.debug.print("\n", .{});
}

fn timeReleaseIndex(library: *liborca.internal.database.LibraryDatabase, allocator: std.mem.Allocator, io: std.Io) !void {
    for ([_]liborca.internal.database.ReleaseSort{ .title, .artist }) |sort| {
        const start = std.Io.Clock.awake.now(io);
        const buckets = try library.releases.letterIndex(allocator, .{ .sort = sort });
        allocator.free(buckets);
        std.debug.print("release {t} letters: {d} buckets in {d} ms\n", .{
            sort,
            buckets.len,
            millisecondsSince(io, start),
        });
    }
    for ([_]struct { []const u8, liborca.internal.database.ReleaseQuery }{
        .{ "all", .{} },
        .{ "lossless", .{ .lossless_only = true } },
        .{ "added", .{ .added_after = 1_700_000_100 } },
    }) |filter| {
        const start = std.Io.Clock.awake.now(io);
        const totals = try library.releases.totals(filter[1]);
        std.debug.print("release {s} totals: {d} releases in {d} ms\n", .{ filter[0], totals.count, millisecondsSince(io, start) });
    }
}

fn timeReleasePage(
    library: *liborca.internal.database.LibraryDatabase,
    allocator: std.mem.Allocator,
    io: std.Io,
    query: liborca.internal.database.ReleaseQuery,
) !i96 {
    var fastest: i96 = std.math.maxInt(i96);
    for (0..runs) |_| {
        const start = std.Io.Clock.awake.now(io);
        var result = try library.releases.page(allocator, query);
        result.deinit();
        fastest = @min(fastest, start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
    }
    return fastest;
}

const benchmark_genres = [_]?i64{ null, 1, 20, 300 };

fn seedGenres(library: *liborca.internal.database.LibraryDatabase, io: std.Io) !void {
    const start = std.Io.Clock.awake.now(io);
    try library.database.exec(
        \\INSERT OR REPLACE INTO artists(id, name, sort_name, key)
        \\    WITH RECURSIVE numbers(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM numbers WHERE value < 25000)
        \\    SELECT value, printf('Benchmark artist %05d', value), printf('Benchmark artist %05d', value),
        \\           printf('benchmark artist %05d', value) FROM numbers;
        \\UPDATE tracks SET artist_id = (id - 1) / 20 % 25000 + 1;
        \\UPDATE releases SET album_artist_id = id * 7 % 25000 + 1;
        \\INSERT INTO genres(id, name, key)
        \\    WITH RECURSIVE numbers(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM numbers WHERE value < 300)
        \\    SELECT value, printf('Benchmark genre %03d', value), printf('benchmarkgenre%03d', value) FROM numbers;
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance)
        \\    SELECT id, 1 + draw * draw * draw * 300 / 1000000000, 0, 0
        \\    FROM (SELECT id, id * 2654435761 % 1000003 % 1000 AS draw FROM tracks);
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance)
        \\    SELECT candidate.track_id, candidate.genre, 1, 0
        \\    FROM (SELECT id AS track_id, 1 + draw * draw * draw * 300 / 1000000000 AS genre
        \\          FROM (SELECT id, id * 40503 % 1000033 % 1000 AS draw FROM tracks WHERE id % 10 >= 6)) AS candidate
        \\    WHERE NOT EXISTS (SELECT 1 FROM track_genres AS existing
        \\                      WHERE existing.track_id = candidate.track_id AND existing.genre_id = candidate.genre);
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance)
        \\    SELECT candidate.track_id, candidate.genre, 2, 0
        \\    FROM (SELECT id AS track_id, 1 + id * 7919 % 300 AS genre FROM tracks WHERE id % 10 = 9) AS candidate
        \\    WHERE NOT EXISTS (SELECT 1 FROM track_genres AS existing
        \\                      WHERE existing.track_id = candidate.track_id AND existing.genre_id = candidate.genre);
    );
    std.debug.print("genres seeded: {d} ms\n", .{millisecondsSince(io, start)});
}

fn timeGenreListing(
    library: *liborca.internal.database.LibraryDatabase,
    allocator: std.mem.Allocator,
    io: std.Io,
) !void {
    const count_start = std.Io.Clock.awake.now(io);
    const genre_count = try library.genres.count(allocator, "");
    std.debug.print("genre list: count {d}: {d} ms", .{ genre_count, millisecondsSince(io, count_start) });
    for ([_]liborca.internal.database.GenreSort{ .name, .track_count }) |sort| {
        const start = std.Io.Clock.awake.now(io);
        var page = try library.genres.page(allocator, .{ .sort = sort, .limit = 100 });
        defer page.deinit();
        std.debug.print(", {t} page: {d} ms", .{ sort, millisecondsSince(io, start) });
    }
    const filter_start = std.Io.Clock.awake.now(io);
    var filtered = try library.genres.page(allocator, .{ .filter = "genre 1", .limit = 100 });
    defer filtered.deinit();
    std.debug.print(", filtered page of {d}: {d} ms\n", .{ filtered.items.len, millisecondsSince(io, filter_start) });
}

fn timeGenreFilters(
    library: *liborca.internal.database.LibraryDatabase,
    allocator: std.mem.Allocator,
    io: std.Io,
    genre_id: ?i64,
) !void {
    const count_start = std.Io.Clock.awake.now(io);
    const track_count = try library.tracks.countMatching(.{ .genre_id = genre_id });
    std.debug.print("genre {?d}: {d} tracks, count {d} ms\n", .{ genre_id, track_count, millisecondsSince(io, count_start) });
    const tail: u32 = @intCast(track_count -| 100);
    for ([_]liborca.internal.database.TrackSort{ .title, .play_count, .year, .date_added }) |sort| {
        std.debug.print("  {t} page", .{sort});
        var previous: ?u32 = null;
        for ([_]u32{ 0, 50_000, 250_000 }) |target| {
            const offset = @min(target, tail);
            if (previous == offset) continue;
            previous = offset;
            const page_ns = try timePage(library, allocator, io, sort, genre_id, offset);
            std.debug.print(", offset {d}: {d} ms", .{ offset, @divTrunc(page_ns, std.time.ns_per_ms) });
        }
        std.debug.print("\n", .{});
    }

    const release_count_start = std.Io.Clock.awake.now(io);
    const release_count = try library.releases.countMatching(.{ .genre_id = genre_id });
    std.debug.print("  releases {d}: count {d} ms", .{ release_count, millisecondsSince(io, release_count_start) });
    for ([_]liborca.internal.database.ReleaseSort{ .title, .year }) |sort| {
        const start = std.Io.Clock.awake.now(io);
        var page = try library.releases.page(allocator, .{ .genre_id = genre_id, .sort = sort, .limit = 100 });
        defer page.deinit();
        std.debug.print(", {t} page: {d} ms", .{ sort, millisecondsSince(io, start) });
    }

    const artist_count_start = std.Io.Clock.awake.now(io);
    const artist_count = try library.artists.countMatching(.{ .genre_id = genre_id });
    std.debug.print("\n  artists {d}: count {d} ms", .{ artist_count, millisecondsSince(io, artist_count_start) });
    for ([_]liborca.internal.database.ArtistSort{ .name, .track_count, .recently_added }) |sort| {
        const start = std.Io.Clock.awake.now(io);
        var page = try library.artists.page(allocator, .{ .genre_id = genre_id, .sort = sort, .limit = 100 });
        defer page.deinit();
        std.debug.print(", {t} page: {d} ms", .{ sort, millisecondsSince(io, start) });
    }
    std.debug.print("\n", .{});
}

fn millisecondsSince(io: std.Io, start: std.Io.Timestamp) i96 {
    return @divTrunc(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds, std.time.ns_per_ms);
}

fn timePage(
    library: *liborca.internal.database.LibraryDatabase,
    allocator: std.mem.Allocator,
    io: std.Io,
    sort: liborca.internal.database.TrackSort,
    genre_id: ?i64,
    offset: u32,
) !i96 {
    return timePageOn(&library.tracks, allocator, io, sort, genre_id, offset);
}

fn timePageOn(
    tracks: *const liborca.internal.database.TrackRepository,
    allocator: std.mem.Allocator,
    io: std.Io,
    sort: liborca.internal.database.TrackSort,
    genre_id: ?i64,
    offset: u32,
) !i96 {
    var fastest: i96 = std.math.maxInt(i96);
    for (0..runs) |_| {
        const start = std.Io.Clock.awake.now(io);
        var result = try tracks.page(allocator, .{
            .genre_id = genre_id,
            .sort = sort,
            .direction = .descending,
            .limit = 100,
            .offset = offset,
        });
        result.deinit();
        fastest = @min(fastest, start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
    }
    return fastest;
}

fn fillEmbeddings(library: *liborca.internal.database.LibraryDatabase, model: audio_similarity.Model, count: usize) !void {
    var prng = std.Random.DefaultPrng.init(0x0ca0_0000 + @as(u64, @backingInt(model)));
    var vector: [1024]u8 = undefined;
    const size = model.spec().embedding_size;
    var update = try library.database.prepare(
        "UPDATE file_audio_embeddings SET vector = ?3 WHERE model = ?1 AND file_id = ?2;",
    );
    defer update.deinit();
    try library.database.exec("BEGIN IMMEDIATE;");
    errdefer library.database.exec("ROLLBACK;") catch {};
    for (1..count + 1) |file_id| {
        prng.random().bytes(vector[0..size]);
        try update.reset();
        try update.bindInt64(1, @backingInt(model));
        try update.bindInt64(2, @intCast(file_id));
        try update.bindBlob(3, vector[0..size]);
        if (try update.step() != .done) return error.SqlFailed;
    }
    try library.database.exec("COMMIT;");
}

const discovery = liborca.internal.library.discovery;

fn timePickRadio(library: *liborca.internal.database.LibraryDatabase, allocator: std.mem.Allocator, io: std.Io) !void {
    for (std.enums.values(audio_similarity.Model)) |model| {
        const source = discovery.Source.of(library, model);
        for ([_]u8{ 0, 100 }) |explore| {
            var fastest: i96 = std.math.maxInt(i96);
            var picked: usize = 0;
            for (0..runs) |_| {
                const start = std.Io.Clock.awake.now(io);
                var picks = try discovery.pickRadio(
                    allocator,
                    &source,
                    .{ .track = 1 },
                    .{ .explore = explore, .include_unplayed = true },
                    .{ .now_s = 1_700_900_000, .seed = 42 },
                    50,
                );
                defer picks.deinit();
                picked = picks.items.len;
                fastest = @min(fastest, start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
            }
            std.debug.print("pickRadio {t} explore {d}: {d} picks, fastest {d} ms\n", .{
                model,
                explore,
                picked,
                @divTrunc(fastest, std.time.ns_per_ms),
            });
        }
    }
}

const scan_write_rows = 100_000;
const scan_write_files = 500_000;
const scan_write_batch = 256;
const ScanWritePhase = struct { name: []const u8, budget_ms: i96 };
const scan_write_phases = [_]ScanWritePhase{
    .{ .name = "insert", .budget_ms = 2500 },
    .{ .name = "state-change update", .budget_ms = 2500 },
    .{ .name = "mark seen", .budget_ms = 250 },
    .{ .name = "mark missing", .budget_ms = 250 },
    .{ .name = "unchanged file update", .budget_ms = 2500 },
};

fn timeScanWrites(allocator: std.mem.Allocator, io: std.Io) !void {
    var fastest: [scan_write_phases.len]i96 = @splat(std.math.maxInt(i96));
    for (0..runs) |run| {
        const phases = try scanWritePhases(allocator, io, run);
        for (&fastest, phases) |*best, value| best.* = @min(best.*, value);
    }
    std.debug.print("scan writes, {d} locations in batches of {d} on {d} files:\n", .{ scan_write_rows, scan_write_batch, scan_write_files });
    for (scan_write_phases, fastest) |phase, nanoseconds| {
        const milliseconds = @divTrunc(nanoseconds, std.time.ns_per_ms);
        std.debug.print("  {s}: {d} ms (budget {d} ms){s}\n", .{
            phase.name,
            milliseconds,
            phase.budget_ms,
            withinBudget(milliseconds, phase.budget_ms),
        });
    }
}

fn scanWritePhases(allocator: std.mem.Allocator, io: std.Io, run: usize) ![scan_write_phases.len]i96 {
    var name: [96]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&name, "file:orca-bench-scan-{d}?mode=memory&cache=shared", .{run}, 0);
    var library = try liborca.internal.database.LibraryDatabase.open(allocator, io, path);
    defer library.close();
    var seed: [1024]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(&seed,
        \\INSERT INTO files(id, channels, quick_hash, content_hash, content_hash_algorithm)
        \\    WITH RECURSIVE numbers(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM numbers WHERE value < {d})
        \\    SELECT value, 2, CAST(value AS BLOB), CAST(value AS BLOB), 1 FROM numbers;
        \\INSERT INTO file_loudness(file_id, source_identity, integrated_lufs)
        \\    SELECT id, content_hash, -6.0 - ((id * 104729) % 1000003) / 50000.0 FROM files WHERE id % 3 <> 0;
        \\INSERT INTO library_roots(id, volume_id, path) VALUES (1, 1, '/bench');
    , .{scan_write_files}, 0));

    var phases: [scan_write_phases.len]i96 = undefined;
    var ids: [scan_write_batch]i64 = undefined;
    for (0..2) |pass| {
        const start = std.Io.Clock.awake.now(io);
        var row: usize = 0;
        while (row < scan_write_rows) {
            const count = @min(scan_write_batch, scan_write_rows - row);
            library.write_lane.acquire();
            defer library.write_lane.release();
            try library.database.exec("BEGIN IMMEDIATE;");
            errdefer library.database.exec("ROLLBACK;") catch {};
            for (row..row + count) |index| {
                var uri: [64]u8 = undefined;
                _ = try library.locations.upsertLocked(.{
                    .file_id = @intCast(index + 1),
                    .volume_id = 1,
                    .root_id = 1,
                    .uri = try std.fmt.bufPrint(&uri, "/bench/{d:0>3}/{d:0>7}.flac", .{ index % 1000, index }),
                    .native_inode = @intCast(index),
                    .size_bytes = 4096,
                    .modified_ns = 1_700_000_000,
                    .state = if (pass == 0) .present else .unverified,
                    .last_seen_generation = 1,
                });
            }
            try library.database.exec("COMMIT;");
            row += count;
        }
        phases[pass] = start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    }

    const seen_start = std.Io.Clock.awake.now(io);
    var row: usize = 0;
    while (row < scan_write_rows) {
        const count = @min(scan_write_batch, scan_write_rows - row);
        for (ids[0..count], row..) |*id, index| id.* = @intCast(index + 1);
        library.write_lane.acquire();
        defer library.write_lane.release();
        try library.database.exec("BEGIN IMMEDIATE;");
        errdefer library.database.exec("ROLLBACK;") catch {};
        try library.locations.markSeenLocked(ids[0..count], 3);
        try library.database.exec("COMMIT;");
        row += count;
    }
    phases[2] = seen_start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;

    const missing_start = std.Io.Clock.awake.now(io);
    const marked = try library.files.markMissingBelowGeneration(1, 4);
    if (marked != scan_write_rows) return error.UnexpectedMissingCount;
    phases[3] = missing_start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;

    const update_start = std.Io.Clock.awake.now(io);
    row = 0;
    while (row < scan_write_rows) {
        const count = @min(scan_write_batch, scan_write_rows - row);
        library.write_lane.acquire();
        defer library.write_lane.release();
        try library.database.exec("BEGIN IMMEDIATE;");
        errdefer library.database.exec("ROLLBACK;") catch {};
        for (row..row + count) |index| {
            var hash: [24]u8 = undefined;
            const value = try std.fmt.bufPrint(&hash, "{d}", .{index + 1});
            try library.files.updateLocked(@intCast(index + 1), .{
                .channels = 2,
                .quick_hash = value,
                .content_hash = value,
            });
        }
        try library.database.exec("COMMIT;");
        row += count;
    }
    phases[4] = update_start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    return phases;
}

const reprojected_tracks = 10_000;
const reprojection_stride = 50;
const reprojection_budget_ms = 500;

fn timeGenreReprojection(library: *liborca.internal.database.LibraryDatabase, io: std.Io) !void {
    try library.database.exec(
        \\CREATE TEMP TABLE reprojected AS SELECT track_id, genre_id, ordinal, provenance FROM track_genres
        \\    WHERE track_id % 50 = 0 ORDER BY track_id, ordinal;
        \\CREATE INDEX temp.reprojected_by_track ON reprojected(track_id);
    );
    const with_triggers = try reprojectionRun(library, io);
    try library.database.exec(
        \\DROP TRIGGER track_genres_first_genre_ai;
        \\DROP TRIGGER track_genres_first_genre_ad;
        \\DROP TRIGGER track_genres_first_genre_au;
    );
    const without_triggers = try reprojectionRun(library, io);
    const percent = @divTrunc((with_triggers - without_triggers) * 100, @max(without_triggers, 1));
    const milliseconds = @divTrunc(with_triggers, std.time.ns_per_ms);
    std.debug.print("genre reprojection, {d} tracks deleted and reinserted in one transaction: {d} ms (budget {d} ms){s}; {d} ms without the first_genre_id triggers ({d}%, informational)\n", .{
        reprojected_tracks,
        milliseconds,
        reprojection_budget_ms,
        withinBudget(milliseconds, reprojection_budget_ms),
        @divTrunc(without_triggers, std.time.ns_per_ms),
        percent,
    });
}

fn reprojectionRun(library: *liborca.internal.database.LibraryDatabase, io: std.Io) !i96 {
    var fastest: i96 = std.math.maxInt(i96);
    var remove = try library.database.prepare("DELETE FROM track_genres WHERE track_id = ?1;");
    defer remove.deinit();
    var restore = try library.database.prepare(
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance)
        \\    SELECT track_id, genre_id, ordinal, provenance FROM temp.reprojected WHERE track_id = ?1 ORDER BY ordinal;
    );
    defer restore.deinit();
    for (0..runs) |_| {
        library.write_lane.acquire();
        defer library.write_lane.release();
        const start = std.Io.Clock.awake.now(io);
        try library.database.exec("BEGIN IMMEDIATE;");
        errdefer library.database.exec("ROLLBACK;") catch {};
        for (0..reprojected_tracks) |index| {
            const track_id: i64 = @intCast((index + 1) * reprojection_stride);
            try remove.bindInt64(1, track_id);
            if (try remove.step() != .done) return error.SqlFailed;
            try remove.reset();
            try restore.bindInt64(1, track_id);
            if (try restore.step() != .done) return error.SqlFailed;
            try restore.reset();
        }
        try library.database.exec("COMMIT;");
        fastest = @min(fastest, start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
    }
    return fastest;
}

const analysis_pass = liborca.internal.library.analysis_pass;
const analysis_files = 48;
const analysis_fixtures = [_][]const u8{
    "generated-reference.flac",
    "fingerprint-reference.mp3",
    "midside-reference.flac",
    "tagged-reference.ogg",
    "tagged-reference.opus",
    "generated-reference.wav",
    "tagged-reference-aac.m4a",
    "tagged-reference-alac.m4a",
    "tagged-reference.mp3",
    "tagged-reference.aiff",
    "hires-reference.flac",
    "stereo-reference.qoa",
};
const analysis_directory = ".zig-cache/orca-bench-analysis";

const MemoryReading = struct {
    baseline_kib: ?u64,
    peak_kib: ?u64,

    fn begin(io: std.Io) MemoryReading {
        const baseline = statusKib(io, "VmRSS:");
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "/proc/self/clear_refs", .data = "5" }) catch {};
        return .{ .baseline_kib = baseline, .peak_kib = null };
    }

    fn finish(self: MemoryReading, io: std.Io) MemoryReading {
        return .{ .baseline_kib = self.baseline_kib, .peak_kib = statusKib(io, "VmHWM:") };
    }

    fn print(self: MemoryReading, label: []const u8) void {
        const peak = self.peak_kib orelse {
            std.debug.print("{s}: peak RSS unavailable\n", .{label});
            return;
        };
        std.debug.print("{s}: peak RSS {d} MiB, {d} MiB resident before\n", .{
            label,
            peak / 1024,
            (self.baseline_kib orelse 0) / 1024,
        });
    }
};

fn statusKib(io: std.Io, key: []const u8) ?u64 {
    var buffer: [8192]u8 = undefined;
    const file = std.Io.Dir.cwd().openFile(io, "/proc/self/status", .{}) catch return null;
    defer file.close(io);
    const length = file.readPositionalAll(io, &buffer, 0) catch return null;
    var lines = std.mem.splitScalar(u8, buffer[0..length], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        var fields = std.mem.tokenizeAny(u8, line[key.len..], " \tkB");
        return std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch null;
    }
    return null;
}

fn analysisLibrary(
    allocator: std.mem.Allocator,
    io: std.Io,
    name: [:0]const u8,
    root: []const u8,
) !liborca.internal.database.LibraryDatabase {
    var library = try liborca.internal.database.LibraryDatabase.open(allocator, io, name);
    errdefer library.close();
    for (0..analysis_files) |index| {
        const uri = try std.fmt.allocPrint(allocator, "{s}/{d:0>2}-{s}", .{ root, index, analysis_fixtures[index % analysis_fixtures.len] });
        defer allocator.free(uri);
        const digest = try liborca.internal.storage.quick_hash.fromPath(io, uri);
        const stat = try std.Io.Dir.cwd().statFile(io, uri, .{});
        const file_id = try library.files.create(.{ .audio_format = 1, .quick_hash = &digest });
        _ = try library.locations.upsert(.{
            .file_id = file_id,
            .volume_id = liborca.internal.database.LibraryDatabase.null_volume,
            .uri = uri,
            .native_inode = @intCast(stat.inode),
            .size_bytes = @intCast(stat.size),
            .modified_ns = @intCast(stat.mtime.nanoseconds),
            .state = .present,
        });
        try library.observed_tags.upsert(.{
            .file_id = file_id,
            .values = .{ .title = "One", .artist = "Artist", .album = "Album" },
        });
    }
    return library;
}

fn writeAnalysisFiles(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(io, analysis_directory);
    try cwd.createDirPath(io, analysis_directory);
    const current = try std.process.currentPathAlloc(io, allocator);
    const root = try std.fs.path.resolve(allocator, &.{ current, analysis_directory });
    for (0..analysis_files) |index| {
        const source = try std.fmt.allocPrint(allocator, "fixtures/audio/{s}", .{analysis_fixtures[index % analysis_fixtures.len]});
        const bytes = try cwd.readFileAlloc(io, source, allocator, .limited(8 * 1024 * 1024));
        const target = try std.fmt.allocPrint(allocator, "{s}/{d:0>2}-{s}", .{ analysis_directory, index, analysis_fixtures[index % analysis_fixtures.len] });
        try cwd.writeFile(io, .{ .sub_path = target, .data = bytes });
    }
    return root;
}

fn timeAnalysisPass(allocator: std.mem.Allocator, io: std.Io) !void {
    const root = try writeAnalysisFiles(allocator, io);
    defer std.Io.Dir.cwd().deleteTree(io, analysis_directory) catch {};
    const available = analysis_pass.availableThreads();
    std.debug.print("analysis pass, {d} files from {d} fixtures:\n", .{ analysis_files, analysis_fixtures.len });
    var thread_counts: [4]u16 = .{ 1, 2, 4, available };
    for (thread_counts, 0..) |threads, position| {
        if (threads > available or (position == 3 and available <= 4)) continue;
        var fastest: i96 = std.math.maxInt(i96);
        var seen: u64 = 0;
        var memory: MemoryReading = .{ .baseline_kib = null, .peak_kib = null };
        for (0..runs) |run| {
            var name: [64]u8 = undefined;
            var library = try analysisLibrary(
                allocator,
                io,
                try std.fmt.bufPrintSentinel(&name, "file:orca-bench-analysis-{d}-{d}?mode=memory&cache=shared", .{ threads, run }, 0),
                root,
            );
            defer library.close();
            var pass: analysis_pass.LibraryAnalysis = .{
                .allocator = allocator,
                .io = io,
                .files = &library.files,
                .analysis_cache = &library.analysis_cache,
                .health_issues = &library.health_issues,
                .write_lane = library.write_lane,
                .database_handle = library.database,
                .parameters = .{ .waveform_buckets = 8 },
                .threads = threads,
            };
            const reading = MemoryReading.begin(io);
            const start = std.Io.Clock.awake.now(io);
            const result = try pass.run();
            const elapsed = start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
            if (elapsed < fastest) {
                fastest = elapsed;
                memory = reading.finish(io);
            }
            seen = result.files_seen;
        }
        const per_minute = @divTrunc(@as(i96, seen) * 60 * std.time.ns_per_s, @max(fastest, 1));
        std.debug.print("  {d} threads: {d} files in {d} ms, {d} files/minute\n", .{
            threads,
            seen,
            @divTrunc(fastest, std.time.ns_per_ms),
            per_minute,
        });
        memory.print("    pass");
    }
    _ = &thread_counts;
}

fn timeModelMemory(allocator: std.mem.Allocator, io: std.Io) !void {
    const path = model_path orelse {
        std.debug.print("model open and embedding pass peak RSS: skipped, pass --model=PATH to a model file\n", .{});
        return;
    };
    const reading = MemoryReading.begin(io);
    var model = liborca.internal.analysis.audio_embedding.Model.open(allocator, io, path) catch |err| {
        std.debug.print("model open peak RSS: skipped, {t} opening {s}\n", .{ err, path });
        return;
    };
    defer model.deinit();
    reading.finish(io).print("model open");

    const root = try writeAnalysisFiles(allocator, io);
    defer std.Io.Dir.cwd().deleteTree(io, analysis_directory) catch {};
    var library = try analysisLibrary(allocator, io, "file:orca-bench-analysis-model?mode=memory&cache=shared", root);
    defer library.close();
    var pass: analysis_pass.LibraryAnalysis = .{
        .allocator = allocator,
        .io = io,
        .files = &library.files,
        .analysis_cache = &library.analysis_cache,
        .health_issues = &library.health_issues,
        .write_lane = library.write_lane,
        .database_handle = library.database,
        .parameters = .{ .waveform_buckets = 8 },
        .embedding_model = model,
    };
    const pass_reading = MemoryReading.begin(io);
    const start = std.Io.Clock.awake.now(io);
    const result = try pass.run();
    std.debug.print("embedding pass: {d} files in {d} ms\n", .{ result.files_seen, millisecondsSince(io, start) });
    pass_reading.finish(io).print("embedding pass");
}

const engine = liborca.internal.audio.engine;

const SilentDecoder = struct {
    fn decoder(self: *SilentDecoder) liborca.internal.codec.Decoder {
        return .{
            .context = self,
            .codec = liborca.internal.codec.decoder.codec_id.pcm_float,
            .vtable = &.{ .read_frames = read, .seek = seek, .deinit = release },
            .format = .{
                .sample_format = .float_32,
                .channels = 1,
                .sample_rate = 48_000,
                .bits_per_sample = 32,
                .bytes_per_frame = 4,
            },
            .frame_count = 48_000 * 600,
        };
    }

    fn read(_: *anyopaque, output: []f32) !usize {
        @memset(output, 0);
        return output.len;
    }

    fn seek(_: *anyopaque, _: u64) !void {}

    fn release(_: *anyopaque) void {}
};

const wakeup_seconds = 10;

fn timeWakeups(allocator: std.mem.Allocator, io: std.Io) !void {
    _ = io;
    var backend: liborca.internal.audio.output.TestBackend = .{ .allocator = allocator };
    defer backend.deinit();
    var player: liborca.internal.audio.player.Player = .{};
    defer player.deinit();
    var registration: liborca.internal.core.work.Registration = .{};
    const player_engine = try engine.PlayerEngine.create(allocator, .{
        .player = &player,
        .handle = .{ .index = 0, .generation = 1 },
        .factory = backend.factory(),
    });
    defer player_engine.destroy();
    player_engine.registration = &registration;
    registration.waker = player_engine.waker();

    var silent: SilentDecoder = .{};
    try player.loadSource(liborca.internal.audio.source_session.SourceSession.init(silent.decoder()));
    const zone = try engine.ZoneRuntime.create(allocator);
    defer zone.destroy();
    zone.output_requested.store(true, .release);
    try player_engine.publishZones(&.{zone});

    const quantum_ns: u64 = @as(u64, engine.frames_per_block) * std.time.ns_per_s / 48_000;
    var samples: [engine.frames_per_block]f32 = undefined;

    player.play();
    player_engine.pass();
    const stream = backend.liveStream() orelse return error.NoOutputOpened;
    var wakeups: u64 = 0;
    var callbacks: u64 = 0;
    var elapsed: u64 = 0;
    var next_callback: u64 = quantum_ns;
    var next_pass: u64 = engine.park_ns;
    while (elapsed < wakeup_seconds * std.time.ns_per_s) {
        elapsed = @min(next_pass, next_callback);
        player_engine.elapsed_ns = elapsed;
        if (next_callback <= elapsed) {
            stream.pump(&samples, engine.frames_per_block);
            callbacks += 1;
            next_callback += quantum_ns;
        }
        if (next_pass <= elapsed) {
            player_engine.pass();
            wakeups += 1;
            next_pass += engine.park_ns;
        }
    }
    std.debug.print("playing, {d} s of audio: {d} engine wakeups ({d}/s), {d} output callbacks\n", .{
        wakeup_seconds,
        wakeups,
        wakeups / wakeup_seconds,
        callbacks,
    });

    player.pause();
    var settle_passes: u64 = 0;
    var settle_callbacks: u64 = 0;
    while (stream.isActive() or !player_engine.isIdle()) {
        player_engine.pass();
        settle_passes += 1;
        if (settle_passes > 64) return error.NeverWentIdle;
        stream.pump(&samples, engine.frames_per_block);
        settle_callbacks += 1;
    }
    var idle_wakeups: u64 = 0;
    var idle_callbacks: u64 = 0;
    var idle_elapsed: u64 = 0;
    while (idle_elapsed < wakeup_seconds * std.time.ns_per_s) : (idle_elapsed += quantum_ns) {
        stream.pump(&samples, engine.frames_per_block);
        if (stream.isActive()) idle_callbacks += 1;
        if (!player_engine.isIdle()) {
            player_engine.pass();
            idle_wakeups += 1;
        }
    }
    std.debug.print("paused: inactive after {d} wakeups and {d} callbacks; then {d} engine wakeups and {d} output callbacks in {d} s\n", .{
        settle_passes,
        settle_callbacks,
        idle_wakeups,
        idle_callbacks,
        wakeup_seconds,
    });
}
