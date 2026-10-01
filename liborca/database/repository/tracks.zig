const std = @import("std");
const sqlite = @import("../sqlite.zig");
const metadata = @import("../../metadata/model.zig");
const quick_hash = @import("../../storage/quick_hash.zig");
const columns = @import("../columns.zig");

const digestColumn = columns.digestColumn;
const max_page = columns.max_page;
const optionalInt64 = columns.optionalInt64;
const Feedback = @import("feedback.zig").Feedback;
const WriteLane = @import("write_lane.zig").WriteLane;

/// The projection's input. A Track is a position on a Release, so this is
/// written by `library/projection.zig` after resolving artists, releases and
/// recordings — never by the scanner, which only observes files.
pub const TrackInput = struct {
    recording_id: ?i64 = null,
    release_id: ?i64 = null,
    /// The Artist row this Track is filed under, resolved from the same key
    /// `ArtistRepository` stores. One primary artist per Track, deliberately —
    /// see the note on migration 9.
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
};

/// Everything playback needs to open a Track's bytes without a second query.
pub const ResolvedLocation = struct {
    allocator: std.mem.Allocator,
    file_id: i64,
    volume_stable_key: []u8,
    uri: []u8,
    audio_format: u8,

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

    pub fn deinit(self: TrackSummary, allocator: std.mem.Allocator) void {
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
/// Every one of these but `rating` names an index created by migration 9, and
/// every ORDER BY they produce ends in `tracks.id`. Both matter. Without the
/// unique tiebreaker a LIMIT/OFFSET walk over a column with ties is free to
/// return one row on two pages and skip a third, because SQLite may order
/// equal keys differently between two evaluations of the same statement.
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
    date_added,
    rating,
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
};

/// One bounded, ordered, filtered request for a page of Tracks.
///
/// A filter is a relational one — `artist_id`, `release_id` — never a text
/// match against the denormalized columns, so an artist browse and an album
/// browse ask the question the schema can actually index.
pub const TrackQuery = struct {
    artist_id: ?i64 = null,
    release_id: ?i64 = null,
    sort: TrackSort = .id,
    direction: SortDirection = .ascending,
    limit: u32 = max_page,
    offset: u32 = 0,
};

pub const TrackRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Upsert by position, because a Track *is* a position on a Release: the
    /// same `(release_id, disc, track)` re-projected must update the row it
    /// already has rather than duplicate it. Rows without a Release or a track
    /// number have no position to collide on and always insert, which is what
    /// `tracks_position` (`COALESCE(track_number, -id)`) encodes.
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
    /// and an open transaction. The projection resolves artists, releases,
    /// recordings and tracks for one folder as a single bounded commit.
    pub fn upsertTracksLocked(self: *TrackRepository, tracks: []const TrackInput) !void {
        if (tracks.len == 0) return;
        var update = try self.db.prepare(
            \\UPDATE tracks SET
            \\    recording_id=?1, title=?2, artist=?3, album=?4, album_artist=?5,
            \\    duration_ms=?6, preferred_file_id=?7, artist_id=?11
            \\WHERE release_id=?8 AND COALESCE(disc_number, 1)=?9 AND track_number=?10;
        );
        defer update.deinit();
        var insert = try self.db.prepare(
            \\INSERT INTO tracks(
            \\    recording_id, release_id, title, artist, album, album_artist,
            \\    duration_ms, track_number, disc_number, preferred_file_id, artist_id
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);
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
            if (try insert.step() != .done) return error.SqlFailed;
            try insert.reset();
        }
    }

    pub fn search(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: u32,
        offset: u32,
    ) !TrackPage {
        var statement = try self.db.prepare(track_columns ++
            "FROM track_search\n" ++
            "JOIN tracks ON tracks.id = track_search.rowid\n" ++
            recording_joins ++
            "WHERE track_search MATCH ?1\n" ++
            "ORDER BY rank\n" ++
            "LIMIT ?2 OFFSET ?3;");
        defer statement.deinit();
        try statement.bindText(1, query);
        try statement.bindInt64(2, limit);
        try statement.bindInt64(3, offset);
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
        const filter: TrackFilter = if (query.artist_id != null and query.release_id != null)
            .artist_and_release
        else if (query.artist_id != null)
            .artist
        else if (query.release_id != null)
            .release
        else
            .none;
        var statement = try self.db.prepare(
            trackQueryText(filter, query.sort, query.direction),
        );
        defer statement.deinit();
        try statement.bindInt64(1, query.limit);
        try statement.bindInt64(2, query.offset);
        if (query.artist_id) |artist_id| try statement.bindInt64(3, artist_id);
        if (query.release_id) |release_id| try statement.bindInt64(4, release_id);
        return collectTrackPage(allocator, statement);
    }

    /// How many Tracks a filtered listing has to page through, so a host can
    /// size a scrollbar without walking the listing.
    /// Counts what `page` would return. It shares `by_artist` with the paged
    /// query rather than restating the predicate, because it had its own copy
    /// and the two drifted the moment the definition of an artist's tracks
    /// widened: the list showed an artist's album tracks while the count above
    /// it said zero. Parameter positions match `buildTrackQuery` for the same
    /// reason.
    pub fn countMatching(self: *const TrackRepository, query: TrackQuery) !u64 {
        var statement = try self.db.prepare(
            "SELECT count(*) FROM tracks\n" ++
                "WHERE (?3 IS NULL OR " ++ by_artist ++ ")\n" ++
                "  AND (?4 IS NULL OR tracks.release_id = ?4);",
        );
        defer statement.deinit();
        try statement.bindOptionalInt64(3, query.artist_id);
        try statement.bindOptionalInt64(4, query.release_id);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn recordingMbid(self: *const TrackRepository, allocator: std.mem.Allocator, track_id: i64) !?RecordingMbid {
        return self.musicBrainzId(allocator, track_id, .musicbrainz_recording_id);
    }

    /// One MusicBrainz ID of the file a Track plays, resolved under
    /// `prefer_file` from Orca's value and the file's tag of the same name.
    pub fn musicBrainzId(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
        comptime field: metadata.Field,
    ) !?RecordingMbid {
        const field_number = std.fmt.comptimePrint("{d}", .{@intFromEnum(field)});
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
            \\SELECT locations.file_id, volumes.stable_key, locations.uri, files.audio_format
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
        };
    }

    /// The recorded facts of the file a Track resolves to, or null when the
    /// Track does not exist or has no file. One row: nothing on disk is read.
    pub fn fileFacts(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
    ) !?TrackFileFacts {
        var statement = try self.db.prepare(
            \\SELECT files.id, files.codec, files.size_bytes, files.sample_rate,
            \\       files.bit_depth, files.channels, files.duration_ms, files.quick_hash,
            \\       (SELECT locations.uri FROM locations
            \\        WHERE locations.file_id = files.id AND locations.state <> 'missing'
            \\        ORDER BY CASE locations.state WHEN 'present' THEN 0 ELSE 1 END, locations.id
            \\        LIMIT 1),
            \\       COALESCE(observed_file_tags.artwork_byte_size, 0) > 0
            \\           AND observed_file_tags.artwork_mime_type IS NOT NULL,
            \\       releases.release_date, releases.is_compilation
            \\FROM tracks
            \\JOIN files ON files.id = COALESCE(
            \\    tracks.preferred_file_id,
            \\    (SELECT id FROM files WHERE recording_id = tracks.recording_id ORDER BY id LIMIT 1)
            \\)
            \\LEFT JOIN observed_file_tags ON observed_file_tags.file_id = files.id
            \\LEFT JOIN releases ON releases.id = tracks.release_id
            \\WHERE tracks.id = ?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
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
            .path = path,
            .has_artwork = statement.columnInt64(9) != 0,
            .release_date = release_date,
            .compilation = if (statement.columnIsNull(11)) null else statement.columnInt64(11) != 0,
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
    \\SELECT tracks.id, tracks.title, tracks.artist, tracks.album, tracks.album_artist,
    \\       tracks.duration_ms, tracks.track_number, tracks.disc_number,
    \\       EXISTS(
    \\           SELECT 1 FROM locations
    \\           WHERE locations.file_id = tracks.preferred_file_id
    \\             AND locations.state <> 'missing'
    \\       ),
    \\       tracks.release_id, tracks.artist_id, COALESCE(feedback.score, 0), tracks.recording_id,
    \\       ratings.rating
    \\
;

pub const recording_joins =
    "LEFT JOIN feedback ON feedback.recording_id = tracks.recording_id\n" ++
    "LEFT JOIN ratings ON ratings.recording_id = tracks.recording_id\n";

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
        .date_added => "tracks.created_at" ++ suffix ++ tiebreak,
        .rating => "ratings.rating IS NULL, ratings.rating" ++ suffix ++ tiebreak,
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

/// What it means for a Release to be an artist's, mirroring `by_artist`.
///
/// Theirs as album artist, *or* carrying a track credited to them, so a
/// featured-only artist's release list is not empty beside their tracks.
pub const by_release_artist =
    "(releases.album_artist_id = ?3 OR releases.id IN " ++
    "(SELECT release_id FROM tracks WHERE tracks.artist_id = ?3))";

fn buildTrackQuery(
    comptime filter: TrackFilter,
    comptime sort: TrackSort,
    comptime direction: SortDirection,
) [:0]const u8 {
    const where = switch (filter) {
        .none => "",
        .artist => "WHERE " ++ by_artist ++ "\n",
        .release => "WHERE tracks.release_id = ?4\n",
        .artist_and_release => "WHERE " ++ by_artist ++ " AND tracks.release_id = ?4\n",
    };
    return track_columns ++ "FROM tracks\n" ++ recording_joins ++ where ++
        "ORDER BY " ++ orderTerms(sort, direction) ++ "\nLIMIT ?1 OFFSET ?2;";
}

/// Every (filter, sort, direction) combination as its own prepared-once
/// statement text. There are 64 of them; concatenating SQL at runtime instead
/// would mean an allocation and a string the caller could influence, and this
/// boundary refuses both on principle.
fn trackQueryText(
    filter: TrackFilter,
    sort: TrackSort,
    direction: SortDirection,
) [:0]const u8 {
    return switch (filter) {
        inline else => |resolved_filter| switch (sort) {
            inline else => |resolved_sort| switch (direction) {
                inline else => |resolved_direction| comptime buildTrackQuery(
                    resolved_filter,
                    resolved_sort,
                    resolved_direction,
                ),
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
    };
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

const recording_mbid_field = std.fmt.comptimePrint("{d}", .{@intFromEnum(metadata.Field.musicbrainz_recording_id)});

/// A locked Orca value, else the file's tag, else an Orca value: the order
/// `TrackRepository.recordingMbid` applies through `metadata.resolveValue`.
/// The two must agree, or details and sync name different recordings.
pub fn effectiveRecordingMbid(comptime file_id: []const u8) []const u8 {
    return "COALESCE(" ++
        "(SELECT NULLIF(value, '') FROM orca_metadata_values WHERE orca_metadata_values.file_id = " ++ file_id ++
        " AND orca_metadata_values.field = " ++ recording_mbid_field ++ " AND orca_metadata_values.locked = 1), " ++
        "(SELECT NULLIF(musicbrainz_recording_id, '') FROM observed_file_tags WHERE observed_file_tags.file_id = " ++ file_id ++ "), " ++
        "(SELECT NULLIF(value, '') FROM orca_metadata_values WHERE orca_metadata_values.file_id = " ++ file_id ++
        " AND orca_metadata_values.field = " ++ recording_mbid_field ++ "))";
}
