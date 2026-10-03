const std = @import("std");
const sqlite = @import("../sqlite.zig");
const columns = @import("../columns.zig");
const metadata = @import("../../metadata/model.zig");

const dupeNullable = columns.dupeNullable;
const max_page = columns.max_page;
const optionalInt64 = columns.optionalInt64;
const presentText = columns.presentText;
const by_release_artist = @import("tracks.zig").by_release_artist;
const track_play_file = @import("tracks.zig").track_play_file;
const codec_id = @import("../../codec/decoder.zig").codec_id;
const ProposalState = @import("identification.zig").ProposalState;
const WriteLane = @import("write_lane.zig").WriteLane;
const search = @import("search.zig");

/// The projection's release input, keyed by the composite `release_key` the
/// projection derives from album, album artist and the strongest available
/// release identifier.
pub const ReleaseUpsert = struct {
    release_key: []const u8,
    title: []const u8,
    album_artist: []const u8 = "",
    release_date: ?[]const u8 = null,
    /// The Artist row this release is filed under. One album artist per
    /// release, deliberately — see the note on migration 9.
    album_artist_id: ?i64 = null,
    is_compilation: bool = false,
    disc_count: ?i64 = null,
    musicbrainz_release_id: ?[]const u8 = null,
    /// The files' release type, such as "Album" or "EP"; stored as
    /// `normalizeReleaseType` folds it. Null keeps what the Release has.
    release_type: ?[]const u8 = null,
};

/// The longest release type kept; a longer one is not a type.
pub const max_release_type = 32;

/// The primary type a release type states, lowercased: "Album; Compilation"
/// and "album/compilation" are both "album". Null when it states none.
pub fn normalizeReleaseType(buffer: *[max_release_type]u8, text: []const u8) ?[]const u8 {
    const end = std.mem.indexOfAny(u8, text, ";/,") orelse text.len;
    const primary = std.mem.trim(u8, text[0..end], " \t");
    if (primary.len == 0 or primary.len > buffer.len) return null;
    return std.ascii.lowerString(buffer, primary);
}

/// A Release as a browse listing shows one.
pub const ReleaseSummary = struct {
    id: i64,
    title: []u8,
    album_artist: []u8,
    album_artist_id: ?i64,
    release_date: ?[]const u8,
    is_compilation: bool,
    disc_count: ?i64,
    track_count: u32,
    /// Summed over the Tracks that declare one; a Track whose duration is
    /// unknown contributes nothing rather than a zero-length lie.
    total_duration_ms: i64,
    loved: bool,
    /// Explicit when any Track is; else clean, then none, when any Track
    /// says so; unknown when no Track states an advisory.
    explicit: metadata.Explicit = .unknown,
    /// Such as "album", as the Release's files state it.
    release_type: ?[]const u8 = null,
    /// The highest of the files the Tracks play.
    max_sample_rate: ?u32 = null,
    max_bit_depth: ?u32 = null,
    /// The codec of every file the Tracks play, `mixed_codec` when they
    /// differ, empty when none was probed.
    codec: []u8 = &.{},
    /// Whether every Track plays a file in a lossless codec.
    lossless: bool = false,
    /// What the review lists hold for the Release: its Tracks with a pending
    /// match outside an album group, plus the album groups with a pending
    /// correction of one of its Tracks.
    pending_reviews: u32 = 0,

    pub const mixed_codec = "mixed";

    /// What `ReleaseQuery.high_resolution_only` keeps.
    pub fn isHighResolution(self: ReleaseSummary) bool {
        return (self.max_sample_rate orelse 0) > high_resolution_sample_rate or
            (self.max_bit_depth orelse 0) > high_resolution_bit_depth;
    }

    pub fn deinit(self: ReleaseSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.album_artist);
        if (self.release_date) |date| allocator.free(date);
        if (self.release_type) |text| allocator.free(text);
        allocator.free(self.codec);
    }
};

/// The most a file may reach and still be standard resolution.
pub const high_resolution_sample_rate = 48_000;
pub const high_resolution_bit_depth = 16;

pub const ReleasePage = struct {
    allocator: std.mem.Allocator,
    items: []ReleaseSummary,

    pub fn deinit(self: ReleasePage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const ReleaseQuery = struct {
    /// Releases filed under this Artist as album artist and those with a
    /// Track credited to them, unless `own_releases_only`.
    album_artist_id: ?i64 = null,
    /// With `album_artist_id`, only the Releases filed under that Artist as
    /// album artist, leaving out those they only appear on.
    own_releases_only: bool = false,
    /// Only Releases with a Track credited to this Artist that are not filed
    /// under them as album artist: the Releases they appear on.
    appearing_artist_id: ?i64 = null,
    /// Only Releases of this kind, read from `release_type`.
    release_kind: ?ReleaseKind = null,
    /// Only Releases holding a Track that carries this genre.
    genre_id: ?i64 = null,
    sort: ReleaseSort = .title,
    loved_only: bool = false,
    /// Only Releases with a Track whose file is above 48 kHz or 16 bits.
    high_resolution_only: bool = false,
    /// Only Releases with `pending_reviews` above zero.
    needs_review_only: bool = false,
    /// Only Releases whose every Track plays a lossless file.
    lossless_only: bool = false,
    /// Only Releases dated within these years, both inclusive; either bound
    /// leaves out undated Releases.
    year_min: ?i32 = null,
    year_max: ?i32 = null,
    /// Only Releases with a cover, embedded in a Track's file or fetched, or
    /// only those without one.
    has_artwork: ?bool = null,
    /// Only Releases whose title or album artist holds a word beginning with
    /// each word of this text, as `SearchRepository.find` matches them. Null,
    /// or text with no word, keeps every Release.
    text: ?[]const u8 = null,
    limit: u32 = max_page,
    offset: u32 = 0,
};

/// What `ReleaseQuery.release_kind` sorts a `release_type` into.
pub const ReleaseKind = enum(u8) {
    /// "album" or "compilation", and a Release whose type is unknown: most
    /// untagged Releases are albums, so a NULL or empty type counts as one.
    album = 0,
    /// "ep" or "single".
    ep_or_single = 1,
    /// Any other type, such as "broadcast" or "other".
    other = 2,
};

const release_kind = std.fmt.comptimePrint(
    "(CASE WHEN COALESCE(releases.release_type, '') IN ('', 'album', 'compilation') THEN {d}\n" ++
        "      WHEN releases.release_type IN ('ep', 'single') THEN {d} ELSE {d} END)",
    .{ @intFromEnum(ReleaseKind.album), @intFromEnum(ReleaseKind.ep_or_single), @intFromEnum(ReleaseKind.other) },
);

/// The orders a Release listing comes in. Each ends in `releases.id`, so it is
/// total and LIMIT/OFFSET paging is exact.
pub const ReleaseSort = enum {
    title,
    /// Album artist, then oldest first within an artist: a shelf.
    artist,
    /// Newest first; undated Releases last.
    year,
    /// Most recently created first.
    recently_added,
    /// Most recently loved first; Releases that are not loved last.
    loved,
    /// Most listens of the Tracks' recordings first.
    most_played,

    fn terms(comptime self: ReleaseSort) []const u8 {
        return switch (self) {
            .title => "releases.title COLLATE NOCASE, releases.id",
            .artist => "releases.album_artist COLLATE NOCASE, releases.release_date IS NULL, " ++
                "releases.release_date, releases.title COLLATE NOCASE, releases.id",
            .year => "releases.release_date IS NULL, releases.release_date DESC, " ++
                "releases.title COLLATE NOCASE, releases.id",
            .recently_added => "releases.id DESC",
            .loved => "release_loves.loved_at IS NULL, release_loves.loved_at DESC, releases.id",
            .most_played => "(SELECT COALESCE(sum(recording_play_stats.play_count), 0) FROM tracks\n" ++
                "    CROSS JOIN recording_play_stats ON recording_play_stats.recording_id = tracks.recording_id\n" ++
                "    WHERE tracks.release_id = releases.id) DESC, releases.id",
        };
    }
};

const pending_state = std.fmt.comptimePrint("{d}", .{@intFromEnum(ProposalState.pending)});

const lossless_codecs = blk: {
    var list: []const u8 = "";
    for (codec_id.lossless) |identifier| list = list ++ (if (list.len == 0) "" else ", ") ++ "'" ++ identifier ++ "'";
    break :blk list;
};

const is_high_resolution = std.fmt.comptimePrint(
    "(play.sample_rate > {d} OR play.bit_depth > {d})",
    .{ high_resolution_sample_rate, high_resolution_bit_depth },
);

const is_lossless = "COALESCE(play.codec IN (" ++ lossless_codecs ++ "), 0)";

const release_year =
    "CASE WHEN substr(releases.release_date, 1, 4) GLOB '[0-9][0-9][0-9][0-9]' " ++
    "THEN CAST(substr(releases.release_date, 1, 4) AS INTEGER) END";

const release_track_files = "tracks LEFT JOIN files AS play ON play.id = " ++ track_play_file ++ "\n" ++
    "    WHERE tracks.release_id = releases.id";

pub const has_cover = "(EXISTS (SELECT 1 FROM release_artwork WHERE release_artwork.release_id = releases.id " ++
    "AND release_artwork.image IS NOT NULL) OR EXISTS (SELECT 1 FROM " ++ release_track_files ++ "\n" ++
    "    AND EXISTS (SELECT 1 FROM observed_file_tags WHERE observed_file_tags.file_id = play.id\n" ++
    "        AND observed_file_tags.artwork_mime_type IS NOT NULL AND observed_file_tags.artwork_byte_size > 0)))";

/// The filters bound as parameters ?6 to ?15, each true when unset. They
/// read the same play files, codec list and pending state as
/// `release_facts`, so a summary and the filters cannot disagree.
const by_bound_filters =
    "(?6 = 0 OR EXISTS (SELECT 1 FROM " ++ release_track_files ++ " AND " ++ is_high_resolution ++ "))\n" ++
    "  AND (?7 = 0 OR EXISTS (SELECT 1 FROM " ++ release_track_files ++ "\n" ++
    "    AND EXISTS (SELECT 1 FROM identification_proposals AS proposal\n" ++
    "        WHERE proposal.file_id = play.id AND proposal.state = " ++ pending_state ++ ")))\n" ++
    "  AND (?8 = 0 OR (EXISTS (SELECT 1 FROM tracks WHERE tracks.release_id = releases.id)\n" ++
    "    AND NOT EXISTS (SELECT 1 FROM " ++ release_track_files ++ " AND " ++ is_lossless ++ " = 0)))\n" ++
    "  AND (?9 IS NULL OR " ++ release_year ++ " >= ?9)\n" ++
    "  AND (?10 IS NULL OR " ++ release_year ++ " <= ?10)\n" ++
    "  AND (?11 IS NULL OR " ++ has_cover ++ " = ?11)\n" ++
    "  AND (?12 IS NULL OR releases.id * 8 + " ++ release_search_kind ++ " IN (SELECT rowid FROM search_index\n" ++
    "    WHERE search_index MATCH ?12 AND rowid % 8 = " ++ release_search_kind ++ "))\n" ++
    "  AND (?13 IS NULL OR " ++ byAppearingArtist("?13") ++ ")\n" ++
    "  AND (?14 IS NULL OR " ++ release_kind ++ " = ?14)\n" ++
    "  AND (?15 = 0 OR releases.album_artist_id = ?3)";

/// The Releases with a Track credited to `artist` that are not filed under
/// them, read through `tracks_artist`.
pub fn byAppearingArtist(comptime artist: []const u8) []const u8 {
    return "(releases.id IN (SELECT tracks.release_id FROM tracks WHERE tracks.artist_id = " ++ artist ++ ")\n" ++
        "    AND releases.album_artist_id IS NOT " ++ artist ++ ")";
}

const release_search_kind = std.fmt.comptimePrint("{d}", .{@intFromEnum(search.SearchKind.release)});

const release_facts =
    "SELECT tracks.release_id AS release_id, count(*) AS track_count,\n" ++
    "       COALESCE(sum(tracks.duration_ms), 0) AS total_duration_ms,\n" ++
    "       CASE WHEN max(tracks.explicit = 2) THEN 2 WHEN max(tracks.explicit = 3) THEN 3\n" ++
    "            WHEN max(tracks.explicit = 1) THEN 1 ELSE 0 END AS explicit,\n" ++
    "       max(play.sample_rate) AS max_sample_rate, max(play.bit_depth) AS max_bit_depth,\n" ++
    "       CASE WHEN min(NULLIF(play.codec, '')) <> max(NULLIF(play.codec, '')) THEN '" ++ ReleaseSummary.mixed_codec ++ "'\n" ++
    "            ELSE max(NULLIF(play.codec, '')) END AS codec,\n" ++
    "       min(" ++ is_lossless ++ ") AS lossless,\n" ++
    "       max(EXISTS (SELECT 1 FROM identification_proposals AS proposal\n" ++
    "           WHERE proposal.file_id = play.id AND proposal.state = " ++ pending_state ++ ")) AS has_pending\n" ++
    "FROM tracks LEFT JOIN files AS play ON play.id = " ++ track_play_file ++ "\n" ++
    "WHERE tracks.release_id IN (SELECT page_id FROM release_page)\n" ++
    "GROUP BY tracks.release_id";

/// Read only for a Release with a pending proposal, which the page's facts
/// already know, so a listing pays for the exact count only where it is not
/// zero.
const pending_reviews =
    "(SELECT count(DISTINCT CASE WHEN proposal.album_group IS NULL THEN tracks.id END) +\n" ++
    "        count(DISTINCT proposal.album_group) FROM tracks\n" ++
    "    CROSS JOIN files AS play ON play.id = " ++ track_play_file ++ "\n" ++
    "    CROSS JOIN identification_proposals AS proposal ON proposal.file_id = play.id\n" ++
    "    WHERE tracks.release_id = releases.id AND proposal.state = " ++ pending_state ++ ")";

/// The Releases `page_ids` selects, as summaries ordered by `order`. The page
/// is chosen before any Track is read, so the per-Release facts cost one
/// pass over the page's Tracks rather than one over every Release's.
fn releaseSelect(comptime page_ids: []const u8, comptime order: []const u8) [:0]const u8 {
    return "WITH release_page(page_id) AS MATERIALIZED (\n" ++ page_ids ++ ")\n" ++
        \\SELECT releases.id, releases.title, releases.album_artist, releases.album_artist_id,
        \\       releases.release_date, releases.is_compilation, releases.disc_count,
        \\       COALESCE(release_facts.track_count, 0), COALESCE(release_facts.total_duration_ms, 0),
        \\       release_loves.release_id IS NOT NULL, COALESCE(release_facts.explicit, 0),
        \\       NULLIF(releases.release_type, ''), release_facts.max_sample_rate,
        \\       release_facts.max_bit_depth, release_facts.codec, COALESCE(release_facts.lossless, 0),
        \\
    ++ "       CASE WHEN release_facts.has_pending THEN " ++ pending_reviews ++ " ELSE 0 END\n" ++
        \\FROM release_page CROSS JOIN releases ON releases.id = release_page.page_id
        \\LEFT JOIN release_loves ON release_loves.release_id = releases.id
        \\
    ++ "LEFT JOIN (" ++ release_facts ++ ") AS release_facts ON release_facts.release_id = releases.id\n" ++
        order ++ ";";
}

const by_loved_release = "releases.id IN (SELECT release_id FROM release_loves)";

const by_release_genre = "releases.id IN (SELECT tracks.release_id FROM track_genres " ++
    "CROSS JOIN tracks ON tracks.id = track_genres.track_id WHERE track_genres.genre_id = ?5)";

fn releaseQueryText(
    comptime sort: ReleaseSort,
    comptime by_artist: bool,
    comptime loved_only: bool,
    comptime by_genre: bool,
) [:0]const u8 {
    @setEvalBranchQuota(20_000);
    comptime var terms: []const u8 = "WHERE " ++ by_bound_filters;
    for ([_]struct { bool, []const u8 }{
        .{ by_artist, by_release_artist },
        .{ loved_only, by_loved_release },
        .{ by_genre, by_release_genre },
    }) |term| {
        if (term[0]) terms = terms ++ "\n  AND " ++ term[1];
    }
    const order = "ORDER BY " ++ comptime sort.terms();
    return releaseSelect(
        "SELECT releases.id FROM releases\n" ++
            "LEFT JOIN release_loves ON release_loves.release_id = releases.id\n" ++
            terms ++ "\n" ++ order ++ "\nLIMIT ?1 OFFSET ?2",
        order,
    );
}

fn collectReleasePage(allocator: std.mem.Allocator, statement: sqlite.Statement) !ReleasePage {
    var results: std.ArrayList(ReleaseSummary) = .empty;
    errdefer {
        for (results.items) |item| item.deinit(allocator);
        results.deinit(allocator);
    }
    while (try statement.step() == .row) {
        const title = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(title);
        const album_artist = try allocator.dupe(u8, statement.columnText(2));
        errdefer allocator.free(album_artist);
        const release_date = try dupeNullable(allocator, statement, 4);
        errdefer if (release_date) |date| allocator.free(date);
        const release_type = try dupeNullable(allocator, statement, 11);
        errdefer if (release_type) |text| allocator.free(text);
        const codec = try allocator.dupe(u8, statement.columnText(14));
        errdefer allocator.free(codec);
        try results.append(allocator, .{
            .id = statement.columnInt64(0),
            .title = title,
            .album_artist = album_artist,
            .album_artist_id = optionalInt64(statement, 3),
            .release_date = release_date,
            .is_compilation = statement.columnInt64(5) != 0,
            .disc_count = optionalInt64(statement, 6),
            .track_count = @intCast(statement.columnInt64(7)),
            .total_duration_ms = statement.columnInt64(8),
            .loved = statement.columnInt64(9) != 0,
            .explicit = std.enums.fromInt(metadata.Explicit, statement.columnInt64(10)) orelse .unknown,
            .release_type = release_type,
            .max_sample_rate = positiveU32(statement, 12),
            .max_bit_depth = positiveU32(statement, 13),
            .codec = codec,
            .lossless = statement.columnInt64(15) != 0,
            .pending_reviews = std.math.cast(u32, statement.columnInt64(16)) orelse std.math.maxInt(u32),
        });
    }
    return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
}

fn positiveU32(statement: sqlite.Statement, column: c_int) ?u32 {
    const value = optionalInt64(statement, column) orelse return null;
    if (value <= 0) return null;
    return std.math.cast(u32, value);
}

fn bindBoundFilters(
    statement: sqlite.Statement,
    query: ReleaseQuery,
    expression: *[search.max_match_expression]u8,
) !void {
    try statement.bindInt64(6, @intFromBool(query.high_resolution_only));
    try statement.bindInt64(7, @intFromBool(query.needs_review_only));
    try statement.bindInt64(8, @intFromBool(query.lossless_only));
    try statement.bindOptionalInt64(9, if (query.year_min) |year| year else null);
    try statement.bindOptionalInt64(10, if (query.year_max) |year| year else null);
    try statement.bindOptionalInt64(11, if (query.has_artwork) |wanted| @intFromBool(wanted) else null);
    try statement.bindOptionalText(12, if (query.text) |text| try search.matchExpression(expression, text) else null);
    try statement.bindOptionalInt64(13, query.appearing_artist_id);
    try statement.bindOptionalInt64(14, if (query.release_kind) |kind| @intFromEnum(kind) else null);
    try statement.bindInt64(15, @intFromBool(query.own_releases_only and query.album_artist_id != null));
}

/// Releases as the projection resolves them, keyed by `release_key`.
pub const ReleaseRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn upsert(self: *ReleaseRepository, input: ReleaseUpsert) !i64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        const id = try self.upsertLocked(input);
        try self.db.exec("COMMIT;");
        return id;
    }

    /// `disc_count` only ever grows: one folder of a two-disc set projected on
    /// its own must not shrink a release the other folder already widened.
    /// A release type the files state replaces one a provider filled.
    pub fn upsertLocked(self: *ReleaseRepository, input: ReleaseUpsert) !i64 {
        var statement = try self.db.prepare(
            \\INSERT INTO releases(
            \\    title, album_artist, release_date, is_compilation,
            \\    disc_count, release_key, musicbrainz_release_id, album_artist_id, release_type
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            \\ON CONFLICT(release_key) DO UPDATE SET
            \\    title=excluded.title,
            \\    album_artist=excluded.album_artist,
            \\    album_artist_id=excluded.album_artist_id,
            \\    release_date=COALESCE(excluded.release_date, releases.release_date),
            \\    is_compilation=excluded.is_compilation,
            \\    disc_count=max(
            \\        COALESCE(excluded.disc_count, 1),
            \\        COALESCE(releases.disc_count, 1)
            \\    ),
            \\    musicbrainz_release_id=COALESCE(
            \\        excluded.musicbrainz_release_id,
            \\        releases.musicbrainz_release_id
            \\    ),
            \\    release_type=COALESCE(excluded.release_type, releases.release_type)
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindText(1, input.title);
        try statement.bindText(2, input.album_artist);
        try statement.bindOptionalText(3, presentText(input.release_date));
        try statement.bindInt64(4, @intFromBool(input.is_compilation));
        try statement.bindOptionalInt64(5, input.disc_count);
        try statement.bindText(6, input.release_key);
        try statement.bindOptionalText(7, presentText(input.musicbrainz_release_id));
        try statement.bindOptionalInt64(8, input.album_artist_id);
        var release_type: [max_release_type]u8 = undefined;
        try statement.bindOptionalText(9, if (input.release_type) |text| normalizeReleaseType(&release_type, text) else null);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    /// Gives a Release the type a provider states, such as MusicBrainz's
    /// "Album", unless it already has one, which its files stated. True when
    /// it was written. No media file is written.
    pub fn fillReleaseType(self: *ReleaseRepository, release_id: i64, provider_type: []const u8) !bool {
        var buffer: [max_release_type]u8 = undefined;
        const release_type = normalizeReleaseType(&buffer, provider_type) orelse return false;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            "UPDATE releases SET release_type = ?2 WHERE id = ?1 AND COALESCE(release_type, '') = '';",
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        try statement.bindText(2, release_type);
        if (try statement.step() != .done) return error.SqlFailed;
        return self.db.changes() != 0;
    }

    /// One bounded page of Releases, optionally scoped to one Artist, ordered
    /// by title with `releases.id` as the tiebreaker so paging is total.
    pub fn page(
        self: *const ReleaseRepository,
        allocator: std.mem.Allocator,
        query: ReleaseQuery,
    ) !ReleasePage {
        if (query.limit == 0 or query.limit > max_page) return error.PageOutOfRange;
        const by_artist = query.album_artist_id != null;
        var statement = switch (query.sort) {
            inline else => |sort| switch (by_artist) {
                inline else => |artist_filter| switch (query.loved_only) {
                    inline else => |loved_filter| switch (query.genre_id != null) {
                        inline else => |genre_filter| try self.db.prepare(
                            comptime releaseQueryText(sort, artist_filter, loved_filter, genre_filter),
                        ),
                    },
                },
            },
        };
        defer statement.deinit();
        try statement.bindInt64(1, query.limit);
        try statement.bindInt64(2, query.offset);
        if (query.album_artist_id) |artist_id| try statement.bindInt64(3, artist_id);
        if (query.genre_id) |genre_id| try statement.bindInt64(5, genre_id);
        var expression: [search.max_match_expression]u8 = undefined;
        try bindBoundFilters(statement, query, &expression);
        return collectReleasePage(allocator, statement);
    }

    /// Counts what `page` would return. Shares `by_release_artist`,
    /// `by_loved_release`, `by_release_genre` and `by_bound_filters` with it
    /// rather than restating the predicate: `TrackRepository.countMatching`
    /// had its own copy and drifted from the page it counted the moment the
    /// definition widened, so the list showed rows the count above it denied.
    pub fn countMatching(self: *const ReleaseRepository, query: ReleaseQuery) !u64 {
        var statement = try self.db.prepare(
            "SELECT count(*) FROM releases\nWHERE (?3 IS NULL OR " ++ by_release_artist ++ ")\n" ++
                "  AND (?4 = 0 OR " ++ by_loved_release ++ ")\n" ++
                "  AND (?5 IS NULL OR " ++ by_release_genre ++ ")\n" ++
                "  AND " ++ by_bound_filters ++ ";",
        );
        defer statement.deinit();
        try statement.bindOptionalInt64(3, query.album_artist_id);
        try statement.bindInt64(4, @intFromBool(query.loved_only));
        try statement.bindOptionalInt64(5, query.genre_id);
        var expression: [search.max_match_expression]u8 = undefined;
        try bindBoundFilters(statement, query, &expression);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn byId(
        self: *const ReleaseRepository,
        allocator: std.mem.Allocator,
        release_id: i64,
    ) !?ReleaseSummary {
        var statement = try self.db.prepare(comptime releaseSelect("SELECT ?1", ""));
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        var found = try collectReleasePage(allocator, statement);
        if (found.items.len == 0) {
            found.deinit();
            return null;
        }
        const first = found.items[0];
        for (found.items[1..]) |extra| extra.deinit(allocator);
        allocator.free(found.items);
        return first;
    }

    pub fn count(self: *const ReleaseRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM releases;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

fn openFormatLibrary(comptime name: []const u8) !@import("../library.zig").LibraryDatabase {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-release-" ++ name ++ "?mode=memory&cache=shared",
    );
    errdefer library.close();
    try library.database.exec(
        \\INSERT INTO releases(id, title, release_key, release_date) VALUES
        \\    (1, 'High resolution', 'r1', '2015-03-01'), (2, 'Mixed', 'r2', '2012'),
        \\    (3, 'Lossy', 'r3', '1999'), (4, 'Undated', 'r4', NULL), (5, 'Empty', 'r5', '2019'),
        \\    (6, 'Grouped', 'r6', '2010');
        \\INSERT INTO recordings(id, title)
        \\    WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v + 1 FROM n WHERE v < 9) SELECT v, 'Song' FROM n;
        \\INSERT INTO files(id, recording_id, codec, sample_rate, bit_depth) VALUES
        \\    (1, 1, 'flac', 96000, 24), (2, 2, 'flac', 44100, 16), (3, 3, 'flac', 44100, 16),
        \\    (4, 4, 'mp3', 44100, NULL), (5, 5, 'mp3', 44100, NULL), (6, 6, 'alac', 44100, 16),
        \\    (7, 7, 'flac', 48000, 24), (8, 8, 'flac', 48000, 16), (9, 9, 'mp3', 48000, NULL);
        \\INSERT INTO tracks(id, recording_id, release_id, title, track_number, preferred_file_id, explicit) VALUES
        \\    (1, 1, 1, 'Song', 1, 1, 2), (2, 2, 1, 'Song', 2, 2, 0), (3, 3, 2, 'Song', 1, 3, 0),
        \\    (4, 4, 2, 'Song', 2, 4, 0), (5, 5, 3, 'Song', 1, 5, 0), (6, 6, 4, 'Song', 1, 6, 0),
        \\    (7, 7, 6, 'Song', 1, 7, 0), (8, 8, 6, 'Song', 2, 8, 0), (9, 9, 3, 'Song', 2, NULL, 0);
        \\INSERT INTO release_artwork(release_id, musicbrainz_release_id, image, mime, fetched_at) VALUES
        \\    (3, 'mbid', x'89504e47', 'image/png', 0), (2, 'mbid', NULL, NULL, 0);
        \\INSERT INTO observed_file_tags(file_id, artwork_mime_type, artwork_byte_size, observed_at) VALUES
        \\    (6, 'image/jpeg', 1024, 0), (7, NULL, NULL, 0);
        \\INSERT INTO identification_proposals(file_id, provider, provider_id, confidence, payload, state, album_group) VALUES
        \\    (6, 'musicbrainz', '0b3c4d5e-6f70-4812-9a3b-4c5d6e7f8091', 0.9,
        \\     '{"title":"Song","artist":"Artist","album":"Undated"}', 0, NULL),
        \\    (7, 'musicbrainz', 'a', 0.9, x'7b7d', 0, 1),
        \\    (8, 'musicbrainz', 'b', 0.9, x'7b7d', 0, 2),
        \\    (8, 'musicbrainz', 'c', 0.9, x'7b7d', 0, NULL),
        \\    (1, 'musicbrainz', 'd', 0.9, x'7b7d', 2, NULL);
        \\INSERT INTO recording_play_stats(recording_id, play_count, last_played_at) VALUES
        \\    (5, 4, 0), (9, 4, 0), (3, 7, 0), (1, 2, 0);
    );
    return library;
}

fn expectReleaseIds(library: anytype, query: ReleaseQuery, expected: []const i64) !void {
    var listed = try library.releases.page(std.testing.allocator, query);
    defer listed.deinit();
    var ids: [8]i64 = undefined;
    for (listed.items, 0..) |item, index| ids[index] = item.id;
    try std.testing.expectEqualSlices(i64, expected, ids[0..listed.items.len]);
    try std.testing.expectEqual(@as(u64, expected.len), try library.releases.countMatching(query));
}

test "a release summary names the codec its tracks share, their highest resolution and whether all are lossless" {
    var library = try openFormatLibrary("summary");
    defer library.close();
    var listed = try library.releases.page(std.testing.allocator, .{ .sort = .recently_added });
    defer listed.deinit();
    const by_id = struct {
        fn find(items: []const ReleaseSummary, id: i64) ReleaseSummary {
            for (items) |item| if (item.id == id) return item;
            unreachable;
        }
    }.find;

    const high = by_id(listed.items, 1);
    try std.testing.expectEqualStrings("flac", high.codec);
    try std.testing.expectEqual(@as(?u32, 96000), high.max_sample_rate);
    try std.testing.expectEqual(@as(?u32, 24), high.max_bit_depth);
    try std.testing.expect(high.lossless and high.isHighResolution());
    try std.testing.expectEqual(metadata.Explicit.explicit, high.explicit);
    try std.testing.expectEqual(@as(u32, 2), high.track_count);

    const mixed = by_id(listed.items, 2);
    try std.testing.expectEqualStrings(ReleaseSummary.mixed_codec, mixed.codec);
    try std.testing.expect(!mixed.lossless and !mixed.isHighResolution());
    try std.testing.expectEqual(@as(?u32, 16), mixed.max_bit_depth);

    const lossy = by_id(listed.items, 3);
    try std.testing.expectEqualStrings("mp3", lossy.codec);
    try std.testing.expectEqual(@as(?u32, null), lossy.max_bit_depth);
    try std.testing.expectEqual(@as(?u32, 48000), lossy.max_sample_rate);

    const empty = by_id(listed.items, 5);
    try std.testing.expectEqualStrings("", empty.codec);
    try std.testing.expect(!empty.lossless);
    try std.testing.expectEqual(@as(u32, 0), empty.track_count);
    try std.testing.expectEqual(@as(?u32, null), empty.max_sample_rate);

    const single = (try library.releases.byId(std.testing.allocator, 6)).?;
    defer single.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("flac", single.codec);
    try std.testing.expect(single.lossless and single.isHighResolution());
    try std.testing.expectEqual(@as(u32, 3), single.pending_reviews);
}

test "each release filter keeps exactly the releases its summary admits, and the count agrees with the page" {
    var library = try openFormatLibrary("filters");
    defer library.close();
    try expectReleaseIds(&library, .{ .sort = .recently_added }, &.{ 6, 5, 4, 3, 2, 1 });
    try expectReleaseIds(&library, .{ .high_resolution_only = true }, &.{ 6, 1 });
    try expectReleaseIds(&library, .{ .lossless_only = true }, &.{ 6, 1, 4 });
    try expectReleaseIds(&library, .{ .needs_review_only = true }, &.{ 6, 4 });
    try expectReleaseIds(&library, .{ .year_min = 2010, .year_max = 2019, .sort = .year }, &.{ 5, 1, 2, 6 });
    try expectReleaseIds(&library, .{ .year_min = 2013 }, &.{ 5, 1 });
    try expectReleaseIds(&library, .{ .year_max = 2000 }, &.{3});
    try expectReleaseIds(&library, .{ .has_artwork = true }, &.{ 3, 4 });
    try expectReleaseIds(&library, .{ .has_artwork = false }, &.{ 5, 6, 1, 2 });
    try expectReleaseIds(&library, .{ .high_resolution_only = true, .year_max = 2012 }, &.{6});
    try expectReleaseIds(&library, .{ .lossless_only = true, .needs_review_only = true, .has_artwork = true }, &.{4});

    var all = try library.releases.page(std.testing.allocator, .{});
    defer all.deinit();
    var reviewed = try library.releases.page(std.testing.allocator, .{ .needs_review_only = true });
    defer reviewed.deinit();
    var high = try library.releases.page(std.testing.allocator, .{ .high_resolution_only = true });
    defer high.deinit();
    var lossless = try library.releases.page(std.testing.allocator, .{ .lossless_only = true });
    defer lossless.deinit();
    for (all.items) |item| {
        try std.testing.expectEqual(item.pending_reviews > 0, containsRelease(reviewed.items, item.id));
        try std.testing.expectEqual(item.isHighResolution(), containsRelease(high.items, item.id));
        try std.testing.expectEqual(item.lossless, containsRelease(lossless.items, item.id));
    }
}

test "release search text keeps only matching titles and album artists, composing with every filter and sort" {
    var library = try openFormatLibrary("text");
    defer library.close();
    try library.database.exec(
        \\UPDATE releases SET album_artist = 'Sigur Rós' WHERE id IN (1, 4, 6);
        \\UPDATE releases SET album_artist = 'Rosalía' WHERE id = 2;
    );
    try expectReleaseIds(&library, .{ .text = "ros", .sort = .recently_added }, &.{ 6, 4, 2, 1 });
    try expectReleaseIds(&library, .{ .text = "ros", .lossless_only = true, .sort = .year }, &.{ 1, 6, 4 });
    try expectReleaseIds(&library, .{ .text = "sigur", .year_max = 2012, .sort = .title }, &.{6});
    try expectReleaseIds(&library, .{ .text = "RESOL" }, &.{1});
    try expectReleaseIds(&library, .{ .text = "high mixed" }, &.{});
    try expectReleaseIds(&library, .{ .text = "\"NEAR\" OR (*", .sort = .recently_added }, &.{});
    try expectReleaseIds(&library, .{ .text = " - ", .sort = .recently_added }, &.{ 6, 5, 4, 3, 2, 1 });
    try std.testing.expectError(error.SearchTextTooLong, library.releases.countMatching(.{ .text = &(@as([300]u8, @splat('a'))) }));
}

fn containsRelease(items: []const ReleaseSummary, id: i64) bool {
    for (items) |item| if (item.id == id) return true;
    return false;
}

test "a release's pending reviews count tracks with an ungrouped match and album groups, and drop when the match is accepted" {
    var library = try openFormatLibrary("reviews");
    defer library.close();
    const before = (try library.releases.byId(std.testing.allocator, 4)).?;
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), before.pending_reviews);

    _ = try library.identification_proposals.acceptProposal(std.testing.allocator, 1);

    const after = (try library.releases.byId(std.testing.allocator, 4)).?;
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), after.pending_reviews);
    try expectReleaseIds(&library, .{ .needs_review_only = true }, &.{6});
    const accepted = (try library.releases.byId(std.testing.allocator, 1)).?;
    defer accepted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), accepted.pending_reviews);
}

test "releases sort by the listens of their tracks' recordings, most first, unplayed last by id" {
    var library = try openFormatLibrary("most-played");
    defer library.close();
    try expectReleaseIds(&library, .{ .sort = .most_played }, &.{ 3, 2, 1, 4, 5, 6 });
    var window = try library.releases.page(std.testing.allocator, .{ .sort = .most_played, .limit = 2, .offset = 1 });
    defer window.deinit();
    try std.testing.expectEqual(@as(usize, 2), window.items.len);
    try std.testing.expectEqual(@as(i64, 2), window.items[0].id);
    try std.testing.expectEqual(@as(i64, 1), window.items[1].id);
}

fn expectReleaseWindow(library: anytype, query: ReleaseQuery, expected: i64) !void {
    var listed = try library.releases.page(std.testing.allocator, query);
    defer listed.deinit();
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqual(expected, listed.items[0].id);
}

test "a release kind filter counts a release of unknown type as an album and composes with filters, sorts and paging" {
    var library = try openFormatLibrary("kind");
    defer library.close();
    try library.database.exec(
        \\UPDATE releases SET release_type = CASE id WHEN 1 THEN 'compilation' WHEN 2 THEN NULL WHEN 3 THEN 'ep'
        \\    WHEN 4 THEN 'single' WHEN 5 THEN 'broadcast' ELSE '' END;
    );
    try expectReleaseIds(&library, .{ .release_kind = .album, .sort = .recently_added }, &.{ 6, 2, 1 });
    try expectReleaseIds(&library, .{ .release_kind = .ep_or_single, .sort = .recently_added }, &.{ 4, 3 });
    try expectReleaseIds(&library, .{ .release_kind = .other }, &.{5});
    try expectReleaseIds(&library, .{ .release_kind = .album, .lossless_only = true }, &.{ 6, 1 });
    try expectReleaseIds(&library, .{ .release_kind = .album, .sort = .year }, &.{ 1, 2, 6 });
    try expectReleaseWindow(&library, .{ .release_kind = .album, .sort = .recently_added, .limit = 1, .offset = 1 }, 2);
}

test "an artist's appearances are the releases they are credited on that are not filed under them, in every sort" {
    var library = try openFormatLibrary("appearances");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name) VALUES (1, 'Guest', 'guest'), (2, 'Host', 'host');
        \\UPDATE releases SET album_artist_id = CASE id WHEN 1 THEN 1 WHEN 2 THEN 1 WHEN 3 THEN 2 WHEN 6 THEN 2 ELSE NULL END;
        \\UPDATE releases SET release_type = 'single' WHERE id = 4;
        \\UPDATE tracks SET artist_id = CASE id WHEN 1 THEN 1 WHEN 3 THEN 2 WHEN 5 THEN 1 WHEN 6 THEN 1 WHEN 7 THEN 1 ELSE NULL END;
    );
    try expectReleaseIds(&library, .{ .appearing_artist_id = 1, .sort = .recently_added }, &.{ 6, 4, 3 });
    try expectReleaseIds(&library, .{ .appearing_artist_id = 2 }, &.{2});
    try expectReleaseIds(&library, .{ .appearing_artist_id = 1, .lossless_only = true, .sort = .recently_added }, &.{ 6, 4 });
    try expectReleaseIds(&library, .{ .appearing_artist_id = 1, .release_kind = .ep_or_single }, &.{4});
    try expectReleaseWindow(&library, .{ .appearing_artist_id = 1, .sort = .recently_added, .limit = 1, .offset = 1 }, 4);
    try expectReleaseIds(&library, .{ .appearing_artist_id = 99 }, &.{});
    for (std.enums.values(ReleaseSort)) |sort| {
        var listed = try library.releases.page(std.testing.allocator, .{ .appearing_artist_id = 1, .sort = sort });
        defer listed.deinit();
        try std.testing.expectEqual(@as(usize, 3), listed.items.len);
        for (listed.items) |item| try std.testing.expect(item.id == 3 or item.id == 4 or item.id == 6);
    }
}

test "an artist's own releases leave out those they only appear on, and the flag means nothing without an artist" {
    var library = try openFormatLibrary("own");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name) VALUES (1, 'Guest', 'guest'), (2, 'Host', 'host');
        \\UPDATE releases SET album_artist_id = CASE id WHEN 1 THEN 1 WHEN 2 THEN 1 WHEN 3 THEN 2 WHEN 6 THEN 2 ELSE NULL END;
        \\UPDATE releases SET release_type = 'single' WHERE id = 2;
        \\UPDATE tracks SET artist_id = CASE id WHEN 1 THEN 1 WHEN 3 THEN 2 WHEN 5 THEN 1 WHEN 6 THEN 1 WHEN 7 THEN 1 ELSE NULL END;
    );
    try expectReleaseIds(&library, .{ .album_artist_id = 1, .sort = .recently_added }, &.{ 6, 4, 3, 2, 1 });
    try expectReleaseIds(&library, .{ .album_artist_id = 1, .own_releases_only = true, .sort = .recently_added }, &.{ 2, 1 });
    try expectReleaseIds(&library, .{ .album_artist_id = 1, .own_releases_only = true, .release_kind = .album }, &.{1});
    try expectReleaseIds(&library, .{ .album_artist_id = 2, .own_releases_only = true, .sort = .recently_added }, &.{ 6, 3 });
    try expectReleaseWindow(&library, .{ .album_artist_id = 1, .own_releases_only = true, .sort = .recently_added, .limit = 1, .offset = 1 }, 1);
    try std.testing.expectEqual(try library.releases.countMatching(.{}), try library.releases.countMatching(.{ .own_releases_only = true }));
}
