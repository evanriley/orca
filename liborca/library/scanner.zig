const std = @import("std");
const codec = @import("../codec/root.zig");
const database = @import("../database/root.zig");
const metadata_model = @import("../metadata/root.zig").model;
const storage = @import("../storage/root.zig");
const projection = @import("projection.zig");
const tag_reader = @import("tag_reader.zig");
const watch = @import("watch.zig");

pub const CancellationToken = struct {
    requested: std.atomic.Value(bool) = .init(false),
    paused: std.atomic.Value(bool) = .init(false),
    /// What a paused `checkpoint` sleeps on. Without one, a checkpoint never
    /// holds, so a pause is not honoured.
    io: ?std.Io = null,

    pub const pause_poll_ms = 50;

    pub fn cancel(self: *CancellationToken) void {
        self.requested.store(true, .release);
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.requested.load(.acquire);
    }

    pub fn pause(self: *CancellationToken) void {
        self.paused.store(true, .release);
    }

    pub fn unpause(self: *CancellationToken) void {
        self.paused.store(false, .release);
    }

    pub fn isPaused(self: *const CancellationToken) bool {
        return self.paused.load(.acquire);
    }

    pub fn checkpoint(self: *const CancellationToken) bool {
        if (self.io) |io| {
            while (self.isPaused() and !self.isCancelled()) {
                io.sleep(.fromMilliseconds(pause_poll_ms), .awake) catch break;
            }
        }
        return self.isCancelled();
    }
};

/// The path or title a pass is working on, written by its threads and read by
/// the control lane for a Job's snapshot.
pub const CurrentItem = struct {
    lock: std.atomic.Mutex = .unlocked,
    bytes: [capacity]u8 = undefined,
    len: usize = 0,

    pub const capacity = 512;

    pub fn set(self: *CurrentItem, text: []const u8) void {
        var length = @min(text.len, capacity);
        while (length > 0 and length < text.len and (text[length] & 0xC0) == 0x80) length -= 1;
        self.acquire();
        defer self.lock.unlock();
        @memcpy(self.bytes[0..length], text[0..length]);
        self.len = length;
    }

    pub fn read(self: *CurrentItem, out: *[capacity]u8) []const u8 {
        self.acquire();
        defer self.lock.unlock();
        @memcpy(out[0..self.len], self.bytes[0..self.len]);
        return out[0..self.len];
    }

    fn acquire(self: *CurrentItem) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }
};

pub const Result = struct {
    files_seen: u64 = 0,
    changed: u64 = 0,
    unchanged: u64 = 0,
    unsupported: u64 = 0,
    images: u64 = 0,
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

const image_extensions = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp" };

fn hasImageExtension(basename: []const u8) bool {
    for (image_extensions) |extension| {
        if (basename.len > extension.len and
            std.ascii.endsWithIgnoreCase(basename, extension)) return true;
    }
    return false;
}

fn isFolderOrBelow(folder: []const u8, path: []const u8) bool {
    if (folder.len == 0) return true;
    if (!std.mem.startsWith(u8, path, folder)) return false;
    return path.len == folder.len or path[folder.len] == '/';
}

/// Walks a root and records what the filesystem currently says.
///
/// The scanner observes: it writes `files`, `locations` and
/// `observed_file_tags`. The one exception is a path whose bytes diverged from
/// a file still present elsewhere: it becomes a file of its own, which takes a
/// copy of the shared file's Orca values and the journal rows naming the path.
/// Turning observations into artists, releases and tracks is the projection's
/// job, and Track metadata is never written from here.
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
    current_item: ?*CurrentItem = null,
    /// Files walked so far, published for a host that is showing progress. A
    /// scan has no honest denominator until the walk finishes, so this is a
    /// count and never a fraction. Optional: nothing here depends on it.
    progress: ?*std.atomic.Value(u64) = null,
    batch_size: usize = 256,
    /// Decoders used to read each changed file's declared audio properties.
    /// Injectable so a test can narrow the set; absent, the builtins are used.
    codecs: ?*const codec.CodecRegistry = null,
    ignore: watch.Ignore = .{},
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
    seen_images: std.ArrayList(i64) = .empty,
    pending_images: std.ArrayList(database.repository.FolderImageUpsert) = .empty,
    /// Root-relative folders this run finished walking, recorded with the
    /// next batch so a folder's scan time commits with its files.
    finished_folders: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Scanner) void {
        self.seen.deinit(self.allocator);
        self.seen_images.deinit(self.allocator);
        self.clearPendingImages();
        self.pending_images.deinit(self.allocator);
        self.clearFinishedFolders();
        self.finished_folders.deinit(self.allocator);
        self.projected.deinit(self.allocator);
        self.* = undefined;
    }

    fn clearPendingImages(self: *Scanner) void {
        for (self.pending_images.items) |image| self.allocator.free(image.uri);
        self.pending_images.clearRetainingCapacity();
    }

    fn clearFinishedFolders(self: *Scanner) void {
        for (self.finished_folders.items) |folder| self.allocator.free(folder);
        self.finished_folders.clearRetainingCapacity();
    }

    pub fn scan(self: *Scanner, root_path: []const u8) !Result {
        return self.walk(root_path, null);
    }

    /// Walks `root_path/subtree` as `scan` walks the whole root, recording
    /// each file under the same uri a full scan gives it. A subtree that is
    /// not there, or is no longer a directory, is a completed walk that found
    /// nothing.
    pub fn scanSubtree(self: *Scanner, root_path: []const u8, subtree: []const u8) !Result {
        try validateSubtree(subtree);
        return self.walk(root_path, subtree);
    }

    fn walk(self: *Scanner, root_path: []const u8, subtree: ?[]const u8) !Result {
        if (self.batch_size == 0) return error.InvalidBatchSize;
        if (self.cancellation) |token| {
            if (token.checkpoint()) return .{ .cancelled = true };
        }
        const root = try std.Io.Dir.cwd().openDir(self.io, root_path, .{ .iterate = true });
        defer root.close(self.io);
        const start = if (subtree) |relative|
            root.openDir(self.io, relative, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return .{},
                else => return err,
            }
        else
            root;
        defer if (subtree != null) start.close(self.io);
        const start_path = if (subtree) |relative|
            try pathUnder(self.allocator, root_path, relative)
        else
            root_path;
        defer if (subtree != null) self.allocator.free(start_path);
        var walker = try start.walk(self.allocator);
        defer walker.deinit();

        var builtin_codecs = codec.CodecRegistry.builtins();
        const codecs = self.codecs orelse &builtin_codecs;

        var pending: std.ArrayList(PendingEntry) = .empty;
        defer {
            for (pending.items) |entry| entry.deinit(self.allocator);
            pending.deinit(self.allocator);
        }
        var result: Result = .{};
        var open_folders: std.ArrayList([]u8) = .empty;
        defer {
            for (open_folders.items) |folder| self.allocator.free(folder);
            open_folders.deinit(self.allocator);
        }
        try open_folders.append(self.allocator, try self.allocator.dupe(u8, ""));

        while (try walker.next(self.io)) |entry| {
            if (self.cancellation) |token| if (token.checkpoint()) {
                result.cancelled = true;
                break;
            };
            if (self.ignore.matches(entry.basename)) {
                if (entry.kind == .directory) walker.leave(self.io);
                continue;
            }
            try self.enterFolder(&open_folders, std.fs.path.dirnamePosix(entry.path) orelse "", subtree);
            if (entry.kind != .file) continue;
            result.files_seen += 1;
            if (self.progress) |counter| counter.store(result.files_seen, .release);

            const path = try pathUnder(self.allocator, start_path, entry.path);
            if (self.current_item) |current| current.set(path);
            if (hasImageExtension(entry.basename) and try self.examineImage(path, entry.basename, &result)) {
                self.allocator.free(path);
            } else {
                try self.examine(path, codecs, &pending, &result, .skip_unchanged);
            }
            if (self.pending_images.items.len >= self.batch_size or
                self.finished_folders.items.len >= self.batch_size)
            {
                try self.flush(&pending);
                result.batches_committed += 1;
                try self.project(&result);
            }
        }
        if (!result.cancelled) {
            while (open_folders.pop()) |folder| try self.finishFolder(folder, subtree);
        }
        if (pending.items.len > 0 or self.pending_images.items.len > 0 or self.finished_folders.items.len > 0) {
            try self.flush(&pending);
            result.batches_committed += 1;
        }
        try self.flushSeen();
        try self.project(&result);
        return result;
    }

    /// Finishes every open folder that `parent`, relative to the walk's
    /// start, is not inside, then opens `parent`. The walk is depth first, so
    /// a folder left behind is never entered again.
    fn enterFolder(
        self: *Scanner,
        open_folders: *std.ArrayList([]u8),
        parent: []const u8,
        subtree: ?[]const u8,
    ) !void {
        while (open_folders.items.len > 0 and
            !isFolderOrBelow(open_folders.items[open_folders.items.len - 1], parent))
        {
            try self.finishFolder(open_folders.pop().?, subtree);
        }
        const top = open_folders.items[open_folders.items.len - 1];
        if (std.mem.eql(u8, top, parent)) return;
        const opened = try self.allocator.dupe(u8, parent);
        errdefer self.allocator.free(opened);
        try open_folders.append(self.allocator, opened);
    }

    /// Takes ownership of `folder`, relative to the walk's start.
    fn finishFolder(self: *Scanner, folder: []u8, subtree: ?[]const u8) !void {
        const prefix = subtree orelse "";
        const relative = if (prefix.len == 0)
            folder
        else if (folder.len == 0)
            try self.allocator.dupe(u8, prefix)
        else
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, folder });
        if (relative.ptr != folder.ptr) self.allocator.free(folder);
        if (self.root_id == null) {
            self.allocator.free(relative);
            return;
        }
        errdefer self.allocator.free(relative);
        try self.finished_folders.append(self.allocator, relative);
    }

    /// Records `path` as a folder image when its bytes are one, and reports
    /// whether they were. Only a header is read.
    fn examineImage(self: *Scanner, path: []const u8, basename: []const u8, result: *Result) !bool {
        var local = storage.LocalFileSource.open(self.io, path) catch return false;
        defer local.close();
        const storage_identity = local.readable().identity();
        const size_bytes = std.math.cast(i64, storage_identity.size) orelse return false;
        const modified_ns = std.math.cast(i64, storage_identity.modified_ns) orelse return false;
        if (try self.locations.unchangedImageId(self.volume_id, path, size_bytes, modified_ns)) |image_id| {
            try self.seen_images.append(self.allocator, image_id);
            if (self.seen_images.items.len >= self.batch_size) try self.flushSeen();
            result.images += 1;
            return true;
        }
        var header: [16]u8 = undefined;
        const header_len = local.readable().readAt(0, &header) catch return false;
        const mime = metadata_model.sniffImageMimeType(header[0..header_len]) orelse return false;
        const uri = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(uri);
        try self.pending_images.append(self.allocator, .{
            .volume_id = self.volume_id,
            .root_id = self.root_id,
            .uri = uri,
            .mime = mime,
            .role = database.repository.ArtworkRole.ofName(basename),
            .size_bytes = size_bytes,
            .modified_ns = modified_ns,
            .last_seen_generation = self.generation,
        });
        result.images += 1;
        return true;
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
        if (self.seen.items.len == 0 and self.seen_images.items.len == 0) return;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.locations.markSeenLocked(self.seen.items, self.generation);
        self.seen.clearRetainingCapacity();
        try self.locations.markImagesSeenLocked(self.seen_images.items, self.generation);
        self.seen_images.clearRetainingCapacity();
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
            const resolution = try self.files.resolveForBytes(entry.path, entry.identity, &entry.quick_hash);
            const file_id = switch (resolution) {
                .new => try self.files.createLocked(upsert),
                .same => |id| same: {
                    try self.files.updateLocked(id, upsert);
                    break :same id;
                },
                .diverged => |shared| try self.files.forkLocked(shared, entry.path, upsert),
            };
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
            }}) else try self.observed_tags.clearLocked(file_id);
            if (self.projection != null) {
                try self.projected.append(self.allocator, file_id);
                // After the fork: when both copies resolve to one Track, the folder projected last decides its file.
                if (resolution == .diverged) try self.projected.append(self.allocator, resolution.diverged);
            }
        }
        for (self.pending_images.items) |image| {
            try self.locations.upsertImageLocked(image);
            if (image.role == .front) try self.locations.refreshFolderCoversLocked(self.allocator, image.volume_id, image.uri);
        }
        if (self.root_id) |root_id| {
            for (self.finished_folders.items) |folder| try self.locations.recordFolderScanLocked(root_id, folder);
        }
        try self.database_handle.exec("COMMIT;");
        for (pending.items) |entry| entry.deinit(self.allocator);
        pending.clearRetainingCapacity();
        self.clearPendingImages();
        self.clearFinishedFolders();
    }
};

const optionalCount = database.columns.optionalCount;

/// The uri a file or directory `relative` to a root is stored under. Every
/// walk builds uris through this, so a subtree walk and a full scan name the
/// same file identically.
pub fn pathUnder(allocator: std.mem.Allocator, root_path: []const u8, relative: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_path, relative });
}

pub fn validateSubtree(subtree: []const u8) error{InvalidReconcileDirectory}!void {
    if (subtree.len == 0) return error.InvalidReconcileDirectory;
    var components = std.mem.splitScalar(u8, subtree, '/');
    while (components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return error.InvalidReconcileDirectory;
    }
}

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

test "a scan of a root holding the Library never examines its database, WAL files or backups" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "song.flac",
        .data = "fLaCgenerated song",
    });
    try temporary.dir.createDirPath(std.testing.io, "library.db.orca-backups/1");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "library.db.orca-backups/1/0-song.flac",
        .data = "fLaCgenerated backup",
    });
    const root_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(root_path);
    const database_path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "{s}/library.db",
        .{root_path},
        0,
    );
    defer std.testing.allocator.free(database_path);
    var library = try database.LibraryDatabase.open(std.testing.allocator, std.testing.io, database_path);
    defer library.close();
    for ([_][]const u8{ "library.db", "library.db-wal", "library.db-shm" }) |name|
        _ = try temporary.dir.statFile(std.testing.io, name, .{});
    var scanner = Scanner{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .files = &library.files,
        .locations = &library.locations,
        .observed_tags = &library.observed_tags,
        .write_lane = library.write_lane,
        .database_handle = library.database,
        .ignore = watch.Ignore.forLibrary(&library),
    };
    defer scanner.deinit();

    const result = try scanner.scan(root_path);
    try std.testing.expectEqual(@as(u64, 1), result.files_seen);
    try std.testing.expectEqual(@as(u64, 1), result.changed);
    try std.testing.expectEqual(@as(u64, 0), result.unsupported);
    try std.testing.expectEqual(@as(u64, 0), result.errors);
    try std.testing.expectEqual(@as(u64, 1), try library.files.count());
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

const PausedCheckpoint = struct {
    threaded: std.Io.Threaded = .init_single_threaded,
    token: CancellationToken = .{},
    returned: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),

    fn run(self: *PausedCheckpoint) void {
        self.cancelled.store(self.token.checkpoint(), .release);
        self.returned.store(true, .release);
    }
};

test "a paused checkpoint holds its thread until cancel, which it notices within one poll" {
    var state: PausedCheckpoint = .{};
    defer state.threaded.deinit();
    state.token.io = state.threaded.io();
    state.token.pause();
    const thread = try std.Thread.spawn(.{}, PausedCheckpoint.run, .{&state});
    try std.testing.io.sleep(.fromMilliseconds(3 * CancellationToken.pause_poll_ms), .awake);
    try std.testing.expect(!state.returned.load(.acquire));

    const cancelled_at = std.Io.Clock.awake.now(std.testing.io);
    state.token.cancel();
    while (!state.returned.load(.acquire)) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    const waited = cancelled_at.durationTo(std.Io.Clock.awake.now(std.testing.io));
    thread.join();
    try std.testing.expect(state.cancelled.load(.acquire));
    try std.testing.expect(waited.toMilliseconds() < 100);
}

test "an unpaused checkpoint returns at once" {
    var state: PausedCheckpoint = .{};
    defer state.threaded.deinit();
    state.token.io = state.threaded.io();
    state.token.pause();
    state.token.unpause();
    state.run();
    try std.testing.expect(!state.cancelled.load(.acquire));
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
    try copyFixtureTo(directory, name, name);
}

fn copyFixtureTo(directory: std.Io.Dir, name: []const u8, sub_path: []const u8) !void {
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
    try directory.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = bytes });
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

test "a rescan of a file whose tags were removed forgets the old tags" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var tagged: [256]u8 = @splat(0);
    @memcpy(tagged[0..3], "ID3");
    @memcpy(tagged[128..131], "TAG");
    @memcpy(tagged[131..140], "Old title");
    @memcpy(tagged[161..171], "Old artist");
    @memcpy(tagged[191..200], "Old album");
    tagged[255] = 17;
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "song.mp3", .data = &tagged });
    const root_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(root_path);

    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-scanner-removed-tags?mode=memory&cache=shared",
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

    _ = try scanner.scan(root_path);
    const song_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/song.mp3", .{root_path});
    defer std.testing.allocator.free(song_path);
    const file_id = (try library.files.resolveByUri(
        database.LibraryDatabase.null_volume,
        song_path,
    )).?;
    const before = (try library.observed_tags.get(std.testing.allocator, file_id)).?;
    defer before.deinit();
    try std.testing.expectEqualStrings("Old title", before.values.title.?);
    try std.testing.expectEqual(@as(usize, 1), before.values.genres.len);

    var untagged: [300]u8 = @splat(0);
    @memcpy(untagged[0..3], "ID3");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "song.mp3", .data = &untagged });
    const rescan = try scanner.scan(root_path);
    try std.testing.expectEqual(@as(u64, 1), rescan.changed);
    try std.testing.expectEqual(file_id, (try library.files.resolveByUri(
        database.LibraryDatabase.null_volume,
        song_path,
    )).?);

    const after = try library.observed_tags.get(std.testing.allocator, file_id);
    defer if (after) |owned| owned.deinit();
    try std.testing.expect(after == null);
    var genres = try library.database.prepare(
        "SELECT count(*) FROM observed_file_genres WHERE file_id=?1;",
    );
    defer genres.deinit();
    try genres.bindInt64(1, file_id);
    try std.testing.expectEqual(database.sqlite.Step.row, try genres.step());
    try std.testing.expectEqual(@as(i64, 0), genres.columnInt64(0));

    var page = try library.tracks.page(std.testing.allocator, .{ .limit = 4, .offset = 0 });
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqualStrings("song", page.items[0].title);
    try std.testing.expectEqualStrings("", page.items[0].artist);
    try std.testing.expectEqualStrings("", page.items[0].album);
}

/// Byte-identical copies of `tagged-reference.flac` at `a/song.flac` and
/// `b/song.flac` under one root, scanned once into a single shared file.
const SharedCopies = struct {
    temporary: std.testing.TmpDir,
    root_path: []u8,
    first_path: []u8,
    second_path: []u8,
    library: database.LibraryDatabase,
    binding: database.RootBinding,
    target: projection.Projection,

    fn init(self: *SharedCopies, name: [:0]const u8) !void {
        self.temporary = std.testing.tmpDir(.{});
        for ([_][]const u8{ "a", "b" }) |folder| try self.temporary.dir.createDir(std.testing.io, folder, .default_dir);
        try copyFixtureTo(self.temporary.dir, "tagged-reference.flac", "a/song.flac");
        try copyFixtureTo(self.temporary.dir, "tagged-reference.flac", "b/song.flac");
        self.root_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{self.temporary.sub_path});
        self.first_path = try pathUnder(std.testing.allocator, self.root_path, "a/song.flac");
        self.second_path = try pathUnder(std.testing.allocator, self.root_path, "b/song.flac");
        self.library = try database.LibraryDatabase.open(std.testing.allocator, std.testing.io, name);
        self.binding = try self.library.ensureRoot(std.testing.io, self.root_path, .{ .stable_key = "test:shared-copies" });
        self.target = .{ .allocator = std.testing.allocator, .library = &self.library };
        const first = try self.scan();
        try std.testing.expectEqual(@as(u64, 2), first.changed);
        try std.testing.expectEqual(@as(u64, 1), try self.library.files.count());
    }

    fn deinit(self: *SharedCopies) void {
        self.library.close();
        std.testing.allocator.free(self.second_path);
        std.testing.allocator.free(self.first_path);
        std.testing.allocator.free(self.root_path);
        self.temporary.cleanup();
    }

    /// A completed scan of the whole root, swept as a scan job sweeps it.
    fn scan(self: *SharedCopies) !Result {
        const run = try self.library.scan_runs.begin(self.binding.root_id);
        var walker = self.scannerFor(run.generation);
        defer walker.deinit();
        const result = try walker.scan(self.root_path);
        _ = try self.library.files.markMissingBelowGeneration(self.binding.root_id, run.generation);
        return result;
    }

    fn scannerFor(self: *SharedCopies, generation: i64) Scanner {
        return .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .files = &self.library.files,
            .locations = &self.library.locations,
            .observed_tags = &self.library.observed_tags,
            .write_lane = self.library.write_lane,
            .database_handle = self.library.database,
            .volume_id = self.binding.volume_id,
            .root_id = self.binding.root_id,
            .generation = generation,
            .projection = &self.target,
        };
    }

    fn fileAt(self: *SharedCopies, path: []const u8) !?i64 {
        return self.library.files.resolveByUri(self.binding.volume_id, path);
    }

    fn sizeOf(self: *SharedCopies, file_id: i64) !i64 {
        var statement = try self.library.database.prepare("SELECT size_bytes FROM files WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    fn rowsOf(self: *SharedCopies, comptime table: []const u8, file_id: i64) !i64 {
        return self.scalarFor("SELECT count(*) FROM " ++ table ++ " WHERE file_id=?1;", file_id);
    }

    fn writtenValuesOf(self: *SharedCopies, file_id: i64) !i64 {
        return self.scalarFor(
            "SELECT count(*) FROM orca_metadata_values WHERE file_id=?1 AND written_at IS NOT NULL;",
            file_id,
        );
    }

    fn scalarFor(self: *SharedCopies, sql: [:0]const u8, file_id: i64) !i64 {
        var statement = try self.library.database.prepare(sql);
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    fn preferredFileOf(self: *SharedCopies, title: []const u8) !i64 {
        var statement = try self.library.database.prepare(
            "SELECT preferred_file_id FROM tracks WHERE title=?1;",
        );
        defer statement.deinit();
        try statement.bindText(1, title);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    fn trackTitles(self: *SharedCopies) ![]u8 {
        var statement = try self.library.database.prepare(
            "SELECT group_concat(title, '|') FROM (SELECT title FROM tracks ORDER BY title);",
        );
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return std.testing.allocator.dupe(u8, statement.columnText(0));
    }
};

test "a copy that diverges from a shared file becomes its own file and the untouched copy keeps the original" {
    var copies: SharedCopies = undefined;
    try copies.init("file:orca-scanner-diverged-copy?mode=memory&cache=shared");
    defer copies.deinit();
    const shared = (try copies.fileAt(copies.first_path)).?;
    try std.testing.expectEqual(shared, (try copies.fileAt(copies.second_path)).?);

    try copyFixtureTo(copies.temporary.dir, "tagged-reference.opus", "a/song.flac");
    const rescan = try copies.scan();
    try std.testing.expectEqual(@as(u64, 1), rescan.changed);
    try std.testing.expectEqual(@as(u64, 2), try copies.library.files.count());

    const diverged = (try copies.fileAt(copies.first_path)).?;
    try std.testing.expect(diverged != shared);
    try std.testing.expectEqual(shared, (try copies.fileAt(copies.second_path)).?);
    try std.testing.expectEqual(@as(i64, 10880), try copies.sizeOf(shared));
    try std.testing.expectEqual(@as(i64, 2734), try copies.sizeOf(diverged));

    const kept = (try copies.library.observed_tags.get(std.testing.allocator, shared)).?;
    defer kept.deinit();
    try std.testing.expectEqualStrings("Reference Tone", kept.values.title.?);
    const read = (try copies.library.observed_tags.get(std.testing.allocator, diverged)).?;
    defer read.deinit();
    try std.testing.expectEqualStrings("Opus Reference", read.values.title.?);

    const titles = try copies.trackTitles();
    defer std.testing.allocator.free(titles);
    try std.testing.expectEqualStrings("Opus Reference|Reference Tone", titles);
}

test "a diverged copy carries the file's Orca values and locks but none of its analysis, history or proposals" {
    var copies: SharedCopies = undefined;
    const Provenance = @import("../metadata/model.zig").Provenance;
    try copies.init("file:orca-scanner-diverged-values?mode=memory&cache=shared");
    defer copies.deinit();
    const shared = (try copies.fileAt(copies.first_path)).?;
    const recording_mbid = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";
    try copies.library.orca_metadata.upsert(.{
        .file_id = shared,
        .field = .title,
        .value = "Curated Title",
        .provenance = .user,
        .locked = true,
    });
    try copies.library.orca_metadata.upsert(.{
        .file_id = shared,
        .field = .musicbrainz_recording_id,
        .value = recording_mbid,
        .provenance = .provider,
    });
    try copies.library.orca_metadata.markWritten(shared, .musicbrainz_recording_id, recording_mbid);
    for ([_][:0]const u8{
        "INSERT INTO analysis_results(file_id, kind, algorithm_id, algorithm_version, parameter_hash, source_identity, result) VALUES (?1, 2, 'orca.temporal-fingerprint', 2, X'00', X'01', X'00');",
        "INSERT INTO library_health_issues(file_id, kind, severity, details) VALUES (?1, 5, 1, 'clipped');",
        "INSERT INTO listens(file_id, started_at, listened_ms, title, artist) VALUES (?1, 1800000000, 1000, 'Reference Tone', 'Orca Test');",
        "INSERT INTO identification_proposals(file_id, provider, provider_id, confidence, payload) VALUES (?1, 'musicbrainz', '8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a', 0.9, '{}');",
        "INSERT INTO identification_searches(file_id, provider, searched_at) VALUES (?1, 'musicbrainz', 1800000000);",
        "INSERT INTO acoustid_submissions(file_id, recording_mbid, submission_id, submitted_at) VALUES (?1, '8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a', 7, 1800000000);",
        "INSERT INTO recording_verifications(file_id, quick_hash, recording_mbid, outcome, heard, verified_at) VALUES (?1, X'01', '8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a', 0, '[]', 1800000000);",
    }) |sql| {
        var statement = try copies.library.database.prepare(sql);
        defer statement.deinit();
        try statement.bindInt64(1, shared);
        try std.testing.expectEqual(database.sqlite.Step.done, try statement.step());
    }

    try copyFixtureTo(copies.temporary.dir, "tagged-reference.opus", "a/song.flac");
    _ = try copies.scan();
    const diverged = (try copies.fileAt(copies.first_path)).?;
    try std.testing.expect(diverged != shared);

    for ([_]i64{ shared, diverged }) |file_id| {
        var values = try copies.library.orca_metadata.values(std.testing.allocator, file_id);
        defer values.deinit();
        try std.testing.expectEqual(@as(usize, 2), values.items.len);
        try std.testing.expectEqualStrings("Curated Title", values.items[0].text);
        try std.testing.expectEqual(Provenance.user, values.items[0].provenance);
        try std.testing.expect(values.items[0].locked);
        try std.testing.expectEqualStrings(recording_mbid, values.items[1].text);
        try std.testing.expectEqual(Provenance.provider, values.items[1].provenance);
        try std.testing.expect(!values.items[1].locked);
    }
    try std.testing.expectEqual(@as(i64, 1), try copies.writtenValuesOf(shared));
    try std.testing.expectEqual(@as(i64, 0), try copies.writtenValuesOf(diverged));
    inline for (.{
        "analysis_results",
        "(SELECT file_id FROM library_health_issues WHERE kind = 5)",
        "listens",
        "identification_proposals",
        "identification_searches",
        "acoustid_submissions",
        "recording_verifications",
    }) |table| {
        try std.testing.expectEqual(@as(i64, 1), try copies.rowsOf(table, shared));
        try std.testing.expectEqual(@as(i64, 0), try copies.rowsOf(table, diverged));
    }
}

test "a split reprojects both the folder the copy left and the folder it is in" {
    var copies: SharedCopies = undefined;
    try copies.init("file:orca-scanner-split-folders?mode=memory&cache=shared");
    defer copies.deinit();
    const shared = (try copies.fileAt(copies.first_path)).?;

    try copyFixtureTo(copies.temporary.dir, "tagged-reference.opus", "a/song.flac");
    const rescan = try copies.scan();
    try std.testing.expectEqual(@as(u64, 2), rescan.projection.folders_visited);
    const diverged = (try copies.fileAt(copies.first_path)).?;
    try std.testing.expectEqual(shared, try copies.preferredFileOf("Reference Tone"));
    try std.testing.expectEqual(diverged, try copies.preferredFileOf("Opus Reference"));
}

test "a rescan after a split reports both copies unchanged" {
    var copies: SharedCopies = undefined;
    try copies.init("file:orca-scanner-split-rescan?mode=memory&cache=shared");
    defer copies.deinit();

    try copyFixtureTo(copies.temporary.dir, "tagged-reference.opus", "a/song.flac");
    _ = try copies.scan();
    const again = try copies.scan();
    try std.testing.expectEqual(@as(u64, 0), again.changed);
    try std.testing.expectEqual(@as(u64, 2), again.unchanged);
    try std.testing.expectEqual(@as(u64, 0), again.projection.folders_visited);
    try std.testing.expectEqual(@as(u64, 2), try copies.library.files.count());
    try std.testing.expectEqual(@as(u64, 2), try copies.library.locations.countPresent());
}

test "a copy that diverged is no longer a second present path of what it left" {
    var copies: SharedCopies = undefined;
    try copies.init("file:orca-scanner-split-duplicate?mode=memory&cache=shared");
    defer copies.deinit();
    const shared = (try copies.fileAt(copies.first_path)).?;
    const before = (try copies.library.locations.secondPresentPath(std.testing.allocator, shared)).?;
    std.testing.allocator.free(before);

    try copyFixtureTo(copies.temporary.dir, "tagged-reference.opus", "a/song.flac");
    _ = try copies.scan();
    const diverged = (try copies.fileAt(copies.first_path)).?;
    try std.testing.expect((try copies.library.locations.secondPresentPath(std.testing.allocator, shared)) == null);
    try std.testing.expect((try copies.library.locations.secondPresentPath(std.testing.allocator, diverged)) == null);
}

test "a moved copy of a shared file stays on that file" {
    var copies: SharedCopies = undefined;
    try copies.init("file:orca-scanner-moved-copy?mode=memory&cache=shared");
    defer copies.deinit();
    const shared = (try copies.fileAt(copies.first_path)).?;

    try copies.temporary.dir.createDir(std.testing.io, "c", .default_dir);
    try copies.temporary.dir.rename("b/song.flac", copies.temporary.dir, "c/song.flac", std.testing.io);
    const moved_path = try pathUnder(std.testing.allocator, copies.root_path, "c/song.flac");
    defer std.testing.allocator.free(moved_path);
    const rescan = try copies.scan();
    try std.testing.expectEqual(@as(u64, 1), rescan.changed);
    try std.testing.expectEqual(@as(u64, 1), try copies.library.files.count());
    try std.testing.expectEqual(shared, (try copies.fileAt(moved_path)).?);
    try std.testing.expectEqual(shared, (try copies.fileAt(copies.first_path)).?);
    try std.testing.expectEqual(
        database.LocationState.missing,
        try copies.library.locations.stateOf((try copies.library.locations.find(copies.binding.volume_id, copies.second_path)).?),
    );
}

test "a file with one location follows its bytes when they change" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try copyFixtureTo(temporary.dir, "tagged-reference.flac", "song.flac");
    const root_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(root_path);
    const song_path = try pathUnder(std.testing.allocator, root_path, "song.flac");
    defer std.testing.allocator.free(song_path);
    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-scanner-single-location?mode=memory&cache=shared",
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
    _ = try scanner.scan(root_path);
    const file_id = (try library.files.resolveByUri(database.LibraryDatabase.null_volume, song_path)).?;

    try copyFixtureTo(temporary.dir, "tagged-reference.opus", "song.flac");
    const rescan = try scanner.scan(root_path);
    try std.testing.expectEqual(@as(u64, 1), rescan.changed);
    try std.testing.expectEqual(@as(u64, 1), try library.files.count());
    try std.testing.expectEqual(file_id, (try library.files.resolveByUri(database.LibraryDatabase.null_volume, song_path)).?);
    const observed = (try library.observed_tags.get(std.testing.allocator, file_id)).?;
    defer observed.deinit();
    try std.testing.expectEqualStrings("Opus Reference", observed.values.title.?);
}

test "a file whose other copy is gone follows its bytes when they change" {
    var copies: SharedCopies = undefined;
    try copies.init("file:orca-scanner-copy-gone?mode=memory&cache=shared");
    defer copies.deinit();
    const shared = (try copies.fileAt(copies.first_path)).?;
    try copies.temporary.dir.deleteFile(std.testing.io, "b/song.flac");
    _ = try copies.scan();
    try std.testing.expectEqual(@as(u64, 1), try copies.library.locations.countPresent());

    try copyFixtureTo(copies.temporary.dir, "tagged-reference.opus", "a/song.flac");
    const rescan = try copies.scan();
    try std.testing.expectEqual(@as(u64, 1), rescan.changed);
    try std.testing.expectEqual(@as(u64, 1), try copies.library.files.count());
    try std.testing.expectEqual(shared, (try copies.fileAt(copies.first_path)).?);
    try std.testing.expectEqual(@as(i64, 2734), try copies.sizeOf(shared));
}

test "hard-linked paths of one file stay one file when it changes" {
    var copies: SharedCopies = undefined;
    try copies.init("file:orca-scanner-hard-link?mode=memory&cache=shared");
    defer copies.deinit();
    const shared = (try copies.fileAt(copies.first_path)).?;
    try copies.temporary.dir.deleteFile(std.testing.io, "b/song.flac");
    try copies.temporary.dir.hardLink("a/song.flac", copies.temporary.dir, "b/song.flac", std.testing.io, .{});
    _ = try copies.scan();
    try std.testing.expectEqual(@as(u64, 1), try copies.library.files.count());

    try copyFixtureTo(copies.temporary.dir, "tagged-reference.opus", "a/song.flac");
    const rescan = try copies.scan();
    try std.testing.expectEqual(@as(u64, 2), rescan.changed);
    try std.testing.expectEqual(@as(u64, 1), try copies.library.files.count());
    try std.testing.expectEqual(shared, (try copies.fileAt(copies.first_path)).?);
    try std.testing.expectEqual(shared, (try copies.fileAt(copies.second_path)).?);
    try std.testing.expectEqual(@as(i64, 2734), try copies.sizeOf(shared));
}

test "a split copy does not submit a recording id it inherited from a provider match" {
    var copies: SharedCopies = undefined;
    try copies.init("file:orca-scanner-split-acoustid?mode=memory&cache=shared");
    defer copies.deinit();
    const shared = (try copies.fileAt(copies.first_path)).?;
    const recording_mbid = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";
    _ = try copies.library.identification_proposals.put(.{
        .file_id = shared,
        .provider = "musicbrainz",
        .provider_id = recording_mbid,
        .confidence = 0.95,
        .payload = "{\"title\":\"Reference Tone\"}",
    });
    const proposal = try copies.scalarFor("SELECT id FROM identification_proposals WHERE file_id=?1;", shared);
    _ = try copies.library.identification_proposals.acceptProposal(std.testing.allocator, proposal);
    const submissions = &copies.library.acoustid_submissions;
    try std.testing.expectEqual(@as(u64, 1), try submissions.submittableCount());

    try copyFixtureTo(copies.temporary.dir, "tagged-reference.opus", "a/song.flac");
    _ = try copies.scan();
    const diverged = (try copies.fileAt(copies.first_path)).?;
    const inherited = (try copies.library.orca_metadata.get(std.testing.allocator, diverged, .musicbrainz_recording_id)).?;
    defer inherited.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(recording_mbid, inherited.text);

    try std.testing.expectEqual(@as(u64, 1), try submissions.submittableCount());
    const page = try submissions.submittablePage(std.testing.allocator, 0, 10);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqual(shared, page.items[0].file_id);
}

test "a shared file with no quick hash is updated in place rather than split" {
    var copies: SharedCopies = undefined;
    try copies.init("file:orca-scanner-no-quick-hash?mode=memory&cache=shared");
    defer copies.deinit();
    const shared = (try copies.fileAt(copies.first_path)).?;
    try copies.library.database.exec("UPDATE files SET quick_hash = NULL;");

    try copyFixtureTo(copies.temporary.dir, "tagged-reference.opus", "a/song.flac");
    const rescan = try copies.scan();
    try std.testing.expectEqual(@as(u64, 1), rescan.changed);
    try std.testing.expectEqual(@as(u64, 1), try copies.library.files.count());
    try std.testing.expectEqual(shared, (try copies.fileAt(copies.first_path)).?);
    try std.testing.expectEqual(shared, (try copies.fileAt(copies.second_path)).?);
}

test "an image in a scanned folder is listed as a front cover beside the music, never as a Track" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "Album/Scans");
    try copyFixtureTo(temporary.dir, "tagged-reference.flac", "Album/song.flac");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "Album/cover.jpg", .data = "\xff\xd8\xff\xe0 a jpeg" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "Album/notes.jpg", .data = "not a picture" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "Album/Scans/Back.PNG", .data = "\x89PNG\r\n\x1a\n a png" });
    const root_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(root_path);
    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-scanner-images?mode=memory&cache=shared",
    );
    defer library.close();
    const binding = try library.ensureRoot(std.testing.io, root_path, .{ .stable_key = "test:images" });

    const ScanOnce = struct {
        fn run(lib: *database.LibraryDatabase, bind: database.RootBinding, path: []const u8) !Result {
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
            const result = try scanner.scan(path);
            _ = try lib.files.markMissingBelowGeneration(bind.root_id, scan_run.generation);
            return result;
        }
    };

    const first = try ScanOnce.run(&library, binding, root_path);
    try std.testing.expectEqual(@as(u64, 2), first.images);
    try std.testing.expectEqual(@as(u64, 1), first.unsupported);
    try std.testing.expectEqual(@as(u64, 1), try library.files.count());

    const album = try library.locations.folderPage(std.testing.allocator, binding.root_id, "Album", 512, 0);
    defer album.deinit();
    try std.testing.expectEqual(@as(usize, 2), album.items.len);
    try std.testing.expectEqual(database.repository.FolderEntryKind.file, album.items[0].kind);
    try std.testing.expectEqualStrings("song.flac", album.items[0].name);
    try std.testing.expectEqual(database.repository.FolderEntryKind.image, album.items[1].kind);
    try std.testing.expectEqualStrings("cover.jpg", album.items[1].name);
    try std.testing.expectEqualStrings("image/jpeg", album.items[1].mime.?);
    try std.testing.expectEqual(@as(?database.repository.ArtworkRole, .front), album.items[1].artwork_role);
    try std.testing.expectEqual(@as(u32, 1), album.image_count);
    try std.testing.expect(album.last_scanned_at != null);

    const scans = try library.locations.folderPage(std.testing.allocator, binding.root_id, "Album/Scans", 512, 0);
    defer scans.deinit();
    try std.testing.expectEqual(@as(usize, 1), scans.items.len);
    try std.testing.expectEqual(@as(?database.repository.ArtworkRole, .back), scans.items[0].artwork_role);
    try std.testing.expect(scans.last_scanned_at != null);
    const root = try library.locations.folderPage(std.testing.allocator, binding.root_id, "", 512, 0);
    defer root.deinit();
    try std.testing.expect(root.last_scanned_at != null);

    try temporary.dir.deleteFile(std.testing.io, "Album/cover.jpg");
    const second = try ScanOnce.run(&library, binding, root_path);
    try std.testing.expectEqual(@as(u64, 1), second.images);
    try std.testing.expectEqual(@as(u64, 1), second.unchanged);
    const after = try library.locations.folderPage(std.testing.allocator, binding.root_id, "Album", 512, 0);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 1), after.items.len);
    try std.testing.expectEqual(@as(u32, 0), after.image_count);
    const kept = try library.locations.folderPage(std.testing.allocator, binding.root_id, "Album/Scans", 512, 0);
    defer kept.deinit();
    try std.testing.expectEqual(@as(usize, 1), kept.items.len);
}

test "a cancelled walk records no scan time for the folders it did not finish" {
    var token: CancellationToken = .{};
    token.cancel();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "cover.jpg", .data = "\xff\xd8\xff\xe0" });
    const root_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(root_path);
    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-scanner-cancelled-folders?mode=memory&cache=shared",
    );
    defer library.close();
    const binding = try library.ensureRoot(std.testing.io, root_path, .{ .stable_key = "test:cancelled-folders" });
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
        .cancellation = &token,
    };
    defer scanner.deinit();
    const result = try scanner.scan(root_path);
    try std.testing.expect(result.cancelled);
    const root = try library.locations.folderPage(std.testing.allocator, binding.root_id, "", 512, 0);
    defer root.deinit();
    try std.testing.expectEqual(@as(?i64, null), root.last_scanned_at);
    try std.testing.expectEqual(@as(u32, 0), root.image_count);
}
