const std = @import("std");
const builtin = @import("builtin");
const content_hash = @import("../storage/content_hash.zig");
const content_measurements = @import("content_measurements.zig");
const ContentMeasurements = content_measurements.ContentMeasurements;
const metadata = @import("../metadata/model.zig");
const migrations = @import("migrations.zig");
const JournalLock = @import("../metadata/journal_lock.zig").JournalLock;
const mutation_recovery = @import("../metadata/recovery.zig");
const platform = @import("../platform.zig");
const quick_hash = @import("../storage/quick_hash.zig");
const repository = @import("repository.zig");
const sqlite = @import("sqlite.zig");
const upgrade_copy = @import("upgrade_copy.zig");

/// How a Library should decide which volume a path lives on.
pub const VolumeOptions = struct {
    /// Bypass the platform adapter. Tests and callers that already know the
    /// volume use this; nothing else should.
    stable_key: ?[]const u8 = null,
    label: []const u8 = "",
    /// Where the platform adapter reads the host's volumes from.
    platform_options: platform.volume.Options = .{},
    /// Whether to consult the platform adapter at all. Off exercises the
    /// root-derived fallback on a host whose storage is perfectly
    /// identifiable.
    use_platform_adapter: bool = true,
};

pub const RootBinding = struct {
    volume_id: i64,
    root_id: i64,
    /// How many unverified locations under the root this call moved from the
    /// fallback volume onto the root's volume.
    claimed_locations: u64 = 0,
};

pub const FileBinding = struct {
    file_id: i64,
    location_id: i64,
    volume_id: i64,
    /// What the location recorded of the bytes it was resolved for.
    quick_hash: quick_hash.Digest,
    identity: repository.StorageIdentityKey,
};

/// Which connection a Library's dynamic database should use: the holder's own
/// writes are the only transaction it may read.
fn laneHeldByCurrentThread(context: *anyopaque) bool {
    const write_lane: *repository.WriteLane = @ptrCast(@alignCast(context));
    return write_lane.heldByCurrentThread();
}

pub fn migrate(allocator: std.mem.Allocator, io: std.Io, database: sqlite.Database, target: usize) !void {
    const copier: upgrade_copy.Copier = .{ .allocator = allocator, .io = io };
    const upgraded_from = try migrations.upgrade(database, target, copier) orelse return;
    if (upgraded_from == 0) return;
    const file = database.filename() orelse return;
    copier.removeOlder(file, upgraded_from) catch |err|
        std.log.warn("{s}: an older copy from before a schema upgrade could not be removed ({t})", .{ file, err });
}

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
    /// The writer/reader pair every repository routes between, selected by
    /// write-lane ownership. Held by pointer so the repositories can point at
    /// it without the Library struct becoming self-referential.
    connections: *sqlite.Connections,
    schema_guard: ?*sqlite.SchemaGuard,
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
    release_tracklists: repository.ReleaseTracklistRepository,
    release_track_pairings: repository.ReleaseTrackPairingRepository,
    reviewed_releases: repository.ReviewedReleaseRepository,
    settings: repository.LibrarySettingsRepository,
    player_state: repository.PlayerStateRepository,
    job_history: repository.JobHistoryRepository,
    stats: repository.LibraryStatsRepository,
    audio_features: repository.AudioFeatureRepository,
    audio_embeddings: repository.AudioEmbeddingRepository,
    fetched_cache: repository.FetchedCacheRepository,
    genres: repository.GenreRepository,
    search: repository.SearchRepository,
    track_lyrics: repository.TrackLyricsRepository,
    playlists: repository.PlaylistRepository,
    identification_proposals: repository.IdentificationProposalRepository,
    recording_verifications: repository.RecordingVerificationRepository,
    acoustid_submissions: repository.AcoustIdSubmissionRepository,

    /// Open a Library, creating its schema when the file is new and
    /// recovering any interrupted file mutation before the caller can see it.
    ///
    /// Recovery runs only while this open holds the journal lock. Without it
    /// another holder is mid-mutation, and its rows are not abandoned:
    /// recovery is deferred to a later open.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8) !LibraryDatabase {
        const owned_path = try allocator.dupeSentinel(u8, path, 0);
        errdefer allocator.free(owned_path);
        var database = try sqlite.Database.open(path);
        errdefer database.close();
        database.io = io;
        const write_lane = try allocator.create(repository.WriteLane);
        errdefer allocator.destroy(write_lane);
        write_lane.* = .{ .io = io };
        try requireWriteAheadLog(database);
        try database.exec("PRAGMA synchronous=NORMAL;");
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
        try migrate(allocator, io, database, migrations.current_version);
        const schema_guard: ?*sqlite.SchemaGuard = if (database.filename() != null) guard: {
            const guard = try allocator.create(sqlite.SchemaGuard);
            errdefer allocator.destroy(guard);
            try guard.install(database, path, migrations.current_version);
            break :guard guard;
        } else null;
        errdefer if (schema_guard) |guard| {
            guard.remove();
            allocator.destroy(guard);
        };
        database.guard = schema_guard;
        const reader = try sqlite.Database.openReadOnly(path);
        errdefer reader.close();
        const connections = try allocator.create(sqlite.Connections);
        errdefer allocator.destroy(connections);
        connections.* = .{
            .writer = database,
            .reader = reader,
            .context = @ptrCast(write_lane),
            .ownsLane = laneHeldByCurrentThread,
        };
        connections.reader.io = io;
        const dynamic = sqlite.Database{ .handle = database.handle, .connections = connections };
        try database.exec(
            \\CREATE TEMP TABLE IF NOT EXISTS swept_cover_releases(id INTEGER PRIMARY KEY);
            \\CREATE TEMP TABLE IF NOT EXISTS cleared_cover_releases(id INTEGER PRIMARY KEY);
            \\CREATE TEMP TABLE IF NOT EXISTS forgotten_files(id INTEGER PRIMARY KEY);
            \\CREATE TEMP TABLE IF NOT EXISTS forgotten_recordings(id INTEGER PRIMARY KEY);
        );
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
            } else {
                std.log.info("{s}: another process holds the mutation journal; recovery waits for the next open", .{path});
                recovery_deferred = true;
            }
        }
        return .{
            .allocator = allocator,
            .path = owned_path,
            .backup_directory = backup_directory,
            .journal_lock_path = journal_lock_path,
            .walk_lock_path = walk_lock_path,
            .recovery_deferred = .init(recovery_deferred),
            .database = database,
            .connections = connections,
            .schema_guard = schema_guard,
            .write_lane = write_lane,
            .tracks = .{ .db = dynamic, .write_lane = write_lane },
            .artists = .{ .db = dynamic, .write_lane = write_lane },
            .releases = .{ .db = dynamic, .write_lane = write_lane },
            .release_artwork = .{ .db = dynamic, .write_lane = write_lane },
            .recordings = .{ .db = dynamic, .write_lane = write_lane },
            .volumes = .{ .db = dynamic, .write_lane = write_lane },
            .library_roots = .{ .db = dynamic, .write_lane = write_lane },
            .scan_runs = .{ .db = dynamic, .write_lane = write_lane },
            .files = .{ .db = dynamic, .write_lane = write_lane },
            .locations = .{ .db = dynamic, .write_lane = write_lane },
            .observed_tags = .{ .db = dynamic, .write_lane = write_lane },
            .orca_metadata = .{ .db = dynamic, .write_lane = write_lane },
            .mutation_journal = .{ .db = dynamic, .write_lane = write_lane },
            .analysis_cache = .{ .db = dynamic, .write_lane = write_lane },
            .health_issues = .{ .db = dynamic, .write_lane = write_lane },
            .duplicate_groups = .{ .db = dynamic, .write_lane = write_lane },
            .provider_cache = .{ .db = dynamic, .write_lane = write_lane },
            .provider_state = .{ .db = dynamic, .write_lane = write_lane },
            .scrobbles = .{ .db = dynamic, .write_lane = write_lane },
            .listens = .{ .db = dynamic, .write_lane = write_lane },
            .feedback = .{ .db = dynamic, .write_lane = write_lane },
            .ratings = .{ .db = dynamic, .write_lane = write_lane },
            .release_loves = .{ .db = dynamic, .write_lane = write_lane },
            .artist_loves = .{ .db = dynamic, .write_lane = write_lane },
            .artist_info = .{ .db = dynamic, .write_lane = write_lane },
            .release_info = .{ .db = dynamic, .write_lane = write_lane },
            .release_tracklists = .{ .db = dynamic, .write_lane = write_lane },
            .release_track_pairings = .{ .db = dynamic, .write_lane = write_lane },
            .reviewed_releases = .{ .db = dynamic, .write_lane = write_lane },
            .settings = .{ .db = dynamic, .write_lane = write_lane },
            .player_state = .{ .db = dynamic, .write_lane = write_lane },
            .job_history = .{ .db = dynamic, .write_lane = write_lane },
            .stats = .{ .db = dynamic },
            .audio_features = .{ .db = dynamic },
            .audio_embeddings = .{ .db = dynamic },
            .fetched_cache = .{ .db = dynamic, .write_lane = write_lane },
            .genres = .{ .db = dynamic, .write_lane = write_lane },
            .search = .{ .db = dynamic },
            .track_lyrics = .{ .db = dynamic, .write_lane = write_lane },
            .playlists = .{ .db = dynamic, .write_lane = write_lane },
            .identification_proposals = .{ .db = dynamic, .write_lane = write_lane },
            .recording_verifications = .{ .db = dynamic, .write_lane = write_lane },
            .acoustid_submissions = .{ .db = dynamic, .write_lane = write_lane },
        };
    }

    fn requireWriteAheadLog(database: sqlite.Database) !void {
        var statement = try database.prepare("PRAGMA journal_mode=WAL;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        const mode = statement.columnText(0);
        const file = database.filename() orelse return;
        if (std.ascii.eqlIgnoreCase(mode, "wal")) return;
        std.log.err("{s}: journal mode is {s}, expected wal; the Library cannot be opened", .{ file, mode });
        return error.OpenFailed;
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
        self.connections.reader.close();
        self.allocator.destroy(self.connections);
        if (self.schema_guard) |guard| {
            guard.remove();
            self.allocator.destroy(guard);
        }
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
        var reader = try sqlite.Database.openReadOnly(self.path);
        reader.io = self.database.io;
        return reader;
    }

    /// The handle whose use the write lane selects: the writer for a thread
    /// that holds the lane, the reader for every other thread. Raw-SQL reads
    /// that may run either way (Home, Daily Mixes, the metadata-issue surface)
    /// use this so a lane-less read sees committed rows; open-time setup and
    /// flows that know they hold the lane keep using `database` directly.
    pub fn queryDatabase(self: *const LibraryDatabase) sqlite.Database {
        return .{ .handle = self.database.handle, .connections = self.connections };
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
            options.platform_options,
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
    /// When the platform can name the volume — a filesystem UUID, or the
    /// identifier in a marker at the mount root — the root is bound to that
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
        if (!std.fs.path.isAbsolute(path)) return error.InvalidLibraryRoot;
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
        if (!std.fs.path.isAbsolute(path)) return error.InvalidLibraryRoot;
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
            platform.volume.stableKey(self.allocator, io, path, options.platform_options) catch null
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
    /// rather than a path. A path whose bytes are not proven to equal those of
    /// a file still present elsewhere becomes a file of its own, as a scan
    /// would make it.
    ///
    /// No tags are read here, so an existing location keeps the identity its
    /// scan recorded and a new one is under no root: either way the next scan
    /// of its root re-observes the path instead of passing it as unchanged.
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
        const question = try self.files.contentQuestion(path, identity, &digest);
        if (question != .none) {
            own = try content_measurements.hashHeld(io, file, identity);
            try measurements.measureQuestion(self.allocator, io, &self.files, question, path, identity, &digest);
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
                try self.files.updateBytesLocked(id, upsert);
                if (own_digest == null) try self.files.forgetUnheldContentHashLocked(id, identity);
                break :same id;
            },
            .diverged => |shared| try self.files.forkLocked(shared, path, upsert),
        };
        const location_id = try self.locations.repointLocked(volume_id, path, file_id) orelse
            try self.locations.upsertLocked(.{
                .file_id = file_id,
                .volume_id = volume_id,
                .uri = path,
                .native_inode = identity.native_inode,
                .size_bytes = identity.size_bytes,
                .modified_ns = identity.modified_ns,
                .state = .present,
            });
        try self.database.exec("COMMIT;");
        return .{
            .file_id = file_id,
            .location_id = location_id,
            .volume_id = volume_id,
            .quick_hash = digest,
            .identity = identity,
        };
    }

    /// Records `digest`, read whole from `binding`'s path while it had
    /// `read`, as the content hash of its file, and reports whether the file
    /// records it now. False when the bytes read are not the ones `binding`
    /// was resolved for, or a scan has recorded others there since.
    pub fn adoptContentHash(
        self: *LibraryDatabase,
        binding: FileBinding,
        digest: *const content_hash.Digest,
        read: repository.StorageIdentityKey,
    ) !bool {
        if (read.volume_id != binding.volume_id) return false;
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.files.adoptContentHashLocked(binding.file_id, digest, &binding.quick_hash, binding.location_id, read);
    }

    /// The volume every path with no better identity falls back to. Every
    /// Library is created with it.
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

comptime {
    _ = @import("library_tests.zig");
}
