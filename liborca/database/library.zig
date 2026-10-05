const std = @import("std");
const content_hash = @import("../storage/content_hash.zig");
const ContentMeasurements = @import("content_measurements.zig").ContentMeasurements;
const metadata = @import("../metadata/model.zig");
const migrations = @import("migrations.zig");
const JournalLock = @import("../metadata/journal_lock.zig").JournalLock;
const mutation_recovery = @import("../metadata/recovery.zig");
const platform = @import("../platform.zig");
const quick_hash = @import("../storage/quick_hash.zig");
const repository = @import("repository.zig");
const sqlite = @import("sqlite.zig");

/// How a Library should decide which volume a path lives on.
pub const VolumeOptions = struct {
    /// Bypass the platform adapter. Tests and callers that already know the
    /// volume use this; nothing else should.
    stable_key: ?[]const u8 = null,
    label: []const u8 = "",
    /// Whether a volume with no filesystem UUID may have an identifier written
    /// to its mount root. Off unless a user explicitly added this root.
    allow_persist: bool = false,
    /// Whether to consult the platform adapter at all. Off exercises the
    /// root-derived fallback on a host whose storage is perfectly
    /// identifiable.
    use_platform_adapter: bool = true,
};

pub const RootBinding = struct {
    volume_id: i64,
    root_id: i64,
    /// How many locations a migration parked on the fallback volume this call
    /// claimed for the real one. Nonzero exactly once per migrated root, and
    /// reported rather than hidden so an upgrade can be audited.
    claimed_locations: u64 = 0,
};

pub const FileBinding = struct {
    file_id: i64,
    location_id: i64,
    volume_id: i64,
};

/// One independently openable Library and its serialized write connection.
pub const LibraryDatabase = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    backup_directory: ?[]u8,
    /// Where the `JournalLock` lives: `<database>.orca-journal.lock`. Null
    /// for a Library with no database file, which no other process can open.
    journal_lock_path: ?[]u8,
    walk_lock_path: ?[]u8,
    /// Set when another holder had the journal lock at open, so recovery was
    /// left to the next holder; `recoverPendingMutations` clears it.
    recovery_deferred: std.atomic.Value(bool),
    database: sqlite.Database,
    write_lane: *repository.WriteLane,
    tracks: repository.TrackRepository,
    artists: repository.ArtistRepository,
    releases: repository.ReleaseRepository,
    release_artwork: repository.ReleaseArtworkRepository,
    recordings: repository.RecordingRepository,
    volumes: repository.VolumeRepository,
    library_roots: repository.LibraryRootRepository,
    scan_runs: repository.ScanRunRepository,
    files: repository.FileRepository,
    locations: repository.LocationRepository,
    observed_tags: repository.ObservedTagsRepository,
    orca_metadata: repository.OrcaMetadataRepository,
    mutation_journal: repository.MutationJournalRepository,
    analysis_cache: repository.AnalysisCacheRepository,
    health_issues: repository.HealthIssueRepository,
    duplicate_groups: repository.DuplicateGroupRepository,
    provider_cache: repository.ProviderCacheRepository,
    provider_state: repository.ProviderStateRepository,
    scrobbles: repository.ScrobbleQueueRepository,
    listens: repository.ListenRepository,
    feedback: repository.FeedbackRepository,
    ratings: repository.RatingRepository,
    release_loves: repository.ReleaseLoveRepository,
    artist_loves: repository.ArtistLoveRepository,
    artist_info: repository.ArtistInfoRepository,
    release_info: repository.ReleaseInfoRepository,
    settings: repository.LibrarySettingsRepository,
    player_state: repository.PlayerStateRepository,
    job_history: repository.JobHistoryRepository,
    stats: repository.LibraryStatsRepository,
    fetched_cache: repository.FetchedCacheRepository,
    genres: repository.GenreRepository,
    search: repository.SearchRepository,
    track_lyrics: repository.TrackLyricsRepository,
    playlists: repository.PlaylistRepository,
    identification_proposals: repository.IdentificationProposalRepository,
    recording_verifications: repository.RecordingVerificationRepository,
    acoustid_submissions: repository.AcoustIdSubmissionRepository,

    /// Open a Library, recovering any interrupted file mutation before the
    /// caller can see it.
    ///
    /// Recovery runs at `journal_ready_version` — after the journal table
    /// exists and before any later migration rewrites what a nonterminal
    /// operation refers to. Migration 8 turns every path-keyed table into
    /// `files.id` identity, so a staged operation whose `source_path` is about
    /// to become a `file_id` must reach a terminal state first. If it cannot,
    /// the Library is not opened at all, matching the existing posture of
    /// refusing to open an unknown newer schema rather than guessing.
    ///
    /// Recovery and migration run only while this open holds the journal lock.
    /// Without it another holder is mid-mutation, and its rows are not
    /// abandoned: recovery is deferred to a later open, and a Library that
    /// still needs a migration returns `error.MutationInProgress`.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8) !LibraryDatabase {
        const owned_path = try allocator.dupeSentinel(u8, path, 0);
        errdefer allocator.free(owned_path);
        const database = try sqlite.Database.open(path);
        errdefer database.close();
        const write_lane = try allocator.create(repository.WriteLane);
        errdefer allocator.destroy(write_lane);
        write_lane.* = .{ .io = io };
        try database.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;");
        const backup_directory: ?[]u8 = if (database.filename()) |file|
            try std.fmt.allocPrint(allocator, "{s}.orca-backups", .{file})
        else
            null;
        errdefer if (backup_directory) |directory| allocator.free(directory);
        const journal_lock_path: ?[]u8 = if (database.filename()) |file|
            try std.fmt.allocPrint(allocator, "{s}.orca-journal.lock", .{file})
        else
            null;
        errdefer if (journal_lock_path) |lock_path| allocator.free(lock_path);
        const walk_lock_path: ?[]u8 = if (database.filename()) |file|
            try std.fmt.allocPrint(allocator, "{s}.orca-scan.lock", .{file})
        else
            null;
        errdefer if (walk_lock_path) |lock_path| allocator.free(lock_path);
        try migrations.applyThrough(database, migrations.journal_ready_version);
        var journal: repository.MutationJournalRepository = .{
            .db = database,
            .write_lane = write_lane,
        };
        var recovery_deferred = false;
        if (journal_lock_path) |lock_path| {
            if (try JournalLock.tryAcquire(io, lock_path)) |acquired| {
                var lock = acquired;
                defer lock.release(io);
                _ = try mutation_recovery.recoverPending(allocator, io, &journal, backup_directory, &lock, null);
                try migrations.apply(database);
                _ = try mutation_recovery.recoverPending(allocator, io, &journal, backup_directory, &lock, null);
            } else {
                std.log.info("{s}: another process holds the mutation journal; recovery waits for the next open", .{path});
                recovery_deferred = true;
                if (try migrations.userVersion(database) < migrations.current_version) return error.MutationInProgress;
            }
        } else {
            try migrations.apply(database);
        }
        return .{
            .allocator = allocator,
            .path = owned_path,
            .backup_directory = backup_directory,
            .journal_lock_path = journal_lock_path,
            .walk_lock_path = walk_lock_path,
            .recovery_deferred = .init(recovery_deferred),
            .database = database,
            .write_lane = write_lane,
            .tracks = .{ .db = database, .write_lane = write_lane },
            .artists = .{ .db = database, .write_lane = write_lane },
            .releases = .{ .db = database, .write_lane = write_lane },
            .release_artwork = .{ .db = database, .write_lane = write_lane },
            .recordings = .{ .db = database, .write_lane = write_lane },
            .volumes = .{ .db = database, .write_lane = write_lane },
            .library_roots = .{ .db = database, .write_lane = write_lane },
            .scan_runs = .{ .db = database, .write_lane = write_lane },
            .files = .{ .db = database, .write_lane = write_lane },
            .locations = .{ .db = database, .write_lane = write_lane },
            .observed_tags = .{ .db = database, .write_lane = write_lane },
            .orca_metadata = .{ .db = database, .write_lane = write_lane },
            .mutation_journal = .{ .db = database, .write_lane = write_lane },
            .analysis_cache = .{ .db = database, .write_lane = write_lane },
            .health_issues = .{ .db = database, .write_lane = write_lane },
            .duplicate_groups = .{ .db = database, .write_lane = write_lane },
            .provider_cache = .{ .db = database, .write_lane = write_lane },
            .provider_state = .{ .db = database, .write_lane = write_lane },
            .scrobbles = .{ .db = database, .write_lane = write_lane },
            .listens = .{ .db = database, .write_lane = write_lane },
            .feedback = .{ .db = database, .write_lane = write_lane },
            .ratings = .{ .db = database, .write_lane = write_lane },
            .release_loves = .{ .db = database, .write_lane = write_lane },
            .artist_loves = .{ .db = database, .write_lane = write_lane },
            .artist_info = .{ .db = database, .write_lane = write_lane },
            .release_info = .{ .db = database, .write_lane = write_lane },
            .settings = .{ .db = database, .write_lane = write_lane },
            .player_state = .{ .db = database, .write_lane = write_lane },
            .job_history = .{ .db = database, .write_lane = write_lane },
            .stats = .{ .db = database },
            .fetched_cache = .{ .db = database, .write_lane = write_lane },
            .genres = .{ .db = database, .write_lane = write_lane },
            .search = .{ .db = database },
            .track_lyrics = .{ .db = database, .write_lane = write_lane },
            .playlists = .{ .db = database, .write_lane = write_lane },
            .identification_proposals = .{ .db = database, .write_lane = write_lane },
            .recording_verifications = .{ .db = database, .write_lane = write_lane },
            .acoustid_submissions = .{ .db = database, .write_lane = write_lane },
        };
    }

    /// Finishes whatever an interrupted holder of the journal lock left
    /// behind. Every write, undo and prune runs this first, under `lock`.
    pub fn recoverPendingMutations(self: *LibraryDatabase, io: std.Io, lock: *const JournalLock) !void {
        _ = try mutation_recovery.recoverPending(
            self.allocator,
            io,
            &self.mutation_journal,
            self.backup_directory,
            lock,
            null,
        );
        self.recovery_deferred.store(false, .release);
    }

    pub fn close(self: *LibraryDatabase) void {
        self.database.close();
        self.allocator.destroy(self.write_lane);
        if (self.backup_directory) |directory| self.allocator.free(directory);
        if (self.journal_lock_path) |lock_path| self.allocator.free(lock_path);
        if (self.walk_lock_path) |lock_path| self.allocator.free(lock_path);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    /// Opens an independent read connection suitable for a bounded query or
    /// snapshot. The caller owns the returned connection.
    pub fn openReader(self: *const LibraryDatabase) !sqlite.Database {
        return sqlite.Database.openReadOnly(self.path);
    }

    /// The volume a path lives on, asking the platform adapter and falling back
    /// to a key derived from the Library root itself.
    pub fn resolveVolume(
        self: *LibraryDatabase,
        io: std.Io,
        path: []const u8,
        options: VolumeOptions,
    ) !?i64 {
        if (options.stable_key) |key|
            return try self.volumes.ensure(.{ .stable_key = key, .label = options.label });
        if (!options.use_platform_adapter) return null;
        const resolved = platform.volume.stableKey(
            self.allocator,
            io,
            path,
            .{ .allow_persist = options.allow_persist },
        ) catch null;
        if (resolved) |resolution| {
            defer resolution.deinit(self.allocator);
            return try self.volumes.ensure(.{
                .stable_key = resolution.key,
                .label = options.label,
            });
        }
        return null;
    }

    /// The volume for a path, or the fallback volume when the platform cannot
    /// name one. Every location needs a volume, so this never fails to answer.
    pub fn volumeFor(
        self: *LibraryDatabase,
        io: std.Io,
        path: []const u8,
        options: VolumeOptions,
    ) !i64 {
        return (try self.resolveVolume(io, path, options)) orelse null_volume;
    }

    /// Register a Library root and the volume it lives on.
    ///
    /// When the platform can name the volume — a filesystem UUID, or an
    /// identifier persisted at the mount root — the root is bound to that
    /// volume. When it cannot, the root itself becomes the identity
    /// (`root:<library_roots.id>`): weaker, because it cannot recognize the
    /// same storage arriving under a different path, but stable for as long as
    /// the root exists.
    pub fn ensureRoot(
        self: *LibraryDatabase,
        io: std.Io,
        path: []const u8,
        options: VolumeOptions,
    ) !RootBinding {
        if (try self.resolveVolume(io, path, options)) |volume_id| {
            const root_id = try self.library_roots.add(volume_id, path);
            return .{
                .volume_id = volume_id,
                .root_id = root_id,
                .claimed_locations = try self.locations.claimLegacyLocations(
                    null_volume,
                    volume_id,
                    root_id,
                    path,
                ),
            };
        }
        if (try self.rootVolume(path)) |existing| {
            if (existing.volume_id != null_volume) return .{
                .volume_id = existing.volume_id,
                .root_id = existing.root_id,
                .claimed_locations = try self.locations.claimLegacyLocations(
                    null_volume,
                    existing.volume_id,
                    existing.root_id,
                    path,
                ),
            };
        }
        var provisional_buffer: [64]u8 = undefined;
        const provisional = try std.fmt.bufPrint(
            &provisional_buffer,
            root_volume_key_prefix ++ "pending:{x}",
            .{std.hash.Wyhash.hash(0, path)},
        );
        const provisional_volume = try self.volumes.ensure(.{ .stable_key = provisional });
        const root_id = try self.library_roots.add(provisional_volume, path);
        var key_buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, root_volume_key_prefix ++ "{d}", .{root_id});
        if (try self.volumes.find(key)) |established| {
            try self.bindRootVolume(root_id, established);
            try self.dropVolume(provisional_volume);
            return .{
                .volume_id = established,
                .root_id = root_id,
                .claimed_locations = try self.locations.claimLegacyLocations(
                    null_volume,
                    established,
                    root_id,
                    path,
                ),
            };
        }
        try self.renameVolume(provisional_volume, key);
        return .{
            .volume_id = provisional_volume,
            .root_id = root_id,
            .claimed_locations = try self.locations.claimLegacyLocations(
                null_volume,
                provisional_volume,
                root_id,
                path,
            ),
        };
    }

    pub fn relocateRoot(
        self: *LibraryDatabase,
        io: std.Io,
        root_id: i64,
        path: []const u8,
        options: VolumeOptions,
    ) !RootBinding {
        const existing = (try self.library_roots.find(self.allocator, root_id)) orelse return error.UnknownRoot;
        defer existing.deinit(self.allocator);
        if (!std.mem.eql(u8, existing.path, path) and
            (repository.pathWithin(path, existing.path) or repository.pathWithin(existing.path, path)))
        {
            if (std.Io.Dir.cwd().access(io, existing.path, .{})) |_| return error.RootPathOverlaps else |_| {}
        }
        var lock: ?JournalLock = if (self.journal_lock_path) |lock_path|
            try JournalLock.tryAcquire(io, lock_path) orelse return error.MutationInProgress
        else
            null;
        defer if (lock) |*held| held.release(io);
        const resolved = if (options.stable_key == null and options.use_platform_adapter)
            platform.volume.stableKey(self.allocator, io, path, .{ .allow_persist = options.allow_persist }) catch null
        else
            null;
        defer if (resolved) |resolution| resolution.deinit(self.allocator);
        var key_buffer: [32]u8 = undefined;
        const key = options.stable_key orelse if (resolved) |resolution|
            resolution.key
        else
            try std.fmt.bufPrint(&key_buffer, root_volume_key_prefix ++ "{d}", .{root_id});
        const volume_id = try self.library_roots.relocate(
            self.allocator,
            root_id,
            .{ .stable_key = key, .label = options.label },
            path,
        );
        return .{ .volume_id = volume_id, .root_id = root_id, .claimed_locations = 0 };
    }

    /// Resolve the file a path names, creating `files` and `locations` rows for
    /// it when no scan has seen it yet.
    ///
    /// This is the identity cascade a scan runs: the same path on the same
    /// volume, then the same inode/size/mtime elsewhere on that volume, then a
    /// file with the same quick hash whose content hash proves the bytes
    /// equal. It is what lets `orca-cli analyze` cache a result against a file
    /// rather than a path. A path whose bytes diverged from a file still
    /// present elsewhere becomes a file of its own, as a scan would make it.
    pub fn resolveOrCreateFile(
        self: *LibraryDatabase,
        io: std.Io,
        path: []const u8,
        options: VolumeOptions,
    ) !FileBinding {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        const digest = try quick_hash.fromFile(io, file, stat.size);
        const volume_id = try self.volumeFor(io, path, options);
        const identity: repository.StorageIdentityKey = .{
            .volume_id = volume_id,
            .native_inode = @bitCast(@as(u64, stat.inode)),
            .size_bytes = @intCast(stat.size),
            .modified_ns = @intCast(stat.mtime.nanoseconds),
        };
        var measurements: ContentMeasurements = .{};
        defer measurements.deinit(self.allocator);
        var own: ?content_hash.Digest = null;
        if (try self.files.reachesQuickHash(path, identity, &digest)) {
            own = try content_hash.fromFile(io, file, stat.size);
            try measurements.measureNominees(self.allocator, io, &self.files, path, identity, &digest);
        }
        const own_digest: ?*const content_hash.Digest = if (own) |*bytes| bytes else null;
        const upsert: repository.FileUpsert = .{
            .size_bytes = identity.size_bytes,
            .quick_hash = &digest,
            .content_hash = if (own_digest) |bytes| bytes else null,
        };

        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.database.exec("BEGIN IMMEDIATE;");
        errdefer self.database.exec("ROLLBACK;") catch {};
        const file_id = switch (try self.files.resolveForBytes(path, identity, &digest, measurements.evidence(own_digest))) {
            .new => try self.files.createLocked(upsert),
            .same => |id| same: {
                try self.files.updateLocked(id, upsert);
                if (own_digest == null) try self.files.forgetUnheldContentHashLocked(id, identity);
                break :same id;
            },
            .diverged => |shared| try self.files.forkLocked(shared, path, upsert),
        };
        const location_id = try self.locations.upsertLocked(.{
            .file_id = file_id,
            .volume_id = volume_id,
            .uri = path,
            .native_inode = identity.native_inode,
            .size_bytes = identity.size_bytes,
            .modified_ns = identity.modified_ns,
            .state = .present,
        });
        try self.database.exec("COMMIT;");
        return .{ .file_id = file_id, .location_id = location_id, .volume_id = volume_id };
    }

    /// The volume every path with no better identity falls back to. It exists
    /// from migration 8 onward, and pre-identity rows already point at it.
    pub const null_volume: i64 = 1;

    /// The prefix of the key a root takes as its own volume when the platform
    /// names none: `root:<library_roots.id>`.
    pub const root_volume_key_prefix = "root:";

    /// The stable key of the volume a root is bound to, or null for the
    /// legacy volume, which records none. The caller owns the key.
    pub fn recordedVolumeKey(self: *LibraryDatabase, allocator: std.mem.Allocator, volume_id: i64) !?[]u8 {
        if (volume_id == null_volume) return null;
        return try self.volumes.stableKey(allocator, volume_id) orelse error.UnknownVolume;
    }

    fn rootVolume(self: *LibraryDatabase, path: []const u8) !?RootBinding {
        var statement = try self.database.prepare(
            "SELECT id, volume_id FROM library_roots WHERE path=?1;",
        );
        defer statement.deinit();
        try statement.bindText(1, path);
        if (try statement.step() != .row) return null;
        return .{ .root_id = statement.columnInt64(0), .volume_id = statement.columnInt64(1) };
    }

    fn bindRootVolume(self: *LibraryDatabase, root_id: i64, volume_id: i64) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.database.prepare(
            "UPDATE library_roots SET volume_id=?1 WHERE id=?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindInt64(2, root_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    fn renameVolume(self: *LibraryDatabase, volume_id: i64, stable_key: []const u8) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.database.prepare(
            "UPDATE volumes SET stable_key=?1 WHERE id=?2;",
        );
        defer statement.deinit();
        try statement.bindText(1, stable_key);
        try statement.bindInt64(2, volume_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    fn dropVolume(self: *LibraryDatabase, volume_id: i64) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.database.prepare("DELETE FROM volumes WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }
};

test "provider cache distinguishes fresh and stale responses" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-provider-cache?mode=memory&cache=shared",
    );
    defer library.close();
    try library.provider_cache.put("musicbrainz", "recording:orca", 200, "candidate", 200);
    const fresh = (try library.provider_cache.get(
        std.testing.allocator,
        "musicbrainz",
        "recording:orca",
        100,
        false,
    )).?;
    defer fresh.deinit();
    try std.testing.expectEqualStrings("candidate", fresh.body);
    try std.testing.expect((try library.provider_cache.get(
        std.testing.allocator,
        "musicbrainz",
        "recording:orca",
        300,
        false,
    )) == null);
    const stale = (try library.provider_cache.get(
        std.testing.allocator,
        "musicbrainz",
        "recording:orca",
        300,
        true,
    )).?;
    defer stale.deinit();
}

test "library health state is atomically replaced and paged" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-health?mode=memory&cache=shared",
    );
    defer library.close();
    const file_id = try library.files.create(.{ .size_bytes = 100 });
    _ = try library.locations.upsert(.{
        .file_id = file_id,
        .volume_id = LibraryDatabase.null_volume,
        .uri = "music/track.flac",
    });
    try library.health_issues.replaceFile(file_id, &.{
        .{ .kind = .clipping, .severity = .warning, .details = "3 clipped samples" },
        .{ .kind = .missing_analysis, .severity = .information },
    });
    try std.testing.expectEqual(@as(u64, 2), try library.health_issues.count());
    var page = try library.health_issues.page(std.testing.allocator, 10, 0);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqual(repository.HealthIssueKind.clipping, page.items[0].kind);
    // The issue reports the location a host should show without becoming
    // path-keyed itself.
    try std.testing.expectEqualStrings("music/track.flac", page.items[0].path);
    try library.health_issues.replaceFile(file_id, &.{});
    try std.testing.expectEqual(@as(u64, 0), try library.health_issues.count());
}

fn openHealthLibrary(comptime name: []const u8) !LibraryDatabase {
    return LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-health-" ++ name ++ "?mode=memory&cache=shared",
    );
}

fn addHealthFile(library: *LibraryDatabase, uri: []const u8, hash: ?[]const u8) !i64 {
    const file_id = try library.files.create(.{ .size_bytes = 100, .quick_hash = hash });
    _ = try library.locations.upsert(.{ .file_id = file_id, .volume_id = LibraryDatabase.null_volume, .uri = uri });
    return file_id;
}

fn setQuickHash(library: *LibraryDatabase, file_id: i64, hash: u8) !void {
    var sql: [96]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(&sql, "UPDATE files SET quick_hash = x'{x:0>2}' WHERE id = {d};", .{ hash, file_id }, 0));
}

test "a dismissed health issue stays hidden until its file's bytes change, and shows again once restored" {
    var library = try openHealthLibrary("dismiss");
    defer library.close();
    const hash: [32]u8 = @splat(1);
    const file_id = try addHealthFile(&library, "music/hashed.flac", &hash);
    const unhashed = try addHealthFile(&library, "music/unhashed.flac", null);
    try library.health_issues.replaceFile(file_id, &.{
        .{ .kind = .clipping, .severity = .warning, .details = "3 clipped samples" },
        .{ .kind = .missing_analysis, .severity = .information },
    });
    try library.health_issues.replaceFile(unhashed, &.{.{ .kind = .clipping, .severity = .warning }});
    try std.testing.expectEqual(@as(u64, 3), try library.health_issues.count());

    try library.health_issues.dismiss(file_id, .clipping);
    try library.health_issues.dismiss(unhashed, .clipping);
    try library.health_issues.dismiss(file_id, .unreadable_file);

    try std.testing.expectEqual(@as(u64, 1), try library.health_issues.count());
    var dismissed = try library.health_issues.page(std.testing.allocator, 10, 0);
    defer dismissed.deinit();
    try std.testing.expectEqual(@as(usize, 1), dismissed.items.len);
    try std.testing.expectEqual(repository.HealthIssueKind.missing_analysis, dismissed.items[0].kind);
    try std.testing.expectEqual(@as(i64, 3), try testScalar(library.database, "SELECT count(*) FROM library_health_issues;"));

    try setQuickHash(&library, file_id, 2);
    try std.testing.expectEqual(@as(u64, 2), try library.health_issues.count());
    var changed = try library.health_issues.page(std.testing.allocator, 10, 0);
    defer changed.deinit();
    try std.testing.expectEqual(@as(usize, 2), changed.items.len);
    try std.testing.expectEqual(repository.HealthIssueKind.clipping, changed.items[0].kind);
    try std.testing.expectEqual(file_id, changed.items[0].file_id);

    try library.health_issues.dismiss(file_id, .clipping);
    try std.testing.expectEqual(@as(u64, 1), try library.health_issues.count());
    try library.health_issues.restore(file_id, .clipping);
    try library.health_issues.restore(file_id, .clipping);
    try library.health_issues.restore(unhashed, .clipping);
    try std.testing.expectEqual(@as(u64, 3), try library.health_issues.count());
    try std.testing.expectError(error.UnknownFile, library.health_issues.dismiss(unhashed + 100, .clipping));

    try library.health_issues.dismiss(file_id, .clipping);
    try library.database.exec("DELETE FROM locations;");
    var sql: [64]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(&sql, "DELETE FROM files WHERE id = {d};", .{file_id}, 0));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT count(*) FROM health_dismissals;"));
}

fn addKindFixture(library: *LibraryDatabase) ![3]i64 {
    const first = try addHealthFile(library, "music/first.flac", null);
    const second = try addHealthFile(library, "music/second.flac", null);
    const third = try addHealthFile(library, "music/third.flac", null);
    try library.health_issues.replaceFile(first, &.{
        .{ .kind = .clipping, .severity = .warning },
        .{ .kind = .missing_track_number, .severity = .information },
    });
    try library.health_issues.replaceFile(second, &.{
        .{ .kind = .clipping, .severity = .information },
        .{ .kind = .corrupt_audio, .severity = .error_severity },
    });
    try library.health_issues.replaceFile(third, &.{
        .{ .kind = .clipping, .severity = .warning },
        .{ .kind = .missing_track_number, .severity = .information },
    });
    return .{ first, second, third };
}

fn expectSummary(library: *LibraryDatabase, expected: []const repository.HealthKindSummary) !void {
    const summary = try library.health_issues.summary();
    try std.testing.expectEqualSlices(repository.HealthKindSummary, expected, summary.items());
}

test "the health summary counts each kind's visible issues and names the highest severity among them" {
    var library = try openHealthLibrary("summary");
    defer library.close();
    _ = try addKindFixture(&library);

    try expectSummary(&library, &.{
        .{ .kind = .corrupt_audio, .severity = .error_severity, .count = 1, .files = 1, .bytes = 100 },
        .{ .kind = .clipping, .severity = .warning, .count = 3, .files = 3, .bytes = 300 },
        .{ .kind = .missing_track_number, .severity = .information, .count = 2, .files = 2, .bytes = 200 },
    });
    var total: u64 = 0;
    for ((try library.health_issues.summary()).items()) |entry| total += entry.count;
    try std.testing.expectEqual(try library.health_issues.count(), total);
}

fn addSizedHealthFile(library: *LibraryDatabase, uri: []const u8, size_bytes: i64) !i64 {
    const file_id = try library.files.create(.{ .size_bytes = size_bytes });
    _ = try library.locations.upsert(.{ .file_id = file_id, .volume_id = LibraryDatabase.null_volume, .uri = uri });
    return file_id;
}

fn summaryOf(library: *LibraryDatabase, kind: repository.HealthIssueKind) !?repository.HealthKindSummary {
    const summary = try library.health_issues.summary();
    for (summary.items()) |entry| if (entry.kind == kind) return entry;
    return null;
}

test "the health summary counts each kind's distinct files and sums their sizes" {
    var library = try openHealthLibrary("summary-sizes");
    defer library.close();
    const small = try addSizedHealthFile(&library, "music/small.flac", 1_000);
    const large = try addSizedHealthFile(&library, "music/large.flac", 250_000);
    try library.health_issues.replaceFile(small, &.{
        .{ .kind = .clipping, .severity = .warning },
        .{ .kind = .missing_track_number, .severity = .information },
    });
    try library.health_issues.replaceFile(large, &.{.{ .kind = .clipping, .severity = .information }});

    try expectSummary(&library, &.{
        .{ .kind = .clipping, .severity = .warning, .count = 2, .files = 2, .bytes = 251_000 },
        .{ .kind = .missing_track_number, .severity = .information, .count = 1, .files = 1, .bytes = 1_000 },
    });
}

test "duplicate bytes in the health summary count only the redundant copies, not the copy that is kept" {
    var library = try openHealthLibrary("summary-duplicates");
    defer library.close();
    const ten_megabytes = 10_000_000;
    const kept = try addSizedHealthFile(&library, "music/kept.flac", ten_megabytes);
    const first_copy = try addSizedHealthFile(&library, "music/copy-1.flac", ten_megabytes);
    const second_copy = try addSizedHealthFile(&library, "music/copy-2.flac", ten_megabytes);
    try library.health_issues.replaceFile(kept, &.{.{ .kind = .exact_duplicate, .severity = .warning, .related_file_id = first_copy }});
    try library.health_issues.replaceFile(first_copy, &.{.{ .kind = .exact_duplicate, .severity = .warning, .related_file_id = kept }});
    try library.health_issues.replaceFile(second_copy, &.{.{ .kind = .exact_duplicate, .severity = .warning, .related_file_id = kept }});
    try std.testing.expectEqual(repository.HealthKindSummary{
        .kind = .exact_duplicate,
        .severity = .warning,
        .count = 3,
        .files = 3,
        .bytes = 2 * ten_megabytes,
    }, (try summaryOf(&library, .exact_duplicate)).?);

    const resembles = try addSizedHealthFile(&library, "music/resembles.mp3", 4_000);
    const resembled = try addSizedHealthFile(&library, "music/resembled.flac", 30_000);
    const also_resembles = try addSizedHealthFile(&library, "music/also.ogg", 5_000);
    try library.health_issues.replaceFile(resembles, &.{.{ .kind = .likely_duplicate, .severity = .information, .related_file_id = resembled }});
    try library.health_issues.replaceFile(resembled, &.{.{ .kind = .likely_duplicate, .severity = .information, .related_file_id = also_resembles }});
    try library.health_issues.replaceFile(also_resembles, &.{.{ .kind = .likely_duplicate, .severity = .information, .related_file_id = resembled }});
    try std.testing.expectEqual(@as(u64, 35_000), (try summaryOf(&library, .likely_duplicate)).?.bytes);

    const located_twice = try addSizedHealthFile(&library, "music/twice-a.flac", 7_000);
    _ = try library.locations.upsert(.{ .file_id = located_twice, .volume_id = LibraryDatabase.null_volume, .uri = "music/twice-b.flac" });
    _ = try library.locations.upsert(.{ .file_id = located_twice, .volume_id = LibraryDatabase.null_volume, .uri = "music/twice-c.flac", .state = .missing });
    try library.health_issues.replaceFile(located_twice, &.{.{ .kind = .exact_duplicate, .severity = .warning }});
    try std.testing.expectEqual(@as(u64, 2 * ten_megabytes + 7_000), (try summaryOf(&library, .exact_duplicate)).?.bytes);
}

test "dismissed issues count toward neither the files nor the bytes of the health summary" {
    var library = try openHealthLibrary("summary-sizes-dismissed");
    defer library.close();
    const kept = try addSizedHealthFile(&library, "music/kept.flac", 6_000);
    const copy = try addSizedHealthFile(&library, "music/copy.flac", 6_000);
    const loud = try addSizedHealthFile(&library, "music/loud.flac", 2_000);
    try library.health_issues.replaceFile(kept, &.{
        .{ .kind = .exact_duplicate, .severity = .warning, .related_file_id = copy },
        .{ .kind = .clipping, .severity = .warning },
    });
    try library.health_issues.replaceFile(copy, &.{.{ .kind = .exact_duplicate, .severity = .warning, .related_file_id = kept }});
    try library.health_issues.replaceFile(loud, &.{.{ .kind = .clipping, .severity = .warning }});

    try library.health_issues.dismiss(copy, .exact_duplicate);
    try library.health_issues.dismiss(loud, .clipping);
    try expectSummary(&library, &.{
        .{ .kind = .clipping, .severity = .warning, .count = 1, .files = 1, .bytes = 6_000 },
        .{ .kind = .exact_duplicate, .severity = .warning, .count = 1, .files = 1, .bytes = 0 },
    });
}

test "an empty library has an empty health summary" {
    var library = try openHealthLibrary("summary-empty");
    defer library.close();
    try expectSummary(&library, &.{});
}

test "a dismissed health issue leaves the summary and its kind's page, and returns to both once restored" {
    var library = try openHealthLibrary("summary-dismiss");
    defer library.close();
    const files = try addKindFixture(&library);

    try library.health_issues.dismiss(files[1], .corrupt_audio);
    try library.health_issues.dismiss(files[0], .clipping);
    try expectSummary(&library, &.{
        .{ .kind = .clipping, .severity = .warning, .count = 2, .files = 2, .bytes = 200 },
        .{ .kind = .missing_track_number, .severity = .information, .count = 2, .files = 2, .bytes = 200 },
    });
    var dismissed = try library.health_issues.pageOfKind(std.testing.allocator, .clipping, 10, 0);
    defer dismissed.deinit();
    try std.testing.expectEqual(@as(usize, 2), dismissed.items.len);
    try std.testing.expectEqual(files[2], dismissed.items[0].file_id);
    try std.testing.expectEqual(files[1], dismissed.items[1].file_id);
    var corrupt = try library.health_issues.pageOfKind(std.testing.allocator, .corrupt_audio, 10, 0);
    defer corrupt.deinit();
    try std.testing.expectEqual(@as(usize, 0), corrupt.items.len);

    try library.health_issues.restore(files[1], .corrupt_audio);
    try library.health_issues.restore(files[0], .clipping);
    try expectSummary(&library, &.{
        .{ .kind = .corrupt_audio, .severity = .error_severity, .count = 1, .files = 1, .bytes = 100 },
        .{ .kind = .clipping, .severity = .warning, .count = 3, .files = 3, .bytes = 300 },
        .{ .kind = .missing_track_number, .severity = .information, .count = 2, .files = 2, .bytes = 200 },
    });
    var restored = try library.health_issues.pageOfKind(std.testing.allocator, .clipping, 10, 0);
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 3), restored.items.len);
}

test "a page of one health kind holds only that kind, in the order of the full page, within its limit and offset" {
    var library = try openHealthLibrary("kind-page");
    defer library.close();
    const files = try addKindFixture(&library);

    var full = try library.health_issues.page(std.testing.allocator, 10, 0);
    defer full.deinit();
    var expected: std.ArrayList(i64) = .empty;
    defer expected.deinit(std.testing.allocator);
    for (full.items) |issue| if (issue.kind == .clipping) try expected.append(std.testing.allocator, issue.file_id);
    try std.testing.expectEqualSlices(i64, &.{ files[0], files[2], files[1] }, expected.items);

    var all = try library.health_issues.pageOfKind(std.testing.allocator, .clipping, 10, 0);
    defer all.deinit();
    try std.testing.expectEqual(expected.items.len, all.items.len);
    for (expected.items, all.items) |file_id, issue| {
        try std.testing.expectEqual(file_id, issue.file_id);
        try std.testing.expectEqual(repository.HealthIssueKind.clipping, issue.kind);
    }

    var middle = try library.health_issues.pageOfKind(std.testing.allocator, .clipping, 1, 1);
    defer middle.deinit();
    try std.testing.expectEqual(@as(usize, 1), middle.items.len);
    try std.testing.expectEqual(files[2], middle.items[0].file_id);
    try std.testing.expectEqual(repository.HealthSeverity.warning, middle.items[0].severity);

    var tail = try library.health_issues.pageOfKind(std.testing.allocator, .clipping, 2, 2);
    defer tail.deinit();
    try std.testing.expectEqual(@as(usize, 1), tail.items.len);
    try std.testing.expectEqual(files[1], tail.items[0].file_id);

    var past = try library.health_issues.pageOfKind(std.testing.allocator, .clipping, 10, 3);
    defer past.deinit();
    try std.testing.expectEqual(@as(usize, 0), past.items.len);
}

test "each health issue names the lowest Track its file backs, that Track's Release, and the action that resolves it" {
    var library = try openHealthLibrary("targets");
    defer library.close();
    const tagged = try library.releases.upsert(.{
        .release_key = "nick drake|bryter layter",
        .title = "Bryter Layter",
        .musicbrainz_release_id = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
    });
    const untagged = try library.releases.upsert(.{ .release_key = "nick drake|pink moon", .title = "Pink Moon" });
    const shared = try addHealthFile(&library, "music/shared.flac", null);
    const fetchable = try addHealthFile(&library, "music/fetchable.flac", null);
    const loose = try addHealthFile(&library, "music/loose.flac", null);
    try library.tracks.upsertTracks(&.{
        .{ .title = "First", .release_id = untagged, .preferred_file_id = shared },
        .{ .title = "Second", .release_id = tagged, .preferred_file_id = shared },
        .{ .title = "Third", .release_id = tagged, .preferred_file_id = fetchable },
    });
    const first = try testScalar(library.database, "SELECT id FROM tracks WHERE title = 'First';");
    try std.testing.expect(first < try testScalar(library.database, "SELECT id FROM tracks WHERE title = 'Second';"));
    const third = try testScalar(library.database, "SELECT id FROM tracks WHERE title = 'Third';");
    try library.health_issues.replaceFile(shared, &.{
        .{ .kind = .artwork_problem, .severity = .information },
        .{ .kind = .exact_duplicate, .severity = .information, .related_file_id = loose },
        .{ .kind = .missing_track_number, .severity = .information },
    });
    try library.health_issues.replaceFile(fetchable, &.{
        .{ .kind = .artwork_problem, .severity = .information },
        .{ .kind = .recording_mismatch, .severity = .warning },
    });
    try library.health_issues.replaceFile(loose, &.{
        .{ .kind = .unreadable_file, .severity = .error_severity },
        .{ .kind = .likely_duplicate, .severity = .information, .related_file_id = shared },
    });

    var page = try library.health_issues.page(std.testing.allocator, 10, 0);
    defer page.deinit();
    const Expected = struct {
        file_id: i64,
        kind: repository.HealthIssueKind,
        track_id: ?i64,
        release_id: ?i64,
        related_file_id: ?i64 = null,
        action: repository.HealthAction,
    };
    const expected = [_]Expected{
        .{ .file_id = loose, .kind = .unreadable_file, .track_id = null, .release_id = null, .action = .reveal_file },
        .{ .file_id = fetchable, .kind = .recording_mismatch, .track_id = third, .release_id = tagged, .action = .review_correction },
        .{ .file_id = shared, .kind = .missing_track_number, .track_id = first, .release_id = untagged, .action = .match_or_edit },
        .{ .file_id = shared, .kind = .artwork_problem, .track_id = first, .release_id = untagged, .action = .match_or_edit },
        .{ .file_id = fetchable, .kind = .artwork_problem, .track_id = third, .release_id = tagged, .action = .fetch_cover_art },
        .{ .file_id = shared, .kind = .exact_duplicate, .track_id = first, .release_id = untagged, .related_file_id = loose, .action = .compare_duplicate },
        .{ .file_id = loose, .kind = .likely_duplicate, .track_id = null, .release_id = null, .related_file_id = shared, .action = .compare_duplicate },
    };
    try std.testing.expectEqual(expected.len, page.items.len);
    for (expected, page.items) |want, issue| {
        try std.testing.expectEqual(want.file_id, issue.file_id);
        try std.testing.expectEqual(want.kind, issue.kind);
        try std.testing.expectEqual(want.track_id, issue.track_id);
        try std.testing.expectEqual(want.release_id, issue.release_id);
        try std.testing.expectEqual(want.related_file_id, issue.related_file_id);
        try std.testing.expectEqual(want.action, issue.action);
    }
}

test "artwork issues on one Release share its fetch action whether the release ID is tagged or named by an accepted match" {
    var library = try openHealthLibrary("artwork-actions");
    defer library.close();
    const tagged = try library.releases.upsert(.{
        .release_key = "nick drake|bryter layter",
        .title = "Bryter Layter",
        .musicbrainz_release_id = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
    });
    const matched = try library.releases.upsert(.{ .release_key = "nick drake|pink moon", .title = "Pink Moon" });
    const unknown = try library.releases.upsert(.{ .release_key = "nick drake|five leaves left", .title = "Five Leaves Left" });
    const releases = [_]i64{ tagged, tagged, matched, matched, unknown, unknown };
    var file_ids: [releases.len]i64 = undefined;
    for (releases, &file_ids, 0..) |release_id, *file_id, index| {
        var uri: [32]u8 = undefined;
        file_id.* = try addHealthFile(&library, try std.fmt.bufPrint(&uri, "music/{d}.flac", .{index}), null);
        try library.tracks.upsertTracks(&.{.{ .title = "Song", .track_number = @intCast(index + 1), .release_id = release_id, .preferred_file_id = file_id.* }});
        try library.health_issues.replaceFile(file_id.*, &.{.{ .kind = .artwork_problem, .severity = .information }});
    }
    try std.testing.expectEqual(matched, try testScalar(library.database, "SELECT release_id FROM tracks WHERE track_number = 3;"));
    const proposal = try putProposal(&library, file_ids[2], match_mbid, 0.9, "{\"title\":\"Song\",\"release_mbid\":\"2b3c4d5e-6f70-4812-9a3b-4c5d6e7f8091\"}");
    var sql: [96]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(&sql, "UPDATE identification_proposals SET state = 1 WHERE id = {d};", .{proposal}, 0));

    var page = try library.health_issues.page(std.testing.allocator, 10, 0);
    defer page.deinit();
    try std.testing.expectEqual(releases.len, page.items.len);
    for (page.items, file_ids, releases) |issue, file_id, release_id| {
        try std.testing.expectEqual(file_id, issue.file_id);
        try std.testing.expectEqual(@as(?i64, release_id), issue.release_id);
        const expected: repository.HealthAction = if (release_id == unknown) .match_or_edit else .fetch_cover_art;
        try std.testing.expectEqual(expected, issue.action);
    }
}

test "listing, counting and summarising health issues reach kinds, dismissals and Tracks through indexes" {
    var library = try openHealthLibrary("plans");
    defer library.close();
    const health = @import("repository/health.zig");
    const plans = [_][]u8{
        try queryPlan(&library, health.health_page_sql),
        try queryPlan(&library, health.health_count_sql),
        try queryPlan(&library, health.health_page_of_kind_sql),
        try queryPlan(&library, health.health_summary_sql),
    };
    defer for (plans) |plan| std.testing.allocator.free(plan);
    for (plans) |plan| {
        try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN health_dismissals") == null);
        try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN files") == null);
        try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN tracks") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, plans[0], "tracks_by_preferred_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, plans[0], "tracks_by_recording") != null);
    try std.testing.expect(std.mem.indexOf(u8, plans[2], "SEARCH library_health_issues USING INDEX library_health_by_kind (kind=?)") != null);
    try std.testing.expect(std.mem.indexOf(u8, plans[3], "SCAN library_health_issues USING COVERING INDEX library_health_by_kind") != null);
}

test "duplicate bytes reach one kind's issues and their links through indexes and never scan files" {
    var library = try openHealthLibrary("reclaimable-plan");
    defer library.close();
    const plan = try queryPlan(&library, @import("repository/health.zig").health_reclaimable_sql);
    defer std.testing.allocator.free(plan);
    try std.testing.expect(std.mem.indexOf(u8, plan, "SEARCH library_health_issues USING INDEX library_health_by_kind (kind=?)") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "library_health_by_related") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN files") == null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN health_dismissals") == null);
}

test "library stats read each present file once, in id order, through a single scan of locations, and the latest analysis through an index" {
    var library = try openHealthLibrary("stats-plan");
    defer library.close();
    const plan = try queryPlan(&library, repository.library_stats_sql);
    defer std.testing.allocator.free(plan);
    try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN locations\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "SEARCH files USING INTEGER PRIMARY KEY (rowid=?)") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN files") == null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "USE TEMP B-TREE FOR ORDER BY") == null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "SEARCH analysis_results USING COVERING INDEX analysis_results_created") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN analysis_results") == null);
}

test "the file behind a health issue reports its properties and its best location, or that every location is missing" {
    var library = try openHealthLibrary("file");
    defer library.close();
    const file_id = try library.files.create(.{
        .codec = "flac",
        .size_bytes = 4096,
        .sample_rate = 44_100,
        .bit_depth = 16,
        .channels = 2,
        .duration_ms = 15_000,
    });
    _ = try library.locations.upsert(.{ .file_id = file_id, .volume_id = LibraryDatabase.null_volume, .uri = "music/gone.flac", .state = .missing });
    _ = try library.locations.upsert(.{ .file_id = file_id, .volume_id = LibraryDatabase.null_volume, .uri = "music/here.flac" });

    const found = (try library.health_issues.file(std.testing.allocator, file_id)).?;
    defer found.deinit();
    try std.testing.expectEqualStrings("music/here.flac", found.path.?);
    try std.testing.expect(!found.missing);
    try std.testing.expectEqualStrings("flac", found.codec);
    try std.testing.expectEqual(@as(?u32, 44_100), found.sample_rate);
    try std.testing.expectEqual(@as(?u32, 16), found.bit_depth);
    try std.testing.expectEqual(@as(?u32, 2), found.channels);
    try std.testing.expectEqual(@as(?i64, 4096), found.size_bytes);
    try std.testing.expectEqual(@as(?i64, 15_000), found.duration_ms);

    try library.database.exec("UPDATE locations SET state = 'missing';");
    const lost = (try library.health_issues.file(std.testing.allocator, file_id)).?;
    defer lost.deinit();
    try std.testing.expect(lost.missing);
    try std.testing.expectEqual(@as(?[]u8, null), lost.path);
    try std.testing.expectEqual(@as(?repository.HealthFile, null), try library.health_issues.file(std.testing.allocator, file_id + 1));
}

test "independent libraries retain separate state and FTS indexes" {
    var first = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-first?mode=memory&cache=shared",
    );
    defer first.close();
    var second = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-second?mode=memory&cache=shared",
    );
    defer second.close();

    try first.tracks.upsertTracks(&.{.{
        .title = "Northern Sky",
        .album = "Bryter Layter",
        .album_artist = "Nick Drake",
    }});
    try second.tracks.upsertTracks(&.{.{
        .title = "Orca",
        .album = "Promises",
        .album_artist = "Floating Points",
    }});

    var page = try first.tracks.search(std.testing.allocator, "Northern", .{ .limit = 25 });
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqualStrings("Northern Sky", page.items[0].title);
    try std.testing.expectEqual(@as(u64, 1), try first.tracks.count());
    try std.testing.expectEqual(@as(u64, 1), try second.tracks.count());
}

test "a full page of ratings is written in one transaction and a larger page is refused" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-batch?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec(
        \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 513)
        \\INSERT INTO recordings(id, title) SELECT i, 'Batch track' FROM n;
        \\INSERT INTO tracks(id, recording_id, title) SELECT id, id, title FROM recordings;
    );

    var ids: [513]i64 = undefined;
    for (&ids, 1..) |*id, value| id.* = @intCast(value);
    try std.testing.expectError(error.PageOutOfRange, library.ratings.set(&ids, 80));
    const change = try library.ratings.set(ids[0..repository.max_page], 80);
    try std.testing.expectEqual(@as(u32, repository.max_page), change.updated);
    try std.testing.expectEqual(
        @as(i64, repository.max_page),
        try testScalar(library.database, "SELECT count(*) FROM ratings WHERE rating = 80;"),
    );
}

test "WAL readers remain available while write submissions serialize" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/library.db",
        .{temporary.sub_path},
        0,
    );
    defer std.testing.allocator.free(path);

    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, path);
    defer library.close();
    const reader = try library.openReader();
    defer reader.close();

    {
        var journal_mode = try reader.prepare("PRAGMA journal_mode;");
        defer journal_mode.deinit();
        try std.testing.expectEqual(sqlite.Step.row, try journal_mode.step());
        try std.testing.expectEqualStrings("wal", journal_mode.columnText(0));
    }

    const Writer = struct {
        fn run(tracks: *repository.TrackRepository, failed: *std.atomic.Value(bool)) void {
            var batch: [250]repository.TrackInput = undefined;
            for (&batch) |*track| track.* = .{ .title = "Concurrent track" };
            tracks.upsertTracks(&batch) catch failed.store(true, .release);
        }
    };
    var failed: std.atomic.Value(bool) = .init(false);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Writer.run, .{ &library.tracks, &failed });
    }

    const read_repository = repository.TrackRepository{
        .db = reader,
        .write_lane = library.write_lane,
    };
    _ = try read_repository.count();
    for (threads) |thread| thread.join();

    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1000), try read_repository.count());
}

test "Orca metadata persists provenance and user locks separately from observations" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-metadata?mode=memory&cache=shared",
    );
    defer library.close();
    const file_id = try library.files.create(.{ .audio_format = 2, .size_bytes = 100 });
    _ = try library.locations.upsert(.{
        .file_id = file_id,
        .volume_id = LibraryDatabase.null_volume,
        .uri = "/music/example.flac",
        .native_inode = 1,
        .size_bytes = 100,
        .modified_ns = 200,
    });
    try library.observed_tags.upsert(.{
        .file_id = file_id,
        .values = .{ .title = "Observed title" },
    });
    try library.orca_metadata.upsert(.{
        .file_id = file_id,
        .field = .title,
        .value = "Curated title",
        .provenance = .user,
        .locked = true,
    });
    try library.orca_metadata.upsert(.{
        .file_id = file_id,
        .field = .title,
        .value = "Provider refresh",
        .provenance = .provider,
    });
    const value = (try library.orca_metadata.get(
        std.testing.allocator,
        file_id,
        .title,
    )).?;
    defer value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Curated title", value.text);
    try std.testing.expectEqual(@import("../metadata/model.zig").Provenance.user, value.provenance);
    try std.testing.expect(value.locked);
    const observed = (try library.observed_tags.get(std.testing.allocator, file_id)).?;
    defer observed.deinit();
    try std.testing.expectEqualStrings("Observed title", observed.values.title.?);
}

test "analysis cache reuses exact identities and invalidates selectively" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-analysis-cache?mode=memory&cache=shared",
    );
    defer library.close();
    const parameter_hash: [32]u8 = @splat(7);
    const file_id = try library.files.create(.{ .size_bytes = 4096 });
    const key: repository.AnalysisCacheKey = .{
        .file_id = file_id,
        .kind = 1,
        .algorithm_id = "orca.diagnostics",
        .algorithm_version = 1,
        .parameter_hash = parameter_hash,
        .source_identity = @splat(3),
    };
    try library.analysis_cache.put(key, "\x00cached\xff");
    const cached = (try library.analysis_cache.get(std.testing.allocator, key)).?;
    defer std.testing.allocator.free(cached);
    try std.testing.expectEqualSlices(u8, "\x00cached\xff", cached);

    var changed_version = key;
    changed_version.algorithm_version = 2;
    try std.testing.expect((try library.analysis_cache.get(
        std.testing.allocator,
        changed_version,
    )) == null);
    // A tag write changes size and mtime but not the audio; only a different
    // quick hash — different bytes — invalidates the entry.
    var changed_source = key;
    changed_source.source_identity[0] += 1;
    try std.testing.expect((try library.analysis_cache.get(
        std.testing.allocator,
        changed_source,
    )) == null);

    try library.analysis_cache.put(changed_version, "version two");
    const version_two = (try library.analysis_cache.get(
        std.testing.allocator,
        changed_version,
    )).?;
    defer std.testing.allocator.free(version_two);
    try std.testing.expectEqualStrings("version two", version_two);
    const version_one = (try library.analysis_cache.get(std.testing.allocator, key)).?;
    defer std.testing.allocator.free(version_one);
    try std.testing.expectEqualSlices(u8, "\x00cached\xff", version_one);
}

test "reopening drives a nonterminal journal record out of staged state" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/mutation-journal.db",
        .{temporary.sub_path},
        0,
    );
    defer std.testing.allocator.free(path);
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, path);
    const operation = try library.mutation_journal.prepare(.{
        .plan_id = 9,
        .group_id = 3,
        .action_index = 0,
        .kind = .write_tags,
        .source_path = "/music/generated.mp3",
        .expected_size = 1024,
        .expected_modified_ns = 55,
        .expected_quick_hash = quick_hash.zero,
    });
    try library.mutation_journal.transition(operation, .planned, .staged, null);
    library.close();

    // Startup recovery runs inside `open`, before the caller sees the Library.
    // This record names no stage or backup path, so its original state cannot
    // be proven and reconciliation — not a claimed rollback — is the honest
    // terminal outcome.
    library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, path);
    defer library.close();
    try std.testing.expectEqual(
        repository.MutationState.needs_reconciliation,
        try library.mutation_journal.state(operation),
    );
    try std.testing.expectError(
        error.StaleMutationOperation,
        library.mutation_journal.transition(operation, .staged, .committed, null),
    );
}

fn expectAudioHash(library: *LibraryDatabase, file_id: i64, expected: ?[]const u8) !void {
    var statement = try library.database.prepare("SELECT audio_hash FROM files WHERE id = ?1;");
    defer statement.deinit();
    try statement.bindInt64(1, file_id);
    try std.testing.expectEqual(sqlite.Step.row, try statement.step());
    if (expected) |bytes| {
        try std.testing.expectEqualSlices(u8, bytes, statement.columnBlob(0));
    } else {
        try std.testing.expect(statement.columnIsNull(0));
    }
}

test "a file's audio hash survives an update only while its quick hash stays the same" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-audio-hash?mode=memory&cache=shared",
    );
    defer library.close();
    const original_bytes: [32]u8 = @splat(1);
    const changed_bytes: [32]u8 = @splat(2);
    const measured_audio: [32]u8 = @splat(0xaa);
    const remeasured_audio: [32]u8 = @splat(0xbb);
    const file_id = try library.files.create(.{
        .audio_format = 1,
        .size_bytes = 4096,
        .quick_hash = &original_bytes,
        .audio_hash = &measured_audio,
    });

    try library.files.update(file_id, .{ .audio_format = 1, .size_bytes = 4096, .quick_hash = &original_bytes });
    try expectAudioHash(&library, file_id, &measured_audio);

    try library.files.update(file_id, .{ .audio_format = 1, .size_bytes = 4097, .quick_hash = &changed_bytes });
    try expectAudioHash(&library, file_id, null);

    try library.files.update(file_id, .{
        .audio_format = 1,
        .size_bytes = 4097,
        .quick_hash = &original_bytes,
        .audio_hash = &remeasured_audio,
    });
    try expectAudioHash(&library, file_id, &remeasured_audio);
}

fn expectContentHash(library: *LibraryDatabase, file_id: i64, expected: ?[]const u8) !void {
    var statement = try library.database.prepare(
        "SELECT content_hash, content_hash_algorithm FROM files WHERE id = ?1;",
    );
    defer statement.deinit();
    try statement.bindInt64(1, file_id);
    try std.testing.expectEqual(sqlite.Step.row, try statement.step());
    if (expected) |bytes| {
        try std.testing.expectEqualSlices(u8, bytes, statement.columnBlob(0));
        try std.testing.expectEqual(@as(i64, 1), statement.columnInt64(1));
    } else {
        try std.testing.expect(statement.columnIsNull(0));
        try std.testing.expect(statement.columnIsNull(1));
    }
}

test "a file's content hash and its algorithm survive an update only while its quick hash stays the same" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-content-hash?mode=memory&cache=shared",
    );
    defer library.close();
    const original_bytes: [32]u8 = @splat(1);
    const changed_bytes: [32]u8 = @splat(2);
    const measured: [32]u8 = @splat(0xaa);
    const remeasured: [32]u8 = @splat(0xbb);
    const file_id = try library.files.create(.{
        .audio_format = 1,
        .size_bytes = 4096,
        .quick_hash = &original_bytes,
        .content_hash = &measured,
    });
    try expectContentHash(&library, file_id, &measured);

    try library.files.update(file_id, .{ .audio_format = 1, .size_bytes = 4096, .quick_hash = &original_bytes });
    try expectContentHash(&library, file_id, &measured);

    try library.files.update(file_id, .{ .audio_format = 1, .size_bytes = 4096, .quick_hash = &changed_bytes });
    try expectContentHash(&library, file_id, null);

    try library.files.update(file_id, .{
        .audio_format = 1,
        .size_bytes = 4096,
        .quick_hash = &changed_bytes,
        .content_hash = &remeasured,
    });
    try expectContentHash(&library, file_id, &remeasured);

    const unhashed = try library.files.create(.{ .audio_format = 1, .size_bytes = 10 });
    try expectContentHash(&library, unhashed, null);
}

test "a renamed file keeps its identity and everything attached to it" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-rename?mode=memory&cache=shared",
    );
    defer library.close();
    const volume_id = try library.volumes.ensure(.{ .stable_key = "test:rename" });
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
    const location_id = try library.locations.upsert(.{
        .file_id = file_id,
        .volume_id = volume_id,
        .uri = "/music/old/name.flac",
        .native_inode = 42,
        .size_bytes = 4096,
        .modified_ns = 99,
    });
    try library.observed_tags.upsert(.{
        .file_id = file_id,
        .values = .{ .title = "Northern Sky", .album = "Bryter Layter" },
    });
    try library.orca_metadata.upsert(.{
        .file_id = file_id,
        .field = .title,
        .value = "Curated title",
        .provenance = .user,
        .locked = true,
    });
    const key: repository.AnalysisCacheKey = .{
        .file_id = file_id,
        .kind = 1,
        .algorithm_id = "orca.audio-diagnostics",
        .algorithm_version = 1,
        .parameter_hash = @splat(0),
        .source_identity = @splat(5),
    };
    try library.analysis_cache.put(key, "loudness");
    try library.health_issues.replaceFile(file_id, &.{
        .{ .kind = .clipping, .severity = .warning, .details = "3 clipped samples" },
    });

    // The move: the same bytes under a different name.
    try library.locations.move(location_id, "/music/new/name.flac");

    try std.testing.expectEqual(
        @as(?i64, file_id),
        try library.files.resolveByUri(volume_id, "/music/new/name.flac"),
    );
    try std.testing.expect(
        (try library.files.resolveByUri(volume_id, "/music/old/name.flac")) == null,
    );
    try std.testing.expectEqual(@as(u64, 1), try library.files.count());
    try std.testing.expectEqual(@as(u64, 1), try library.locations.count());

    const observed = (try library.observed_tags.get(std.testing.allocator, file_id)).?;
    defer observed.deinit();
    try std.testing.expectEqualStrings("Northern Sky", observed.values.title.?);
    const curated = (try library.orca_metadata.get(std.testing.allocator, file_id, .title)).?;
    defer curated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Curated title", curated.text);
    try std.testing.expect(curated.locked);
    const cached = (try library.analysis_cache.get(std.testing.allocator, key)).?;
    defer std.testing.allocator.free(cached);
    try std.testing.expectEqualStrings("loudness", cached);
    try std.testing.expectEqual(@as(u64, 1), try library.health_issues.count());
    var page = try library.health_issues.page(std.testing.allocator, 10, 0);
    defer page.deinit();
    try std.testing.expectEqualStrings("/music/new/name.flac", page.items[0].path);
}

fn countForFile(library: *LibraryDatabase, sql: [:0]const u8, file_id: i64) !i64 {
    var statement = try library.database.prepare(sql);
    defer statement.deinit();
    try statement.bindInt64(1, file_id);
    if (try statement.step() != .row) return error.SqlFailed;
    return statement.columnInt64(0);
}

test "forking a file copies Orca's values with no written-at mark and nothing else" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-fork?mode=memory&cache=shared",
    );
    defer library.close();
    const volume_id = try library.volumes.ensure(.{ .stable_key = "test:fork" });
    const shared_bytes: [32]u8 = @splat(1);
    const forked_bytes: [32]u8 = @splat(2);
    const measured_audio: [32]u8 = @splat(0xaa);
    const shared = try library.files.create(.{
        .audio_format = 1,
        .size_bytes = 4096,
        .quick_hash = &shared_bytes,
        .audio_hash = &measured_audio,
    });
    for ([_][]const u8{ "/music/a/song.flac", "/music/b/song.flac" }) |uri| {
        _ = try library.locations.upsert(.{ .file_id = shared, .volume_id = volume_id, .uri = uri });
    }
    try library.observed_tags.upsert(.{ .file_id = shared, .values = .{ .title = "Northern Sky" } });
    try library.orca_metadata.upsert(.{
        .file_id = shared,
        .field = .title,
        .value = "Curated title",
        .provenance = .user,
        .locked = true,
    });
    try library.orca_metadata.upsert(.{
        .file_id = shared,
        .field = .album,
        .value = "Bryter Layter",
        .provenance = .provider,
    });
    try library.orca_metadata.markWritten(shared, .album, "Bryter Layter");
    try library.analysis_cache.put(.{
        .file_id = shared,
        .kind = 1,
        .algorithm_id = "orca.audio-diagnostics",
        .algorithm_version = 1,
        .parameter_hash = @splat(0),
        .source_identity = shared_bytes,
    }, "loudness");
    try library.health_issues.replaceFile(shared, &.{
        .{ .kind = .clipping, .severity = .warning, .details = "3 clipped samples" },
    });
    var journal = try library.database.prepare(
        \\INSERT INTO mutation_operations(
        \\    plan_id, group_id, action_index, kind, file_id, source_path,
        \\    expected_size, expected_modified_ns, state
        \\) VALUES (1, 1, ?1, 0, ?2, ?3, 4096, 5, 2);
    );
    defer journal.deinit();
    for ([_][]const u8{ "/music/a/song.flac", "/music/b/song.flac" }, 0..) |uri, index| {
        try journal.reset();
        try journal.bindInt64(1, @intCast(index));
        try journal.bindInt64(2, shared);
        try journal.bindText(3, uri);
        try std.testing.expectEqual(sqlite.Step.done, try journal.step());
    }

    library.write_lane.acquire();
    try library.database.exec("BEGIN IMMEDIATE;");
    const fresh = try library.files.forkLocked(shared, "/music/a/song.flac", .{
        .audio_format = 1,
        .size_bytes = 2048,
        .quick_hash = &forked_bytes,
    });
    try library.database.exec("COMMIT;");
    library.write_lane.release();

    try std.testing.expect(fresh != shared);
    for ([_]i64{ shared, fresh }) |file_id| {
        var values = try library.orca_metadata.values(std.testing.allocator, file_id);
        defer values.deinit();
        try std.testing.expectEqual(@as(usize, 2), values.items.len);
        try std.testing.expectEqualStrings("Curated title", values.items[0].text);
        try std.testing.expectEqual(metadata.Provenance.user, values.items[0].provenance);
        try std.testing.expect(values.items[0].locked);
        try std.testing.expectEqualStrings("Bryter Layter", values.items[1].text);
        try std.testing.expectEqual(metadata.Provenance.provider, values.items[1].provenance);
        try std.testing.expect(!values.items[1].locked);
    }
    const written_sql = "SELECT count(*) FROM orca_metadata_values WHERE file_id=?1 AND written_at IS NOT NULL;";
    try std.testing.expectEqual(@as(i64, 1), try countForFile(&library, written_sql, shared));
    try std.testing.expectEqual(@as(i64, 0), try countForFile(&library, written_sql, fresh));

    try std.testing.expectEqual(@as(i64, 2048), try countForFile(&library, "SELECT size_bytes FROM files WHERE id=?1;", fresh));
    try std.testing.expectEqual(@as(i64, 1), try countForFile(&library, "SELECT count(*) FROM files WHERE id=?1 AND audio_hash IS NULL;", fresh));
    try expectAudioHash(&library, shared, &measured_audio);
    try std.testing.expect((try library.observed_tags.get(std.testing.allocator, fresh)) == null);
    inline for (.{
        "SELECT count(*) FROM analysis_results WHERE file_id=?1;",
        "SELECT count(*) FROM library_health_issues WHERE file_id=?1;",
        "SELECT count(*) FROM locations WHERE file_id=?1;",
    }) |sql| {
        try std.testing.expectEqual(@as(i64, 0), try countForFile(&library, sql, fresh));
        try std.testing.expect(try countForFile(&library, sql, shared) > 0);
    }

    var journaled = try library.database.prepare(
        "SELECT source_path FROM mutation_operations WHERE file_id=?1;",
    );
    defer journaled.deinit();
    for ([_]struct { file_id: i64, path: []const u8 }{
        .{ .file_id = fresh, .path = "/music/a/song.flac" },
        .{ .file_id = shared, .path = "/music/b/song.flac" },
    }) |expected| {
        try journaled.reset();
        try journaled.bindInt64(1, expected.file_id);
        try std.testing.expectEqual(sqlite.Step.row, try journaled.step());
        try std.testing.expectEqualStrings(expected.path, journaled.columnText(0));
        try std.testing.expectEqual(sqlite.Step.done, try journaled.step());
    }
}

test "analyzing a path whose bytes diverged from a shared file splits it as a scan would" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const flac = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "fixtures/audio/tagged-reference.flac",
        std.testing.allocator,
        .limited(1 << 22),
    );
    defer std.testing.allocator.free(flac);
    const opus = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "fixtures/audio/tagged-reference.opus",
        std.testing.allocator,
        .limited(1 << 22),
    );
    defer std.testing.allocator.free(opus);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "first.flac", .data = flac });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "second.flac", .data = flac });
    const first = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/first.flac", .{temporary.sub_path});
    defer std.testing.allocator.free(first);
    const second = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/second.flac", .{temporary.sub_path});
    defer std.testing.allocator.free(second);

    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-analyze-diverged?mode=memory&cache=shared",
    );
    defer library.close();
    const options: VolumeOptions = .{ .stable_key = "test:analyze-diverged" };
    const shared = (try library.resolveOrCreateFile(std.testing.io, first, options)).file_id;
    try std.testing.expectEqual(shared, (try library.resolveOrCreateFile(std.testing.io, second, options)).file_id);
    try library.orca_metadata.upsert(.{
        .file_id = shared,
        .field = .title,
        .value = "Curated title",
        .provenance = .user,
        .locked = true,
    });

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "first.flac", .data = opus });
    const binding = try library.resolveOrCreateFile(std.testing.io, first, options);
    try std.testing.expect(binding.file_id != shared);
    try std.testing.expectEqual(@as(u64, 2), try library.files.count());
    try std.testing.expectEqual(@as(?i64, binding.file_id), try library.files.resolveByUri(binding.volume_id, first));
    try std.testing.expectEqual(@as(?i64, shared), try library.files.resolveByUri(binding.volume_id, second));
    const carried = (try library.orca_metadata.get(std.testing.allocator, binding.file_id, .title)).?;
    defer carried.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Curated title", carried.text);
    try std.testing.expect(carried.locked);

    try std.testing.expectEqual(binding.file_id, (try library.resolveOrCreateFile(std.testing.io, first, options)).file_id);
    try std.testing.expectEqual(shared, (try library.resolveOrCreateFile(std.testing.io, second, options)).file_id);
    try std.testing.expectEqual(@as(u64, 2), try library.files.count());
}

test "analyzing paths whose quick hashes collide joins only those with equal bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const bytes = try std.testing.allocator.alloc(u8, 4 * quick_hash.window_bytes);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    bytes[bytes.len / 2] = 1;
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "one.bin", .data = bytes });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "copy.bin", .data = bytes });
    bytes[bytes.len / 2] = 2;
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "two.bin", .data = bytes });
    var paths: [3][]u8 = undefined;
    for (&paths, [_][]const u8{ "one.bin", "two.bin", "copy.bin" }) |*path, name| {
        path.* = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ temporary.sub_path, name });
    }
    defer for (paths) |path| std.testing.allocator.free(path);

    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-analyze-quick-hash-twins?mode=memory&cache=shared",
    );
    defer library.close();
    const options: VolumeOptions = .{ .stable_key = "test:analyze-quick-hash-twins" };
    const one = (try library.resolveOrCreateFile(std.testing.io, paths[0], options)).file_id;
    try expectContentHash(&library, one, null);
    const two = (try library.resolveOrCreateFile(std.testing.io, paths[1], options)).file_id;
    try std.testing.expect(two != one);
    try std.testing.expectEqual(one, (try library.resolveOrCreateFile(std.testing.io, paths[2], options)).file_id);
    try std.testing.expectEqual(@as(u64, 2), try library.files.count());
    try expectContentHash(&library, one, &(try content_hash.fromPath(std.testing.io, paths[0])));
    try expectContentHash(&library, two, &(try content_hash.fromPath(std.testing.io, paths[1])));
}

test "observed tags round trip every field a reader can produce" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-observed-tags?mode=memory&cache=shared",
    );
    defer library.close();
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 1 });
    const genres = [_][]const u8{ "Folk", "Baroque Pop" };
    try library.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = "Northern Sky",
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .album_artist = "Nick Drake",
        .composer = "Nick Drake",
        .track_number = 8,
        .track_total = 10,
        .disc_number = 1,
        .disc_total = 1,
        .date = "1971-03-01",
        .original_date = "1971",
        .genres = &genres,
        .compilation = false,
        .label = "Island",
        .media = "12\" Vinyl",
        .isrc = "GBAYE7100123",
        .release_country = "GB",
        .release_type = "album",
        .release_status = "official",
        .musicbrainz_recording_id = "recording-id",
        .musicbrainz_release_id = "release-id",
        .musicbrainz_release_group_id = "release-group-id",
        .musicbrainz_release_track_id = "release-track-id",
        .musicbrainz_artist_id = "artist-id",
        .musicbrainz_album_artist_id = "album-artist-id",
        .artwork = .{ .mime_type = "image/jpeg", .byte_size = 51200, .kind = .front_cover },
    } });

    const stored = (try library.observed_tags.get(std.testing.allocator, file_id)).?;
    defer stored.deinit();
    const values = stored.values;
    try std.testing.expectEqualStrings("Northern Sky", values.title.?);
    try std.testing.expectEqualStrings("Nick Drake", values.composer.?);
    try std.testing.expectEqual(@as(?u32, 10), values.track_total);
    try std.testing.expectEqual(@as(?u32, 1), values.disc_total);
    try std.testing.expectEqualStrings("1971", values.original_date.?);
    try std.testing.expectEqual(@as(?bool, false), values.compilation);
    try std.testing.expectEqualStrings("Island", values.label.?);
    try std.testing.expectEqualStrings("GBAYE7100123", values.isrc.?);
    try std.testing.expectEqualStrings("official", values.release_status.?);
    // The MusicBrainz release id is the projection's strongest grouping key.
    try std.testing.expectEqualStrings("release-id", values.musicbrainz_release_id.?);
    try std.testing.expectEqualStrings("album-artist-id", values.musicbrainz_album_artist_id.?);
    try std.testing.expectEqual(@as(u64, 51200), values.artwork.?.byte_size);
    try std.testing.expectEqual(
        @import("../metadata/model.zig").ArtworkKind.front_cover,
        values.artwork.?.kind,
    );
    // Genres keep their order and their multiplicity.
    try std.testing.expectEqual(@as(usize, 2), values.genres.len);
    try std.testing.expectEqualStrings("Folk", values.genres[0]);
    try std.testing.expectEqualStrings("Baroque Pop", values.genres[1]);

    // Re-observing a file with fewer genres does not leave the old ones behind.
    try library.observed_tags.upsert(.{
        .file_id = file_id,
        .values = .{ .title = "Northern Sky", .genres = genres[0..1] },
    });
    const reobserved = (try library.observed_tags.get(std.testing.allocator, file_id)).?;
    defer reobserved.deinit();
    try std.testing.expectEqual(@as(usize, 1), reobserved.values.genres.len);
    try std.testing.expect(reobserved.values.album == null);
}

test "a Track resolves to the location its preferred file lives at" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-playable?mode=memory&cache=shared",
    );
    defer library.close();
    const volume_id = try library.volumes.ensure(.{
        .stable_key = "uuid:test",
        .label = "Test volume",
    });
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
    _ = try library.locations.upsert(.{
        .file_id = file_id,
        .volume_id = volume_id,
        .uri = "/music/northern-sky.flac",
    });
    try library.tracks.upsertTracks(&.{.{
        .title = "Northern Sky",
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .album_artist = "Nick Drake",
        .preferred_file_id = file_id,
    }});

    var page = try library.tracks.page(std.testing.allocator, .{ .limit = 10, .offset = 0 });
    defer page.deinit();
    try std.testing.expectEqualStrings("Nick Drake", page.items[0].artist);
    try std.testing.expect(page.items[0].has_playable_file);

    const resolved = (try library.tracks.playableLocation(
        std.testing.allocator,
        page.items[0].id,
    )).?;
    defer resolved.deinit();
    try std.testing.expectEqual(file_id, resolved.file_id);
    try std.testing.expectEqualStrings("uuid:test", resolved.volume_stable_key);
    try std.testing.expectEqualStrings("/music/northern-sky.flac", resolved.uri);
    try std.testing.expectEqual(@as(u8, 1), resolved.audio_format);

    // A Track with no file behind it is reported as unplayable rather than
    // failing at the point a host tries to start it.
    try library.tracks.upsertTracks(&.{.{ .title = "Orphan" }});
    var second = try library.tracks.page(std.testing.allocator, .{ .limit = 10, .offset = 1 });
    defer second.deinit();
    try std.testing.expect(!second.items[0].has_playable_file);
    try std.testing.expect(
        (try library.tracks.playableLocation(std.testing.allocator, second.items[0].id)) == null,
    );
}

test "a root on unidentifiable storage becomes its own volume identity" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-roots?mode=memory&cache=shared",
    );
    defer library.close();

    // No stable key and no permission to persist one: the root itself is the
    // only identity available, and it must still be stable across calls.
    const first = try library.ensureRoot(std.testing.io, "/music/unidentified", .{
        .use_platform_adapter = false,
    });
    const second = try library.ensureRoot(std.testing.io, "/music/unidentified", .{
        .use_platform_adapter = false,
    });
    try std.testing.expectEqual(first.root_id, second.root_id);
    try std.testing.expectEqual(first.volume_id, second.volume_id);
    const key = (try library.volumes.stableKey(std.testing.allocator, first.volume_id)).?;
    defer std.testing.allocator.free(key);
    var expected: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&expected, "root:{d}", .{first.root_id}),
        key,
    );

    const named = try library.ensureRoot(std.testing.io, "/music/named", .{
        .stable_key = "uuid:1234",
        .label = "Music drive",
    });
    try std.testing.expect(named.volume_id != first.volume_id);
    var roots = try library.library_roots.list(std.testing.allocator);
    defer roots.deinit();
    try std.testing.expectEqual(@as(usize, 2), roots.items.len);
    try std.testing.expectEqualStrings("/music/unidentified", roots.items[0].path);
    try std.testing.expect(roots.items[0].enabled);
}

test "scan runs take a fresh generation per root and record how they ended" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-scan-runs?mode=memory&cache=shared",
    );
    defer library.close();
    const binding = try library.ensureRoot(std.testing.io, "/music", .{
        .stable_key = "uuid:scan-runs",
    });
    const first = try library.scan_runs.begin(binding.root_id);
    try std.testing.expectEqual(@as(i64, 1), first.generation);
    try library.scan_runs.finish(first.id, .completed, .{ .files_seen = 3, .changed = 3 });
    try std.testing.expectEqual(
        repository.ScanRunState.completed,
        try library.scan_runs.outcome(first.id),
    );
    const second = try library.scan_runs.begin(binding.root_id);
    try std.testing.expectEqual(@as(i64, 2), second.generation);
    try library.scan_runs.cancel(second.id, .{});
    try std.testing.expectEqual(
        repository.ScanRunState.cancelled,
        try library.scan_runs.outcome(second.id),
    );
    // A finished run is terminal; a late second report is refused rather than
    // rewriting how the run ended.
    try std.testing.expectError(
        error.StaleScanRun,
        library.scan_runs.finish(second.id, .completed, .{}),
    );
}

test "a completed run marks only the locations it did not reach as missing" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-sweep?mode=memory&cache=shared",
    );
    defer library.close();
    const binding = try library.ensureRoot(std.testing.io, "/music", .{
        .stable_key = "uuid:sweep",
    });
    const seen = try library.files.create(.{ .size_bytes = 1 });
    const unseen = try library.files.create(.{ .size_bytes = 2 });
    const seen_location = try library.locations.upsert(.{
        .file_id = seen,
        .volume_id = binding.volume_id,
        .root_id = binding.root_id,
        .uri = "/music/present.flac",
        .last_seen_generation = 4,
    });
    const unseen_location = try library.locations.upsert(.{
        .file_id = unseen,
        .volume_id = binding.volume_id,
        .root_id = binding.root_id,
        .uri = "/music/vanished.flac",
        .last_seen_generation = 3,
    });

    try std.testing.expectEqual(
        @as(u64, 1),
        try library.files.markMissingBelowGeneration(binding.root_id, 4),
    );
    try std.testing.expectEqual(
        repository.LocationState.present,
        try library.locations.stateOf(seen_location),
    );
    // Missing, never deleted: an unmounted drive must not eat a library.
    try std.testing.expectEqual(
        repository.LocationState.missing,
        try library.locations.stateOf(unseen_location),
    );
    try std.testing.expectEqual(@as(u64, 2), try library.files.count());
}

test "a directory sweep marks only unreached locations below that directory, never a sibling sharing its name's prefix" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-sweep-under?mode=memory&cache=shared",
    );
    defer library.close();
    const binding = try library.ensureRoot(std.testing.io, "/music", .{
        .stable_key = "uuid:sweep-under",
    });
    const Row = struct { uri: []const u8, generation: i64, expected: repository.LocationState };
    const rows = [_]Row{
        .{ .uri = "/music/A/New/gone.flac", .generation = 3, .expected = .missing },
        .{ .uri = "/music/A/New/deep/gone.flac", .generation = 3, .expected = .missing },
        .{ .uri = "/music/A/New/kept.flac", .generation = 4, .expected = .present },
        .{ .uri = "/music/A/Newer/other.flac", .generation = 3, .expected = .present },
        .{ .uri = "/music/A/New.flac", .generation = 3, .expected = .present },
        .{ .uri = "/music/A/Nevv/other.flac", .generation = 3, .expected = .present },
        .{ .uri = "/music/B/other.flac", .generation = 3, .expected = .present },
    };
    var ids: [rows.len]i64 = undefined;
    for (rows, &ids, 0..) |row, *id, index| id.* = try library.locations.upsert(.{
        .file_id = try library.files.create(.{ .size_bytes = @intCast(index + 1) }),
        .volume_id = binding.volume_id,
        .root_id = binding.root_id,
        .uri = row.uri,
        .last_seen_generation = row.generation,
    });

    try std.testing.expectEqual(
        @as(u64, 2),
        try library.files.markMissingBelowGenerationUnder(binding.volume_id, binding.root_id, 4, "/music/A/New"),
    );
    for (rows, ids) |row, id| {
        try std.testing.expectEqual(row.expected, try library.locations.stateOf(id));
    }
    try std.testing.expectEqual(
        @as(i64, 3),
        try testScalar(library.database, "SELECT last_seen_generation FROM locations WHERE uri='/music/A/Newer/other.flac';"),
    );
}

test "a directory sweep reads a uri range of the volume's unique index, never the whole root" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-sweep-under-plan?mode=memory&cache=shared",
    );
    defer library.close();
    const plan = try queryPlan(&library, repository.mark_missing_under_sql);
    defer std.testing.allocator.free(plan);
    try std.testing.expect(std.mem.indexOf(u8, plan, "sqlite_autoindex_locations_1 (volume_id=? AND uri>? AND uri<?)") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "locations_sweep") == null);
}

fn locationOf(library: *LibraryDatabase, file_id: i64) !struct { volume_id: i64, uri: []u8 } {
    var statement = try library.database.prepare("SELECT volume_id, uri FROM locations WHERE file_id=?1;");
    defer statement.deinit();
    try statement.bindInt64(1, file_id);
    if (try statement.step() != .row) return error.LocationNotFound;
    return .{
        .volume_id = statement.columnInt64(0),
        .uri = try std.testing.allocator.dupe(u8, statement.columnText(1)),
    };
}

test "relocating a root moves the locations under it and keeps every id, and a path nested with another root's is refused" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-relocate-root?mode=memory&cache=shared",
    );
    defer library.close();
    const moving = try library.ensureRoot(std.testing.io, "/music/old", .{ .stable_key = "uuid:old" });
    const other = try library.ensureRoot(std.testing.io, "/music/other", .{ .stable_key = "uuid:other" });

    const Placed = struct { uri: []const u8, binding: RootBinding, state: repository.LocationState };
    const placed = [_]Placed{
        .{ .uri = "/music/old/a.flac", .binding = moving, .state = .present },
        .{ .uri = "/music/old/sub/b.flac", .binding = moving, .state = .missing },
        .{ .uri = "/music/other/c.flac", .binding = other, .state = .present },
    };
    var file_ids: [placed.len]i64 = undefined;
    for (placed, &file_ids, 0..) |item, *file_id, index| {
        file_id.* = try library.files.create(.{ .audio_format = 1, .size_bytes = 1 });
        _ = try library.locations.upsert(.{
            .file_id = file_id.*,
            .volume_id = item.binding.volume_id,
            .root_id = item.binding.root_id,
            .uri = item.uri,
            .state = item.state,
        });
        var title: [16]u8 = undefined;
        try library.tracks.upsertTracks(&.{.{
            .title = try std.fmt.bufPrint(&title, "Entry {d}", .{index}),
            .preferred_file_id = file_id.*,
        }});
    }
    var tracks_before = try library.tracks.page(std.testing.allocator, .{ .limit = 8, .offset = 0 });
    defer tracks_before.deinit();
    try std.testing.expectEqual(@as(u64, 1), try library.tracks.missingFileCount());

    var roots = try library.library_roots.page(std.testing.allocator, 8, 0);
    defer roots.deinit();
    try std.testing.expectEqual(@as(u64, 2), roots.items[0].track_count);
    try std.testing.expectEqual(@as(u64, 1), roots.items[0].unavailable_tracks);
    try std.testing.expectEqual(@as(u64, 1), roots.items[1].track_count);
    try std.testing.expectEqual(@as(u64, 0), roots.items[1].unavailable_tracks);

    const moved_volume = try library.library_roots.relocate(std.testing.allocator, moving.root_id, .{ .stable_key = "uuid:moved" }, "/mnt/new");
    const relocated = (try library.library_roots.find(std.testing.allocator, moving.root_id)).?;
    defer relocated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/mnt/new", relocated.path);
    try std.testing.expectEqual(moved_volume, relocated.volume_id);
    const expected = [_]struct { volume_id: i64, uri: []const u8 }{
        .{ .volume_id = moved_volume, .uri = "/mnt/new/a.flac" },
        .{ .volume_id = moved_volume, .uri = "/mnt/new/sub/b.flac" },
        .{ .volume_id = other.volume_id, .uri = "/music/other/c.flac" },
    };
    for (expected, file_ids) |want, file_id| {
        const location = try locationOf(&library, file_id);
        defer std.testing.allocator.free(location.uri);
        try std.testing.expectEqual(want.volume_id, location.volume_id);
        try std.testing.expectEqualStrings(want.uri, location.uri);
    }
    var tracks_after = try library.tracks.page(std.testing.allocator, .{ .limit = 8, .offset = 0 });
    defer tracks_after.deinit();
    try std.testing.expectEqual(tracks_before.items.len, tracks_after.items.len);
    for (tracks_before.items, tracks_after.items) |before, after|
        try std.testing.expectEqual(before.id, after.id);

    const held = try library.files.create(.{ .audio_format = 1, .size_bytes = 1 });
    _ = try library.locations.upsert(.{ .file_id = held, .volume_id = moved_volume, .uri = "/mnt/held/d.flac" });
    const refused: repository.VolumeInput = .{ .stable_key = "uuid:refused" };
    for ([_][]const u8{ "/music/other", "/music", "/music/other/inner" }) |taken| {
        try std.testing.expectError(
            error.RootPathOverlaps,
            library.library_roots.relocate(std.testing.allocator, moving.root_id, refused, taken),
        );
    }
    try std.testing.expectError(
        error.RootPathOverlaps,
        library.library_roots.relocate(std.testing.allocator, moving.root_id, .{ .stable_key = "uuid:moved" }, "/mnt/held"),
    );
    try std.testing.expectError(
        error.InvalidLibraryRoot,
        library.library_roots.relocate(std.testing.allocator, moving.root_id, refused, ""),
    );
    try std.testing.expectError(
        error.UnknownRoot,
        library.library_roots.relocate(std.testing.allocator, moving.root_id + other.root_id + 1, refused, "/mnt/none"),
    );
    try std.testing.expectEqual(@as(?i64, null), try library.volumes.find("uuid:refused"));
    const unchanged = (try library.library_roots.find(std.testing.allocator, moving.root_id)).?;
    defer unchanged.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/mnt/new", unchanged.path);
    const kept = try locationOf(&library, file_ids[0]);
    defer std.testing.allocator.free(kept.uri);
    try std.testing.expectEqualStrings("/mnt/new/a.flac", kept.uri);
}

fn placeLocation(library: *LibraryDatabase, binding: RootBinding, uri: []const u8) !i64 {
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 1 });
    _ = try library.locations.upsert(.{
        .file_id = file_id,
        .volume_id = binding.volume_id,
        .root_id = binding.root_id,
        .uri = uri,
    });
    return file_id;
}

test "a root is not relocated into or around its old folder while it exists, nor where a moved location lands on another" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-relocate-nested?mode=memory&cache=shared",
    );
    defer library.close();
    try temporary.dir.createDirPath(std.testing.io, "lib/music/inner");
    const old_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/lib/music", .{temporary.sub_path});
    defer std.testing.allocator.free(old_path);
    const inner = try std.fmt.allocPrint(std.testing.allocator, "{s}/inner", .{old_path});
    defer std.testing.allocator.free(inner);
    const parent = std.fs.path.dirname(old_path).?;
    const volume: VolumeOptions = .{ .stable_key = "uuid:nested" };
    const root = try library.ensureRoot(std.testing.io, old_path, volume);
    const top_uri = try std.fmt.allocPrint(std.testing.allocator, "{s}/a.flac", .{old_path});
    defer std.testing.allocator.free(top_uri);
    const nested_uri = try std.fmt.allocPrint(std.testing.allocator, "{s}/music/a.flac", .{old_path});
    defer std.testing.allocator.free(nested_uri);
    const top = try placeLocation(&library, root, top_uri);
    const nested = try placeLocation(&library, root, nested_uri);

    try std.testing.expectError(error.RootPathOverlaps, library.relocateRoot(std.testing.io, root.root_id, inner, volume));
    try std.testing.expectError(error.RootPathOverlaps, library.relocateRoot(std.testing.io, root.root_id, parent, volume));
    _ = try library.relocateRoot(std.testing.io, root.root_id, old_path, volume);

    try temporary.dir.deleteTree(std.testing.io, "lib/music");
    try std.testing.expectError(error.RootPathOverlaps, library.relocateRoot(std.testing.io, root.root_id, parent, volume));
    const unmoved = try locationOf(&library, nested);
    defer std.testing.allocator.free(unmoved.uri);
    try std.testing.expectEqualStrings(nested_uri, unmoved.uri);

    _ = try library.relocateRoot(std.testing.io, root.root_id, inner, volume);
    const expected = [_]struct { file_id: i64, suffix: []const u8 }{
        .{ .file_id = top, .suffix = "/inner/a.flac" },
        .{ .file_id = nested, .suffix = "/inner/music/a.flac" },
    };
    for (expected) |want| {
        const location = try locationOf(&library, want.file_id);
        defer std.testing.allocator.free(location.uri);
        const uri = try std.mem.concat(std.testing.allocator, u8, &.{ old_path, want.suffix });
        defer std.testing.allocator.free(uri);
        try std.testing.expectEqualStrings(uri, location.uri);
    }
}

fn expectJournalPaths(library: *LibraryDatabase, operation_id: i64, expected: [4]?[]const u8) !void {
    const operation = try library.mutation_journal.get(std.testing.allocator, operation_id);
    defer operation.deinit();
    const actual = [4]?[]const u8{ operation.source_path, operation.destination_path, operation.stage_path, operation.backup_path };
    for (expected, actual) |want, have| {
        if (want) |path| try std.testing.expectEqualStrings(path, have.?) else try std.testing.expectEqual(@as(?[]const u8, null), have);
    }
}

test "relocating a root rewrites the journal's paths under it and no others, and refuses over an unfinished or unreconciled write" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-relocate-journal?mode=memory&cache=shared",
    );
    defer library.close();
    const root = try library.ensureRoot(std.testing.io, "/music/old", .{ .stable_key = "uuid:old" });
    const journal = &library.mutation_journal;
    const Row = struct {
        kind: repository.MutationKind = .write_tags,
        before: [4]?[]const u8,
        after: [4]?[]const u8,
    };
    const rows = [_]Row{
        .{
            .before = .{ "/music/old/a.flac", null, "/music/old/.a.flac.orca-stage-1-0", "/data/library.db.orca-backups/1/0-a.flac" },
            .after = .{ "/mnt/new/a.flac", null, "/mnt/new/.a.flac.orca-stage-1-0", "/data/library.db.orca-backups/1/0-a.flac" },
        },
        .{
            .before = .{ "/music/old/sub/b.flac", null, "/music/old/sub/b.flac.orca-stage-1-1", "/music/old/sub/b.flac.orca-backup-1-1" },
            .after = .{ "/mnt/new/sub/b.flac", null, "/mnt/new/sub/b.flac.orca-stage-1-1", "/mnt/new/sub/b.flac.orca-backup-1-1" },
        },
        .{
            .kind = .move,
            .before = .{ "/music/old/c.flac", "/music/old/moved/c.flac", null, null },
            .after = .{ "/mnt/new/c.flac", "/mnt/new/moved/c.flac", null, null },
        },
        .{
            .before = .{ "/music/older/d.flac", null, "/music/older/.d.flac.orca-stage-1-3", "/music/old.orca-backups/1/3-d.flac" },
            .after = .{ "/music/older/d.flac", null, "/music/older/.d.flac.orca-stage-1-3", "/music/old.orca-backups/1/3-d.flac" },
        },
    };
    var operation_ids: [rows.len]i64 = undefined;
    for (rows, &operation_ids, 0..) |row, *operation_id, index| {
        operation_id.* = try journal.prepare(.{
            .plan_id = 1,
            .group_id = 1,
            .action_index = @intCast(index),
            .kind = row.kind,
            .source_path = row.before[0].?,
            .destination_path = row.before[1],
            .stage_path = row.before[2],
            .backup_path = row.before[3],
            .expected_size = 1,
            .expected_modified_ns = 1,
            .expected_quick_hash = @splat(0),
        });
        try journal.transition(operation_id.*, .planned, .staged, null);
        try journal.transition(operation_id.*, .staged, .committed, null);
    }

    const unfinished = try journal.prepare(.{
        .plan_id = 2,
        .group_id = 2,
        .action_index = 0,
        .kind = .write_tags,
        .source_path = "/music/old/e.flac",
        .stage_path = "/music/old/.e.flac.orca-stage-2-0",
        .expected_size = 1,
        .expected_modified_ns = 1,
        .expected_quick_hash = @splat(0),
    });
    try journal.transition(unfinished, .planned, .staged, null);
    const refused: repository.VolumeInput = .{ .stable_key = "uuid:refused" };
    try std.testing.expectError(
        error.MutationInProgress,
        library.library_roots.relocate(std.testing.allocator, root.root_id, refused, "/mnt/new"),
    );
    try journal.transition(unfinished, .staged, .needs_reconciliation, "kept every file");
    try std.testing.expectError(
        error.MutationNeedsReconciliation,
        library.library_roots.relocate(std.testing.allocator, root.root_id, refused, "/mnt/new"),
    );
    try std.testing.expectEqual(@as(?i64, null), try library.volumes.find("uuid:refused"));
    for (rows, operation_ids) |row, operation_id| try expectJournalPaths(&library, operation_id, row.before);

    var statement = try library.database.prepare("DELETE FROM mutation_operations WHERE id=?1;");
    defer statement.deinit();
    try statement.bindInt64(1, unfinished);
    try std.testing.expectEqual(sqlite.Step.done, try statement.step());
    _ = try library.library_roots.relocate(std.testing.allocator, root.root_id, .{ .stable_key = "uuid:new" }, "/mnt/new");
    for (rows, operation_ids) |row, operation_id| try expectJournalPaths(&library, operation_id, row.after);
}

test "opening a version-7 library recovers its journal before the schema moves" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/v7-library.db",
        .{temporary.sub_path},
        0,
    );
    defer std.testing.allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "fixtures/database/v7-library.db",
        std.testing.allocator,
        .limited(8 * 1024 * 1024),
    );
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });

    // Recovery runs at the journal-ready version, between migration 5 and the
    // rest, so a terminal record survives untouched and migration 8 is free to
    // rewrite the tables underneath it.
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, path);
    defer library.close();
    try std.testing.expectEqual(
        repository.MutationState.committed,
        try library.mutation_journal.state(1),
    );
    try std.testing.expectEqual(@as(u64, 5), try library.files.count());
    var page = try library.tracks.search(std.testing.allocator, "Bryter", .{ .limit = 10 });
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);

    const file_id = (try library.files.resolveByUri(
        LibraryDatabase.null_volume,
        "/music/drake/northern-sky.flac",
    )).?;
    const observed = (try library.observed_tags.get(std.testing.allocator, file_id)).?;
    defer observed.deinit();
    try std.testing.expectEqualStrings("Northern Sky", observed.values.title.?);
}

test "an artist's tracks include the ones on a release they are the album artist of" {
    // The narrow definition -- credit only -- leaves an artist owning an album
    // and no songs whenever the track credit differs from the album credit,
    // which real tags do constantly: a featured artist, a collaboration, a
    // separator convention, or simply no ARTIST tag at all.
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-artist-shelf?mode=memory&cache=shared",
    );
    defer library.close();

    const headliner = (try library.artists.ensure(.{
        .key = "grayarea",
        .name = "Grayarea",
        .sort_name = "grayarea",
    })).?;
    const featured = (try library.artists.ensure(.{
        .key = "grayarea feat. erik shepard",
        .name = "Grayarea feat. Erik Shepard",
        .sort_name = "grayarea feat. erik shepard",
    })).?;
    // Deliberately two artists: a featured credit is not a spelling of the
    // headline act, and merging them would destroy information.
    try std.testing.expect(headliner != featured);

    const release = try library.releases.upsert(.{
        .release_key = "grayarea|gravity",
        .title = "Gravity",
        .album_artist = "Grayarea",
        .album_artist_id = headliner,
    });
    try library.tracks.upsertTracks(&.{
        .{
            .title = "Gravity",
            .artist = "Grayarea feat. Erik Shepard",
            .artist_id = featured,
            .release_id = release,
            .track_number = 1,
        },
        .{
            .title = "Gravity (Reprise)",
            .artist = "Grayarea",
            .artist_id = headliner,
            .release_id = release,
            .track_number = 2,
        },
    });

    var page = try library.tracks.page(std.testing.allocator, .{ .artist_id = headliner });
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    // Credited once and on the album: counted once, not twice.
    try std.testing.expectEqual(
        @as(u64, 2),
        try library.tracks.countMatching(.{ .artist_id = headliner }),
    );

    // The count and the page it counts must agree.
    var artists = try library.artists.page(std.testing.allocator, .{ .limit = 16 });
    defer artists.deinit();
    for (artists.items) |artist| {
        if (artist.id != headliner) continue;
        try std.testing.expectEqual(@as(u64, 2), artist.track_count);
        try std.testing.expectEqual(@as(u64, 1), artist.release_count);
    }

    // The featured artist keeps their own credit and gains nothing.
    try std.testing.expectEqual(
        @as(u64, 1),
        try library.tracks.countMatching(.{ .artist_id = featured }),
    );

    // ...but they do appear on the record, and the release listing has to say
    // so, or an artist shows songs and an empty album list.
    var featured_releases = try library.releases.page(
        std.testing.allocator,
        .{ .album_artist_id = featured },
    );
    defer featured_releases.deinit();
    try std.testing.expectEqual(@as(usize, 1), featured_releases.items.len);
    try std.testing.expectEqual(release, featured_releases.items[0].id);
    try std.testing.expectEqual(
        @as(u64, 1),
        try library.releases.countMatching(.{ .album_artist_id = featured }),
    );

    // The headliner is not double-counted for fronting it and appearing on it.
    try std.testing.expectEqual(
        @as(u64, 1),
        try library.releases.countMatching(.{ .album_artist_id = headliner }),
    );

    // The count beside an artist must agree with the pane it labels.
    var listing = try library.artists.page(std.testing.allocator, .{ .limit = 16 });
    defer listing.deinit();
    for (listing.items) |artist| {
        if (artist.id != featured) continue;
        try std.testing.expectEqual(@as(u64, 1), artist.release_count);
    }
}

test "an artist search matches the spelling a person types, not the one stored" {
    // The artist key folds punctuation and case, so a search has to fold the
    // needle the same way or it is stricter than identity is.
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-artist-search?mode=memory&cache=shared",
    );
    defer library.close();
    for ([_][2][]const u8{
        .{ "el-p", "El\u{2010}P" },
        .{ "the o'jays", "The O\u{2019}Jays" },
        .{ "stevie nicks", "Stevie Nicks" },
    }) |pair| {
        _ = try library.artists.ensure(.{
            .key = pair[0],
            .name = pair[1],
            .sort_name = pair[0],
        });
    }

    // Typed with an ASCII hyphen; stored with U+2010.
    var hyphen = try library.artists.page(std.testing.allocator, .{ .filter = "El-P" });
    defer hyphen.deinit();
    try std.testing.expectEqual(@as(usize, 1), hyphen.items.len);
    try std.testing.expectEqualStrings("El\u{2010}P", hyphen.items[0].name);

    // Typed with a straight apostrophe; stored with a curly one.
    var quote = try library.artists.page(std.testing.allocator, .{ .filter = "O'Jays" });
    defer quote.deinit();
    try std.testing.expectEqual(@as(usize, 1), quote.items.len);

    // A substring in the middle, and case-insensitively.
    var infix = try library.artists.page(std.testing.allocator, .{ .filter = "NICKS" });
    defer infix.deinit();
    try std.testing.expectEqual(@as(usize, 1), infix.items.len);

    // The count reports what matched, not what exists.
    try std.testing.expectEqual(
        @as(u64, 1),
        try library.artists.countMatching(.{ .filter = "nicks" }),
    );
    try std.testing.expectEqual(@as(u64, 3), try library.artists.countMatching(.{}));

    // A name containing a LIKE wildcard is matched literally, which is why the
    // predicate is `instr` rather than `LIKE`.
    _ = try library.artists.ensure(.{ .key = "100% silk", .name = "100% Silk", .sort_name = "100% silk" });
    var literal = try library.artists.page(std.testing.allocator, .{ .filter = "100%" });
    defer literal.deinit();
    try std.testing.expectEqual(@as(usize, 1), literal.items.len);
    var wildcard = try library.artists.page(std.testing.allocator, .{ .filter = "%silk" });
    defer wildcard.deinit();
    try std.testing.expectEqual(@as(usize, 0), wildcard.items.len);
}

test "recording a missing file declines the write lane rather than waiting for it" {
    // The decode producer calls this when a track will not open. A job worker
    // holds the write lane across an entire batch commit, so a producer that
    // waited would stop feeding the render callback and turn an unplugged
    // drive into underruns. Missing audio is a worse answer than a stale row.
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-missing-lane?mode=memory&cache=shared",
    );
    defer library.close();
    const volume_id = try library.volumes.ensure(.{
        .stable_key = "uuid:lane",
        .label = "Lane",
    });
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 16 });
    const location_id = try library.locations.upsert(.{
        .file_id = file_id,
        .volume_id = volume_id,
        .uri = "/music/gone.flac",
    });

    // Exactly the contention the producer meets: somebody else is committing.
    library.write_lane.acquire();
    const wrote_while_held = try library.locations.markMissingIfLaneFree(file_id);
    library.write_lane.release();
    try std.testing.expect(!wrote_while_held);
    // Declining means declining: the row is untouched, not half-written.
    try std.testing.expect(try library.locations.stateOf(location_id) != .missing);

    // With the lane free it does the write it skipped.
    try std.testing.expect(try library.locations.markMissingIfLaneFree(file_id));
    try std.testing.expectEqual(
        repository.LocationState.missing,
        try library.locations.stateOf(location_id),
    );
}

const testScalar = @import("columns.zig").scalar;

fn testListen(file_id: i64, started_at: i64) repository.ListenInput {
    return .{
        .file_id = file_id,
        .started_at = started_at,
        .listened_ms = 200_000,
        .duration_ms = 240_000,
        .title = "Northern Sky",
        .artist = "Nick Drake",
        .album = "Bryter Layter",
    };
}

test "a recorded listen is counted for its Track and survives the Track being reprojected" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-listen-count?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec("INSERT INTO recordings(id, title) VALUES (7, 'Northern Sky');");
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
    const track: repository.TrackInput = .{
        .recording_id = 7,
        .title = "Northern Sky",
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .preferred_file_id = file_id,
    };
    try library.tracks.upsertTracks(&.{track});
    const first_id = try testScalar(library.database, "SELECT id FROM tracks;");
    try std.testing.expectEqual(
        repository.PlayStats{ .play_count = 0, .last_played_at = null },
        try library.listens.trackPlayStats(first_id),
    );

    try library.database.exec("UPDATE files SET recording_id = 7;");
    var listen = testListen(file_id, 1_700_000_000);
    try std.testing.expect(try library.listens.record(listen) != null);
    listen.started_at = 1_700_001_000;
    try std.testing.expect(try library.listens.record(listen) != null);
    try std.testing.expect(try library.listens.record(listen) == null);
    try std.testing.expectEqual(
        repository.PlayStats{ .play_count = 2, .last_played_at = 1_700_001_000 },
        try library.listens.trackPlayStats(first_id),
    );

    try library.tracks.upsertTracks(&.{.{ .title = "Filler" }});
    try library.database.exec("DELETE FROM tracks WHERE title='Northern Sky';");
    try library.tracks.upsertTracks(&.{track});
    const second_id = try testScalar(library.database, "SELECT id FROM tracks WHERE title='Northern Sky';");
    try std.testing.expect(second_id != first_id);
    try std.testing.expectEqual(
        repository.PlayStats{ .play_count = 2, .last_played_at = 1_700_001_000 },
        try library.listens.trackPlayStats(second_id),
    );
    try std.testing.expectEqual(
        repository.PlayStats{ .play_count = 0, .last_played_at = null },
        try library.listens.trackPlayStats(second_id + 1000),
    );
}

test "a Track's total is counted only when none of its files states one" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-stated-total?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec("INSERT INTO recordings(id, title) VALUES (7, 'Northern Sky');");
    const flac_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
    const mp3_id = try library.files.create(.{ .audio_format = 2, .size_bytes = 2048 });
    try library.database.exec("UPDATE files SET recording_id = 7;");
    try library.observed_tags.upsert(.{ .file_id = flac_id, .values = .{ .title = "Northern Sky" } });
    try library.observed_tags.upsert(.{ .file_id = mp3_id, .values = .{ .title = "Northern Sky", .track_total = 10 } });
    try library.tracks.upsertTracks(&.{
        .{ .recording_id = 7, .title = "Northern Sky", .preferred_file_id = flac_id, .track_total = 10 },
    });
    const track_id = try testScalar(library.database, "SELECT id FROM tracks;");
    const stated = (try library.tracks.fileFacts(std.testing.allocator, track_id)).?;
    defer stated.deinit();
    try std.testing.expect(!stated.track_total_inferred);

    try library.observed_tags.upsert(.{ .file_id = mp3_id, .values = .{ .title = "Northern Sky" } });
    const counted = (try library.tracks.fileFacts(std.testing.allocator, track_id)).?;
    defer counted.deinit();
    try std.testing.expect(counted.track_total_inferred);
}

test "two files of one recording each played once count two plays on both Tracks" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-listen-recording?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec("INSERT INTO recordings(id, title) VALUES (7, 'Northern Sky');");
    const flac_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
    const mp3_id = try library.files.create(.{ .audio_format = 2, .size_bytes = 2048 });
    try library.tracks.upsertTracks(&.{
        .{ .recording_id = 7, .title = "Northern Sky", .album = "Bryter Layter", .preferred_file_id = flac_id },
        .{ .recording_id = 7, .title = "Northern Sky", .album = "Best Of", .preferred_file_id = mp3_id },
    });
    try library.database.exec("UPDATE files SET recording_id = 7;");
    var listen = testListen(flac_id, 1_700_000_000);
    try std.testing.expect(try library.listens.record(listen) != null);
    listen.file_id = mp3_id;
    listen.started_at = 1_700_005_000;
    try std.testing.expect(try library.listens.record(listen) != null);

    var page = try library.tracks.page(std.testing.allocator, .{ .sort = .play_count, .direction = .descending });
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    for (page.items) |item| {
        try std.testing.expectEqual(@as(u64, 2), item.play_count);
        try std.testing.expectEqual(@as(?i64, 1_700_005_000), item.last_played_at);
        try std.testing.expectEqual(
            repository.PlayStats{ .play_count = 2, .last_played_at = 1_700_005_000 },
            try library.listens.trackPlayStats(item.id),
        );
    }
}

test "a listen stays after its file is forgotten, with no file" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-listen-forgotten?mode=memory&cache=shared",
    );
    defer library.close();
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
    _ = try library.listens.record(testListen(file_id, 1_700_000_000));

    try library.database.exec("DELETE FROM files;");

    try std.testing.expectEqual(@as(i64, 1), try testScalar(library.database, "SELECT count(*) FROM listens;"));
    try std.testing.expectEqual(
        @as(i64, 1),
        try testScalar(library.database, "SELECT count(*) FROM listens WHERE file_id IS NULL AND title='Northern Sky';"),
    );
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT count(*) FROM pragma_foreign_key_check;"));
}

test "recording the same file and start twice counts once and queues once" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-listen-dedup?mode=memory&cache=shared",
    );
    defer library.close();
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });

    const first = try library.listens.recordAndQueue(testListen(file_id, 1_700_000_000), "listenbrainz", "{}");
    const again = try library.listens.recordAndQueue(testListen(file_id, 1_700_000_000), "listenbrainz", "{}");

    try std.testing.expect(first != null);
    try std.testing.expectEqual(@as(?i64, null), again);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(library.database, "SELECT count(*) FROM listens;"));
    try std.testing.expectEqual(@as(u64, 1), try library.scrobbles.pendingCount());
    const entries = try library.scrobbles.lease(std.testing.allocator, "listenbrainz", 1, 0, 60, 10);
    defer {
        for (entries) |entry| entry.deinit();
        std.testing.allocator.free(entries);
    }
    var expected_key: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&expected_key, "listen:{d}", .{first.?}),
        entries[0].event_key,
    );
}

test "updating a listen's time heard only ever raises it" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-listen-update?mode=memory&cache=shared",
    );
    defer library.close();
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
    _ = try library.listens.record(testListen(file_id, 1_700_000_000));

    try library.listens.updateListened(file_id, 1_700_000_000, 230_000);
    try std.testing.expectEqual(@as(i64, 230_000), try testScalar(library.database, "SELECT listened_ms FROM listens;"));
    try library.listens.updateListened(file_id, 1_700_000_000, 100_000);
    try std.testing.expectEqual(@as(i64, 230_000), try testScalar(library.database, "SELECT listened_ms FROM listens;"));
    try library.listens.updateListened(file_id, 1_700_000_001, 300_000);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(library.database, "SELECT count(*) FROM listens;"));
}

test "a local-only listen finished past ListenBrainz's rule becomes syncable and is queued once" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-listen-syncable?mode=memory&cache=shared",
    );
    defer library.close();
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
    var input = testListen(file_id, 1_700_000_000);
    input.listened_ms = 31_000;
    input.syncable = false;
    _ = try library.listens.record(input);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT syncable FROM listens;"));

    try std.testing.expect(try library.listens.finishSyncable(file_id, 1_700_000_000, 130_000, "listenbrainz", "{}"));
    try std.testing.expect(!try library.listens.finishSyncable(file_id, 1_700_000_000, 140_000, "listenbrainz", "{}"));

    try std.testing.expectEqual(@as(i64, 1), try testScalar(library.database, "SELECT syncable FROM listens;"));
    try std.testing.expectEqual(@as(i64, 140_000), try testScalar(library.database, "SELECT listened_ms FROM listens;"));
    try std.testing.expectEqual(@as(u64, 1), try library.scrobbles.pendingCount());
}

test "clearing listens removes them, their pending deliveries and play counts, and keeps ratings and loves" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-listen-clear?mode=memory&cache=shared",
    );
    defer library.close();
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
    try library.database.exec(
        \\INSERT INTO recordings(id, title) VALUES (7, 'Northern Sky');
        \\UPDATE files SET recording_id = 7;
        \\INSERT INTO ratings(recording_id, rating, updated_at) VALUES (7, 80, 1);
    );
    _ = try library.listens.recordAndQueue(testListen(file_id, 1_700_000_000), "listenbrainz", "{}");
    _ = try library.listens.record(testListen(file_id, 1_700_000_500));
    try library.database.exec(
        "INSERT INTO scrobble_queue(service, event_key, payload, state, created_at) VALUES ('listenbrainz', 'feedback:7', '{}', 0, 1);",
    );
    try std.testing.expectEqual(@as(u64, 2), try library.listens.count());

    try std.testing.expectEqual(@as(u64, 2), try library.listens.clear());

    try std.testing.expectEqual(@as(u64, 0), try library.listens.count());
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT count(*) FROM recording_play_stats;"));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT count(*) FROM scrobble_queue WHERE event_key LIKE 'listen:%';"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(library.database, "SELECT count(*) FROM scrobble_queue;"));
    try std.testing.expectEqual(@as(i64, 80), try testScalar(library.database, "SELECT rating FROM ratings WHERE recording_id = 7;"));
}

test "a listen recorded after the history was cleared is queued although its id was used before" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-listen-clear-reuse?mode=memory&cache=shared",
    );
    defer library.close();
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
    const first = (try library.listens.recordAndQueue(testListen(file_id, 1_700_000_000), "listenbrainz", "{}")).?;
    try library.database.exec("UPDATE scrobble_queue SET state = 2;");
    _ = try library.listens.clear();

    const second = (try library.listens.recordAndQueue(testListen(file_id, 1_700_000_900), "listenbrainz", "{}")).?;
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(library.database, "SELECT count(*) FROM scrobble_queue WHERE state = 0;"));
}

test "a listen subject carries the Track's metadata and the file's MusicBrainz ids" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-listen-subject?mode=memory&cache=shared",
    );
    defer library.close();
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
    try library.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = "Northern Sky",
        .musicbrainz_recording_id = "rec-mbid",
        .musicbrainz_release_id = "rel-mbid",
        .musicbrainz_artist_id = "",
    } });
    try library.tracks.upsertTracks(&.{.{
        .title = "Northern Sky",
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .duration_ms = 240_000,
        .track_number = 8,
        .preferred_file_id = file_id,
    }});
    const track_id = try testScalar(library.database, "SELECT id FROM tracks;");

    const subject = (try library.listens.listenSubject(std.testing.allocator, track_id)).?;
    defer subject.deinit();
    try std.testing.expectEqual(@as(?i64, file_id), subject.file_id);
    try std.testing.expectEqualStrings("Nick Drake", subject.artist);
    try std.testing.expectEqualStrings("Bryter Layter", subject.album);
    try std.testing.expectEqual(@as(?i64, 240_000), subject.duration_ms);
    try std.testing.expectEqual(@as(?i64, 8), subject.track_number);
    try std.testing.expectEqualStrings("rec-mbid", subject.recording_mbid.?);
    try std.testing.expectEqualStrings("rel-mbid", subject.release_mbid.?);
    try std.testing.expectEqual(@as(?[]u8, null), subject.artist_mbid);
    try std.testing.expect((try library.listens.listenSubject(std.testing.allocator, track_id + 1000)) == null);
}

test "two owners never lease the same event and an expired lease can be reclaimed" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-lease?mode=memory&cache=shared",
    );
    defer library.close();
    try library.scrobbles.enqueue("listenbrainz", "one", "{}");
    try library.scrobbles.enqueue("listenbrainz", "two", "{}");
    try library.scrobbles.enqueue("other-service", "other", "{}");

    const first = try library.scrobbles.lease(std.testing.allocator, "listenbrainz", 1, 100, 200, 1);
    defer freeEntries(first);
    const second = try library.scrobbles.lease(std.testing.allocator, "listenbrainz", 2, 100, 200, 10);
    defer freeEntries(second);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqualStrings("one", first[0].event_key);
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqualStrings("two", second[0].event_key);
    try std.testing.expectEqual(@as(?i64, 200), try library.scrobbles.nextAttemptAt("listenbrainz"));

    const before_expiry = try library.scrobbles.lease(std.testing.allocator, "listenbrainz", 3, 199, 300, 10);
    defer freeEntries(before_expiry);
    try std.testing.expectEqual(@as(usize, 0), before_expiry.len);

    const reclaimed = try library.scrobbles.lease(std.testing.allocator, "listenbrainz", 3, 200, 300, 10);
    defer freeEntries(reclaimed);
    try std.testing.expectEqual(@as(usize, 2), reclaimed.len);
    try std.testing.expectEqualStrings("one", reclaimed[0].event_key);
    try std.testing.expectEqualStrings("two", reclaimed[1].event_key);

    try std.testing.expectError(error.StaleScrobbleEvent, library.scrobbles.markDelivered(first[0].id, 1));
    try std.testing.expectError(error.StaleScrobbleEvent, library.scrobbles.markRetry(first[0].id, 1, 500, "late"));
    try std.testing.expectError(error.StaleScrobbleEvent, library.scrobbles.markRejected(first[0].id, 1, "late"));
    try std.testing.expectError(error.StaleScrobbleEvent, library.scrobbles.release(first[0].id, 1));
    try library.scrobbles.markDelivered(first[0].id, 3);
    try std.testing.expectError(error.StaleScrobbleEvent, library.scrobbles.markDelivered(first[0].id, 3));
    try std.testing.expectEqual(@as(u64, 1), try library.scrobbles.deliveredCount("listenbrainz"));
    try std.testing.expectEqual(@as(u64, 2), try library.scrobbles.pendingCount());
}

test "releasing a leased event does not count an attempt but retrying does" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-lease-attempts?mode=memory&cache=shared",
    );
    defer library.close();
    try library.scrobbles.enqueue("listenbrainz", "one", "{}");

    const leased = try library.scrobbles.lease(std.testing.allocator, "listenbrainz", 1, 100, 200, 10);
    defer freeEntries(leased);
    try library.scrobbles.release(leased[0].id, 1);
    try std.testing.expectEqual(@as(?i64, 0), try library.scrobbles.nextAttemptAt("listenbrainz"));

    const again = try library.scrobbles.lease(std.testing.allocator, "listenbrainz", 1, 100, 200, 10);
    defer freeEntries(again);
    try std.testing.expectEqual(@as(u32, 0), again[0].attempt_count);
    try library.scrobbles.markRetry(again[0].id, 1, 400, "offline");
    try std.testing.expectEqual(@as(?i64, 400), try library.scrobbles.nextAttemptAt("listenbrainz"));

    const early = try library.scrobbles.lease(std.testing.allocator, "listenbrainz", 1, 399, 500, 10);
    defer freeEntries(early);
    try std.testing.expectEqual(@as(usize, 0), early.len);
    const retried = try library.scrobbles.lease(std.testing.allocator, "listenbrainz", 1, 400, 500, 10);
    defer freeEntries(retried);
    try std.testing.expectEqual(@as(u32, 1), retried[0].attempt_count);
    try library.scrobbles.markRejected(retried[0].id, 1, "invalid");
    try std.testing.expectEqual(@as(?i64, null), try library.scrobbles.nextAttemptAt("listenbrainz"));
    try std.testing.expectEqual(@as(u64, 0), try library.scrobbles.pendingCount());
    try std.testing.expectEqual(
        @as(i64, 1),
        try testScalar(library.database, "SELECT count(*) FROM scrobble_queue WHERE state=3 AND attempt_count=2 AND lease_owner IS NULL;"),
    );
}

fn freeEntries(entries: []repository.ScrobbleQueueEntry) void {
    for (entries) |entry| entry.deinit();
    std.testing.allocator.free(entries);
}

const Feedback = repository.Feedback;
const settled_at: i64 = 4_000_000_000;
const feedback_mbid = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";

fn openFeedbackLibrary(comptime name: []const u8) !LibraryDatabase {
    return LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-feedback-" ++ name ++ "?mode=memory&cache=shared",
    );
}

fn addFeedbackTrack(library: *LibraryDatabase, title: []const u8, recording_id: ?i64, mbid: ?[]const u8) !i64 {
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
    if (recording_id) |recording| {
        var sql: [96]u8 = undefined;
        try library.database.exec(try std.fmt.bufPrintSentinel(
            &sql,
            "UPDATE files SET recording_id = {d} WHERE id = {d};",
            .{ recording, file_id },
            0,
        ));
    }
    try library.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = title,
        .musicbrainz_recording_id = mbid,
    } });
    try library.tracks.upsertTracks(&.{.{
        .recording_id = recording_id,
        .title = title,
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .preferred_file_id = file_id,
    }});
    var sql: [96]u8 = undefined;
    return testScalar(library.database, try std.fmt.bufPrintSentinel(
        &sql,
        "SELECT id FROM tracks WHERE preferred_file_id = {d};",
        .{file_id},
        0,
    ));
}

fn addRecording(library: *LibraryDatabase) !i64 {
    try library.database.exec("INSERT INTO recordings(title) VALUES ('Song');");
    return testScalar(library.database, "SELECT max(id) FROM recordings;");
}

test "feedback on one Track shows on every Track of its recording, in pages and searches" {
    var library = try openFeedbackLibrary("shared");
    defer library.close();
    const recording = try addRecording(&library);
    const flac = try addFeedbackTrack(&library, "Northern Sky", recording, null);
    const compilation = try addFeedbackTrack(&library, "Northern Sky", recording, null);
    const other = try addFeedbackTrack(&library, "Pink Moon", try addRecording(&library), null);

    const change = try library.feedback.set(&.{flac}, .loved);
    try std.testing.expectEqual(@as(u32, 1), change.updated);
    try std.testing.expectEqual(Feedback.loved, try library.feedback.forTrack(compilation));
    try std.testing.expectEqual(Feedback.none, try library.feedback.forTrack(other));

    const summary = (try library.tracks.byId(std.testing.allocator, compilation)).?;
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(Feedback.loved, summary.feedback);
    var page = try library.tracks.page(std.testing.allocator, .{ .limit = 8 });
    defer page.deinit();
    for (page.items) |item| {
        const expected: Feedback = if (item.id == other) .none else .loved;
        try std.testing.expectEqual(expected, item.feedback);
    }
    var found = try library.tracks.search(std.testing.allocator, "Northern", .{ .limit = 8 });
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 2), found.items.len);
    for (found.items) |item| try std.testing.expectEqual(Feedback.loved, item.feedback);

    _ = try library.feedback.set(&.{compilation}, .hated);
    try std.testing.expectEqual(Feedback.hated, try library.feedback.forTrack(flac));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(library.database, "SELECT count(*) FROM feedback;"));
}

test "feedback on a Track with no recording or no row is skipped and counted" {
    var library = try openFeedbackLibrary("skipped");
    defer library.close();
    const bare = try addFeedbackTrack(&library, "Bare", null, null);
    const kept = try addFeedbackTrack(&library, "Kept", try addRecording(&library), null);

    const change = try library.feedback.set(&.{ bare, kept, 9999 }, .loved);
    try std.testing.expectEqual(@as(u32, 1), change.updated);
    try std.testing.expectEqual(@as(u32, 2), change.skipped);
    try std.testing.expectEqual(Feedback.none, try library.feedback.forTrack(bare));
    try std.testing.expectEqual(Feedback.loved, try library.feedback.forTrack(kept));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(library.database, "SELECT count(*) FROM feedback;"));

    var many: [repository.max_page + 1]i64 = undefined;
    @memset(&many, kept);
    try std.testing.expectError(error.PageOutOfRange, library.feedback.set(&many, .loved));
}

test "clearing feedback that was never sent leaves nothing to send" {
    var library = try openFeedbackLibrary("clear-unsent");
    defer library.close();
    const track = try addFeedbackTrack(&library, "Song", try addRecording(&library), feedback_mbid);
    _ = try library.feedback.set(&.{track}, .loved);
    try std.testing.expectEqual(@as(u64, 1), try library.feedback.pendingSyncCount());

    _ = try library.feedback.set(&.{track}, .none);

    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT count(*) FROM feedback;"));
    try std.testing.expectEqual(@as(u64, 0), try library.feedback.pendingSyncCount());
    try std.testing.expect(try library.feedback.nextToSync(std.testing.allocator, settled_at) == null);
}

test "clearing feedback that was sent stays pending until the clear is sent" {
    var library = try openFeedbackLibrary("clear-sent");
    defer library.close();
    const track = try addFeedbackTrack(&library, "Song", try addRecording(&library), feedback_mbid);
    _ = try library.feedback.set(&.{track}, .loved);
    const love = (try library.feedback.nextToSync(std.testing.allocator, settled_at)).?;
    defer love.deinit();
    try std.testing.expectEqualStrings(feedback_mbid, love.recording_mbid);
    try std.testing.expectEqual(Feedback.loved, love.feedback);
    try library.feedback.markSynced(love.recording_id, .loved);
    try std.testing.expect(try library.feedback.nextToSync(std.testing.allocator, settled_at) == null);
    try std.testing.expectEqual(Feedback.loved, try library.feedback.forTrack(track));

    _ = try library.feedback.set(&.{track}, .none);

    try std.testing.expectEqual(Feedback.none, try library.feedback.forTrack(track));
    const clear = (try library.feedback.nextToSync(std.testing.allocator, settled_at)).?;
    defer clear.deinit();
    try std.testing.expectEqual(Feedback.none, clear.feedback);
    try library.feedback.markSynced(clear.recording_id, .none);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT count(*) FROM feedback;"));
}

test "a change made while feedback was being sent is still pending after it is marked synced" {
    var library = try openFeedbackLibrary("in-flight");
    defer library.close();
    const track = try addFeedbackTrack(&library, "Song", try addRecording(&library), feedback_mbid);
    _ = try library.feedback.set(&.{track}, .loved);
    const sending = (try library.feedback.nextToSync(std.testing.allocator, settled_at)).?;
    defer sending.deinit();

    _ = try library.feedback.set(&.{track}, .hated);
    try library.feedback.markSynced(sending.recording_id, sending.feedback);

    const next = (try library.feedback.nextToSync(std.testing.allocator, settled_at)).?;
    defer next.deinit();
    try std.testing.expectEqual(Feedback.hated, next.feedback);
    try std.testing.expectEqual(Feedback.hated, try library.feedback.forTrack(track));
}

test "a clear made while a love was being sent is sent next" {
    var library = try openFeedbackLibrary("cleared-in-flight");
    defer library.close();
    const track = try addFeedbackTrack(&library, "Song", try addRecording(&library), feedback_mbid);
    _ = try library.feedback.set(&.{track}, .loved);
    const sending = (try library.feedback.nextToSync(std.testing.allocator, settled_at)).?;
    defer sending.deinit();

    _ = try library.feedback.set(&.{track}, .none);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT count(*) FROM feedback;"));
    try library.feedback.markSynced(sending.recording_id, sending.feedback);

    const clear = (try library.feedback.nextToSync(std.testing.allocator, settled_at)).?;
    defer clear.deinit();
    try std.testing.expectEqual(Feedback.none, clear.feedback);
    try library.feedback.markSynced(clear.recording_id, .none);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT count(*) FROM feedback;"));
}

test "rejected feedback is not offered again until the user changes it" {
    var library = try openFeedbackLibrary("rejected");
    defer library.close();
    const track = try addFeedbackTrack(&library, "Song", try addRecording(&library), feedback_mbid);
    _ = try library.feedback.set(&.{track}, .loved);
    const sending = (try library.feedback.nextToSync(std.testing.allocator, settled_at)).?;
    defer sending.deinit();

    try library.feedback.markRejected(sending.recording_id, sending.feedback, "HTTP 400: invalid recording");

    try std.testing.expect(try library.feedback.nextToSync(std.testing.allocator, settled_at) == null);
    try std.testing.expectEqual(@as(u64, 0), try library.feedback.pendingSyncCount());
    try std.testing.expectEqual(Feedback.loved, try library.feedback.forTrack(track));
    _ = try library.feedback.set(&.{track}, .hated);
    const changed = (try library.feedback.nextToSync(std.testing.allocator, settled_at)).?;
    defer changed.deinit();
    try std.testing.expectEqual(Feedback.hated, changed.feedback);
}

test "feedback without a MusicBrainz recording id is kept but never offered for sync" {
    var library = try openFeedbackLibrary("no-mbid");
    defer library.close();
    const untagged = try addFeedbackTrack(&library, "Untagged", try addRecording(&library), null);
    const blank = try addFeedbackTrack(&library, "Blank", try addRecording(&library), "");
    const tagged = try addFeedbackTrack(&library, "Tagged", try addRecording(&library), feedback_mbid);
    _ = try library.feedback.set(&.{ untagged, blank }, .loved);

    try std.testing.expect(try library.feedback.nextToSync(std.testing.allocator, settled_at) == null);
    try std.testing.expectEqual(@as(u64, 0), try library.feedback.pendingSyncCount());
    try std.testing.expect(!try library.feedback.canSync(untagged));
    try std.testing.expect(!try library.feedback.canSync(blank));
    try std.testing.expect(try library.feedback.canSync(tagged));
    try std.testing.expectEqual(Feedback.loved, try library.feedback.forTrack(untagged));

    _ = try library.feedback.set(&.{tagged}, .hated);
    try std.testing.expectEqual(@as(u64, 1), try library.feedback.pendingSyncCount());
}

test "a recording takes its MusicBrainz id from whichever of its files carries one" {
    var library = try openFeedbackLibrary("mbid-from-sibling");
    defer library.close();
    const recording = try addRecording(&library);
    const untagged = try addFeedbackTrack(&library, "Song", recording, null);
    _ = try addFeedbackTrack(&library, "Song", recording, feedback_mbid);

    try std.testing.expect(try library.feedback.canSync(untagged));
    _ = try library.feedback.set(&.{untagged}, .loved);
    const pending = (try library.feedback.nextToSync(std.testing.allocator, settled_at)).?;
    defer pending.deinit();
    try std.testing.expectEqualStrings(feedback_mbid, pending.recording_mbid);
}

test "the oldest unsent change is offered first" {
    var library = try openFeedbackLibrary("order");
    defer library.close();
    const first = try addFeedbackTrack(&library, "First", try addRecording(&library), feedback_mbid);
    const second = try addFeedbackTrack(&library, "Second", try addRecording(&library), "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4b");
    _ = try library.feedback.set(&.{second}, .loved);
    try library.database.exec("UPDATE feedback SET updated_at = updated_at - 10;");
    _ = try library.feedback.set(&.{first}, .loved);

    const next = (try library.feedback.nextToSync(std.testing.allocator, settled_at)).?;
    defer next.deinit();
    try std.testing.expectEqualStrings("8f3471b5-7e6a-48da-86a9-c1c07a0f5b4b", next.recording_mbid);
}

const match_mbid = "0b3c4d5e-6f70-4812-9a3b-4c5d6e7f8091";
const rival_mbid = "1d2e3f40-5162-4738-8a9b-0c1d2e3f4a5b";
const match_payload = "{\"title\":\"Song\",\"artist\":\"Nick Drake\",\"album\":\"Bryter Layter\"}";

fn putProposal(library: *LibraryDatabase, file_id: i64, mbid: []const u8, confidence: f32, payload: []const u8) !i64 {
    return putProposalFrom(library, file_id, "musicbrainz", mbid, confidence, payload);
}

fn putProposalFrom(library: *LibraryDatabase, file_id: i64, provider: []const u8, mbid: []const u8, confidence: f32, payload: []const u8) !i64 {
    _ = try library.identification_proposals.put(.{
        .file_id = file_id,
        .provider = provider,
        .provider_id = mbid,
        .confidence = confidence,
        .payload = payload,
    });
    return testScalar(library.database, "SELECT max(id) FROM identification_proposals;");
}

fn playFileOf(library: *LibraryDatabase, track_id: i64) !i64 {
    var sql: [96]u8 = undefined;
    return testScalar(library.database, try std.fmt.bufPrintSentinel(&sql, "SELECT preferred_file_id FROM tracks WHERE id = {d};", .{track_id}, 0));
}

fn proposalState(library: *LibraryDatabase, proposal_id: i64) !repository.ProposalState {
    var sql: [96]u8 = undefined;
    const state = try testScalar(library.database, try std.fmt.bufPrintSentinel(&sql, "SELECT state FROM identification_proposals WHERE id = {d};", .{proposal_id}, 0));
    return @enumFromInt(@as(u8, @intCast(state)));
}

fn expectSyncedUnder(library: *LibraryDatabase, track_id: i64, expected: []const u8, provenance: metadata.Provenance) !void {
    const next = (try library.feedback.nextToSync(std.testing.allocator, settled_at)).?;
    defer next.deinit();
    try std.testing.expectEqualStrings(expected, next.recording_mbid);
    const subject = (try library.listens.listenSubject(std.testing.allocator, track_id)).?;
    defer subject.deinit();
    try std.testing.expectEqualStrings(expected, subject.recording_mbid.?);
    const resolved = (try library.tracks.recordingMbid(std.testing.allocator, track_id)).?;
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, resolved.text);
    try std.testing.expectEqual(provenance, resolved.provenance);
}

test "an accepted match gives feedback and listens a recording id, a file's tag outranks it, and a user's lock outranks both" {
    var library = try openFeedbackLibrary("accepted-match");
    defer library.close();
    const track = try addFeedbackTrack(&library, "Song", try addRecording(&library), null);
    const file = try playFileOf(&library, track);
    _ = try library.feedback.set(&.{track}, .loved);
    try std.testing.expect(!try library.feedback.canSync(track));
    try std.testing.expectEqual(@as(u64, 0), try library.feedback.pendingSyncCount());
    try std.testing.expect(try library.tracks.recordingMbid(std.testing.allocator, track) == null);

    const acceptance = try library.identification_proposals.acceptProposal(
        std.testing.allocator,
        try putProposal(&library, file, match_mbid, 0.9, match_payload),
    );

    try std.testing.expectEqual(@as(u32, 3), acceptance.values_written);
    try std.testing.expectEqual(file, acceptance.file_id);
    try std.testing.expect(try library.feedback.canSync(track));
    try std.testing.expectEqual(@as(u64, 1), try library.feedback.pendingSyncCount());
    try expectSyncedUnder(&library, track, match_mbid, .provider);

    try library.observed_tags.upsert(.{ .file_id = file, .values = .{ .title = "Song", .musicbrainz_recording_id = feedback_mbid } });
    try expectSyncedUnder(&library, track, feedback_mbid, .observed_file);

    try library.orca_metadata.upsert(.{
        .file_id = file,
        .field = .musicbrainz_recording_id,
        .value = rival_mbid,
        .provenance = .user,
        .locked = true,
    });
    try expectSyncedUnder(&library, track, rival_mbid, .user);
}

test "a proposal accepted twice, or after its sibling was, is refused and changes nothing" {
    var library = try openFeedbackLibrary("accept-stale");
    defer library.close();
    const track = try addFeedbackTrack(&library, "Song", try addRecording(&library), null);
    const file = try playFileOf(&library, track);
    const first = try putProposal(&library, file, match_mbid, 0.9, match_payload);
    const sibling = try putProposal(&library, file, rival_mbid, 0.8, match_payload);
    const proposals = &library.identification_proposals;

    _ = try proposals.acceptProposal(std.testing.allocator, first);

    try std.testing.expectError(error.StaleIdentificationProposal, proposals.acceptProposal(std.testing.allocator, first));
    try std.testing.expectError(error.StaleIdentificationProposal, proposals.acceptProposal(std.testing.allocator, sibling));
    try std.testing.expectError(error.StaleIdentificationProposal, proposals.dismiss(sibling));
    try std.testing.expectError(error.UnknownIdentificationProposal, proposals.acceptProposal(std.testing.allocator, sibling + 100));
    try std.testing.expectError(error.UnknownIdentificationProposal, proposals.dismiss(sibling + 100));
    try std.testing.expectEqual(repository.ProposalState.accepted, try proposalState(&library, first));
    try std.testing.expectEqual(repository.ProposalState.dismissed, try proposalState(&library, sibling));
    const stored = (try library.orca_metadata.get(std.testing.allocator, file, .musicbrainz_recording_id)).?;
    defer stored.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(match_mbid, stored.text);
    try std.testing.expect(!stored.locked);
}

test "a proposal whose payload or recording id cannot be read is refused and leaves everything as it was" {
    var library = try openFeedbackLibrary("accept-corrupt");
    defer library.close();
    const track = try addFeedbackTrack(&library, "Song", try addRecording(&library), null);
    const file = try playFileOf(&library, track);
    const corrupt = try putProposal(&library, file, match_mbid, 0.9, "{\"title\":");
    const not_an_id = try putProposal(&library, file, "recording-1", 0.8, match_payload);

    try std.testing.expectError(error.InvalidProposalPayload, library.identification_proposals.acceptProposal(std.testing.allocator, corrupt));
    try std.testing.expectError(error.InvalidProposalPayload, library.identification_proposals.acceptProposal(std.testing.allocator, not_an_id));

    try std.testing.expect(try library.orca_metadata.get(std.testing.allocator, file, .musicbrainz_recording_id) == null);
    try std.testing.expectEqual(repository.ProposalState.pending, try proposalState(&library, corrupt));
    try std.testing.expectEqual(repository.ProposalState.pending, try proposalState(&library, not_an_id));
    try library.identification_proposals.dismiss(corrupt);
    try std.testing.expectEqual(repository.ProposalState.dismissed, try proposalState(&library, corrupt));
}

test "confident proposals are accepted in bulk where a file's best one shows a higher percent than every other" {
    var library = try openFeedbackLibrary("accept-confident");
    defer library.close();
    var files: [6]i64 = undefined;
    for (&files) |*file| file.* = try playFileOf(&library, try addFeedbackTrack(&library, "Song", try addRecording(&library), null));
    const alone = try putProposal(&library, files[0], match_mbid, 0.95, match_payload);
    const contested = try putProposal(&library, files[1], match_mbid, 0.95, match_payload);
    const runner_up = try putProposal(&library, files[1], rival_mbid, 0.92, match_payload);
    const ahead = try putProposal(&library, files[2], match_mbid, 0.95, match_payload);
    const behind = try putProposal(&library, files[2], rival_mbid, 0.6, match_payload);
    const doubtful = try putProposal(&library, files[3], match_mbid, 0.7, match_payload);
    const unreadable = try putProposal(&library, files[4], match_mbid, 0.99, "[");
    const tied = try putProposal(&library, files[5], match_mbid, 0.951, match_payload);
    const also_tied = try putProposal(&library, files[5], rival_mbid, 0.958, match_payload);

    try std.testing.expectEqual(@as(u64, 3), try library.identification_proposals.confidentCount(std.testing.allocator, 0.9));
    const accepted = try library.identification_proposals.acceptConfident(std.testing.allocator, 0.9);
    defer accepted.deinit();

    try std.testing.expectEqual(@as(u64, 3), accepted.accepted);
    try std.testing.expectEqual(repository.ProposalState.accepted, try proposalState(&library, alone));
    try std.testing.expectEqual(repository.ProposalState.accepted, try proposalState(&library, contested));
    try std.testing.expectEqual(repository.ProposalState.dismissed, try proposalState(&library, runner_up));
    try std.testing.expectEqual(repository.ProposalState.accepted, try proposalState(&library, ahead));
    try std.testing.expectEqual(repository.ProposalState.dismissed, try proposalState(&library, behind));
    try std.testing.expectEqual(repository.ProposalState.pending, try proposalState(&library, doubtful));
    try std.testing.expectEqual(repository.ProposalState.pending, try proposalState(&library, unreadable));
    try std.testing.expectEqual(repository.ProposalState.pending, try proposalState(&library, tied));
    try std.testing.expectEqual(repository.ProposalState.pending, try proposalState(&library, also_tied));
    try std.testing.expectEqual(@as(u64, 0), try library.identification_proposals.confidentCount(std.testing.allocator, 0.9));
    for ([_]f32{ 0, -0.5, 1.5, std.math.nan(f32) }) |invalid| {
        try std.testing.expectError(error.InvalidMinimumConfidence, library.identification_proposals.acceptConfident(std.testing.allocator, invalid));
        try std.testing.expectError(error.InvalidMinimumConfidence, library.identification_proposals.confidentCount(std.testing.allocator, invalid));
    }
}

fn acceptedCount(proposals: *repository.IdentificationProposalRepository, minimum_confidence: f32) !u64 {
    const acceptance = try proposals.acceptConfident(std.testing.allocator, minimum_confidence);
    defer acceptance.deinit();
    return acceptance.accepted;
}

const fingerprinted_payload = "{\"title\":\"Song\",\"acoustid_score\":0.95}";

test "a match the file's fingerprint backs is accepted in bulk over a more confident text-only rival" {
    var library = try openFeedbackLibrary("accept-fingerprinted");
    defer library.close();
    const file = try playFileOf(&library, try addFeedbackTrack(&library, "Song", try addRecording(&library), null));
    const live_version = try putProposal(&library, file, rival_mbid, 0.97, match_payload);
    const fingerprinted = try putProposalFrom(&library, file, "acoustid", match_mbid, 0.85, fingerprinted_payload);

    try std.testing.expectEqual(@as(u64, 1), try library.identification_proposals.confidentCount(std.testing.allocator, 0.8));
    try std.testing.expectEqual(@as(u64, 1), try acceptedCount(&library.identification_proposals, 0.8));

    try std.testing.expectEqual(repository.ProposalState.accepted, try proposalState(&library, fingerprinted));
    try std.testing.expectEqual(repository.ProposalState.dismissed, try proposalState(&library, live_version));
    const stored = (try library.orca_metadata.get(std.testing.allocator, file, .musicbrainz_recording_id)).?;
    defer stored.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(match_mbid, stored.text);
}

test "duplicate recordings the fingerprint backs equally resolve to the song's track number, else the lowest recording ID" {
    var library = try openFeedbackLibrary("accept-duplicates");
    defer library.close();
    const numbered_track = try addFeedbackTrack(&library, "Song", try addRecording(&library), null);
    var sql: [96]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(&sql, "UPDATE tracks SET track_number = 2 WHERE id = {d};", .{numbered_track}, 0));
    const numbered = try playFileOf(&library, numbered_track);
    const unnumbered = try playFileOf(&library, try addFeedbackTrack(&library, "Song", try addRecording(&library), null));
    const on_track = "{\"title\":\"Song\",\"track_number\":2,\"acoustid_score\":0.95}";
    const elsewhere = "{\"title\":\"Song\",\"track_number\":7,\"acoustid_score\":0.95}";
    const numbered_rival = try putProposalFrom(&library, numbered, "musicbrainz+acoustid", rival_mbid, 0.93, on_track);
    const numbered_match = try putProposalFrom(&library, numbered, "musicbrainz+acoustid", match_mbid, 0.935, elsewhere);
    const unnumbered_rival = try putProposalFrom(&library, unnumbered, "musicbrainz+acoustid", rival_mbid, 0.93, on_track);
    const unnumbered_match = try putProposalFrom(&library, unnumbered, "musicbrainz+acoustid", match_mbid, 0.935, elsewhere);

    try std.testing.expectEqual(@as(u64, 2), try acceptedCount(&library.identification_proposals, 0.9));

    try std.testing.expectEqual(repository.ProposalState.accepted, try proposalState(&library, numbered_rival));
    try std.testing.expectEqual(repository.ProposalState.dismissed, try proposalState(&library, numbered_match));
    try std.testing.expectEqual(repository.ProposalState.dismissed, try proposalState(&library, unnumbered_rival));
    try std.testing.expectEqual(repository.ProposalState.accepted, try proposalState(&library, unnumbered_match));
}

test "a Track's proposals come most confident first, old payloads included, and a dismissed one is not offered" {
    var library = try openFeedbackLibrary("proposal-page");
    defer library.close();
    const track = try addFeedbackTrack(&library, "Song", try addRecording(&library), null);
    const file = try playFileOf(&library, track);
    const older = try putProposal(&library, file, rival_mbid, 0.7, "{\"title\":\"Old\",\"artist\":\"Nick Drake\",\"album\":\"Five Leaves Left\",\"track_number\":2}");
    const newer = try putProposal(
        &library,
        file,
        match_mbid,
        0.9,
        "{\"title\":\"Song\",\"artist\":\"Nick Drake\",\"album\":\"Bryter Layter\",\"release_mbid\":\"" ++ feedback_mbid ++ "\",\"duration_ms\":224000,\"mb_score\":97,\"extra\":1}",
    );

    const page = try library.identification_proposals.pendingForTrack(std.testing.allocator, track, 10);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqual(newer, page.items[0].id);
    try std.testing.expectEqualStrings(match_mbid, page.items[0].recording_mbid);
    try std.testing.expectEqualStrings(feedback_mbid, page.items[0].release_mbid.?);
    try std.testing.expectEqual(@as(?u64, 224_000), page.items[0].duration_ms);
    try std.testing.expectEqual(@as(?u8, 97), page.items[0].musicbrainz_score);
    try std.testing.expectEqual(older, page.items[1].id);
    try std.testing.expectEqualStrings("Five Leaves Left", page.items[1].album);
    try std.testing.expectEqual(@as(?u32, 2), page.items[1].track_number);
    try std.testing.expectEqual(@as(?[]const u8, null), page.items[1].release_mbid);
    try std.testing.expectEqual(@as(?u8, null), page.items[1].musicbrainz_score);

    try library.identification_proposals.dismiss(newer);
    const remaining = try library.identification_proposals.pendingForTrack(std.testing.allocator, track, 10);
    defer remaining.deinit();
    try std.testing.expectEqual(@as(usize, 1), remaining.items.len);
    try std.testing.expectEqual(older, remaining.items[0].id);
    try std.testing.expectError(error.PageOutOfRange, library.identification_proposals.pendingForTrack(std.testing.allocator, track, 0));
}

test "matching selects a Track until each provider in scope has answered for its file, and never one with a recording id" {
    var library = try openFeedbackLibrary("unidentified");
    defer library.close();
    const proposals = &library.identification_proposals;
    _ = try addFeedbackTrack(&library, "Tagged", try addRecording(&library), feedback_mbid);
    const untagged = try addFeedbackTrack(&library, "Untagged", try addRecording(&library), null);
    const recording = try addRecording(&library);
    const two_files = try addFeedbackTrack(&library, "Two Files", recording, null);
    const second_file = try library.files.create(.{ .audio_format = 2, .size_bytes = 2048 });
    var sql: [96]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(&sql, "UPDATE files SET recording_id = {d} WHERE id = {d};", .{ recording, second_file }, 0));
    const musicbrainz_answered = try addFeedbackTrack(&library, "MusicBrainz Answered", try addRecording(&library), null);
    _ = try proposals.recordSearch(std.testing.allocator, try playFileOf(&library, musicbrainz_answered), .{ .musicbrainz = true }, &.{});
    const both_answered = try addFeedbackTrack(&library, "Both Answered", try addRecording(&library), null);
    _ = try proposals.recordSearch(std.testing.allocator, try playFileOf(&library, both_answered), .{ .musicbrainz = true, .acoustid = true }, &.{});
    const matched = try addFeedbackTrack(&library, "Matched", try addRecording(&library), null);
    _ = try proposals.acceptProposal(std.testing.allocator, try putProposal(&library, try playFileOf(&library, matched), match_mbid, 0.9, match_payload));

    try std.testing.expectEqual(@as(u64, 2), try proposals.unidentifiedCount(.library, .unidentified, false, null));
    try std.testing.expectEqual(@as(u64, 3), try proposals.unidentifiedCount(.library, .unidentified, true, null));
    try std.testing.expectEqual(@as(u64, 2), try proposals.unidentifiedCount(.library, .unidentified, true, 2));
    try std.testing.expectEqual(@as(u64, 1), try proposals.unidentifiedCount(.{ .track = two_files }, .unidentified, false, null));
    try std.testing.expectEqual(@as(u64, 0), try proposals.unidentifiedCount(.{ .track = musicbrainz_answered }, .unidentified, false, null));
    try std.testing.expectEqual(@as(u64, 1), try proposals.unidentifiedCount(.{ .track = musicbrainz_answered }, .unidentified, true, null));
    const only = try proposals.unidentifiedPage(std.testing.allocator, .{ .track = two_files }, .unidentified, false, 0, 2);
    defer only.deinit();
    try std.testing.expectEqual(@as(usize, 1), only.items.len);
    try std.testing.expectEqual(two_files, only.items[0].track_id);
    const first = try proposals.unidentifiedPage(std.testing.allocator, .library, .unidentified, true, 0, 2);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 2), first.items.len);
    try std.testing.expectEqual(untagged, first.items[0].track_id);
    try std.testing.expectEqualStrings("Nick Drake", first.items[0].artist);
    try std.testing.expect(first.items[0].needs_musicbrainz and first.items[0].needs_acoustid);
    try std.testing.expectEqual(@as(?[]u8, null), first.items[0].path);
    try std.testing.expectEqual(two_files, first.items[1].track_id);
    try std.testing.expectEqual(try playFileOf(&library, two_files), first.items[1].file_id);
    const rest = try proposals.unidentifiedPage(std.testing.allocator, .library, .unidentified, true, first.items[1].track_id, 2);
    defer rest.deinit();
    try std.testing.expectEqual(@as(usize, 1), rest.items.len);
    try std.testing.expectEqual(musicbrainz_answered, rest.items[0].track_id);
    try std.testing.expect(!rest.items[0].needs_musicbrainz and rest.items[0].needs_acoustid);

    try library.observed_tags.upsert(.{ .file_id = try playFileOf(&library, untagged), .values = .{
        .title = "Untagged",
        .musicbrainz_recording_id = rival_mbid,
    } });
    try std.testing.expectEqual(@as(u64, 2), try proposals.unidentifiedCount(.library, .unidentified, true, null));
}

test "re-identify selects every Track in scope with a play file, with the recording id in effect, whatever was answered" {
    var library = try openFeedbackLibrary("reidentify");
    defer library.close();
    const proposals = &library.identification_proposals;
    const tagged = try addFeedbackTrack(&library, "Tagged", try addRecording(&library), feedback_mbid);
    const both_answered = try addFeedbackTrack(&library, "Both Answered", try addRecording(&library), null);
    _ = try proposals.recordSearch(std.testing.allocator, try playFileOf(&library, both_answered), .{ .musicbrainz = true, .acoustid = true }, &.{});

    try std.testing.expectEqual(@as(u64, 0), try proposals.unidentifiedCount(.{ .track = tagged }, .unidentified, true, null));
    try std.testing.expectEqual(@as(u64, 2), try proposals.unidentifiedCount(.library, .every, true, null));
    try std.testing.expectEqual(@as(u64, 1), try proposals.unidentifiedCount(.{ .track = tagged }, .every, false, null));
    const page = try proposals.unidentifiedPage(std.testing.allocator, .library, .every, false, 0, 10);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqual(tagged, page.items[0].track_id);
    try std.testing.expectEqualStrings(feedback_mbid, page.items[0].recording_mbid.?);
    try std.testing.expect(page.items[0].needs_musicbrainz and !page.items[0].needs_acoustid);
    try std.testing.expectEqual(both_answered, page.items[1].track_id);
    try std.testing.expectEqual(@as(?[]u8, null), page.items[1].recording_mbid);
    try std.testing.expect(page.items[1].needs_musicbrainz);
}

fn proposalScalar(library: *LibraryDatabase, comptime column: []const u8, proposal_id: i64) !i64 {
    var sql: [128]u8 = undefined;
    return testScalar(library.database, try std.fmt.bufPrintSentinel(&sql, "SELECT " ++ column ++ " FROM identification_proposals WHERE id = {d};", .{proposal_id}, 0));
}

test "a search's proposals merge by recording, two providers agreeing raise the confidence, and a dismissed one stays dismissed" {
    var library = try openFeedbackLibrary("merge");
    defer library.close();
    const proposals = &library.identification_proposals;
    const file = try playFileOf(&library, try addFeedbackTrack(&library, "Song", try addRecording(&library), null));

    try std.testing.expectEqual(@as(u32, 1), try proposals.recordSearch(std.testing.allocator, file, .{ .musicbrainz = true }, &.{.{
        .recording_mbid = match_mbid,
        .found_by = .{ .musicbrainz = true },
        .payload = .{ .title = "Song", .album = "Bryter Layter", .mb_score = 100, .musicbrainz_confidence = 0.8 },
    }}));
    const merged = try testScalar(library.database, "SELECT max(id) FROM identification_proposals;");
    const legacy = try putProposal(&library, file, rival_mbid, 0.6, match_payload);
    try proposals.dismiss(legacy);
    try std.testing.expectEqual(@as(u32, 1), try proposals.recordSearch(std.testing.allocator, file, .{ .acoustid = true }, &.{
        .{
            .recording_mbid = match_mbid,
            .found_by = .{ .acoustid = true },
            .payload = .{ .title = "AcoustID title", .acoustid_score = 0.95, .acoustid_confidence = 0.7 },
        },
        .{
            .recording_mbid = rival_mbid,
            .found_by = .{ .acoustid = true },
            .payload = .{ .title = "", .acoustid_score = 0.9, .acoustid_confidence = 0.9 },
        },
    }));

    try std.testing.expectEqual(@as(i64, 2), try testScalar(library.database, "SELECT count(*) FROM identification_proposals;"));
    const page = try proposals.pendingForTrack(std.testing.allocator, try testScalar(library.database, "SELECT min(id) FROM tracks;"), 10);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    const both = page.items[0];
    try std.testing.expectEqual(merged, both.id);
    try std.testing.expectEqualStrings("musicbrainz+acoustid", both.provider);
    try std.testing.expectApproxEqAbs(@as(f32, 1 - 0.2 * 0.3), both.confidence, 0.0001);
    try std.testing.expect(both.confidence > 0.8);
    try std.testing.expectEqualStrings("Song", both.title);
    try std.testing.expectEqual(@as(?u8, 100), both.musicbrainz_score);
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), both.acoustid_score.?, 0.0001);
    try std.testing.expectEqual(repository.ProposalState.dismissed, try proposalState(&library, legacy));
    try std.testing.expectEqual(@as(i64, 96), try proposalScalar(&library, "CAST(round(confidence * 100) AS INTEGER)", legacy));
    try std.testing.expectEqual(@as(i64, 2), try testScalar(library.database, "SELECT count(*) FROM identification_searches;"));

    try std.testing.expectError(error.InvalidIdentificationProposal, proposals.recordSearch(std.testing.allocator, file, .{ .musicbrainz = true }, &.{.{
        .recording_mbid = "not-a-recording",
        .found_by = .{ .musicbrainz = true },
        .payload = .{},
    }}));
    try std.testing.expectEqual(@as(i64, 2), try testScalar(library.database, "SELECT count(*) FROM identification_searches;"));
}

fn setRecordingId(library: *LibraryDatabase, track_id: i64, mbid: []const u8, provenance: metadata.Provenance, locked: bool) !void {
    try library.orca_metadata.upsert(.{
        .file_id = try playFileOf(library, track_id),
        .field = .musicbrainz_recording_id,
        .value = mbid,
        .provenance = provenance,
        .locked = locked,
    });
}

test "only a recording ID Orca chose and the file's tag does not carry is offered to AcoustID, once per ID" {
    var library = try openFeedbackLibrary("submittable");
    defer library.close();
    const accepted = try addFeedbackTrack(&library, "Accepted", try addRecording(&library), null);
    _ = try library.identification_proposals.acceptProposal(std.testing.allocator, try putProposal(
        &library,
        try playFileOf(&library, accepted),
        match_mbid,
        0.9,
        "{\"title\":\"Accepted\",\"duration_ms\":181000}",
    ));
    const tag_wins = try addFeedbackTrack(&library, "Tag Wins", try addRecording(&library), feedback_mbid);
    try setRecordingId(&library, tag_wins, match_mbid, .user, false);
    const same_as_tag = try addFeedbackTrack(&library, "Same As Tag", try addRecording(&library), feedback_mbid);
    try setRecordingId(&library, same_as_tag, feedback_mbid, .user, true);
    const locked_edit = try addFeedbackTrack(&library, "Locked Edit", try addRecording(&library), feedback_mbid);
    try setRecordingId(&library, locked_edit, rival_mbid, .user, true);
    const inferred = try addFeedbackTrack(&library, "Inferred", try addRecording(&library), null);
    try setRecordingId(&library, inferred, rival_mbid, .inference, false);
    const submissions = &library.acoustid_submissions;

    try std.testing.expectEqual(@as(u64, 2), try submissions.submittableCount());
    const page = try submissions.submittablePage(std.testing.allocator, 0, 10);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqual(accepted, page.items[0].track_id);
    try std.testing.expectEqualStrings(match_mbid, page.items[0].recording_mbid);
    try std.testing.expectEqual(@as(?u64, 181_000), page.items[0].recording_length_ms);
    try std.testing.expectEqualStrings("Bryter Layter", page.items[0].album);
    try std.testing.expectEqual(locked_edit, page.items[1].track_id);
    try std.testing.expectEqual(@as(?u64, null), page.items[1].recording_length_ms);

    try submissions.record(&.{.{ .file_id = page.items[0].file_id, .recording_mbid = match_mbid, .submission_id = 41 }});
    try std.testing.expectEqual(@as(u64, 1), try submissions.submittableCount());
    try setRecordingId(&library, accepted, rival_mbid, .user, false);
    try std.testing.expectEqual(@as(u64, 2), try submissions.submittableCount());
    const later = try submissions.submittablePage(std.testing.allocator, page.items[0].file_id, 10);
    defer later.deinit();
    try std.testing.expectEqual(@as(usize, 1), later.items.len);
    try std.testing.expectEqual(locked_edit, later.items[0].track_id);
}

test "a recording ID AcoustID proposed or a text-only match accepted in bulk is not offered to AcoustID, while reviewed text matches and edits are" {
    var library = try openFeedbackLibrary("submittable-evidence");
    defer library.close();
    const proposals = &library.identification_proposals;
    const fingerprinted = "{\"title\":\"Song\",\"acoustid_score\":0.97}";
    const from_acoustid = try addFeedbackTrack(&library, "From AcoustID", try addRecording(&library), null);
    _ = try proposals.acceptProposal(std.testing.allocator, try putProposalFrom(&library, try playFileOf(&library, from_acoustid), "acoustid", match_mbid, 0.9, fingerprinted));
    const from_both = try addFeedbackTrack(&library, "From Both", try addRecording(&library), null);
    _ = try proposals.acceptProposal(std.testing.allocator, try putProposalFrom(&library, try playFileOf(&library, from_both), "musicbrainz+acoustid", match_mbid, 0.9, fingerprinted));
    const reviewed = try addFeedbackTrack(&library, "Reviewed", try addRecording(&library), null);
    _ = try proposals.acceptProposal(std.testing.allocator, try putProposal(&library, try playFileOf(&library, reviewed), match_mbid, 0.95, match_payload));
    const edited = try addFeedbackTrack(&library, "Edited", try addRecording(&library), null);
    _ = try proposals.acceptProposal(std.testing.allocator, try putProposalFrom(&library, try playFileOf(&library, edited), "acoustid", match_mbid, 0.9, fingerprinted));
    try setRecordingId(&library, edited, match_mbid, .user, false);
    const bulk = try addFeedbackTrack(&library, "Bulk", try addRecording(&library), null);
    const bulk_proposal = try putProposal(&library, try playFileOf(&library, bulk), match_mbid, 0.95, match_payload);
    try std.testing.expectEqual(@as(u64, 1), try acceptedCount(proposals, 0.9));
    try std.testing.expectEqual(repository.ProposalState.accepted, try proposalState(&library, bulk_proposal));
    const submissions = &library.acoustid_submissions;

    try std.testing.expectEqual(@as(u64, 2), try submissions.submittableCount());
    const page = try submissions.submittablePage(std.testing.allocator, 0, 10);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqual(reviewed, page.items[0].track_id);
    try std.testing.expectEqual(edited, page.items[1].track_id);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(library.database, "SELECT count(*) FROM identification_proposals WHERE accepted_in_bulk = 1;"));
}

fn queryPlan(library: *LibraryDatabase, comptime sql: []const u8) ![]u8 {
    var statement = try library.database.prepare("EXPLAIN QUERY PLAN " ++ sql ++ "");
    defer statement.deinit();
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(std.testing.allocator);
    while (try statement.step() == .row) {
        try joined.appendSlice(std.testing.allocator, statement.columnText(3));
        try joined.append(std.testing.allocator, '\n');
    }
    return joined.toOwnedSlice(std.testing.allocator);
}

test "feedback lookups by recording search an index and never scan files" {
    var library = try openFeedbackLibrary("plans");
    defer library.close();
    const plans = [_][]u8{
        try queryPlan(&library, repository.feedback_next_sql),
        try queryPlan(&library, repository.feedback_pending_sql),
        try queryPlan(&library, repository.feedback_syncable_sql),
        try queryPlan(&library, "SELECT " ++ repository.track_play_file ++ " FROM tracks WHERE tracks.id = 1;"),
    };
    defer for (plans) |plan| std.testing.allocator.free(plan);
    for (plans) |plan| {
        try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN files") == null);
        try std.testing.expect(std.mem.indexOf(u8, plan, "files_by_recording") != null);
    }
}

test "a recording id and the matching selection are looked up by key, never by scanning metadata or proposals" {
    var library = try openFeedbackLibrary("mbid-plans");
    defer library.close();
    const plans = [_][]u8{
        try queryPlan(&library, repository.feedback_next_sql),
        try queryPlan(&library, repository.feedback_pending_sql),
        try queryPlan(&library, repository.feedback_syncable_sql),
        try queryPlan(&library, repository.unidentified_page_sql),
        try queryPlan(&library, "SELECT " ++ repository.effectiveRecordingMbid("1") ++ ";"),
        try queryPlan(&library, repository.acoustid_submittable_page_sql),
        try queryPlan(&library, repository.review_page_sql),
        try queryPlan(&library, repository.review_count_sql),
        try queryPlan(&library, repository.unidentified_release_page_sql),
        try queryPlan(&library, repository.reidentify_page_sql),
        try queryPlan(&library, repository.reidentify_release_page_sql),
    };
    defer for (plans) |plan| std.testing.allocator.free(plan);
    for (plans) |plan| {
        try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN orca_metadata_values") == null);
        try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN observed_file_tags") == null);
        try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN identification_proposals") == null);
        try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN files") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, plans[3], "SCAN tracks") == null);
    try std.testing.expect(std.mem.indexOf(u8, plans[8], "SCAN tracks") == null);
}

test "verification selects its files by Release, Track and key, never by scanning metadata, files or verifications" {
    var library = try openFeedbackLibrary("verify-plans");
    defer library.close();
    const plans = [_][]u8{
        try queryPlan(&library, repository.verifiable_release_page_sql),
        try queryPlan(&library, repository.verifiable_loose_page_sql),
        try queryPlan(&library, repository.verifiable_track_page_sql),
        try queryPlan(&library, repository.verifiable_releases_sql),
        try queryPlan(&library, repository.verifiable_count_sql),
    };
    defer for (plans) |plan| std.testing.allocator.free(plan);
    for (plans) |plan| {
        try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN orca_metadata_values") == null);
        try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN observed_file_tags") == null);
        try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN recording_verifications") == null);
        try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN files") == null);
    }
    for (plans[0..4]) |plan| try std.testing.expect(std.mem.indexOf(u8, plan, "SCAN tracks") == null);
}

test "a change is offered only once it has stood for two seconds, and the count includes it before" {
    var library = try openFeedbackLibrary("settle");
    defer library.close();
    const track = try addFeedbackTrack(&library, "Song", try addRecording(&library), feedback_mbid);
    _ = try library.feedback.set(&.{track}, .loved);
    const changed_at = try testScalar(library.database, "SELECT updated_at FROM feedback;");

    try std.testing.expect(try library.feedback.nextToSync(std.testing.allocator, changed_at) == null);
    try std.testing.expect(try library.feedback.nextToSync(std.testing.allocator, changed_at + 1) == null);
    try std.testing.expectEqual(@as(u64, 1), try library.feedback.pendingSyncCount());
    const ready = (try library.feedback.nextToSync(std.testing.allocator, changed_at + repository.feedback_settle_seconds)).?;
    ready.deinit();
}

test "clearing feedback the service refused forgets it without a clear to send" {
    var library = try openFeedbackLibrary("clear-rejected");
    defer library.close();
    const track = try addFeedbackTrack(&library, "Song", try addRecording(&library), feedback_mbid);
    _ = try library.feedback.set(&.{track}, .loved);
    const sending = (try library.feedback.nextToSync(std.testing.allocator, settled_at)).?;
    defer sending.deinit();
    try library.feedback.markRejected(sending.recording_id, sending.feedback, "HTTP 400");

    const change = try library.feedback.set(&.{track}, .none);

    try std.testing.expectEqual(@as(u32, 1), change.updated);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT count(*) FROM feedback;"));
    try std.testing.expect(try library.feedback.nextToSync(std.testing.allocator, settled_at) == null);
}

test "clearing a Track that has no feedback changes nothing and is not counted" {
    var library = try openFeedbackLibrary("clear-nothing");
    defer library.close();
    const track = try addFeedbackTrack(&library, "Song", try addRecording(&library), feedback_mbid);

    const change = try library.feedback.set(&.{track}, .none);

    try std.testing.expectEqual(@as(u32, 0), change.updated);
    try std.testing.expectEqual(@as(u32, 0), change.skipped);
}

test "a rating belongs to the recording, shows on every Track of it and survives a new Track id" {
    var library = try openFeedbackLibrary("rating-shared");
    defer library.close();
    const recording = try addRecording(&library);
    const flac = try addFeedbackTrack(&library, "Northern Sky", recording, null);
    const compilation = try addFeedbackTrack(&library, "Northern Sky", recording, null);
    const bare = try addFeedbackTrack(&library, "Bare", null, null);

    const change = try library.ratings.set(&.{ flac, bare, 9999 }, 80);
    try std.testing.expectEqual(@as(u32, 1), change.updated);
    try std.testing.expectEqual(@as(u32, 2), change.skipped);
    try std.testing.expectEqual(@as(?u8, 80), try library.ratings.forTrack(compilation));
    try std.testing.expectEqual(@as(?u8, null), try library.ratings.forTrack(bare));
    const summary = (try library.tracks.byId(std.testing.allocator, compilation)).?;
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u8, 80), summary.rating);

    try library.database.exec("DELETE FROM tracks WHERE recording_id IS NOT NULL;");
    const reprojected = try addFeedbackTrack(&library, "Northern Sky", recording, null);
    var page = try library.tracks.page(std.testing.allocator, .{});
    defer page.deinit();
    for (page.items) |item| {
        const expected: ?u8 = if (item.id == reprojected) 80 else null;
        try std.testing.expectEqual(expected, item.rating);
    }

    const cleared = try library.ratings.set(&.{ reprojected, reprojected }, null);
    try std.testing.expectEqual(@as(u32, 1), cleared.updated);
    try std.testing.expectEqual(@as(?u8, null), try library.ratings.forTrack(reprojected));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT count(*) FROM ratings;"));
}

test "a rating of 0 or above 100 is refused and writes nothing" {
    var library = try openFeedbackLibrary("rating-invalid");
    defer library.close();
    const track = try addFeedbackTrack(&library, "Song", try addRecording(&library), null);
    _ = try library.ratings.set(&.{track}, 40);

    try std.testing.expectError(error.InvalidRating, library.ratings.set(&.{track}, 0));
    try std.testing.expectError(error.InvalidRating, library.ratings.set(&.{track}, 101));
    try std.testing.expectEqual(@as(?u8, 40), try library.ratings.forTrack(track));
}

test "sorting by rating puts unrated Tracks last in both directions" {
    var library = try openFeedbackLibrary("rating-sort");
    defer library.close();
    const unrated = try addFeedbackTrack(&library, "Unrated", try addRecording(&library), null);
    const low = try addFeedbackTrack(&library, "Low", try addRecording(&library), null);
    const high = try addFeedbackTrack(&library, "High", try addRecording(&library), null);
    _ = try library.ratings.set(&.{low}, 20);
    _ = try library.ratings.set(&.{high}, 100);

    for ([_]struct { SortDirection, [3]i64 }{
        .{ .ascending, .{ low, high, unrated } },
        .{ .descending, .{ high, low, unrated } },
    }) |case| {
        var page = try library.tracks.page(std.testing.allocator, .{ .sort = .rating, .direction = case[0] });
        defer page.deinit();
        try std.testing.expectEqual(@as(usize, 3), page.items.len);
        for (case[1], page.items) |expected, item| try std.testing.expectEqual(expected, item.id);
    }
}

fn addLoveRelease(library: *LibraryDatabase, title: []const u8) !i64 {
    return library.releases.upsert(.{ .release_key = title, .title = title });
}

fn setLovedAt(library: *LibraryDatabase, release_id: i64, loved_at: i64) !void {
    var sql: [96]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(
        &sql,
        "UPDATE release_loves SET loved_at = {d} WHERE release_id = {d};",
        .{ loved_at, release_id },
        0,
    ));
}

test "loving a loved Release keeps when it was loved, and clearing an unloved one changes nothing" {
    var library = try openFeedbackLibrary("release-love");
    defer library.close();
    const album = try addLoveRelease(&library, "Pink Moon");

    const loved = try library.release_loves.set(&.{ album, 9999 }, true);
    try std.testing.expectEqual(@as(u32, 1), loved.updated);
    try std.testing.expectEqual(@as(u32, 1), loved.skipped);
    try std.testing.expect(try library.release_loves.isLoved(album));
    try setLovedAt(&library, album, 100);

    const again = try library.release_loves.set(&.{album}, true);
    try std.testing.expectEqual(@as(u32, 0), again.updated);
    try std.testing.expectEqual(@as(i64, 100), try testScalar(library.database, "SELECT loved_at FROM release_loves;"));

    const cleared = try library.release_loves.set(&.{ album, album }, false);
    try std.testing.expectEqual(@as(u32, 1), cleared.updated);
    try std.testing.expect(!try library.release_loves.isLoved(album));
    const nothing = try library.release_loves.set(&.{album}, false);
    try std.testing.expectEqual(@as(u32, 0), nothing.updated);
    try std.testing.expectEqual(@as(u32, 0), nothing.skipped);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT count(*) FROM feedback;"));

    var many: [repository.max_page + 1]i64 = undefined;
    @memset(&many, album);
    try std.testing.expectError(error.PageOutOfRange, library.release_loves.set(&many, true));
    try std.testing.expect(!try library.release_loves.isLoved(album));
}

test "only loved Releases are listed and counted, most recently loved first" {
    var library = try openFeedbackLibrary("release-love-page");
    defer library.close();
    const artist = (try library.artists.ensure(.{ .key = "nick drake", .name = "Nick Drake" })).?;
    const first = try addLoveRelease(&library, "Five Leaves Left");
    const second = try addLoveRelease(&library, "Bryter Layter");
    const third = try addLoveRelease(&library, "Pink Moon");
    _ = try addLoveRelease(&library, "Unloved");
    try library.database.exec("UPDATE releases SET album_artist_id = (SELECT id FROM artists) WHERE title <> 'Bryter Layter';");
    _ = try library.release_loves.set(&.{ first, second, third }, true);
    try setLovedAt(&library, first, 300);
    try setLovedAt(&library, second, 100);
    try setLovedAt(&library, third, 200);

    for ([_]struct { query: repository.ReleaseQuery, expected: []const i64 }{
        .{ .query = .{ .loved_only = true, .sort = .loved }, .expected = &.{ first, third, second } },
        .{ .query = .{ .loved_only = true, .album_artist_id = artist, .sort = .loved }, .expected = &.{ first, third } },
        .{ .query = .{ .loved_only = true, .album_artist_id = artist }, .expected = &.{ first, third } },
    }) |case| {
        var page = try library.releases.page(std.testing.allocator, case.query);
        defer page.deinit();
        try std.testing.expectEqual(case.expected.len, page.items.len);
        try std.testing.expectEqual(@as(u64, case.expected.len), try library.releases.countMatching(case.query));
        for (case.expected, page.items) |expected, item| {
            try std.testing.expectEqual(expected, item.id);
            try std.testing.expect(item.loved);
        }
    }

    var everything = try library.releases.page(std.testing.allocator, .{ .sort = .loved });
    defer everything.deinit();
    try std.testing.expectEqual(@as(usize, 4), everything.items.len);
    try std.testing.expectEqual(@as(u64, 4), try library.releases.countMatching(.{}));
    try std.testing.expectEqual(second, everything.items[2].id);
    try std.testing.expect(!everything.items[3].loved);
    const unloved = (try library.releases.byId(std.testing.allocator, everything.items[3].id)).?;
    defer unloved.deinit(std.testing.allocator);
    try std.testing.expect(!unloved.loved);
    const summary = (try library.releases.byId(std.testing.allocator, first)).?;
    defer summary.deinit(std.testing.allocator);
    try std.testing.expect(summary.loved);
}

test "only loved Artists are listed and counted, most recently loved first, and loving one twice keeps when it was loved" {
    var library = try openFeedbackLibrary("artist-love-page");
    defer library.close();
    const drake = (try library.artists.ensure(.{ .key = "nick drake", .name = "Nick Drake", .sort_name = "nick drake" })).?;
    const bush = (try library.artists.ensure(.{ .key = "kate bush", .name = "Kate Bush", .sort_name = "kate bush" })).?;
    const eno = (try library.artists.ensure(.{ .key = "brian eno", .name = "Brian Eno", .sort_name = "brian eno" })).?;
    _ = (try library.artists.ensure(.{ .key = "unloved", .name = "Unloved", .sort_name = "unloved" })).?;

    const loved = try library.artist_loves.set(&.{ drake, bush, eno, 9999 }, true);
    try std.testing.expectEqual(@as(u32, 3), loved.updated);
    try std.testing.expectEqual(@as(u32, 1), loved.skipped);
    try library.database.exec("UPDATE artist_loves SET loved_at = CASE artist_id WHEN (SELECT id FROM artists WHERE key = 'nick drake') THEN 300 WHEN (SELECT id FROM artists WHERE key = 'kate bush') THEN 100 ELSE 200 END;");
    const again = try library.artist_loves.set(&.{drake}, true);
    try std.testing.expectEqual(@as(u32, 0), again.updated);
    try std.testing.expectEqual(@as(i64, 300), try testScalar(library.database, "SELECT loved_at FROM artist_loves WHERE artist_id = (SELECT id FROM artists WHERE key = 'nick drake');"));

    for ([_]struct { query: repository.ArtistQuery, expected: []const i64 }{
        .{ .query = .{ .loved_only = true, .sort = .recently_loved }, .expected = &.{ drake, eno, bush } },
        .{ .query = .{ .loved_only = true }, .expected = &.{ eno, bush, drake } },
        .{ .query = .{ .loved_only = true, .filter = "drake" }, .expected = &.{drake} },
    }) |case| {
        var page = try library.artists.page(std.testing.allocator, case.query);
        defer page.deinit();
        try std.testing.expectEqual(case.expected.len, page.items.len);
        try std.testing.expectEqual(@as(u64, case.expected.len), try library.artists.countMatching(case.query));
        for (case.expected, page.items) |expected, item| {
            try std.testing.expectEqual(expected, item.id);
            try std.testing.expect(item.loved);
        }
    }

    var everyone = try library.artists.page(std.testing.allocator, .{ .sort = .recently_loved });
    defer everyone.deinit();
    try std.testing.expectEqual(@as(usize, 4), everyone.items.len);
    try std.testing.expect(!everyone.items[3].loved);
    const cleared = try library.artist_loves.set(&.{ bush, bush }, false);
    try std.testing.expectEqual(@as(u32, 1), cleared.updated);
    try std.testing.expect(!try library.artist_loves.isLoved(bush));
    try std.testing.expectEqual(@as(u64, 2), try library.artists.countMatching(.{ .loved_only = true }));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT count(*) FROM feedback;"));
}

test "only loved Tracks are listed and counted, most recently loved first, and a clear waiting to be sent is not a love" {
    var library = try openFeedbackLibrary("track-love-page");
    defer library.close();
    const older = try addFeedbackTrack(&library, "Older", try addRecording(&library), null);
    const newer = try addFeedbackTrack(&library, "Newer", try addRecording(&library), null);
    const hated = try addFeedbackTrack(&library, "Hated", try addRecording(&library), null);
    const clearing = try addFeedbackTrack(&library, "Clearing", try addRecording(&library), feedback_mbid);
    _ = try addFeedbackTrack(&library, "Plain", try addRecording(&library), null);
    _ = try library.feedback.set(&.{ older, newer, clearing }, .loved);
    _ = try library.feedback.set(&.{hated}, .hated);
    try library.feedback.markSynced(try testScalar(library.database, "SELECT recording_id FROM tracks WHERE title = 'Clearing';"), .loved);
    _ = try library.feedback.set(&.{clearing}, .none);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT score FROM feedback WHERE synced_score = 1;"));
    try library.database.exec(
        \\UPDATE feedback SET updated_at = 100 WHERE recording_id = (SELECT recording_id FROM tracks WHERE title = 'Older');
        \\UPDATE feedback SET updated_at = 200 WHERE recording_id = (SELECT recording_id FROM tracks WHERE title = 'Newer');
    );

    const query: repository.TrackQuery = .{ .loved_only = true, .sort = .loved };
    var page = try library.tracks.page(std.testing.allocator, query);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqual(@as(u64, 2), try library.tracks.countMatching(query));
    try std.testing.expectEqual(newer, page.items[0].id);
    try std.testing.expectEqual(older, page.items[1].id);

    var everything = try library.tracks.page(std.testing.allocator, .{ .sort = .loved });
    defer everything.deinit();
    try std.testing.expectEqual(@as(usize, 5), everything.items.len);
    try std.testing.expectEqual(@as(u64, 5), try library.tracks.countMatching(.{}));
    try std.testing.expectEqual(newer, everything.items[0].id);
    try std.testing.expectEqual(older, everything.items[1].id);
    for (everything.items[2..]) |item| try std.testing.expect(item.feedback != .loved);
}

const SortDirection = repository.SortDirection;

fn expectPlaylist(library: *LibraryDatabase, playlist_id: i64, expected: []const i64) !void {
    var page = try library.playlists.entries(std.testing.allocator, playlist_id, repository.max_page, 0, .{ .now = 0, .seed = 0 });
    defer page.deinit();
    try std.testing.expectEqual(expected.len, page.items.len);
    for (page.items, expected, 0..) |entry, recording_id, position| {
        try std.testing.expectEqual(@as(u32, @intCast(position)), entry.position);
        try std.testing.expectEqual(recording_id, entry.recording_id);
    }
}

test "playlist names are trimmed, non-empty and unique" {
    var library = try openFeedbackLibrary("playlist-names");
    defer library.close();
    const mix = try library.playlists.create("  Mix \t");
    const other = try library.playlists.create("Other");

    try std.testing.expectError(error.PlaylistNameTaken, library.playlists.create("Mix"));
    try std.testing.expectError(error.InvalidPlaylistName, library.playlists.create(""));
    try std.testing.expectError(error.InvalidPlaylistName, library.playlists.create(" \t\n"));
    try std.testing.expectError(error.PlaylistNameTaken, library.playlists.rename(other, " Mix"));
    try std.testing.expectError(error.UnknownPlaylist, library.playlists.rename(9999, "New"));
    try library.playlists.rename(mix, "Mix");
    try library.playlists.rename(mix, "A Mix");

    var page = try library.playlists.list(std.testing.allocator, repository.max_page, 0, .{ .now = 0, .seed = 0 });
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqualStrings("A Mix", page.items[0].name);
    try std.testing.expectEqualStrings("Other", page.items[1].name);
}

test "inserting, moving and removing playlist entries keeps positions contiguous" {
    var library = try openFeedbackLibrary("playlist-order");
    defer library.close();
    const a = try addRecording(&library);
    const b = try addRecording(&library);
    const c = try addRecording(&library);
    const track_a = try addFeedbackTrack(&library, "A", a, null);
    const track_b = try addFeedbackTrack(&library, "B", b, null);
    const track_c = try addFeedbackTrack(&library, "C", c, null);
    const bare = try addFeedbackTrack(&library, "Bare", null, null);
    const playlist = try library.playlists.create("Mix");

    const added = try library.playlists.insert(playlist, &.{ track_a, bare, track_b, track_c }, null);
    try std.testing.expectEqual(@as(u32, 3), added.added);
    try std.testing.expectEqual(@as(u32, 1), added.skipped);
    try expectPlaylist(&library, playlist, &.{ a, b, c });

    try library.playlists.move(playlist, 0, 2);
    try expectPlaylist(&library, playlist, &.{ b, c, a });
    try library.playlists.move(playlist, 2, 0);
    try expectPlaylist(&library, playlist, &.{ a, b, c });
    try library.playlists.move(playlist, 2, 0);
    try expectPlaylist(&library, playlist, &.{ c, a, b });
    try library.playlists.move(playlist, 1, 1);
    try expectPlaylist(&library, playlist, &.{ c, a, b });
    try std.testing.expectError(error.PositionOutOfRange, library.playlists.move(playlist, 3, 0));

    try std.testing.expectError(error.PositionOutOfRange, library.playlists.insert(playlist, &.{track_a}, 5));
    _ = try library.playlists.insert(playlist, &.{track_a}, 3);
    try expectPlaylist(&library, playlist, &.{ c, a, b, a });
    _ = try library.playlists.insert(playlist, &.{ track_b, track_c }, 1);
    try expectPlaylist(&library, playlist, &.{ c, b, c, a, b, a });

    try std.testing.expectError(error.PositionOutOfRange, library.playlists.remove(playlist, &.{ 1, 6 }));
    try expectPlaylist(&library, playlist, &.{ c, b, c, a, b, a });
    try std.testing.expectEqual(@as(u32, 3), try library.playlists.remove(playlist, &.{ 4, 0, 0, 2 }));
    try expectPlaylist(&library, playlist, &.{ b, a, a });
    try std.testing.expectEqual(@as(u32, 1), try library.playlists.remove(playlist, &.{ 0, 0 }));
    try expectPlaylist(&library, playlist, &.{ a, a });

    var page = try library.playlists.list(std.testing.allocator, repository.max_page, 0, .{ .now = 0, .seed = 0 });
    defer page.deinit();
    try std.testing.expectEqual(@as(u32, 2), page.items[0].entries);
    try std.testing.expectEqual(@as(u32, 2), page.items[0].available);
}

test "an add that would take a playlist past 10,000 entries fails and writes nothing" {
    var library = try openFeedbackLibrary("playlist-full");
    defer library.close();
    const recording = try addRecording(&library);
    const track = try addFeedbackTrack(&library, "Song", recording, null);
    const playlist = try library.playlists.create("Long");
    var sql: [256]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(
        &sql,
        "WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < 9998) " ++
            "INSERT INTO playlist_entries SELECT {d}, i, {d}, 0 FROM n;",
        .{ playlist, recording },
        0,
    ));

    try std.testing.expectError(error.PlaylistFull, library.playlists.insert(playlist, &.{ track, track }, 0));
    var many: [repository.max_page + 1]i64 = @splat(track);
    try std.testing.expectError(error.PageOutOfRange, library.playlists.insert(playlist, &many, null));
    try std.testing.expectEqual(@as(i64, 9999), try testScalar(library.database, "SELECT count(*) FROM playlist_entries;"));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT min(position) FROM playlist_entries;"));
    _ = try library.playlists.insert(playlist, &.{track}, 0);
    try std.testing.expectEqual(@as(i64, 9999), try testScalar(library.database, "SELECT max(position) FROM playlist_entries;"));
}

test "deleting a playlist removes its entries" {
    var library = try openFeedbackLibrary("playlist-delete");
    defer library.close();
    const track = try addFeedbackTrack(&library, "Song", try addRecording(&library), null);
    const playlist = try library.playlists.create("Gone");
    const kept = try library.playlists.create("Kept");
    _ = try library.playlists.insert(playlist, &.{ track, track }, null);
    _ = try library.playlists.insert(kept, &.{track}, null);

    try library.playlists.delete(playlist);

    try std.testing.expectError(error.UnknownPlaylist, library.playlists.delete(playlist));
    try std.testing.expectError(error.UnknownPlaylist, library.playlists.entries(std.testing.allocator, playlist, 10, 0, .{ .now = 0, .seed = 0 }));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(library.database, "SELECT count(*) FROM playlist_entries;"));
}

test "a playlist entry plays its recording's lowest Track id and is unavailable without a Track" {
    var library = try openFeedbackLibrary("playlist-resolve");
    defer library.close();
    const shared = try addRecording(&library);
    const gone = try addRecording(&library);
    const first = try addFeedbackTrack(&library, "First", shared, null);
    const second = try addFeedbackTrack(&library, "Second", shared, null);
    const leaving = try addFeedbackTrack(&library, "Leaving", gone, null);
    const playlist = try library.playlists.create("Mix");
    _ = try library.playlists.insert(playlist, &.{ second, leaving, first }, null);
    var sql: [64]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(&sql, "DELETE FROM tracks WHERE id = {d};", .{leaving}, 0));

    var page = try library.playlists.entries(std.testing.allocator, playlist, 10, 0, .{ .now = 0, .seed = 0 });
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 3), page.items.len);
    try std.testing.expectEqual(first, page.items[0].track.?.id);
    try std.testing.expectEqualStrings("First", page.items[0].track.?.title);
    try std.testing.expect(page.items[1].track == null);
    try std.testing.expectEqual(gone, page.items[1].recording_id);
    try std.testing.expectEqual(first, page.items[2].track.?.id);

    const ids = try library.playlists.trackIds(std.testing.allocator, playlist, .{ .now = 0, .seed = 0 });
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(i64, &.{ first, first }, ids);

    var playlists = try library.playlists.list(std.testing.allocator, 10, 0, .{ .now = 0, .seed = 0 });
    defer playlists.deinit();
    try std.testing.expectEqual(@as(u32, 3), playlists.items[0].entries);
    try std.testing.expectEqual(@as(u32, 2), playlists.items[0].available);
}

test "playlist metadata keeps its tags in order, and only description and tag changes move updated_at" {
    var library = try openFeedbackLibrary("playlist-metadata");
    defer library.close();
    const playlist = try library.playlists.create("Mix");
    try library.database.exec("UPDATE playlists SET updated_at = 5;");

    try library.playlists.update(playlist, .{ .pinned = true, .loved = true });
    try std.testing.expectEqual(@as(i64, 5), try testScalar(library.database, "SELECT updated_at FROM playlists;"));
    try std.testing.expect(try testScalar(library.database, "SELECT pinned_at FROM playlists;") > 5);

    try library.playlists.update(playlist, .{ .description = "  Late night  ", .tags = &.{ " lofi ", "focus", "lofi" } });
    try std.testing.expect(try testScalar(library.database, "SELECT updated_at FROM playlists;") > 5);
    {
        const summary = try library.playlists.summary(std.testing.allocator, playlist, .{ .now = 0, .seed = 0 });
        defer summary.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("Late night", summary.description);
        try std.testing.expect(summary.pinned and summary.loved);
        try std.testing.expectEqual(repository.PlaylistKind.manual, summary.kind);
        try std.testing.expectEqual(repository.PlaylistCreator.user, summary.creator);
        try std.testing.expectEqual(@as(usize, 2), summary.tags.len);
        try std.testing.expectEqualStrings("lofi", summary.tags[0]);
        try std.testing.expectEqualStrings("focus", summary.tags[1]);
    }

    try library.playlists.update(playlist, .{ .pinned = false, .tags = &.{} });
    {
        const summary = try library.playlists.summary(std.testing.allocator, playlist, .{ .now = 0, .seed = 0 });
        defer summary.deinit(std.testing.allocator);
        try std.testing.expect(!summary.pinned and summary.loved);
        try std.testing.expectEqual(@as(usize, 0), summary.tags.len);
        try std.testing.expectEqualStrings("Late night", summary.description);
    }

    const nine: [9][]const u8 = .{ "a", "b", "c", "d", "e", "f", "g", "h", "i" };
    try std.testing.expectError(error.TooManyPlaylistTags, library.playlists.update(playlist, .{ .tags = &nine }));
    try std.testing.expectError(error.InvalidPlaylistTag, library.playlists.update(playlist, .{ .tags = &.{" "} }));
    const long_tag: [65]u8 = @splat('t');
    try std.testing.expectError(error.InvalidPlaylistTag, library.playlists.update(playlist, .{ .tags = &.{&long_tag} }));
    const long_description: [4097]u8 = @splat('d');
    try std.testing.expectError(error.PlaylistDescriptionTooLong, library.playlists.update(playlist, .{ .description = &long_description }));
    try std.testing.expectError(error.UnknownPlaylist, library.playlists.update(9999, .{ .pinned = true }));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT count(*) FROM playlist_tags;"));
}

test "playlist pages filter by name, kind, pin and creator and sort as asked" {
    var library = try openFeedbackLibrary("playlist-page");
    defer library.close();
    const recording = try addRecording(&library);
    const track = try addFeedbackTrack(&library, "Song", recording, null);
    const alpha = try library.playlists.create("Alpha mix");
    const beta = try library.playlists.createSmart(std.testing.allocator, "Beta", "{\"v\":1,\"rules\":[]}");
    const gamma = try library.playlists.createWithRecordings(std.testing.allocator, "Gamma mix", &.{ recording, recording });
    _ = try library.playlists.insert(alpha, &.{track}, null);
    try library.playlists.update(alpha, .{ .pinned = true });
    try library.database.exec(
        \\UPDATE playlists SET created_at = id, updated_at = 10 - id;
    );

    const Case = struct { query: repository.PlaylistQuery, ids: []const i64 };
    const cases = [_]Case{
        .{ .query = .{}, .ids = &.{ alpha, beta, gamma } },
        .{ .query = .{ .sort = .created }, .ids = &.{ gamma, beta, alpha } },
        .{ .query = .{ .sort = .name }, .ids = &.{ alpha, beta, gamma } },
        .{ .query = .{ .sort = .entries }, .ids = &.{ gamma, alpha, beta } },
        .{ .query = .{ .filter = "MIX" }, .ids = &.{ alpha, gamma } },
        .{ .query = .{ .kind = .smart }, .ids = &.{beta} },
        .{ .query = .{ .kind = .manual }, .ids = &.{ alpha, gamma } },
        .{ .query = .{ .pinned_only = true }, .ids = &.{alpha} },
        .{ .query = .{ .created_by = .imported }, .ids = &.{gamma} },
        .{ .query = .{ .created_by = .user, .sort = .name }, .ids = &.{ alpha, beta } },
        .{ .query = .{ .limit = 1, .offset = 1 }, .ids = &.{beta} },
    };
    for (cases) |case| {
        var page = try library.playlists.page(std.testing.allocator, case.query, .{ .now = 0, .seed = 0 });
        defer page.deinit();
        try std.testing.expectEqual(case.ids.len, page.items.len);
        for (page.items, case.ids) |item, id| try std.testing.expectEqual(id, item.id);
        var unpaged = case.query;
        unpaged.offset = 0;
        unpaged.limit = repository.max_page;
        if (case.query.limit == repository.max_page)
            try std.testing.expectEqual(@as(u64, case.ids.len), try library.playlists.pageCount(unpaged));
    }
    try std.testing.expectError(error.PageOutOfRange, library.playlists.page(std.testing.allocator, .{ .limit = 0 }, .{ .now = 0, .seed = 0 }));
}

fn addSmartTrack(library: *LibraryDatabase, title: []const u8, artist: []const u8) !i64 {
    const recording = try addRecording(library);
    const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
    var sql: [96]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(&sql, "UPDATE files SET recording_id = {d} WHERE id = {d};", .{ recording, file_id }, 0));
    try library.tracks.upsertTracks(&.{.{
        .recording_id = recording,
        .title = title,
        .artist = artist,
        .album = "Album",
        .preferred_file_id = file_id,
    }});
    return testScalar(library.database, try std.fmt.bufPrintSentinel(&sql, "SELECT id FROM tracks WHERE preferred_file_id = {d};", .{file_id}, 0));
}

test "a smart playlist's relative dates count back from the clock it is given, not the wall clock" {
    var library = try openFeedbackLibrary("playlist-smart-clock");
    defer library.close();
    const day = std.time.s_per_day;
    const old = try addSmartTrack(&library, "Old", "Artist");
    const recent = try addSmartTrack(&library, "Recent", "Artist");
    var sql: [128]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(&sql, "UPDATE files SET first_seen_at = {d} WHERE id = (SELECT preferred_file_id FROM tracks WHERE id = {d});", .{ 100 * day, old }, 0));
    try library.database.exec(try std.fmt.bufPrintSentinel(&sql, "UPDATE files SET first_seen_at = {d} WHERE id = (SELECT preferred_file_id FROM tracks WHERE id = {d});", .{ 200 * day, recent }, 0));
    const in_last =
        \\{"v":1,"rules":[{"field":"added_at","op":"in_last_days","value":30}]}
    ;
    const not_in_last =
        \\{"v":1,"rules":[{"field":"added_at","op":"not_in_last_days","value":30}]}
    ;
    try std.testing.expectEqual(@as(u64, 2), try library.playlists.smartCount(std.testing.allocator, in_last, .{ .now = 110 * day, .seed = 0 }));
    try std.testing.expectEqual(@as(u64, 1), try library.playlists.smartCount(std.testing.allocator, in_last, .{ .now = 210 * day, .seed = 0 }));
    try std.testing.expectEqual(@as(u64, 0), try library.playlists.smartCount(std.testing.allocator, in_last, .{ .now = 300 * day, .seed = 0 }));
    try std.testing.expectEqual(@as(u64, 0), try library.playlists.smartCount(std.testing.allocator, not_in_last, .{ .now = 110 * day, .seed = 0 }));
    try std.testing.expectEqual(@as(u64, 1), try library.playlists.smartCount(std.testing.allocator, not_in_last, .{ .now = 210 * day, .seed = 0 }));

    const playlist = try library.playlists.createSmart(std.testing.allocator, "Recent", in_last);
    var page = try library.playlists.entries(std.testing.allocator, playlist, repository.max_page, 0, .{ .now = 210 * day, .seed = 0 });
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqual(recent, page.items[0].track.?.id);
}

fn smartTrackIds(library: *LibraryDatabase, rules: []const u8, seed: u64) ![]i64 {
    var preview = try library.playlists.smartPreview(std.testing.allocator, rules, repository.max_page, .{ .now = 0, .seed = seed });
    defer preview.deinit(std.testing.allocator);
    const ids = try std.testing.allocator.alloc(i64, preview.sample.len);
    for (ids, preview.sample) |*id, track| id.* = track.id;
    return ids;
}

test "a random smart playlist order is fixed by its seed and two seeds give the same Tracks in another order" {
    var library = try openFeedbackLibrary("playlist-smart-random");
    defer library.close();
    var title_buffer: [16]u8 = undefined;
    for (0..40) |index| _ = try addSmartTrack(&library, try std.fmt.bufPrint(&title_buffer, "Song {d}", .{index}), "Artist");
    const rules =
        \\{"v":1,"rules":[],"sort":{"field":"random"}}
    ;
    const first = try smartTrackIds(&library, rules, 1);
    defer std.testing.allocator.free(first);
    const again = try smartTrackIds(&library, rules, 1);
    defer std.testing.allocator.free(again);
    const second = try smartTrackIds(&library, rules, 2);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqual(@as(usize, 40), first.len);
    try std.testing.expectEqualSlices(i64, first, again);
    try std.testing.expect(!std.mem.eql(i64, first, second));
    const sorted_first = try std.testing.allocator.dupe(i64, first);
    defer std.testing.allocator.free(sorted_first);
    const sorted_second = try std.testing.allocator.dupe(i64, second);
    defer std.testing.allocator.free(sorted_second);
    std.mem.sort(i64, sorted_first, {}, std.sort.asc(i64));
    std.mem.sort(i64, sorted_second, {}, std.sort.asc(i64));
    try std.testing.expectEqualSlices(i64, sorted_first, sorted_second);

    const playlist = try library.playlists.createSmart(std.testing.allocator, "Shuffled", rules);
    const stored = try library.playlists.trackIds(std.testing.allocator, playlist, .{ .now = 0, .seed = 1 });
    defer std.testing.allocator.free(stored);
    try std.testing.expect(!std.mem.eql(i64, first, stored));
    var page = try library.playlists.entries(std.testing.allocator, playlist, 10, 10, .{ .now = 0, .seed = 1 });
    defer page.deinit();
    for (page.items, stored[10..20]) |entry, id| try std.testing.expectEqual(id, entry.track.?.id);
}

test "an hour limit keeps the leading Tracks whose lengths fit in it" {
    var library = try openFeedbackLibrary("playlist-smart-hours");
    defer library.close();
    var title_buffer: [16]u8 = undefined;
    for (0..30) |index| _ = try addSmartTrack(&library, try std.fmt.bufPrint(&title_buffer, "Song {d:0>2}", .{index}), "Artist");
    try library.database.exec("UPDATE tracks SET duration_ms = 250000;");
    const rules =
        \\{"v":1,"rules":[],"sort":{"field":"title"},"limit_hours":1}
    ;
    var preview = try library.playlists.smartPreview(std.testing.allocator, rules, 0, .{ .now = 0, .seed = 0 });
    defer preview.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 14), preview.count);
    try std.testing.expectEqual(@as(u64, 14 * 250000), preview.duration_ms);
    try std.testing.expect(preview.duration_ms <= std.time.ms_per_hour);
    try std.testing.expectEqual(@as(usize, 0), preview.sample.len);

    const playlist = try library.playlists.createSmart(std.testing.allocator, "Hour", rules);
    const summary = try library.playlists.summary(std.testing.allocator, playlist, .{ .now = 0, .seed = 0 });
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 14), summary.entries);
    const ids = try library.playlists.trackIds(std.testing.allocator, playlist, .{ .now = 0, .seed = 0 });
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 14), ids.len);

    try library.database.exec("UPDATE tracks SET duration_ms = 3600001 WHERE title = 'Song 00';");
    try std.testing.expectEqual(@as(u64, 0), try library.playlists.smartCount(std.testing.allocator, rules, .{ .now = 0, .seed = 0 }));
}

test "an in_playlist rule matches a manual playlist's Tracks and refuses any other playlist" {
    var library = try openFeedbackLibrary("playlist-smart-membership");
    defer library.close();
    const northern = try addSmartTrack(&library, "Northern Sky", "Nick Drake");
    const pink = try addSmartTrack(&library, "Pink Moon", "Nick Drake");
    const sky = try addSmartTrack(&library, "Sky Blue", "Peter Gabriel");
    const manual = try library.playlists.create("Manual");
    _ = try library.playlists.insert(manual, &.{ sky, northern }, null);

    var rules_buffer: [160]u8 = undefined;
    const member = try std.fmt.bufPrint(&rules_buffer, "{{\"v\":1,\"rules\":[{{\"field\":\"in_playlist\",\"op\":\"is\",\"value\":{d}}}]}}", .{manual});
    const member_ids = try smartTrackIds(&library, member, 0);
    defer std.testing.allocator.free(member_ids);
    try std.testing.expectEqualSlices(i64, &.{ northern, sky }, member_ids);
    var other_buffer: [160]u8 = undefined;
    const not_member = try std.fmt.bufPrint(&other_buffer, "{{\"v\":1,\"rules\":[{{\"field\":\"in_playlist\",\"op\":\"is_not\",\"value\":{d}}}]}}", .{manual});
    const other_ids = try smartTrackIds(&library, not_member, 0);
    defer std.testing.allocator.free(other_ids);
    try std.testing.expectEqualSlices(i64, &.{pink}, other_ids);

    const smart = try library.playlists.createSmart(std.testing.allocator, "Members", member);
    var self_buffer: [160]u8 = undefined;
    const itself = try std.fmt.bufPrint(&self_buffer, "{{\"v\":1,\"rules\":[{{\"field\":\"in_playlist\",\"op\":\"is\",\"value\":{d}}}]}}", .{smart});
    try std.testing.expectError(error.InvalidRulePlaylist, library.playlists.setRules(std.testing.allocator, smart, itself));
    try std.testing.expectError(error.InvalidRulePlaylist, library.playlists.createSmart(std.testing.allocator, "Nested", itself));
    try std.testing.expectError(error.InvalidRulePlaylist, library.playlists.smartCount(
        std.testing.allocator,
        "{\"v\":1,\"rules\":[{\"field\":\"in_playlist\",\"op\":\"is\",\"value\":9999}]}",
        .{ .now = 0, .seed = 0 },
    ));

    try library.playlists.delete(manual);
    const ids = try library.playlists.trackIds(std.testing.allocator, smart, .{ .now = 0, .seed = 0 });
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 0), ids.len);
}

test "a playlist position sort lists Tracks in a manual playlist's order and the rest after them" {
    var library = try openFeedbackLibrary("playlist-smart-position");
    defer library.close();
    const northern = try addSmartTrack(&library, "Northern Sky", "Nick Drake");
    const pink = try addSmartTrack(&library, "Pink Moon", "Nick Drake");
    const sky = try addSmartTrack(&library, "Sky Blue", "Peter Gabriel");
    const manual = try library.playlists.create("Manual");
    _ = try library.playlists.insert(manual, &.{ sky, northern, sky }, null);

    var rules_buffer: [200]u8 = undefined;
    const members = try std.fmt.bufPrint(&rules_buffer, "{{\"v\":1,\"rules\":[{{\"field\":\"in_playlist\",\"op\":\"is\",\"value\":{d}}}],\"sort\":{{\"field\":\"playlist_position\",\"playlist\":{d}}}}}", .{ manual, manual });
    const member_ids = try smartTrackIds(&library, members, 0);
    defer std.testing.allocator.free(member_ids);
    try std.testing.expectEqualSlices(i64, &.{ sky, northern }, member_ids);

    var everything_buffer: [200]u8 = undefined;
    const everything = try std.fmt.bufPrint(&everything_buffer, "{{\"v\":1,\"rules\":[],\"sort\":{{\"field\":\"playlist_position\",\"playlist\":{d},\"descending\":true}}}}", .{manual});
    const all_ids = try smartTrackIds(&library, everything, 0);
    defer std.testing.allocator.free(all_ids);
    try std.testing.expectEqualSlices(i64, &.{ northern, sky, pink }, all_ids);

    var preview = try library.playlists.smartPreview(std.testing.allocator, members, 1, .{ .now = 0, .seed = 0 });
    defer preview.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), preview.count);
    try std.testing.expectEqual(sky, preview.sample[0].id);

    const smart = try library.playlists.createSmart(std.testing.allocator, "Ordered", members);
    var self_buffer: [160]u8 = undefined;
    const by_itself = try std.fmt.bufPrint(&self_buffer, "{{\"v\":1,\"rules\":[],\"sort\":{{\"field\":\"playlist_position\",\"playlist\":{d}}}}}", .{smart});
    try std.testing.expectError(error.InvalidRulePlaylist, library.playlists.setRules(std.testing.allocator, smart, by_itself));
    try std.testing.expectError(error.InvalidRulePlaylist, library.playlists.smartCount(std.testing.allocator, by_itself, .{ .now = 0, .seed = 0 }));
    const stored = try library.playlists.trackIds(std.testing.allocator, smart, .{ .now = 0, .seed = 0 });
    defer std.testing.allocator.free(stored);
    try std.testing.expectEqualSlices(i64, &.{ sky, northern }, stored);
}

test "a playlist's formats count each codec and the entries measured for their file's current bytes" {
    var library = try openFeedbackLibrary("playlist-formats");
    defer library.close();
    const first = try addSmartTrack(&library, "One", "Nick Drake");
    const second = try addSmartTrack(&library, "Two", "Nick Drake");
    const third = try addSmartTrack(&library, "Three", "Peter Gabriel");
    const fourth = try addSmartTrack(&library, "Four", "Kate Bush");
    try library.database.exec(
        \\INSERT INTO artists(name) SELECT DISTINCT artist FROM tracks;
        \\UPDATE tracks SET artist_id = (SELECT id FROM artists WHERE artists.name = tracks.artist);
        \\UPDATE files SET codec = 'flac', quick_hash = x'01' WHERE id IN (SELECT preferred_file_id FROM tracks WHERE title IN ('One', 'Two'));
        \\UPDATE files SET codec = 'alac', quick_hash = x'02' WHERE id = (SELECT preferred_file_id FROM tracks WHERE title = 'Three');
        \\INSERT INTO file_loudness(file_id, source_identity, integrated_lufs)
        \\    SELECT preferred_file_id, x'01', -14.0 FROM tracks WHERE title = 'One';
        \\INSERT INTO file_loudness(file_id, source_identity, integrated_lufs)
        \\    SELECT preferred_file_id, x'09', -14.0 FROM tracks WHERE title = 'Three';
    );
    const manual = try library.playlists.create("Manual");
    _ = try library.playlists.insert(manual, &.{ first, second, third, fourth, first }, null);

    const formats = try library.playlists.formats(std.testing.allocator, manual, .{ .now = 0, .seed = 0 });
    defer formats.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), formats.codecs.len);
    try std.testing.expectEqualStrings("flac", formats.codecs[0].codec);
    try std.testing.expectEqual(@as(u64, 3), formats.codecs[0].count);
    try std.testing.expectEqualStrings("alac", formats.codecs[1].codec);
    try std.testing.expectEqual(@as(u64, 1), formats.codecs[1].count);
    try std.testing.expectEqual(@as(u64, 2), formats.analyzed);
    try std.testing.expectEqual(@as(u64, 3), formats.unanalyzed);

    const summary = try library.playlists.summary(std.testing.allocator, manual, .{ .now = 0, .seed = 0 });
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 3), summary.artist_count);
    try std.testing.expect(summary.mixed_artists);

    const smart = try library.playlists.createSmart(
        std.testing.allocator,
        "Drake",
        "{\"v\":1,\"rules\":[{\"field\":\"artist\",\"op\":\"is\",\"value\":\"Nick Drake\"}]}",
    );
    const smart_formats = try library.playlists.formats(std.testing.allocator, smart, .{ .now = 0, .seed = 0 });
    defer smart_formats.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), smart_formats.codecs.len);
    try std.testing.expectEqual(@as(u64, 2), smart_formats.codecs[0].count);
    try std.testing.expectEqual(@as(u64, 1), smart_formats.analyzed);
    try std.testing.expectEqual(@as(u64, 1), smart_formats.unanalyzed);
    const smart_summary = try library.playlists.summary(std.testing.allocator, smart, .{ .now = 0, .seed = 0 });
    defer smart_summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), smart_summary.artist_count);
    try std.testing.expect(!smart_summary.mixed_artists);
}
test "a smart playlist lists one Track per matching recording in its rules' order up to its limit and refuses entry edits" {
    var library = try openFeedbackLibrary("playlist-smart");
    defer library.close();
    const northern = try addSmartTrack(&library, "Northern Sky", "Nick Drake");
    const pink = try addSmartTrack(&library, "Pink Moon", "Nick Drake");
    const sky = try addSmartTrack(&library, "Sky Blue", "Peter Gabriel");
    _ = try addSmartTrack(&library, "River Man", "Nick Drake");
    const duplicate = try addFeedbackTrack(&library, "Northern Sky", try testScalar(library.database, "SELECT recording_id FROM tracks WHERE title = 'Northern Sky';"), null);
    try std.testing.expect(duplicate > northern);
    try library.database.exec(
        \\INSERT INTO artists(name) SELECT DISTINCT artist FROM tracks;
        \\UPDATE tracks SET artist_id = (SELECT id FROM artists WHERE artists.name = tracks.artist);
    );
    const rules =
        \\{"v":1,"match":"any","rules":[{"field":"title","op":"contains","value":"SKY"},{"field":"title","op":"starts_with","value":"pink"}],
        \\"sort":{"field":"title","descending":true},"limit":2}
    ;
    const playlist = try library.playlists.createSmart(std.testing.allocator, "Skies", rules);

    var page = try library.playlists.entries(std.testing.allocator, playlist, repository.max_page, 0, .{ .now = 0, .seed = 0 });
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqual(sky, page.items[0].track.?.id);
    try std.testing.expectEqual(pink, page.items[1].track.?.id);
    try std.testing.expectEqual(@as(u32, 1), page.items[1].position);
    var second = try library.playlists.entries(std.testing.allocator, playlist, repository.max_page, 1, .{ .now = 0, .seed = 0 });
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.items.len);
    try std.testing.expectEqual(@as(u32, 1), second.items[0].position);

    const ids = try library.playlists.trackIds(std.testing.allocator, playlist, .{ .now = 0, .seed = 0 });
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(i64, &.{ sky, pink }, ids);
    try std.testing.expectEqual(@as(u64, 2), try library.playlists.smartCount(std.testing.allocator, rules, .{ .now = 0, .seed = 0 }));
    try std.testing.expectEqual(@as(u64, 2), try library.playlists.smartCount(
        std.testing.allocator,
        "{\"v\":1,\"rules\":[{\"field\":\"title\",\"op\":\"contains\",\"value\":\"sky\"}]}",
        .{ .now = 0, .seed = 0 },
    ));

    const summary = try library.playlists.summary(std.testing.allocator, playlist, .{ .now = 0, .seed = 0 });
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(repository.PlaylistKind.smart, summary.kind);
    try std.testing.expectEqual(@as(u32, 2), summary.entries);
    try std.testing.expectEqual(@as(u32, 2), summary.available);
    try std.testing.expect(summary.mixed_artists);

    const exported = try library.playlists.exportRows(std.testing.allocator, playlist, .{ .now = 0, .seed = 0 });
    defer exported.deinit();
    try std.testing.expectEqual(@as(usize, 0), exported.items.len);
    try std.testing.expectEqual(@as(u32, 2), exported.unavailable);

    try std.testing.expectError(error.PlaylistIsSmart, library.playlists.insert(playlist, &.{northern}, null));
    try std.testing.expectError(error.PlaylistIsSmart, library.playlists.remove(playlist, &.{0}));
    try std.testing.expectError(error.PlaylistIsSmart, library.playlists.move(playlist, 0, 1));
    const stored = (try library.playlists.rules(std.testing.allocator, playlist)).?;
    defer std.testing.allocator.free(stored);
    try std.testing.expectEqualStrings(rules, stored);

    const manual = try library.playlists.create("Manual");
    try std.testing.expect(try library.playlists.rules(std.testing.allocator, manual) == null);
    try std.testing.expectError(error.PlaylistIsManual, library.playlists.setRules(std.testing.allocator, manual, rules));
    try std.testing.expectError(error.UnknownRuleField, library.playlists.setRules(
        std.testing.allocator,
        playlist,
        "{\"v\":1,\"rules\":[{\"field\":\"path\",\"op\":\"is\",\"value\":\"x\"}]}",
    ));
    try std.testing.expectError(error.UnknownRuleField, library.playlists.createSmart(
        std.testing.allocator,
        "Bad",
        "{\"v\":1,\"rules\":[{\"field\":\"path\",\"op\":\"is\",\"value\":\"x\"}]}",
    ));
    try library.playlists.setRules(std.testing.allocator, playlist, "{\"v\":1,\"rules\":[{\"field\":\"artist\",\"op\":\"is\",\"value\":\"peter gabriel\"}]}");
    const now_ids = try library.playlists.trackIds(std.testing.allocator, playlist, .{ .now = 0, .seed = 0 });
    defer std.testing.allocator.free(now_ids);
    try std.testing.expectEqualSlices(i64, &.{sky}, now_ids);
}

test "a hostile smart playlist value is matched literally and never runs as SQL" {
    var library = try openFeedbackLibrary("playlist-smart-hostile");
    defer library.close();
    const hostile = try addSmartTrack(&library, "x'); DROP TABLE tracks; --", "A");
    const percent = try addSmartTrack(&library, "100%_done", "A");
    _ = try addSmartTrack(&library, "1000 done", "A");

    const is_hostile = try library.playlists.createSmart(
        std.testing.allocator,
        "Hostile",
        "{\"v\":1,\"rules\":[{\"field\":\"title\",\"op\":\"is\",\"value\":\"x'); DROP TABLE tracks; --\"}]}",
    );
    const ids = try library.playlists.trackIds(std.testing.allocator, is_hostile, .{ .now = 0, .seed = 0 });
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(i64, &.{hostile}, ids);

    const wildcard = try library.playlists.createSmart(
        std.testing.allocator,
        "Wildcard",
        "{\"v\":1,\"rules\":[{\"field\":\"title\",\"op\":\"contains\",\"value\":\"%_\"}]}",
    );
    const literal = try library.playlists.trackIds(std.testing.allocator, wildcard, .{ .now = 0, .seed = 0 });
    defer std.testing.allocator.free(literal);
    try std.testing.expectEqualSlices(i64, &.{percent}, literal);
    try std.testing.expectEqual(@as(i64, 3), try testScalar(library.database, "SELECT count(*) FROM tracks;"));
}

test "every rule field with every operator it accepts runs against the library" {
    var library = try openFeedbackLibrary("playlist-smart-fields");
    defer library.close();
    _ = try addSmartTrack(&library, "Northern Sky", "Nick Drake");
    const manual = try library.playlists.create("Manual");
    var manual_value_buffer: [32]u8 = undefined;
    const manual_value = try std.fmt.bufPrint(&manual_value_buffer, ",\"value\":{d}", .{manual});
    const smart_playlist = @import("../library/smart_playlist.zig");
    var checked: usize = 0;
    inline for (std.meta.fields(smart_playlist.Field)) |field_info| {
        const field: smart_playlist.Field = @enumFromInt(field_info.value);
        inline for (std.meta.fields(smart_playlist.Operator)) |operator_info| {
            const operator: smart_playlist.Operator = @enumFromInt(operator_info.value);
            if (operator.appliesTo(field.fieldType())) {
                const value: []const u8 = switch (operator) {
                    .is_set, .is_not_set => "",
                    .between => ",\"value\":[1,2]",
                    .in_last_days, .not_in_last_days => ",\"value\":30",
                    else => switch (field.fieldType()) {
                        .text => ",\"value\":\"sky\"",
                        .integer, .date => ",\"value\":1",
                        .boolean => ",\"value\":true",
                        .playlist => manual_value,
                    },
                };
                var buffer: [256]u8 = undefined;
                const rules = try std.fmt.bufPrint(
                    &buffer,
                    "{{\"v\":1,\"rules\":[{{\"field\":\"{s}\",\"op\":\"{s}\"{s}}}],\"sort\":{{\"field\":\"{s}\"}}}}",
                    .{ field_info.name, operator_info.name, value, if (field == .added_at) "added_at" else "title" },
                );
                _ = library.playlists.smartCount(std.testing.allocator, rules, .{ .now = 1_000_000, .seed = 0 }) catch |err| {
                    std.debug.print("{s}\n", .{rules});
                    return err;
                };
                checked += 1;
            }
        }
    }
    try std.testing.expect(checked > 100);
}

test "a front image in a Release's folder or a fetched cover gives its Tracks artwork in details and in a has_artwork rule" {
    var library = try openFeedbackLibrary("folder-cover-artwork");
    defer library.close();
    const covered = try addSmartTrack(&library, "Northern Sky", "Nick Drake");
    const bare = try addSmartTrack(&library, "Pink Moon", "Nick Drake");
    var sql: [192]u8 = undefined;
    try library.database.exec("INSERT INTO releases(id, title, release_key) VALUES (71, 'Covered', 'covered'), (72, 'Bare', 'bare');");
    for ([_]struct { i64, i64, []const u8 }{ .{ covered, 71, "Covered" }, .{ bare, 72, "Bare" } }) |row| {
        try library.database.exec(try std.fmt.bufPrintSentinel(&sql, "UPDATE tracks SET release_id = {d} WHERE id = {d};", .{ row[1], row[0] }, 0));
        try library.database.exec(try std.fmt.bufPrintSentinel(&sql,
            \\INSERT INTO locations(file_id, volume_id, uri, state)
            \\    SELECT preferred_file_id, 1, '/m/{s}/1.flac', 'present' FROM tracks WHERE id = {d};
        , .{ row[2], row[0] }, 0));
    }
    try library.database.exec(
        \\INSERT INTO folder_images(volume_id, uri, mime, role, size_bytes, modified_ns) VALUES
        \\    (1, '/m/Covered/cover.jpg', 'image/jpeg', 0, 10, 0), (1, '/m/Bare/back.jpg', 'image/jpeg', 1, 10, 0);
    );
    for ([_]i64{ 71, 72 }) |release_id| _ = try repository.refreshFolderCoverLocked(library.database, release_id);

    const with_artwork =
        \\{"v":1,"rules":[{"field":"has_artwork","op":"is","value":true}]}
    ;
    for ([_]bool{ false, true }) |fetched| {
        if (fetched) try library.database.exec(
            "INSERT INTO release_artwork(release_id, musicbrainz_release_id, image, mime, fetched_at) VALUES (72, 'mbid', x'01', 'image/jpeg', 1);",
        );
        for ([_]struct { i64, bool }{ .{ covered, true }, .{ bare, fetched } }) |row| {
            const facts = (try library.tracks.fileFacts(std.testing.allocator, row[0])).?;
            defer facts.deinit();
            try std.testing.expectEqual(row[1], facts.has_artwork);
        }
        const ids = try smartTrackIds(&library, with_artwork, 0);
        defer std.testing.allocator.free(ids);
        try std.testing.expectEqualSlices(i64, if (fetched) &.{ covered, bare } else &.{covered}, ids);
    }
}

test "an imported playlist is created by import, not by the user" {
    var library = try openFeedbackLibrary("playlist-imported");
    defer library.close();
    const recording = try addRecording(&library);
    const imported = try library.playlists.createWithRecordings(std.testing.allocator, "From file", &.{recording});
    const summary = try library.playlists.summary(std.testing.allocator, imported, .{ .now = 0, .seed = 0 });
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(repository.PlaylistCreator.imported, summary.creator);
}

test "a Track's lyrics row is replaced whole, is not stored for a gone Track, and goes with its Track" {
    var library = try openFeedbackLibrary("track-lyrics");
    defer library.close();
    const track = try addFeedbackTrack(&library, "Northern Sky", null, null);
    const first: [32]u8 = @splat(1);
    const second: [32]u8 = @splat(2);

    try std.testing.expect(try library.track_lyrics.get(std.testing.allocator, track) == null);
    try std.testing.expect(try library.track_lyrics.put(track, &first, .{ .lrclib_id = 7, .synced = "[00:01.00]a", .plain = "a" }, 100));
    {
        const stored = (try library.track_lyrics.get(std.testing.allocator, track)).?;
        defer stored.deinit();
        try std.testing.expectEqualSlices(u8, &first, &stored.query_digest);
        try std.testing.expectEqual(@as(?i64, 7), stored.record.lrclib_id);
        try std.testing.expectEqualStrings("[00:01.00]a", stored.record.synced.?);
        try std.testing.expectEqualStrings("a", stored.record.plain.?);
        try std.testing.expect(!stored.record.isMiss());
        try std.testing.expectEqual(@as(i64, 100), stored.fetched_at);
    }
    try std.testing.expect(try library.track_lyrics.put(track, &second, .{}, 200));
    {
        const stored = (try library.track_lyrics.get(std.testing.allocator, track)).?;
        defer stored.deinit();
        try std.testing.expectEqualSlices(u8, &second, &stored.query_digest);
        try std.testing.expect(stored.record.isMiss());
        try std.testing.expectEqual(@as(?i64, null), stored.record.lrclib_id);
        try std.testing.expectEqual(@as(i64, 200), stored.fetched_at);
    }

    try std.testing.expect(!try library.track_lyrics.put(track + 1000, &first, .{ .instrumental = true }, 300));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(library.database, "SELECT count(*) FROM track_lyrics;"));
    var sql: [64]u8 = undefined;
    try library.database.exec(try std.fmt.bufPrintSentinel(&sql, "DELETE FROM tracks WHERE id = {d};", .{track}, 0));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT count(*) FROM track_lyrics;"));
}
