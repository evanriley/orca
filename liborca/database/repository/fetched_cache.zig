const std = @import("std");
const sqlite = @import("../sqlite.zig");
const WriteLane = @import("write_lane.zig").WriteLane;

/// The bytes of provider data a Library keeps, by kind. Nothing here was
/// read from a file or chosen by a person, so all of it can be fetched again.
pub const CacheSize = struct {
    /// Cover Art Archive covers of Releases and of release groups.
    artwork_bytes: u64 = 0,
    /// Wikimedia Commons photos of Artists and of related artists.
    photo_bytes: u64 = 0,
    /// LRCLIB lyrics.
    lyrics_bytes: u64 = 0,
    /// Artist and Release descriptions, links, related artists, release
    /// groups and listener counts.
    info_bytes: u64 = 0,

    pub fn total(self: CacheSize) u64 {
        return self.artwork_bytes + self.photo_bytes + self.lyrics_bytes + self.info_bytes;
    }
};

const local_photo = "(photo IS NOT NULL AND photo_source = 0)";

const artist_info_text =
    "COALESCE(length(CAST(wikidata_id AS BLOB)), 0) + COALESCE(length(CAST(artist_type AS BLOB)), 0) + " ++
    "COALESCE(length(CAST(biography AS BLOB)), 0) + COALESCE(length(CAST(biography_url AS BLOB)), 0) + " ++
    "COALESCE(length(CAST(biography_licence AS BLOB)), 0) + COALESCE(length(CAST(origin AS BLOB)), 0)";

const cache_size_sql =
    "SELECT\n" ++
    "  (SELECT COALESCE(sum(length(image)), 0) FROM release_artwork) +\n" ++
    "  (SELECT COALESCE(sum(length(image)), 0) FROM release_group_covers),\n" ++
    "  (SELECT COALESCE(sum(length(photo)), 0) FROM artist_info WHERE NOT " ++ local_photo ++ ") +\n" ++
    "  (SELECT COALESCE(sum(length(photo)), 0) FROM related_artist_photos),\n" ++
    "  (SELECT COALESCE(sum(COALESCE(length(CAST(synced AS BLOB)), 0) + COALESCE(length(CAST(plain AS BLOB)), 0)), 0)\n" ++
    "     FROM track_lyrics),\n" ++
    "  (SELECT COALESCE(sum(" ++ artist_info_text ++ "), 0) FROM artist_info) +\n" ++
    "  (SELECT COALESCE(sum(COALESCE(length(CAST(description AS BLOB)), 0) + COALESCE(length(CAST(description_url AS BLOB)), 0)\n" ++
    "     + COALESCE(length(CAST(description_licence AS BLOB)), 0)), 0) FROM release_info) +\n" ++
    "  (SELECT COALESCE(sum(length(CAST(url AS BLOB))), 0) FROM artist_links) +\n" ++
    "  (SELECT COALESCE(sum(length(CAST(related_mbid AS BLOB)) + length(CAST(related_name AS BLOB))), 0) FROM artist_related) +\n" ++
    "  (SELECT COALESCE(sum(length(CAST(mbid AS BLOB)) + length(CAST(title AS BLOB))\n" ++
    "     + COALESCE(length(CAST(primary_type AS BLOB)), 0) + COALESCE(length(CAST(credited_with AS BLOB)), 0)), 0)\n" ++
    "     FROM artist_release_groups);";

/// An Artist whose photo is a copy of an image in its folder keeps the row
/// that holds it, with everything fetched taken out and `fetched_at` zero so
/// the next look fetches again.
const clear_sql =
    "BEGIN IMMEDIATE;\n" ++
    "DELETE FROM release_artwork;\n" ++
    "DELETE FROM release_group_covers;\n" ++
    "DELETE FROM related_artist_photos;\n" ++
    "DELETE FROM track_lyrics;\n" ++
    "DELETE FROM release_info;\n" ++
    "DELETE FROM artist_links;\n" ++
    "DELETE FROM artist_related;\n" ++
    "DELETE FROM artist_release_groups;\n" ++
    "DELETE FROM artist_info WHERE NOT " ++ local_photo ++ ";\n" ++
    "UPDATE artist_info SET wikidata_id = NULL, begin_year = NULL, end_year = NULL, ended = 0,\n" ++
    "    artist_type = NULL, biography = NULL, biography_source = NULL, biography_url = NULL,\n" ++
    "    biography_licence = NULL, biography_language = NULL, requested_language = NULL,\n" ++
    "    listeners = NULL, listeners_fetched_at = NULL, origin = NULL, fetched_at = 0;\n" ++
    "COMMIT;";

/// Provider data kept in the Library: what `CacheSize` counts.
pub const FetchedCacheRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn size(self: *const FetchedCacheRepository) !CacheSize {
        var statement = try self.db.prepare(cache_size_sql);
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return .{
            .artwork_bytes = @intCast(statement.columnInt64(0)),
            .photo_bytes = @intCast(statement.columnInt64(1)),
            .lyrics_bytes = @intCast(statement.columnInt64(2)),
            .info_bytes = @intCast(statement.columnInt64(3)),
        };
    }

    /// Deletes every fetched cover, photo, lyric and description in one
    /// transaction, and returns what they held. Embedded and folder images,
    /// local lyrics and anything a person chose live elsewhere and stay.
    pub fn clear(self: *FetchedCacheRepository) !CacheSize {
        self.write_lane.acquire();
        defer self.write_lane.release();
        const before = try self.size();
        self.db.exec(clear_sql) catch |err| {
            self.db.exec("ROLLBACK;") catch {};
            return err;
        };
        return before;
    }
};

const LibraryDatabase = @import("../library.zig").LibraryDatabase;

fn scalar(db: sqlite.Database, sql: [:0]const u8) !i64 {
    var statement = try db.prepare(sql);
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return statement.columnInt64(0);
}

test "clearing the cache removes fetched covers, photos, lyrics and info, and keeps folder artist photos and folder covers" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-fetched-cache?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name, key) VALUES (1, 'Fetched', 'Fetched', 'fetched'), (2, 'Folder', 'Folder', 'folder');
        \\INSERT INTO releases(id, title, has_folder_cover) VALUES (1, 'Covered', 1);
        \\INSERT INTO tracks(id, release_id, title) VALUES (1, 1, 'Song');
        \\INSERT INTO release_artwork(release_id, musicbrainz_release_id, image, mime, fetched_at) VALUES (1, 'r', x'0102030405', 'image/jpeg', 1);
        \\INSERT INTO release_group_covers(mbid, image, mime, fetched_at) VALUES ('g', x'010203', 'image/jpeg', 1);
        \\INSERT INTO artist_release_groups(artist_id, mbid, title, position) VALUES (1, 'g', 'Away', 0);
        \\INSERT INTO artist_info(artist_id, biography, photo, photo_mime, photo_source, fetched_at, outcome) VALUES
        \\    (1, 'bio', x'01020304', 'image/jpeg', 1, 1, 0),
        \\    (2, 'text', x'0102', 'image/png', 0, 1, 0);
        \\INSERT INTO related_artist_photos(musicbrainz_artist_id, photo, photo_mime, photo_source, fetched_at) VALUES ('m', x'01', 'image/jpeg', 1, 1);
        \\INSERT INTO artist_links(artist_id, kind, url) VALUES (1, 0, 'https://a');
        \\INSERT INTO artist_related(artist_id, ordinal, related_mbid, related_name, score) VALUES (1, 0, 'm', 'Other', 1);
        \\INSERT INTO release_info(release_id, description, fetched_at, outcome) VALUES (1, 'about', 1, 0);
        \\INSERT INTO track_lyrics(track_id, query_digest, synced, plain, fetched_at) VALUES (1, x'00', '[00:01]la', 'la', 1);
    );

    const before = try library.fetched_cache.size();
    try std.testing.expectEqual(@as(u64, 8), before.artwork_bytes);
    try std.testing.expectEqual(@as(u64, 5), before.photo_bytes);
    try std.testing.expectEqual(@as(u64, 11), before.lyrics_bytes);
    try std.testing.expectEqual(@as(u64, 3 + 4 + 5 + 9 + 1 + 5 + 1 + 4), before.info_bytes);

    try std.testing.expectEqual(before, try library.fetched_cache.clear());

    try std.testing.expectEqual(CacheSize{}, try library.fetched_cache.size());
    try std.testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT count(*) FROM release_artwork;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT count(*) FROM track_lyrics;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM artist_info;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT length(photo) FROM artist_info WHERE artist_id = 2 AND biography IS NULL AND fetched_at = 0;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT has_folder_cover FROM releases WHERE id = 1;"));
}
