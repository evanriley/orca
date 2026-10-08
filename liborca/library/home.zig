//! Home page data: bounded read-only queries over the Library's listening
//! history and collection. See docs/discovery.md.
const std = @import("std");
const database = @import("../database/root.zig");
const optionalInt64 = @import("../database/columns.zig").optionalInt64;

const sqlite = database.sqlite;
const LibraryDatabase = database.LibraryDatabase;

/// The most items any Home list holds.
pub const max_items = 24;
pub const max_text_bytes = 256;
pub const week_days = 7;

const day_s = 86_400;
const rediscover_min_plays = 10;
const rediscover_quiet_days = 180;
const deep_cut_artist_days = 90;
const deep_cut_artists = 10;
const deep_cut_max_plays = 1;

/// When the page is read: Unix seconds, and the local offset east of UTC.
/// Local days are `now_s + utc_offset_s` counted in days from the epoch.
pub const LocalTime = struct {
    now_s: i64,
    utc_offset_s: i64 = 0,

    pub fn localDay(self: LocalTime) i64 {
        return @divFloor(self.now_s + self.utc_offset_s, day_s);
    }

    fn dayStart(self: LocalTime, local_day: i64) i64 {
        return local_day * day_s - self.utc_offset_s;
    }
};

/// A string cut to fit, never inside a UTF-8 sequence.
pub const Text = struct {
    buffer: [max_text_bytes]u8 = undefined,
    len: u16 = 0,

    pub fn slice(self: *const Text) []const u8 {
        return self.buffer[0..self.len];
    }

    fn set(self: *Text, text: []const u8) void {
        var length = @min(text.len, self.buffer.len);
        while (length > 0 and length < text.len and (text[length] & 0xC0) == 0x80) length -= 1;
        @memcpy(self.buffer[0..length], text[0..length]);
        self.len = @intCast(length);
    }
};

pub const TopArtist = struct {
    artist_id: i64,
    name: Text = .{},
    plays: u32,
};

/// A Release with the plays of its Recordings and when one was last played.
/// `plays` and `last_played_at` come from the Library's play history.
pub const PlayedRelease = struct {
    release_id: i64,
    title: Text = .{},
    /// The album Artist as written; the Artist of its first Track when empty.
    artist: Text = .{},
    plays: u32,
    last_played_at: i64,
};

pub const HomeTrack = struct {
    track_id: i64,
    artist_id: ?i64,
    release_id: ?i64,
    title: Text = .{},
    artist: Text = .{},
    release: Text = .{},
    /// Plays of the Track's Recording; 0 in `neverPlayed`.
    plays: u32,
    /// When the Track was added to the Library, in Unix seconds.
    added_at: i64,
};

pub const ListeningWeek = struct {
    /// The local day number (days since the Unix epoch) of `day_listened_ms[0]`;
    /// the last element is today.
    first_local_day: i64,
    /// Listening time per local day: the sum of `listens.listened_ms`.
    day_listened_ms: [week_days]u64 = @splat(0),
    listened_ms: u64 = 0,
    plays: u32 = 0,
    /// Distinct Artists and Releases of the Tracks played, counted by the
    /// first Track of each listened Recording.
    artists: u32 = 0,
    releases: u32 = 0,
    top_artist: ?TopArtist = null,
    /// The 7 local days before the 7 above.
    previous_listened_ms: u64 = 0,
    previous_plays: u32 = 0,
};

pub const Formats = struct {
    releases: u64,
    tracks: u64,
    /// The Tracks' summed duration, a Track with none counting as zero.
    duration_ms: u64,
    /// Tracks by the codec of their preferred file; the four sum to `tracks`.
    flac: u64,
    alac: u64,
    mp3: u64,
    /// Any other codec, and Tracks with no preferred file.
    other: u64,
};

pub const OnThisDay = struct {
    /// The most played Release among the listens of this local date one year
    /// ago (29 February falls back to the 28th), with that day's plays of it.
    top_release: ?PlayedRelease = null,
    /// Tracks added since 00:00 local time on Monday of this week.
    added_this_week: u32 = 0,
    /// Tracks added since 1 January, local time.
    added_this_year: u32 = 0,
    tracks: u32 = 0,
    /// Tracks whose Recording has no listen, and their share of `tracks`
    /// rounded down to a whole percent; 0 when there are no Tracks.
    never_played_tracks: u32 = 0,
    never_played_percent: u8 = 0,
};

pub const HistoryAge = struct {
    first_listen_at: ?i64 = null,
    /// Distinct local days with at least one listen.
    listen_days: u32 = 0,
    recording_enabled: bool = true,
};

fn firstTrackOf(comptime recording: []const u8) []const u8 {
    return "(SELECT min(first.id) FROM tracks AS first WHERE first.recording_id = " ++ recording ++ ")";
}

fn localDayOf(comptime column: []const u8, comptime offset: []const u8) []const u8 {
    return "((" ++ column ++ " + " ++ offset ++ " - ((" ++ column ++ " + " ++ offset ++ ") % 86400 + 86400) % 86400) / 86400)";
}

fn counted(value: i64) u32 {
    return std.math.cast(u32, value) orelse std.math.maxInt(u32);
}

fn total(value: i64) u64 {
    return @intCast(@max(value, 0));
}

const heard_tracks = "FROM listens JOIN tracks ON tracks.id = " ++ firstTrackOf("listens.recording_id") ++ "\n";
const in_window = "WHERE listens.started_at >= ?1 AND listens.started_at <= ?2\n";
const heard_in_window = heard_tracks ++ in_window;

fn topArtistsBetween(db: sqlite.Database, since_s: i64, until_s: i64, output: []TopArtist) !usize {
    const limit = @min(output.len, max_items);
    if (limit == 0) return 0;
    var statement = try db.prepare(
        "SELECT tracks.artist_id, artists.name, count(*) AS plays\n" ++ heard_tracks ++
            "JOIN artists ON artists.id = tracks.artist_id\n" ++ in_window ++
            "GROUP BY tracks.artist_id ORDER BY plays DESC, tracks.artist_id LIMIT ?3;",
    );
    defer statement.deinit();
    try statement.bindInt64(1, since_s);
    try statement.bindInt64(2, until_s);
    try statement.bindInt64(3, @intCast(limit));
    var count: usize = 0;
    while (try statement.step() == .row) : (count += 1) {
        output[count] = .{ .artist_id = statement.columnInt64(0), .plays = counted(statement.columnInt64(2)) };
        output[count].name.set(statement.columnText(1));
    }
    return count;
}

pub fn listeningWeek(library: *const LibraryDatabase, time: LocalTime) !ListeningWeek {
    const db = library.database;
    const today = time.localDay();
    const week_start_day = today - (week_days - 1);
    const week_start = time.dayStart(week_start_day);
    var result: ListeningWeek = .{ .first_local_day = week_start_day };

    var days = try db.prepare(
        "SELECT " ++ comptime localDayOf("started_at", "?3") ++ " AS local_day, sum(max(listened_ms, 0)), count(*)\n" ++
            "FROM listens WHERE started_at >= ?1 AND started_at <= ?2 GROUP BY local_day;",
    );
    defer days.deinit();
    try days.bindInt64(1, time.dayStart(week_start_day - week_days));
    try days.bindInt64(2, time.now_s);
    try days.bindInt64(3, time.utc_offset_s);
    while (try days.step() == .row) {
        const day = days.columnInt64(0);
        const listened_ms = total(days.columnInt64(1));
        const plays = counted(days.columnInt64(2));
        if (day >= week_start_day) {
            const index: usize = @intCast(@min(day - week_start_day, week_days - 1));
            result.day_listened_ms[index] += listened_ms;
            result.listened_ms += listened_ms;
            result.plays +|= plays;
        } else {
            result.previous_listened_ms += listened_ms;
            result.previous_plays +|= plays;
        }
    }

    var distinct = try db.prepare(
        "SELECT count(DISTINCT tracks.artist_id), count(DISTINCT tracks.release_id)\n" ++ heard_in_window ++ ";",
    );
    defer distinct.deinit();
    try distinct.bindInt64(1, week_start);
    try distinct.bindInt64(2, time.now_s);
    if (try distinct.step() == .row) {
        result.artists = counted(distinct.columnInt64(0));
        result.releases = counted(distinct.columnInt64(1));
    }

    var top: [1]TopArtist = undefined;
    if (try topArtistsBetween(db, week_start, time.now_s, &top) == 1) result.top_artist = top[0];
    return result;
}

const release_artist = "COALESCE(NULLIF(releases.album_artist, ''), (SELECT artists.name FROM artists WHERE artists.id = releases.album_artist_id), '')";

fn readPlayedReleases(statement: sqlite.Statement, output: []PlayedRelease) !usize {
    var count: usize = 0;
    while (count < output.len and try statement.step() == .row) : (count += 1) {
        output[count] = .{
            .release_id = statement.columnInt64(0),
            .plays = counted(statement.columnInt64(3)),
            .last_played_at = statement.columnInt64(4),
        };
        output[count].title.set(statement.columnText(1));
        output[count].artist.set(statement.columnText(2));
    }
    return count;
}

const played_releases =
    "SELECT releases.id, releases.title, " ++ release_artist ++ ", sum(stats.play_count), max(stats.last_played_at)\n" ++
    "FROM recording_play_stats AS stats\n" ++
    "JOIN tracks ON tracks.id = " ++ firstTrackOf("stats.recording_id") ++ "\n" ++
    "JOIN releases ON releases.id = tracks.release_id\n" ++
    "GROUP BY releases.id\n";

/// The Releases most recently played, latest first.
pub fn recentReleases(library: *const LibraryDatabase, time: LocalTime, output: []PlayedRelease) !usize {
    const limit = @min(output.len, max_items);
    var statement = try library.database.prepare(
        played_releases ++ "HAVING max(stats.last_played_at) <= ?1\n" ++
            "ORDER BY max(stats.last_played_at) DESC, releases.id LIMIT ?2;",
    );
    defer statement.deinit();
    try statement.bindInt64(1, time.now_s);
    try statement.bindInt64(2, @intCast(limit));
    return readPlayedReleases(statement, output[0..limit]);
}

/// Releases played at least 10 times and not in the last 180 days, most
/// played first, the longest unheard first among equals.
pub fn rediscover(library: *const LibraryDatabase, time: LocalTime, output: []PlayedRelease) !usize {
    const limit = @min(output.len, max_items);
    var statement = try library.database.prepare(
        played_releases ++ "HAVING sum(stats.play_count) >= " ++ std.fmt.comptimePrint("{d}", .{rediscover_min_plays}) ++
            " AND max(stats.last_played_at) <= ?1\n" ++
            "ORDER BY sum(stats.play_count) DESC, max(stats.last_played_at), releases.id LIMIT ?2;",
    );
    defer statement.deinit();
    try statement.bindInt64(1, time.now_s - rediscover_quiet_days * day_s);
    try statement.bindInt64(2, @intCast(limit));
    return readPlayedReleases(statement, output[0..limit]);
}

fn readTracks(statement: sqlite.Statement, output: []HomeTrack) !usize {
    var count: usize = 0;
    while (count < output.len and try statement.step() == .row) : (count += 1) {
        output[count] = .{
            .track_id = statement.columnInt64(0),
            .artist_id = optionalInt64(statement, 1),
            .release_id = optionalInt64(statement, 2),
            .plays = counted(statement.columnInt64(6)),
            .added_at = statement.columnInt64(7),
        };
        output[count].title.set(statement.columnText(3));
        output[count].artist.set(statement.columnText(4));
        output[count].release.set(statement.columnText(5));
    }
    return count;
}

const track_columns =
    "SELECT tracks.id, tracks.artist_id, tracks.release_id, tracks.title, tracks.artist,\n" ++
    "    COALESCE((SELECT releases.title FROM releases WHERE releases.id = tracks.release_id), tracks.album),\n";

/// Tracks whose Recording has no listen, newest added first.
pub fn neverPlayed(library: *const LibraryDatabase, output: []HomeTrack) !usize {
    const limit = @min(output.len, max_items);
    var statement = try library.database.prepare(
        track_columns ++ "    0, tracks.created_at\n" ++
            "FROM tracks WHERE NOT EXISTS (SELECT 1 FROM recording_play_stats AS stats WHERE stats.recording_id = tracks.recording_id)\n" ++
            "ORDER BY tracks.created_at DESC, tracks.id DESC LIMIT ?1;",
    );
    defer statement.deinit();
    try statement.bindInt64(1, @intCast(limit));
    return readTracks(statement, output[0..limit]);
}

/// Tracks played at most once by the 10 Artists most played in the last 90
/// days: unplayed first, then the most played Artist's.
pub fn deepCuts(library: *const LibraryDatabase, time: LocalTime, output: []HomeTrack) !usize {
    const limit = @min(output.len, max_items);
    var statement = try library.database.prepare(
        "WITH favorites AS (SELECT tracks.artist_id AS artist_id, count(*) AS plays\n" ++ heard_in_window ++
            "    AND tracks.artist_id IS NOT NULL\n" ++
            "GROUP BY tracks.artist_id ORDER BY plays DESC, tracks.artist_id LIMIT " ++
            std.fmt.comptimePrint("{d}", .{deep_cut_artists}) ++ ")\n" ++
            track_columns ++ "    COALESCE(stats.play_count, 0), tracks.created_at\n" ++
            "FROM favorites JOIN tracks ON tracks.artist_id = favorites.artist_id\n" ++
            "LEFT JOIN recording_play_stats AS stats ON stats.recording_id = tracks.recording_id\n" ++
            "WHERE COALESCE(stats.play_count, 0) <= " ++ std.fmt.comptimePrint("{d}", .{deep_cut_max_plays}) ++ "\n" ++
            "ORDER BY COALESCE(stats.play_count, 0), favorites.plays DESC, tracks.id LIMIT ?3;",
    );
    defer statement.deinit();
    try statement.bindInt64(1, time.now_s - deep_cut_artist_days * day_s);
    try statement.bindInt64(2, time.now_s);
    try statement.bindInt64(3, @intCast(limit));
    return readTracks(statement, output[0..limit]);
}

/// The Artists most played in the last `days` days, most played first.
pub fn topArtists(library: *const LibraryDatabase, time: LocalTime, days: u32, output: []TopArtist) !usize {
    return topArtistsBetween(library.database, time.now_s - @as(i64, days) * day_s, time.now_s, output);
}

pub fn formats(library: *const LibraryDatabase) !Formats {
    var statement = try library.database.prepare(
        \\SELECT (SELECT count(*) FROM releases), count(*), COALESCE(sum(max(tracks.duration_ms, 0)), 0),
        \\       COALESCE(sum(files.codec = 'flac'), 0), COALESCE(sum(files.codec = 'alac'), 0),
        \\       COALESCE(sum(files.codec = 'mp3'), 0)
        \\FROM tracks LEFT JOIN files ON files.id = tracks.preferred_file_id;
    );
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    var result: Formats = .{
        .releases = total(statement.columnInt64(0)),
        .tracks = total(statement.columnInt64(1)),
        .duration_ms = total(statement.columnInt64(2)),
        .flac = total(statement.columnInt64(3)),
        .alac = total(statement.columnInt64(4)),
        .mp3 = total(statement.columnInt64(5)),
        .other = 0,
    };
    result.other = result.tracks - result.flac - result.alac - result.mp3;
    return result;
}

const CivilDate = struct { year: i64, month: u8, day: u8 };

fn civilFromDays(days: i64) CivilDate {
    const shifted = days + 719_468;
    const era = @divFloor(shifted, 146_097);
    const day_of_era = shifted - era * 146_097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const shifted_month = @divFloor(5 * day_of_year + 2, 153);
    const month: i64 = if (shifted_month < 10) shifted_month + 3 else shifted_month - 9;
    return .{
        .year = year_of_era + era * 400 + @intFromBool(month <= 2),
        .month = @intCast(month),
        .day = @intCast(day_of_year - @divFloor(153 * shifted_month + 2, 5) + 1),
    };
}

fn daysFromCivil(date: CivilDate) i64 {
    const year = date.year - @intFromBool(date.month <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month: i64 = if (date.month > 2) date.month - 3 else date.month + 9;
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + date.day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

/// The local day number of the same date one year before `local_day`.
fn sameDayLastYear(local_day: i64) i64 {
    const today = civilFromDays(local_day);
    const leap_day = today.month == 2 and today.day == 29;
    return daysFromCivil(.{ .year = today.year - 1, .month = today.month, .day = if (leap_day) 28 else today.day });
}

fn mondayOf(local_day: i64) i64 {
    return local_day - @mod(local_day + 3, 7);
}

fn tracksAddedSince(db: sqlite.Database, since_s: i64, until_s: i64) !u32 {
    var statement = try db.prepare("SELECT count(*) FROM tracks WHERE created_at >= ?1 AND created_at <= ?2;");
    defer statement.deinit();
    try statement.bindInt64(1, since_s);
    try statement.bindInt64(2, until_s);
    if (try statement.step() != .row) return error.SqlFailed;
    return counted(statement.columnInt64(0));
}

pub fn onThisDay(library: *const LibraryDatabase, time: LocalTime) !OnThisDay {
    const db = library.database;
    const today = time.localDay();
    var result: OnThisDay = .{};

    const last_year = sameDayLastYear(today);
    var played = try db.prepare(
        "SELECT releases.id, releases.title, " ++ release_artist ++ ", count(*) AS plays, max(listens.started_at)\n" ++
            "FROM listens JOIN tracks ON tracks.id = " ++ comptime firstTrackOf("listens.recording_id") ++ "\n" ++
            "JOIN releases ON releases.id = tracks.release_id\n" ++
            "WHERE listens.started_at >= ?1 AND listens.started_at < ?2\n" ++
            "GROUP BY releases.id ORDER BY plays DESC, max(listens.started_at) DESC, releases.id LIMIT 1;",
    );
    defer played.deinit();
    try played.bindInt64(1, time.dayStart(last_year));
    try played.bindInt64(2, time.dayStart(last_year + 1));
    var top: [1]PlayedRelease = undefined;
    if (try readPlayedReleases(played, &top) == 1) result.top_release = top[0];

    const year_start_day = daysFromCivil(.{ .year = civilFromDays(today).year, .month = 1, .day = 1 });
    result.added_this_week = try tracksAddedSince(db, time.dayStart(mondayOf(today)), time.now_s);
    result.added_this_year = try tracksAddedSince(db, time.dayStart(year_start_day), time.now_s);

    var unplayed = try db.prepare(
        \\SELECT count(*), COALESCE(sum(NOT EXISTS (SELECT 1 FROM recording_play_stats AS stats
        \\                                         WHERE stats.recording_id = tracks.recording_id)), 0)
        \\FROM tracks;
    );
    defer unplayed.deinit();
    if (try unplayed.step() != .row) return error.SqlFailed;
    result.tracks = counted(unplayed.columnInt64(0));
    result.never_played_tracks = counted(unplayed.columnInt64(1));
    if (result.tracks > 0) {
        const percent = @as(u64, result.never_played_tracks) * 100 / result.tracks;
        result.never_played_percent = @intCast(percent);
    }
    return result;
}

pub fn historyAge(library: *const LibraryDatabase, time: LocalTime) !HistoryAge {
    var statement = try library.database.prepare(
        "SELECT min(started_at), count(DISTINCT " ++ comptime localDayOf("started_at", "?2") ++ ") FROM listens WHERE started_at <= ?1;",
    );
    defer statement.deinit();
    try statement.bindInt64(1, time.now_s);
    try statement.bindInt64(2, time.utc_offset_s);
    if (try statement.step() != .row) return error.SqlFailed;
    return .{
        .first_listen_at = optionalInt64(statement, 0),
        .listen_days = counted(statement.columnInt64(1)),
        .recording_enabled = try library.settings.flag(database.setting_listen_recording, true),
    };
}

const testing = std.testing;

const offset_s: i64 = 2 * 3600;
const today_day: i64 = 20_000;
const midnight_s = today_day * day_s - offset_s;
const noon_s = midnight_s + 12 * 3600;
const fixture_time: LocalTime = .{ .now_s = noon_s, .utc_offset_s = offset_s };

fn openHomeLibrary(comptime name: []const u8) !LibraryDatabase {
    return LibraryDatabase.open(testing.allocator, testing.io, "file:orca-test-home-" ++ name ++ "?mode=memory&cache=shared");
}

fn run(library: *LibraryDatabase, comptime format: []const u8, arguments: anytype) !void {
    var buffer: [1024]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(&buffer, format, arguments, 0));
}

fn addArtist(library: *LibraryDatabase, id: i64, name: []const u8) !void {
    try run(library, "INSERT INTO artists(id, name, key) VALUES ({d}, '{s}', '{s}');", .{ id, name, name });
}

fn addRelease(library: *LibraryDatabase, id: i64, title: []const u8, album_artist: []const u8) !void {
    try run(library, "INSERT INTO releases(id, title, album_artist, release_key) VALUES ({d}, '{s}', '{s}', 'key{d}');", .{ id, title, album_artist, id });
}

const TrackSpec = struct {
    id: i64,
    artist: i64,
    release: i64,
    created_at: i64 = 1000,
    codec: ?[]const u8 = "flac",
    duration_ms: i64 = 60_000,
};

fn addTrack(library: *LibraryDatabase, spec: TrackSpec) !void {
    try run(library, "INSERT INTO recordings(id, title) VALUES ({d}, 'r{d}');", .{ spec.id, spec.id });
    if (spec.codec) |codec| {
        try run(library, "INSERT INTO files(id, recording_id, codec) VALUES ({d}, {d}, '{s}');", .{ spec.id, spec.id, codec });
    }
    try run(
        library,
        "INSERT INTO tracks(id, recording_id, release_id, title, artist, artist_id, duration_ms, created_at)\n" ++
            "VALUES ({d}, {d}, {d}, 'Track {d}', 'Artist {d}', {d}, {d}, {d});",
        .{ spec.id, spec.id, spec.release, spec.id, spec.artist, spec.artist, spec.duration_ms, spec.created_at },
    );
    if (spec.codec != null) try run(library, "UPDATE tracks SET preferred_file_id = {d} WHERE id = {d};", .{ spec.id, spec.id });
}

fn listen(library: *LibraryDatabase, recording: i64, started_at: i64, listened_ms: i64) !void {
    try run(
        library,
        "INSERT INTO listens(recording_id, started_at, listened_ms, title, artist) VALUES ({d}, {d}, {d}, 't', 'a');",
        .{ recording, started_at, listened_ms },
    );
}

fn rebuildStats(library: *LibraryDatabase) !void {
    try library.database.exec(
        \\DELETE FROM recording_play_stats;
        \\INSERT INTO recording_play_stats(recording_id, play_count, last_played_at)
        \\    SELECT recording_id, count(*), max(started_at) FROM listens WHERE recording_id IS NOT NULL GROUP BY recording_id;
    );
}

test "the civil calendar converts days both ways and falls back from 29 February" {
    try testing.expectEqual(CivilDate{ .year = 1970, .month = 1, .day = 1 }, civilFromDays(0));
    try testing.expectEqual(CivilDate{ .year = 2024, .month = 2, .day = 29 }, civilFromDays(19_782));
    try testing.expectEqual(@as(i64, 19_782), daysFromCivil(.{ .year = 2024, .month = 2, .day = 29 }));
    try testing.expectEqual(daysFromCivil(.{ .year = 2023, .month = 2, .day = 28 }), sameDayLastYear(19_782));
    try testing.expectEqual(daysFromCivil(.{ .year = 2023, .month = 3, .day = 1 }), sameDayLastYear(daysFromCivil(.{ .year = 2024, .month = 3, .day = 1 })));
    try testing.expectEqual(daysFromCivil(.{ .year = 2024, .month = 2, .day = 26 }), mondayOf(19_782));
}

test "an empty library has empty lists and zero numbers" {
    var library = try openHomeLibrary("empty");
    defer library.close();
    var releases: [max_items]PlayedRelease = undefined;
    var tracks: [max_items]HomeTrack = undefined;
    var artists: [max_items]TopArtist = undefined;

    const week = try listeningWeek(&library, fixture_time);
    try testing.expectEqual(@as(u64, 0), week.listened_ms);
    try testing.expectEqual(@as(u32, 0), week.plays);
    try testing.expect(week.top_artist == null);
    try testing.expectEqual(@as(i64, today_day - 6), week.first_local_day);
    try testing.expectEqual(@as(usize, 0), try recentReleases(&library, fixture_time, &releases));
    try testing.expectEqual(@as(usize, 0), try rediscover(&library, fixture_time, &releases));
    try testing.expectEqual(@as(usize, 0), try neverPlayed(&library, &tracks));
    try testing.expectEqual(@as(usize, 0), try deepCuts(&library, fixture_time, &tracks));
    try testing.expectEqual(@as(usize, 0), try topArtists(&library, fixture_time, 30, &artists));
    const shape = try formats(&library);
    try testing.expectEqual(@as(u64, 0), shape.tracks + shape.other + shape.releases + shape.duration_ms);
    const day = try onThisDay(&library, fixture_time);
    try testing.expect(day.top_release == null);
    try testing.expectEqual(@as(u8, 0), day.never_played_percent);
    const age = try historyAge(&library, fixture_time);
    try testing.expectEqual(@as(?i64, null), age.first_listen_at);
    try testing.expectEqual(@as(u32, 0), age.listen_days);
    try testing.expect(age.recording_enabled);
}

test "the listening week buckets by local day and compares with the 7 days before" {
    var library = try openHomeLibrary("week");
    defer library.close();
    try addArtist(&library, 1, "Ann");
    try addArtist(&library, 2, "Bo");
    try addRelease(&library, 1, "One", "Ann");
    try addRelease(&library, 2, "Two", "Bo");
    try addTrack(&library, .{ .id = 1, .artist = 1, .release = 1 });
    try addTrack(&library, .{ .id = 2, .artist = 2, .release = 2 });
    try addTrack(&library, .{ .id = 3, .artist = 1, .release = 1 });

    try listen(&library, 1, midnight_s, 60_000);
    try listen(&library, 3, midnight_s + 3600, 30_000);
    try listen(&library, 2, midnight_s - 1, 120_000);
    try listen(&library, 1, midnight_s - 6 * day_s, 10_000);
    try listen(&library, 1, midnight_s - 6 * day_s - 1, 1_000);
    try listen(&library, 2, midnight_s - 13 * day_s, 2_000);
    try listen(&library, 2, midnight_s - 13 * day_s - 1, 4_000);
    try listen(&library, 2, noon_s + 1, 99_000);

    const week = try listeningWeek(&library, fixture_time);
    try testing.expectEqual([week_days]u64{ 10_000, 0, 0, 0, 0, 120_000, 90_000 }, week.day_listened_ms);
    try testing.expectEqual(@as(u64, 220_000), week.listened_ms);
    try testing.expectEqual(@as(u32, 4), week.plays);
    try testing.expectEqual(@as(u32, 2), week.artists);
    try testing.expectEqual(@as(u32, 2), week.releases);
    try testing.expectEqual(@as(i64, 1), week.top_artist.?.artist_id);
    try testing.expectEqualStrings("Ann", week.top_artist.?.name.slice());
    try testing.expectEqual(@as(u32, 3), week.top_artist.?.plays);
    try testing.expectEqual(@as(u64, 3_000), week.previous_listened_ms);
    try testing.expectEqual(@as(u32, 2), week.previous_plays);

    const west = try listeningWeek(&library, .{ .now_s = noon_s, .utc_offset_s = -offset_s });
    try testing.expectEqual(@as(i64, today_day - 6), west.first_local_day);
    try testing.expect(west.listened_ms != week.listened_ms);
}

test "the Release lists select by recent play, quiet period and bound" {
    var library = try openHomeLibrary("releases");
    defer library.close();
    try addArtist(&library, 1, "Ann");
    try addRelease(&library, 1, "Recent", "Ann");
    try addRelease(&library, 2, "Loved Long Ago", "");
    try run(&library, "UPDATE releases SET album_artist_id = 1 WHERE id = 2;", .{});
    try addRelease(&library, 3, "Nine Plays", "Ann");
    try addRelease(&library, 4, "Loved Recently", "Ann");
    try addTrack(&library, .{ .id = 1, .artist = 1, .release = 1 });
    try addTrack(&library, .{ .id = 2, .artist = 1, .release = 2 });
    try addTrack(&library, .{ .id = 3, .artist = 1, .release = 3 });
    try addTrack(&library, .{ .id = 4, .artist = 1, .release = 4 });
    const long_ago = noon_s - 200 * day_s;
    for (0..10) |index| try listen(&library, 2, long_ago + @as(i64, @intCast(index)) * 60, 1000);
    for (0..9) |index| try listen(&library, 3, long_ago + @as(i64, @intCast(index)) * 60, 1000);
    for (0..10) |index| try listen(&library, 4, noon_s - 179 * day_s + @as(i64, @intCast(index)) * 60, 1000);
    try listen(&library, 1, noon_s - 3600, 1000);
    try rebuildStats(&library);

    var releases: [max_items]PlayedRelease = undefined;
    const recent = try recentReleases(&library, fixture_time, &releases);
    try testing.expectEqual(@as(usize, 4), recent);
    try testing.expectEqualStrings("Recent", releases[0].title.slice());
    try testing.expectEqualStrings("Ann", releases[0].artist.slice());
    try testing.expectEqual(noon_s - 3600, releases[0].last_played_at);
    try testing.expectEqual(@as(i64, 4), releases[1].release_id);
    try testing.expectEqual(@as(usize, 2), try recentReleases(&library, fixture_time, releases[0..2]));

    const quiet = try rediscover(&library, fixture_time, &releases);
    try testing.expectEqual(@as(usize, 1), quiet);
    try testing.expectEqual(@as(i64, 2), releases[0].release_id);
    try testing.expectEqual(@as(u32, 10), releases[0].plays);
    try testing.expectEqualStrings("Ann", releases[0].artist.slice());
    try testing.expectEqual(long_ago + 9 * 60, releases[0].last_played_at);
}

test "a list holds at most 24 items" {
    var library = try openHomeLibrary("bound");
    defer library.close();
    try addArtist(&library, 1, "Ann");
    for (1..31) |index| {
        const id: i64 = @intCast(index);
        try addRelease(&library, id, "R", "Ann");
        try addTrack(&library, .{ .id = id, .artist = 1, .release = id, .created_at = 1000 + id });
        try listen(&library, id, noon_s - id * 60, 1000);
    }
    try rebuildStats(&library);
    var releases: [40]PlayedRelease = undefined;
    var artists: [40]TopArtist = undefined;
    try testing.expectEqual(@as(usize, max_items), try recentReleases(&library, fixture_time, &releases));
    try testing.expectEqual(@as(usize, 1), try topArtists(&library, fixture_time, 30, &artists));
    try run(&library, "DELETE FROM recording_play_stats;", .{});
    var tracks: [40]HomeTrack = undefined;
    try testing.expectEqual(@as(usize, max_items), try neverPlayed(&library, &tracks));
    try testing.expectEqual(@as(i64, 30), tracks[0].track_id);
}

test "never played Tracks are those whose Recording has no listen, newest added first" {
    var library = try openHomeLibrary("never");
    defer library.close();
    try addArtist(&library, 1, "Ann");
    try addRelease(&library, 1, "One", "Ann");
    try addTrack(&library, .{ .id = 1, .artist = 1, .release = 1, .created_at = 100 });
    try addTrack(&library, .{ .id = 2, .artist = 1, .release = 1, .created_at = 300 });
    try addTrack(&library, .{ .id = 3, .artist = 1, .release = 1, .created_at = 200 });
    try listen(&library, 3, noon_s - 10, 1000);
    try rebuildStats(&library);
    var tracks: [max_items]HomeTrack = undefined;
    try testing.expectEqual(@as(usize, 2), try neverPlayed(&library, &tracks));
    try testing.expectEqual(@as(i64, 2), tracks[0].track_id);
    try testing.expectEqual(@as(i64, 300), tracks[0].added_at);
    try testing.expectEqualStrings("One", tracks[0].release.slice());
    try testing.expectEqualStrings("Artist 1", tracks[0].artist.slice());
    try testing.expectEqual(@as(i64, 1), tracks[1].track_id);
    try testing.expectEqual(@as(?i64, 1), tracks[0].release_id);
}

test "deep cuts are Tracks played at most once by the 10 Artists most played in 90 days" {
    var library = try openHomeLibrary("deep");
    defer library.close();
    for (1..14) |index| {
        const artist: i64 = @intCast(index);
        var name: [8]u8 = undefined;
        const artist_name = try std.fmt.bufPrint(&name, "A{d}", .{artist});
        try addArtist(&library, artist, artist_name);
        try addRelease(&library, artist, artist_name, artist_name);
        for (0..3) |slot| try addTrack(&library, .{ .id = artist * 10 + @as(i64, @intCast(slot)), .artist = artist, .release = artist });
    }
    for (1..13) |index| {
        const artist: i64 = @intCast(index);
        for (0..(13 - index)) |play| try listen(&library, artist * 10, noon_s - 1000 - @as(i64, @intCast(play)) * 60, 1000);
    }
    for (0..20) |play| try listen(&library, 130, noon_s - 100 * day_s - @as(i64, @intCast(play)) * 60, 1000);
    try listen(&library, 31, noon_s - 120 * day_s, 1000);
    try listen(&library, 32, noon_s - 120 * day_s, 1000);
    try listen(&library, 32, noon_s - 121 * day_s, 1000);
    try rebuildStats(&library);

    var tracks: [max_items]HomeTrack = undefined;
    const count = try deepCuts(&library, fixture_time, &tracks);
    try testing.expectEqual(@as(usize, 19), count);
    for (tracks[0..count]) |track| {
        try testing.expect(track.artist_id.? <= 10);
        try testing.expect(track.plays <= 1);
        try testing.expect(@rem(track.track_id, 10) != 0 and track.track_id != 32);
    }
    try testing.expectEqual(@as(i64, 11), tracks[0].track_id);
    try testing.expectEqual(@as(u32, 0), tracks[0].plays);
    try testing.expectEqual(@as(i64, 31), tracks[count - 1].track_id);
    try testing.expectEqual(@as(u32, 1), tracks[count - 1].plays);

    var ranked: [max_items]TopArtist = undefined;
    try testing.expectEqual(@as(usize, 12), try topArtists(&library, fixture_time, 90, &ranked));
    try testing.expectEqual(@as(i64, 1), ranked[0].artist_id);
    try testing.expectEqual(@as(u32, 12), ranked[0].plays);
    try testing.expectEqual(@as(i64, 12), ranked[11].artist_id);
    try testing.expectEqual(@as(usize, 13), try topArtists(&library, fixture_time, 101, &ranked));
    try testing.expectEqual(@as(i64, 13), ranked[0].artist_id);
    try testing.expectEqual(@as(usize, 0), try topArtists(&library, fixture_time, 0, &ranked));
}

test "format counts sum to the Track count, with unknown codecs and missing files as Other" {
    var library = try openHomeLibrary("formats");
    defer library.close();
    try addArtist(&library, 1, "Ann");
    try addRelease(&library, 1, "One", "Ann");
    try addRelease(&library, 2, "Empty", "Ann");
    try addTrack(&library, .{ .id = 1, .artist = 1, .release = 1, .codec = "flac", .duration_ms = 1000 });
    try addTrack(&library, .{ .id = 2, .artist = 1, .release = 1, .codec = "flac", .duration_ms = 2000 });
    try addTrack(&library, .{ .id = 3, .artist = 1, .release = 1, .codec = "alac", .duration_ms = 4000 });
    try addTrack(&library, .{ .id = 4, .artist = 1, .release = 1, .codec = "mp3", .duration_ms = 8000 });
    try addTrack(&library, .{ .id = 5, .artist = 1, .release = 1, .codec = "aac" });
    try addTrack(&library, .{ .id = 6, .artist = 1, .release = 1, .codec = null });
    const shape = try formats(&library);
    const stats = try library.stats.stats();
    try testing.expectEqual(stats.tracks, shape.tracks);
    try testing.expectEqual(stats.releases, shape.releases);
    try testing.expectEqual(stats.total_duration_ms, shape.duration_ms);
    try testing.expectEqual(@as(u64, 2), shape.flac);
    try testing.expectEqual(@as(u64, 1), shape.alac);
    try testing.expectEqual(@as(u64, 1), shape.mp3);
    try testing.expectEqual(@as(u64, 2), shape.other);
    try testing.expectEqual(shape.tracks, shape.flac + shape.alac + shape.mp3 + shape.other);
}

test "on this day finds the most played Release of the date a year ago in local time" {
    var library = try openHomeLibrary("on-this-day");
    defer library.close();
    try addArtist(&library, 1, "Ann");
    try addRelease(&library, 1, "Once", "Ann");
    try addRelease(&library, 2, "Twice", "Ann");
    try addTrack(&library, .{ .id = 1, .artist = 1, .release = 1 });
    try addTrack(&library, .{ .id = 2, .artist = 1, .release = 2 });
    const last_year = sameDayLastYear(today_day);
    const start = last_year * day_s - offset_s;
    try listen(&library, 1, start - 1, 1000);
    try listen(&library, 1, start + 10, 1000);
    try listen(&library, 2, start + 20, 1000);
    try listen(&library, 2, start + 30, 1000);
    try listen(&library, 1, start + day_s, 1000);
    try rebuildStats(&library);

    const day = try onThisDay(&library, fixture_time);
    try testing.expectEqual(@as(i64, 2), day.top_release.?.release_id);
    try testing.expectEqual(@as(u32, 2), day.top_release.?.plays);
    try testing.expectEqual(start + 30, day.top_release.?.last_played_at);
    try testing.expect((try onThisDay(&library, .{ .now_s = noon_s + 5 * day_s, .utc_offset_s = offset_s })).top_release == null);
}

test "added this week starts on Monday, added this year on 1 January, in local time" {
    var library = try openHomeLibrary("added");
    defer library.close();
    try addArtist(&library, 1, "Ann");
    try addRelease(&library, 1, "One", "Ann");
    const monday = mondayOf(today_day);
    const january = daysFromCivil(.{ .year = civilFromDays(today_day).year, .month = 1, .day = 1 });
    const monday_start = monday * day_s - offset_s;
    const january_start = january * day_s - offset_s;
    try addTrack(&library, .{ .id = 1, .artist = 1, .release = 1, .created_at = monday_start });
    try addTrack(&library, .{ .id = 2, .artist = 1, .release = 1, .created_at = monday_start - 1 });
    try addTrack(&library, .{ .id = 3, .artist = 1, .release = 1, .created_at = january_start });
    try addTrack(&library, .{ .id = 4, .artist = 1, .release = 1, .created_at = january_start - 1 });
    try listen(&library, 1, noon_s, 1000);
    try rebuildStats(&library);

    const day = try onThisDay(&library, fixture_time);
    try testing.expectEqual(@as(u32, 1), day.added_this_week);
    try testing.expectEqual(@as(u32, 3), day.added_this_year);
    try testing.expectEqual(@as(u32, 4), day.tracks);
    try testing.expectEqual(@as(u32, 3), day.never_played_tracks);
    try testing.expectEqual(@as(u8, 75), day.never_played_percent);
}

test "the never-played share rounds down, so one played Track keeps it under 100" {
    var library = try openHomeLibrary("never-share");
    defer library.close();
    try addArtist(&library, 1, "Ann");
    try addRelease(&library, 1, "One", "Ann");
    var id: i64 = 1;
    while (id <= 201) : (id += 1) try addTrack(&library, .{ .id = id, .artist = 1, .release = 1 });
    try listen(&library, 1, noon_s, 1000);
    try rebuildStats(&library);

    const day = try onThisDay(&library, fixture_time);
    try testing.expectEqual(@as(u32, 200), day.never_played_tracks);
    try testing.expectEqual(@as(u8, 99), day.never_played_percent);
}

test "history age reports the first listen, distinct local days and the recording setting" {
    var library = try openHomeLibrary("age");
    defer library.close();
    try addArtist(&library, 1, "Ann");
    try addRelease(&library, 1, "One", "Ann");
    try addTrack(&library, .{ .id = 1, .artist = 1, .release = 1 });
    try listen(&library, 1, midnight_s - 5 * day_s, 1000);
    try listen(&library, 1, midnight_s - 5 * day_s + 100, 1000);
    try listen(&library, 1, midnight_s - 1, 1000);
    try listen(&library, 1, midnight_s, 1000);
    try listen(&library, 1, noon_s + 60, 1000);
    try library.settings.setFlag(database.setting_listen_recording, false);
    const age = try historyAge(&library, fixture_time);
    try testing.expectEqual(@as(?i64, midnight_s - 5 * day_s), age.first_listen_at);
    try testing.expectEqual(@as(u32, 3), age.listen_days);
    try testing.expect(!age.recording_enabled);
}
