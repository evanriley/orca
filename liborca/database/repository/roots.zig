const std = @import("std");
const sqlite = @import("../sqlite.zig");

const WriteLane = @import("write_lane.zig").WriteLane;
const refreshFolderCoverLocked = @import("locations.zig").refreshFolderCoverLocked;

pub const LibraryRoot = struct {
    id: i64,
    volume_id: i64,
    path: []u8,
    enabled: bool,

    pub fn deinit(self: LibraryRoot, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

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
        _ = try pruneOrphanedReleasesAndArtists(self.db, allocator, releases.items, artists.items);

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
            \\SELECT id, volume_id, path, enabled FROM library_roots
            \\ORDER BY id LIMIT ?1 OFFSET ?2;
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
            try roots.append(allocator, .{
                .id = statement.columnInt64(0),
                .volume_id = statement.columnInt64(1),
                .path = path,
                .enabled = statement.columnInt64(3) != 0,
            });
        }
        return .{ .allocator = allocator, .items = try roots.toOwnedSlice(allocator) };
    }
};
