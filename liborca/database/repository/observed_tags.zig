const std = @import("std");
const sqlite = @import("../sqlite.zig");
const metadata = @import("../../metadata/model.zig");
const columns = @import("../columns.zig");

const countColumn = columns.countColumn;
const dupeNullable = columns.dupeNullable;
const optionalCount = columns.optionalCount;
const presentText = columns.presentText;
const WriteLane = @import("write_lane.zig").WriteLane;

/// Observed tags as the readers produce them, addressed by file identity.
///
/// The tag set is `metadata.ObservedTags` verbatim: anything a reader can
/// report is storable, because the previous schema silently dropped every
/// field it had no column for — including the MusicBrainz release id, which is
/// the strongest key the projection has for grouping files into a Release.
pub const ObservedTagsInput = struct {
    file_id: i64,
    values: metadata.ObservedTags,
};

/// Stored observed tags plus the arena their text lives in, mirroring
/// `library.tag_reader.Tags` so a round trip costs the caller one `deinit`.
pub const StoredObservedTags = struct {
    arena: *std.heap.ArenaAllocator,
    values: metadata.ObservedTags,

    pub fn deinit(self: StoredObservedTags) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

/// Observed tags for one file: what the file itself says, nothing resolved.
///
/// Every field `metadata.ObservedTags` can carry has a column, because the
/// previous path-keyed table stored four of them and discarded the rest at this
/// boundary. Genres are the one multi-valued field, and they get their own
/// ordinal-keyed child table rather than a delimiter-packed string: order and
/// multiplicity survive a round trip exactly, and "every file tagged Ambient"
/// stays an indexable query instead of a substring match.
pub const ObservedTagsRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn upsert(self: *ObservedTagsRepository, input: ObservedTagsInput) !void {
        return self.upsertBatch(&.{input});
    }

    pub fn upsertBatch(self: *ObservedTagsRepository, inputs: []const ObservedTagsInput) !void {
        if (inputs.len == 0) return;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try self.upsertBatchLocked(inputs);
        try self.db.exec("COMMIT;");
    }

    /// Same as `upsertBatch` for a caller that already holds the write lane and
    /// an open transaction — a scan batch writes files, locations and tags as
    /// one bounded commit.
    pub fn upsertBatchLocked(
        self: *ObservedTagsRepository,
        inputs: []const ObservedTagsInput,
    ) !void {
        var statement = try self.db.prepare(
            \\INSERT INTO observed_file_tags(
            \\    file_id, title, artist, album, album_artist, composer,
            \\    track_number, track_total, disc_number, disc_total,
            \\    date, original_date, compilation, label, media, isrc,
            \\    release_country, release_type, release_status,
            \\    musicbrainz_recording_id, musicbrainz_release_id,
            \\    musicbrainz_release_group_id, musicbrainz_release_track_id,
            \\    musicbrainz_artist_id, musicbrainz_album_artist_id,
            \\    artwork_mime_type, artwork_byte_size, artwork_kind, explicit, comment, observed_at,
            \\    artwork_width, artwork_height, artwork_hash
            \\) VALUES (
            \\    ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15,
            \\    ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28, ?29, ?30,
            \\    unixepoch(), ?31, ?32, ?33
            \\) ON CONFLICT(file_id) DO UPDATE SET
            \\    title=excluded.title, artist=excluded.artist, album=excluded.album,
            \\    album_artist=excluded.album_artist, composer=excluded.composer,
            \\    track_number=excluded.track_number, track_total=excluded.track_total,
            \\    disc_number=excluded.disc_number, disc_total=excluded.disc_total,
            \\    date=excluded.date, original_date=excluded.original_date,
            \\    compilation=excluded.compilation, label=excluded.label,
            \\    media=excluded.media, isrc=excluded.isrc,
            \\    release_country=excluded.release_country,
            \\    release_type=excluded.release_type,
            \\    release_status=excluded.release_status,
            \\    musicbrainz_recording_id=excluded.musicbrainz_recording_id,
            \\    musicbrainz_release_id=excluded.musicbrainz_release_id,
            \\    musicbrainz_release_group_id=excluded.musicbrainz_release_group_id,
            \\    musicbrainz_release_track_id=excluded.musicbrainz_release_track_id,
            \\    musicbrainz_artist_id=excluded.musicbrainz_artist_id,
            \\    musicbrainz_album_artist_id=excluded.musicbrainz_album_artist_id,
            \\    artwork_mime_type=excluded.artwork_mime_type,
            \\    artwork_byte_size=excluded.artwork_byte_size,
            \\    artwork_kind=excluded.artwork_kind,
            \\    artwork_width=excluded.artwork_width,
            \\    artwork_height=excluded.artwork_height,
            \\    artwork_hash=excluded.artwork_hash,
            \\    explicit=excluded.explicit,
            \\    comment=excluded.comment,
            \\    observed_at=excluded.observed_at;
        );
        defer statement.deinit();
        var delete_genres = try self.db.prepare(
            "DELETE FROM observed_file_genres WHERE file_id=?1;",
        );
        defer delete_genres.deinit();
        var insert_genre = try self.db.prepare(
            "INSERT INTO observed_file_genres(file_id, ordinal, value) VALUES (?1, ?2, ?3);",
        );
        defer insert_genre.deinit();
        for (inputs) |input| {
            const tags = input.values;
            try statement.bindInt64(1, input.file_id);
            try statement.bindOptionalText(2, presentText(tags.title));
            try statement.bindOptionalText(3, presentText(tags.artist));
            try statement.bindOptionalText(4, presentText(tags.album));
            try statement.bindOptionalText(5, presentText(tags.album_artist));
            try statement.bindOptionalText(6, presentText(tags.composer));
            try statement.bindOptionalInt64(7, optionalCount(tags.track_number));
            try statement.bindOptionalInt64(8, optionalCount(tags.track_total));
            try statement.bindOptionalInt64(9, optionalCount(tags.disc_number));
            try statement.bindOptionalInt64(10, optionalCount(tags.disc_total));
            try statement.bindOptionalText(11, presentText(tags.date));
            try statement.bindOptionalText(12, presentText(tags.original_date));
            try statement.bindOptionalInt64(
                13,
                if (tags.compilation) |flag| @intFromBool(flag) else null,
            );
            try statement.bindOptionalText(14, presentText(tags.label));
            try statement.bindOptionalText(15, presentText(tags.media));
            try statement.bindOptionalText(16, presentText(tags.isrc));
            try statement.bindOptionalText(17, presentText(tags.release_country));
            try statement.bindOptionalText(18, presentText(tags.release_type));
            try statement.bindOptionalText(19, presentText(tags.release_status));
            try statement.bindOptionalText(20, presentText(tags.musicbrainz_recording_id));
            try statement.bindOptionalText(21, presentText(tags.musicbrainz_release_id));
            try statement.bindOptionalText(22, presentText(tags.musicbrainz_release_group_id));
            try statement.bindOptionalText(23, presentText(tags.musicbrainz_release_track_id));
            try statement.bindOptionalText(24, presentText(tags.musicbrainz_artist_id));
            try statement.bindOptionalText(25, presentText(tags.musicbrainz_album_artist_id));
            if (tags.artwork) |artwork| {
                try statement.bindText(26, artwork.mime_type);
                try statement.bindInt64(27, @intCast(artwork.byte_size));
                try statement.bindInt64(28, @intFromEnum(artwork.kind));
                try statement.bindOptionalInt64(31, optionalCount(artwork.width));
                try statement.bindOptionalInt64(32, optionalCount(artwork.height));
                try statement.bindOptionalInt64(33, artwork.hash);
            } else {
                try statement.bindOptionalText(26, null);
                try statement.bindOptionalInt64(27, null);
                try statement.bindOptionalInt64(28, null);
                try statement.bindOptionalInt64(31, null);
                try statement.bindOptionalInt64(32, null);
                try statement.bindOptionalInt64(33, null);
            }
            try statement.bindOptionalInt64(29, if (tags.explicit) |advisory| @intFromEnum(advisory) else null);
            try statement.bindOptionalText(30, presentText(tags.comment));
            if (try statement.step() != .done) return error.SqlFailed;
            try statement.reset();

            try delete_genres.bindInt64(1, input.file_id);
            if (try delete_genres.step() != .done) return error.SqlFailed;
            try delete_genres.reset();
            for (tags.genres, 0..) |genre, ordinal| {
                if (genre.len == 0) continue;
                try insert_genre.bindInt64(1, input.file_id);
                try insert_genre.bindInt64(2, @intCast(ordinal));
                try insert_genre.bindText(3, genre);
                if (try insert_genre.step() != .done) return error.SqlFailed;
                try insert_genre.reset();
            }
        }
    }

    pub fn clearLocked(self: *ObservedTagsRepository, file_id: i64) !void {
        var delete_genres = try self.db.prepare(
            "DELETE FROM observed_file_genres WHERE file_id=?1;",
        );
        defer delete_genres.deinit();
        try delete_genres.bindInt64(1, file_id);
        if (try delete_genres.step() != .done) return error.SqlFailed;
        var delete_tags = try self.db.prepare(
            "DELETE FROM observed_file_tags WHERE file_id=?1;",
        );
        defer delete_tags.deinit();
        try delete_tags.bindInt64(1, file_id);
        if (try delete_tags.step() != .done) return error.SqlFailed;
    }

    pub fn get(
        self: *const ObservedTagsRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
    ) !?StoredObservedTags {
        var statement = try self.db.prepare(
            \\SELECT title, artist, album, album_artist, composer,
            \\       track_number, track_total, disc_number, disc_total,
            \\       date, original_date, compilation, label, media, isrc,
            \\       release_country, release_type, release_status,
            \\       musicbrainz_recording_id, musicbrainz_release_id,
            \\       musicbrainz_release_group_id, musicbrainz_release_track_id,
            \\       musicbrainz_artist_id, musicbrainz_album_artist_id,
            \\       artwork_mime_type, artwork_byte_size, artwork_kind, explicit, comment,
            \\       artwork_width, artwork_height, artwork_hash
            \\FROM observed_file_tags WHERE file_id=?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .row) return null;

        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = .init(allocator);
        errdefer arena.deinit();
        const scratch = arena.allocator();
        var values: metadata.ObservedTags = .{
            .title = try dupeNullable(scratch, statement, 0),
            .artist = try dupeNullable(scratch, statement, 1),
            .album = try dupeNullable(scratch, statement, 2),
            .album_artist = try dupeNullable(scratch, statement, 3),
            .composer = try dupeNullable(scratch, statement, 4),
            .track_number = countColumn(statement, 5),
            .track_total = countColumn(statement, 6),
            .disc_number = countColumn(statement, 7),
            .disc_total = countColumn(statement, 8),
            .date = try dupeNullable(scratch, statement, 9),
            .original_date = try dupeNullable(scratch, statement, 10),
            .compilation = if (statement.columnIsNull(11))
                null
            else
                statement.columnInt64(11) != 0,
            .label = try dupeNullable(scratch, statement, 12),
            .media = try dupeNullable(scratch, statement, 13),
            .isrc = try dupeNullable(scratch, statement, 14),
            .release_country = try dupeNullable(scratch, statement, 15),
            .release_type = try dupeNullable(scratch, statement, 16),
            .release_status = try dupeNullable(scratch, statement, 17),
            .musicbrainz_recording_id = try dupeNullable(scratch, statement, 18),
            .musicbrainz_release_id = try dupeNullable(scratch, statement, 19),
            .musicbrainz_release_group_id = try dupeNullable(scratch, statement, 20),
            .musicbrainz_release_track_id = try dupeNullable(scratch, statement, 21),
            .musicbrainz_artist_id = try dupeNullable(scratch, statement, 22),
            .musicbrainz_album_artist_id = try dupeNullable(scratch, statement, 23),
            .explicit = if (statement.columnIsNull(27))
                null
            else
                std.enums.fromInt(metadata.Explicit, statement.columnInt64(27)),
            .comment = try dupeNullable(scratch, statement, 28),
        };
        if (try dupeNullable(scratch, statement, 24)) |mime_type| values.artwork = .{
            .mime_type = mime_type,
            .byte_size = @intCast(statement.columnInt64(25)),
            .kind = std.enums.fromInt(metadata.ArtworkKind, statement.columnInt64(26)) orelse
                .other,
            .width = countColumn(statement, 29),
            .height = countColumn(statement, 30),
            .hash = if (statement.columnIsNull(31)) null else statement.columnInt64(31),
        };
        values.genres = try self.genres(scratch, file_id);
        return .{ .arena = arena, .values = values };
    }

    fn genres(
        self: *const ObservedTagsRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
    ) ![]const []const u8 {
        var statement = try self.db.prepare(
            "SELECT value FROM observed_file_genres WHERE file_id=?1 ORDER BY ordinal;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        var values: std.ArrayList([]const u8) = .empty;
        errdefer values.deinit(allocator);
        while (try statement.step() == .row)
            try values.append(allocator, try allocator.dupe(u8, statement.columnText(0)));
        return values.toOwnedSlice(allocator);
    }

    pub fn count(self: *const ObservedTagsRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM observed_file_tags;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};
