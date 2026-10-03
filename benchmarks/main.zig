const std = @import("std");
const liborca = @import("liborca");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const track_count = if (args.len > 1)
        try std.fmt.parseInt(usize, args[1], 10)
    else
        500_000;
    const path = if (args.len > 2)
        try allocator.dupeSentinel(u8, args[2], 0)
    else
        try allocator.dupeSentinel(u8, "file:orca-benchmark?mode=memory&cache=shared", 0);

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
    if (args.len > 2) {
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
                const start = std.Io.Clock.awake.now(init.io);
                var result = try library.tracks.page(allocator, query);
                result.deinit();
                const page_ns = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
                std.debug.print(", {t} {d}: {d} ms", .{ sort, offset, @divTrunc(page_ns, std.time.ns_per_ms) });
            }
        }
        const count_start = std.Io.Clock.awake.now(init.io);
        const matching = try library.tracks.countMatching(filter[1]);
        const count_ns = count_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        var search_query = filter[1];
        search_query.limit = 100;
        const filtered_search_start = std.Io.Clock.awake.now(init.io);
        var found = try library.tracks.search(allocator, "Synthetic", search_query);
        found.deinit();
        const filtered_search_ns = filtered_search_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        std.debug.print(", count {d} in {d} ms, search {d} ms\n", .{
            matching,
            @divTrunc(count_ns, std.time.ns_per_ms),
            @divTrunc(filtered_search_ns, std.time.ns_per_ms),
        });
    }
    for ([_]liborca.internal.database.ReleaseSort{ .title, .year, .recently_added }) |sort| {
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

    try seedGenres(&library, init.io);
    try timeGenreListing(&library, allocator, init.io);
    for (benchmark_genres) |genre_id| try timeGenreFilters(&library, allocator, init.io, genre_id);
    try timeSmartPlaylists(&library, allocator, init.io);
    try timeLibrarySearch(&library, allocator, init.io);
    try timeFolders(&library, allocator, init.io);
    try timeLibraryStats(&library, init.io);
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

fn timeLibraryStats(library: *liborca.internal.database.LibraryDatabase, io: std.Io) !void {
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
    const summary = try library.health_issues.summary();
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
        const matching = try library.playlists.smartCount(allocator, case[1], now);
        const count_ms = millisecondsSince(io, count_start);
        const playlist_id = try library.playlists.createSmart(allocator, case[0], case[1]);
        const page_start = std.Io.Clock.awake.now(io);
        var page = try library.playlists.entries(allocator, playlist_id, 100, 0, now);
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

fn timeReleasePage(
    library: *liborca.internal.database.LibraryDatabase,
    allocator: std.mem.Allocator,
    io: std.Io,
    query: liborca.internal.database.ReleaseQuery,
) !i96 {
    const start = std.Io.Clock.awake.now(io);
    var result = try library.releases.page(allocator, query);
    defer result.deinit();
    return start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
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
    const start = std.Io.Clock.awake.now(io);
    var result = try library.tracks.page(allocator, .{
        .genre_id = genre_id,
        .sort = sort,
        .direction = .descending,
        .limit = 100,
        .offset = offset,
    });
    defer result.deinit();
    return start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
}
