//! Daily Mixes: up to six mixes a local day made from the Library's listening
//! history with the discovery scoring. See docs/discovery.md.
const std = @import("std");
const database = @import("../database/root.zig");
const discovery = @import("discovery.zig");
const home = @import("home.zig");
const scanner = @import("scanner.zig");
const optionalInt64 = @import("../database/columns.zig").optionalInt64;
const track_play_file = @import("../database/repository/tracks.zig").track_play_file;

const sqlite = database.sqlite;
const LibraryDatabase = database.LibraryDatabase;
const PickReason = discovery.PickReason;
const ReasonPart = discovery.ReasonPart;
const Ranked = discovery.Ranked;

pub const max_mixes = 6;
/// The most entries a mix of either kind holds.
pub const max_entries = 25;
pub const max_mix_artists = 4;
pub const max_covers = 4;
pub const max_name_bytes = 256;
/// How long "Not for me" leaves a Recording out.
pub const not_for_me_days = 90;

const day_s = 86_400;
/// A mix day starts at 04:00 local time.
const day_start_s = 4 * 3600;
const min_listens = 30;
const min_listen_days = 3;
const cluster_window_s = 30 * day_s;
const max_cluster_artists = 50;
const min_cluster_artists = 2;
const min_cluster_candidates = 40;
const rarely_played_after_s = 365 * day_s;
const stale_after_s = 180 * day_s;
const favorite_plays = 3;
const favorite_rating = 80;
const max_duration_ms = 90 * 60_000;
const rarely_played_name = "Rarely played";
const new_to_you_window_s = 90 * day_s;

pub const Kind = enum(u8) {
    /// Made for a cluster of Artists sharing a genre, named after it.
    genre = 0,
    /// Recordings played before but not in the last year.
    rarely_played = 1,
    /// Recordings on Releases from the decade most listened to in the last
    /// 30 days, or with the most Tracks; named after it, such as "2010s".
    decade = 2,
    /// Recordings on Releases none of whose Tracks were played, by Artists
    /// heard in the last 90 days.
    new_to_you = 3,
    /// Recordings played at most once by the 10 Artists most played in the
    /// last 90 days.
    deep_cuts = 4,
    /// Recordings in the top third of the Library's energy.
    upbeat = 5,
    /// Recordings in the bottom third of the Library's energy.
    wind_down = 6,
};

/// The theme kinds in the order a day's rotation walks them.
const theme_kinds = [_]Kind{ .decade, .new_to_you, .deep_cuts, .upbeat, .wind_down };

pub const State = enum(u8) {
    ready = 0,
    /// Fewer than 30 listens, or listens on fewer than 3 local days.
    not_enough_history = 1,
    /// `mixes.count` is 0.
    off = 2,
    not_generated = 3,
};

/// The mix day `now_s` falls in: local days counted from the Unix epoch,
/// each starting at 04:00.
pub fn mixDay(now_s: i64, utc_offset_s: i64) i64 {
    return @divFloor(now_s + utc_offset_s - day_start_s, day_s);
}

pub const Options = struct {
    now_s: i64,
    /// Seconds east of UTC.
    utc_offset_s: i64 = 0,
    /// Regenerates even when the stored mixes are from this mix day.
    force: bool = false,
};

pub const Outcome = enum {
    /// The stored mixes are from this mix day and were kept.
    kept,
    generated,
    /// `mixes.count` is 0; stored mixes were cleared.
    off,
    /// The history is below the threshold; stored mixes were cleared.
    not_enough_history,
    /// Nothing was written.
    cancelled,
};

pub const Generation = struct {
    outcome: Outcome,
    mixes: u32 = 0,
};

/// Recordings left out of one mix, by reason.
pub const LeftOutCounts = struct {
    recent: u32 = 0,
    not_for_me: u32 = 0,
    hated: u32 = 0,
    live: u32 = 0,
    /// Passed over because an earlier mix of the day holds them.
    other_mix: u32 = 0,
    /// Passed over for the Artist or Release spacing rules.
    diversity: u32 = 0,
};

/// How many entries of a mix fall in each class when it was made.
pub const Makeup = struct {
    /// Loved, rated 80 or more, or played 3 or more times in the last 180
    /// days.
    favorite: u32 = 0,
    /// Played once or twice, or not in the last 180 days.
    rarely_played: u32 = 0,
    never_played: u32 = 0,
};

pub const MixArtist = struct {
    id: i64,
    name_buffer: [max_name_bytes]u8 = undefined,
    name_len: u16 = 0,

    pub fn name(self: *const MixArtist) []const u8 {
        return self.name_buffer[0..self.name_len];
    }
};

pub const Mix = struct {
    id: i64,
    ordinal: u8,
    kind: Kind,
    /// Null for every kind but genre, and when the genre was deleted since.
    genre_id: ?i64,
    /// The first year of a decade mix's decade; null for other kinds.
    decade: ?i64 = null,
    name_buffer: [max_name_bytes]u8 = undefined,
    name_len: u16 = 0,
    /// The mix's Artists, most played first.
    artists: [max_mix_artists]MixArtist = undefined,
    artist_count: u8 = 0,
    /// Entries a client is shown, after Not for me.
    entry_count: u32 = 0,
    /// Summed over those entries; an unknown duration adds 0.
    duration_ms: u64 = 0,
    /// Bit `n` set when reason kind `n` names at least one entry.
    signals: u32 = 0,
    left_out: LeftOutCounts = .{},
    makeup: Makeup = .{},
    /// Distinct Releases of the first entries, for a cover mosaic.
    covers: [max_covers]i64 = undefined,
    cover_count: u8 = 0,

    pub fn name(self: *const Mix) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    pub fn mixArtists(self: *const Mix) []const MixArtist {
        return self.artists[0..self.artist_count];
    }

    pub fn coverReleases(self: *const Mix) []const i64 {
        return self.covers[0..self.cover_count];
    }
};

pub const DailyMixes = struct {
    state: State,
    /// Unix seconds of the stored mixes' generation; null when none are stored.
    generated_at: ?i64 = null,
    /// The mix day the stored mixes were made for.
    local_day: ?i64 = null,
    mixes: [max_mixes]Mix = undefined,
    count: u8 = 0,

    pub fn items(self: *const DailyMixes) []const Mix {
        return self.mixes[0..self.count];
    }
};

pub const Entry = struct {
    /// The lowest-id Track of the Recording with a present file.
    track_id: i64,
    recording_id: i64,
    duration_ms: ?i64,
    reason: PickReason,
};

/// Makes the day's mixes, or keeps the stored ones when they are from this
/// mix day and `force` is not set. A failed or cancelled run leaves the
/// stored mixes as they were.
pub fn generate(
    allocator: std.mem.Allocator,
    library: *LibraryDatabase,
    options: Options,
    cancellation: ?*const scanner.CancellationToken,
) !Generation {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reader = try library.openReader();
    defer reader.close();
    const source: discovery.Source = .onConnection(reader, library.write_lane);
    const settings = try discovery.readSettings(&source.settings);
    const day = mixDay(options.now_s, options.utc_offset_s);

    if (settings.mix_count == .off) {
        try store(library, &.{}, null, options.now_s);
        return .{ .outcome = .off };
    }
    if (!options.force) {
        const stored = try source.settings.integer(database.setting_mixes_generated_day, std.math.minInt(i64));
        if (stored >= day) return .{ .outcome = .kept };
    }
    if (!try enoughHistory(reader, options.now_s, options.utc_offset_s)) {
        try store(library, &.{}, null, options.now_s);
        return .{ .outcome = .not_enough_history };
    }

    const mixes = try makeMixes(arena, &source, options.now_s, day, settings, @backingInt(settings.mix_count), cancellation) orelse
        return .{ .outcome = .cancelled };
    try store(library, mixes, day, options.now_s);
    return .{ .outcome = .generated, .mixes = @intCast(mixes.len) };
}

/// The day's mixes, at most `mix_count`: genre mixes, then theme mixes, then
/// Rarely played. Null when cancelled.
pub fn makeMixes(
    arena: std.mem.Allocator,
    source: *const discovery.Source,
    now_s: i64,
    day: i64,
    settings: discovery.Settings,
    mix_count: usize,
    cancellation: ?*const scanner.CancellationToken,
) !?[]const Built {
    const day_seed = std.hash.Wyhash.hash(0, std.mem.asBytes(&day));
    const avoid_days: i64 = @backingInt(settings.avoid_days);
    var builder: Builder = .{ .arena = arena, .source = source, .now_s = now_s };
    const top = try loadTopArtists(arena, source.database, now_s);
    var themes: Themes = .{
        .arena = arena,
        .source = source,
        .now_s = now_s,
        .day_seed = day_seed,
        .avoid_days = avoid_days,
        .top_artists = top,
        .start = @intCast(@mod(day, theme_kinds.len)),
    };

    if (isCancelled(cancellation)) return null;
    const unplayed_since = now_s - rarely_played_after_s;
    const rarely_mix: discovery.MixFilter = .{ .now_s = now_s, .seed = mixSeed(day_seed, max_mixes), .avoid_days = 0 };
    const rarely = try discovery.rankRarelyPlayed(arena, source, rarely_mix, unplayed_since);
    const others = mix_count - @intFromBool(rarely.items.len > 0 and mix_count > 1);

    var reserved: usize = 0;
    if (others >= 2) {
        for (0..theme_kinds.len) |step| {
            if (isCancelled(cancellation)) return null;
            if (try themes.ranked(step) != null) {
                reserved = 1;
                break;
            }
        }
    }

    const clusters = try loadClusters(arena, source.database, top);
    for (clusters) |cluster| {
        if (builder.mixes.items.len == others - reserved) break;
        if (isCancelled(cancellation)) return null;
        const mix: discovery.MixFilter = .{ .now_s = now_s, .seed = mixSeed(day_seed, builder.mixes.items.len), .avoid_days = avoid_days };
        const ranking = try discovery.rankCluster(arena, source, .{ .genre_id = cluster.genre_id, .artists = cluster.artists }, mix);
        if (cluster.artists.len < min_cluster_artists and clusterCandidates(ranking.items, cluster.artists) < min_cluster_candidates) continue;
        const avoid_after = if (ranking.relaxed_recent or avoid_days == 0) null else now_s - avoid_days * day_s;
        const left_out = try discovery.leftOut(arena, source, .{ .artists = cluster.artists }, now_s, avoid_after);
        try builder.add(.genre, cluster.genre_id, null, cluster.name, ranking.items, left_out, cluster);
    }

    var rarely_built: ?Built = null;
    if (rarely.items.len > 0 and builder.mixes.items.len < mix_count) {
        if (isCancelled(cancellation)) return null;
        const rarely_left_out = try discovery.leftOut(arena, source, .{ .unplayed_since = unplayed_since }, now_s, null);
        const before = builder.mixes.items.len;
        try builder.add(.rarely_played, null, null, rarely_played_name, rarely.items, rarely_left_out, null);
        if (builder.mixes.items.len > before) rarely_built = builder.mixes.pop();
    }

    const room = mix_count - @intFromBool(rarely_built != null);
    for (0..theme_kinds.len) |step| {
        if (builder.mixes.items.len >= room) break;
        if (isCancelled(cancellation)) return null;
        const theme = try themes.ranked(step) orelse continue;
        const avoid_after = if (theme.ranking.relaxed_recent or avoid_days == 0) null else now_s - avoid_days * day_s;
        const left_out = try discovery.leftOut(arena, source, .{ .theme = theme.theme }, now_s, avoid_after);
        try builder.add(theme.kind, null, theme.decade, theme.name, theme.ranking.items, left_out, null);
    }

    if (isCancelled(cancellation)) return null;
    if (rarely_built) |built| try builder.mixes.append(arena, built);
    return builder.mixes.items;
}

const RankedTheme = struct {
    kind: Kind,
    theme: discovery.Theme,
    name: []const u8,
    decade: ?i64,
    ranking: discovery.Ranking,
};

/// The theme kinds of a day, ranked on first use. Step 0 is the day's
/// starting kind.
const Themes = struct {
    arena: std.mem.Allocator,
    source: *const discovery.Source,
    now_s: i64,
    day_seed: u64,
    avoid_days: i64,
    top_artists: []const ArtistPlays,
    start: usize,
    taste: ?discovery.Taste = null,
    done: [theme_kinds.len]bool = @splat(false),
    found: [theme_kinds.len]?RankedTheme = @splat(null),

    /// The theme at `step` of the rotation when it has at least
    /// `min_cluster_candidates` candidates.
    fn ranked(self: *Themes, step: usize) !?RankedTheme {
        const index = (self.start + step) % theme_kinds.len;
        if (!self.done[index]) {
            self.found[index] = try self.rank(theme_kinds[index]);
            self.done[index] = true;
        }
        return self.found[index];
    }

    fn rank(self: *Themes, kind: Kind) !?RankedTheme {
        const db = self.source.database;
        var decade: ?i64 = null;
        const theme: discovery.Theme, const name: []const u8 = switch (kind) {
            .decade => theme: {
                decade = try favoriteDecade(db, self.now_s) orelse return null;
                break :theme .{ .{ .decade = decade.? }, try std.fmt.allocPrint(self.arena, "{d}s", .{decade.?}) };
            },
            .new_to_you => .{ .{ .new_to_you = self.now_s - new_to_you_window_s }, "New to you" },
            .deep_cuts => theme: {
                const artists = try deepCutArtists(self.arena, db, self.now_s);
                if (artists.len == 0) return null;
                break :theme .{ .{ .deep_cuts = artists }, "Deep cuts" };
            },
            .upbeat => .{ .upbeat, "Upbeat" },
            .wind_down => .{ .wind_down, "Wind down" },
            .genre, .rarely_played => unreachable,
        };
        if (self.taste == null) {
            const artists = try self.arena.alloc(i64, self.top_artists.len);
            for (artists, self.top_artists) |*id, artist| id.* = artist.id;
            self.taste = try discovery.tasteOf(self.arena, self.source, artists, self.now_s);
        }
        const mix: discovery.MixFilter = .{
            .now_s = self.now_s,
            .seed = mixSeed(self.day_seed, max_mixes + 1 + @as(usize, @backingInt(kind))),
            .avoid_days = self.avoid_days,
        };
        const ranking = try discovery.rankTheme(self.arena, self.source, &self.taste.?, theme, mix);
        if (ranking.items.len < min_cluster_candidates) return null;
        return .{ .kind = kind, .theme = theme, .name = name, .decade = decade, .ranking = ranking };
    }
};

/// The decade most listened to in the last 30 days by the Release year of
/// each listen's Recording, else the decade with the most Tracks; null when
/// no Release has a year.
fn favoriteDecade(db: sqlite.Database, now_s: i64) !?i64 {
    var listened = try db.prepare(
        "SELECT year / 10 * 10 AS decade FROM (SELECT (SELECT " ++ discovery.year_of_track_release ++ " FROM tracks\n" ++
            "        LEFT JOIN releases AS track_release ON track_release.id = tracks.release_id\n" ++
            "        WHERE tracks.recording_id = listens.recording_id ORDER BY tracks.id LIMIT 1) AS year\n" ++
            "    FROM listens WHERE listens.started_at > ?1 - " ++ std.fmt.comptimePrint("{d}", .{cluster_window_s}) ++
            " AND listens.started_at <= ?1 AND listens.recording_id IS NOT NULL)\n" ++
            "WHERE year > 0 GROUP BY decade ORDER BY count(*) DESC, decade LIMIT 1;",
    );
    defer listened.deinit();
    try listened.bindInt64(1, now_s);
    if (try listened.step() == .row) return listened.columnInt64(0);

    var stocked = try db.prepare(
        "SELECT year / 10 * 10 AS decade FROM (SELECT " ++ discovery.year_of_track_release ++ " AS year FROM tracks\n" ++
            "    JOIN releases AS track_release ON track_release.id = tracks.release_id WHERE tracks.recording_id IS NOT NULL)\n" ++
            "WHERE year > 0 GROUP BY decade ORDER BY count(*) DESC, decade LIMIT 1;",
    );
    defer stocked.deinit();
    if (try stocked.step() == .row) return stocked.columnInt64(0);
    return null;
}

/// The Artists whose deep cuts Home shows.
fn deepCutArtists(arena: std.mem.Allocator, db: sqlite.Database, now_s: i64) ![]const i64 {
    var statement = try db.prepare(home.deep_cut_favorites ++ "SELECT artist_id FROM favorites ORDER BY plays DESC, artist_id;");
    defer statement.deinit();
    try statement.bindInt64(1, now_s - home.deep_cut_artist_days * day_s);
    try statement.bindInt64(2, now_s);
    var artists: std.ArrayList(i64) = .empty;
    while (try statement.step() == .row) try artists.append(arena, statement.columnInt64(0));
    return artists.items;
}

fn isCancelled(cancellation: ?*const scanner.CancellationToken) bool {
    const token = cancellation orelse return false;
    return token.isCancelled();
}

fn mixSeed(day_seed: u64, ordinal: usize) u64 {
    const value: u64 = ordinal;
    return std.hash.Wyhash.hash(day_seed, std.mem.asBytes(&value));
}

fn enoughHistory(db: sqlite.Database, now_s: i64, utc_offset_s: i64) !bool {
    var statement = try db.prepare(
        \\SELECT count(*), count(DISTINCT (started_at + ?2 - ((started_at + ?2) % 86400 + 86400) % 86400) / 86400)
        \\FROM listens WHERE started_at <= ?1;
    );
    defer statement.deinit();
    try statement.bindInt64(1, now_s);
    try statement.bindInt64(2, utc_offset_s);
    if (try statement.step() != .row) return false;
    return statement.columnInt64(0) >= min_listens and statement.columnInt64(1) >= min_listen_days;
}

const Cluster = struct {
    genre_id: i64,
    name: []const u8,
    plays: i64,
    artists: []const i64,
    artist_plays: []const i64,

    fn playsOf(self: *const Cluster, artist: i64) i64 {
        for (self.artists, self.artist_plays) |id, plays| if (id == artist) return plays;
        return 0;
    }
};

const ArtistPlays = struct { id: i64, plays: i64 };

/// The 50 Artists most played in the last 30 days, most played first.
fn loadTopArtists(arena: std.mem.Allocator, db: sqlite.Database, now_s: i64) ![]const ArtistPlays {
    var top = try db.prepare(
        "SELECT artist_id, count(*) AS plays FROM (SELECT (SELECT tracks.artist_id FROM tracks\n" ++
            "        WHERE tracks.recording_id = listens.recording_id ORDER BY tracks.id LIMIT 1) AS artist_id\n" ++
            "    FROM listens WHERE listens.started_at > ?1 - " ++ std.fmt.comptimePrint("{d}", .{cluster_window_s}) ++
            " AND listens.started_at <= ?1 AND listens.recording_id IS NOT NULL)\n" ++
            "WHERE artist_id IS NOT NULL GROUP BY artist_id ORDER BY plays DESC, artist_id LIMIT " ++
            std.fmt.comptimePrint("{d}", .{max_cluster_artists}) ++ ";",
    );
    defer top.deinit();
    try top.bindInt64(1, now_s);
    var played: std.ArrayList(ArtistPlays) = .empty;
    while (try top.step() == .row) try played.append(arena, .{ .id = top.columnInt64(0), .plays = top.columnInt64(1) });
    return played.items;
}

/// `played` grouped by each Artist's most common first genre, most played
/// group first.
fn loadClusters(arena: std.mem.Allocator, db: sqlite.Database, played: []const ArtistPlays) ![]Cluster {
    if (played.len == 0) return &.{};

    var ids: std.ArrayList(u8) = .empty;
    try ids.append(arena, '[');
    for (played, 0..) |artist, index| try ids.print(arena, "{s}{d}", .{ if (index == 0) "" else ",", artist.id });
    try ids.append(arena, ']');
    var genres = try db.prepare(
        \\SELECT tracks.artist_id, track_genres.genre_id, genres.name, count(*) AS uses FROM tracks
        \\JOIN track_genres ON track_genres.track_id = tracks.id AND track_genres.ordinal = 0
        \\JOIN genres ON genres.id = track_genres.genre_id
        \\WHERE tracks.artist_id IN (SELECT value FROM json_each(?1))
        \\GROUP BY tracks.artist_id, track_genres.genre_id
        \\ORDER BY tracks.artist_id, uses DESC, track_genres.genre_id;
    );
    defer genres.deinit();
    try genres.bindText(1, ids.items);
    const Genre = struct { id: i64, name: []const u8 };
    var genre_of: std.AutoHashMapUnmanaged(i64, Genre) = .empty;
    while (try genres.step() == .row) {
        const entry = try genre_of.getOrPut(arena, genres.columnInt64(0));
        if (entry.found_existing) continue;
        entry.value_ptr.* = .{ .id = genres.columnInt64(1), .name = try arena.dupe(u8, genres.columnText(2)) };
    }

    const Group = struct {
        genre: Genre,
        plays: i64 = 0,
        artists: std.ArrayList(i64) = .empty,
        artist_plays: std.ArrayList(i64) = .empty,
    };
    var groups: std.ArrayList(Group) = .empty;
    for (played) |artist| {
        const genre = genre_of.get(artist.id) orelse continue;
        const group = for (groups.items) |*group| {
            if (group.genre.id == genre.id) break group;
        } else added: {
            try groups.append(arena, .{ .genre = genre });
            break :added &groups.items[groups.items.len - 1];
        };
        group.plays += artist.plays;
        try group.artists.append(arena, artist.id);
        try group.artist_plays.append(arena, artist.plays);
    }
    const clusters = try arena.alloc(Cluster, groups.items.len);
    for (clusters, groups.items) |*cluster, group| cluster.* = .{
        .genre_id = group.genre.id,
        .name = group.genre.name,
        .plays = group.plays,
        .artists = group.artists.items,
        .artist_plays = group.artist_plays.items,
    };
    std.mem.sort(Cluster, clusters, {}, struct {
        fn lessThan(_: void, a: Cluster, b: Cluster) bool {
            if (a.plays != b.plays) return a.plays > b.plays;
            return a.genre_id < b.genre_id;
        }
    }.lessThan);
    return clusters;
}

fn clusterCandidates(items: []const Ranked, artists: []const i64) usize {
    var count: usize = 0;
    for (items) |item| {
        const artist = item.artist_id orelse continue;
        if (std.mem.indexOfScalar(i64, artists, artist) != null) count += 1;
    }
    return count;
}

const Class = enum(u2) { favorite, rarely_played, never_played };

fn classify(item: *const Ranked, now_s: i64) Class {
    if (item.loved or (item.rating orelse 0) >= favorite_rating) return .favorite;
    if (item.play_count == 0) return .never_played;
    if (item.play_count < favorite_plays) return .rarely_played;
    const last = item.last_played_at orelse return .rarely_played;
    return if (now_s - last > stale_after_s) .rarely_played else .favorite;
}

/// 60 % favorites, 25 % rarely played and 15 % never played of
/// `max_entries`, rounded so they sum to it.
const class_targets: [3]u32 = targets: {
    const favorite = max_entries * 60 / 100;
    const never = (max_entries * 15 + 50) / 100;
    break :targets .{ favorite, max_entries - favorite - never, never };
};

const BuiltEntry = struct {
    recording_id: i64,
    reason: PickReason,
};

const Built = struct {
    kind: Kind,
    genre_id: ?i64,
    decade: ?i64,
    name: []const u8,
    artists: []const i64,
    entries: []const BuiltEntry,
    signals: u32,
    left_out: LeftOutCounts,
    makeup: Makeup,
};

const Builder = struct {
    arena: std.mem.Allocator,
    source: *const discovery.Source,
    now_s: i64,
    used: std.AutoHashMapUnmanaged(i64, void) = .empty,
    mixes: std.ArrayList(Built) = .empty,

    const Mark = enum(u2) { open, chosen, other_mix, diversity };

    /// Picks at most `max_entries` and 90 minutes from `items`, best first.
    /// A genre, decade, Upbeat or Wind down mix takes from the class furthest
    /// below its target, and from the next class when that one has nothing
    /// left. A pick that would run
    /// past 90 minutes is passed over. Adds nothing when nothing qualifies.
    fn add(
        self: *Builder,
        kind: Kind,
        genre_id: ?i64,
        decade: ?i64,
        name: []const u8,
        items: []const Ranked,
        left_out: discovery.LeftOut,
        cluster: ?Cluster,
    ) !void {
        const durations = try self.trackDurations(items);
        const marks = try self.arena.alloc(Mark, items.len);
        @memset(marks, .open);
        const too_long = try self.arena.alloc(bool, items.len);
        @memset(too_long, false);
        const classes = try self.arena.alloc(Class, items.len);
        for (items, classes) |*item, *class| class.* = classify(item, self.now_s);

        var history: std.ArrayList(discovery.RecentPick) = .empty;
        var picked: std.ArrayList(BuiltEntry) = .empty;
        var counts: [3]u32 = @splat(0);
        var total_ms: i64 = 0;
        var signals: u32 = 0;
        while (picked.items.len < max_entries) {
            const chosen = for (classOrder(kind, counts)) |wanted| {
                if (self.next(items, classes, marks, too_long, durations, wanted, history.items, total_ms)) |index| break index;
            } else break;
            const item = &items[chosen];
            marks[chosen] = .chosen;
            try self.used.put(self.arena, item.recording_id, {});
            try history.append(self.arena, .{
                .recording_id = item.recording_id,
                .artist_id = item.artist_id,
                .release_id = item.release_id,
                .never_played = item.play_count == 0,
            });
            try picked.append(self.arena, .{ .recording_id = item.recording_id, .reason = item.reason });
            counts[@backingInt(classes[chosen])] += 1;
            total_ms += durations[chosen];
            for ([_]?ReasonPart{ item.reason.first, item.reason.second }) |part| if (part) |p| {
                signals |= @as(u32, 1) << @intCast(@backingInt(p.kind));
            };
        }
        if (picked.items.len == 0) return;

        var passed_over: [2]u32 = @splat(0);
        for (marks) |mark| switch (mark) {
            .other_mix => passed_over[0] += 1,
            .diversity => passed_over[1] += 1,
            .open, .chosen => {},
        };
        try self.mixes.append(self.arena, .{
            .kind = kind,
            .genre_id = genre_id,
            .decade = decade,
            .name = name,
            .artists = try self.topArtists(items, marks, if (cluster) |*c| c else null),
            .entries = picked.items,
            .signals = signals,
            .left_out = .{
                .recent = left_out.recent,
                .not_for_me = left_out.not_for_me,
                .hated = left_out.hated,
                .live = left_out.live,
                .other_mix = passed_over[0],
                .diversity = passed_over[1],
            },
            .makeup = .{ .favorite = counts[0], .rarely_played = counts[1], .never_played = counts[2] },
        });
    }

    /// The classes to take the next pick from: the one furthest below its
    /// target first, ties in class order. Rarely played, New to you and
    /// Deep cuts, whose Recordings are mostly of one class, take from any.
    fn classOrder(kind: Kind, counts: [3]u32) [3]?Class {
        switch (kind) {
            .rarely_played, .new_to_you, .deep_cuts => return .{ null, null, null },
            .genre, .decade, .upbeat, .wind_down => {},
        }
        var order: [3]?Class = .{ .favorite, .rarely_played, .never_played };
        std.mem.sort(?Class, &order, counts, struct {
            fn lessThan(taken: [3]u32, a: ?Class, b: ?Class) bool {
                const index_a = @backingInt(a.?);
                const index_b = @backingInt(b.?);
                const deficit_a = @as(i64, class_targets[index_a]) - taken[index_a];
                const deficit_b = @as(i64, class_targets[index_b]) - taken[index_b];
                if (deficit_a != deficit_b) return deficit_a > deficit_b;
                return index_a < index_b;
            }
        }.lessThan);
        return order;
    }

    /// The best open item of `wanted`, or of any class when null. Items it
    /// passes over are marked with why.
    fn next(
        self: *Builder,
        items: []const Ranked,
        classes: []const Class,
        marks: []Mark,
        too_long: []bool,
        durations: []const i64,
        wanted: ?Class,
        history: []const discovery.RecentPick,
        total_ms: i64,
    ) ?usize {
        for (items, 0..) |item, index| {
            if (marks[index] == .chosen or marks[index] == .other_mix or too_long[index]) continue;
            if (wanted) |class| if (classes[index] != class) continue;
            if (self.used.contains(item.recording_id)) {
                marks[index] = .other_mix;
                continue;
            }
            if (total_ms + durations[index] > max_duration_ms) {
                too_long[index] = true;
                continue;
            }
            if (!discovery.diverse(history, item.artist_id, item.release_id)) {
                marks[index] = .diversity;
                continue;
            }
            return index;
        }
        return null;
    }

    fn trackDurations(self: *Builder, items: []const Ranked) ![]i64 {
        const durations = try self.arena.alloc(i64, items.len);
        @memset(durations, 0);
        if (items.len == 0) return durations;
        var ids: std.ArrayList(u8) = .empty;
        try ids.append(self.arena, '[');
        var index_of: std.AutoHashMapUnmanaged(i64, usize) = .empty;
        for (items, 0..) |item, index| {
            try ids.print(self.arena, "{s}{d}", .{ if (index == 0) "" else ",", item.track_id });
            try index_of.put(self.arena, item.track_id, index);
        }
        try ids.append(self.arena, ']');
        var statement = try self.source.database.prepare(
            "SELECT id, duration_ms FROM tracks WHERE id IN (SELECT value FROM json_each(?1)) AND duration_ms > 0;",
        );
        defer statement.deinit();
        try statement.bindText(1, ids.items);
        while (try statement.step() == .row) {
            const index = index_of.get(statement.columnInt64(0)) orelse continue;
            durations[index] = statement.columnInt64(1);
        }
        return durations;
    }

    /// The Artists of the chosen entries, at most `max_mix_artists`: for a
    /// genre mix the most played in the last 30 days, for other kinds the
    /// most played overall, then the most entries.
    fn topArtists(self: *Builder, items: []const Ranked, marks: []const Mark, cluster: ?*const Cluster) ![]const i64 {
        const Tally = struct { id: i64, plays: i64, entries: u32 };
        var tallies: std.ArrayList(Tally) = .empty;
        for (items, marks) |item, mark| {
            if (mark != .chosen) continue;
            const artist = item.artist_id orelse continue;
            const tally = for (tallies.items) |*tally| {
                if (tally.id == artist) break tally;
            } else added: {
                const plays = if (cluster) |c| c.playsOf(artist) else 0;
                try tallies.append(self.arena, .{ .id = artist, .plays = plays, .entries = 0 });
                break :added &tallies.items[tallies.items.len - 1];
            };
            tally.entries += 1;
            if (cluster == null) tally.plays += item.play_count;
        }
        std.mem.sort(Tally, tallies.items, {}, struct {
            fn lessThan(_: void, a: Tally, b: Tally) bool {
                if (a.plays != b.plays) return a.plays > b.plays;
                if (a.entries != b.entries) return a.entries > b.entries;
                return a.id < b.id;
            }
        }.lessThan);
        const kept = tallies.items[0..@min(tallies.items.len, max_mix_artists)];
        const ids = try self.arena.alloc(i64, kept.len);
        for (kept, ids) |tally, *id| id.* = tally.id;
        return ids;
    }
};

/// Replaces every stored mix with `mixes` in one transaction. A null `day`
/// forgets the mix day, so the next run makes mixes again.
fn store(library: *LibraryDatabase, mixes: []const Built, day: ?i64, now_s: i64) !void {
    const db = library.database;
    library.write_lane.acquire();
    defer library.write_lane.release();
    try db.exec("BEGIN IMMEDIATE;");
    errdefer db.exec("ROLLBACK;") catch {};
    try db.exec("DELETE FROM daily_mixes;");

    var insert_mix = try db.prepare(
        \\INSERT INTO daily_mixes(ordinal, kind, genre_id, name, local_day, generated_at, signals,
        \\    left_out_recent, left_out_not_for_me, left_out_hated, left_out_live, left_out_other_mix, left_out_diversity,
        \\    favorite_count, rarely_played_count, never_played_count, decade)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17) RETURNING id;
    );
    defer insert_mix.deinit();
    var insert_artist = try db.prepare("INSERT INTO daily_mix_artists(mix_id, position, artist_id) VALUES (?1, ?2, ?3);");
    defer insert_artist.deinit();
    var insert_entry = try db.prepare(
        \\INSERT INTO daily_mix_entries(mix_id, position, recording_id, reason1_kind, reason1_a, reason1_b,
        \\    reason2_kind, reason2_a, reason2_b) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);
    );
    defer insert_entry.deinit();

    for (mixes, 0..) |mix, ordinal| {
        const values = [_]i64{
            @intCast(ordinal),       @backingInt(mix.kind), 0,                        0,
            day orelse 0,            now_s,                 mix.signals,              mix.left_out.recent,
            mix.left_out.not_for_me, mix.left_out.hated,    mix.left_out.live,        mix.left_out.other_mix,
            mix.left_out.diversity,  mix.makeup.favorite,   mix.makeup.rarely_played, mix.makeup.never_played,
        };
        for (values, 1..) |value, column| switch (column) {
            3 => try insert_mix.bindOptionalInt64(3, mix.genre_id),
            4 => try insert_mix.bindText(4, mix.name),
            else => try insert_mix.bindInt64(@intCast(column), value),
        };
        try insert_mix.bindOptionalInt64(17, mix.decade);
        if (try insert_mix.step() != .row) return error.SqlFailed;
        const mix_id = insert_mix.columnInt64(0);
        if (try insert_mix.step() != .done) return error.SqlFailed;
        try insert_mix.reset();

        for (mix.artists, 0..) |artist, position| {
            try insert_artist.bindInt64(1, mix_id);
            try insert_artist.bindInt64(2, @intCast(position));
            try insert_artist.bindInt64(3, artist);
            if (try insert_artist.step() != .done) return error.SqlFailed;
            try insert_artist.reset();
        }
        for (mix.entries, 0..) |entry, position| {
            try insert_entry.bindInt64(1, mix_id);
            try insert_entry.bindInt64(2, @intCast(position));
            try insert_entry.bindInt64(3, entry.recording_id);
            try bindReason(insert_entry, 4, entry.reason.first);
            try bindReason(insert_entry, 7, entry.reason.second);
            if (try insert_entry.step() != .done) return error.SqlFailed;
            try insert_entry.reset();
        }
    }

    var day_setting = try db.prepare(if (day == null)
        "DELETE FROM library_settings WHERE key = ?1 AND ?2 IS NULL;"
    else
        "INSERT INTO library_settings(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value;");
    defer day_setting.deinit();
    var buffer: [24]u8 = undefined;
    try day_setting.bindText(1, database.setting_mixes_generated_day);
    if (day) |value| {
        try day_setting.bindText(2, std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable);
    } else try day_setting.bindOptionalInt64(2, null);
    if (try day_setting.step() != .done) return error.SqlFailed;
    try db.exec("COMMIT;");
}

fn bindReason(statement: sqlite.Statement, column: c_int, part: ?ReasonPart) !void {
    const found = part orelse {
        try statement.bindOptionalInt64(column, null);
        try statement.bindInt64(column + 1, 0);
        try statement.bindInt64(column + 2, 0);
        return;
    };
    try statement.bindInt64(column, @backingInt(found.kind));
    try statement.bindInt64(column + 1, found.a);
    try statement.bindInt64(column + 2, found.b);
}

const visible_entries =
    "WITH entry AS (SELECT daily_mix_entries.*, (SELECT min(tracks.id) FROM tracks\n" ++
    "        WHERE tracks.recording_id = daily_mix_entries.recording_id\n" ++
    "          AND EXISTS (SELECT 1 FROM locations WHERE locations.file_id = " ++ track_play_file ++ " AND locations.state = 'present')) AS track_id\n" ++
    "    FROM daily_mix_entries WHERE mix_id = ?1\n" ++
    "      AND NOT EXISTS (SELECT 1 FROM recommendation_feedback AS not_for_me\n" ++
    "          WHERE not_for_me.recording_id = daily_mix_entries.recording_id AND not_for_me.expires_at > ?2))\n";

/// The stored mixes with what a client shows of them at `now_s`.
pub fn read(library: *const LibraryDatabase, now_s: i64, utc_offset_s: i64) !DailyMixes {
    const db = library.database;
    const settings = try discovery.readSettings(&library.settings);
    if (settings.mix_count == .off) return .{ .state = .off };

    var result: DailyMixes = .{ .state = .not_generated };
    var mixes = try db.prepare(
        \\SELECT id, ordinal, kind, genre_id, name, local_day, generated_at, signals,
        \\    left_out_recent, left_out_not_for_me, left_out_hated, left_out_live, left_out_other_mix, left_out_diversity,
        \\    favorite_count, rarely_played_count, never_played_count, decade
        \\FROM daily_mixes ORDER BY ordinal LIMIT 6;
    );
    defer mixes.deinit();
    while (try mixes.step() == .row) {
        const mix = &result.mixes[result.count];
        mix.* = .{
            .id = mixes.columnInt64(0),
            .ordinal = @intCast(mixes.columnInt64(1)),
            .kind = std.enums.fromInt(Kind, @as(u8, @intCast(mixes.columnInt64(2)))) orelse .genre,
            .genre_id = optionalInt64(mixes, 3),
            .decade = optionalInt64(mixes, 17),
            .signals = @intCast(mixes.columnInt64(7)),
            .left_out = .{
                .recent = countAt(mixes, 8),
                .not_for_me = countAt(mixes, 9),
                .hated = countAt(mixes, 10),
                .live = countAt(mixes, 11),
                .other_mix = countAt(mixes, 12),
                .diversity = countAt(mixes, 13),
            },
            .makeup = .{ .favorite = countAt(mixes, 14), .rarely_played = countAt(mixes, 15), .never_played = countAt(mixes, 16) },
        };
        mix.name_len = copyName(&mix.name_buffer, mixes.columnText(4));
        result.local_day = mixes.columnInt64(5);
        result.generated_at = mixes.columnInt64(6);
        result.count += 1;
    }
    for (result.mixes[0..result.count]) |*mix| try readMixDetails(db, mix, now_s);

    if (result.count > 0) {
        result.state = .ready;
    } else if (!try enoughHistory(db, now_s, utc_offset_s)) {
        result.state = .not_enough_history;
    } else if (try library.settings.integer(database.setting_mixes_generated_day, std.math.minInt(i64)) == mixDay(now_s, utc_offset_s)) {
        result.state = .ready;
    }
    return result;
}

fn countAt(statement: sqlite.Statement, column: c_int) u32 {
    return std.math.cast(u32, statement.columnInt64(column)) orelse std.math.maxInt(u32);
}

fn copyName(buffer: *[max_name_bytes]u8, text: []const u8) u16 {
    var length = @min(text.len, buffer.len);
    while (length > 0 and length < text.len and (text[length] & 0xC0) == 0x80) length -= 1;
    @memcpy(buffer[0..length], text[0..length]);
    return @intCast(length);
}

fn readMixDetails(db: sqlite.Database, mix: *Mix, now_s: i64) !void {
    var artists = try db.prepare(
        \\SELECT daily_mix_artists.artist_id, artists.name FROM daily_mix_artists
        \\JOIN artists ON artists.id = daily_mix_artists.artist_id
        \\WHERE daily_mix_artists.mix_id = ?1 ORDER BY daily_mix_artists.position LIMIT 4;
    );
    defer artists.deinit();
    try artists.bindInt64(1, mix.id);
    while (try artists.step() == .row) {
        const artist = &mix.artists[mix.artist_count];
        artist.* = .{ .id = artists.columnInt64(0) };
        artist.name_len = copyName(&artist.name_buffer, artists.columnText(1));
        mix.artist_count += 1;
    }

    var totals = try db.prepare(visible_entries ++
        "SELECT count(*), COALESCE(sum(MAX(COALESCE(tracks.duration_ms, 0), 0)), 0)\n" ++
        "FROM entry JOIN tracks ON tracks.id = entry.track_id;");
    defer totals.deinit();
    try totals.bindInt64(1, mix.id);
    try totals.bindInt64(2, now_s);
    if (try totals.step() == .row) {
        mix.entry_count = @intCast(totals.columnInt64(0));
        mix.duration_ms = @intCast(totals.columnInt64(1));
    }

    var covers = try db.prepare(visible_entries ++
        "SELECT tracks.release_id FROM entry JOIN tracks ON tracks.id = entry.track_id\n" ++
        "WHERE tracks.release_id IS NOT NULL GROUP BY tracks.release_id ORDER BY min(entry.position) LIMIT 4;");
    defer covers.deinit();
    try covers.bindInt64(1, mix.id);
    try covers.bindInt64(2, now_s);
    while (try covers.step() == .row) {
        mix.covers[mix.cover_count] = covers.columnInt64(0);
        mix.cover_count += 1;
    }
}

/// Writes the mix's entries in order, leaving out Recordings marked Not for
/// me at `now_s` and those with no present file, into `output`, which holds
/// `max_entries`. Returns how many were written.
pub fn entries(library: *const LibraryDatabase, mix_id: i64, now_s: i64, output: []Entry) !usize {
    const db = library.database;
    var exists = try db.prepare("SELECT 1 FROM daily_mixes WHERE id = ?1;");
    defer exists.deinit();
    try exists.bindInt64(1, mix_id);
    if (try exists.step() != .row) return error.UnknownDailyMix;

    var statement = try db.prepare(visible_entries ++
        "SELECT entry.track_id, entry.recording_id, tracks.duration_ms, reason1_kind, reason1_a, reason1_b,\n" ++
        "    reason2_kind, reason2_a, reason2_b\n" ++
        "FROM entry JOIN tracks ON tracks.id = entry.track_id ORDER BY entry.position LIMIT ?3;");
    defer statement.deinit();
    try statement.bindInt64(1, mix_id);
    try statement.bindInt64(2, now_s);
    try statement.bindInt64(3, @intCast(@min(output.len, max_entries)));
    var written: usize = 0;
    while (try statement.step() == .row) : (written += 1) output[written] = .{
        .track_id = statement.columnInt64(0),
        .recording_id = statement.columnInt64(1),
        .duration_ms = optionalInt64(statement, 2),
        .reason = .{ .first = reasonAt(statement, 3), .second = reasonAt(statement, 6) },
    };
    return written;
}

fn reasonAt(statement: sqlite.Statement, column: c_int) ?ReasonPart {
    const raw = optionalInt64(statement, column) orelse return null;
    const kind = std.enums.fromInt(discovery.ReasonKind, std.math.cast(u8, raw) orelse return null) orelse return null;
    return .{ .kind = kind, .a = statement.columnInt64(column + 1), .b = statement.columnInt64(column + 2) };
}

/// Leaves the Track's Recording out of Radio and Daily Mixes for
/// `not_for_me_days` from `now_s`, or extends that.
pub fn notForMe(library: *LibraryDatabase, track_id: i64, now_s: i64) !void {
    const recording_id = try trackRecording(library.database, track_id);
    library.write_lane.acquire();
    defer library.write_lane.release();
    var statement = try library.database.prepare(
        \\INSERT INTO recommendation_feedback(recording_id, created_at, expires_at) VALUES (?1, ?2, ?3)
        \\ON CONFLICT(recording_id) DO UPDATE SET created_at = excluded.created_at, expires_at = excluded.expires_at;
    );
    defer statement.deinit();
    try statement.bindInt64(1, recording_id);
    try statement.bindInt64(2, now_s);
    try statement.bindInt64(3, now_s + not_for_me_days * day_s);
    if (try statement.step() != .done) return error.SqlFailed;
}

pub fn clearNotForMe(library: *LibraryDatabase, track_id: i64) !void {
    const recording_id = try trackRecording(library.database, track_id);
    library.write_lane.acquire();
    defer library.write_lane.release();
    var statement = try library.database.prepare("DELETE FROM recommendation_feedback WHERE recording_id = ?1;");
    defer statement.deinit();
    try statement.bindInt64(1, recording_id);
    if (try statement.step() != .done) return error.SqlFailed;
}

/// Forgets every Not for me.
pub fn resetRecommendations(library: *LibraryDatabase) !void {
    library.write_lane.acquire();
    defer library.write_lane.release();
    try library.database.exec("DELETE FROM recommendation_feedback;");
}

fn trackRecording(db: sqlite.Database, track_id: i64) !i64 {
    var statement = try db.prepare("SELECT recording_id FROM tracks WHERE id = ?1 AND recording_id IS NOT NULL;");
    defer statement.deinit();
    try statement.bindInt64(1, track_id);
    if (try statement.step() != .row) return error.TrackNotFound;
    return statement.columnInt64(0);
}

/// A new manual playlist named `name` holding the Tracks `entries` returns
/// at `now_s`, in order.
pub fn save(library: *LibraryDatabase, mix_id: i64, name: []const u8, now_s: i64) !i64 {
    var found: [max_entries]Entry = undefined;
    const written = try entries(library, mix_id, now_s, &found);
    var track_ids: [max_entries]i64 = undefined;
    for (found[0..written], track_ids[0..written]) |entry, *id| id.* = entry.track_id;
    const playlist_id = try library.playlists.create(name);
    errdefer library.playlists.delete(playlist_id) catch {};
    if (written > 0) _ = try library.playlists.insert(playlist_id, track_ids[0..written], null);
    return playlist_id;
}

test "a mix day starts at 04:00 local time" {
    const day = 20_000;
    const midnight = day * day_s;
    try std.testing.expectEqual(@as(i64, day - 1), mixDay(midnight + 3 * 3600, 0));
    try std.testing.expectEqual(@as(i64, day), mixDay(midnight + 4 * 3600, 0));
    try std.testing.expectEqual(@as(i64, day), mixDay(midnight + 2 * 3600, 2 * 3600));
    try std.testing.expectEqual(@as(i64, day - 1), mixDay(midnight + 5 * 3600, -2 * 3600));
}

test "class targets are 15 favorites, 6 rarely played and 4 never played" {
    try std.testing.expectEqual([3]u32{ 15, 6, 4 }, class_targets);
}

const testing = std.testing;
const test_now: i64 = 1_800_000_000;

const Fixture = struct {
    library: LibraryDatabase,
    sql: std.ArrayList(u8) = .empty,
    next: i64 = 1,
    arena_state: std.heap.ArenaAllocator,

    const Spec = struct {
        artist: i64,
        release: ?i64 = null,
        genre: ?i64 = null,
        plays: u8 = 0,
        days_ago: i64 = 10,
        onset_rate: ?f64 = null,
        hated: bool = false,
    };

    fn open(fixture: *Fixture, comptime name: []const u8) !void {
        fixture.* = .{
            .library = try LibraryDatabase.open(testing.allocator, testing.io, "file:orca-test-mixes-" ++ name ++ "?mode=memory&cache=shared"),
            .arena_state = .init(testing.allocator),
        };
        try fixture.add("INSERT OR IGNORE INTO volumes(id, stable_key) VALUES (1, 'legacy');\n", .{});
        for (1..41) |artist| try fixture.add("INSERT INTO artists(id, name, key) VALUES ({d}, 'Artist {d}', 'artist {d}');\n", .{ artist, artist, artist });
        for (1..11) |genre| try fixture.add("INSERT INTO genres(id, name, key) VALUES ({d}, 'G{d}', 'g{d}');\n", .{ genre, genre, genre });
    }

    fn close(self: *Fixture) void {
        self.sql.deinit(testing.allocator);
        self.arena_state.deinit();
        self.library.close();
    }

    fn add(self: *Fixture, comptime format: []const u8, arguments: anytype) !void {
        try self.sql.print(testing.allocator, format, arguments);
    }

    fn release(self: *Fixture, id: i64, date: ?[]const u8) !void {
        if (date) |value| {
            try self.add("INSERT INTO releases(id, title, release_type, release_date) VALUES ({d}, 'R{d}', 'album', '{s}');\n", .{ id, id, value });
        } else try self.add("INSERT INTO releases(id, title, release_type) VALUES ({d}, 'R{d}', 'album');\n", .{ id, id });
    }

    fn recording(self: *Fixture, spec: Spec) !void {
        const id = self.next;
        self.next += 1;
        try self.add(
            \\INSERT INTO recordings(id, title) VALUES ({d}, 'r');
            \\INSERT INTO files(id, recording_id, audio_format, size_bytes, content_hash, content_hash_algorithm, channels)
            \\    VALUES ({d}, {d}, 1, 1, x'{x:0>16}', 1, 2);
            \\INSERT INTO tracks(id, recording_id, release_id, title, artist_id, preferred_file_id, duration_ms, created_at)
            \\    VALUES ({d}, {d}, {s}, 't', {d}, {d}, 180000, 1000);
            \\INSERT INTO locations(file_id, volume_id, uri, state) VALUES ({d}, 1, '/m/{d}', 'present');
            \\
        , .{
            id,                              id,
            id,                              @as(u64, @intCast(id)),
            id,                              id,
            try self.optional(spec.release), spec.artist,
            id,                              id,
            id,
        });
        if (spec.genre) |genre| try self.add("INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES ({d}, {d}, 0, 0);\n", .{ id, genre });
        if (spec.onset_rate) |rate| try self.add(
            "INSERT INTO file_audio_features(file_id, source_identity, onset_rate) VALUES ({d}, x'{x:0>16}', {d});\n",
            .{ id, @as(u64, @intCast(id)), rate },
        );
        if (spec.hated) try self.add("INSERT INTO feedback(recording_id, score, updated_at) VALUES ({d}, -1, 1);\n", .{id});
        for (0..spec.plays) |play| try self.add(
            "INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist) VALUES ({d}, {d}, {d}, 1000, 't', 'a');\n",
            .{ id, id, test_now - (spec.days_ago + @as(i64, @intCast(play))) * day_s - id },
        );
    }

    fn optional(self: *Fixture, value: ?i64) ![]const u8 {
        const id = value orelse return "NULL";
        return std.fmt.allocPrint(self.arena_state.allocator(), "{d}", .{id});
    }

    fn finish(self: *Fixture) !void {
        try self.add(
            \\INSERT OR REPLACE INTO recording_play_stats(recording_id, play_count, last_played_at)
            \\    SELECT recording_id, count(*), max(started_at) FROM listens GROUP BY recording_id;
            \\
        , .{});
        try self.sql.append(testing.allocator, 0);
        try self.library.database.exec(self.sql.items[0 .. self.sql.items.len - 1 :0]);
        self.sql.clearRetainingCapacity();
    }

    fn source(self: *Fixture) discovery.Source {
        return .of(&self.library);
    }

    fn themes(self: *Fixture, src: *const discovery.Source, day: i64) !Themes {
        const arena = self.arena_state.allocator();
        return .{
            .arena = arena,
            .source = src,
            .now_s = test_now,
            .day_seed = 1,
            .avoid_days = 3,
            .top_artists = try loadTopArtists(arena, src.database, test_now),
            .start = @intCast(@mod(day, theme_kinds.len)),
        };
    }

    fn qualifies(self: *Fixture, kind: Kind) !bool {
        const src = self.source();
        var themes_state = try self.themes(&src, 0);
        return try themes_state.rank(kind) != null;
    }

    fn mixes(self: *Fixture, mix_count: usize, day: i64) ![]const Built {
        const src = self.source();
        const settings = try discovery.readSettings(&src.settings);
        return (try makeMixes(self.arena_state.allocator(), &src, test_now, day, settings, mix_count, null)).?;
    }

    fn artistOf(self: *Fixture, recording_id: i64) !i64 {
        var statement = try self.library.database.prepare("SELECT artist_id FROM tracks WHERE recording_id = ?1;");
        defer statement.deinit();
        try statement.bindInt64(1, recording_id);
        try testing.expectEqual(sqlite.Step.row, try statement.step());
        return statement.columnInt64(0);
    }
};

fn expectMixNames(mixes: []const Built, names: []const []const u8) !void {
    try testing.expectEqual(names.len, mixes.len);
    for (mixes, names) |mix, name| try testing.expectEqualStrings(name, mix.name);
}

fn themePools(fixture: *Fixture, count: usize, features: bool) !void {
    try fixture.release(1, "1985-01-01");
    try fixture.release(2, null);
    try fixture.release(3, null);
    for (0..count) |_| try fixture.recording(.{ .artist = 1, .release = 1 });
    try fixture.recording(.{ .artist = 1, .release = 1, .hated = true });
    try fixture.recording(.{ .artist = 2, .release = 2, .plays = 2 });
    for (0..count) |_| try fixture.recording(.{ .artist = 2, .release = 3 });
    const featured = count * 3;
    for (0..featured) |index| try fixture.recording(.{
        .artist = 3,
        .onset_rate = if (features) @floatFromInt(index + 1) else null,
    });
    try fixture.finish();
}

test "each theme kind qualifies with 40 candidates after exclusions and not with 39" {
    inline for (.{ .{ "theme-40", 40, true }, .{ "theme-39", 39, false } }) |case| {
        var fixture: Fixture = undefined;
        try fixture.open(case[0]);
        defer fixture.close();
        try themePools(&fixture, case[1], true);
        for (theme_kinds) |kind| {
            errdefer std.debug.print("{s} with {d} candidates\n", .{ @tagName(kind), case[1] });
            try testing.expectEqual(case[2], try fixture.qualifies(kind));
        }
    }
}

test "Upbeat and Wind down never qualify without audio features" {
    var fixture: Fixture = undefined;
    try fixture.open("theme-no-features");
    defer fixture.close();
    try themePools(&fixture, 60, false);

    try testing.expect(!try fixture.qualifies(.upbeat));
    try testing.expect(!try fixture.qualifies(.wind_down));
    try testing.expect(try fixture.qualifies(.deep_cuts));
}

test "the decade mix takes the decade most listened to in 30 days, else the decade with the most Tracks" {
    var fixture: Fixture = undefined;
    try fixture.open("decade");
    defer fixture.close();
    try fixture.release(1, "1994");
    try fixture.release(2, "2003-07-01");
    try fixture.release(3, null);
    for (0..50) |_| try fixture.recording(.{ .artist = 1, .release = 1 });
    for (0..45) |_| try fixture.recording(.{ .artist = 2, .release = 2 });
    for (0..10) |_| try fixture.recording(.{ .artist = 3, .release = 3, .plays = 3 });
    try fixture.recording(.{ .artist = 2, .release = 2, .plays = 3, .days_ago = 40 });
    try fixture.finish();
    const src = fixture.source();

    try testing.expectEqual(@as(?i64, 1990), try favoriteDecade(src.database, test_now));
    var themes = try fixture.themes(&src, 0);
    const found = (try themes.ranked(0)).?;
    try testing.expectEqual(Kind.decade, found.kind);
    try testing.expectEqualStrings("1990s", found.name);
    try testing.expectEqual(@as(?i64, 1990), found.decade);

    try fixture.recording(.{ .artist = 2, .release = 2, .plays = 1, .days_ago = 2 });
    try fixture.finish();
    try testing.expectEqual(@as(?i64, 2000), try favoriteDecade(src.database, test_now));

    try fixture.library.database.exec("UPDATE releases SET release_date = NULL;");
    try testing.expectEqual(@as(?i64, null), try favoriteDecade(src.database, test_now));
}

fn listeningHistory(fixture: *Fixture, genres: usize, rarely: bool) !void {
    for (1..genres * 2 + 1) |artist_index| {
        const artist: i64 = @intCast(artist_index);
        const genre = @divFloor(artist - 1, 2) + 1;
        try fixture.release(artist * 2 - 1, "2015");
        try fixture.release(artist * 2, "2015");
        const plays: u8 = @intCast(2 + genres * 2 - artist_index);
        for (0..6) |_| try fixture.recording(.{ .artist = artist, .release = artist * 2 - 1, .genre = genre, .plays = plays });
        for (0..30) |_| try fixture.recording(.{ .artist = artist, .release = artist * 2, .genre = genre });
    }
    if (rarely) {
        try fixture.release(100, null);
        for (0..80) |index| try fixture.recording(.{ .artist = @intCast(31 + index % 10), .release = 100, .plays = 2, .days_ago = 400 });
    }
    try fixture.finish();
}

fn expectDistinctAndSpaced(fixture: *Fixture, mixes: []const Built) !void {
    var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
    defer seen.deinit(testing.allocator);
    for (mixes) |mix| {
        try testing.expect(mix.entries.len > 0);
        var run: usize = 0;
        var last_artist: i64 = -1;
        for (mix.entries) |entry| {
            try testing.expect(!seen.contains(entry.recording_id));
            try seen.put(testing.allocator, entry.recording_id, {});
            const artist = try fixture.artistOf(entry.recording_id);
            run = if (artist == last_artist) run + 1 else 1;
            last_artist = artist;
            try testing.expect(run <= 2);
        }
    }
}

test "with three genres and no Rarely played, six mixes are the genres then three themes in rotation" {
    var fixture: Fixture = undefined;
    try fixture.open("slots-thin");
    defer fixture.close();
    try listeningHistory(&fixture, 3, false);

    const mixes = try fixture.mixes(6, 5 * 4000);
    try expectMixNames(mixes, &.{ "G1", "G2", "G3", "2010s", "New to you", "Deep cuts" });
    try testing.expectEqual(Kind.decade, mixes[3].kind);
    try testing.expectEqual(@as(?i64, 2010), mixes[3].decade);
    try testing.expectEqual(@as(?i64, null), mixes[3].genre_id);
    try testing.expectEqual(Kind.new_to_you, mixes[4].kind);
    try testing.expectEqual(Kind.deep_cuts, mixes[5].kind);
    try expectDistinctAndSpaced(&fixture, mixes);
    for (mixes[3..]) |mix| try testing.expectEqual(@as(usize, max_entries), mix.entries.len);
}

test "with rich history six mixes are four genres, one theme and Rarely played last" {
    var fixture: Fixture = undefined;
    try fixture.open("slots-rich");
    defer fixture.close();
    try listeningHistory(&fixture, 5, true);

    const mixes = try fixture.mixes(6, 5 * 4000);
    try expectMixNames(mixes, &.{ "G1", "G2", "G3", "G4", "2010s", "Rarely played" });
    try testing.expectEqual(Kind.rarely_played, mixes[5].kind);
    try expectDistinctAndSpaced(&fixture, mixes);

    const four = try fixture.mixes(4, 5 * 4000);
    try expectMixNames(four, &.{ "G1", "G2", "2010s", "Rarely played" });
}

test "the theme slot rotates to the next qualifying kind on the next day" {
    var fixture: Fixture = undefined;
    try fixture.open("slots-rotate");
    defer fixture.close();
    try listeningHistory(&fixture, 5, true);

    try expectMixNames(try fixture.mixes(6, 5 * 4000), &.{ "G1", "G2", "G3", "G4", "2010s", "Rarely played" });
    try expectMixNames(try fixture.mixes(6, 5 * 4000 + 1), &.{ "G1", "G2", "G3", "G4", "New to you", "Rarely played" });
    try expectMixNames(try fixture.mixes(6, 5 * 4000 + 3), &.{ "G1", "G2", "G3", "G4", "2010s", "Rarely played" });
}

test "two mixes are one genre and Rarely played, or a genre and a theme without Rarely played, or a theme without genres" {
    {
        var fixture: Fixture = undefined;
        try fixture.open("slots-two-rarely");
        defer fixture.close();
        try listeningHistory(&fixture, 3, true);
        try expectMixNames(try fixture.mixes(2, 5 * 4000), &.{ "G1", "Rarely played" });
    }
    {
        var fixture: Fixture = undefined;
        try fixture.open("slots-two-thin");
        defer fixture.close();
        try listeningHistory(&fixture, 3, false);
        try expectMixNames(try fixture.mixes(2, 5 * 4000 + 2), &.{ "G1", "Deep cuts" });
    }
    {
        var fixture: Fixture = undefined;
        try fixture.open("slots-two-no-genre");
        defer fixture.close();
        try listeningHistory(&fixture, 3, true);
        try fixture.library.database.exec("DELETE FROM track_genres;");
        try expectMixNames(try fixture.mixes(2, 5 * 4000), &.{ "2010s", "Rarely played" });
    }
}

test "Upbeat and Wind down hold only Recordings in their third of the energy, and New to you and Deep cuts take any class" {
    var fixture: Fixture = undefined;
    try fixture.open("slots-energy");
    defer fixture.close();
    for (0..150) |index| try fixture.recording(.{
        .artist = @intCast(1 + index % 5),
        .onset_rate = @floatFromInt(index + 1),
        .plays = if (index % 7 == 0) 1 else 0,
    });
    try fixture.finish();

    const mixes = try fixture.mixes(6, 5 * 4000 + 3);
    try expectMixNames(mixes, &.{ "Upbeat", "Wind down", "Deep cuts" });
    try expectDistinctAndSpaced(&fixture, mixes);
    for (mixes[0].entries) |entry| try testing.expect(entry.recording_id > 100);
    for (mixes[1].entries) |entry| try testing.expect(entry.recording_id <= 50);
    try testing.expectEqual(@as(usize, max_entries), mixes[2].entries.len);

    const any: [3]?Class = .{ null, null, null };
    try testing.expectEqual(any, Builder.classOrder(.new_to_you, @splat(0)));
    try testing.expectEqual(any, Builder.classOrder(.deep_cuts, @splat(0)));
    try testing.expect(Builder.classOrder(.upbeat, @splat(0))[0] != null);
    try testing.expect(Builder.classOrder(.decade, @splat(0))[0] != null);
}
