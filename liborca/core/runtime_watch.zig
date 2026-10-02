const std = @import("std");
const database = @import("../database/root.zig");
const job = @import("job.zig");
const job_worker = @import("job_worker.zig");
const library_pass = @import("../library/root.zig");
const runtime = @import("runtime.zig");
const runtime_jobs = @import("runtime_jobs.zig");
const work = @import("work.zig");

const hints = library_pass.watch_hints;
const watch = library_pass.watch;

const JobHandle = runtime.JobHandle;
const JobWorker = job_worker.JobWorker;
const LibraryHandle = runtime.LibraryHandle;
const LibraryObject = runtime.LibraryObject;
const OrcaRuntime = runtime.OrcaRuntime;

pub const WatchOptions = struct {
    /// A root's changes are reconciled once it has been quiet this long.
    quiet_ms: u32 = 2000,
    /// ...or once this long has passed since its first unreconciled change.
    max_delay_ms: u32 = 30_000,
    /// How often a root the watch limit left partly unwatched is reconciled
    /// whole, and a root that is unavailable is tried again.
    degraded_rescan_ms: u32 = 15 * 60 * 1000,
};

pub const WatchState = enum {
    /// Not watched, or the watcher stopped on an error.
    off,
    watching,
    /// Watching, but a root is unavailable or the watch limit was reached.
    degraded,
    /// No watcher on this platform.
    unsupported,
};

pub const WatchStatus = struct {
    state: WatchState,
    roots_watched: u32 = 0,
    /// Roots that were deleted, moved or unmounted, are on another volume
    /// than the one recorded, or could not be watched. Each is tried again
    /// every `WatchOptions.degraded_rescan_ms`.
    roots_unavailable: u32 = 0,
    /// Roots the watch limit left partly unwatched. Each is reconciled whole
    /// every `WatchOptions.degraded_rescan_ms` while it stays so.
    roots_degraded: u32 = 0,
    directories_watched: u64 = 0,
    /// Some root is degraded: `fs.inotify.max_user_watches` was reached.
    watch_limit_reached: bool = false,
    /// Changes wait for a reconcile.
    reconcile_pending: bool = false,
    reconcile_running: bool = false,
};

const WatchedRoot = struct {
    id: i64,
    available: bool = true,
};

const PendingRoot = struct {
    root_id: i64,
    dirty: hints.DirtySet = .{},
};

const ActiveReconcile = struct {
    job: JobHandle,
    root_id: i64,
};

/// A root whose waiting changes a host's scan of the whole root took over.
const CoveredRoot = struct {
    job: JobHandle,
    root_id: i64,
};

/// A watched Library's watcher and the control lane's record of what it
/// reported. Control lane only.
pub const LibraryWatch = struct {
    library: LibraryHandle,
    watcher: *watch.Watcher,
    work_handle: work.WorkHandle,
    roots: std.ArrayList(WatchedRoot) = .empty,
    pending: std.ArrayList(PendingRoot) = .empty,
    covered: std.ArrayList(CoveredRoot) = .empty,
    active: ?ActiveReconcile = null,

    /// After the watcher's thread has been joined.
    fn destroy(self: *LibraryWatch, allocator: std.mem.Allocator) void {
        self.watcher.destroy();
        self.roots.deinit(allocator);
        for (self.pending.items) |*entry| entry.dirty.deinit(allocator);
        self.pending.deinit(allocator);
        self.covered.deinit(allocator);
        allocator.destroy(self);
    }

    fn root(self: *LibraryWatch, root_id: i64) ?*WatchedRoot {
        for (self.roots.items) |*candidate| if (candidate.id == root_id) return candidate;
        return null;
    }

    fn isAvailable(self: *LibraryWatch, root_id: i64) bool {
        const known = self.root(root_id) orelse return false;
        return known.available;
    }

    fn pendingFor(self: *LibraryWatch, allocator: std.mem.Allocator, root_id: i64) ?*hints.DirtySet {
        for (self.pending.items) |*entry| if (entry.root_id == root_id) return &entry.dirty;
        self.pending.append(allocator, .{ .root_id = root_id }) catch return null;
        return &self.pending.items[self.pending.items.len - 1].dirty;
    }

    fn requeue(self: *LibraryWatch, allocator: std.mem.Allocator, root_id: i64) void {
        if (!self.isAvailable(root_id)) return;
        const dirty = self.pendingFor(allocator, root_id) orelse return;
        dirty.markWholeRoot(allocator);
    }

    fn dropPending(self: *LibraryWatch, allocator: std.mem.Allocator, root_id: i64) void {
        for (self.pending.items, 0..) |*entry, index| {
            if (entry.root_id != root_id) continue;
            entry.dirty.deinit(allocator);
            _ = self.pending.orderedRemove(index);
            return;
        }
    }

    fn dropCovered(self: *LibraryWatch, root_id: i64) void {
        var index: usize = 0;
        while (index < self.covered.items.len) {
            if (self.covered.items[index].root_id == root_id) {
                _ = self.covered.orderedRemove(index);
            } else index += 1;
        }
    }

    /// A host job walking whole roots takes over their waiting changes. They
    /// come back as whole roots if it does not succeed.
    fn cover(self: *LibraryWatch, allocator: std.mem.Allocator, job_handle: JobHandle, root_id: ?i64) void {
        var index: usize = 0;
        while (index < self.pending.items.len) {
            const entry = &self.pending.items[index];
            if (root_id) |only| if (entry.root_id != only) {
                index += 1;
                continue;
            };
            self.covered.append(allocator, .{ .job = job_handle, .root_id = entry.root_id }) catch {
                index += 1;
                continue;
            };
            entry.dirty.deinit(allocator);
            _ = self.pending.orderedRemove(index);
        }
    }

    fn uncover(self: *LibraryWatch, allocator: std.mem.Allocator, job_handle: JobHandle, succeeded: bool) void {
        var index: usize = 0;
        while (index < self.covered.items.len) {
            const entry = self.covered.items[index];
            if (!entry.job.eql(job_handle)) {
                index += 1;
                continue;
            }
            _ = self.covered.orderedRemove(index);
            if (!succeeded) self.requeue(allocator, entry.root_id);
        }
    }
};

pub fn libraryWatch(self: *OrcaRuntime, library: LibraryHandle, options: WatchOptions) !void {
    try runtime.requireRunning(self);
    if (!watch.supported) return error.WatchingUnsupported;
    if (options.quiet_ms == 0 or options.max_delay_ms < options.quiet_ms or options.degraded_rescan_ms == 0)
        return error.InvalidWatchOptions;
    const object_value = try self.libraries.get(library);
    const library_database = object_value.database orelse return error.LibraryHasNoDatabase;
    if (object_value.watch) |existing| {
        if (!existing.watcher.status().stopped) return error.AlreadyWatching;
        stopWatch(self, object_value);
    }
    object_value.watch = try startWatch(self, library, library_database, options);
    object_value.watch_options = options;
}

pub fn libraryUnwatch(self: *OrcaRuntime, library: LibraryHandle) !void {
    try runtime.requireRunning(self);
    const object_value = try self.libraries.get(library);
    object_value.watch_options = null;
    stopWatch(self, object_value);
}

pub fn libraryWatchStatus(self: *OrcaRuntime, library: LibraryHandle) !WatchStatus {
    try runtime.requireRunning(self);
    const object_value = try self.libraries.get(library);
    if (!watch.supported) return .{ .state = .unsupported };
    const library_watch = object_value.watch orelse return .{ .state = .off };
    const status = library_watch.watcher.status();
    return .{
        .state = if (status.stopped)
            .off
        else if (status.watch_limit_reached or status.roots_unavailable != 0)
            .degraded
        else
            .watching,
        .roots_watched = status.roots_watched,
        .roots_unavailable = status.roots_unavailable,
        .roots_degraded = status.roots_degraded,
        .directories_watched = status.directories_watched,
        .watch_limit_reached = status.watch_limit_reached,
        .reconcile_pending = library_watch.pending.items.len != 0,
        .reconcile_running = library_watch.active != null,
    };
}

fn startWatch(
    self: *OrcaRuntime,
    library: LibraryHandle,
    library_database: *database.LibraryDatabase,
    options: WatchOptions,
) !*LibraryWatch {
    const allocator = self.allocator;
    var listed = try library_database.library_roots.list(allocator);
    defer listed.deinit();
    var keys: std.heap.ArenaAllocator = .init(allocator);
    defer keys.deinit();
    var roots: std.ArrayList(watch.Root) = .empty;
    defer roots.deinit(allocator);
    var watched: std.ArrayList(WatchedRoot) = .empty;
    errdefer watched.deinit(allocator);
    for (listed.items) |listed_root| {
        if (!listed_root.enabled) continue;
        try roots.append(allocator, .{
            .id = listed_root.id,
            .path = listed_root.path,
            .volume_key = try library_database.recordedVolumeKey(keys.allocator(), listed_root.volume_id),
        });
        try watched.append(allocator, .{ .id = listed_root.id });
    }

    const library_watch = try allocator.create(LibraryWatch);
    errdefer allocator.destroy(library_watch);
    const work_handle = try self.work_registry.begin(work.unowned);
    const registration = self.work_registry.registration(work_handle) catch unreachable;
    errdefer {
        registration.finish();
        self.work_registry.complete(work_handle) catch {};
    }
    const watcher = try watch.Watcher.create(
        allocator,
        registration,
        &self.host_signal,
        .{
            .quiet_ms = options.quiet_ms,
            .max_delay_ms = options.max_delay_ms,
            .degraded_rescan_ms = options.degraded_rescan_ms,
            .watch_limit = self.watch_limit,
        },
        watch.Ignore.forLibrary(library_database),
        roots.items,
    );
    errdefer watcher.destroy();
    registration.waker = watcher.waker();
    registration.thread = try std.Thread.spawn(.{}, watch.Watcher.run, .{watcher});
    library_watch.* = .{
        .library = library,
        .watcher = watcher,
        .work_handle = work_handle,
        .roots = watched,
    };
    return library_watch;
}

fn stopWatch(self: *OrcaRuntime, object_value: *LibraryObject) void {
    const library_watch = object_value.watch orelse return;
    object_value.watch = null;
    if (library_watch.active) |active| stopAutoReconcile(self, active.job);
    self.work_registry.complete(library_watch.work_handle) catch {};
    library_watch.destroy(self.allocator);
}

/// Rebuilds the watcher from the Library's roots when a command cannot be
/// queued to it; every root is armed again and so reconciled whole.
fn restartWatch(self: *OrcaRuntime, object_value: *LibraryObject) void {
    const library_watch = object_value.watch orelse return;
    const library = library_watch.library;
    stopWatch(self, object_value);
    const options = object_value.watch_options orelse return;
    const library_database = object_value.database orelse return;
    object_value.watch = startWatch(self, library, library_database, options) catch null;
}

/// Cancels and joins one automatic reconcile and records it without a
/// `job_finished` event: the host never started it.
fn stopAutoReconcile(self: *OrcaRuntime, job_handle: JobHandle) void {
    for (self.job_workers.items) |worker| {
        if (worker.retired or !worker.job.eql(job_handle)) continue;
        worker.token.cancel();
        self.work_registry.complete(worker.work_handle) catch {};
        runtime_jobs.finalizeJobWorker(self, worker, false);
        return;
    }
}

pub fn preemptAutoReconcile(self: *OrcaRuntime, library: LibraryHandle) void {
    const object_value = self.libraries.get(library) catch return;
    const library_watch = object_value.watch orelse return;
    const active = library_watch.active orelse return;
    stopAutoReconcile(self, active.job);
    library_watch.active = null;
}

pub fn hostJobStarted(self: *OrcaRuntime, library: LibraryHandle, job_handle: JobHandle, request: job_worker.Request) void {
    const object_value = self.libraries.get(library) catch return;
    const library_watch = object_value.watch orelse return;
    switch (request) {
        .scan => |scan| library_watch.cover(self.allocator, job_handle, scan.root_id),
        .reconcile => |pending| switch (pending.request.scope) {
            .whole_root => library_watch.cover(self.allocator, job_handle, pending.request.root_id),
            .subtrees => {},
        },
        else => {},
    }
}

/// Called for every job worker as it is finalized, on every path.
pub fn jobFinalized(self: *OrcaRuntime, worker: *JobWorker, state: job.State) void {
    if (worker.origin == .watcher and self.state.load(.acquire) == .running) {
        const stats = worker.scanStats();
        if (stats.changed + stats.marked_missing != 0) {
            self.telemetry.publish(.{ .library_changed = .{ .library = worker.library } }) catch {};
        }
    }
    const object_value = self.libraries.get(worker.library) catch return;
    const library_watch = object_value.watch orelse return;
    switch (worker.origin) {
        .watcher => {
            const active = library_watch.active orelse return;
            if (!active.job.eql(worker.job)) return;
            library_watch.active = null;
            if (worker.volume_changed.load(.acquire)) return rootOnOtherVolume(self, object_value, active.root_id);
            if (state == .cancelled) library_watch.requeue(self.allocator, active.root_id);
        },
        .host => library_watch.uncover(self.allocator, worker.job, state == .succeeded),
        .maintenance => {},
    }
}

fn rootOnOtherVolume(self: *OrcaRuntime, object_value: *LibraryObject, root_id: i64) void {
    const library_watch = object_value.watch orelse return;
    const known = library_watch.root(root_id) orelse return;
    known.available = false;
    library_watch.dropPending(self.allocator, root_id);
    library_watch.dropCovered(root_id);
    if (!library_watch.watcher.send(.{ .root_unavailable = root_id })) restartWatch(self, object_value);
}

pub fn rootAdded(self: *OrcaRuntime, library: LibraryHandle, binding: database.RootBinding, path: []const u8) void {
    const object_value = self.libraries.get(library) catch return;
    const library_watch = object_value.watch orelse return;
    const library_database = object_value.database orelse return;
    const root_id = binding.root_id;
    if (library_watch.root(root_id)) |known| {
        known.available = true;
    } else library_watch.roots.append(self.allocator, .{ .id = root_id }) catch {
        restartWatch(self, object_value);
        return;
    };
    const command = armCommand(self.allocator, library_database, binding, path) catch {
        restartWatch(self, object_value);
        return;
    };
    if (!library_watch.watcher.send(command)) {
        command.deinit(self.allocator);
        restartWatch(self, object_value);
    }
}

fn armCommand(
    allocator: std.mem.Allocator,
    library_database: *database.LibraryDatabase,
    binding: database.RootBinding,
    path: []const u8,
) !hints.Command {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    return .{ .arm_root = .{
        .root_id = binding.root_id,
        .path = owned_path,
        .volume_key = try library_database.recordedVolumeKey(allocator, binding.volume_id),
    } };
}

pub fn rootRemoved(self: *OrcaRuntime, library: LibraryHandle, root_id: i64) void {
    const object_value = self.libraries.get(library) catch return;
    const library_watch = object_value.watch orelse return;
    library_watch.dropPending(self.allocator, root_id);
    library_watch.dropCovered(root_id);
    for (library_watch.roots.items, 0..) |known, index| {
        if (known.id != root_id) continue;
        _ = library_watch.roots.orderedRemove(index);
        break;
    }
    if (!library_watch.watcher.send(.{ .disarm_root = root_id })) restartWatch(self, object_value);
}

/// Control lane, from `pump`: takes what each watcher published and starts
/// the next automatic reconcile of a Library that has none running and no
/// job that walks or writes it.
pub fn pumpWatchers(self: *OrcaRuntime) void {
    if (self.state.load(.acquire) != .running) return;
    for (self.libraries.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        const library_watch = object_value.watch orelse continue;
        takeHints(self, library_watch);
        startPendingReconcile(self, library_watch);
    }
}

fn takeHints(self: *OrcaRuntime, library_watch: *LibraryWatch) void {
    const allocator = self.allocator;
    while (library_watch.watcher.takeHint()) |hint| {
        switch (hint.reason) {
            .subtree, .whole_root => {
                const known = library_watch.root(hint.root_id) orelse {
                    if (hint.path) |path| allocator.free(path);
                    continue;
                };
                known.available = true;
                const dirty = library_watch.pendingFor(allocator, hint.root_id) orelse {
                    if (hint.path) |path| allocator.free(path);
                    continue;
                };
                if (hint.reason == .subtree) if (hint.path) |path| {
                    dirty.markDirectory(allocator, path);
                    continue;
                };
                dirty.markWholeRoot(allocator);
            },
            .root_unavailable => {
                const known = library_watch.root(hint.root_id) orelse continue;
                known.available = false;
                library_watch.dropPending(allocator, hint.root_id);
                library_watch.dropCovered(hint.root_id);
                if (library_watch.active) |active| {
                    if (active.root_id == hint.root_id) cancelAutoReconcile(self, active.job);
                }
            },
            .watch_limit => {},
        }
    }
}

fn cancelAutoReconcile(self: *OrcaRuntime, job_handle: JobHandle) void {
    for (self.job_workers.items) |worker| {
        if (worker.retired or !worker.job.eql(job_handle)) continue;
        worker.token.cancel();
        worker.registration.requestCancellation();
    }
}

fn conflictingJobRunning(self: *const OrcaRuntime, library: LibraryHandle) bool {
    for (self.job_workers.items) |worker| {
        if (worker.retired or !worker.library.eql(library)) continue;
        switch (worker.kind()) {
            .scan, .reconcile, .projection, .mutation => return true,
            else => {},
        }
    }
    return false;
}

fn startPendingReconcile(self: *OrcaRuntime, library_watch: *LibraryWatch) void {
    if (library_watch.active != null or library_watch.pending.items.len == 0) return;
    if (conflictingJobRunning(self, library_watch.library)) return;
    var next = library_watch.pending.orderedRemove(0);
    defer next.dirty.deinit(self.allocator);
    const pending = job_worker.PendingReconcile.create(self.allocator, .{
        .root_id = next.root_id,
        .scope = if (next.dirty.whole_root) .whole_root else .{ .subtrees = next.dirty.directories.items },
    }) catch return;
    const job_handle = runtime_jobs.spawnJobWorker(self, library_watch.library, .{ .reconcile = pending }, .watcher) catch {
        pending.destroy();
        return;
    };
    library_watch.active = .{ .job = job_handle, .root_id = next.root_id };
}

/// Zero while a watcher's hints wait to be taken, or while a Library's
/// waiting changes could start a reconcile now; null otherwise. A reconcile
/// held back by a running job is covered by that job's own pump timeout.
pub fn watchPumpDueMs(self: *OrcaRuntime) ?u64 {
    for (self.libraries.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        const library_watch = object_value.watch orelse continue;
        if (library_watch.watcher.hintsQueued()) return 0;
        if (library_watch.active == null and library_watch.pending.items.len != 0 and
            !conflictingJobRunning(self, library_watch.library)) return 0;
    }
    return null;
}

/// Control lane, immediately after `work_registry.drain()`: every watcher
/// thread has been joined and its registration freed.
pub fn releaseDrainedWatchers(self: *OrcaRuntime) void {
    for (self.libraries.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        const library_watch = object_value.watch orelse continue;
        object_value.watch = null;
        library_watch.destroy(self.allocator);
    }
}

/// Starts a watcher again for every Library still meant to be watched,
/// after a drain that joined them all. Arming reconciles each root whole,
/// which catches up on anything that changed while nothing watched.
pub fn rearmWatchers(self: *OrcaRuntime) void {
    if (self.state.load(.acquire) != .running) return;
    for (self.libraries.slots.items, 0..) |*slot, index| {
        const object_value = if (slot.value) |*value| value else continue;
        const options = object_value.watch_options orelse continue;
        if (object_value.watch != null) continue;
        const library_database = object_value.database orelse continue;
        const library: LibraryHandle = .{ .index = @intCast(index), .generation = slot.generation };
        object_value.watch = startWatch(self, library, library_database, options) catch null;
    }
}
