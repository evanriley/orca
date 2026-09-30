const std = @import("std");
const sqlite = @import("../sqlite.zig");

const WriteLane = @import("write_lane.zig").WriteLane;

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
    /// A byte-identical copy never becomes a second `files` row: the scanner's
    /// identity cascade resolves it by quick hash to the row that already
    /// exists, so the Library models it as one file at two locations. That is
    /// still the same audio stored twice, and it is what a person asking about
    /// duplicates means, so the duplicate scan reads it here rather than
    /// pretending the copy does not exist.
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
};
