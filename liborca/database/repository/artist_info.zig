const std = @import("std");
const sqlite = @import("../sqlite.zig");
const metadata = @import("../../metadata/model.zig");
const columns = @import("../columns.zig");
const text_key = @import("../text_key.zig");

const max_page = columns.max_page;
const WriteLane = @import("write_lane.zig").WriteLane;
const track_play_file = @import("tracks.zig").track_play_file;
const release_group_mbid_field = std.fmt.comptimePrint("{d}", .{@backingInt(metadata.Field.musicbrainz_release_group_id)});

pub const PhotoSource = enum(u8) { local = 0, commons = 1 };
pub const BiographySource = enum(u8) { wikipedia = 0 };

/// Where an artist link points. Stored by number in `artist_links.kind`;
/// append only.
pub const ArtistLinkKind = enum(u8) {
    official = 0,
    wikipedia = 1,
    wikidata = 2,
    musicbrainz = 3,
    discogs = 4,
    lastfm = 5,
    bandcamp = 6,
    soundcloud = 7,
    youtube = 8,
    spotify = 9,
    apple_music = 10,
    tidal = 11,
    deezer = 12,
    instagram = 13,
    x = 14,
    facebook = 15,
    tiktok = 16,
    other = 17,
};

pub const ArtistLink = struct {
    kind: ArtistLinkKind,
    url: []const u8,
};

/// At most this many links are kept per Artist.
pub const max_links = 64;

/// One `artist_info` row without the photo bytes. Strings are borrowed when
/// writing and owned by `ArtistInfo` when read.
pub const ArtistInfoRecord = struct {
    musicbrainz_artist_id: ?[]const u8 = null,
    wikidata_id: ?[]const u8 = null,
    begin_year: ?i32 = null,
    end_year: ?i32 = null,
    ended: bool = false,
    artist_type: ?[]const u8 = null,
    biography: ?[]const u8 = null,
    biography_source: ?BiographySource = null,
    biography_url: ?[]const u8 = null,
    biography_licence: ?[]const u8 = null,
    biography_language: ?[]const u8 = null,
    /// The Wikipedia language the fetch asked for; `biography_language`
    /// differs when it fell back to English.
    requested_language: ?[]const u8 = null,
    /// Null when no photo is stored.
    photo_source: ?PhotoSource = null,
    photo_url: ?[]const u8 = null,
    photo_licence: ?[]const u8 = null,
    photo_licence_url: ?[]const u8 = null,
    photo_credit: ?[]const u8 = null,
    /// Unix seconds.
    fetched_at: i64 = 0,
    /// `core.artist_info.Outcome`, by number.
    outcome: u8 = 0,
    /// ListenBrainz's count of distinct listeners. Read only: `store`
    /// leaves it, and `storeListenBrainz` writes it.
    listeners: ?u64 = null,
    /// Unix seconds of the last ListenBrainz refresh that fully succeeded.
    listeners_fetched_at: ?i64 = null,
    origin: ?[]const u8 = null,
};

pub const max_release_groups = 200;

/// A MusicBrainz release group credited to an Artist, for
/// `storeReleaseGroups`. Strings are borrowed.
pub const ReleaseGroupRecord = struct {
    mbid: []const u8,
    title: []const u8,
    primary_type: ?[]const u8 = null,
    first_release_year: ?i32 = null,
    /// The credit's other artists as MusicBrainz shows them; null when the
    /// Artist is credited alone.
    credited_with: ?[]const u8 = null,
};

/// What `release_group_covers` holds for a release group.
pub const ReleaseGroupCoverState = enum { not_fetched, none, kept };

/// A release group's kept cover row, without the image.
pub const ReleaseGroupCoverMark = struct {
    has_image: bool,
    /// Unix seconds.
    fetched_at: i64,
};

/// A MusicBrainz release group of an Artist. Caller-owned.
pub const ElsewhereRelease = struct {
    mbid: []u8,
    title: []u8,
    primary_type: ?[]u8,
    year: ?i32,
    credited_with: ?[]u8,
    /// A Release of the Artist in the Library from this release group;
    /// always null from `elsewhere`, which leaves those groups out.
    library_release_id: ?i64,
    cover: ReleaseGroupCoverState = .not_fetched,

    pub fn deinit(self: ElsewhereRelease, allocator: std.mem.Allocator) void {
        allocator.free(self.mbid);
        allocator.free(self.title);
        if (self.primary_type) |text| allocator.free(text);
        if (self.credited_with) |text| allocator.free(text);
    }
};

/// At most this many related artists are kept per Artist.
pub const max_related = 12;

pub const RelatedArtistRecord = struct {
    mbid: []const u8,
    name: []const u8,
    score: u32,
};

pub const RelatedArtist = struct {
    mbid: []const u8,
    name: []const u8,
    score: u32,
    /// The library's Artist with this MusicBrainz ID or, failing that, this
    /// folded name.
    library_artist_id: ?i64,
    /// Whether a photo is kept: the library Artist's when
    /// `library_artist_id` is set, otherwise the one `relatedPhoto` reads.
    has_photo: bool,
};

pub const RelatedArtists = struct {
    arena: std.heap.ArenaAllocator,
    items: []RelatedArtist,

    pub fn deinit(self: *RelatedArtists) void {
        self.arena.deinit();
    }
};

/// What `storeListenBrainz` changes; a null field is left as stored.
pub const ListenBrainzUpdate = struct {
    listeners: ?ListenersChange = null,
    /// Replaces the related artists; past `max_related` are dropped.
    related: ?[]const RelatedArtistRecord = null,
    /// Unix seconds.
    fetched_at: ?i64 = null,
};

pub const ListenersChange = union(enum) {
    unknown,
    count: u64,
};

/// A caller-owned `ArtistInfoRecord`.
pub const ArtistInfo = struct {
    arena: std.heap.ArenaAllocator,
    record: ArtistInfoRecord,

    pub fn deinit(self: *ArtistInfo) void {
        self.arena.deinit();
    }
};

pub const ArtistLinks = struct {
    arena: std.heap.ArenaAllocator,
    items: []ArtistLink,

    pub fn deinit(self: *ArtistLinks) void {
        self.arena.deinit();
    }
};

pub const ArtistInfoPhoto = struct {
    bytes: []const u8,
    mime_type: []const u8,
};

/// Where a related artist's kept photo came from and the credit it needs.
/// Strings are borrowed when writing and owned by `RelatedArtistPhotoInfo`
/// when read.
pub const RelatedArtistPhotoRecord = struct {
    source: PhotoSource = .commons,
    /// The photo's Commons page.
    url: ?[]const u8 = null,
    licence: ?[]const u8 = null,
    licence_url: ?[]const u8 = null,
    credit: ?[]const u8 = null,
    /// Unix seconds; set when read, and `storeRelatedPhoto` takes it apart.
    fetched_at: i64 = 0,
};

/// A caller-owned `RelatedArtistPhotoRecord`.
pub const RelatedArtistPhotoInfo = struct {
    arena: std.heap.ArenaAllocator,
    record: RelatedArtistPhotoRecord,

    pub fn deinit(self: *RelatedArtistPhotoInfo) void {
        self.arena.deinit();
    }
};

/// A related artist's photo with where it came from, for
/// `storeRelatedPhoto`.
pub const RelatedArtistPhoto = struct {
    image: ArtistInfoPhoto,
    record: RelatedArtistPhotoRecord,
};

/// What `store` does to the photo columns. `keep` leaves the stored photo
/// and its source, URL, licence and credit as they are.
pub const PhotoChange = union(enum) {
    keep,
    clear,
    set: ArtistInfoPhoto,
};

/// A folder holding one present file of one of an Artist's Releases, and
/// the root that file was found under.
pub const ReleaseFolder = struct {
    uri: []const u8,
    root_path: []const u8,
};

pub const ReleaseFolders = struct {
    arena: std.heap.ArenaAllocator,
    items: []ReleaseFolder,

    pub fn deinit(self: *ReleaseFolders) void {
        self.arena.deinit();
    }
};

pub const ArtistSubject = struct {
    musicbrainz_artist_id: ?[36]u8 = null,
};

/// At most this many Releases are looked at to find an Artist's folder.
pub const max_release_folders = 64;

pub const ArtistInfoRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn get(self: *const ArtistInfoRepository, allocator: std.mem.Allocator, artist_id: i64) !?ArtistInfo {
        var statement = try self.db.prepare(
            \\SELECT musicbrainz_artist_id, wikidata_id, begin_year, end_year, ended, artist_type,
            \\    biography, biography_source, biography_url, biography_licence, biography_language,
            \\    CASE WHEN photo IS NULL THEN NULL ELSE photo_source END,
            \\    photo_url, photo_licence, photo_licence_url, photo_credit, fetched_at, outcome, requested_language,
            \\    listeners, listeners_fetched_at, origin
            \\FROM artist_info WHERE artist_id=?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, artist_id);
        if (try statement.step() != .row) return null;
        var info: ArtistInfo = .{ .arena = .init(allocator), .record = .{} };
        errdefer info.deinit();
        const arena = info.arena.allocator();
        info.record = .{
            .musicbrainz_artist_id = try optionalText(arena, statement, 0),
            .wikidata_id = try optionalText(arena, statement, 1),
            .begin_year = optionalYear(statement, 2),
            .end_year = optionalYear(statement, 3),
            .ended = statement.columnInt64(4) != 0,
            .artist_type = try optionalText(arena, statement, 5),
            .biography = try optionalText(arena, statement, 6),
            .biography_source = optionalEnum(BiographySource, statement, 7),
            .biography_url = try optionalText(arena, statement, 8),
            .biography_licence = try optionalText(arena, statement, 9),
            .biography_language = try optionalText(arena, statement, 10),
            .photo_source = optionalEnum(PhotoSource, statement, 11),
            .photo_url = try optionalText(arena, statement, 12),
            .photo_licence = try optionalText(arena, statement, 13),
            .photo_licence_url = try optionalText(arena, statement, 14),
            .photo_credit = try optionalText(arena, statement, 15),
            .fetched_at = statement.columnInt64(16),
            .outcome = std.math.cast(u8, statement.columnInt64(17)) orelse 0,
            .requested_language = try optionalText(arena, statement, 18),
            .listeners = if (statement.columnIsNull(19)) null else std.math.cast(u64, statement.columnInt64(19)),
            .listeners_fetched_at = if (statement.columnIsNull(20)) null else statement.columnInt64(20),
            .origin = try optionalText(arena, statement, 21),
        };
        return info;
    }

    /// Writes an Artist's row and, when `new_links` is not null, replaces its
    /// links, in one transaction. Links past `max_links` are dropped.
    pub fn store(
        self: *ArtistInfoRepository,
        artist_id: i64,
        record: *const ArtistInfoRecord,
        photo_change: PhotoChange,
        new_links: ?[]const ArtistLink,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var statement = try self.db.prepare(
            \\INSERT INTO artist_info(artist_id, musicbrainz_artist_id, wikidata_id, begin_year, end_year, ended,
            \\    artist_type, biography, biography_source, biography_url, biography_licence, biography_language,
            \\    photo, photo_mime, photo_source, photo_url, photo_licence, photo_licence_url, photo_credit,
            \\    fetched_at, outcome, requested_language, origin)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?23, ?24)
            \\ON CONFLICT(artist_id) DO UPDATE SET
            \\    musicbrainz_artist_id=excluded.musicbrainz_artist_id, wikidata_id=excluded.wikidata_id,
            \\    begin_year=excluded.begin_year, end_year=excluded.end_year, ended=excluded.ended,
            \\    artist_type=excluded.artist_type, biography=excluded.biography,
            \\    biography_source=excluded.biography_source, biography_url=excluded.biography_url,
            \\    biography_licence=excluded.biography_licence, biography_language=excluded.biography_language,
            \\    photo=CASE WHEN ?22 THEN excluded.photo ELSE artist_info.photo END,
            \\    photo_mime=CASE WHEN ?22 THEN excluded.photo_mime ELSE artist_info.photo_mime END,
            \\    photo_source=CASE WHEN ?22 THEN excluded.photo_source ELSE artist_info.photo_source END,
            \\    photo_url=CASE WHEN ?22 THEN excluded.photo_url ELSE artist_info.photo_url END,
            \\    photo_licence=CASE WHEN ?22 THEN excluded.photo_licence ELSE artist_info.photo_licence END,
            \\    photo_licence_url=CASE WHEN ?22 THEN excluded.photo_licence_url ELSE artist_info.photo_licence_url END,
            \\    photo_credit=CASE WHEN ?22 THEN excluded.photo_credit ELSE artist_info.photo_credit END,
            \\    fetched_at=excluded.fetched_at, outcome=excluded.outcome,
            \\    requested_language=excluded.requested_language, origin=excluded.origin;
        );
        defer statement.deinit();
        try statement.bindInt64(1, artist_id);
        try statement.bindOptionalText(2, record.musicbrainz_artist_id);
        try statement.bindOptionalText(3, record.wikidata_id);
        try statement.bindOptionalInt64(4, if (record.begin_year) |year| year else null);
        try statement.bindOptionalInt64(5, if (record.end_year) |year| year else null);
        try statement.bindInt64(6, @intFromBool(record.ended));
        try statement.bindOptionalText(7, record.artist_type);
        try statement.bindOptionalText(8, record.biography);
        try statement.bindOptionalInt64(9, if (record.biography_source) |source| @backingInt(source) else null);
        try statement.bindOptionalText(10, record.biography_url);
        try statement.bindOptionalText(11, record.biography_licence);
        try statement.bindOptionalText(12, record.biography_language);
        const new_photo: ?ArtistInfoPhoto = switch (photo_change) {
            .set => |image| image,
            .keep, .clear => null,
        };
        const described = new_photo != null;
        try statement.bindOptionalBlob(13, if (new_photo) |image| image.bytes else null);
        try statement.bindOptionalText(14, if (new_photo) |image| image.mime_type else null);
        try statement.bindOptionalInt64(15, if (described) if (record.photo_source) |source| @backingInt(source) else null else null);
        try statement.bindOptionalText(16, if (described) record.photo_url else null);
        try statement.bindOptionalText(17, if (described) record.photo_licence else null);
        try statement.bindOptionalText(18, if (described) record.photo_licence_url else null);
        try statement.bindOptionalText(19, if (described) record.photo_credit else null);
        try statement.bindInt64(20, record.fetched_at);
        try statement.bindInt64(21, record.outcome);
        try statement.bindInt64(22, @intFromBool(photo_change != .keep));
        try statement.bindOptionalText(23, record.requested_language);
        try statement.bindOptionalText(24, record.origin);
        if (try statement.step() != .done) return error.SqlFailed;

        if (new_links) |replacement| {
            var clear = try self.db.prepare("DELETE FROM artist_links WHERE artist_id=?1;");
            defer clear.deinit();
            try clear.bindInt64(1, artist_id);
            if (try clear.step() != .done) return error.SqlFailed;
            var insert = try self.db.prepare(
                "INSERT INTO artist_links(artist_id, kind, url) VALUES (?1, ?2, ?3) ON CONFLICT DO NOTHING;",
            );
            defer insert.deinit();
            for (replacement[0..@min(replacement.len, max_links)]) |link| {
                try insert.bindInt64(1, artist_id);
                try insert.bindInt64(2, @backingInt(link.kind));
                try insert.bindText(3, link.url);
                if (try insert.step() != .done) return error.SqlFailed;
                try insert.reset();
            }
        }
        try self.db.exec("COMMIT;");
    }

    /// Writes what ListenBrainz said of an Artist whose row `store` wrote,
    /// in one transaction. False when the Artist has no row.
    pub fn storeListenBrainz(self: *ArtistInfoRepository, artist_id: i64, update: ListenBrainzUpdate) !bool {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var statement = try self.db.prepare(
            \\UPDATE artist_info SET
            \\    listeners = CASE WHEN ?2 THEN ?3 ELSE listeners END,
            \\    listeners_fetched_at = COALESCE(?4, listeners_fetched_at)
            \\WHERE artist_id = ?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, artist_id);
        try statement.bindInt64(2, @intFromBool(update.listeners != null));
        const count: ?i64 = if (update.listeners) |change| switch (change) {
            .unknown => null,
            .count => |value| std.math.cast(i64, value) orelse std.math.maxInt(i64),
        } else null;
        try statement.bindOptionalInt64(3, count);
        try statement.bindOptionalInt64(4, update.fetched_at);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() == 0) {
            try self.db.exec("ROLLBACK;");
            return false;
        }
        if (update.related) |replacement| {
            var clear = try self.db.prepare("DELETE FROM artist_related WHERE artist_id=?1;");
            defer clear.deinit();
            try clear.bindInt64(1, artist_id);
            if (try clear.step() != .done) return error.SqlFailed;
            var insert = try self.db.prepare(
                "INSERT INTO artist_related(artist_id, ordinal, related_mbid, related_name, score) VALUES (?1, ?2, ?3, ?4, ?5);",
            );
            defer insert.deinit();
            for (replacement[0..@min(replacement.len, max_related)], 0..) |related_artist, ordinal| {
                try insert.bindInt64(1, artist_id);
                try insert.bindInt64(2, @intCast(ordinal));
                try insert.bindText(3, related_artist.mbid);
                try insert.bindText(4, related_artist.name);
                try insert.bindInt64(5, related_artist.score);
                if (try insert.step() != .done) return error.SqlFailed;
                try insert.reset();
            }
        }
        try self.db.exec("COMMIT;");
        return true;
    }

    /// Replaces an Artist's release groups, in one transaction. Groups past
    /// `max_release_groups` are dropped. A group no Artist keeps any more
    /// loses its cover.
    pub fn storeReleaseGroups(self: *ArtistInfoRepository, artist_id: i64, groups: []const ReleaseGroupRecord) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var mark = try self.db.prepare("UPDATE artist_release_groups SET position = -1 - position WHERE artist_id=?1;");
        defer mark.deinit();
        try mark.bindInt64(1, artist_id);
        if (try mark.step() != .done) return error.SqlFailed;
        var insert = try self.db.prepare(
            \\INSERT INTO artist_release_groups(artist_id, mbid, title, primary_type, first_release_year, credited_with, position)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            \\ON CONFLICT(artist_id, mbid) DO UPDATE SET title=excluded.title, primary_type=excluded.primary_type,
            \\    first_release_year=excluded.first_release_year, credited_with=excluded.credited_with,
            \\    position=excluded.position
            \\WHERE artist_release_groups.position < 0;
        );
        defer insert.deinit();
        for (groups[0..@min(groups.len, max_release_groups)], 0..) |group, position| {
            try insert.bindInt64(1, artist_id);
            try insert.bindText(2, group.mbid);
            try insert.bindText(3, group.title);
            try insert.bindOptionalText(4, group.primary_type);
            try insert.bindOptionalInt64(5, if (group.first_release_year) |year| year else null);
            try insert.bindOptionalText(6, group.credited_with);
            try insert.bindInt64(7, @intCast(position));
            if (try insert.step() != .done) return error.SqlFailed;
            try insert.reset();
        }
        var sweep = try self.db.prepare("DELETE FROM artist_release_groups WHERE artist_id=?1 AND position < 0;");
        defer sweep.deinit();
        try sweep.bindInt64(1, artist_id);
        if (try sweep.step() != .done) return error.SqlFailed;
        try self.db.exec("COMMIT;");
    }

    /// An Artist's kept Album and EP release groups, compared without case,
    /// that none of its Releases or appearances in the Library belongs to,
    /// newest first. A Release belongs to a group its release info, a file's
    /// tags or an accepted value names, compared without case. Singles,
    /// other types and groups with no type are stored but not listed.
    pub fn elsewhere(self: *const ArtistInfoRepository, allocator: std.mem.Allocator, artist_id: i64) ![]ElsewhereRelease {
        var statement = try self.db.prepare(
            \\WITH artist_releases(id) AS (
            \\    SELECT id FROM releases WHERE album_artist_id = ?1
            \\    UNION SELECT release_id FROM tracks WHERE artist_id = ?1 AND release_id IS NOT NULL),
            \\artist_files(release_id, file_id) AS (
            \\    SELECT tracks.release_id,
            \\
        ++ track_play_file ++
            \\
            \\    FROM tracks WHERE tracks.release_id IN artist_releases),
            \\library_groups(release_id, mbid) AS (
            \\    SELECT release_id, musicbrainz_release_group_id FROM release_info
            \\        WHERE release_id IN artist_releases AND musicbrainz_release_group_id IS NOT NULL
            \\    UNION ALL
            \\    SELECT artist_files.release_id, observed_file_tags.musicbrainz_release_group_id FROM artist_files
            \\        JOIN observed_file_tags ON observed_file_tags.file_id = artist_files.file_id
            \\        WHERE observed_file_tags.musicbrainz_release_group_id IS NOT NULL
            \\    UNION ALL
            \\    SELECT artist_files.release_id, orca_metadata_values.value FROM artist_files
            \\        JOIN orca_metadata_values ON orca_metadata_values.file_id = artist_files.file_id
            \\            AND orca_metadata_values.field =
        ++ release_group_mbid_field ++
            \\)
            \\SELECT groups.mbid, title, primary_type, first_release_year, credited_with,
            \\    CASE WHEN covers.mbid IS NULL THEN 0 WHEN covers.image IS NULL THEN 1 ELSE 2 END
            \\FROM artist_release_groups AS groups LEFT JOIN release_group_covers AS covers ON covers.mbid = groups.mbid
            \\WHERE artist_id = ?1 AND groups.primary_type COLLATE NOCASE IN ('Album', 'EP') AND NOT EXISTS (
            \\    SELECT 1 FROM library_groups WHERE library_groups.mbid = groups.mbid COLLATE NOCASE)
            \\ORDER BY first_release_year IS NULL, first_release_year DESC, position
            \\LIMIT ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, artist_id);
        try statement.bindInt64(2, max_release_groups);
        var items: std.ArrayList(ElsewhereRelease) = .empty;
        errdefer {
            for (items.items) |item| item.deinit(allocator);
            items.deinit(allocator);
        }
        while (try statement.step() == .row) {
            try items.ensureUnusedCapacity(allocator, 1);
            const mbid = try allocator.dupe(u8, statement.columnText(0));
            errdefer allocator.free(mbid);
            const title = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(title);
            const primary_type = try optionalOwnedText(allocator, statement, 2);
            errdefer if (primary_type) |text| allocator.free(text);
            const credited_with = try optionalOwnedText(allocator, statement, 4);
            items.appendAssumeCapacity(.{
                .mbid = mbid,
                .title = title,
                .primary_type = primary_type,
                .year = optionalYear(statement, 3),
                .credited_with = credited_with,
                .library_release_id = null,
                .cover = std.enums.fromInt(ReleaseGroupCoverState, statement.columnInt64(5)) orelse .not_fetched,
            });
        }
        return items.toOwnedSlice(allocator);
    }

    /// An Artist's related artists, the highest scores first, each matched
    /// to a library Artist by MusicBrainz ID or folded name.
    pub fn related(self: *const ArtistInfoRepository, allocator: std.mem.Allocator, artist_id: i64) !RelatedArtists {
        var result: RelatedArtists = .{ .arena = .init(allocator), .items = &.{} };
        errdefer result.deinit();
        const arena = result.arena.allocator();
        var statement = try self.db.prepare(
            "SELECT related_mbid, related_name, score FROM artist_related WHERE artist_id=?1 ORDER BY ordinal LIMIT ?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, artist_id);
        try statement.bindInt64(2, max_related);
        var by_mbid = try self.db.prepare(
            "SELECT id FROM artists WHERE musicbrainz_artist_id = ?1 COLLATE NOCASE AND id <> ?2 ORDER BY id LIMIT 1;",
        );
        defer by_mbid.deinit();
        var by_key = try self.db.prepare("SELECT id FROM artists WHERE key = ?1 AND id <> ?2;");
        defer by_key.deinit();
        var library_photo = try self.db.prepare(
            "SELECT 1 FROM artist_info WHERE artist_id = ?1 AND photo IS NOT NULL;",
        );
        defer library_photo.deinit();
        var related_photo = try self.db.prepare(
            "SELECT 1 FROM related_artist_photos WHERE musicbrainz_artist_id = ?1 AND photo IS NOT NULL;",
        );
        defer related_photo.deinit();
        var items: std.ArrayList(RelatedArtist) = .empty;
        while (try statement.step() == .row) {
            const mbid = try arena.dupe(u8, statement.columnText(0));
            const name = try arena.dupe(u8, statement.columnText(1));
            var library_artist_id: ?i64 = null;
            try by_mbid.bindText(1, mbid);
            try by_mbid.bindInt64(2, artist_id);
            if (try by_mbid.step() == .row) library_artist_id = by_mbid.columnInt64(0);
            try by_mbid.reset();
            if (library_artist_id == null) {
                const key = try text_key.normalizeKey(arena, name);
                try by_key.bindText(1, key);
                try by_key.bindInt64(2, artist_id);
                if (try by_key.step() == .row) library_artist_id = by_key.columnInt64(0);
                try by_key.reset();
            }
            const has_photo = if (library_artist_id) |id| found: {
                try library_photo.bindInt64(1, id);
                defer library_photo.reset() catch {};
                break :found try library_photo.step() == .row;
            } else found: {
                try related_photo.bindText(1, mbid);
                defer related_photo.reset() catch {};
                break :found try related_photo.step() == .row;
            };
            try items.append(arena, .{
                .mbid = mbid,
                .name = name,
                .score = std.math.cast(u32, statement.columnInt64(2)) orelse 0,
                .library_artist_id = library_artist_id,
                .has_photo = has_photo,
            });
        }
        result.items = items.items;
        return result;
    }

    pub fn photo(self: *const ArtistInfoRepository, allocator: std.mem.Allocator, artist_id: i64) !?metadata.EmbeddedImage {
        var statement = try self.db.prepare("SELECT photo FROM artist_info WHERE artist_id=?1 AND photo IS NOT NULL;");
        defer statement.deinit();
        try statement.bindInt64(1, artist_id);
        if (try statement.step() != .row) return null;
        const bytes = try allocator.dupe(u8, statement.columnBlob(0));
        return metadata.adoptImage(allocator, bytes, .other) catch {
            allocator.free(bytes);
            return null;
        };
    }

    /// The photo kept for a related artist by MusicBrainz artist ID, compared
    /// without case; null when none is kept or it was found to have none.
    pub fn relatedPhoto(self: *const ArtistInfoRepository, allocator: std.mem.Allocator, mbid: []const u8) !?metadata.EmbeddedImage {
        var statement = try self.db.prepare(
            "SELECT photo FROM related_artist_photos WHERE musicbrainz_artist_id = ?1 AND photo IS NOT NULL;",
        );
        defer statement.deinit();
        try statement.bindText(1, mbid);
        if (try statement.step() != .row) return null;
        const bytes = try allocator.dupe(u8, statement.columnBlob(0));
        return metadata.adoptImage(allocator, bytes, .other) catch {
            allocator.free(bytes);
            return null;
        };
    }

    /// Where the photo kept for a related artist came from and its credit;
    /// null when none is kept or it was found to have none.
    pub fn relatedPhotoInfo(self: *const ArtistInfoRepository, allocator: std.mem.Allocator, mbid: []const u8) !?RelatedArtistPhotoInfo {
        var statement = try self.db.prepare(
            \\SELECT photo_source, photo_url, photo_licence, photo_licence_url, photo_credit, fetched_at
            \\FROM related_artist_photos WHERE musicbrainz_artist_id = ?1 AND photo IS NOT NULL;
        );
        defer statement.deinit();
        try statement.bindText(1, mbid);
        if (try statement.step() != .row) return null;
        var info: RelatedArtistPhotoInfo = .{ .arena = .init(allocator), .record = .{} };
        errdefer info.deinit();
        const arena = info.arena.allocator();
        info.record = .{
            .source = optionalEnum(PhotoSource, statement, 0) orelse .commons,
            .url = try optionalText(arena, statement, 1),
            .licence = try optionalText(arena, statement, 2),
            .licence_url = try optionalText(arena, statement, 3),
            .credit = try optionalText(arena, statement, 4),
            .fetched_at = statement.columnInt64(5),
        };
        return info;
    }

    /// When `storeRelatedPhoto` last wrote the related artist's row, photo
    /// or not, in Unix seconds; null when it never did.
    pub fn relatedPhotoFetchedAt(self: *const ArtistInfoRepository, mbid: []const u8) !?i64 {
        var statement = try self.db.prepare(
            "SELECT fetched_at FROM related_artist_photos WHERE musicbrainz_artist_id = ?1;",
        );
        defer statement.deinit();
        try statement.bindText(1, mbid);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    /// Keeps a related artist's photo with its source and credit, or with
    /// null remembers that it has none, replacing what was kept.
    pub fn storeRelatedPhoto(self: *ArtistInfoRepository, mbid: []const u8, related_photo: ?*const RelatedArtistPhoto, fetched_at: i64) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO related_artist_photos(musicbrainz_artist_id, photo, photo_mime, photo_source, photo_url,
            \\    photo_licence, photo_licence_url, photo_credit, fetched_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            \\ON CONFLICT(musicbrainz_artist_id) DO UPDATE SET
            \\    photo=excluded.photo, photo_mime=excluded.photo_mime, photo_source=excluded.photo_source,
            \\    photo_url=excluded.photo_url, photo_licence=excluded.photo_licence,
            \\    photo_licence_url=excluded.photo_licence_url, photo_credit=excluded.photo_credit,
            \\    fetched_at=excluded.fetched_at;
        );
        defer statement.deinit();
        try statement.bindText(1, mbid);
        const record: RelatedArtistPhotoRecord = if (related_photo) |kept| kept.record else .{};
        try statement.bindOptionalBlob(2, if (related_photo) |kept| kept.image.bytes else null);
        try statement.bindOptionalText(3, if (related_photo) |kept| kept.image.mime_type else null);
        try statement.bindOptionalInt64(4, if (related_photo != null) @backingInt(record.source) else null);
        try statement.bindOptionalText(5, record.url);
        try statement.bindOptionalText(6, record.licence);
        try statement.bindOptionalText(7, record.licence_url);
        try statement.bindOptionalText(8, record.credit);
        try statement.bindInt64(9, fetched_at);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// The cover kept for a release group by MusicBrainz release group ID;
    /// null when none is kept or the archive had none.
    pub fn releaseGroupCover(self: *const ArtistInfoRepository, allocator: std.mem.Allocator, mbid: []const u8) !?metadata.EmbeddedImage {
        var statement = try self.db.prepare("SELECT image FROM release_group_covers WHERE mbid = ?1 AND image IS NOT NULL;");
        defer statement.deinit();
        try statement.bindText(1, mbid);
        if (try statement.step() != .row) return null;
        const bytes = try allocator.dupe(u8, statement.columnBlob(0));
        return metadata.adoptImage(allocator, bytes, .front_cover) catch {
            allocator.free(bytes);
            return null;
        };
    }

    /// Whether a release group's cover row holds an image and when it was
    /// written; null when no row is kept.
    pub fn releaseGroupCoverMark(self: *const ArtistInfoRepository, mbid: []const u8) !?ReleaseGroupCoverMark {
        var statement = try self.db.prepare("SELECT image IS NOT NULL, fetched_at FROM release_group_covers WHERE mbid = ?1;");
        defer statement.deinit();
        try statement.bindText(1, mbid);
        if (try statement.step() != .row) return null;
        return .{ .has_image = statement.columnInt64(0) != 0, .fetched_at = statement.columnInt64(1) };
    }

    /// Keeps a release group's cover, or with null remembers that the
    /// archive had none, replacing what was kept. Nothing is kept for a group
    /// no Artist keeps.
    pub fn storeReleaseGroupCover(self: *ArtistInfoRepository, mbid: []const u8, image: ?ArtistInfoPhoto, fetched_at: i64) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO release_group_covers(mbid, image, mime, fetched_at)
            \\SELECT ?1, ?2, ?3, ?4 WHERE EXISTS (SELECT 1 FROM artist_release_groups WHERE mbid = ?1)
            \\ON CONFLICT(mbid) DO UPDATE SET image=excluded.image, mime=excluded.mime, fetched_at=excluded.fetched_at;
        );
        defer statement.deinit();
        try statement.bindText(1, mbid);
        try statement.bindOptionalBlob(2, if (image) |kept| kept.bytes else null);
        try statement.bindOptionalText(3, if (image) |kept| kept.mime_type else null);
        try statement.bindInt64(4, fetched_at);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// An Artist's links, by kind and then URL.
    pub fn links(self: *const ArtistInfoRepository, allocator: std.mem.Allocator, artist_id: i64) !ArtistLinks {
        var result: ArtistLinks = .{ .arena = .init(allocator), .items = &.{} };
        errdefer result.deinit();
        const arena = result.arena.allocator();
        var statement = try self.db.prepare(
            "SELECT kind, url FROM artist_links WHERE artist_id=?1 ORDER BY kind, url LIMIT ?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, artist_id);
        try statement.bindInt64(2, max_page);
        var items: std.ArrayList(ArtistLink) = .empty;
        while (try statement.step() == .row) {
            const kind = std.enums.fromInt(ArtistLinkKind, statement.columnInt64(0)) orelse .other;
            try items.append(arena, .{ .kind = kind, .url = try arena.dupe(u8, statement.columnText(1)) });
        }
        result.items = items.items;
        return result;
    }

    /// The Artist's MusicBrainz artist ID, when it has a well-formed one.
    /// Null when there is no such Artist.
    pub fn subject(self: *const ArtistInfoRepository, artist_id: i64) !?ArtistSubject {
        var statement = try self.db.prepare("SELECT musicbrainz_artist_id FROM artists WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, artist_id);
        if (try statement.step() != .row) return null;
        var result: ArtistSubject = .{};
        if (!statement.columnIsNull(0)) {
            const text = statement.columnText(0);
            if (metadata.isMusicBrainzId(text)) result.musicbrainz_artist_id = text[0..36].*;
        }
        return result;
    }

    /// The earliest year a Release the Artist is album artist of was
    /// released, from release dates that begin with a four-digit year.
    pub fn earliestReleaseYear(self: *const ArtistInfoRepository, artist_id: i64) !?i32 {
        var statement = try self.db.prepare(
            \\SELECT min(CAST(substr(release_date, 1, 4) AS INTEGER)) FROM releases
            \\WHERE album_artist_id = ?1 AND substr(release_date, 1, 4) GLOB '[0-9][0-9][0-9][0-9]'
            \\    AND CAST(substr(release_date, 1, 4) AS INTEGER) > 0;
        );
        defer statement.deinit();
        try statement.bindInt64(1, artist_id);
        if (try statement.step() != .row) return null;
        return optionalYear(statement, 0);
    }

    /// One present file's path for each of up to `max_release_folders` of
    /// the Releases the Artist is album artist of.
    pub fn releaseFolders(self: *const ArtistInfoRepository, allocator: std.mem.Allocator, artist_id: i64) !ReleaseFolders {
        var result: ReleaseFolders = .{ .arena = .init(allocator), .items = &.{} };
        errdefer result.deinit();
        const arena = result.arena.allocator();
        var statement = try self.db.prepare(
            \\SELECT locations.uri, library_roots.path FROM (
            \\    SELECT (
            \\        SELECT locations.id FROM tracks
            \\        JOIN locations ON locations.file_id = COALESCE(
            \\            tracks.preferred_file_id,
            \\            (SELECT id FROM files WHERE recording_id = tracks.recording_id ORDER BY id LIMIT 1))
            \\        WHERE tracks.release_id = releases.id AND locations.state = 'present'
            \\        ORDER BY locations.id LIMIT 1) AS location_id
            \\    FROM releases WHERE releases.album_artist_id = ?1 ORDER BY releases.id LIMIT ?2
            \\) AS picked
            \\JOIN locations ON locations.id = picked.location_id
            \\JOIN library_roots ON library_roots.id = locations.root_id
            \\ORDER BY locations.id;
        );
        defer statement.deinit();
        try statement.bindInt64(1, artist_id);
        try statement.bindInt64(2, max_release_folders);
        var items: std.ArrayList(ReleaseFolder) = .empty;
        while (try statement.step() == .row) {
            try items.append(arena, .{
                .uri = try arena.dupe(u8, statement.columnText(0)),
                .root_path = try arena.dupe(u8, statement.columnText(1)),
            });
        }
        result.items = items.items;
        return result;
    }

    /// Whether some present file under `folder` belongs to a Track whose
    /// Release has another album artist, or none.
    pub fn folderHoldsOtherArtists(self: *const ArtistInfoRepository, allocator: std.mem.Allocator, artist_id: i64, folder: []const u8) !bool {
        const trimmed = std.mem.trimEnd(u8, folder, "/");
        const low = try std.mem.concat(allocator, u8, &.{ trimmed, "/" });
        defer allocator.free(low);
        const high = try std.mem.concat(allocator, u8, &.{ trimmed, "0" });
        defer allocator.free(high);
        var statement = try self.db.prepare(
            \\SELECT 1 FROM locations
            \\JOIN files ON files.id = locations.file_id
            \\JOIN tracks ON tracks.recording_id = files.recording_id
            \\LEFT JOIN releases ON releases.id = tracks.release_id
            \\WHERE locations.uri >= ?2 AND locations.uri < ?3 AND locations.state = 'present'
            \\    AND (releases.album_artist_id IS NULL OR releases.album_artist_id <> ?1)
            \\LIMIT 1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, artist_id);
        try statement.bindText(2, low);
        try statement.bindText(3, high);
        return try statement.step() == .row;
    }
};

fn optionalText(arena: std.mem.Allocator, statement: sqlite.Statement, index: c_int) !?[]const u8 {
    if (statement.columnIsNull(index)) return null;
    return try arena.dupe(u8, statement.columnText(index));
}

fn optionalOwnedText(allocator: std.mem.Allocator, statement: sqlite.Statement, index: c_int) !?[]u8 {
    if (statement.columnIsNull(index)) return null;
    return try allocator.dupe(u8, statement.columnText(index));
}

fn optionalYear(statement: sqlite.Statement, index: c_int) ?i32 {
    if (statement.columnIsNull(index)) return null;
    return std.math.cast(i32, statement.columnInt64(index));
}

fn optionalEnum(comptime E: type, statement: sqlite.Statement, index: c_int) ?E {
    if (statement.columnIsNull(index)) return null;
    return std.enums.fromInt(E, statement.columnInt64(index));
}

const LibraryDatabase = @import("../library.zig").LibraryDatabase;

fn openTestLibrary(comptime name: []const u8) !LibraryDatabase {
    return LibraryDatabase.open(std.testing.allocator, std.testing.io, "file:orca-test-artist-info-" ++ name ++ "?mode=memory&cache=shared");
}

test "storing artist info with the photo kept leaves the stored photo and its credit as they were" {
    var library = try openTestLibrary("keep");
    defer library.close();
    const artist = (try library.artists.ensure(.{ .key = "nick drake", .name = "Nick Drake" })).?;
    const png = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 0 };

    try library.artist_info.store(artist, &.{
        .begin_year = 1966,
        .photo_source = .commons,
        .photo_licence = "CC BY 2.0",
        .photo_credit = "A. Photographer",
        .fetched_at = 10,
        .outcome = 1,
    }, .{ .set = .{ .bytes = &png, .mime_type = "image/png" } }, &.{
        .{ .kind = .wikidata, .url = "https://www.wikidata.org/wiki/Q1" },
        .{ .kind = .official, .url = "https://example.org" },
        .{ .kind = .official, .url = "https://example.org" },
    });
    try library.artist_info.store(artist, &.{ .begin_year = 1967, .fetched_at = 20, .outcome = 7 }, .keep, null);

    var info = (try library.artist_info.get(std.testing.allocator, artist)).?;
    defer info.deinit();
    try std.testing.expectEqual(@as(?i32, 1967), info.record.begin_year);
    try std.testing.expectEqual(@as(?PhotoSource, .commons), info.record.photo_source);
    try std.testing.expectEqualStrings("CC BY 2.0", info.record.photo_licence.?);
    try std.testing.expectEqualStrings("A. Photographer", info.record.photo_credit.?);
    try std.testing.expectEqual(@as(u8, 7), info.record.outcome);
    const image = (try library.artist_info.photo(std.testing.allocator, artist)).?;
    defer image.deinit();
    try std.testing.expectEqualStrings("image/png", image.mime_type);
    var links = try library.artist_info.links(std.testing.allocator, artist);
    defer links.deinit();
    try std.testing.expectEqual(@as(usize, 2), links.items.len);
    try std.testing.expectEqual(ArtistLinkKind.official, links.items[0].kind);

    try library.artist_info.store(artist, &.{ .fetched_at = 30, .outcome = 1 }, .clear, &.{});
    var cleared = (try library.artist_info.get(std.testing.allocator, artist)).?;
    defer cleared.deinit();
    try std.testing.expectEqual(@as(?PhotoSource, null), cleared.record.photo_source);
    try std.testing.expectEqual(@as(?[]const u8, null), cleared.record.photo_credit);
    try std.testing.expectEqual(@as(?metadata.EmbeddedImage, null), try library.artist_info.photo(std.testing.allocator, artist));
    var no_links = try library.artist_info.links(std.testing.allocator, artist);
    defer no_links.deinit();
    try std.testing.expectEqual(@as(usize, 0), no_links.items.len);
}

test "ListenBrainz listeners and related artists are kept beside the info and matched to library Artists by MBID or folded name" {
    var library = try openTestLibrary("listenbrainz");
    defer library.close();
    const artist = (try library.artists.ensure(.{ .key = "amine", .name = "Aminé" })).?;
    const smino = (try library.artists.ensure(.{ .key = "smino", .name = "Smino" })).?;
    const saba = (try library.artists.ensure(.{ .key = "saba", .name = "Saba" })).?;
    try library.database.exec("UPDATE artists SET musicbrainz_artist_id='aaaaaaaa-0000-4000-8000-000000000001' WHERE key='saba';");

    try std.testing.expect(!try library.artist_info.storeListenBrainz(artist, .{ .listeners = .{ .count = 9025 } }));
    try library.artist_info.store(artist, &.{ .fetched_at = 10, .outcome = 1 }, .keep, null);
    try std.testing.expect(try library.artist_info.storeListenBrainz(artist, .{
        .listeners = .{ .count = 9025 },
        .related = &.{
            .{ .mbid = "bbbbbbbb-0000-4000-8000-000000000002", .name = "SMINO", .score = 412 },
            .{ .mbid = "AAAAAAAA-0000-4000-8000-000000000001", .name = "Somebody Else", .score = 300 },
            .{ .mbid = "cccccccc-0000-4000-8000-000000000003", .name = "Noname", .score = 201 },
        },
        .fetched_at = 20,
    }));
    try library.artist_info.store(artist, &.{ .fetched_at = 30, .outcome = 1 }, .keep, null);

    var info = (try library.artist_info.get(std.testing.allocator, artist)).?;
    defer info.deinit();
    try std.testing.expectEqual(@as(?u64, 9025), info.record.listeners);
    try std.testing.expectEqual(@as(?i64, 20), info.record.listeners_fetched_at);

    var related_artists = try library.artist_info.related(std.testing.allocator, artist);
    defer related_artists.deinit();
    try std.testing.expectEqual(@as(usize, 3), related_artists.items.len);
    try std.testing.expectEqual(@as(?i64, smino), related_artists.items[0].library_artist_id);
    try std.testing.expectEqual(@as(?i64, saba), related_artists.items[1].library_artist_id);
    try std.testing.expectEqual(@as(?i64, null), related_artists.items[2].library_artist_id);
    try std.testing.expectEqual(@as(u32, 201), related_artists.items[2].score);

    try std.testing.expect(try library.artist_info.storeListenBrainz(artist, .{ .listeners = .unknown }));
    var unknown = (try library.artist_info.get(std.testing.allocator, artist)).?;
    defer unknown.deinit();
    try std.testing.expectEqual(@as(?u64, null), unknown.record.listeners);
    try std.testing.expectEqual(@as(?i64, 20), unknown.record.listeners_fetched_at);
    var kept = try library.artist_info.related(std.testing.allocator, artist);
    defer kept.deinit();
    try std.testing.expectEqual(@as(usize, 3), kept.items.len);
}

test "a related artist's photo is kept with its credit by MusicBrainz ID without case, a marker remembers it has none, and related artists say which have one" {
    var library = try openTestLibrary("related-photo");
    defer library.close();
    const artist = (try library.artists.ensure(.{ .key = "amine", .name = "Aminé" })).?;
    const smino = (try library.artists.ensure(.{ .key = "smino", .name = "Smino" })).?;
    const png = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 0 };
    try library.artist_info.store(artist, &.{ .fetched_at = 10, .outcome = 1 }, .keep, null);
    try library.artist_info.store(smino, &.{ .fetched_at = 10, .outcome = 1 }, .{ .set = .{ .bytes = &png, .mime_type = "image/png" } }, null);
    try std.testing.expect(try library.artist_info.storeListenBrainz(artist, .{
        .related = &.{
            .{ .mbid = "bbbbbbbb-0000-4000-8000-000000000002", .name = "Smino", .score = 412 },
            .{ .mbid = "cccccccc-0000-4000-8000-000000000003", .name = "Noname", .score = 300 },
            .{ .mbid = "dddddddd-0000-4000-8000-000000000004", .name = "Saba", .score = 201 },
        },
        .fetched_at = 20,
    }));

    try std.testing.expectEqual(@as(?i64, null), try library.artist_info.relatedPhotoFetchedAt("cccccccc-0000-4000-8000-000000000003"));
    try library.artist_info.storeRelatedPhoto("CCCCCCCC-0000-4000-8000-000000000003", &.{
        .image = .{ .bytes = &png, .mime_type = "image/png" },
        .record = .{
            .url = "https://commons.wikimedia.org/wiki/File:Noname.jpg",
            .licence = "CC BY-SA 4.0",
            .licence_url = "https://creativecommons.org/licenses/by-sa/4.0",
            .credit = "A. Photographer",
        },
    }, 30);
    try library.artist_info.storeRelatedPhoto("dddddddd-0000-4000-8000-000000000004", null, 40);

    const image = (try library.artist_info.relatedPhoto(std.testing.allocator, "cccccccc-0000-4000-8000-000000000003")).?;
    defer image.deinit();
    try std.testing.expectEqualStrings("image/png", image.mime_type);
    try std.testing.expectEqual(@as(?metadata.EmbeddedImage, null), try library.artist_info.relatedPhoto(std.testing.allocator, "dddddddd-0000-4000-8000-000000000004"));
    var photo_info = (try library.artist_info.relatedPhotoInfo(std.testing.allocator, "cccccccc-0000-4000-8000-000000000003")).?;
    defer photo_info.deinit();
    try std.testing.expectEqual(PhotoSource.commons, photo_info.record.source);
    try std.testing.expectEqualStrings("https://commons.wikimedia.org/wiki/File:Noname.jpg", photo_info.record.url.?);
    try std.testing.expectEqualStrings("CC BY-SA 4.0", photo_info.record.licence.?);
    try std.testing.expectEqualStrings("https://creativecommons.org/licenses/by-sa/4.0", photo_info.record.licence_url.?);
    try std.testing.expectEqualStrings("A. Photographer", photo_info.record.credit.?);
    try std.testing.expectEqual(@as(i64, 30), photo_info.record.fetched_at);
    try std.testing.expectEqual(@as(?RelatedArtistPhotoInfo, null), try library.artist_info.relatedPhotoInfo(std.testing.allocator, "dddddddd-0000-4000-8000-000000000004"));
    try std.testing.expectEqual(@as(?i64, 30), try library.artist_info.relatedPhotoFetchedAt("cccccccc-0000-4000-8000-000000000003"));
    try std.testing.expectEqual(@as(?i64, 40), try library.artist_info.relatedPhotoFetchedAt("DDDDDDDD-0000-4000-8000-000000000004"));

    var related_artists = try library.artist_info.related(std.testing.allocator, artist);
    defer related_artists.deinit();
    try std.testing.expect(related_artists.items[0].has_photo);
    try std.testing.expect(related_artists.items[1].has_photo);
    try std.testing.expect(!related_artists.items[2].has_photo);

    try library.artist_info.storeRelatedPhoto("cccccccc-0000-4000-8000-000000000003", null, 50);
    try std.testing.expectEqual(@as(?metadata.EmbeddedImage, null), try library.artist_info.relatedPhoto(std.testing.allocator, "cccccccc-0000-4000-8000-000000000003"));
    try std.testing.expectEqual(@as(?RelatedArtistPhotoInfo, null), try library.artist_info.relatedPhotoInfo(std.testing.allocator, "cccccccc-0000-4000-8000-000000000003"));
    try std.testing.expectEqual(@as(?i64, 50), try library.artist_info.relatedPhotoFetchedAt("cccccccc-0000-4000-8000-000000000003"));
}

test "an artist's origin is stored and read back with the rest of its info" {
    var library = try openTestLibrary("origin");
    defer library.close();
    const artist = (try library.artists.ensure(.{ .key = "amine", .name = "Aminé" })).?;
    try library.artist_info.store(artist, &.{ .origin = "Portland", .fetched_at = 10, .outcome = 1 }, .keep, null);
    var info = (try library.artist_info.get(std.testing.allocator, artist)).?;
    defer info.deinit();
    try std.testing.expectEqualStrings("Portland", info.record.origin.?);
    try library.artist_info.store(artist, &.{ .fetched_at = 20, .outcome = 1 }, .keep, null);
    var cleared = (try library.artist_info.get(std.testing.allocator, artist)).?;
    defer cleared.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), cleared.record.origin);
}

test "elsewhere leaves out release groups a Release or appearance of the artist names in its release info, a file's tags or an accepted value, without case" {
    var library = try openTestLibrary("elsewhere");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name) VALUES (1, 'Host', 'host'), (2, 'Other', 'other');
        \\INSERT INTO releases(id, title, release_key, album_artist_id) VALUES
        \\    (1, 'Own', 'r1', 1), (2, 'Feature', 'r2', 2), (3, 'Not theirs', 'r3', 2);
        \\INSERT INTO files(id, size_bytes, quick_hash) VALUES (1, 100, x'01'), (2, 100, x'02'), (3, 100, x'03');
        \\INSERT INTO tracks(id, release_id, title, artist_id, preferred_file_id) VALUES
        \\    (1, 1, 'One', 1, 1), (2, 2, 'Guest spot', 1, 2), (3, 3, 'Theirs', 2, 3);
        \\INSERT INTO release_info(release_id, musicbrainz_release_group_id, fetched_at, outcome) VALUES
        \\    (1, '0C1F6A8E-3D5B-4C2A-9E7F-1A2B3C4D5E01', 10, 1);
        \\INSERT INTO observed_file_tags(file_id, musicbrainz_release_group_id) VALUES
        \\    (2, '0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e02'), (3, '0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e04');
    );
    try library.database.exec(std.fmt.comptimePrint(
        "INSERT INTO orca_metadata_values(file_id, field, value, provenance) VALUES (1, {s}, '0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e03', 0);",
        .{release_group_mbid_field},
    ));
    try library.artist_info.storeReleaseGroups(1, &.{
        .{ .mbid = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e01", .title = "Own", .primary_type = "Album", .first_release_year = 2017 },
        .{ .mbid = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e02", .title = "Feature", .primary_type = "Album", .first_release_year = 2018 },
        .{ .mbid = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e03", .title = "Accepted", .primary_type = "Album", .first_release_year = 2019 },
        .{ .mbid = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e04", .title = "Someone else's copy", .primary_type = "Album", .first_release_year = 2020 },
        .{ .mbid = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e05", .title = "Undated", .primary_type = "EP" },
        .{ .mbid = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e06", .title = "Collab", .primary_type = "Album", .first_release_year = 2023, .credited_with = "Kaytranada" },
    });

    const found = try library.artist_info.elsewhere(std.testing.allocator, 1);
    defer {
        for (found) |group| group.deinit(std.testing.allocator);
        std.testing.allocator.free(found);
    }
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("Collab", found[0].title);
    try std.testing.expectEqualStrings("Album", found[0].primary_type.?);
    try std.testing.expectEqual(@as(?i32, 2023), found[0].year);
    try std.testing.expectEqualStrings("Kaytranada", found[0].credited_with.?);
    try std.testing.expectEqual(@as(?i64, null), found[0].library_release_id);
    try std.testing.expectEqualStrings("Someone else's copy", found[1].title);
    try std.testing.expectEqualStrings("Undated", found[2].title);
    try std.testing.expectEqual(@as(?i32, null), found[2].year);

    const none = try library.artist_info.elsewhere(std.testing.allocator, 2);
    defer std.testing.allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "elsewhere lists only Album and EP release groups, without case, and still stores the rest" {
    var library = try openTestLibrary("elsewhere-types");
    defer library.close();
    const host = (try library.artists.ensure(.{ .key = "host", .name = "Host" })).?;
    try library.artist_info.storeReleaseGroups(host, &.{
        .{ .mbid = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e01", .title = "Single", .primary_type = "Single", .first_release_year = 2024 },
        .{ .mbid = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e02", .title = "Album", .primary_type = "Album", .first_release_year = 2020 },
        .{ .mbid = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e03", .title = "Other", .primary_type = "Other", .first_release_year = 2023 },
        .{ .mbid = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e04", .title = "Untyped", .first_release_year = 2022 },
        .{ .mbid = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e05", .title = "Extended", .primary_type = "ep", .first_release_year = 2021 },
    });
    try std.testing.expectEqual(@as(i64, 5), try columns.scalar(library.database, "SELECT count(*) FROM artist_release_groups;"));

    const found = try library.artist_info.elsewhere(std.testing.allocator, host);
    defer {
        for (found) |group| group.deinit(std.testing.allocator);
        std.testing.allocator.free(found);
    }
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("Extended", found[0].title);
    try std.testing.expectEqualStrings("Album", found[1].title);
}

test "replacing an Artist's release groups removes the covers of the groups it drops unless another Artist keeps them, and keeps the rest" {
    var library = try openTestLibrary("release-group-covers");
    defer library.close();
    const host = (try library.artists.ensure(.{ .key = "host", .name = "Host" })).?;
    const guest = (try library.artists.ensure(.{ .key = "guest", .name = "Guest" })).?;
    const kept = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e01";
    const dropped = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e02";
    const shared = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e03";
    const missing = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e04";
    const jpeg: ArtistInfoPhoto = .{ .bytes = "\xff\xd8\xff\xe0JFIF", .mime_type = "image/jpeg" };
    try library.artist_info.storeReleaseGroups(host, &.{
        .{ .mbid = kept, .title = "Kept", .primary_type = "Album" },
        .{ .mbid = dropped, .title = "Dropped", .primary_type = "Album" },
        .{ .mbid = shared, .title = "Shared", .primary_type = "Album" },
        .{ .mbid = missing, .title = "Missing", .primary_type = "Album" },
    });
    try library.artist_info.storeReleaseGroups(guest, &.{.{ .mbid = shared, .title = "Shared", .primary_type = "Album" }});
    for ([_][]const u8{ kept, dropped, shared }) |mbid| try library.artist_info.storeReleaseGroupCover(mbid, jpeg, 10);
    try library.artist_info.storeReleaseGroupCover(missing, null, 10);
    try library.artist_info.storeReleaseGroupCover("0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5eff", jpeg, 10);
    try std.testing.expectEqual(@as(i64, 4), try columns.scalar(library.database, "SELECT count(*) FROM release_group_covers;"));

    const before = try library.artist_info.elsewhere(std.testing.allocator, host);
    defer {
        for (before) |group| group.deinit(std.testing.allocator);
        std.testing.allocator.free(before);
    }
    try std.testing.expectEqual(ReleaseGroupCoverState.kept, before[0].cover);
    try std.testing.expectEqual(ReleaseGroupCoverState.none, before[3].cover);
    try std.testing.expectEqual(ReleaseGroupCoverMark{ .has_image = false, .fetched_at = 10 }, (try library.artist_info.releaseGroupCoverMark(missing)).?);

    try library.artist_info.storeReleaseGroups(host, &.{.{ .mbid = kept, .title = "Kept again" }});
    try std.testing.expectEqual(@as(i64, 2), try columns.scalar(library.database, "SELECT count(*) FROM release_group_covers;"));
    const cover = (try library.artist_info.releaseGroupCover(std.testing.allocator, kept)).?;
    defer cover.deinit();
    try std.testing.expectEqualStrings(jpeg.bytes, cover.bytes);
    try std.testing.expect(try library.artist_info.releaseGroupCover(std.testing.allocator, dropped) == null);
    try std.testing.expect(try library.artist_info.releaseGroupCoverMark(missing) == null);
    try std.testing.expect(try library.artist_info.releaseGroupCoverMark(shared) != null);

    try library.database.exec("DELETE FROM artists;");
    try std.testing.expectEqual(@as(i64, 0), try columns.scalar(library.database, "SELECT count(*) FROM release_group_covers;"));
}

test "storing release groups replaces the artist's, keeps at most the bound, and leaves other artists' alone" {
    var library = try openTestLibrary("release-groups-bound");
    defer library.close();
    const host = (try library.artists.ensure(.{ .key = "host", .name = "Host" })).?;
    const other = (try library.artists.ensure(.{ .key = "other", .name = "Other" })).?;
    var mbids: [max_release_groups + 1][36]u8 = undefined;
    var groups: [max_release_groups + 1]ReleaseGroupRecord = undefined;
    for (&mbids, &groups, 0..) |*mbid, *group, index| {
        _ = std.fmt.bufPrint(mbid, "00000000-0000-4000-8000-{x:0>12}", .{index}) catch unreachable;
        group.* = .{ .mbid = mbid, .title = "Group", .primary_type = "Album" };
    }
    try library.artist_info.storeReleaseGroups(host, &groups);
    try library.artist_info.storeReleaseGroups(other, groups[0..2]);
    const stored = try library.artist_info.elsewhere(std.testing.allocator, host);
    defer {
        for (stored) |group| group.deinit(std.testing.allocator);
        std.testing.allocator.free(stored);
    }
    try std.testing.expectEqual(@as(usize, max_release_groups), stored.len);

    try library.artist_info.storeReleaseGroups(host, groups[5..6]);
    const replaced = try library.artist_info.elsewhere(std.testing.allocator, host);
    defer {
        for (replaced) |group| group.deinit(std.testing.allocator);
        std.testing.allocator.free(replaced);
    }
    try std.testing.expectEqual(@as(usize, 1), replaced.len);
    try std.testing.expectEqualStrings(&mbids[5], replaced[0].mbid);
    const others = try library.artist_info.elsewhere(std.testing.allocator, other);
    defer {
        for (others) |group| group.deinit(std.testing.allocator);
        std.testing.allocator.free(others);
    }
    try std.testing.expectEqual(@as(usize, 2), others.len);
}
