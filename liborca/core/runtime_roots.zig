const std = @import("std");
const database = @import("../database/root.zig");
const library_pass = @import("../library/root.zig");
const metadata = @import("../metadata/root.zig");
const storage = @import("../storage/root.zig");
const track_details = @import("track_details.zig");
const job_worker = @import("job_worker.zig");
const runtime = @import("runtime.zig");
const runtime_jobs = @import("runtime_jobs.zig");
const runtime_maintenance = @import("runtime_maintenance.zig");
const runtime_watch = @import("runtime_watch.zig");

const EditedTracks = runtime.EditedTracks;
const JobHandle = runtime.JobHandle;
const LibraryHandle = runtime.LibraryHandle;
const OrcaRuntime = runtime.OrcaRuntime;
const PendingTagWrite = job_worker.PendingTagWrite;
const PruneSummary = runtime.PruneSummary;
const RemovedRoot = runtime.RemovedRoot;
const TagWriteChange = runtime.TagWriteChange;
const TagWriteConflict = runtime.TagWriteConflict;
const TagWriteFile = runtime.TagWriteFile;
const TagWriteGenres = runtime.TagWriteGenres;
const TagWritePlan = runtime.TagWritePlan;
const TagWriteSkip = runtime.TagWriteSkip;
const TagWriteSkipReason = runtime.TagWriteSkipReason;
const TrackDetails = runtime.TrackDetails;
const TrackEdit = runtime.TrackEdit;
const TrackEditPage = runtime.TrackEditPage;

const max_edit_bytes = 4096;

fn validateEdit(field: metadata.Field, value: []const u8) !void {
    if (value.len == 0 or value.len > max_edit_bytes or !std.unicode.utf8ValidateSlice(value))
        return error.InvalidEditValue;
    switch (field) {
        .track_number, .disc_number => {
            const number = std.fmt.parseUnsigned(u16, value, 10) catch return error.InvalidEditValue;
            if (number == 0 or number > 9999) return error.InvalidEditValue;
        },
        .compilation => if (!std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "1"))
            return error.InvalidEditValue,
        .explicit => if (!std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "1") and
            !std.mem.eql(u8, value, "2")) return error.InvalidEditValue,
        .musicbrainz_recording_id,
        .musicbrainz_release_id,
        .musicbrainz_release_group_id,
        .musicbrainz_release_track_id,
        .musicbrainz_album_artist_id,
        => if (!metadata.isMusicBrainzId(value)) return error.InvalidEditValue,
        .title, .artist, .album, .album_artist, .date => {},
    }
}

/// A field's observed value as text, the form a `Change.before` states it in.
fn observedText(allocator: std.mem.Allocator, tags: metadata.ObservedTags, field: metadata.Field) !?[]const u8 {
    return switch (field) {
        .title => tags.title,
        .artist => tags.artist,
        .album => tags.album,
        .album_artist => tags.album_artist,
        .date => tags.date,
        .track_number => if (tags.track_number) |n| try std.fmt.allocPrint(allocator, "{d}", .{n}) else null,
        .disc_number => if (tags.disc_number) |n| try std.fmt.allocPrint(allocator, "{d}", .{n}) else null,
        .compilation => if (tags.compilation) |flag| (if (flag) "1" else "0") else null,
        .musicbrainz_recording_id => tags.musicbrainz_recording_id,
        .musicbrainz_release_id => tags.musicbrainz_release_id,
        .musicbrainz_release_group_id => tags.musicbrainz_release_group_id,
        .musicbrainz_release_track_id => tags.musicbrainz_release_track_id,
        .musicbrainz_album_artist_id => tags.musicbrainz_album_artist_id,
        .explicit => if (tags.explicit) |advisory| advisory.advisoryText() else null,
    };
}

fn backupPlanDirectoryExists(allocator: std.mem.Allocator, io: std.Io, backups: []const u8, plan_id: u64) !bool {
    const path = try std.fmt.allocPrint(allocator, "{s}/{d}", .{ backups, plan_id });
    defer allocator.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// Why a file cannot be written now, or null when it can.
fn tagWriteRefusal(
    io: std.Io,
    library_database: *database.LibraryDatabase,
    location: database.repository.PresentLocation,
) !?TagWriteSkipReason {
    if (!(metadata.executor.canWriteTags(io, location.uri) catch return .missing)) return .format_not_writable;
    std.Io.Dir.cwd().access(io, std.Io.Dir.path.dirname(location.uri) orelse ".", .{ .write = true, .execute = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return .folder_not_writable,
        error.FileNotFound => return .missing,
        else => return err,
    };
    var local = storage.LocalFileSource.open(io, location.uri) catch return .missing;
    const observed = local.readable().identity();
    local.close();
    const key: database.StorageIdentityKey = .{
        .volume_id = location.volume_id,
        .native_inode = std.math.cast(i64, observed.inode) orelse return .changed_since_scan,
        .size_bytes = std.math.cast(i64, observed.size) orelse return .changed_since_scan,
        .modified_ns = std.math.cast(i64, observed.modified_ns) orelse return .changed_since_scan,
    };
    if (try library_database.locations.unchangedLocationId(location.volume_id, location.uri, key) == null)
        return .changed_since_scan;
    return null;
}

pub fn libraryAddRoot(
    self: *OrcaRuntime,
    library: LibraryHandle,
    io: std.Io,
    path: []const u8,
) !database.RootBinding {
    try runtime.requireRunning(self);
    const library_database = try runtime.libraryDatabase(self, library);
    const binding = try library_database.ensureRoot(io, path, .{ .allow_persist = true });
    runtime_watch.rootAdded(self, library, binding, path);
    return binding;
}

pub fn libraryRemoveRoot(
    self: *OrcaRuntime,
    library: LibraryHandle,
    root_id: i64,
) !RemovedRoot {
    try runtime.requireRunning(self);
    const library_database = try runtime.libraryDatabase(self, library);
    runtime_watch.preemptAutoReconcile(self, library);
    runtime_maintenance.preemptUnit(self, library);
    if (runtime_jobs.libraryJobRunning(self, library)) return error.LibraryJobRunning;
    const removal = try library_database.library_roots.remove(self.allocator, root_id);
    defer removal.deinit();
    runtime_watch.rootRemoved(self, library, root_id);
    var pass: library_pass.Projection = .{
        .allocator = self.allocator,
        .library = library_database,
    };
    _ = try pass.run(.{ .files = removal.surviving_file_ids });
    return .{
        .files_forgotten = removal.files_forgotten,
        .tracks_removed = removal.tracks_removed,
    };
}

pub fn libraryRootPage(
    self: *OrcaRuntime,
    library: LibraryHandle,
    limit: u32,
    offset: u32,
) !database.repository.LibraryRootPage {
    return (try runtime.libraryDatabase(self, library)).library_roots.page(
        self.allocator,
        limit,
        offset,
    );
}

pub fn libraryFolderPage(
    self: *OrcaRuntime,
    library: LibraryHandle,
    root_id: i64,
    relative_path: []const u8,
    limit: u32,
    offset: u32,
) !database.repository.FolderPage {
    return (try runtime.libraryDatabase(self, library)).locations.folderPage(
        self.allocator,
        root_id,
        relative_path,
        limit,
        offset,
    );
}

pub fn playerPlayFolder(
    self: *OrcaRuntime,
    player: runtime.PlayerHandle,
    library: LibraryHandle,
    io: std.Io,
    root_id: i64,
    relative_path: []const u8,
    shuffle: bool,
) !void {
    const track_ids = try (try runtime.libraryDatabase(self, library)).locations.folderTrackIds(
        self.allocator,
        root_id,
        relative_path,
    );
    defer self.allocator.free(track_ids);
    if (track_ids.len == 0) return error.FolderEmpty;
    try self.playerSetShuffle(player, shuffle);
    return self.playerPlayTracks(player, library, io, track_ids, 0);
}

pub fn libraryTrackSummary(
    self: *OrcaRuntime,
    library: LibraryHandle,
    track_id: i64,
) !?database.TrackSummary {
    return (try runtime.libraryDatabase(self, library)).tracks.byId(self.allocator, track_id);
}

pub fn libraryTrackDetails(
    self: *OrcaRuntime,
    library: LibraryHandle,
    track_id: i64,
) !?TrackDetails {
    return track_details.load(self.allocator, try runtime.libraryDatabase(self, library), track_id);
}

pub fn libraryEditTracks(
    self: *OrcaRuntime,
    library: LibraryHandle,
    track_ids: []const i64,
    edits: []const TrackEdit,
) !EditedTracks {
    if (track_ids.len == 0 or track_ids.len > database.repository.max_page) return error.InvalidTrackSelection;
    if (edits.len == 0) return error.NoTrackEdits;
    for (edits) |edit| if (edit.value) |value| try validateEdit(edit.field, value);
    const library_database = try runtime.libraryDatabase(self, library);

    var files: std.ArrayList(i64) = .empty;
    defer files.deinit(self.allocator);
    for (track_ids) |track_id| {
        const ids = try library_database.tracks.fileIds(self.allocator, track_id);
        defer self.allocator.free(ids);
        if (ids.len == 0) return error.TrackNotFound;
        try files.appendSlice(self.allocator, ids);
    }
    for (files.items) |file_id| for (edits) |edit| {
        if (edit.value) |value| {
            try library_database.orca_metadata.upsert(.{
                .file_id = file_id,
                .field = edit.field,
                .value = value,
                .provenance = .user,
                .locked = true,
            });
        } else {
            try library_database.orca_metadata.remove(file_id, edit.field);
        }
    };
    var pass: library_pass.Projection = .{
        .allocator = self.allocator,
        .library = library_database,
    };
    _ = try pass.run(.{ .files = files.items });

    var edited: std.ArrayList(i64) = .empty;
    errdefer edited.deinit(self.allocator);
    for (files.items) |file_id| {
        const ids = try library_database.tracks.idsForFile(self.allocator, file_id);
        defer self.allocator.free(ids);
        for (ids) |id| {
            if (std.mem.indexOfScalar(i64, edited.items, id) == null) try edited.append(self.allocator, id);
        }
    }
    return .{ .allocator = self.allocator, .ids = try edited.toOwnedSlice(self.allocator) };
}

pub fn libraryTrackEdits(
    self: *OrcaRuntime,
    library: LibraryHandle,
    track_id: i64,
) !TrackEditPage {
    const library_database = try runtime.libraryDatabase(self, library);
    const ids = try library_database.tracks.fileIds(self.allocator, track_id);
    defer self.allocator.free(ids);
    if (ids.len == 0) return error.TrackNotFound;
    return library_database.orca_metadata.values(self.allocator, ids[0]);
}

pub fn planTagWrite(
    self: *OrcaRuntime,
    library: LibraryHandle,
    io: std.Io,
    track_ids: []const i64,
) !TagWritePlan {
    if (track_ids.len == 0 or track_ids.len > database.repository.max_page) return error.InvalidTrackSelection;
    const library_database = try runtime.libraryDatabase(self, library);

    const preview_arena = try self.allocator.create(std.heap.ArenaAllocator);
    preview_arena.* = .init(self.allocator);
    var preview: TagWritePlan = .{
        .arena = preview_arena,
        .plan_id = 0,
        .digest = @splat(0),
        .files = &.{},
        .skipped = &.{},
        .conflicts = &.{},
    };
    errdefer preview.deinit();
    const owned = preview_arena.allocator();

    var scratch_arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    var file_ids: std.ArrayList(i64) = .empty;
    for (track_ids) |track_id| {
        const ids = try library_database.tracks.fileIds(scratch, track_id);
        if (ids.len == 0) return error.TrackNotFound;
        for (ids) |id| if (std.mem.indexOfScalar(i64, file_ids.items, id) == null) try file_ids.append(scratch, id);
    }

    var actions: std.ArrayList(metadata.mutation.Action) = .empty;
    var locations: std.ArrayList(database.repository.PresentLocation) = .empty;
    var planned_file_ids: std.ArrayList(i64) = .empty;
    var files: std.ArrayList(TagWriteFile) = .empty;
    var skipped: std.ArrayList(TagWriteSkip) = .empty;
    var conflicts: std.ArrayList(TagWriteConflict) = .empty;
    for (file_ids.items) |file_id| {
        const location = try library_database.locations.presentOf(scratch, file_id) orelse {
            try skipped.append(owned, .{ .file_id = file_id, .path = "", .reason = .missing });
            continue;
        };
        const reason = try tagWriteRefusal(io, library_database, location);
        if (reason) |refusal| {
            try skipped.append(owned, .{ .file_id = file_id, .path = try owned.dupe(u8, location.uri), .reason = refusal });
            continue;
        }

        const values = try library_database.orca_metadata.values(scratch, file_id);
        const observed = try library_database.observed_tags.get(scratch, file_id);
        const tags: metadata.ObservedTags = if (observed) |stored| stored.values else .{};
        var changes: std.ArrayList(metadata.mutation.Change) = .empty;
        var shown: std.ArrayList(TagWriteChange) = .empty;
        for (values.items) |value| {
            const before = try observedText(scratch, tags, value.field);
            if (before) |current| {
                if (std.mem.eql(u8, current, value.text)) continue;
                if (!value.locked) {
                    try conflicts.append(owned, .{
                        .file_id = file_id,
                        .path = try owned.dupe(u8, location.uri),
                        .field = value.field,
                        .file_value = try owned.dupe(u8, current),
                        .orca_value = try owned.dupe(u8, value.text),
                        .provenance = value.provenance,
                    });
                    continue;
                }
            }
            try changes.append(scratch, .{ .field = value.field, .before = before, .after = value.text });
            try shown.append(owned, .{
                .field = value.field,
                .before = if (before) |text| try owned.dupe(u8, text) else null,
                .after = try owned.dupe(u8, value.text),
                .provenance = value.provenance,
            });
        }
        const genres = try userGenreChange(scratch, library_database, file_id, track_ids, tags.genres);
        if (changes.items.len == 0 and genres == null) continue;
        try actions.append(scratch, .{ .write_tags = .{
            .path = location.uri,
            .expected = try metadata.file_mutation.identity(io, location.uri),
            .changes = changes.items,
            .genres = genres,
        } });
        try locations.append(scratch, location);
        try planned_file_ids.append(scratch, file_id);
        try files.append(owned, .{
            .file_id = file_id,
            .path = try owned.dupe(u8, location.uri),
            .changes = shown.items,
            .genres = if (genres) |change| .{
                .before = try dupeValues(owned, change.before),
                .after = try dupeValues(owned, change.after),
            } else null,
        });
    }
    preview.skipped = skipped.items;
    preview.conflicts = conflicts.items;
    if (actions.items.len == 0) return preview;

    const slot = for (&self.pending_tag_writes) |*candidate| {
        if (candidate.* == null) break candidate;
    } else return error.TooManyPendingTagWrites;
    var plan_id = try library_database.mutation_journal.nextGroupId();
    for (self.pending_tag_writes) |held| if (held) |pending| {
        plan_id = @max(plan_id, pending.plan.id + 1);
    };
    if (library_database.backup_directory) |backups| {
        while (try backupPlanDirectoryExists(scratch, io, backups, plan_id)) plan_id += 1;
    }

    const pending = try self.allocator.create(PendingTagWrite);
    errdefer self.allocator.destroy(pending);
    pending.* = .{
        .arena = .init(self.allocator),
        .library = library,
        .plan = try metadata.mutation.Plan.init(self.allocator, plan_id, actions.items),
        .locations = &.{},
        .file_ids = &.{},
    };
    errdefer {
        pending.plan.deinit();
        pending.arena.deinit();
    }
    const held_locations = try pending.arena.allocator().alloc(database.repository.PresentLocation, locations.items.len);
    for (held_locations, locations.items) |*held, location| {
        held.* = location;
        held.uri = try pending.arena.allocator().dupe(u8, location.uri);
    }
    pending.locations = held_locations;
    pending.file_ids = try pending.arena.allocator().dupe(i64, planned_file_ids.items);

    preview.files = files.items;
    preview.plan_id = plan_id;
    preview.digest = pending.plan.approval().digest;
    slot.* = pending;
    return preview;
}

fn userGenreChange(
    allocator: std.mem.Allocator,
    library_database: *database.LibraryDatabase,
    file_id: i64,
    track_ids: []const i64,
    observed: []const []const u8,
) !?metadata.mutation.GenreChange {
    const backed = try library_database.tracks.idsForFile(allocator, file_id);
    for (track_ids) |track_id| {
        if (std.mem.indexOfScalar(i64, backed, track_id) == null) continue;
        const names = try library_database.genres.forTrack(allocator, track_id);
        if (names.items.len == 0 or names.items[0].provenance != .user) continue;
        const after = try allocator.alloc([]const u8, names.items.len);
        for (after, names.items) |*name, genre| name.* = genre.name;
        if (try sameGenres(allocator, observed, after)) return null;
        return .{ .before = observed, .after = after };
    }
    return null;
}

fn sameGenres(allocator: std.mem.Allocator, left: []const []const u8, right: []const []const u8) !bool {
    const left_genres = try metadata.genre_alias.foldAll(allocator, left);
    const right_genres = try metadata.genre_alias.foldAll(allocator, right);
    if (left_genres.len != right_genres.len) return false;
    for (left_genres, right_genres) |left_genre, right_genre| {
        if (!std.mem.eql(u8, left_genre.key, right_genre.key)) return false;
    }
    return true;
}

fn dupeValues(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const copies = try allocator.alloc([]const u8, values.len);
    for (copies, values) |*copy, value| copy.* = try allocator.dupe(u8, value);
    return copies;
}

pub fn startTagWrite(
    self: *OrcaRuntime,
    library: LibraryHandle,
    plan_id: u64,
    digest: metadata.mutation.Digest,
) !JobHandle {
    const slot = for (&self.pending_tag_writes) |*candidate| {
        const pending = candidate.* orelse continue;
        if (pending.plan.id == plan_id and pending.library.eql(library)) break candidate;
    } else return error.UnknownTagWritePlan;
    const library_database = try runtime.libraryDatabase(self, library);
    if (library_database.backup_directory == null) return error.NoBackupDirectory;
    const io = self.control_threaded.io();
    const pending = slot.*.?;
    pending.journal_lock = try metadata.JournalLock.acquireForMutation(io, library_database.journal_lock_path);
    errdefer {
        pending.journal_lock.?.release(io);
        pending.journal_lock = null;
    }
    try pending.plan.approve(.{ .plan_id = plan_id, .digest = digest });
    const job_handle = try runtime_jobs.startJobWorker(self, library, .{ .mutation = pending });
    slot.* = null;
    return job_handle;
}

pub fn discardTagWrite(self: *OrcaRuntime, library: LibraryHandle, plan_id: u64) !void {
    for (&self.pending_tag_writes) |*candidate| {
        const pending = candidate.* orelse continue;
        if (pending.plan.id != plan_id or !pending.library.eql(library)) continue;
        pending.destroy(self.control_threaded.io());
        candidate.* = null;
        return;
    }
    return error.UnknownTagWritePlan;
}

pub fn tagWriteGenres(self: *OrcaRuntime, library: LibraryHandle, plan_id: u64, file_id: i64) !?TagWriteGenres {
    _ = try runtime.libraryDatabase(self, library);
    for (self.pending_tag_writes) |held| {
        const pending = held orelse continue;
        if (pending.plan.id != plan_id or !pending.library.eql(library)) continue;
        const index = std.mem.indexOfScalar(i64, pending.file_ids, file_id) orelse return null;
        return switch (pending.plan.actions[index]) {
            .write_tags => |write| write.genres,
            .move => null,
        };
    }
    return error.UnknownTagWritePlan;
}

pub fn undoTagWrite(self: *OrcaRuntime, library: LibraryHandle, io: std.Io, group_id: u64) !void {
    const library_database = try runtime.libraryDatabase(self, library);
    for (self.job_workers.items) |worker| {
        const pending = worker.tagWrite() orelse continue;
        if (!worker.retired and pending.plan.id == group_id) return error.TagWriteInProgress;
    }
    var lock = try metadata.JournalLock.acquireForMutation(io, library_database.journal_lock_path);
    const already_undone = undo: {
        defer lock.release(io);
        try library_database.recoverPendingMutations(io, &lock);
        var executor: metadata.executor.Executor = .{
            .allocator = self.allocator,
            .io = io,
            .journal = &library_database.mutation_journal,
            .journal_lock = &lock,
            .backup_directory = library_database.backup_directory,
        };
        executor.undoGroup(group_id) catch |err| switch (err) {
            error.MutationGroupAlreadyUndone => break :undo true,
            else => return err,
        };
        break :undo false;
    };
    const operations = try library_database.mutation_journal.groupOperationIds(self.allocator, group_id);
    defer self.allocator.free(operations);
    for (operations) |operation_id| {
        var operation = try library_database.mutation_journal.get(self.allocator, operation_id);
        defer operation.deinit();
        const location = try library_database.locations.presentByUri(self.allocator, operation.source_path) orelse continue;
        defer self.allocator.free(location.uri);
        try job_worker.reobserve(self.allocator, io, library_database, location);
    }
    if (already_undone) return error.MutationGroupAlreadyUndone;
}

pub fn pruneTagWriteBackups(self: *OrcaRuntime, library: LibraryHandle, io: std.Io, older_than_s: u64) !PruneSummary {
    const library_database = try runtime.libraryDatabase(self, library);
    var lock = try metadata.JournalLock.acquireForMutation(io, library_database.journal_lock_path);
    defer lock.release(io);
    try library_database.recoverPendingMutations(io, &lock);
    var executor: metadata.executor.Executor = .{
        .allocator = self.allocator,
        .io = io,
        .journal = &library_database.mutation_journal,
        .journal_lock = &lock,
        .backup_directory = library_database.backup_directory,
    };
    return executor.pruneBackups(older_than_s);
}
