const std = @import("std");
const builtin = @import("builtin");
const analysis_service = @import("../analysis/service.zig");
const artwork = @import("artwork.zig");
const browse_loader = @import("browse_loader.zig");
const audio = @import("../audio/root.zig");
const control = @import("control.zig");
const database = @import("../database/root.zig");
const library_pass = @import("../library/root.zig");
const metadata = @import("../metadata/root.zig");
const network = @import("../network/root.zig");
const job = @import("job.zig");
const job_worker = @import("job_worker.zig");
const object = @import("object.zig");
const storage = @import("../storage/root.zig");
const work = @import("work.zig");
const runtime_module = @import("runtime.zig");
const runtime_zones = @import("runtime_zones.zig");
const runtime_queue = @import("runtime_queue.zig");
const runtime_provider_tests = @import("runtime_provider_tests.zig");

const ArtworkResult = runtime_module.ArtworkResult;
const BrowseResult = runtime_module.BrowseResult;
const JobHandle = runtime_module.JobHandle;
const LibraryHandle = runtime_module.LibraryHandle;
const OrcaRuntime = runtime_module.OrcaRuntime;
const QueueHistoryEntry = runtime_module.QueueHistoryEntry;
const QueueHistoryReason = runtime_module.QueueHistoryReason;
const State = runtime_module.State;
const TagWriteFailureReason = runtime_module.TagWriteFailureReason;
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
    const binding = try addFixturesRoot(&runtime, library);
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
    const binding = try addFixturesRoot(&runtime, library);
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
    const binding = try addFixturesRoot(&runtime, library);
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

/// Two WAVE files of one size whose first and last 64 KiB match and whose
/// middles differ, so their quick hashes are equal and their bytes are not.
fn writeQuickHashTwins(dir: std.Io.Dir, first: []const u8, second: []const u8) !void {
    const frames = 100_000;
    try runtime_provider_tests.writeSilentWave(dir, first, frames);
    try runtime_provider_tests.writeSilentWave(dir, second, frames);
    const file = try dir.openFile(std.testing.io, second, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "middle", 44 + frames);
}

test "two files whose quick hashes collide stay two files and neither is an exact duplicate" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeQuickHashTwins(temporary.dir, "one.wav", "two.wav");
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempFolder(&runtime, &temporary, "file:orca-scan-quick-hash-twins?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    try std.testing.expectEqual(@as(u64, 2), try library_database.files.count());
    var statement = try library_database.database.prepare("SELECT file_id FROM locations ORDER BY id;");
    defer statement.deinit();
    while (try statement.step() == .row) {
        const copy = try library_database.locations.secondPresentPath(std.testing.allocator, statement.columnInt64(0));
        defer if (copy) |path| std.testing.allocator.free(path);
        try std.testing.expectEqual(@as(?[]u8, null), copy);
    }

    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryDuplicateScan(library, .{})));
    var exact = try library_database.health_issues.pageOfKind(std.testing.allocator, .exact_duplicate, 8, 0);
    defer exact.deinit();
    try std.testing.expectEqual(@as(usize, 0), exact.items.len);
}

/// The duplicate kind recorded for the file at the path ending in `suffix`,
/// or null when it has none.
fn duplicateKindAt(library_database: *database.LibraryDatabase, suffix: []const u8) !?database.HealthIssueKind {
    var statement = try library_database.database.prepare(
        \\SELECT library_health_issues.kind FROM library_health_issues
        \\JOIN locations ON locations.file_id = library_health_issues.file_id
        \\WHERE locations.uri LIKE '%' || ?1 AND library_health_issues.kind IN (?2, ?3, ?4);
    );
    defer statement.deinit();
    try statement.bindText(1, suffix);
    try statement.bindInt64(2, @backingInt(database.HealthIssueKind.exact_duplicate));
    try statement.bindInt64(3, @backingInt(database.HealthIssueKind.identical_audio));
    try statement.bindInt64(4, @backingInt(database.HealthIssueKind.likely_duplicate));
    if (try statement.step() != .row) return null;
    const kind = std.enums.fromInt(database.HealthIssueKind, statement.columnInt64(0)).?;
    if (try statement.step() == .row) return error.MoreThanOneDuplicateKind;
    return kind;
}

test "a WAV of a FLAC and an ALAC of a FLAC are identical audio, and a QOA of a WAV is at most a likely duplicate" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const fixtures = [_][]const u8{
        "tagged-reference.wav",
        "generated-reference.flac",
        "tagged-reference-alac.m4a",
        "tagged-reference.flac",
        "generated-reference.wav",
        "stereo-reference.qoa",
    };
    for (fixtures) |name| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "fixtures/audio/{s}", .{name});
        defer std.testing.allocator.free(source);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, source, std.testing.allocator, .limited(1 << 22));
        defer std.testing.allocator.free(bytes);
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
    }
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempFolder(&runtime, &temporary, "file:orca-duplicate-ladder-fixtures?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryAnalysis(library, .{ .threads = 1 })));
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryDuplicateScan(library, .{})));

    for (fixtures[0..4]) |name| {
        try std.testing.expectEqual(@as(?database.HealthIssueKind, .identical_audio), try duplicateKindAt(library_database, name));
    }
    for (fixtures[4..]) |name| {
        const kind = try duplicateKindAt(library_database, name);
        try std.testing.expect(kind == null or kind.? == .likely_duplicate);
    }
}

test "a scan Job reports the files its walk will reach as its total" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-scan-job-total?mode=memory&cache=shared",
    );
    const binding = try addFixturesRoot(&runtime, library);
    const job_handle = try runtime.startLibraryScan(library, .{ .root_id = binding.root_id });
    while (true) {
        runtime.reapFinishedJobs();
        const snapshot = try runtime.jobSnapshotSynced(job_handle);
        if (snapshot.total_units) |total| try std.testing.expect(snapshot.completed_units <= total);
        if (snapshot.state == .succeeded) break;
        if (snapshot.state == .failed or snapshot.state == .cancelled)
            return error.ScanDidNotSucceed;
        std.Thread.yield() catch {};
    }
    const snapshot = try runtime.jobSnapshotSynced(job_handle);
    const stats = try runtime.jobScanStats(job_handle);
    try std.testing.expect(stats.files_seen > 0);
    try std.testing.expectEqual(@as(?u64, stats.files_seen), snapshot.total_units);
    try std.testing.expectEqual(stats.files_seen, snapshot.completed_units);

    const reconcile = try runtime.startLibraryReconcile(library, .{
        .root_id = binding.root_id,
        .scope = .{ .subtrees = &.{ "Missing", "Missing Too" } },
    });
    while (true) {
        runtime.reapFinishedJobs();
        const state = (try runtime.jobSnapshotSynced(reconcile)).state;
        if (state == .succeeded) break;
        if (state == .failed or state == .cancelled) return error.ReconcileDidNotSucceed;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(?u64, 0), (try runtime.jobSnapshotSynced(reconcile)).total_units);
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
    const binding = try addFixturesRoot(runtime, library);
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

test "library stats after a scan agree with the browse counts and gain an analysis time once the library is analysed" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scanFixtureLibrary(&runtime, "file:orca-library-stats-scan?mode=memory&cache=shared");

    const scanned = try runtime.libraryStats(library);
    try std.testing.expectEqual(try runtime.libraryArtistCount(library), scanned.artists);
    try std.testing.expectEqual(try runtime.libraryReleaseCount(library), scanned.releases);
    try std.testing.expectEqual(try runtime.libraryTrackCount(library), scanned.tracks);
    try std.testing.expect(scanned.files > 0);
    try std.testing.expect(scanned.total_bytes > 0);
    try std.testing.expect(scanned.total_duration_ms > 0);
    try std.testing.expect(scanned.last_scan_finished_at != null);
    try std.testing.expectEqual(@as(?i64, null), scanned.last_analysis_at);

    const job_handle = try runtime.startLibraryAnalysis(library, .{ .threads = 1 });
    while (true) {
        runtime.reapFinishedJobs();
        const snapshot = try runtime.jobSnapshotSynced(job_handle);
        if (snapshot.state == .succeeded) break;
        if (snapshot.state == .failed or snapshot.state == .cancelled)
            return error.AnalysisDidNotSucceed;
        std.Thread.yield() catch {};
    }
    const analysed = try runtime.libraryStats(library);
    try std.testing.expect(analysed.last_analysis_at != null);
    try std.testing.expect(analysed.last_analysis_at.? >= scanned.last_scan_finished_at.?);
    try std.testing.expectEqual(scanned.files, analysed.files);
}

test "backfill pending counts the files and covers a backfill would repair, and the backfill leaves only what it cannot" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scanFixtureLibrary(&runtime, "file:orca-backfill-pending?mode=memory&cache=shared");
    const availability = try runtime.libraryAvailability(library, std.testing.io);
    defer availability.deinit();
    const scanned = try runtime.libraryBackfillPending(library, &availability);

    const library_database = try libraryDatabase(&runtime, library);
    try library_database.database.exec(
        \\UPDATE observed_file_tags SET artwork_width = NULL, artwork_height = NULL, artwork_hash = NULL
        \\WHERE artwork_byte_size > 0;
        \\UPDATE files SET duration_ms = NULL
        \\WHERE id = (SELECT min(file_id) FROM observed_file_tags WHERE artwork_byte_size > 0);
    );
    const covers: u64 = @intCast(try database.columns.scalar(
        library_database.database,
        "SELECT count(*) FROM observed_file_tags WHERE artwork_byte_size > 0;",
    ));
    try std.testing.expect(covers > 0);
    try std.testing.expectEqual(runtime_module.BackfillPending{
        .files = scanned.files + 1,
        .covers = scanned.covers + covers,
    }, try runtime.libraryBackfillPending(library, &availability));

    const job_handle = try runtime.startLibraryPropertyBackfill(library, .{});
    while (true) {
        runtime.reapFinishedJobs();
        const snapshot = try runtime.jobSnapshotSynced(job_handle);
        if (snapshot.state == .succeeded) break;
        if (snapshot.state == .failed or snapshot.state == .cancelled)
            return error.BackfillDidNotSucceed;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(scanned, try runtime.libraryBackfillPending(library, &availability));
}

test "backfill pending leaves out a file the backfill already found unreadable, while the backfill still tries it" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "music");
    {
        const reference = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            "fixtures/audio/generated-reference.flac",
            std.testing.allocator,
            .limited(1 << 22),
        );
        defer std.testing.allocator.free(reference);
        const music = try temporary.dir.openDir(std.testing.io, "music", .{});
        defer music.close(std.testing.io);
        try music.writeFile(std.testing.io, .{ .sub_path = "truncated.flac", .data = reference[0..30] });
    }
    const root = try absoluteTestPath(".zig-cache/tmp/{s}/music", .{temporary.sub_path});
    defer std.testing.allocator.free(root);

    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-backfill-pending-unreadable?mode=memory&cache=shared");
    const binding = try runtime.libraryAddRoot(library, std.testing.io, root);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryScan(library, .{ .root_id = binding.root_id })));
    const availability = try runtime.libraryAvailability(library, std.testing.io);
    defer availability.deinit();

    const library_database = try libraryDatabase(&runtime, library);
    try library_database.database.exec("DELETE FROM library_health_issues;");
    try std.testing.expectEqual(
        runtime_module.BackfillPending{ .files = 1, .covers = 0 },
        try runtime.libraryBackfillPending(library, &availability),
    );

    const first = try runtime.startLibraryPropertyBackfill(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, first));
    const tried = try runtime.jobScanStats(first);
    try std.testing.expectEqual(@as(u64, 1), tried.files_seen);
    try std.testing.expectEqual(@as(u64, 1), tried.errors);
    try std.testing.expectEqual(
        runtime_module.BackfillPending{ .files = 0, .covers = 0 },
        try runtime.libraryBackfillPending(library, &availability),
    );

    const second = try runtime.startLibraryPropertyBackfill(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, second));
    try std.testing.expectEqual(@as(u64, 1), (try runtime.jobScanStats(second)).files_seen);
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

/// Records the content hash of the bytes at `facts.path` on its file, as an
/// analysis pass that read them would.
fn recordContentHash(
    library_database: *database.LibraryDatabase,
    facts: database.repository.TrackFileFacts,
) !storage.content_hash.Digest {
    const digest = try storage.content_hash.fromPath(std.testing.io, facts.path.?);
    var statement = try library_database.database.prepare(
        "UPDATE files SET content_hash = ?1, content_hash_algorithm = 1 WHERE id = ?2;",
    );
    defer statement.deinit();
    try statement.bindBlob(1, &digest);
    try statement.bindInt64(2, facts.file_id);
    if (try statement.step() != .done) return error.TestUnexpectedResult;
    return digest;
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
        .clipped_runs = 0,
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
        analysis_service.diagnosticsKey(facts.file_id, try recordContentHash(library_database, facts), .{}),
        encoded,
    );

    const mp3 = try scannedFixtureDetails(&runtime, library, "covered-reference.mp3");
    defer mp3.deinit();
    const mp3_facts = (try library_database.tracks.fileFacts(std.testing.allocator, mp3.track_id)).?;
    defer mp3_facts.deinit();
    _ = try recordContentHash(library_database, mp3_facts);
    const stale_identity: storage.quick_hash.Digest = @splat(7);
    try library_database.analysis_cache.put(
        analysis_service.diagnosticsKey(mp3_facts.file_id, stale_identity, .{}),
        encoded,
    );
    try library_database.analysis_cache.put(
        analysis_service.diagnosticsKey(mp3_facts.file_id, mp3_facts.quick_hash.?, .{}),
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
    const binding = try addFixturesRoot(&runtime, library);
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

test "enumerated output devices carry the capabilities their backend reports" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    var devices: [4]audio.backend.Device = undefined;
    try std.testing.expectEqual(@as(usize, 1), try runtime.enumerateOutputDevices(&devices, .capabilities));
    try std.testing.expectEqual(audio.output.TestBackend.test_capabilities, devices[0].capabilities.?);
}

test "identity enumeration leaves device capabilities unknown" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    var devices: [4]audio.backend.Device = undefined;
    try std.testing.expectEqual(@as(usize, 1), try runtime.enumerateOutputDevices(&devices, .identity));
    try std.testing.expectEqual(@as(?audio.backend.DeviceCapabilities, null), devices[0].capabilities);
}

fn hasReason(path: audio.dsp.SignalPath, reason: audio.signal_path.Reason) bool {
    return std.mem.indexOfScalar(audio.signal_path.Reason, path.reasonList(), reason) != null;
}

test "a Player's signal path names the open device's kind and quantum, and neither once the output closes" {
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

    var path = try runtime.playerSignalPath(player);
    try std.testing.expectEqual(audio.backend.DeviceKind.unknown, path.output_kind);
    try std.testing.expectEqual(@as(?u32, null), path.device_quantum_frames);

    try runtime.zoneRequestOutput(zone, 1);
    try runtime.playPlayer(player);
    var samples: [512]f32 = @splat(0);
    var deadline: TestDeadline = .init(5_000);
    while (path.device_quantum_frames == null and deadline.tick()) {
        if (deadline.remaining_ms % 5 != 0) continue;
        if (backend.liveStream()) |stream| stream.pump(&samples, 256);
        path = try runtime.playerSignalPath(player);
    }
    try std.testing.expect(path.output != null);
    try std.testing.expectEqual(@as(?u32, 256), path.device_quantum_frames);
    try std.testing.expectEqual(audio.backend.DeviceKind.virtual, path.output_kind);
    const discoveries = backend.discoveries.load(.monotonic);
    try std.testing.expectEqual(@as(usize, 1), discoveries);
    for (0..8) |_| path = try runtime.playerSignalPath(player);
    try std.testing.expectEqual(audio.backend.DeviceKind.virtual, path.output_kind);
    try std.testing.expectEqual(discoveries, backend.discoveries.load(.monotonic));

    try runtime.zoneCloseOutput(zone);
    deadline = .init(5_000);
    while (path.output != null and deadline.tick()) {
        if (deadline.remaining_ms % 5 != 0) continue;
        path = try runtime.playerSignalPath(player);
    }
    try std.testing.expectEqual(@as(?audio.pcm.Format, null), path.output);
    try std.testing.expectEqual(audio.backend.DeviceKind.unknown, path.output_kind);

    try runtime.destroyZone(zone);
    try runtime.destroyPlayer(player);
}

test "a Player's signal path names the device's own format while its output is open" {
    const device_format: audio.backend.DeviceFormat = .{
        .sample_format = .signed_24_32,
        .sample_rate = 48_000,
        .channels = 2,
    };
    var backend: audio.output.TestBackend = .{
        .allocator = std.testing.allocator,
        .device_format = device_format,
    };
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

    var path = try runtime.playerSignalPath(player);
    try std.testing.expectEqual(@as(?audio.backend.DeviceFormat, null), path.device_format);

    try runtime.zoneRequestOutput(zone, 1);
    try runtime.playPlayer(player);
    var samples: [512]f32 = @splat(0);
    var deadline: TestDeadline = .init(5_000);
    while (path.device_format == null and deadline.tick()) {
        if (deadline.remaining_ms % 5 != 0) continue;
        if (backend.liveStream()) |stream| stream.pump(&samples, 256);
        path = try runtime.playerSignalPath(player);
    }
    try std.testing.expectEqual(device_format, path.device_format.?);
    try std.testing.expect(!path.bit_perfect_eligible);
    try std.testing.expect(hasReason(path, .sample_format_conversion));
    try std.testing.expect(!hasReason(path, .sample_rate_conversion));

    try runtime.zoneCloseOutput(zone);
    deadline = .init(5_000);
    while (path.output != null and deadline.tick()) {
        if (deadline.remaining_ms % 5 != 0) continue;
        path = try runtime.playerSignalPath(player);
    }
    try std.testing.expectEqual(@as(?audio.backend.DeviceFormat, null), path.device_format);
    try std.testing.expect(!hasReason(path, .sample_format_conversion));

    try runtime.destroyZone(zone);
    try runtime.destroyPlayer(player);
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
    try std.testing.expectEqual(audio.backend.DeviceKind.unknown, path.output_kind);

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

const test_parametric_filters = [_]audio.dsp.Filter{
    .{ .kind = .low_shelf, .frequency_hz = 105, .gain_db = 3, .q = 0.71 },
    .{ .kind = .peak, .frequency_hz = 1000, .gain_db = -2, .q = 1.41 },
    .{ .kind = .peak, .frequency_hz = 3000, .gain_db = 2.5, .q = 2 },
    .{ .kind = .high_shelf, .frequency_hz = 10_000, .gain_db = -1.5, .q = 0.71 },
};

fn testParametric(filters: []const audio.dsp.Filter, preamp_db: f32) audio.dsp.ParametricEqualizer {
    var value: audio.dsp.ParametricEqualizer = .{ .count = @intCast(filters.len), .preamp_db = preamp_db };
    @memcpy(value.filters[0..filters.len], filters);
    return value;
}

test "the parametric equalizer rejects out-of-range filters and keeps the last valid setting" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const player = try runtime.createPlayer();

    var bad = test_parametric_filters;
    bad[2].q = 0;
    try std.testing.expectError(
        error.FilterQOutOfRange,
        runtime.playerSetParametricEqualizer(player, testParametric(&bad, -3)),
    );
    try std.testing.expectError(
        error.ParametricPreampOutOfRange,
        runtime.playerSetParametricEqualizer(player, testParametric(&test_parametric_filters, 7)),
    );
    try std.testing.expect(try runtime.playerParametricEqualizer(player) == null);

    const setting = testParametric(&test_parametric_filters, -3);
    try runtime.playerSetParametricEqualizer(player, setting);
    bad = test_parametric_filters;
    bad[0].frequency_hz = 25_000;
    try std.testing.expectError(
        error.FilterFrequencyOutOfRange,
        runtime.playerSetParametricEqualizer(player, testParametric(&bad, -3)),
    );
    const kept = (try runtime.playerParametricEqualizer(player)).?;
    try std.testing.expectEqualSlices(audio.dsp.Filter, setting.filterList(), kept.filterList());
    try std.testing.expectEqual(@as(f32, -3), kept.preamp_db);
}

test "turning either equalizer on turns the other off, so the ten-band one reads null while the parametric one runs" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const player = try runtime.createPlayer();
    const setting = testParametric(&test_parametric_filters, -3);

    try runtime.playerSetEqualizer(player, audio.dsp.Equalizer.preset(.bass));
    try runtime.playerSetParametricEqualizer(player, setting);
    try std.testing.expectEqual(@as(?audio.dsp.Equalizer, null), try runtime.playerEqualizer(player));
    try std.testing.expectEqualSlices(
        audio.dsp.Filter,
        setting.filterList(),
        (try runtime.playerParametricEqualizer(player)).?.filterList(),
    );

    try runtime.playerSetEqualizer(player, audio.dsp.Equalizer.preset(.treble));
    try std.testing.expect(try runtime.playerParametricEqualizer(player) == null);
    try std.testing.expectEqual(
        @as(?audio.dsp.Equalizer, audio.dsp.Equalizer.preset(.treble)),
        try runtime.playerEqualizer(player),
    );

    try runtime.playerSetParametricEqualizer(player, null);
    try std.testing.expectEqual(
        @as(?audio.dsp.Equalizer, audio.dsp.Equalizer.preset(.treble)),
        try runtime.playerEqualizer(player),
    );
}

/// Frames the render callback can still emit without waiting on the producer.
/// Only the consumer may call it, between callbacks: `current` is its own.
fn queuedFrames(pipe: anytype) u64 {
    var frames: u64 = if (pipe.current) |block| block.frames - pipe.current_frame else 0;
    const tail = pipe.ready.tail.load(.acquire);
    var head = pipe.ready.head.load(.monotonic);
    while (head != tail) : (head +%= 1)
        frames += pipe.ready.items[head % pipe.ready.items.len].frames;
    return frames;
}

test "a parametric change and signal path reads mid-queue cost no audio across a gapless transition" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const fixtures = try openFixtureLibrary(
        &runtime,
        "file:orca-parametric-gapless?mode=memory&cache=shared",
        &.{
            "fixtures/audio/generated-reference.flac",
            "./fixtures/audio/generated-reference.flac",
        },
    );
    const entry_frames = 480;
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.setZonePolicy(zone, .interactive);
    try runtime.attachZone(zone, player);
    try runtime.zoneRequestOutput(zone, 0);
    try runtime.playerPlayTracks(player, fixtures.library, std.testing.io, fixtures.ids[0..2], 0);

    var deadline: TestDeadline = .init(5_000);
    while (try runtime.zoneOutputState(zone) != .active and deadline.tick()) {}
    const stream = backend.liveStream() orelse return error.OutputNeverOpened;
    const channels = stream.request.format.channels;
    const runtime_zone = (try runtime.zones.get(zone)).zone;
    const epoch = (try runtime.playerSnapshot(player)).epoch;
    const setting = testParametric(&test_parametric_filters, -3);

    var samples: [256 * audio.zone_runtime.max_channels]f32 = undefined;
    var requested: u64 = 0;
    var serials: [2]u32 = @splat(0);
    var serial_count: usize = 0;
    var changed = false;
    while (requested < 2 * entry_frames) {
        const frames: u32 = @intCast(@min(256, 2 * entry_frames - requested));
        deadline = .init(5_000);
        while (queuedFrames(&runtime_zone.pipe) < frames and deadline.tick()) {}
        stream.pump(samples[0 .. frames * channels], frames);
        requested += frames;

        const serial = (try runtime.zoneStats(zone)).rendered_entry_serial;
        if (serial_count == 0 or serials[serial_count - 1] != serial) {
            try std.testing.expect(serial_count < serials.len);
            serials[serial_count] = serial;
            serial_count += 1;
            const path = try runtime.playerSignalPath(player);
            if (changed) {
                try std.testing.expectEqualSlices(
                    audio.dsp.Filter,
                    setting.filterList(),
                    path.parametric.?.filterList(),
                );
                try std.testing.expect(hasReason(path, .sample_processing));
            } else {
                try std.testing.expect(path.parametric == null);
                try std.testing.expect(!hasReason(path, .sample_processing));
            }
        }
        if (!changed and requested < entry_frames) {
            try runtime.playerSetParametricEqualizer(player, setting);
            changed = true;
        }
    }

    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 2), serial_count);
    try std.testing.expectEqual(serials[0] + 1, serials[1]);
    try std.testing.expectEqual(@as(u64, 0), (try runtime.zoneStats(zone)).underruns);
    const position = runtime_zone.position.load(.acquire);
    try std.testing.expectEqual(@as(u16, @truncate(epoch)), audio.render.positionEpoch(position));
    try std.testing.expectEqual(@as(u64, 2 * entry_frames), audio.render.positionFrames(position));
    try std.testing.expectEqual(epoch, (try runtime.playerSnapshot(player)).epoch);

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

fn expectZoneSetAdopted(engine: *const audio.engine.PlayerEngine) !void {
    try std.testing.expectEqual(engine.control_sequence, engine.ack.load(.acquire));
}

test "a Zone attached and destroyed right after play is adopted by the engine before each call returns" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const player = try runtime.createPlayer();
    const playing = try runtime.createZone();
    try runtime.attachZone(playing, player);
    try runtime.playerLoadFile(player, std.testing.io, "fixtures/audio/generated-reference.wav");
    try runtime.playPlayer(player);
    const engine = (try runtime.players.get(player)).engine orelse return error.EngineNeverStarted;

    const added = try runtime.createZone();
    try runtime.attachZone(added, player);
    try expectZoneSetAdopted(engine);
    try runtime.destroyZone(added);
    try expectZoneSetAdopted(engine);
}

test "a Zone attached, moved, detached or destroyed while its Player's engine starts waits for that engine to adopt the change" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());
    const zone = try runtime.createZone();

    const attached = try runtime.createPlayer();
    const attached_engine = try runtime_queue.ensureEngine(&runtime, attached);
    try runtime.attachZone(zone, attached);
    try expectZoneSetAdopted(attached_engine);

    const moved_from = try runtime.createPlayer();
    const moved_to = try runtime.createPlayer();
    try runtime.attachZone(zone, moved_from);
    const from_engine = try runtime_queue.ensureEngine(&runtime, moved_from);
    const to_engine = try runtime_queue.ensureEngine(&runtime, moved_to);
    try runtime.attachZone(zone, moved_to);
    try expectZoneSetAdopted(from_engine);
    try expectZoneSetAdopted(to_engine);

    const detached = try runtime.createPlayer();
    try runtime.attachZone(zone, detached);
    const detached_engine = try runtime_queue.ensureEngine(&runtime, detached);
    try runtime.detachZone(zone);
    try expectZoneSetAdopted(detached_engine);

    const destroyed = try runtime.createPlayer();
    try runtime.attachZone(zone, destroyed);
    const destroyed_engine = try runtime_queue.ensureEngine(&runtime, destroyed);
    try runtime.destroyZone(zone);
    try expectZoneSetAdopted(destroyed_engine);
}

test "destroying a Player right after its engine thread is spawned joins that thread" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const player = try runtime.createPlayer();
    _ = try runtime_queue.ensureEngine(&runtime, player);
    try runtime.destroyPlayer(player);

    try std.testing.expectEqual(@as(usize, 0), inFlightWorkCount(&runtime));
}

fn awaitZoneActive(runtime: *OrcaRuntime, zone: ZoneHandle) !void {
    var deadline: TestDeadline = .init(5_000);
    while (try runtime.zoneOutputState(zone) != .active) {
        if (!deadline.tick()) return error.OutputNeverOpened;
    }
}

test "attaching a Zone to another Player closes its output and reopens it for the new Player" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const previous = try runtime.createPlayer();
    const next = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, previous);
    try runtime.playerLoadFile(previous, std.testing.io, "fixtures/audio/generated-reference.wav");
    try runtime.playerLoadFile(next, std.testing.io, "fixtures/audio/generated-reference.wav");
    try runtime.zoneRequestOutput(zone, 0);
    try runtime.playPlayer(previous);
    try awaitZoneActive(&runtime, zone);
    const previous_stream = backend.liveStream() orelse return error.OutputNeverOpened;

    try runtime.attachZone(zone, next);
    try std.testing.expect(previous_stream.closed);
    try awaitZoneActive(&runtime, zone);
    try std.testing.expectEqual(@as(usize, 2), backend.opens);
    const next_stream = backend.liveStream() orelse return error.OutputNeverReopened;
    try std.testing.expect(next_stream != previous_stream);

    try runtime.playPlayer(next);
    var samples: [512]f32 = undefined;
    var deadline: TestDeadline = .init(5_000);
    while ((try runtime.playerSnapshot(next)).position_frames == 0 and deadline.tick())
        next_stream.pump(&samples, 256);
    try std.testing.expect((try runtime.playerSnapshot(next)).position_frames > 0);

    try runtime.destroyZone(zone);
    try runtime.destroyPlayer(next);
    try runtime.destroyPlayer(previous);
}

test "re-attaching a Zone to the Player it is already on does not interrupt its output" {
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
    try awaitZoneActive(&runtime, zone);
    const stream = backend.liveStream() orelse return error.OutputNeverOpened;

    try runtime.attachZone(zone, player);
    try std.testing.expect(!stream.closed);
    try std.testing.expectEqual(audio.zone.OutputState.active, try runtime.zoneOutputState(zone));
    try std.testing.expectEqual(@as(usize, 1), backend.opens);

    try runtime.destroyZone(zone);
    try runtime.destroyPlayer(player);
}

test "detaching a Zone forgets the timeline its callback published" {
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
    try awaitZoneActive(&runtime, zone);
    const stream = backend.liveStream() orelse return error.OutputNeverOpened;
    var samples: [512]f32 = undefined;
    var deadline: TestDeadline = .init(5_000);
    while ((try runtime.zoneStats(zone)).rendered_entry_serial == 0 and deadline.tick())
        stream.pump(&samples, 256);
    try std.testing.expect((try runtime.zoneStats(zone)).rendered_entry_serial != 0);

    try runtime.detachZone(zone);
    const stats = try runtime.zoneStats(zone);
    try std.testing.expectEqual(audio.zone.OutputState.closed, stats.output_state);
    try std.testing.expectEqual(@as(u32, 0), stats.rendered_entry_serial);
    const detached = (try runtime.zones.get(zone)).zone;
    try std.testing.expectEqual(@as(u64, 0), detached.position.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), detached.entry_anchor.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), detached.context.published_position);
    try std.testing.expect(detached.quiescent());

    try runtime.destroyZone(zone);
    try runtime.destroyPlayer(player);
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

test "playing a stopped queue whose cursor file has gone steps over it to the next entry" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try copyFixtureInto(temporary.dir, "fixtures/audio/generated-reference.flac", "a.flac");
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "b.flac");
    const first_path = try absoluteTestPath(".zig-cache/tmp/{s}/a.flac", .{temporary.sub_path});
    defer std.testing.allocator.free(first_path);
    const second_path = try absoluteTestPath(".zig-cache/tmp/{s}/b.flac", .{temporary.sub_path});
    defer std.testing.allocator.free(second_path);

    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());
    const fixtures = try openFixtureLibrary(
        &runtime,
        "file:orca-queue-missing-start?mode=memory&cache=shared",
        &.{ first_path, second_path },
    );
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneRequestOutput(zone, 0);
    try runtime.playerPlayTracks(player, fixtures.library, std.testing.io, fixtures.ids[0..2], 0);
    try runtime.stopPlayer(player);
    try temporary.dir.deleteFile(std.testing.io, "a.flac");

    try runtime.playPlayer(player);

    var samples: [512]f32 = @splat(0);
    var deadline: TestDeadline = .init(5_000);
    while (deadline.tick()) {
        if (backend.liveStream()) |stream| stream.pump(&samples, 256);
        if ((try runtime.playerQueueStats(player)).entries_started == 0) continue;
        if ((try runtime.playerSnapshot(player)).position_frames > 0) break;
    }
    const stats = try runtime.playerQueueStats(player);
    try std.testing.expectEqual(@as(u64, 1), stats.open_failures);
    try std.testing.expectEqual(@as(u64, 1), stats.entries_started);
    try std.testing.expect((try runtime.playerSnapshot(player)).position_frames > 0);
    try std.testing.expectEqual(@as(u32, 1), (try runtime.playerQueueSnapshot(player)).cursor);
    try std.testing.expectEqual(fixtures.ids[1], (try runtime.playerNowPlaying(player)).?.track_id);
}

test "a Player reports the Track whose file has gone, until another entry opens" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try copyFixtureInto(temporary.dir, "fixtures/audio/generated-reference.flac", "a.flac");
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "b.flac");

    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());
    const library = try scannedTempFolder(&runtime, &temporary, "file:orca-failure-file-missing?mode=memory&cache=shared");
    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    const library_database = try libraryDatabase(&runtime, library);
    const first = (try library_database.tracks.playableLocation(std.testing.allocator, ids[0])).?;
    const first_is_a = std.mem.endsWith(u8, first.uri, "/a.flac");
    first.deinit();
    const order: [2]i64 = if (first_is_a) .{ ids[0], ids[1] } else .{ ids[1], ids[0] };
    try temporary.dir.deleteFile(std.testing.io, "a.flac");

    const player = try runtime.createPlayer();
    try std.testing.expect((try runtime.playerStatus(player)).last_failure == null);
    try std.testing.expectError(
        error.TrackFileMissing,
        runtime.playerPlayTracks(player, library, std.testing.io, &order, 0),
    );
    const failure = (try runtime.playerStatus(player)).last_failure.?;
    try std.testing.expectEqual(order[0], failure.track_id);
    try std.testing.expectEqual(runtime_module.PlaybackFailure.Reason.file_missing, failure.reason);
    try std.testing.expectEqual(@as(u64, 1), try runtime.libraryMissingFileCount(library));
    var roots = try runtime.libraryRootPage(library, 8, 0);
    defer roots.deinit();
    try std.testing.expect(roots.items[0].available);
    try std.testing.expectEqual(@as(u64, 2), roots.items[0].track_count);
    try std.testing.expectEqual(@as(u64, 1), roots.items[0].unavailable_tracks);

    try runtime.playerPlayTracks(player, library, std.testing.io, &order, 1);
    try std.testing.expect((try runtime.playerStatus(player)).last_failure == null);
}

test "a Track under a root that has moved is reported as folder unavailable until the root is relocated" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "music");
    {
        const music = try temporary.dir.openDir(std.testing.io, "music", .{});
        defer music.close(std.testing.io);
        try copyFixtureInto(music, "fixtures/audio/generated-reference.flac", "a.flac");
    }
    const root = try absoluteTestPath(".zig-cache/tmp/{s}/music", .{temporary.sub_path});
    defer std.testing.allocator.free(root);
    const moved = try absoluteTestPath(".zig-cache/tmp/{s}/moved", .{temporary.sub_path});
    defer std.testing.allocator.free(moved);

    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());
    const library = try runtime.openLibrary(std.testing.io, "file:orca-failure-folder?mode=memory&cache=shared");
    const binding = try runtime.libraryAddRoot(library, std.testing.io, root);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryScan(library, .{ .root_id = binding.root_id })));
    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 1), ids.len);

    try std.Io.Dir.rename(temporary.dir, "music", temporary.dir, "moved", std.testing.io);
    const player = try runtime.createPlayer();
    try std.testing.expectError(
        error.TrackFolderUnavailable,
        runtime.playerPlayTracks(player, library, std.testing.io, ids, 0),
    );
    const failure = (try runtime.playerStatus(player)).last_failure.?;
    try std.testing.expectEqual(ids[0], failure.track_id);
    try std.testing.expectEqual(runtime_module.PlaybackFailure.Reason.folder_unavailable, failure.reason);
    try std.testing.expectEqual(@as(u64, 0), try runtime.libraryMissingFileCount(library));
    {
        var roots = try runtime.libraryRootPage(library, 8, 0);
        defer roots.deinit();
        try std.testing.expect(!roots.items[0].available);
        try std.testing.expectEqual(@as(u64, 1), roots.items[0].track_count);
        try std.testing.expectEqual(@as(u64, 1), roots.items[0].unavailable_tracks);
    }

    try std.testing.expectError(
        error.InvalidLibraryRoot,
        runtime.libraryRelocateRoot(library, std.testing.io, binding.root_id, root),
    );
    try std.testing.expectError(
        error.UnknownRoot,
        runtime.libraryRelocateRoot(library, std.testing.io, binding.root_id + 1, moved),
    );
    const relocation = try runtime.libraryRelocateRoot(library, std.testing.io, binding.root_id, moved);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, relocation));
    {
        var roots = try runtime.libraryRootPage(library, 8, 0);
        defer roots.deinit();
        try std.testing.expectEqual(@as(usize, 1), roots.items.len);
        try std.testing.expectEqual(binding.root_id, roots.items[0].id);
        try std.testing.expectEqualStrings(moved, roots.items[0].path);
        try std.testing.expect(roots.items[0].available);
        try std.testing.expectEqual(@as(u64, 0), roots.items[0].unavailable_tracks);
    }
    const relocated_ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(relocated_ids);
    try std.testing.expectEqualSlices(i64, ids, relocated_ids);

    try runtime.playerPlayTracks(player, library, std.testing.io, ids, 0);
    try std.testing.expect((try runtime.playerStatus(player)).last_failure == null);
}

test "an offline root leaves only its own Releases unavailable until its folder returns" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for ([_][]const u8{ "away", "home" }, [_][]const u8{ "fixtures/audio/tagged-reference.flac", "fixtures/audio/covered-reference.flac" }) |name, fixture| {
        try temporary.dir.createDirPath(std.testing.io, name);
        const directory = try temporary.dir.openDir(std.testing.io, name, .{});
        defer directory.close(std.testing.io);
        try copyFixtureInto(directory, fixture, "a.flac");
    }
    const away = try absoluteTestPath(".zig-cache/tmp/{s}/away", .{temporary.sub_path});
    defer std.testing.allocator.free(away);
    const home = try absoluteTestPath(".zig-cache/tmp/{s}/home", .{temporary.sub_path});
    defer std.testing.allocator.free(home);

    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-offline-availability?mode=memory&cache=shared");
    const away_root = (try runtime.libraryAddRoot(library, std.testing.io, away)).root_id;
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryScan(library, .{ .root_id = away_root })));
    _ = try runtime.libraryAddRoot(library, std.testing.io, home);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryScan(library, .{})));
    var away_release: ?i64 = null;
    var home_release: ?i64 = null;
    {
        var tracks = try runtime.libraryTrackQuery(library, "", .{ .limit = 16 });
        defer tracks.deinit();
        try std.testing.expectEqual(@as(usize, 2), tracks.items.len);
        for (tracks.items) |track| {
            if (std.mem.eql(u8, track.title, "Reference Tone")) away_release = track.release_id else home_release = track.release_id;
        }
    }
    const releases = [_]i64{ home_release.?, away_release.?, home_release.?, away_release.? };
    try std.testing.expect(releases[0] != releases[1]);
    var available: [4]bool = undefined;

    {
        const availability = try runtime.libraryAvailability(library, std.testing.io);
        defer availability.deinit();
        try std.testing.expectEqual(@as(usize, 0), availability.offline_roots.len);
        try runtime.libraryReleasesAvailable(library, &availability, &releases, &available);
        try std.testing.expectEqualSlices(bool, &.{ true, true, true, true }, &available);
    }

    try std.Io.Dir.rename(temporary.dir, "away", temporary.dir, "gone", std.testing.io);
    {
        const availability = try runtime.libraryAvailability(library, std.testing.io);
        defer availability.deinit();
        try std.testing.expectEqual(@as(usize, 1), availability.offline_roots.len);
        const offline = availability.offline_roots[0];
        try std.testing.expectEqual(away_root, offline.id);
        try std.testing.expectEqualStrings(away, offline.path);
        try std.testing.expect(offline.volume.len != 0);
        try std.testing.expect(offline.last_seen_at != null);
        try std.testing.expectEqual(@as(u64, 1), availability.unavailable_tracks);
        try std.testing.expectEqual(@as(u64, 1), availability.unavailable_releases);
        try runtime.libraryReleasesAvailable(library, &availability, &releases, &available);
        try std.testing.expectEqualSlices(bool, &.{ true, false, true, false }, &available);
    }

    try std.Io.Dir.rename(temporary.dir, "gone", temporary.dir, "away", std.testing.io);
    {
        const availability = try runtime.libraryAvailability(library, std.testing.io);
        defer availability.deinit();
        try std.testing.expectEqual(@as(usize, 0), availability.offline_roots.len);
        try std.testing.expectEqual(@as(u64, 0), availability.unavailable_releases);
    }
}

test "a tag write undone after its root was relocated restores the original bytes at the new path" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try tempDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    const fixtures = [_]struct { source: []const u8, name: []const u8 }{
        .{ .source = "fixtures/audio/covered-reference.mp3", .name = "a.mp3" },
        .{ .source = "fixtures/audio/tagged-reference.flac", .name = "b.flac" },
    };
    try temporary.dir.createDirPath(std.testing.io, "music");
    {
        const music = try temporary.dir.openDir(std.testing.io, "music", .{});
        defer music.close(std.testing.io);
        for (fixtures) |fixture| try copyFixtureInto(music, fixture.source, fixture.name);
    }
    const root = try absoluteTestPath(".zig-cache/tmp/{s}/music", .{temporary.sub_path});
    defer std.testing.allocator.free(root);
    const moved = try absoluteTestPath(".zig-cache/tmp/{s}/moved", .{temporary.sub_path});
    defer std.testing.allocator.free(moved);

    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, database_path);
    const binding = try runtime.libraryAddRoot(library, std.testing.io, root);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryScan(library, .{ .root_id = binding.root_id })));
    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    const edited = try runtime.libraryEditTracks(library, ids, &.{.{ .field = .album, .value = "Written Album" }});
    const preview = try runtime.planTagWrite(library, std.testing.io, edited.ids);
    edited.deinit();
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 2), preview.files.len);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startTagWrite(library, preview.plan_id, preview.digest)));

    try std.Io.Dir.rename(temporary.dir, "music", temporary.dir, "moved", std.testing.io);
    const library_database = try libraryDatabase(&runtime, library);
    {
        var foreign = (try metadata.JournalLock.tryAcquire(std.testing.io, library_database.journal_lock_path.?)).?;
        defer foreign.release(std.testing.io);
        try std.testing.expectError(
            error.MutationInProgress,
            runtime.libraryRelocateRoot(library, std.testing.io, binding.root_id, moved),
        );
    }
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.libraryRelocateRoot(library, std.testing.io, binding.root_id, moved)));
    try runtime.undoTagWrite(library, std.testing.io, preview.plan_id);

    const restored_dir = try temporary.dir.openDir(std.testing.io, "moved", .{});
    defer restored_dir.close(std.testing.io);
    for (fixtures) |fixture| {
        const original = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture.source, std.testing.allocator, .limited(1 << 22));
        defer std.testing.allocator.free(original);
        const restored = try restored_dir.readFileAlloc(std.testing.io, fixture.name, std.testing.allocator, .limited(1 << 22));
        defer std.testing.allocator.free(restored);
        try std.testing.expectEqualSlices(u8, original, restored);
    }
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, library_database.backup_directory.?, .{}));
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

test "a cover embedded in a Release's file beats one fetched for it, and none is fetched for such a Release" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var archive: network.testing.ScriptedTransport = .{};
    defer archive.deinit();
    var clock: network.testing.TestClock = .{ .wall_offset_ms = 1_800_000_000_000 };
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = .{ .transport = archive.transport(), .clock = clock.clock(), .wall_clock = clock.wallClock() };
    const fixtures = try openArtworkLibrary(
        &runtime,
        "file:orca-artwork-fetched?mode=memory&cache=shared",
        &.{ "fixtures/audio/tagged-reference.flac", "fixtures/audio/covered-reference.flac" },
    );
    const library_database = try libraryDatabase(&runtime, fixtures.library);
    const fetched = "\xff\xd8\xff\xe0fetched";
    try library_database.release_artwork.put(fixtures.release_id, "2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b", .{
        .bytes = fetched,
        .mime_type = "image/jpeg",
    }, 1_800_000_000);

    const release_cover = (try runtime.libraryReleaseArtwork(fixtures.library, std.testing.io, fixtures.release_id)).?;
    defer release_cover.deinit();
    try std.testing.expectEqualStrings("image/png", release_cover.mime_type);
    const embedded = (try runtime.libraryTrackArtwork(fixtures.library, std.testing.io, fixtures.ids[1])).?;
    defer embedded.deinit();
    try std.testing.expectEqualStrings("image/png", embedded.mime_type);
    const fallback = (try runtime.libraryTrackArtwork(fixtures.library, std.testing.io, fixtures.ids[0])).?;
    defer fallback.deinit();
    try std.testing.expectEqualStrings(fetched, fallback.bytes);

    const fetch = try runtime.startReleaseCoverArtFetch(fixtures.library, fixtures.release_id);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, fetch));
    try std.testing.expectEqual(runtime_module.CoverArtOutcome.embedded, (try runtime.jobMatchStats(fetch)).cover_art);
    try std.testing.expectEqual(@as(u32, 0), archive.requestCount());
}

const TrackAndRelease = struct { track_id: i64, release_id: i64 };

fn onlyTrackAndRelease(runtime: *OrcaRuntime, library: LibraryHandle) !TrackAndRelease {
    var statement = try (try libraryDatabase(runtime, library)).database.prepare("SELECT id, release_id FROM tracks;");
    defer statement.deinit();
    try std.testing.expectEqual(database.sqlite.Step.row, try statement.step());
    const found: TrackAndRelease = .{ .track_id = statement.columnInt64(0), .release_id = statement.columnInt64(1) };
    try std.testing.expectEqual(database.sqlite.Step.done, try statement.step());
    return found;
}

fn expectReleaseCover(runtime: *OrcaRuntime, library: LibraryHandle, ids: TrackAndRelease, expected: ?[]const u8) !void {
    const release_cover = try runtime.libraryReleaseArtwork(library, std.testing.io, ids.release_id);
    defer if (release_cover) |image| image.deinit();
    const track_cover = try runtime.libraryTrackArtwork(library, std.testing.io, ids.track_id);
    defer if (track_cover) |image| image.deinit();
    if (expected) |bytes| {
        try std.testing.expectEqualStrings(bytes, release_cover.?.bytes);
        try std.testing.expectEqualStrings("image/jpeg", release_cover.?.mime_type);
        try std.testing.expectEqual(metadata.ArtworkKind.front_cover, release_cover.?.kind);
        try std.testing.expectEqualStrings(bytes, track_cover.?.bytes);
    } else {
        try std.testing.expect(release_cover == null);
        try std.testing.expect(track_cover == null);
    }
}

test "a Release whose files carry no cover shows the cover.jpg in its folder" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "Album");
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "Album/song.flac");
    const cover = "\xff\xd8\xff\xe0folder cover";
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "Album/cover.jpg", .data = cover });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "Album/back.jpg", .data = "\xff\xd8\xff\xe0back" });
    const library = try scannedTempFolder(&runtime, &temporary, "file:orca-artwork-folder?mode=memory&cache=shared");
    const ids = try onlyTrackAndRelease(&runtime, library);

    try expectReleaseCover(&runtime, library, ids, cover);
}

test "a cover embedded in a Release's file beats the cover.jpg in its folder" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "Album");
    try copyFixtureInto(temporary.dir, "fixtures/audio/covered-reference.flac", "Album/song.flac");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "Album/cover.jpg", .data = "\xff\xd8\xff\xe0folder cover" });
    const library = try scannedTempFolder(&runtime, &temporary, "file:orca-artwork-folder-embedded?mode=memory&cache=shared");
    const ids = try onlyTrackAndRelease(&runtime, library);

    const release_cover = (try runtime.libraryReleaseArtwork(library, std.testing.io, ids.release_id)).?;
    defer release_cover.deinit();
    try std.testing.expectEqualStrings("image/png", release_cover.mime_type);
    try std.testing.expectEqual(@as(usize, 217), release_cover.bytes.len);
}

test "a replaced cover.jpg is shown after a rescan, and a deleted or no longer image one gives no cover" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "Album");
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "Album/song.flac");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "Album/cover.jpg", .data = "\xff\xd8\xff\xe0first" });
    const library = try scannedTempFolder(&runtime, &temporary, "file:orca-artwork-folder-replaced?mode=memory&cache=shared");
    const ids = try onlyTrackAndRelease(&runtime, library);
    try expectReleaseCover(&runtime, library, ids, "\xff\xd8\xff\xe0first");

    const replacement = "\xff\xd8\xff\xe0a larger second cover";
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "Album/cover.jpg", .data = replacement });
    try rescan(&runtime, library);
    try expectReleaseCover(&runtime, library, ids, replacement);

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "Album/cover.jpg", .data = "not a picture any more" });
    try expectReleaseCover(&runtime, library, ids, null);

    try temporary.dir.deleteFile(std.testing.io, "Album/cover.jpg");
    try expectReleaseCover(&runtime, library, ids, null);
    try rescan(&runtime, library);
    try expectReleaseCover(&runtime, library, ids, null);
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

fn expectPlayStatsMatchListens(library_database: *database.LibraryDatabase) !void {
    var statement = try library_database.database.prepare(
        \\WITH counted AS (
        \\    SELECT recording_id, count(*) AS play_count, max(started_at) AS last_played_at
        \\    FROM listens WHERE recording_id IS NOT NULL GROUP BY recording_id)
        \\SELECT (SELECT count(*) FROM (SELECT * FROM counted EXCEPT SELECT * FROM recording_play_stats))
        \\     + (SELECT count(*) FROM (SELECT * FROM recording_play_stats EXCEPT SELECT * FROM counted));
    );
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    try std.testing.expectEqual(@as(i64, 0), statement.columnInt64(0));
    try std.testing.expectEqual(@as(i64, 0), try @import("../database/columns.zig").scalar(
        library_database.database,
        "SELECT count(*) FROM listens JOIN files ON files.id = listens.file_id " ++
            "WHERE listens.recording_id IS NOT files.recording_id;",
    ));
}

fn listenToEveryTrack(runtime: *OrcaRuntime, library: LibraryHandle, started_at: i64) !void {
    const library_database = try libraryDatabase(runtime, library);
    var page = try runtime.libraryTrackQuery(library, "", .{ .limit = 16 });
    defer page.deinit();
    for (page.items) |item| {
        const files = try library_database.tracks.fileIds(std.testing.allocator, item.id);
        defer std.testing.allocator.free(files);
        _ = try library_database.listens.recordAndQueue(.{
            .file_id = files[0],
            .started_at = started_at,
            .listened_ms = 1_000,
            .title = item.title,
            .artist = item.artist,
        }, "listenbrainz", item.title);
    }
}

test "plays follow files into a merged recording, equal each recording's listens after a rescan, and leave with it when its root is removed" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempLibrary(&runtime, &temporary, "file:orca-runtime-play-stats?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    try listenToEveryTrack(&runtime, library, 1_700_000_000);
    try expectPlayStatsMatchListens(library_database);
    try std.testing.expectEqual(@as(u64, 3), try library_database.recordings.count());
    try library_database.database.exec("CREATE TEMP TABLE payloads_before AS SELECT id, payload FROM scrobble_queue;");

    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    (try runtime.libraryEditTracks(library, ids, &.{
        .{ .field = .title, .value = "Merged" },
        .{ .field = .artist, .value = "Orca" },
        .{ .field = .album, .value = "Merged" },
        .{ .field = .track_number, .value = "1" },
        .{ .field = .disc_number, .value = "1" },
    })).deinit();
    var merged = try runtime.libraryTrackQuery(library, "", .{ .limit = 16 });
    try std.testing.expectEqual(@as(usize, 1), merged.items.len);
    const merged_recording = merged.items[0].recording_id.?;
    try std.testing.expectEqual(@as(u64, 3), merged.items[0].play_count);
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), merged.items[0].last_played_at);
    merged.deinit();
    try std.testing.expectEqual(@as(i64, 0), try @import("../database/columns.zig").scalar(
        library_database.database,
        "SELECT (SELECT count(*) FROM (SELECT id, payload FROM scrobble_queue EXCEPT SELECT * FROM payloads_before)) " ++
            "+ (SELECT count(*) FROM (SELECT * FROM payloads_before EXCEPT SELECT id, payload FROM scrobble_queue));",
    ));
    try std.testing.expectEqual(@as(i64, 3), try @import("../database/columns.zig").scalar(
        library_database.database,
        "SELECT count(*) FROM payloads_before;",
    ));
    try std.testing.expectEqual(@as(i64, 3), try @import("../database/columns.zig").scalar(
        library_database.database,
        "SELECT count(*) FROM files WHERE recording_id = (SELECT recording_id FROM tracks);",
    ));
    try expectPlayStatsMatchListens(library_database);

    try listenToEveryTrack(&runtime, library, 1_700_001_000);
    try expectPlayStatsMatchListens(library_database);
    var played = try runtime.libraryTrackQuery(library, "", .{ .limit = 16 });
    try std.testing.expectEqual(merged_recording, played.items[0].recording_id.?);
    try std.testing.expectEqual(@as(?i64, 1_700_001_000), played.items[0].last_played_at);
    try std.testing.expectEqual(@as(u64, 4), played.items[0].play_count);
    played.deinit();

    try rescan(&runtime, library);
    try expectPlayStatsMatchListens(library_database);
    var rescanned = try runtime.libraryTrackQuery(library, "", .{ .limit = 16 });
    try std.testing.expectEqual(@as(u64, 4), rescanned.items[0].play_count);
    rescanned.deinit();

    var roots = try runtime.libraryRootPage(library, 1, 0);
    const root_id = roots.items[0].id;
    roots.deinit();
    const removed = try runtime.libraryRemoveRoot(library, root_id);
    try std.testing.expectEqual(@as(u64, 3), removed.files_forgotten);
    try std.testing.expectEqual(@as(u64, 1), removed.recordings_forgotten);
    try expectPlayStatsMatchListens(library_database);
    try std.testing.expectEqual(@as(u64, 2), try library_database.recordings.count());
    try std.testing.expectEqual(@as(i64, 0), try @import("../database/columns.zig").scalar(
        library_database.database,
        "SELECT count(*) FROM recording_play_stats;",
    ));
    try std.testing.expectEqual(@as(i64, 4), try @import("../database/columns.zig").scalar(
        library_database.database,
        "SELECT count(*) FROM listens WHERE recording_id IS NULL AND title <> '';",
    ));
}

fn expectSearchIndexesInSync(library_database: *database.LibraryDatabase) !void {
    try library_database.database.exec(
        \\INSERT INTO search_index(search_index, rank) VALUES ('integrity-check', 1);
        \\INSERT INTO track_search(track_search, rank) VALUES ('integrity-check', 1);
    );
    try std.testing.expectEqual(@as(i64, 0), try database.columns.scalar(library_database.database,
        \\WITH source(rowid, kind, entity_id, title, subtitle) AS (
        \\    SELECT id * 8 + 0, 0, id, name, '' FROM artists
        \\    UNION ALL SELECT id * 8 + 1, 1, id, title, album_artist FROM releases
        \\    UNION ALL SELECT id * 8 + 3, 3, id, name, description FROM playlists
        \\    UNION ALL SELECT id * 8 + 4, 4, id, name, '' FROM genres
        \\), indexed AS (SELECT rowid, kind, entity_id, title, subtitle FROM search_index)
        \\SELECT (SELECT count(*) FROM (SELECT * FROM indexed EXCEPT SELECT * FROM source))
        \\     + (SELECT count(*) FROM (SELECT * FROM source EXCEPT SELECT * FROM indexed));
    ));
}

fn expectTrackHits(runtime: *OrcaRuntime, library: LibraryHandle, text: []const u8, count: usize, title: ?[]const u8) !void {
    var results = try runtime.librarySearch(library, text, .{ .artists = 0, .releases = 0, .playlists = 0, .genres = 0 });
    defer results.deinit();
    try std.testing.expectEqual(count, results.hits.len);
    if (title) |expected| for (results.hits) |hit| try std.testing.expectEqualStrings(expected, hit.title);
}

test "scanning, editing, renaming, deleting and rescanning keep both search indexes equal to the rows they index" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempLibrary(&runtime, &temporary, "file:orca-runtime-search-sync?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    try expectSearchIndexesInSync(library_database);

    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 3), ids.len);
    (try runtime.libraryEditTracks(library, ids[0..1], &.{.{ .field = .title, .value = "Indexed Lantern" }})).deinit();
    try expectSearchIndexesInSync(library_database);
    try expectTrackHits(&runtime, library, "lantern", 1, "Indexed Lantern");
    (try runtime.libraryEditTracks(library, ids[1..], &.{
        .{ .field = .artist, .value = "Quill Harbour" },
        .{ .field = .album, .value = "Tidewater" },
    })).deinit();
    const edited_ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(edited_ids);
    try runtime.librarySetTrackGenres(library, edited_ids, &.{"Sea Shanty"});
    try expectSearchIndexesInSync(library_database);
    try expectTrackHits(&runtime, library, "tidewater quill", 2, null);

    const playlist_id = try runtime.libraryCreatePlaylist(library, "Morning Tide");
    try runtime.libraryRenamePlaylist(library, playlist_id, "Evening Tide");
    try runtime.libraryUpdatePlaylist(library, playlist_id, .{ .description = "Harbour songs" });
    try expectSearchIndexesInSync(library_database);

    try std.Io.Dir.rename(temporary.dir, "b.flac", temporary.dir, "renamed.flac", std.testing.io);
    try temporary.dir.deleteFile(std.testing.io, "a.mp3");
    try rescan(&runtime, library);
    try expectSearchIndexesInSync(library_database);

    try runtime.libraryDeletePlaylist(library, playlist_id);
    var roots = try runtime.libraryRootPage(library, 1, 0);
    const root_id = roots.items[0].id;
    roots.deinit();
    _ = try runtime.libraryRemoveRoot(library, root_id);
    try expectSearchIndexesInSync(library_database);
    try std.testing.expectEqual(@as(i64, 0), try database.columns.scalar(library_database.database, "SELECT count(*) FROM track_search_docsize;"));
    try expectTrackHits(&runtime, library, "tidewater", 0, null);
}

pub fn expectGenreTotalsInSync(library_database: *database.LibraryDatabase) !void {
    try std.testing.expectEqual(@as(i64, 0), try database.columns.scalar(library_database.database, database.migrations.genre_totals_drift_sql));
}

fn expectGenreListed(runtime: *OrcaRuntime, library: LibraryHandle, name: []const u8, tracks: u32) !void {
    var page = try runtime.libraryGenrePage(library, .{ .filter = name, .limit = 8 });
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    const genre = page.items[0];
    try std.testing.expectEqual(tracks, genre.track_count);
    try std.testing.expectEqual(@as(u64, genre.track_count), try runtime.libraryTrackMatchCount(library, .{ .genre_id = genre.id }));
    try std.testing.expectEqual(@as(u64, genre.release_count), try runtime.libraryReleaseCountMatching(library, .{ .genre_id = genre.id }));
    try std.testing.expectEqual(@as(u64, genre.artist_count), try runtime.libraryArtistCountMatching(library, .{ .genre_id = genre.id }));
    const by_id = (try runtime.libraryGenre(library, genre.id)).?;
    defer by_id.deinit(std.testing.allocator);
    try std.testing.expectEqual(genre.release_count, by_id.release_count);
    try std.testing.expectEqual(genre.total_duration_ms, by_id.total_duration_ms);
}

test "scanning, editing, deleting, rescanning and removing a root keep the genre totals equal to a count over the Tracks" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempLibrary(&runtime, &temporary, "file:orca-runtime-genre-totals?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    try expectGenreTotalsInSync(library_database);

    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 3), ids.len);
    try runtime.librarySetTrackGenres(library, ids, &.{ "Sea Shanty", "Folk" });
    try expectGenreTotalsInSync(library_database);
    try expectGenreListed(&runtime, library, "sea shanty", 3);

    (try runtime.libraryEditTracks(library, ids[0..1], &.{
        .{ .field = .artist, .value = "Quill Harbour" },
        .{ .field = .album, .value = "Tidewater" },
        .{ .field = .album_artist, .value = "Quill Harbour" },
    })).deinit();
    try expectGenreTotalsInSync(library_database);
    const edited_ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(edited_ids);
    try runtime.librarySetTrackGenres(library, edited_ids[0..1], &.{"Folk"});
    try expectGenreTotalsInSync(library_database);
    try expectGenreListed(&runtime, library, "folk", 3);
    try expectGenreListed(&runtime, library, "sea shanty", 2);
    (try runtime.libraryEditTracks(library, edited_ids, &.{.{ .field = .album_artist, .value = "Lantern Choir" }})).deinit();
    try expectGenreTotalsInSync(library_database);

    try std.Io.Dir.rename(temporary.dir, "b.flac", temporary.dir, "renamed.flac", std.testing.io);
    try temporary.dir.deleteFile(std.testing.io, "a.mp3");
    try rescan(&runtime, library);
    try expectGenreTotalsInSync(library_database);

    var roots = try runtime.libraryRootPage(library, 1, 0);
    const root_id = roots.items[0].id;
    roots.deinit();
    _ = try runtime.libraryRemoveRoot(library, root_id);
    try expectGenreTotalsInSync(library_database);
    try std.testing.expectEqual(@as(u64, 0), try runtime.libraryGenreCount(library, ""));
    try std.testing.expectEqual(@as(i64, 0), try database.columns.scalar(library_database.database, "SELECT count(*) FROM genre_totals;"));
}

test "a disc with no stated total counts up to its highest track number" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.opus", "three.opus");
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.wav", "four.wav");
    const library = try scannedTempFolder(&runtime, &temporary, "file:orca-runtime-counted-total?mode=memory&cache=shared");

    var page = try runtime.libraryTrackQuery(library, "", .{ .limit = 16, .sort = .track_number });
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    for (page.items, [_]i64{ 3, 4 }) |item, number| {
        try std.testing.expectEqual(@as(?i64, number), item.track_number);
        try std.testing.expectEqual(@as(?i64, 4), item.track_total);
        try std.testing.expectEqual(@as(?i64, 1), item.disc_total);
        const details = (try runtime.libraryTrackDetails(library, item.id)).?;
        defer details.deinit();
        try std.testing.expect(details.track_total_inferred);
    }
}

test "a lyrics job hands its Track's lyrics over once, and a Track without a file has none" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "b.flac");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "b.lrc", .data = "[00:01.00]One\n[00:02.00]Two\n" });
    const library = try scannedTempFolder(&runtime, &temporary, "file:orca-runtime-lyrics?mode=memory&cache=shared");
    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);

    const found = try runtime.startTrackLyrics(library, ids[0], .{});
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, found));
    try std.testing.expectEqual(runtime_module.LyricsOutcome.local, try runtime.jobLyricsOutcome(found));
    const lyrics = (try runtime.jobTakeLyrics(found)).?;
    defer lyrics.deinit();
    try std.testing.expectEqual(@as(usize, 2), lyrics.lines.len);
    try std.testing.expectEqual(@as(?usize, 1), lyrics.lineAt(2500));
    try std.testing.expect(try runtime.jobTakeLyrics(found) == null);

    const missing = try runtime.startTrackLyrics(library, ids[0] + 1000, .{});
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, missing));
    try std.testing.expectEqual(runtime_module.LyricsOutcome.not_found, try runtime.jobLyricsOutcome(missing));
    try std.testing.expect(try runtime.jobTakeLyrics(missing) == null);

    var roots = try runtime.libraryRootPage(library, 1, 0);
    defer roots.deinit();
    const scan = try runtime.startLibraryScan(library, .{ .root_id = roots.items[0].id });
    _ = try awaitJob(&runtime, scan);
    try std.testing.expectError(error.NotALyricsJob, runtime.jobLyricsOutcome(scan));
}

test "lyrics a host never takes are freed with their job" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try copyFixtureInto(temporary.dir, "fixtures/audio/lyrics-synced.flac", "b.flac");
    const library = try scannedTempFolder(&runtime, &temporary, "file:orca-runtime-lyrics-untaken?mode=memory&cache=shared");
    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    const handle = try runtime.startTrackLyrics(library, ids[0], .{});
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, handle));
    try std.testing.expectEqual(runtime_module.LyricsOutcome.local, try runtime.jobLyricsOutcome(handle));
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

/// Pumps, so a Job waiting for its Library's slot starts once it is free.
pub fn awaitJobPumping(runtime: *OrcaRuntime, job_handle: JobHandle) !job.State {
    var deadline: TestDeadline = .init(10_000);
    while (deadline.tick()) {
        runtime.pump();
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
    return scannedTempFolder(runtime, temporary, name);
}

pub fn scannedTempFolder(runtime: *OrcaRuntime, temporary: *std.testing.TmpDir, name: [:0]const u8) !LibraryHandle {
    const root = try absoluteTestPath(".zig-cache/tmp/{s}", .{temporary.sub_path});
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

pub fn tempDatabasePath(data: *std.testing.TmpDir) ![:0]u8 {
    return std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/library.db", .{data.sub_path}, 0);
}

fn expectJournaledError(library_database: *database.LibraryDatabase, group_id: u64, action_index: u32, expected: []const u8) !void {
    var statement = try library_database.database.prepare(
        "SELECT error FROM mutation_operations WHERE group_id=?1 AND action_index=?2;",
    );
    defer statement.deinit();
    try statement.bindInt64(1, @intCast(group_id));
    try statement.bindInt64(2, action_index);
    if (try statement.step() != .row) return error.MutationOperationNotFound;
    try std.testing.expectEqualStrings(expected, statement.columnText(0));
}

pub fn rescan(runtime: *OrcaRuntime, library: LibraryHandle) !void {
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

const release_id_edits = [_]runtime_module.TrackEdit{
    .{ .field = .musicbrainz_release_id, .value = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a" },
    .{ .field = .musicbrainz_release_group_id, .value = "0b6a3a3e-3b2c-4c8e-9a51-1f2d3c4b5a69" },
    .{ .field = .musicbrainz_release_track_id, .value = "c2f7b3a4-5d6e-4f80-9a1b-2c3d4e5f6a7b" },
    .{ .field = .musicbrainz_album_artist_id, .value = "d4e5f6a7-b8c9-4d0e-8f1a-2b3c4d5e6f70" },
};

fn expectObservedReleaseIds(library_database: *database.LibraryDatabase, file_id: i64) !void {
    const stored = (try library_database.observed_tags.get(std.testing.allocator, file_id)).?;
    defer stored.deinit();
    try std.testing.expectEqualStrings(release_id_edits[0].value.?, stored.values.musicbrainz_release_id.?);
    try std.testing.expectEqualStrings(release_id_edits[1].value.?, stored.values.musicbrainz_release_group_id.?);
    try std.testing.expectEqualStrings(release_id_edits[2].value.?, stored.values.musicbrainz_release_track_id.?);
    try std.testing.expectEqualStrings(release_id_edits[3].value.?, stored.values.musicbrainz_album_artist_id.?);
}

test "release-level MusicBrainz ids are written into FLAC and MP3 files, a rescan reads them back, and undo restores the bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try tempDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempLibrary(&runtime, &temporary, database_path);
    const library_database = try libraryDatabase(&runtime, library);
    const names = [_][]const u8{ "a.mp3", "b.flac" };
    var originals: [names.len][]u8 = undefined;
    for (names, &originals) |name, *original|
        original.* = try temporary.dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(1 << 22));
    defer for (originals) |original| std.testing.allocator.free(original);

    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    try std.testing.expectError(error.InvalidEditValue, runtime.libraryEditTracks(
        library,
        ids,
        &.{.{ .field = .musicbrainz_release_id, .value = "Some Album" }},
    ));
    const edited = try runtime.libraryEditTracks(library, ids, &release_id_edits);
    defer edited.deinit();

    const preview = try runtime.planTagWrite(library, std.testing.io, edited.ids);
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 2), preview.files.len);
    for (preview.files) |file| {
        try std.testing.expect(std.mem.endsWith(u8, file.path, "a.mp3") or std.mem.endsWith(u8, file.path, "b.flac"));
        try std.testing.expectEqual(release_id_edits.len, file.changes.len);
        for (file.changes) |change| try std.testing.expect(change.before == null);
    }
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startTagWrite(library, preview.plan_id, preview.digest)));

    try rescan(&runtime, library);
    for (preview.files) |file| try expectObservedReleaseIds(library_database, file.file_id);
    for (names, originals) |name, original| {
        const written = try temporary.dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(1 << 22));
        defer std.testing.allocator.free(written);
        try std.testing.expect(!std.mem.eql(u8, original, written));
    }

    try runtime.undoTagWrite(library, std.testing.io, preview.plan_id);
    for (names, originals) |name, original| {
        const restored = try temporary.dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(1 << 22));
        defer std.testing.allocator.free(restored);
        try std.testing.expectEqualSlices(u8, original, restored);
    }
}

fn expectGenreNames(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_name, actual_name| try std.testing.expectEqualStrings(expected_name, actual_name);
}

test "user genres are written into FLAC and MP3 files, a rescan reads them back, and undo restores the bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try tempDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempLibrary(&runtime, &temporary, database_path);
    const library_database = try libraryDatabase(&runtime, library);
    const names = [_][]const u8{ "a.mp3", "b.flac" };
    var originals: [names.len][]u8 = undefined;
    for (names, &originals) |name, *original|
        original.* = try temporary.dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(1 << 22));
    defer for (originals) |original| std.testing.allocator.free(original);
    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    const genres = [_][]const u8{ "Shoegaze", "Dream Pop", "Noise Rock" };

    try runtime.librarySetTrackGenres(library, ids, &.{ "Shoegaze; Dream Pop", "Noise Rock" });
    const preview = try runtime.planTagWrite(library, std.testing.io, ids);
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 2), preview.files.len);
    for (preview.files) |file| {
        try std.testing.expectEqual(@as(usize, 0), file.changes.len);
        try expectGenreNames(&genres, file.genres.?.after);
        const held = (try runtime.tagWriteGenres(library, preview.plan_id, file.file_id)).?;
        try std.testing.expectEqualDeep(file.genres.?, held);
    }
    try std.testing.expect(try runtime.tagWriteGenres(library, preview.plan_id, -1) == null);
    try std.testing.expectError(
        error.UnknownTagWritePlan,
        runtime.tagWriteGenres(library, preview.plan_id + 1, preview.files[0].file_id),
    );
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startTagWrite(library, preview.plan_id, preview.digest)));
    try std.testing.expectError(
        error.UnknownTagWritePlan,
        runtime.tagWriteGenres(library, preview.plan_id, preview.files[0].file_id),
    );

    try rescan(&runtime, library);
    for (preview.files) |file| {
        const stored = (try library_database.observed_tags.get(std.testing.allocator, file.file_id)).?;
        defer stored.deinit();
        try expectGenreNames(&genres, stored.values.genres);
    }
    const unchanged = try runtime.planTagWrite(library, std.testing.io, ids);
    defer unchanged.deinit();
    try std.testing.expectEqual(@as(usize, 0), unchanged.files.len);

    try runtime.librarySetTrackGenres(library, ids, &.{});
    for (preview.files) |file| {
        const track_ids = try library_database.tracks.idsForFile(std.testing.allocator, file.file_id);
        defer std.testing.allocator.free(track_ids);
        const from_file = try runtime.libraryTrackGenres(library, track_ids[0]);
        defer from_file.deinit();
        var file_names: [genres.len][]const u8 = undefined;
        try std.testing.expectEqual(genres.len, from_file.items.len);
        for (&file_names, from_file.items) |*name, genre| {
            try std.testing.expectEqual(metadata.Provenance.observed_file, genre.provenance);
            name.* = genre.name;
        }
        try expectGenreNames(&genres, &file_names);
    }

    try runtime.undoTagWrite(library, std.testing.io, preview.plan_id);
    for (names, originals) |name, original| {
        const restored = try temporary.dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(1 << 22));
        defer std.testing.allocator.free(restored);
        try std.testing.expectEqualSlices(u8, original, restored);
    }
}

fn expectComposerAndComment(runtime: *OrcaRuntime, library: LibraryHandle, track_id: i64, composer: ?[]const u8, comment: ?[]const u8) !void {
    const details = (try runtime.libraryTrackDetails(library, track_id)).?;
    defer details.deinit();
    try std.testing.expectEqualDeep(composer, @as(?[]const u8, details.composer));
    try std.testing.expectEqualDeep(comment, @as(?[]const u8, details.comment));
}

test "a composer and comment are written into FLAC and MP3 files, an unlocked value that disagrees is a conflict, and clearing one edit leaves the other" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try tempDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempLibrary(&runtime, &temporary, database_path);
    const library_database = try libraryDatabase(&runtime, library);
    const names = [_][]const u8{ "a.mp3", "b.flac" };
    var originals: [names.len][]u8 = undefined;
    for (names, &originals) |name, *original|
        original.* = try temporary.dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(1 << 22));
    defer for (originals) |original| std.testing.allocator.free(original);
    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    for (ids) |id| try expectComposerAndComment(&runtime, library, id, null, null);

    const edited = try runtime.libraryEditTracks(library, ids, &.{
        .{ .field = .composer, .value = "Nick Drake" },
        .{ .field = .comment, .value = "First note" },
    });
    defer edited.deinit();
    for (edited.ids) |id| try expectComposerAndComment(&runtime, library, id, "Nick Drake", "First note");
    const preview = try runtime.planTagWrite(library, std.testing.io, edited.ids);
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 2), preview.files.len);
    try std.testing.expectEqual(@as(usize, 1), preview.skipped.len);
    try std.testing.expectEqual(TagWriteSkipReason.format_not_writable, preview.skipped[0].reason);
    for (preview.files) |file| {
        try std.testing.expectEqual(@as(usize, 2), file.changes.len);
        for (file.changes) |change| try std.testing.expect(change.before == null);
    }
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startTagWrite(library, preview.plan_id, preview.digest)));
    try rescan(&runtime, library);
    for (preview.files) |file| {
        const stored = (try library_database.observed_tags.get(std.testing.allocator, file.file_id)).?;
        defer stored.deinit();
        try std.testing.expectEqualStrings("Nick Drake", stored.values.composer.?);
        try std.testing.expectEqualStrings("First note", stored.values.comment.?);
    }

    const provider_note: database.repository.OrcaMetadataInput = .{
        .file_id = 0,
        .field = .comment,
        .value = "Provider note",
        .provenance = .provider,
        .locked = false,
    };
    for (preview.files) |file| {
        var input = provider_note;
        input.file_id = file.file_id;
        try library_database.orca_metadata.upsert(input);
        var values = try library_database.orca_metadata.values(std.testing.allocator, file.file_id);
        defer values.deinit();
        for (values.items) |value| {
            try std.testing.expect(value.locked and value.provenance == .user);
            if (value.field == .comment) try std.testing.expectEqualStrings("First note", value.text);
        }
        try library_database.orca_metadata.remove(file.file_id, .comment);
        try library_database.orca_metadata.upsert(input);
    }
    for (edited.ids) |id| try expectComposerAndComment(&runtime, library, id, "Nick Drake", "First note");
    const unlocked = try runtime.planTagWrite(library, std.testing.io, edited.ids);
    defer unlocked.deinit();
    try std.testing.expectEqual(@as(usize, 0), unlocked.files.len);
    try std.testing.expectEqual(@as(usize, 2), unlocked.conflicts.len);
    for (unlocked.conflicts) |conflict| {
        try std.testing.expectEqual(metadata.Field.comment, conflict.field);
        try std.testing.expectEqualStrings("First note", conflict.file_value);
        try std.testing.expectEqualStrings("Provider note", conflict.orca_value);
    }

    const relocked = try runtime.libraryEditTracks(library, edited.ids, &.{.{ .field = .comment, .value = "Locked note" }});
    defer relocked.deinit();
    for (relocked.ids) |id| try expectComposerAndComment(&runtime, library, id, "Nick Drake", "Locked note");
    const locked = try runtime.planTagWrite(library, std.testing.io, relocked.ids);
    defer locked.deinit();
    try std.testing.expectEqual(@as(usize, 2), locked.files.len);
    try std.testing.expectEqual(@as(usize, 0), locked.conflicts.len);
    for (locked.files) |file| {
        try std.testing.expectEqual(@as(usize, 1), file.changes.len);
        try std.testing.expectEqual(metadata.Field.comment, file.changes[0].field);
        try std.testing.expectEqualStrings("First note", file.changes[0].before.?);
        try std.testing.expectEqualStrings("Locked note", file.changes[0].after.?);
    }
    try runtime.discardTagWrite(library, locked.plan_id);

    const cleared = try runtime.libraryEditTracks(library, relocked.ids, &.{.{ .field = .comment, .value = null }});
    defer cleared.deinit();
    for (cleared.ids) |id| {
        const file_ids = try library_database.tracks.fileIds(std.testing.allocator, id);
        defer std.testing.allocator.free(file_ids);
        const written = for (preview.files) |file| {
            if (file.file_id == file_ids[0]) break true;
        } else false;
        try expectComposerAndComment(&runtime, library, id, "Nick Drake", if (written) "First note" else null);
        var values = try runtime.libraryTrackEdits(library, id);
        defer values.deinit();
        try std.testing.expectEqual(@as(usize, 1), values.items.len);
        try std.testing.expectEqual(metadata.Field.composer, values.items[0].field);
        try std.testing.expect(values.items[0].locked);
    }

    try runtime.undoTagWrite(library, std.testing.io, preview.plan_id);
    for (names, originals) |name, original| {
        const restored = try temporary.dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(1 << 22));
        defer std.testing.allocator.free(restored);
        try std.testing.expectEqualSlices(u8, original, restored);
    }
}

test "field states mark an unwritten edit as edited and shared, and a tag-write plan names each file's tag format" {
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

    const untouched = try runtime.libraryTrackFieldStates(library, ids);
    defer untouched.deinit();
    try std.testing.expectEqual(@as(u32, @intCast(ids.len)), untouched.track_count);
    for (std.enums.values(runtime_module.EditableTrackField)) |field|
        try std.testing.expect(!untouched.fields.get(field).edited);
    try std.testing.expect(untouched.fields.get(.composer).value == null);
    try std.testing.expect(!untouched.fields.get(.composer).mixed);

    const edited = try runtime.libraryEditTracks(library, ids, &.{.{ .field = .album_artist, .value = "Orca Edit Ensemble" }});
    defer edited.deinit();
    const states = try runtime.libraryTrackFieldStates(library, edited.ids);
    defer states.deinit();
    const album_artist = states.fields.get(.album_artist);
    try std.testing.expectEqualStrings("Orca Edit Ensemble", album_artist.value.?);
    try std.testing.expect(!album_artist.mixed);
    try std.testing.expect(album_artist.edited);
    try std.testing.expect(!states.fields.get(.composer).edited);
    try std.testing.expect(states.cover.tracks <= states.track_count);

    const plan = try runtime.planTagWrite(library, std.testing.io, edited.ids);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.files.len);
    for (plan.files) |file| {
        if (std.mem.endsWith(u8, file.path, ".flac")) {
            try std.testing.expectEqual(runtime_module.TagWriteFormat.vorbis_comment, file.format);
            try std.testing.expectEqualStrings("ALBUMARTIST", file.format.key(.album_artist).?);
            try std.testing.expectEqualStrings("GENRE", file.format.key(null).?);
        } else {
            try std.testing.expectEqual(runtime_module.TagWriteFormat.id3v2, file.format);
            try std.testing.expect(file.format.key(.album_artist) == null);
        }
    }
    try runtime.discardTagWrite(library, plan.plan_id);
}

test "a chosen front outranks a Track's embedded cover in its field states until it is cleared" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempLibrary(&runtime, &temporary, "file:orca-runtime-chosen-field-cover?mode=memory&cache=shared");
    var page = try runtime.libraryTrackQuery(library, "", .{ .limit = 16 });
    defer page.deinit();

    var covered: ?struct { track_id: i64, release_id: i64 } = null;
    for (page.items) |item| {
        const states = try runtime.libraryTrackFieldStates(library, &.{item.id});
        defer states.deinit();
        if (states.cover.source == .embedded) covered = .{ .track_id = item.id, .release_id = item.release_id.? };
    }
    const track = covered orelse return error.TestExpectedEmbeddedCover;

    var png: [33]u8 = undefined;
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, png[8..12], 13, .big);
    @memcpy(png[12..16], "IHDR");
    std.mem.writeInt(u32, png[16..20], 600, .big);
    std.mem.writeInt(u32, png[20..24], 600, .big);
    @memcpy(png[24..33], "\x08\x02\x00\x00\x00\x00\x00\x00\x00");
    try runtime.librarySetReleaseArtwork(library, track.release_id, .front, &png, "image/png");
    const chosen = try runtime.libraryTrackFieldStates(library, &.{track.track_id});
    defer chosen.deinit();
    try std.testing.expectEqual(runtime_module.TrackFieldCoverSource.chosen, chosen.cover.source);
    try std.testing.expectEqual(@as(u32, 1), chosen.cover.tracks);
    try std.testing.expect(chosen.cover.mime_type == null and chosen.cover.file_name == null);

    try std.testing.expect(try runtime.libraryClearReleaseArtwork(library, track.release_id, .front));
    const cleared = try runtime.libraryTrackFieldStates(library, &.{track.track_id});
    defer cleared.deinit();
    try std.testing.expectEqual(runtime_module.TrackFieldCoverSource.embedded, cleared.cover.source);
}

test "a value stored under a field number this build does not know is skipped by edits, tag-write planning and the projection" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempLibrary(&runtime, &temporary, "file:orca-runtime-unknown-field?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    const edited = try runtime.libraryEditTracks(library, ids, &.{.{ .field = .album, .value = "Known Album" }});
    defer edited.deinit();
    try library_database.database.exec(
        \\INSERT INTO orca_metadata_values(file_id, field, value, provenance, locked, updated_at)
        \\SELECT id, 99, 'from a newer build', 1, 1, unixepoch() FROM files;
    );
    try std.testing.expectEqual(@as(i64, 3), try database.columns.scalar(
        library_database.database,
        "SELECT count(*) FROM orca_metadata_values WHERE field = 99;",
    ));

    for (edited.ids) |track_id| {
        var values = try runtime.libraryTrackEdits(library, track_id);
        defer values.deinit();
        try std.testing.expectEqual(@as(usize, 1), values.items.len);
        try std.testing.expectEqual(metadata.Field.album, values.items[0].field);
    }

    const preview = try runtime.planTagWrite(library, std.testing.io, edited.ids);
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 2), preview.files.len);
    for (preview.files) |file| {
        try std.testing.expectEqual(@as(usize, 1), file.changes.len);
        try std.testing.expectEqual(metadata.Field.album, file.changes[0].field);
    }
    try runtime.discardTagWrite(library, preview.plan_id);

    var projection: library_pass.Projection = .{ .allocator = std.testing.allocator, .library = library_database };
    _ = try projection.run(.all);
    var page = try runtime.libraryTrackQuery(library, "", .{ .limit = 16 });
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 3), page.items.len);
    for (page.items) |item| try std.testing.expectEqualStrings("Known Album", item.album);
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

test "a tag write refuses to start while another process holds the journal lock and its plan stays pending" {
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
    (try runtime.libraryEditTracks(library, ids, &.{.{ .field = .album, .value = "Locked Album" }})).deinit();
    const edited = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(edited);
    const preview = try runtime.planTagWrite(library, std.testing.io, edited);
    defer preview.deinit();
    const library_database = try libraryDatabase(&runtime, library);
    const original_mp3 = try temporary.dir.readFileAlloc(std.testing.io, "a.mp3", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(original_mp3);

    var foreign = (try metadata.JournalLock.tryAcquire(std.testing.io, library_database.journal_lock_path.?)).?;
    try std.testing.expectError(error.MutationInProgress, runtime.startTagWrite(library, preview.plan_id, preview.digest));
    const untouched_mp3 = try temporary.dir.readFileAlloc(std.testing.io, "a.mp3", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(untouched_mp3);
    try std.testing.expectEqualSlices(u8, original_mp3, untouched_mp3);
    try std.testing.expectEqual(@as(u64, 1), try library_database.mutation_journal.nextGroupId());

    foreign.release(std.testing.io);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startTagWrite(library, preview.plan_id, preview.digest)));
}

test "undoing a tag write that was already undone reports it and re-observes the files" {
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
    (try runtime.libraryEditTracks(library, ids, &.{.{ .field = .album, .value = "Undone Album" }})).deinit();
    const edited = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(edited);
    const preview = try runtime.planTagWrite(library, std.testing.io, edited);
    defer preview.deinit();
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startTagWrite(library, preview.plan_id, preview.digest)));
    const library_database = try libraryDatabase(&runtime, library);
    {
        var lock = try metadata.JournalLock.acquireForMutation(std.testing.io, library_database.journal_lock_path);
        defer lock.release(std.testing.io);
        var executor: metadata.executor.Executor = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .journal = &library_database.mutation_journal,
            .journal_lock = &lock,
            .backup_directory = library_database.backup_directory,
        };
        try executor.undoGroup(preview.plan_id);
    }
    const written = (try library_database.observed_tags.get(std.testing.allocator, preview.files[0].file_id)).?;
    defer written.deinit();
    try std.testing.expectEqualStrings("Undone Album", written.values.album.?);

    try std.testing.expectError(error.MutationGroupAlreadyUndone, runtime.undoTagWrite(library, std.testing.io, preview.plan_id));
    const stored = (try library_database.observed_tags.get(std.testing.allocator, preview.files[0].file_id)).?;
    defer stored.deinit();
    try std.testing.expect(stored.values.album == null or !std.mem.eql(u8, stored.values.album.?, "Undone Album"));
}

/// Another process's work under its own journal lock: a write of `a.mp3` that
/// commits as group 900, then a write of `c.m4a` that it abandons after the
/// rename, as group 901. Returns the abandoned operation.
fn foreignWrites(
    library_database: *database.LibraryDatabase,
    temporary: *std.testing.TmpDir,
    lock: *const metadata.JournalLock,
) !i64 {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const a_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/a.mp3", .{temporary.sub_path});
    defer allocator.free(a_path);
    const actions = [_]metadata.mutation.Action{.{ .write_tags = .{
        .path = a_path,
        .expected = try metadata.file_mutation.identity(io, a_path),
        .changes = &.{.{ .field = .title, .before = null, .after = "Foreign" }},
    } }};
    var plan = try metadata.mutation.Plan.init(allocator, 900, &actions);
    defer plan.deinit();
    try plan.approve(plan.approval());
    var executor: metadata.executor.Executor = .{
        .allocator = allocator,
        .io = io,
        .journal = &library_database.mutation_journal,
        .journal_lock = lock,
        .backup_directory = library_database.backup_directory,
    };
    try executor.executePlan(&plan, 900);

    const c_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/c.m4a", .{temporary.sub_path});
    defer allocator.free(c_path);
    const stage = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/.c.m4a.orca-stage-901-0", .{temporary.sub_path});
    defer allocator.free(stage);
    const plan_backups = try std.fmt.allocPrint(allocator, "{s}/901", .{library_database.backup_directory.?});
    defer allocator.free(plan_backups);
    const backup = try std.fmt.allocPrint(allocator, "{s}/0-c.m4a", .{plan_backups});
    defer allocator.free(backup);
    const original = try metadata.file_mutation.identity(io, c_path);
    const journal = &library_database.mutation_journal;
    const operation = try journal.prepare(.{
        .plan_id = 901,
        .group_id = 901,
        .action_index = 0,
        .kind = .write_tags,
        .source_path = c_path,
        .stage_path = stage,
        .backup_path = backup,
        .expected_size = original.size_bytes,
        .expected_modified_ns = original.modified_ns,
        .expected_quick_hash = original.quick_hash,
        .expected_content_hash = original.content_hash,
    });
    const bytes = try temporary.dir.readFileAlloc(io, "c.m4a", allocator, .limited(1 << 22));
    defer allocator.free(bytes);
    const replacement = try std.mem.concat(allocator, u8, &.{ bytes, "abandoned" });
    defer allocator.free(replacement);
    try temporary.dir.writeFile(io, .{ .sub_path = ".c.m4a.orca-stage-901-0", .data = replacement });
    const staged = try metadata.file_mutation.identity(io, stage);
    try journal.recordResultIdentity(operation, .planned, staged.size_bytes, staged.modified_ns, staged.quick_hash, staged.content_hash.?);
    try journal.transition(operation, .planned, .staged, null);
    try metadata.file_mutation.createDirectoryDurably(io, library_database.backup_directory.?);
    try metadata.file_mutation.createDirectoryDurably(io, plan_backups);
    try metadata.file_mutation.commitReplacement(io, c_path, stage, backup, original);
    return operation;
}

const MutationAfterAbandon = enum { write, undo, prune };

/// Open the Library while another process holds the journal lock, let that
/// process abandon a write and exit, then run `mutation`: it must first
/// finish the abandoned write.
fn expectAbandonedWriteRecoveredFirst(mutation: MutationAfterAbandon) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try tempDatabasePath(&data);
    defer allocator.free(database_path);
    const lock_path = lock_path: {
        var created = try database.LibraryDatabase.open(allocator, io, database_path);
        defer created.close();
        break :lock_path try allocator.dupe(u8, created.journal_lock_path.?);
    };
    defer allocator.free(lock_path);
    var foreign = (try metadata.JournalLock.tryAcquire(io, lock_path)).?;
    var foreign_held = true;
    defer if (foreign_held) foreign.release(io);
    var runtime = OrcaRuntime.init(allocator);
    defer runtime.deinit();
    const library = try scannedTempLibrary(&runtime, &temporary, database_path);
    const library_database = try libraryDatabase(&runtime, library);
    try std.testing.expect(library_database.recovery_deferred.load(.acquire));
    const a_original = try temporary.dir.readFileAlloc(io, "a.mp3", allocator, .limited(1 << 22));
    defer allocator.free(a_original);
    const c_original = try temporary.dir.readFileAlloc(io, "c.m4a", allocator, .limited(1 << 22));
    defer allocator.free(c_original);
    const abandoned = try foreignWrites(library_database, &temporary, &foreign);
    foreign.release(io);
    foreign_held = false;
    try std.testing.expectEqual(database.repository.MutationState.staged, try library_database.mutation_journal.state(abandoned));

    switch (mutation) {
        .write => {
            const ids = try allTrackIds(&runtime, library);
            defer allocator.free(ids);
            (try runtime.libraryEditTracks(library, ids, &.{.{ .field = .album, .value = "After Recovery" }})).deinit();
            const edited = try allTrackIds(&runtime, library);
            defer allocator.free(edited);
            const preview = try runtime.planTagWrite(library, io, edited);
            defer preview.deinit();
            try std.testing.expectEqual(@as(usize, 1), preview.files.len);
            try std.testing.expect(std.mem.endsWith(u8, preview.files[0].path, "b.flac"));
            try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startTagWrite(library, preview.plan_id, preview.digest)));
            const written = try library_database.mutation_journal.groupOperationIds(allocator, preview.plan_id);
            defer allocator.free(written);
            for (written) |id| try std.testing.expectEqual(database.repository.MutationState.committed, try library_database.mutation_journal.state(id));
        },
        .undo => {
            try runtime.undoTagWrite(library, io, 900);
            const restored = try temporary.dir.readFileAlloc(io, "a.mp3", allocator, .limited(1 << 22));
            defer allocator.free(restored);
            try std.testing.expectEqualSlices(u8, a_original, restored);
        },
        .prune => try std.testing.expectEqual(@as(u64, 1), (try runtime.pruneTagWriteBackups(library, io, 0)).backups),
    }
    try std.testing.expectEqual(database.repository.MutationState.rolled_back, try library_database.mutation_journal.state(abandoned));
    const c_after = try temporary.dir.readFileAlloc(io, "c.m4a", allocator, .limited(1 << 22));
    defer allocator.free(c_after);
    try std.testing.expectEqualSlices(u8, c_original, c_after);
    try std.testing.expect(!library_database.recovery_deferred.load(.acquire));
}

test "a tag write first recovers a write another process abandoned after this one opened the Library" {
    try expectAbandonedWriteRecoveredFirst(.write);
}

test "an undo first recovers a write another process abandoned after this one opened the Library" {
    try expectAbandonedWriteRecoveredFirst(.undo);
}

test "pruning first recovers a write another process abandoned after this one opened the Library" {
    try expectAbandonedWriteRecoveredFirst(.prune);
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

test "a file in a folder Orca cannot create files in is skipped before writing" {
    if (builtin.os.tag != .linux or std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try tempDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    try temporary.dir.createDirPath(std.testing.io, "locked");
    try temporary.dir.createDirPath(std.testing.io, "open");
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "locked/b.flac");
    try copyFixtureInto(temporary.dir, "fixtures/audio/covered-reference.mp3", "open/a.mp3");
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempFolder(&runtime, &temporary, database_path);
    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    const edited = try runtime.libraryEditTracks(library, ids, &.{.{ .field = .title, .value = "Written Title" }});
    defer edited.deinit();
    const original = try temporary.dir.readFileAlloc(std.testing.io, "locked/b.flac", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(original);
    try temporary.dir.setFilePermissions(std.testing.io, "locked", .fromMode(0o555), .{});
    defer temporary.dir.setFilePermissions(std.testing.io, "locked", .default_dir, .{}) catch {};

    const preview = try runtime.planTagWrite(library, std.testing.io, edited.ids);
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 1), preview.files.len);
    try std.testing.expect(std.mem.endsWith(u8, preview.files[0].path, "open/a.mp3"));
    try std.testing.expectEqual(@as(usize, 1), preview.skipped.len);
    try std.testing.expectEqual(TagWriteSkipReason.folder_not_writable, preview.skipped[0].reason);
    try std.testing.expect(std.mem.endsWith(u8, preview.skipped[0].path, "locked/b.flac"));

    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startTagWrite(library, preview.plan_id, preview.digest)));
    const library_database = try libraryDatabase(&runtime, library);
    try std.testing.expectEqual(@as(i64, 1), try database.columns.scalar(library_database.database, "SELECT count(*) FROM mutation_operations;"));
    try std.testing.expectEqual(@as(i64, 0), try database.columns.scalar(library_database.database, "SELECT count(*) FROM mutation_operations WHERE source_path LIKE '%/locked/%';"));
    const after = try temporary.dir.readFileAlloc(std.testing.io, "locked/b.flac", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, original, after);
    var locked = try temporary.dir.openDir(std.testing.io, "locked", .{ .iterate = true });
    defer locked.close(std.testing.io);
    var entries = locked.iterate();
    try std.testing.expectEqualStrings("b.flac", (try entries.next(std.testing.io)).?.name);
    try std.testing.expect(try entries.next(std.testing.io) == null);
}

test "a failed tag write reports its file and reason" {
    if (builtin.os.tag != .linux or std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
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
    const edited = try runtime.libraryEditTracks(library, ids, &.{.{ .field = .title, .value = "Written Title" }});
    defer edited.deinit();
    const preview = try runtime.planTagWrite(library, std.testing.io, edited.ids);
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 2), preview.files.len);
    const original = try temporary.dir.readFileAlloc(std.testing.io, "b.flac", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(original);
    try temporary.parent_dir.setFilePermissions(std.testing.io, &temporary.sub_path, .fromMode(0o555), .{});
    defer temporary.parent_dir.setFilePermissions(std.testing.io, &temporary.sub_path, .default_dir, .{}) catch {};

    const job_handle = try runtime.startTagWrite(library, preview.plan_id, preview.digest);
    try std.testing.expectEqual(job.State.failed, try awaitJob(&runtime, job_handle));
    const failure = (try runtime.jobTagWriteFailure(job_handle)).?;
    try std.testing.expectEqual(preview.files[0].file_id, failure.file_id);
    try std.testing.expectEqual(@as(u32, 0), failure.action_index);
    try std.testing.expectEqual(TagWriteFailureReason.permission_denied, failure.reason);

    const library_database = try libraryDatabase(&runtime, library);
    try expectJournaledError(library_database, preview.plan_id, 0, "AccessDenied");
    _ = try runtime.pruneTagWriteBackups(library, std.testing.io, 0);
    try expectJournaledError(library_database, preview.plan_id, 0, "AccessDenied");
    const after = try temporary.dir.readFileAlloc(std.testing.io, "b.flac", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, original, after);
    try expectOnlyFixtureFiles(temporary.dir);

    const scan = try runtime.startLibraryScan(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, scan));
    try std.testing.expectError(error.NotATagWriteJob, runtime.jobTagWriteFailure(scan));
}

test "writing tags to one copy of a shared file splits that copy off and marks the written value on the file that holds it" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try tempDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    for ([_][]const u8{ "one", "two" }) |folder| try temporary.dir.createDir(std.testing.io, folder, .default_dir);
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "one/song.flac");
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "two/song.flac");
    const root = try absoluteTestPath(".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(root);
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, database_path);
    const binding = try runtime.libraryAddRoot(library, std.testing.io, root);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryScan(library, .{ .root_id = binding.root_id })));
    const library_database = try libraryDatabase(&runtime, library);
    try std.testing.expectEqual(@as(i64, 1), try database.columns.scalar(library_database.database, "SELECT count(*) FROM files;"));

    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    (try runtime.libraryEditTracks(library, ids, &.{.{ .field = .album, .value = "Written Album" }})).deinit();
    const edited = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(edited);
    const preview = try runtime.planTagWrite(library, std.testing.io, edited);
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 1), preview.files.len);
    const shared = preview.files[0].file_id;
    const written_path = preview.files[0].path;
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startTagWrite(library, preview.plan_id, preview.digest)));

    const untouched_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{
        root,
        if (std.mem.endsWith(u8, written_path, "one/song.flac")) "two/song.flac" else "one/song.flac",
    });
    defer std.testing.allocator.free(untouched_path);
    const written = (try library_database.files.resolveByUri(binding.volume_id, written_path)).?;
    try std.testing.expect(written != shared);
    try std.testing.expectEqual(@as(?i64, shared), try library_database.files.resolveByUri(binding.volume_id, untouched_path));
    var marked = try library_database.database.prepare(
        "SELECT count(*) FROM orca_metadata_values WHERE file_id=?1 AND value='Written Album' AND written_at IS NOT NULL;",
    );
    defer marked.deinit();
    for ([_]struct { file_id: i64, count: i64 }{ .{ .file_id = written, .count = 1 }, .{ .file_id = shared, .count = 0 } }) |expected| {
        try marked.reset();
        try marked.bindInt64(1, expected.file_id);
        try std.testing.expectEqual(database.sqlite.Step.row, try marked.step());
        try std.testing.expectEqual(expected.count, marked.columnInt64(0));
    }

    const after = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(after);
    const again = try runtime.planTagWrite(library, std.testing.io, after);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 1), again.files.len);
    try std.testing.expectEqual(shared, again.files[0].file_id);
    try std.testing.expectEqualStrings(untouched_path, again.files[0].path);
    try runtime.discardTagWrite(library, again.plan_id);
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
    const binding = try addFixturesRoot(&runtime, library);
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
    const binding = try addFixturesRoot(&runtime, library);
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

fn awaitBrowse(runtime: *OrcaRuntime, library: LibraryHandle, request: u64) !BrowseResult {
    var deadline: TestDeadline = .init(10_000);
    while (deadline.tick()) {
        const result = runtime.libraryTakeBrowse(library) orelse continue;
        errdefer result.deinit();
        try std.testing.expectEqual(request, result.request);
        return result;
    }
    return error.BrowseNeverFinished;
}

fn expectSameTracks(expected: []const database.TrackSummary, actual: []const database.TrackSummary) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |wanted, found| {
        try std.testing.expectEqual(wanted.id, found.id);
        try std.testing.expectEqualStrings(wanted.title, found.title);
    }
}

fn expectSameReleases(expected: []const database.ReleaseSummary, actual: []const database.ReleaseSummary) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |wanted, found| {
        try std.testing.expectEqual(wanted.id, found.id);
        try std.testing.expectEqualStrings(wanted.title, found.title);
    }
}

fn firstTitleWord(items: anytype) ![]const u8 {
    for (items) |item| {
        var words = std.mem.tokenizeAny(u8, item.title, " -()[]");
        if (words.next()) |word| return word;
    }
    return error.NoTitledItem;
}

test "browse requests answer exactly as the synchronous page, totals and count queries do" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-browse-round-trip?mode=memory&cache=shared");
    const binding = try addFixturesRoot(&runtime, library);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryScan(library, .{ .root_id = binding.root_id })));

    var every_track = try runtime.libraryTrackQuery(library, "", .{});
    defer every_track.deinit();
    const word = try firstTitleWord(every_track.items);
    const track_queries = [_]struct { text: []const u8, query: database.TrackQuery }{
        .{ .text = "", .query = .{ .sort = .title, .direction = .descending, .lossless = true, .limit = 7, .offset = 1 } },
        .{ .text = "", .query = .{ .sort = .path, .codec = "FLAC", .min_sample_rate = 44_100 } },
        .{ .text = word, .query = .{ .limit = 50 } },
    };
    for (track_queries) |listing| {
        var expected = try runtime.libraryTrackQuery(library, listing.text, listing.query);
        defer expected.deinit();
        try std.testing.expect(expected.items.len > 0);
        const page_request = try runtime.libraryRequestBrowse(library, std.testing.io, .{ .track_page = .{ .text = listing.text, .query = listing.query } });
        const page = try awaitBrowse(&runtime, library, page_request);
        defer page.deinit();
        try std.testing.expectEqual(runtime_module.BrowseKind.track_page, page.kind);
        try expectSameTracks(expected.items, (try page.payload).track_page.items);

        const expected_totals = try runtime.libraryTrackQueryTotals(library, listing.text, listing.query);
        try std.testing.expect(expected_totals.count > 0);
        const totals_request = try runtime.libraryRequestBrowse(library, std.testing.io, .{ .track_totals = .{ .text = listing.text, .query = listing.query } });
        const totals = try awaitBrowse(&runtime, library, totals_request);
        try std.testing.expectEqual(runtime_module.BrowseKind.track_totals, totals.kind);
        try std.testing.expectEqual(expected_totals, (try totals.payload).track_totals);
    }

    var every_release = try runtime.libraryReleasePage(library, .{});
    defer every_release.deinit();
    const release_queries = [_]database.ReleaseQuery{
        .{ .sort = .artist, .limit = 5, .offset = 1 },
        .{ .sort = .year, .lossless_only = true },
        .{ .text = try firstTitleWord(every_release.items) },
    };
    for (release_queries) |query| {
        var expected = try runtime.libraryReleasePage(library, query);
        defer expected.deinit();
        try std.testing.expect(expected.items.len > 0);
        const page_request = try runtime.libraryRequestBrowse(library, std.testing.io, .{ .release_page = query });
        const page = try awaitBrowse(&runtime, library, page_request);
        defer page.deinit();
        try std.testing.expectEqual(runtime_module.BrowseKind.release_page, page.kind);
        try expectSameReleases(expected.items, (try page.payload).release_page.items);

        const expected_count = try runtime.libraryReleaseCountMatching(library, query);
        const count_request = try runtime.libraryRequestBrowse(library, std.testing.io, .{ .release_count = query });
        const count = try awaitBrowse(&runtime, library, count_request);
        try std.testing.expectEqual(runtime_module.BrowseKind.release_count, count.kind);
        try std.testing.expectEqual(expected_count, (try count.payload).release_count);
    }
}

test "a browse request copies its text, so changing the caller's buffers afterwards changes nothing" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-browse-copies?mode=memory&cache=shared");
    const binding = try addFixturesRoot(&runtime, library);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryScan(library, .{ .root_id = binding.root_id })));
    const library_database = try libraryDatabase(&runtime, library);
    var registration: work.Registration = .{};
    var loader: browse_loader.Loader = .init(std.testing.allocator, library_database, try library_database.openReader(), &registration);
    defer loader.deinit();

    var flac = try runtime.libraryTrackQuery(library, "", .{ .codec = "flac" });
    defer flac.deinit();
    var releases = try runtime.libraryReleasePage(library, .{});
    defer releases.deinit();
    const track_word = try firstTitleWord(flac.items);
    const release_word = try firstTitleWord(releases.items);
    var track_text: [64]u8 = undefined;
    var codec: [8]u8 = undefined;
    var release_text: [64]u8 = undefined;
    @memcpy(track_text[0..track_word.len], track_word);
    @memcpy(codec[0..4], "flac");
    @memcpy(release_text[0..release_word.len], release_word);
    const track_query: database.TrackQuery = .{ .codec = codec[0..4] };
    try loader.request(std.testing.io, 1, .{ .track_page = .{ .text = track_text[0..track_word.len], .query = track_query } });
    try loader.request(std.testing.io, 2, .{ .track_totals = .{ .text = track_text[0..track_word.len], .query = track_query } });
    try loader.request(std.testing.io, 3, .{ .release_page = .{ .text = release_text[0..release_word.len] } });
    try loader.request(std.testing.io, 4, .{ .release_count = .{ .text = release_text[0..release_word.len] } });
    @memset(&track_text, 'q');
    @memset(&codec, 'q');
    @memset(&release_text, 'q');
    while (loader.step()) {}

    var expected_tracks = try runtime.libraryTrackQuery(library, track_word, .{ .codec = "flac" });
    defer expected_tracks.deinit();
    try std.testing.expect(expected_tracks.items.len > 0);
    var changed_tracks = try runtime.libraryTrackQuery(library, track_text[0..track_word.len], .{ .codec = codec[0..4] });
    defer changed_tracks.deinit();
    try std.testing.expectEqual(@as(usize, 0), changed_tracks.items.len);
    const track_page = loader.take().?;
    defer track_page.deinit();
    try expectSameTracks(expected_tracks.items, (try track_page.payload).track_page.items);
    const track_totals = loader.take().?;
    try std.testing.expectEqual(try runtime.libraryTrackQueryTotals(library, track_word, .{ .codec = "flac" }), (try track_totals.payload).track_totals);

    var expected_releases = try runtime.libraryReleasePage(library, .{ .text = release_word });
    defer expected_releases.deinit();
    try std.testing.expect(expected_releases.items.len > 0);
    try std.testing.expectEqual(@as(u64, 0), try runtime.libraryReleaseCountMatching(library, .{ .text = release_text[0..release_word.len] }));
    const release_page = loader.take().?;
    defer release_page.deinit();
    try expectSameReleases(expected_releases.items, (try release_page.payload).release_page.items);
    const release_count = loader.take().?;
    try std.testing.expectEqual(@as(u64, expected_releases.items.len), (try release_count.payload).release_count);
}

test "closing a library or the runtime with browse requests in flight joins the loader and frees every result" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const closed = try runtime.openLibrary(std.testing.io, "file:orca-browse-close-a?mode=memory&cache=shared");
    const left_open = try runtime.openLibrary(std.testing.io, "file:orca-browse-close-b?mode=memory&cache=shared");
    for ([_]LibraryHandle{ closed, left_open }) |library| {
        const binding = try addFixturesRoot(&runtime, library);
        try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryScan(library, .{ .root_id = binding.root_id })));
    }
    for ([_]LibraryHandle{ closed, left_open }) |library| {
        for (0..browse_loader.capacity) |index| _ = try runtime.libraryRequestBrowse(library, std.testing.io, switch (index % 4) {
            0 => .{ .track_page = .{ .query = .{ .sort = .path } } },
            1 => .{ .track_totals = .{ .query = .{ .lossless = true } } },
            2 => .{ .release_page = .{ .sort = .artist } },
            else => .{ .release_count = .{ .lossless_only = true } },
        });
        try std.testing.expectError(error.BrowseQueueFull, runtime.libraryRequestBrowse(library, std.testing.io, .{ .release_count = .{} }));
    }
    const loader = &(try runtime.libraries.get(closed)).browse.?.loader;
    var deadline: TestDeadline = .init(5_000);
    while (loader.results.len() == 0 and deadline.tick()) {}
    try runtime.destroyLibrary(closed);
    try std.testing.expect(runtime.libraryTakeBrowse(closed) == null);
    try std.testing.expectEqual(@as(?*runtime_module.BrowseLoader, null), (try runtime.libraries.get(left_open)).browse);
    try std.testing.expectEqual(@as(usize, 0), inFlightWorkCount(&runtime));

    for (0..browse_loader.capacity) |_| _ = try runtime.libraryRequestBrowse(left_open, std.testing.io, .{ .track_page = .{ .query = .{ .sort = .genre } } });
}

test "a browse result for a closed library is never delivered to the library that reuses its slot" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const first = try runtime.openLibrary(std.testing.io, "file:orca-browse-slot-a?mode=memory&cache=shared");
    const finished = try runtime.libraryRequestBrowse(first, std.testing.io, .{ .track_totals = .{} });
    const loader = &(try runtime.libraries.get(first)).browse.?.loader;
    var deadline: TestDeadline = .init(5_000);
    while (loader.results.len() == 0 and deadline.tick()) {}
    try std.testing.expectEqual(@as(usize, 1), loader.results.len());
    const pending = try runtime.libraryRequestBrowse(first, std.testing.io, .{ .release_page = .{} });
    try runtime.destroyLibrary(first);

    const second = try runtime.openLibrary(std.testing.io, "file:orca-browse-slot-b?mode=memory&cache=shared");
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(runtime.libraryTakeBrowse(first) == null);
    try std.testing.expect(runtime.libraryTakeBrowse(second) == null);
    try std.testing.expectEqual(@as(?*runtime_module.BrowseLoader, null), (try runtime.libraries.get(second)).browse);

    const fresh = try runtime.libraryRequestBrowse(second, std.testing.io, .{ .track_totals = .{} });
    try std.testing.expect(fresh > finished and fresh > pending);
    const result = try awaitBrowse(&runtime, second, fresh);
    try std.testing.expectEqual(@as(u64, 0), (try result.payload).track_totals.count);
    var quiet: TestDeadline = .init(20);
    while (quiet.tick()) try std.testing.expect(runtime.libraryTakeBrowse(second) == null);
}

test "every release order lists the same releases, each in its own order" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-release-sorts?mode=memory&cache=shared");
    const binding = try addFixturesRoot(&runtime, library);
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
    const binding = try addFixturesRoot(&runtime, library);
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

test "queue history lists skipped and replaced entries newest first, and saving the queue keeps the current entry and those after it" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());
    const library = try runtime.openLibrary(std.testing.io, "file:orca-queue-history?mode=memory&cache=shared");
    const binding = try addFixturesRoot(&runtime, library);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryScan(library, .{ .root_id = binding.root_id })));
    var page = try runtime.libraryTrackQuery(library, "", .{ .limit = 6, .sort = .id });
    defer page.deinit();
    var ids: [6]i64 = undefined;
    var playable: usize = 0;
    for (page.items) |item| {
        if (!item.has_playable_file or item.recording_id == null) continue;
        ids[playable] = item.id;
        playable += 1;
    }
    try std.testing.expect(playable >= 4);

    const player = try runtime.createPlayer();
    try runtime.playerBindLibrary(player, library, std.testing.io);
    try std.testing.expectError(error.QueueEmpty, runtime.playerSaveQueueAsPlaylist(player, library, "Empty"));
    try runtime.playerPlayTracksBound(player, library, ids[0..3], 0);
    try runtime.pausePlayer(player);
    try std.testing.expect(try runtime.playerNext(player));
    try runtime.pausePlayer(player);
    try runtime.playerQueueJump(player, 0);
    try runtime.pausePlayer(player);
    try runtime.playerPlayTracksBound(player, library, ids[1..4], 1);
    try runtime.pausePlayer(player);

    var entries: [8]QueueHistoryEntry = undefined;
    try std.testing.expectEqual(@as(usize, 3), try runtime.playerQueueHistory(player, 0, &entries));
    try std.testing.expectEqual(ids[0], entries[0].track.track_id);
    try std.testing.expectEqual(QueueHistoryReason.replaced, entries[0].reason);
    try std.testing.expectEqual(ids[1], entries[1].track.track_id);
    try std.testing.expectEqual(QueueHistoryReason.skipped, entries[1].reason);
    try std.testing.expectEqual(ids[0], entries[2].track.track_id);
    try std.testing.expectEqual(QueueHistoryReason.skipped, entries[2].reason);
    try std.testing.expectEqual(@as(usize, 2), try runtime.playerQueueHistory(player, 1, &entries));
    try std.testing.expectEqual(ids[1], entries[0].track.track_id);

    var tracks = try runtime.playerQueueHistoryTracks(player, std.testing.allocator, 0, 8);
    defer tracks.deinit();
    try std.testing.expectEqual(@as(usize, 3), tracks.items.len);
    try std.testing.expectEqual(ids[0], tracks.items[0].id);
    try std.testing.expectEqual(ids[1], tracks.items[1].id);
    try std.testing.expectError(error.PageOutOfRange, runtime.playerQueueHistoryTracks(player, std.testing.allocator, 0, 0));

    const playlist = try runtime.playerSaveQueueAsPlaylist(player, library, "Saved Queue");
    var saved = try runtime.libraryPlaylistEntries(library, playlist, 10, 0);
    defer saved.deinit();
    try std.testing.expectEqual(@as(usize, 2), saved.items.len);
    try std.testing.expectEqual(ids[2], saved.items[0].track.?.id);
    try std.testing.expectEqual(ids[3], saved.items[1].track.?.id);
    try std.testing.expectError(error.PlaylistNameTaken, runtime.playerSaveQueueAsPlaylist(player, library, "Saved Queue"));

    try runtime.playerClearQueueHistory(player);
    try std.testing.expectEqual(@as(usize, 0), try runtime.playerQueueHistory(player, 0, &entries));
}

test "a root cannot be removed while a job runs on its library, and afterwards its tracks leave the library" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try copyFixtureInto(temporary.dir, "fixtures/audio/covered-reference.mp3", "a.mp3");
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "b.flac");
    const root = try absoluteTestPath(".zig-cache/tmp/{s}", .{temporary.sub_path});
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
    data: ?std.testing.TmpDir,
    runtime: OrcaRuntime,
    root: []u8,
    library: LibraryHandle,
    root_id: i64,

    fn init(self: *ReconcileFixture, name: [:0]const u8) !void {
        self.data = null;
        return self.initAt(name);
    }

    fn initFile(self: *ReconcileFixture) !void {
        self.data = std.testing.tmpDir(.{});
        errdefer self.data.?.cleanup();
        const path = try tempDatabasePath(&self.data.?);
        defer std.testing.allocator.free(path);
        return self.initAt(path);
    }

    fn initAt(self: *ReconcileFixture, name: [:0]const u8) !void {
        self.temporary = std.testing.tmpDir(.{});
        errdefer self.temporary.cleanup();
        try self.temporary.dir.createDirPath(std.testing.io, "A");
        try self.temporary.dir.createDirPath(std.testing.io, "B");
        try copyFixtureInto(self.temporary.dir, "fixtures/audio/tagged-reference.flac", "A/one.flac");
        try copyFixtureInto(self.temporary.dir, "fixtures/audio/covered-reference.mp3", "B/two.mp3");
        self.root = try absoluteTestPath(".zig-cache/tmp/{s}", .{self.temporary.sub_path});
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
        if (self.data) |*data| data.cleanup();
    }

    fn databasePath(self: *ReconcileFixture) ![:0]u8 {
        return tempDatabasePath(&self.data.?);
    }

    fn walkLockPath(self: *ReconcileFixture) ![]const u8 {
        return (try libraryDatabase(&self.runtime, self.library)).walk_lock_path.?;
    }

    fn expectWalkLockFree(self: *ReconcileFixture) !void {
        var lock = try library_pass.WalkLock.tryAcquire(std.testing.io, try self.walkLockPath()) orelse
            return error.WalkLockHeld;
        lock.release(std.testing.io);
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

    fn scanRunTotal(self: *ReconcileFixture) !i64 {
        const library_database = try libraryDatabase(&self.runtime, self.library);
        var statement = try library_database.database.prepare("SELECT count(*) FROM scan_runs WHERE root_id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, self.root_id);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    fn scanRunCount(self: *ReconcileFixture, state: database.ScanRunState) !i64 {
        const library_database = try libraryDatabase(&self.runtime, self.library);
        var statement = try library_database.database.prepare(
            "SELECT count(*) FROM scan_runs WHERE root_id=?1 AND state=?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, self.root_id);
        try statement.bindText(2, state.text());
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    fn removeRootDirectory(self: *ReconcileFixture) !void {
        try self.temporary.parent_dir.deleteTree(std.testing.io, &self.temporary.sub_path);
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

test "a reconcile whose directory cannot be opened fails and sweeps nothing under it, while the other directories are swept" {
    if (builtin.os.tag != .linux or std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-reconcile-unreadable?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.temporary.dir.deleteFile(std.testing.io, "A/one.flac");
    try fixture.temporary.dir.deleteFile(std.testing.io, "B/two.mp3");
    try fixture.temporary.dir.setFilePermissions(std.testing.io, "A", .fromMode(0), .{});
    defer fixture.temporary.dir.setFilePermissions(std.testing.io, "A", .default_dir, .{}) catch {};

    const outcome = try fixture.reconcile(&.{ "A", "B" });
    try std.testing.expectEqual(job.State.failed, outcome.state);
    try std.testing.expectEqual(@as(u64, 1), outcome.stats.errors);
    try std.testing.expectEqual(@as(u64, 1), outcome.stats.marked_missing);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("A/one.flac")).?.state);
    try std.testing.expectEqual(database.LocationState.missing, (try fixture.location("B/two.mp3")).?.state);
    try std.testing.expectEqual(@as(i64, 1), try fixture.scanRunCount(.failed));
    try std.testing.expectEqual(@as(i64, 0), try fixture.scanRunCount(.running));
}

test "a reconcile keeps everything under a subdirectory it cannot enter and still sweeps what is gone" {
    if (builtin.os.tag != .linux or std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-reconcile-unenterable?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.temporary.dir.createDirPath(std.testing.io, "A/Locked");
    try copyFixtureInto(fixture.temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "A/Locked/three.m4a");
    try std.testing.expectEqual(job.State.succeeded, (try fixture.reconcile(&.{"A"})).state);
    try fixture.temporary.dir.deleteFile(std.testing.io, "A/one.flac");
    try fixture.temporary.dir.setFilePermissions(std.testing.io, "A/Locked", .fromMode(0), .{});
    defer fixture.temporary.dir.setFilePermissions(std.testing.io, "A/Locked", .default_dir, .{}) catch {};

    const outcome = try fixture.reconcile(&.{"A"});
    try std.testing.expectEqual(job.State.succeeded, outcome.state);
    try std.testing.expectEqual(@as(u64, 1), outcome.stats.errors);
    try std.testing.expectEqual(@as(u64, 1), outcome.stats.marked_missing);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("A/Locked/three.m4a")).?.state);
    try std.testing.expectEqual(database.LocationState.missing, (try fixture.location("A/one.flac")).?.state);
    try std.testing.expectEqual(@as(i64, 3), try fixture.scanRunCount(.completed));
}

test "re-observing a file it cannot read keeps the file and reports the error" {
    if (builtin.os.tag != .linux or std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-reobserve-unreadable?mode=memory&cache=shared");
    defer fixture.deinit();
    const kept = (try fixture.location("A/one.flac")).?;
    const uri = try std.fmt.allocPrint(std.testing.allocator, "{s}/A/one.flac", .{fixture.root});
    defer std.testing.allocator.free(uri);
    const library_database = try libraryDatabase(&fixture.runtime, fixture.library);
    const location = (try library_database.locations.presentByUri(std.testing.allocator, uri)).?;
    defer std.testing.allocator.free(location.uri);
    try fixture.temporary.dir.setFilePermissions(std.testing.io, "A/one.flac", .fromMode(0), .{});
    defer fixture.temporary.dir.setFilePermissions(std.testing.io, "A/one.flac", .default_file, .{}) catch {};

    try std.testing.expectError(error.ReadFailed, job_worker.reobserve(std.testing.allocator, std.testing.io, library_database, location));
    const after = (try fixture.location("A/one.flac")).?;
    try std.testing.expectEqual(database.LocationState.present, after.state);
    try std.testing.expectEqual(kept.file_id, after.file_id);
}

test "a scan that cannot enter a directory succeeds, keeps everything under it and still sweeps what is gone" {
    if (builtin.os.tag != .linux or std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-scan-unenterable?mode=memory&cache=shared");
    defer fixture.deinit();
    const scanned = (try fixture.location("A/one.flac")).?;
    try fixture.temporary.dir.deleteFile(std.testing.io, "B/two.mp3");
    try fixture.temporary.dir.setFilePermissions(std.testing.io, "A", .fromMode(0), .{});
    defer fixture.temporary.dir.setFilePermissions(std.testing.io, "A", .default_dir, .{}) catch {};

    const job_handle = try fixture.runtime.startLibraryScan(fixture.library, .{ .root_id = fixture.root_id });
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&fixture.runtime, job_handle));
    const stats = try fixture.runtime.jobScanStats(job_handle);
    try std.testing.expectEqual(@as(u64, 1), stats.errors);
    try std.testing.expectEqual(@as(u64, 1), stats.marked_missing);
    const kept = (try fixture.location("A/one.flac")).?;
    try std.testing.expectEqual(database.LocationState.present, kept.state);
    try std.testing.expectEqual(scanned.generation + 1, kept.generation);
    try std.testing.expectEqual(database.LocationState.missing, (try fixture.location("B/two.mp3")).?.state);
    try std.testing.expectEqual(@as(i64, 2), try fixture.scanRunCount(.completed));
}

test "a scan whose root directory cannot be opened fails its run and marks nothing missing" {
    if (builtin.os.tag != .linux or std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-scan-root-locked?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.temporary.dir.deleteFile(std.testing.io, "B/two.mp3");
    try fixture.temporary.parent_dir.setFilePermissions(std.testing.io, &fixture.temporary.sub_path, .fromMode(0), .{});
    defer fixture.temporary.parent_dir.setFilePermissions(std.testing.io, &fixture.temporary.sub_path, .default_dir, .{}) catch {};

    const job_handle = try fixture.runtime.startLibraryScan(fixture.library, .{ .root_id = fixture.root_id });
    try std.testing.expectEqual(job.State.failed, try awaitJob(&fixture.runtime, job_handle));
    const stats = try fixture.runtime.jobScanStats(job_handle);
    try std.testing.expect(!stats.volume_changed);
    try std.testing.expectEqual(@as(u64, 0), stats.marked_missing);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("B/two.mp3")).?.state);
    try std.testing.expectEqual(@as(i64, 1), try fixture.scanRunCount(.failed));
    try std.testing.expectEqual(@as(i64, 0), try fixture.scanRunCount(.running));
}

test "a scan that cannot open a file succeeds, keeps the file present and still sweeps what is gone" {
    if (builtin.os.tag != .linux or std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-scan-unopenable-file?mode=memory&cache=shared");
    defer fixture.deinit();
    const scanned = (try fixture.location("A/one.flac")).?;
    try fixture.temporary.dir.deleteFile(std.testing.io, "B/two.mp3");
    try fixture.temporary.dir.setFilePermissions(std.testing.io, "A/one.flac", .fromMode(0), .{});
    defer fixture.temporary.dir.setFilePermissions(std.testing.io, "A/one.flac", .default_file, .{}) catch {};

    const job_handle = try fixture.runtime.startLibraryScan(fixture.library, .{ .root_id = fixture.root_id });
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&fixture.runtime, job_handle));
    const stats = try fixture.runtime.jobScanStats(job_handle);
    try std.testing.expectEqual(@as(u64, 1), stats.errors);
    try std.testing.expectEqual(@as(u64, 1), stats.marked_missing);
    const kept = (try fixture.location("A/one.flac")).?;
    try std.testing.expectEqual(database.LocationState.present, kept.state);
    try std.testing.expectEqual(scanned.generation + 1, kept.generation);
    try std.testing.expectEqual(scanned.file_id, kept.file_id);
    try std.testing.expectEqual(database.LocationState.missing, (try fixture.location("B/two.mp3")).?.state);
    try std.testing.expectEqual(@as(i64, 2), try fixture.scanRunCount(.completed));
}

test "a scan whose root directory is gone fails its run and marks nothing missing" {
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-scan-root-gone?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.removeRootDirectory();

    const job_handle = try fixture.runtime.startLibraryScan(fixture.library, .{ .root_id = fixture.root_id });
    try std.testing.expectEqual(job.State.failed, try awaitJob(&fixture.runtime, job_handle));
    const stats = try fixture.runtime.jobScanStats(job_handle);
    try std.testing.expect(!stats.volume_changed);
    try std.testing.expectEqual(@as(u64, 0), stats.marked_missing);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("A/one.flac")).?.state);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("B/two.mp3")).?.state);
    try std.testing.expectEqual(@as(i64, 1), try fixture.scanRunCount(.failed));
    try std.testing.expectEqual(@as(i64, 0), try fixture.scanRunCount(.running));
}

test "a scan of a root recorded under its own volume key whose directory is gone fails and marks nothing missing" {
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-scan-own-key-root-gone?mode=memory&cache=shared");
    defer fixture.deinit();
    try recordRootOnOwnVolumeKey(&fixture.runtime, fixture.library, fixture.root_id);
    try fixture.removeRootDirectory();

    const job_handle = try fixture.runtime.startLibraryScan(fixture.library, .{ .root_id = fixture.root_id });
    try std.testing.expectEqual(job.State.failed, try awaitJob(&fixture.runtime, job_handle));
    const stats = try fixture.runtime.jobScanStats(job_handle);
    try std.testing.expectEqual(@as(u64, 0), stats.marked_missing);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("A/one.flac")).?.state);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("B/two.mp3")).?.state);
    try std.testing.expectEqual(@as(i64, if (stats.volume_changed) 0 else 1), try fixture.scanRunCount(.failed));
    try std.testing.expectEqual(@as(i64, 0), try fixture.scanRunCount(.running));
}

test "a scan cancelled once its run has begun marks nothing missing and leaves no run running" {
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-scan-cancel-run?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.temporary.dir.deleteFile(std.testing.io, "B/two.mp3");
    const write_lane = (try libraryDatabase(&fixture.runtime, fixture.library)).write_lane;

    write_lane.acquire();
    const job_handle = held: {
        errdefer write_lane.release();
        const handle = try fixture.runtime.startLibraryScan(fixture.library, .{ .root_id = fixture.root_id });
        while (write_lane.mutex.state.load(.acquire) != .contended) std.Thread.yield() catch {};
        try fixture.runtime.cancelJob(handle);
        break :held handle;
    };
    write_lane.release();

    try std.testing.expectEqual(job.State.cancelled, try awaitJob(&fixture.runtime, job_handle));
    try std.testing.expectEqual(@as(u64, 0), (try fixture.runtime.jobScanStats(job_handle)).marked_missing);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("B/two.mp3")).?.state);
    try std.testing.expectEqual(@as(i64, 1), try fixture.scanRunCount(.cancelled));
    try std.testing.expectEqual(@as(i64, 0), try fixture.scanRunCount(.running));
}

test "a walk in a second runtime is refused while the first walks the library's database file, and runs once it has finished" {
    var fixture: ReconcileFixture = undefined;
    try fixture.initFile();
    defer fixture.deinit();
    try fixture.temporary.dir.deleteFile(std.testing.io, "B/two.mp3");
    const database_path = try fixture.databasePath();
    defer std.testing.allocator.free(database_path);
    var second = OrcaRuntime.init(std.testing.allocator);
    defer second.deinit();
    const second_library = try second.openLibrary(std.testing.io, database_path);
    const runs_before = try fixture.scanRunTotal();
    const write_lane = (try libraryDatabase(&fixture.runtime, fixture.library)).write_lane;

    write_lane.acquire();
    const first_scan = held: {
        errdefer write_lane.release();
        const handle = try fixture.runtime.startLibraryScan(fixture.library, .{ .root_id = fixture.root_id });
        try std.testing.expectError(error.LibraryScanRunning, second.startLibraryScan(second_library, .{ .root_id = fixture.root_id }));
        try std.testing.expectError(error.LibraryScanRunning, second.startLibraryReconcile(second_library, .{
            .root_id = fixture.root_id,
            .scope = .{ .subtrees = &.{"B"} },
        }));
        try std.testing.expectEqual(runs_before, try fixture.scanRunTotal());
        try std.testing.expectEqual(database.LocationState.present, (try fixture.location("A/one.flac")).?.state);
        try std.testing.expectEqual(database.LocationState.present, (try fixture.location("B/two.mp3")).?.state);
        break :held handle;
    };
    write_lane.release();

    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&fixture.runtime, first_scan));
    try std.testing.expectEqual(runs_before + 1, try fixture.scanRunTotal());
    try std.testing.expectEqual(database.LocationState.missing, (try fixture.location("B/two.mp3")).?.state);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&second, try second.startLibraryScan(second_library, .{ .root_id = fixture.root_id })));
    try std.testing.expectEqual(runs_before + 2, try fixture.scanRunTotal());
    try std.testing.expectEqual(@as(i64, 0), try fixture.scanRunCount(.running));
    try std.testing.expectEqual(job.State.succeeded, (try fixture.reconcile(&.{"A"})).state);
}

test "a scan or reconcile fails the run a crashed walker left running and then completes its own" {
    var fixture: ReconcileFixture = undefined;
    try fixture.initFile();
    defer fixture.deinit();
    const library_database = try libraryDatabase(&fixture.runtime, fixture.library);
    try fixture.temporary.dir.deleteFile(std.testing.io, "B/two.mp3");

    _ = try library_database.scan_runs.begin(fixture.root_id);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&fixture.runtime, try fixture.runtime.startLibraryScan(fixture.library, .{ .root_id = fixture.root_id })));
    try std.testing.expectEqual(@as(i64, 1), try fixture.scanRunCount(.failed));
    try std.testing.expectEqual(@as(i64, 0), try fixture.scanRunCount(.running));
    try std.testing.expectEqual(database.LocationState.missing, (try fixture.location("B/two.mp3")).?.state);

    _ = try library_database.scan_runs.begin(fixture.root_id);
    try fixture.temporary.dir.deleteFile(std.testing.io, "A/one.flac");
    try std.testing.expectEqual(job.State.succeeded, (try fixture.reconcile(&.{"A"})).state);
    try std.testing.expectEqual(@as(i64, 2), try fixture.scanRunCount(.failed));
    try std.testing.expectEqual(@as(i64, 0), try fixture.scanRunCount(.running));
    try std.testing.expectEqual(database.LocationState.missing, (try fixture.location("A/one.flac")).?.state);
}

test "a walk that fails because its root is gone releases the walk lock" {
    var fixture: ReconcileFixture = undefined;
    try fixture.initFile();
    defer fixture.deinit();
    try fixture.removeRootDirectory();

    try std.testing.expectEqual(job.State.failed, try awaitJob(&fixture.runtime, try fixture.runtime.startLibraryScan(fixture.library, .{ .root_id = fixture.root_id })));
    try fixture.expectWalkLockFree();
    try std.testing.expectEqual(job.State.failed, (try fixture.reconcile(&.{"A"})).state);
    try fixture.expectWalkLockFree();
}

test "a cancelled walk releases the walk lock" {
    var fixture: ReconcileFixture = undefined;
    try fixture.initFile();
    defer fixture.deinit();
    const write_lane = (try libraryDatabase(&fixture.runtime, fixture.library)).write_lane;

    write_lane.acquire();
    const job_handle = held: {
        errdefer write_lane.release();
        const handle = try fixture.runtime.startLibraryScan(fixture.library, .{ .root_id = fixture.root_id });
        try std.testing.expect(try library_pass.WalkLock.tryAcquire(std.testing.io, try fixture.walkLockPath()) == null);
        while (write_lane.mutex.state.load(.acquire) != .contended) std.Thread.yield() catch {};
        try fixture.runtime.cancelJob(handle);
        break :held handle;
    };
    write_lane.release();

    try std.testing.expectEqual(job.State.cancelled, try awaitJob(&fixture.runtime, job_handle));
    try fixture.expectWalkLockFree();
}

test "a root relocated while another process walks the library is refused and commits nothing" {
    var fixture: ReconcileFixture = undefined;
    try fixture.initFile();
    defer fixture.deinit();
    var elsewhere = std.testing.tmpDir(.{});
    defer elsewhere.cleanup();
    const moved = try absoluteTestPath(".zig-cache/tmp/{s}", .{elsewhere.sub_path});
    defer std.testing.allocator.free(moved);
    const jobs_before = fixture.runtime.jobs.jobs.count();

    {
        var foreign = (try library_pass.WalkLock.tryAcquire(std.testing.io, try fixture.walkLockPath())).?;
        defer foreign.release(std.testing.io);
        try std.testing.expectError(
            error.LibraryScanRunning,
            fixture.runtime.libraryRelocateRoot(fixture.library, std.testing.io, fixture.root_id, moved),
        );
    }
    try std.testing.expectEqual(jobs_before, fixture.runtime.jobs.jobs.count());
    {
        var roots = try fixture.runtime.libraryRootPage(fixture.library, 8, 0);
        defer roots.deinit();
        try std.testing.expectEqualStrings(fixture.root, roots.items[0].path);
    }
    try fixture.expectWalkLockFree();

    const relocation = try fixture.runtime.libraryRelocateRoot(fixture.library, std.testing.io, fixture.root_id, moved);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&fixture.runtime, relocation));
    {
        var roots = try fixture.runtime.libraryRootPage(fixture.library, 8, 0);
        defer roots.deinit();
        try std.testing.expectEqualStrings(moved, roots.items[0].path);
    }
    try fixture.expectWalkLockFree();
}

test "a root relocated while the library's jobs are paused frees the walk lock until its reconcile starts" {
    var fixture: ReconcileFixture = undefined;
    try fixture.initFile();
    defer fixture.deinit();
    var elsewhere = std.testing.tmpDir(.{});
    defer elsewhere.cleanup();
    const moved = try absoluteTestPath(".zig-cache/tmp/{s}", .{elsewhere.sub_path});
    defer std.testing.allocator.free(moved);

    try fixture.runtime.pauseAll(fixture.library);
    const relocation = try fixture.runtime.libraryRelocateRoot(fixture.library, std.testing.io, fixture.root_id, moved);
    try std.testing.expectEqual(job.State.waiting, (try fixture.runtime.jobSnapshotSynced(relocation)).state);
    try fixture.expectWalkLockFree();
    try std.testing.expectEqual(@as(u64, 0), try fixture.runtime.libraryMissingFileCount(fixture.library));

    try fixture.runtime.resumeAll(fixture.library);
    fixture.runtime.pump();
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&fixture.runtime, relocation));
    try std.testing.expectEqual(@as(u64, 2), try fixture.runtime.libraryMissingFileCount(fixture.library));
    try fixture.expectWalkLockFree();
}

test "a second scan or reconcile of a library waits for the one that runs and then runs in turn" {
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
    for ([_]JobHandle{ try second_scan, try reconcile }) |waiting| {
        try std.testing.expectEqual(job.State.waiting, (try fixture.runtime.jobSnapshotSynced(waiting)).state);
    }
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&fixture.runtime, running));
    try std.testing.expectEqual(job.State.waiting, (try fixture.runtime.jobSnapshotSynced(try reconcile)).state);
    try std.testing.expectEqual(job.State.succeeded, try awaitJobPumping(&fixture.runtime, try second_scan));
    try std.testing.expectEqual(job.State.succeeded, try awaitJobPumping(&fixture.runtime, try reconcile));
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

/// Binds the root's recorded volume to a key the platform resolves for no
/// path, which is how an unmounted drive's mount point looks to a walk.
pub fn recordRootOnAnotherVolume(runtime: *OrcaRuntime, library: LibraryHandle, root_id: i64) !void {
    const library_database = try libraryDatabase(runtime, library);
    var statement = try library_database.database.prepare(
        "UPDATE volumes SET stable_key='uuid:orca-test-elsewhere' WHERE id=(SELECT volume_id FROM library_roots WHERE id=?1);",
    );
    defer statement.deinit();
    try statement.bindInt64(1, root_id);
    if (try statement.step() != .done) return error.SqlFailed;
}

fn recordRootOnOwnVolumeKey(runtime: *OrcaRuntime, library: LibraryHandle, root_id: i64) !void {
    const library_database = try libraryDatabase(runtime, library);
    var statement = try library_database.database.prepare(
        "UPDATE volumes SET stable_key=?2 || ?1 WHERE id=(SELECT volume_id FROM library_roots WHERE id=?1);",
    );
    defer statement.deinit();
    try statement.bindInt64(1, root_id);
    try statement.bindText(2, database.LibraryDatabase.root_volume_key_prefix);
    if (try statement.step() != .done) return error.SqlFailed;
}

test "a scan of a root no longer on its recorded volume fails and marks nothing missing" {
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-scan-other-volume?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.temporary.dir.deleteFile(std.testing.io, "A/one.flac");
    try recordRootOnAnotherVolume(&fixture.runtime, fixture.library, fixture.root_id);

    const job_handle = try fixture.runtime.startLibraryScan(fixture.library, .{});
    try std.testing.expectEqual(job.State.failed, try awaitJob(&fixture.runtime, job_handle));
    const stats = try fixture.runtime.jobScanStats(job_handle);
    try std.testing.expectEqual(@as(u64, 1), stats.errors);
    try std.testing.expectEqual(@as(u64, 0), stats.files_seen);
    try std.testing.expectEqual(@as(u64, 0), stats.marked_missing);
    try std.testing.expect(stats.volume_changed);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("A/one.flac")).?.state);
    try std.testing.expectEqual(@as(i64, 0), try fixture.scanRunCount(.running));
}

test "a subtree reconcile of a root no longer on its recorded volume fails and marks nothing missing" {
    var fixture: ReconcileFixture = undefined;
    try fixture.init("file:orca-reconcile-other-volume?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.temporary.dir.deleteTree(std.testing.io, "A");
    try recordRootOnAnotherVolume(&fixture.runtime, fixture.library, fixture.root_id);

    const outcome = try fixture.reconcile(&.{"A"});
    try std.testing.expectEqual(job.State.failed, outcome.state);
    try std.testing.expectEqual(@as(u64, 1), outcome.stats.errors);
    try std.testing.expectEqual(@as(u64, 0), outcome.stats.marked_missing);
    try std.testing.expect(outcome.stats.volume_changed);
    try std.testing.expectEqual(database.LocationState.present, (try fixture.location("A/one.flac")).?.state);
    try std.testing.expectEqual(@as(i64, 0), try fixture.scanRunCount(.running));
}

test "a rating and a playlist entry follow a track that a library edit moves to another album" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-runtime-playlist-edit?mode=memory&cache=shared");
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
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 1,
    } });
    var projection: library_pass.Projection = .{ .allocator = std.testing.allocator, .library = library_database };
    _ = try projection.run(.{ .files = &.{file_id} });
    var before = try runtime.libraryTrackQuery(library, "", .{ .limit = 4 });
    const track_id = before.items[0].id;
    before.deinit();

    const rated = try runtime.librarySetRating(library, &.{track_id}, 60);
    try std.testing.expectEqual(@as(u32, 1), rated.updated);
    const playlist = try runtime.libraryCreatePlaylist(library, "Mix");
    _ = try runtime.libraryPlaylistInsert(library, playlist, &.{track_id}, null);

    const moved = try runtime.libraryEditTracks(library, &.{track_id}, &.{.{ .field = .album, .value = "Other Album" }});
    defer moved.deinit();
    try std.testing.expectEqual(@as(usize, 1), moved.ids.len);
    try std.testing.expectEqual(track_id, moved.ids[0]);

    const details = (try runtime.libraryTrackDetails(library, moved.ids[0])).?;
    defer details.deinit();
    try std.testing.expectEqual(@as(?u8, 60), details.rating);
    var entries = try runtime.libraryPlaylistEntries(library, playlist, 10, 0);
    defer entries.deinit();
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqual(moved.ids[0], entries.items[0].track.?.id);
    try std.testing.expectEqualStrings("Other Album", entries.items[0].track.?.album);
}

test "playing a playlist queues its available entries, and one with none is refused with the queue untouched" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());
    const fixtures = try openFixtureLibrary(
        &runtime,
        "file:orca-playlist-play?mode=memory&cache=shared",
        &.{
            "fixtures/audio/generated-reference.wav",
            "fixtures/audio/generated-reference.flac",
            "fixtures/audio/generated-reference.qoa",
        },
    );
    const library_database = try libraryDatabase(&runtime, fixtures.library);
    try library_database.database.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'One'), (2, 'Two'), (3, 'Three');
        \\UPDATE tracks SET recording_id = id - (SELECT min(id) FROM tracks) + 1;
    );
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneRequestOutput(zone, 0);

    const empty = try runtime.libraryCreatePlaylist(fixtures.library, "Empty");
    try std.testing.expectError(error.PlaylistEmpty, runtime.playerPlayPlaylist(player, fixtures.library, std.testing.io, empty, 0));
    _ = try runtime.libraryPlaylistInsert(fixtures.library, empty, &.{fixtures.ids[2]}, null);
    try library_database.database.exec("DELETE FROM tracks WHERE recording_id = 3;");
    try std.testing.expectError(error.PlaylistEmpty, runtime.playerPlayPlaylist(player, fixtures.library, std.testing.io, empty, 0));
    try std.testing.expectEqual(@as(u32, 0), (try runtime.playerQueueSnapshot(player)).entries);

    const playlist = try runtime.libraryCreatePlaylist(fixtures.library, "Mix");
    _ = try runtime.libraryPlaylistInsert(fixtures.library, playlist, &.{ fixtures.ids[1], fixtures.ids[0] }, null);
    try runtime.libraryPlaylistMove(fixtures.library, playlist, 1, 0);
    _ = try runtime.libraryPlaylistInsert(fixtures.library, playlist, &.{ fixtures.ids[1], fixtures.ids[0] }, 1);
    _ = try runtime.libraryPlaylistRemove(fixtures.library, playlist, &.{ 1, 2 });
    try runtime.playerPlayPlaylist(player, fixtures.library, std.testing.io, playlist, 0);

    try std.testing.expectEqual(@as(u32, 2), (try runtime.playerQueueSnapshot(player)).entries);
    const now_playing = (try runtime.playerNowPlaying(player)).?;
    try std.testing.expectEqual(fixtures.ids[0], now_playing.track_id);
}

const PlaylistFileFixture = struct {
    runtime: OrcaRuntime,
    library: LibraryHandle,
    directory: std.testing.TmpDir,
    root: []u8,

    fn init(self: *PlaylistFileFixture, uri: [:0]const u8) !void {
        self.runtime = OrcaRuntime.init(std.testing.allocator);
        errdefer self.runtime.deinit();
        self.library = try self.runtime.openLibrary(std.testing.io, uri);
        self.directory = std.testing.tmpDir(.{ .iterate = true });
        errdefer self.directory.cleanup();
        const current = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
        defer std.testing.allocator.free(current);
        self.root = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ current, self.directory.sub_path });
    }

    fn deinit(self: *PlaylistFileFixture) void {
        std.testing.allocator.free(self.root);
        self.directory.cleanup();
        self.runtime.deinit();
    }

    fn path(self: *const PlaylistFileFixture, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ self.root, name });
    }

    fn addTrack(self: *PlaylistFileFixture, name: []const u8, title: []const u8, album: []const u8, number: u32, duration_ms: i64) !i64 {
        const library_database = try libraryDatabase(&self.runtime, self.library);
        const uri = try self.path(name);
        defer std.testing.allocator.free(uri);
        const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024, .duration_ms = duration_ms });
        _ = try library_database.locations.upsert(.{
            .file_id = file_id,
            .volume_id = database.LibraryDatabase.null_volume,
            .uri = uri,
            .state = .present,
        });
        try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = .{
            .title = title,
            .artist = "Artist",
            .album = album,
            .album_artist = "Artist",
            .track_number = number,
        } });
        var projection: library_pass.Projection = .{ .allocator = std.testing.allocator, .library = library_database };
        _ = try projection.run(.{ .files = &.{file_id} });
        var statement = try library_database.database.prepare(
            "SELECT tracks.id FROM tracks JOIN files ON files.recording_id = tracks.recording_id WHERE files.id = ?1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try std.testing.expect(try statement.step() == .row);
        return statement.columnInt64(0);
    }

    fn writePlaylist(self: *PlaylistFileFixture, name: []const u8, contents: []const u8) !void {
        try self.directory.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = contents });
    }

    fn entryTrackIds(self: *PlaylistFileFixture, playlist_id: i64) ![]?i64 {
        var page = try self.runtime.libraryPlaylistEntries(self.library, playlist_id, 512, 0);
        defer page.deinit();
        const ids = try std.testing.allocator.alloc(?i64, page.items.len);
        for (ids, page.items) |*id, entry| id.* = if (entry.track) |track| track.id else null;
        return ids;
    }

    fn playlistCount(self: *PlaylistFileFixture) !usize {
        var page = try self.runtime.libraryPlaylists(self.library, 512, 0);
        defer page.deinit();
        return page.items.len;
    }
};

test "an exported playlist imports back to the same tracks in the same order, with absolute or relative paths" {
    var fixture: PlaylistFileFixture = undefined;
    try fixture.init("file:orca-playlist-round-trip?mode=memory&cache=shared");
    defer fixture.deinit();
    const one = try fixture.addTrack("Music/A/01.flac", "One", "Album", 1, 200_000);
    const two = try fixture.addTrack("Music/A/02.flac", "Two", "Album", 2, 180_400);
    const three = try fixture.addTrack("Music/B/01.flac", "Three", "Other", 1, 61_600);
    const playlist = try fixture.runtime.libraryCreatePlaylist(fixture.library, "Mix");
    _ = try fixture.runtime.libraryPlaylistInsert(fixture.library, playlist, &.{ three, one, two, one }, null);
    try fixture.directory.dir.createDirPath(std.testing.io, "lists");

    for ([_]runtime_module.PlaylistPathStyle{ .absolute, .relative }) |style| {
        const target = try fixture.path(if (style == .absolute) "lists/absolute.m3u8" else "lists/relative.m3u8");
        defer std.testing.allocator.free(target);
        const exported = try fixture.runtime.libraryExportPlaylist(fixture.library, std.testing.io, playlist, target, .{
            .paths = style,
            .replace = false,
        });
        try std.testing.expectEqual(@as(u32, 4), exported.written);
        try std.testing.expectEqual(@as(u32, 0), exported.skipped);

        const imported = try fixture.runtime.libraryImportPlaylist(fixture.library, std.testing.io, target, null);
        defer imported.deinit();
        try std.testing.expectEqual(@as(u32, 4), imported.matched_by_path);
        try std.testing.expectEqual(@as(u32, 0), imported.unmatched);
        const ids = try fixture.entryTrackIds(imported.playlist_id);
        defer std.testing.allocator.free(ids);
        try std.testing.expectEqualSlices(?i64, &.{ three, one, two, one }, ids);
    }

    const relative = try fixture.directory.dir.readFileAlloc(std.testing.io, "lists/relative.m3u8", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(relative);
    try std.testing.expectEqualStrings(
        "#EXTM3U\n#EXTINF:62,Artist - Three\n../Music/B/01.flac\n#EXTINF:200,Artist - One\n../Music/A/01.flac\n" ++
            "#EXTINF:180,Artist - Two\n../Music/A/02.flac\n#EXTINF:200,Artist - One\n../Music/A/01.flac\n",
        relative,
    );
    var page = try fixture.runtime.libraryPlaylists(fixture.library, 512, 0);
    defer page.deinit();
    try std.testing.expectEqualStrings("absolute", page.items[0].name);
    try std.testing.expectEqualStrings("relative", page.items[2].name);
}

test "import resolves relative entries against the playlist's folder and percent-decodes file URIs" {
    var fixture: PlaylistFileFixture = undefined;
    try fixture.init("file:orca-playlist-resolve?mode=memory&cache=shared");
    defer fixture.deinit();
    const one = try fixture.addTrack("Music/Björk/01 Joga.flac", "Jóga", "Homogenic", 1, 305_000);
    const two = try fixture.addTrack("Music/Björk/02.flac", "Unravel", "Homogenic", 2, 201_000);
    const uri = try std.fmt.allocPrint(std.testing.allocator, "#EXTM3U\n../Music/./Björk//01 Joga.flac\nfile://{s}/Music/Bj%C3%B6rk/02.flac\nhttp://example.com/a.mp3\nfile://host{s}/Music/Bj%C3%B6rk/02.flac\n", .{ fixture.root, fixture.root });
    defer std.testing.allocator.free(uri);
    try fixture.directory.dir.createDirPath(std.testing.io, "lists");
    try fixture.writePlaylist("lists/mix.m3u8", uri);
    const target = try fixture.path("lists/mix.m3u8");
    defer std.testing.allocator.free(target);

    const imported = try fixture.runtime.libraryImportPlaylist(fixture.library, std.testing.io, target, "Björk");
    defer imported.deinit();
    try std.testing.expectEqual(@as(u32, 2), imported.matched_by_path);
    try std.testing.expectEqual(@as(u32, 2), imported.unmatched);
    try std.testing.expectEqualStrings("http://example.com/a.mp3", imported.unmatched_lines[0]);
    try std.testing.expect(std.mem.startsWith(u8, imported.unmatched_lines[1], "file://host/"));
    const ids = try fixture.entryTrackIds(imported.playlist_id);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(?i64, &.{ one, two }, ids);

    const again = try fixture.runtime.libraryImportPlaylist(fixture.library, std.testing.io, target, "Björk");
    defer again.deinit();
    var page = try fixture.runtime.libraryPlaylists(fixture.library, 512, 0);
    defer page.deinit();
    try std.testing.expectEqualStrings("Björk (2)", page.items[1].name);
}

test "an #EXTINF line matches only when exactly one recording has that artist, title and length" {
    var fixture: PlaylistFileFixture = undefined;
    try fixture.init("file:orca-playlist-extinf?mode=memory&cache=shared");
    defer fixture.deinit();
    const unique = try fixture.addTrack("Music/A/01.flac", "Unique Song", "Album", 1, 200_000);
    _ = try fixture.addTrack("Music/A/02.flac", "Twice", "Album", 2, 150_000);
    _ = try fixture.addTrack("Music/B/02.flac", "Twice", "Other", 2, 151_000);
    try fixture.writePlaylist("info.m3u", "#EXTM3U\n" ++
        "#EXTINF:202,ARTIST  -  unique   song\n/gone/one.flac\n" ++
        "#EXTINF:150,Artist - Twice\n/gone/two.flac\n" ++
        "#EXTINF:203,Artist - Unique Song\n/gone/late.flac\n" ++
        "#EXTINF:-1,Artist - Unique Song\n/gone/unknown.flac\n" ++
        "#EXTINF:200,Unique Song\n/gone/no-separator.flac\n");
    const target = try fixture.path("info.m3u");
    defer std.testing.allocator.free(target);

    const imported = try fixture.runtime.libraryImportPlaylist(fixture.library, std.testing.io, target, null);
    defer imported.deinit();
    try std.testing.expectEqual(@as(u32, 0), imported.matched_by_path);
    try std.testing.expectEqual(@as(u32, 2), imported.matched_by_info);
    try std.testing.expectEqual(@as(u32, 3), imported.unmatched);
    try std.testing.expectEqualStrings("/gone/two.flac", imported.unmatched_lines[0]);
    try std.testing.expectEqualStrings("/gone/late.flac", imported.unmatched_lines[1]);
    try std.testing.expectEqualStrings("/gone/no-separator.flac", imported.unmatched_lines[2]);
    const ids = try fixture.entryTrackIds(imported.playlist_id);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(?i64, &.{ unique, unique }, ids);
}

test "importing an empty or oversized playlist file is refused and creates no playlist" {
    var fixture: PlaylistFileFixture = undefined;
    try fixture.init("file:orca-playlist-limits?mode=memory&cache=shared");
    defer fixture.deinit();
    try fixture.writePlaylist("empty.m3u8", "#EXTM3U\n#EXTINF:5,A - B\n\n");
    const empty = try fixture.path("empty.m3u8");
    defer std.testing.allocator.free(empty);
    try std.testing.expectError(error.PlaylistEmpty, fixture.runtime.libraryImportPlaylist(fixture.library, std.testing.io, empty, null));

    const big = try std.testing.allocator.alloc(u8, 5 * 1024 * 1024);
    defer std.testing.allocator.free(big);
    @memset(big, '#');
    try fixture.writePlaylist("big.m3u8", big);
    const big_path = try fixture.path("big.m3u8");
    defer std.testing.allocator.free(big_path);
    try std.testing.expectError(error.PlaylistTooLarge, fixture.runtime.libraryImportPlaylist(fixture.library, std.testing.io, big_path, null));

    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(std.testing.allocator);
    for (0..database.repository.max_playlist_entries + 1) |_| try many.appendSlice(std.testing.allocator, "/x.flac\n");
    try fixture.writePlaylist("many.m3u8", many.items);
    const many_path = try fixture.path("many.m3u8");
    defer std.testing.allocator.free(many_path);
    try std.testing.expectError(error.PlaylistTooLarge, fixture.runtime.libraryImportPlaylist(fixture.library, std.testing.io, many_path, null));

    try std.testing.expectEqual(@as(usize, 0), try fixture.playlistCount());
}

test "exporting over an existing file without replace fails and leaves it unchanged" {
    var fixture: PlaylistFileFixture = undefined;
    try fixture.init("file:orca-playlist-no-replace?mode=memory&cache=shared");
    defer fixture.deinit();
    const track = try fixture.addTrack("Music/A/01.flac", "One", "Album", 1, 1_000);
    const playlist = try fixture.runtime.libraryCreatePlaylist(fixture.library, "Mix");
    _ = try fixture.runtime.libraryPlaylistInsert(fixture.library, playlist, &.{track}, null);
    try fixture.writePlaylist("mix.m3u8", "keep me\n");
    const target = try fixture.path("mix.m3u8");
    defer std.testing.allocator.free(target);

    try std.testing.expectError(error.PathAlreadyExists, fixture.runtime.libraryExportPlaylist(
        fixture.library,
        std.testing.io,
        playlist,
        target,
        .{ .paths = .absolute, .replace = false },
    ));
    const kept = try fixture.directory.dir.readFileAlloc(std.testing.io, "mix.m3u8", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("keep me\n", kept);

    const replaced = try fixture.runtime.libraryExportPlaylist(fixture.library, std.testing.io, playlist, target, .{
        .paths = .absolute,
        .replace = true,
    });
    try std.testing.expectEqual(@as(u32, 1), replaced.written);
    const written = try fixture.directory.dir.readFileAlloc(std.testing.io, "mix.m3u8", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.startsWith(u8, written, "#EXTM3U\n#EXTINF:1,Artist - One\n/"));
}

test "an export whose rename fails leaves no temporary file, and unavailable entries are skipped" {
    var fixture: PlaylistFileFixture = undefined;
    try fixture.init("file:orca-playlist-failed-rename?mode=memory&cache=shared");
    defer fixture.deinit();
    const track = try fixture.addTrack("Music/A/01.flac", "One", "Album", 1, 1_000);
    const gone = try fixture.addTrack("Music/A/02.flac", "Two", "Album", 2, 1_000);
    const playlist = try fixture.runtime.libraryCreatePlaylist(fixture.library, "Mix");
    _ = try fixture.runtime.libraryPlaylistInsert(fixture.library, playlist, &.{ track, gone }, null);
    const library_database = try libraryDatabase(&fixture.runtime, fixture.library);
    var remove = try library_database.database.prepare("DELETE FROM tracks WHERE id = ?1;");
    defer remove.deinit();
    try remove.bindInt64(1, gone);
    _ = try remove.step();
    try fixture.directory.dir.createDirPath(std.testing.io, "taken.m3u8/inside");
    const target = try fixture.path("taken.m3u8");
    defer std.testing.allocator.free(target);

    if (fixture.runtime.libraryExportPlaylist(fixture.library, std.testing.io, playlist, target, .{
        .paths = .absolute,
        .replace = true,
    })) |_| return error.TestUnexpectedResult else |_| {}
    var listing = fixture.directory.dir.iterate();
    var names: usize = 0;
    while (try listing.next(std.testing.io)) |entry| {
        names += 1;
        try std.testing.expectEqualStrings("taken.m3u8", entry.name);
    }
    try std.testing.expectEqual(@as(usize, 1), names);

    const exported = try fixture.path("ok.m3u8");
    defer std.testing.allocator.free(exported);
    const result = try fixture.runtime.libraryExportPlaylist(fixture.library, std.testing.io, playlist, exported, .{
        .paths = .absolute,
        .replace = false,
    });
    try std.testing.expectEqual(@as(u32, 1), result.written);
    try std.testing.expectEqual(@as(u32, 1), result.skipped);
}

test "#EXTINF lines without a length match only a unique recording when several are imported together" {
    var fixture: PlaylistFileFixture = undefined;
    try fixture.init("file:orca-playlist-extinf-unknown?mode=memory&cache=shared");
    defer fixture.deinit();
    const unique = try fixture.addTrack("Music/A/01.flac", "Unique Song", "Album", 1, 200_000);
    _ = try fixture.addTrack("Music/A/02.flac", "Twice", "Album", 2, 150_000);
    _ = try fixture.addTrack("Music/B/02.flac", "Twice", "Other", 2, 90_000);
    const shared = try fixture.addTrack("Music/A/03.flac", "Shared", "Album", 3, 100_000);
    const copy = try fixture.addTrack("Music/C/03.flac", "Shared", "Third", 3, 100_000);
    const library_database = try libraryDatabase(&fixture.runtime, fixture.library);
    var share = try library_database.database.prepare(
        "UPDATE tracks SET recording_id = (SELECT recording_id FROM tracks WHERE id = ?1) WHERE id = ?2;",
    );
    defer share.deinit();
    try share.bindInt64(1, shared);
    try share.bindInt64(2, copy);
    _ = try share.step();
    try fixture.writePlaylist("unknown.m3u", "#EXTM3U\n" ++
        "#EXTINF:-1,artist - UNIQUE SONG\n/gone/one.flac\n" ++
        "#EXTINF:-1,Artist - Twice\n/gone/two.flac\n" ++
        "#EXTINF:-1,Artist - Shared\n/gone/shared.flac\n" ++
        "#EXTINF:-1,Artist - Missing\n/gone/missing.flac\n" ++
        "#EXTINF:-1,Artist - Unique Song\n/gone/again.flac\n");
    const target = try fixture.path("unknown.m3u");
    defer std.testing.allocator.free(target);

    const imported = try fixture.runtime.libraryImportPlaylist(fixture.library, std.testing.io, target, null);
    defer imported.deinit();
    try std.testing.expectEqual(@as(u32, 3), imported.matched_by_info);
    try std.testing.expectEqual(@as(u32, 2), imported.unmatched);
    try std.testing.expectEqualStrings("/gone/two.flac", imported.unmatched_lines[0]);
    try std.testing.expectEqualStrings("/gone/missing.flac", imported.unmatched_lines[1]);
    const ids = try fixture.entryTrackIds(imported.playlist_id);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(?i64, &.{ unique, @min(shared, copy), unique }, ids);
}

fn randomPageIds(fixture: *PlaylistFileFixture, playlist_id: i64, ids: *std.ArrayList(i64)) !void {
    var offset: u32 = 0;
    while (true) : (offset += 12) {
        var page = try fixture.runtime.libraryPlaylistEntries(fixture.library, playlist_id, 12, offset);
        defer page.deinit();
        if (page.items.len == 0) return;
        for (page.items) |entry| try ids.append(std.testing.allocator, entry.track.?.id);
    }
}

test "a random smart playlist's pages read through the runtime are disjoint and together hold every Track, before and after a reshuffle" {
    var fixture: PlaylistFileFixture = undefined;
    try fixture.init("file:orca-playlist-random-pages?mode=memory&cache=shared");
    defer fixture.deinit();
    fixture.runtime.playlist_shuffle_seed = 0x5eed;
    var expected: [30]i64 = undefined;
    var name_buffer: [32]u8 = undefined;
    for (&expected, 0..) |*id, index| {
        const name = try std.fmt.bufPrint(&name_buffer, "Music/{d:0>2}.flac", .{index});
        id.* = try fixture.addTrack(name, name, "Album", @intCast(index + 1), 200_000);
    }
    const playlist = try fixture.runtime.libraryCreateSmartPlaylist(
        fixture.library,
        "Shuffle",
        "{\"v\":1,\"rules\":[],\"sort\":{\"field\":\"random\"}}",
    );

    var first: std.ArrayList(i64) = .empty;
    defer first.deinit(std.testing.allocator);
    try randomPageIds(&fixture, playlist, &first);
    var again: std.ArrayList(i64) = .empty;
    defer again.deinit(std.testing.allocator);
    try randomPageIds(&fixture, playlist, &again);
    try std.testing.expectEqualSlices(i64, first.items, again.items);
    try std.testing.expect(!std.mem.eql(i64, &expected, first.items));

    fixture.runtime.libraryReshufflePlaylists();
    var reshuffled: std.ArrayList(i64) = .empty;
    defer reshuffled.deinit(std.testing.allocator);
    try randomPageIds(&fixture, playlist, &reshuffled);

    for ([_][]i64{ first.items, reshuffled.items }) |ids| {
        std.mem.sort(i64, ids, {}, std.sort.asc(i64));
        try std.testing.expectEqualSlices(i64, &expected, ids);
    }
}

test "the thirty-third waiting Job is refused with JobQueueFull until a cancelled one leaves the queue" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-job-queue-full?mode=memory&cache=shared");
    try runtime.pauseAll(library);
    var waiting: [runtime_module.max_waiting_jobs]JobHandle = undefined;
    for (&waiting) |*job_handle| {
        job_handle.* = try runtime.startLibraryProjection(library);
        const snapshot = try runtime.jobSnapshotSynced(job_handle.*);
        try std.testing.expectEqual(job.State.waiting, snapshot.state);
        try std.testing.expect(snapshot.paused);
    }
    try std.testing.expectError(error.JobQueueFull, runtime.startLibraryProjection(library));
    try std.testing.expectEqual(@as(usize, 0), runtime.job_workers.items.len);

    const queue = try runtime.jobQueuePage(library, std.testing.allocator);
    defer std.testing.allocator.free(queue);
    try std.testing.expectEqual(waiting.len, queue.len);
    try std.testing.expect(queue[0].after == null);
    for (queue, waiting, 0..) |entry, job_handle, index| {
        try std.testing.expect(entry.job.eql(job_handle));
        try std.testing.expectEqual(job.Kind.projection, entry.kind);
        if (index != 0) try std.testing.expect(entry.after.?.eql(waiting[index - 1]));
    }

    try runtime.cancelJob(waiting[0]);
    try std.testing.expectError(error.JobQueueFull, runtime.startLibraryProjection(library));
    runtime.pump();
    try std.testing.expectEqual(job.State.cancelled, (try runtime.jobSnapshotSynced(waiting[0])).state);
    _ = try runtime.startLibraryProjection(library);
    try std.testing.expectError(error.JobQueueFull, runtime.startLibraryProjection(library));
}

test "Jobs pauseAll holds wait for resumeAll, and a Library's history keeps every finished Job and retries a cancelled one" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-job-history?mode=memory&cache=shared");
    const binding = try addFixturesRoot(&runtime, library);
    const scan = try runtime.startLibraryScan(library, .{ .root_id = binding.root_id });
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, scan));

    try runtime.pauseAll(library);
    try std.testing.expect(try runtime.libraryJobsPaused(library));
    const held = try runtime.startLibraryProjection(library);
    const dropped = try runtime.startLibraryProjection(library);
    try runtime.cancelJob(dropped);
    runtime.pump();
    try std.testing.expectEqual(job.State.cancelled, (try runtime.jobSnapshotSynced(dropped)).state);
    try std.testing.expectEqual(job.State.waiting, (try runtime.jobSnapshotSynced(held)).state);
    try std.testing.expectEqual(@as(usize, 0), inFlightWorkCount(&runtime));

    try runtime.resumeAll(library);
    try std.testing.expect(!try runtime.libraryJobsPaused(library));
    try std.testing.expect(!(try runtime.jobSnapshotSynced(held)).paused);
    runtime.pump();
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, held));

    const problems = try runtime.jobHistoryPage(library, std.testing.allocator, .problems, 10, 0);
    defer std.testing.allocator.free(problems);
    try std.testing.expectEqual(@as(usize, 1), problems.len);
    try std.testing.expectEqual(job.Kind.projection, problems[0].kind);
    try std.testing.expectEqual(job.State.cancelled, problems[0].state);
    try std.testing.expectEqualStrings("cancelled", problems[0].error_text.slice());
    try std.testing.expect(problems[0].retryable);

    const retried = try runtime.jobRetry(library, problems[0].id);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, retried));

    const history = try runtime.jobHistoryPage(library, std.testing.allocator, .all, 10, 0);
    defer std.testing.allocator.free(history);
    const kinds = [_]job.Kind{ .projection, .projection, .projection, .scan };
    const states = [_]job.State{ .succeeded, .succeeded, .cancelled, .succeeded };
    try std.testing.expectEqual(kinds.len, history.len);
    for (history, kinds, states) |entry, kind, state| {
        try std.testing.expectEqual(kind, entry.kind);
        try std.testing.expectEqual(state, entry.state);
        try std.testing.expect(entry.started_at <= entry.finished_at);
    }
    try std.testing.expectEqual(problems[0].id, history[2].id);
    try std.testing.expect(!history[3].retryable);
    try std.testing.expect(history[3].summary.slice().len != 0);
    try std.testing.expectError(error.JobNotRetryable, runtime.jobRetry(library, history[3].id));
    try std.testing.expectError(error.UnknownJobHistory, runtime.jobRetry(library, history[0].id + 1));
}

pub fn absoluteTestPath(comptime format: []const u8, args: anytype) ![]u8 {
    const relative = try std.fmt.allocPrint(std.testing.allocator, format, args);
    defer std.testing.allocator.free(relative);
    const current = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(current);
    return std.fs.path.resolve(std.testing.allocator, &.{ current, relative });
}

pub fn addFixturesRoot(runtime: *OrcaRuntime, library: LibraryHandle) !database.RootBinding {
    const root = try absoluteTestPath("fixtures/audio", .{});
    defer std.testing.allocator.free(root);
    return runtime.libraryAddRoot(library, std.testing.io, root);
}
