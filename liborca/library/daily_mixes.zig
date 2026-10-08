//! Daily Mixes: up to six mixes a local day made from the Library's listening
//! history with the discovery scoring. See docs/discovery.md.
const std = @import("std");
const database = @import("../database/root.zig");
const discovery = @import("discovery.zig");
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

pub const Kind = enum(u8) {
    /// Made for a cluster of Artists sharing a genre, named after it.
    genre = 0,
    /// Recordings played before but not in the last year.
    rarely_played = 1,
};

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
    /// Null for Rarely played, and when the genre was deleted since.
    genre_id: ?i64,
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

    const day_seed = std.hash.Wyhash.hash(0, std.mem.asBytes(&day));
    const avoid_days: i64 = @backingInt(settings.avoid_days);
    const genre_mixes = @as(usize, @backingInt(settings.mix_count)) - 1;
    var builder: Builder = .{ .arena = arena, .source = &source, .now_s = options.now_s };

    const clusters = try loadClusters(arena, reader, options.now_s);
    for (clusters) |cluster| {
        if (builder.mixes.items.len == genre_mixes) break;
        if (isCancelled(cancellation)) return .{ .outcome = .cancelled };
        const mix: discovery.MixFilter = .{ .now_s = options.now_s, .seed = mixSeed(day_seed, builder.mixes.items.len), .avoid_days = avoid_days };
        const ranking = try discovery.rankCluster(arena, &source, .{ .genre_id = cluster.genre_id, .artists = cluster.artists }, mix);
        if (cluster.artists.len < min_cluster_artists and clusterCandidates(ranking.items, cluster.artists) < min_cluster_candidates) continue;
        const avoid_after = if (ranking.relaxed_recent or avoid_days == 0) null else options.now_s - avoid_days * day_s;
        const left_out = try discovery.leftOut(arena, &source, .{ .artists = cluster.artists }, options.now_s, avoid_after);
        try builder.add(.genre, cluster.genre_id, cluster.name, ranking.items, left_out, cluster);
    }

    if (isCancelled(cancellation)) return .{ .outcome = .cancelled };
    const unplayed_since = options.now_s - rarely_played_after_s;
    const rarely_mix: discovery.MixFilter = .{ .now_s = options.now_s, .seed = mixSeed(day_seed, max_mixes), .avoid_days = 0 };
    const rarely = try discovery.rankRarelyPlayed(arena, &source, rarely_mix, unplayed_since);
    const rarely_left_out = try discovery.leftOut(arena, &source, .{ .unplayed_since = unplayed_since }, options.now_s, null);
    try builder.add(.rarely_played, null, rarely_played_name, rarely.items, rarely_left_out, null);

    if (isCancelled(cancellation)) return .{ .outcome = .cancelled };
    try store(library, builder.mixes.items, day, options.now_s);
    return .{ .outcome = .generated, .mixes = @intCast(builder.mixes.items.len) };
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

/// The 50 Artists most played in the last 30 days, grouped by each one's most
/// common first genre, most played group first.
fn loadClusters(arena: std.mem.Allocator, db: sqlite.Database, now_s: i64) ![]Cluster {
    const Played = struct { id: i64, plays: i64 };
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
    var played: std.ArrayList(Played) = .empty;
    while (try top.step() == .row) try played.append(arena, .{ .id = top.columnInt64(0), .plays = top.columnInt64(1) });
    if (played.items.len == 0) return &.{};

    var ids: std.ArrayList(u8) = .empty;
    try ids.append(arena, '[');
    for (played.items, 0..) |artist, index| try ids.print(arena, "{s}{d}", .{ if (index == 0) "" else ",", artist.id });
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
    for (played.items) |artist| {
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
    /// A genre mix takes from the class furthest below its target, and from
    /// the next class when that one has nothing left. A pick that would run
    /// past 90 minutes is passed over. Adds nothing when nothing qualifies.
    fn add(
        self: *Builder,
        kind: Kind,
        genre_id: ?i64,
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
    /// target first, ties in class order. Rarely played takes from any
    /// class.
    fn classOrder(kind: Kind, counts: [3]u32) [3]?Class {
        if (kind == .rarely_played) return .{ null, null, null };
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
    /// genre mix the most played in the last 30 days, for Rarely played the
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
        \\    favorite_count, rarely_played_count, never_played_count)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16) RETURNING id;
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
        \\    favorite_count, rarely_played_count, never_played_count
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
