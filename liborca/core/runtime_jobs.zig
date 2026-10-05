const std = @import("std");
const analysis_service = @import("../analysis/service.zig");
const database = @import("../database/root.zig");
const library_pass = @import("../library/root.zig");
const job = @import("job.zig");
const job_history = @import("job_history.zig");
const work = @import("work.zig");
const job_worker = @import("job_worker.zig");
const runtime = @import("runtime.zig");
const runtime_listens = @import("runtime_listens.zig");
const runtime_maintenance = @import("runtime_maintenance.zig");
const runtime_watch = @import("runtime_watch.zig");

const AcoustIdSubmittablePage = runtime.AcoustIdSubmittablePage;
const AnalysisRequest = runtime.AnalysisRequest;
const ArtistInfoOptions = runtime.ArtistInfoOptions;
const ArtistInfoOutcome = runtime.ArtistInfoOutcome;
const ReleaseInfoOptions = runtime.ReleaseInfoOptions;
const ReleaseInfoOutcome = runtime.ReleaseInfoOutcome;
const GenreFillOptions = runtime.GenreFillOptions;
const BackfillRequest = runtime.BackfillRequest;
const DuplicateScanRequest = runtime.DuplicateScanRequest;
const ConsistencyRequest = runtime.ConsistencyRequest;
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

pub const max_waiting_jobs = 32;

/// A host's Job in the `waiting` state: its Library's slot was held, the
/// Library's Jobs were paused, or, for a provider Job, a maintenance unit had
/// yet to stop. The queue owns `request` until `startWaitingJobs` hands it to
/// a worker. Control lane only.
pub const WaitingJob = struct {
    job: JobHandle,
    library: LibraryHandle,
    request: job_worker.Request,
};

pub const WaitingJobs = struct {
    entries: [max_waiting_jobs]WaitingJob = undefined,
    len: usize = 0,

    pub fn items(self: *const WaitingJobs) []const WaitingJob {
        return self.entries[0..self.len];
    }

    fn append(self: *WaitingJobs, entry: WaitingJob) !void {
        if (self.len == max_waiting_jobs) return error.JobQueueFull;
        self.entries[self.len] = entry;
        self.len += 1;
    }

    fn orderedRemove(self: *WaitingJobs, index: usize) WaitingJob {
        const entry = self.entries[index];
        std.mem.copyForwards(WaitingJob, self.entries[index .. self.len - 1], self.entries[index + 1 .. self.len]);
        self.len -= 1;
        return entry;
    }
};

/// A Job holding or waiting for its Library's slot, in the order they run.
pub const QueuedJob = struct {
    job: JobHandle,
    kind: job.Kind,
    /// The Job this one starts after; null for the one holding the slot, or
    /// the first waiting while none does.
    after: ?JobHandle,
};

pub const JobHistoryEntry = job_history.JobHistoryEntry;
pub const JobHistoryFilter = job_history.Filter;

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

pub fn startLibraryConsistencyPass(
    self: *OrcaRuntime,
    library: LibraryHandle,
    request: ConsistencyRequest,
) !JobHandle {
    return startJobWorker(self, library, .{ .consistency = request });
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
    if (providerJobWaiting(self)) return error.MatchingAlreadyRunning;
    if (maintenanceUnitRunning(self)) |unit| return queueBehindUnit(self, library, job_request, unit);
    if (runningJob(self, .metadata_lookup)) return error.MatchingAlreadyRunning;
    if (runningJob(self, .acoustid_submission)) return error.AcoustIdBusy;
    return startJobWorker(self, library, job_request);
}

pub fn startReleaseCoverArtFetch(self: *OrcaRuntime, library: LibraryHandle, release_id: i64) !JobHandle {
    return startCoverArtJob(self, library, release_id, .front);
}

pub fn startCoverArtCandidates(self: *OrcaRuntime, library: LibraryHandle, release_id: i64) !JobHandle {
    return startCoverArtJob(self, library, release_id, .candidates);
}

pub fn useCoverArtCandidate(
    self: *OrcaRuntime,
    library: LibraryHandle,
    release_id: i64,
    caa_id: i64,
    kind: database.ReleaseArtworkKind,
) !JobHandle {
    try runtime.requireRunning(self);
    const db = try runtime.libraryDatabase(self, library);
    _ = try db.release_artwork.candidateRelease(release_id, caa_id) orelse return error.UnknownCoverArtCandidate;
    return startCoverArtJob(self, library, release_id, .{ .use = .{ .caa_id = caa_id, .kind = kind } });
}

fn startCoverArtJob(self: *OrcaRuntime, library: LibraryHandle, release_id: i64, task: job_worker.CoverArtTask) !JobHandle {
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
        .cover_art_task = task,
    } };
    if (providerJobWaiting(self)) return error.MatchingAlreadyRunning;
    if (maintenanceUnitRunning(self)) |unit| return queueBehindUnit(self, library, job_request, unit);
    if (runningJob(self, .metadata_lookup)) return error.MatchingAlreadyRunning;
    return startJobWorker(self, library, job_request);
}

pub fn startTrackLyrics(self: *OrcaRuntime, library: LibraryHandle, track_id: i64, options: LyricsOptions) !JobHandle {
    try runtime.requireRunning(self);
    const setup: ?job_worker.LyricsSetup = if (options.fetch) .{
        .io = try runtime_listens.networkIo(self),
        .identity = self.client_identity orelse return error.ClientIdentityRequired,
        .hooks = self.matching_hooks,
        .server = self.lrclib_server,
    } else null;
    return startJobWorker(self, library, .{ .lyrics = .{ .track_id = track_id, .options = options, .setup = setup } });
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

pub fn startArtistInfoFetch(self: *OrcaRuntime, library: LibraryHandle, artist_id: i64, options: ArtistInfoOptions) !JobHandle {
    try runtime.requireRunning(self);
    const language: job_worker.ArtistInfoLanguage = try .init(options.language);
    _ = try (try runtime.libraryDatabase(self, library)).artist_info.subject(artist_id) orelse return error.UnknownArtist;
    return startJobWorker(self, library, .{ .artist_info = .{
        .artist_id = artist_id,
        .language = language,
        .force = options.force,
        .offline = options.offline,
        .include_releases = options.include_releases,
        .setup = try infoSetup(self),
    } });
}

fn infoSetup(self: *OrcaRuntime) !job_worker.ArtistInfoSetup {
    return .{
        .io = try runtime_listens.networkIo(self),
        .identity = self.client_identity orelse return error.ClientIdentityRequired,
        .hooks = self.matching_hooks,
        .musicbrainz_server = self.musicbrainz_server,
        .wikidata_server = self.wikidata_server,
        .commons_server = self.wikimedia_commons_server,
        .wikipedia_server = self.wikipedia_server,
        .listenbrainz_server = self.listenbrainz_server,
        .listenbrainz_labs_server = self.listenbrainz_labs_server,
        .coverartarchive_server = self.coverartarchive_server,
    };
}

pub fn startReleaseInfoFetch(self: *OrcaRuntime, library: LibraryHandle, release_id: i64, options: ReleaseInfoOptions) !JobHandle {
    try runtime.requireRunning(self);
    const language: job_worker.ArtistInfoLanguage = try .init(options.language);
    _ = try (try runtime.libraryDatabase(self, library)).release_info.subject(release_id) orelse return error.UnknownRelease;
    return startJobWorker(self, library, .{ .release_info = .{
        .target = .{ .release = release_id },
        .language = language,
        .force = options.force,
        .offline = options.offline,
        .setup = try infoSetup(self),
    } });
}

pub fn startGenreFill(self: *OrcaRuntime, library: LibraryHandle, options: GenreFillOptions) !JobHandle {
    try runtime.requireRunning(self);
    if (options.limit == 0 or options.limit > database.repository.max_page) return error.InvalidLimit;
    _ = try runtime.libraryDatabase(self, library);
    return startJobWorker(self, library, .{ .release_info = .{
        .target = .{ .missing_genres = options.limit },
        .language = try .init("en"),
        .offline = options.offline,
        .setup = try infoSetup(self),
    } });
}

pub fn jobReleaseInfoOutcome(self: *OrcaRuntime, job_handle: JobHandle) !ReleaseInfoOutcome {
    if (queuedHostJob(self, job_handle)) return error.NotAReleaseInfoJob;
    for (self.job_workers.items) |worker| {
        if (!worker.job.eql(job_handle)) continue;
        if (worker.kind() != .release_info) return error.NotAReleaseInfoJob;
        return worker.artistInfoOutcome();
    }
    return error.StaleHandle;
}

pub fn jobArtistInfoOutcome(self: *OrcaRuntime, job_handle: JobHandle) !ArtistInfoOutcome {
    if (queuedHostJob(self, job_handle)) return error.NotAnArtistInfoJob;
    for (self.job_workers.items) |worker| {
        if (!worker.job.eql(job_handle)) continue;
        if (worker.kind() != .artist_info) return error.NotAnArtistInfoJob;
        return worker.artistInfoOutcome();
    }
    return error.StaleHandle;
}

pub fn jobArtistInfoStores(self: *OrcaRuntime, job_handle: JobHandle) !u32 {
    if (queuedHostJob(self, job_handle)) return error.NotAnArtistInfoJob;
    for (self.job_workers.items) |worker| {
        if (!worker.job.eql(job_handle)) continue;
        if (worker.kind() != .artist_info) return error.NotAnArtistInfoJob;
        return worker.artistInfoStores();
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
    if (providerJobWaiting(self)) return error.AcoustIdBusy;
    if (maintenanceUnitRunning(self)) |unit| return queueBehindUnit(self, library, job_request, unit);
    if (runningJob(self, .metadata_lookup) or runningJob(self, .acoustid_submission)) return error.AcoustIdBusy;
    return startJobWorker(self, library, job_request);
}

/// A provider Job arriving while a maintenance unit runs: the unit is
/// cancelled and the Job waits until its worker is joined and its
/// `job_finished` published, so two workers never share a provider.
fn queueBehindUnit(self: *OrcaRuntime, library: LibraryHandle, request: job_worker.Request, unit: *JobWorker) !JobHandle {
    const job_handle = try queueJob(self, library, request);
    unit.token.cancel();
    unit.registration.requestCancellation();
    return job_handle;
}

/// Takes ownership of `request` only on success.
fn queueJob(self: *OrcaRuntime, library: LibraryHandle, request: job_worker.Request) !JobHandle {
    try checkBatchSize(request);
    const object_value = try self.libraries.get(library);
    const library_database = object_value.database orelse return error.LibraryHasNoDatabase;
    if (self.waiting_jobs.len == max_waiting_jobs) return error.JobQueueFull;
    const job_handle = try self.jobs.create(request.kind(), try plannedUnits(self, library_database, request));
    self.jobs.wait(job_handle) catch unreachable;
    if (object_value.jobs_paused) self.jobs.setPausedWhileWaiting(job_handle, true) catch unreachable;
    self.waiting_jobs.append(.{ .job = job_handle, .library = library, .request = request }) catch unreachable;
    return job_handle;
}

fn providerJobWaiting(self: *const OrcaRuntime) bool {
    for (self.waiting_jobs.items()) |entry| {
        if (usesProviders(entry.request.kind())) return true;
    }
    return false;
}

fn usesProviders(kind: job.Kind) bool {
    return kind == .metadata_lookup or kind == .acoustid_submission;
}

/// The live host worker holding `library`'s one slot, finished or not until
/// it is reaped.
fn slotHolder(self: *const OrcaRuntime, library: LibraryHandle) ?*JobWorker {
    for (self.job_workers.items) |worker| {
        if (worker.retired or worker.origin != .host or !worker.library.eql(library)) continue;
        if (worker.request.queues()) return worker;
    }
    return null;
}

fn mustWait(self: *const OrcaRuntime, library: LibraryHandle) bool {
    const object_value = self.libraries.getConst(library) catch return false;
    if (object_value.jobs_paused) return true;
    for (self.waiting_jobs.items()) |entry| {
        if (entry.library.eql(library)) return true;
    }
    return slotHolder(self, library) != null;
}

/// Control lane, from `pump` once finished workers are reaped. Finishes
/// the waiting Jobs the host cancelled, and starts each one whose Library's
/// slot is free, in the order they arrived.
pub fn startWaitingJobs(self: *OrcaRuntime) void {
    var index: usize = 0;
    while (index < self.waiting_jobs.len) {
        const entry = self.waiting_jobs.entries[index];
        const cancelling = if (self.jobs.snapshot(entry.job)) |snapshot| snapshot.state == .cancelling else |_| true;
        if (!cancelling and !waitingJobStartable(self, index)) {
            index += 1;
            continue;
        }
        if (!self.events.hasCapacity()) return;
        _ = self.waiting_jobs.orderedRemove(index);
        if (cancelling) {
            finishWaitingJob(self, entry, .cancelled, true);
            continue;
        }
        startWaitingJob(self, entry) catch finishWaitingJob(self, entry, .failed, true);
    }
}

fn waitingJobStartable(self: *const OrcaRuntime, index: usize) bool {
    if (self.state.load(.acquire) != .running) return false;
    const entry = self.waiting_jobs.entries[index];
    const object_value = self.libraries.getConst(entry.library) catch return true;
    if (object_value.jobs_paused) return false;
    for (self.waiting_jobs.entries[0..index]) |earlier| {
        if (earlier.library.eql(entry.library)) return false;
    }
    if (slotHolder(self, entry.library) != null) return false;
    return !(usesProviders(entry.request.kind()) and maintenanceWorkerLive(self));
}

fn startWaitingJob(self: *OrcaRuntime, entry: WaitingJob) !void {
    const library_database = try runtime.libraryDatabase(self, entry.library);
    try self.jobs.replan(entry.job, try plannedUnits(self, library_database, entry.request));
    switch (entry.request.kind()) {
        .scan, .reconcile, .mutation => runtime_watch.preemptAutoReconcile(self, entry.library),
        else => {},
    }
    if (walksLibrary(entry.request.kind()) and walkRunning(self, entry.library)) return error.LibraryScanRunning;
    try spawnWorkerForJob(self, entry.job, entry.library, library_database, entry.request, .host);
    runtime_watch.hostJobStarted(self, entry.library, entry.job, entry.request);
}

fn finishWaitingJob(self: *OrcaRuntime, entry: WaitingJob, state: job.State, publish: bool) void {
    self.jobs.finish(entry.job, state) catch {};
    if (self.libraries.get(entry.library)) |object_value| {
        if (object_value.database) |library_database| recordWaitingHistory(self, library_database, entry, state);
    } else |_| {}
    destroyRequest(self, entry.request);
    if (!publish) return;
    self.events.publish(.{
        .request_id = 0,
        .outcome = .{ .job_finished = .{ .job = entry.job, .state = state } },
    }) catch {};
}

fn destroyRequest(self: *OrcaRuntime, request: job_worker.Request) void {
    switch (request) {
        .reconcile => |pending| pending.destroy(),
        .mutation => |pending| pending.destroy(self.control_threaded.io()),
        else => {},
    }
}

/// Zero while a waiting Job could start or finish now; null otherwise. One
/// held up by a worker is covered by that worker's own pump timeout, and one
/// held by a paused Library by the `resumeAll` that frees it.
pub fn queuedJobPumpDueMs(self: *const OrcaRuntime) ?u64 {
    for (self.waiting_jobs.items(), 0..) |entry, index| {
        const snapshot = self.jobs.snapshot(entry.job) catch return 0;
        if (snapshot.state == .cancelling or waitingJobStartable(self, index)) return 0;
    }
    return null;
}

/// Finishes the waiting Jobs cancelled without an event when `library` is
/// going away, or every Library's when null.
pub fn dropWaitingJobs(self: *OrcaRuntime, library: ?LibraryHandle) void {
    var index: usize = 0;
    while (index < self.waiting_jobs.len) {
        const entry = self.waiting_jobs.entries[index];
        if (library) |only| if (!entry.library.eql(only)) {
            index += 1;
            continue;
        };
        _ = self.waiting_jobs.orderedRemove(index);
        finishWaitingJob(self, entry, .cancelled, false);
    }
}

fn queuedHostJob(self: *const OrcaRuntime, job_handle: JobHandle) bool {
    for (self.waiting_jobs.items()) |entry| {
        if (entry.job.eql(job_handle)) return true;
    }
    return false;
}

fn liveWorker(self: *const OrcaRuntime, job_handle: JobHandle) ?*JobWorker {
    for (self.job_workers.items) |worker| {
        if (!worker.retired and worker.job.eql(job_handle)) return worker;
    }
    return null;
}

pub fn pauseJob(self: *OrcaRuntime, job_handle: JobHandle) !void {
    try runtime.requireRunning(self);
    const worker = liveWorker(self, job_handle) orelse return notLive(self, job_handle);
    if (!worker.request.pausable()) return error.JobNotPausable;
    try self.jobs.pause(job_handle);
    worker.token.pause();
}

pub fn resumeJob(self: *OrcaRuntime, job_handle: JobHandle) !void {
    try runtime.requireRunning(self);
    const worker = liveWorker(self, job_handle) orelse return notLive(self, job_handle);
    try self.jobs.unpause(job_handle);
    worker.token.unpause();
}

fn notLive(self: *const OrcaRuntime, job_handle: JobHandle) error{ StaleHandle, JobAlreadyFinished, JobNotPausable } {
    const snapshot = self.jobs.snapshot(job_handle) catch return error.StaleHandle;
    return switch (snapshot.state) {
        .succeeded, .failed, .cancelled => error.JobAlreadyFinished,
        else => error.JobNotPausable,
    };
}

pub fn pauseAll(self: *OrcaRuntime, library: LibraryHandle) !void {
    try runtime.requireRunning(self);
    const object_value = try self.libraries.get(library);
    object_value.jobs_paused = true;
    for (self.job_workers.items) |worker| {
        if (worker.retired or !worker.library.eql(library) or !worker.request.pausable()) continue;
        self.jobs.pause(worker.job) catch continue;
        worker.token.pause();
    }
    markWaitingPaused(self, library, true);
}

pub fn resumeAll(self: *OrcaRuntime, library: LibraryHandle) !void {
    try runtime.requireRunning(self);
    const object_value = try self.libraries.get(library);
    object_value.jobs_paused = false;
    for (self.job_workers.items) |worker| {
        if (worker.retired or !worker.library.eql(library)) continue;
        self.jobs.unpause(worker.job) catch continue;
        worker.token.unpause();
    }
    markWaitingPaused(self, library, false);
}

fn markWaitingPaused(self: *OrcaRuntime, library: LibraryHandle, paused: bool) void {
    for (self.waiting_jobs.items()) |entry| {
        if (entry.library.eql(library)) self.jobs.setPausedWhileWaiting(entry.job, paused) catch {};
    }
}

pub fn libraryJobsPaused(self: *const OrcaRuntime, library: LibraryHandle) !bool {
    const object_value = try self.libraries.getConst(library);
    return object_value.jobs_paused;
}

pub fn jobQueuePage(self: *OrcaRuntime, library: LibraryHandle, allocator: std.mem.Allocator) ![]QueuedJob {
    try runtime.requireRunning(self);
    _ = try self.libraries.getConst(library);
    var queued: std.ArrayList(QueuedJob) = .empty;
    errdefer queued.deinit(allocator);
    var after: ?JobHandle = null;
    if (slotHolder(self, library)) |worker| {
        try queued.append(allocator, .{ .job = worker.job, .kind = worker.kind(), .after = null });
        after = worker.job;
    }
    for (self.waiting_jobs.items()) |entry| {
        if (!entry.library.eql(library)) continue;
        const snapshot = self.jobs.snapshot(entry.job) catch continue;
        if (snapshot.state == .cancelling) continue;
        try queued.append(allocator, .{ .job = entry.job, .kind = entry.request.kind(), .after = after });
        after = entry.job;
    }
    return queued.toOwnedSlice(allocator);
}

pub fn jobHistoryPage(
    self: *OrcaRuntime,
    library: LibraryHandle,
    allocator: std.mem.Allocator,
    filter: JobHistoryFilter,
    limit: u32,
    offset: u32,
) ![]JobHistoryEntry {
    const library_database = try runtime.libraryDatabase(self, library);
    var page = try library_database.job_history.page(allocator, filter, limit, offset);
    defer page.deinit();
    var entries: std.ArrayList(JobHistoryEntry) = try .initCapacity(allocator, page.items.len);
    errdefer entries.deinit(allocator);
    for (page.items) |row| {
        if (JobHistoryEntry.fromRow(row)) |entry| entries.appendAssumeCapacity(entry);
    }
    return entries.toOwnedSlice(allocator);
}

pub fn jobRetry(self: *OrcaRuntime, library: LibraryHandle, history_id: i64) !JobHandle {
    const library_database = try runtime.libraryDatabase(self, library);
    const row = try library_database.job_history.get(self.allocator, history_id) orelse return error.UnknownJobHistory;
    defer row.deinit();
    if (!row.retryable) return error.JobNotRetryable;
    const text = row.request orelse return error.JobNotRetryable;
    const parsed = job_history.RetryRequest.decode(self.allocator, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.JobNotRetryable,
    };
    defer parsed.deinit();
    return switch (parsed.value) {
        .scan => |request| startLibraryScan(self, library, request),
        .reconcile => |request| startLibraryReconcile(self, library, request),
        .projection => startLibraryProjection(self, library),
        .property_backfill => |request| startLibraryPropertyBackfill(self, library, request),
        .analysis => |request| startLibraryAnalysis(self, library, request),
        .duplicate_scan => |request| startLibraryDuplicateScan(self, library, request),
        .consistency => |request| startLibraryConsistencyPass(self, library, request),
        .matching => |request| startLibraryMatching(self, library, request),
        .cover_art => |request| startReleaseCoverArtFetch(self, library, request.release_id),
        .acoustid_submission => startAcoustIdSubmission(self, library),
        .genre_fill => |options| startGenreFill(self, library, options),
    };
}

fn recordWaitingHistory(self: *OrcaRuntime, library_database: *database.LibraryDatabase, entry: WaitingJob, state: job.State) void {
    const snapshot = self.jobs.snapshot(entry.job) catch return;
    const now = runtime_listens.sampleTime(self).wall_s;
    recordHistory(self, library_database, entry.request, .{
        .kind = @tagName(snapshot.kind),
        .started_at = now,
        .finished_at = now,
        .state = @tagName(state),
        .completed_units = 0,
        .total_units = snapshot.total_units,
        .error_text = @tagName(state),
    });
}

fn recordWorkerHistory(self: *OrcaRuntime, worker: *const JobWorker, state: job.State) void {
    if (worker.origin != .host or !worker.request.queues()) return;
    const snapshot = self.jobs.snapshot(worker.job) catch return;
    const now = runtime_listens.sampleTime(self).wall_s;
    var error_buffer: [64]u8 = undefined;
    var summary_buffer: [256]u8 = undefined;
    recordHistory(self, worker.database, worker.request, .{
        .kind = @tagName(snapshot.kind),
        .started_at = snapshot.started_at orelse now,
        .finished_at = now,
        .state = @tagName(state),
        .completed_units = snapshot.completed_units,
        .total_units = snapshot.total_units,
        .error_text = job_history.errorText(worker, state, &error_buffer),
        .undo_group_id = if (state == .succeeded) if (worker.tagWrite()) |pending| pending.plan.id else null else null,
        .summary = job_history.summary(worker, &summary_buffer),
    });
}

fn recordHistory(
    self: *OrcaRuntime,
    library_database: *database.LibraryDatabase,
    request: job_worker.Request,
    input: database.JobHistoryInput,
) void {
    var row = input;
    const encoded: ?[]u8 = if (job_history.RetryRequest.fromRequest(request)) |retry|
        retry.encode(self.allocator) catch null
    else
        null;
    defer if (encoded) |text| self.allocator.free(text);
    row.request = encoded;
    row.retryable = encoded != null and !std.mem.eql(u8, input.state, "succeeded");
    _ = library_database.job_history.insert(row) catch {};
}

pub fn jobOrigin(self: *const OrcaRuntime, job_handle: JobHandle) !job_worker.Origin {
    if (queuedHostJob(self, job_handle)) return .host;
    for (self.job_workers.items) |worker| {
        if (worker.job.eql(job_handle)) return worker.origin;
    }
    return error.StaleHandle;
}

pub fn hostWorkLive(self: *const OrcaRuntime) bool {
    if (self.waiting_jobs.len != 0) return true;
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
    if (request.queues() and mustWait(self, library)) return queueJob(self, library, request);
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
            .incompletePropertiesCount(backfill.force) +
            try database.repository.unmeasuredCoverCount(library_database.database),
        .analysis => try library_database.files.unanalyzedCount(
            analysis_service.diagnosticsSelector(.{}),
        ),
        .duplicate_scan => try library_database.files.count(),
        .consistency => try library_database.releases.count(),
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
        .scan, .reconcile, .projection, .lyrics, .artist_info, .release_info => null,
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
    try self.jobs.start(job_handle, runtime_listens.sampleTime(self).wall_s);

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
    worker.token.io = worker.threaded.io();
    registration.waker = .{ .context = &worker.token, .wake_fn = JobWorker.wakeFromPause };
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
    var snapshot = try self.jobs.snapshot(job_handle);
    const worker = liveWorker(self, job_handle) orelse return snapshot;
    var item: [library_pass.CurrentItem.capacity]u8 = undefined;
    snapshot.current_item.set(worker.current_item.read(&item));
    writeDetail(worker, &snapshot.detail);
    return snapshot;
}

fn writeDetail(worker: *const JobWorker, detail: *job.BoundedText(128)) void {
    var buffer: [128]u8 = undefined;
    detail.set(switch (worker.request) {
        .analysis => |request| blk: {
            const threads = request.threads orelse library_pass.analysis_pass.defaultThreads();
            break :blk std.fmt.bufPrint(&buffer, "{d} {s}", .{
                threads, if (threads == 1) "thread" else "threads",
            }) catch "";
        },
        .metadata_lookup, .acoustid_submission => "rate-limited to 1 request a second",
        else => "",
    });
}

pub fn jobScanStats(self: *OrcaRuntime, job_handle: JobHandle) !ScanStats {
    if (queuedHostJob(self, job_handle)) return .{};
    for (self.job_workers.items) |worker| {
        if (!worker.job.eql(job_handle)) continue;
        var stats = worker.scanStats();
        if (stats.stage == .read_tags) {
            var item: [library_pass.CurrentItem.capacity]u8 = undefined;
            stats.current_path.set(worker.current_item.read(&item));
        }
        return stats;
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

pub fn jobMatchRelease(self: *OrcaRuntime, job_handle: JobHandle) !?i64 {
    if (queuedHostJob(self, job_handle)) return null;
    for (self.job_workers.items) |worker| {
        if (!worker.job.eql(job_handle)) continue;
        return worker.matchRelease();
    }
    return error.StaleHandle;
}

fn syncJobProgress(self: *OrcaRuntime) void {
    const now_ms = runtime_listens.sampleTime(self).mono_ms;
    for (self.job_workers.items) |worker| {
        if (worker.retired) continue;
        const completed = worker.filesProcessed();
        if (worker.totalUnits(completed)) |total| self.jobs.observeTotal(worker.job, total) catch {};
        self.jobs.observeProgress(worker.job, completed) catch {};
        self.jobs.sampleProgress(worker.job, now_ms) catch {};
    }
}

fn publishJobProgress(self: *OrcaRuntime) void {
    for (self.job_workers.items) |worker| {
        if (worker.retired or worker.origin != .host or worker.registration.isFinished()) continue;
        const snapshot = self.jobs.snapshot(worker.job) catch continue;
        const current: job_worker.PublishedProgress = .{
            .completed_units = snapshot.completed_units,
            .total_units = snapshot.total_units,
            .state = snapshot.state,
        };
        if (worker.published) |published| if (std.meta.eql(published, current)) continue;
        self.telemetry.publish(.{ .job_progress = .{
            .job = worker.job,
            .completed_units = current.completed_units,
            .total_units = current.total_units,
        } }) catch continue;
        worker.published = current;
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
    publishJobProgress(self);
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
    for (self.waiting_jobs.items()) |entry| {
        if (entry.library.eql(library)) return true;
    }
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
    const completed = worker.filesProcessed();
    if (worker.totalUnits(completed)) |total| self.jobs.observeTotal(worker.job, total) catch {};
    self.jobs.observeProgress(worker.job, completed) catch {};
    self.jobs.finish(worker.job, state) catch {};
    recordWorkerHistory(self, worker, state);
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
