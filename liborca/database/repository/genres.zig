const std = @import("std");
const sqlite = @import("../sqlite.zig");
const columns = @import("../columns.zig");
const metadata = @import("../../metadata/model.zig");
const genre_alias = @import("../../metadata/genre_alias.zig");

const max_page = columns.max_page;
const by_artist = @import("tracks.zig").by_artist;
const has_cover = @import("releases.zig").has_cover;
const WriteLane = @import("write_lane.zig").WriteLane;

/// The most genres one edit gives a Track.
pub const max_track_genres = 16;

/// A Genre as a browse listing shows one. Every count is over the Tracks that
/// carry the genre now.
pub const GenreSummary = struct {
    id: i64,
    name: []u8,
    track_count: u32,
    release_count: u32,
    /// Track artists and the album artists of those Tracks' Releases, as
    /// `ArtistQuery.genre_id` lists them.
    artist_count: u32,
    /// Summed over the Tracks that declare a duration.
    total_duration_ms: i64,

    pub fn deinit(self: GenreSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const GenrePage = struct {
    allocator: std.mem.Allocator,
    items: []GenreSummary,

    pub fn deinit(self: GenrePage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

/// The orders a Genre listing comes in. Each ends in `genres.id`.
pub const GenreSort = enum {
    name,
    /// Most Tracks first.
    track_count,

    fn terms(comptime self: GenreSort) []const u8 {
        return switch (self) {
            .name => "name COLLATE NOCASE, id",
            .track_count => "track_count DESC, name COLLATE NOCASE, id",
        };
    }
};

pub const GenreQuery = struct {
    /// Free text, folded the way `genres.key` is but without the alias table,
    /// so `hip hop` finds `Hip-Hop` and `Alternative Hip Hop`.
    filter: []const u8 = "",
    sort: GenreSort = .name,
    limit: u32 = max_page,
    offset: u32 = 0,
};

/// One genre of a Track, and where it came from.
pub const GenreName = struct {
    id: i64,
    name: []u8,
    provenance: metadata.Provenance,
};

pub const GenreNames = struct {
    allocator: std.mem.Allocator,
    items: []GenreName,

    pub fn deinit(self: GenreNames) void {
        for (self.items) |item| self.allocator.free(item.name);
        self.allocator.free(self.items);
    }
};

/// A genre and how many of a Release's or an Artist's Tracks carry it.
pub const GenreCount = struct {
    id: i64,
    name: []u8,
    track_count: u32,
};

pub const GenreCounts = struct {
    allocator: std.mem.Allocator,
    items: []GenreCount,

    pub fn deinit(self: GenreCounts) void {
        for (self.items) |item| self.allocator.free(item.name);
        self.allocator.free(self.items);
    }
};

pub const ReleaseIds = struct {
    allocator: std.mem.Allocator,
    ids: []i64,

    pub fn deinit(self: ReleaseIds) void {
        self.allocator.free(self.ids);
    }
};

/// The Artists owning a Track of the genre bound at `parameter`, under
/// `by_artist`'s definition of owning: credited, or album artist of its
/// Release.
pub fn artistsOfGenre(comptime parameter: []const u8) []const u8 {
    return "artists.id IN (" ++ genreArtistIds(parameter) ++ ")";
}

fn genreArtistIds(comptime parameter: []const u8) []const u8 {
    return "SELECT tracks.artist_id FROM track_genres " ++
        "CROSS JOIN tracks ON tracks.id = track_genres.track_id " ++
        "WHERE track_genres.genre_id = " ++ parameter ++ " AND tracks.artist_id IS NOT NULL " ++
        "UNION SELECT releases.album_artist_id FROM track_genres " ++
        "CROSS JOIN tracks ON tracks.id = track_genres.track_id " ++
        "CROSS JOIN releases ON releases.id = tracks.release_id " ++
        "WHERE track_genres.genre_id = " ++ parameter ++ " AND releases.album_artist_id IS NOT NULL";
}

fn genreSummaryText(comptime clauses: []const u8) [:0]const u8 {
    return "SELECT genres.id, genres.name, genre_totals.track_count, genre_totals.release_count,\n" ++
        "       genre_totals.artist_count, genre_totals.duration_ms\n" ++
        "FROM genre_totals CROSS JOIN genres ON genres.id = genre_totals.genre_id\n" ++
        clauses ++ ";";
}

fn genreQueryText(comptime sort: GenreSort, comptime filtered: bool) [:0]const u8 {
    const filter = if (filtered) "WHERE instr(genres.key, ?3) > 0 " else "";
    return genreSummaryText(filter ++ "ORDER BY " ++ comptime sort.terms() ++ " LIMIT ?1 OFFSET ?2");
}

fn collectGenrePage(allocator: std.mem.Allocator, statement: sqlite.Statement) !GenrePage {
    var results: std.ArrayList(GenreSummary) = .empty;
    errdefer {
        for (results.items) |item| item.deinit(allocator);
        results.deinit(allocator);
    }
    while (try statement.step() == .row) {
        const name = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(name);
        try results.append(allocator, .{
            .id = statement.columnInt64(0),
            .name = name,
            .track_count = @intCast(statement.columnInt64(2)),
            .release_count = @intCast(statement.columnInt64(3)),
            .artist_count = @intCast(statement.columnInt64(4)),
            .total_duration_ms = statement.columnInt64(5),
        });
    }
    return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
}

fn collectCounts(allocator: std.mem.Allocator, statement: sqlite.Statement) !GenreCounts {
    var results: std.ArrayList(GenreCount) = .empty;
    errdefer {
        for (results.items) |item| allocator.free(item.name);
        results.deinit(allocator);
    }
    while (try statement.step() == .row) {
        const name = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(name);
        try results.append(allocator, .{
            .id = statement.columnInt64(0),
            .name = name,
            .track_count = @intCast(statement.columnInt64(2)),
        });
    }
    return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
}

const count_order = "ORDER BY count(*) DESC, genres.name COLLATE NOCASE, genres.id\nLIMIT ?1;";

/// Genres as the projection and edits resolve them: one row per folded key,
/// attached to Tracks through `track_genres`.
pub const GenreRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn page(self: *const GenreRepository, allocator: std.mem.Allocator, query: GenreQuery) !GenrePage {
        if (query.limit == 0 or query.limit > max_page) return error.PageOutOfRange;
        const needle = try genre_alias.searchKey(allocator, query.filter);
        defer allocator.free(needle);
        var statement = switch (query.sort) {
            inline else => |sort| if (needle.len == 0)
                try self.db.prepare(comptime genreQueryText(sort, false))
            else
                try self.db.prepare(comptime genreQueryText(sort, true)),
        };
        defer statement.deinit();
        try statement.bindInt64(1, query.limit);
        try statement.bindInt64(2, query.offset);
        if (needle.len != 0) try statement.bindText(3, needle);
        return collectGenrePage(allocator, statement);
    }

    /// Counts what `page` would return for the same filter.
    pub fn count(self: *const GenreRepository, allocator: std.mem.Allocator, filter: []const u8) !u64 {
        const needle = try genre_alias.searchKey(allocator, filter);
        defer allocator.free(needle);
        var statement = try self.db.prepare(
            \\SELECT count(*) FROM genre_totals CROSS JOIN genres ON genres.id = genre_totals.genre_id
            \\WHERE ?1 = '' OR instr(genres.key, ?1) > 0;
        );
        defer statement.deinit();
        try statement.bindText(1, needle);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn byId(self: *const GenreRepository, allocator: std.mem.Allocator, genre_id: i64) !?GenreSummary {
        var statement = try self.db.prepare(comptime genreSummaryText("WHERE genre_totals.genre_id = ?1"));
        defer statement.deinit();
        try statement.bindInt64(1, genre_id);
        var found = try collectGenrePage(allocator, statement);
        if (found.items.len == 0) {
            found.deinit();
            return null;
        }
        const first = found.items[0];
        for (found.items[1..]) |extra| extra.deinit(allocator);
        allocator.free(found.items);
        return first;
    }

    /// A Track's genres in the order its source gave them.
    pub fn forTrack(self: *const GenreRepository, allocator: std.mem.Allocator, track_id: i64) !GenreNames {
        var statement = try self.db.prepare(
            \\SELECT genres.id, genres.name, track_genres.provenance
            \\FROM track_genres JOIN genres ON genres.id = track_genres.genre_id
            \\WHERE track_genres.track_id = ?1
            \\ORDER BY track_genres.ordinal
            \\LIMIT ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        try statement.bindInt64(2, max_page);
        var results: std.ArrayList(GenreName) = .empty;
        errdefer {
            for (results.items) |item| allocator.free(item.name);
            results.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const name = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(name);
            try results.append(allocator, .{
                .id = statement.columnInt64(0),
                .name = name,
                .provenance = std.enums.fromInt(metadata.Provenance, statement.columnInt64(2)) orelse
                    return error.InvalidStoredProvenance,
            });
        }
        return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
    }

    /// A Release's genres, most of its Tracks first.
    pub fn forRelease(self: *const GenreRepository, allocator: std.mem.Allocator, release_id: i64, limit: u32) !GenreCounts {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(
            "SELECT genres.id, genres.name, count(*)\n" ++
                "FROM tracks CROSS JOIN track_genres ON track_genres.track_id = tracks.id\n" ++
                "JOIN genres ON genres.id = track_genres.genre_id\n" ++
                "WHERE tracks.release_id = ?2\nGROUP BY genres.id\n" ++ count_order,
        );
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        try statement.bindInt64(2, release_id);
        return collectCounts(allocator, statement);
    }

    /// An Artist's genres over the Tracks `by_artist` gives them, most first.
    pub fn forArtist(self: *const GenreRepository, allocator: std.mem.Allocator, artist_id: i64, limit: u32) !GenreCounts {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(
            "SELECT genres.id, genres.name, count(*)\n" ++
                "FROM tracks CROSS JOIN track_genres ON track_genres.track_id = tracks.id\n" ++
                "JOIN genres ON genres.id = track_genres.genre_id\n" ++
                "WHERE " ++ by_artist ++ "\nGROUP BY genres.id\n" ++ count_order,
        );
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        try statement.bindInt64(3, artist_id);
        return collectCounts(allocator, statement);
    }

    /// The genre's Releases that have a cover, most played first, for a cover
    /// mosaic.
    pub fn artworkReleases(self: *const GenreRepository, allocator: std.mem.Allocator, genre_id: i64, limit: u32) !ReleaseIds {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(
            "WITH played AS (\n" ++
                "  SELECT tracks.release_id AS release_id,\n" ++
                "         COALESCE(sum(recording_play_stats.play_count), 0) AS play_count, count(*) AS track_count\n" ++
                "  FROM track_genres CROSS JOIN tracks ON tracks.id = track_genres.track_id\n" ++
                "  LEFT JOIN recording_play_stats ON recording_play_stats.recording_id = tracks.recording_id\n" ++
                "  WHERE track_genres.genre_id = ?2 AND tracks.release_id IS NOT NULL\n" ++
                "  GROUP BY tracks.release_id)\n" ++
                "SELECT played.release_id FROM played CROSS JOIN releases ON releases.id = played.release_id\n" ++
                "WHERE " ++ has_cover ++ "\n" ++
                "ORDER BY played.play_count DESC, played.track_count DESC, played.release_id\n" ++
                "LIMIT ?1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        try statement.bindInt64(2, genre_id);
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row) try ids.append(allocator, statement.columnInt64(0));
        return .{ .allocator = allocator, .ids = try ids.toOwnedSlice(allocator) };
    }

    /// Gives each Track exactly `names`, as the user's genres, which no scan
    /// replaces; a name that lists several genres (`Rock, Pop`) gives each.
    /// Empty `names` drops the user's genres and restores the ones the
    /// Track's file states. Fails without changing anything when a Track does
    /// not exist, a name folds to nothing, or the names list more than
    /// `max_track_genres` genres.
    pub fn setTrackGenres(
        self: *GenreRepository,
        allocator: std.mem.Allocator,
        track_ids: []const i64,
        names: []const []const u8,
    ) !void {
        if (track_ids.len == 0 or track_ids.len > max_page) return error.PageOutOfRange;
        if (names.len > max_track_genres) return error.TooManyGenres;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        for (names) |name| {
            const genres = try genre_alias.foldAll(arena.allocator(), &.{name});
            if (genres.len == 0) return error.InvalidGenre;
        }
        if ((try genre_alias.foldAll(arena.allocator(), names)).len > max_track_genres) return error.TooManyGenres;

        self.write_lane.acquire();
        defer self.write_lane.release();
        var writer: GenreWriter = try .init(self.db);
        defer writer.deinit();
        var find = try self.db.prepare("SELECT 1 FROM tracks WHERE id = ?1;");
        defer find.deinit();
        var observed = try self.db.prepare(
            \\SELECT observed.value FROM observed_file_genres AS observed
            \\WHERE observed.file_id = COALESCE(
            \\    (SELECT preferred_file_id FROM tracks WHERE id = ?1 AND EXISTS
            \\        (SELECT 1 FROM observed_file_genres WHERE file_id = tracks.preferred_file_id)),
            \\    (SELECT min(member.id) FROM tracks JOIN files AS member ON member.recording_id = tracks.recording_id
            \\     WHERE tracks.id = ?1
            \\       AND EXISTS (SELECT 1 FROM observed_file_genres WHERE file_id = member.id)))
            \\ORDER BY observed.ordinal;
        );
        defer observed.deinit();

        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        for (track_ids) |track_id| {
            _ = arena.reset(.retain_capacity);
            try find.bindInt64(1, track_id);
            const found = try find.step() == .row;
            try find.reset();
            if (!found) return error.TrackNotFound;
            try writer.clear(track_id);
            if (names.len != 0) {
                try writer.write(arena.allocator(), track_id, names, .user);
                continue;
            }
            var values: std.ArrayList([]const u8) = .empty;
            try observed.bindInt64(1, track_id);
            while (try observed.step() == .row)
                try values.append(arena.allocator(), try arena.allocator().dupe(u8, observed.columnText(0)));
            try observed.reset();
            try writer.write(arena.allocator(), track_id, values.items, .observed_file);
        }
        try pruneOrphansLocked(self.db);
        try self.db.exec("COMMIT;");
    }

    /// Writes a provider's genres on the Tracks of an Artist, as `by_artist`
    /// owns them, or of a Release, that have no genres from their file or the
    /// user. A Release's genres replace earlier provider genres; an Artist's
    /// go only on Tracks with no genres at all, so they never displace a
    /// Release's. Empty `names` changes nothing. Returns the Tracks written.
    pub fn fillFromProvider(
        self: *GenreRepository,
        allocator: std.mem.Allocator,
        target: ProviderGenreTarget,
        names: []const []const u8,
    ) !u32 {
        if (names.len == 0) return 0;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const folded = try genre_alias.foldAll(arena.allocator(), names);
        if (folded.len == 0) return 0;
        const capped = names[0..@min(names.len, max_track_genres)];

        self.write_lane.acquire();
        defer self.write_lane.release();
        var writer: GenreWriter = try .init(self.db);
        defer writer.deinit();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        const select = try self.db.prepare(switch (target) {
            .artist =>
            \\SELECT tracks.id FROM tracks
            \\WHERE (tracks.artist_id = ?1 OR tracks.release_id IN (SELECT id FROM releases WHERE album_artist_id = ?1))
            \\    AND NOT EXISTS (SELECT 1 FROM track_genres WHERE track_id = tracks.id)
            \\ORDER BY tracks.id;
            ,
            .release =>
            \\SELECT tracks.id FROM tracks
            \\WHERE tracks.release_id = ?1
            \\    AND NOT EXISTS (SELECT 1 FROM track_genres WHERE track_id = tracks.id AND provenance IN (0, 1))
            \\ORDER BY tracks.id;
            ,
        });
        defer select.deinit();
        try select.bindInt64(1, switch (target) {
            .artist, .release => |id| id,
        });
        var track_ids: std.ArrayList(i64) = .empty;
        while (try select.step() == .row) try track_ids.append(arena.allocator(), select.columnInt64(0));
        if (track_ids.items.len == 0) {
            try self.db.exec("COMMIT;");
            return 0;
        }
        for (track_ids.items) |track_id| {
            try writer.clear(track_id);
            try writer.write(arena.allocator(), track_id, capped, .provider);
        }
        try pruneOrphansLocked(self.db);
        try self.db.exec("COMMIT;");
        return std.math.cast(u32, track_ids.items.len) orelse std.math.maxInt(u32);
    }

    /// Up to `limit` Releases with a MusicBrainz release ID and a Track that
    /// has no genres at all, by id. Caller frees.
    pub fn releasesWithoutGenres(self: *const GenreRepository, allocator: std.mem.Allocator, limit: u32) ![]i64 {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(
            \\SELECT releases.id FROM releases
            \\WHERE COALESCE(releases.musicbrainz_release_id, '') <> ''
            \\    AND EXISTS (SELECT 1 FROM tracks WHERE tracks.release_id = releases.id
            \\        AND NOT EXISTS (SELECT 1 FROM track_genres WHERE track_id = tracks.id))
            \\ORDER BY releases.id LIMIT ?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row) try ids.append(allocator, statement.columnInt64(0));
        return ids.toOwnedSlice(allocator);
    }
};

pub const ProviderGenreTarget = union(enum) {
    artist: i64,
    release: i64,
};

/// Deletes the genres no Track carries. The caller holds the write lane and
/// an open transaction.
pub fn pruneOrphansLocked(db: sqlite.Database) !void {
    try db.exec("DELETE FROM genres WHERE NOT EXISTS (SELECT 1 FROM track_genres WHERE genre_id = genres.id);");
}

/// Writes Tracks' genres for a caller that holds the write lane and an open
/// transaction, with its statements prepared once for a whole folder.
pub const GenreWriter = struct {
    has_user: sqlite.Statement,
    delete_observed: sqlite.Statement,
    delete_all: sqlite.Statement,
    upsert_genre: sqlite.Statement,
    insert_row: sqlite.Statement,
    track_at: sqlite.Statement,
    carry_target: sqlite.Statement,
    carry: sqlite.Statement,

    pub fn init(db: sqlite.Database) !GenreWriter {
        var has_user = try db.prepare("SELECT 1 FROM track_genres WHERE track_id = ?1 AND provenance = 1 LIMIT 1;");
        errdefer has_user.deinit();
        var delete_observed = try db.prepare("DELETE FROM track_genres WHERE track_id = ?1 AND provenance = 0;");
        errdefer delete_observed.deinit();
        var delete_all = try db.prepare("DELETE FROM track_genres WHERE track_id = ?1;");
        errdefer delete_all.deinit();
        var upsert_genre = try db.prepare(
            "INSERT INTO genres(name, key) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET key = excluded.key RETURNING id;",
        );
        errdefer upsert_genre.deinit();
        var insert_row = try db.prepare(
            "INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES (?1, ?2, ?3, ?4);",
        );
        errdefer insert_row.deinit();
        var track_at = try db.prepare(
            "SELECT id FROM tracks WHERE release_id = ?1 AND COALESCE(disc_number, 1) = ?2 AND track_number = ?3;",
        );
        errdefer track_at.deinit();
        var carry_target = try db.prepare(
            \\SELECT id FROM tracks
            \\WHERE id <> ?2 AND (preferred_file_id = ?1
            \\    OR recording_id = (SELECT recording_id FROM files WHERE id = ?1))
            \\ORDER BY preferred_file_id IS ?1 DESC, id DESC
            \\LIMIT 1;
        );
        errdefer carry_target.deinit();
        const carry = try db.prepare(
            \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance)
            \\SELECT ?2, genre_id, ordinal, provenance FROM track_genres
            \\WHERE track_id = ?1 AND provenance = 1;
        );
        return .{
            .has_user = has_user,
            .delete_observed = delete_observed,
            .delete_all = delete_all,
            .upsert_genre = upsert_genre,
            .insert_row = insert_row,
            .track_at = track_at,
            .carry_target = carry_target,
            .carry = carry,
        };
    }

    pub fn deinit(self: *GenreWriter) void {
        self.has_user.deinit();
        self.delete_observed.deinit();
        self.delete_all.deinit();
        self.upsert_genre.deinit();
        self.insert_row.deinit();
        self.track_at.deinit();
        self.carry_target.deinit();
        self.carry.deinit();
    }

    /// The projection's write for the Track at a position: the genres its
    /// file states, unless the user gave it genres. A file that states none
    /// leaves a provider's genres in place.
    pub fn projectAt(
        self: *GenreWriter,
        allocator: std.mem.Allocator,
        release_id: i64,
        disc: i64,
        number: i64,
        values: []const []const u8,
    ) !void {
        try self.track_at.bindInt64(1, release_id);
        try self.track_at.bindInt64(2, disc);
        try self.track_at.bindInt64(3, number);
        const track_id: ?i64 = if (try self.track_at.step() == .row) self.track_at.columnInt64(0) else null;
        try self.track_at.reset();
        try self.project(allocator, track_id orelse return, values);
    }

    pub fn project(self: *GenreWriter, allocator: std.mem.Allocator, track_id: i64, values: []const []const u8) !void {
        if (try self.hasUser(track_id)) return;
        if (values.len == 0) {
            try runFor(&self.delete_observed, track_id);
            return;
        }
        try self.clear(track_id);
        try self.write(allocator, track_id, values, .observed_file);
    }

    /// Moves the user's genres from a Track the projection is about to delete
    /// to the Track its file backs now, unless that Track has its own.
    pub fn carryUser(self: *GenreWriter, from_track_id: i64, file_id: i64) !void {
        if (!try self.hasUser(from_track_id)) return;
        try self.carry_target.bindInt64(1, file_id);
        try self.carry_target.bindInt64(2, from_track_id);
        const target: ?i64 = if (try self.carry_target.step() == .row) self.carry_target.columnInt64(0) else null;
        try self.carry_target.reset();
        const to_track_id = target orelse return;
        if (try self.hasUser(to_track_id)) return;
        try self.clear(to_track_id);
        try self.carry.bindInt64(1, from_track_id);
        try self.carry.bindInt64(2, to_track_id);
        if (try self.carry.step() != .done) return error.SqlFailed;
        try self.carry.reset();
    }

    fn clear(self: *GenreWriter, track_id: i64) !void {
        try runFor(&self.delete_all, track_id);
    }

    fn hasUser(self: *GenreWriter, track_id: i64) !bool {
        try self.has_user.bindInt64(1, track_id);
        defer self.has_user.reset() catch {};
        return try self.has_user.step() == .row;
    }

    /// Splits and folds the values, keeps the first of any two that fold to
    /// one genre, and numbers the rest in order.
    fn write(
        self: *GenreWriter,
        allocator: std.mem.Allocator,
        track_id: i64,
        values: []const []const u8,
        provenance: metadata.Provenance,
    ) !void {
        const genres = try genre_alias.foldAll(allocator, values);
        defer genre_alias.freeAll(allocator, genres);
        for (genres, 0..) |genre, ordinal| {
            try self.upsert_genre.bindText(1, genre.name);
            try self.upsert_genre.bindText(2, genre.key);
            if (try self.upsert_genre.step() != .row) return error.SqlFailed;
            const genre_id = self.upsert_genre.columnInt64(0);
            try self.upsert_genre.reset();
            try self.insert_row.bindInt64(1, track_id);
            try self.insert_row.bindInt64(2, genre_id);
            try self.insert_row.bindInt64(3, @intCast(ordinal));
            try self.insert_row.bindInt64(4, @intFromEnum(provenance));
            if (try self.insert_row.step() != .done) return error.SqlFailed;
            try self.insert_row.reset();
        }
    }
};

fn runFor(statement: *sqlite.Statement, track_id: i64) !void {
    try statement.bindInt64(1, track_id);
    if (try statement.step() != .done) return error.SqlFailed;
    try statement.reset();
}

test "every genre page and lookup holds the rows and counts one query over each genre's Tracks gives" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-genre-pages?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES
        \\    (1, 'A', 'A', 'a'), (2, 'B', 'B', 'b'), (3, 'C', 'C', 'c');
        \\INSERT INTO releases(id, title, album_artist_id) VALUES (1, 'One', 3), (2, 'Two', NULL), (3, 'Three', 1);
        \\INSERT INTO tracks(id, release_id, artist_id, title, duration_ms) VALUES
        \\    (1, 1, 1, 'a', 100), (2, 1, NULL, 'b', NULL), (3, NULL, 2, 'c', 50),
        \\    (4, 2, 1, 'd', 30), (5, 3, 1, 'e', 70), (6, NULL, NULL, 'f', NULL);
        \\INSERT INTO genres(id, name, key) VALUES
        \\    (1, 'Rock', 'rock'), (2, 'jazz', 'jazz'), (3, 'Folk', 'folk'), (4, 'Ambient', 'ambient'),
        \\    (5, 'Unheard', 'unheard'), (6, 'Rockabilly', 'rockabilly');
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES
        \\    (1, 1, 0, 0), (2, 1, 0, 0), (3, 1, 0, 0), (1, 2, 1, 0), (4, 2, 0, 0), (5, 3, 0, 0),
        \\    (6, 4, 0, 0), (5, 6, 1, 1), (6, 6, 1, 1);
    );
    const reference_columns = comptime "SELECT genres.id, genres.name,\n" ++
        "       (SELECT count(*) FROM track_genres WHERE genre_id = genres.id) AS track_count,\n" ++
        "       (SELECT count(DISTINCT tracks.release_id) FROM track_genres CROSS JOIN tracks ON tracks.id = track_genres.track_id WHERE track_genres.genre_id = genres.id),\n" ++
        "       (SELECT count(*) FROM (" ++ genreArtistIds("genres.id") ++ ")),\n" ++
        "       (SELECT COALESCE(sum(tracks.duration_ms), 0) FROM track_genres CROSS JOIN tracks ON tracks.id = track_genres.track_id WHERE track_genres.genre_id = genres.id)\n" ++
        "FROM genres WHERE EXISTS (SELECT 1 FROM track_genres WHERE genre_id = genres.id) AND (?1 = '' OR instr(genres.key, ?1) > 0)\n";
    inline for (.{ GenreSort.name, GenreSort.track_count }) |sort| {
        for ([_][]const u8{ "", "rock" }) |filter| {
            var reference = try library.database.prepare(reference_columns ++ "ORDER BY " ++ comptime sort.terms() ++ ";");
            defer reference.deinit();
            try reference.bindText(1, filter);
            var expected = try collectGenrePage(std.testing.allocator, reference);
            defer expected.deinit();
            try std.testing.expectEqual(if (filter.len == 0) @as(usize, 5) else 2, expected.items.len);
            try std.testing.expectEqual(@as(u64, expected.items.len), try library.genres.count(std.testing.allocator, filter));
            var offset: u32 = 0;
            while (offset < expected.items.len + 2) : (offset += 2) {
                var page = try library.genres.page(std.testing.allocator, .{
                    .filter = filter,
                    .sort = sort,
                    .limit = 2,
                    .offset = offset,
                });
                defer page.deinit();
                const want = expected.items[@min(offset, expected.items.len)..@min(offset + 2, expected.items.len)];
                try std.testing.expectEqual(want.len, page.items.len);
                for (want, page.items) |expected_genre, genre| try std.testing.expectEqualDeep(expected_genre, genre);
            }
        }
    }

    var everything = try library.genres.page(std.testing.allocator, .{});
    defer everything.deinit();
    for (everything.items) |genre| {
        const found = (try library.genres.byId(std.testing.allocator, genre.id)).?;
        defer found.deinit(std.testing.allocator);
        try std.testing.expectEqualDeep(genre, found);
    }
    try std.testing.expectEqual(@as(?GenreSummary, null), try library.genres.byId(std.testing.allocator, 5));
    const rock = (try library.genres.byId(std.testing.allocator, 1)).?;
    defer rock.deinit(std.testing.allocator);
    try std.testing.expectEqual(GenreSummary{
        .id = 1,
        .name = rock.name,
        .track_count = 3,
        .release_count = 1,
        .artist_count = 3,
        .total_duration_ms = 150,
    }, rock);
}

test "provider genres go only on Tracks without file or user genres, a Release's replacing an Artist's but never the reverse" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-genre-provider-fill?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES (1, 'Queen', 'Queen', 'queen');
        \\INSERT INTO releases(id, title, album_artist_id, musicbrainz_release_id) VALUES
        \\    (1, 'Hot Space', 1, '047a4aae-27f8-4f2d-92fb-214fd8dc865a'), (2, 'Loose', NULL, NULL);
        \\INSERT INTO tracks(id, release_id, artist_id, title) VALUES
        \\    (1, 1, 1, 'tagged'), (2, 1, 1, 'edited'), (3, 1, 1, 'bare'), (4, 2, 1, 'loose');
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Glam', 'glam'), (2, 'Mine', 'mine');
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES (1, 1, 0, 0), (2, 2, 0, 1);
    );
    const missing = try library.genres.releasesWithoutGenres(std.testing.allocator, 10);
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualSlices(i64, &.{1}, missing);

    try std.testing.expectEqual(@as(u32, 2), try library.genres.fillFromProvider(std.testing.allocator, .{ .artist = 1 }, &.{ "Hip Hop", "Pop" }));
    try std.testing.expectEqual(@as(u32, 1), try library.genres.fillFromProvider(std.testing.allocator, .{ .release = 1 }, &.{ "rock", "funk" }));
    try std.testing.expectEqual(@as(u32, 0), try library.genres.fillFromProvider(std.testing.allocator, .{ .artist = 1 }, &.{"Pop"}));
    try std.testing.expectEqual(@as(u32, 0), try library.genres.fillFromProvider(std.testing.allocator, .{ .release = 1 }, &.{}));

    const expectations = [_]struct { track: i64, names: []const []const u8, provenance: metadata.Provenance }{
        .{ .track = 1, .names = &.{"Glam"}, .provenance = .observed_file },
        .{ .track = 2, .names = &.{"Mine"}, .provenance = .user },
        .{ .track = 3, .names = &.{ "Rock", "Funk" }, .provenance = .provider },
        .{ .track = 4, .names = &.{ "Hip Hop", "Pop" }, .provenance = .provider },
    };
    for (expectations) |expected| {
        const names = try library.genres.forTrack(std.testing.allocator, expected.track);
        defer names.deinit();
        try std.testing.expectEqual(expected.names.len, names.items.len);
        for (expected.names, names.items) |name, genre| {
            try std.testing.expect(std.ascii.eqlIgnoreCase(name, genre.name));
            try std.testing.expectEqual(expected.provenance, genre.provenance);
        }
    }
    const after = try library.genres.releasesWithoutGenres(std.testing.allocator, 10);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "a genre's artwork holds only the Releases the artwork filter finds a cover for, most played first" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-genre-artwork?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec(
        \\INSERT INTO releases(id, title, release_key) VALUES
        \\    (1, 'Fetched', 'r1'), (2, 'Embedded', 'r2'), (3, 'Bare', 'r3'), (4, 'Fetch missed', 'r4'),
        \\    (5, 'Elsewhere', 'r5');
        \\INSERT INTO recordings(id, title)
        \\    WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v + 1 FROM n WHERE v < 6) SELECT v, 'Song' FROM n;
        \\INSERT INTO files(id, recording_id, codec)
        \\    WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v + 1 FROM n WHERE v < 6) SELECT v, v, 'flac' FROM n;
        \\INSERT INTO tracks(id, recording_id, release_id, title, track_number, preferred_file_id) VALUES
        \\    (1, 1, 1, 'Song', 1, 1), (2, 2, 2, 'Song', 1, 2), (3, 3, 3, 'Song', 1, 3),
        \\    (4, 4, 4, 'Song', 1, 4), (5, 5, 5, 'Song', 1, 5), (6, 6, 1, 'Song', 2, 6);
        \\INSERT INTO release_artwork(release_id, musicbrainz_release_id, image, mime, fetched_at) VALUES
        \\    (1, 'mbid', x'89504e47', 'image/png', 0), (4, 'mbid', NULL, NULL, 0),
        \\    (5, 'mbid', x'89504e47', 'image/png', 0);
        \\INSERT INTO observed_file_tags(file_id, artwork_mime_type, artwork_byte_size, observed_at) VALUES
        \\    (2, 'image/jpeg', 2048, 0), (3, 'image/jpeg', 0, 0);
        \\INSERT INTO recording_play_stats(recording_id, play_count, last_played_at) VALUES
        \\    (1, 1, 0), (2, 5, 0), (3, 9, 0), (4, 9, 0), (5, 20, 0);
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Rock', 'rock'), (2, 'Jazz', 'jazz');
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES
        \\    (1, 1, 0, 0), (2, 1, 0, 0), (3, 1, 0, 0), (4, 1, 0, 0), (5, 2, 0, 0), (6, 1, 0, 0);
    );

    var artwork = try library.genres.artworkReleases(std.testing.allocator, 1, 8);
    defer artwork.deinit();
    try std.testing.expectEqualSlices(i64, &.{ 2, 1 }, artwork.ids);

    var with_artwork = try library.releases.page(std.testing.allocator, .{ .genre_id = 1, .has_artwork = true });
    defer with_artwork.deinit();
    try std.testing.expectEqual(artwork.ids.len, with_artwork.items.len);
    for (with_artwork.items) |release| try std.testing.expect(std.mem.indexOfScalar(i64, artwork.ids, release.id) != null);

    var first = try library.genres.artworkReleases(std.testing.allocator, 1, 1);
    defer first.deinit();
    try std.testing.expectEqualSlices(i64, &.{2}, first.ids);
}
