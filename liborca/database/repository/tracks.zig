const std = @import("std");
const sqlite = @import("../sqlite.zig");
const metadata = @import("../../metadata/model.zig");
const quick_hash = @import("../../storage/quick_hash.zig");
const content_hash = @import("../../storage/content_hash.zig");
const codec_id = @import("../../codec/decoder.zig").codec_id;
const measurableChannels = @import("analysis.zig").measurableChannels;
const columns = @import("../columns.zig");

const digestColumn = columns.digestColumn;
const max_page = columns.max_page;

/// The most rows `TrackRepository.playableIds` reads at once: a playback
/// queue's capacity.
pub const max_id_window = 10_000;
const optionalInt64 = columns.optionalInt64;
const Feedback = @import("feedback.zig").Feedback;
const WriteLane = @import("write_lane.zig").WriteLane;
const search_text = @import("search.zig");
const releases = @import("releases.zig");

/// The projection's input: a Track's values at its position on a Release,
/// written by `library/projection.zig` after resolving artists, releases and
/// recordings — never by the scanner, which only observes files.
pub const TrackInput = struct {
    recording_id: ?i64 = null,
    release_id: ?i64 = null,
    /// The Artist row this Track is filed under, resolved from the same key
    /// `ArtistRepository` stores. One primary artist per Track, deliberately.
    artist_id: ?i64 = null,
    title: []const u8,
    artist: []const u8 = "",
    album: []const u8 = "",
    album_artist: []const u8 = "",
    duration_ms: ?i64 = null,
    track_number: ?i64 = null,
    disc_number: ?i64 = null,
    /// Denormalized cache of the encoding playback should reach for, so
    /// starting a Track is one indexed lookup instead of a three-way join.
    preferred_file_id: ?i64 = null,
    track_total: ?i64 = null,
    disc_total: ?i64 = null,
    explicit: metadata.Explicit = .unknown,
};

/// A Track `TrackRepository.seatTracksLocked` writes: the row `id` names,
/// wherever it stands, or a new row when `id` is null.
pub const TrackSeat = struct {
    id: ?i64 = null,
    track: TrackInput,
};

fn bindSeated(statement: sqlite.Statement, track: TrackInput) !void {
    try statement.bindOptionalInt64(2, track.recording_id);
    try statement.bindOptionalInt64(3, track.release_id);
    try statement.bindText(4, track.title);
    try statement.bindText(5, track.artist);
    try statement.bindText(6, track.album);
    try statement.bindText(7, track.album_artist);
    try statement.bindOptionalInt64(8, track.duration_ms);
    try statement.bindOptionalInt64(9, track.track_number);
    try statement.bindOptionalInt64(10, track.disc_number);
    try statement.bindOptionalInt64(11, track.preferred_file_id);
    try statement.bindOptionalInt64(12, track.artist_id);
    try statement.bindOptionalInt64(13, track.track_total);
    try statement.bindOptionalInt64(14, track.disc_total);
    try statement.bindInt64(15, @backingInt(track.explicit));
}

/// Everything playback needs to open a Track's bytes without a second query.
pub const ResolvedLocation = struct {
    allocator: std.mem.Allocator,
    file_id: i64,
    volume_stable_key: []u8,
    uri: []u8,
    audio_format: u8,
    root_id: ?i64,

    pub fn deinit(self: ResolvedLocation) void {
        self.allocator.free(self.volume_stable_key);
        self.allocator.free(self.uri);
    }
};

/// What the Library recorded about the file a Track resolves to, read in one
/// row so a host can describe a Track without one query per fact.
pub const TrackFileFacts = struct {
    allocator: std.mem.Allocator,
    file_id: i64,
    codec: []u8,
    size_bytes: i64,
    sample_rate: ?i64,
    bit_depth: ?i64,
    channels: ?i64,
    duration_ms: ?i64,
    quick_hash: ?quick_hash.Digest,
    /// The content hash recorded for the file's bytes, which keys their
    /// analysis results, or null when none is recorded.
    content_hash: ?content_hash.Digest,
    /// The uri of the best location that is not missing, or null when every
    /// location is.
    path: ?[]u8,
    /// Whether the last scan observed a non-empty cover in the file.
    has_artwork: bool,
    /// The Release's date and compilation flag, as the projection resolved them
    /// from every file of the Release and any user edits. Null without a
    /// Release.
    release_date: ?[]u8,
    compilation: ?bool,
    /// When the library first saw the file, in Unix seconds.
    first_seen_at: ?i64,
    /// The modification time of `path`'s location, in Unix seconds.
    modified_at: ?i64,
    /// Whether the file states no track total, so the Track's total was
    /// counted from the positions on its disc.
    track_total_inferred: bool,

    pub fn deinit(self: TrackFileFacts) void {
        self.allocator.free(self.codec);
        if (self.path) |value| self.allocator.free(value);
        if (self.release_date) |value| self.allocator.free(value);
    }
};

pub const RecordingMbid = struct {
    text: []u8,
    provenance: metadata.Provenance,

    pub fn deinit(self: RecordingMbid, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const TrackSummary = struct {
    id: i64,
    title: []u8,
    artist: []u8,
    album: []u8,
    album_artist: []u8,
    duration_ms: ?i64,
    track_number: ?i64,
    disc_number: ?i64,
    /// Whether the Track resolves to a file with a location, so a host can grey
    /// out a row without asking a second question per Track.
    has_playable_file: bool,
    release_id: ?i64 = null,
    /// The credited Artist, when the projection resolved one.
    artist_id: ?i64 = null,
    recording_id: ?i64 = null,
    feedback: Feedback = .none,
    rating: ?u8 = null,
    /// The preferred file's codec name; empty when no file is known.
    codec: []u8 = &.{},
    sample_rate: ?u32 = null,
    bit_depth: ?u32 = null,
    /// Whether the codec discards audio. False for an unknown codec.
    lossy: bool = false,
    /// When the library first saw the preferred file, in Unix seconds.
    added_at: ?i64 = null,
    /// Listens of the Track's recording through any of its files.
    play_count: u64 = 0,
    last_played_at: ?i64 = null,
    explicit: metadata.Explicit = .unknown,
    track_total: ?i64 = null,
    disc_total: ?i64 = null,
    /// The leading year of the Release's date.
    year: ?i32 = null,
    integrated_lufs: ?f32 = null,
    bitrate_kbps: ?u32 = null,
    path: []u8 = &.{},
    album_artist_id: ?i64 = null,
    /// The name of the Track's first genre; empty when it has none.
    genre: []u8 = &.{},

    pub fn deinit(self: TrackSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.genre);
        allocator.free(self.path);
        allocator.free(self.codec);
        allocator.free(self.title);
        allocator.free(self.artist);
        allocator.free(self.album);
        allocator.free(self.album_artist);
    }
};

pub const TrackPage = struct {
    allocator: std.mem.Allocator,
    items: []TrackSummary,

    pub fn deinit(self: TrackPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

/// What a Track listing is ordered by.
///
/// Every one of these but `rating` and `loved` names an index, and every
/// ORDER BY they produce ends in `tracks.id`. Both matter. Without the unique
/// tiebreaker a LIMIT/OFFSET walk over a column with ties is free to return
/// one row on two pages and skip a third, because SQLite may order equal keys
/// differently between two evaluations of the same statement.
pub const TrackSort = enum {
    /// Insertion order. The cheapest listing there is, and the default, so a
    /// caller that has no opinion pays for none.
    id,
    artist,
    album,
    title,
    /// Disc, then track number, which is the order an album is listened to.
    track_number,
    duration,
    /// When the file the Track plays was first seen, which an edit that
    /// reprojects the Track keeps; Tracks without a file sort last.
    date_added,
    rating,
    /// Most recently loved first; Tracks whose recording is not loved last.
    loved,
    /// Listens of the Track's recording; unplayed Tracks count zero.
    play_count,
    /// Tracks whose recording was never played sort last in either direction.
    last_played,
    /// The Release's year; Tracks without one sort last in either direction.
    year,
    loudness,
    bitrate,
    path,
    album_artist,
    genre,
};

pub const SortDirection = enum {
    ascending,
    descending,

    fn suffix(self: SortDirection) []const u8 {
        return switch (self) {
            .ascending => "",
            .descending => " DESC",
        };
    }

    fn reversed(self: SortDirection) SortDirection {
        return switch (self) {
            .ascending => .descending,
            .descending => .ascending,
        };
    }
};

/// The size of what a `TrackQuery` matches.
pub const TrackTotals = struct {
    count: u64,
    duration_ms: u64,
};

/// One bounded, ordered, filtered request for a page of Tracks.
///
/// A filter is a relational one — `artist_id`, `release_id` — never a text
/// match against the denormalized columns, so an artist browse and an album
/// browse ask the question the schema can actually index.
pub const TrackQuery = struct {
    artist_id: ?i64 = null,
    release_id: ?i64 = null,
    /// Only Tracks that carry this genre, in `track_genres`.
    genre_id: ?i64 = null,
    /// Only Tracks whose recording is loved. A clear still waiting to be sent
    /// is not a love.
    loved_only: bool = false,
    /// Only Tracks dated within these years, both inclusive, read from the
    /// Release as `TrackSort.year` reads it; either bound leaves out undated
    /// Tracks.
    year_min: ?i32 = null,
    year_max: ?i32 = null,
    /// Only Tracks whose play file is in a lossless codec, or only those in a
    /// lossy one. A Track with no probed codec is neither.
    lossless: ?bool = null,
    /// Only Tracks whose play file runs at this many hertz or more.
    min_sample_rate: ?u32 = null,
    /// Only Tracks whose play file runs at this many hertz or fewer.
    max_sample_rate: ?u32 = null,
    /// Only Tracks whose play file is in this codec, a `codec_id` in any case.
    codec: ?[]const u8 = null,
    /// Only Tracks whose play file was first seen after this Unix time, the
    /// time `TrackSort.date_added` orders by.
    added_after: ?i64 = null,
    /// Only Tracks whose advisory is `Explicit.explicit`.
    explicit_only: bool = false,
    sort: TrackSort = .id,
    direction: SortDirection = .ascending,
    limit: u32 = max_page,
    offset: u32 = 0,
};

pub const TrackRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Upsert by position: a row already at `(release_id, disc, track)` takes
    /// the new values, whatever it presented before, and anything else
    /// inserts. Rows without a Release or a track number have no position to
    /// collide on and always insert, which is what `tracks_position`
    /// (`COALESCE(track_number, -id)`) encodes. The projection does not use
    /// this: it keeps a Track with its file through `seatTracksLocked`.
    pub fn upsertTracks(self: *TrackRepository, tracks: []const TrackInput) !void {
        if (tracks.len == 0) return;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try self.upsertTracksLocked(tracks);
        try self.db.exec("COMMIT;");
    }

    /// Same as `upsertTracks` for a caller that already holds the write lane
    /// and an open transaction.
    pub fn upsertTracksLocked(self: *TrackRepository, tracks: []const TrackInput) !void {
        if (tracks.len == 0) return;
        var update = try self.db.prepare(
            \\UPDATE tracks SET
            \\    recording_id=?1, title=?2, artist=?3, album=?4, album_artist=?5,
            \\    duration_ms=?6, preferred_file_id=?7, artist_id=?11,
            \\    track_total=?12, disc_total=?13, explicit=?14
            \\WHERE release_id=?8 AND COALESCE(disc_number, 1)=?9 AND track_number=?10;
        );
        defer update.deinit();
        var insert = try self.db.prepare(
            \\INSERT INTO tracks(
            \\    recording_id, release_id, title, artist, album, album_artist,
            \\    duration_ms, track_number, disc_number, preferred_file_id, artist_id,
            \\    track_total, disc_total, explicit
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14);
        );
        defer insert.deinit();
        for (tracks) |track| {
            if (track.release_id != null and track.track_number != null) {
                try update.bindOptionalInt64(1, track.recording_id);
                try update.bindText(2, track.title);
                try update.bindText(3, track.artist);
                try update.bindText(4, track.album);
                try update.bindText(5, track.album_artist);
                try update.bindOptionalInt64(6, track.duration_ms);
                try update.bindOptionalInt64(7, track.preferred_file_id);
                try update.bindOptionalInt64(8, track.release_id);
                try update.bindInt64(9, track.disc_number orelse 1);
                try update.bindOptionalInt64(10, track.track_number);
                try update.bindOptionalInt64(11, track.artist_id);
                try update.bindOptionalInt64(12, track.track_total);
                try update.bindOptionalInt64(13, track.disc_total);
                try update.bindInt64(14, @backingInt(track.explicit));
                if (try update.step() != .done) return error.SqlFailed;
                const updated = self.db.changes() != 0;
                try update.reset();
                if (updated) continue;
            }
            try insert.bindOptionalInt64(1, track.recording_id);
            try insert.bindOptionalInt64(2, track.release_id);
            try insert.bindText(3, track.title);
            try insert.bindText(4, track.artist);
            try insert.bindText(5, track.album);
            try insert.bindText(6, track.album_artist);
            try insert.bindOptionalInt64(7, track.duration_ms);
            try insert.bindOptionalInt64(8, track.track_number);
            try insert.bindOptionalInt64(9, track.disc_number);
            try insert.bindOptionalInt64(10, track.preferred_file_id);
            try insert.bindOptionalInt64(11, track.artist_id);
            try insert.bindOptionalInt64(12, track.track_total);
            try insert.bindOptionalInt64(13, track.disc_total);
            try insert.bindInt64(14, @backingInt(track.explicit));
            if (try insert.step() != .done) return error.SqlFailed;
            try insert.reset();
        }
    }

    /// Writes each Track by id at the position its `track` states, inserting
    /// those without an id and storing the id each got. Rows changing
    /// position are parked first with no track number, which
    /// `tracks_position` keeps unique by id, so rows trading positions never
    /// collide. Every position written must be vacant or held by a row in
    /// `seats`. The caller holds the write lane and an open transaction.
    pub fn seatTracksLocked(self: *TrackRepository, seats: []TrackSeat) !void {
        if (seats.len == 0) return;
        var park = try self.db.prepare(
            \\UPDATE tracks SET release_id = ?2, disc_number = ?3, track_number = NULL
            \\WHERE id = ?1 AND NOT (release_id IS ?2 AND COALESCE(disc_number, 1) = COALESCE(?3, 1)
            \\  AND track_number IS ?4);
        );
        defer park.deinit();
        for (seats) |seat| {
            const id = seat.id orelse continue;
            try park.bindInt64(1, id);
            try park.bindOptionalInt64(2, seat.track.release_id);
            try park.bindOptionalInt64(3, seat.track.disc_number);
            try park.bindOptionalInt64(4, seat.track.track_number);
            if (try park.step() != .done) return error.SqlFailed;
            try park.reset();
        }

        var update = try self.db.prepare(
            \\UPDATE tracks SET
            \\    recording_id=?2, release_id=?3, title=?4, artist=?5, album=?6, album_artist=?7,
            \\    duration_ms=?8, track_number=?9, disc_number=?10, preferred_file_id=?11, artist_id=?12,
            \\    track_total=?13, disc_total=?14, explicit=?15
            \\WHERE id=?1;
        );
        defer update.deinit();
        var insert = try self.db.prepare(
            \\INSERT INTO tracks(
            \\    recording_id, release_id, title, artist, album, album_artist,
            \\    duration_ms, track_number, disc_number, preferred_file_id, artist_id,
            \\    track_total, disc_total, explicit
            \\) VALUES (?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15);
        );
        defer insert.deinit();
        for (seats) |*seat| {
            const statement = if (seat.id != null) update else insert;
            if (seat.id) |id| try statement.bindInt64(1, id);
            try bindSeated(statement, seat.track);
            if (try statement.step() != .done) return error.SqlFailed;
            if (seat.id == null) {
                seat.id = self.db.lastInsertRowId();
            } else if (self.db.changes() == 0) {
                return error.TrackNotFound;
            }
            try statement.reset();
        }
    }

    /// The full-text matches for `text` that pass every filter of `query`, in
    /// relevance order; `query.sort` and `query.direction` do not apply. Each
    /// word of `text` must begin a word of the Track, and no character of it
    /// is FTS5 syntax; text with no word matches nothing.
    pub fn search(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        text: []const u8,
        query: TrackQuery,
    ) !TrackPage {
        if (query.limit == 0 or query.limit > max_page) return error.PageOutOfRange;
        var expression_buffer: [search_text.max_match_expression]u8 = undefined;
        const expression = try search_text.matchExpression(&expression_buffer, text) orelse
            return .{ .allocator = allocator, .items = &.{} };
        const bounded = hasBoundFilter(query);
        var statement = try self.db.prepare(switch (bounded) {
            inline else => |with_bound| track_columns ++
                "FROM track_search\n" ++
                "JOIN tracks ON tracks.id = track_search.rowid\n" ++
                recording_joins ++
                "WHERE track_search MATCH ?12\n" ++
                "  AND " ++ comptime filterText(if (with_bound) .per_track else .none) ++ "\n" ++
                "ORDER BY rank\n" ++
                "LIMIT ?1 OFFSET ?2;",
        });
        defer statement.deinit();
        try statement.bindInt64(1, query.limit);
        try statement.bindInt64(2, query.offset);
        try bindFilters(statement, query, bounded);
        try statement.bindText(12, expression);
        return collectTrackPage(allocator, statement);
    }

    /// One bounded page of Tracks, in an order the caller named.
    ///
    /// Both halves of `query` are load-bearing. The sort decides which index
    /// SQLite walks, and because every generated ORDER BY ends in `tracks.id`
    /// the walk is a total order — so page N+1 continues exactly where page N
    /// stopped, even across the thousands of Tracks that share a title with
    /// another. The filters are relational: `artist_id` and `release_id`, not
    /// a text match against the denormalized columns.
    pub fn page(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        query: TrackQuery,
    ) !TrackPage {
        if (query.limit == 0 or query.limit > max_page) return error.PageOutOfRange;
        const filter = trackFilter(query);
        return self.pageAs(allocator, query, filter, pageForm(query, filter));
    }

    fn pageAs(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        query: TrackQuery,
        filter: TrackFilter,
        form: PageForm,
    ) !TrackPage {
        var statement = try self.db.prepare(
            trackQueryText(filter, query.loved_only, query.genre_id != null, query.sort, query.direction, form),
        );
        defer statement.deinit();
        try statement.bindInt64(1, query.limit);
        try statement.bindInt64(2, query.offset);
        try bindPage(statement, query, form);
        return collectTrackPage(allocator, statement);
    }

    /// How many Tracks a filtered listing has to page through, so a host can
    /// size a scrollbar without walking the listing.
    /// Counts what `page` would return. It shares `by_artist` with the paged
    /// query rather than restating the predicate, because it had its own copy
    /// and the two drifted the moment the definition of an artist's tracks
    /// widened: the list showed an artist's album tracks while the count above
    /// it said zero. Parameter positions match `buildTrackQuery` for the same
    /// reason. A genre alone is counted from `track_genres`, which holds each
    /// of a Track's genres once.
    pub fn countMatching(self: *const TrackRepository, query: TrackQuery) !u64 {
        if (query.genre_id) |genre_id| {
            if (query.artist_id == null and query.release_id == null and !query.loved_only and
                !hasBoundFilter(query))
                return self.countCarrying(genre_id);
        }
        const bound = boundForm(query);
        var statement = try self.db.prepare(switch (bound) {
            inline else => |resolved_bound| "SELECT count(*) FROM tracks\nWHERE " ++ comptime filterText(resolved_bound) ++ ";",
        });
        defer statement.deinit();
        try bindFilters(statement, query, bound != .none);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// Tracks whose preferred file has no location other than a missing one,
    /// as the last scan or open recorded it; nothing on disk is asked.
    pub fn missingFileCount(self: *const TrackRepository) !u64 {
        var statement = try self.db.prepare(
            \\SELECT count(*) FROM tracks
            \\WHERE NOT EXISTS (
            \\    SELECT 1 FROM locations
            \\    WHERE locations.file_id = tracks.preferred_file_id AND locations.state <> 'missing'
            \\);
        );
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// How many Tracks `page` would return for the same query and their
    /// summed duration, a Track with none counting as zero.
    pub fn totals(self: *const TrackRepository, query: TrackQuery) !TrackTotals {
        const bounded = hasBoundFilter(query);
        if (!bounded and trackFilter(query) == .none and !query.loved_only and query.genre_id == null) {
            var statement = try self.db.prepare("SELECT count(*), COALESCE(sum(max(duration_ms, 0)), 0) FROM tracks;");
            defer statement.deinit();
            if (try statement.step() != .row) return error.SqlFailed;
            return .{ .count = @intCast(statement.columnInt64(0)), .duration_ms = @intCast(statement.columnInt64(1)) };
        }
        var statement = try self.db.prepare(switch (boundForm(query)) {
            inline else => |resolved_bound| "SELECT count(*), COALESCE(sum(max(tracks.duration_ms, 0)), 0) FROM tracks\nWHERE " ++
                comptime filterText(resolved_bound) ++ ";",
        });
        defer statement.deinit();
        try bindFilters(statement, query, bounded);
        if (try statement.step() != .row) return error.SqlFailed;
        return .{ .count = @intCast(statement.columnInt64(0)), .duration_ms = @intCast(statement.columnInt64(1)) };
    }

    /// How many Tracks `search` would return for `text` and the same
    /// filters, and their summed duration; text with no word matches nothing.
    pub fn searchTotals(self: *const TrackRepository, text: []const u8, query: TrackQuery) !TrackTotals {
        var expression_buffer: [search_text.max_match_expression]u8 = undefined;
        const expression = try search_text.matchExpression(&expression_buffer, text) orelse
            return .{ .count = 0, .duration_ms = 0 };
        const bounded = hasBoundFilter(query);
        var statement = try self.db.prepare(switch (bounded) {
            inline else => |with_bound| "SELECT count(*), COALESCE(sum(max(tracks.duration_ms, 0)), 0)\n" ++
                "FROM track_search\n" ++
                "JOIN tracks ON tracks.id = track_search.rowid\n" ++
                "WHERE track_search MATCH ?12\n" ++
                "  AND " ++ comptime filterText(if (with_bound) .per_track else .none) ++ ";",
        });
        defer statement.deinit();
        try bindFilters(statement, query, bounded);
        try statement.bindText(12, expression);
        if (try statement.step() != .row) return error.SqlFailed;
        return .{ .count = @intCast(statement.columnInt64(0)), .duration_ms = @intCast(statement.columnInt64(1)) };
    }

    /// The ids of the Tracks with a playable file among the `limit` rows from
    /// `offset` of the listing `page`, or `search` when `text` is not empty,
    /// returns for `query`, in that listing's order. `limit` may exceed a
    /// page, up to `max_id_window`.
    pub fn playableIds(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        text: []const u8,
        query: TrackQuery,
    ) ![]i64 {
        if (query.limit == 0 or query.limit > max_id_window) return error.PageOutOfRange;
        var statement = if (text.len != 0) blk: {
            var expression_buffer: [search_text.max_match_expression]u8 = undefined;
            const expression = try search_text.matchExpression(&expression_buffer, text) orelse
                return allocator.alloc(i64, 0);
            const bounded = hasBoundFilter(query);
            const statement = try self.db.prepare(switch (bounded) {
                inline else => |with_bound| "SELECT tracks.id, EXISTS(SELECT 1 FROM locations\n" ++
                    "    WHERE locations.file_id = tracks.preferred_file_id AND locations.state <> 'missing')\n" ++
                    "FROM track_search\n" ++
                    "JOIN tracks ON tracks.id = track_search.rowid\n" ++
                    "WHERE track_search MATCH ?12\n" ++
                    "  AND " ++ comptime filterText(if (with_bound) .per_track else .none) ++ "\n" ++
                    "ORDER BY rank\n" ++
                    "LIMIT ?1 OFFSET ?2;",
            });
            errdefer statement.deinit();
            try bindFilters(statement, query, bounded);
            try statement.bindText(12, expression);
            break :blk statement;
        } else blk: {
            const filter = trackFilter(query);
            const statement = try self.db.prepare(
                trackQueryText(filter, query.loved_only, query.genre_id != null, query.sort, query.direction, pageForm(query, filter)),
            );
            errdefer statement.deinit();
            try bindPage(statement, query, pageForm(query, filter));
            break :blk statement;
        };
        defer statement.deinit();
        try statement.bindInt64(1, query.limit);
        try statement.bindInt64(2, query.offset);
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row) {
            if (statement.columnInt64(if (text.len != 0) 1 else 8) != 0) try ids.append(allocator, statement.columnInt64(0));
        }
        return ids.toOwnedSlice(allocator);
    }

    fn countCarrying(self: *const TrackRepository, genre_id: i64) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM track_genres WHERE genre_id = ?1;");
        defer statement.deinit();
        try statement.bindInt64(1, genre_id);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn recordingMbid(self: *const TrackRepository, allocator: std.mem.Allocator, track_id: i64) !?RecordingMbid {
        return self.resolvedField(allocator, track_id, .musicbrainz_recording_id);
    }

    /// One text field of the file a Track plays, such as a MusicBrainz ID or
    /// the composer, resolved under `prefer_file` from Orca's value and the
    /// file's tag of the same name.
    pub fn resolvedField(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
        comptime field: metadata.Field,
    ) !?RecordingMbid {
        const field_number = std.fmt.comptimePrint("{d}", .{@backingInt(field)});
        var statement = try self.db.prepare(
            "SELECT orca.value, orca.provenance, orca.locked, observed." ++ @tagName(field) ++ "\n" ++
                "FROM (SELECT " ++ track_play_file ++ " AS file_id FROM tracks WHERE tracks.id = ?1) AS track\n" ++
                "LEFT JOIN orca_metadata_values AS orca\n" ++
                "    ON orca.file_id = track.file_id AND orca.field = " ++ field_number ++ "\n" ++
                "LEFT JOIN observed_file_tags AS observed ON observed.file_id = track.file_id;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return null;
        const orca: ?metadata.Value = if (statement.columnIsNull(0) or statement.columnText(0).len == 0) null else .{
            .text = statement.columnText(0),
            .provenance = std.enums.fromInt(metadata.Provenance, statement.columnInt64(1)) orelse
                return error.InvalidStoredProvenance,
            .locked = statement.columnInt64(2) != 0,
        };
        const observed: ?metadata.Value = if (statement.columnIsNull(3) or statement.columnText(3).len == 0) null else .{
            .text = statement.columnText(3),
            .provenance = .observed_file,
        };
        const resolved = metadata.resolveValue(observed, orca, .prefer_file) orelse return null;
        return .{ .text = try allocator.dupe(u8, resolved.text), .provenance = resolved.provenance };
    }

    /// The files a Track resolves to: its preferred file and every other
    /// encoding of its recording. Bounded by `max_page`.
    pub fn fileIds(self: *const TrackRepository, allocator: std.mem.Allocator, track_id: i64) ![]i64 {
        var statement = try self.db.prepare(track_file_ids_sql);
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        try statement.bindInt64(2, max_page);
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row) try ids.append(allocator, statement.columnInt64(0));
        return ids.toOwnedSlice(allocator);
    }

    /// The Tracks a file backs: as their preferred file, or through their
    /// Recording. The reverse of `fileIds`.
    pub fn idsForFile(self: *const TrackRepository, allocator: std.mem.Allocator, file_id: i64) ![]i64 {
        var statement = try self.db.prepare(file_track_ids_sql);
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, max_page);
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row) try ids.append(allocator, statement.columnInt64(0));
        return ids.toOwnedSlice(allocator);
    }

    /// One Track by id, for the "what is playing right now" question. Bounded
    /// by construction: a single row, copied out, with no statement escaping.
    pub fn byId(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
    ) !?TrackSummary {
        var statement = try self.db.prepare(track_columns ++ "FROM tracks\n" ++ recording_joins ++
            "WHERE tracks.id = ?1;");
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        var page_result = try collectTrackPage(allocator, statement);
        if (page_result.items.len == 0) {
            page_result.deinit();
            return null;
        }
        const first = page_result.items[0];
        for (page_result.items[1..]) |extra| extra.deinit(allocator);
        allocator.free(page_result.items);
        return first;
    }

    /// Where a Track's bytes actually live. This is the call that turns "a row
    /// in a list" into "audio a Player can open", so it answers with the
    /// volume's stable key rather than assuming a local path, and prefers a
    /// location that a scan has confirmed.
    pub fn playableLocation(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
    ) !?ResolvedLocation {
        var statement = try self.db.prepare(
            \\SELECT locations.file_id, volumes.stable_key, locations.uri, files.audio_format,
            \\       locations.root_id
            \\FROM tracks
            \\JOIN files ON files.id = COALESCE(
            \\    tracks.preferred_file_id,
            \\    (SELECT id FROM files WHERE recording_id = tracks.recording_id ORDER BY id LIMIT 1)
            \\)
            \\JOIN locations ON locations.file_id = files.id
            \\JOIN volumes ON volumes.id = locations.volume_id
            \\WHERE tracks.id = ?1
            \\ORDER BY CASE locations.state
            \\    WHEN 'present' THEN 0 WHEN 'unverified' THEN 1 ELSE 2 END, locations.id
            \\LIMIT 1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return null;
        const stable_key = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(stable_key);
        const uri = try allocator.dupe(u8, statement.columnText(2));
        errdefer allocator.free(uri);
        return .{
            .allocator = allocator,
            .file_id = statement.columnInt64(0),
            .volume_stable_key = stable_key,
            .uri = uri,
            .audio_format = std.math.cast(u8, statement.columnInt64(3)) orelse
                return error.InvalidStoredAudioFormat,
            .root_id = if (statement.columnIsNull(4)) null else statement.columnInt64(4),
        };
    }

    /// The Release a Track is filed under, or null when it has none or does
    /// not exist.
    pub fn releaseId(self: *const TrackRepository, track_id: i64) !?i64 {
        var statement = try self.db.prepare("SELECT release_id FROM tracks WHERE id = ?1;");
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row or statement.columnIsNull(0)) return null;
        return statement.columnInt64(0);
    }

    /// The recorded facts of the file a Track resolves to, or null when the
    /// Track does not exist or has no file. One row: nothing on disk is read.
    pub fn fileFacts(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
    ) !?TrackFileFacts {
        return self.fileFactsOf(allocator, track_id, null);
    }

    /// `fileFacts` about one named file of the Track instead of the one it
    /// resolves to, or about the resolved file when `file_id` is null.
    pub fn fileFactsOf(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
        file_id: ?i64,
    ) !?TrackFileFacts {
        var statement = try self.db.prepare(
            \\SELECT files.id, files.codec, files.size_bytes, files.sample_rate,
            \\       files.bit_depth, files.channels, files.duration_ms, files.quick_hash,
            \\       (SELECT locations.uri FROM locations
            \\        WHERE locations.file_id = files.id AND locations.state <> 'missing'
            \\        ORDER BY CASE locations.state WHEN 'present' THEN 0 ELSE 1 END, locations.id
            \\        LIMIT 1),
            \\       COALESCE(observed_file_tags.artwork_byte_size, 0) > 0
            \\           AND observed_file_tags.artwork_mime_type IS NOT NULL
        ++ "\n           OR " ++ releases.releaseCoverSql("releases") ++ ",\n" ++
            \\       releases.release_date, releases.is_compilation, files.first_seen_at,
            \\       (SELECT locations.modified_ns FROM locations
            \\        WHERE locations.file_id = files.id AND locations.state <> 'missing'
            \\        ORDER BY CASE locations.state WHEN 'present' THEN 0 ELSE 1 END, locations.id
            \\        LIMIT 1),
            \\       tracks.track_total IS NOT NULL AND NOT EXISTS (
            \\           SELECT 1 FROM files AS member
            \\           JOIN observed_file_tags AS member_tags ON member_tags.file_id = member.id
            \\           WHERE (member.id = tracks.preferred_file_id OR member.recording_id = tracks.recording_id)
            \\             AND member_tags.track_total > 0),
            \\       CASE WHEN files.content_hash_algorithm = 1 THEN files.content_hash END
            \\FROM tracks
            \\JOIN files ON files.id = COALESCE(
            \\    ?2,
            \\    tracks.preferred_file_id,
            \\    (SELECT id FROM files WHERE recording_id = tracks.recording_id ORDER BY id LIMIT 1)
            \\)
            \\LEFT JOIN observed_file_tags ON observed_file_tags.file_id = files.id
            \\LEFT JOIN releases ON releases.id = tracks.release_id
            \\WHERE tracks.id = ?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        try statement.bindOptionalInt64(2, file_id);
        if (try statement.step() != .row) return null;
        const codec = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(codec);
        const path: ?[]u8 = if (statement.columnIsNull(8))
            null
        else
            try allocator.dupe(u8, statement.columnText(8));
        errdefer if (path) |value| allocator.free(value);
        const release_date: ?[]u8 = if (statement.columnIsNull(10))
            null
        else
            try allocator.dupe(u8, statement.columnText(10));
        errdefer if (release_date) |value| allocator.free(value);
        return .{
            .allocator = allocator,
            .file_id = statement.columnInt64(0),
            .codec = codec,
            .size_bytes = statement.columnInt64(2),
            .sample_rate = optionalInt64(statement, 3),
            .bit_depth = optionalInt64(statement, 4),
            .channels = optionalInt64(statement, 5),
            .duration_ms = optionalInt64(statement, 6),
            .quick_hash = digestColumn(statement, 7),
            .content_hash = digestColumn(statement, 15),
            .path = path,
            .has_artwork = statement.columnInt64(9) != 0,
            .release_date = release_date,
            .compilation = if (statement.columnIsNull(11)) null else statement.columnInt64(11) != 0,
            .first_seen_at = optionalInt64(statement, 12),
            .modified_at = if (optionalInt64(statement, 13)) |nanoseconds|
                (if (nanoseconds > 0) @divFloor(nanoseconds, std.time.ns_per_s) else null)
            else
                null,
            .track_total_inferred = statement.columnInt64(14) != 0,
        };
    }

    /// Which of a Release's Tracks might supply its cover, in listening order.
    ///
    /// Fills `out` and returns how many ids were written, so the answer is
    /// bounded by the caller's buffer and allocates nothing.
    ///
    /// The predicate is what the *scan* observed — `artwork_mime_type` is not
    /// null and the payload is not empty — rather than what a file turns out to
    /// contain. That is what makes this cheap: a Release whose files carry no
    /// artwork answers with one indexed query and opens no files at all, where
    /// finding out by reading would mean opening every track to learn nothing.
    /// The observation can be stale, so it selects candidates rather than
    /// deciding; the bytes are still read from the file.
    ///
    /// The order is `tracks_position`'s: disc, then track number, then id. It
    /// is a total order over a Release, so the same Release yields the same
    /// cover on every run — which is the whole point when its tracks disagree.
    pub fn artworkCandidatesInto(
        self: *const TrackRepository,
        release_id: i64,
        out: []i64,
    ) !usize {
        if (out.len == 0) return 0;
        var statement = try self.db.prepare(
            \\SELECT tracks.id
            \\FROM tracks
            \\JOIN files ON files.id = COALESCE(
            \\    tracks.preferred_file_id,
            \\    (SELECT id FROM files WHERE recording_id = tracks.recording_id ORDER BY id LIMIT 1)
            \\)
            \\JOIN observed_file_tags ON observed_file_tags.file_id = files.id
            \\WHERE tracks.release_id = ?1
            \\  AND observed_file_tags.artwork_mime_type IS NOT NULL
            \\  AND COALESCE(observed_file_tags.artwork_byte_size, 0) > 0
            \\ORDER BY COALESCE(tracks.disc_number, 1),
            \\         COALESCE(tracks.track_number, -tracks.id),
            \\         tracks.id
            \\LIMIT ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        try statement.bindInt64(2, @intCast(out.len));
        var written: usize = 0;
        while (written < out.len and try statement.step() == .row) : (written += 1)
            out[written] = statement.columnInt64(0);
        return written;
    }

    pub fn count(self: *const TrackRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM tracks;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

pub const track_columns =
    "SELECT tracks.id, tracks.title, tracks.artist, tracks.album, tracks.album_artist,\n" ++
    "       tracks.duration_ms, tracks.track_number, tracks.disc_number,\n" ++
    "       EXISTS(\n" ++
    "           SELECT 1 FROM locations\n" ++
    "           WHERE locations.file_id = tracks.preferred_file_id\n" ++
    "             AND locations.state <> 'missing'\n" ++
    "       ),\n" ++
    "       tracks.release_id, tracks.artist_id, COALESCE(feedback.score, 0), tracks.recording_id,\n" ++
    "       ratings.rating, play_file.codec, play_file.sample_rate, play_file.bit_depth,\n" ++
    "       play_file.first_seen_at, COALESCE(recording_play_stats.play_count, 0),\n" ++
    "       recording_play_stats.last_played_at, tracks.explicit, tracks.track_total,\n" ++
    "       tracks.disc_total, " ++ release_year ++ ", " ++ play_file_loudness ++ ",\n" ++
    "       " ++ play_file_bitrate ++ ",\n" ++
    "       COALESCE(" ++ play_file_path ++ ", ''), track_release.album_artist_id,\n" ++
    "       COALESCE(" ++ first_genre_name ++ ", '')\n";

/// How many columns `track_columns` selects, so a query that appends its own
/// columns can read them past the end.
pub const track_column_count = 29;

/// The Release's leading four-digit year, or NULL when its date has none.
pub const release_year =
    "CASE WHEN substr(track_release.release_date, 1, 4) GLOB '[0-9][0-9][0-9][0-9]' " ++
    "THEN CAST(substr(track_release.release_date, 1, 4) AS INTEGER) END";

const play_file_bitrate =
    "CASE WHEN play_file.size_bytes > 0 AND play_file.duration_ms > 0 THEN " ++ indexed_bitrate ++ " END";

const indexed_bitrate = "(play_file.size_bytes * 8 + play_file.duration_ms / 2) / play_file.duration_ms";

fn bestLocation(comptime column: []const u8, comptime file_id: []const u8) []const u8 {
    return "(SELECT best_location." ++ column ++ " FROM locations AS best_location\n" ++
        "    WHERE best_location.file_id = " ++ file_id ++ " AND best_location.state <> 'missing'\n" ++
        "    ORDER BY CASE best_location.state WHEN 'present' THEN 0 ELSE 1 END, best_location.id LIMIT 1)";
}

const play_file_join = "LEFT JOIN files AS play_file ON play_file.id = " ++ track_play_file ++ "\n";
pub const play_file_loudness = "(SELECT file_loudness.integrated_lufs FROM file_loudness " ++
    "WHERE file_loudness.file_id = play_file.id AND file_loudness.source_identity = play_file.content_hash " ++
    "AND play_file.content_hash_algorithm = 1 AND " ++ measurableChannels("play_file") ++ ")";
const play_file_path = bestLocation("uri", "play_file.id");
const first_genre_id = "(SELECT first_track_genre.genre_id FROM track_genres AS first_track_genre " ++
    "WHERE first_track_genre.track_id = tracks.id AND first_track_genre.ordinal = 0)";
const first_genre_name = "(SELECT first_genre.name FROM genres AS first_genre WHERE first_genre.id = " ++
    first_genre_id ++ ")";

pub const recording_joins =
    "LEFT JOIN feedback ON feedback.recording_id = tracks.recording_id\n" ++
    "LEFT JOIN ratings ON ratings.recording_id = tracks.recording_id\n" ++
    "LEFT JOIN recording_play_stats ON recording_play_stats.recording_id = tracks.recording_id\n" ++
    play_file_join ++
    "LEFT JOIN releases AS track_release ON track_release.id = tracks.release_id\n";

const TrackFilter = enum { none, artist, release, artist_and_release };

/// A NULL track number sorts after every real one rather than before every
/// one, which is what "the untagged tail of the album" means. The same
/// expression appears in `tracks_sort_*` and `tracks_by_*`, so SQLite can
/// satisfy the ORDER BY from the index instead of building a temp B-tree.
const null_position = "2147483647";

fn positionTerms(comptime direction: SortDirection) []const u8 {
    const suffix = comptime direction.suffix();
    return "COALESCE(tracks.disc_number, 1)" ++ suffix ++
        ", COALESCE(tracks.track_number, " ++ null_position ++ ")" ++ suffix;
}

pub fn orderTerms(comptime sort: TrackSort, comptime direction: SortDirection) []const u8 {
    const suffix = comptime direction.suffix();
    const tiebreak = ", tracks.id" ++ suffix;
    return switch (sort) {
        .id => "tracks.id" ++ suffix,
        .artist => "tracks.artist COLLATE NOCASE" ++ suffix ++
            ", tracks.album COLLATE NOCASE" ++ suffix ++
            ", " ++ positionTerms(direction) ++ tiebreak,
        .album => "tracks.album COLLATE NOCASE" ++ suffix ++
            ", " ++ positionTerms(direction) ++ tiebreak,
        .title => "tracks.title COLLATE NOCASE" ++ suffix ++ tiebreak,
        .track_number => positionTerms(direction) ++ tiebreak,
        .duration => "tracks.duration_ms" ++ suffix ++ tiebreak,
        .date_added => "play_file.first_seen_at IS NULL, play_file.first_seen_at" ++ suffix ++ tiebreak,
        .rating => "ratings.rating IS NULL, ratings.rating" ++ suffix ++ tiebreak,
        .loved => "COALESCE(feedback.score, 0) <> 1, " ++
            "CASE WHEN feedback.score = 1 THEN feedback.updated_at END" ++
            comptime direction.reversed().suffix() ++ tiebreak,
        .play_count => "COALESCE(recording_play_stats.play_count, 0)" ++ suffix ++ tiebreak,
        .last_played => "recording_play_stats.last_played_at IS NULL, " ++
            "recording_play_stats.last_played_at" ++ suffix ++ tiebreak,
        .year => "(" ++ release_year ++ ") IS NULL, " ++ release_year ++ suffix ++ tiebreak,
        .loudness => play_file_loudness ++ suffix ++ " NULLS LAST" ++ tiebreak,
        .bitrate => "(" ++ play_file_bitrate ++ ") IS NULL, " ++ play_file_bitrate ++ suffix ++ tiebreak,
        .path => play_file_path ++ suffix ++ " NULLS LAST" ++ tiebreak,
        .album_artist => "tracks.album_artist COLLATE NOCASE" ++ suffix ++
            ", tracks.album COLLATE NOCASE" ++ suffix ++
            ", " ++ positionTerms(direction) ++ tiebreak,
        .genre => first_genre_name ++ " COLLATE NOCASE" ++ suffix ++ " NULLS LAST, " ++
            first_genre_id ++ suffix ++ tiebreak,
    };
}

/// What it means for a Track to be an artist's.
///
/// Credited to them, *or* on a Release they are the album artist of. The
/// narrow definition -- credit only -- leaves an artist owning an album and no
/// songs whenever track credits differ from the album credit ("X feat. Y",
/// "X / Y", no ARTIST tag). Those are different credited artists, and merging
/// them would destroy information.
pub const by_artist =
    "(tracks.artist_id = ?3 OR tracks.release_id IN " ++
    "(SELECT id FROM releases WHERE album_artist_id = ?3))";

pub const by_loved_recording =
    "tracks.recording_id IN (SELECT recording_id FROM feedback WHERE score = 1)";

pub const by_genre = "tracks.id IN (SELECT track_id FROM track_genres WHERE genre_id = ?6)";

/// What it means for a Release to be an artist's, mirroring `by_artist`.
///
/// Theirs as album artist, *or* carrying a track credited to them, so a
/// featured-only artist's release list is not empty beside their tracks.
pub const by_release_artist =
    "(releases.album_artist_id = ?3 OR releases.id IN " ++
    "(SELECT release_id FROM tracks WHERE tracks.artist_id = ?3))";

/// The filters bound as parameters ?7 to ?11 and ?13 to ?15, each true when
/// unset; ?12 is a search's match expression. A year
/// is read as `release_year` reads it and a codec as `codec_id.lossless`
/// lists it, so a filter and the summary it filters cannot disagree.
const by_bound_filters = by_bound_track_filters ++ "\n  AND " ++
    "(?9 IS NULL OR EXISTS (SELECT 1 FROM files AS bound_file WHERE bound_file.id = " ++ track_play_file ++ "\n" ++
    "    AND bound_file.codec <> '' AND (bound_file.codec IN (" ++ lossless_codecs ++ ")) = ?9))\n" ++
    "  AND (?10 IS NULL OR EXISTS (SELECT 1 FROM files AS bound_file WHERE bound_file.id = " ++ track_play_file ++ "\n" ++
    "    AND bound_file.sample_rate >= ?10))\n" ++
    "  AND (?13 IS NULL OR EXISTS (SELECT 1 FROM files AS bound_file WHERE bound_file.id = " ++ track_play_file ++ "\n" ++
    "    AND bound_file.first_seen_at > ?13))\n" ++
    "  AND (?14 IS NULL OR EXISTS (SELECT 1 FROM files AS bound_file WHERE bound_file.id = " ++ track_play_file ++ "\n" ++
    "    AND bound_file.codec = lower(?14)))\n" ++
    "  AND (?15 IS NULL OR EXISTS (SELECT 1 FROM files AS bound_file WHERE bound_file.id = " ++ track_play_file ++ "\n" ++
    "    AND bound_file.sample_rate <= ?15))";

const by_bound_track_filters =
    "(?7 IS NULL OR tracks.release_id IN (SELECT id FROM releases WHERE " ++ bare_release_year ++ " >= ?7))\n" ++
    "  AND (?8 IS NULL OR tracks.release_id IN (SELECT id FROM releases WHERE " ++ bare_release_year ++ " <= ?8))\n" ++
    "  AND (?11 = 0 OR tracks.explicit = " ++ explicit_value ++ ")";

const by_bound_filters_from_files = by_bound_track_filters ++ "\n" ++
    "  AND tracks.id IN (SELECT tracks.id FROM files AS bound_file\n" ++
    "    CROSS JOIN tracks ON tracks.preferred_file_id = bound_file.id\n" ++
    "    WHERE " ++ bound_file_terms ++ "\n" ++
    "    UNION ALL SELECT tracks.id FROM tracks\n" ++
    "    CROSS JOIN files AS bound_file ON bound_file.id = " ++ track_play_file ++ "\n" ++
    "    WHERE tracks.preferred_file_id IS NULL AND " ++ bound_file_terms ++ ")";

const bound_file_terms =
    "(?9 IS NULL OR bound_file.codec <> '' AND (bound_file.codec IN (" ++ lossless_codecs ++ ")) = ?9)\n" ++
    "      AND (?10 IS NULL OR bound_file.sample_rate >= ?10)\n" ++
    "      AND (?13 IS NULL OR bound_file.first_seen_at > ?13)\n" ++
    "      AND (?14 IS NULL OR bound_file.codec = lower(?14))\n" ++
    "      AND (?15 IS NULL OR bound_file.sample_rate <= ?15)";

const by_relational_filters =
    "(?3 IS NULL OR " ++ by_artist ++ ")\n" ++
    "  AND (?4 IS NULL OR tracks.release_id = ?4)\n" ++
    "  AND (?5 = 0 OR " ++ by_loved_recording ++ ")\n" ++
    "  AND (?6 IS NULL OR " ++ by_genre ++ ")";

/// Every filter of a `TrackQuery`, each true when unset, on the parameter
/// positions `buildTrackQuery` gives them; the bound filters only when
/// `with_bound`, so a listing without them never tests them.
fn filterText(comptime bound: BoundForm) []const u8 {
    return switch (bound) {
        .none => by_relational_filters,
        .per_track => by_relational_filters ++ "\n  AND " ++ by_bound_filters,
        .from_files => by_relational_filters ++ "\n  AND " ++ by_bound_filters_from_files,
    };
}

const BoundForm = enum { none, per_track, from_files };

fn boundForm(query: TrackQuery) BoundForm {
    if (!hasBoundFilter(query)) return .none;
    const file_filter = query.lossless != null or query.min_sample_rate != null or
        query.max_sample_rate != null or query.codec != null or query.added_after != null;
    if (file_filter and query.artist_id == null and query.release_id == null and !query.loved_only and
        query.genre_id == null) return .from_files;
    return .per_track;
}

const bare_release_year =
    "CASE WHEN substr(release_date, 1, 4) GLOB '[0-9][0-9][0-9][0-9]' " ++
    "THEN CAST(substr(release_date, 1, 4) AS INTEGER) END";

const lossless_codecs = blk: {
    var list: []const u8 = "";
    for (codec_id.lossless) |identifier| list = list ++ (if (list.len == 0) "" else ", ") ++ "'" ++ identifier ++ "'";
    break :blk list;
};

const explicit_value = std.fmt.comptimePrint("{d}", .{@backingInt(metadata.Explicit.explicit)});

fn hasBoundFilter(query: TrackQuery) bool {
    return query.year_min != null or query.year_max != null or query.lossless != null or
        query.min_sample_rate != null or query.explicit_only or query.max_sample_rate != null or
        query.codec != null or query.added_after != null;
}

fn bindBoundFilters(statement: sqlite.Statement, query: TrackQuery) !void {
    try statement.bindOptionalInt64(7, if (query.year_min) |year| year else null);
    try statement.bindOptionalInt64(8, if (query.year_max) |year| year else null);
    try statement.bindOptionalInt64(9, if (query.lossless) |lossless| @intFromBool(lossless) else null);
    try statement.bindOptionalInt64(10, if (query.min_sample_rate) |rate| rate else null);
    try statement.bindInt64(11, @intFromBool(query.explicit_only));
    try statement.bindOptionalInt64(13, query.added_after);
    try statement.bindOptionalText(14, query.codec);
    try statement.bindOptionalInt64(15, if (query.max_sample_rate) |rate| rate else null);
}

fn trackFilter(query: TrackQuery) TrackFilter {
    if (query.artist_id != null and query.release_id != null) return .artist_and_release;
    if (query.artist_id != null) return .artist;
    if (query.release_id != null) return .release;
    return .none;
}

fn pageForm(query: TrackQuery, filter: TrackFilter) PageForm {
    if (hasBoundFilter(query)) return if (boundForm(query) == .from_files and !walksTrackIndex(query.sort))
        .from_files
    else
        .bounded;
    if (filter == .none and !query.loved_only and query.genre_id == null and
        query.offset <= candidate_offset_max)
        return .candidates;
    return .scan;
}

fn walksTrackIndex(sort: TrackSort) bool {
    return switch (sort) {
        .id, .artist, .album, .title, .track_number, .duration, .album_artist => true,
        .date_added, .rating, .loved, .play_count, .last_played, .year, .loudness, .bitrate, .path, .genre => false,
    };
}

fn bindPage(statement: sqlite.Statement, query: TrackQuery, form: PageForm) !void {
    if (query.artist_id) |artist_id| try statement.bindInt64(3, artist_id);
    if (query.release_id) |release_id| try statement.bindInt64(4, release_id);
    if (query.genre_id) |genre_id| try statement.bindInt64(6, genre_id);
    if (form == .bounded or form == .from_files) {
        try statement.bindInt64(5, @intFromBool(query.loved_only));
        try bindBoundFilters(statement, query);
    }
}

fn bindFilters(statement: sqlite.Statement, query: TrackQuery, bounded: bool) !void {
    try statement.bindOptionalInt64(3, query.artist_id);
    try statement.bindOptionalInt64(4, query.release_id);
    try statement.bindInt64(5, @intFromBool(query.loved_only));
    try statement.bindOptionalInt64(6, query.genre_id);
    if (bounded) try bindBoundFilters(statement, query);
}

fn buildTrackQuery(
    comptime filter: TrackFilter,
    comptime loved_only: bool,
    comptime genre: bool,
    comptime sort: TrackSort,
    comptime direction: SortDirection,
    comptime form: PageForm,
) [:0]const u8 {
    @setEvalBranchQuota(20_000);
    const filter_terms = switch (filter) {
        .none => "",
        .artist => by_artist,
        .release => "tracks.release_id = ?4",
        .artist_and_release => by_artist ++ " AND tracks.release_id = ?4",
    };
    comptime var terms: []const u8 = "";
    inline for ([_][]const u8{
        filter_terms,
        if (loved_only) by_loved_recording else "",
        if (genre) by_genre else "",
        if (form == .bounded or form == .from_files) "(?5 = 0 OR " ++ by_loved_recording ++ ")" else "",
        if (form == .bounded or form == .from_files) "(?6 IS NULL OR " ++ by_genre ++ ")" else "",
        switch (form) {
            .scan, .candidates => "",
            .bounded => by_bound_filters,
            .from_files => by_bound_filters_from_files,
        },
    }) |term| {
        if (term.len != 0) terms = terms ++ (if (terms.len == 0) "WHERE " else " AND ") ++ term;
    }
    const where = if (terms.len == 0) "" else terms ++ "\n";
    const order = "ORDER BY " ++ orderTerms(sort, direction) ++ "\n";
    if (form == .candidates and filter == .none and !loved_only and !genre) {
        if (candidateIds(sort, direction)) |candidates| {
            return track_columns ++
                "FROM (SELECT tracks.id AS page_id FROM (" ++ candidates ++ ") AS candidate\n" ++
                "CROSS JOIN tracks ON tracks.id = candidate.page_id\n" ++ sortJoin(sort) ++ order ++
                "LIMIT ?1 OFFSET ?2) AS track_page\n" ++
                "CROSS JOIN tracks ON tracks.id = track_page.page_id\n" ++ recording_joins ++ order ++ ";";
        }
    }
    return track_columns ++
        "FROM (SELECT tracks.id AS page_id FROM tracks\n" ++ sortJoin(sort) ++ where ++ order ++
        "LIMIT ?1 OFFSET ?2) AS track_page\n" ++
        "JOIN tracks ON tracks.id = track_page.page_id\n" ++ recording_joins ++ order ++ ";";
}

/// How a page chooses its ids. `candidates` reads only the first
/// `limit + offset` rows of each index it walks, so its cost grows with the
/// offset; past `candidate_offset_max` a `scan` of the whole library is
/// cheaper. `bounded` is a scan that also applies `by_bound_filters`, kept
/// apart so a page with none of them does not test them on every row; it
/// binds the loved and genre filters rather than spelling them out, so it
/// adds one statement per relational filter, sort and direction.
/// `from_files` is `bounded` with `by_bound_filters_from_files`, for a page
/// with no relational filter, a play-file filter and a sort that reads
/// every row anyway; a sort that walks a Track index stays `bounded`, which
/// stops at the page instead of collecting every match first.
const PageForm = enum { scan, candidates, bounded, from_files };

const candidate_offset_max = 50_000;

/// For a whole-library page sorted by a value that lives outside `tracks`,
/// the ids that can reach it: the first `limit + offset` of each part of the
/// library the sort orders differently, each part walked from an index on
/// its own sort value. A part's order must equal `orderTerms` restricted to
/// that part, or rows are lost from the page.
fn candidateIds(comptime sort: TrackSort, comptime direction: SortDirection) ?[]const u8 {
    const suffix = comptime direction.suffix();
    const by_id = "tracks.id" ++ suffix;
    const no_stats = "tracks WHERE NOT EXISTS (SELECT 1 FROM recording_play_stats " ++
        "WHERE recording_play_stats.recording_id = tracks.recording_id)";
    const with_stats = "recording_play_stats CROSS JOIN tracks " ++
        "ON tracks.recording_id = recording_play_stats.recording_id";
    return switch (sort) {
        .id, .artist, .album, .title, .track_number, .duration, .album_artist => null,
        .play_count => candidatePart(with_stats, "recording_play_stats.play_count" ++ suffix ++ ", " ++ by_id) ++
            "UNION ALL\n" ++ candidatePart(no_stats, by_id),
        .last_played => candidatePart(with_stats, "recording_play_stats.last_played_at" ++ suffix ++ ", " ++ by_id) ++
            "UNION ALL\n" ++ candidatePart(no_stats, by_id),
        .rating => candidatePart(
            "ratings CROSS JOIN tracks ON tracks.recording_id = ratings.recording_id",
            "ratings.rating" ++ suffix ++ ", " ++ by_id,
        ) ++ "UNION ALL\n" ++ candidatePart(
            "tracks WHERE NOT EXISTS (SELECT 1 FROM ratings WHERE ratings.recording_id = tracks.recording_id)",
            by_id,
        ),
        .loved => candidatePart(
            "feedback CROSS JOIN tracks ON tracks.recording_id = feedback.recording_id WHERE feedback.score = 1",
            "feedback.updated_at" ++ comptime direction.reversed().suffix() ++ ", " ++ by_id,
        ) ++ "UNION ALL\n" ++ candidatePart(
            "tracks WHERE NOT EXISTS (SELECT 1 FROM feedback " ++
                "WHERE feedback.recording_id = tracks.recording_id AND feedback.score = 1)",
            by_id,
        ),
        .year => candidatePart(
            "releases AS track_release CROSS JOIN tracks ON tracks.release_id = track_release.id " ++
                "WHERE (" ++ release_year ++ ") IS NOT NULL",
            release_year ++ suffix ++ ", " ++ by_id,
        ) ++ "UNION ALL\n" ++ candidatePart(
            "releases AS track_release CROSS JOIN tracks ON tracks.release_id = track_release.id " ++
                "WHERE (" ++ release_year ++ ") IS NULL",
            by_id,
        ) ++ "UNION ALL\n" ++ candidatePart("tracks WHERE tracks.release_id IS NULL", by_id),
        .date_added => candidatePart(
            "files AS play_file CROSS JOIN tracks ON tracks.preferred_file_id = play_file.id",
            "play_file.first_seen_at" ++ suffix ++ ", " ++ by_id,
        ) ++ "UNION ALL\n" ++ withoutPreferredFile(sort, direction),
        .loudness => candidatePart(
            "file_loudness CROSS JOIN files AS play_file ON play_file.id = file_loudness.file_id " ++
                "AND play_file.content_hash = file_loudness.source_identity AND play_file.content_hash_algorithm = 1 " ++
                "AND " ++ measurableChannels("play_file") ++ "\n" ++
                "CROSS JOIN tracks ON tracks.preferred_file_id = play_file.id",
            "file_loudness.integrated_lufs" ++ suffix ++ ", " ++ by_id,
        ) ++ "UNION ALL\n" ++ withoutPreferredFile(sort, direction) ++ "UNION ALL\n" ++ candidatePart(
            "tracks WHERE tracks.preferred_file_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM files " ++
                "CROSS JOIN file_loudness ON file_loudness.file_id = files.id " ++
                "AND file_loudness.source_identity = files.content_hash AND files.content_hash_algorithm = 1 " ++
                "WHERE files.id = tracks.preferred_file_id AND " ++ measurableChannels("files") ++ ")",
            by_id,
        ),
        .bitrate => candidatePart(
            "files AS play_file CROSS JOIN tracks ON tracks.preferred_file_id = play_file.id\n" ++
                "WHERE play_file.size_bytes > 0 AND play_file.duration_ms > 0",
            indexed_bitrate ++ suffix ++ ", " ++ by_id,
        ) ++ "UNION ALL\n" ++ withoutPreferredFile(sort, direction) ++ "UNION ALL\n" ++ candidatePart(
            "files AS play_file CROSS JOIN tracks ON tracks.preferred_file_id = play_file.id\n" ++
                "WHERE (play_file.size_bytes > 0 AND play_file.duration_ms > 0) IS NOT 1",
            by_id,
        ),
        .path => candidatePart(
            "locations AS play_location CROSS JOIN tracks ON tracks.preferred_file_id = play_location.file_id\n" ++
                "WHERE play_location.id = " ++ bestLocation("id", "play_location.file_id"),
            "play_location.uri" ++ suffix ++ ", " ++ by_id,
        ) ++ "UNION ALL\n" ++ withoutPreferredFile(sort, direction) ++ "UNION ALL\n" ++ candidatePart(
            "files AS unlocated_file CROSS JOIN tracks ON tracks.preferred_file_id = unlocated_file.id\n" ++
                "WHERE NOT EXISTS (SELECT 1 FROM locations " ++
                "WHERE locations.file_id = unlocated_file.id AND locations.state <> 'missing')",
            by_id,
        ),
        .genre => candidatePart(
            "genres AS first_genre CROSS JOIN track_genres AS first_track_genre " ++
                "ON first_track_genre.genre_id = first_genre.id AND first_track_genre.ordinal = 0\n" ++
                "CROSS JOIN tracks ON tracks.id = first_track_genre.track_id",
            "first_genre.name COLLATE NOCASE" ++ suffix ++ ", first_genre.id" ++ suffix ++ ", " ++ by_id,
        ) ++ "UNION ALL\n" ++ candidatePart(
            "tracks WHERE NOT EXISTS (SELECT 1 FROM track_genres " ++
                "WHERE track_genres.track_id = tracks.id AND track_genres.ordinal = 0)",
            by_id,
        ),
    };
}

fn withoutPreferredFile(comptime sort: TrackSort, comptime direction: SortDirection) []const u8 {
    return candidatePart("tracks " ++ sortJoin(sort) ++ "WHERE tracks.preferred_file_id IS NULL", orderTerms(sort, direction));
}

fn candidatePart(comptime from: []const u8, comptime order: []const u8) []const u8 {
    return "SELECT page_id FROM (SELECT tracks.id AS page_id FROM " ++ from ++
        "\nORDER BY " ++ order ++ "\nLIMIT ?1 + ?2)\n";
}

/// The one join of `recording_joins` that a sort reads, so a page's ids are
/// chosen without joining every row of the library to all of them.
fn sortJoin(comptime sort: TrackSort) []const u8 {
    return switch (sort) {
        .id, .artist, .album, .title, .track_number, .duration, .album_artist, .genre => "",
        .date_added, .bitrate, .loudness, .path => play_file_join,
        .rating => "LEFT JOIN ratings ON ratings.recording_id = tracks.recording_id\n",
        .loved => "LEFT JOIN feedback ON feedback.recording_id = tracks.recording_id\n",
        .play_count, .last_played => "LEFT JOIN recording_play_stats ON recording_play_stats.recording_id = tracks.recording_id\n",
        .year => "LEFT JOIN releases AS track_release ON track_release.id = tracks.release_id\n",
    };
}

/// Every (filter, loved filter, genre filter, sort, direction, form)
/// combination as its own prepared-once statement text, the `bounded` form
/// once for every loved and genre filter and `from_files` once per sort and
/// direction. There are 734 distinct ones; concatenating SQL at runtime
/// instead would mean an allocation and a string the caller could influence,
/// and this boundary refuses both on principle.
fn trackQueryText(
    filter: TrackFilter,
    loved_only: bool,
    genre: bool,
    sort: TrackSort,
    direction: SortDirection,
    form: PageForm,
) [:0]const u8 {
    if (form == .from_files) return switch (sort) {
        inline else => |resolved_sort| switch (direction) {
            inline else => |resolved_direction| comptime buildTrackQuery(
                .none,
                false,
                false,
                resolved_sort,
                resolved_direction,
                .from_files,
            ),
        },
    };
    if (form == .bounded) return switch (filter) {
        inline else => |resolved_filter| switch (sort) {
            inline else => |resolved_sort| switch (direction) {
                inline else => |resolved_direction| comptime buildTrackQuery(
                    resolved_filter,
                    false,
                    false,
                    resolved_sort,
                    resolved_direction,
                    .bounded,
                ),
            },
        },
    };
    return switch (filter) {
        inline else => |resolved_filter| switch (loved_only) {
            inline else => |resolved_loved_only| switch (genre) {
                inline else => |resolved_genre| switch (sort) {
                    inline else => |resolved_sort| switch (direction) {
                        inline else => |resolved_direction| switch (form) {
                            .bounded, .from_files => unreachable,
                            inline .scan, .candidates => |resolved_form| comptime buildTrackQuery(
                                resolved_filter,
                                resolved_loved_only,
                                resolved_genre,
                                resolved_sort,
                                resolved_direction,
                                resolved_form,
                            ),
                        },
                    },
                },
            },
        },
    };
}

fn collectTrackPage(allocator: std.mem.Allocator, statement: sqlite.Statement) !TrackPage {
    var results: std.ArrayList(TrackSummary) = .empty;
    errdefer {
        for (results.items) |item| item.deinit(allocator);
        results.deinit(allocator);
    }
    while (try statement.step() == .row) {
        const summary = try readTrackSummary(allocator, statement);
        errdefer summary.deinit(allocator);
        try results.append(allocator, summary);
    }
    return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
}

/// One row of `track_columns`, copied out.
pub fn readTrackSummary(allocator: std.mem.Allocator, statement: sqlite.Statement) !TrackSummary {
    const title = try allocator.dupe(u8, statement.columnText(1));
    errdefer allocator.free(title);
    const artist = try allocator.dupe(u8, statement.columnText(2));
    errdefer allocator.free(artist);
    const album = try allocator.dupe(u8, statement.columnText(3));
    errdefer allocator.free(album);
    const album_artist = try allocator.dupe(u8, statement.columnText(4));
    errdefer allocator.free(album_artist);
    const codec = try allocator.dupe(u8, statement.columnText(14));
    errdefer allocator.free(codec);
    const path = try allocator.dupe(u8, statement.columnText(26));
    errdefer allocator.free(path);
    const genre = try allocator.dupe(u8, statement.columnText(28));
    errdefer allocator.free(genre);
    return .{
        .id = statement.columnInt64(0),
        .title = title,
        .artist = artist,
        .album = album,
        .album_artist = album_artist,
        .duration_ms = optionalInt64(statement, 5),
        .track_number = optionalInt64(statement, 6),
        .disc_number = optionalInt64(statement, 7),
        .has_playable_file = statement.columnInt64(8) != 0,
        .release_id = optionalInt64(statement, 9),
        .artist_id = optionalInt64(statement, 10),
        .feedback = Feedback.fromScore(statement.columnInt64(11)) orelse return error.InvalidStoredFeedback,
        .recording_id = optionalInt64(statement, 12),
        .rating = if (statement.columnIsNull(13))
            null
        else
            std.math.cast(u8, statement.columnInt64(13)) orelse return error.InvalidStoredRating,
        .codec = codec,
        .sample_rate = positiveU32(statement, 15),
        .bit_depth = positiveU32(statement, 16),
        .lossy = codec.len > 0 and !codec_id.isLossless(codec),
        .added_at = optionalInt64(statement, 17),
        .play_count = std.math.cast(u64, statement.columnInt64(18)) orelse return error.InvalidStoredPlayCount,
        .last_played_at = optionalInt64(statement, 19),
        .explicit = std.enums.fromInt(metadata.Explicit, statement.columnInt64(20)) orelse
            return error.InvalidStoredExplicit,
        .track_total = optionalInt64(statement, 21),
        .disc_total = optionalInt64(statement, 22),
        .year = if (statement.columnIsNull(23)) null else std.math.cast(i32, statement.columnInt64(23)),
        .integrated_lufs = if (statement.columnIsNull(24)) null else @floatCast(statement.columnDouble(24)),
        .bitrate_kbps = positiveU32(statement, 25),
        .path = path,
        .album_artist_id = optionalInt64(statement, 27),
        .genre = genre,
    };
}

fn positiveU32(statement: sqlite.Statement, column: c_int) ?u32 {
    const value = optionalInt64(statement, column) orelse return null;
    if (value <= 0) return null;
    return std.math.cast(u32, value);
}

/// The file a Track plays: its preferred file, else the first file of its
/// Recording, matching `TrackRepository.playableLocation`.
/// The files Track ?1 resolves to, at most ?2: its preferred file and every
/// other encoding of its recording.
pub const track_file_ids_sql =
    \\SELECT preferred_file_id FROM tracks WHERE id=?1 AND preferred_file_id IS NOT NULL
    \\UNION
    \\SELECT f.id FROM files f JOIN tracks t ON f.recording_id = t.recording_id
    \\WHERE t.id=?1
    \\LIMIT ?2;
;

pub const file_track_ids_sql =
    \\SELECT id FROM tracks WHERE preferred_file_id=?1
    \\UNION
    \\SELECT t.id FROM tracks t JOIN files f ON f.recording_id = t.recording_id
    \\WHERE f.id=?1
    \\LIMIT ?2;
;

pub const track_play_file =
    \\COALESCE(
    \\    tracks.preferred_file_id,
    \\    (SELECT id FROM files WHERE recording_id = tracks.recording_id ORDER BY id LIMIT 1))
;

/// A locked Orca value, else the file's tag, else an Orca value: the order
/// `TrackRepository.recordingMbid` applies through `metadata.resolveValue`.
/// The two must agree, or details and sync name different recordings.
pub fn effectiveRecordingMbid(comptime file_id: []const u8) []const u8 {
    return effectiveIdSql(.musicbrainz_recording_id, "musicbrainz_recording_id", file_id);
}

/// The file's release ID in effect, resolved in the order of
/// `effectiveRecordingMbid`, which is the projection's under `prefer_file`.
pub fn effectiveReleaseMbid(comptime file_id: []const u8) []const u8 {
    return effectiveIdSql(.musicbrainz_release_id, "musicbrainz_release_id", file_id);
}

fn effectiveIdSql(comptime field: metadata.Field, comptime tag_column: []const u8, comptime file_id: []const u8) []const u8 {
    const field_number = std.fmt.comptimePrint("{d}", .{@backingInt(field)});
    return "COALESCE(" ++
        "(SELECT NULLIF(value, '') FROM orca_metadata_values WHERE orca_metadata_values.file_id = " ++ file_id ++
        " AND orca_metadata_values.field = " ++ field_number ++ " AND orca_metadata_values.locked = 1), " ++
        "(SELECT NULLIF(" ++ tag_column ++ ", '') FROM observed_file_tags WHERE observed_file_tags.file_id = " ++ file_id ++ "), " ++
        "(SELECT NULLIF(value, '') FROM orca_metadata_values WHERE orca_metadata_values.file_id = " ++ file_id ++
        " AND orca_metadata_values.field = " ++ field_number ++ "))";
}

test "every page of a whole-library sort, in either form, and of a genre's sort holds the rows a single ORDER BY puts there" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-candidate-pages?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec(
        \\CREATE TEMP TABLE numbers AS
        \\    WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v + 1 FROM n WHERE v < 30) SELECT v FROM n;
        \\INSERT INTO recordings(id, title) SELECT v, 'Song' FROM numbers WHERE v <= 24;
        \\INSERT INTO releases(id, title, release_date) VALUES
        \\    (1, 'A', '1999-05-01'), (2, 'B', NULL), (3, 'C', '1999'), (4, 'D', 'unknown'), (5, 'E', '2003');
        \\INSERT INTO files(id, recording_id, first_seen_at)
        \\    SELECT v, v, 1700000000 + (v * 37) % 11 FROM numbers WHERE v <= 20;
        \\INSERT INTO tracks(id, recording_id, release_id, title, track_number, preferred_file_id)
        \\    SELECT v,
        \\        CASE WHEN v % 9 = 0 THEN NULL ELSE (v - 1) % 24 + 1 END,
        \\        CASE WHEN v % 6 = 0 THEN NULL ELSE v % 5 + 1 END,
        \\        'Song', v,
        \\        CASE WHEN v % 4 = 0 OR v > 20 THEN NULL ELSE v END
        \\    FROM numbers;
        \\INSERT INTO recording_play_stats(recording_id, play_count, last_played_at)
        \\    SELECT v, v % 3 + 1, 1700000000 + v % 4 FROM numbers WHERE v % 2 = 0 AND v <= 24;
        \\INSERT INTO ratings(recording_id, rating, updated_at)
        \\    SELECT v, (v % 4 + 1) * 20, 1700000000 FROM numbers WHERE v % 3 = 0 AND v <= 24;
        \\INSERT INTO feedback(recording_id, score, updated_at)
        \\    SELECT v, CASE WHEN v % 4 = 1 THEN 1 ELSE -1 END, 1700000000 + v % 3
        \\    FROM numbers WHERE v % 4 IN (1, 2) AND v <= 24;
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Rock', 'rock'), (2, 'Jazz', 'jazz');
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance)
        \\    SELECT v, 1, 0, 0 FROM numbers WHERE v % 3 <> 1;
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance)
        \\    SELECT v, 2, 1, 0 FROM numbers WHERE v % 5 = 0;
        \\INSERT INTO genres(id, name, key) VALUES (3, 'ROCK', 'rock-upper');
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance)
        \\    SELECT v, 3, 0, 0 FROM numbers WHERE v % 3 = 1 AND v % 2 = 0;
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES (7, 2, 0, 0);
        \\UPDATE tracks SET album_artist = CASE id % 4 WHEN 0 THEN 'b' WHEN 1 THEN 'A' WHEN 2 THEN '' ELSE 'a' END,
        \\    album = CASE id % 3 WHEN 0 THEN 'x' ELSE 'Y' END;
        \\UPDATE files SET size_bytes = (id * 7919) % 5 * 1000000,
        \\    duration_ms = CASE WHEN id % 7 = 0 THEN NULL ELSE 200000 + (id % 3) * 1000 END,
        \\    quick_hash = CAST(id AS BLOB), content_hash = CAST(id AS BLOB), content_hash_algorithm = 1,
        \\    channels = CASE WHEN id % 11 = 0 THEN NULL WHEN id % 7 = 3 THEN 6 ELSE id % 2 + 1 END;
        \\INSERT INTO file_loudness(file_id, source_identity, integrated_lufs)
        \\    SELECT id, content_hash, -((id * 13) % 6) - 0.5 FROM files WHERE id % 5 <> 0;
        \\INSERT INTO file_loudness(file_id, source_identity, integrated_lufs) VALUES (5, x'ff', -1.0);
        \\INSERT OR IGNORE INTO volumes(id, stable_key) VALUES (1, 'legacy');
        \\INSERT INTO locations(file_id, volume_id, uri, state)
        \\    SELECT id, 1, '/m/' || char(65 + (id * 7) % 5) || id,
        \\        CASE id % 6 WHEN 0 THEN 'missing' WHEN 1 THEN 'unverified' ELSE 'present' END
        \\    FROM files;
        \\INSERT INTO locations(file_id, volume_id, uri, state)
        \\    SELECT id, 1, '/a/' || id, 'present' FROM files WHERE id % 3 = 1;
    );

    const windows = [_][2]u32{ .{ 30, 0 }, .{ 5, 0 }, .{ 5, 7 }, .{ 4, 26 }, .{ 10, 25 } };
    inline for (.{ .play_count, .last_played, .rating, .loved, .year, .date_added, .loudness, .bitrate, .path, .album_artist, .genre }) |sort| {
        inline for (.{ .ascending, .descending }) |direction| {
            var expected = try library.database.prepare("SELECT tracks.id FROM tracks\n" ++
                recording_joins ++ "ORDER BY " ++
                comptime orderTerms(sort, direction) ++ "\nLIMIT ?1 OFFSET ?2;");
            defer expected.deinit();
            for (windows) |window| for ([_]PageForm{ .scan, .candidates }) |form| {
                var page = try library.tracks.pageAs(std.testing.allocator, .{
                    .sort = sort,
                    .direction = direction,
                    .limit = window[0],
                    .offset = window[1],
                }, .none, form);
                defer page.deinit();
                try expected.bindInt64(1, window[0]);
                try expected.bindInt64(2, window[1]);
                var count: usize = 0;
                while (try expected.step() == .row) : (count += 1) {
                    try std.testing.expect(count < page.items.len);
                    try std.testing.expectEqual(expected.columnInt64(0), page.items[count].id);
                }
                try std.testing.expectEqual(count, page.items.len);
                try expected.reset();
            };
            var expected_genre = try library.database.prepare("SELECT tracks.id FROM tracks\n" ++
                recording_joins ++ "WHERE " ++ by_genre ++ "\nORDER BY " ++
                comptime orderTerms(sort, direction) ++ "\nLIMIT ?1 OFFSET ?2;");
            defer expected_genre.deinit();
            for (windows) |window| {
                const query: TrackQuery = .{
                    .genre_id = 1,
                    .sort = sort,
                    .direction = direction,
                    .limit = window[0],
                    .offset = window[1],
                };
                var page = try library.tracks.page(std.testing.allocator, query);
                defer page.deinit();
                try expected_genre.bindInt64(1, window[0]);
                try expected_genre.bindInt64(2, window[1]);
                try expected_genre.bindInt64(6, 1);
                var count: usize = 0;
                while (try expected_genre.step() == .row) : (count += 1) {
                    try std.testing.expect(count < page.items.len);
                    try std.testing.expectEqual(expected_genre.columnInt64(0), page.items[count].id);
                }
                try std.testing.expectEqual(count, page.items.len);
                try expected_genre.reset();
                try std.testing.expectEqual(@as(u64, 20), try library.tracks.countMatching(query));
            }
        }
    }
}

test "a Track reads loudness, bitrate and path from the file it plays and its first genre, and sorts by them and album artist with unknowns last" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-track-file-sorts?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES (1, 'AA', 'AA', 'aa');
        \\INSERT INTO releases(id, title, album_artist_id) VALUES (1, 'X', 1);
        \\INSERT INTO recordings(id, title) VALUES (1, 'r'), (2, 'r'), (3, 'r'), (4, 'r');
        \\INSERT INTO files(id, recording_id, size_bytes, duration_ms, quick_hash, content_hash, content_hash_algorithm, channels) VALUES
        \\    (1, 1, 4012500, 200000, x'01', x'01', 1, 2), (2, 2, 0, 200000, x'02', x'02', 1, 2),
        \\    (4, 4, 1000000, 100000, x'04', x'04', 1, 2);
        \\INSERT INTO file_loudness(file_id, source_identity, integrated_lufs) VALUES
        \\    (1, x'01', -9.5), (2, x'ff', -3.0), (4, x'04', -20.0);
        \\INSERT OR IGNORE INTO volumes(id, stable_key) VALUES (1, 'legacy');
        \\INSERT INTO locations(file_id, volume_id, uri, state) VALUES
        \\    (1, 1, '/z/1', 'missing'), (1, 1, '/u/1', 'unverified'), (1, 1, '/p/1', 'present'),
        \\    (2, 1, '/z/2', 'missing'), (4, 1, '/a/4', 'present');
        \\INSERT INTO tracks(id, recording_id, release_id, title, album, album_artist, track_number, preferred_file_id) VALUES
        \\    (1, 1, 1, 't', 'Y', 'beta', 1, 1), (2, 2, NULL, 't', 'X', 'Alpha', 2, 2),
        \\    (3, 3, NULL, 't', '', '', 1, NULL), (4, 4, NULL, 't', 'x', 'alpha', 1, 4);
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Rock', 'rock'), (2, 'ambient', 'ambient');
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES
        \\    (1, 1, 0, 0), (1, 2, 1, 0), (2, 1, 0, 0), (4, 2, 0, 0);
    );

    const first = (try library.tracks.byId(std.testing.allocator, 1)).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?f32, -9.5), first.integrated_lufs);
    try std.testing.expectEqual(@as(?u32, 161), first.bitrate_kbps);
    try std.testing.expectEqualStrings("/p/1", first.path);
    try std.testing.expectEqual(@as(?i64, 1), first.album_artist_id);
    try std.testing.expectEqualStrings("Rock", first.genre);
    const second = (try library.tracks.byId(std.testing.allocator, 2)).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?f32, null), second.integrated_lufs);
    try std.testing.expectEqual(@as(?u32, null), second.bitrate_kbps);
    try std.testing.expectEqualStrings("", second.path);
    try std.testing.expectEqual(@as(?i64, null), second.album_artist_id);
    const third = (try library.tracks.byId(std.testing.allocator, 3)).?;
    defer third.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", third.genre);

    const Case = struct { sort: TrackSort, direction: SortDirection, ids: [4]i64 };
    const cases = [_]Case{
        .{ .sort = .loudness, .direction = .ascending, .ids = .{ 4, 1, 2, 3 } },
        .{ .sort = .loudness, .direction = .descending, .ids = .{ 1, 4, 3, 2 } },
        .{ .sort = .bitrate, .direction = .ascending, .ids = .{ 4, 1, 2, 3 } },
        .{ .sort = .bitrate, .direction = .descending, .ids = .{ 1, 4, 3, 2 } },
        .{ .sort = .path, .direction = .ascending, .ids = .{ 4, 1, 2, 3 } },
        .{ .sort = .path, .direction = .descending, .ids = .{ 1, 4, 3, 2 } },
        .{ .sort = .album_artist, .direction = .ascending, .ids = .{ 3, 4, 2, 1 } },
        .{ .sort = .album_artist, .direction = .descending, .ids = .{ 1, 2, 4, 3 } },
        .{ .sort = .genre, .direction = .ascending, .ids = .{ 4, 1, 2, 3 } },
        .{ .sort = .genre, .direction = .descending, .ids = .{ 2, 1, 4, 3 } },
    };
    for (cases) |case| for ([_]PageForm{ .scan, .candidates }) |form| {
        var page = try library.tracks.pageAs(std.testing.allocator, .{
            .sort = case.sort,
            .direction = case.direction,
            .limit = 10,
        }, .none, form);
        defer page.deinit();
        try std.testing.expectEqual(@as(usize, 4), page.items.len);
        for (case.ids, page.items) |id, item| try std.testing.expectEqual(id, item.id);
    };
}

test "paging by loudness lists a file with no channel count or more than two channels with the unmeasured, each Track once" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-track-loudness-channels?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'r'), (2, 'r'), (3, 'r'), (4, 'r'), (5, 'r'), (6, 'r'), (7, 'r'), (8, 'r');
        \\INSERT INTO files(id, recording_id, content_hash, content_hash_algorithm, channels) VALUES
        \\    (1, 1, x'01', 1, 2), (2, 2, x'02', 1, 2), (3, 3, x'03', 1, 2), (4, 4, x'04', 1, 1),
        \\    (5, 5, x'05', 1, NULL), (6, 6, x'06', 1, 6), (7, 7, x'07', 1, 2);
        \\INSERT INTO file_loudness(file_id, source_identity, integrated_lufs) VALUES
        \\    (1, x'01', -10.0), (2, x'02', -5.0), (3, x'03', -20.0), (4, x'04', -15.0),
        \\    (5, x'05', -1.0), (6, x'06', -30.0);
        \\INSERT INTO tracks(id, recording_id, title, preferred_file_id) VALUES
        \\    (1, 1, 't', 1), (2, 2, 't', 2), (3, 3, 't', 3), (4, 4, 't', 4),
        \\    (5, 5, 't', 5), (6, 6, 't', 6), (7, 7, 't', 7), (8, 8, 't', NULL);
    );

    const Case = struct { direction: SortDirection, ids: [8]i64 };
    for ([_]Case{
        .{ .direction = .ascending, .ids = .{ 3, 4, 1, 2, 5, 6, 7, 8 } },
        .{ .direction = .descending, .ids = .{ 2, 1, 4, 3, 8, 7, 6, 5 } },
    }) |case| for ([_]PageForm{ .scan, .candidates, .bounded }) |form| {
        var listed: [8]i64 = undefined;
        var count: usize = 0;
        var offset: u32 = 0;
        while (true) : (offset += 3) {
            var page = try library.tracks.pageAs(std.testing.allocator, .{
                .sort = .loudness,
                .direction = case.direction,
                .limit = 3,
                .offset = offset,
            }, .none, form);
            defer page.deinit();
            if (page.items.len == 0) break;
            for (page.items) |item| {
                try std.testing.expect(count < listed.len);
                listed[count] = item.id;
                count += 1;
                try std.testing.expectEqual(item.id <= 4, item.integrated_lufs != null);
            }
        }
        try std.testing.expectEqualSlices(i64, &case.ids, listed[0..count]);
    };
}

test "a whole-library page by loudness, bitrate, path, album artist or first genre walks that sort's index" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-track-sort-plans?mode=memory&cache=shared",
    );
    defer library.close();
    inline for (.{
        .{ TrackSort.loudness, PageForm.candidates, "SCAN file_loudness USING INDEX file_loudness_by_lufs\n" },
        .{ TrackSort.bitrate, PageForm.candidates, "SCAN play_file USING INDEX files_by_bitrate\n" },
        .{ TrackSort.bitrate, PageForm.candidates, "SCAN play_file USING INDEX files_without_bitrate\n" },
        .{ TrackSort.path, PageForm.candidates, "SCAN play_location USING INDEX locations_by_uri\n" },
        .{ TrackSort.album_artist, PageForm.scan, "SCAN tracks USING INDEX tracks_sort_album_artist\n" },
        .{ TrackSort.genre, PageForm.candidates, "SCAN first_genre USING COVERING INDEX genres_by_name\n" },
    }) |case| inline for (.{ SortDirection.ascending, SortDirection.descending }) |direction| {
        var statement = try library.database.prepare("EXPLAIN QUERY PLAN " ++
            comptime trackQueryText(.none, false, false, case[0], direction, case[1]));
        defer statement.deinit();
        var plan: std.ArrayList(u8) = .empty;
        defer plan.deinit(std.testing.allocator);
        while (try statement.step() == .row) {
            try plan.appendSlice(std.testing.allocator, statement.columnText(3));
            try plan.append(std.testing.allocator, '\n');
        }
        try std.testing.expect(std.mem.indexOf(u8, plan.items, case[2]) != null);
    };
}

test "a whole-library page by path tests each file's locations from the index of those not missing" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-track-path-plan?mode=memory&cache=shared",
    );
    defer library.close();
    inline for (.{ SortDirection.ascending, SortDirection.descending }) |direction| {
        const plan = try explainPlan(&library, comptime trackQueryText(.none, false, false, .path, direction, .candidates));
        defer std.testing.allocator.free(plan);
        try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN unlocated_file") != null);
        try std.testing.expect(std.mem.indexOf(u8, plan, "SEARCH locations USING COVERING INDEX locations_held (file_id=?)\n") != null);
    }
}

test "an unnarrowed listing filtered by its files collects the matching files once, and a narrowed one does not" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-track-file-filter-plan?mode=memory&cache=shared",
    );
    defer library.close();
    try std.testing.expectEqual(BoundForm.from_files, boundForm(.{ .codec = "flac" }));
    try std.testing.expectEqual(BoundForm.from_files, boundForm(.{ .added_after = 1, .year_min = 1990 }));
    try std.testing.expectEqual(BoundForm.per_track, boundForm(.{ .codec = "flac", .artist_id = 1 }));
    try std.testing.expectEqual(BoundForm.per_track, boundForm(.{ .min_sample_rate = 1, .genre_id = 1 }));
    try std.testing.expectEqual(BoundForm.per_track, boundForm(.{ .year_min = 1990 }));
    try std.testing.expectEqual(PageForm.from_files, pageForm(.{ .codec = "flac", .sort = .date_added }, .none));
    try std.testing.expectEqual(PageForm.bounded, pageForm(.{ .codec = "flac", .sort = .title }, .none));
    try std.testing.expectEqual(PageForm.bounded, pageForm(.{ .codec = "flac", .sort = .date_added, .loved_only = true }, .none));
    const statements = .{
        "SELECT count(*) FROM tracks\nWHERE " ++ comptime filterText(.from_files) ++ ";",
        comptime trackQueryText(.none, false, false, .date_added, .descending, .from_files),
    };
    inline for (statements) |sql| {
        const plan = try explainPlan(&library, sql);
        defer std.testing.allocator.free(plan);
        try std.testing.expect(std.mem.indexOf(u8, plan, "LIST SUBQUERY") != null);
        try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN bound_file\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, plan, "SEARCH tracks USING COVERING INDEX tracks_by_preferred_file (preferred_file_id=?)\n") != null);
    }
}

fn explainPlan(library: anytype, comptime sql: []const u8) ![]u8 {
    var statement = try library.database.prepare("EXPLAIN QUERY PLAN " ++ sql);
    defer statement.deinit();
    var plan: std.ArrayList(u8) = .empty;
    errdefer plan.deinit(std.testing.allocator);
    while (try statement.step() == .row) {
        try plan.appendSlice(std.testing.allocator, statement.columnText(3));
        try plan.append(std.testing.allocator, '\n');
    }
    return plan.toOwnedSlice(std.testing.allocator);
}

test "a genre's Track count is the general filter's, alone, beside other filters and after a Track goes" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-genre-count?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES (1, 'A', 'A', 'a'), (2, 'B', 'B', 'b');
        \\INSERT INTO recordings(id, title) VALUES (1, 'One'), (2, 'Two'), (3, 'Three'), (4, 'Four'), (5, 'Five');
        \\INSERT INTO releases(id, title, album_artist_id) VALUES (1, 'First', NULL), (2, 'Second', 1);
        \\INSERT INTO tracks(id, recording_id, release_id, artist_id, title, track_number) VALUES
        \\    (1, 1, 1, 1, 'One', 1), (2, 2, 1, 2, 'Two', 2), (3, 3, 2, 2, 'Three', 1),
        \\    (4, 4, 2, 2, 'Four', 2), (5, 5, NULL, 2, 'Five', NULL);
        \\INSERT INTO feedback(recording_id, score, updated_at) VALUES (1, 1, 1), (4, 1, 1), (5, -1, 1);
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Rock', 'rock'), (2, 'Jazz', 'jazz'), (3, 'Folk', 'folk');
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES
        \\    (1, 1, 0, 0), (1, 2, 1, 0), (2, 1, 0, 1), (3, 2, 0, 0), (4, 1, 0, 0), (5, 1, 0, 0), (5, 2, 1, 0);
    );
    var general = try library.database.prepare(
        "SELECT count(*) FROM tracks\n" ++
            "WHERE (?3 IS NULL OR " ++ by_artist ++ ")\n" ++
            "  AND (?5 = 0 OR " ++ by_loved_recording ++ ")\n" ++
            "  AND " ++ by_genre ++ ";",
    );
    defer general.deinit();
    const queries = [_]TrackQuery{
        .{ .genre_id = 1 },
        .{ .genre_id = 2 },
        .{ .genre_id = 3 },
        .{ .genre_id = 99 },
        .{ .genre_id = 1, .artist_id = 1 },
        .{ .genre_id = 2, .artist_id = 1 },
        .{ .genre_id = 1, .loved_only = true },
    };
    const before = [_]u64{ 4, 3, 0, 0, 2, 2, 2 };
    const after = [_]u64{ 3, 3, 0, 0, 1, 2, 1 };
    for ([_][]const u64{ &before, &after }, 0..) |expected, round| {
        if (round == 1) try library.database.exec("DELETE FROM tracks WHERE id = 4;");
        for (queries, expected) |query, count| {
            try general.bindOptionalInt64(3, query.artist_id);
            try general.bindInt64(5, @intFromBool(query.loved_only));
            try general.bindInt64(6, query.genre_id.?);
            if (try general.step() != .row) return error.SqlFailed;
            try std.testing.expectEqual(count, @as(u64, @intCast(general.columnInt64(0))));
            try general.reset();
            try std.testing.expectEqual(count, try library.tracks.countMatching(query));
        }
    }
}
test "each Track filter keeps only its Tracks, alone, combined, counted, totalled and in a search" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-track-filters?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec(
        \\INSERT INTO recordings(id, title) VALUES
        \\    (1, 'r'), (2, 'r'), (3, 'r'), (4, 'r'), (5, 'r'), (6, 'r'), (7, 'r'), (8, 'r');
        \\INSERT INTO releases(id, title, release_date) VALUES
        \\    (1, 'Bryter Layter', '1971-03-05'), (2, 'Later', '1999'), (3, 'Undated', NULL), (4, 'Odd', 'unknown');
        \\INSERT INTO files(id, recording_id, codec, sample_rate) VALUES
        \\    (1, 1, 'flac', 44100), (2, 2, 'flac', 96000), (3, 3, 'mp3', 44100), (4, 4, 'opus', 48000),
        \\    (5, 5, '', NULL), (6, 6, 'alac', 192000), (8, 8, 'aac', 48000);
        \\INSERT INTO tracks(id, recording_id, release_id, title, explicit, preferred_file_id) VALUES
        \\    (1, 1, 1, 'Northern Sky', 2, 1), (2, 2, 1, 'Hazey Jane', 0, 2), (3, 3, 2, 'Northern Lights', 2, 3),
        \\    (4, 4, 2, 'Fly', 3, 4), (5, 5, 3, 'Northern Wind', 0, 5), (6, 6, 4, 'Poor Boy', 1, 6),
        \\    (7, 7, NULL, 'Northern Star', 2, NULL), (8, 8, 2, 'At the Chime', 0, NULL);
        \\INSERT INTO feedback(recording_id, score, updated_at) VALUES (1, 1, 1), (3, 1, 1), (6, -1, 1);
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Folk', 'folk');
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES (1, 1, 0, 0), (3, 1, 0, 0), (4, 1, 0, 0);
        \\UPDATE files SET first_seen_at = id * 100;
        \\UPDATE tracks SET duration_ms = id * 1000;
    );
    const Case = struct { query: TrackQuery, ids: []const i64 };
    const cases = [_]Case{
        .{ .query = .{}, .ids = &.{ 1, 2, 3, 4, 5, 6, 7, 8 } },
        .{ .query = .{ .year_min = 1990 }, .ids = &.{ 3, 4, 8 } },
        .{ .query = .{ .year_max = 1990 }, .ids = &.{ 1, 2 } },
        .{ .query = .{ .year_min = 1971, .year_max = 1971 }, .ids = &.{ 1, 2 } },
        .{ .query = .{ .lossless = true }, .ids = &.{ 1, 2, 6 } },
        .{ .query = .{ .lossless = false }, .ids = &.{ 3, 4, 8 } },
        .{ .query = .{ .min_sample_rate = 48000 }, .ids = &.{ 2, 4, 6, 8 } },
        .{ .query = .{ .explicit_only = true }, .ids = &.{ 1, 3, 7 } },
        .{ .query = .{ .lossless = true, .min_sample_rate = 96000 }, .ids = &.{ 2, 6 } },
        .{ .query = .{ .explicit_only = true, .year_min = 1990 }, .ids = &.{3} },
        .{ .query = .{ .loved_only = true, .lossless = true }, .ids = &.{1} },
        .{ .query = .{ .release_id = 2, .lossless = false, .min_sample_rate = 48000 }, .ids = &.{ 4, 8 } },
        .{ .query = .{ .genre_id = 1, .lossless = false }, .ids = &.{ 3, 4 } },
        .{ .query = .{ .genre_id = 1, .loved_only = true, .explicit_only = true }, .ids = &.{ 1, 3 } },
        .{ .query = .{ .codec = "FLAC" }, .ids = &.{ 1, 2 } },
        .{ .query = .{ .codec = "aac" }, .ids = &.{8} },
        .{ .query = .{ .codec = "wav" }, .ids = &.{} },
        .{ .query = .{ .max_sample_rate = 48000 }, .ids = &.{ 1, 3, 4, 8 } },
        .{ .query = .{ .min_sample_rate = 48000, .max_sample_rate = 96000 }, .ids = &.{ 2, 4, 8 } },
        .{ .query = .{ .added_after = 400 }, .ids = &.{ 5, 6, 8 } },
        .{ .query = .{ .added_after = 400, .codec = "alac" }, .ids = &.{6} },
        .{ .query = .{ .added_after = 100, .codec = "flac", .release_id = 1 }, .ids = &.{2} },
        .{ .query = .{ .added_after = 300, .genre_id = 1 }, .ids = &.{4} },
    };
    for (cases) |case| {
        for (std.enums.values(TrackSort)) |sort| for ([_]SortDirection{ .ascending, .descending }) |direction| {
            var query = case.query;
            query.sort = sort;
            query.direction = direction;
            var page = try library.tracks.page(std.testing.allocator, query);
            defer page.deinit();
            var ids: [8]i64 = undefined;
            for (page.items, 0..) |item, index| ids[index] = item.id;
            std.mem.sort(i64, ids[0..page.items.len], {}, std.sort.asc(i64));
            try std.testing.expectEqualSlices(i64, case.ids, ids[0..page.items.len]);
            try std.testing.expectEqual(@as(u64, case.ids.len), try library.tracks.countMatching(query));
            var duration_ms: u64 = 0;
            for (case.ids) |id| duration_ms += @intCast(id * 1000);
            try std.testing.expectEqual(
                TrackTotals{ .count = case.ids.len, .duration_ms = duration_ms },
                try library.tracks.totals(query),
            );
        };
    }
    const searches = [_]Case{
        .{ .query = .{}, .ids = &.{ 1, 3, 5, 7 } },
        .{ .query = .{ .explicit_only = true }, .ids = &.{ 1, 3, 7 } },
        .{ .query = .{ .lossless = true }, .ids = &.{1} },
        .{ .query = .{ .year_max = 1990 }, .ids = &.{1} },
        .{ .query = .{ .loved_only = true, .lossless = false }, .ids = &.{3} },
        .{ .query = .{ .min_sample_rate = 1 }, .ids = &.{ 1, 3 } },
        .{ .query = .{ .genre_id = 1, .year_min = 1990 }, .ids = &.{3} },
        .{ .query = .{ .codec = "Flac" }, .ids = &.{1} },
        .{ .query = .{ .added_after = 200 }, .ids = &.{ 3, 5 } },
        .{ .query = .{ .max_sample_rate = 44100 }, .ids = &.{ 1, 3 } },
    };
    for (searches) |case| {
        var page = try library.tracks.search(std.testing.allocator, "Northern", case.query);
        defer page.deinit();
        var ids: [8]i64 = undefined;
        for (page.items, 0..) |item, index| ids[index] = item.id;
        std.mem.sort(i64, ids[0..page.items.len], {}, std.sort.asc(i64));
        try std.testing.expectEqualSlices(i64, case.ids, ids[0..page.items.len]);
        var duration_ms: u64 = 0;
        for (case.ids) |id| duration_ms += @intCast(id * 1000);
        try std.testing.expectEqual(
            TrackTotals{ .count = case.ids.len, .duration_ms = duration_ms },
            try library.tracks.searchTotals("Northern", case.query),
        );
    }
    try std.testing.expectEqual(TrackTotals{ .count = 0, .duration_ms = 0 }, try library.tracks.searchTotals("\"", .{}));
}

test "a listing's playable ids are its rows with a playable file, in its order, past one page and in a search" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-track-playable-ids?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec(
        \\CREATE TEMP TABLE numbers AS
        \\    WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v + 1 FROM n WHERE v < 1200) SELECT v FROM n;
        \\INSERT INTO recordings(id, title) SELECT v, 'r' FROM numbers;
        \\INSERT INTO files(id, recording_id, first_seen_at) SELECT v, v, v % 50 FROM numbers;
        \\INSERT INTO tracks(id, recording_id, title, preferred_file_id)
        \\    SELECT v, v, CASE WHEN v % 2 = 0 THEN 'Even ' ELSE 'Odd ' END || v, v FROM numbers;
        \\INSERT OR IGNORE INTO volumes(id, stable_key) VALUES (1, 'legacy');
        \\INSERT INTO locations(file_id, volume_id, uri, state)
        \\    SELECT v, 1, '/m/' || v, CASE WHEN v % 3 = 0 THEN 'missing' ELSE 'present' END FROM numbers;
    );
    const windows = [_][2]u32{ .{ 1200, 0 }, .{ 700, 300 }, .{ 10, 1195 } };
    for ([_]TrackSort{ .title, .date_added }) |sort| for (windows) |window| {
        const query: TrackQuery = .{ .sort = sort, .direction = .descending, .limit = window[0], .offset = window[1] };
        const ids = try library.tracks.playableIds(std.testing.allocator, "", query);
        defer std.testing.allocator.free(ids);
        var expected: std.ArrayList(i64) = .empty;
        defer expected.deinit(std.testing.allocator);
        var offset = window[1];
        while (offset < window[0] + window[1]) : (offset += max_page) {
            var paged = query;
            paged.offset = offset;
            paged.limit = @min(max_page, window[0] + window[1] - offset);
            var page = try library.tracks.page(std.testing.allocator, paged);
            defer page.deinit();
            for (page.items) |item| if (item.has_playable_file) try expected.append(std.testing.allocator, item.id);
        }
        try std.testing.expectEqualSlices(i64, expected.items, ids);
    };
    const query: TrackQuery = .{ .limit = 1000, .offset = 50 };
    const ids = try library.tracks.playableIds(std.testing.allocator, "even", query);
    defer std.testing.allocator.free(ids);
    var expected: std.ArrayList(i64) = .empty;
    defer expected.deinit(std.testing.allocator);
    var offset: u32 = 50;
    while (offset < 1050) : (offset += max_page) {
        var page = try library.tracks.search(std.testing.allocator, "even", .{ .limit = @min(max_page, 1050 - offset), .offset = offset });
        defer page.deinit();
        for (page.items) |item| if (item.has_playable_file) try expected.append(std.testing.allocator, item.id);
    }
    try std.testing.expectEqual(@as(usize, 366), expected.items.len);
    try std.testing.expectEqualSlices(i64, expected.items, ids);
    try std.testing.expectError(error.PageOutOfRange, library.tracks.playableIds(std.testing.allocator, "", .{ .limit = max_id_window + 1 }));
}

test "quotes and FTS5 operators in Track search text are matched as text, never as query syntax" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-track-search-text?mode=memory&cache=shared",
    );
    defer library.close();
    try library.tracks.upsertTracks(&.{
        .{ .title = "Northern Sky", .album = "Bryter Layter", .album_artist = "Nick Drake" },
        .{ .title = "Amber Light", .album = "Hours", .album_artist = "Quiet" },
    });
    const cases = [_]struct { text: []const u8, titles: []const []const u8 }{
        .{ .text = "Northern", .titles = &.{"Northern Sky"} },
        .{ .text = "\"NEAR\" OR (am* -x) ^title: {a b}", .titles = &.{} },
        .{ .text = "\"", .titles = &.{} },
        .{ .text = "-", .titles = &.{} },
        .{ .text = "am\"", .titles = &.{"Amber Light"} },
        .{ .text = "title:northern", .titles = &.{} },
    };
    for (cases) |case| {
        var page = try library.tracks.search(std.testing.allocator, case.text, .{ .limit = 8 });
        defer page.deinit();
        try std.testing.expectEqual(case.titles.len, page.items.len);
        for (case.titles, page.items) |title, item| try std.testing.expectEqualStrings(title, item.title);
    }
    const too_long: [search_text.max_search_text + 1]u8 = @splat('a');
    try std.testing.expectError(error.SearchTextTooLong, library.tracks.search(std.testing.allocator, &too_long, .{ .limit = 8 }));
}

test "seating Tracks by id lets them trade positions and keep their ids, and refuses an id with no row" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-track-seat?mode=memory&cache=shared",
    );
    defer library.close();
    const release_id = try library.releases.upsert(.{ .release_key = "seat", .title = "Seat" });
    try library.tracks.upsertTracks(&.{
        .{ .title = "One", .release_id = release_id, .track_number = 1 },
        .{ .title = "Two", .release_id = release_id, .track_number = 2 },
    });
    var by_number = try library.database.prepare("SELECT id FROM tracks ORDER BY track_number;");
    defer by_number.deinit();
    var ids: [2]i64 = undefined;
    for (&ids) |*id| {
        try std.testing.expectEqual(sqlite.Step.row, try by_number.step());
        id.* = by_number.columnInt64(0);
    }
    try by_number.reset();

    var seats = [_]TrackSeat{
        .{ .id = ids[0], .track = .{ .title = "One", .release_id = release_id, .track_number = 2 } },
        .{ .id = ids[1], .track = .{ .title = "Two", .release_id = release_id, .track_number = 1 } },
        .{ .track = .{ .title = "Three", .release_id = release_id, .track_number = 3 } },
    };
    library.write_lane.acquire();
    defer library.write_lane.release();
    try library.database.exec("BEGIN IMMEDIATE;");
    errdefer library.database.exec("ROLLBACK;") catch {};
    try library.tracks.seatTracksLocked(&seats);
    var missing = [_]TrackSeat{.{ .id = seats[2].id.? + 1, .track = .{ .title = "Gone", .release_id = release_id } }};
    try std.testing.expectError(error.TrackNotFound, library.tracks.seatTracksLocked(&missing));
    try library.database.exec("COMMIT;");

    var number_of = try library.database.prepare("SELECT track_number FROM tracks WHERE id = ?1;");
    defer number_of.deinit();
    for ([_]i64{ ids[0], ids[1], seats[2].id.? }, [_]i64{ 2, 1, 3 }) |id, number| {
        try number_of.bindInt64(1, id);
        try std.testing.expectEqual(sqlite.Step.row, try number_of.step());
        try std.testing.expectEqual(number, number_of.columnInt64(0));
        try number_of.reset();
    }
    var count = try library.database.prepare("SELECT count(*) FROM tracks;");
    defer count.deinit();
    try std.testing.expectEqual(sqlite.Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 3), count.columnInt64(0));
}
