const std = @import("std");
const sqlite = @import("../sqlite.zig");
const text_key = @import("../text_key.zig");
const columns = @import("../columns.zig");

const max_page = columns.max_page;
const presentText = columns.presentText;
const by_artist = @import("tracks.zig").by_artist;
const by_release_artist = @import("tracks.zig").by_release_artist;
const byAppearingArtist = @import("releases.zig").byAppearingArtist;
const artistsOfGenre = @import("genres.zig").artistsOfGenre;
const WriteLane = @import("write_lane.zig").WriteLane;

/// The projection's artist input. Identity is `key` — the normalized name —
/// unless a MusicBrainz artist id is present, which outranks it.
pub const ArtistUpsert = struct {
    key: []const u8,
    name: []const u8,
    /// The folded key an artist listing orders by — `text_key.sortKey`, which
    /// drops a leading English article so "The Beatles" files under B. Stored
    /// rather than computed per query so one index serves the whole listing.
    sort_name: []const u8 = "",
    musicbrainz_artist_id: ?[]const u8 = null,
};

/// Artists as the projection resolves them.
///
/// An Artist as a browse listing shows one: the name to display, the key it is
/// filed under, and how much of the library is theirs.
pub const ArtistSummary = struct {
    id: i64,
    name: []u8,
    /// The folded sort key. A host displays `name` and trusts this only for
    /// section headers, because it is lowercased and article-stripped.
    sort_name: []u8,
    release_count: u32,
    track_count: u32,
    loved: bool = false,

    pub fn deinit(self: ArtistSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.sort_name);
    }
};

/// What an Artist page sums over the whole Artist, not a page of it.
pub const ArtistTotals = struct {
    /// The Releases filed under the Artist as album artist, as
    /// `ReleaseQuery.own_releases_only` lists them. Unlike
    /// `ArtistSummary.release_count`, it leaves out `appearance_count`.
    release_count: u32,
    /// As `ArtistSummary.track_count`.
    track_count: u32,
    /// Summed over those Tracks; a Track with no known duration adds 0.
    duration_ms: u64,
    /// The Releases `ReleaseQuery.appearing_artist_id` lists for the Artist.
    appearance_count: u32,
};

pub const ArtistPage = struct {
    allocator: std.mem.Allocator,
    items: []ArtistSummary,

    pub fn deinit(self: ArtistPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

/// Identity is the normalized name (`artists.key`), which is what makes
/// `Sigur Rós`, `sigur rós` and `Sigur  Rós` one artist. A MusicBrainz artist
/// id, when the files carry one, outranks that: it recognizes the same artist
/// under a differently spelled name, and it is looked up first.
pub const ArtistRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn ensure(self: *ArtistRepository, input: ArtistUpsert) !?i64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        const id = try self.ensureLocked(input);
        try self.db.exec("COMMIT;");
        return id;
    }

    /// Null for a nameless artist: an empty name is an absent artist, not an
    /// artist whose name happens to be empty, and collapsing every untagged
    /// file onto one shared row would be worse than having no row.
    pub fn ensureLocked(self: *ArtistRepository, input: ArtistUpsert) !?i64 {
        if (input.key.len == 0) return null;
        if (input.musicbrainz_artist_id) |mbid| if (mbid.len != 0) {
            var lookup = try self.db.prepare(
                "SELECT id FROM artists WHERE musicbrainz_artist_id=?1 LIMIT 1;",
            );
            defer lookup.deinit();
            try lookup.bindText(1, mbid);
            if (try lookup.step() == .row) return lookup.columnInt64(0);
        };
        var statement = try self.db.prepare(
            \\INSERT INTO artists(name, key, sort_name, musicbrainz_artist_id)
            \\VALUES (?1, ?2, ?4, ?3)
            \\ON CONFLICT(key) DO UPDATE SET
            \\    name = CASE WHEN excluded.name = '' THEN artists.name ELSE excluded.name END,
            \\    sort_name = CASE
            \\        WHEN excluded.name = '' THEN artists.sort_name ELSE excluded.sort_name END,
            \\    musicbrainz_artist_id =
            \\        COALESCE(artists.musicbrainz_artist_id, excluded.musicbrainz_artist_id)
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindText(1, input.name);
        try statement.bindText(2, input.key);
        try statement.bindOptionalText(3, presentText(input.musicbrainz_artist_id));
        try statement.bindText(4, input.sort_name);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    /// One bounded page of Artists in sort-key order, optionally narrowed to
    /// those whose name contains `filter`.
    ///
    /// `sort_name` is unique enough for a person but not for a database, so
    /// the order ends in `artists.id` — the same total-order rule the Track
    /// listing follows, for the same reason.
    ///
    /// The needle is folded exactly as `artists.key` was, so typing `el-p`
    /// finds `El‐P` spelled with U+2010 and `stevie nicks` finds `Stevie
    /// Nicks`. Matching uses `instr` rather than `LIKE` so a name containing
    /// `%` or `_` is a literal rather than a wildcard, and the fold is done on
    /// the stack because a search box calls this on every keystroke.
    ///
    /// A filtered listing scans the artist table. That is deliberate: an
    /// infix match cannot use an index, and artists grow far more slowly than
    /// tracks. If that ever stops being cheap the answer is an FTS table, not
    /// an index.
    pub fn page(
        self: *const ArtistRepository,
        allocator: std.mem.Allocator,
        query: ArtistQuery,
    ) !ArtistPage {
        if (query.limit == 0 or query.limit > max_page) return error.PageOutOfRange;
        var folded: [text_key.key_buffer_size]u8 = undefined;
        const needle = text_key.normalizeInto(&folded, query.filter);
        var statement = switch (query.sort) {
            inline else => |sort| switch (needle.len != 0) {
                inline else => |by_needle| switch (query.genre_id != null) {
                    inline else => |by_genre| switch (query.loved_only) {
                        inline else => |by_loved| try self.db.prepare(comptime artistQueryText(sort, by_needle, by_genre, by_loved)),
                    },
                },
            },
        };
        defer statement.deinit();
        try statement.bindInt64(1, query.limit);
        try statement.bindInt64(2, query.offset);
        if (needle.len != 0) try statement.bindText(3, needle);
        if (query.genre_id) |genre_id| try statement.bindInt64(4, genre_id);
        return collectArtistPage(allocator, statement);
    }

    /// Counts what `page` would return, sharing its folding and its predicate.
    pub fn countMatching(self: *const ArtistRepository, query: ArtistQuery) !u64 {
        var folded: [text_key.key_buffer_size]u8 = undefined;
        const needle = text_key.normalizeInto(&folded, query.filter);
        if (needle.len == 0 and query.genre_id == null and !query.loved_only) return self.count();
        var statement = try self.db.prepare(
            "SELECT count(*) FROM artists WHERE (?3 = '' OR instr(artists.key, ?3) > 0)\n" ++
                "  AND (?4 IS NULL OR " ++ comptime artistsOfGenre("?4") ++ ")\n" ++
                "  AND (?5 = 0 OR EXISTS (SELECT 1 FROM artist_loves WHERE artist_loves.artist_id = artists.id));",
        );
        defer statement.deinit();
        try statement.bindText(3, needle);
        try statement.bindOptionalInt64(4, query.genre_id);
        try statement.bindInt64(5, @intFromBool(query.loved_only));
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn byId(
        self: *const ArtistRepository,
        allocator: std.mem.Allocator,
        artist_id: i64,
    ) !?ArtistSummary {
        var statement = try self.db.prepare(artist_columns ++ artist_from ++
            \\WHERE artists.id = ?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, artist_id);
        var found = try collectArtistPage(allocator, statement);
        if (found.items.len == 0) {
            found.deinit();
            return null;
        }
        const first = found.items[0];
        for (found.items[1..]) |extra| extra.deinit(allocator);
        allocator.free(found.items);
        return first;
    }

    /// The Artist's totals in one query, or null for an unknown Artist.
    pub fn totals(self: *const ArtistRepository, artist_id: i64) !?ArtistTotals {
        var statement = try self.db.prepare(
            "SELECT (SELECT count(*) FROM releases WHERE releases.album_artist_id = ?3),\n" ++
                "       artist_tracks.track_count, artist_tracks.duration_ms,\n" ++
                "       (SELECT count(*) FROM releases WHERE " ++ comptime byAppearingArtist("?3") ++ ")\n" ++
                "FROM artists, (SELECT count(*) AS track_count,\n" ++
                "    COALESCE(sum(tracks.duration_ms), 0) AS duration_ms\n" ++
                "    FROM tracks WHERE " ++ by_artist ++ ") AS artist_tracks\n" ++
                "WHERE artists.id = ?3;",
        );
        defer statement.deinit();
        try statement.bindInt64(3, artist_id);
        if (try statement.step() != .row) return null;
        return .{
            .release_count = @intCast(statement.columnInt64(0)),
            .track_count = @intCast(statement.columnInt64(1)),
            .duration_ms = @intCast(statement.columnInt64(2)),
            .appearance_count = @intCast(statement.columnInt64(3)),
        };
    }

    pub fn count(self: *const ArtistRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM artists;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

/// The per-artist counts are correlated subqueries rather than a GROUP BY
/// join: each is one range count over `tracks_by_artist` / `releases_by_artist`
/// for a page of at most 512 rows, and a join would have to aggregate the whole
/// table before the LIMIT could apply.
const artist_columns =
    "SELECT artists.id, artists.name, COALESCE(artists.sort_name, ''),\n" ++
    "       (SELECT count(*) FROM releases WHERE " ++ artistOwns(by_release_artist) ++ "),\n" ++
    "       (SELECT count(*) FROM tracks WHERE " ++ artistOwns(by_artist) ++ "),\n" ++
    "       artist_loves.artist_id IS NOT NULL\n";

const artist_from = "FROM artists LEFT JOIN artist_loves ON artist_loves.artist_id = artists.id\n";

/// The newest Release of `by_release_artist`, as two lookups because its OR
/// would read every Release for each Artist: `releases_by_artist` for those
/// filed under them, `tracks_artist` for those they appear on.
const newest_release = "max(COALESCE((SELECT max(releases.id) FROM releases WHERE releases.album_artist_id = artists.id), 0),\n" ++
    "    COALESCE((SELECT max(tracks.release_id) FROM tracks WHERE tracks.artist_id = artists.id), 0))";

fn artistQueryText(comptime sort: ArtistSort, comptime by_needle: bool, comptime by_genre: bool, comptime by_loved: bool) [:0]const u8 {
    var terms: []const []const u8 = &.{};
    if (by_needle) terms = terms ++ .{"instr(artists.key, ?3) > 0"};
    if (by_genre) terms = terms ++ .{artistsOfGenre("?4")};
    if (by_loved) terms = terms ++ .{"artist_loves.artist_id IS NOT NULL"};
    var where: []const u8 = "";
    for (terms, 0..) |term, index| where = where ++ (if (index == 0) "WHERE " else " AND ") ++ term;
    if (where.len != 0) where = where ++ "\n";
    return artist_columns ++ artist_from ++ where ++ "ORDER BY " ++ comptime sort.terms() ++
        "\nLIMIT ?1 OFFSET ?2;";
}

/// Rewrites one of the shared artist predicates from its bound-parameter form
/// to the correlated form the artist listing needs, so the count beside a
/// name and the pane it labels cannot disagree.
fn artistOwns(comptime predicate: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var rest = predicate;
        while (std.mem.indexOf(u8, rest, "?3")) |at| {
            out = out ++ rest[0..at] ++ "artists.id";
            rest = rest[at + 2 ..];
        }
        return out ++ rest;
    }
}

fn collectArtistPage(allocator: std.mem.Allocator, statement: sqlite.Statement) !ArtistPage {
    var results: std.ArrayList(ArtistSummary) = .empty;
    errdefer {
        for (results.items) |item| item.deinit(allocator);
        results.deinit(allocator);
    }
    while (try statement.step() == .row) {
        const name = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(name);
        const sort_name = try allocator.dupe(u8, statement.columnText(2));
        errdefer allocator.free(sort_name);
        try results.append(allocator, .{
            .id = statement.columnInt64(0),
            .name = name,
            .sort_name = sort_name,
            .release_count = @intCast(statement.columnInt64(3)),
            .track_count = @intCast(statement.columnInt64(4)),
            .loved = statement.columnInt64(5) != 0,
        });
    }
    return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
}

/// One bounded request for a page of Releases, optionally scoped to an Artist.
pub const ArtistQuery = struct {
    /// Free text. Folded the way `artists.key` was folded before matching, so
    /// a search is spelling-insensitive in the same way identity is.
    filter: []const u8 = "",
    /// Only the Artists owning a Track that carries this genre: credited on
    /// it, or album artist of its Release.
    genre_id: ?i64 = null,
    /// Only the Artists the user loved.
    loved_only: bool = false,
    sort: ArtistSort = .name,
    limit: u32 = max_page,
    offset: u32 = 0,
};

/// The orders an Artist listing comes in. Each ends in `artists.id`.
pub const ArtistSort = enum {
    name,
    /// Most Tracks first, counting every Track the Artist owns, not only
    /// those of a genre filter.
    track_count,
    /// Most recently loved first, then the Artists not loved.
    recently_loved,
    /// The Artist whose newest Release, in `ReleaseSort.recently_added`'s
    /// order, was added most recently first; Artists with no Release last.
    recently_added,

    fn terms(comptime self: ArtistSort) []const u8 {
        return switch (self) {
            .name => "artists.sort_name, artists.id",
            .track_count => "5 DESC, artists.sort_name, artists.id",
            .recently_loved => "artist_loves.loved_at IS NULL, artist_loves.loved_at DESC, artists.id",
            .recently_added => newest_release ++ " DESC, artists.id DESC",
        };
    }
};

fn openArtistLibrary(comptime name: []const u8) !@import("../library.zig").LibraryDatabase {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-artist-" ++ name ++ "?mode=memory&cache=shared",
    );
    errdefer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name) VALUES
        \\    (1, 'Host', 'host'), (2, 'Other', 'other'), (3, 'Guest', 'guest'), (4, 'Silent', 'silent');
        \\INSERT INTO releases(id, title, release_key, album_artist_id) VALUES
        \\    (1, 'Own', 'r1', 1), (2, 'Theirs', 'r2', 2), (3, 'Later', 'r3', 1), (4, 'Unfiled', 'r4', NULL);
        \\INSERT INTO tracks(id, release_id, title, duration_ms, artist_id) VALUES
        \\    (1, 1, 'One', 1000, 1), (2, 1, 'Two', NULL, 1), (3, 2, 'Feature', 500, 1),
        \\    (4, 2, 'Their own', 700, 2), (5, 3, 'Later', NULL, 3), (6, 4, 'Loose', 250, 1);
    );
    return library;
}

test "artist totals count only the artist's own releases, sum every track their listing holds with a null duration as zero, and count their appearances" {
    var library = try openArtistLibrary("totals");
    defer library.close();
    const host = (try library.artists.totals(1)).?;
    try std.testing.expectEqual(ArtistTotals{ .release_count = 2, .track_count = 5, .duration_ms = 1750, .appearance_count = 2 }, host);
    try std.testing.expectEqual(@as(u64, host.track_count), try library.tracks.countMatching(.{ .artist_id = 1 }));
    try std.testing.expectEqual(@as(u64, host.release_count), try library.releases.countMatching(.{ .album_artist_id = 1, .own_releases_only = true }));
    try std.testing.expectEqual(@as(u64, host.release_count + host.appearance_count), try library.releases.countMatching(.{ .album_artist_id = 1 }));
    const other = (try library.artists.totals(2)).?;
    try std.testing.expectEqual(ArtistTotals{ .release_count = 1, .track_count = 2, .duration_ms = 1200, .appearance_count = 0 }, other);
    try std.testing.expectEqual(@as(u64, 1), try library.releases.countMatching(.{ .album_artist_id = 2, .own_releases_only = true }));
    try std.testing.expectEqual(@as(u64, 4), try library.releases.countMatching(.{ .own_releases_only = true }));
    const silent = (try library.artists.totals(4)).?;
    try std.testing.expectEqual(ArtistTotals{ .release_count = 0, .track_count = 0, .duration_ms = 0, .appearance_count = 0 }, silent);
    try std.testing.expectEqual(@as(?ArtistTotals, null), try library.artists.totals(99));
}

test "artists sort by their newest release, filed under them or appeared on, newest first, then by id, with none last" {
    var library = try openArtistLibrary("recently-added");
    defer library.close();
    var listed = try library.artists.page(std.testing.allocator, .{ .sort = .recently_added });
    defer listed.deinit();
    var ids: [4]i64 = undefined;
    for (listed.items, 0..) |item, index| ids[index] = item.id;
    try std.testing.expectEqualSlices(i64, &.{ 1, 3, 2, 4 }, ids[0..listed.items.len]);
    var window = try library.artists.page(std.testing.allocator, .{ .sort = .recently_added, .limit = 2, .offset = 1 });
    defer window.deinit();
    try std.testing.expectEqual(@as(usize, 2), window.items.len);
    try std.testing.expectEqual(@as(i64, 3), window.items[0].id);
    try std.testing.expectEqual(@as(i64, 2), window.items[1].id);
}
