const std = @import("std");
const sqlite = @import("../sqlite.zig");

const WriteLane = @import("write_lane.zig").WriteLane;
const max_page = @import("../columns.zig").max_page;
const scalar = @import("../columns.zig").scalar;
const max_playlist_entries = @import("playlists.zig").max_playlist_entries;
const health = @import("health.zig");
const artwork_problems = @import("artwork_problems.zig");
const HealthIssueKind = health.HealthIssueKind;

pub const LocationState = enum {
    present,
    missing,
    unverified,

    pub fn text(self: LocationState) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) ?LocationState {
        return std.meta.stringToEnum(LocationState, value);
    }
};

pub const LocationUpsert = struct {
    file_id: i64,
    volume_id: i64,
    root_id: ?i64 = null,
    uri: []const u8,
    native_device: ?i64 = null,
    native_inode: ?i64 = null,
    size_bytes: i64 = 0,
    modified_ns: i64 = 0,
    state: LocationState = .present,
    last_seen_generation: i64 = 0,
};

pub const StorageIdentityKey = struct {
    volume_id: i64,
    native_inode: i64,
    size_bytes: i64,
    modified_ns: i64,
};

pub const PresentLocation = struct {
    uri: []u8,
    volume_id: i64,
    root_id: ?i64,
    generation: i64,
};

/// `file` is an audio file; `image` is a picture beside the music.
pub const FolderEntryKind = enum { folder, file, image };

pub const FolderEntryStatus = enum { imported, unreadable };

/// What a picture in a folder shows, by its name: a stem of `cover`, `front`
/// or `folder` is the front cover.
pub const ArtworkRole = enum {
    front,
    back,
    booklet,
    other,

    pub fn ofName(basename: []const u8) ArtworkRole {
        const stem = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot| basename[0..dot] else basename;
        for ([_][]const u8{ "cover", "front", "folder" }) |name|
            if (std.ascii.eqlIgnoreCase(stem, name)) return .front;
        if (std.ascii.eqlIgnoreCase(stem, "back")) return .back;
        if (std.ascii.eqlIgnoreCase(stem, "booklet")) return .booklet;
        return .other;
    }
};

pub const FolderImageUpsert = struct {
    volume_id: i64,
    root_id: ?i64,
    uri: []const u8,
    mime: []const u8,
    role: ArtworkRole,
    size_bytes: i64,
    modified_ns: i64,
    last_seen_generation: i64,
    /// `metadata.image_header`'s measurement of the bytes; a null hash leaves
    /// the image for the property backfill to measure.
    width: ?u32 = null,
    height: ?u32 = null,
    hash: ?i64 = null,
};

/// One child of a folder under a library root. A folder's counts cover every
/// non-missing location below it; a file's describe that one location; an
/// image has no counts.
pub const FolderEntry = struct {
    name: []u8,
    kind: FolderEntryKind,
    /// `unreadable` when the file holds an `unreadable_file` health issue.
    status: FolderEntryStatus,
    /// The Track whose preferred file this is; null for a folder or image.
    track_id: ?i64,
    /// Null for a folder or image.
    file_id: ?i64,
    file_count: u32,
    track_count: u32,
    total_duration_ms: i64,
    /// Images only, sniffed from the bytes.
    mime: ?[]u8,
    /// Images only.
    artwork_role: ?ArtworkRole,
};

pub const FolderPage = struct {
    allocator: std.mem.Allocator,
    items: []FolderEntry,
    /// When a scan last finished walking this folder.
    last_scanned_at: ?i64,
    /// The one Release every Track directly in this folder belongs to; null
    /// when there are none or they belong to more than one.
    release_id: ?i64,
    release_title: ?[]u8,
    release_artist: ?[]u8,
    /// Images directly in this folder.
    image_count: u32,

    pub fn deinit(self: FolderPage) void {
        freeEntries(self.allocator, self.items);
        self.allocator.free(self.items);
        if (self.release_title) |title| self.allocator.free(title);
        if (self.release_artist) |artist| self.allocator.free(artist);
    }
};

fn freeEntries(allocator: std.mem.Allocator, items: []const FolderEntry) void {
    for (items) |item| {
        allocator.free(item.name);
        if (item.mime) |mime| allocator.free(mime);
    }
}

/// A folder path relative to a library root, as the scanner stores it below
/// the root: empty for the root itself, otherwise `/`-separated components
/// with no empty, `.` or `..` component and no NUL.
pub fn validateFolderPath(relative_path: []const u8) !void {
    if (relative_path.len == 0) return;
    if (std.mem.indexOfScalar(u8, relative_path, 0) != null) return error.InvalidFolderPath;
    var components = std.mem.splitScalar(u8, relative_path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, ".."))
            return error.InvalidFolderPath;
    }
}

/// Every location below a folder has a uri in `[prefix, upper)`: `prefix`
/// ends in `/`, and `upper` replaces that `/` with `0`, the byte after it.
const FolderRange = struct {
    root_id: i64,
    volume_id: i64,
    prefix: []u8,
    upper: []u8,

    fn deinit(self: FolderRange, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        allocator.free(self.upper);
    }
};

const folder_filter = "volume_id=?1 AND +root_id=?4 AND state<>'missing' AND uri<?3";
const folder_seek_from_sql = "SELECT uri, file_id FROM locations WHERE " ++ folder_filter ++
    " AND uri>=?2 ORDER BY uri LIMIT 1;";
const folder_seek_after_sql = "SELECT uri, file_id FROM locations WHERE " ++ folder_filter ++
    " AND uri>?2 ORDER BY uri LIMIT 1;";
const folder_totals_sql = "WITH below AS MATERIALIZED (SELECT DISTINCT file_id FROM locations WHERE " ++
    folder_filter ++ " AND uri>=?2)\n" ++
    \\SELECT (SELECT count(*) FROM below),
    \\       (SELECT count(*) FROM below JOIN tracks ON tracks.preferred_file_id=below.file_id),
    \\       (SELECT COALESCE(sum(files.duration_ms), 0) FROM below JOIN files ON files.id=below.file_id);
;
const folder_track_ids_sql =
    "SELECT tracks.id FROM locations JOIN tracks ON tracks.preferred_file_id=locations.file_id WHERE " ++
    "locations.volume_id=?1 AND +locations.root_id=?4 AND locations.state<>'missing'" ++
    " AND locations.uri>=?2 AND locations.uri<?3 ORDER BY locations.uri, tracks.id;";
const folder_images_filter = "volume_id=?1 AND rtrim(uri, replace(uri, '/', ''))=?2 AND +root_id=?3";
const folder_images_sql = "SELECT uri, mime, role FROM folder_images WHERE " ++ folder_images_filter ++
    " ORDER BY uri LIMIT ?4 OFFSET ?5;";
const folder_image_count_sql = "SELECT count(*) FROM folder_images WHERE " ++ folder_images_filter ++ ";";

const under_directory_filter = " WHERE volume_id=?1 AND uri>=?2 || '/' AND uri<?2 || '0' AND +root_id=?3;";
const seen_under_sql = "UPDATE locations SET last_seen_generation=max(last_seen_generation, ?4)" ++ under_directory_filter;
const images_seen_under_sql = "UPDATE folder_images SET last_seen_generation=max(last_seen_generation, ?4)" ++ under_directory_filter;

const front_role = std.fmt.comptimePrint("{d}", .{@backingInt(ArtworkRole.front)});

/// The `(volume_id, folder path)` of the folder holding most of a Release's
/// present preferred files, the lowest path on a tie: the one folder whose
/// front image is the Release's cover. `release_id` is an SQL expression.
inline fn releaseCoverFolderSql(comptime release_id: []const u8) []const u8 {
    return "(SELECT cover_location.volume_id, rtrim(cover_location.uri, replace(cover_location.uri, '/', ''))\n" ++
        "    FROM tracks AS cover_track JOIN locations AS cover_location ON cover_location.file_id = cover_track.preferred_file_id\n" ++
        "    WHERE cover_track.release_id = " ++ release_id ++ " AND cover_location.state <> 'missing'\n" ++
        "    GROUP BY 1, 2 ORDER BY count(DISTINCT cover_track.id) DESC, 2 LIMIT 1)";
}

const folder_image_folder = "(cover_image.volume_id, rtrim(cover_image.uri, replace(cover_image.uri, '/', '')))";

/// True when the Release's cover folder (`releaseCoverFolderSql`) holds a
/// front image, so `releases.has_folder_cover` agrees with the image
/// `releaseFrontImages` returns.
inline fn releaseHasFolderCoverSql(comptime release_id: []const u8) []const u8 {
    return "EXISTS (SELECT 1 FROM folder_images AS cover_image WHERE cover_image.role = " ++ front_role ++
        " AND " ++ folder_image_folder ++ " = " ++ releaseCoverFolderSql(release_id) ++ ")";
}

fn releaseFrontImagesSql(comptime select: []const u8, comptime release_id: []const u8) [:0]const u8 {
    return "SELECT " ++ select ++ " FROM folder_images AS cover_image\n" ++
        "WHERE cover_image.role = " ++ front_role ++ " AND " ++ folder_image_folder ++ " = " ++
        releaseCoverFolderSql(release_id) ++ "\n" ++
        "ORDER BY CASE lower(substr(cover_image.uri,\n" ++
        "        length(rtrim(cover_image.uri, replace(cover_image.uri, '/', ''))) + 1, 5))\n" ++
        "    WHEN 'cover' THEN 0 WHEN 'front' THEN 1 ELSE 2 END,\n" ++
        "    cover_image.size_bytes DESC, cover_image.uri\n" ++
        "LIMIT ?2;";
}

const release_front_images_sql = releaseFrontImagesSql("cover_image.uri", "?1");
const track_release_front_images_sql = releaseFrontImagesSql("cover_image.uri", "(SELECT release_id FROM tracks WHERE id = ?1)");
/// `releaseFrontImages` as the width, height and hash the scan measured.
pub const release_front_measurements_sql = releaseFrontImagesSql("cover_image.width, cover_image.height, cover_image.hash", "?1");
const folder_releases_sql =
    "SELECT DISTINCT tracks.release_id FROM locations JOIN tracks ON tracks.preferred_file_id = locations.file_id\n" ++
    "WHERE locations.uri >= ?2 AND locations.uri < ?3 AND locations.volume_id = ?1\n" ++
    "  AND rtrim(locations.uri, replace(locations.uri, '/', '')) = ?2 AND tracks.release_id IS NOT NULL;";
const refresh_folder_cover_sql =
    "UPDATE releases SET has_folder_cover = " ++ releaseHasFolderCoverSql("releases.id") ++
    " WHERE id = ?1 RETURNING has_folder_cover;";

pub const refresh_swept_folder_covers_sql =
    "UPDATE releases SET has_folder_cover = " ++ releaseHasFolderCoverSql("releases.id") ++
    " WHERE id IN (SELECT id FROM temp.swept_cover_releases);";

/// Recomputes `releases.has_folder_cover` for one Release and returns it.
/// Caller holds the write lane.
pub fn refreshFolderCoverLocked(db: sqlite.Database, release_id: i64) !bool {
    var statement = try db.prepare(refresh_folder_cover_sql);
    defer statement.deinit();
    try statement.bindInt64(1, release_id);
    if (try statement.step() != .row) return false;
    const covered = statement.columnInt64(0) != 0;
    _ = try statement.step();
    return covered;
}

/// Visits a folder's direct children in uri order, one indexed seek per
/// child: a subfolder is reported once and its whole range skipped.
const FolderWalk = struct {
    allocator: std.mem.Allocator,
    range: *const FolderRange,
    seek_from: sqlite.Statement,
    seek_after: sqlite.Statement,
    cursor: std.ArrayList(u8) = .empty,
    cursor_inclusive: bool = true,
    name: std.ArrayList(u8) = .empty,
    file_id: i64 = 0,

    fn init(db: sqlite.Database, allocator: std.mem.Allocator, range: *const FolderRange) !FolderWalk {
        var seek_from = try db.prepare(folder_seek_from_sql);
        errdefer seek_from.deinit();
        const seek_after = try db.prepare(folder_seek_after_sql);
        var walk: FolderWalk = .{
            .allocator = allocator,
            .range = range,
            .seek_from = seek_from,
            .seek_after = seek_after,
        };
        errdefer walk.deinit();
        try walk.cursor.appendSlice(allocator, range.prefix);
        return walk;
    }

    fn deinit(self: *FolderWalk) void {
        self.seek_from.deinit();
        self.seek_after.deinit();
        self.cursor.deinit(self.allocator);
        self.name.deinit(self.allocator);
    }

    /// The next child's kind; its name is in `name` and, for a file, its
    /// file in `file_id`, until the following call.
    fn next(self: *FolderWalk) !?FolderEntryKind {
        while (true) {
            const statement = if (self.cursor_inclusive) &self.seek_from else &self.seek_after;
            try statement.reset();
            try statement.bindInt64(1, self.range.volume_id);
            try statement.bindText(2, self.cursor.items);
            try statement.bindText(3, self.range.upper);
            try statement.bindInt64(4, self.range.root_id);
            if (try statement.step() != .row) return null;
            const found = statement.columnText(0);
            const rest = found[self.range.prefix.len..];
            self.name.clearRetainingCapacity();
            self.cursor.clearRetainingCapacity();
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
                if (slash == 0) {
                    try self.cursor.appendSlice(self.allocator, found);
                    self.cursor_inclusive = false;
                    continue;
                }
                try self.name.appendSlice(self.allocator, rest[0..slash]);
                try self.cursor.appendSlice(self.allocator, found[0 .. self.range.prefix.len + slash]);
                try self.cursor.append(self.allocator, '0');
                self.cursor_inclusive = true;
                return .folder;
            }
            try self.cursor.appendSlice(self.allocator, found);
            self.cursor_inclusive = false;
            if (rest.len == 0) continue;
            try self.name.appendSlice(self.allocator, rest);
            self.file_id = statement.columnInt64(1);
            return .file;
        }
    }
};

pub const LocationRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn upsert(self: *LocationRepository, input: LocationUpsert) !i64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.upsertLocked(input);
    }

    pub fn upsertLocked(self: *LocationRepository, input: LocationUpsert) !i64 {
        // Generations count per root: a stamp is raised within its root and replaced when the root changes.
        var statement = try self.db.prepare(
            \\INSERT INTO locations(
            \\    file_id, volume_id, root_id, uri, native_device, native_inode,
            \\    size_bytes, modified_ns, state, missing_since, last_seen_generation
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, NULL, ?10)
            \\ON CONFLICT(volume_id, uri) DO UPDATE SET
            \\    file_id=excluded.file_id,
            \\    root_id=COALESCE(excluded.root_id, locations.root_id),
            \\    native_device=excluded.native_device,
            \\    native_inode=excluded.native_inode,
            \\    size_bytes=excluded.size_bytes,
            \\    modified_ns=excluded.modified_ns,
            \\    state=excluded.state,
            \\    missing_since=NULL,
            \\    last_seen_generation=CASE WHEN COALESCE(excluded.root_id, locations.root_id) IS locations.root_id
            \\        THEN max(locations.last_seen_generation, excluded.last_seen_generation)
            \\        ELSE excluded.last_seen_generation END
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindInt64(1, input.file_id);
        try statement.bindInt64(2, input.volume_id);
        try statement.bindOptionalInt64(3, input.root_id);
        try statement.bindText(4, input.uri);
        try statement.bindOptionalInt64(5, input.native_device);
        try statement.bindOptionalInt64(6, input.native_inode);
        try statement.bindInt64(7, input.size_bytes);
        try statement.bindInt64(8, input.modified_ns);
        try statement.bindText(9, input.state.text());
        try statement.bindInt64(10, input.last_seen_generation);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    /// Move the unverified locations under a root from the fallback volume onto
    /// the real volume and root a scan just resolved. Without this the
    /// scanner's `(volume_id, uri)` lookup misses those rows and imports their
    /// files again as new ones, orphaning every lock, analysis result and
    /// health issue on the old rows.
    ///
    /// `UPDATE OR IGNORE` because a location may already exist at that URI on
    /// the target volume; the live row wins and the legacy row is left for the
    /// operator to see rather than being destroyed here.
    pub fn claimLegacyLocations(
        self: *LocationRepository,
        legacy_volume_id: i64,
        volume_id: i64,
        root_id: i64,
        root_path: []const u8,
    ) !u64 {
        if (legacy_volume_id == volume_id) return 0;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE OR IGNORE locations SET volume_id=?1, root_id=?2
            \\WHERE volume_id=?3 AND state='unverified'
            \\  AND (uri=?4 OR substr(uri, 1, length(?4) + 1) = ?4 || '/');
        );
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindInt64(2, root_id);
        try statement.bindInt64(3, legacy_volume_id);
        try statement.bindText(4, root_path);
        if (try statement.step() != .done) return error.SqlFailed;
        return self.db.changes();
    }

    /// A move within a volume: the uri changes and `files.id` does not, so
    /// metadata, locks, analysis and health attached to the file survive.
    pub fn move(self: *LocationRepository, location_id: i64, destination: []const u8) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE locations SET uri=?1, state='present', missing_since=NULL
            \\WHERE id=?2;
        );
        defer statement.deinit();
        try statement.bindText(1, destination);
        try statement.bindInt64(2, location_id);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.LocationNotFound;
    }

    pub fn find(self: *const LocationRepository, volume_id: i64, path: []const u8) !?i64 {
        var statement = try self.db.prepare(
            "SELECT id FROM locations WHERE volume_id=?1 AND uri=?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindText(2, path);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    /// Tier 1 of the identity cascade in one query: this path, on this volume,
    /// with the filesystem facts a scan already recorded. A hit means no
    /// format, tag or hash work is needed for this entry at all.
    ///
    /// Only a `present` location can be unchanged. An `unverified` one has
    /// never been confirmed by a scan, so it is re-observed once and promoted
    /// rather than trusted on sight.
    /// The id of the present Location this identity already describes, or null
    /// when the entry is new or its bytes changed. With `root_id`, a location
    /// a scan of that root did not record, such as one `orca-cli analyze`
    /// made, is not unchanged either, so its tags are observed.
    ///
    /// The caller must stamp what this returns through `markSeenLocked`. A scan
    /// that skips an unchanged file without recording that it *saw* it leaves
    /// the Location below the run's generation, and the post-run sweep then
    /// marks a file that is sitting right there as `missing`.
    pub fn unchangedLocationId(
        self: *const LocationRepository,
        volume_id: i64,
        path: []const u8,
        key: StorageIdentityKey,
        root_id: ?i64,
    ) !?i64 {
        var statement = try self.db.prepare(
            \\SELECT id FROM locations
            \\WHERE volume_id=?1 AND uri=?2 AND native_inode=?3
            \\  AND size_bytes=?4 AND modified_ns=?5 AND state='present'
            \\  AND (?6 IS NULL OR root_id=?6);
        );
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindText(2, path);
        try statement.bindInt64(3, key.native_inode);
        try statement.bindInt64(4, key.size_bytes);
        try statement.bindInt64(5, key.modified_ns);
        try statement.bindOptionalInt64(6, root_id);
        return switch (try statement.step()) {
            .row => statement.columnInt64(0),
            .done => null,
        };
    }

    /// Points the location at `path` on `volume_id` at `file_id` as present,
    /// keeping the identity a scan recorded for it. Null when there is none.
    pub fn repointLocked(self: *LocationRepository, volume_id: i64, path: []const u8, file_id: i64) !?i64 {
        var statement = try self.db.prepare(
            \\UPDATE locations SET file_id=?3, state='present', missing_since=NULL
            \\WHERE volume_id=?1 AND uri=?2
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindText(2, path);
        try statement.bindInt64(3, file_id);
        return switch (try statement.step()) {
            .row => statement.columnInt64(0),
            .done => null,
        };
    }

    /// Record that this run reached these Locations, so the sweep does not
    /// mistake them for absent. Caller holds the write lane.
    pub fn markSeenLocked(
        self: *LocationRepository,
        ids: []const i64,
        generation: i64,
    ) !void {
        if (ids.len == 0) return;
        var statement = try self.db.prepare(
            \\UPDATE locations SET last_seen_generation=max(last_seen_generation, ?2) WHERE id=?1;
        );
        defer statement.deinit();
        for (ids) |id| {
            try statement.reset();
            try statement.bindInt64(1, id);
            try statement.bindInt64(2, generation);
            if (try statement.step() != .done) return error.SqlFailed;
        }
    }

    pub fn uri(
        self: *const LocationRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
    ) !?[]u8 {
        var statement = try self.db.prepare(
            "SELECT uri FROM locations WHERE file_id=?1 ORDER BY id LIMIT 1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .row) return null;
        return try allocator.dupe(u8, statement.columnText(0));
    }

    /// The present location at `uri` on any volume, for re-observing a path
    /// the mutation journal names.
    pub fn presentByUri(
        self: *const LocationRepository,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !?PresentLocation {
        var statement = try self.db.prepare(
            \\SELECT uri, volume_id, root_id, last_seen_generation FROM locations
            \\WHERE uri=?1 AND state='present' ORDER BY id LIMIT 1;
        );
        defer statement.deinit();
        try statement.bindText(1, path);
        if (try statement.step() != .row) return null;
        return .{
            .uri = try allocator.dupe(u8, statement.columnText(0)),
            .volume_id = statement.columnInt64(1),
            .root_id = if (statement.columnIsNull(2)) null else statement.columnInt64(2),
            .generation = if (statement.columnIsNull(3)) 0 else statement.columnInt64(3),
        };
    }

    /// Where a file's bytes are now, with the root and generation a scanner
    /// needs to re-observe it in place. Null when no location is present.
    pub fn presentOf(
        self: *const LocationRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
    ) !?PresentLocation {
        var statement = try self.db.prepare(
            \\SELECT uri, volume_id, root_id, last_seen_generation FROM locations
            \\WHERE file_id=?1 AND state='present' ORDER BY id LIMIT 1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .row) return null;
        return .{
            .uri = try allocator.dupe(u8, statement.columnText(0)),
            .volume_id = statement.columnInt64(1),
            .root_id = if (statement.columnIsNull(2)) null else statement.columnInt64(2),
            .generation = if (statement.columnIsNull(3)) 0 else statement.columnInt64(3),
        };
    }

    /// The second path at which Orca holds this file's bytes, when there is
    /// one.
    ///
    /// A byte-identical copy is not a second `files` row: the scanner's
    /// identity cascade joins it to the row that already exists only once
    /// their content hashes are equal, so the Library models it as one file at
    /// two locations. That is still the same audio stored twice, and it is
    /// what a person asking about duplicates means, so the duplicate scan reads
    /// it here rather than pretending the copy does not exist. Two present
    /// locations of one file are therefore bytes confirmed equal, or a path
    /// re-found by uri or by inode, size and mtime, as a hard link is. A copy
    /// whose bytes change is split off into a file of its own and is no longer
    /// a location of this one.
    ///
    /// Only `present` locations count. A file that *moved* leaves a `missing`
    /// row behind and a `present` one ahead, and reporting that pair as a
    /// duplicate would name a path that is not there.
    pub fn secondPresentPath(
        self: *const LocationRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
    ) !?[]u8 {
        var statement = try self.db.prepare(
            "SELECT uri FROM locations WHERE file_id=?1 AND state='present'" ++
                " ORDER BY id LIMIT 1 OFFSET 1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .row) return null;
        return try allocator.dupe(u8, statement.columnText(0));
    }

    /// Records that a file the Library still lists is not where it says.
    ///
    /// Called from the decode producer when a track will not open, so it
    /// **declines the write rather than waiting for it**. A job worker holds
    /// the write lane across an entire batch commit; a producer parked behind
    /// one stops feeding the render callback, which zero-fills and counts
    /// underruns. Missing audio is a worse answer than a stale row.
    ///
    /// Skipping costs nothing that matters: the scanner is the authority on
    /// location state and reconciles it properly, and the next attempt on this
    /// track tries again. Returns whether the row was written.
    pub fn markMissingIfLaneFree(self: *LocationRepository, file_id: i64) !bool {
        if (!self.write_lane.tryAcquire()) return false;
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE locations SET state='missing', missing_since=unixepoch()
            \\WHERE file_id=?1 AND state<>'missing';
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .done) return error.SqlFailed;
        return true;
    }

    pub fn stateOf(self: *const LocationRepository, location_id: i64) !LocationState {
        var statement = try self.db.prepare("SELECT state FROM locations WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, location_id);
        if (try statement.step() != .row) return error.LocationNotFound;
        return LocationState.parse(statement.columnText(0)) orelse
            error.InvalidStoredLocationState;
    }

    pub fn count(self: *const LocationRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM locations;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// Locations a scan has confirmed are where the library says they are.
    pub fn countPresent(self: *const LocationRepository) !u64 {
        var statement = try self.db.prepare(
            "SELECT count(*) FROM locations WHERE state='present';",
        );
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    fn folderRange(
        self: *const LocationRepository,
        allocator: std.mem.Allocator,
        root_id: i64,
        relative_path: []const u8,
    ) !FolderRange {
        try validateFolderPath(relative_path);
        var statement = try self.db.prepare("SELECT volume_id, path FROM library_roots WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, root_id);
        if (try statement.step() != .row) return error.UnknownRoot;
        const root_path = statement.columnText(1);
        const prefix = if (relative_path.len == 0)
            try std.mem.concat(allocator, u8, &.{ root_path, "/" })
        else
            try std.mem.concat(allocator, u8, &.{ root_path, "/", relative_path, "/" });
        errdefer allocator.free(prefix);
        const upper = try allocator.dupe(u8, prefix);
        upper[upper.len - 1] = '0';
        return .{ .root_id = root_id, .volume_id = statement.columnInt64(0), .prefix = prefix, .upper = upper };
    }

    /// One page of the folder at `relative_path` under library root
    /// `root_id`: its subfolders, then its audio files, then its images.
    ///
    /// Children are found by seeking along the `(volume_id, uri)` unique
    /// index and jumping over each subfolder's range once its name is known,
    /// so a page costs the children up to its end plus the rows inside the
    /// subfolders it shows, never the whole tree. Folders are in byte order
    /// of `name/`, files and images in byte order of their name; paths match
    /// as stored. Missing locations are left out.
    pub fn folderPage(
        self: *const LocationRepository,
        allocator: std.mem.Allocator,
        root_id: i64,
        relative_path: []const u8,
        limit: u32,
        offset: u32,
    ) !FolderPage {
        if (limit == 0 or limit > max_page) return error.InvalidLimit;
        const range = try self.folderRange(allocator, root_id, relative_path);
        defer range.deinit(allocator);

        var page: FolderPage = .{
            .allocator = allocator,
            .items = &.{},
            .last_scanned_at = try self.folderScannedAt(root_id, relative_path),
            .release_id = null,
            .release_title = null,
            .release_artist = null,
            .image_count = try self.folderImageCount(&range),
        };
        errdefer page.deinit();
        try self.folderRelease(allocator, &range, &page);
        page.items = try self.folderEntries(allocator, &range, limit, offset);
        return page;
    }

    fn folderScannedAt(self: *const LocationRepository, root_id: i64, relative_path: []const u8) !?i64 {
        var statement = try self.db.prepare(
            "SELECT scanned_at FROM folder_scans WHERE root_id=?1 AND relative_path=?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, root_id);
        try statement.bindText(2, relative_path);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    fn folderImageCount(self: *const LocationRepository, range: *const FolderRange) !u32 {
        var statement = try self.db.prepare(folder_image_count_sql);
        defer statement.deinit();
        try statement.bindInt64(1, range.volume_id);
        try statement.bindText(2, range.prefix);
        try statement.bindInt64(3, range.root_id);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// Names the Release on `page` when every Track directly in the folder
    /// belongs to that one Release. A folder with more than `max_page`
    /// children names none, so a page never walks a whole library root.
    fn folderRelease(
        self: *const LocationRepository,
        allocator: std.mem.Allocator,
        range: *const FolderRange,
        page: *FolderPage,
    ) !void {
        var releases = try self.db.prepare("SELECT release_id FROM tracks WHERE preferred_file_id=?1;");
        defer releases.deinit();
        var release_id: ?i64 = null;
        var walk = try FolderWalk.init(self.db, allocator, range);
        defer walk.deinit();
        var children: usize = 0;
        while (try walk.next()) |kind| {
            children += 1;
            if (children > max_page) return;
            if (kind != .file) continue;
            try releases.reset();
            try releases.bindInt64(1, walk.file_id);
            while (try releases.step() == .row) {
                if (releases.columnIsNull(0)) return;
                const found = releases.columnInt64(0);
                if (release_id) |known| {
                    if (known != found) return;
                } else release_id = found;
            }
        }
        const id = release_id orelse return;
        var release = try self.db.prepare("SELECT title, album_artist FROM releases WHERE id=?1;");
        defer release.deinit();
        try release.bindInt64(1, id);
        if (try release.step() != .row) return;
        const title = try allocator.dupe(u8, release.columnText(0));
        errdefer allocator.free(title);
        const artist = try allocator.dupe(u8, release.columnText(1));
        page.release_id = id;
        page.release_title = title;
        page.release_artist = artist;
    }

    fn folderEntries(
        self: *const LocationRepository,
        allocator: std.mem.Allocator,
        range: *const FolderRange,
        limit: u32,
        offset: u32,
    ) ![]FolderEntry {
        var items: std.ArrayList(FolderEntry) = .empty;
        errdefer {
            freeEntries(allocator, items.items);
            items.deinit(allocator);
        }

        var totals = try self.db.prepare(folder_totals_sql);
        defer totals.deinit();
        var subfolder_upper: std.ArrayList(u8) = .empty;
        defer subfolder_upper.deinit(allocator);

        var folders: u32 = 0;
        {
            var walk = try FolderWalk.init(self.db, allocator, range);
            defer walk.deinit();
            while (items.items.len < limit) {
                const kind = try walk.next() orelse break;
                if (kind != .folder) continue;
                folders += 1;
                if (folders <= offset) continue;
                subfolder_upper.clearRetainingCapacity();
                try subfolder_upper.appendSlice(allocator, walk.cursor.items);
                const subfolder_prefix = walk.cursor.items;
                subfolder_prefix[subfolder_prefix.len - 1] = '/';
                defer subfolder_prefix[subfolder_prefix.len - 1] = '0';
                try totals.reset();
                try totals.bindInt64(1, range.volume_id);
                try totals.bindText(2, subfolder_prefix);
                try totals.bindText(3, subfolder_upper.items);
                try totals.bindInt64(4, range.root_id);
                if (try totals.step() != .row) return error.SqlFailed;
                const name = try allocator.dupe(u8, walk.name.items);
                errdefer allocator.free(name);
                try items.append(allocator, .{
                    .name = name,
                    .kind = .folder,
                    .status = .imported,
                    .track_id = null,
                    .file_id = null,
                    .file_count = @intCast(totals.columnInt64(0)),
                    .track_count = @intCast(totals.columnInt64(1)),
                    .total_duration_ms = totals.columnInt64(2),
                    .mime = null,
                    .artwork_role = null,
                });
                try totals.reset();
            }
        }
        if (items.items.len == limit) return items.toOwnedSlice(allocator);

        var file_facts = try self.db.prepare(
            \\SELECT (SELECT id FROM tracks WHERE preferred_file_id=?1 ORDER BY id LIMIT 1),
            \\       (SELECT duration_ms FROM files WHERE id=?1),
            \\       EXISTS (SELECT 1 FROM library_health_issues WHERE file_id=?1 AND kind=?2);
        );
        defer file_facts.deinit();
        const file_offset = offset -| folders;
        var files: u32 = 0;
        {
            var walk = try FolderWalk.init(self.db, allocator, range);
            defer walk.deinit();
            while (items.items.len < limit) {
                const kind = try walk.next() orelse break;
                if (kind != .file) continue;
                files += 1;
                if (files <= file_offset) continue;
                try file_facts.reset();
                try file_facts.bindInt64(1, walk.file_id);
                try file_facts.bindInt64(2, @backingInt(HealthIssueKind.unreadable_file));
                if (try file_facts.step() != .row) return error.SqlFailed;
                const track_id: ?i64 = if (file_facts.columnIsNull(0)) null else file_facts.columnInt64(0);
                const name = try allocator.dupe(u8, walk.name.items);
                errdefer allocator.free(name);
                try items.append(allocator, .{
                    .name = name,
                    .kind = .file,
                    .status = if (file_facts.columnInt64(2) != 0) .unreadable else .imported,
                    .track_id = track_id,
                    .file_id = walk.file_id,
                    .file_count = 1,
                    .track_count = if (track_id == null) 0 else 1,
                    .total_duration_ms = if (file_facts.columnIsNull(1)) 0 else file_facts.columnInt64(1),
                    .mime = null,
                    .artwork_role = null,
                });
            }
        }
        if (items.items.len == limit) return items.toOwnedSlice(allocator);

        var images = try self.db.prepare(folder_images_sql);
        defer images.deinit();
        try images.bindInt64(1, range.volume_id);
        try images.bindText(2, range.prefix);
        try images.bindInt64(3, range.root_id);
        try images.bindInt64(4, @intCast(limit - items.items.len));
        try images.bindInt64(5, file_offset -| files);
        while (try images.step() == .row) {
            const name = try allocator.dupe(u8, images.columnText(0)[range.prefix.len..]);
            errdefer allocator.free(name);
            const mime = try allocator.dupe(u8, images.columnText(1));
            errdefer allocator.free(mime);
            try items.append(allocator, .{
                .name = name,
                .kind = .image,
                .status = .imported,
                .track_id = null,
                .file_id = null,
                .file_count = 0,
                .track_count = 0,
                .total_duration_ms = 0,
                .mime = mime,
                .artwork_role = std.enums.fromInt(ArtworkRole, images.columnInt64(2)) orelse .other,
            });
        }
        return items.toOwnedSlice(allocator);
    }

    /// The id of the image row this identity already describes, or null when
    /// the image is new or its bytes changed. The caller must stamp what this
    /// returns through `markImagesSeenLocked`, as with `unchangedLocationId`.
    pub fn unchangedImageId(
        self: *const LocationRepository,
        volume_id: i64,
        path: []const u8,
        size_bytes: i64,
        modified_ns: i64,
    ) !?i64 {
        var statement = try self.db.prepare(
            "SELECT id FROM folder_images WHERE volume_id=?1 AND uri=?2 AND size_bytes=?3 AND modified_ns=?4;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindText(2, path);
        try statement.bindInt64(3, size_bytes);
        try statement.bindInt64(4, modified_ns);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    pub fn findImage(self: *const LocationRepository, volume_id: i64, path: []const u8) !?i64 {
        var statement = try self.db.prepare(
            "SELECT id FROM folder_images WHERE volume_id=?1 AND uri=?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindText(2, path);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    /// Caller holds the write lane.
    pub fn markImagesSeenLocked(self: *LocationRepository, ids: []const i64, generation: i64) !void {
        if (ids.len == 0) return;
        var statement = try self.db.prepare("UPDATE folder_images SET last_seen_generation=max(last_seen_generation, ?2) WHERE id=?1;");
        defer statement.deinit();
        for (ids) |id| {
            try statement.reset();
            try statement.bindInt64(1, id);
            try statement.bindInt64(2, generation);
            if (try statement.step() != .done) return error.SqlFailed;
        }
    }

    /// Stamps every Location of `root_id` under `directory`, the directory's
    /// own uri, as `markSeenLocked` stamps one. A sibling whose name merely
    /// starts with the directory's is not under it. Caller holds the write lane.
    pub fn markSeenUnderLocked(
        self: *LocationRepository,
        volume_id: i64,
        root_id: i64,
        directory: []const u8,
        generation: i64,
    ) !void {
        try self.stampUnder(seen_under_sql, volume_id, root_id, directory, generation);
    }

    /// The folder images twin of `markSeenUnderLocked`. Caller holds the write lane.
    pub fn markImagesSeenUnderLocked(
        self: *LocationRepository,
        volume_id: i64,
        root_id: i64,
        directory: []const u8,
        generation: i64,
    ) !void {
        try self.stampUnder(images_seen_under_sql, volume_id, root_id, directory, generation);
    }

    fn stampUnder(
        self: *LocationRepository,
        sql: [:0]const u8,
        volume_id: i64,
        root_id: i64,
        directory: []const u8,
        generation: i64,
    ) !void {
        var statement = try self.db.prepare(sql);
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindText(2, directory);
        try statement.bindInt64(3, root_id);
        try statement.bindInt64(4, generation);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Caller holds the write lane.
    pub fn upsertImageLocked(self: *LocationRepository, input: FolderImageUpsert) !void {
        // Generations count per root: a stamp is raised within its root and replaced when the root changes.
        var statement = try self.db.prepare(
            \\INSERT INTO folder_images(
            \\    volume_id, root_id, uri, mime, role, size_bytes, modified_ns, last_seen_generation,
            \\    width, height, hash
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            \\ON CONFLICT(volume_id, uri) DO UPDATE SET
            \\    root_id=COALESCE(excluded.root_id, folder_images.root_id),
            \\    mime=excluded.mime,
            \\    role=excluded.role,
            \\    size_bytes=excluded.size_bytes,
            \\    modified_ns=excluded.modified_ns,
            \\    last_seen_generation=CASE WHEN COALESCE(excluded.root_id, folder_images.root_id) IS folder_images.root_id
            \\        THEN max(folder_images.last_seen_generation, excluded.last_seen_generation)
            \\        ELSE excluded.last_seen_generation END,
            \\    width=excluded.width,
            \\    height=excluded.height,
            \\    hash=excluded.hash;
        );
        defer statement.deinit();
        try statement.bindInt64(1, input.volume_id);
        try statement.bindOptionalInt64(2, input.root_id);
        try statement.bindText(3, input.uri);
        try statement.bindText(4, input.mime);
        try statement.bindInt64(5, @backingInt(input.role));
        try statement.bindInt64(6, input.size_bytes);
        try statement.bindInt64(7, input.modified_ns);
        try statement.bindInt64(8, input.last_seen_generation);
        try statement.bindOptionalInt64(9, if (input.width) |width| width else null);
        try statement.bindOptionalInt64(10, if (input.height) |height| height else null);
        try statement.bindOptionalInt64(11, input.hash);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Recomputes `has_folder_cover` for the Releases with a Track in the
    /// folder of `image_uri`, and retires `artwork_problem` for those it
    /// covers, as a fetched cover does. Caller holds the write lane.
    pub fn refreshFolderCoversLocked(
        self: *LocationRepository,
        allocator: std.mem.Allocator,
        volume_id: i64,
        image_uri: []const u8,
    ) !void {
        const slash = std.mem.lastIndexOfScalar(u8, image_uri, '/') orelse return;
        const folder = image_uri[0 .. slash + 1];
        const upper = try std.mem.concat(allocator, u8, &.{ image_uri[0..slash], "0" });
        defer allocator.free(upper);
        var release_ids: std.ArrayList(i64) = .empty;
        defer release_ids.deinit(allocator);
        {
            var statement = try self.db.prepare(folder_releases_sql);
            defer statement.deinit();
            try statement.bindInt64(1, volume_id);
            try statement.bindText(2, folder);
            try statement.bindText(3, upper);
            while (try statement.step() == .row) try release_ids.append(allocator, statement.columnInt64(0));
        }
        for (release_ids.items) |release_id| {
            _ = try refreshFolderCoverLocked(self.db, release_id);
            try artwork_problems.settleReleaseLocked(self.db, release_id);
        }
    }

    /// The uris of the front cover images in the folder holding most of a
    /// Release's Tracks' preferred files, the lowest folder path on a tie: a
    /// `cover` stem first, then `front`, then `folder`, the largest first
    /// within each. At most `limit`, allocated in `arena`.
    pub fn releaseFrontImages(
        self: *const LocationRepository,
        arena: std.mem.Allocator,
        release_id: i64,
        limit: u32,
    ) ![]const []const u8 {
        return self.frontImages(arena, release_front_images_sql, release_id, limit);
    }

    /// `releaseFrontImages` for the Release a Track belongs to.
    pub fn trackReleaseFrontImages(
        self: *const LocationRepository,
        arena: std.mem.Allocator,
        track_id: i64,
        limit: u32,
    ) ![]const []const u8 {
        return self.frontImages(arena, track_release_front_images_sql, track_id, limit);
    }

    fn frontImages(
        self: *const LocationRepository,
        arena: std.mem.Allocator,
        sql: [:0]const u8,
        id: i64,
        limit: u32,
    ) ![]const []const u8 {
        var statement = try self.db.prepare(sql);
        defer statement.deinit();
        try statement.bindInt64(1, id);
        try statement.bindInt64(2, limit);
        var uris: std.ArrayList([]const u8) = .empty;
        while (try statement.step() == .row) try uris.append(arena, try arena.dupe(u8, statement.columnText(0)));
        return uris.toOwnedSlice(arena);
    }

    /// Records that a scan finished walking the folder at `relative_path`.
    /// Caller holds the write lane.
    pub fn recordFolderScanLocked(self: *LocationRepository, root_id: i64, relative_path: []const u8) !void {
        var statement = try self.db.prepare(
            \\INSERT INTO folder_scans(root_id, relative_path, scanned_at) VALUES (?1, ?2, unixepoch())
            \\ON CONFLICT(root_id, relative_path) DO UPDATE SET scanned_at=excluded.scanned_at;
        );
        defer statement.deinit();
        try statement.bindInt64(1, root_id);
        try statement.bindText(2, relative_path);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// The Tracks whose preferred file is located anywhere below the folder,
    /// each once, in path order, at most `max_playlist_entries`. Caller owns
    /// the slice.
    pub fn folderTrackIds(
        self: *const LocationRepository,
        allocator: std.mem.Allocator,
        root_id: i64,
        relative_path: []const u8,
    ) ![]i64 {
        const range = try self.folderRange(allocator, root_id, relative_path);
        defer range.deinit(allocator);
        var statement = try self.db.prepare(folder_track_ids_sql);
        defer statement.deinit();
        try statement.bindInt64(1, range.volume_id);
        try statement.bindText(2, range.prefix);
        try statement.bindText(3, range.upper);
        try statement.bindInt64(4, range.root_id);
        var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
        defer seen.deinit(allocator);
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (ids.items.len < max_playlist_entries and try statement.step() == .row) {
            const id = statement.columnInt64(0);
            if ((try seen.getOrPut(allocator, id)).found_existing) continue;
            try ids.append(allocator, id);
        }
        return ids.toOwnedSlice(allocator);
    }
};

fn openFolderTestLibrary(comptime name: []const u8) !@import("../library.zig").LibraryDatabase {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-folders-" ++ name ++ "?mode=memory&cache=shared",
    );
    errdefer library.close();
    try library.database.exec(
        \\INSERT INTO volumes(id, stable_key) VALUES (2, 'music');
        \\INSERT INTO library_roots(id, volume_id, path) VALUES (1, 2, '/m'), (2, 2, '/other');
    );
    return library;
}

fn expectFolderEntry(entry: FolderEntry, kind: FolderEntryKind, name: []const u8, files: u32, tracks: u32, duration_ms: i64) !void {
    try std.testing.expectEqual(kind, entry.kind);
    try std.testing.expectEqualStrings(name, entry.name);
    try std.testing.expectEqual(files, entry.file_count);
    try std.testing.expectEqual(tracks, entry.track_count);
    try std.testing.expectEqual(duration_ms, entry.total_duration_ms);
}

test "folder queries read a uri range of the volume's unique index, never the whole root" {
    var library = try openFolderTestLibrary("plan");
    defer library.close();
    for ([_][]const u8{ folder_seek_from_sql, folder_seek_after_sql, folder_totals_sql, folder_track_ids_sql }) |sql| {
        const explain = try std.mem.concatWithSentinel(std.testing.allocator, u8, &.{ "EXPLAIN QUERY PLAN ", sql }, 0);
        defer std.testing.allocator.free(explain);
        var statement = try library.database.prepare(explain);
        defer statement.deinit();
        var plan: std.ArrayList(u8) = .empty;
        defer plan.deinit(std.testing.allocator);
        while (try statement.step() == .row) {
            try plan.appendSlice(std.testing.allocator, statement.columnText(3));
            try plan.append(std.testing.allocator, '\n');
        }
        try std.testing.expect(std.mem.indexOf(u8, plan.items, "sqlite_autoindex_locations_1 (volume_id=? AND uri>? AND uri<?)") != null);
        try std.testing.expect(std.mem.indexOf(u8, plan.items, "locations_sweep") == null);
        try std.testing.expect(std.mem.indexOf(u8, plan.items, "SCAN locations") == null);
    }
}

test "folders list before files, each in name order" {
    var library = try openFolderTestLibrary("order");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO files(id, duration_ms) VALUES (1, 10), (2, 20), (3, 30), (4, 40), (5, NULL);
        \\INSERT INTO tracks(id, title, preferred_file_id) VALUES (11, 'a', 1), (13, 'c', 3), (14, 'd', 4);
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state) VALUES
        \\    (4, 2, 1, '/m/b.flac', 'present'),
        \\    (1, 2, 1, '/m/Zed/1.flac', 'present'),
        \\    (5, 2, 1, '/m/a.flac', 'present'),
        \\    (2, 2, 1, '/m/Abba/2.flac', 'present'),
        \\    (3, 2, 1, '/m/Abba0.flac', 'present');
    );
    const page = try library.locations.folderPage(std.testing.allocator, 1, "", 512, 0);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 5), page.items.len);
    try expectFolderEntry(page.items[0], .folder, "Abba", 1, 0, 20);
    try expectFolderEntry(page.items[1], .folder, "Zed", 1, 1, 10);
    try expectFolderEntry(page.items[2], .file, "Abba0.flac", 1, 1, 30);
    try expectFolderEntry(page.items[3], .file, "a.flac", 1, 0, 0);
    try expectFolderEntry(page.items[4], .file, "b.flac", 1, 1, 40);
    try std.testing.expectEqual(@as(?i64, 13), page.items[2].track_id);
    try std.testing.expectEqual(@as(?i64, 3), page.items[2].file_id);
    try std.testing.expectEqual(@as(?i64, null), page.items[3].track_id);
    try std.testing.expectEqual(@as(?i64, null), page.items[0].file_id);
}

test "folder totals count every file nested below the folder" {
    var library = try openFolderTestLibrary("totals");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO files(id, duration_ms) VALUES (1, 100), (2, 200), (3, 300), (4, 400);
        \\INSERT INTO tracks(id, title, preferred_file_id) VALUES (1, 'a', 1), (2, 'b', 2), (3, 'c', 3);
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state) VALUES
        \\    (1, 2, 1, '/m/Artist/Album/1.flac', 'present'),
        \\    (2, 2, 1, '/m/Artist/Album/CD2/2.flac', 'present'),
        \\    (3, 2, 1, '/m/Artist/3.flac', 'unverified'),
        \\    (4, 2, 1, '/m/Artist/cover.flac', 'present'),
        \\    (4, 2, 1, '/m/Artist/Album/copy-of-cover.flac', 'present');
    );
    const top = try library.locations.folderPage(std.testing.allocator, 1, "", 512, 0);
    defer top.deinit();
    try std.testing.expectEqual(@as(usize, 1), top.items.len);
    try expectFolderEntry(top.items[0], .folder, "Artist", 4, 3, 1000);

    const artist = try library.locations.folderPage(std.testing.allocator, 1, "Artist", 512, 0);
    defer artist.deinit();
    try std.testing.expectEqual(@as(usize, 3), artist.items.len);
    try expectFolderEntry(artist.items[0], .folder, "Album", 3, 2, 700);
    try expectFolderEntry(artist.items[1], .file, "3.flac", 1, 1, 300);
    try expectFolderEntry(artist.items[2], .file, "cover.flac", 1, 0, 400);
}

test "missing locations are excluded from folder pages and totals" {
    var library = try openFolderTestLibrary("missing");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO files(id, duration_ms) VALUES (1, 100), (2, 200), (3, 300);
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state) VALUES
        \\    (1, 2, 1, '/m/Gone/1.flac', 'missing'),
        \\    (2, 2, 1, '/m/Half/2.flac', 'present'),
        \\    (3, 2, 1, '/m/Half/3.flac', 'missing'),
        \\    (3, 2, 1, '/m/3.flac', 'missing');
    );
    const page = try library.locations.folderPage(std.testing.allocator, 1, "", 512, 0);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try expectFolderEntry(page.items[0], .folder, "Half", 1, 0, 200);
    const gone = try library.locations.folderPage(std.testing.allocator, 1, "Gone", 512, 0);
    defer gone.deinit();
    try std.testing.expectEqual(@as(usize, 0), gone.items.len);
}

test "folder paths with dot-dot, a leading slash or a NUL are refused" {
    var library = try openFolderTestLibrary("refused");
    defer library.close();
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "..", "a/../b", "/m", "/", "a/", "a//b", "./a", "a\x00b" }) |path| {
        try std.testing.expectError(error.InvalidFolderPath, library.locations.folderPage(allocator, 1, path, 10, 0));
        try std.testing.expectError(error.InvalidFolderPath, library.locations.folderTrackIds(allocator, 1, path));
    }
    try std.testing.expectError(error.UnknownRoot, library.locations.folderPage(allocator, 99, "", 10, 0));
    try std.testing.expectError(error.InvalidLimit, library.locations.folderPage(allocator, 1, "", 0, 0));
    try std.testing.expectError(error.InvalidLimit, library.locations.folderPage(allocator, 1, "", 513, 0));
}

test "glob and like metacharacters in folder names match literally" {
    var library = try openFolderTestLibrary("metacharacters");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO files(id, duration_ms) VALUES (1, 1), (2, 2), (3, 4), (4, 8), (5, 16);
        \\INSERT INTO tracks(id, title, preferred_file_id) VALUES (1, 'a', 1), (2, 'b', 2), (3, 'c', 3), (4, 'd', 4), (5, 'e', 5);
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state) VALUES
        \\    (1, 2, 1, '/m/[Live] 2001/1.flac', 'present'),
        \\    (2, 2, 1, '/m/L/1.flac', 'present'),
        \\    (3, 2, 1, '/m/100% *Hits?/1.flac', 'present'),
        \\    (4, 2, 1, '/m/100_ Hits/1.flac', 'present'),
        \\    (5, 2, 1, '/m/[Live] 2001 Deluxe/1.flac', 'present');
    );
    const live = try library.locations.folderPage(std.testing.allocator, 1, "[Live] 2001", 512, 0);
    defer live.deinit();
    try std.testing.expectEqual(@as(usize, 1), live.items.len);
    try std.testing.expectEqual(@as(?i64, 1), live.items[0].track_id);

    const hits = try library.locations.folderPage(std.testing.allocator, 1, "100% *Hits?", 512, 0);
    defer hits.deinit();
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(@as(?i64, 3), hits.items[0].track_id);

    const ids = try library.locations.folderTrackIds(std.testing.allocator, 1, "[Live] 2001");
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(i64, &.{1}, ids);
}

test "a folder page is bounded by its limit and pages on with offset" {
    var library = try openFolderTestLibrary("paging");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO files(id) VALUES (1), (2), (3), (4), (5), (6);
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state) VALUES
        \\    (1, 2, 1, '/m/A/x.flac', 'present'),
        \\    (2, 2, 1, '/m/B/x.flac', 'present'),
        \\    (3, 2, 1, '/m/C/x.flac', 'present'),
        \\    (4, 2, 1, '/m/1.flac', 'present'),
        \\    (5, 2, 1, '/m/2.flac', 'present'),
        \\    (6, 2, 2, '/m/3.flac', 'present');
    );
    const expected = [_][]const u8{ "A", "B", "C", "1.flac", "2.flac" };
    for (0..expected.len + 1) |offset| {
        const page = try library.locations.folderPage(std.testing.allocator, 1, "", 2, @intCast(offset));
        defer page.deinit();
        const want = expected[@min(offset, expected.len)..@min(offset + 2, expected.len)];
        try std.testing.expectEqual(want.len, page.items.len);
        for (want, page.items) |name, item| try std.testing.expectEqualStrings(name, item.name);
    }
}

test "a folder's Tracks come recursively in path order, each once" {
    var library = try openFolderTestLibrary("tracks");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO files(id) VALUES (1), (2), (3), (4), (5);
        \\INSERT INTO tracks(id, title, preferred_file_id) VALUES (10, 'a', 1), (20, 'b', 2), (30, 'c', 3), (40, 'd', 4);
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state) VALUES
        \\    (3, 2, 1, '/m/A/b/1.flac', 'present'),
        \\    (1, 2, 1, '/m/A/z.flac', 'present'),
        \\    (2, 2, 1, '/m/A/a/2.flac', 'present'),
        \\    (1, 2, 1, '/m/A/a/copy.flac', 'present'),
        \\    (4, 2, 1, '/m/A/gone.flac', 'missing'),
        \\    (5, 2, 1, '/m/A/untracked.flac', 'present'),
        \\    (4, 2, 1, '/m/B/4.flac', 'present');
    );
    const ids = try library.locations.folderTrackIds(std.testing.allocator, 1, "A");
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(i64, &.{ 20, 10, 30 }, ids);
    const all = try library.locations.folderTrackIds(std.testing.allocator, 1, "");
    defer std.testing.allocator.free(all);
    try std.testing.expectEqualSlices(i64, &.{ 20, 10, 30, 40 }, all);
}

fn insertTestImage(library: anytype, uri: []const u8, role: ArtworkRole) !void {
    try library.locations.upsertImageLocked(.{
        .volume_id = 2,
        .root_id = 1,
        .uri = uri,
        .mime = "image/jpeg",
        .role = role,
        .size_bytes = 10,
        .modified_ns = 20,
        .last_seen_generation = 1,
    });
}

test "a picture's role comes from its name, whatever its case" {
    try std.testing.expectEqual(ArtworkRole.front, ArtworkRole.ofName("cover.jpg"));
    try std.testing.expectEqual(ArtworkRole.front, ArtworkRole.ofName("Folder.JPG"));
    try std.testing.expectEqual(ArtworkRole.front, ArtworkRole.ofName("FRONT.png"));
    try std.testing.expectEqual(ArtworkRole.back, ArtworkRole.ofName("Back.webp"));
    try std.testing.expectEqual(ArtworkRole.booklet, ArtworkRole.ofName("booklet.gif"));
    try std.testing.expectEqual(ArtworkRole.other, ArtworkRole.ofName("cover 2.jpg"));
    try std.testing.expectEqual(ArtworkRole.other, ArtworkRole.ofName("scan.cover.jpg"));
    try std.testing.expectEqual(ArtworkRole.front, ArtworkRole.ofName("cover"));
}

test "images list after the audio files of their own folder only, and count toward it" {
    var library = try openFolderTestLibrary("images");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO files(id, duration_ms) VALUES (1, 10), (2, 20);
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state) VALUES
        \\    (1, 2, 1, '/m/A/1.flac', 'present'),
        \\    (2, 2, 1, '/m/A/Sub/2.flac', 'present');
    );
    try insertTestImage(&library, "/m/A/cover.jpg", .front);
    try insertTestImage(&library, "/m/A/back.jpg", .back);
    try insertTestImage(&library, "/m/A/Sub/scan.jpg", .other);
    try insertTestImage(&library, "/m/A0/cover.jpg", .front);
    try insertTestImage(&library, "/m/cover.jpg", .front);

    const page = try library.locations.folderPage(std.testing.allocator, 1, "A", 512, 0);
    defer page.deinit();
    try std.testing.expectEqual(@as(u32, 2), page.image_count);
    try std.testing.expectEqual(@as(usize, 4), page.items.len);
    try expectFolderEntry(page.items[0], .folder, "Sub", 1, 0, 20);
    try expectFolderEntry(page.items[1], .file, "1.flac", 1, 0, 10);
    try expectFolderEntry(page.items[2], .image, "back.jpg", 0, 0, 0);
    try expectFolderEntry(page.items[3], .image, "cover.jpg", 0, 0, 0);
    try std.testing.expectEqual(@as(?ArtworkRole, .back), page.items[2].artwork_role);
    try std.testing.expectEqual(@as(?ArtworkRole, .front), page.items[3].artwork_role);
    try std.testing.expectEqualStrings("image/jpeg", page.items[3].mime.?);
    try std.testing.expectEqual(FolderEntryStatus.imported, page.items[3].status);
    try std.testing.expectEqual(@as(?i64, null), page.items[3].file_id);
    try std.testing.expectEqual(@as(?ArtworkRole, null), page.items[1].artwork_role);

    const expected = [_][]const u8{ "Sub", "1.flac", "back.jpg", "cover.jpg" };
    for (0..expected.len + 1) |offset| {
        const part = try library.locations.folderPage(std.testing.allocator, 1, "A", 1, @intCast(offset));
        defer part.deinit();
        const want = expected[@min(offset, expected.len)..@min(offset + 1, expected.len)];
        try std.testing.expectEqual(want.len, part.items.len);
        for (want, part.items) |name, item| try std.testing.expectEqualStrings(name, item.name);
    }
}

test "folder images are read through their folder index, never by scanning" {
    var library = try openFolderTestLibrary("image-plan");
    defer library.close();
    for ([_][]const u8{ folder_images_sql, folder_image_count_sql }) |sql| {
        const explain = try std.mem.concatWithSentinel(std.testing.allocator, u8, &.{ "EXPLAIN QUERY PLAN ", sql }, 0);
        defer std.testing.allocator.free(explain);
        var statement = try library.database.prepare(explain);
        defer statement.deinit();
        var plan: std.ArrayList(u8) = .empty;
        defer plan.deinit(std.testing.allocator);
        while (try statement.step() == .row) {
            try plan.appendSlice(std.testing.allocator, statement.columnText(3));
            try plan.append(std.testing.allocator, '\n');
        }
        try std.testing.expect(std.mem.indexOf(u8, plan.items, "folder_images_folder") != null);
        try std.testing.expect(std.mem.indexOf(u8, plan.items, "SCAN folder_images") == null);
        try std.testing.expect(std.mem.indexOf(u8, plan.items, "SCAN locations") == null);
        try std.testing.expect(std.mem.indexOf(u8, plan.items, "SCAN tracks") == null);
    }
}

test "a new front image retires the missing artwork issue of the Releases it now covers, and only theirs" {
    var library = try openFolderTestLibrary("folder-cover-health");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO releases(id, title, release_key) VALUES (1, 'Here', 'here'), (2, 'Elsewhere', 'elsewhere');
        \\INSERT INTO files(id) VALUES (1), (2), (3), (4);
        \\INSERT INTO tracks(id, title, release_id, preferred_file_id) VALUES
        \\    (10, 'a', 1, 1), (11, 'b', 1, 2), (20, 'c', 2, 3), (21, 'd', 2, 4);
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state) VALUES
        \\    (1, 2, 1, '/m/Here/1.flac', 'present'),
        \\    (2, 2, 1, '/m/Here/2.flac', 'present'),
        \\    (3, 2, 1, '/m/Here/3.flac', 'present'),
        \\    (4, 2, 1, '/m/Elsewhere/4.flac', 'present');
    );
    for ([_]i64{ 1, 2, 3, 4 }) |file_id|
        try health.recordIssueLocked(library.database, file_id, .{ .kind = .artwork_problem, .severity = .information });
    try insertSizedFrontImage(&library, "/m/Here/back.jpg", 10);
    try library.locations.refreshFolderCoversLocked(std.testing.allocator, 2, "/m/Here/back.jpg");
    try std.testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT has_folder_cover FROM releases WHERE id = 1;"));
    try insertSizedFrontImage(&library, "/m/Here/cover.jpg", 10);
    try library.locations.refreshFolderCoversLocked(std.testing.allocator, 2, "/m/Here/cover.jpg");
    try std.testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT has_folder_cover FROM releases WHERE id = 1;"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT has_folder_cover FROM releases WHERE id = 2;"));

    var remaining = try library.database.prepare(
        "SELECT file_id FROM library_health_issues WHERE kind = ?1 ORDER BY file_id;",
    );
    defer remaining.deinit();
    try remaining.bindInt64(1, @backingInt(HealthIssueKind.artwork_problem));
    var file_ids: std.ArrayList(i64) = .empty;
    defer file_ids.deinit(std.testing.allocator);
    while (try remaining.step() == .row) try file_ids.append(std.testing.allocator, remaining.columnInt64(0));
    try std.testing.expectEqualSlices(i64, &.{ 3, 4 }, file_ids.items);
}

fn insertSizedFrontImage(library: anytype, uri: []const u8, size_bytes: i64) !void {
    try library.locations.upsertImageLocked(.{
        .volume_id = 2,
        .root_id = 1,
        .uri = uri,
        .mime = "image/jpeg",
        .role = ArtworkRole.ofName(std.fs.path.basename(uri)),
        .size_bytes = size_bytes,
        .modified_ns = 20,
        .last_seen_generation = 1,
    });
}

test "a Release's front images come from the folder holding most of its Tracks, cover before front before folder, largest first" {
    var library = try openFolderTestLibrary("release-front-images");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO releases(id, title, release_key) VALUES (1, 'Split', 'split'), (2, 'Tied', 'tied');
        \\INSERT INTO files(id) VALUES (1), (2), (3), (4), (5);
        \\INSERT INTO tracks(id, title, release_id, preferred_file_id) VALUES
        \\    (10, 'a', 1, 1), (11, 'b', 1, 2), (12, 'c', 1, 3), (20, 'd', 2, 4), (21, 'e', 2, 5);
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state) VALUES
        \\    (1, 2, 1, '/m/Split/CD2/1.flac', 'present'),
        \\    (2, 2, 1, '/m/Split/CD2/2.flac', 'present'),
        \\    (3, 2, 1, '/m/Split/CD1/1.flac', 'present'),
        \\    (4, 2, 1, '/m/Tied/B/1.flac', 'present'),
        \\    (5, 2, 1, '/m/Tied/A/1.flac', 'present');
    );
    try insertSizedFrontImage(&library, "/m/Split/CD1/cover.jpg", 900);
    try insertSizedFrontImage(&library, "/m/Split/CD2/folder.jpg", 900);
    try insertSizedFrontImage(&library, "/m/Split/CD2/Front.png", 10);
    try insertSizedFrontImage(&library, "/m/Split/CD2/cover.png", 10);
    try insertSizedFrontImage(&library, "/m/Split/CD2/COVER.jpg", 20);
    try insertSizedFrontImage(&library, "/m/Split/CD2/back.jpg", 999);
    try insertSizedFrontImage(&library, "/m/Split/CD2/Sub/cover.jpg", 999);
    try insertSizedFrontImage(&library, "/m/Tied/A/folder.jpg", 1);
    try insertSizedFrontImage(&library, "/m/Tied/B/cover.jpg", 1);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const split = try library.locations.releaseFrontImages(arena, 1, 8);
    try std.testing.expectEqual(@as(usize, 4), split.len);
    for ([_][]const u8{ "/m/Split/CD2/COVER.jpg", "/m/Split/CD2/cover.png", "/m/Split/CD2/Front.png", "/m/Split/CD2/folder.jpg" }, split) |want, got|
        try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqual(@as(usize, 2), (try library.locations.releaseFrontImages(arena, 1, 2)).len);

    const tied = try library.locations.trackReleaseFrontImages(arena, 21, 8);
    try std.testing.expectEqual(@as(usize, 1), tied.len);
    try std.testing.expectEqualStrings("/m/Tied/A/folder.jpg", tied[0]);

    try library.database.exec("UPDATE locations SET state = 'missing' WHERE file_id = 5;");
    const moved = try library.locations.releaseFrontImages(arena, 2, 8);
    try std.testing.expectEqualStrings("/m/Tied/B/cover.jpg", moved[0]);
    try std.testing.expectEqual(@as(usize, 0), (try library.locations.releaseFrontImages(arena, 3, 8)).len);
}

test "a Release's front images are found through the folder index, never by scanning" {
    var library = try openFolderTestLibrary("release-front-image-plan");
    defer library.close();
    for ([_][:0]const u8{
        release_front_images_sql,
        track_release_front_images_sql,
        refresh_folder_cover_sql,
        refresh_swept_folder_covers_sql,
    }) |sql| {
        const explain = try std.mem.concatWithSentinel(std.testing.allocator, u8, &.{ "EXPLAIN QUERY PLAN ", sql }, 0);
        defer std.testing.allocator.free(explain);
        var statement = try library.database.prepare(explain);
        defer statement.deinit();
        var plan: std.ArrayList(u8) = .empty;
        defer plan.deinit(std.testing.allocator);
        while (try statement.step() == .row) {
            try plan.appendSlice(std.testing.allocator, statement.columnText(3));
            try plan.append(std.testing.allocator, '\n');
        }
        try std.testing.expect(std.mem.indexOf(u8, plan.items, "folder_images_folder") != null);
        try std.testing.expect(std.mem.indexOf(u8, plan.items, "SCAN folder_images") == null);
        try std.testing.expect(std.mem.indexOf(u8, plan.items, "SCAN tracks") == null);
    }
}

test "a file property backfill could not decode is listed as unreadable" {
    var library = try openFolderTestLibrary("unreadable");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO files(id) VALUES (1), (2);
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state) VALUES
        \\    (1, 2, 1, '/m/bad.flac', 'present'),
        \\    (2, 2, 1, '/m/good.flac', 'present');
    );
    var statement = try library.database.prepare(
        "INSERT INTO library_health_issues(file_id, kind, severity) VALUES (1, ?1, 2);",
    );
    defer statement.deinit();
    try statement.bindInt64(1, @backingInt(HealthIssueKind.unreadable_file));
    _ = try statement.step();
    const page = try library.locations.folderPage(std.testing.allocator, 1, "", 512, 0);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqual(FolderEntryStatus.unreadable, page.items[0].status);
    try std.testing.expectEqual(FolderEntryStatus.imported, page.items[1].status);
}

test "a folder names its Release only when every Track in it belongs to that one" {
    var library = try openFolderTestLibrary("release");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO releases(id, title, album_artist) VALUES (1, 'One', 'Band'), (2, 'Two', 'Band');
        \\INSERT INTO files(id) VALUES (1), (2), (3), (4), (5);
        \\INSERT INTO tracks(id, title, preferred_file_id, release_id) VALUES
        \\    (1, 'a', 1, 1), (2, 'b', 2, 1), (3, 'c', 3, 1), (4, 'd', 4, 2), (5, 'e', 5, 1);
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state) VALUES
        \\    (1, 2, 1, '/m/One/1.flac', 'present'),
        \\    (2, 2, 1, '/m/One/2.flac', 'present'),
        \\    (3, 2, 1, '/m/One/Other/3.flac', 'present'),
        \\    (4, 2, 1, '/m/One/Other/4.flac', 'present'),
        \\    (5, 2, 1, '/m/One/Gone.flac', 'missing');
    );
    const one = try library.locations.folderPage(std.testing.allocator, 1, "One", 512, 0);
    defer one.deinit();
    try std.testing.expectEqual(@as(?i64, 1), one.release_id);
    try std.testing.expectEqualStrings("One", one.release_title.?);
    try std.testing.expectEqualStrings("Band", one.release_artist.?);

    const mixed = try library.locations.folderPage(std.testing.allocator, 1, "One/Other", 512, 0);
    defer mixed.deinit();
    try std.testing.expectEqual(@as(?i64, null), mixed.release_id);
    try std.testing.expectEqual(@as(?[]u8, null), mixed.release_title);

    const root = try library.locations.folderPage(std.testing.allocator, 1, "", 512, 0);
    defer root.deinit();
    try std.testing.expectEqual(@as(?i64, null), root.release_id);
}

test "a folder with more children than a page names no Release" {
    var library = try openFolderTestLibrary("release-bound");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO releases(id, title) VALUES (1, 'Big');
        \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 513)
        \\INSERT INTO files(id) SELECT i FROM n;
        \\INSERT INTO tracks(id, title, preferred_file_id, release_id) SELECT id, 't', id, 1 FROM files;
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state)
        \\    SELECT id, 2, 1, printf('/m/Big/%03d.flac', id), 'present' FROM files;
    );
    const big = try library.locations.folderPage(std.testing.allocator, 1, "Big", 512, 0);
    defer big.deinit();
    try std.testing.expectEqual(@as(?i64, null), big.release_id);
    try library.database.exec("DELETE FROM locations WHERE file_id=513;");
    const page = try library.locations.folderPage(std.testing.allocator, 1, "Big", 512, 0);
    defer page.deinit();
    try std.testing.expectEqual(@as(?i64, 1), page.release_id);
}

test "a folder's last scan is when a walk last finished it, and none before" {
    var library = try openFolderTestLibrary("last-scan");
    defer library.close();
    const before = try library.locations.folderPage(std.testing.allocator, 1, "", 512, 0);
    defer before.deinit();
    try std.testing.expectEqual(@as(?i64, null), before.last_scanned_at);
    try library.locations.recordFolderScanLocked(1, "");
    try library.locations.recordFolderScanLocked(1, "");
    const after = try library.locations.folderPage(std.testing.allocator, 1, "", 512, 0);
    defer after.deinit();
    try std.testing.expect(after.last_scanned_at.? > 1_700_000_000);
    const other = try library.locations.folderPage(std.testing.allocator, 2, "", 512, 0);
    defer other.deinit();
    try std.testing.expectEqual(@as(?i64, null), other.last_scanned_at);
}

test "a sweep that forgets a front image or loses a Release's files clears the Release's folder cover, and only its" {
    var library = try openFolderTestLibrary("folder-cover-sweep");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO releases(id, title, release_key) VALUES (1, 'Here', 'here'), (2, 'Elsewhere', 'elsewhere');
        \\INSERT INTO files(id) VALUES (1), (2), (3);
        \\INSERT INTO tracks(id, title, release_id, preferred_file_id) VALUES (10, 'a', 1, 1), (11, 'b', 1, 2), (20, 'c', 2, 3);
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state, last_seen_generation) VALUES
        \\    (1, 2, 1, '/m/Here/1.flac', 'present', 2),
        \\    (2, 2, 1, '/m/Here/2.flac', 'present', 2),
        \\    (3, 2, 1, '/m/Elsewhere/3.flac', 'present', 3);
        \\INSERT INTO folder_images(volume_id, root_id, uri, mime, role, size_bytes, modified_ns, last_seen_generation) VALUES
        \\    (2, 1, '/m/Here/cover.jpg', 'image/jpeg', 0, 10, 1, 1),
        \\    (2, 1, '/m/Elsewhere/cover.jpg', 'image/jpeg', 0, 10, 1, 3);
    );
    for ([_]i64{ 1, 2 }) |release_id| try std.testing.expect(try refreshFolderCoverLocked(library.database, release_id));

    try std.testing.expectEqual(@as(u64, 0), try library.files.markMissingBelowGeneration(1, 2));
    try std.testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT has_folder_cover FROM releases WHERE id = 1;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT has_folder_cover FROM releases WHERE id = 2;"));

    try library.database.exec(
        \\INSERT INTO folder_images(volume_id, root_id, uri, mime, role, size_bytes, modified_ns, last_seen_generation) VALUES
        \\    (2, 1, '/m/Here/cover.jpg', 'image/jpeg', 0, 10, 1, 3);
        \\UPDATE locations SET last_seen_generation = 3 WHERE file_id = 3;
    );
    try std.testing.expect(try refreshFolderCoverLocked(library.database, 1));
    try std.testing.expectEqual(@as(u64, 2), try library.files.markMissingBelowGenerationUnder(2, 1, 3, "/m/Here"));
    try std.testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT has_folder_cover FROM releases WHERE id = 1;"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT has_folder_cover FROM releases WHERE id = 2;"));
}

test "a stamp under a directory raises only its root's rows below that directory, and never lowers one" {
    var library = try openFolderTestLibrary("seen-under");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO files(id) VALUES (1), (2), (3), (4), (5);
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state, last_seen_generation) VALUES
        \\    (1, 2, 1, '/m/ab/1.flac', 'present', 2),
        \\    (2, 2, 1, '/m/ab/deep/2.flac', 'present', 9),
        \\    (3, 2, 1, '/m/abc/3.flac', 'present', 2),
        \\    (4, 2, 2, '/m/ab/nested/4.flac', 'present', 2),
        \\    (5, 2, 1, '/m/ab', 'present', 2);
        \\INSERT INTO folder_images(volume_id, root_id, uri, mime, role, size_bytes, modified_ns, last_seen_generation) VALUES
        \\    (2, 1, '/m/ab/cover.jpg', 'image/jpeg', 0, 10, 1, 2),
        \\    (2, 1, '/m/abc/cover.jpg', 'image/jpeg', 0, 10, 1, 2),
        \\    (2, 2, '/m/ab/nested/cover.jpg', 'image/jpeg', 0, 10, 1, 2);
    );
    library.write_lane.acquire();
    try library.locations.markSeenUnderLocked(2, 1, "/m/ab", 5);
    try library.locations.markImagesSeenUnderLocked(2, 1, "/m/ab", 5);
    library.write_lane.release();
    try std.testing.expectEqual(@as(i64, 5), try scalar(library.database, "SELECT last_seen_generation FROM locations WHERE file_id = 1;"));
    try std.testing.expectEqual(@as(i64, 9), try scalar(library.database, "SELECT last_seen_generation FROM locations WHERE file_id = 2;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT last_seen_generation FROM locations WHERE file_id = 3;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT last_seen_generation FROM locations WHERE file_id = 4;"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT last_seen_generation FROM locations WHERE file_id = 5;"));
    try std.testing.expectEqual(@as(i64, 5), try scalar(library.database, "SELECT last_seen_generation FROM folder_images WHERE uri = '/m/ab/cover.jpg';"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT last_seen_generation FROM folder_images WHERE uri = '/m/abc/cover.jpg';"));
    try std.testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT last_seen_generation FROM folder_images WHERE uri = '/m/ab/nested/cover.jpg';"));
}

test "a stamp under a directory reads a uri range of the volume's unique index, never the whole root" {
    var library = try openFolderTestLibrary("seen-under-plan");
    defer library.close();
    for ([_][:0]const u8{ seen_under_sql, images_seen_under_sql }) |sql| {
        const explain = try std.mem.concatWithSentinel(std.testing.allocator, u8, &.{ "EXPLAIN QUERY PLAN ", sql }, 0);
        defer std.testing.allocator.free(explain);
        var statement = try library.database.prepare(explain);
        defer statement.deinit();
        var plan: std.ArrayList(u8) = .empty;
        defer plan.deinit(std.testing.allocator);
        while (try statement.step() == .row) {
            try plan.appendSlice(std.testing.allocator, statement.columnText(3));
            try plan.append(std.testing.allocator, '\n');
        }
        try std.testing.expect(std.mem.indexOf(u8, plan.items, "(volume_id=? AND uri>? AND uri<?)") != null);
        try std.testing.expect(std.mem.indexOf(u8, plan.items, "_sweep") == null);
        try std.testing.expect(std.mem.indexOf(u8, plan.items, "SCAN") == null);
    }
}

fn testImageUpsert(root_id: ?i64, uri: []const u8, generation: i64) FolderImageUpsert {
    return .{
        .volume_id = 2,
        .root_id = root_id,
        .uri = uri,
        .mime = "image/jpeg",
        .role = .front,
        .size_bytes = 10,
        .modified_ns = 20,
        .last_seen_generation = generation,
    };
}

const test_location_generation = "SELECT last_seen_generation FROM locations WHERE uri='/m/a.flac';";
const test_image_generation = "SELECT last_seen_generation FROM folder_images WHERE uri='/m/cover.jpg';";

fn insertTestLocation(library: anytype, root_id: ?i64, generation: i64) !i64 {
    return library.locations.upsert(.{ .file_id = 1, .volume_id = 2, .root_id = root_id, .uri = "/m/a.flac", .last_seen_generation = generation });
}

test "an upsert with a lower generation never lowers a location's stamp in its root" {
    var library = try openFolderTestLibrary("monotonic-location-upsert");
    defer library.close();
    try library.database.exec("INSERT INTO files(id) VALUES (1);");
    _ = try insertTestLocation(&library, 1, 5);
    _ = try insertTestLocation(&library, 1, 3);
    try std.testing.expectEqual(@as(i64, 5), try scalar(library.database, test_location_generation));
    _ = try insertTestLocation(&library, null, 2);
    try std.testing.expectEqual(@as(i64, 5), try scalar(library.database, test_location_generation));
    _ = try insertTestLocation(&library, 1, 6);
    try std.testing.expectEqual(@as(i64, 6), try scalar(library.database, test_location_generation));
}

test "marking a location seen with a lower generation never lowers its stamp" {
    var library = try openFolderTestLibrary("monotonic-location-seen");
    defer library.close();
    try library.database.exec("INSERT INTO files(id) VALUES (1);");
    const location_id = try insertTestLocation(&library, 1, 5);
    try library.locations.markSeenLocked(&.{location_id}, 4);
    try std.testing.expectEqual(@as(i64, 5), try scalar(library.database, test_location_generation));
    try library.locations.markSeenLocked(&.{location_id}, 6);
    try std.testing.expectEqual(@as(i64, 6), try scalar(library.database, test_location_generation));
}

test "an image upsert with a lower generation never lowers the image's stamp in its root" {
    var library = try openFolderTestLibrary("monotonic-image-upsert");
    defer library.close();
    try library.locations.upsertImageLocked(testImageUpsert(1, "/m/cover.jpg", 5));
    try library.locations.upsertImageLocked(testImageUpsert(1, "/m/cover.jpg", 3));
    try std.testing.expectEqual(@as(i64, 5), try scalar(library.database, test_image_generation));
    try library.locations.upsertImageLocked(testImageUpsert(null, "/m/cover.jpg", 2));
    try std.testing.expectEqual(@as(i64, 5), try scalar(library.database, test_image_generation));
    try library.locations.upsertImageLocked(testImageUpsert(1, "/m/cover.jpg", 6));
    try std.testing.expectEqual(@as(i64, 6), try scalar(library.database, test_image_generation));
}

test "marking an image seen with a lower generation never lowers its stamp" {
    var library = try openFolderTestLibrary("monotonic-image-seen");
    defer library.close();
    try library.locations.upsertImageLocked(testImageUpsert(1, "/m/cover.jpg", 5));
    const image_id = try scalar(library.database, "SELECT id FROM folder_images WHERE uri='/m/cover.jpg';");
    try library.locations.markImagesSeenLocked(&.{image_id}, 4);
    try std.testing.expectEqual(@as(i64, 5), try scalar(library.database, test_image_generation));
    try library.locations.markImagesSeenLocked(&.{image_id}, 7);
    try std.testing.expectEqual(@as(i64, 7), try scalar(library.database, test_image_generation));
}

test "a location or an image claimed by another root takes that root's generation" {
    var library = try openFolderTestLibrary("stamps-across-roots");
    defer library.close();
    try library.database.exec(
        \\INSERT INTO library_roots(id, volume_id, path) VALUES (3, 2, '/m/nested');
        \\INSERT INTO files(id) VALUES (1);
    );
    _ = try library.locations.upsert(.{ .file_id = 1, .volume_id = 2, .root_id = 1, .uri = "/m/nested/a.flac", .last_seen_generation = 9 });
    _ = try library.locations.upsert(.{ .file_id = 1, .volume_id = 2, .root_id = 3, .uri = "/m/nested/a.flac", .last_seen_generation = 1 });
    try std.testing.expectEqual(@as(i64, 3), try scalar(library.database, "SELECT root_id FROM locations WHERE uri='/m/nested/a.flac';"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT last_seen_generation FROM locations WHERE uri='/m/nested/a.flac';"));

    try library.locations.upsertImageLocked(testImageUpsert(1, "/m/nested/cover.jpg", 9));
    try library.locations.upsertImageLocked(testImageUpsert(3, "/m/nested/cover.jpg", 1));
    try std.testing.expectEqual(@as(i64, 3), try scalar(library.database, "SELECT root_id FROM folder_images WHERE uri='/m/nested/cover.jpg';"));
    try std.testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT last_seen_generation FROM folder_images WHERE uri='/m/nested/cover.jpg';"));
}
