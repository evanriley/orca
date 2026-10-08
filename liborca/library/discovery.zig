//! Discovery scoring: ranks the Library's Recordings against a seed for Radio
//! and Daily Mixes. Every signal is local; see docs/discovery.md.
const std = @import("std");
const database = @import("../database/root.zig");
const sqlite = database.sqlite;
const AudioFeatures = database.AudioFeatures;
const track_play_file = @import("../database/repository/tracks.zig").track_play_file;
const optionalInt64 = @import("../database/columns.zig").optionalInt64;

pub const max_pool = 2000;
pub const max_picks = 512;
pub const max_focus = 4;
pub const max_session_exclusions = 4096;
pub const max_session_adjustments = 256;
pub const max_session_recent = 16;

const max_seed_tracks = 512;
const max_seed_artists = 64;
const max_related_sources = 16;
const max_profile_genres = 32;
const max_bucket_genres = 8;
const max_seed_listens = 2000;
const max_colisten_rows = 40_000;
const colisten_window_s = 30 * 60;
const colisten_history_s = 365 * 86_400;
const recent_seed_tracks = 5;
const added_reason_window_s = 60 * 86_400;
const diversity_window = 10;
const unplayed_window = 4;

/// Where a Radio starts.
pub const Seed = union(enum) {
    track: i64,
    release: i64,
    artist: i64,
    genre: i64,
    /// The first year of a decade, such as 1990.
    decade: i64,
    loved,
    /// The last five Tracks heard.
    recent,
};

/// A hard filter on what Radio may pick. Filters of one kind admit a
/// Recording that matches any of them; filters of different kinds must all
/// match.
pub const Focus = union(enum) {
    genre: i64,
    decade: i64,
    /// The bottom third of the Library's energy.
    low_energy,
    /// The top third of the Library's energy.
    high_energy,
};

pub const RadioOptions = struct {
    /// 0 stays close to the seed; 100 explores.
    explore: u8 = 35,
    focus: [max_focus]?Focus = @splat(null),
    /// Null reads `radio.include_unplayed`.
    include_unplayed: ?bool = null,
    /// Null leaves out what was played within `discovery.avoid_days`; true
    /// does so even when that setting is 0, for its default of 3 days.
    avoid_recent: ?bool = null,
    include_live: bool = false,
};

/// A score change for one Artist or genre for the rest of a session.
pub const Adjustment = struct {
    id: i64,
    delta: f64,
};

/// A pick already made in this session, oldest first.
pub const RecentPick = struct {
    recording_id: i64,
    artist_id: ?i64,
    release_id: ?i64,
    never_played: bool,
};

/// What a Radio session carries from pick to pick.
pub const Session = struct {
    now_s: i64,
    /// The same seed and `now_s` rank the same Library the same way.
    seed: u64,
    excluded_recordings: []const i64 = &.{},
    artist_adjustments: []const Adjustment = &.{},
    genre_adjustments: []const Adjustment = &.{},
    recent: []const RecentPick = &.{},
};

/// One value per scoring component, each 0 to 1, or the weights they carry.
pub const Components = struct {
    artist: f64 = 0,
    genre: f64 = 0,
    audio: f64 = 0,
    co_listening: f64 = 0,
    era: f64 = 0,
    taste: f64 = 0,
    jitter: f64 = 0,

    const names = .{ "artist", "genre", "audio", "co_listening", "era", "taste", "jitter" };

    /// The weights at `explore`, 0 to 100, linear between Close and Explore.
    pub fn weightsAt(explore: u8) Components {
        const t = @as(f64, @floatFromInt(@min(explore, 100))) / 100;
        var result: Components = .{};
        inline for (names) |name| {
            @field(result, name) = @field(close, name) + (@field(far, name) - @field(close, name)) * t;
        }
        return result;
    }

    /// These weights with Audio's share spread over the others.
    pub fn withoutAudio(self: Components) Components {
        const rest = 1 - self.audio;
        var result = self;
        result.audio = 0;
        if (rest <= 0) return result;
        inline for (names) |name| @field(result, name) = @field(result, name) / rest;
        return result;
    }

    pub fn weighted(self: Components, weights: Components) f64 {
        var total: f64 = 0;
        inline for (names) |name| total += @field(self, name) * @field(weights, name);
        return total;
    }

    const close: Components = .{ .artist = 0.35, .genre = 0.20, .audio = 0.15, .co_listening = 0.10, .era = 0.08, .taste = 0.07, .jitter = 0.05 };
    const far: Components = .{ .artist = 0.10, .genre = 0.10, .audio = 0.25, .co_listening = 0.25, .era = 0.05, .taste = 0.10, .jitter = 0.15 };
};

/// Why a Recording was picked. The numbering is stored in
/// `daily_mix_entries` and must not change.
pub const ReasonKind = enum(u8) {
    /// a: play count, b: last played, Unix seconds.
    played = 0,
    loved = 1,
    /// a: the Artist.
    same_artist = 2,
    /// a: the seed Artist it is related to, b: its own Artist.
    related_artist = 3,
    /// a: the genre.
    shared_genre = 4,
    /// a: the Recording (b = 0) or Artist (b = 1) it was often played after.
    often_after = 5,
    /// a: `sound_tempo`, `sound_key` and `sound_energy` flags.
    similar_sound = 6,
    never_played = 7,
    /// a: play count.
    rarely_played = 8,
    /// a: when it was added, Unix seconds.
    added = 9,
};

pub const sound_tempo: i64 = 1;
pub const sound_key: i64 = 2;
pub const sound_energy: i64 = 4;

pub const ReasonPart = struct {
    kind: ReasonKind,
    a: i64 = 0,
    b: i64 = 0,
};

/// Up to two true reasons, the stronger first.
pub const PickReason = struct {
    first: ?ReasonPart = null,
    second: ?ReasonPart = null,
};

pub const Pick = struct {
    track_id: i64,
    recording_id: i64,
    artist_id: ?i64,
    release_id: ?i64,
    score: f64,
    components: Components,
    reason: PickReason,
    never_played: bool,
};

pub const Picks = struct {
    allocator: std.mem.Allocator,
    items: []Pick,
    /// The weights the components were combined with.
    weights: Components,
    /// Whether Recordings played within the avoid window were let back in
    /// because nothing else qualified.
    relaxed_recent: bool,

    pub fn deinit(self: *Picks) void {
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const AvoidDays = enum(u8) { none = 0, one_day = 1, three_days = 3, seven_days = 7 };
pub const MixCount = enum(u8) { off = 0, four = 4, six = 6 };

/// The Library's Radio and Daily Mix settings.
pub const Settings = struct {
    radio_continue: bool = true,
    include_unplayed: bool = true,
    avoid_days: AvoidDays = .three_days,
    mix_count: MixCount = .six,
};

pub fn readSettings(settings: *const database.LibrarySettingsRepository) !Settings {
    const defaults: Settings = .{};
    const avoid = try settings.integer(database.setting_discovery_avoid_days, @backingInt(defaults.avoid_days));
    const mixes = try settings.integer(database.setting_mixes_count, @backingInt(defaults.mix_count));
    return .{
        .radio_continue = try settings.flag(database.setting_radio_continue, defaults.radio_continue),
        .include_unplayed = try settings.flag(database.setting_radio_include_unplayed, defaults.include_unplayed),
        .avoid_days = enumOr(AvoidDays, avoid, defaults.avoid_days),
        .mix_count = enumOr(MixCount, mixes, defaults.mix_count),
    };
}

pub fn writeSettings(settings: *database.LibrarySettingsRepository, value: Settings) !void {
    try settings.setFlag(database.setting_radio_continue, value.radio_continue);
    try settings.setFlag(database.setting_radio_include_unplayed, value.include_unplayed);
    try settings.setInteger(database.setting_discovery_avoid_days, @backingInt(value.avoid_days));
    try settings.setInteger(database.setting_mixes_count, @backingInt(value.mix_count));
}

fn enumOr(comptime E: type, value: i64, default: E) E {
    const tag = std.math.cast(@typeInfo(E).@"enum".tag_type, value) orelse return default;
    return std.enums.fromInt(E, tag) orelse default;
}

/// 1 when the tempos match, also at half or double, falling to 0 at a
/// quarter apart.
pub fn tempoSimilarity(a: f64, b: f64) f64 {
    if (a <= 0 or b <= 0) return 0;
    var nearest: f64 = std.math.inf(f64);
    for ([_]f64{ 0.5, 1, 2 }) |ratio| nearest = @min(nearest, @abs(std.math.log2(a / (ratio * b))));
    return @max(0, 1 - nearest / std.math.log2(1.25));
}

/// 1 for the same key, 0.7 for its relative or a fifth away, else 0.
pub fn keySimilarity(a: AudioFeatures.Key, b: AudioFeatures.Key) f64 {
    if (a.pitch == b.pitch and a.mode == b.mode) return 1;
    if (a.mode == b.mode) {
        const interval = (@as(u8, a.pitch) + 12 - b.pitch) % 12;
        return if (interval == 5 or interval == 7) 0.7 else 0;
    }
    const major, const minor = if (a.mode == .major) .{ a, b } else .{ b, a };
    return if ((major.pitch + 9) % 12 == minor.pitch) 0.7 else 0;
}

pub fn energySimilarity(a: f64, b: f64) f64 {
    return std.math.clamp(1 - @abs(a - b), 0, 1);
}

/// What a seed sounds like: the median tempo, the most common key and the
/// mean energy of its Tracks.
pub const Sound = struct {
    tempo: ?f64 = null,
    key: ?AudioFeatures.Key = null,
    energy: ?f64 = null,

    pub fn isEmpty(self: Sound) bool {
        return self.tempo == null and self.key == null and self.energy == null;
    }
};

pub const AudioScore = struct {
    value: f64,
    /// `sound_*` flags for the parts close enough to name.
    flags: i64,
};

/// The audio component of a candidate against a seed's sound. Parts either
/// side lacks drop out and the rest are renormalised; a candidate with
/// nothing to compare scores 0.3.
pub fn audioScore(seed: Sound, candidate: ?AudioFeatures) AudioScore {
    const features = candidate orelse return .{ .value = 0.3, .flags = 0 };
    var sum: f64 = 0;
    var weight: f64 = 0;
    var flags: i64 = 0;
    if (seed.tempo) |a| if (features.tempo) |b| {
        const s = tempoSimilarity(a, b.bpm);
        sum += 0.4 * s;
        weight += 0.4;
        if (s >= 0.7) flags |= sound_tempo;
    };
    if (seed.key) |a| if (features.key) |b| {
        const s = keySimilarity(a, b);
        sum += 0.2 * s;
        weight += 0.2;
        if (s >= 0.7) flags |= sound_key;
    };
    if (seed.energy) |a| if (features.energy) |b| {
        const s = energySimilarity(a, b);
        sum += 0.4 * s;
        weight += 0.4;
        if (s >= 0.85) flags |= sound_energy;
    };
    if (weight == 0) return .{ .value = 0.3, .flags = 0 };
    return .{ .value = sum / weight, .flags = flags };
}

/// 1 inside the seed's years, falling to 0 at 15 years outside; 0.3 when
/// either side has no year.
pub fn eraScore(low: ?i64, high: ?i64, year: ?i64) f64 {
    const lo = low orelse return 0.3;
    const hi = high orelse return 0.3;
    const y = year orelse return 0.3;
    const distance: i64 = if (y < lo) lo - y else if (y > hi) y - hi else 0;
    return @max(0, 1 - @as(f64, @floatFromInt(distance)) / 15);
}

pub fn tasteScore(loved: bool, rating: ?i64, release_or_artist_loved: bool) f64 {
    var value: f64 = if (loved) 0.5 else 0;
    if (rating) |r| value += @as(f64, @floatFromInt(std.math.clamp(r, 0, 100))) / 200;
    if (release_or_artist_loved) value += 0.2;
    return @min(value, 1);
}

pub fn jitter(recording_id: i64, seed: u64) f64 {
    const hash = std.hash.Wyhash.hash(seed, std.mem.asBytes(&recording_id));
    return @as(f64, @floatFromInt(hash >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
}

/// The connection and repositories scoring reads, which may be a read-only
/// connection of its own.
pub const Source = struct {
    database: sqlite.Database,
    settings: database.LibrarySettingsRepository,
    artist_info: database.ArtistInfoRepository,
    audio_features: database.AudioFeatureRepository,

    pub fn of(library: *const database.LibraryDatabase) Source {
        return onConnection(library.database, library.write_lane);
    }

    pub fn onConnection(connection: sqlite.Database, write_lane: *database.repository.WriteLane) Source {
        return .{
            .database = connection,
            .settings = .{ .db = connection, .write_lane = write_lane },
            .artist_info = .{ .db = connection, .write_lane = write_lane },
            .audio_features = .{ .db = connection },
        };
    }
};

/// Up to `limit` (at most `max_picks`) Recordings for a Radio from `seed`,
/// ranked and spaced out. Reads the Library only.
pub fn pickRadio(
    allocator: std.mem.Allocator,
    library: *const Source,
    seed: Seed,
    options: RadioOptions,
    session: Session,
    limit: usize,
) !Picks {
    if (limit > max_picks) return error.RadioLimitTooLarge;
    try validateRadio(seed, options);
    if (session.excluded_recordings.len > max_session_exclusions or
        session.artist_adjustments.len > max_session_adjustments or
        session.genre_adjustments.len > max_session_adjustments or
        session.recent.len > max_session_recent) return error.RadioSessionTooLarge;

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db = library.database;

    const settings = try readSettings(&library.settings);
    const include_unplayed = options.include_unplayed orelse settings.include_unplayed;
    const avoid_days: i64 = if (options.avoid_recent) |avoid|
        (if (!avoid) 0 else if (settings.avoid_days == .none) @backingInt(AvoidDays.three_days) else @backingInt(settings.avoid_days))
    else
        @backingInt(settings.avoid_days);

    try requireSeed(db, seed);
    var profile = try buildProfile(arena, library, seed, session.now_s);

    var weights = Components.weightsAt(options.explore);
    if (profile.sound.isEmpty()) weights = weights.withoutAudio();

    var excluded: std.ArrayList(i64) = .empty;
    try excluded.appendSlice(arena, session.excluded_recordings);
    for (session.recent) |recent| try excluded.append(arena, recent.recording_id);
    if (seed == .track) for (profile.seed_tracks) |track| try excluded.append(arena, track.recording_id);

    var filter: Filter = .{
        .now_s = session.now_s,
        .include_live = options.include_live,
        .focus_genres = try jsonIds(arena, focusValues(arena, options, .genre)),
        .focus_decades = try jsonIds(arena, focusValues(arena, options, .decade)),
        .avoid_after = if (avoid_days > 0) session.now_s - avoid_days * 86_400 else null,
        .require_played = !include_unplayed,
        .excluded = try jsonIds(arena, excluded.items),
        .jitter_seed = @intCast(session.seed % 4_294_967_291),
    };
    const energy_focus = energyFocus(options);

    var relaxed_recent = false;
    var candidates = try loadCandidates(arena, library, &profile, &filter, energy_focus);
    if (candidates.len == 0 and filter.avoid_after != null) {
        filter.avoid_after = null;
        relaxed_recent = true;
        candidates = try loadCandidates(arena, library, &profile, &filter, energy_focus);
    }

    for (candidates) |*candidate| score(candidate, &profile, weights, session);

    const order = try arena.alloc(u32, candidates.len);
    for (order, 0..) |*slot, index| slot.* = @intCast(index);
    std.mem.sort(u32, order, candidates, byScore);

    var picks: std.ArrayList(Pick) = .empty;
    errdefer picks.deinit(allocator);
    try picks.ensureTotalCapacity(allocator, @min(limit, candidates.len));
    var history: std.ArrayList(RecentPick) = .empty;
    try history.appendSlice(arena, session.recent);
    const used = try arena.alloc(bool, candidates.len);
    @memset(used, false);

    while (picks.items.len < limit) {
        const chosen = choose(candidates, order, used, history.items) orelse break;
        used[chosen] = true;
        const candidate = &candidates[chosen];
        try history.append(arena, .{
            .recording_id = candidate.recording_id,
            .artist_id = candidate.artist_id,
            .release_id = candidate.release_id,
            .never_played = candidate.play_count == 0,
        });
        picks.appendAssumeCapacity(.{
            .track_id = candidate.track_id,
            .recording_id = candidate.recording_id,
            .artist_id = candidate.artist_id,
            .release_id = candidate.release_id,
            .score = candidate.score,
            .components = candidate.components,
            .reason = reasonFor(candidate, &profile, weights, session.now_s),
            .never_played = candidate.play_count == 0,
        });
    }

    return .{
        .allocator = allocator,
        .items = try picks.toOwnedSlice(allocator),
        .weights = weights,
        .relaxed_recent = relaxed_recent,
    };
}

/// Artists a Daily Mix is made for, under the genre they share.
pub const Cluster = struct {
    genre_id: i64,
    artists: []const i64,
};

/// What Daily Mix ranking reads besides the Library.
pub const MixFilter = struct {
    now_s: i64,
    seed: u64,
    /// Played Recordings within this many days are left out; 0 for none.
    avoid_days: i64,

    fn filter(self: MixFilter) Filter {
        return .{
            .now_s = self.now_s,
            .include_live = false,
            .focus_genres = "[]",
            .focus_decades = "[]",
            .avoid_after = if (self.avoid_days > 0) self.now_s - self.avoid_days * 86_400 else null,
            .require_played = false,
            .excluded = "[]",
            .jitter_seed = @intCast(self.seed % 4_294_967_291),
        };
    }
};

/// A Daily Mix candidate with its true reasons.
pub const Ranked = struct {
    track_id: i64,
    recording_id: i64,
    artist_id: ?i64,
    release_id: ?i64,
    score: f64,
    reason: PickReason,
    loved: bool,
    rating: ?i64,
    play_count: i64,
    last_played_at: ?i64,
};

/// At most `max_pool` candidates, best first.
pub const Ranking = struct {
    items: []const Ranked,
    /// Whether Recordings played within the avoid window were let back in
    /// because nothing else qualified.
    relaxed_recent: bool,
};

/// Eligible Recordings ranked against the cluster's profile: its Artists at
/// 1.0 and their related Artists, its genre pinned at 1, and the years,
/// sound and co-listening of the Artists' Tracks. Never-played Recordings are
/// candidates whatever `radio.include_unplayed` says.
pub fn rankCluster(arena: std.mem.Allocator, library: *const Source, cluster: Cluster, mix: MixFilter) !Ranking {
    var profile = try buildClusterProfile(arena, library, cluster, mix.now_s);
    var weights = Components.weightsAt((RadioOptions{}).explore);
    if (profile.sound.isEmpty()) weights = weights.withoutAudio();

    var filter = mix.filter();
    var relaxed_recent = false;
    var candidates = try loadCandidates(arena, library, &profile, &filter, .{});
    if (candidates.len == 0 and filter.avoid_after != null) {
        filter.avoid_after = null;
        relaxed_recent = true;
        candidates = try loadCandidates(arena, library, &profile, &filter, .{});
    }
    const session: Session = .{ .now_s = mix.now_s, .seed = mix.seed };
    for (candidates) |*candidate| score(candidate, &profile, weights, session);
    const order = try arena.alloc(u32, candidates.len);
    for (order, 0..) |*slot, index| slot.* = @intCast(index);
    std.mem.sort(u32, order, candidates, byScore);

    const items = try arena.alloc(Ranked, candidates.len);
    for (items, order) |*item, index| {
        const candidate = &candidates[index];
        item.* = rankedFrom(candidate, candidate.score, reasonFor(candidate, &profile, weights, mix.now_s));
    }
    return .{ .items = items, .relaxed_recent = relaxed_recent };
}

/// Eligible Recordings played at least once but not since `unplayed_since`,
/// at most `max_pool` of the most played, ordered by play count times
/// 1 + jitter / 2. Their reasons are loved and their play history.
pub fn rankRarelyPlayed(arena: std.mem.Allocator, library: *const Source, mix: MixFilter, unplayed_since: i64) !Ranking {
    var filter = mix.filter();
    filter.avoid_after = null;
    var statement = try library.database.prepare(rarely_played_sql);
    defer statement.deinit();
    try filter.bind(statement);
    try statement.bindInt64(8, unplayed_since);
    var ids: std.ArrayList(i64) = .empty;
    while (try statement.step() == .row) try ids.append(arena, statement.columnInt64(0));

    const candidates = try candidateDetails(arena, library, &filter, ids.items, .{});
    const profile: Profile = .{ .seed = .recent, .seed_tracks = &.{}, .own_artists = false };
    const weights = Components.weightsAt(0);
    const items = try arena.alloc(Ranked, candidates.len);
    for (items, candidates) |*item, *candidate| {
        candidate.components.taste = tasteScore(candidate.loved, candidate.rating, candidate.release_or_artist_loved);
        const count: f64 = @floatFromInt(candidate.play_count);
        item.* = rankedFrom(candidate, count * (1 + jitter(candidate.recording_id, mix.seed) / 2), reasonFor(candidate, &profile, weights, mix.now_s));
    }
    std.mem.sort(Ranked, items, {}, struct {
        fn lessThan(_: void, a: Ranked, b: Ranked) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.recording_id < b.recording_id;
        }
    }.lessThan);
    return .{ .items = items, .relaxed_recent = false };
}

const rarely_played_sql =
    "SELECT tracks.recording_id FROM tracks JOIN recording_play_stats AS rarely ON rarely.recording_id = tracks.recording_id\n" ++
    "WHERE rarely.play_count > 0 AND rarely.last_played_at <= ?8 AND " ++ eligible ++ "\n" ++
    "GROUP BY tracks.recording_id ORDER BY max(rarely.play_count) DESC, tracks.recording_id LIMIT " ++
    std.fmt.comptimePrint("{d}", .{max_pool}) ++ ";";

fn rankedFrom(candidate: *const Candidate, value: f64, reason: PickReason) Ranked {
    return .{
        .track_id = candidate.track_id,
        .recording_id = candidate.recording_id,
        .artist_id = candidate.artist_id,
        .release_id = candidate.release_id,
        .score = value,
        .reason = reason,
        .loved = candidate.loved,
        .rating = candidate.rating,
        .play_count = candidate.play_count,
        .last_played_at = candidate.last_played_at,
    };
}

fn buildClusterProfile(arena: std.mem.Allocator, library: *const Source, cluster: Cluster, now_s: i64) !Profile {
    const db = library.database;
    var statement = try db.prepare(seedTracksSql("tracks.artist_id IN (SELECT value FROM json_each(?1))"));
    defer statement.deinit();
    try statement.bindText(1, try jsonIds(arena, cluster.artists));
    var tracks: std.ArrayList(SeedTrack) = .empty;
    while (try statement.step() == .row) try tracks.append(arena, .{
        .track_id = statement.columnInt64(0),
        .recording_id = statement.columnInt64(1),
        .artist_id = optionalInt64(statement, 2),
        .year = optionalInt64(statement, 3),
    });

    var profile: Profile = .{ .seed = .{ .genre = cluster.genre_id }, .seed_tracks = tracks.items, .own_artists = true };
    try profileArtists(arena, library, &profile);
    for (cluster.artists) |artist| try profile.artists.put(arena, artist, 1);
    try profileGenres(arena, db, &profile);
    profileYears(arena, &profile);
    try profileSound(arena, library, &profile);
    profile.colisten = try loadCoListening(arena, db, tracks.items, now_s);
    return profile;
}

/// Recordings with a present file that a Daily Mix left out, each counted
/// under the first of hated, Not for me, live and recently played that
/// applies.
pub const LeftOut = struct {
    hated: u32 = 0,
    not_for_me: u32 = 0,
    live: u32 = 0,
    recent: u32 = 0,
};

/// Which Recordings `leftOut` counts.
pub const LeftOutScope = union(enum) {
    /// Recordings by these Artists.
    artists: []const i64,
    /// Recordings played at least once but not since this time.
    unplayed_since: i64,
};

/// Counts the Recordings in `scope` the mix exclusions left out. Recently
/// played ones count only under `avoid_after`, null when the avoid window
/// was off or relaxed.
pub fn leftOut(arena: std.mem.Allocator, library: *const Source, scope: LeftOutScope, now_s: i64, avoid_after: ?i64) !LeftOut {
    var statement = try library.database.prepare(switch (scope) {
        .artists => leftOutSql("tracks.artist_id IN (SELECT value FROM json_each(?2))"),
        .unplayed_since => leftOutSql("tracks.recording_id IN (SELECT recording_id FROM recording_play_stats\n" ++
            "    WHERE play_count > 0 AND last_played_at <= ?2)"),
    });
    defer statement.deinit();
    try statement.bindInt64(1, now_s);
    switch (scope) {
        .artists => |ids| try statement.bindText(2, try jsonIds(arena, ids)),
        .unplayed_since => |since| try statement.bindInt64(2, since),
    }
    try statement.bindOptionalInt64(3, avoid_after);
    if (try statement.step() != .row) return .{};
    return .{
        .hated = @intCast(statement.columnInt64(0)),
        .not_for_me = @intCast(statement.columnInt64(1)),
        .live = @intCast(statement.columnInt64(2)),
        .recent = @intCast(statement.columnInt64(3)),
    };
}

fn leftOutSql(comptime scope: []const u8) [:0]const u8 {
    return "SELECT COALESCE(sum(hated), 0), COALESCE(sum(NOT hated AND not_for_me), 0),\n" ++
        "    COALESCE(sum(NOT hated AND NOT not_for_me AND live), 0),\n" ++
        "    COALESCE(sum(NOT hated AND NOT not_for_me AND NOT live AND recent), 0)\n" ++
        "FROM (SELECT tracks.recording_id,\n" ++
        "    EXISTS (SELECT 1 FROM feedback WHERE feedback.recording_id = tracks.recording_id AND feedback.score = -1) AS hated,\n" ++
        "    EXISTS (SELECT 1 FROM recommendation_feedback AS not_for_me\n" ++
        "        WHERE not_for_me.recording_id = tracks.recording_id AND not_for_me.expires_at > ?1) AS not_for_me,\n" ++
        "    min(tracks.release_id IS NOT NULL AND EXISTS (SELECT 1 FROM releases AS live\n" ++
        "        WHERE live.id = tracks.release_id AND (" ++ live_release ++ "))) AS live,\n" ++
        "    ?3 IS NOT NULL AND EXISTS (SELECT 1 FROM recording_play_stats AS recent\n" ++
        "        WHERE recent.recording_id = tracks.recording_id AND recent.last_played_at > ?3) AS recent\n" ++
        "  FROM tracks WHERE tracks.recording_id IS NOT NULL AND (" ++ scope ++ ")\n" ++
        "    AND EXISTS (SELECT 1 FROM locations WHERE locations.file_id = " ++ track_play_file ++ " AND locations.state = 'present')\n" ++
        "  GROUP BY tracks.recording_id);";
}

pub fn validateRadio(seed: Seed, options: RadioOptions) !void {
    if (options.explore > 100) return error.InvalidExplore;
    switch (seed) {
        .decade => |year| if (!validDecade(year)) return error.InvalidDecade,
        else => {},
    }
    for (options.focus) |focus| if (focus) |f| switch (f) {
        .decade => |year| if (!validDecade(year)) return error.InvalidDecade,
        else => {},
    };
}

fn validDecade(year: i64) bool {
    return year >= 0 and year <= 9990 and @mod(year, 10) == 0;
}

fn focusValues(arena: std.mem.Allocator, options: RadioOptions, comptime kind: std.meta.Tag(Focus)) []const i64 {
    var values: [max_focus]i64 = undefined;
    var count: usize = 0;
    for (options.focus) |focus| if (focus) |f| if (f == kind) {
        values[count] = @field(f, @tagName(kind));
        count += 1;
    };
    return arena.dupe(i64, values[0..count]) catch &.{};
}

const EnergyFocus = struct { low: bool = false, high: bool = false };

fn energyFocus(options: RadioOptions) EnergyFocus {
    var result: EnergyFocus = .{};
    for (options.focus) |focus| if (focus) |f| switch (f) {
        .low_energy => result.low = true,
        .high_energy => result.high = true,
        else => {},
    };
    return result;
}

fn energyMatches(focus: EnergyFocus, features: ?AudioFeatures) bool {
    if (!focus.low and !focus.high) return true;
    const energy = (features orelse return false).energy orelse return false;
    return (focus.low and energy < 1.0 / 3.0) or (focus.high and energy >= 2.0 / 3.0);
}

fn requireSeed(db: sqlite.Database, seed: Seed) !void {
    const sql: [:0]const u8, const id = switch (seed) {
        .track => |id| .{ "SELECT 1 FROM tracks WHERE id = ?1;", id },
        .release => |id| .{ "SELECT 1 FROM releases WHERE id = ?1;", id },
        .artist => |id| .{ "SELECT 1 FROM artists WHERE id = ?1;", id },
        .genre => |id| .{ "SELECT 1 FROM genres WHERE id = ?1;", id },
        .decade, .loved, .recent => return,
    };
    var statement = try db.prepare(sql);
    defer statement.deinit();
    try statement.bindInt64(1, id);
    if (try statement.step() != .row) return error.UnknownRadioSeed;
}

const SeedTrack = struct {
    track_id: i64,
    recording_id: i64,
    artist_id: ?i64,
    year: ?i64,
};

const Related = struct {
    value: f64,
    via: i64,
};

const ProfileGenre = struct {
    id: i64,
    weight: f64,
};

const Profile = struct {
    seed: Seed,
    seed_tracks: []const SeedTrack,
    /// Whether the seed's own Artists are named as "same artist".
    own_artists: bool,
    artists: std.AutoHashMapUnmanaged(i64, f64) = .empty,
    related: std.AutoHashMapUnmanaged(i64, Related) = .empty,
    genres: std.AutoHashMapUnmanaged(i64, f64) = .empty,
    genre_order: []const ProfileGenre = &.{},
    year_low: ?i64 = null,
    year_high: ?i64 = null,
    sound: Sound = .{},
    colisten: CoListening = .{},
};

const year_of_track_release =
    "CASE WHEN substr(track_release.release_date, 1, 4) GLOB '[0-9][0-9][0-9][0-9]' " ++
    "THEN CAST(substr(track_release.release_date, 1, 4) AS INTEGER) END";

const bare_release_year =
    "CASE WHEN substr(release_date, 1, 4) GLOB '[0-9][0-9][0-9][0-9]' " ++
    "THEN CAST(substr(release_date, 1, 4) AS INTEGER) END";

fn seedTracksSql(comptime where: []const u8) [:0]const u8 {
    return "SELECT tracks.id, tracks.recording_id, tracks.artist_id, " ++ year_of_track_release ++ "\n" ++
        "FROM tracks LEFT JOIN releases AS track_release ON track_release.id = tracks.release_id\n" ++
        "LEFT JOIN recording_play_stats AS stats ON stats.recording_id = tracks.recording_id\n" ++
        "WHERE tracks.recording_id IS NOT NULL AND (" ++ where ++ ")\n" ++
        "ORDER BY COALESCE(stats.play_count, 0) DESC, tracks.id LIMIT " ++ std.fmt.comptimePrint("{d}", .{max_seed_tracks}) ++ ";";
}

fn buildProfile(arena: std.mem.Allocator, library: *const Source, seed: Seed, now_s: i64) !Profile {
    const db = library.database;
    var statement = try db.prepare(switch (seed) {
        .track => seedTracksSql("tracks.id = ?1"),
        .release => seedTracksSql("tracks.release_id = ?1"),
        .artist => seedTracksSql("tracks.artist_id = ?1"),
        .genre => seedTracksSql("tracks.id IN (SELECT track_id FROM track_genres WHERE genre_id = ?1)"),
        .decade => seedTracksSql("tracks.release_id IN (SELECT id FROM releases WHERE " ++ bare_release_year ++ " BETWEEN ?1 AND ?1 + 9)"),
        .loved => seedTracksSql("tracks.recording_id IN (SELECT recording_id FROM feedback WHERE score = 1)"),
        .recent => seedTracksSql(
            "tracks.id IN (SELECT (SELECT min(heard_track.id) FROM tracks AS heard_track\n" ++
                "        WHERE heard_track.recording_id = heard.recording_id)\n" ++
                "    FROM (SELECT recording_id, max(started_at) AS last_heard\n" ++
                "        FROM (SELECT recording_id, started_at FROM listens\n" ++
                "            WHERE started_at <= ?1 AND recording_id IS NOT NULL\n" ++
                "            ORDER BY started_at DESC LIMIT 50)\n" ++
                "        GROUP BY recording_id ORDER BY last_heard DESC LIMIT " ++
                std.fmt.comptimePrint("{d}", .{recent_seed_tracks}) ++ ") AS heard)",
        ),
    });
    defer statement.deinit();
    switch (seed) {
        .track, .release, .artist, .genre, .decade => |id| try statement.bindInt64(1, id),
        .recent => try statement.bindInt64(1, now_s),
        .loved => {},
    }
    var tracks: std.ArrayList(SeedTrack) = .empty;
    while (try statement.step() == .row) try tracks.append(arena, .{
        .track_id = statement.columnInt64(0),
        .recording_id = statement.columnInt64(1),
        .artist_id = optionalInt64(statement, 2),
        .year = optionalInt64(statement, 3),
    });

    var profile: Profile = .{
        .seed = seed,
        .seed_tracks = tracks.items,
        .own_artists = switch (seed) {
            .track, .release, .artist, .recent => true,
            .genre, .decade, .loved => false,
        },
    };
    try profileArtists(arena, library, &profile);
    try profileGenres(arena, db, &profile);
    profileYears(arena, &profile);
    try profileSound(arena, library, &profile);
    profile.colisten = try loadCoListening(arena, db, tracks.items, now_s);
    return profile;
}

fn profileArtists(arena: std.mem.Allocator, library: *const Source, profile: *Profile) !void {
    var counts: std.AutoHashMapUnmanaged(i64, f64) = .empty;
    for (profile.seed_tracks) |track| if (track.artist_id) |artist| {
        const entry = try counts.getOrPut(arena, artist);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    };
    if (profile.seed == .artist) try counts.put(arena, profile.seed.artist, 1);

    var ranked: std.ArrayList(ProfileGenre) = .empty;
    var it = counts.iterator();
    var most: f64 = 0;
    while (it.next()) |entry| {
        try ranked.append(arena, .{ .id = entry.key_ptr.*, .weight = entry.value_ptr.* });
        most = @max(most, entry.value_ptr.*);
    }
    if (profile.own_artists) {
        for (ranked.items) |*item| item.weight = 1;
    } else if (most > 0) {
        for (ranked.items) |*item| item.weight /= most;
    }
    if (profile.seed == .loved) {
        var loved = try library.database.prepare("SELECT artist_id FROM artist_loves ORDER BY loved_at DESC, artist_id LIMIT 64;");
        defer loved.deinit();
        while (try loved.step() == .row) {
            const id = loved.columnInt64(0);
            for (ranked.items) |*item| {
                if (item.id == id) {
                    item.weight = 1;
                    break;
                }
            } else try ranked.append(arena, .{ .id = id, .weight = 1 });
        }
    }
    std.mem.sort(ProfileGenre, ranked.items, {}, heavierFirst);
    const kept = ranked.items[0..@min(ranked.items.len, max_seed_artists)];
    for (kept) |item| try profile.artists.put(arena, item.id, item.weight);

    for (kept[0..@min(kept.len, max_related_sources)]) |source| {
        const related = try library.artist_info.related(arena, source.id);
        var best: u32 = 0;
        for (related.items) |item| best = @max(best, item.score);
        if (best == 0) continue;
        for (related.items) |item| {
            const id = item.library_artist_id orelse continue;
            const value = @as(f64, @floatFromInt(item.score)) / @as(f64, @floatFromInt(best)) * 0.8 * source.weight;
            const entry = try profile.related.getOrPut(arena, id);
            if (!entry.found_existing or entry.value_ptr.value < value or
                (entry.value_ptr.value == value and source.id < entry.value_ptr.via))
                entry.value_ptr.* = .{ .value = value, .via = source.id };
        }
    }
}

fn heavierFirst(_: void, a: ProfileGenre, b: ProfileGenre) bool {
    if (a.weight != b.weight) return a.weight > b.weight;
    return a.id < b.id;
}

fn genreWeight(ordinal: i64) f64 {
    return if (ordinal == 0) 1 else 0.5;
}

fn profileGenres(arena: std.mem.Allocator, db: sqlite.Database, profile: *Profile) !void {
    var ids: std.ArrayList(i64) = .empty;
    for (profile.seed_tracks) |track| try ids.append(arena, track.track_id);
    var statement = try db.prepare("SELECT genre_id, ordinal FROM track_genres WHERE track_id IN (SELECT value FROM json_each(?1));");
    defer statement.deinit();
    try statement.bindText(1, try jsonIds(arena, ids.items));
    var sums: std.AutoHashMapUnmanaged(i64, f64) = .empty;
    while (try statement.step() == .row) {
        const entry = try sums.getOrPut(arena, statement.columnInt64(0));
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += genreWeight(statement.columnInt64(1));
    }
    if (profile.seed == .genre) {
        const entry = try sums.getOrPut(arena, profile.seed.genre);
        if (!entry.found_existing) entry.value_ptr.* = 1;
        entry.value_ptr.* = std.math.inf(f64);
    }
    var ranked: std.ArrayList(ProfileGenre) = .empty;
    var it = sums.iterator();
    while (it.next()) |entry| try ranked.append(arena, .{ .id = entry.key_ptr.*, .weight = entry.value_ptr.* });
    std.mem.sort(ProfileGenre, ranked.items, {}, heavierFirst);
    const kept = ranked.items[0..@min(ranked.items.len, max_profile_genres)];
    var most: f64 = 0;
    for (kept) |item| if (std.math.isFinite(item.weight)) {
        most = @max(most, item.weight);
    };
    for (kept) |*item| {
        item.weight = if (!std.math.isFinite(item.weight) or most == 0) 1 else item.weight / most;
        try profile.genres.put(arena, item.id, item.weight);
    }
    profile.genre_order = kept;
}

fn profileYears(arena: std.mem.Allocator, profile: *Profile) void {
    if (profile.seed == .decade) {
        profile.year_low = profile.seed.decade;
        profile.year_high = profile.seed.decade + 9;
        return;
    }
    var years: std.ArrayList(i64) = .empty;
    for (profile.seed_tracks) |track| if (track.year) |year| years.append(arena, year) catch return;
    if (years.items.len == 0) return;
    std.mem.sort(i64, years.items, {}, std.sort.asc(i64));
    const last = years.items.len - 1;
    profile.year_low = years.items[last / 4];
    profile.year_high = years.items[(last * 3 + 3) / 4];
}

fn profileSound(arena: std.mem.Allocator, library: *const Source, profile: *Profile) !void {
    const ids = try arena.alloc(i64, profile.seed_tracks.len);
    for (profile.seed_tracks, ids) |track, *id| id.* = track.track_id;
    const features = try arena.alloc(?AudioFeatures, ids.len);
    try library.audio_features.tracksFeatures(arena, ids, features);

    var tempos: std.ArrayList(f64) = .empty;
    var keys: [24]u32 = @splat(0);
    var energy_sum: f64 = 0;
    var energy_count: usize = 0;
    for (features) |maybe| {
        const f = maybe orelse continue;
        if (f.tempo) |tempo| try tempos.append(arena, tempo.bpm);
        if (f.key) |key| keys[@as(usize, key.pitch) * 2 + @backingInt(key.mode)] += 1;
        if (f.energy) |energy| {
            energy_sum += energy;
            energy_count += 1;
        }
    }
    if (tempos.items.len > 0) {
        std.mem.sort(f64, tempos.items, {}, std.sort.asc(f64));
        profile.sound.tempo = tempos.items[(tempos.items.len - 1) / 2];
    }
    var best: usize = 0;
    for (keys, 0..) |count, index| if (count > keys[best]) {
        best = index;
    };
    if (keys[best] > 0) profile.sound.key = .{
        .pitch = @intCast(best / 2),
        .mode = @fromBackingInt(@intCast(best % 2)),
        .confidence = 1,
    };
    if (energy_count > 0) profile.sound.energy = energy_sum / @as(f64, @floatFromInt(energy_count));
}

const Follow = struct {
    seed_listen: i64,
    seed_recording: i64,
    recording_id: i64,
    artist_id: ?i64,
};

const CoListening = struct {
    seed_listens: usize = 0,
    follows: []const Follow = &.{},
    by_recording: std.AutoHashMapUnmanaged(i64, std.ArrayList(i64)) = .empty,
    by_artist: std.AutoHashMapUnmanaged(i64, std.ArrayList(i64)) = .empty,

    fn count(self: *const CoListening, recording_id: i64, artist_id: ?i64) usize {
        const empty: []const i64 = &.{};
        const a = if (self.by_recording.get(recording_id)) |list| list.items else empty;
        const b = if (artist_id) |id| (if (self.by_artist.get(id)) |list| list.items else empty) else empty;
        var i: usize = 0;
        var j: usize = 0;
        var total: usize = 0;
        while (i < a.len or j < b.len) : (total += 1) {
            if (j == b.len or (i < a.len and a[i] < b[j])) {
                i += 1;
            } else if (i == a.len or b[j] < a[i]) {
                j += 1;
            } else {
                i += 1;
                j += 1;
            }
        }
        return total;
    }
};

const colisten_sql =
    "WITH heard AS (SELECT id, recording_id, started_at FROM listens\n" ++
    "    WHERE recording_id IN (SELECT value FROM json_each(?1))\n" ++
    "      AND started_at > ?2 - " ++ std.fmt.comptimePrint("{d}", .{colisten_history_s}) ++ " AND started_at <= ?2\n" ++
    "    ORDER BY started_at DESC, id LIMIT " ++ std.fmt.comptimePrint("{d}", .{max_seed_listens}) ++ ")\n" ++
    "SELECT heard.id, heard.recording_id, next.recording_id,\n" ++
    "    (SELECT next_track.artist_id FROM tracks AS next_track\n" ++
    "     WHERE next_track.recording_id = next.recording_id ORDER BY next_track.id LIMIT 1)\n" ++
    "FROM heard LEFT JOIN listens AS next ON next.started_at > heard.started_at\n" ++
    "    AND next.started_at <= heard.started_at + " ++ std.fmt.comptimePrint("{d}", .{colisten_window_s}) ++ "\n" ++
    "    AND next.recording_id IS NOT NULL AND next.recording_id <> heard.recording_id\n" ++
    "ORDER BY heard.id, next.started_at, next.id LIMIT " ++ std.fmt.comptimePrint("{d}", .{max_colisten_rows}) ++ ";";

fn loadCoListening(arena: std.mem.Allocator, db: sqlite.Database, seed_tracks: []const SeedTrack, now_s: i64) !CoListening {
    var result: CoListening = .{};
    if (seed_tracks.len == 0) return result;
    var recordings: std.ArrayList(i64) = .empty;
    for (seed_tracks) |track| try recordings.append(arena, track.recording_id);
    var statement = try db.prepare(colisten_sql);
    defer statement.deinit();
    try statement.bindText(1, try jsonIds(arena, recordings.items));
    try statement.bindInt64(2, now_s);
    var follows: std.ArrayList(Follow) = .empty;
    var last_listen: ?i64 = null;
    while (try statement.step() == .row) {
        const listen = statement.columnInt64(0);
        if (last_listen != listen) {
            result.seed_listens += 1;
            last_listen = listen;
        }
        if (statement.columnIsNull(2)) continue;
        const follow: Follow = .{
            .seed_listen = listen,
            .seed_recording = statement.columnInt64(1),
            .recording_id = statement.columnInt64(2),
            .artist_id = optionalInt64(statement, 3),
        };
        try follows.append(arena, follow);
        try appendListen(arena, &result.by_recording, follow.recording_id, listen);
        if (follow.artist_id) |artist| try appendListen(arena, &result.by_artist, artist, listen);
    }
    result.follows = follows.items;
    return result;
}

fn appendListen(arena: std.mem.Allocator, map: *std.AutoHashMapUnmanaged(i64, std.ArrayList(i64)), key: i64, listen: i64) !void {
    const entry = try map.getOrPut(arena, key);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    const list = entry.value_ptr;
    if (list.items.len == 0 or list.items[list.items.len - 1] != listen) try list.append(arena, listen);
}

const Filter = struct {
    now_s: i64,
    include_live: bool,
    focus_genres: []const u8,
    focus_decades: []const u8,
    avoid_after: ?i64,
    require_played: bool,
    excluded: []const u8,
    jitter_seed: i64,

    fn bind(self: *const Filter, statement: sqlite.Statement) !void {
        try statement.bindInt64(1, self.now_s);
        try statement.bindInt64(2, @intFromBool(self.include_live));
        try statement.bindText(3, self.focus_genres);
        try statement.bindText(4, self.focus_decades);
        try statement.bindOptionalInt64(5, self.avoid_after);
        try statement.bindInt64(6, @intFromBool(self.require_played));
        try statement.bindText(7, self.excluded);
    }
};

fn yearOf(comptime alias: []const u8) []const u8 {
    return "CASE WHEN substr(" ++ alias ++ ".release_date, 1, 4) GLOB '[0-9][0-9][0-9][0-9]' " ++
        "THEN CAST(substr(" ++ alias ++ ".release_date, 1, 4) AS INTEGER) END";
}

const live_release =
    "(' ' || replace(replace(replace(lower(COALESCE(live.release_type, '')), '+', ' '), ',', ' '), ';', ' ') || ' ') LIKE '% live %'\n" ++
    "    OR lower(live.title) LIKE '%(live%' OR lower(live.title) LIKE '%[live%' OR lower(live.title) LIKE '%live album%'";

const eligible =
    "tracks.recording_id IS NOT NULL\n" ++
    "  AND EXISTS (SELECT 1 FROM locations WHERE locations.file_id = " ++ track_play_file ++ " AND locations.state = 'present')\n" ++
    "  AND NOT EXISTS (SELECT 1 FROM feedback WHERE feedback.recording_id = tracks.recording_id AND feedback.score = -1)\n" ++
    "  AND NOT EXISTS (SELECT 1 FROM recommendation_feedback AS not_for_me\n" ++
    "      WHERE not_for_me.recording_id = tracks.recording_id AND not_for_me.expires_at > ?1)\n" ++
    "  AND (?2 OR tracks.release_id IS NULL OR NOT EXISTS (SELECT 1 FROM releases AS live\n" ++
    "      WHERE live.id = tracks.release_id AND (" ++ live_release ++ ")))\n" ++
    "  AND (json_array_length(?3) = 0 OR EXISTS (SELECT 1 FROM track_genres AS focus_genre\n" ++
    "      WHERE focus_genre.track_id = tracks.id AND focus_genre.genre_id IN (SELECT value FROM json_each(?3))))\n" ++
    "  AND (json_array_length(?4) = 0 OR EXISTS (SELECT 1 FROM releases AS focus_release, json_each(?4) AS decade\n" ++
    "      WHERE focus_release.id = tracks.release_id\n" ++
    "        AND " ++ yearOf("focus_release") ++ " BETWEEN decade.value AND decade.value + 9))\n" ++
    "  AND (?5 IS NULL OR NOT EXISTS (SELECT 1 FROM recording_play_stats AS recent\n" ++
    "      WHERE recent.recording_id = tracks.recording_id AND recent.last_played_at > ?5))\n" ++
    "  AND (?6 = 0 OR EXISTS (SELECT 1 FROM recording_play_stats AS played\n" ++
    "      WHERE played.recording_id = tracks.recording_id AND played.play_count > 0))\n" ++
    "  AND tracks.recording_id NOT IN (SELECT value FROM json_each(?7))";

fn bucketSql(comptime condition: []const u8) [:0]const u8 {
    return "SELECT tracks.recording_id FROM tracks WHERE (" ++ condition ++ ") AND " ++ eligible ++ "\n" ++
        "GROUP BY tracks.recording_id ORDER BY (tracks.recording_id * 2654435761 + ?9) % 4294967311, tracks.recording_id LIMIT ?10;";
}

const bucket_artists = bucketSql("tracks.artist_id IN (SELECT value FROM json_each(?8))");
const bucket_genres = bucketSql("tracks.id IN (SELECT track_id FROM track_genres WHERE genre_id IN (SELECT value FROM json_each(?8)))");
const bucket_recordings = bucketSql("tracks.recording_id IN (SELECT value FROM json_each(?8))");
const bucket_tempo = bucketSql(
    \\tracks.recording_id IN (SELECT files.recording_id FROM file_audio_features AS near
    \\    JOIN files ON files.id = near.file_id
    \\    WHERE near.tempo_bpm BETWEEN ?8 * 0.9 AND ?8 * 1.1
    \\       OR near.tempo_bpm BETWEEN ?8 * 1.8 AND ?8 * 2.2
    \\       OR near.tempo_bpm BETWEEN ?8 * 0.45 AND ?8 * 0.55)
);
const bucket_era = bucketSql("tracks.release_id IN (SELECT id FROM releases WHERE " ++ bare_release_year ++
    " BETWEEN json_extract(?8, '$[0]') AND json_extract(?8, '$[1]'))");
const bucket_any = bucketSql("?8 IS NULL");

const Pool = struct {
    ids: std.ArrayList(i64) = .empty,
    seen: std.AutoHashMapUnmanaged(i64, void) = .empty,

    fn add(self: *Pool, arena: std.mem.Allocator, db: sqlite.Database, comptime sql: [:0]const u8, filter: *const Filter, argument: anytype, quota: usize) !void {
        if (self.ids.items.len >= max_pool or quota == 0) return;
        var statement = try db.prepare(sql);
        defer statement.deinit();
        try filter.bind(statement);
        switch (@TypeOf(argument)) {
            []const u8 => try statement.bindText(8, argument),
            f64 => try statement.bindDouble(8, argument),
            @TypeOf(null) => try statement.bindOptionalInt64(8, null),
            else => @compileError("unsupported bucket argument"),
        }
        try statement.bindInt64(9, filter.jitter_seed);
        try statement.bindInt64(10, @intCast(quota));
        while (try statement.step() == .row) {
            if (self.ids.items.len >= max_pool) break;
            const id = statement.columnInt64(0);
            const entry = try self.seen.getOrPut(arena, id);
            if (!entry.found_existing) try self.ids.append(arena, id);
        }
    }
};

const Candidate = struct {
    recording_id: i64,
    track_id: i64,
    artist_id: ?i64,
    release_id: ?i64,
    year: ?i64,
    loved: bool,
    rating: ?i64,
    release_or_artist_loved: bool,
    play_count: i64,
    last_played_at: ?i64,
    added_at: i64,
    genres: []const GenreOnTrack = &.{},
    features: ?AudioFeatures = null,
    components: Components = .{},
    score: f64 = 0,
    sound_flags: i64 = 0,
    shared_genre: ?i64 = null,
};

const GenreOnTrack = struct {
    id: i64,
    ordinal: i64,
};

const details_sql =
    "WITH pool(recording_id) AS (SELECT value FROM json_each(?8)),\n" ++
    "chosen(recording_id, track_id) AS (SELECT pool.recording_id,\n" ++
    "    (SELECT min(tracks.id) FROM tracks WHERE tracks.recording_id = pool.recording_id AND " ++ eligible ++ ")\n" ++
    "    FROM pool)\n" ++
    "SELECT chosen.recording_id, tracks.id, tracks.artist_id, tracks.release_id, " ++ year_of_track_release ++ ",\n" ++
    "    EXISTS (SELECT 1 FROM feedback WHERE feedback.recording_id = chosen.recording_id AND feedback.score = 1),\n" ++
    "    (SELECT rating FROM ratings WHERE ratings.recording_id = chosen.recording_id),\n" ++
    "    EXISTS (SELECT 1 FROM release_loves WHERE release_loves.release_id = tracks.release_id)\n" ++
    "        OR EXISTS (SELECT 1 FROM artist_loves WHERE artist_loves.artist_id = tracks.artist_id),\n" ++
    "    COALESCE(stats.play_count, 0), stats.last_played_at, tracks.created_at\n" ++
    "FROM chosen JOIN tracks ON tracks.id = chosen.track_id\n" ++
    "LEFT JOIN releases AS track_release ON track_release.id = tracks.release_id\n" ++
    "LEFT JOIN recording_play_stats AS stats ON stats.recording_id = chosen.recording_id\n" ++
    "ORDER BY chosen.recording_id;";

fn loadCandidates(
    arena: std.mem.Allocator,
    library: *const Source,
    profile: *const Profile,
    filter: *const Filter,
    energy_focus: EnergyFocus,
) ![]Candidate {
    const db = library.database;
    var pool: Pool = .{};

    var artists: std.ArrayList(i64) = .empty;
    for (profile.seed_tracks) |track| if (track.artist_id) |id| try artists.append(arena, id);
    var artist_it = profile.artists.keyIterator();
    while (artist_it.next()) |id| try artists.append(arena, id.*);
    var related_it = profile.related.keyIterator();
    while (related_it.next()) |id| try artists.append(arena, id.*);
    std.mem.sort(i64, artists.items, {}, std.sort.asc(i64));
    if (artists.items.len > 0) try pool.add(arena, db, bucket_artists, filter, try jsonIds(arena, artists.items), 600);

    var genres: std.ArrayList(i64) = .empty;
    for (profile.genre_order[0..@min(profile.genre_order.len, max_bucket_genres)]) |genre| try genres.append(arena, genre.id);
    if (genres.items.len > 0) try pool.add(arena, db, bucket_genres, filter, try jsonIds(arena, genres.items), 600);

    if (profile.colisten.follows.len > 0) {
        const recordings = try topKeys(arena, &profile.colisten.by_recording, 300);
        try pool.add(arena, db, bucket_recordings, filter, try jsonIds(arena, recordings), 300);
        const followed_artists = try topKeys(arena, &profile.colisten.by_artist, 20);
        try pool.add(arena, db, bucket_artists, filter, try jsonIds(arena, followed_artists), 200);
    }

    if (profile.sound.tempo) |tempo| try pool.add(arena, db, bucket_tempo, filter, tempo, 300);
    if (profile.year_low) |low| {
        const range = try std.fmt.allocPrint(arena, "[{d},{d}]", .{ low - 5, profile.year_high.? + 5 });
        try pool.add(arena, db, bucket_era, filter, @as([]const u8, range), 200);
    }
    try pool.add(arena, db, bucket_any, filter, null, max_pool - @min(pool.ids.items.len, max_pool));
    return candidateDetails(arena, library, filter, pool.ids.items, energy_focus);
}

fn candidateDetails(
    arena: std.mem.Allocator,
    library: *const Source,
    filter: *const Filter,
    recording_ids: []const i64,
    energy_focus: EnergyFocus,
) ![]Candidate {
    const db = library.database;
    var candidates: std.ArrayList(Candidate) = .empty;
    if (recording_ids.len == 0) return candidates.items;
    var details = try db.prepare(details_sql);
    defer details.deinit();
    try filter.bind(details);
    try details.bindText(8, try jsonIds(arena, recording_ids));
    while (try details.step() == .row) try candidates.append(arena, .{
        .recording_id = details.columnInt64(0),
        .track_id = details.columnInt64(1),
        .artist_id = optionalInt64(details, 2),
        .release_id = optionalInt64(details, 3),
        .year = optionalInt64(details, 4),
        .loved = details.columnInt64(5) != 0,
        .rating = optionalInt64(details, 6),
        .release_or_artist_loved = details.columnInt64(7) != 0,
        .play_count = details.columnInt64(8),
        .last_played_at = optionalInt64(details, 9),
        .added_at = details.columnInt64(10),
    });

    const track_ids = try arena.alloc(i64, candidates.items.len);
    var index_of: std.AutoHashMapUnmanaged(i64, usize) = .empty;
    for (candidates.items, track_ids, 0..) |candidate, *id, index| {
        id.* = candidate.track_id;
        try index_of.put(arena, candidate.track_id, index);
    }
    const features = try arena.alloc(?AudioFeatures, track_ids.len);
    try library.audio_features.tracksFeatures(arena, track_ids, features);
    for (candidates.items, features) |*candidate, f| candidate.features = f;

    var genre_rows = try db.prepare(
        "SELECT track_id, genre_id, ordinal FROM track_genres WHERE track_id IN (SELECT value FROM json_each(?1)) ORDER BY track_id, ordinal;",
    );
    defer genre_rows.deinit();
    try genre_rows.bindText(1, try jsonIds(arena, track_ids));
    var lists = try arena.alloc(std.ArrayList(GenreOnTrack), candidates.items.len);
    @memset(lists, .empty);
    while (try genre_rows.step() == .row) {
        const index = index_of.get(genre_rows.columnInt64(0)) orelse continue;
        try lists[index].append(arena, .{ .id = genre_rows.columnInt64(1), .ordinal = genre_rows.columnInt64(2) });
    }
    for (candidates.items, lists) |*candidate, list| candidate.genres = list.items;

    var kept: usize = 0;
    for (candidates.items) |candidate| {
        if (!energyMatches(energy_focus, candidate.features)) continue;
        candidates.items[kept] = candidate;
        kept += 1;
    }
    return candidates.items[0..kept];
}

fn topKeys(arena: std.mem.Allocator, map: *const std.AutoHashMapUnmanaged(i64, std.ArrayList(i64)), limit: usize) ![]i64 {
    const Entry = struct { id: i64, count: usize };
    var entries: std.ArrayList(Entry) = .empty;
    var it = map.iterator();
    while (it.next()) |entry| try entries.append(arena, .{ .id = entry.key_ptr.*, .count = entry.value_ptr.items.len });
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            if (a.count != b.count) return a.count > b.count;
            return a.id < b.id;
        }
    }.lessThan);
    const kept = entries.items[0..@min(entries.items.len, limit)];
    const ids = try arena.alloc(i64, kept.len);
    for (kept, ids) |entry, *id| id.* = entry.id;
    return ids;
}

fn score(candidate: *Candidate, profile: *const Profile, weights: Components, session: Session) void {
    var components: Components = .{};
    if (candidate.artist_id) |artist| {
        const direct = profile.artists.get(artist) orelse 0;
        const related = if (profile.related.get(artist)) |r| r.value else 0;
        components.artist = @max(direct, related);
    }

    var genre_sum: f64 = 0;
    var genre_weight: f64 = 0;
    var best_shared: f64 = 0;
    for (candidate.genres) |genre| {
        const w = genreWeight(genre.ordinal);
        genre_weight += w;
        if (profile.genres.get(genre.id)) |p| {
            genre_sum += w * p;
            if (p > best_shared or (p == best_shared and candidate.shared_genre != null and genre.id < candidate.shared_genre.?)) {
                best_shared = p;
                candidate.shared_genre = genre.id;
            }
        }
    }
    if (genre_weight > 0) components.genre = genre_sum / genre_weight;

    if (!profile.sound.isEmpty()) {
        const audio = audioScore(profile.sound, candidate.features);
        components.audio = audio.value;
        candidate.sound_flags = audio.flags;
    }

    if (profile.colisten.seed_listens > 0) {
        const count = profile.colisten.count(candidate.recording_id, candidate.artist_id);
        components.co_listening = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(profile.colisten.seed_listens));
    }

    components.era = eraScore(profile.year_low, profile.year_high, candidate.year);
    components.taste = tasteScore(candidate.loved, candidate.rating, candidate.release_or_artist_loved);
    components.jitter = jitter(candidate.recording_id, session.seed);

    var total = components.weighted(weights);
    if (candidate.artist_id) |artist| for (session.artist_adjustments) |adjustment| {
        if (adjustment.id == artist) total += adjustment.delta;
    };
    for (session.genre_adjustments) |adjustment| for (candidate.genres) |genre| {
        if (genre.id == adjustment.id) {
            total += adjustment.delta;
            break;
        }
    };
    candidate.components = components;
    candidate.score = total;
}

fn byScore(candidates: []const Candidate, a: u32, b: u32) bool {
    const x = candidates[a];
    const y = candidates[b];
    if (x.score != y.score) return x.score > y.score;
    return x.recording_id < y.recording_id;
}

fn choose(candidates: []const Candidate, order: []const u32, used: []const bool, history: []const RecentPick) ?u32 {
    for ([_]bool{ true, false }) |space_unplayed| {
        for (0..3) |relaxation| {
            for (order) |index| {
                if (used[index]) continue;
                if (allowed(candidates[index], history, relaxation, space_unplayed)) return index;
            }
        }
    }
    return null;
}

fn allowed(candidate: Candidate, history: []const RecentPick, relaxation: usize, space_unplayed: bool) bool {
    if (space_unplayed and candidate.play_count == 0) {
        const window = history[history.len -| (unplayed_window - 1)..];
        for (window) |recent| if (recent.never_played) return false;
    }
    return diverseAt(history, candidate.artist_id, candidate.release_id, relaxation);
}

/// Whether a pick by `artist_id` from `release_id` after `history` keeps to
/// at most 2 consecutive picks by one Artist and 2 from one Release in any
/// 10.
pub fn diverse(history: []const RecentPick, artist_id: ?i64, release_id: ?i64) bool {
    return diverseAt(history, artist_id, release_id, 0);
}

fn diverseAt(history: []const RecentPick, artist_id: ?i64, release_id: ?i64, relaxation: usize) bool {
    if (relaxation < 2) if (artist_id) |artist| {
        if (history.len >= 2 and history[history.len - 1].artist_id == artist and history[history.len - 2].artist_id == artist)
            return false;
    };
    if (relaxation < 1) if (release_id) |release| {
        var same: usize = 0;
        for (history[history.len -| (diversity_window - 1)..]) |recent| {
            if (recent.release_id == release) same += 1;
        }
        if (same >= 2) return false;
    };
    return true;
}

const Contribution = struct {
    strength: f64,
    part: ReasonPart,
};

fn reasonFor(candidate: *const Candidate, profile: *const Profile, weights: Components, now_s: i64) PickReason {
    var options: [6]Contribution = undefined;
    var count: usize = 0;
    const c = candidate.components;

    if (candidate.artist_id) |artist| if (c.artist > 0) {
        if (profile.own_artists and profile.artists.contains(artist)) {
            options[count] = .{ .strength = weights.artist * c.artist, .part = .{ .kind = .same_artist, .a = artist } };
            count += 1;
        } else if (profile.related.get(artist)) |related| if (related.value >= c.artist) {
            options[count] = .{ .strength = weights.artist * c.artist, .part = .{ .kind = .related_artist, .a = related.via, .b = artist } };
            count += 1;
        };
    };
    if (candidate.shared_genre) |genre| if (c.genre > 0) {
        options[count] = .{ .strength = weights.genre * c.genre, .part = .{ .kind = .shared_genre, .a = genre } };
        count += 1;
    };
    if (c.co_listening > 0) if (oftenAfter(candidate, profile)) |part| {
        options[count] = .{ .strength = weights.co_listening * c.co_listening, .part = part };
        count += 1;
    };
    if (candidate.features != null and candidate.sound_flags != 0) {
        options[count] = .{ .strength = weights.audio * c.audio, .part = .{ .kind = .similar_sound, .a = candidate.sound_flags } };
        count += 1;
    }
    if (candidate.loved) {
        options[count] = .{ .strength = weights.taste * c.taste, .part = .{ .kind = .loved } };
        count += 1;
    }

    std.mem.sort(Contribution, options[0..count], {}, struct {
        fn lessThan(_: void, a: Contribution, b: Contribution) bool {
            if (a.strength != b.strength) return a.strength > b.strength;
            return @backingInt(a.part.kind) < @backingInt(b.part.kind);
        }
    }.lessThan);

    var reason: PickReason = .{};
    var parts: [2]?ReasonPart = .{ null, null };
    var filled: usize = 0;
    for (options[0..count]) |option| {
        if (filled == 2) break;
        parts[filled] = option.part;
        filled += 1;
    }
    if (filled < 2) {
        parts[filled] = historyReason(candidate);
        filled += 1;
    }
    if (filled < 2 and candidate.added_at <= now_s and now_s - candidate.added_at <= added_reason_window_s) {
        parts[filled] = .{ .kind = .added, .a = candidate.added_at };
        filled += 1;
    }
    reason.first = parts[0];
    reason.second = parts[1];
    return reason;
}

fn historyReason(candidate: *const Candidate) ReasonPart {
    if (candidate.play_count == 0) return .{ .kind = .never_played };
    if (candidate.play_count <= 2) return .{ .kind = .rarely_played, .a = candidate.play_count };
    return .{ .kind = .played, .a = candidate.play_count, .b = candidate.last_played_at orelse 0 };
}

/// What the candidate was most often played after: the seed Artist for an
/// Artist seed, else the seed Recording. Named only when it happened at
/// least twice.
fn oftenAfter(candidate: *const Candidate, profile: *const Profile) ?ReasonPart {
    const follows = profile.colisten.follows;
    if (profile.seed == .artist) {
        var listens: usize = 0;
        var last: ?i64 = null;
        for (follows) |follow| {
            if (follow.recording_id != candidate.recording_id and
                (candidate.artist_id == null or follow.artist_id != candidate.artist_id)) continue;
            if (last == follow.seed_listen) continue;
            last = follow.seed_listen;
            listens += 1;
        }
        return if (listens >= 2) .{ .kind = .often_after, .a = profile.seed.artist, .b = 1 } else null;
    }
    const Tally = struct { id: i64, count: usize, last_listen: i64 };
    var tallies: [16]Tally = undefined;
    var tallied: usize = 0;
    var best: ?Tally = null;
    for (follows) |follow| {
        if (follow.recording_id != candidate.recording_id) continue;
        var slot: usize = 0;
        while (slot < tallied and tallies[slot].id != follow.seed_recording) slot += 1;
        if (slot == tallied) {
            if (tallied == tallies.len) continue;
            tallies[slot] = .{ .id = follow.seed_recording, .count = 0, .last_listen = -1 };
            tallied += 1;
        }
        const tally = &tallies[slot];
        if (tally.last_listen == follow.seed_listen) continue;
        tally.last_listen = follow.seed_listen;
        tally.count += 1;
        if (best == null or tally.count > best.?.count or (tally.count == best.?.count and tally.id < best.?.id))
            best = tally.*;
    }
    const chosen = best orelse return null;
    return if (chosen.count >= 2) .{ .kind = .often_after, .a = chosen.id, .b = 0 } else null;
}

fn jsonIds(arena: std.mem.Allocator, ids: []const i64) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.append(arena, '[');
    for (ids, 0..) |id, index| try text.print(arena, "{s}{d}", .{ if (index == 0) "" else ",", id });
    try text.append(arena, ']');
    return text.items;
}

const testing = std.testing;
const test_now: i64 = 10_000_000;

fn openFixture(comptime name: []const u8) !database.LibraryDatabase {
    var library = try database.LibraryDatabase.open(testing.allocator, testing.io, "file:orca-test-discovery-" ++ name ++ "?mode=memory&cache=shared");
    errdefer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, key, musicbrainz_artist_id) VALUES
        \\    (1, 'A', 'a', 'mb-a'), (2, 'B', 'b', 'mb-b'), (3, 'C', 'c', 'mb-c'),
        \\    (4, 'D', 'd', 'mb-d'), (5, 'E', 'e', 'mb-e'), (6, 'F', 'f', 'mb-f');
        \\INSERT INTO releases(id, title, album_artist_id, release_date, release_type) VALUES
        \\    (1, 'One', 1, '1990-03-01', 'album'), (2, 'Two', 1, '1992', 'album'),
        \\    (3, 'Three', 2, '1991', 'album'), (4, 'Four', 3, '2005', 'album'),
        \\    (5, 'Five', 4, '2010', 'album'), (6, 'Six', 5, '1975', 'compilation + live'),
        \\    (7, 'Seven', 6, '1999', 'album'), (8, 'Eight', 3, '1994', 'album');
        \\WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 48)
        \\INSERT INTO recordings(id, title) SELECT n, 'r' || n FROM seq;
        \\INSERT INTO files(id, recording_id, size_bytes, quick_hash, content_hash, content_hash_algorithm, channels)
        \\    SELECT id, id, 1, CAST(id AS BLOB), CAST(id AS BLOB), 1, 2 FROM recordings;
        \\INSERT INTO tracks(id, recording_id, release_id, title, artist_id, preferred_file_id, created_at)
        \\    SELECT id, id, (id - 1) / 6 + 1, 't' || id,
        \\        (SELECT album_artist_id FROM releases WHERE releases.id = (recordings.id - 1) / 6 + 1), id, 1000
        \\    FROM recordings;
        \\INSERT OR IGNORE INTO volumes(id, stable_key) VALUES (1, 'legacy');
        \\INSERT INTO locations(file_id, volume_id, uri, state) SELECT id, 1, '/m/' || id, 'present' FROM files;
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Hip Hop', 'hip hop'), (2, 'Jazz', 'jazz'), (3, 'Rock', 'rock');
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance)
        \\    SELECT id, CASE release_id WHEN 4 THEN 2 WHEN 5 THEN 2 WHEN 6 THEN 3 WHEN 7 THEN 3 ELSE 1 END, 0, 0 FROM tracks;
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) SELECT id, 2, 1, 0 FROM tracks WHERE release_id = 3;
        \\INSERT INTO file_audio_features(file_id, source_identity, tempo_bpm, tempo_confidence, key_pitch, key_mode,
        \\    key_confidence, onset_rate, centroid_hz)
        \\    SELECT id, content_hash, 80 + id * 2, 0.5, id % 12, id % 2, 0.5, id * 0.1, 1000 + id * 10 FROM files;
        \\INSERT INTO file_loudness(file_id, source_identity, integrated_lufs) SELECT id, content_hash, -20 + id * 0.2 FROM files;
        \\INSERT INTO artist_related(artist_id, ordinal, related_mbid, related_name, score) VALUES
        \\    (1, 0, 'mb-b', 'B', 100), (1, 1, 'mb-c', 'C', 50);
        \\INSERT INTO recording_play_stats(recording_id, play_count, last_played_at)
        \\    SELECT id, 1 + id % 5, 1000 FROM recordings;
    );
    return library;
}

fn radioFor(library: *database.LibraryDatabase, seed: Seed, options: RadioOptions, limit: usize) !Picks {
    const source: Source = .of(library);
    return pickRadio(testing.allocator, &source, seed, options, .{ .now_s = test_now, .seed = 42 }, limit);
}

fn picked(picks: Picks, recording_id: i64) bool {
    for (picks.items) |pick| if (pick.recording_id == recording_id) return true;
    return false;
}

test "weights move linearly from Close to Explore and always sum to one" {
    const close = Components.weightsAt(0);
    try testing.expectApproxEqAbs(@as(f64, 0.35), close.artist, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.05), close.jitter, 1e-12);
    const middle = Components.weightsAt(35);
    try testing.expectApproxEqAbs(@as(f64, 0.35 - 0.25 * 0.35), middle.artist, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.20 - 0.10 * 0.35), middle.genre, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.15 + 0.10 * 0.35), middle.audio, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.10 + 0.15 * 0.35), middle.co_listening, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.08 - 0.03 * 0.35), middle.era, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.07 + 0.03 * 0.35), middle.taste, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.05 + 0.10 * 0.35), middle.jitter, 1e-12);
    const far = Components.weightsAt(100);
    try testing.expectApproxEqAbs(@as(f64, 0.10), far.artist, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.25), far.co_listening, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.15), far.jitter, 1e-12);
    const ones: Components = .{ .artist = 1, .genre = 1, .audio = 1, .co_listening = 1, .era = 1, .taste = 1, .jitter = 1 };
    for ([_]Components{ close, middle, far, middle.withoutAudio() }) |weights|
        try testing.expectApproxEqAbs(@as(f64, 1), ones.weighted(weights), 1e-12);
    try testing.expectEqual(@as(f64, 0), middle.withoutAudio().audio);
    try testing.expectApproxEqAbs(middle.artist / (1 - middle.audio), middle.withoutAudio().artist, 1e-12);
}

test "tempo matches at half and double, key at its relative and fifth, energy by distance" {
    try testing.expectEqual(@as(f64, 1), tempoSimilarity(120, 120));
    try testing.expectApproxEqAbs(@as(f64, 1), tempoSimilarity(60, 120), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), tempoSimilarity(240, 120), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), tempoSimilarity(150, 120), 1e-12);
    try testing.expectEqual(@as(f64, 0), tempoSimilarity(170, 120));
    try testing.expectApproxEqAbs(1 - std.math.log2(132.0 / 120.0) / std.math.log2(1.25), tempoSimilarity(132, 120), 1e-12);

    const c_major: AudioFeatures.Key = .{ .pitch = 0, .mode = .major, .confidence = 1 };
    try testing.expectEqual(@as(f64, 1), keySimilarity(c_major, c_major));
    try testing.expectEqual(@as(f64, 0.7), keySimilarity(c_major, .{ .pitch = 9, .mode = .minor, .confidence = 1 }));
    try testing.expectEqual(@as(f64, 0.7), keySimilarity(.{ .pitch = 9, .mode = .minor, .confidence = 1 }, c_major));
    try testing.expectEqual(@as(f64, 0.7), keySimilarity(c_major, .{ .pitch = 7, .mode = .major, .confidence = 1 }));
    try testing.expectEqual(@as(f64, 0.7), keySimilarity(c_major, .{ .pitch = 5, .mode = .major, .confidence = 1 }));
    try testing.expectEqual(@as(f64, 0), keySimilarity(c_major, .{ .pitch = 0, .mode = .minor, .confidence = 1 }));
    try testing.expectEqual(@as(f64, 0), keySimilarity(c_major, .{ .pitch = 2, .mode = .major, .confidence = 1 }));
    try testing.expectApproxEqAbs(@as(f64, 0.75), energySimilarity(0.5, 0.25), 1e-12);

    const seed: Sound = .{ .tempo = 120, .key = c_major, .energy = 0.5 };
    const full = audioScore(seed, .{
        .tempo = .{ .bpm = 60, .confidence = 1 },
        .key = .{ .pitch = 7, .mode = .major, .confidence = 1 },
        .onset_rate = null,
        .centroid_hz = null,
        .energy = 0.25,
    });
    try testing.expectApproxEqAbs(0.4 * 1 + 0.2 * 0.7 + 0.4 * 0.75, full.value, 1e-12);
    try testing.expectEqual(sound_tempo | sound_key, full.flags);

    const no_key = audioScore(seed, .{ .tempo = .{ .bpm = 120, .confidence = 1 }, .key = null, .onset_rate = null, .centroid_hz = null, .energy = 0.4 });
    try testing.expectApproxEqAbs((0.4 * 1 + 0.4 * 0.9) / 0.8, no_key.value, 1e-12);
    try testing.expectEqual(sound_tempo | sound_energy, no_key.flags);

    const tempo_only_seed = audioScore(.{ .tempo = 120 }, .{ .tempo = null, .key = c_major, .onset_rate = null, .centroid_hz = null, .energy = 0.4 });
    try testing.expectEqual(@as(f64, 0.3), tempo_only_seed.value);
    try testing.expectEqual(@as(f64, 0.3), audioScore(seed, null).value);
}

test "era, taste and jitter components" {
    try testing.expectEqual(@as(f64, 1), eraScore(1990, 1995, 1993));
    try testing.expectApproxEqAbs(@as(f64, 1 - 5.0 / 15.0), eraScore(1990, 1995, 2000), 1e-12);
    try testing.expectEqual(@as(f64, 0), eraScore(1990, 1995, 1960));
    try testing.expectEqual(@as(f64, 0.3), eraScore(1990, 1995, null));
    try testing.expectEqual(@as(f64, 0.3), eraScore(null, null, 1990));
    try testing.expectEqual(@as(f64, 0), tasteScore(false, null, false));
    try testing.expectApproxEqAbs(@as(f64, 0.9), tasteScore(true, 80, false), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.6), tasteScore(false, 80, true), 1e-12);
    try testing.expectEqual(@as(f64, 1), tasteScore(true, 100, true));
    try testing.expectApproxEqAbs(@as(f64, 0.7), tasteScore(true, 40, false), 1e-12);
    try testing.expectEqual(jitter(7, 1), jitter(7, 1));
    try testing.expect(jitter(7, 1) != jitter(7, 2));
    try testing.expect(jitter(7, 1) >= 0 and jitter(7, 1) < 1);
}

test "the discovery settings read their defaults, keep what is written, and ignore stored values outside their sets" {
    var library = try openFixture("settings");
    defer library.close();
    try testing.expectEqual(Settings{}, try readSettings(&library.settings));
    const changed: Settings = .{ .radio_continue = false, .include_unplayed = false, .avoid_days = .seven_days, .mix_count = .four };
    try writeSettings(&library.settings, changed);
    try testing.expectEqual(changed, try readSettings(&library.settings));
    try library.database.exec("UPDATE library_settings SET value = '5' WHERE key IN ('discovery.avoid_days', 'mixes.count');");
    const read = try readSettings(&library.settings);
    try testing.expectEqual(AvoidDays.three_days, read.avoid_days);
    try testing.expectEqual(MixCount.six, read.mix_count);
}

test "every seed kind finds picks in a Library" {
    var library = try openFixture("seeds");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO feedback(recording_id, score, updated_at) VALUES (7, 1, 1), (40, 1, 1);
        \\INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist) VALUES
        \\    (1, 1, 9000000, 1000, 't', 'a'), (2, 2, 9000300, 1000, 't', 'a'), (25, 25, 9000600, 1000, 't', 'a');
    );
    for ([_]Seed{ .{ .track = 1 }, .{ .release = 4 }, .{ .artist = 1 }, .{ .genre = 2 }, .{ .decade = 1990 }, .loved, .recent }) |seed| {
        var picks = try radioFor(&library, seed, .{}, 20);
        defer picks.deinit();
        try testing.expect(picks.items.len > 0);
        for (picks.items) |pick| try testing.expect(pick.reason.first != null);
    }
    try testing.expectError(error.UnknownRadioSeed, radioFor(&library, .{ .track = 999 }, .{}, 10));
    try testing.expectError(error.UnknownRadioSeed, radioFor(&library, .{ .genre = 999 }, .{}, 10));
    try testing.expectError(error.InvalidDecade, radioFor(&library, .{ .decade = 1995 }, .{}, 10));
    try testing.expectError(error.InvalidExplore, radioFor(&library, .loved, .{ .explore = 101 }, 10));
}

test "the seed Track, hated, Not for me and live Recordings are left out; an expired Not for me is not" {
    var library = try openFixture("exclusions");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO feedback(recording_id, score, updated_at) VALUES (2, -1, 1);
        \\INSERT INTO recommendation_feedback(recording_id, created_at, expires_at) VALUES (3, 1, 10000100), (4, 1, 9999999);
    );
    var picks = try radioFor(&library, .{ .track = 1 }, .{ .explore = 0 }, max_picks);
    defer picks.deinit();
    try testing.expect(!picked(picks, 1));
    try testing.expect(!picked(picks, 2));
    try testing.expect(!picked(picks, 3));
    try testing.expect(picked(picks, 4));
    for (31..37) |live| try testing.expect(!picked(picks, @intCast(live)));
    try testing.expectEqual(@as(usize, 48 - 3 - 6), picks.items.len);

    var with_live = try radioFor(&library, .{ .track = 1 }, .{ .include_live = true }, max_picks);
    defer with_live.deinit();
    for (31..37) |live| try testing.expect(picked(with_live, @intCast(live)));

    try library.database.exec("UPDATE releases SET title = 'Seven (Live at the Hall)' WHERE id = 7;");
    var titled = try radioFor(&library, .{ .track = 1 }, .{}, max_picks);
    defer titled.deinit();
    for (37..43) |live| try testing.expect(!picked(titled, @intCast(live)));

    try testing.expectError(error.RadioLimitTooLarge, radioFor(&library, .{ .track = 1 }, .{}, max_picks + 1));
}

test "session exclusions and adjustments change what is picked" {
    var library = try openFixture("session");
    defer library.close();
    var plain = try radioFor(&library, .{ .artist = 1 }, .{ .explore = 0 }, 5);
    defer plain.deinit();
    const first = plain.items[0];
    try testing.expectEqual(@as(?i64, 1), first.artist_id);
    var adjusted = try pickRadio(testing.allocator, &Source.of(&library), .{ .artist = 1 }, .{ .explore = 0 }, .{
        .now_s = test_now,
        .seed = 42,
        .excluded_recordings = &.{first.recording_id},
        .artist_adjustments = &.{.{ .id = 1, .delta = -1 }},
    }, 5);
    defer adjusted.deinit();
    try testing.expect(!picked(adjusted, first.recording_id));
    try testing.expect(adjusted.items[0].artist_id != 1);
}

test "Recordings played within the avoid window are left out unless nothing else qualifies" {
    var library = try openFixture("avoid");
    defer library.close();
    try library.database.exec("UPDATE recording_play_stats SET last_played_at = 9990000 WHERE recording_id IN (5, 40);");
    var picks = try radioFor(&library, .{ .track = 1 }, .{}, max_picks);
    defer picks.deinit();
    try testing.expect(!picked(picks, 5));
    try testing.expect(!picks.relaxed_recent);
    var off = try radioFor(&library, .{ .track = 1 }, .{ .avoid_recent = false }, max_picks);
    defer off.deinit();
    try testing.expect(picked(off, 5));

    try library.settings.setInteger(database.setting_discovery_avoid_days, 0);
    var setting_off = try radioFor(&library, .{ .track = 1 }, .{}, max_picks);
    defer setting_off.deinit();
    try testing.expect(picked(setting_off, 5));
    try library.settings.setInteger(database.setting_discovery_avoid_days, 3);

    try library.database.exec("UPDATE recording_play_stats SET last_played_at = 9990000 WHERE recording_id BETWEEN 37 AND 42;");
    var relaxed = try radioFor(&library, .{ .track = 1 }, .{ .focus = .{ .{ .genre = 3 }, null, null, null } }, max_picks);
    defer relaxed.deinit();
    try testing.expect(relaxed.relaxed_recent);
    try testing.expectEqual(@as(usize, 6), relaxed.items.len);
}

test "picks space out Artists and Releases, and relax only when nothing else fits" {
    var library = try openFixture("diversity");
    defer library.close();
    var picks = try radioFor(&library, .{ .artist = 1 }, .{ .explore = 0 }, 30);
    defer picks.deinit();
    try testing.expectEqual(@as(usize, 30), picks.items.len);
    for (picks.items[2..], 2..) |pick, index| {
        const a = picks.items[index - 1].artist_id;
        const b = picks.items[index - 2].artist_id;
        try testing.expect(!(a == pick.artist_id and b == pick.artist_id));
    }
    for (0..picks.items.len) |end| {
        const start = end -| (diversity_window - 1);
        var same: usize = 0;
        for (picks.items[start..end]) |earlier| {
            if (earlier.release_id == picks.items[end].release_id) same += 1;
        }
        try testing.expect(same <= 2);
    }

    var narrow = try radioFor(&library, .{ .genre = 2 }, .{ .focus = .{ .{ .genre = 2 }, null, null, null } }, 20);
    defer narrow.deinit();
    try testing.expectEqual(@as(usize, 18), narrow.items.len);
    var releases: [4]?i64 = .{ null, null, null, null };
    for (narrow.items[0..4], 0..) |pick, index| releases[index] = pick.release_id;
    var per_release: [9]usize = @splat(0);
    for (releases) |release| per_release[@intCast(release.?)] += 1;
    for (per_release) |count| try testing.expect(count <= 2);
}

fn expectUnplayedSpacedWhilePlayedRemain(picks: Picks) !void {
    for (picks.items, 0..) |pick, index| {
        if (!pick.never_played) continue;
        const crowded = for (picks.items[index -| 3..index]) |earlier| {
            if (earlier.never_played) break true;
        } else false;
        if (!crowded) continue;
        for (picks.items[index..]) |later| try testing.expect(later.never_played);
    }
}

test "never-played Recordings are at most one in four while played ones remain, and none when unplayed is off" {
    var library = try openFixture("unplayed");
    defer library.close();
    try library.database.exec("DELETE FROM recording_play_stats WHERE recording_id % 2 = 0;");
    var picks = try radioFor(&library, .{ .track = 1 }, .{ .include_unplayed = true }, max_picks);
    defer picks.deinit();
    var never: usize = 0;
    for (picks.items) |pick| never += @intFromBool(pick.never_played);
    try testing.expect(never > 0);
    try testing.expectEqual(@as(usize, 41), picks.items.len);
    try expectUnplayedSpacedWhilePlayedRemain(picks);
    var short = try radioFor(&library, .{ .track = 1 }, .{ .include_unplayed = true }, 12);
    defer short.deinit();
    for (short.items, 0..) |pick, index| {
        if (!pick.never_played) continue;
        for (short.items[index -| 3..index]) |earlier| try testing.expect(!earlier.never_played);
    }
    var off = try radioFor(&library, .{ .track = 1 }, .{ .include_unplayed = false }, max_picks);
    defer off.deinit();
    for (off.items) |pick| try testing.expect(!pick.never_played);
    try library.settings.setFlag(database.setting_radio_include_unplayed, false);
    var setting_off = try radioFor(&library, .{ .track = 1 }, .{}, max_picks);
    defer setting_off.deinit();
    for (setting_off.items) |pick| try testing.expect(!pick.never_played);
}

test "a Library with almost no history fills a Radio with never-played picks once the played ones run out" {
    var library = try database.LibraryDatabase.open(testing.allocator, testing.io, "file:orca-test-discovery-sparse?mode=memory&cache=shared");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, key) SELECT n, 'A' || n, 'a' || n FROM
        \\    (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 40) SELECT n FROM seq);
        \\INSERT INTO releases(id, title, album_artist_id, release_date, release_type)
        \\    SELECT id, 'R' || id, id, '2000', 'album' FROM artists;
        \\WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 203)
        \\INSERT INTO recordings(id, title) SELECT n, 'r' || n FROM seq;
        \\INSERT INTO files(id, recording_id, size_bytes, quick_hash, content_hash, content_hash_algorithm, channels)
        \\    SELECT id, id, 1, CAST(id AS BLOB), CAST(id AS BLOB), 1, 2 FROM recordings;
        \\INSERT INTO tracks(id, recording_id, release_id, title, artist_id, preferred_file_id, created_at)
        \\    SELECT id, id, id % 40 + 1, 't' || id, id % 40 + 1, id, 1000 FROM recordings;
        \\INSERT OR IGNORE INTO volumes(id, stable_key) VALUES (1, 'legacy');
        \\INSERT INTO locations(file_id, volume_id, uri, state) SELECT id, 1, '/m/' || id, 'present' FROM files;
        \\INSERT INTO recording_play_stats(recording_id, play_count, last_played_at) VALUES (1, 4, 1000), (2, 2, 1000), (3, 1, 1000);
    );
    var picks = try radioFor(&library, .{ .track = 1 }, .{ .include_unplayed = true }, 25);
    defer picks.deinit();
    try testing.expectEqual(@as(usize, 25), picks.items.len);
    var played: usize = 0;
    for (picks.items) |pick| {
        if (!pick.never_played) {
            played += 1;
            continue;
        }
        const reason = pick.reason;
        const names_never = (reason.first != null and reason.first.?.kind == .never_played) or
            (reason.second != null and reason.second.?.kind == .never_played);
        try testing.expect(names_never);
    }
    try testing.expectEqual(@as(usize, 2), played);
    try expectUnplayedSpacedWhilePlayedRemain(picks);
    var off = try radioFor(&library, .{ .track = 1 }, .{ .include_unplayed = false }, 25);
    defer off.deinit();
    try testing.expectEqual(@as(usize, 2), off.items.len);
}

test "focus filters keep only their genre, decade or energy" {
    var library = try openFixture("focus");
    defer library.close();
    var decade = try radioFor(&library, .loved, .{ .focus = .{ .{ .decade = 2000 }, null, null, null } }, max_picks);
    defer decade.deinit();
    try testing.expectEqual(@as(usize, 6), decade.items.len);
    for (decade.items) |pick| try testing.expectEqual(@as(?i64, 4), pick.release_id);
    var high = try radioFor(&library, .loved, .{ .focus = .{ .high_energy, null, null, null } }, max_picks);
    defer high.deinit();
    try testing.expect(high.items.len > 0);
    for (high.items) |pick| {
        const f = (try library.audio_features.trackFeatures(pick.track_id)).?;
        try testing.expect(f.energy.? >= 2.0 / 3.0);
    }
}

test "every reason is true of its pick" {
    var library = try openFixture("reasons");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO feedback(recording_id, score, updated_at) VALUES (8, 1, 1);
        \\INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist) VALUES
        \\    (1, 1, 9000000, 1000, 't', 'a'), (20, 20, 9000200, 1000, 't', 'a'),
        \\    (1, 1, 9100000, 1000, 't', 'a'), (20, 20, 9100300, 1000, 't', 'a'),
        \\    (1, 1, 9200000, 1000, 't', 'a'), (44, 44, 9205000, 1000, 't', 'a');
    );
    var seed_genres = try library.database.prepare("SELECT 1 FROM track_genres WHERE track_id = 1 AND genre_id = ?1;");
    defer seed_genres.deinit();
    var pick_genres = try library.database.prepare("SELECT 1 FROM track_genres WHERE track_id = ?1 AND genre_id = ?2;");
    defer pick_genres.deinit();
    var follows = try library.database.prepare(
        \\SELECT count(*) FROM listens AS seed JOIN listens AS next
        \\    ON next.started_at > seed.started_at AND next.started_at <= seed.started_at + 1800
        \\WHERE seed.recording_id = ?1 AND next.recording_id = ?2;
    );
    defer follows.deinit();

    var saw_often_after = false;
    for ([_]u8{ 0, 35, 100 }) |explore| {
        var picks = try radioFor(&library, .{ .track = 1 }, .{ .explore = explore }, 40);
        defer picks.deinit();
        for (picks.items) |pick| for ([_]?ReasonPart{ pick.reason.first, pick.reason.second }) |maybe| {
            const part = maybe orelse continue;
            switch (part.kind) {
                .same_artist => try testing.expectEqual(@as(?i64, 1), pick.artist_id),
                .related_artist => {
                    try testing.expectEqual(@as(i64, 1), part.a);
                    try testing.expect(pick.artist_id == 2 or pick.artist_id == 3);
                },
                .shared_genre => {
                    try seed_genres.bindInt64(1, part.a);
                    try testing.expectEqual(sqlite.Step.row, try seed_genres.step());
                    try seed_genres.reset();
                    try pick_genres.bindInt64(1, pick.track_id);
                    try pick_genres.bindInt64(2, part.a);
                    try testing.expectEqual(sqlite.Step.row, try pick_genres.step());
                    try pick_genres.reset();
                },
                .often_after => {
                    saw_often_after = true;
                    try testing.expectEqual(@as(i64, 0), part.b);
                    try follows.bindInt64(1, part.a);
                    try follows.bindInt64(2, pick.recording_id);
                    try testing.expectEqual(sqlite.Step.row, try follows.step());
                    try testing.expect(follows.columnInt64(0) >= 2);
                    try follows.reset();
                },
                .loved => try testing.expectEqual(@as(i64, 8), pick.recording_id),
                .never_played => try testing.expect(pick.never_played),
                .rarely_played => try testing.expect(part.a >= 1 and part.a <= 2),
                .played => try testing.expect(part.a >= 3),
                .similar_sound => try testing.expect(part.a != 0 and pick.components.audio > 0.3),
                .added => {},
            }
        };
    }
    try testing.expect(saw_often_after);
}

test "the same seed and time pick the same Recordings in the same order" {
    var library = try openFixture("determinism");
    defer library.close();
    var first = try radioFor(&library, .{ .genre = 1 }, .{ .explore = 100 }, 30);
    defer first.deinit();
    var second = try radioFor(&library, .{ .genre = 1 }, .{ .explore = 100 }, 30);
    defer second.deinit();
    try testing.expectEqual(first.items.len, second.items.len);
    for (first.items, second.items) |a, b| {
        try testing.expectEqual(a.recording_id, b.recording_id);
        try testing.expectEqual(a.score, b.score);
        try testing.expectEqual(a.reason, b.reason);
    }
    var limited = try radioFor(&library, .{ .genre = 1 }, .{}, 0);
    defer limited.deinit();
    try testing.expectEqual(@as(usize, 0), limited.items.len);
}
