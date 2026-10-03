const std = @import("std");
const sqlite = @import("../sqlite.zig");

/// The longest search text a query accepts, in bytes.
pub const max_search_text = 256;
/// The most hits of one kind a search returns.
pub const max_search_hits_per_kind = 50;

/// What a search hit names. The values are `search_index.kind`, which holds
/// no Tracks: they are searched in `track_search`.
pub const SearchKind = enum(u8) { artist, release, track, playlist, genre };

pub const SearchHit = struct {
    kind: SearchKind,
    id: i64,
    /// The Artist's, Release's, Track's, Playlist's or Genre's name.
    title: []u8,
    /// A Release's album artist, a Track's artist and album, a Playlist's
    /// description; empty for an Artist or a Genre.
    subtitle: []u8,
    /// Lower is more relevant, comparable only within one kind of one search.
    /// For a Track, 0 when every word is a whole word of the title, 1 when
    /// every word begins a word of the title, 2 otherwise; for any other kind,
    /// bm25 over title and subtitle, title weighted higher.
    rank: f32,

    pub fn deinit(self: SearchHit, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.subtitle);
    }
};

/// How many hits of each kind a search returns, each at most
/// `max_search_hits_per_kind`.
pub const SearchLimits = struct {
    artists: u8 = 5,
    releases: u8 = 5,
    tracks: u8 = 8,
    playlists: u8 = 4,
    genres: u8 = 3,
};

/// Hits in kind order, most relevant first within each kind.
pub const SearchResults = struct {
    allocator: std.mem.Allocator,
    hits: []SearchHit,

    pub fn deinit(self: SearchResults) void {
        for (self.hits) |hit| hit.deinit(self.allocator);
        self.allocator.free(self.hits);
    }
};

/// Room for `matchExpression` of any text up to `max_search_text`: a
/// one-byte word costs at most eight bytes of expression, doubled quotes two
/// per byte.
pub const max_match_expression = max_search_text * 5 + 8;

/// The FTS5 query that finds `text` in `search_index` or `track_search`: each
/// whitespace separated word as a quoted prefix, all of them required, so no
/// character the user types is FTS5 syntax. A word with nothing the tokenizer
/// keeps is left out, since it would match nothing. Null when no word remains.
pub fn matchExpression(buffer: *[max_match_expression]u8, text: []const u8) !?[]const u8 {
    return expressionOf(buffer, text, .prefix);
}

const WordMatch = enum { prefix, whole };

fn expressionOf(buffer: *[max_match_expression]u8, text: []const u8, match: WordMatch) !?[]const u8 {
    if (text.len > max_search_text) return error.SearchTextTooLong;
    var expression: std.Io.Writer = .fixed(buffer);
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n\x0b\x0c");
    while (words.next()) |word| {
        if (!hasWordCharacter(word)) continue;
        if (expression.end != 0) try expression.writeAll(" AND ");
        try expression.writeByte('"');
        for (word) |byte| {
            if (byte == '"') try expression.writeByte('"');
            try expression.writeByte(byte);
        }
        try expression.writeAll(switch (match) {
            .prefix => "\"*",
            .whole => "\"",
        });
    }
    if (expression.end == 0) return null;
    return expression.buffered();
}

fn hasWordCharacter(word: []const u8) bool {
    var index: usize = 0;
    while (index < word.len) {
        const byte = word[index];
        if (byte < 0x80) {
            if (std.ascii.isAlphanumeric(byte)) return true;
            index += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(byte) catch return true;
        if (index + length > word.len) return true;
        const codepoint = std.unicode.utf8Decode(word[index..][0..length]) catch return true;
        if (!isSeparator(codepoint)) return true;
        index += length;
    }
    return false;
}

fn isSeparator(codepoint: u21) bool {
    return switch (codepoint) {
        0xaa, 0xb2, 0xb3, 0xb5, 0xb9, 0xba, 0xbc, 0xbd, 0xbe => false,
        0xa0...0xa9, 0xab...0xb1, 0xb4, 0xb6...0xb8, 0xbb, 0xbf, 0xd7, 0xf7, 0x2000...0x206f => true,
        else => false,
    };
}

const track_hits_sql = "SELECT " ++ std.fmt.comptimePrint("{d}", .{@intFromEnum(SearchKind.track)}) ++
    \\ AS kind, tracks.id, tracks.title, tracks.artist || ' ' || tracks.album, tiered.score FROM (
    \\    SELECT hit, min(tier) AS score FROM (
    \\        SELECT * FROM (
    \\            SELECT rowid AS hit, 0 AS tier FROM track_search
    \\            WHERE track_search MATCH '{title}: (' || ?7 || ')' ORDER BY rowid LIMIT ?4
    \\        )
    \\        UNION ALL
    \\        SELECT * FROM (
    \\            SELECT rowid AS hit, 1 AS tier FROM track_search
    \\            WHERE track_search MATCH '{title}: (' || ?1 || ')' ORDER BY rowid LIMIT ?4
    \\        )
    \\        UNION ALL
    \\        SELECT * FROM (
    \\            SELECT rowid AS hit, 2 AS tier FROM track_search
    \\            WHERE track_search MATCH '{title artist album}: (' || ?1 || ')' ORDER BY rowid LIMIT ?4
    \\        )
    \\    ) GROUP BY hit ORDER BY score, hit LIMIT ?4
    \\) AS tiered JOIN tracks ON tracks.id = tiered.hit
    \\
;

const ranked_hits_sql = blk: {
    var arms: []const u8 = "";
    for (0..std.meta.fields(SearchKind).len) |kind| {
        if (kind == @intFromEnum(SearchKind.track)) continue;
        arms = arms ++ (if (arms.len == 0) "" else "    UNION ALL\n") ++ std.fmt.comptimePrint(
            \\    SELECT * FROM (
            \\        SELECT rowid AS hit, bm25(search_index, 0, 0, 10, 4) AS score FROM search_index
            \\        WHERE search_index MATCH ?1 AND rowid % 8 = {d} ORDER BY score, rowid LIMIT ?{d}
            \\    )
            \\
        , .{ kind, kind + 2 });
    }
    break :blk "SELECT entry.kind AS kind, entry.entity_id AS id, entry.title, entry.subtitle, ranked.score AS score FROM (\n" ++
        arms ++ ") AS ranked JOIN search_index AS entry ON entry.rowid = ranked.hit\nUNION ALL\n" ++
        track_hits_sql ++ "ORDER BY kind, score, id;";
};

pub const SearchRepository = struct {
    db: sqlite.Database,

    pub fn find(self: *const SearchRepository, allocator: std.mem.Allocator, text: []const u8, limits: SearchLimits) !SearchResults {
        inline for (std.meta.fields(SearchLimits)) |field| {
            if (@field(limits, field.name) > max_search_hits_per_kind) return error.InvalidSearchLimits;
        }
        var buffer: [max_match_expression]u8 = undefined;
        const expression = try matchExpression(&buffer, text) orelse
            return .{ .allocator = allocator, .hits = &.{} };
        var whole_buffer: [max_match_expression]u8 = undefined;
        const whole_words = (try expressionOf(&whole_buffer, text, .whole)).?;
        var statement = try self.db.prepare(ranked_hits_sql);
        defer statement.deinit();
        try statement.bindText(1, expression);
        try statement.bindInt64(2, limits.artists);
        try statement.bindInt64(3, limits.releases);
        try statement.bindInt64(4, limits.tracks);
        try statement.bindInt64(5, limits.playlists);
        try statement.bindInt64(6, limits.genres);
        try statement.bindText(7, whole_words);
        var hits: std.ArrayList(SearchHit) = .empty;
        errdefer {
            for (hits.items) |hit| hit.deinit(allocator);
            hits.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const title = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(title);
            const subtitle = try allocator.dupe(u8, statement.columnText(3));
            errdefer allocator.free(subtitle);
            try hits.append(allocator, .{
                .kind = @enumFromInt(@as(u8, @intCast(statement.columnInt64(0)))),
                .id = statement.columnInt64(1),
                .title = title,
                .subtitle = subtitle,
                .rank = @floatCast(statement.columnDouble(4)),
            });
        }
        return .{ .allocator = allocator, .hits = try hits.toOwnedSlice(allocator) };
    }
};

const LibraryDatabase = @import("../library.zig").LibraryDatabase;

fn openSearchLibrary(comptime name: []const u8) !LibraryDatabase {
    return LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-search-" ++ name ++ "?mode=memory&cache=shared",
    );
}

const Expected = struct { kind: SearchKind, id: i64 };

fn expectHits(library: *LibraryDatabase, text: []const u8, limits: SearchLimits, expected: []const Expected) !void {
    var results = try library.search.find(std.testing.allocator, text, limits);
    defer results.deinit();
    var actual: std.ArrayList(Expected) = .empty;
    defer actual.deinit(std.testing.allocator);
    for (results.hits) |hit| try actual.append(std.testing.allocator, .{ .kind = hit.kind, .id = hit.id });
    try std.testing.expectEqualSlices(Expected, expected, actual.items);
}

fn indexRow(library: *LibraryDatabase, kind: SearchKind, id: i64) !?[2][]u8 {
    var statement = try library.database.prepare(
        "SELECT title, subtitle FROM search_index WHERE rowid = ?1 * 8 + ?2 AND kind = ?2 AND entity_id = ?1;",
    );
    defer statement.deinit();
    try statement.bindInt64(1, id);
    try statement.bindInt64(2, @intFromEnum(kind));
    if (try statement.step() != .row) return null;
    const title = try std.testing.allocator.dupe(u8, statement.columnText(0));
    errdefer std.testing.allocator.free(title);
    return .{ title, try std.testing.allocator.dupe(u8, statement.columnText(1)) };
}

fn expectIndexRow(library: *LibraryDatabase, kind: SearchKind, id: i64, title: ?[]const u8, subtitle: []const u8) !void {
    const row = try indexRow(library, kind, id);
    if (title == null) return std.testing.expectEqual(@as(?[2][]u8, null), row);
    const found = row orelse return error.TestExpectedIndexRow;
    defer for (found) |value| std.testing.allocator.free(value);
    try std.testing.expectEqualStrings(title.?, found[0]);
    try std.testing.expectEqualStrings(subtitle, found[1]);
}

fn expectTrackHit(library: *LibraryDatabase, text: []const u8, id: i64, title: []const u8, subtitle: []const u8) !void {
    var results = try library.search.find(std.testing.allocator, text, .{ .artists = 0, .releases = 0, .playlists = 0, .genres = 0 });
    defer results.deinit();
    try std.testing.expectEqual(@as(usize, 1), results.hits.len);
    try std.testing.expectEqual(SearchKind.track, results.hits[0].kind);
    try std.testing.expectEqual(id, results.hits[0].id);
    try std.testing.expectEqualStrings(title, results.hits[0].title);
    try std.testing.expectEqualStrings(subtitle, results.hits[0].subtitle);
}

test "inserting, renaming and deleting each searched table keeps its search index row current" {
    var library = try openSearchLibrary("triggers");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES (1, 'Björk', 'Björk', 'bjork');
        \\INSERT INTO releases(id, title, album_artist) VALUES (1, 'Homogenic', 'Björk');
        \\INSERT INTO tracks(id, release_id, title, artist, album) VALUES (1, 1, 'Jóga', 'Björk', 'Homogenic');
        \\INSERT INTO playlists(id, name, description, created_at, updated_at) VALUES (1, 'Morning', 'Quiet ones', 0, 0);
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Art Pop', 'art pop');
    );
    try expectIndexRow(&library, .artist, 1, "Björk", "");
    try expectIndexRow(&library, .release, 1, "Homogenic", "Björk");
    try expectIndexRow(&library, .track, 1, null, "");
    try expectIndexRow(&library, .playlist, 1, "Morning", "Quiet ones");
    try expectIndexRow(&library, .genre, 1, "Art Pop", "");
    try expectTrackHit(&library, "joga", 1, "Jóga", "Björk Homogenic");
    try expectHits(&library, "bjork", .{}, &.{
        .{ .kind = .artist, .id = 1 },
        .{ .kind = .release, .id = 1 },
        .{ .kind = .track, .id = 1 },
    });

    try library.database.exec(
        \\UPDATE artists SET name = 'Bjork Gudmundsdottir' WHERE id = 1;
        \\UPDATE releases SET title = 'Vespertine', album_artist = 'Guðmundsdóttir' WHERE id = 1;
        \\UPDATE tracks SET title = 'Hidden Place', artist = 'Guðmundsdóttir', album = 'Vespertine' WHERE id = 1;
        \\UPDATE playlists SET name = 'Evening', description = 'Loud ones' WHERE id = 1;
        \\UPDATE genres SET name = 'Electronic', key = 'electronic' WHERE id = 1;
    );
    try expectIndexRow(&library, .artist, 1, "Bjork Gudmundsdottir", "");
    try expectIndexRow(&library, .release, 1, "Vespertine", "Guðmundsdóttir");
    try expectIndexRow(&library, .playlist, 1, "Evening", "Loud ones");
    try expectIndexRow(&library, .genre, 1, "Electronic", "");
    try expectTrackHit(&library, "hidden place", 1, "Hidden Place", "Guðmundsdóttir Vespertine");
    try expectHits(&library, "joga", .{}, &.{});
    try expectHits(&library, "homogenic", .{}, &.{});
    try expectHits(&library, "morning", .{}, &.{});
    try expectHits(&library, "evening", .{}, &.{.{ .kind = .playlist, .id = 1 }});

    try library.database.exec(
        \\DELETE FROM tracks WHERE id = 1;
        \\DELETE FROM releases WHERE id = 1;
        \\DELETE FROM artists WHERE id = 1;
        \\DELETE FROM playlists WHERE id = 1;
        \\DELETE FROM genres WHERE id = 1;
    );
    inline for (std.meta.fields(SearchKind)) |field| {
        try expectIndexRow(&library, @field(SearchKind, field.name), 1, null, "");
    }
    try std.testing.expectEqual(@as(i64, 0), try scalar(&library, "SELECT count(*) FROM search_index;"));
    try expectHits(&library, "hidden", .{}, &.{});
    try library.database.exec("INSERT INTO track_search(track_search, rank) VALUES ('integrity-check', 1);");
}

fn scalar(library: *LibraryDatabase, sql: [:0]const u8) !i64 {
    var statement = try library.database.prepare(sql);
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return statement.columnInt64(0);
}

fn trackIndexBlocks(library: *LibraryDatabase) ![]u8 {
    var statement = try library.database.prepare("SELECT group_concat(id || ':' || hex(block), ',') FROM track_search_data;");
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return std.testing.allocator.dupe(u8, statement.columnText(0));
}

test "updating a column the search index does not hold leaves the index row untouched" {
    var library = try openSearchLibrary("unindexed-updates");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES (1, 'Aminé', 'Aminé', 'amine');
        \\INSERT INTO releases(id, title, album_artist) VALUES (1, 'Limbo', 'Aminé');
        \\INSERT INTO tracks(id, release_id, title, artist, album, album_artist) VALUES (1, 1, 'Woodlawn', 'Aminé', 'Limbo', 'Aminé');
        \\INSERT INTO playlists(id, name, description, created_at, updated_at) VALUES (1, 'Morning', '', 0, 0);
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Hip Hop', 'hip hop');
    );
    const blocks = try trackIndexBlocks(&library);
    defer std.testing.allocator.free(blocks);
    try library.database.exec(
        \\UPDATE search_index SET title = 'sentinel';
        \\UPDATE artists SET sort_name = 'Amine', musicbrainz_artist_id = 'x' WHERE id = 1;
        \\UPDATE releases SET release_date = '2020', disc_count = 1 WHERE id = 1;
        \\UPDATE tracks SET duration_ms = 1000, track_number = 3, preferred_file_id = NULL, explicit = 1 WHERE id = 1;
        \\UPDATE tracks SET title = 'Woodlawn', artist = 'Aminé', album = 'Limbo', album_artist = 'Aminé' WHERE id = 1;
        \\UPDATE playlists SET pinned_at = 5, updated_at = 6 WHERE id = 1;
        \\UPDATE genres SET key = 'hiphop' WHERE id = 1;
    );
    try std.testing.expectEqual(@as(i64, 4), try scalar(&library, "SELECT count(*) FROM search_index WHERE title = 'sentinel';"));
    const unchanged = try trackIndexBlocks(&library);
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings(blocks, unchanged);

    try library.database.exec("UPDATE tracks SET album_artist = 'Amine' WHERE id = 1;");
    const changed = try trackIndexBlocks(&library);
    defer std.testing.allocator.free(changed);
    try std.testing.expect(!std.mem.eql(u8, blocks, changed));
}

test "a search folds diacritics and matches each word as a prefix of a word" {
    var library = try openSearchLibrary("folding");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES
        \\    (1, 'Sigur Rós', 'Sigur Rós', 'sigur ros'), (2, 'Aminé', 'Aminé', 'amine'), (3, 'Rosalía', 'Rosalía', 'rosalia');
    );
    try expectHits(&library, "sigur ros", .{}, &.{.{ .kind = .artist, .id = 1 }});
    try expectHits(&library, "amin", .{}, &.{.{ .kind = .artist, .id = 2 }});
    try expectHits(&library, "AMINE", .{}, &.{.{ .kind = .artist, .id = 2 }});
    try expectHits(&library, "ros sig", .{}, &.{.{ .kind = .artist, .id = 1 }});
    try expectHits(&library, "osal", .{}, &.{});
    try expectHits(&library, "  \t ", .{}, &.{});
}

test "a search returns at most each kind's cap, in kind order, most relevant first" {
    var library = try openSearchLibrary("caps");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES
        \\    (1, 'Blue Moon', 'a', 'a'), (2, 'Blue', 'b', 'b'), (3, 'Blue Blue Sky Cloud', 'c', 'c');
        \\INSERT INTO releases(id, title, album_artist) VALUES (1, 'Kind of Blue', 'Miles'), (2, 'Red', 'Blue');
        \\INSERT INTO tracks(id, title, artist, album) VALUES (1, 'Blue', 'X', 'Y'), (2, 'Green', 'Blue', 'Y'), (3, 'Bluer', 'X', 'Y');
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Blues', 'blues');
    );
    try expectHits(&library, "blue", .{ .artists = 2, .releases = 1, .tracks = 3, .playlists = 4, .genres = 0 }, &.{
        .{ .kind = .artist, .id = 2 },
        .{ .kind = .artist, .id = 3 },
        .{ .kind = .release, .id = 1 },
        .{ .kind = .track, .id = 1 },
        .{ .kind = .track, .id = 3 },
        .{ .kind = .track, .id = 2 },
    });
    try expectHits(&library, "blue", .{ .artists = 0, .releases = 0, .tracks = 0, .playlists = 0, .genres = 0 }, &.{});
    try std.testing.expectError(error.InvalidSearchLimits, library.search.find(std.testing.allocator, "blue", .{ .tracks = 51 }));
    var text: [max_search_text + 1]u8 = @splat('a');
    try std.testing.expectError(error.SearchTextTooLong, library.search.find(std.testing.allocator, &text, .{}));
    var longest = try library.search.find(std.testing.allocator, text[0..max_search_text], .{});
    longest.deinit();
}

test "a Track whose title holds every word whole outranks one whose title words only begin with them, which outranks an artist or album match" {
    var library = try openSearchLibrary("track-tiers");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO tracks(id, title, artist, album, album_artist) VALUES
        \\    (1, 'Album Track', 'Am', 'Y', 'Z'), (2, 'Amsterdam', 'X', 'Y', 'Z'), (3, 'Quiet', 'X', 'Americana', 'Z'),
        \\    (4, 'Here I Am', 'X', 'Y', 'Z'), (5, 'Elsewhere', 'X', 'Y', 'Amos'), (6, 'Am I Blue', 'X', 'Y', 'Z');
    );
    var results = try library.search.find(std.testing.allocator, "am", .{});
    defer results.deinit();
    const expected = [_]struct { id: i64, rank: f32 }{
        .{ .id = 4, .rank = 0 }, .{ .id = 6, .rank = 0 }, .{ .id = 2, .rank = 1 }, .{ .id = 1, .rank = 2 }, .{ .id = 3, .rank = 2 },
    };
    try std.testing.expectEqual(expected.len, results.hits.len);
    for (expected, results.hits) |want, hit| {
        try std.testing.expectEqual(SearchKind.track, hit.kind);
        try std.testing.expectEqual(want.id, hit.id);
        try std.testing.expectEqual(want.rank, hit.rank);
    }
    const tracks_only: SearchLimits = .{ .artists = 0, .releases = 0, .tracks = 1, .playlists = 0, .genres = 0 };
    try expectHits(&library, "am", tracks_only, &.{.{ .kind = .track, .id = 4 }});
    try expectHits(&library, "am here", .{}, &.{.{ .kind = .track, .id = 4 }});
    try expectHits(&library, "amst", .{}, &.{.{ .kind = .track, .id = 2 }});
    try expectHits(&library, "am blu", .{}, &.{.{ .kind = .track, .id = 6 }});
    try expectHits(&library, "amos", .{}, &.{});
}

test "quotes, stars, operators and brackets in search text are matched as text, never as FTS5 syntax" {
    var library = try openSearchLibrary("hostile");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES
        \\    (1, 'Near "Quoted" Star*', 'a', 'a'), (2, 'Or And Not', 'b', 'b'), (3, 'Re-Mix (Live)', 'c', 'c'),
        \\    (4, 'Plain', 'd', 'd');
    );
    try expectHits(&library, "NEAR", .{}, &.{.{ .kind = .artist, .id = 1 }});
    try expectHits(&library, "\"quoted\"", .{}, &.{.{ .kind = .artist, .id = 1 }});
    try expectHits(&library, "star*", .{}, &.{.{ .kind = .artist, .id = 1 }});
    try expectHits(&library, "OR", .{}, &.{.{ .kind = .artist, .id = 2 }});
    try expectHits(&library, "or and not", .{}, &.{.{ .kind = .artist, .id = 2 }});
    try expectHits(&library, "NOT plain", .{}, &.{});
    try expectHits(&library, "re-mix", .{}, &.{.{ .kind = .artist, .id = 3 }});
    try expectHits(&library, "(live)", .{}, &.{.{ .kind = .artist, .id = 3 }});
    try expectHits(&library, "- mix", .{}, &.{.{ .kind = .artist, .id = 3 }});
    for ([_][]const u8{ "\"", "\"\"", "*", "-", "(", ")", "^", ":", "NEAR(", "a\"b", "kind:1", "title:plain", "{title}", "\xff\xfe", "\u{2014}" }) |text| {
        var results = try library.search.find(std.testing.allocator, text, .{});
        results.deinit();
    }
    try expectHits(&library, "title:plain", .{}, &.{});

    var expression: [max_match_expression]u8 = undefined;
    var single_letters: [max_search_text]u8 = undefined;
    for (&single_letters, 0..) |*byte, index| byte.* = if (index % 2 == 0) 'a' else ' ';
    try std.testing.expect(try matchExpression(&expression, &single_letters) != null);
    var quotes: [max_search_text]u8 = @splat('"');
    quotes[0] = 'a';
    try std.testing.expect(try matchExpression(&expression, &quotes) != null);
}
