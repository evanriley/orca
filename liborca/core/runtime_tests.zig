const std = @import("std");
const builtin = @import("builtin");
const analysis_service = @import("../analysis/service.zig");
const artwork = @import("artwork.zig");
const audio = @import("../audio/root.zig");
const control = @import("control.zig");
const database = @import("../database/root.zig");
const library_pass = @import("../library/root.zig");
const job = @import("job.zig");
const object = @import("object.zig");
const storage = @import("../storage/root.zig");
const work = @import("work.zig");
const runtime_module = @import("runtime.zig");
const runtime_zones = @import("runtime_zones.zig");
const runtime_queue = @import("runtime_queue.zig");

const ArtworkResult = runtime_module.ArtworkResult;
const JobHandle = runtime_module.JobHandle;
const LibraryHandle = runtime_module.LibraryHandle;
const OrcaRuntime = runtime_module.OrcaRuntime;
const State = runtime_module.State;
const TagWriteSkipReason = runtime_module.TagWriteSkipReason;
const TrackDetails = runtime_module.TrackDetails;
const WorkHandle = runtime_module.WorkHandle;
const ZoneHandle = runtime_module.ZoneHandle;
const libraryDatabase = runtime_module.libraryDatabase;

fn markZoneOutputLost(self: *OrcaRuntime, zone: ZoneHandle) !void {
    try runtime_module.requireRunning(self);
    const object_value = try self.zones.get(zone);
    try runtime_zones.requireZoneIdle(self, object_value);
    object_value.zone.zone.deviceLost();
    object_value.zone.publishState();
}

fn beginZoneRecovery(self: *OrcaRuntime, zone: ZoneHandle) !void {
    try runtime_module.requireRunning(self);
    const object_value = try self.zones.get(zone);
    try runtime_zones.requireZoneIdle(self, object_value);
    object_value.zone.zone.beginRecovery();
    object_value.zone.publishState();
}

fn failZoneRecovery(self: *OrcaRuntime, zone: ZoneHandle) !void {
    try runtime_module.requireRunning(self);
    const object_value = try self.zones.get(zone);
    try runtime_zones.requireZoneIdle(self, object_value);
    object_value.zone.zone.recoveryFailed();
    object_value.zone.publishState();
}

/// Stands in for the executors later phases will add: it registers work and
/// starts a real worker thread that observes cancellation, so shutdown and
/// destroy paths are exercised against a live worker rather than a bare
/// handle. The worker only ever touches its own `work.Registration`.
fn startDummyWork(self: *OrcaRuntime) !WorkHandle {
    try runtime_module.requireRunning(self);
    const work_handle = try self.work_registry.begin(work.unowned);
    const registration = self.work_registry.registration(work_handle) catch unreachable;
    registration.thread = std.Thread.spawn(
        .{},
        dummyWorker,
        .{registration},
    ) catch |err| {
        registration.finish();
        self.work_registry.complete(work_handle) catch {};
        return err;
    };
    return work_handle;
}

fn dummyWorker(registration: *work.Registration) void {
    while (!registration.cancellationRequested()) std.Thread.yield() catch {};
    registration.finish();
}

fn completeDummyWork(self: *OrcaRuntime, work_handle: WorkHandle) !void {
    try runtime_module.requireRunning(self);
    try self.work_registry.complete(work_handle);
}

pub fn inFlightWorkCount(self: *const OrcaRuntime) usize {
    return self.work_registry.count();
}

test "a scan runs on a registered worker and honors cancellation" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-scan-job-cancel?mode=memory&cache=shared",
    );
    const binding = try runtime.libraryAddRoot(library, std.testing.io, "fixtures/audio");
    const job_handle = try runtime.startLibraryScan(library, .{ .root_id = binding.root_id });
    try runtime.cancelJob(job_handle);

    while (true) {
        runtime.reapFinishedJobs();
        const snapshot = try runtime.jobSnapshotSynced(job_handle);
        switch (snapshot.state) {
            .cancelled, .succeeded, .failed => break,
            else => std.Thread.yield() catch {},
        }
    }
    // The finish notification travels the lossless completion lane, not the
    // coalescing telemetry one.
    var finished = false;
    while (runtime.pollEvent()) |event| switch (event.outcome) {
        .job_finished => |value| finished = finished or value.job.eql(job_handle),
        else => {},
    };
    try std.testing.expect(finished);
    try std.testing.expectEqual(@as(usize, 0), inFlightWorkCount(&runtime));
}

test "shutdown joins a scan worker that is still walking" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-scan-job-shutdown?mode=memory&cache=shared",
    );
    const binding = try runtime.libraryAddRoot(library, std.testing.io, "fixtures/audio");
    const job_handle = try runtime.startLibraryScan(library, .{ .root_id = binding.root_id });
    // No wait: shutdown must cancel the worker's token, join its thread, and
    // only then close the database the worker is writing to.
    runtime.shutdown();
    try std.testing.expectEqual(@as(usize, 0), inFlightWorkCount(&runtime));
    try std.testing.expectError(error.StaleHandle, runtime.jobSnapshotSynced(job_handle));
}

test "a completed scan projects what it observed" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-scan-job-project?mode=memory&cache=shared",
    );
    const binding = try runtime.libraryAddRoot(library, std.testing.io, "fixtures/audio");
    const job_handle = try runtime.startLibraryScan(library, .{ .root_id = binding.root_id });
    while (true) {
        runtime.reapFinishedJobs();
        const snapshot = try runtime.jobSnapshotSynced(job_handle);
        if (snapshot.state == .succeeded) break;
        if (snapshot.state == .failed or snapshot.state == .cancelled)
            return error.ScanDidNotSucceed;
        std.Thread.yield() catch {};
    }
    const stats = try runtime.jobScanStats(job_handle);
    try std.testing.expect(stats.files_seen > 0);
    try std.testing.expect(stats.changed > 0);
    // A scan whose results are never projected has not made a library
    // browsable, which is why the projection runs inside the scan job.
    try std.testing.expect(stats.tracks_written > 0);
    try std.testing.expect(try runtime.libraryTrackCount(library) > 0);
}

/// Scans `fixtures/audio` to completion and returns the details of the Track
/// whose file is named `file_name`.
fn scannedFixtureDetails(
    runtime: *OrcaRuntime,
    library: LibraryHandle,
    file_name: []const u8,
) !TrackDetails {
    var page = try runtime.libraryTrackQuery(library, "", .{ .limit = database.repository.max_page });
    defer page.deinit();
    for (page.items) |item| {
        const details = (try runtime.libraryTrackDetails(library, item.id)).?;
        if (details.path) |path| if (std.mem.endsWith(u8, path, file_name)) return details;
        details.deinit();
    }
    return error.FixtureNotScanned;
}

fn scanFixtureLibrary(runtime: *OrcaRuntime, uri: [:0]const u8) !LibraryHandle {
    const library = try runtime.openLibrary(std.testing.io, uri);
    const binding = try runtime.libraryAddRoot(library, std.testing.io, "fixtures/audio");
    const job_handle = try runtime.startLibraryScan(library, .{ .root_id = binding.root_id });
    while (true) {
        runtime.reapFinishedJobs();
        const snapshot = try runtime.jobSnapshotSynced(job_handle);
        if (snapshot.state == .succeeded) return library;
        if (snapshot.state == .failed or snapshot.state == .cancelled)
            return error.ScanDidNotSucceed;
        std.Thread.yield() catch {};
    }
}

test "a scanned track's details match the format of its file" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scanFixtureLibrary(&runtime, "file:orca-track-details-scan?mode=memory&cache=shared");

    const flac = try scannedFixtureDetails(&runtime, library, "covered-reference.flac");
    defer flac.deinit();
    try std.testing.expectEqualStrings("flac", flac.codec);
    try std.testing.expect(!flac.lossy);
    try std.testing.expectEqual(@as(?u32, 48_000), flac.sample_rate);
    try std.testing.expectEqual(@as(?u32, 16), flac.bit_depth);
    try std.testing.expectEqual(@as(?u32, 2), flac.channels);
    try std.testing.expectEqual(@as(?i64, 9_483), flac.size_bytes);
    try std.testing.expectEqual(@as(?i64, 10), flac.duration_ms);
    try std.testing.expectEqual(@as(?u32, 7_586), flac.bitrate_kbps);
    try std.testing.expect(flac.has_artwork);
    try std.testing.expect(!flac.file_missing);
    try std.testing.expect(flac.loudness == null);

    const mp3 = try scannedFixtureDetails(&runtime, library, "covered-reference.mp3");
    defer mp3.deinit();
    try std.testing.expectEqualStrings("mp3", mp3.codec);
    try std.testing.expect(mp3.lossy);
    try std.testing.expectEqual(@as(?u32, 44_100), mp3.sample_rate);
    try std.testing.expectEqual(@as(?u32, null), mp3.bit_depth);
    try std.testing.expectEqual(@as(?u32, 2), mp3.channels);
}

test "a scanned track's details carry its tags and its release's date" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scanFixtureLibrary(&runtime, "file:orca-track-details-tags?mode=memory&cache=shared");

    const aac = try scannedFixtureDetails(&runtime, library, "tagged-reference-aac.m4a");
    defer aac.deinit();
    try std.testing.expectEqualStrings("AAC Reference", aac.title);
    try std.testing.expectEqualStrings("Orca Fixtures", aac.artist);
    try std.testing.expectEqualStrings("Codec References", aac.album);
    try std.testing.expectEqualStrings("Orca Fixtures", aac.album_artist);
    try std.testing.expectEqualStrings("2026", aac.date.?);
    try std.testing.expectEqual(@as(?i64, 2), aac.track_number);
    try std.testing.expectEqual(@as(?i64, 1), aac.disc_number);
    try std.testing.expectEqual(@as(?bool, false), aac.compilation);
    try std.testing.expect(aac.lossy);
    try std.testing.expect(!aac.has_artwork);
}

test "details of a track that does not exist are null" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-track-details-none?mode=memory&cache=shared",
    );
    try std.testing.expect((try runtime.libraryTrackDetails(library, 1)) == null);
}

test "details report a track whose file has gone as missing, without a path" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-track-details-missing?mode=memory&cache=shared",
    );
    const library_database = try libraryDatabase(&runtime, library);
    const volume_id = try library_database.volumes.ensure(.{ .stable_key = "uuid:details", .label = "Details" });
    const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 0 });
    _ = try library_database.locations.upsert(.{
        .file_id = file_id,
        .volume_id = volume_id,
        .uri = "fixtures/audio/gone.flac",
        .state = .missing,
    });
    try library_database.tracks.upsertTracks(&.{.{ .title = "Gone", .preferred_file_id = file_id }});
    var page = try library_database.tracks.page(std.testing.allocator, .{ .limit = 1, .offset = 0 });
    defer page.deinit();

    const details = (try runtime.libraryTrackDetails(library, page.items[0].id)).?;
    defer details.deinit();
    try std.testing.expectEqualStrings("Gone", details.title);
    try std.testing.expect(details.file_missing);
    try std.testing.expect(details.path == null);
    try std.testing.expect(details.size_bytes == null);
    try std.testing.expect(details.bitrate_kbps == null);
    try std.testing.expect(details.duration_ms == null);
}

test "details carry the loudness stored for the file's recorded bytes and no other" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scanFixtureLibrary(&runtime, "file:orca-track-details-loudness?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);

    const before = try scannedFixtureDetails(&runtime, library, "covered-reference.flac");
    defer before.deinit();
    try std.testing.expect(before.loudness == null);

    const analysis = @import("../analysis/root.zig");
    const result: analysis.diagnostics.Result = .{
        .allocator = std.testing.allocator,
        .integrated_lufs = -9.1,
        .replay_gain_db = -8.9,
        .sample_peak = 0.966,
        .rms = 0.1,
        .clipped_samples = 0,
        .silent_frames = 0,
        .leading_silence_frames = 0,
        .trailing_silence_frames = 0,
        .waveform = &.{},
    };
    const encoded = try analysis.encoding.encode(std.testing.allocator, result);
    defer std.testing.allocator.free(encoded);

    const facts = (try library_database.tracks.fileFacts(std.testing.allocator, before.track_id)).?;
    defer facts.deinit();
    try library_database.analysis_cache.put(
        analysis_service.diagnosticsKey(facts.file_id, facts.quick_hash.?, .{}),
        encoded,
    );

    const mp3 = try scannedFixtureDetails(&runtime, library, "covered-reference.mp3");
    defer mp3.deinit();
    const mp3_facts = (try library_database.tracks.fileFacts(std.testing.allocator, mp3.track_id)).?;
    defer mp3_facts.deinit();
    const stale_identity: storage.quick_hash.Digest = @splat(7);
    try library_database.analysis_cache.put(
        analysis_service.diagnosticsKey(mp3_facts.file_id, stale_identity, .{}),
        encoded,
    );

    const after = try scannedFixtureDetails(&runtime, library, "covered-reference.flac");
    defer after.deinit();
    const loudness = after.loudness.?;
    try std.testing.expectApproxEqAbs(@as(f32, -9.1), loudness.integrated_lufs, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -8.9), loudness.replay_gain_db, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.966), loudness.sample_peak, 0.0001);

    const stale = try scannedFixtureDetails(&runtime, library, "covered-reference.mp3");
    defer stale.deinit();
    try std.testing.expect(stale.loudness == null);
}

test "runtime can repeatedly start and stop without leaking" {
    for (0..100) |_| {
        var runtime = OrcaRuntime.init(std.testing.allocator);
        _ = try runtime.createLibrary();
        _ = try runtime.createPlayer();
        _ = try runtime.createZone();
        _ = try startDummyWork(&runtime);
        runtime.shutdown();
        runtime.shutdown();
        try std.testing.expectEqual(State.stopped, runtime.state.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), inFlightWorkCount(&runtime));
        runtime.deinit();
    }
}

test "shutdown invalidates objects and rejects new work" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    const player = try runtime.createPlayer();
    const dummy_work = try startDummyWork(&runtime);
    runtime.shutdown();

    try std.testing.expectError(error.RuntimeNotRunning, runtime.createPlayer());
    try std.testing.expectError(error.RuntimeNotRunning, runtime.destroyPlayer(player));
    try std.testing.expectError(error.RuntimeNotRunning, completeDummyWork(&runtime, dummy_work));
}

/// Holds a raw pointer to a runtime-owned Player, exactly as a real worker
/// would hold a published snapshot, and keeps using it after cancellation.
const BlockingRuntimeWorker = struct {
    registration: *work.Registration,
    player: *audio.player.Player,
    running: std.atomic.Value(bool) = .init(false),
    released_object: std.atomic.Value(bool) = .init(false),

    fn run(self: *BlockingRuntimeWorker) void {
        self.running.store(true, .release);
        while (!self.registration.cancellationRequested()) std.Thread.yield() catch {};
        // Still legitimately touching the Player the runtime is about to free.
        for (0..10_000) |_| std.mem.doNotOptimizeAway(self.player.snapshot());
        self.released_object.store(true, .release);
        self.registration.finish();
    }
};

test "shutdown cannot return while a worker still uses a runtime object" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    const player = try runtime.createPlayer();
    const work_handle = try runtime.work_registry.begin(work.unowned);
    var worker: BlockingRuntimeWorker = .{
        .registration = try runtime.work_registry.registration(work_handle),
        .player = (try runtime.players.get(player)).player,
    };
    worker.registration.thread = try std.Thread.spawn(
        .{},
        BlockingRuntimeWorker.run,
        .{&worker},
    );
    while (!worker.running.load(.acquire)) std.Thread.yield() catch {};
    try std.testing.expect(!worker.released_object.load(.acquire));

    runtime.shutdown();

    try std.testing.expect(worker.released_object.load(.acquire));
    try std.testing.expectEqual(State.stopped, runtime.state.load(.acquire));
    try std.testing.expectError(error.RuntimeNotRunning, runtime.playerSnapshot(player));
}

test "destroying one Player leaves other Players and unrelated work running" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const keeper = try runtime.createPlayer();
    const doomed = try runtime.createPlayer();
    _ = try runtime_queue.ensureEngine(&runtime, keeper);
    _ = try runtime_queue.ensureEngine(&runtime, doomed);
    // Work unbound to any Player: a scan must outlive a Player being destroyed,
    // because it never touches one.
    const unrelated = try startDummyWork(&runtime);
    try std.testing.expectEqual(@as(usize, 3), inFlightWorkCount(&runtime));

    try runtime.destroyPlayer(doomed);

    try std.testing.expectError(error.StaleHandle, runtime.players.get(doomed));
    try std.testing.expect((try runtime.players.get(keeper)).engine != null);
    // Exactly the destroyed Player's registration was retired.
    try std.testing.expectEqual(@as(usize, 2), inFlightWorkCount(&runtime));
    try std.testing.expect(!try runtime.work_registry.cancellationRequested(unrelated));

    try completeDummyWork(&runtime, unrelated);
}

test "destroying a Player joins workers before freeing it" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    const player = try runtime.createPlayer();
    const work_handle = try runtime.work_registry.begin(runtime_module.playerOwnerTag(player));
    var worker: BlockingRuntimeWorker = .{
        .registration = try runtime.work_registry.registration(work_handle),
        .player = (try runtime.players.get(player)).player,
    };
    worker.registration.thread = try std.Thread.spawn(
        .{},
        BlockingRuntimeWorker.run,
        .{&worker},
    );
    while (!worker.running.load(.acquire)) std.Thread.yield() catch {};

    try runtime.destroyPlayer(player);

    try std.testing.expect(worker.released_object.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), inFlightWorkCount(&runtime));
}

test "commands complete asynchronously through bounded events" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    const request_id = try runtime.submit(.create_player);
    try std.testing.expect(runtime.pollEvent() == null);
    try std.testing.expect(runtime.processNextCommand());
    const event = runtime.pollEvent() orelse return error.MissingEvent;

    try std.testing.expectEqual(request_id, event.request_id);
    switch (event.outcome) {
        .player_created => {},
        else => return error.UnexpectedOutcome,
    }
}

test "submit wakes the host and the pump timeout is zero until pumped" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var counter: control.CountingWaker = .{};
    try runtime.setWaker(counter.waker());
    try std.testing.expectEqual(@as(?u64, null), runtime.nextPumpTimeoutMs());

    _ = try runtime.submit(.create_player);
    try std.testing.expectEqual(@as(u32, 1), counter.count());
    try std.testing.expectEqual(@as(?u64, 0), runtime.nextPumpTimeoutMs());
    runtime.pump();
    _ = runtime.pollEvent() orelse return error.MissingEvent;
    try std.testing.expectEqual(@as(?u64, null), runtime.nextPumpTimeoutMs());

    _ = try runtime.submit(.create_player);
    _ = try runtime.submit(.create_player);
    try std.testing.expectEqual(@as(u32, 2), counter.count());
}

test "commands left queued by event backpressure keep the pump timeout at zero" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    for (0..256) |_| _ = try runtime.submit(.create_player);
    runtime.pump();
    _ = try runtime.submit(.create_player);
    runtime.pump();
    while (runtime.pollEvent()) |_| {}
    try std.testing.expectEqual(@as(?u64, 0), runtime.nextPumpTimeoutMs());
    runtime.pump();
    while (runtime.pollEvent()) |_| {}
    try std.testing.expectEqual(@as(?u64, null), runtime.nextPumpTimeoutMs());
}

test "setWaker is refused once a worker runs" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());
    var counter: control.CountingWaker = .{};
    try runtime.setWaker(counter.waker());

    const player = try runtime.createPlayer();
    try runtime.playerLoadFile(player, std.testing.io, "fixtures/audio/generated-reference.wav");
    try std.testing.expectError(error.WorkersRunning, runtime.setWaker(null));
    try runtime.destroyPlayer(player);
    try runtime.setWaker(null);
}

test "a finished job wakes the host" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var counter: control.CountingWaker = .{};
    try runtime.setWaker(counter.waker());
    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-scan-job-wake?mode=memory&cache=shared",
    );
    const binding = try runtime.libraryAddRoot(library, std.testing.io, "fixtures/audio");
    const job_handle = try runtime.startLibraryScan(library, .{ .root_id = binding.root_id });
    try runtime.cancelJob(job_handle);

    var deadline: TestDeadline = .init(5_000);
    while (counter.count() == 0 and deadline.tick()) {}
    try std.testing.expectEqual(@as(u32, 1), counter.count());
    runtime.reapFinishedJobs();
    var finished = false;
    while (runtime.pollEvent()) |event| switch (event.outcome) {
        .job_finished => |value| finished = finished or value.job.eql(job_handle),
        else => {},
    };
    try std.testing.expect(finished);
}

test "slow completion consumers apply bounded backpressure" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    for (0..256) |_| {
        _ = try runtime.submit(.create_player);
        try std.testing.expect(runtime.processNextCommand());
    }
    _ = try runtime.submit(.create_player);
    try std.testing.expect(!runtime.processNextCommand());

    _ = runtime.pollEvent() orelse return error.MissingEvent;
    try std.testing.expect(runtime.processNextCommand());
}

test "runtime Library handles own independent databases" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-runtime-library?mode=memory&cache=shared",
    );
    const library_database = try libraryDatabase(&runtime, library);
    try library_database.tracks.upsertTracks(&.{.{ .title = "Runtime track" }});
    try std.testing.expectEqual(@as(u64, 1), try library_database.tracks.count());
    try runtime.destroyLibrary(library);
    try std.testing.expectError(error.StaleHandle, libraryDatabase(&runtime, library));
}

test "runtime Players and Zones retain stable state behind handles" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    const epoch = try runtime.seekPlayer(player, 96_000);
    const snapshot = try runtime.playerSnapshot(player);
    try std.testing.expectEqual(epoch, snapshot.epoch);
    try std.testing.expectEqual(@as(u64, 96_000), snapshot.position_frames);

    try runtime.destroyPlayer(player);
    try std.testing.expectError(error.StaleHandle, runtime.playerSnapshot(player));
    try runtime.destroyZone(zone);
}

test "runtime Zone policies and failures remain independent" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const robust = try runtime.createZone();
    const interactive = try runtime.createZone();
    try runtime.setZonePolicy(interactive, .interactive);
    try std.testing.expectEqual(
        audio.zone.RenderStrategy.direct_rt,
        try runtime.zoneRenderStrategy(interactive),
    );
    (try runtime.zones.get(robust)).zone.zone.beginOpen(1);
    (try runtime.zones.get(interactive)).zone.zone.beginOpen(2);
    (try runtime.zones.get(robust)).zone.publishState();
    (try runtime.zones.get(interactive)).zone.publishState();
    try markZoneOutputLost(&runtime, robust);
    try beginZoneRecovery(&runtime, robust);
    try failZoneRecovery(&runtime, robust);
    try std.testing.expectEqual(
        audio.zone.OutputState.failed,
        try runtime.zoneOutputState(robust),
    );
    try std.testing.expectEqual(
        audio.zone.OutputState.opening,
        try runtime.zoneOutputState(interactive),
    );
}

/// A wall-clock bound for a test that is waiting on another thread.
///
/// A count of `std.Thread.yield()` calls is not a duration, and on a loaded
/// machine it runs out before an engine has opened an output. The sleep also
/// stops a spin-wait from competing with the very thread it is waiting for.
pub const TestDeadline = struct {
    remaining_ms: u64,

    pub fn init(milliseconds: u64) TestDeadline {
        return .{ .remaining_ms = milliseconds };
    }

    /// Sleeps a millisecond and reports whether there is time left. Written as
    /// a loop condition: `while (!ready and deadline.tick()) {}`.
    pub fn tick(self: *TestDeadline) bool {
        if (self.remaining_ms == 0) return false;
        self.remaining_ms -= 1;
        const duration: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&duration, null);
        return true;
    }
};

test "a runtime Player and Zone form one object graph that actually renders" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.playerLoadFile(
        player,
        std.testing.io,
        "fixtures/audio/generated-reference.wav",
    );
    try runtime.zoneRequestOutput(zone, 0);
    try runtime.playPlayer(player);

    // The Zone's own OutputSession is what the engine opens — nothing about
    // playback lives on a caller frame any more.
    var deadline: TestDeadline = .init(5_000);
    while (try runtime.zoneOutputState(zone) != .active and deadline.tick()) {}
    var waited: usize = 0;
    try std.testing.expectEqual(
        audio.zone.OutputState.active,
        try runtime.zoneOutputState(zone),
    );
    const stream = backend.liveStream() orelse return error.OutputNeverOpened;

    // Render until the callback has produced real audio, exactly as a backend
    // real-time thread would.
    var samples: [512]f32 = @splat(0);
    var rendered: usize = 0;
    waited = 0;
    while (rendered == 0 and waited < 4000) : (waited += 1) {
        stream.pump(&samples, 256);
        for (samples) |sample| {
            if (sample != 0) rendered += 1;
        }
        if (rendered == 0) std.Thread.yield() catch {};
    }
    try std.testing.expect(rendered > 0);

    // Position telemetry is derived from the clock Zone and published through
    // the coalescing channel, not reconstructed by the caller.
    waited = 0;
    while (waited < 4000) : (waited += 1) {
        if ((try runtime.playerSnapshot(player)).position_frames > 0) break;
        stream.pump(&samples, 256);
        std.Thread.yield() catch {};
    }
    try std.testing.expect((try runtime.playerSnapshot(player)).position_frames > 0);

    try runtime.destroyZone(zone);
    try runtime.destroyPlayer(player);
}

fn awaitEngineParked(engine: *const audio.engine.PlayerEngine) !void {
    var deadline: TestDeadline = .init(5_000);
    var last = engine.pass_epoch.load(.seq_cst);
    var unchanged_ms: u32 = 0;
    while (unchanged_ms < 50) {
        if (!deadline.tick()) return error.EngineNeverParked;
        const current = engine.pass_epoch.load(.seq_cst);
        unchanged_ms = if (current == last) unchanged_ms + 1 else 0;
        last = current;
    }
}

test "playing a paused or stopped Player wakes its parked engine" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.playerLoadFile(player, std.testing.io, "fixtures/audio/generated-reference.wav");
    try runtime.zoneRequestOutput(zone, 0);
    try runtime.playPlayer(player);
    var deadline: TestDeadline = .init(5_000);
    while (try runtime.zoneOutputState(zone) != .active and deadline.tick()) {}
    const stream = backend.liveStream() orelse return error.OutputNeverOpened;
    var samples: [512]f32 = undefined;
    deadline = .init(5_000);
    while ((try runtime.playerSnapshot(player)).position_frames == 0 and deadline.tick())
        stream.pump(&samples, 256);

    try runtime.pausePlayer(player);
    try awaitEngineParked((try runtime.players.get(player)).engine.?);
    const paused_at = (try runtime.playerSnapshot(player)).position_frames;
    try std.testing.expect(paused_at > 0);

    try runtime.playPlayer(player);
    deadline = .init(5_000);
    while ((try runtime.playerSnapshot(player)).position_frames <= paused_at and deadline.tick())
        stream.pump(&samples, 256);
    try std.testing.expect((try runtime.playerSnapshot(player)).position_frames > paused_at);

    try runtime.stopPlayer(player);
    try awaitEngineParked((try runtime.players.get(player)).engine.?);
    try std.testing.expectEqual(@as(u64, 0), (try runtime.playerSnapshot(player)).position_frames);
    try runtime.playerLoadFile(player, std.testing.io, "fixtures/audio/generated-reference.wav");
    try runtime.playPlayer(player);
    deadline = .init(5_000);
    while ((try runtime.playerSnapshot(player)).position_frames == 0 and deadline.tick())
        stream.pump(&samples, 256);
    try std.testing.expect((try runtime.playerSnapshot(player)).position_frames > 0);

    try runtime.destroyZone(zone);
    try runtime.destroyPlayer(player);
}

test "the equalizer and crossfeed reject out-of-range values and keep the last valid setting" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const player = try runtime.createPlayer();

    var too_loud: audio.dsp.Equalizer = .{};
    too_loud.gains_db[4] = 12.5;
    try std.testing.expectError(
        error.EqualizerGainOutOfRange,
        runtime.playerSetEqualizer(player, too_loud),
    );
    try std.testing.expectError(
        error.EqualizerPreampOutOfRange,
        runtime.playerSetEqualizer(player, .{ .preamp_db = -30 }),
    );
    try std.testing.expectEqual(@as(?audio.dsp.Equalizer, null), try runtime.playerEqualizer(player));

    const bass = audio.dsp.Equalizer.preset(.bass);
    try runtime.playerSetEqualizer(player, bass);
    try std.testing.expectError(
        error.EqualizerGainOutOfRange,
        runtime.playerSetEqualizer(player, too_loud),
    );
    try std.testing.expectEqual(@as(?audio.dsp.Equalizer, bass), try runtime.playerEqualizer(player));

    try std.testing.expectError(error.CrossfeedAmountOutOfRange, runtime.playerSetCrossfeed(player, 1.5));
    try std.testing.expectEqual(@as(?f32, null), try runtime.playerCrossfeed(player));
    try runtime.playerSetCrossfeed(player, 0.3);
    try std.testing.expectEqual(@as(?f32, 0.3), try runtime.playerCrossfeed(player));
    try runtime.playerSetCrossfeed(player, null);
    try std.testing.expectEqual(@as(?f32, null), try runtime.playerCrossfeed(player));
}

fn hasReason(path: audio.dsp.SignalPath, reason: audio.signal_path.Reason) bool {
    return std.mem.indexOfScalar(audio.signal_path.Reason, path.reasonList(), reason) != null;
}

test "a Player's signal path reports sample processing only while DSP or volume is in effect" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.playerLoadFile(
        player,
        std.testing.io,
        "fixtures/audio/generated-reference.wav",
    );
    try runtime.zoneRequestOutput(zone, 0);
    try runtime.playPlayer(player);

    var samples: [512]f32 = @splat(0);
    var path = try runtime.playerSignalPath(player);
    var deadline: TestDeadline = .init(5_000);
    while (path.output == null and deadline.tick()) {
        if (deadline.remaining_ms % 5 != 0) continue;
        if (backend.liveStream()) |stream| stream.pump(&samples, 256);
        path = try runtime.playerSignalPath(player);
    }
    try std.testing.expect(path.source != null);
    const output = path.output orelse return error.OutputNeverOpened;
    try std.testing.expectEqual(audio.pcm.SampleFormat.float_32, output.sample_format);
    try std.testing.expectEqual(path.source.?.sample_rate, output.sample_rate);
    try std.testing.expectEqual(path.source.?.channels, output.channels);
    try std.testing.expect(!hasReason(path, .sample_processing));
    try std.testing.expect(path.bit_perfect_eligible);
    try std.testing.expect(path.widened_exactly);
    try std.testing.expectEqual(@as(f32, 1), path.volume);
    try std.testing.expectEqual(@as(?audio.dsp.Equalizer, null), path.equalizer);

    try runtime.playerSetEqualizer(player, audio.dsp.Equalizer.preset(.bass));
    path = try runtime.playerSignalPath(player);
    try std.testing.expect(!path.bit_perfect_eligible);
    try std.testing.expect(hasReason(path, .sample_processing));
    try std.testing.expectEqual(@as(?audio.dsp.Equalizer, audio.dsp.Equalizer.preset(.bass)), path.equalizer);
    try std.testing.expect(path.output != null);

    try runtime.playerSetEqualizer(player, null);
    path = try runtime.playerSignalPath(player);
    try std.testing.expect(!hasReason(path, .sample_processing));

    try runtime.playerSetVolume(player, 0.5);
    path = try runtime.playerSignalPath(player);
    deadline = .init(5_000);
    while (path.volume != 0.5 and deadline.tick()) {
        if (deadline.remaining_ms % 5 != 0) continue;
        if (backend.liveStream()) |stream| stream.pump(&samples, 256);
        path = try runtime.playerSignalPath(player);
    }
    try std.testing.expect(hasReason(path, .sample_processing));
    try std.testing.expectEqual(@as(f32, 0.5), path.volume);

    try runtime.playerSetVolume(player, 1);
    path = try runtime.playerSignalPath(player);
    deadline = .init(5_000);
    while (path.volume != 1 and deadline.tick()) {
        if (deadline.remaining_ms % 5 != 0) continue;
        if (backend.liveStream()) |stream| stream.pump(&samples, 256);
        path = try runtime.playerSignalPath(player);
    }
    try std.testing.expectEqual(@as(f32, 1), path.volume);
    try std.testing.expect(path.bit_perfect_eligible);

    try runtime.destroyZone(zone);
    try runtime.destroyPlayer(player);
}

test "shutdown joins a Player's engine thread before freeing its objects" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.playerLoadFile(
        player,
        std.testing.io,
        "fixtures/audio/generated-reference.wav",
    );
    try runtime.zoneRequestOutput(zone, 0);
    try runtime.playPlayer(player);
    try std.testing.expectEqual(@as(usize, 1), inFlightWorkCount(&runtime));

    runtime.shutdown();

    // The registration is gone, which can only happen after the engine thread
    // called finish() — it was joined, not abandoned.
    try std.testing.expectEqual(@as(usize, 0), inFlightWorkCount(&runtime));
    try std.testing.expectError(error.RuntimeNotRunning, runtime.playerSnapshot(player));
    try std.testing.expectError(error.RuntimeNotRunning, runtime.zoneOutputState(zone));
}

test "destroying a Zone is acknowledged by the engine before its path is freed" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const player = try runtime.createPlayer();
    const kept = try runtime.createZone();
    const removed = try runtime.createZone();
    try runtime.attachZone(kept, player);
    try runtime.attachZone(removed, player);
    try runtime.playerLoadFile(
        player,
        std.testing.io,
        "fixtures/audio/generated-reference.wav",
    );
    try runtime.zoneRequestOutput(kept, 0);
    try runtime.zoneRequestOutput(removed, 0);
    try runtime.playPlayer(player);

    var removed_deadline: TestDeadline = .init(5_000);
    while (try runtime.zoneOutputState(removed) != .active and removed_deadline.tick()) {}
    try std.testing.expectEqual(@as(usize, 2), backend.stream_count);

    // No global work drain here: removal is published to the engine and the
    // engine's acknowledgement is what makes freeing the Zone safe.
    try runtime.destroyZone(removed);
    try std.testing.expectEqual(@as(usize, 1), inFlightWorkCount(&runtime));
    try std.testing.expectEqual(
        audio.zone.OutputState.active,
        try runtime.zoneOutputState(kept),
    );
    try std.testing.expectError(error.StaleHandle, runtime.zoneOutputState(removed));
}

test "engine-owned Zone output state is not mutable from the control lane" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.playerLoadFile(
        player,
        std.testing.io,
        "fixtures/audio/generated-reference.wav",
    );
    try std.testing.expectError(error.ZoneOwnedByEngine, markZoneOutputLost(&runtime, zone));
    try std.testing.expectError(error.ZoneOwnedByEngine, runtime.setZonePolicy(zone, .interactive));
}

/// Builds a Library whose Tracks point at real fixture files, so the queue is
/// exercised through the same `playableLocation` -> `LocalFileSource` ->
/// `CodecRegistry` path a projected corpus uses.
fn openFixtureLibrary(
    runtime: *OrcaRuntime,
    uri: [:0]const u8,
    paths: []const []const u8,
) !struct { library: LibraryHandle, ids: [4]i64 } {
    const library = try runtime.openLibrary(std.testing.io, uri);
    const library_database = try libraryDatabase(runtime, library);
    const volume_id = try library_database.volumes.ensure(.{
        .stable_key = "uuid:queue-fixture",
        .label = "Fixtures",
    });
    var ids: [4]i64 = @splat(0);
    for (paths, 0..) |path, index| {
        const file_id = try library_database.files.create(.{
            .audio_format = 1,
            .size_bytes = 1024,
        });
        _ = try library_database.locations.upsert(.{
            .file_id = file_id,
            .volume_id = volume_id,
            .uri = path,
        });
        var title_buffer: [32]u8 = undefined;
        try library_database.tracks.upsertTracks(&.{.{
            .title = try std.fmt.bufPrint(&title_buffer, "Entry {d}", .{index}),
            .preferred_file_id = file_id,
        }});
        var page = try library_database.tracks.page(std.testing.allocator, .{ .limit = 1, .offset = @intCast(index) });
        defer page.deinit();
        ids[index] = page.items[0].id;
    }
    return .{ .library = library, .ids = ids };
}

test "a queue of Library tracks plays through the real resolve-open-decode path" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const fixtures = try openFixtureLibrary(
        &runtime,
        "file:orca-queue-play?mode=memory&cache=shared",
        &.{
            "fixtures/audio/generated-reference.wav",
            "fixtures/audio/generated-reference.flac",
        },
    );
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneRequestOutput(zone, 0);
    try runtime.playerPlayTracks(
        player,
        fixtures.library,
        std.testing.io,
        fixtures.ids[0..2],
        0,
    );

    var samples: [512]f32 = @splat(0);
    var started_deadline: TestDeadline = .init(5_000);
    while (started_deadline.tick()) {
        if (backend.liveStream()) |stream| stream.pump(&samples, 256);
        if ((try runtime.playerQueueSnapshot(player)).decode_position > 0) break;
    }
    // The engine resolved the *second* entry on its own, opened it, and primed
    // it behind the first: this is auto-advance through the database.
    const stats = try runtime.playerQueueStats(player);
    try std.testing.expectEqual(@as(u64, 1), stats.entries_started);
    try std.testing.expectEqual(@as(u64, 0), stats.open_failures);
    try std.testing.expectEqual(@as(u32, 1), (try runtime.playerQueueSnapshot(player)).decode_position);

    // And now-playing is the audible entry, resolvable back to a Track id.
    var audible_deadline: TestDeadline = .init(5_000);
    while (audible_deadline.tick()) {
        if (backend.liveStream()) |stream| stream.pump(&samples, 256);
        if ((try runtime.playerQueueSnapshot(player)).cursor == 1) break;
    }
    const now_playing = (try runtime.playerNowPlaying(player)).?;
    try std.testing.expectEqual(fixtures.ids[1], now_playing.track_id);
}

test "a user skip is immediate and does not wait for the current entry to drain" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const fixtures = try openFixtureLibrary(
        &runtime,
        "file:orca-queue-skip?mode=memory&cache=shared",
        &.{
            "fixtures/audio/generated-reference.wav",
            "fixtures/audio/generated-reference.flac",
            "fixtures/audio/tagged-reference.flac",
        },
    );
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneRequestOutput(zone, 0);
    try runtime.playerPlayTracks(
        player,
        fixtures.library,
        std.testing.io,
        fixtures.ids[0..3],
        0,
    );
    const epoch_before = (try runtime.playerSnapshot(player)).epoch;

    // No pumping at all: nothing has drained, and the skip still lands.
    try std.testing.expect(try runtime.playerNext(player));
    const snapshot = try runtime.playerQueueSnapshot(player);
    try std.testing.expectEqual(@as(u32, 1), snapshot.cursor);
    // The epoch moved, which is what makes already-prepared audio disappear
    // from the callback rather than being played out first.
    try std.testing.expect((try runtime.playerSnapshot(player)).epoch != epoch_before);
    try std.testing.expectEqual(
        fixtures.ids[1],
        (try runtime.playerNowPlaying(player)).?.track_id,
    );

    try std.testing.expect(try runtime.playerNext(player));
    // The end of a non-repeating queue reports honestly instead of wrapping.
    try std.testing.expect(!try runtime.playerNext(player));
    try runtime.playerSetRepeat(player, .all);
    try std.testing.expect(try runtime.playerNext(player));
    try std.testing.expectEqual(
        @as(u32, 0),
        (try runtime.playerQueueSnapshot(player)).cursor,
    );
}

test "previous restarts the entry past three seconds and steps back before it" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const fixtures = try openFixtureLibrary(
        &runtime,
        "file:orca-queue-previous?mode=memory&cache=shared",
        &.{
            "fixtures/audio/generated-reference.wav",
            "fixtures/audio/generated-reference.flac",
        },
    );
    const player = try runtime.createPlayer();
    try runtime.playerPlayTracks(
        player,
        fixtures.library,
        std.testing.io,
        fixtures.ids[0..2],
        1,
    );

    // Under three seconds in: move to the previous entry.
    try std.testing.expect(try runtime.playerPrevious(player));
    try std.testing.expectEqual(
        @as(u32, 0),
        (try runtime.playerQueueSnapshot(player)).cursor,
    );

    // Past three seconds: restart this entry instead of leaving it.
    const format = (try runtime.players.get(player)).player.format().?;
    _ = try runtime.seekPlayer(player, 4 * format.sample_rate);
    try std.testing.expect(try runtime.playerPrevious(player));
    try std.testing.expectEqual(
        @as(u32, 0),
        (try runtime.playerQueueSnapshot(player)).cursor,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        (try runtime.playerSnapshot(player)).position_frames,
    );
}

test "stop keeps the queue while clear empties it" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const fixtures = try openFixtureLibrary(
        &runtime,
        "file:orca-queue-stop?mode=memory&cache=shared",
        &.{
            "fixtures/audio/generated-reference.wav",
            "fixtures/audio/generated-reference.flac",
        },
    );
    const player = try runtime.createPlayer();
    try runtime.playerPlayTracks(
        player,
        fixtures.library,
        std.testing.io,
        fixtures.ids[0..2],
        1,
    );

    try runtime.stopPlayer(player);
    const stopped = try runtime.playerQueueSnapshot(player);
    try std.testing.expectEqual(@as(u32, 2), stopped.entries);
    try std.testing.expectEqual(@as(u32, 1), stopped.cursor);
    try std.testing.expect((try runtime.players.get(player)).player.sources == null);

    try runtime.playerClearQueue(player);
    try std.testing.expectEqual(
        @as(u32, 0),
        (try runtime.playerQueueSnapshot(player)).entries,
    );
}

test "a track with no file behind it fails typed through the command lane" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-queue-typed?mode=memory&cache=shared",
    );
    const library_database = try libraryDatabase(&runtime, library);
    try library_database.tracks.upsertTracks(&.{.{ .title = "Orphan" }});
    var page = try library_database.tracks.page(std.testing.allocator, .{ .limit = 1, .offset = 0 });
    defer page.deinit();
    const player = try runtime.createPlayer();
    try runtime.playerBindLibrary(player, library, std.testing.io);

    const request_id = try runtime.submit(.{ .play_track = .{
        .player = player,
        .library = library,
        .track_id = page.items[0].id,
    } });
    try std.testing.expect(runtime.processNextCommand());
    const event = runtime.pollEvent() orelse return error.MissingEvent;
    try std.testing.expectEqual(request_id, event.request_id);
    switch (event.outcome) {
        .failed => |failure| try std.testing.expectEqual(
            control.Failure.track_has_no_file,
            failure,
        ),
        else => return error.UnexpectedOutcome,
    }
}

test "destroying a Library releases every Player bound to it" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const fixtures = try openFixtureLibrary(
        &runtime,
        "file:orca-queue-unbind?mode=memory&cache=shared",
        &.{"fixtures/audio/generated-reference.wav"},
    );
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneRequestOutput(zone, 0);
    try runtime.playerPlayTracks(
        player,
        fixtures.library,
        std.testing.io,
        fixtures.ids[0..1],
        0,
    );

    // The opener holds a pointer into the Library. Closing it while an engine
    // thread could still resolve through it would be a use-after-free.
    try runtime.destroyLibrary(fixtures.library);
    try std.testing.expect((try runtime.players.get(player)).opener == null);
    try std.testing.expect((try runtime.players.get(player)).player.sources == null);
    // The queue itself is the user's list and survives; it just cannot resolve.
    try std.testing.expectEqual(
        @as(u32, 1),
        (try runtime.playerQueueSnapshot(player)).entries,
    );
}

/// A Release whose Tracks point at real fixture files and whose observed tags
/// record what those files actually carry, so the candidate query is exercised
/// against the same columns a scan writes.
fn openArtworkLibrary(
    runtime: *OrcaRuntime,
    uri: [:0]const u8,
    paths: []const []const u8,
) !struct { library: LibraryHandle, release_id: i64, ids: [4]i64 } {
    const library = try runtime.openLibrary(std.testing.io, uri);
    const library_database = try libraryDatabase(runtime, library);
    const volume_id = try library_database.volumes.ensure(.{
        .stable_key = "uuid:artwork-fixture",
        .label = "Fixtures",
    });
    const release_id = try library_database.releases.upsert(.{
        .release_key = "artwork-fixture",
        .title = "Covered",
    });
    var ids: [4]i64 = @splat(0);
    for (paths, 0..) |path, index| {
        const file_id = try library_database.files.create(.{
            .audio_format = 1,
            .size_bytes = 1024,
        });
        _ = try library_database.locations.upsert(.{
            .file_id = file_id,
            .volume_id = volume_id,
            .uri = path,
        });
        // Exactly what a scan of this file would have observed.
        var file = try storage.LocalFileSource.open(std.testing.io, path);
        defer file.close();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        // Through the payload offset, as the scanner does: one of these
        // fixtures is a FLAC stream behind an ID3v2 tag.
        const detection = (try storage.format.detect(file.readable())).?;
        var tag_view: storage.OffsetSource = .{
            .inner = file.readable(),
            .offset = detection.payload_offset,
        };
        const observed = try library_pass.tag_reader.read(
            arena.allocator(),
            detection.format,
            if (detection.payload_offset == 0) file.readable() else tag_view.readable(),
        );
        try library_database.observed_tags.upsertBatch(&.{.{
            .file_id = file_id,
            .values = if (observed) |tags| tags.values else .{},
        }});
        if (observed) |tags| tags.deinit();

        var title_buffer: [32]u8 = undefined;
        try library_database.tracks.upsertTracks(&.{.{
            .title = try std.fmt.bufPrint(&title_buffer, "Entry {d}", .{index}),
            .release_id = release_id,
            .track_number = @intCast(index + 1),
            .preferred_file_id = file_id,
        }});
        var page = try library_database.tracks.page(
            std.testing.allocator,
            .{ .limit = 1, .offset = @intCast(index) },
        );
        defer page.deinit();
        ids[index] = page.items[0].id;
    }
    return .{ .library = library, .release_id = release_id, .ids = ids };
}

test "a Track resolves to the cover embedded in its own file" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const fixtures = try openArtworkLibrary(
        &runtime,
        "file:orca-artwork-track?mode=memory&cache=shared",
        &.{ "fixtures/audio/covered-reference.flac", "fixtures/audio/tagged-reference.flac" },
    );

    const image = (try runtime.libraryTrackArtwork(
        fixtures.library,
        std.testing.io,
        fixtures.ids[0],
    )).?;
    defer image.deinit();
    try std.testing.expectEqualStrings("image/png", image.mime_type);
    try std.testing.expectEqual(@as(usize, 217), image.bytes.len);

    // The second file carries no picture, and that is an answer, not a failure.
    try std.testing.expect((try runtime.libraryTrackArtwork(
        fixtures.library,
        std.testing.io,
        fixtures.ids[1],
    )) == null);
}

test "a Track whose file has gone reports no cover rather than failing" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const fixtures = try openArtworkLibrary(
        &runtime,
        "file:orca-artwork-missing?mode=memory&cache=shared",
        &.{"fixtures/audio/covered-reference.flac"},
    );
    // Repoint the Location at a path nothing is at, exactly as a moved file
    // leaves the Library until the next scan reconciles it.
    const library_database = try libraryDatabase(&runtime, fixtures.library);
    const volume_id = (try library_database.volumes.find("uuid:artwork-fixture")).?;
    const location_id = (try library_database.locations.find(
        volume_id,
        "fixtures/audio/covered-reference.flac",
    )).?;
    try library_database.locations.move(location_id, "fixtures/audio/does-not-exist.flac");
    try std.testing.expect((try runtime.libraryTrackArtwork(
        fixtures.library,
        std.testing.io,
        fixtures.ids[0],
    )) == null);
}

test "a Release takes its cover from its first track in listening order" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    // Track one carries no cover at all, so the rule is "the first track that
    // has one" rather than "track one or nothing". Tracks two and three carry
    // *different* covers, which is what makes the order observable: a Release
    // whose tracks disagree must still answer the same way every time.
    const fixtures = try openArtworkLibrary(
        &runtime,
        "file:orca-artwork-release?mode=memory&cache=shared",
        &.{
            "fixtures/audio/tagged-reference.flac",
            "fixtures/audio/covered-reference.mp3",
            "fixtures/audio/covered-alternate-reference.flac",
        },
    );
    const image = (try runtime.libraryReleaseArtwork(
        fixtures.library,
        std.testing.io,
        fixtures.release_id,
    )).?;
    defer image.deinit();
    try std.testing.expectEqualStrings("image/png", image.mime_type);
    // Track two's cover, not track three's 138-byte one.
    try std.testing.expectEqual(@as(usize, 217), image.bytes.len);

    // A Release nothing was filed under has no cover and opens no files.
    try std.testing.expect((try runtime.libraryReleaseArtwork(
        fixtures.library,
        std.testing.io,
        fixtures.release_id + 1,
    )) == null);
}

test "a library edit regroups a track without touching its file, and clearing it reverts" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-runtime-edit?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
    _ = try library_database.locations.upsert(.{
        .file_id = file_id,
        .volume_id = database.LibraryDatabase.null_volume,
        .uri = "/m/Artist/a.flac",
        .state = .present,
    });
    try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = "Song",
        .artist = "File Artist",
        .album = "File Album",
        .album_artist = "File Artist",
        .track_number = 1,
    } });
    var projection: library_pass.Projection = .{ .allocator = std.testing.allocator, .library = library_database };
    _ = try projection.run(.{ .files = &.{file_id} });

    var before = try runtime.libraryTrackQuery(library, "", .{ .limit = 4 });
    const track_id = before.items[0].id;
    before.deinit();

    try std.testing.expectError(error.InvalidEditValue, runtime.libraryEditTracks(
        library,
        &.{track_id},
        &.{.{ .field = .track_number, .value = "zero" }},
    ));
    const moved = try runtime.libraryEditTracks(library, &.{track_id}, &.{
        .{ .field = .artist, .value = "Edited Artist" },
        .{ .field = .album, .value = "Edited Album" },
    });
    defer moved.deinit();
    var edited = try runtime.libraryTrackQuery(library, "", .{ .limit = 4 });
    try std.testing.expectEqual(@as(usize, 1), edited.items.len);
    try std.testing.expectEqualStrings("Edited Artist", edited.items[0].artist);
    try std.testing.expectEqualStrings("Edited Album", edited.items[0].album);
    const edited_id = edited.items[0].id;
    edited.deinit();
    try std.testing.expectEqualSlices(i64, &.{edited_id}, moved.ids);

    var values = try runtime.libraryTrackEdits(library, edited_id);
    try std.testing.expectEqual(@as(usize, 2), values.items.len);
    try std.testing.expect(values.items[0].locked);
    values.deinit();

    (try runtime.libraryEditTracks(library, &.{edited_id}, &.{
        .{ .field = .artist, .value = null },
        .{ .field = .album, .value = null },
    })).deinit();
    var reverted = try runtime.libraryTrackQuery(library, "", .{ .limit = 4 });
    defer reverted.deinit();
    try std.testing.expectEqual(@as(usize, 1), reverted.items.len);
    try std.testing.expectEqualStrings("File Artist", reverted.items[0].artist);
    try std.testing.expectEqual(@as(u64, 1), try library_database.artists.count());
}

pub fn copyFixtureInto(dir: std.Io.Dir, fixture: []const u8, name: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture, std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(bytes);
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
}

pub fn awaitJob(runtime: *OrcaRuntime, job_handle: JobHandle) !job.State {
    var deadline: TestDeadline = .init(10_000);
    while (deadline.tick()) {
        runtime.reapFinishedJobs();
        const snapshot = try runtime.jobSnapshotSynced(job_handle);
        switch (snapshot.state) {
            .succeeded, .failed, .cancelled => return snapshot.state,
            else => {},
        }
    }
    return error.JobDidNotFinish;
}

pub fn scannedTempLibrary(runtime: *OrcaRuntime, temporary: *std.testing.TmpDir, name: [:0]const u8) !LibraryHandle {
    try copyFixtureInto(temporary.dir, "fixtures/audio/covered-reference.mp3", "a.mp3");
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "b.flac");
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "c.m4a");
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(root);
    const library = try runtime.openLibrary(std.testing.io, name);
    const binding = try runtime.libraryAddRoot(library, std.testing.io, root);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(runtime, try runtime.startLibraryScan(library, .{ .root_id = binding.root_id })));
    return library;
}

pub fn allTrackIds(runtime: *OrcaRuntime, library: LibraryHandle) ![]i64 {
    var page = try runtime.libraryTrackQuery(library, "", .{ .limit = 16 });
    defer page.deinit();
    const ids = try std.testing.allocator.alloc(i64, page.items.len);
    for (ids, page.items) |*id, item| id.* = item.id;
    return ids;
}

fn tempDatabasePath(data: *std.testing.TmpDir) ![:0]u8 {
    return std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/library.db", .{data.sub_path}, 0);
}

fn rescan(runtime: *OrcaRuntime, library: LibraryHandle) !void {
    var roots = try runtime.libraryRootPage(library, 1, 0);
    defer roots.deinit();
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(runtime, try runtime.startLibraryScan(library, .{ .root_id = roots.items[0].id })));
}

fn expectOnlyFixtureFiles(dir: std.Io.Dir) !void {
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        count += 1;
        try std.testing.expect(std.mem.eql(u8, entry.name, "a.mp3") or
            std.mem.eql(u8, entry.name, "b.flac") or
            std.mem.eql(u8, entry.name, "c.m4a"));
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "an approved tag write rewrites the files, the rescan agrees, and undo restores their bytes" {
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try tempDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempLibrary(&runtime, &temporary, database_path);
    const original_mp3 = try temporary.dir.readFileAlloc(std.testing.io, "a.mp3", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(original_mp3);

    var ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 3), ids.len);
    const moved = try runtime.libraryEditTracks(library, ids, &.{.{ .field = .album, .value = "Written Album" }});
    std.testing.allocator.free(ids);
    ids = try std.testing.allocator.dupe(i64, moved.ids);
    moved.deinit();

    const preview = try runtime.planTagWrite(library, std.testing.io, ids);
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 2), preview.files.len);
    try std.testing.expectEqual(@as(usize, 1), preview.skipped.len);
    try std.testing.expectEqual(TagWriteSkipReason.format_not_writable, preview.skipped[0].reason);
    for (preview.files) |file| {
        try std.testing.expectEqual(@as(usize, 1), file.changes.len);
        try std.testing.expectEqualStrings("Written Album", file.changes[0].after.?);
    }

    var wrong = preview.digest;
    wrong[0] ^= 1;
    try std.testing.expectError(error.MutationApprovalMismatch, runtime.startTagWrite(library, preview.plan_id, wrong));
    const job_handle = try runtime.startTagWrite(library, preview.plan_id, preview.digest);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, job_handle));
    try std.testing.expectError(error.UnknownTagWritePlan, runtime.startTagWrite(library, preview.plan_id, preview.digest));

    const after = try runtime.planTagWrite(library, std.testing.io, ids);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 0), after.files.len);
    try std.testing.expectEqual(@as(u64, 0), after.plan_id);

    const library_database = try libraryDatabase(&runtime, library);
    try expectOnlyFixtureFiles(temporary.dir);
    try rescan(&runtime, library);
    try std.testing.expectEqual(@as(i64, 3), try database.columns.scalar(library_database.database, "SELECT count(*) FROM tracks;"));

    try runtime.undoTagWrite(library, std.testing.io, preview.plan_id);
    const restored_mp3 = try temporary.dir.readFileAlloc(std.testing.io, "a.mp3", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(restored_mp3);
    try std.testing.expectEqualSlices(u8, original_mp3, restored_mp3);
    try expectOnlyFixtureFiles(temporary.dir);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, library_database.backup_directory.?, .{}));
    try rescan(&runtime, library);
    try std.testing.expectEqual(@as(i64, 3), try database.columns.scalar(library_database.database, "SELECT count(*) FROM files;"));
    try std.testing.expectEqual(@as(i64, 0), try database.columns.scalar(library_database.database, "SELECT count(*) FROM locations WHERE state <> 'present';"));
    const stored = (try library_database.observed_tags.get(std.testing.allocator, preview.files[0].file_id)).?;
    defer stored.deinit();
    try std.testing.expect(stored.values.album == null or !std.mem.eql(u8, stored.values.album.?, "Written Album"));

    const again = try runtime.planTagWrite(library, std.testing.io, ids);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 2), again.files.len);
    try runtime.discardTagWrite(library, again.plan_id);
}

test "pruned tag-write backups free their space and leave the write impossible to undo" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try tempDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempLibrary(&runtime, &temporary, database_path);
    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    (try runtime.libraryEditTracks(library, ids, &.{.{ .field = .album, .value = "Pruned Album" }})).deinit();
    const edited = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(edited);
    const preview = try runtime.planTagWrite(library, std.testing.io, edited);
    defer preview.deinit();
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startTagWrite(library, preview.plan_id, preview.digest)));
    const written_mp3 = try temporary.dir.readFileAlloc(std.testing.io, "a.mp3", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(written_mp3);

    try std.testing.expectEqual(@as(u64, 0), (try runtime.pruneTagWriteBackups(library, std.testing.io, 3600)).backups);
    const pruned = try runtime.pruneTagWriteBackups(library, std.testing.io, 0);
    try std.testing.expectEqual(@as(u64, 2), pruned.backups);
    try std.testing.expect(pruned.bytes > 0);
    try std.testing.expectError(error.TagWriteBackupPruned, runtime.undoTagWrite(library, std.testing.io, preview.plan_id));
    const after_mp3 = try temporary.dir.readFileAlloc(std.testing.io, "a.mp3", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(after_mp3);
    try std.testing.expectEqualSlices(u8, written_mp3, after_mp3);
}

test "a Library with no database file refuses to start a tag write" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempLibrary(&runtime, &temporary, "file:orca-runtime-tag-write-memory?mode=memory&cache=shared");
    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    (try runtime.libraryEditTracks(library, ids, &.{.{ .field = .album, .value = "Nowhere" }})).deinit();
    const edited = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(edited);
    const preview = try runtime.planTagWrite(library, std.testing.io, edited);
    defer preview.deinit();
    try std.testing.expect(preview.files.len > 0);

    try std.testing.expectError(error.NoBackupDirectory, runtime.startTagWrite(library, preview.plan_id, preview.digest));
    try runtime.discardTagWrite(library, preview.plan_id);
}

test "a file changed since its scan is left out of a tag write" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempLibrary(&runtime, &temporary, "file:orca-runtime-tag-write-changed?mode=memory&cache=shared");
    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    (try runtime.libraryEditTracks(library, ids, &.{.{ .field = .title, .value = "Written Title" }})).deinit();

    const bytes = try temporary.dir.readFileAlloc(std.testing.io, "b.flac", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(bytes);
    const grown = try std.mem.concat(std.testing.allocator, u8, &.{ bytes, "x" });
    defer std.testing.allocator.free(grown);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "b.flac", .data = grown });

    const preview = try runtime.planTagWrite(library, std.testing.io, ids);
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 1), preview.files.len);
    try std.testing.expect(std.mem.endsWith(u8, preview.files[0].path, "a.mp3"));
    var changed = false;
    for (preview.skipped) |skip| changed = changed or skip.reason == .changed_since_scan;
    try std.testing.expect(changed);
    // Left pending on purpose: shutdown must free it.
}

fn collectArtwork(runtime: *OrcaRuntime, library: LibraryHandle, results: []?ArtworkResult, first_request: u64, wanted: usize) !usize {
    var deadline: TestDeadline = .init(10_000);
    var collected: usize = 0;
    while (collected < wanted and deadline.tick()) {
        while (runtime.libraryTakeArtwork(library)) |result| {
            results[@intCast(result.request - first_request)] = result;
            collected += 1;
        }
    }
    return collected;
}

test "requested covers arrive off the caller's thread and match the synchronous lookup" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artwork-async?mode=memory&cache=shared");
    const binding = try runtime.libraryAddRoot(library, std.testing.io, "fixtures/audio");
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryScan(library, .{ .root_id = binding.root_id })));

    var releases = try runtime.libraryReleasePage(library, .{ .limit = 32 });
    defer releases.deinit();
    try std.testing.expect(releases.items.len > 1);

    var results: [32]?ArtworkResult = @splat(null);
    defer for (results) |entry| if (entry) |result| if (result.image) |image| image.deinit();
    const first = try runtime.libraryRequestArtwork(library, std.testing.io, .{ .release = releases.items[0].id });
    for (releases.items[1..]) |release|
        _ = try runtime.libraryRequestArtwork(library, std.testing.io, .{ .release = release.id });
    try std.testing.expectEqual(releases.items.len, try collectArtwork(&runtime, library, &results, first, releases.items.len));

    var covered: usize = 0;
    for (releases.items, results[0..releases.items.len]) |release, entry| {
        const result = entry.?;
        try std.testing.expectEqual(release.id, result.subject.release);
        const expected = try runtime.libraryReleaseArtwork(library, std.testing.io, release.id);
        defer if (expected) |image| image.deinit();
        try std.testing.expectEqual(expected == null, result.image == null);
        if (expected) |image| {
            covered += 1;
            try std.testing.expectEqualSlices(u8, image.bytes, result.image.?.bytes);
        }
    }
    try std.testing.expect(covered > 0);
}

test "closing a library frees covers nobody took" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artwork-shutdown?mode=memory&cache=shared");
    const binding = try runtime.libraryAddRoot(library, std.testing.io, "fixtures/audio");
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryScan(library, .{ .root_id = binding.root_id })));
    var releases = try runtime.libraryReleasePage(library, .{ .limit = 8 });
    defer releases.deinit();
    for (releases.items) |release|
        _ = try runtime.libraryRequestArtwork(library, std.testing.io, .{ .release = release.id });
    var deadline: TestDeadline = .init(5_000);
    const loader = &(try runtime.libraries.get(library)).artwork.?.loader;
    while (loader.results.len() != releases.items.len and deadline.tick()) {}
    try runtime.destroyLibrary(library);
}

test "every release order lists the same releases, each in its own order" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-release-sorts?mode=memory&cache=shared");
    const binding = try runtime.libraryAddRoot(library, std.testing.io, "fixtures/audio");
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryScan(library, .{ .root_id = binding.root_id })));

    var by_title = try runtime.libraryReleasePage(library, .{ .sort = .title });
    defer by_title.deinit();
    try std.testing.expect(by_title.items.len > 2);
    inline for (.{ database.ReleaseSort.artist, .year, .recently_added }) |sort| {
        var page = try runtime.libraryReleasePage(library, .{ .sort = sort });
        defer page.deinit();
        try std.testing.expectEqual(by_title.items.len, page.items.len);
        for (by_title.items) |expected| {
            for (page.items) |item| {
                if (item.id == expected.id) break;
            } else return error.ReleaseMissing;
        }
        for (page.items[0 .. page.items.len - 1], page.items[1..]) |a, b| switch (sort) {
            .artist => try std.testing.expect(std.ascii.orderIgnoreCase(a.album_artist, b.album_artist) != .gt),
            .year => if (b.release_date) |later| try std.testing.expect(
                a.release_date != null and std.mem.order(u8, a.release_date.?, later) != .lt,
            ),
            .recently_added => try std.testing.expect(a.id > b.id),
            else => {},
        };
    }
}

test "queue edits from the host jump, insert after the playing entry and refuse to remove it" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());
    const library = try runtime.openLibrary(std.testing.io, "file:orca-queue-edits?mode=memory&cache=shared");
    const binding = try runtime.libraryAddRoot(library, std.testing.io, "fixtures/audio");
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryScan(library, .{ .root_id = binding.root_id })));
    var page = try runtime.libraryTrackQuery(library, "", .{ .limit = 6, .sort = .id });
    defer page.deinit();
    var ids: [6]i64 = undefined;
    var playable: usize = 0;
    for (page.items) |item| {
        if (!item.has_playable_file) continue;
        ids[playable] = item.id;
        playable += 1;
    }
    try std.testing.expect(playable >= 4);

    const player = try runtime.createPlayer();
    try runtime.playerBindLibrary(player, library, std.testing.io);
    try runtime.playerPlayTracksBound(player, library, ids[0..3], 0);
    try runtime.pausePlayer(player);

    try runtime.playerQueueInsertNext(player, library, ids[3..4]);
    var queued = try runtime.playerQueueTracks(player, std.testing.allocator, 0, 8);
    defer queued.deinit();
    try std.testing.expectEqual(@as(usize, 4), queued.items.len);
    try std.testing.expectEqual(ids[0], queued.items[0].id);
    try std.testing.expectEqual(ids[3], queued.items[1].id);
    try std.testing.expectEqual(ids[1], queued.items[2].id);

    try std.testing.expectError(error.QueueEntryInUse, runtime.playerQueueRemove(player, 0));
    try runtime.playerQueueRemove(player, 2);
    try std.testing.expectEqual(@as(u32, 3), (try runtime.playerStatus(player)).queue_length);

    try runtime.playerQueueJump(player, 2);
    const status = try runtime.playerStatus(player);
    try std.testing.expectEqual(@as(u32, 2), status.queue_index);
    try std.testing.expectEqual(ids[2], status.track_id.?);
    try std.testing.expectError(error.PositionOutOfRange, runtime.playerQueueJump(player, 3));
}

test "a root cannot be removed while a job runs on its library, and afterwards its tracks leave the library" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try copyFixtureInto(temporary.dir, "fixtures/audio/covered-reference.mp3", "a.mp3");
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "b.flac");
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(root);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-runtime-remove-root?mode=memory&cache=shared");
    const binding = try runtime.libraryAddRoot(library, std.testing.io, root);

    const scan_of_root = try runtime.startLibraryScan(library, .{ .root_id = binding.root_id });
    try std.testing.expectError(error.LibraryJobRunning, runtime.libraryRemoveRoot(library, binding.root_id));
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, scan_of_root));

    const scan_of_all = try runtime.startLibraryScan(library, .{});
    try std.testing.expectError(error.LibraryJobRunning, runtime.libraryRemoveRoot(library, binding.root_id));
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, scan_of_all));

    var before = try runtime.libraryTrackQuery(library, "", .{ .limit = 16 });
    const tracks_before = before.items.len;
    before.deinit();
    try std.testing.expect(tracks_before != 0);

    const removed = try runtime.libraryRemoveRoot(library, binding.root_id);
    try std.testing.expectEqual(@as(u64, 2), removed.files_forgotten);
    try std.testing.expectEqual(@as(u64, tracks_before), removed.tracks_removed);
    var after = try runtime.libraryTrackQuery(library, "", .{ .limit = 16 });
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 0), after.items.len);
    var roots = try runtime.libraryRootPage(library, 16, 0);
    defer roots.deinit();
    try std.testing.expectEqual(@as(usize, 0), roots.items.len);
    try std.testing.expectError(error.UnknownRoot, runtime.libraryRemoveRoot(library, binding.root_id));
    try std.Io.Dir.cwd().access(std.testing.io, root, .{});
}

/// A library over a temporary root holding `A/one.flac` and `B/two.mp3`,
/// scanned once in full.
const ReconcileFixture = struct {
    temporary: std.testing.TmpDir,
    runtime: OrcaRuntime,
    root: []u8,
    library: LibraryHandle,
    root_id: i64,

    fn init(self: *ReconcileFixture, name: [:0]const u8) !void {
        self.temporary = std.testing.tmpDir(.{});
        errdefer self.temporary.cleanup();
        try self.temporary.dir.createDirPath(std.testing.io, "A");
        try self.temporary.dir.createDirPath(std.testing.io, "B");
        try copyFixtureInto(self.temporary.dir, "fixtures/audio/tagged-reference.flac", "A/one.flac");
        try copyFixtureInto(self.temporary.dir, "fixtures/audio/covered-reference.mp3", "B/two.mp3");
        self.root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{self.temporary.sub_path});
        errdefer std.testing.allocator.free(self.root);
        self.runtime = OrcaRuntime.init(std.testing.allocator);
        errdefer self.runtime.deinit();
        self.library = try self.runtime.openLibrary(std.testing.io, name);
        self.root_id = (try self.runtime.libraryAddRoot(self.library, std.testing.io, self.root)).root_id;
        try std.testing.expectEqual(job.State.succeeded, try awaitJob(&self.runtime, try self.runtime.startLibraryScan(self.library, .{ .root_id = self.root_id })));
    }

    fn deinit(self: *ReconcileFixture) void {
        self.runtime.deinit();
        std.testing.allocator.free(self.root);
        self.temporary.cleanup();
    }

    fn reconcile(self: *ReconcileFixture, subtrees: []const []const u8) !struct { state: job.State, stats: runtime_module.ScanStats } {
        const job_handle = try self.runtime.startLibraryReconcile(self.library, .{
            .root_id = self.root_id,
            .scope = .{ .subtrees = subtrees },
        });
        const state = try awaitJob(&self.runtime, job_handle);
        return .{ .state = state, .stats = try self.runtime.jobScanStats(job_handle) };
    }

    fn location(self: *ReconcileFixture, relative: []const u8) !?StoredLocation {
        const uri = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ self.root, relative });
        defer std.testing.allocator.free(uri);
        const library_database = try libraryDatabase(&self.runtime, self.library);
        var statement = try library_database.database.prepare(
            "SELECT state, last_seen_generation, file_id FROM locations WHERE uri=?1;",
        );
        defer statement.deinit();
        try statement.bindText(1, uri);
        if (try statement.step() != .row) return null;
        return .{
            .state = database.LocationState.parse(statement.columnText(0)).?,
            .generation = statement.columnInt64(1),
            .file_id = statement.columnInt64(2),
        };
    }

    fn locationCount(self: *ReconcileFixture) !u64 {
        return (try libraryDatabase(&self.runtime, self.library)).locations.count();
    }
};

const StoredLocation = struct {
    state: database.LocationState,
    generation: i64,
    file_id: i64,
};

test "a subtree reconcile records a file added under that directory and leaves sibling directories' locations untouched" {
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-reconcile-added?mode=memory&cache=shared");
    defer fixture.deinit();
    const sibling_before = (try fixture.location("B/two.mp3")).?;
    try fixture.temporary.dir.createDirPath(std.testing.io, "A/New");
    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "A/New/three.m4a");

    const outcome = try fixture.reconcile(&.{"A"});
    try std.testing.expectEqual(job.State.succeeded, outcome.state);
    try std.testing.expectEqual(@as(u64, 1), outcome.stats.changed);
    try std.testing.expectEqual(@as(u64, 1), outcome.stats.unchanged);
    try std.testing.expectEqual(@as(u64, 0), outcome.stats.marked_missing);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("A/New/three.m4a")).?.state);
    try std.testing.expectEqual(sibling_before, (try fixture.location("B/two.mp3")).?);
}

test "a subtree reconcile marks a deleted file under the directory missing" {
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-reconcile-deleted?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.temporary.dir.deleteFile(std.testing.io, "A/one.flac");
    try fixture.temporary.dir.deleteFile(std.testing.io, "B/two.mp3");

    const outcome = try fixture.reconcile(&.{"A"});
    try std.testing.expectEqual(job.State.succeeded, outcome.state);
    try std.testing.expectEqual(@as(u64, 1), outcome.stats.marked_missing);
    try std.testing.expectEqual(database.LocationState.missing, (try fixture.location("A/one.flac")).?.state);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("B/two.mp3")).?.state);
}

test "reconciling a deleted directory marks everything under it missing" {
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-reconcile-deleted-directory?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.temporary.dir.deleteTree(std.testing.io, "A");

    const outcome = try fixture.reconcile(&.{"A"});
    try std.testing.expectEqual(job.State.succeeded, outcome.state);
    try std.testing.expectEqual(@as(u64, 0), outcome.stats.files_seen);
    try std.testing.expectEqual(@as(u64, 1), outcome.stats.marked_missing);
    try std.testing.expectEqual(database.LocationState.missing, (try fixture.location("A/one.flac")).?.state);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("B/two.mp3")).?.state);
}

test "a rename within a reconciled directory keeps the file's identity at its new uri and marks the old one missing" {
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-reconcile-rename?mode=memory&cache=shared");
    defer fixture.deinit();
    const before = (try fixture.location("A/one.flac")).?;
    try std.Io.Dir.rename(fixture.temporary.dir, "A/one.flac", fixture.temporary.dir, "A/renamed.flac", std.testing.io);

    const outcome = try fixture.reconcile(&.{"A"});
    try std.testing.expectEqual(job.State.succeeded, outcome.state);
    const renamed = (try fixture.location("A/renamed.flac")).?;
    try std.testing.expectEqual(database.LocationState.present, renamed.state);
    try std.testing.expectEqual(before.file_id, renamed.file_id);
    try std.testing.expectEqual(database.LocationState.missing, (try fixture.location("A/one.flac")).?.state);
}

test "reconciling a directory never sweeps a sibling whose name starts with the directory's" {
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-reconcile-prefix?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.temporary.dir.createDirPath(std.testing.io, "A/New");
    try fixture.temporary.dir.createDirPath(std.testing.io, "A/Newer");
    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "A/New/three.m4a");
    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference.ogg", "A/Newer/four.ogg");
    try std.testing.expectEqual(job.State.succeeded, (try fixture.reconcile(&.{"A"})).state);
    try fixture.temporary.dir.deleteFile(std.testing.io, "A/New/three.m4a");
    try fixture.temporary.dir.deleteFile(std.testing.io, "A/Newer/four.ogg");

    const outcome = try fixture.reconcile(&.{"A/New"});
    try std.testing.expectEqual(job.State.succeeded, outcome.state);
    try std.testing.expectEqual(@as(u64, 1), outcome.stats.marked_missing);
    try std.testing.expectEqual(database.LocationState.missing, (try fixture.location("A/New/three.m4a")).?.state);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("A/Newer/four.ogg")).?.state);
}

test "an unreadable subdirectory fails the reconcile and sweeps nothing under its directory, while the other directories are swept" {
    if (builtin.os.tag != .linux or std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-reconcile-unreadable?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.temporary.dir.createDirPath(std.testing.io, "A/locked");
    try fixture.temporary.dir.deleteFile(std.testing.io, "A/one.flac");
    try fixture.temporary.dir.deleteFile(std.testing.io, "B/two.mp3");
    try fixture.temporary.dir.setFilePermissions(std.testing.io, "A/locked", .fromMode(0), .{});
    defer fixture.temporary.dir.setFilePermissions(std.testing.io, "A/locked", .default_dir, .{}) catch {};

    const outcome = try fixture.reconcile(&.{ "A", "B" });
    try std.testing.expectEqual(job.State.failed, outcome.state);
    try std.testing.expectEqual(@as(u64, 1), outcome.stats.errors);
    try std.testing.expectEqual(@as(u64, 1), outcome.stats.marked_missing);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("A/one.flac")).?.state);
    try std.testing.expectEqual(database.LocationState.missing, (try fixture.location("B/two.mp3")).?.state);
}

test "a second scan or reconcile of a library is refused while one runs" {
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-reconcile-concurrent?mode=memory&cache=shared");
    defer fixture.deinit();
    const library_database = try libraryDatabase(&fixture.runtime, fixture.library);
    library_database.write_lane.acquire();
    const running = fixture.runtime.startLibraryScan(fixture.library, .{ .root_id = fixture.root_id }) catch |err| {
        library_database.write_lane.release();
        return err;
    };
    const second_scan = fixture.runtime.startLibraryScan(fixture.library, .{});
    const reconcile = fixture.runtime.startLibraryReconcile(fixture.library, .{ .root_id = fixture.root_id });
    library_database.write_lane.release();
    try std.testing.expectError(error.LibraryScanRunning, second_scan);
    try std.testing.expectError(error.LibraryScanRunning, reconcile);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&fixture.runtime, running));
    try std.testing.expectEqual(job.State.succeeded, (try fixture.reconcile(&.{"A"})).state);
}

test "a reconciled directory names each file with the uri a full scan gave it" {
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-reconcile-uris?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.temporary.dir.createDirPath(std.testing.io, "A/b/c");
    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "A/b/c/deep.m4a");
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&fixture.runtime, try fixture.runtime.startLibraryScan(fixture.library, .{ .root_id = fixture.root_id })));
    const locations = try fixture.locationCount();

    const outcome = try fixture.reconcile(&.{ "A/b", "A/b/c" });
    try std.testing.expectEqual(job.State.succeeded, outcome.state);
    try std.testing.expectEqual(@as(u64, 1), outcome.stats.files_seen);
    try std.testing.expectEqual(@as(u64, 1), outcome.stats.unchanged);
    try std.testing.expectEqual(@as(u64, 0), outcome.stats.changed);
    try std.testing.expectEqual(locations, try fixture.locationCount());
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("A/b/c/deep.m4a")).?.state);
}
