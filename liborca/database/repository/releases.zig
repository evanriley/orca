const std = @import("std");
const sqlite = @import("../sqlite.zig");
const columns = @import("../columns.zig");

const dupeNullable = columns.dupeNullable;
const max_page = columns.max_page;
const optionalInt64 = columns.optionalInt64;
const presentText = columns.presentText;
const by_release_artist = @import("tracks.zig").by_release_artist;
const WriteLane = @import("write_lane.zig").WriteLane;

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
};

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

    pub fn deinit(self: ReleaseSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.album_artist);
        if (self.release_date) |date| allocator.free(date);
    }
};

pub const ReleasePage = struct {
    allocator: std.mem.Allocator,
    items: []ReleaseSummary,

    pub fn deinit(self: ReleasePage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const ReleaseQuery = struct {
    album_artist_id: ?i64 = null,
    sort: ReleaseSort = .title,
    loved_only: bool = false,
    limit: u32 = max_page,
    offset: u32 = 0,
};

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

    fn terms(comptime self: ReleaseSort) []const u8 {
        return switch (self) {
            .title => "releases.title COLLATE NOCASE, releases.id",
            .artist => "releases.album_artist COLLATE NOCASE, releases.release_date IS NULL, " ++
                "releases.release_date, releases.title COLLATE NOCASE, releases.id",
            .year => "releases.release_date IS NULL, releases.release_date DESC, " ++
                "releases.title COLLATE NOCASE, releases.id",
            .recently_added => "releases.id DESC",
            .loved => "release_loves.loved_at IS NULL, release_loves.loved_at DESC, releases.id",
        };
    }
};

const release_columns =
    \\SELECT releases.id, releases.title, releases.album_artist, releases.album_artist_id,
    \\       releases.release_date, releases.is_compilation, releases.disc_count,
    \\       (SELECT count(*) FROM tracks WHERE tracks.release_id = releases.id),
    \\       (SELECT COALESCE(sum(tracks.duration_ms), 0) FROM tracks
    \\        WHERE tracks.release_id = releases.id),
    \\       release_loves.release_id IS NOT NULL
    \\FROM releases
    \\LEFT JOIN release_loves ON release_loves.release_id = releases.id
    \\
;

const by_loved_release = "releases.id IN (SELECT release_id FROM release_loves)";

fn releaseQueryText(comptime sort: ReleaseSort, comptime by_artist: bool, comptime loved_only: bool) [:0]const u8 {
    const artist_terms = if (by_artist) by_release_artist else "";
    const loved_terms = if (loved_only) by_loved_release else "";
    const joiner = if (by_artist and loved_only) " AND " else "";
    const where = if (by_artist or loved_only) "WHERE " ++ artist_terms ++ joiner ++ loved_terms ++ "\n" else "";
    return release_columns ++ where ++ "ORDER BY " ++ comptime sort.terms() ++ "\nLIMIT ?1 OFFSET ?2;";
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
        });
    }
    return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
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
    pub fn upsertLocked(self: *ReleaseRepository, input: ReleaseUpsert) !i64 {
        var statement = try self.db.prepare(
            \\INSERT INTO releases(
            \\    title, album_artist, release_date, is_compilation,
            \\    disc_count, release_key, musicbrainz_release_id, album_artist_id
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
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
            \\    )
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
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
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
                    inline else => |loved_filter| try self.db.prepare(
                        comptime releaseQueryText(sort, artist_filter, loved_filter),
                    ),
                },
            },
        };
        defer statement.deinit();
        try statement.bindInt64(1, query.limit);
        try statement.bindInt64(2, query.offset);
        if (query.album_artist_id) |artist_id| try statement.bindInt64(3, artist_id);
        return collectReleasePage(allocator, statement);
    }

    /// Counts what `page` would return. Shares `by_release_artist` and
    /// `by_loved_release` with it rather than restating the predicate:
    /// `TrackRepository.countMatching` had its own copy and drifted from the
    /// page it counted the moment the definition widened, so the list showed
    /// rows the count above it denied.
    pub fn countMatching(self: *const ReleaseRepository, query: ReleaseQuery) !u64 {
        var statement = try self.db.prepare(
            "SELECT count(*) FROM releases\nWHERE (?3 IS NULL OR " ++ by_release_artist ++ ")\n" ++
                "  AND (?4 = 0 OR " ++ by_loved_release ++ ");",
        );
        defer statement.deinit();
        try statement.bindOptionalInt64(3, query.album_artist_id);
        try statement.bindInt64(4, @intFromBool(query.loved_only));
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn byId(
        self: *const ReleaseRepository,
        allocator: std.mem.Allocator,
        release_id: i64,
    ) !?ReleaseSummary {
        var statement = try self.db.prepare(release_columns ++ "WHERE releases.id = ?1;");
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
