const std = @import("std");
const migrations = @import("migrations.zig");
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
    database: sqlite.Database,
    write_lane: *repository.WriteLane,
    tracks: repository.TrackRepository,
    artists: repository.ArtistRepository,
    releases: repository.ReleaseRepository,
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
    provider_cache: repository.ProviderCacheRepository,
    scrobbles: repository.ScrobbleQueueRepository,
    identification_proposals: repository.IdentificationProposalRepository,

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
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8) !LibraryDatabase {
        const owned_path = try allocator.dupeSentinel(u8, path, 0);
        errdefer allocator.free(owned_path);
        const database = try sqlite.Database.open(path);
        errdefer database.close();
        const write_lane = try allocator.create(repository.WriteLane);
        errdefer allocator.destroy(write_lane);
        write_lane.* = .{ .io = io };
        try database.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;");
        try migrations.applyThrough(database, migrations.journal_ready_version);
        var journal: repository.MutationJournalRepository = .{
            .db = database,
            .write_lane = write_lane,
        };
        _ = try mutation_recovery.recoverPending(allocator, io, &journal);
        try migrations.apply(database);
        return .{
            .allocator = allocator,
            .path = owned_path,
            .database = database,
            .write_lane = write_lane,
            .tracks = .{ .db = database, .write_lane = write_lane },
            .artists = .{ .db = database, .write_lane = write_lane },
            .releases = .{ .db = database, .write_lane = write_lane },
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
            .provider_cache = .{ .db = database, .write_lane = write_lane },
            .scrobbles = .{ .db = database, .write_lane = write_lane },
            .identification_proposals = .{ .db = database, .write_lane = write_lane },
        };
    }

    pub fn close(self: *LibraryDatabase) void {
        self.database.close();
        self.allocator.destroy(self.write_lane);
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
        if (try self.rootVolume(path)) |existing| return .{
            .volume_id = existing.volume_id,
            .root_id = existing.root_id,
            .claimed_locations = try self.locations.claimLegacyLocations(
                null_volume,
                existing.volume_id,
                existing.root_id,
                path,
            ),
        };
        var provisional_buffer: [64]u8 = undefined;
        const provisional = try std.fmt.bufPrint(
            &provisional_buffer,
            "root:pending:{x}",
            .{std.hash.Wyhash.hash(0, path)},
        );
        const provisional_volume = try self.volumes.ensure(.{ .stable_key = provisional });
        const root_id = try self.library_roots.add(provisional_volume, path);
        var key_buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "root:{d}", .{root_id});
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

    /// Resolve the file a path names, creating `files` and `locations` rows for
    /// it when no scan has seen it yet.
    ///
    /// This is the identity cascade in its cheapest useful form: the same path
    /// on the same volume, then the same inode/size/mtime elsewhere on that
    /// volume, then the same quick hash anywhere. It is what lets
    /// `orca-cli analyze` cache a result against a file rather than a path.
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
        const size: i64 = @intCast(stat.size);
        const modified_ns: i64 = @intCast(stat.mtime.nanoseconds);
        const inode: i64 = @bitCast(@as(u64, stat.inode));

        const existing = (try self.files.resolveByUri(volume_id, path)) orelse
            (try self.files.resolveByIdentity(.{
                .volume_id = volume_id,
                .native_inode = inode,
                .size_bytes = size,
                .modified_ns = modified_ns,
            })) orelse
            try self.files.resolveByQuickHash(&digest);
        const file_id = existing orelse try self.files.create(.{
            .size_bytes = size,
            .quick_hash = &digest,
        });
        if (existing != null) try self.files.update(file_id, .{
            .size_bytes = size,
            .quick_hash = &digest,
        });
        const location_id = try self.locations.upsert(.{
            .file_id = file_id,
            .volume_id = volume_id,
            .uri = path,
            .native_inode = inode,
            .size_bytes = size,
            .modified_ns = modified_ns,
            .state = .present,
        });
        return .{ .file_id = file_id, .location_id = location_id, .volume_id = volume_id };
    }

    /// The volume every path with no better identity falls back to. It exists
    /// from migration 8 onward, and pre-identity rows already point at it.
    pub const null_volume: i64 = 1;

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

    var page = try first.tracks.search(std.testing.allocator, "Northern", 25, 0);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqualStrings("Northern Sky", page.items[0].title);
    try std.testing.expectEqual(@as(u64, 1), try first.tracks.count());
    try std.testing.expectEqual(@as(u64, 1), try second.tracks.count());
}

test "ten thousand ratings update in one transaction" {
    var library = try LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-batch?mode=memory&cache=shared",
    );
    defer library.close();

    var tracks: [10_000]repository.TrackInput = undefined;
    for (&tracks) |*track| track.* = .{ .title = "Batch track" };
    try library.tracks.upsertTracks(&tracks);

    var ids: [10_000]i64 = undefined;
    for (&ids, 1..) |*id, value| id.* = @intCast(value);
    try library.tracks.setRatings(&ids, 80);
    try std.testing.expectEqual(
        @as(u64, 10_000),
        try library.tracks.countWithRating(80),
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
    // The MusicBrainz release id is the projection's strongest grouping key and
    // used to be dropped at this boundary entirely.
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

    var page = try library.tracks.page(std.testing.allocator, 10, 0);
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
    var second = try library.tracks.page(std.testing.allocator, 10, 1);
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
    var page = try library.tracks.search(std.testing.allocator, "Bryter", 10, 0);
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
