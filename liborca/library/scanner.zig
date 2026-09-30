const std = @import("std");
const codec = @import("../codec/root.zig");
const database = @import("../database/root.zig");
const mutation_executor = @import("../metadata/executor.zig");
const storage = @import("../storage/root.zig");
const projection = @import("projection.zig");
const tag_reader = @import("tag_reader.zig");

pub const CancellationToken = struct {
    requested: std.atomic.Value(bool) = .init(false),

    pub fn cancel(self: *CancellationToken) void {
        self.requested.store(true, .release);
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.requested.load(.acquire);
    }
};

pub const Result = struct {
    files_seen: u64 = 0,
    changed: u64 = 0,
    unchanged: u64 = 0,
    unsupported: u64 = 0,
    errors: u64 = 0,
    batches_committed: u64 = 0,
    cancelled: bool = false,
    /// What the projection made of what this scan observed. Zero on a scan
    /// that changed nothing, because nothing then needs reprojecting.
    projection: projection.Result = .{},
};

/// One entry the scan decided to write, held until its batch commits.
const PendingEntry = struct {
    path: []u8,
    audio_format: storage.AudioFormat,
    identity: database.StorageIdentityKey,
    quick_hash: storage.QuickHash,
    properties: codec.registry.Properties,
    tags: ?tag_reader.Tags,

    fn deinit(self: PendingEntry, allocator: std.mem.Allocator) void {
        if (self.tags) |tags| tags.deinit();
        allocator.free(self.path);
    }
};

/// Walks a root and records what the filesystem currently says.
///
/// The scanner observes: it writes `files`, `locations` and
/// `observed_file_tags` and nothing else. Turning observations into artists,
/// releases and tracks is the projection's job, and Track metadata is never
/// written from here.
pub const Scanner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    files: *database.FileRepository,
    locations: *database.LocationRepository,
    observed_tags: *database.ObservedTagsRepository,
    write_lane: *database.repository.WriteLane,
    database_handle: database.sqlite.Database,
    /// The volume the root lives on, resolved by the platform adapter before
    /// the scan starts — never `st_dev`, which does not survive a remount.
    volume_id: i64 = 1,
    root_id: ?i64 = null,
    /// Stamped onto every location this run reaches, so a completed run can
    /// name the ones it did not.
    generation: i64 = 0,
    cancellation: ?*const CancellationToken = null,
    /// Files walked so far, published for a host that is showing progress. A
    /// scan has no honest denominator until the walk finishes, so this is a
    /// count and never a fraction. Optional: nothing here depends on it.
    progress: ?*std.atomic.Value(u64) = null,
    batch_size: usize = 256,
    /// Decoders used to read each changed file's declared audio properties.
    /// Injectable so a test can narrow the set; absent, the builtins are used.
    codecs: ?*const codec.CodecRegistry = null,
    /// Where observations become a browsable library.
    ///
    /// The scanner still writes only files, locations and observed tags; it
    /// hands the projection the file ids its batch changed and the projection
    /// decides, from `EffectiveMetadata`, what Tracks those imply. Absent, a
    /// scan simply observes and `tracks` is refreshed by a later standalone
    /// reprojection.
    projection: ?*projection.Projection = null,
    /// File ids the last batch committed, held until the projection has
    /// consumed them. Not part of the scan's observation contract.
    projected: std.ArrayList(i64) = .empty,
    /// Locations this run skipped as unchanged, awaiting their generation
    /// stamp. Bounded like a write batch: seeing a file and recording that we
    /// saw it must not be separated by an unbounded amount of work.
    seen: std.ArrayList(i64) = .empty,

    pub fn deinit(self: *Scanner) void {
        self.seen.deinit(self.allocator);
        self.projected.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn scan(self: *Scanner, root_path: []const u8) !Result {
        if (self.batch_size == 0) return error.InvalidBatchSize;
        if (self.cancellation) |token| {
            if (token.isCancelled()) return .{ .cancelled = true };
        }
        const root = try std.Io.Dir.cwd().openDir(self.io, root_path, .{ .iterate = true });
        defer root.close(self.io);
        var walker = try root.walk(self.allocator);
        defer walker.deinit();

        var builtin_codecs = codec.CodecRegistry.builtins();
        const codecs = self.codecs orelse &builtin_codecs;

        var pending: std.ArrayList(PendingEntry) = .empty;
        defer {
            for (pending.items) |entry| entry.deinit(self.allocator);
            pending.deinit(self.allocator);
        }
        var result: Result = .{};

        while (try walker.next(self.io)) |entry| {
            if (self.cancellation) |token| if (token.isCancelled()) {
                result.cancelled = true;
                break;
            };
            if (entry.kind != .file) continue;
            if (mutation_executor.isOrcaTemporaryName(entry.basename)) continue;
            result.files_seen += 1;
            if (self.progress) |counter| counter.store(result.files_seen, .release);

            const path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ root_path, entry.path },
            );
            try self.examine(path, codecs, &pending, &result, .skip_unchanged);
        }
        if (pending.items.len > 0) {
            try self.flush(&pending);
            result.batches_committed += 1;
        }
        try self.flushSeen();
        try self.project(&result);
        return result;
    }

    const Unchanged = enum { skip_unchanged, observe_always };

    /// Observes one file: identity, container, tags and declared properties,
    /// queued for the next committed batch. Takes ownership of `path`.
    fn examine(
        self: *Scanner,
        path: []u8,
        codecs: *const codec.CodecRegistry,
        pending: *std.ArrayList(PendingEntry),
        result: *Result,
        unchanged_policy: Unchanged,
    ) !void {
        var owned_path = true;
        defer if (owned_path) self.allocator.free(path);
        var local = storage.LocalFileSource.open(self.io, path) catch {
            result.errors += 1;
            return;
        };
        defer local.close();
        const storage_identity = local.readable().identity();
        const identity = database.StorageIdentityKey{
            .volume_id = self.volume_id,
            .native_inode = std.math.cast(i64, storage_identity.inode) orelse {
                result.errors += 1;
                return;
            },
            .size_bytes = std.math.cast(i64, storage_identity.size) orelse {
                result.errors += 1;
                return;
            },
            .modified_ns = std.math.cast(i64, storage_identity.modified_ns) orelse {
                result.errors += 1;
                return;
            },
        };
        const unchanged = if (unchanged_policy == .skip_unchanged)
            try self.locations.unchangedLocationId(self.volume_id, path, identity)
        else
            null;
        if (unchanged) |location_id| {
            // Skipping the work is not the same as not having seen it. The
            // sweep marks anything below this run's generation `missing`,
            // so an unstamped skip would report every unchanged file as
            // absent on the second scan of an untouched library.
            try self.seen.append(self.allocator, location_id);
            if (self.seen.items.len >= self.batch_size) try self.flushSeen();
            result.unchanged += 1;
            return;
        }
        const detection = (try storage.format.detect(local.readable())) orelse {
            result.unsupported += 1;
            return;
        };
        const audio_format = detection.format;
        // A tag reader is defined over the container it is handed, so an
        // ID3v2 tag in front of a FLAC stream has to be stepped over before
        // asking for Vorbis comments, or the file is filed with no artist
        // and no album.
        //
        // `codecs.probe` needs no such help: the registry resolves the
        // prefix itself for every decoder it opens.
        var tag_view: storage.OffsetSource = .{
            .inner = local.readable(),
            .offset = detection.payload_offset,
        };
        const tag_source = if (detection.payload_offset == 0)
            local.readable()
        else
            tag_view.readable();
        // Unreadable tags leave the file observed but untagged: a corrupt
        // tag is not a reason to drop a playable file from the library.
        const tags = tag_reader.read(
            self.allocator,
            audio_format,
            tag_source,
        ) catch null;
        errdefer if (tags) |owned| owned.deinit();
        // Only changed bytes are probed: the unchanged fast path above is
        // what keeps a rescan of a large library nearly free, and opening a
        // decoder there would throw that away. A file that will not open is
        // recorded with no properties rather than failing the scan —
        // truncated and malformed audio is normal in a real library.
        const properties = codecs.probe(
            self.allocator,
            audio_format,
            local.readable(),
        ) catch codec.registry.Properties{};
        try pending.append(self.allocator, .{
            .path = path,
            .audio_format = audio_format,
            .identity = identity,
            .quick_hash = try storage.quick_hash.fromSource(local.readable()),
            .properties = properties,
            .tags = tags,
        });
        owned_path = false;
        result.changed += 1;
        if (pending.items.len >= self.batch_size) {
            try self.flush(pending);
            result.batches_committed += 1;
            try self.project(result);
        }
    }

    /// Re-observes specific files of this scanner's root, as a scan would,
    /// and projects them. For files Orca itself just rewrote: their bytes are
    /// known to have changed, so the unchanged fast path is not consulted.
    pub fn observeFiles(self: *Scanner, paths: []const []const u8) !Result {
        var builtin_codecs = codec.CodecRegistry.builtins();
        const codecs = self.codecs orelse &builtin_codecs;
        var pending: std.ArrayList(PendingEntry) = .empty;
        defer {
            for (pending.items) |entry| entry.deinit(self.allocator);
            pending.deinit(self.allocator);
        }
        var result: Result = .{};
        for (paths) |path| {
            result.files_seen += 1;
            try self.examine(try self.allocator.dupe(u8, path), codecs, &pending, &result, .observe_always);
        }
        if (pending.items.len > 0) {
            try self.flush(&pending);
            result.batches_committed += 1;
        }
        try self.project(&result);
        return result;
    }

    /// Stamp the run's generation onto Locations it skipped as unchanged.
    fn flushSeen(self: *Scanner) !void {
        if (self.seen.items.len == 0) return;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.locations.markSeenLocked(self.seen.items, self.generation);
        self.seen.clearRetainingCapacity();
    }

    /// Reproject exactly what the last batches changed.
    ///
    /// It runs outside the batch transaction and after the write lane is
    /// released, because the projection takes both itself, and it is scoped to
    /// the changed files so a rescan that found nothing new does no work at
    /// all rather than rebuilding the whole library.
    fn project(self: *Scanner, result: *Result) !void {
        const target = self.projection orelse return;
        if (self.projected.items.len == 0) return;
        const batch = try target.run(.{ .files = self.projected.items });
        self.projected.clearRetainingCapacity();
        result.projection.folders_visited += batch.folders_visited;
        result.projection.groups_projected += batch.groups_projected;
        result.projection.files_projected += batch.files_projected;
        result.projection.tracks_written += batch.tracks_written;
        result.projection.releases_written += batch.releases_written;
        result.projection.recordings_created += batch.recordings_created;
        result.projection.compilations += batch.compilations;
        result.projection.filename_titles += batch.filename_titles;
        result.projection.synthetic_positions += batch.synthetic_positions;
        result.projection.displaced_positions += batch.displaced_positions;
    }

    /// One bounded commit per batch, resolving each entry's file identity
    /// inside the same transaction that records it.
    fn flush(self: *Scanner, pending: *std.ArrayList(PendingEntry)) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.database_handle.exec("BEGIN IMMEDIATE;");
        errdefer self.database_handle.exec("ROLLBACK;") catch {};
        for (pending.items) |entry| {
            const upsert = database.FileUpsert{
                .audio_format = @intFromEnum(entry.audio_format),
                // Empty only for a file that sniffed as audio and then refused
                // to open: the container is known, the encoding inside it is
                // not, and an invented identifier would be worse than none.
                .codec = entry.properties.codec orelse "",
                .size_bytes = entry.identity.size_bytes,
                .sample_rate = optionalCount(entry.properties.sample_rate),
                .bit_depth = optionalCount(entry.properties.bit_depth),
                .channels = optionalCount(entry.properties.channels),
                .duration_ms = optionalCount(entry.properties.duration_ms),
                .quick_hash = &entry.quick_hash,
            };
            const existing = (try self.files.resolveByUri(self.volume_id, entry.path)) orelse
                (try self.files.resolveByIdentity(entry.identity)) orelse
                try self.files.resolveByQuickHash(&entry.quick_hash);
            const file_id = if (existing) |id| resolved: {
                try self.files.updateLocked(id, upsert);
                break :resolved id;
            } else try self.files.createLocked(upsert);
            _ = try self.locations.upsertLocked(.{
                .file_id = file_id,
                .volume_id = self.volume_id,
                .root_id = self.root_id,
                .uri = entry.path,
                .native_inode = entry.identity.native_inode,
                .size_bytes = entry.identity.size_bytes,
                .modified_ns = entry.identity.modified_ns,
                .state = .present,
                .last_seen_generation = self.generation,
            });
            if (entry.tags) |tags| try self.observed_tags.upsertBatchLocked(&.{.{
                .file_id = file_id,
                .values = tags.values,
            }});
            if (self.projection != null) try self.projected.append(self.allocator, file_id);
        }
        try self.database_handle.exec("COMMIT;");
        for (pending.items) |entry| entry.deinit(self.allocator);
        pending.clearRetainingCapacity();
    }
};

const optionalCount = database.columns.optionalCount;

test "scanner batches audio and skips unchanged files on restart" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "first.wav",
        .data = "RIFFxxxxWAVEfmt ",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "second.flac",
        .data = "fLaCgenerated",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "notes.txt",
        .data = "not audio",
    });
    var mp3: [256]u8 = @splat(0);
    @memcpy(mp3[0..3], "ID3");
    @memcpy(mp3[128..131], "TAG");
    @memcpy(mp3[131..145], "Observed title");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "tagged.mp3",
        .data = &mp3,
    });
    const root_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(root_path);

    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-scanner-test?mode=memory&cache=shared",
    );
    defer library.close();
    var scanner = Scanner{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .files = &library.files,
        .locations = &library.locations,
        .observed_tags = &library.observed_tags,
        .write_lane = library.write_lane,
        .database_handle = library.database,
        .batch_size = 1,
    };
    defer scanner.deinit();

    const first = try scanner.scan(root_path);
    try std.testing.expectEqual(@as(u64, 3), first.changed);
    try std.testing.expectEqual(@as(u64, 1), first.unsupported);
    try std.testing.expectEqual(@as(u64, 3), first.batches_committed);
    const second = try scanner.scan(root_path);
    try std.testing.expectEqual(@as(u64, 0), second.changed);
    try std.testing.expectEqual(@as(u64, 3), second.unchanged);
    try std.testing.expectEqual(@as(u64, 3), try library.files.count());
    const mp3_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/tagged.mp3",
        .{root_path},
    );
    defer std.testing.allocator.free(mp3_path);
    const file_id = (try library.files.resolveByUri(
        database.LibraryDatabase.null_volume,
        mp3_path,
    )).?;
    const observed = (try library.observed_tags.get(std.testing.allocator, file_id)).?;
    defer observed.deinit();
    try std.testing.expectEqualStrings("Observed title", observed.values.title.?);
}

test "a scan projects only the batches it changed and reprojects nothing on a rescan" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "one.flac",
        .data = "fLaCgenerated one",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "two.flac",
        .data = "fLaCgenerated two",
    });
    const root_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(root_path);

    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-scanner-projection?mode=memory&cache=shared",
    );
    defer library.close();
    var target: projection.Projection = .{
        .allocator = std.testing.allocator,
        .library = &library,
    };
    var scanner = Scanner{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .files = &library.files,
        .locations = &library.locations,
        .observed_tags = &library.observed_tags,
        .write_lane = library.write_lane,
        .database_handle = library.database,
        .projection = &target,
    };
    defer scanner.deinit();

    // These fixtures carry no tags at all, so the projection has only the
    // filesystem to work from — and must still produce a browsable Track for
    // every file rather than nothing. The counters are per batch and a folder
    // straddling two batches is resolved in both, so they are read here at the
    // default batch size where the folder lands in one.
    const first = try scanner.scan(root_path);
    try std.testing.expectEqual(@as(u64, 2), first.changed);
    try std.testing.expectEqual(@as(u64, 2), first.projection.tracks_written);
    try std.testing.expectEqual(@as(u64, 2), first.projection.filename_titles);
    try std.testing.expectEqual(@as(u64, 2), try library.tracks.count());

    const second = try scanner.scan(root_path);
    try std.testing.expectEqual(@as(u64, 0), second.changed);
    try std.testing.expectEqual(@as(u64, 0), second.projection.folders_visited);
    try std.testing.expectEqual(@as(u64, 0), second.projection.tracks_written);
    try std.testing.expectEqual(@as(u64, 2), try library.tracks.count());
}

test "a scan never ingests the temporaries and backups a tag write leaves beside the music" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for ([_][]const u8{
        "one.flac",
        ".one.flac.orca-stage-7-0",
        ".one.flac.orca-restore-7-0",
        "one.flac.orca-stage-3-0",
        "one.flac.orca-backup-3-0",
        "one.flac.orca-stage-3-0.recovery-displaced",
    }) |name| try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = name,
        .data = "fLaCgenerated one",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".hidden.flac",
        .data = "fLaCgenerated hidden",
    });
    const root_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(root_path);
    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-scanner-temporaries?mode=memory&cache=shared",
    );
    defer library.close();
    var scanner = Scanner{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .files = &library.files,
        .locations = &library.locations,
        .observed_tags = &library.observed_tags,
        .write_lane = library.write_lane,
        .database_handle = library.database,
    };
    defer scanner.deinit();

    const result = try scanner.scan(root_path);
    try std.testing.expectEqual(@as(u64, 2), result.files_seen);
    try std.testing.expectEqual(@as(u64, 2), try library.files.count());
}

test "cancelled scans stop before filesystem work" {
    var token: CancellationToken = .{};
    token.cancel();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(root_path);
    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-cancelled-scanner?mode=memory&cache=shared",
    );
    defer library.close();
    var scanner = Scanner{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .files = &library.files,
        .locations = &library.locations,
        .observed_tags = &library.observed_tags,
        .write_lane = library.write_lane,
        .database_handle = library.database,
        .cancellation = &token,
    };
    defer scanner.deinit();
    const result = try scanner.scan(root_path);
    try std.testing.expect(result.cancelled);
}

test "a scan after migration claims the files it inherited instead of re-importing them" {
    try expectMigratedFilesClaimed(.{});
}

test "a migrated root on storage Orca cannot name moves off the legacy volume with its files" {
    try expectMigratedFilesClaimed(.{ .use_platform_adapter = false });
}

fn expectMigratedFilesClaimed(volume_options: database.VolumeOptions) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "first.flac",
        .data = "fLaCgenerated first",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "second.flac",
        .data = "fLaCgenerated second",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "third.wav",
        .data = "RIFFxxxxWAVEfmt ",
    });
    const root_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(root_path);
    // The database lives outside the scanned root so the walk sees only music.
    var database_directory = std.testing.tmpDir(.{});
    defer database_directory.cleanup();
    const database_path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/library.db",
        .{database_directory.sub_path},
        0,
    );
    defer std.testing.allocator.free(database_path);
    const tracked = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/first.flac",
        .{root_path},
    );
    defer std.testing.allocator.free(tracked);

    // A version-7 library: observations keyed by path, with user state hanging
    // off those paths, and no `library_roots` row.
    {
        const raw = try database.sqlite.Database.open(database_path);
        defer raw.close();
        try database.migrations.applyThrough(raw, 7);
        var insert = try raw.prepare(
            \\INSERT INTO observed_files(path, inode, size_bytes, modified_ns, audio_format)
            \\VALUES (?1, 1, 19, 5, 1);
        );
        defer insert.deinit();
        for ([_][]const u8{ "first.flac", "second.flac", "third.wav" }) |name| {
            const path = try std.fmt.allocPrint(
                std.testing.allocator,
                "{s}/{s}",
                .{ root_path, name },
            );
            defer std.testing.allocator.free(path);
            try insert.bindText(1, path);
            try std.testing.expectEqual(database.sqlite.Step.done, try insert.step());
            try insert.reset();
        }
        var metadata = try raw.prepare(
            \\INSERT INTO orca_metadata_values(path, field, value, provenance, locked)
            \\VALUES (?1, 0, 'Curated title', 1, 1);
        );
        defer metadata.deinit();
        try metadata.bindText(1, tracked);
        try std.testing.expectEqual(database.sqlite.Step.done, try metadata.step());
        var health = try raw.prepare(
            \\INSERT INTO library_health_issues(path, kind, severity, details)
            \\VALUES (?1, 5, 1, 'clipped');
        );
        defer health.deinit();
        try health.bindText(1, tracked);
        try std.testing.expectEqual(database.sqlite.Step.done, try health.step());
    }

    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        database_path,
    );
    defer library.close();
    try std.testing.expectEqual(@as(u64, 3), try library.files.count());
    const migrated_file_id = (try library.files.resolveByUri(
        database.LibraryDatabase.null_volume,
        tracked,
    )).?;

    const binding = try library.ensureRoot(std.testing.io, root_path, volume_options);
    try std.testing.expect(binding.volume_id != database.LibraryDatabase.null_volume);
    try std.testing.expectEqual(@as(u64, 3), binding.claimed_locations);

    const run = try library.scan_runs.begin(binding.root_id);
    var scanner = Scanner{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .files = &library.files,
        .locations = &library.locations,
        .observed_tags = &library.observed_tags,
        .write_lane = library.write_lane,
        .database_handle = library.database,
        .volume_id = binding.volume_id,
        .root_id = binding.root_id,
        .generation = run.generation,
    };
    defer scanner.deinit();
    const result = try scanner.scan(root_path);
    try std.testing.expectEqual(@as(u64, 3), result.files_seen);
    try std.testing.expectEqual(@as(u64, 3), result.changed);
    _ = try library.files.markMissingBelowGeneration(binding.root_id, run.generation);

    // Nothing was re-imported: the same files, the same locations, the same ids.
    try std.testing.expectEqual(@as(u64, 3), try library.files.count());
    try std.testing.expectEqual(@as(u64, 3), try library.locations.count());
    try std.testing.expectEqual(
        @as(?i64, migrated_file_id),
        try library.files.resolveByUri(binding.volume_id, tracked),
    );
    try std.testing.expect(
        (try library.files.resolveByUri(database.LibraryDatabase.null_volume, tracked)) == null,
    );

    // And the user state migrated onto that file is still on the file the user
    // is now browsing, rather than stranded on an orphaned duplicate.
    const curated = (try library.orca_metadata.get(
        std.testing.allocator,
        migrated_file_id,
        .title,
    )).?;
    defer curated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Curated title", curated.text);
    try std.testing.expect(curated.locked);
    try std.testing.expectEqual(@as(u64, 1), try library.health_issues.count());
    var issues = try library.health_issues.page(std.testing.allocator, 10, 0);
    defer issues.deinit();
    try std.testing.expectEqual(migrated_file_id, issues.items[0].file_id);
    try std.testing.expectEqualStrings(tracked, issues.items[0].path);

    // Claimed locations are verified by the scan, not left unverified forever.
    const location_id = (try library.locations.find(binding.volume_id, tracked)).?;
    try std.testing.expectEqual(
        database.LocationState.present,
        try library.locations.stateOf(location_id),
    );
    try std.testing.expectEqual(
        @as(i64, 0),
        try countUnverified(library.database),
    );

    // A second scan now takes the unchanged fast path for every entry.
    const second_run = try library.scan_runs.begin(binding.root_id);
    scanner.generation = second_run.generation;
    const second = try scanner.scan(root_path);
    try std.testing.expectEqual(@as(u64, 0), second.changed);
    try std.testing.expectEqual(@as(u64, 3), second.unchanged);
    try std.testing.expectEqual(@as(u64, 3), try library.files.count());
}

fn countUnverified(db: database.sqlite.Database) !i64 {
    var statement = try db.prepare("SELECT count(*) FROM locations WHERE state='unverified';");
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return statement.columnInt64(0);
}

test "a scan records the audio properties of every file whose bytes changed" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for ([_][]const u8{
        "tagged-reference.flac",
        "vbr-xing-reference.mp3",
        "truncated-reference.mp3",
    }) |name| try copyFixture(temporary.dir, name);
    // Malformed audio is normal in a real library: this one sniffs as FLAC and
    // then refuses to open, and the scan must record it and keep going.
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "broken.flac",
        .data = "fLaC but not a stream",
    });
    const root_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(root_path);

    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-scanner-properties?mode=memory&cache=shared",
    );
    defer library.close();
    var scanner = Scanner{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .files = &library.files,
        .locations = &library.locations,
        .observed_tags = &library.observed_tags,
        .write_lane = library.write_lane,
        .database_handle = library.database,
    };
    defer scanner.deinit();

    const first = try scanner.scan(root_path);
    try std.testing.expectEqual(@as(u64, 4), first.changed);
    try std.testing.expectEqual(@as(u64, 0), first.errors);

    // Lossless declares a sample width; MPEG audio has none to declare and is
    // left unknown rather than given an invented one.
    // `codec` names the encoding, not the container, so a lossless row and a
    // lossy row are told apart by it without consulting anything else.
    try expectProperties(&library, root_path, "tagged-reference.flac", .{
        .codec = "flac",
        .sample_rate = 44100,
        .bit_depth = 16,
        .channels = 2,
        .duration_ms = 200,
    });
    try expectProperties(&library, root_path, "vbr-xing-reference.mp3", .{
        .codec = "mp3",
        .sample_rate = 44100,
        .bit_depth = null,
        .channels = 2,
        .duration_ms = 2000,
    });
    // Sniffed as FLAC, would not open: the container is known and the encoding
    // is not, so the identifier stays empty rather than being guessed from it.
    try expectProperties(&library, root_path, "broken.flac", .{
        .codec = "",
        .sample_rate = null,
        .bit_depth = null,
        .channels = null,
        .duration_ms = null,
    });

    // And the fast path stays the fast path: nothing changed, so nothing is
    // reopened and no decoder runs at all.
    const second = try scanner.scan(root_path);
    try std.testing.expectEqual(@as(u64, 0), second.changed);
    try std.testing.expectEqual(@as(u64, 4), second.unchanged);
}

const ExpectedProperties = struct {
    codec: []const u8,
    sample_rate: ?i64,
    bit_depth: ?i64,
    channels: ?i64,
    duration_ms: ?i64,
};

fn expectProperties(
    library: *database.LibraryDatabase,
    root_path: []const u8,
    name: []const u8,
    expected: ExpectedProperties,
) !void {
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}",
        .{ root_path, name },
    );
    defer std.testing.allocator.free(path);
    const file_id = (try library.files.resolveByUri(
        database.LibraryDatabase.null_volume,
        path,
    )).?;
    var statement = try library.database.prepare(
        "SELECT sample_rate, bit_depth, channels, duration_ms, codec FROM files WHERE id=?1;",
    );
    defer statement.deinit();
    try statement.bindInt64(1, file_id);
    if (try statement.step() != .row) return error.SqlFailed;
    try std.testing.expectEqual(expected.sample_rate, column(statement, 0));
    try std.testing.expectEqual(expected.bit_depth, column(statement, 1));
    try std.testing.expectEqual(expected.channels, column(statement, 2));
    try std.testing.expectEqual(expected.duration_ms, column(statement, 3));
    try std.testing.expectEqualStrings(expected.codec, statement.columnText(4));
}

fn column(statement: database.sqlite.Statement, index: c_int) ?i64 {
    if (statement.columnIsNull(index)) return null;
    return statement.columnInt64(index);
}

fn copyFixture(directory: std.Io.Dir, name: []const u8) !void {
    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        "fixtures/audio/{s}",
        .{name},
    );
    defer std.testing.allocator.free(source);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        source,
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(bytes);
    try directory.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
}

test "rescanning an untouched library leaves every file present" {
    // The unchanged fast path must still stamp the run's generation onto each
    // Location, or the post-run sweep marks every skipped file `missing`.
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "kept.flac",
        .data = "fLaCgenerated kept",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "removed.flac",
        .data = "fLaCgenerated removed",
    });
    const root_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(root_path);

    var database_directory = std.testing.tmpDir(.{});
    defer database_directory.cleanup();
    const database_path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/library.db",
        .{database_directory.sub_path},
        0,
    );
    defer std.testing.allocator.free(database_path);

    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        database_path,
    );
    defer library.close();
    const binding = try library.ensureRoot(std.testing.io, root_path, .{});

    const Sweep = struct {
        fn run(lib: *database.LibraryDatabase, bind: anytype, root: []const u8) !Result {
            const scan_run = try lib.scan_runs.begin(bind.root_id);
            var scanner = Scanner{
                .allocator = std.testing.allocator,
                .io = std.testing.io,
                .files = &lib.files,
                .locations = &lib.locations,
                .observed_tags = &lib.observed_tags,
                .write_lane = lib.write_lane,
                .database_handle = lib.database,
                .volume_id = bind.volume_id,
                .root_id = bind.root_id,
                .generation = scan_run.generation,
            };
            defer scanner.deinit();
            const outcome = try scanner.scan(root);
            _ = try lib.files.markMissingBelowGeneration(bind.root_id, scan_run.generation);
            return outcome;
        }
    };

    const first = try Sweep.run(&library, binding, root_path);
    try std.testing.expectEqual(@as(u64, 2), first.changed);
    try std.testing.expectEqual(@as(u64, 2), try library.locations.countPresent());

    // The second scan changes nothing, so every entry takes the fast path. It
    // must still count as seen.
    const second = try Sweep.run(&library, binding, root_path);
    try std.testing.expectEqual(@as(u64, 0), second.changed);
    try std.testing.expectEqual(@as(u64, 2), second.unchanged);
    try std.testing.expectEqual(@as(u64, 2), try library.locations.countPresent());

    // A third scan proves it is stable rather than alternating.
    _ = try Sweep.run(&library, binding, root_path);
    try std.testing.expectEqual(@as(u64, 2), try library.locations.countPresent());

    // And the sweep still does its actual job: a file that really went away is
    // reported missing rather than quietly kept.
    try temporary.dir.deleteFile(std.testing.io, "removed.flac");
    _ = try Sweep.run(&library, binding, root_path);
    try std.testing.expectEqual(@as(u64, 1), try library.locations.countPresent());
}

test "an ID3 tag in front of a FLAC stream does not hide the tags behind it" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var fixture = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/tagged-reference.flac",
    );
    const readable = fixture.readable();
    const stream = try std.testing.allocator.alloc(u8, @intCast(readable.size()));
    defer std.testing.allocator.free(stream);
    try std.testing.expectEqual(stream.len, try readable.readAt(0, stream));
    fixture.close();

    // A minimal ID3v2.4 header: "ID3", version, flags, then the payload size as
    // four syncsafe bytes -- seven bits each, high bit always clear. The tag
    // body here is zero padding, which is what a tagger's reserved space looks
    // like anyway.
    const tag_body = 300;
    const tagged = try std.testing.allocator.alloc(u8, 10 + tag_body + stream.len);
    defer std.testing.allocator.free(tagged);
    @memset(tagged[0 .. 10 + tag_body], 0);
    @memcpy(tagged[0..3], "ID3");
    tagged[3] = 4;
    tagged[4] = 0;
    tagged[5] = 0;
    tagged[6] = @intCast((tag_body >> 21) & 0x7f);
    tagged[7] = @intCast((tag_body >> 14) & 0x7f);
    tagged[8] = @intCast((tag_body >> 7) & 0x7f);
    tagged[9] = @intCast(tag_body & 0x7f);
    @memcpy(tagged[10 + tag_body ..], stream);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "id3-then-flac.flac",
        .data = tagged,
    });

    const root_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(root_path);

    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-scanner-id3-flac?mode=memory&cache=shared",
    );
    defer library.close();
    var scanner = Scanner{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .files = &library.files,
        .locations = &library.locations,
        .observed_tags = &library.observed_tags,
        .write_lane = library.write_lane,
        .database_handle = library.database,
    };
    defer scanner.deinit();

    const result = try scanner.scan(root_path);
    try std.testing.expectEqual(@as(u64, 1), result.changed);
    try std.testing.expectEqual(@as(u64, 0), result.unsupported);

    const stored = try library.observed_tags.get(std.testing.allocator, 1);
    defer if (stored) |owned| owned.deinit();
    try std.testing.expect(stored != null);
    // The same values the untagged fixture yields, read from behind the tag.
    try std.testing.expectEqualStrings("Reference Tone", stored.?.values.title.?);
    try std.testing.expectEqualStrings("Orca Test", stored.?.values.artist.?);
}
