const std = @import("std");
const database = @import("../database/root.zig");
const job = @import("job.zig");
const network = @import("../network/root.zig");
const runtime_module = @import("runtime.zig");
const runtime_provider_tests = @import("runtime_provider_tests.zig");
const runtime_tests = @import("runtime_tests.zig");

const testing = std.testing;
const sqlite = database.sqlite;
const DailyMix = runtime_module.DailyMix;
const DailyMixEntry = runtime_module.DailyMixEntry;
const DailyMixes = runtime_module.DailyMixes;
const LibraryHandle = runtime_module.LibraryHandle;
const OrcaRuntime = runtime_module.OrcaRuntime;

const day_s = 86_400;
/// 08:00 UTC.
const now_s: i64 = 1_800_000_000;
const track_ms = 180_000;
const genre_artists = 12;
const recordings_per_artist = 20;
const solo_artist = 13;
const big_artist = 14;
const first_old_artist = 15;
const old_artists = 10;
const live_release = 30;
const release_count = 40;

/// Twelve Artists in six genres of two, each with 8 favorites (4 listens
/// 5 to 8 days ago), 6 played once and 6 never played on two Releases; a
/// most played lone Artist with 10 Recordings ("Solo"), a lone Artist with 45
/// ("Big"), ten Artists with one Recording each last played 400 days ago on
/// a Release of its own ("Old"), and a live Release by Artist 1. Every Track
/// lasts 3 minutes.
const Rig = struct {
    runtime: OrcaRuntime,
    clock: network.testing.TestClock = .{ .wall_offset_ms = now_s * 1000 },
    library: LibraryHandle = undefined,
    next_recording: i64 = 1,
    listen_time: i64 = 0,
    sql: std.ArrayList(u8) = .empty,

    fn init(self: *Rig, uri: [:0]const u8) !void {
        self.* = .{ .runtime = .init(testing.allocator) };
        errdefer self.runtime.deinit();
        defer self.sql.deinit(testing.allocator);
        self.runtime.listen_hooks.sample_clock = runtime_provider_tests.sampleClock(&self.clock);
        self.library = try self.runtime.openLibrary(testing.io, uri);

        try self.add(
            \\INSERT INTO genres(id, name, key) VALUES (1, 'Hip Hop', 'hip hop'), (2, 'Jazz', 'jazz'), (3, 'Rock', 'rock'),
            \\    (4, 'Folk', 'folk'), (5, 'Ambient', 'ambient'), (6, 'Metal', 'metal'), (7, 'Solo', 'solo'),
            \\    (8, 'Big', 'big'), (9, 'Old', 'old');
            \\
        , .{});
        for (1..first_old_artist + old_artists) |artist| try self.add("INSERT INTO artists(id, name, key) VALUES ({d}, 'Artist {d}', 'artist {d}');\n", .{ artist, artist, artist });
        for (1..release_count + 1) |release| try self.add(
            "INSERT INTO releases(id, title, release_type) VALUES ({d}, 'Release {d}', '{s}');\n",
            .{ release, release, if (release == live_release) "live" else "album" },
        );

        for (1..genre_artists + 1) |artist_index| {
            const artist: i64 = @intCast(artist_index);
            const genre = @divFloor(artist - 1, 2) + 1;
            for (0..recordings_per_artist) |index| {
                const release = artist * 2 - 1 + @as(i64, @intFromBool(index >= recordings_per_artist / 2));
                const plays: u8 = if (index < 8) 4 else if (index < 14) 1 else 0;
                try self.recording(artist, release, genre, plays, 5);
            }
        }
        for (0..10) |_| try self.recording(solo_artist, 25, 7, 10, 5);
        for (0..45) |index| {
            const release: i64 = 26 + @as(i64, @intCast(index / 15));
            const plays: u8 = if (index < 20) 4 else if (index < 30) 1 else 0;
            try self.recording(big_artist, release, 8, plays, 5);
        }
        for (0..old_artists) |index| try self.recording(first_old_artist + @as(i64, @intCast(index)), 31 + @as(i64, @intCast(index)), 9, 2, 400);
        for (0..3) |_| try self.recording(1, live_release, 1, 4, 5);

        try self.add(
            \\INSERT INTO recording_play_stats(recording_id, play_count, last_played_at)
            \\    SELECT recording_id, count(*), max(started_at) FROM listens GROUP BY recording_id;
        , .{});
        try self.add("\x00", .{});
        const library_database = try self.libraryDatabase();
        try library_database.database.exec(self.sql.items[0 .. self.sql.items.len - 1 :0]);
    }

    fn deinit(self: *Rig) void {
        self.runtime.deinit();
    }

    fn add(self: *Rig, comptime format: []const u8, arguments: anytype) !void {
        try self.sql.print(testing.allocator, format, arguments);
    }

    /// A Recording with one Track and file, and `plays` listens a day apart
    /// from `days_ago` days back.
    fn recording(self: *Rig, artist: i64, release: i64, genre: i64, plays: u8, days_ago: i64) !void {
        const id = self.next_recording;
        self.next_recording += 1;
        try self.add(
            \\INSERT INTO recordings(id, title) VALUES ({d}, 'r{d}');
            \\INSERT INTO files(id, recording_id, audio_format, size_bytes) VALUES ({d}, {d}, 1, 1);
            \\INSERT INTO tracks(id, recording_id, release_id, title, artist_id, preferred_file_id, duration_ms, created_at)
            \\    VALUES ({d}, {d}, {d}, 't{d}', {d}, {d}, {d}, 1000);
            \\INSERT INTO locations(file_id, volume_id, uri, state) VALUES ({d}, {d}, '/m/{d}', 'present');
            \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES ({d}, {d}, 0, 0);
            \\
        , .{
            id,                                   id,
            id,                                   id,
            id,                                   id,
            release,                              id,
            artist,                               id,
            track_ms,                             id,
            database.LibraryDatabase.null_volume, id,
            id,                                   genre,
        });
        for (0..plays) |play| {
            self.listen_time += 1;
            const started = now_s - (days_ago + @as(i64, @intCast(play))) * day_s - self.listen_time;
            try self.listen(id, started);
        }
    }

    fn listen(self: *Rig, recording_id: i64, started_at: i64) !void {
        try self.add(
            "INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist) VALUES ({d}, {d}, {d}, 1000, 't', 'a');\n",
            .{ recording_id, recording_id, started_at },
        );
    }

    fn libraryDatabase(self: *Rig) !*database.LibraryDatabase {
        return runtime_module.libraryDatabase(&self.runtime, self.library);
    }

    fn exec(self: *Rig, sql: [:0]const u8) !void {
        try (try self.libraryDatabase()).database.exec(sql);
    }

    fn scalar(self: *Rig, sql: [:0]const u8) !i64 {
        var statement = try (try self.libraryDatabase()).database.prepare(sql);
        defer statement.deinit();
        try testing.expectEqual(sqlite.Step.row, try statement.step());
        return statement.columnInt64(0);
    }

    fn generate(self: *Rig, request: runtime_module.DailyMixesRequest) !job.State {
        const job_handle = try self.runtime.startDailyMixes(self.library, request);
        return runtime_tests.awaitJob(&self.runtime, job_handle);
    }

    fn generateNow(self: *Rig) !void {
        try testing.expectEqual(job.State.succeeded, try self.generate(.{ .now_s = now_s, .force = true }));
    }

    fn mixes(self: *Rig) !DailyMixes {
        return self.runtime.libraryDailyMixes(self.library, now_s, 0);
    }

    fn entries(self: *Rig, mix_id: i64, output: *[runtime_module.max_daily_mix_entries]DailyMixEntry) ![]DailyMixEntry {
        const count = try self.runtime.libraryDailyMixEntries(self.library, mix_id, output);
        return output[0..count];
    }

    fn setMixCount(self: *Rig, count: runtime_module.DailyMixCount) !void {
        var settings = try self.runtime.libraryDiscoverySettings(self.library);
        settings.mix_count = count;
        try self.runtime.setLibraryDiscoverySettings(self.library, settings);
    }

    fn trackOf(self: *Rig, recording_id: i64) !struct { artist: i64, release: i64 } {
        var statement = try (try self.libraryDatabase()).database.prepare("SELECT artist_id, release_id FROM tracks WHERE recording_id = ?1;");
        defer statement.deinit();
        try statement.bindInt64(1, recording_id);
        try testing.expectEqual(sqlite.Step.row, try statement.step());
        return .{ .artist = statement.columnInt64(0), .release = statement.columnInt64(1) };
    }

    fn query(self: *Rig, sql: [:0]const u8, value: i64) !?i64 {
        var statement = try (try self.libraryDatabase()).database.prepare(sql);
        defer statement.deinit();
        try statement.bindInt64(1, value);
        if (try statement.step() != .row) return null;
        if (statement.columnIsNull(0)) return null;
        return statement.columnInt64(0);
    }
};

fn expectNames(snapshot: *const DailyMixes, names: []const []const u8) !void {
    try testing.expectEqual(names.len, snapshot.count);
    for (snapshot.items(), names, 0..) |*mix, name, ordinal| {
        try testing.expectEqualStrings(name, mix.name());
        try testing.expectEqual(@as(u8, @intCast(ordinal)), mix.ordinal);
    }
}

test "daily mixes are genre clusters most played first then rarely played, skipping a lone artist with few candidates" {
    var rig: Rig = undefined;
    try rig.init("file:orca-mixes-clusters?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.generateNow();

    const snapshot = try rig.mixes();
    try testing.expectEqual(runtime_module.DailyMixesState.ready, snapshot.state);
    try testing.expectEqual(@as(?i64, now_s), snapshot.generated_at);
    try testing.expectEqual(@as(?i64, @divFloor(now_s - 4 * 3600, day_s)), snapshot.local_day);
    try expectNames(&snapshot, &.{ "Big", "Hip Hop", "Jazz", "Rock", "Folk", "Rarely played" });
    const big = &snapshot.items()[0];
    try testing.expectEqual(runtime_module.DailyMixKind.genre, big.kind);
    try testing.expectEqual(@as(?i64, 8), big.genre_id);
    try testing.expectEqual(big_artist, big.mixArtists()[0].id);
    try testing.expectEqualStrings("Artist 14", big.mixArtists()[0].name());
    const hip_hop = &snapshot.items()[1];
    try testing.expect(hip_hop.artist_count >= 2 and hip_hop.artist_count <= 4);
    try testing.expect(hip_hop.cover_count >= 1 and hip_hop.cover_count <= 4);
    const rarely = &snapshot.items()[5];
    try testing.expectEqual(runtime_module.DailyMixKind.rarely_played, rarely.kind);
    try testing.expectEqual(@as(?i64, null), rarely.genre_id);
}

test "a genre mix holds 25 tracks within 60 to 90 minutes, 15 favorites, 6 rarely played and 4 never played" {
    var rig: Rig = undefined;
    try rig.init("file:orca-mixes-shape?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.generateNow();

    const snapshot = try rig.mixes();
    for (snapshot.items()[0 .. snapshot.count - 1]) |*mix| {
        try testing.expectEqual(@as(u32, 25), mix.entry_count);
        try testing.expect(mix.duration_ms >= 60 * 60_000 and mix.duration_ms <= 90 * 60_000);
    }
    const first = &snapshot.items()[0];
    try testing.expectEqual(@as(u32, 15), first.makeup.favorite);
    try testing.expectEqual(@as(u32, 6), first.makeup.rarely_played);
    try testing.expectEqual(@as(u32, 4), first.makeup.never_played);
}

test "a class with no candidates is filled from the classes furthest below their targets" {
    var rig: Rig = undefined;
    try rig.init("file:orca-mixes-shortfall?mode=memory&cache=shared");
    defer rig.deinit();
    try rig.exec(
        \\INSERT INTO recording_play_stats(recording_id, play_count, last_played_at)
        \\    SELECT id, 1, 1000 FROM recordings WHERE id NOT IN (SELECT recording_id FROM recording_play_stats);
    );

    try rig.generateNow();

    const snapshot = try rig.mixes();
    for (snapshot.items()[0 .. snapshot.count - 1]) |*mix| {
        try testing.expectEqual(@as(u32, 0), mix.makeup.never_played);
        try testing.expectEqual(@as(u32, 25), mix.makeup.favorite + mix.makeup.rarely_played);
        try testing.expect(mix.makeup.favorite >= 15 and mix.makeup.rarely_played >= 6);
    }
}

test "no recording repeats across the day's mixes and every mix keeps the artist and release spacing" {
    var rig: Rig = undefined;
    try rig.init("file:orca-mixes-unique?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.generateNow();

    const snapshot = try rig.mixes();
    var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
    defer seen.deinit(testing.allocator);
    for (snapshot.items()) |*mix| {
        var buffer: [runtime_module.max_daily_mix_entries]DailyMixEntry = undefined;
        const listed = try rig.entries(mix.id, &buffer);
        try testing.expectEqual(@as(usize, mix.entry_count), listed.len);
        var artists: [runtime_module.max_daily_mix_entries]i64 = undefined;
        var releases: [runtime_module.max_daily_mix_entries]i64 = undefined;
        for (listed, 0..) |entry, index| {
            try testing.expect(!seen.contains(entry.recording_id));
            try seen.put(testing.allocator, entry.recording_id, {});
            const track = try rig.trackOf(entry.recording_id);
            artists[index] = track.artist;
            releases[index] = track.release;
            if (index >= 2) try testing.expect(!(artists[index - 2] == track.artist and artists[index - 1] == track.artist));
            var same: usize = 0;
            for (releases[index -| 9 .. index + 1]) |release| {
                if (release == track.release) same += 1;
            }
            try testing.expect(same <= 2);
        }
    }
}

test "rarely played comes last and holds only recordings played before but not in the last year" {
    var rig: Rig = undefined;
    try rig.init("file:orca-mixes-rarely?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.generateNow();

    const snapshot = try rig.mixes();
    const rarely = &snapshot.items()[snapshot.count - 1];
    try testing.expectEqual(runtime_module.DailyMixKind.rarely_played, rarely.kind);
    try testing.expectEqualStrings("Rarely played", rarely.name());
    var old_in_genre_mixes: u32 = 0;
    for (snapshot.items()[0 .. snapshot.count - 1]) |*mix| {
        var genre_buffer: [runtime_module.max_daily_mix_entries]DailyMixEntry = undefined;
        for (try rig.entries(mix.id, &genre_buffer)) |entry| {
            if ((try rig.trackOf(entry.recording_id)).artist >= first_old_artist) old_in_genre_mixes += 1;
        }
    }
    try testing.expectEqual(old_artists - old_in_genre_mixes, rarely.entry_count);
    for (rarely.mixArtists()) |artist| try testing.expect(artist.id >= first_old_artist);
    var buffer: [runtime_module.max_daily_mix_entries]DailyMixEntry = undefined;
    for (try rig.entries(rarely.id, &buffer)) |entry| {
        const plays = try rig.query("SELECT play_count FROM recording_play_stats WHERE recording_id = ?1;", entry.recording_id);
        try testing.expectEqual(@as(?i64, 2), plays);
        const last = (try rig.query("SELECT last_played_at FROM recording_play_stats WHERE recording_id = ?1;", entry.recording_id)).?;
        try testing.expect(last <= now_s - 365 * day_s);
    }
}

test "every reason a mix entry gives is true of it" {
    var rig: Rig = undefined;
    try rig.init("file:orca-mixes-reasons?mode=memory&cache=shared");
    defer rig.deinit();
    try rig.exec("INSERT INTO feedback(recording_id, score, updated_at) VALUES (21, 1, 1), (22, 1, 1);");

    try rig.generateNow();

    const snapshot = try rig.mixes();
    var parts: usize = 0;
    for (snapshot.items()) |*mix| {
        var used: u32 = 0;
        var buffer: [runtime_module.max_daily_mix_entries]DailyMixEntry = undefined;
        for (try rig.entries(mix.id, &buffer)) |entry| {
            const track = try rig.trackOf(entry.recording_id);
            for ([_]?runtime_module.ReasonPart{ entry.reason.first, entry.reason.second }) |maybe| {
                const part = maybe orelse continue;
                parts += 1;
                used |= @as(u32, 1) << @intCast(@backingInt(part.kind));
                const plays = (try rig.query("SELECT play_count FROM recording_play_stats WHERE recording_id = ?1;", entry.recording_id)) orelse 0;
                switch (part.kind) {
                    .played => try testing.expect(plays >= 3 and part.a == plays),
                    .rarely_played => try testing.expect(plays >= 1 and plays <= 2 and part.a == plays),
                    .never_played => try testing.expectEqual(@as(i64, 0), plays),
                    .loved => try testing.expectEqual(@as(?i64, 1), try rig.query("SELECT score FROM feedback WHERE recording_id = ?1;", entry.recording_id)),
                    .same_artist => {
                        try testing.expectEqual(track.artist, part.a);
                        try testing.expect(mix.kind == .genre);
                    },
                    .shared_genre => {
                        const genre = try rig.query("SELECT genre_id FROM track_genres JOIN tracks ON tracks.id = track_genres.track_id WHERE tracks.recording_id = ?1;", entry.recording_id);
                        try testing.expectEqual(@as(?i64, part.a), genre);
                        try testing.expectEqual(mix.genre_id, genre);
                    },
                    .added, .related_artist, .often_after, .similar_sound => {},
                }
            }
        }
        try testing.expectEqual(used, mix.signals);
    }
    try testing.expect(parts > 0);
}

test "live, hated, not for me and recently played recordings are left out and counted" {
    var rig: Rig = undefined;
    try rig.init("file:orca-mixes-exclusions?mode=memory&cache=shared");
    defer rig.deinit();
    try rig.exec(
        \\INSERT INTO feedback(recording_id, score, updated_at) VALUES (1, -1, 1);
        \\INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist) VALUES (2, 2, 1799900000, 1000, 't', 'a');
        \\UPDATE recording_play_stats SET play_count = play_count + 1, last_played_at = 1799900000 WHERE recording_id = 2;
    );
    try rig.runtime.libraryNotForMe(rig.library, 3, now_s);

    try rig.generateNow();

    const snapshot = try rig.mixes();
    const hip_hop = &snapshot.items()[1];
    try testing.expectEqualStrings("Hip Hop", hip_hop.name());
    try testing.expectEqual(@as(u32, 1), hip_hop.left_out.hated);
    try testing.expectEqual(@as(u32, 1), hip_hop.left_out.not_for_me);
    try testing.expectEqual(@as(u32, 3), hip_hop.left_out.live);
    try testing.expectEqual(@as(u32, 1), hip_hop.left_out.recent);
    for (snapshot.items()) |*mix| {
        var buffer: [runtime_module.max_daily_mix_entries]DailyMixEntry = undefined;
        for (try rig.entries(mix.id, &buffer)) |entry| {
            try testing.expect(entry.recording_id > 3);
            try testing.expect((try rig.trackOf(entry.recording_id)).release != live_release);
        }
    }
}

test "below 30 listens or 3 local days the mixes are cleared and there is not enough history" {
    var rig: Rig = undefined;
    try rig.init("file:orca-mixes-threshold?mode=memory&cache=shared");
    defer rig.deinit();
    try rig.generateNow();
    try testing.expect((try rig.mixes()).count > 0);

    try rig.exec(
        \\DELETE FROM listens;
        \\INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist)
        \\    WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < 28)
        \\    SELECT 1 + i % 8, 1 + i % 8, 1800000000 - 86400 * (1 + i % 3) - i, 1000, 't', 'a' FROM n;
    );
    try rig.generateNow();
    var snapshot = try rig.mixes();
    try testing.expectEqual(runtime_module.DailyMixesState.not_enough_history, snapshot.state);
    try testing.expectEqual(@as(u8, 0), snapshot.count);
    try testing.expectEqual(@as(i64, 0), try rig.scalar("SELECT count(*) FROM daily_mixes;"));

    try rig.exec(
        \\DELETE FROM listens;
        \\INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist)
        \\    WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < 29)
        \\    SELECT 1 + i % 8, 1 + i % 8, 1800000000 - 86400 * (1 + i % 2) - i, 1000, 't', 'a' FROM n;
    );
    try rig.generateNow();
    snapshot = try rig.mixes();
    try testing.expectEqual(runtime_module.DailyMixesState.not_enough_history, snapshot.state);
    try testing.expectEqual(@as(u8, 0), snapshot.count);

    try rig.exec(
        \\DELETE FROM listens;
        \\INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist)
        \\    WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < 29)
        \\    SELECT 1 + i % 2 * 20 + i / 2 % 8, 1 + i % 2 * 20 + i / 2 % 8, 1800000000 - 86400 * (4 + i % 3) - i, 1000, 't', 'a' FROM n;
    );
    try testing.expectEqual(job.State.succeeded, try rig.generate(.{ .now_s = now_s }));
    snapshot = try rig.mixes();
    try testing.expectEqual(runtime_module.DailyMixesState.ready, snapshot.state);
    try testing.expectEqualStrings("Hip Hop", snapshot.items()[0].name());
}

test "mixes regenerate once a new mix day starts at 04:00 local time, or when forced" {
    var rig: Rig = undefined;
    try rig.init("file:orca-mixes-day?mode=memory&cache=shared");
    defer rig.deinit();
    const next_midnight = (@divFloor(now_s, day_s) + 1) * day_s;
    const generatedAt = struct {
        fn read(r: *Rig) !?i64 {
            return r.query("SELECT max(generated_at) FROM daily_mixes WHERE ?1 = ?1;", 0);
        }
    }.read;

    try testing.expectEqual(job.State.succeeded, try rig.generate(.{ .now_s = now_s }));
    try testing.expectEqual(@as(?i64, now_s), try generatedAt(&rig));

    try testing.expectEqual(job.State.succeeded, try rig.generate(.{ .now_s = now_s + 3600 }));
    try testing.expectEqual(@as(?i64, now_s), try generatedAt(&rig));

    try testing.expectEqual(job.State.succeeded, try rig.generate(.{ .now_s = next_midnight + 3 * 3600 + 3599 }));
    try testing.expectEqual(@as(?i64, now_s), try generatedAt(&rig));

    try testing.expectEqual(job.State.succeeded, try rig.generate(.{ .now_s = next_midnight + 2 * 3600, .utc_offset_s = 2 * 3600 }));
    try testing.expectEqual(@as(?i64, next_midnight + 2 * 3600), try generatedAt(&rig));

    try testing.expectEqual(job.State.succeeded, try rig.generate(.{ .now_s = next_midnight + 4 * 3600 }));
    try testing.expectEqual(@as(?i64, next_midnight + 2 * 3600), try generatedAt(&rig));

    try testing.expectEqual(job.State.succeeded, try rig.generate(.{ .now_s = next_midnight + 5 * 3600, .force = true }));
    try testing.expectEqual(@as(?i64, next_midnight + 5 * 3600), try generatedAt(&rig));

    try rig.exec("DELETE FROM daily_mixes; DELETE FROM library_settings WHERE key = 'mixes.generated_day';");
    try testing.expectEqual(job.State.succeeded, try rig.generate(.{ .now_s = next_midnight + 3 * 3600 }));
    try testing.expectEqual(@as(?i64, next_midnight + 3 * 3600), try generatedAt(&rig));
    try testing.expectEqual(job.State.succeeded, try rig.generate(.{ .now_s = next_midnight + 5 * 3600 }));
    try testing.expectEqual(@as(?i64, next_midnight + 5 * 3600), try generatedAt(&rig));
}

test "mixes.count makes six or four mixes, and off clears them" {
    var rig: Rig = undefined;
    try rig.init("file:orca-mixes-count?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.generateNow();
    try testing.expectEqual(@as(u8, 6), (try rig.mixes()).count);

    try rig.setMixCount(.four);
    try rig.generateNow();
    const four = try rig.mixes();
    try expectNames(&four, &.{ "Big", "Hip Hop", "Jazz", "Rarely played" });

    try rig.setMixCount(.off);
    try rig.generateNow();
    const off = try rig.mixes();
    try testing.expectEqual(runtime_module.DailyMixesState.off, off.state);
    try testing.expectEqual(@as(u8, 0), off.count);
    try testing.expectEqual(@as(i64, 0), try rig.scalar("SELECT count(*) FROM daily_mixes;"));

    try rig.setMixCount(.six);
    try testing.expectEqual(job.State.succeeded, try rig.generate(.{ .now_s = now_s }));
    try testing.expectEqual(@as(u8, 6), (try rig.mixes()).count);
}

test "a lone artist's cluster qualifies only with 40 candidates" {
    var rig: Rig = undefined;
    try rig.init("file:orca-mixes-lone?mode=memory&cache=shared");
    defer rig.deinit();
    try rig.exec("DELETE FROM tracks WHERE artist_id = 14 AND recording_id IN (SELECT recording_id FROM tracks WHERE artist_id = 14 ORDER BY id DESC LIMIT 6);");

    try rig.generateNow();

    try expectNames(&(try rig.mixes()), &.{ "Hip Hop", "Jazz", "Rock", "Folk", "Ambient", "Rarely played" });
}

test "not for me hides an entry at once and undo puts it back in place, and reset forgets every mark" {
    var rig: Rig = undefined;
    try rig.init("file:orca-mixes-not-for-me?mode=memory&cache=shared");
    defer rig.deinit();
    try rig.generateNow();
    const mix = (try rig.mixes()).items()[1];
    var before_buffer: [runtime_module.max_daily_mix_entries]DailyMixEntry = undefined;
    const before = try rig.entries(mix.id, &before_buffer);
    const hidden = before[3];

    try rig.runtime.libraryNotForMe(rig.library, hidden.track_id, now_s);

    var hidden_buffer: [runtime_module.max_daily_mix_entries]DailyMixEntry = undefined;
    const without = try rig.entries(mix.id, &hidden_buffer);
    try testing.expectEqual(before.len - 1, without.len);
    for (without) |entry| try testing.expect(entry.recording_id != hidden.recording_id);
    try testing.expectEqual(@as(u32, @intCast(before.len - 1)), (try rig.mixes()).items()[1].entry_count);
    try testing.expectEqual(mix.duration_ms - track_ms, (try rig.mixes()).items()[1].duration_ms);
    try testing.expectEqual(@as(?i64, now_s + 90 * day_s), try rig.query("SELECT expires_at FROM recommendation_feedback WHERE recording_id = ?1;", hidden.recording_id));

    try rig.runtime.libraryClearNotForMe(rig.library, hidden.track_id);

    var after_buffer: [runtime_module.max_daily_mix_entries]DailyMixEntry = undefined;
    const after = try rig.entries(mix.id, &after_buffer);
    try testing.expectEqual(before.len, after.len);
    for (before, after) |expected, actual| try testing.expectEqual(expected.recording_id, actual.recording_id);

    try rig.runtime.libraryNotForMe(rig.library, before[0].track_id, now_s);
    try rig.runtime.libraryNotForMe(rig.library, before[1].track_id, now_s);
    try rig.runtime.libraryResetRecommendations(rig.library);
    try testing.expectEqual(@as(i64, 0), try rig.scalar("SELECT count(*) FROM recommendation_feedback;"));
    try testing.expectError(error.TrackNotFound, rig.runtime.libraryNotForMe(rig.library, 999_999, now_s));
}

test "saving a mix makes a manual playlist of its shown tracks in order" {
    var rig: Rig = undefined;
    try rig.init("file:orca-mixes-save?mode=memory&cache=shared");
    defer rig.deinit();
    try rig.generateNow();
    const mix = (try rig.mixes()).items()[0];
    var buffer: [runtime_module.max_daily_mix_entries]DailyMixEntry = undefined;
    const listed = try rig.entries(mix.id, &buffer);
    try rig.runtime.libraryNotForMe(rig.library, listed[0].track_id, now_s);

    const playlist_id = try rig.runtime.librarySaveDailyMix(rig.library, mix.id, "Big Mix");

    const library_database = try rig.libraryDatabase();
    var statement = try library_database.database.prepare("SELECT recording_id FROM playlist_entries WHERE playlist_id = ?1 ORDER BY position;");
    defer statement.deinit();
    try statement.bindInt64(1, playlist_id);
    var index: usize = 1;
    while (try statement.step() == .row) : (index += 1) try testing.expectEqual(listed[index].recording_id, statement.columnInt64(0));
    try testing.expectEqual(listed.len, index);
    try testing.expectEqual(@as(?i64, 0), try rig.query("SELECT kind + creator FROM playlists WHERE id = ?1;", playlist_id));
    try testing.expectError(error.UnknownDailyMix, rig.runtime.librarySaveDailyMix(rig.library, 999_999, "Nothing"));
}

test "a generation that fails while writing keeps the previous mixes" {
    var rig: Rig = undefined;
    try rig.init("file:orca-mixes-failure?mode=memory&cache=shared");
    defer rig.deinit();
    try rig.generateNow();
    const before = try rig.mixes();
    try rig.exec(
        \\CREATE TEMP TRIGGER fail_mix_entries BEFORE INSERT ON daily_mix_entries
        \\BEGIN SELECT RAISE(ABORT, 'refused'); END;
    );

    try testing.expectEqual(job.State.failed, try rig.generate(.{ .now_s = now_s + 60, .force = true }));

    try rig.exec("DROP TRIGGER fail_mix_entries;");
    const after = try rig.mixes();
    try testing.expectEqual(before.count, after.count);
    try testing.expectEqual(before.generated_at, after.generated_at);
    for (before.items(), after.items()) |*expected, *actual| {
        try testing.expectEqual(expected.id, actual.id);
        try testing.expectEqual(expected.entry_count, actual.entry_count);
    }
}

test "generation reads the committed Library, not the write connection's open transaction" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try runtime_tests.absoluteTestPath(".zig-cache/tmp/{s}/mixes.db", .{temporary.sub_path});
    defer testing.allocator.free(path);
    const uri = try std.fmt.allocPrintSentinel(testing.allocator, "file:{s}", .{path}, 0);
    defer testing.allocator.free(uri);
    var rig: Rig = undefined;
    try rig.init(uri);
    defer rig.deinit();
    try rig.generateNow();
    const before = try rig.mixes();

    try rig.exec("BEGIN; DELETE FROM library_settings WHERE key = 'mixes.generated_day';");
    const state = try rig.generate(.{ .now_s = now_s + 60 });
    try rig.exec("ROLLBACK;");

    try testing.expectEqual(job.State.succeeded, state);
    try testing.expectEqual(before.generated_at, (try rig.mixes()).generated_at);
}

test "closing the library during generation joins the job" {
    var rig: Rig = undefined;
    try rig.init("file:orca-mixes-close?mode=memory&cache=shared");
    defer rig.deinit();

    const job_handle = try rig.runtime.startDailyMixes(rig.library, .{ .now_s = now_s, .force = true });
    try rig.runtime.destroyLibrary(rig.library);

    const state = (try rig.runtime.jobSnapshotSynced(job_handle)).state;
    try testing.expect(state == .succeeded or state == .cancelled);
}
