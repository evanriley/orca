const std = @import("std");
const sqlite = @import("../sqlite.zig");

const WriteLane = @import("write_lane.zig").WriteLane;
const max_page = @import("../columns.zig").max_page;
const max_playlist_entries = @import("playlists.zig").max_playlist_entries;

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

pub const FolderEntryKind = enum { folder, file };

/// One child of a folder under a library root. A folder's counts cover every
/// non-missing location below it; a file's describe that one location.
pub const FolderEntry = struct {
    name: []u8,
    kind: FolderEntryKind,
    /// The Track whose preferred file this is; always null for a folder.
    track_id: ?i64,
    /// Always null for a folder.
    file_id: ?i64,
    file_count: u32,
    track_count: u32,
    total_duration_ms: i64,
};

pub const FolderPage = struct {
    allocator: std.mem.Allocator,
    items: []FolderEntry,

    pub fn deinit(self: FolderPage) void {
        for (self.items) |item| self.allocator.free(item.name);
        self.allocator.free(self.items);
    }
};

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
            \\    last_seen_generation=excluded.last_seen_generation
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

    /// Move locations a migration left on the fallback volume onto the real
    /// volume and root a scan just resolved.
    ///
    /// A migration cannot know what volume a path lives on — the storage may
    /// not even be mounted — so it parks every migrated location on the
    /// `legacy` volume in the `unverified` state. The first scan that resolves
    /// a real volume for a root claims the ones under it. Without this the
    /// scanner's `(volume_id, uri)` lookup misses every migrated row and
    /// re-imports the entire library as new files, silently orphaning every
    /// preserved lock, analysis result and health issue on the old rows.
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
    /// Only a `present` location can be unchanged. An `unverified` one — every
    /// location a migration produced — has never been confirmed by a scan and
    /// carries whatever tags the old schema had room for, so it is re-observed
    /// once and promoted rather than trusted on sight.
    /// The id of the present Location this identity already describes, or null
    /// when the entry is new or its bytes changed.
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
    ) !?i64 {
        var statement = try self.db.prepare(
            \\SELECT id FROM locations
            \\WHERE volume_id=?1 AND uri=?2 AND native_inode=?3
            \\  AND size_bytes=?4 AND modified_ns=?5 AND state='present';
        );
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindText(2, path);
        try statement.bindInt64(3, key.native_inode);
        try statement.bindInt64(4, key.size_bytes);
        try statement.bindInt64(5, key.modified_ns);
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
            \\UPDATE locations SET last_seen_generation=?2 WHERE id=?1;
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
    /// identity cascade resolves it by quick hash to the row that already
    /// exists, so the Library models it as one file at two locations. That is
    /// still the same audio stored twice, and it is what a person asking about
    /// duplicates means, so the duplicate scan reads it here rather than
    /// pretending the copy does not exist. A copy whose bytes change is split
    /// off into a file of its own and is no longer a location of this one.
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
    /// `root_id`: its subfolders, then its files.
    ///
    /// Children are found by seeking along the `(volume_id, uri)` unique
    /// index and jumping over each subfolder's range once its name is known,
    /// so a page costs the children up to its end plus the rows inside the
    /// subfolders it shows, never the whole tree. Folders are in byte order
    /// of `name/`, files in byte order of their name; paths match as stored.
    /// Missing locations are left out.
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

        var items: std.ArrayList(FolderEntry) = .empty;
        errdefer {
            for (items.items) |item| allocator.free(item.name);
            items.deinit(allocator);
        }

        var totals = try self.db.prepare(folder_totals_sql);
        defer totals.deinit();
        var subfolder_upper: std.ArrayList(u8) = .empty;
        defer subfolder_upper.deinit(allocator);

        var folders: u32 = 0;
        {
            var walk = try FolderWalk.init(self.db, allocator, &range);
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
                    .track_id = null,
                    .file_id = null,
                    .file_count = @intCast(totals.columnInt64(0)),
                    .track_count = @intCast(totals.columnInt64(1)),
                    .total_duration_ms = totals.columnInt64(2),
                });
                try totals.reset();
            }
        }
        if (items.items.len == limit) return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };

        var file_facts = try self.db.prepare(
            \\SELECT (SELECT id FROM tracks WHERE preferred_file_id=?1 ORDER BY id LIMIT 1),
            \\       (SELECT duration_ms FROM files WHERE id=?1);
        );
        defer file_facts.deinit();
        const file_offset = offset -| folders;
        var files: u32 = 0;
        var walk = try FolderWalk.init(self.db, allocator, &range);
        defer walk.deinit();
        while (items.items.len < limit) {
            const kind = try walk.next() orelse break;
            if (kind != .file) continue;
            files += 1;
            if (files <= file_offset) continue;
            try file_facts.reset();
            try file_facts.bindInt64(1, walk.file_id);
            if (try file_facts.step() != .row) return error.SqlFailed;
            const track_id: ?i64 = if (file_facts.columnIsNull(0)) null else file_facts.columnInt64(0);
            const name = try allocator.dupe(u8, walk.name.items);
            errdefer allocator.free(name);
            try items.append(allocator, .{
                .name = name,
                .kind = .file,
                .track_id = track_id,
                .file_id = walk.file_id,
                .file_count = 1,
                .track_count = if (track_id == null) 0 else 1,
                .total_duration_ms = if (file_facts.columnIsNull(1)) 0 else file_facts.columnInt64(1),
            });
        }
        return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
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
