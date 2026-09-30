const std = @import("std");
const sqlite = @import("../sqlite.zig");
const text_key = @import("../text_key.zig");
const columns = @import("../columns.zig");

const max_page = columns.max_page;
const presentText = columns.presentText;
const by_artist = @import("tracks.zig").by_artist;
const by_release_artist = @import("tracks.zig").by_release_artist;
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

    pub fn deinit(self: ArtistSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.sort_name);
    }
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
        var statement = if (needle.len == 0)
            try self.db.prepare(artist_columns ++
                \\FROM artists
                \\ORDER BY artists.sort_name, artists.id
                \\LIMIT ?1 OFFSET ?2;
            )
        else
            try self.db.prepare(artist_columns ++
                \\FROM artists
                \\WHERE instr(artists.key, ?3) > 0
                \\ORDER BY artists.sort_name, artists.id
                \\LIMIT ?1 OFFSET ?2;
            );
        defer statement.deinit();
        try statement.bindInt64(1, query.limit);
        try statement.bindInt64(2, query.offset);
        if (needle.len != 0) try statement.bindText(3, needle);
        return collectArtistPage(allocator, statement);
    }

    /// Counts what `page` would return, sharing its folding and its predicate.
    pub fn countMatching(self: *const ArtistRepository, query: ArtistQuery) !u64 {
        var folded: [text_key.key_buffer_size]u8 = undefined;
        const needle = text_key.normalizeInto(&folded, query.filter);
        if (needle.len == 0) return self.count();
        var statement = try self.db.prepare(
            "SELECT count(*) FROM artists WHERE instr(artists.key, ?1) > 0;",
        );
        defer statement.deinit();
        try statement.bindText(1, needle);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn byId(
        self: *const ArtistRepository,
        allocator: std.mem.Allocator,
        artist_id: i64,
    ) !?ArtistSummary {
        var statement = try self.db.prepare(artist_columns ++
            \\FROM artists WHERE artists.id = ?1;
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
    "       (SELECT count(*) FROM tracks WHERE " ++ artistOwns(by_artist) ++ ")\n";

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
        });
    }
    return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
}

/// One bounded request for a page of Releases, optionally scoped to an Artist.
pub const ArtistQuery = struct {
    /// Free text. Folded the way `artists.key` was folded before matching, so
    /// a search is spelling-insensitive in the same way identity is.
    filter: []const u8 = "",
    limit: u32 = max_page,
    offset: u32 = 0,
};
