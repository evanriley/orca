const std = @import("std");
const sqlite = @import("../sqlite.zig");

const WriteLane = @import("write_lane.zig").WriteLane;
const MutationState = @import("mutations.zig").MutationState;
const VolumeInput = @import("volumes.zig").VolumeInput;
const VolumeRepository = @import("volumes.zig").VolumeRepository;
const refreshFolderCoverLocked = @import("locations.zig").refreshFolderCoverLocked;

/// `available`, `track_count`, `unavailable_tracks`, `volume` and
/// `last_seen_at` are filled in by a `page`, and `available` only by
/// `Runtime.libraryRootPage`, which looks at the filesystem; `list` leaves
/// them at their defaults.
pub const LibraryRoot = struct {
    id: i64,
    volume_id: i64,
    path: []u8,
    enabled: bool,
    available: bool = true,
    track_count: u64 = 0,
    unavailable_tracks: u64 = 0,
    /// The volume's label, else its stable key (`uuid:…`, `root:…`); empty
    /// when the root has no recorded volume.
    volume: []u8 = &.{},
    /// Unix seconds when the root was last read: its newest completed scan,
    /// else when its volume was last bound.
    last_seen_at: ?i64 = null,

    pub fn deinit(self: LibraryRoot, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.volume);
    }
};

pub const OfflineCounts = struct {
    tracks: u64 = 0,
    releases: u64 = 0,
};

pub const available_location =
    \\SELECT 1 FROM locations AS held
    \\WHERE held.state <> 'missing'
    \\  AND (held.root_id IS NULL OR instr(?1, ',' || held.root_id || ',') = 0)
    \\  AND
;

pub const LibraryRootPage = struct {
    allocator: std.mem.Allocator,
    items: []LibraryRoot,

    pub fn deinit(self: LibraryRootPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const RootRemoval = struct {
    allocator: std.mem.Allocator,
    files_forgotten: u64,
    tracks_removed: u64,
    /// Files that were also located outside the removed root and so remain.
    surviving_file_ids: []i64,

    pub fn deinit(self: RootRemoval) void {
        self.allocator.free(self.surviving_file_ids);
    }
};

pub const OrphanPruneCounts = struct {
    releases: u64 = 0,
    artists: u64 = 0,
};

/// Deletes the candidate releases no track references, then the artists among
/// the candidates and those releases' album artists that no track or release
/// references. Runs inside the caller's transaction; candidates may repeat.
pub fn pruneOrphanedReleasesAndArtists(
    db: sqlite.Database,
    allocator: std.mem.Allocator,
    release_candidates: []const i64,
    artist_candidates: []const i64,
    deleted_releases: ?*std.ArrayList(i64),
) !OrphanPruneCounts {
    var counts: OrphanPruneCounts = .{};
    if (release_candidates.len == 0) return counts;

    var artists: std.ArrayList(i64) = .empty;
    defer artists.deinit(allocator);
    try artists.appendSlice(allocator, artist_candidates);

    var release_in_use = try db.prepare("SELECT 1 FROM tracks WHERE release_id = ?1 LIMIT 1;");
    defer release_in_use.deinit();
    var release_artist = try db.prepare("SELECT album_artist_id FROM releases WHERE id = ?1;");
    defer release_artist.deinit();
    var delete_release = try db.prepare("DELETE FROM releases WHERE id = ?1;");
    defer delete_release.deinit();
    for (release_candidates) |release_id| {
        try release_in_use.bindInt64(1, release_id);
        const in_use = try release_in_use.step() == .row;
        try release_in_use.reset();
        if (in_use) continue;
        try release_artist.bindInt64(1, release_id);
        const found = try release_artist.step() == .row;
        if (found and !release_artist.columnIsNull(0)) try artists.append(allocator, release_artist.columnInt64(0));
        try release_artist.reset();
        if (!found) continue;
        try delete_release.bindInt64(1, release_id);
        if (try delete_release.step() != .done) return error.SqlFailed;
        try delete_release.reset();
        counts.releases += 1;
        if (deleted_releases) |deleted| try deleted.append(allocator, release_id);
    }

    var artist_in_use = try db.prepare(
        \\SELECT 1 WHERE EXISTS (SELECT 1 FROM tracks WHERE artist_id = ?1)
        \\   OR EXISTS (SELECT 1 FROM releases WHERE album_artist_id = ?1);
    );
    defer artist_in_use.deinit();
    var delete_artist = try db.prepare("DELETE FROM artists WHERE id = ?1;");
    defer delete_artist.deinit();
    for (artists.items) |artist_id| {
        try artist_in_use.bindInt64(1, artist_id);
        const in_use = try artist_in_use.step() == .row;
        try artist_in_use.reset();
        if (in_use) continue;
        try delete_artist.bindInt64(1, artist_id);
        if (try delete_artist.step() != .done) return error.SqlFailed;
        try delete_artist.reset();
        if (db.changes() == 1) counts.artists += 1;
    }
    return counts;
}

pub fn pathWithin(inner: []const u8, outer: []const u8) bool {
    return std.mem.startsWith(u8, inner, outer) and (inner.len == outer.len or inner[outer.len] == '/');
}

inline fn journalUnder(comptime column: []const u8) []const u8 {
    return "(" ++ column ++ ">=?1 || '/' AND " ++ column ++ "<?1 || '0')";
}

pub const LibraryRootRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn add(self: *LibraryRootRepository, volume_id: i64, path: []const u8) !i64 {
        if (path.len == 0) return error.InvalidLibraryRoot;
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.addLocked(volume_id, path);
    }

    pub fn addLocked(self: *LibraryRootRepository, volume_id: i64, path: []const u8) !i64 {
        var statement = try self.db.prepare(
            \\INSERT INTO library_roots(volume_id, path, enabled) VALUES (?1, ?2, 1)
            \\ON CONFLICT(path) DO UPDATE SET volume_id=excluded.volume_id
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindText(2, path);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    /// Forgets the root and everything that exists only under it, in one
    /// transaction. Only rows are deleted; no file on disk is touched.
    ///
    /// A file with a location under another root, or under no root, survives
    /// and is returned so the caller can reproject it: its tracks may have
    /// been backed by a sibling that is now gone.
    pub fn remove(
        self: *LibraryRootRepository,
        allocator: std.mem.Allocator,
        root_id: i64,
    ) !RootRemoval {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};

        {
            var exists = try self.db.prepare("SELECT 1 FROM library_roots WHERE id=?1;");
            defer exists.deinit();
            try exists.bindInt64(1, root_id);
            if (try exists.step() != .row) return error.UnknownRoot;
        }

        try self.db.exec("CREATE TEMP TABLE forgotten_files(id INTEGER PRIMARY KEY);");
        const files_forgotten = try self.execWithRoot(
            \\INSERT INTO temp.forgotten_files(id)
            \\SELECT DISTINCT file_id FROM locations AS under
            \\WHERE root_id = ?1 AND NOT EXISTS (
            \\    SELECT 1 FROM locations AS elsewhere
            \\    WHERE elsewhere.file_id = under.file_id AND elsewhere.root_id IS NOT ?1
            \\);
        , root_id);

        var surviving: std.ArrayList(i64) = .empty;
        errdefer surviving.deinit(allocator);
        {
            var statement = try self.db.prepare(
                \\SELECT DISTINCT file_id FROM locations
                \\WHERE root_id = ?1 AND file_id NOT IN (SELECT id FROM temp.forgotten_files);
            );
            defer statement.deinit();
            try statement.bindInt64(1, root_id);
            while (try statement.step() == .row) try surviving.append(allocator, statement.columnInt64(0));
        }

        var releases: std.ArrayList(i64) = .empty;
        defer releases.deinit(allocator);
        var artists: std.ArrayList(i64) = .empty;
        defer artists.deinit(allocator);
        {
            var statement = try self.db.prepare(
                \\SELECT DISTINCT release_id, artist_id FROM tracks
                \\WHERE preferred_file_id IN (SELECT id FROM temp.forgotten_files);
            );
            defer statement.deinit();
            while (try statement.step() == .row) {
                if (!statement.columnIsNull(0)) try releases.append(allocator, statement.columnInt64(0));
                if (!statement.columnIsNull(1)) try artists.append(allocator, statement.columnInt64(1));
            }
        }

        try self.db.exec("DELETE FROM tracks WHERE preferred_file_id IN (SELECT id FROM temp.forgotten_files);");
        const tracks_removed = self.db.changes();
        _ = try pruneOrphanedReleasesAndArtists(self.db, allocator, releases.items, artists.items, null);

        try self.db.exec("UPDATE mutation_operations SET file_id = NULL WHERE file_id IN (SELECT id FROM temp.forgotten_files);");
        _ = try self.execWithRoot("DELETE FROM locations WHERE root_id = ?1;", root_id);
        try self.db.exec("DELETE FROM files WHERE id IN (SELECT id FROM temp.forgotten_files);");
        _ = try self.execWithRoot("DELETE FROM library_roots WHERE id = ?1;", root_id);
        for (releases.items) |release_id| _ = try refreshFolderCoverLocked(self.db, release_id);
        try self.db.exec("DROP TABLE temp.forgotten_files;");
        try self.db.exec("COMMIT;");
        return .{
            .allocator = allocator,
            .files_forgotten = files_forgotten,
            .tracks_removed = tracks_removed,
            .surviving_file_ids = try surviving.toOwnedSlice(allocator),
        };
    }

    /// One transaction, so a crash leaves the root, every row under it and the
    /// journaled paths under it wholly at the old path or wholly at the new
    /// one.
    pub fn relocate(
        self: *LibraryRootRepository,
        allocator: std.mem.Allocator,
        root_id: i64,
        volume: VolumeInput,
        path: []const u8,
    ) !i64 {
        if (path.len == 0) return error.InvalidLibraryRoot;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};

        const old_path = old: {
            var statement = try self.db.prepare("SELECT path FROM library_roots WHERE id=?1;");
            defer statement.deinit();
            try statement.bindInt64(1, root_id);
            if (try statement.step() != .row) return error.UnknownRoot;
            break :old try allocator.dupe(u8, statement.columnText(0));
        };
        defer allocator.free(old_path);
        var volumes: VolumeRepository = .{ .db = self.db, .write_lane = self.write_lane };
        const volume_id = try volumes.ensureLocked(volume);

        {
            var taken = try self.db.prepare(
                \\SELECT 1 FROM library_roots WHERE id<>?1 AND (path=?2
                \\    OR path>=?2 || '/' AND path<?2 || '0'
                \\    OR ?2>=path || '/' AND ?2<path || '0')
                \\UNION ALL
                \\SELECT 1 FROM locations WHERE volume_id=?3 AND uri>=?2 || '/' AND uri<?2 || '0'
                \\    AND root_id IS NOT ?1
                \\UNION ALL
                \\SELECT 1 FROM folder_images WHERE volume_id=?3 AND uri>=?2 || '/' AND uri<?2 || '0'
                \\    AND root_id IS NOT ?1
                \\LIMIT 1;
            );
            defer taken.deinit();
            try taken.bindInt64(1, root_id);
            try taken.bindText(2, path);
            try taken.bindInt64(3, volume_id);
            if (try taken.step() == .row) return error.RootPathOverlaps;
        }
        if (pathWithin(path, old_path) or pathWithin(old_path, path)) {
            inline for (.{ "locations", "folder_images" }) |table| {
                var landing = try self.db.prepare(
                    "SELECT 1 FROM " ++ table ++ " AS moving JOIN " ++ table ++ " AS held\n" ++
                        "    ON held.volume_id=?3 AND held.uri=?2 || substr(moving.uri, length(?4) + 1)\n" ++
                        "    AND held.id<>moving.id\n" ++
                        "WHERE moving.root_id=?1 AND moving.uri>=?4 || '/' AND moving.uri<?4 || '0' LIMIT 1;",
                );
                defer landing.deinit();
                try landing.bindInt64(1, root_id);
                try landing.bindText(2, path);
                try landing.bindInt64(3, volume_id);
                try landing.bindText(4, old_path);
                if (try landing.step() == .row) return error.RootPathOverlaps;
            }
        }
        {
            var unfinished = try self.db.prepare(
                "SELECT state FROM mutation_operations WHERE state NOT IN (?2, ?3) AND (" ++
                    journalUnder("source_path") ++ " OR " ++ journalUnder("destination_path") ++ " OR " ++
                    journalUnder("stage_path") ++ " OR " ++ journalUnder("backup_path") ++
                    ")\nORDER BY state=?4 DESC LIMIT 1;",
            );
            defer unfinished.deinit();
            try unfinished.bindText(1, old_path);
            try unfinished.bindInt64(2, @intFromEnum(MutationState.committed));
            try unfinished.bindInt64(3, @intFromEnum(MutationState.rolled_back));
            try unfinished.bindInt64(4, @intFromEnum(MutationState.needs_reconciliation));
            if (try unfinished.step() == .row) {
                if (unfinished.columnInt64(0) == @intFromEnum(MutationState.needs_reconciliation))
                    return error.MutationNeedsReconciliation;
                return error.MutationInProgress;
            }
        }

        inline for (.{ "locations", "folder_images" }) |table| {
            var statement = try self.db.prepare(
                "UPDATE " ++ table ++ " SET volume_id=?3, uri=?2 || substr(uri, length(?4) + 1)\n" ++
                    "WHERE root_id=?1 AND uri>=?4 || '/' AND uri<?4 || '0';",
            );
            defer statement.deinit();
            try statement.bindInt64(1, root_id);
            try statement.bindText(2, path);
            try statement.bindInt64(3, volume_id);
            try statement.bindText(4, old_path);
            if (try statement.step() != .done) return error.SqlFailed;
        }
        inline for (.{ "source_path", "destination_path", "stage_path", "backup_path" }) |column| {
            var statement = try self.db.prepare(
                "UPDATE mutation_operations SET " ++ column ++ "=?2 || substr(" ++ column ++ ", length(?1) + 1)\n" ++
                    "WHERE " ++ journalUnder(column) ++ ";",
            );
            defer statement.deinit();
            try statement.bindText(1, old_path);
            try statement.bindText(2, path);
            if (try statement.step() != .done) return error.SqlFailed;
        }
        {
            var statement = try self.db.prepare("UPDATE library_roots SET path=?2, volume_id=?3 WHERE id=?1;");
            defer statement.deinit();
            try statement.bindInt64(1, root_id);
            try statement.bindText(2, path);
            try statement.bindInt64(3, volume_id);
            if (try statement.step() != .done) return error.SqlFailed;
        }
        try self.db.exec("COMMIT;");
        return volume_id;
    }

    pub fn find(self: *const LibraryRootRepository, allocator: std.mem.Allocator, root_id: i64) !?LibraryRoot {
        var statement = try self.db.prepare(
            "SELECT id, volume_id, path, enabled FROM library_roots WHERE id=?1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, root_id);
        if (try statement.step() != .row) return null;
        return .{
            .id = statement.columnInt64(0),
            .volume_id = statement.columnInt64(1),
            .path = try allocator.dupe(u8, statement.columnText(2)),
            .enabled = statement.columnInt64(3) != 0,
        };
    }

    fn execWithRoot(self: *LibraryRootRepository, sql: [:0]const u8, root_id: i64) !u64 {
        var statement = try self.db.prepare(sql);
        defer statement.deinit();
        try statement.bindInt64(1, root_id);
        if (try statement.step() != .done) return error.SqlFailed;
        return self.db.changes();
    }

    pub fn list(
        self: *const LibraryRootRepository,
        allocator: std.mem.Allocator,
    ) !LibraryRootPage {
        var statement = try self.db.prepare(
            "SELECT id, volume_id, path, enabled FROM library_roots ORDER BY id;",
        );
        defer statement.deinit();
        var roots: std.ArrayList(LibraryRoot) = .empty;
        errdefer {
            for (roots.items) |root| root.deinit(allocator);
            roots.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const path = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(path);
            try roots.append(allocator, .{
                .id = statement.columnInt64(0),
                .volume_id = statement.columnInt64(1),
                .path = path,
                .enabled = statement.columnInt64(3) != 0,
            });
        }
        return .{ .allocator = allocator, .items = try roots.toOwnedSlice(allocator) };
    }

    /// Bounded page, for the ABI: a host never receives an unbounded list, even
    /// of something as small as a root set.
    pub fn page(
        self: *const LibraryRootRepository,
        allocator: std.mem.Allocator,
        limit: u32,
        offset: u32,
    ) !LibraryRootPage {
        var statement = try self.db.prepare(
            \\SELECT library_roots.id, volume_id, path, enabled,
            \\    (SELECT count(DISTINCT tracks.id) FROM locations
            \\     JOIN tracks ON tracks.preferred_file_id = locations.file_id
            \\     WHERE locations.root_id = library_roots.id),
            \\    (SELECT count(DISTINCT tracks.id) FROM locations
            \\     JOIN tracks ON tracks.preferred_file_id = locations.file_id
            \\     WHERE locations.root_id = library_roots.id AND NOT EXISTS (
            \\         SELECT 1 FROM locations AS held
            \\         WHERE held.file_id = tracks.preferred_file_id AND held.state <> 'missing')),
            \\    COALESCE(NULLIF(volumes.label, ''), volumes.stable_key, ''),
            \\    COALESCE(
            \\        (SELECT max(finished_at) FROM scan_runs
            \\         WHERE scan_runs.root_id = library_roots.id AND scan_runs.state = 'completed'),
            \\        volumes.last_seen_at, 0)
            \\FROM library_roots
            \\LEFT JOIN volumes ON volumes.id = library_roots.volume_id
            \\ORDER BY library_roots.id LIMIT ?1 OFFSET ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        try statement.bindInt64(2, offset);
        var roots: std.ArrayList(LibraryRoot) = .empty;
        errdefer {
            for (roots.items) |root| root.deinit(allocator);
            roots.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const path = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(path);
            const volume = try allocator.dupe(u8, statement.columnText(6));
            errdefer allocator.free(volume);
            const last_seen_at = statement.columnInt64(7);
            try roots.append(allocator, .{
                .id = statement.columnInt64(0),
                .volume_id = statement.columnInt64(1),
                .path = path,
                .enabled = statement.columnInt64(3) != 0,
                .track_count = @intCast(statement.columnInt64(4)),
                .unavailable_tracks = @intCast(statement.columnInt64(5)),
                .volume = volume,
                .last_seen_at = if (last_seen_at > 0) last_seen_at else null,
            });
        }
        return .{ .allocator = allocator, .items = try roots.toOwnedSlice(allocator) };
    }

    /// Tracks and Releases that cannot play because of the roots in
    /// `offline`, a comma-delimited id list with a leading and trailing comma
    /// (",3,7,"): those with a play file under one of them and none present
    /// under any other root.
    pub fn offlineCounts(self: *const LibraryRootRepository, offline: []const u8) !OfflineCounts {
        var tracks = try self.db.prepare(
            \\SELECT count(DISTINCT tracks.id) FROM locations
            \\JOIN tracks ON tracks.preferred_file_id = locations.file_id
            \\WHERE instr(?1, ',' || locations.root_id || ',') > 0
            \\  AND NOT EXISTS (
        ++ available_location ++
            \\      held.file_id = tracks.preferred_file_id);
        );
        defer tracks.deinit();
        try tracks.bindText(1, offline);
        if (try tracks.step() != .row) return error.SqlFailed;
        var releases = try self.db.prepare(
            \\SELECT count(DISTINCT tracks.release_id) FROM locations
            \\JOIN tracks ON tracks.preferred_file_id = locations.file_id
            \\WHERE instr(?1, ',' || locations.root_id || ',') > 0
            \\  AND tracks.release_id IS NOT NULL
            \\  AND NOT EXISTS (
            \\      SELECT 1 FROM tracks AS sibling
            \\      WHERE sibling.release_id = tracks.release_id AND EXISTS (
        ++ available_location ++
            \\      held.file_id = sibling.preferred_file_id));
        );
        defer releases.deinit();
        try releases.bindText(1, offline);
        if (try releases.step() != .row) return error.SqlFailed;
        return .{
            .tracks = @intCast(tracks.columnInt64(0)),
            .releases = @intCast(releases.columnInt64(0)),
        };
    }

    /// Sets `available[i]` to whether `release_ids[i]` keeps a Track that can
    /// play while the roots in `offline` (as for `offlineCounts`) are away.
    pub fn releasesAvailable(
        self: *const LibraryRootRepository,
        offline: []const u8,
        release_ids: []const i64,
        available: []bool,
    ) !void {
        if (available.len != release_ids.len) return error.InvalidArgument;
        var statement = try self.db.prepare(
            \\SELECT EXISTS (
            \\    SELECT 1 FROM tracks JOIN locations ON locations.file_id = tracks.preferred_file_id
            \\    WHERE tracks.release_id = ?2 AND instr(?1, ',' || locations.root_id || ',') > 0)
            \\  AND NOT EXISTS (
            \\    SELECT 1 FROM tracks WHERE tracks.release_id = ?2 AND EXISTS (
        ++ available_location ++
            \\    held.file_id = tracks.preferred_file_id));
        );
        defer statement.deinit();
        for (release_ids, available) |release_id, *slot| {
            try statement.bindText(1, offline);
            try statement.bindInt64(2, release_id);
            if (try statement.step() != .row) return error.SqlFailed;
            slot.* = statement.columnInt64(0) == 0;
            try statement.reset();
        }
    }
};
