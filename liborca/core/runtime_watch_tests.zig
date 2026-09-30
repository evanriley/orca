const std = @import("std");
const builtin = @import("builtin");
const database = @import("../database/root.zig");
const job = @import("job.zig");
const job_worker = @import("job_worker.zig");
const runtime_module = @import("runtime.zig");
const runtime_tests = @import("runtime_tests.zig");

const JobHandle = runtime_module.JobHandle;
const LibraryHandle = runtime_module.LibraryHandle;
const OrcaRuntime = runtime_module.OrcaRuntime;
const ScanStats = runtime_module.ScanStats;
const TestDeadline = runtime_tests.TestDeadline;
const WatchOptions = runtime_module.WatchOptions;
const awaitJob = runtime_tests.awaitJob;
const copyFixtureInto = runtime_tests.copyFixtureInto;
const libraryDatabase = runtime_module.libraryDatabase;

const io = std.testing.io;
const fast: WatchOptions = .{ .quiet_ms = 50, .max_delay_ms = 1000 };

const Finished = struct {
    job: JobHandle,
    root_id: i64,
    state: job.State,
    stats: ScanStats,
};

/// A watched Library over a temporary root holding `A/one.flac`, scanned in
/// full and past the reconcile that arming the root starts.
const WatchFixture = struct {
    temporary: std.testing.TmpDir,
    data: std.testing.TmpDir,
    runtime: OrcaRuntime,
    root: []u8,
    library: LibraryHandle,
    root_id: i64,
    library_changed: u32,

    const Database = union(enum) {
        memory: [:0]const u8,
        /// A file named `library.db` in its own temporary directory.
        file_outside_root,
        /// A file named `library.db` at the top of the root.
        file_inside_root,
    };

    fn init(self: *WatchFixture, location: Database, options: WatchOptions) !void {
        self.temporary = std.testing.tmpDir(.{});
        errdefer self.temporary.cleanup();
        self.data = std.testing.tmpDir(.{});
        errdefer self.data.cleanup();
        self.library_changed = 0;
        try self.temporary.dir.createDirPath(io, "A");
        try copyFixtureInto(self.temporary.dir, "fixtures/audio/tagged-reference.flac", "A/one.flac");
        self.root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{self.temporary.sub_path});
        errdefer std.testing.allocator.free(self.root);
        const database_path = switch (location) {
            .memory => |name| try std.testing.allocator.dupeZ(u8, name),
            .file_outside_root => try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/library.db", .{self.data.sub_path}, 0),
            .file_inside_root => try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/library.db", .{self.root}, 0),
        };
        defer std.testing.allocator.free(database_path);
        self.runtime = OrcaRuntime.init(std.testing.allocator);
        errdefer self.runtime.deinit();
        self.library = try self.runtime.openLibrary(io, database_path);
        self.root_id = (try self.runtime.libraryAddRoot(self.library, io, self.root)).root_id;
        try std.testing.expectEqual(job.State.succeeded, try awaitJob(&self.runtime, try self.runtime.startLibraryScan(self.library, .{ .root_id = self.root_id })));
        try self.runtime.libraryWatch(self.library, options);
        const armed = try self.awaitReconcile();
        try std.testing.expectEqual(job.State.succeeded, armed.state);
        try std.testing.expectEqual(@as(u64, 0), armed.stats.changed + armed.stats.marked_missing);
        self.library_changed = 0;
    }

    fn deinit(self: *WatchFixture) void {
        self.runtime.deinit();
        std.testing.allocator.free(self.root);
        self.data.cleanup();
        self.temporary.cleanup();
    }

    fn isAutomatic(self: *WatchFixture, job_handle: JobHandle) bool {
        for (self.runtime.job_workers.items) |worker| {
            if (worker.job.eql(job_handle)) return worker.origin == .watcher;
        }
        return false;
    }

    fn pumpOnce(self: *WatchFixture) !?Finished {
        self.runtime.pump();
        var finished: ?Finished = null;
        while (self.runtime.pollEvent()) |event| switch (event.outcome) {
            .job_finished => |value| {
                if (!self.isAutomatic(value.job)) continue;
                finished = .{
                    .job = value.job,
                    .root_id = (try self.runtime.jobReconcileRoot(value.job)).?,
                    .state = value.state,
                    .stats = try self.runtime.jobScanStats(value.job),
                };
            },
            else => {},
        };
        while (self.runtime.pollTelemetry()) |telemetry| switch (telemetry) {
            .library_changed => |changed| {
                try std.testing.expect(changed.library.eql(self.library));
                self.library_changed += 1;
            },
            else => {},
        };
        return finished;
    }

    fn awaitReconcile(self: *WatchFixture) !Finished {
        var deadline: TestDeadline = .init(10_000);
        while (deadline.tick()) if (try self.pumpOnce()) |finished| return finished;
        return error.NoReconcile;
    }

    fn awaitLocation(self: *WatchFixture, relative: []const u8, state: database.LocationState) !Finished {
        for (0..8) |_| {
            const finished = try self.awaitReconcile();
            try std.testing.expectEqual(job.State.succeeded, finished.state);
            if (try self.locationState(relative) == state) return finished;
        }
        return error.LocationNeverReached;
    }

    fn expectNoReconcile(self: *WatchFixture, milliseconds: u64) !void {
        var deadline: TestDeadline = .init(milliseconds);
        while (deadline.tick()) if (try self.pumpOnce()) |_| return error.UnexpectedReconcile;
        try std.testing.expect(!(try self.runtime.libraryWatchStatus(self.library)).reconcile_running);
    }

    fn awaitStatus(self: *WatchFixture, comptime field: []const u8, value: anytype) !runtime_module.WatchStatus {
        var deadline: TestDeadline = .init(5_000);
        while (deadline.tick()) {
            _ = try self.pumpOnce();
            const status = try self.runtime.libraryWatchStatus(self.library);
            if (@field(status, field) == value) return status;
        }
        return error.StatusNeverReached;
    }

    fn runningAutomatic(self: *WatchFixture) !*const job_worker.JobWorker {
        for (self.runtime.job_workers.items) |worker| {
            if (!worker.retired and worker.origin == .watcher) return worker;
        }
        return error.NoAutomaticReconcile;
    }

    fn locationState(self: *WatchFixture, relative: []const u8) !?database.LocationState {
        const uri = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ self.root, relative });
        defer std.testing.allocator.free(uri);
        const library_database = try libraryDatabase(&self.runtime, self.library);
        var statement = try library_database.database.prepare("SELECT state FROM locations WHERE uri=?1;");
        defer statement.deinit();
        try statement.bindText(1, uri);
        if (try statement.step() != .row) return null;
        return database.LocationState.parse(statement.columnText(0)).?;
    }

    /// Holds the Library's write lane until the running automatic reconcile
    /// has been asked to cancel, so a test can act while it is certainly
    /// still running.
    fn holdReconcile(self: *WatchFixture) !Holder {
        const lane = (try libraryDatabase(&self.runtime, self.library)).write_lane;
        lane.acquire();
        errdefer lane.release();
        _ = try self.awaitStatus("reconcile_running", true);
        const automatic = try self.runningAutomatic();
        return .{
            .job = automatic.job,
            .thread = try std.Thread.spawn(.{}, Holder.releaseOnCancel, .{ lane, &automatic.token.requested }),
        };
    }
};

const Holder = struct {
    job: JobHandle,
    thread: std.Thread,

    fn releaseOnCancel(lane: *database.repository.WriteLane, token: *const std.atomic.Value(bool)) void {
        while (!token.load(.acquire)) std.Thread.yield() catch {};
        lane.release();
    }
};

test "a file created in a nested directory of a watched root is recorded and library_changed is published" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.{ .memory = "file:orca-watch-created?mode=memory&cache=shared" }, fast);
    defer fixture.deinit();

    try fixture.temporary.dir.createDirPath(io, "A/New/Disc 1");
    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "A/New/Disc 1/two.m4a");
    const finished = try fixture.awaitLocation("A/New/Disc 1/two.m4a", .present);
    try std.testing.expectEqual(fixture.root_id, finished.root_id);
    try std.testing.expectEqual(@as(u64, 1), finished.stats.changed);
    try std.testing.expectEqual(@as(u32, 1), fixture.library_changed);
    try std.testing.expectEqual(@as(u64, 2), try fixture.runtime.libraryTrackCount(fixture.library));
}

test "a deleted file under a watched root is marked missing" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.{ .memory = "file:orca-watch-deleted?mode=memory&cache=shared" }, fast);
    defer fixture.deinit();

    try fixture.temporary.dir.deleteFile(io, "A/one.flac");
    const finished = try fixture.awaitLocation("A/one.flac", .missing);
    try std.testing.expectEqual(@as(u64, 1), finished.stats.marked_missing);
    try std.testing.expectEqual(@as(u32, 1), fixture.library_changed);
}

test "a directory created and at once populated is recorded, and so is a file added to it later" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.{ .memory = "file:orca-watch-populated?mode=memory&cache=shared" }, fast);
    defer fixture.deinit();

    try fixture.temporary.dir.createDirPath(io, "B/C");
    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "B/C/two.m4a");
    _ = try fixture.awaitLocation("B/C/two.m4a", .present);
    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference.ogg", "B/C/three.ogg");
    _ = try fixture.awaitLocation("B/C/three.ogg", .present);
}

test "shutdown joins a watching library's watcher" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.{ .memory = "file:orca-watch-shutdown?mode=memory&cache=shared" }, fast);
    defer fixture.deinit();
    fixture.runtime.shutdown();
    try std.testing.expectEqual(@as(usize, 0), fixture.runtime.work_registry.count());
}

test "shutdown joins an automatic reconcile that is still running" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.{ .memory = "file:orca-watch-shutdown-running?mode=memory&cache=shared" }, fast);
    defer fixture.deinit();

    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "A/two.m4a");
    const holder = try fixture.holdReconcile();
    fixture.runtime.shutdown();
    holder.thread.join();
    try std.testing.expectEqual(@as(usize, 0), fixture.runtime.work_registry.count());
}

test "destroying another library leaves a watched library watching" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.{ .memory = "file:orca-watch-destroy-other?mode=memory&cache=shared" }, fast);
    defer fixture.deinit();

    const other = try fixture.runtime.openLibrary(io, "file:orca-watch-destroy-other-b?mode=memory&cache=shared");
    try fixture.runtime.destroyLibrary(other);
    const rearmed = try fixture.awaitReconcile();
    try std.testing.expectEqual(@as(u64, 1), rearmed.stats.files_seen);
    try std.testing.expectEqual(runtime_module.WatchState.watching, (try fixture.runtime.libraryWatchStatus(fixture.library)).state);

    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "A/two.m4a");
    _ = try fixture.awaitLocation("A/two.m4a", .present);
}

test "destroying a watched library joins its watcher" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.{ .memory = "file:orca-watch-destroy-self?mode=memory&cache=shared" }, fast);
    defer fixture.deinit();
    try fixture.runtime.destroyLibrary(fixture.library);
    try std.testing.expectEqual(@as(usize, 0), fixture.runtime.work_registry.count());
}

test "a root removed while watched is forgotten and stops producing reconciles" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.{ .memory = "file:orca-watch-remove-root?mode=memory&cache=shared" }, fast);
    defer fixture.deinit();

    const removed = try fixture.runtime.libraryRemoveRoot(fixture.library, fixture.root_id);
    try std.testing.expectEqual(@as(u64, 1), removed.files_forgotten);
    _ = try fixture.awaitStatus("roots_watched", @as(u32, 0));
    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "A/two.m4a");
    try fixture.expectNoReconcile(300);
    try std.testing.expectEqual(@as(u64, 0), (try fixture.runtime.libraryWatchStatus(fixture.library)).directories_watched);
}

test "a root removed while its automatic reconcile runs is removed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.{ .memory = "file:orca-watch-remove-running?mode=memory&cache=shared" }, fast);
    defer fixture.deinit();

    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "A/two.m4a");
    const holder = try fixture.holdReconcile();
    _ = try fixture.runtime.libraryRemoveRoot(fixture.library, fixture.root_id);
    holder.thread.join();
    try fixture.expectNoReconcile(300);
    const status = try fixture.runtime.libraryWatchStatus(fixture.library);
    try std.testing.expect(!status.reconcile_pending);
}

test "a host scan pre-empts a running automatic reconcile and takes over its root" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.{ .memory = "file:orca-watch-preempt-scan?mode=memory&cache=shared" }, fast);
    defer fixture.deinit();

    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "A/two.m4a");
    const holder = try fixture.holdReconcile();
    const automatic = holder.job;
    const scan = fixture.runtime.startLibraryScan(fixture.library, .{ .root_id = fixture.root_id });
    holder.thread.join();
    const scan_job = try scan;
    try std.testing.expectEqual(job.State.cancelled, (try fixture.runtime.jobSnapshotSynced(automatic)).state);
    const status = try fixture.runtime.libraryWatchStatus(fixture.library);
    try std.testing.expect(!status.reconcile_running);
    try std.testing.expect(!status.reconcile_pending);

    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&fixture.runtime, scan_job));
    while (fixture.runtime.pollEvent()) |event| switch (event.outcome) {
        .job_finished => |value| try std.testing.expect(!value.job.eql(automatic)),
        else => {},
    };
    try std.testing.expectEqual(database.LocationState.present, (try fixture.locationState("A/two.m4a")).?);
    try fixture.expectNoReconcile(300);
}

test "a host reconcile of other directories pre-empts an automatic reconcile, whose root is reconciled afterwards" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.{ .memory = "file:orca-watch-preempt-reconcile?mode=memory&cache=shared" }, fast);
    defer fixture.deinit();

    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "A/two.m4a");
    const holder = try fixture.holdReconcile();
    const reconcile = fixture.runtime.startLibraryReconcile(fixture.library, .{
        .root_id = fixture.root_id,
        .scope = .{ .subtrees = &.{"Elsewhere"} },
    });
    holder.thread.join();
    const reconcile_job = try reconcile;
    try std.testing.expect((try fixture.runtime.libraryWatchStatus(fixture.library)).reconcile_pending);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&fixture.runtime, reconcile_job));

    const resumed = try fixture.awaitReconcile();
    try std.testing.expectEqual(job.State.succeeded, resumed.state);
    try std.testing.expectEqual(@as(u64, 2), resumed.stats.files_seen);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.locationState("A/two.m4a")).?);
}

test "unwatching joins the watcher and a running automatic reconcile, and nothing is reconciled afterwards" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.{ .memory = "file:orca-watch-unwatch?mode=memory&cache=shared" }, fast);
    defer fixture.deinit();
    try std.testing.expectError(error.AlreadyWatching, fixture.runtime.libraryWatch(fixture.library, fast));

    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "A/two.m4a");
    const holder = try fixture.holdReconcile();
    const unwatched = fixture.runtime.libraryUnwatch(fixture.library);
    holder.thread.join();
    try unwatched;
    try std.testing.expectEqual(@as(usize, 0), fixture.runtime.work_registry.count());
    try std.testing.expectEqual(runtime_module.WatchState.off, (try fixture.runtime.libraryWatchStatus(fixture.library)).state);
    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference.ogg", "A/three.ogg");
    try fixture.expectNoReconcile(300);
}

test "the database's own files inside a watched root, and Orca's temporaries, cause no reconcile" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.file_inside_root, fast);
    defer fixture.deinit();

    const ids = try runtime_tests.allTrackIds(&fixture.runtime, fixture.library);
    defer std.testing.allocator.free(ids);
    (try fixture.runtime.libraryEditTracks(fixture.library, ids, &.{.{ .field = .album, .value = "Edited" }})).deinit();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "A/.one.flac.orca-stage-9-0", .data = "fLaC" });
    try fixture.temporary.dir.createDirPath(io, "library.db.orca-backups/9");
    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference.flac", "library.db.orca-backups/9/one.flac");
    try fixture.expectNoReconcile(300);

    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "A/two.m4a");
    const finished = try fixture.awaitLocation("A/two.m4a", .present);
    try std.testing.expectEqual(@as(u64, 1), finished.stats.changed);
}

test "a tag write under a watched root causes one reconcile, which changes nothing" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.file_outside_root, fast);
    defer fixture.deinit();

    const ids = try runtime_tests.allTrackIds(&fixture.runtime, fixture.library);
    defer std.testing.allocator.free(ids);
    const edited = try fixture.runtime.libraryEditTracks(fixture.library, ids, &.{.{ .field = .album, .value = "Written" }});
    defer edited.deinit();
    const plan = try fixture.runtime.planTagWrite(fixture.library, io, edited.ids);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.files.len);
    const write = try fixture.runtime.startTagWrite(fixture.library, plan.plan_id, plan.digest);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&fixture.runtime, write));

    var reconciles: u32 = 0;
    var deadline: TestDeadline = .init(1_000);
    while (deadline.tick()) {
        const finished = try fixture.pumpOnce() orelse continue;
        reconciles += 1;
        try std.testing.expectEqual(@as(u64, 0), finished.stats.changed + finished.stats.marked_missing);
    }
    try std.testing.expectEqual(@as(u32, 1), reconciles);
    try std.testing.expectEqual(@as(u32, 0), fixture.library_changed);
}

test "more changed directories than a root holds apart are reconciled as the whole root, once" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.{ .memory = "file:orca-watch-collapse?mode=memory&cache=shared" }, .{ .quiet_ms = 300, .max_delay_ms = 5_000 });
    defer fixture.deinit();

    var name: [16]u8 = undefined;
    for (0..70) |index| try fixture.temporary.dir.createDirPath(io, try std.fmt.bufPrint(&name, "D{d}", .{index}));
    const finished = try fixture.awaitReconcile();
    try std.testing.expectEqual(@as(u64, 1), finished.stats.files_seen);
    try fixture.expectNoReconcile(700);
}

test "a watched root that disappears is reported and never swept" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: WatchFixture = undefined;
    try fixture.init(.{ .memory = "file:orca-watch-root-gone?mode=memory&cache=shared" }, fast);
    defer fixture.deinit();

    const moved = try std.fmt.allocPrint(std.testing.allocator, "{s}-moved", .{fixture.root});
    defer std.testing.allocator.free(moved);
    try std.Io.Dir.rename(std.Io.Dir.cwd(), fixture.root, std.Io.Dir.cwd(), moved, io);
    defer std.Io.Dir.rename(std.Io.Dir.cwd(), moved, std.Io.Dir.cwd(), fixture.root, io) catch {};
    const status = try fixture.awaitStatus("roots_unavailable", @as(u32, 1));
    try std.testing.expectEqual(runtime_module.WatchState.degraded, status.state);
    try fixture.expectNoReconcile(300);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.locationState("A/one.flac")).?);
}

test "watching is refused where there is no watcher" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(io, "file:orca-watch-unsupported?mode=memory&cache=shared");
    try std.testing.expectError(error.WatchingUnsupported, runtime.libraryWatch(library, .{}));
    try std.testing.expectEqual(runtime_module.WatchState.unsupported, (try runtime.libraryWatchStatus(library)).state);
}
