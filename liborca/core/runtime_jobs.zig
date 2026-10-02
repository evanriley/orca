const std = @import("std");
const analysis_service = @import("../analysis/service.zig");
const database = @import("../database/root.zig");
const job = @import("job.zig");
const work = @import("work.zig");
const job_worker = @import("job_worker.zig");
const runtime = @import("runtime.zig");
const runtime_listens = @import("runtime_listens.zig");
const runtime_maintenance = @import("runtime_maintenance.zig");
const runtime_watch = @import("runtime_watch.zig");

const AcoustIdSubmittablePage = runtime.AcoustIdSubmittablePage;
const AnalysisRequest = runtime.AnalysisRequest;
const BackfillRequest = runtime.BackfillRequest;
const DuplicateScanRequest = runtime.DuplicateScanRequest;
const JobHandle = runtime.JobHandle;
const JobWorker = job_worker.JobWorker;
const LibraryHandle = runtime.LibraryHandle;
const Lyrics = runtime.Lyrics;
const LyricsOptions = runtime.LyricsOptions;
const LyricsOutcome = runtime.LyricsOutcome;
const MatchRequest = runtime.MatchRequest;
const MatchStats = runtime.MatchStats;
const OrcaRuntime = runtime.OrcaRuntime;
const ReconcileRequest = runtime.ReconcileRequest;
const ScanRequest = runtime.ScanRequest;
const ScanStats = runtime.ScanStats;
const SubmissionStats = runtime.SubmissionStats;
const TagWriteFailure = runtime.TagWriteFailure;

/// How many finished job records keep their scanner counters queryable. A
/// bounded tail: a host reads the stats of the scan that just ended, not of
/// every scan the process ever ran.
const retained_job_records: usize = 8;

pub const job_progress_interval_ms: u64 = 100;

/// A host's matching, cover or submission job that arrived while a
/// maintenance unit ran: created queued, and started by `startQueuedHostJob`
/// once the unit's worker is joined and its `job_finished` published, so two
/// workers never share a provider. Control lane only.
pub const PendingHostJob = struct {
    job: JobHandle,
    library: LibraryHandle,
    request: job_worker.Request,
};

pub fn startLibraryScan(
    self: *OrcaRuntime,
    library: LibraryHandle,
    request: ScanRequest,
) !JobHandle {
    return startJobWorker(self, library, .{ .scan = request });
}

pub fn startLibraryReconcile(
    self: *OrcaRuntime,
    library: LibraryHandle,
    request: ReconcileRequest,
) !JobHandle {
    const pending = try job_worker.PendingReconcile.create(self.allocator, request);
    errdefer pending.destroy();
    return startJobWorker(self, library, .{ .reconcile = pending });
}

pub fn startLibraryProjection(self: *OrcaRuntime, library: LibraryHandle) !JobHandle {
    return startJobWorker(self, library, .projection);
}

pub fn startLibraryPropertyBackfill(
    self: *OrcaRuntime,
    library: LibraryHandle,
    request: BackfillRequest,
) !JobHandle {
    return startJobWorker(self, library, .{ .property_backfill = request });
}

pub fn startLibraryAnalysis(
    self: *OrcaRuntime,
    library: LibraryHandle,
    request: AnalysisRequest,
) !JobHandle {
    return startJobWorker(self, library, .{ .analysis = request });
}

pub fn startLibraryDuplicateScan(
    self: *OrcaRuntime,
    library: LibraryHandle,
    request: DuplicateScanRequest,
) !JobHandle {
    return startJobWorker(self, library, .{ .duplicate_scan = request });
}

pub fn startLibraryMatching(
    self: *OrcaRuntime,
    library: LibraryHandle,
    request: MatchRequest,
) !JobHandle {
    try runtime.requireRunning(self);
    const identity = self.client_identity orelse return error.ClientIdentityRequired;
    if (request.track_id != null and request.release_id != null) return error.InvalidMatchRequest;
    if (request.release_id == null and (request.accept_minimum_confidence != null or request.cover_art))
        return error.InvalidMatchRequest;
    switch (request.mode) {
        .search => {},
        .reidentify => if ((request.track_id == null and request.release_id == null) or
            request.accept_minimum_confidence != null) return error.InvalidMatchRequest,
        .verify => {
            if (request.accept_minimum_confidence != null or request.cover_art) return error.InvalidMatchRequest;
            if (!acoustIdInScope(self, request.fingerprints)) return error.AcoustIdRequired;
        },
    }
    if (request.accept_minimum_confidence) |minimum| {
        if (!std.math.isFinite(minimum) or minimum <= 0 or minimum > 1) return error.InvalidMinimumConfidence;
    }
    if (request.release_id) |release_id| try requireRelease(self, library, release_id);
    const scope: database.MatchScope = if (request.track_id) |track_id|
        .{ .track = track_id }
    else if (request.release_id) |release_id|
        .{ .release = release_id }
    else
        .library;
    const job_request: job_worker.Request = .{ .metadata_lookup = .{
        .batch_size = request.batch_size,
        .limit = request.limit,
        .setup = .{
            .io = try runtime_listens.networkIo(self),
            .server = self.musicbrainz_server,
            .identity = identity,
            .hooks = self.matching_hooks,
            .scope = scope,
            .mode = request.mode,
            .acoustid = if (request.fingerprints) acoustIdSetup(self) else null,
            .cover_art_server = self.coverartarchive_server,
        },
        .accept_minimum_confidence = request.accept_minimum_confidence,
        .cover_art = request.cover_art,
    } };
    if (self.pending_host_job != null) return error.MatchingAlreadyRunning;
    if (maintenanceUnitRunning(self)) |unit| return queueHostJob(self, library, job_request, unit);
    if (runningJob(self, .metadata_lookup)) return error.MatchingAlreadyRunning;
    if (runningJob(self, .acoustid_submission)) return error.AcoustIdBusy;
    return startJobWorker(self, library, job_request);
}

pub fn startReleaseCoverArtFetch(self: *OrcaRuntime, library: LibraryHandle, release_id: i64) !JobHandle {
    try runtime.requireRunning(self);
    const identity = self.client_identity orelse return error.ClientIdentityRequired;
    try requireRelease(self, library, release_id);
    const job_request: job_worker.Request = .{ .metadata_lookup = .{
        .batch_size = 1,
        .limit = null,
        .setup = .{
            .io = try runtime_listens.networkIo(self),
            .server = self.musicbrainz_server,
            .identity = identity,
            .hooks = self.matching_hooks,
            .scope = .{ .release = release_id },
            .acoustid = null,
            .cover_art_server = self.coverartarchive_server,
        },
        .lookups = false,
        .cover_art = true,
    } };
    if (self.pending_host_job != null) return error.MatchingAlreadyRunning;
    if (maintenanceUnitRunning(self)) |unit| return queueHostJob(self, library, job_request, unit);
    if (runningJob(self, .metadata_lookup)) return error.MatchingAlreadyRunning;
    return startJobWorker(self, library, job_request);
}

pub fn startTrackLyrics(self: *OrcaRuntime, library: LibraryHandle, track_id: i64, options: LyricsOptions) !JobHandle {
    return startJobWorker(self, library, .{ .lyrics = .{ .track_id = track_id, .options = options } });
}

pub fn jobLyricsOutcome(self: *OrcaRuntime, job_handle: JobHandle) !LyricsOutcome {
    return (try lyricsWorker(self, job_handle)).lyricsOutcome();
}

pub fn jobTakeLyrics(self: *OrcaRuntime, job_handle: JobHandle) !?Lyrics {
    return (try lyricsWorker(self, job_handle)).takeLyrics();
}

fn lyricsWorker(self: *OrcaRuntime, job_handle: JobHandle) !*JobWorker {
    if (queuedHostJob(self, job_handle)) return error.NotALyricsJob;
    for (self.job_workers.items) |worker| {
        if (!worker.job.eql(job_handle)) continue;
        if (worker.kind() != .lyrics) return error.NotALyricsJob;
        return worker;
    }
    return error.StaleHandle;
}

fn requireRelease(self: *OrcaRuntime, library: LibraryHandle, release_id: i64) !void {
    const release = try (try runtime.libraryDatabase(self, library)).releases.byId(self.allocator, release_id) orelse
        return error.UnknownRelease;
    release.deinit(self.allocator);
}

pub fn startAcoustIdSubmission(self: *OrcaRuntime, library: LibraryHandle) !JobHandle {
    try runtime.requireRunning(self);
    const identity = self.client_identity orelse return error.ClientIdentityRequired;
    const job_request: job_worker.Request = .{ .acoustid_submission = .{
        .io = try runtime_listens.networkIo(self),
        .identity = identity,
        .hooks = self.matching_hooks,
        .acoustid = acoustIdSetup(self),
    } };
    if (self.pending_host_job != null) return error.AcoustIdBusy;
    if (maintenanceUnitRunning(self)) |unit| return queueHostJob(self, library, job_request, unit);
    if (runningJob(self, .metadata_lookup) or runningJob(self, .acoustid_submission)) return error.AcoustIdBusy;
    return startJobWorker(self, library, job_request);
}

fn queueHostJob(self: *OrcaRuntime, library: LibraryHandle, request: job_worker.Request, unit: *JobWorker) !JobHandle {
    try checkBatchSize(request);
    const total_units = try plannedUnits(self, try runtime.libraryDatabase(self, library), request);
    const job_handle = try self.jobs.create(request.kind(), total_units);
    unit.token.cancel();
    unit.registration.requestCancellation();
    self.pending_host_job = .{ .job = job_handle, .library = library, .request = request };
    return job_handle;
}

/// Control lane, from `pump` once finished workers are reaped. Starts the
/// queued host job when no maintenance unit is left unjoined, or finishes it
/// cancelled when the host cancelled it while it waited.
pub fn startQueuedHostJob(self: *OrcaRuntime) void {
    const pending = self.pending_host_job orelse return;
    if (maintenanceWorkerLive(self) or !self.events.hasCapacity()) return;
    self.pending_host_job = null;
    const snapshot = self.jobs.snapshot(pending.job) catch return;
    const state: job.State = if (snapshot.state == .cancelling) .cancelled else started: {
        const library_database = runtime.libraryDatabase(self, pending.library) catch break :started .failed;
        spawnWorkerForJob(self, pending.job, pending.library, library_database, pending.request, .host) catch
            break :started .failed;
        return;
    };
    self.jobs.finish(pending.job, state) catch {};
    self.events.publish(.{
        .request_id = 0,
        .outcome = .{ .job_finished = .{ .job = pending.job, .state = state } },
    }) catch {};
}

/// Zero while a queued host job could start now; null otherwise. One held
/// up by a unit's worker is covered by that worker's own pump timeout.
pub fn queuedJobPumpDueMs(self: *const OrcaRuntime) ?u64 {
    if (self.pending_host_job == null or maintenanceWorkerLive(self)) return null;
    return 0;
}

/// Finishes the queued host job cancelled without an event when `library`
/// is going away, or any Library when null.
pub fn dropQueuedHostJob(self: *OrcaRuntime, library: ?LibraryHandle) void {
    const pending = self.pending_host_job orelse return;
    if (library) |only| if (!pending.library.eql(only)) return;
    self.jobs.finish(pending.job, .cancelled) catch {};
    self.pending_host_job = null;
}

fn queuedHostJob(self: *const OrcaRuntime, job_handle: JobHandle) bool {
    const pending = self.pending_host_job orelse return false;
    return pending.job.eql(job_handle);
}

pub fn jobOrigin(self: *const OrcaRuntime, job_handle: JobHandle) !job_worker.Origin {
    if (queuedHostJob(self, job_handle)) return .host;
    for (self.job_workers.items) |worker| {
        if (worker.job.eql(job_handle)) return worker.origin;
    }
    return error.StaleHandle;
}

pub fn hostWorkLive(self: *const OrcaRuntime) bool {
    if (self.pending_host_job != null) return true;
    for (self.job_workers.items) |worker| {
        if (!worker.retired and worker.origin != .maintenance) return true;
    }
    return false;
}

fn maintenanceWorkerLive(self: *const OrcaRuntime) bool {
    return maintenanceUnitRunning(self) != null;
}

pub fn maintenanceUnitRunning(self: *const OrcaRuntime) ?*JobWorker {
    for (self.job_workers.items) |worker| {
        if (!worker.retired and worker.origin == .maintenance) return worker;
    }
    return null;
}

pub fn jobSubmissionStats(self: *OrcaRuntime, job_handle: JobHandle) !SubmissionStats {
    if (queuedHostJob(self, job_handle)) return .{};
    for (self.job_workers.items) |worker| {
        if (!worker.job.eql(job_handle)) continue;
        return worker.submissionStats();
    }
    return error.StaleHandle;
}

pub fn libraryAcoustIdSubmittableCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
    return (try runtime.libraryDatabase(self, library)).acoustid_submissions.submittableCount();
}

pub fn libraryAcoustIdSubmittablePage(
    self: *OrcaRuntime,
    library: LibraryHandle,
    cursor: i64,
    limit: u32,
) !AcoustIdSubmittablePage {
    return (try runtime.libraryDatabase(self, library)).acoustid_submissions.submittablePage(self.allocator, cursor, limit);
}

fn runningJob(self: *const OrcaRuntime, kind: job.Kind) bool {
    for (self.job_workers.items) |worker| {
        if (!worker.retired and worker.kind() == kind and !worker.registration.isFinished()) return true;
    }
    return false;
}

fn walksLibrary(kind: job.Kind) bool {
    return kind == .scan or kind == .reconcile;
}

/// One walk per Library at a time: a walk stamps each location it reaches
/// with its own generation, and a second walk's later stamp or sweep would
/// mark files the other just saw as missing.
fn walkRunning(self: *const OrcaRuntime, library: LibraryHandle) bool {
    for (self.job_workers.items) |worker| {
        if (worker.retired or worker.registration.isFinished()) continue;
        if (worker.library.eql(library) and walksLibrary(worker.kind())) return true;
    }
    return false;
}

pub fn acoustIdSetup(self: *const OrcaRuntime) job_worker.AcoustIdSetup {
    return .{
        .server = self.acoustid_server,
        .client_key = self.acoustid_client_key,
        .credentials = self.credential_store,
    };
}

/// Whether a matching job would look anything up on AcoustID: a key is set
/// or the credential store may hold one.
pub fn acoustIdInScope(self: *const OrcaRuntime, fingerprints: bool) bool {
    return fingerprints and (self.acoustid_client_key != null or self.credential_store != null);
}

pub fn startJobWorker(
    self: *OrcaRuntime,
    library: LibraryHandle,
    request: job_worker.Request,
) !JobHandle {
    try runtime.requireRunning(self);
    switch (request.kind()) {
        .scan, .reconcile, .mutation => runtime_watch.preemptAutoReconcile(self, library),
        else => {},
    }
    const job_handle = try spawnJobWorker(self, library, request, .host);
    runtime_watch.hostJobStarted(self, library, job_handle, request);
    return job_handle;
}

pub fn spawnJobWorker(
    self: *OrcaRuntime,
    library: LibraryHandle,
    request: job_worker.Request,
    origin: job_worker.Origin,
) !JobHandle {
    try runtime.requireRunning(self);
    try checkBatchSize(request);
    const library_database = try runtime.libraryDatabase(self, library);
    if (walksLibrary(request.kind()) and walkRunning(self, library)) return error.LibraryScanRunning;
    const job_handle = try self.jobs.create(request.kind(), try plannedUnits(self, library_database, request));
    errdefer self.jobs.finish(job_handle, .failed) catch {};
    try spawnWorkerForJob(self, job_handle, library, library_database, request, origin);
    return job_handle;
}

fn checkBatchSize(request: job_worker.Request) !void {
    if (request.batchSize()) |batch_size| if (batch_size == 0) return error.InvalidBatchSize;
}

fn plannedUnits(self: *const OrcaRuntime, library_database: *database.LibraryDatabase, request: job_worker.Request) !?u64 {
    return switch (request) {
        .property_backfill => |backfill| try library_database.files
            .incompletePropertiesCount(backfill.force),
        .analysis => try library_database.files.unanalyzedCount(
            analysis_service.diagnosticsSelector(.{}),
        ),
        .duplicate_scan => try library_database.files.count(),
        .mutation => |pending| pending.plan.actions.len,
        .metadata_lookup => |matching| if (!matching.lookups)
            0
        else if (matching.setup.mode.selection()) |selection|
            try library_database.identification_proposals.unidentifiedCount(
                matching.setup.scope,
                selection,
                matching.setup.acoustid != null and acoustIdInScope(self, true),
                matching.limit,
            )
        else
            try library_database.recording_verifications.verifiableCount(matching.setup.scope, matching.limit),
        .acoustid_submission => try library_database.acoustid_submissions.submittableCount(),
        .scan, .reconcile, .projection, .lyrics => null,
    };
}

fn spawnWorkerForJob(
    self: *OrcaRuntime,
    job_handle: JobHandle,
    library: LibraryHandle,
    library_database: *database.LibraryDatabase,
    request: job_worker.Request,
    origin: job_worker.Origin,
) !void {
    pruneRetiredJobWorkers(self);
    const worker = try self.allocator.create(JobWorker);
    errdefer self.allocator.destroy(worker);
    try self.jobs.start(job_handle);

    const work_handle = try self.work_registry.begin(work.unowned);
    const registration = self.work_registry.registration(work_handle) catch unreachable;
    errdefer {
        registration.finish();
        self.work_registry.complete(work_handle) catch {};
    }
    worker.* = .{
        .allocator = self.allocator,
        .registration = registration,
        .work_handle = work_handle,
        .job = job_handle,
        .library = library,
        .database = library_database,
        .request = request,
        .origin = origin,
        .stats = .init(request),
        .host_signal = &self.host_signal,
    };
    try self.job_workers.append(self.allocator, worker);
    errdefer _ = self.job_workers.pop();
    registration.thread = try std.Thread.spawn(.{}, JobWorker.run, .{worker});
}

pub fn cancelJob(self: *OrcaRuntime, job_handle: JobHandle) !void {
    try runtime.requireRunning(self);
    try self.jobs.requestCancellation(job_handle);
    for (self.job_workers.items) |worker| {
        if (worker.retired or !worker.job.eql(job_handle)) continue;
        worker.token.cancel();
        worker.registration.requestCancellation();
    }
}

pub fn jobSnapshotSynced(self: *OrcaRuntime, job_handle: JobHandle) !job.Snapshot {
    syncJobProgress(self);
    return self.jobs.snapshot(job_handle);
}

pub fn jobScanStats(self: *OrcaRuntime, job_handle: JobHandle) !ScanStats {
    if (queuedHostJob(self, job_handle)) return .{};
    for (self.job_workers.items) |worker| {
        if (!worker.job.eql(job_handle)) continue;
        return worker.scanStats();
    }
    return error.StaleHandle;
}

pub fn jobReconcileRoot(self: *OrcaRuntime, job_handle: JobHandle) !?i64 {
    if (queuedHostJob(self, job_handle)) return null;
    for (self.job_workers.items) |worker| {
        if (!worker.job.eql(job_handle)) continue;
        const pending = worker.pendingReconcile() orelse return null;
        return pending.request.root_id;
    }
    return error.StaleHandle;
}

pub fn jobTagWriteFailure(self: *OrcaRuntime, job_handle: JobHandle) !?TagWriteFailure {
    if (queuedHostJob(self, job_handle)) return error.NotATagWriteJob;
    for (self.job_workers.items) |worker| {
        if (!worker.job.eql(job_handle)) continue;
        if (worker.kind() != .mutation) return error.NotATagWriteJob;
        return worker.tagWriteFailure();
    }
    return error.StaleHandle;
}

pub fn jobMatchStats(self: *OrcaRuntime, job_handle: JobHandle) !MatchStats {
    if (queuedHostJob(self, job_handle)) return .{};
    for (self.job_workers.items) |worker| {
        if (!worker.job.eql(job_handle)) continue;
        return worker.matchStats();
    }
    return error.StaleHandle;
}

fn syncJobProgress(self: *OrcaRuntime) void {
    for (self.job_workers.items) |worker| {
        if (worker.retired) continue;
        self.jobs.observeProgress(worker.job, worker.filesProcessed()) catch {};
    }
}

/// Zero while a finished worker waits to be reaped, which a full event
/// channel can defer past the wake its finish raised;
/// `job_progress_interval_ms` while one runs; null when none is live.
pub fn jobPumpDueMs(self: *const OrcaRuntime) ?u64 {
    var due: ?u64 = null;
    for (self.job_workers.items) |worker| {
        if (worker.retired) continue;
        if (worker.registration.isFinished()) return 0;
        due = job_progress_interval_ms;
    }
    return due;
}

pub fn reapFinishedJobs(self: *OrcaRuntime) void {
    syncJobProgress(self);
    for (self.job_workers.items) |worker| {
        if (worker.retired or !worker.registration.isFinished()) continue;
        // The completion event is lossless: a full channel means the host
        // has stopped polling, so the worker stays reapable until it drains.
        if (!self.events.hasCapacity()) return;
        self.work_registry.complete(worker.work_handle) catch {};
        finalizeJobWorker(self, worker, true);
    }
}

/// Ignores maintenance units, which a caller pre-empts instead.
pub fn libraryJobRunning(self: *const OrcaRuntime, library: LibraryHandle) bool {
    if (self.pending_host_job) |pending| if (pending.library.eql(library)) return true;
    for (self.job_workers.items) |worker| {
        if (!worker.retired and worker.origin != .maintenance and worker.library.eql(library)) return true;
    }
    return false;
}

/// Records a joined worker's outcome. `publish` is false where no host
/// should see the event: on the shutdown path, where none will poll it, and
/// for an automatic reconcile the runtime stopped itself.
pub fn finalizeJobWorker(self: *OrcaRuntime, worker: *JobWorker, publish: bool) void {
    worker.retired = true;
    const state: job.State = if (worker.failed.load(.acquire))
        .failed
    else if (worker.wasCancelled())
        .cancelled
    else
        .succeeded;
    self.jobs.observeProgress(worker.job, worker.filesProcessed()) catch {};
    self.jobs.finish(worker.job, state) catch {};
    if (worker.matchStats().accepted != 0) runtime_listens.recordingIdsChanged(self, worker.library);
    runtime_watch.jobFinalized(self, worker, state);
    runtime_maintenance.jobFinalized(self, worker, state);
    if (!publish) return;
    self.events.publish(.{
        .request_id = 0,
        .outcome = .{ .job_finished = .{ .job = worker.job, .state = state } },
    }) catch {};
}

/// Control lane. Cancels every job worker's cooperative token. The registry
/// flag alone cannot reach inside a scan — the scanner polls a
/// `CancellationToken` — so the two are always set together.
pub fn cancelJobWorkers(self: *OrcaRuntime) void {
    for (self.job_workers.items) |worker| {
        if (worker.retired) continue;
        worker.token.cancel();
    }
}

/// Control lane, immediately after `work_registry.drain()`: every worker
/// thread has been joined and its registration already freed, so the
/// records are finalized without touching the Registry again.
pub fn finalizeDrainedJobWorkers(self: *OrcaRuntime) void {
    for (self.job_workers.items) |worker| {
        if (worker.retired) continue;
        finalizeJobWorker(self, worker, false);
    }
}

/// Retains a bounded tail of finished job records so `jobScanStats` still
/// answers for a scan that has just completed, and no more.
fn pruneRetiredJobWorkers(self: *OrcaRuntime) void {
    var retired: usize = 0;
    for (self.job_workers.items) |worker| {
        if (worker.retired) retired += 1;
    }
    if (retired <= retained_job_records) return;
    var to_drop = retired - retained_job_records;
    var index: usize = 0;
    while (index < self.job_workers.items.len and to_drop != 0) {
        const worker = self.job_workers.items[index];
        if (!worker.retired) {
            index += 1;
            continue;
        }
        _ = self.job_workers.orderedRemove(index);
        destroyJobWorker(self, worker);
        to_drop -= 1;
    }
}

pub fn freeAllJobWorkers(self: *OrcaRuntime) void {
    for (self.job_workers.items) |worker| destroyJobWorker(self, worker);
    self.job_workers.deinit(self.allocator);
    self.job_workers = .empty;
}

fn destroyJobWorker(self: *OrcaRuntime, worker: *JobWorker) void {
    if (worker.tagWrite()) |pending| pending.destroy(self.control_threaded.io());
    if (worker.pendingReconcile()) |pending| pending.destroy();
    switch (worker.stats) {
        .lyrics => |stats| if (stats.result) |lyrics| lyrics.deinit(),
        else => {},
    }
    self.allocator.destroy(worker);
}

pub fn discardPendingTagWrites(self: *OrcaRuntime, library: ?LibraryHandle) void {
    for (&self.pending_tag_writes) |*slot| {
        const pending = slot.* orelse continue;
        if (library) |only| if (!pending.library.eql(only)) continue;
        pending.destroy(self.control_threaded.io());
        slot.* = null;
    }
}
