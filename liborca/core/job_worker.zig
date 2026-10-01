const std = @import("std");
const codec = @import("../codec/root.zig");
const control = @import("control.zig");
const cover_art = @import("cover_art.zig");
const database = @import("../database/root.zig");
const job = @import("job.zig");
const library_pass = @import("../library/root.zig");
const metadata = @import("../metadata/root.zig");
const network = @import("../network/root.zig");
const object = @import("object.zig");
const providers = @import("../providers/root.zig");
const work = @import("work.zig");

const LibraryHandle = object.LibraryHandle;
const JobHandle = object.JobHandle;
const WorkHandle = work.WorkHandle;
const OwnedIdentity = network.client.OwnedIdentity;
const CredentialStore = providers.credentials.Store;

pub const AcoustIdUse = library_pass.matching.AcoustIdUse;
pub const BusyService = library_pass.matching.BusyService;
pub const SubmissionOutcome = library_pass.acoustid_submission.Outcome;
pub const CoverArtOutcome = cover_art.Outcome;

pub const ScanRequest = struct {
    /// Which registered root to walk. Null walks every enabled root.
    root_id: ?i64 = null,
    batch_size: usize = 256,
};

pub const ReconcileScope = union(enum) {
    whole_root,
    /// Directories relative to the root, in normal form: see
    /// `library.scanner.validateSubtree`.
    subtrees: []const []const u8,
};

pub const ReconcileRequest = struct {
    root_id: i64,
    scope: ReconcileScope = .whole_root,
    batch_size: usize = 256,
};

/// A reconcile request whose directories the runtime owns, validated and with
/// every directory already inside another one dropped. The caller's slices
/// need not outlive `startLibraryReconcile`.
pub const PendingReconcile = struct {
    arena: std.heap.ArenaAllocator,
    request: ReconcileRequest,

    pub fn create(allocator: std.mem.Allocator, request: ReconcileRequest) !*PendingReconcile {
        const self = try allocator.create(PendingReconcile);
        errdefer allocator.destroy(self);
        self.* = .{ .arena = .init(allocator), .request = request };
        errdefer self.arena.deinit();
        switch (request.scope) {
            .whole_root => {},
            .subtrees => |subtrees| self.request.scope = .{
                .subtrees = try outermostSubtrees(self.arena.allocator(), subtrees),
            },
        }
        return self;
    }

    pub fn destroy(self: *PendingReconcile) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
};

/// Copies of `subtrees` with duplicates and every directory inside another
/// listed one removed, since walking the outer one already walks it.
fn outermostSubtrees(arena: std.mem.Allocator, subtrees: []const []const u8) ![]const []const u8 {
    if (subtrees.len == 0) return error.InvalidReconcileDirectory;
    for (subtrees) |subtree| try library_pass.scanner.validateSubtree(subtree);
    const sorted = try arena.dupe([]const u8, subtrees);
    std.mem.sort([]const u8, sorted, {}, ancestorsFirst);
    var kept: std.ArrayList([]const u8) = .empty;
    for (sorted) |subtree| {
        if (kept.items.len != 0 and isWithin(subtree, kept.items[kept.items.len - 1])) continue;
        try kept.append(arena, try arena.dupe(u8, subtree));
    }
    return kept.items;
}

/// Byte order with `/` lowest, so a directory's descendants sort directly
/// after it and before any sibling whose name extends its own.
fn ancestorsFirst(_: void, left: []const u8, right: []const u8) bool {
    for (left[0..@min(left.len, right.len)], right[0..@min(left.len, right.len)]) |a, b| {
        if (a == b) continue;
        if (a == '/') return true;
        if (b == '/') return false;
        return a < b;
    }
    return left.len < right.len;
}

fn isWithin(subtree: []const u8, ancestor: []const u8) bool {
    if (!std.mem.startsWith(u8, subtree, ancestor)) return false;
    return subtree.len == ancestor.len or subtree[ancestor.len] == '/';
}

pub const BackfillRequest = struct {
    batch_size: usize = 256,
    /// Re-probe rows that already declare properties. See
    /// `library.PropertyBackfill.force` for why this is not the default.
    force: bool = false,
};

pub const AnalysisRequest = struct {
    /// Files per selected page and per bounded commit. Small on purpose: see
    /// `library.LibraryAnalysis.batch_size`.
    batch_size: usize = 32,
    /// Files decoded at once, at most `batch_size`. Null takes
    /// `analysisDefaultThreads`; see `library.LibraryAnalysis.threads`.
    threads: ?u16 = null,
};

pub const DuplicateScanRequest = struct {
    batch_size: usize = 256,
};

/// What an AcoustID submission job did.
pub const SubmissionStats = struct {
    files_examined: u64 = 0,
    submitted: u64 = 0,
    sent_as_metadata: u64 = 0,
    fingerprinted: u64 = 0,
    fingerprint_cache_hits: u64 = 0,
    fingerprint_failures: u64 = 0,
    rejected: u64 = 0,
    requests: u64 = 0,
    /// Why the job stopped; `completed` while it runs.
    outcome: SubmissionOutcome = .completed,
};

pub const MatchingHooks = struct {
    transport: ?network.client.Transport = null,
    /// AcoustID's transport; `transport` when null.
    acoustid_transport: ?network.client.Transport = null,
    /// The Cover Art Archive's transport; `transport` when null.
    cover_art_transport: ?network.client.Transport = null,
    clock: ?network.client.Clock = null,
    wall_clock: ?network.client.Clock = null,
    random: ?std.Random = null,
};

pub const AcoustIdSetup = struct {
    server: []const u8,
    client_key: ?[]const u8,
    credentials: ?CredentialStore,
};

pub const MatchingSetup = struct {
    io: std.Io,
    server: []const u8,
    identity: OwnedIdentity,
    hooks: MatchingHooks,
    scope: database.MatchScope,
    /// Null when the job looks nothing up on AcoustID.
    acoustid: ?AcoustIdSetup,
    cover_art_server: []const u8,
};

pub const SubmissionSetup = struct {
    io: std.Io,
    identity: OwnedIdentity,
    hooks: MatchingHooks,
    acoustid: AcoustIdSetup,
};

/// The application key a matching or submission job uses: the credential
/// store's `org.acoustid`/`client-key`, else the host's, also when the store
/// cannot be read. Read on the worker's thread; the caller frees it with
/// `wipeAndFree`.
fn resolveClientKey(allocator: std.mem.Allocator, setup: AcoustIdSetup) !?[]u8 {
    if (setup.credentials) |store| {
        const override = store.get(allocator, providers.acoustid.credential_service, providers.acoustid.client_key_account) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        if (override) |stored| {
            if (validAcoustIdKey(stored)) return stored;
            providers.credentials.wipeAndFree(allocator, stored);
        }
    }
    const key = setup.client_key orelse return null;
    return try allocator.dupe(u8, key);
}

pub fn validAcoustIdKey(key: []const u8) bool {
    if (key.len == 0 or key.len > providers.acoustid.max_key_bytes) return false;
    for (key) |byte| if (byte <= 0x20 or byte >= 0x7f) return false;
    return true;
}

/// A sealed plan and where each of its files lives, owned by the runtime until
/// a worker takes it.
pub const PendingTagWrite = struct {
    arena: std.heap.ArenaAllocator,
    library: LibraryHandle,
    plan: metadata.mutation.Plan,
    /// Index-aligned with `plan.actions`, allocated in `arena`.
    locations: []database.repository.PresentLocation,

    pub fn destroy(self: *PendingTagWrite) void {
        const allocator = self.arena.child_allocator;
        self.plan.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }
};

/// Re-reads one file Orca just rewrote, as a scan of its root would, and
/// reprojects it.
pub fn reobserve(
    allocator: std.mem.Allocator,
    io: std.Io,
    library_database: *database.LibraryDatabase,
    location: database.repository.PresentLocation,
) !void {
    var pass: library_pass.Projection = .{ .allocator = allocator, .library = library_database };
    var scanner: library_pass.Scanner = .{
        .allocator = allocator,
        .io = io,
        .files = &library_database.files,
        .locations = &library_database.locations,
        .observed_tags = &library_database.observed_tags,
        .write_lane = library_database.write_lane,
        .database_handle = library_database.database,
        .volume_id = location.volume_id,
        .root_id = location.root_id,
        .generation = location.generation,
        .projection = &pass,
    };
    defer scanner.deinit();
    _ = try scanner.observeFiles(&.{location.uri});
}

pub const MatchingRequest = struct {
    batch_size: usize,
    limit: ?u32,
    setup: MatchingSetup,
    /// False when the job only accepts matches or fetches a cover.
    lookups: bool = true,
    /// With a Release scope: then accept each of its files' one match at
    /// least this confident.
    accept_minimum_confidence: ?f32 = null,
    /// With a Release scope: then fetch its front cover.
    cover_art: bool = false,
};

pub const Request = union(enum) {
    scan: ScanRequest,
    /// The worker owns the request once started.
    reconcile: *PendingReconcile,
    projection,
    property_backfill: BackfillRequest,
    analysis: AnalysisRequest,
    duplicate_scan: DuplicateScanRequest,
    /// The worker owns the plan once started.
    mutation: *PendingTagWrite,
    metadata_lookup: MatchingRequest,
    acoustid_submission: SubmissionSetup,

    pub fn kind(self: Request) job.Kind {
        return switch (self) {
            .scan => .scan,
            .reconcile => .reconcile,
            .projection => .projection,
            .property_backfill => .property_backfill,
            .analysis => .analysis,
            .duplicate_scan => .duplicate_scan,
            .mutation => .mutation,
            .metadata_lookup => .metadata_lookup,
            .acoustid_submission => .acoustid_submission,
        };
    }

    pub fn batchSize(self: Request) ?usize {
        return switch (self) {
            .scan => |request| request.batch_size,
            .reconcile => |pending| pending.request.batch_size,
            .property_backfill => |request| request.batch_size,
            .analysis => |request| request.batch_size,
            .duplicate_scan => |request| request.batch_size,
            .metadata_lookup => |request| request.batch_size,
            .projection, .mutation, .acoustid_submission => null,
        };
    }
};

/// What a scan job observed, mirroring `scanner.Result` plus what the
/// projection made of it. A scan has no honest denominator until its walk
/// finishes, so there is a count of files processed and no total.
pub const ScanStats = struct {
    files_seen: u64 = 0,
    changed: u64 = 0,
    unchanged: u64 = 0,
    unsupported: u64 = 0,
    errors: u64 = 0,
    batches_committed: u64 = 0,
    cancelled: bool = false,
    folders_visited: u64 = 0,
    files_projected: u64 = 0,
    tracks_written: u64 = 0,
    releases_written: u64 = 0,
    /// Locations the job's completed walks no longer found.
    marked_missing: u64 = 0,
    /// A root was not walked because it is no longer on the volume the
    /// Library recorded for it, as when its drive is not mounted.
    volume_changed: bool = false,
};

/// The same counters as the worker publishes them: monotonic atomics, so the
/// control lane may read a running scan's progress without stopping it.
const LiveScanStats = struct {
    files_seen: std.atomic.Value(u64) = .init(0),
    changed: std.atomic.Value(u64) = .init(0),
    unchanged: std.atomic.Value(u64) = .init(0),
    unsupported: std.atomic.Value(u64) = .init(0),
    errors: std.atomic.Value(u64) = .init(0),
    batches_committed: std.atomic.Value(u64) = .init(0),
    cancelled: std.atomic.Value(bool) = .init(false),
    folders_visited: std.atomic.Value(u64) = .init(0),
    files_projected: std.atomic.Value(u64) = .init(0),
    tracks_written: std.atomic.Value(u64) = .init(0),
    releases_written: std.atomic.Value(u64) = .init(0),
    marked_missing: std.atomic.Value(u64) = .init(0),

    fn read(self: *const LiveScanStats, in_flight: u64) ScanStats {
        return .{
            .files_seen = self.files_seen.load(.acquire) + in_flight,
            .changed = self.changed.load(.acquire),
            .unchanged = self.unchanged.load(.acquire),
            .unsupported = self.unsupported.load(.acquire),
            .errors = self.errors.load(.acquire),
            .batches_committed = self.batches_committed.load(.acquire),
            .cancelled = self.cancelled.load(.acquire),
            .folders_visited = self.folders_visited.load(.acquire),
            .files_projected = self.files_projected.load(.acquire),
            .tracks_written = self.tracks_written.load(.acquire),
            .releases_written = self.releases_written.load(.acquire),
            .marked_missing = self.marked_missing.load(.acquire),
        };
    }
};

const DuplicateStats = struct {
    files_seen: u64,
    exact: u64,
    likely: u64,
    unique: u64,
    uncomparable: u64,
    errors: u64,
    batches_committed: u64,
    buckets_truncated: u64,
    comparisons: u64,
    cancelled: bool,

    /// The mapping `orca.h` documents for `orca_library_start_duplicate_scan`.
    fn scanStats(self: DuplicateStats) ScanStats {
        return .{
            .files_seen = self.files_seen,
            .changed = self.exact + self.likely,
            .unchanged = self.unique,
            .unsupported = self.uncomparable,
            .errors = self.errors,
            .batches_committed = self.batches_committed,
            .cancelled = self.cancelled,
            .folders_visited = self.buckets_truncated,
            .files_projected = self.comparisons,
            .tracks_written = self.exact,
            .releases_written = self.likely,
        };
    }
};

const LiveDuplicateStats = struct {
    files_seen: std.atomic.Value(u64) = .init(0),
    exact: std.atomic.Value(u64) = .init(0),
    likely: std.atomic.Value(u64) = .init(0),
    unique: std.atomic.Value(u64) = .init(0),
    uncomparable: std.atomic.Value(u64) = .init(0),
    errors: std.atomic.Value(u64) = .init(0),
    batches_committed: std.atomic.Value(u64) = .init(0),
    buckets_truncated: std.atomic.Value(u64) = .init(0),
    comparisons: std.atomic.Value(u64) = .init(0),
    cancelled: std.atomic.Value(bool) = .init(false),

    fn read(self: *const LiveDuplicateStats, in_flight: u64) DuplicateStats {
        return .{
            .files_seen = self.files_seen.load(.acquire) + in_flight,
            .exact = self.exact.load(.acquire),
            .likely = self.likely.load(.acquire),
            .unique = self.unique.load(.acquire),
            .uncomparable = self.uncomparable.load(.acquire),
            .errors = self.errors.load(.acquire),
            .batches_committed = self.batches_committed.load(.acquire),
            .buckets_truncated = self.buckets_truncated.load(.acquire),
            .comparisons = self.comparisons.load(.acquire),
            .cancelled = self.cancelled.load(.acquire),
        };
    }
};

/// What a matching job did with the Tracks it examined. `requests` and
/// `cache_hits` are MusicBrainz's.
pub const MatchStats = struct {
    tracks_examined: u64 = 0,
    matched: u64 = 0,
    unmatched: u64 = 0,
    insufficient_evidence: u64 = 0,
    refused: u64 = 0,
    proposals_stored: u64 = 0,
    requests: u64 = 0,
    cache_hits: u64 = 0,
    fingerprinted: u64 = 0,
    fingerprint_cache_hits: u64 = 0,
    fingerprint_failures: u64 = 0,
    acoustid_requests: u64 = 0,
    acoustid_cache_hits: u64 = 0,
    acoustid_refused: u64 = 0,
    acoustid: AcoustIdUse = .off,
    cancelled: bool = false,
    busy: BusyService = .none,
    /// Matches the job accepted after its lookups.
    accepted: u64 = 0,
    cover_art: CoverArtOutcome = .not_requested,
};

const LiveMatchStats = struct {
    tracks_examined: std.atomic.Value(u64) = .init(0),
    matched: std.atomic.Value(u64) = .init(0),
    unmatched: std.atomic.Value(u64) = .init(0),
    insufficient_evidence: std.atomic.Value(u64) = .init(0),
    refused: std.atomic.Value(u64) = .init(0),
    proposals_stored: std.atomic.Value(u64) = .init(0),
    requests: std.atomic.Value(u64) = .init(0),
    cache_hits: std.atomic.Value(u64) = .init(0),
    fingerprinted: std.atomic.Value(u64) = .init(0),
    fingerprint_cache_hits: std.atomic.Value(u64) = .init(0),
    fingerprint_failures: std.atomic.Value(u64) = .init(0),
    acoustid_requests: std.atomic.Value(u64) = .init(0),
    acoustid_cache_hits: std.atomic.Value(u64) = .init(0),
    acoustid_refused: std.atomic.Value(u64) = .init(0),
    acoustid: std.atomic.Value(AcoustIdUse) = .init(.off),
    cancelled: std.atomic.Value(bool) = .init(false),
    busy: std.atomic.Value(BusyService) = .init(.none),
    accepted: std.atomic.Value(u64) = .init(0),
    cover_art: std.atomic.Value(CoverArtOutcome) = .init(.not_requested),
    /// A running matching pass's counters.
    progress: library_pass.matching.Progress = .{},

    fn read(self: *const LiveMatchStats) MatchStats {
        const progress = &self.progress;
        return .{
            .tracks_examined = self.tracks_examined.load(.acquire) + progress.tracks_seen.load(.acquire),
            .matched = self.matched.load(.acquire) + progress.matched.load(.acquire),
            .unmatched = self.unmatched.load(.acquire),
            .insufficient_evidence = self.insufficient_evidence.load(.acquire),
            .refused = self.refused.load(.acquire),
            .proposals_stored = self.proposals_stored.load(.acquire),
            .requests = self.requests.load(.acquire),
            .cache_hits = self.cache_hits.load(.acquire),
            .fingerprinted = self.fingerprinted.load(.acquire) + progress.fingerprinted.load(.acquire),
            .fingerprint_cache_hits = self.fingerprint_cache_hits.load(.acquire),
            .fingerprint_failures = self.fingerprint_failures.load(.acquire),
            .acoustid_requests = self.acoustid_requests.load(.acquire),
            .acoustid_cache_hits = self.acoustid_cache_hits.load(.acquire),
            .acoustid_refused = self.acoustid_refused.load(.acquire),
            .acoustid = self.acoustid.load(.acquire),
            .cancelled = self.cancelled.load(.acquire),
            .busy = self.busy.load(.acquire),
            .accepted = self.accepted.load(.acquire),
            .cover_art = self.cover_art.load(.acquire),
        };
    }
};

const LiveSubmissionStats = struct {
    /// Written by the worker just before it finishes; read only after.
    result: SubmissionStats = .{},
    cancelled: std.atomic.Value(bool) = .init(false),
};

pub const Stats = union(enum) {
    scan: LiveScanStats,
    duplicates: LiveDuplicateStats,
    matching: LiveMatchStats,
    submission: LiveSubmissionStats,

    pub fn init(request: Request) Stats {
        return switch (request) {
            .scan, .reconcile, .projection, .property_backfill, .analysis, .mutation => .{ .scan = .{} },
            .duplicate_scan => .{ .duplicates = .{} },
            .metadata_lookup => .{ .matching = .{} },
            .acoustid_submission => .{ .submission = .{} },
        };
    }
};

pub const Origin = enum { host, watcher };

/// One background worker behind a `JobHandle`.
///
/// Threading contract, the same one `core/work.zig` states: the worker thread
/// touches only this struct, the Library database it was handed and the
/// runtime's `host_signal`. It never resolves a handle, never reads a
/// `handle.Pool`, and touches nothing else of the runtime. The control lane
/// cancels it, joins it through `work.Registry`, and only then reads anything
/// that is not an atomic here.
pub const JobWorker = struct {
    allocator: std.mem.Allocator,
    registration: *work.Registration,
    work_handle: WorkHandle,
    job: JobHandle,
    library: LibraryHandle,
    /// Borrowed. The control lane joins this worker before the Library it
    /// belongs to can be closed, which is what makes the raw pointer safe.
    database: *database.LibraryDatabase,
    request: Request,
    origin: Origin = .host,
    /// The worker's own `std.Io`. The ABI's belongs to the calling thread and
    /// is never borrowed across a thread boundary.
    threaded: std.Io.Threaded = .init_single_threaded,
    /// What the scanner polls. Set by `cancelJob` and by every runtime path
    /// that drains workers, because the registry flag alone cannot reach
    /// inside a filesystem walk.
    token: library_pass.CancellationToken = .{},
    /// Files the *current* root's walk has reached, written by the scanner.
    progress: std.atomic.Value(u64) = .init(0),
    stats: Stats,
    failed: std.atomic.Value(bool) = .init(false),
    volume_changed: std.atomic.Value(bool) = .init(false),
    /// Control lane only: the thread has been joined and the record finalized.
    retired: bool = false,
    /// Raised after `finish`, which is safe only because the control lane
    /// joins the thread, not merely waits for `finish`, before it frees this
    /// struct or the runtime.
    host_signal: *control.HostSignal,

    pub fn run(self: *JobWorker) void {
        defer {
            self.threaded.deinit();
            self.registration.finish();
            self.host_signal.raise();
        }
        switch (self.request) {
            .scan => |request| self.runScan(request),
            .reconcile => |pending| self.runReconcile(pending.request),
            .projection => self.runProjection(),
            .property_backfill => |request| self.runPropertyBackfill(request),
            .analysis => |request| self.runAnalysis(request),
            .duplicate_scan => |request| self.runDuplicateScan(request),
            .mutation => |pending| self.runTagWrite(pending),
            .metadata_lookup => |request| self.runMatching(request),
            .acoustid_submission => |setup| self.runSubmission(setup),
        }
    }

    pub fn kind(self: *const JobWorker) job.Kind {
        return self.request.kind();
    }

    pub fn pendingReconcile(self: *const JobWorker) ?*PendingReconcile {
        return switch (self.request) {
            .reconcile => |pending| pending,
            else => null,
        };
    }

    pub fn tagWrite(self: *const JobWorker) ?*PendingTagWrite {
        return switch (self.request) {
            .mutation => |pending| pending,
            else => null,
        };
    }

    fn cancelled(self: *const JobWorker) bool {
        return self.token.isCancelled() or self.registration.cancellationRequested();
    }

    fn runProjection(self: *JobWorker) void {
        var pass: library_pass.Projection = .{
            .allocator = self.allocator,
            .library = self.database,
        };
        const result = pass.run(.all) catch {
            self.failed.store(true, .release);
            return;
        };
        self.noteProjection(result);
    }

    /// Repairs `files` rows with missing properties and reprojects each batch.
    ///
    /// The reprojection is not optional and not the caller's to sequence:
    /// `tracks.duration_ms` is *derived* from the file rows, so a backfill
    /// that repaired the files and left the Tracks reading zero would have
    /// fixed nothing a user can see. It is scoped to the repaired ids, exactly
    /// as a scan batch is, so repairing 104 rows reprojects the handful of
    /// folders they live in rather than the whole library.
    fn runPropertyBackfill(self: *JobWorker, request: BackfillRequest) void {
        const stats = &self.stats.scan;
        var pass: library_pass.Projection = .{
            .allocator = self.allocator,
            .library = self.database,
        };
        var backfill: library_pass.PropertyBackfill = .{
            .allocator = self.allocator,
            .io = self.threaded.io(),
            .files = &self.database.files,
            .health_issues = &self.database.health_issues,
            .write_lane = self.database.write_lane,
            .database_handle = self.database.database,
            .cancellation = &self.token,
            .progress = &self.progress,
            .batch_size = request.batch_size,
            .force = request.force,
            .projection = &pass,
        };
        defer backfill.deinit();
        const result = backfill.run() catch {
            self.failed.store(true, .release);
            return;
        };
        self.progress.store(0, .release);
        _ = stats.files_seen.fetchAdd(result.files_seen, .acq_rel);
        _ = stats.changed.fetchAdd(result.changed, .acq_rel);
        _ = stats.unchanged.fetchAdd(result.unchanged, .acq_rel);
        _ = stats.unsupported.fetchAdd(result.unsupported, .acq_rel);
        _ = stats.errors.fetchAdd(result.errors, .acq_rel);
        _ = stats.batches_committed.fetchAdd(result.batches_committed, .acq_rel);
        if (result.cancelled) stats.cancelled.store(true, .release);
        self.noteProjection(result.projection);
    }

    /// Decodes every file the Library has not measured yet and stores the
    /// result.
    ///
    /// Nothing is reprojected afterwards, and that is not an omission: a
    /// backfill repairs `files` columns the projection derives Tracks from,
    /// while this writes analysis results and an audio hash, which the
    /// projection does not read. Reprojecting here would be work with no
    /// output.
    fn runAnalysis(self: *JobWorker, request: AnalysisRequest) void {
        const stats = &self.stats.scan;
        var pass: library_pass.LibraryAnalysis = .{
            .allocator = self.allocator,
            .io = self.threaded.io(),
            .files = &self.database.files,
            .analysis_cache = &self.database.analysis_cache,
            .health_issues = &self.database.health_issues,
            .write_lane = self.database.write_lane,
            .database_handle = self.database.database,
            .cancellation = &self.token,
            .progress = &self.progress,
            .batch_size = request.batch_size,
            .threads = request.threads,
        };
        const result = pass.run() catch {
            self.failed.store(true, .release);
            return;
        };
        self.progress.store(0, .release);
        _ = stats.files_seen.fetchAdd(result.files_seen, .acq_rel);
        _ = stats.changed.fetchAdd(result.changed, .acq_rel);
        _ = stats.unchanged.fetchAdd(result.unchanged, .acq_rel);
        _ = stats.unsupported.fetchAdd(result.unsupported, .acq_rel);
        _ = stats.errors.fetchAdd(result.errors, .acq_rel);
        _ = stats.batches_committed.fetchAdd(result.batches_committed, .acq_rel);
        if (result.cancelled) stats.cancelled.store(true, .release);
    }

    /// Finds the audio the Library holds more than once.
    ///
    /// Nothing is decoded and no file is opened: the pass compares
    /// measurements the analysis job already stored, through two indexes. That
    /// is why it is a job of its own rather than a phase of the analysis --
    /// the measuring takes hours and the comparing takes seconds, and a person
    /// who has analyzed their library should not have to analyze it again to
    /// ask the question a second time.
    fn runDuplicateScan(self: *JobWorker, request: DuplicateScanRequest) void {
        const stats = &self.stats.duplicates;
        var pass: library_pass.DuplicateScan = .{
            .allocator = self.allocator,
            .files = &self.database.files,
            .locations = &self.database.locations,
            .analysis_cache = &self.database.analysis_cache,
            .health_issues = &self.database.health_issues,
            .write_lane = self.database.write_lane,
            .database_handle = self.database.database,
            .cancellation = &self.token,
            .progress = &self.progress,
            .batch_size = request.batch_size,
        };
        const result = pass.run() catch {
            self.failed.store(true, .release);
            return;
        };
        self.progress.store(0, .release);
        _ = stats.files_seen.fetchAdd(result.files_seen, .acq_rel);
        _ = stats.exact.fetchAdd(result.exact, .acq_rel);
        _ = stats.likely.fetchAdd(result.likely, .acq_rel);
        _ = stats.unique.fetchAdd(result.unique, .acq_rel);
        _ = stats.uncomparable.fetchAdd(result.uncomparable, .acq_rel);
        _ = stats.errors.fetchAdd(result.errors, .acq_rel);
        _ = stats.batches_committed.fetchAdd(result.batches_committed, .acq_rel);
        _ = stats.buckets_truncated.fetchAdd(result.buckets_truncated, .acq_rel);
        _ = stats.comparisons.fetchAdd(result.comparisons, .acq_rel);
        if (result.cancelled) stats.cancelled.store(true, .release);
    }

    fn runMatching(self: *JobWorker, request: MatchingRequest) void {
        const stats = &self.stats.matching;
        const setup = request.setup;
        var standard: network.StandardTransport = .init(self.allocator, setup.io);
        defer standard.deinit();
        var system_clock: network.SystemClock = .{ .io = setup.io };
        const random_source: std.Random.IoSource = .{ .io = setup.io };
        const services: Services = .{
            .transport = setup.hooks.transport orelse standard.transport(),
            .clock = setup.hooks.clock orelse system_clock.clock(),
            .wall_clock = setup.hooks.wall_clock orelse system_clock.wallClock(),
            .random = setup.hooks.random orelse random_source.interface(),
            .shared_state = providers.shared_state.store(&self.database.provider_state),
        };
        if (request.lookups and !self.runLookups(request, services)) return;
        const release_id = switch (setup.scope) {
            .release => |id| id,
            .library, .track => return,
        };
        if (request.accept_minimum_confidence) |minimum| {
            if (self.cancelled()) return stats.cancelled.store(true, .release);
            const accepted = self.database.identification_proposals.acceptConfidentInRelease(self.allocator, minimum, release_id) catch {
                self.failed.store(true, .release);
                return;
            };
            stats.accepted.store(accepted, .release);
        }
        if (request.cover_art) {
            if (self.cancelled()) return stats.cancelled.store(true, .release);
            self.runCoverArt(setup, services, release_id);
        }
    }

    const Services = struct {
        transport: network.client.Transport,
        clock: network.client.Clock,
        wall_clock: network.client.Clock,
        random: std.Random,
        shared_state: network.client.StateStore,
    };

    fn runCoverArt(self: *JobWorker, setup: MatchingSetup, services: Services, release_id: i64) void {
        const stats = &self.stats.matching;
        var gateway: network.Gateway = .{
            .transport = setup.hooks.cover_art_transport orelse services.transport,
            .clock = services.clock,
            .wall_clock = services.wall_clock,
            .random = services.random,
            .config = .{
                .identity = setup.identity.view(),
                .max_response_bytes = providers.coverartarchive.max_image_bytes,
            },
            .cancel = &self.registration.cancel,
            .sharing = .{ .store = services.shared_state, .service = providers.coverartarchive.service },
        };
        defer gateway.releaseLease();
        var archive: providers.coverartarchive.CoverArtArchive = .{
            .gateway = &gateway,
            .server = setup.cover_art_server,
        };
        var fetch: cover_art.Fetch = .{
            .allocator = self.allocator,
            .io = self.threaded.io(),
            .library = self.database,
            .archive = &archive,
            .wall_clock = services.wall_clock,
        };
        const outcome = fetch.run(release_id) catch {
            self.failed.store(true, .release);
            return;
        };
        stats.cover_art.store(outcome, .release);
        switch (outcome) {
            .cancelled => stats.cancelled.store(true, .release),
            .refused, .unavailable, .busy => self.failed.store(true, .release),
            .not_requested, .embedded, .fetched, .cached, .cached_miss, .not_found, .no_release_id => {},
        }
    }

    /// False when the job has to stop here: failed or cancelled.
    fn runLookups(self: *JobWorker, request: MatchingRequest, services: Services) bool {
        const stats = &self.stats.matching;
        const setup = request.setup;
        const clock = services.clock;
        const wall_clock = services.wall_clock;
        const random = services.random;
        const shared_state = services.shared_state;
        var gateway: network.Gateway = .{
            .transport = services.transport,
            .clock = clock,
            .wall_clock = wall_clock,
            .random = random,
            .config = .{ .identity = setup.identity.view() },
            .cancel = &self.registration.cancel,
            .sharing = .{ .store = shared_state, .service = providers.musicbrainz.service },
        };
        defer gateway.releaseLease();
        var musicbrainz: providers.musicbrainz.MusicBrainz = .{
            .gateway = &gateway,
            .cache = &self.database.provider_cache,
            .wall_clock = wall_clock,
            .server = setup.server,
        };
        var acoustid_gateway: network.Gateway = .{
            .transport = setup.hooks.acoustid_transport orelse services.transport,
            .clock = clock,
            .wall_clock = wall_clock,
            .random = random,
            .config = .{ .identity = setup.identity.view() },
            .cancel = &self.registration.cancel,
            .sharing = .{ .store = shared_state, .service = providers.acoustid.service },
        };
        defer acoustid_gateway.releaseLease();
        const client_key = if (setup.acoustid) |acoustid| resolveClientKey(self.allocator, acoustid) catch {
            self.failed.store(true, .release);
            return false;
        } else null;
        defer if (client_key) |key| providers.credentials.wipeAndFree(self.allocator, key);
        var acoustid: ?providers.acoustid.AcoustId = if (client_key) |key| .{
            .gateway = &acoustid_gateway,
            .cache = &self.database.provider_cache,
            .wall_clock = wall_clock,
            .server = setup.acoustid.?.server,
            .client_key = key,
        } else null;
        stats.acoustid.store(if (acoustid != null) .searched else if (setup.acoustid == null) .off else .no_client_key, .release);
        const codecs = codec.CodecRegistry.builtins();
        var pass: library_pass.LibraryMatching = .{
            .allocator = self.allocator,
            .proposals = &self.database.identification_proposals,
            .musicbrainz = &musicbrainz,
            .acoustid = if (acoustid) |*service| service else null,
            .acoustid_use = stats.acoustid.load(.acquire),
            .fingerprinter = .{
                .allocator = self.allocator,
                .io = self.threaded.io(),
                .codecs = &codecs,
                .cache = &self.database.analysis_cache,
                .cancellation = &self.token,
            },
            .cancellation = &self.token,
            .progress = &stats.progress,
            .batch_size = request.batch_size,
            .limit = request.limit,
            .scope = setup.scope,
        };
        const result = pass.run() catch {
            self.failed.store(true, .release);
            return false;
        };
        stats.progress.tracks_seen.store(0, .release);
        stats.progress.matched.store(0, .release);
        stats.progress.fingerprinted.store(0, .release);
        _ = stats.tracks_examined.fetchAdd(result.tracks_seen, .acq_rel);
        _ = stats.matched.fetchAdd(result.matched, .acq_rel);
        _ = stats.unmatched.fetchAdd(result.unmatched, .acq_rel);
        _ = stats.insufficient_evidence.fetchAdd(result.insufficient, .acq_rel);
        _ = stats.refused.fetchAdd(result.refused, .acq_rel);
        _ = stats.proposals_stored.fetchAdd(result.proposals_stored, .acq_rel);
        _ = stats.requests.fetchAdd(result.requests_answered, .acq_rel);
        _ = stats.cache_hits.fetchAdd(result.cache_hits, .acq_rel);
        _ = stats.fingerprinted.fetchAdd(result.fingerprinted, .acq_rel);
        _ = stats.fingerprint_cache_hits.fetchAdd(result.fingerprint_cache_hits, .acq_rel);
        _ = stats.fingerprint_failures.fetchAdd(result.fingerprint_failures, .acq_rel);
        _ = stats.acoustid_requests.fetchAdd(result.acoustid_requests, .acq_rel);
        _ = stats.acoustid_cache_hits.fetchAdd(result.acoustid_cache_hits, .acq_rel);
        _ = stats.acoustid_refused.fetchAdd(result.acoustid_refused, .acq_rel);
        stats.acoustid.store(result.acoustid, .release);
        stats.busy.store(result.busy, .release);
        if (result.cancelled) stats.cancelled.store(true, .release);
        if (result.unavailable or result.busy != .none) self.failed.store(true, .release);
        return !result.cancelled and !result.unavailable and result.busy == .none;
    }

    fn runSubmission(self: *JobWorker, setup: SubmissionSetup) void {
        const stats = &self.stats.submission;
        var standard: network.StandardTransport = .init(self.allocator, setup.io);
        defer standard.deinit();
        var system_clock: network.SystemClock = .{ .io = setup.io };
        const wall_clock = setup.hooks.wall_clock orelse system_clock.wallClock();
        const random_source: std.Random.IoSource = .{ .io = setup.io };
        var gateway: network.Gateway = .{
            .transport = setup.hooks.acoustid_transport orelse setup.hooks.transport orelse standard.transport(),
            .clock = setup.hooks.clock orelse system_clock.clock(),
            .wall_clock = wall_clock,
            .random = setup.hooks.random orelse random_source.interface(),
            .config = .{ .identity = setup.identity.view() },
            .cancel = &self.registration.cancel,
            .sharing = .{
                .store = providers.shared_state.store(&self.database.provider_state),
                .service = providers.acoustid.service,
            },
        };
        defer gateway.releaseLease();
        const client_key = resolveClientKey(self.allocator, setup.acoustid) catch {
            self.failed.store(true, .release);
            return;
        } orelse {
            stats.result = .{ .outcome = .needs_client_key };
            self.failed.store(true, .release);
            return;
        };
        defer providers.credentials.wipeAndFree(self.allocator, client_key);
        var acoustid: providers.acoustid.AcoustId = .{
            .gateway = &gateway,
            .cache = &self.database.provider_cache,
            .wall_clock = wall_clock,
            .server = setup.acoustid.server,
            .client_key = client_key,
        };
        const codecs = codec.CodecRegistry.builtins();
        var pass: library_pass.AcoustIdSubmission = .{
            .allocator = self.allocator,
            .submissions = &self.database.acoustid_submissions,
            .acoustid = &acoustid,
            .fingerprinter = .{
                .allocator = self.allocator,
                .io = self.threaded.io(),
                .codecs = &codecs,
                .cache = &self.database.analysis_cache,
                .cancellation = &self.token,
            },
            .credentials = setup.acoustid.credentials,
            .cancellation = &self.token,
            .progress = &self.progress,
        };
        const result = pass.run() catch {
            self.failed.store(true, .release);
            return;
        };
        stats.result = .{
            .files_examined = result.files_examined,
            .submitted = result.submitted,
            .sent_as_metadata = result.sent_as_metadata,
            .fingerprinted = result.fingerprinted,
            .fingerprint_cache_hits = result.fingerprint_cache_hits,
            .fingerprint_failures = result.fingerprint_failures,
            .rejected = result.rejected,
            .requests = result.requests,
            .outcome = result.outcome,
        };
        switch (result.outcome) {
            .completed => {},
            .cancelled => stats.cancelled.store(true, .release),
            .needs_client_key, .invalid_client_key, .needs_user_key, .invalid_user_key, .unavailable, .busy => self.failed.store(true, .release),
        }
    }

    fn runScan(self: *JobWorker, request: ScanRequest) void {
        const io = self.threaded.io();
        var roots = self.database.library_roots.list(self.allocator) catch {
            self.failed.store(true, .release);
            return;
        };
        defer roots.deinit();
        for (roots.items) |root| {
            if (self.cancelled()) {
                self.stats.scan.cancelled.store(true, .release);
                break;
            }
            if (!root.enabled) continue;
            if (request.root_id) |wanted| {
                if (root.id != wanted) continue;
            }
            self.scanRoot(io, root, request.batch_size) catch self.failed.store(true, .release);
        }
    }

    fn runReconcile(self: *JobWorker, request: ReconcileRequest) void {
        const io = self.threaded.io();
        var roots = self.database.library_roots.list(self.allocator) catch {
            self.failed.store(true, .release);
            return;
        };
        defer roots.deinit();
        const root = for (roots.items) |candidate| {
            if (candidate.id == request.root_id and candidate.enabled) break candidate;
        } else {
            self.failed.store(true, .release);
            return;
        };
        switch (request.scope) {
            .whole_root => self.scanRoot(io, root, request.batch_size) catch self.failed.store(true, .release),
            .subtrees => |subtrees| self.reconcileSubtrees(io, root, subtrees, request.batch_size) catch self.failed.store(true, .release),
        }
    }

    fn rootScanner(
        self: *JobWorker,
        io: std.Io,
        root: database.repository.LibraryRoot,
        generation: i64,
        batch_size: usize,
        pass: *library_pass.Projection,
    ) library_pass.Scanner {
        return .{
            .allocator = self.allocator,
            .io = io,
            .files = &self.database.files,
            .locations = &self.database.locations,
            .observed_tags = &self.database.observed_tags,
            .write_lane = self.database.write_lane,
            .database_handle = self.database.database,
            .volume_id = root.volume_id,
            .root_id = root.id,
            .generation = generation,
            .cancellation = &self.token,
            .batch_size = batch_size,
            .progress = &self.progress,
            .projection = pass,
        };
    }

    /// One root, walked exactly as `orca-cli scan` walks it: observe, project
    /// each committed batch, close the run, and — only on a run that finished —
    /// name the locations the walk never reached.
    fn scanRoot(
        self: *JobWorker,
        io: std.Io,
        root: database.repository.LibraryRoot,
        batch_size: usize,
    ) !void {
        self.progress.store(0, .release);
        try self.requireRecordedVolume(io, root);
        const scan_run = try self.database.scan_runs.begin(root.id);
        var pass: library_pass.Projection = .{
            .allocator = self.allocator,
            .library = self.database,
        };
        var scanner = self.rootScanner(io, root, scan_run.generation, batch_size, &pass);
        defer scanner.deinit();
        const result = try scanner.scan(root.path);
        try self.database.scan_runs.finish(
            scan_run.id,
            if (result.cancelled) .cancelled else .completed,
            scanCounters(result),
        );
        // Never on a cancelled run: a partial walk must not mark the files it
        // did not reach as missing.
        const marked_missing = if (result.cancelled) 0 else try self.database.files.markMissingBelowGeneration(
            root.id,
            scan_run.generation,
        );
        self.noteScan(result);
        _ = self.stats.scan.marked_missing.fetchAdd(marked_missing, .acq_rel);
    }

    /// A root whose path now resolves to another volume, as the mount point
    /// of an unmounted drive does, is neither walked nor swept: the sweep
    /// would mark every file on the drive missing.
    fn requireRecordedVolume(self: *JobWorker, io: std.Io, root: database.repository.LibraryRoot) !void {
        const recorded = try self.database.recordedVolumeKey(self.allocator, root.volume_id);
        defer if (recorded) |key| self.allocator.free(key);
        if (library_pass.volume_check.onRecordedVolume(self.allocator, io, root.path, recorded)) return;
        _ = self.stats.scan.errors.fetchAdd(1, .acq_rel);
        self.volume_changed.store(true, .release);
        return error.RootVolumeChanged;
    }

    /// Walks each directory under one run of the root, then sweeps only the
    /// directories whose walk finished: a directory that failed or was cut
    /// short keeps every location it holds.
    fn reconcileSubtrees(
        self: *JobWorker,
        io: std.Io,
        root: database.repository.LibraryRoot,
        subtrees: []const []const u8,
        batch_size: usize,
    ) !void {
        const stats = &self.stats.scan;
        try self.requireRecordedVolume(io, root);
        const walked = try self.allocator.alloc(bool, subtrees.len);
        defer self.allocator.free(walked);
        @memset(walked, false);
        const scan_run = try self.database.scan_runs.begin(root.id);
        var pass: library_pass.Projection = .{
            .allocator = self.allocator,
            .library = self.database,
        };
        var scanner = self.rootScanner(io, root, scan_run.generation, batch_size, &pass);
        defer scanner.deinit();
        var totals: library_pass.scanner.Result = .{};
        var walk_failed = false;
        for (subtrees, walked) |subtree, *completed| {
            if (self.cancelled()) {
                totals.cancelled = true;
                break;
            }
            self.progress.store(0, .release);
            const result = scanner.scanSubtree(root.path, subtree) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    walk_failed = true;
                    totals.errors += 1;
                    continue;
                },
            };
            accumulate(&totals, result);
            if (result.cancelled) break;
            completed.* = true;
        }
        try self.database.scan_runs.finish(
            scan_run.id,
            if (totals.cancelled) .cancelled else if (walk_failed) .failed else .completed,
            scanCounters(totals),
        );
        if (!totals.cancelled) {
            for (subtrees, walked) |subtree, completed| {
                if (!completed) continue;
                const prefix = try library_pass.scanner.pathUnder(self.allocator, root.path, subtree);
                defer self.allocator.free(prefix);
                _ = stats.marked_missing.fetchAdd(try self.database.files.markMissingBelowGenerationUnder(
                    root.volume_id,
                    root.id,
                    scan_run.generation,
                    prefix,
                ), .acq_rel);
            }
        }
        self.noteScan(totals);
        if (walk_failed) self.failed.store(true, .release);
    }

    fn noteScan(self: *JobWorker, result: library_pass.scanner.Result) void {
        const stats = &self.stats.scan;
        self.progress.store(0, .release);
        _ = stats.files_seen.fetchAdd(result.files_seen, .acq_rel);
        _ = stats.changed.fetchAdd(result.changed, .acq_rel);
        _ = stats.unchanged.fetchAdd(result.unchanged, .acq_rel);
        _ = stats.unsupported.fetchAdd(result.unsupported, .acq_rel);
        _ = stats.errors.fetchAdd(result.errors, .acq_rel);
        _ = stats.batches_committed.fetchAdd(result.batches_committed, .acq_rel);
        if (result.cancelled) stats.cancelled.store(true, .release);
        self.noteProjection(result.projection);
    }

    fn runTagWrite(self: *JobWorker, pending: *PendingTagWrite) void {
        const stats = &self.stats.scan;
        const io = self.threaded.io();
        _ = stats.files_seen.fetchAdd(pending.plan.actions.len, .acq_rel);
        var executor: metadata.executor.Executor = .{
            .allocator = self.allocator,
            .io = io,
            .journal = &self.database.mutation_journal,
            .backup_directory = self.database.backup_directory,
        };
        if (executor.executePlan(&pending.plan, pending.plan.id)) {
            _ = stats.changed.fetchAdd(pending.plan.actions.len, .acq_rel);
        } else |_| {
            _ = stats.errors.fetchAdd(1, .acq_rel);
            self.failed.store(true, .release);
        }
        for (pending.locations) |location| {
            reobserve(self.allocator, io, self.database, location) catch {
                _ = stats.errors.fetchAdd(1, .acq_rel);
            };
        }
    }

    fn noteProjection(self: *JobWorker, result: library_pass.projection.Result) void {
        const stats = &self.stats.scan;
        _ = stats.folders_visited.fetchAdd(result.folders_visited, .acq_rel);
        _ = stats.files_projected.fetchAdd(result.files_projected, .acq_rel);
        _ = stats.tracks_written.fetchAdd(result.tracks_written, .acq_rel);
        _ = stats.releases_written.fetchAdd(result.releases_written, .acq_rel);
    }

    pub fn filesProcessed(self: *const JobWorker) u64 {
        return switch (self.stats) {
            .matching => self.matchStats().tracks_examined,
            .submission => self.submissionStats().files_examined,
            .scan => |*stats| stats.files_seen.load(.acquire) + self.progress.load(.acquire),
            .duplicates => |*stats| stats.files_seen.load(.acquire) + self.progress.load(.acquire),
        };
    }

    pub fn scanStats(self: *const JobWorker) ScanStats {
        return switch (self.stats) {
            .scan => |*stats| stats: {
                var read = stats.read(self.progress.load(.acquire));
                read.volume_changed = self.volume_changed.load(.acquire);
                break :stats read;
            },
            .duplicates => |*stats| stats.read(self.progress.load(.acquire)).scanStats(),
            .matching => .{},
            .submission => |*stats| .{ .cancelled = stats.cancelled.load(.acquire) },
        };
    }

    pub fn matchStats(self: *const JobWorker) MatchStats {
        return switch (self.stats) {
            .matching => |*stats| stats.read(),
            .scan, .duplicates, .submission => .{},
        };
    }

    pub fn submissionStats(self: *const JobWorker) SubmissionStats {
        if (self.retired or self.registration.isFinished()) return switch (self.stats) {
            .submission => |*stats| stats.result,
            .scan, .duplicates, .matching => .{},
        };
        return .{ .files_examined = self.progress.load(.acquire) };
    }

    pub fn wasCancelled(self: *const JobWorker) bool {
        return switch (self.stats) {
            .scan => |*stats| stats.cancelled.load(.acquire),
            .duplicates => |*stats| stats.cancelled.load(.acquire),
            .matching => |*stats| stats.cancelled.load(.acquire),
            .submission => |*stats| stats.cancelled.load(.acquire),
        };
    }
};

fn scanCounters(result: library_pass.scanner.Result) database.repository.ScanCounters {
    return .{
        .files_seen = result.files_seen,
        .changed = result.changed,
        .unchanged = result.unchanged,
        .unsupported = result.unsupported,
        .errors = result.errors,
    };
}

fn accumulate(totals: *library_pass.scanner.Result, result: library_pass.scanner.Result) void {
    totals.files_seen += result.files_seen;
    totals.changed += result.changed;
    totals.unchanged += result.unchanged;
    totals.unsupported += result.unsupported;
    totals.errors += result.errors;
    totals.batches_committed += result.batches_committed;
    totals.cancelled = totals.cancelled or result.cancelled;
    totals.projection.folders_visited += result.projection.folders_visited;
    totals.projection.files_projected += result.projection.files_projected;
    totals.projection.tracks_written += result.projection.tracks_written;
    totals.projection.releases_written += result.projection.releases_written;
}

test "nested and repeated reconcile directories collapse to the outermost, and a name-prefix sibling is kept" {
    const pending = try PendingReconcile.create(std.testing.allocator, .{
        .root_id = 1,
        .scope = .{ .subtrees = &.{ "A/B", "A-x", "A", "A/B/C", "A", "B" } },
    });
    defer pending.destroy();
    const kept = pending.request.scope.subtrees;
    try std.testing.expectEqual(@as(usize, 3), kept.len);
    try std.testing.expectEqualStrings("A", kept[0]);
    try std.testing.expectEqualStrings("A-x", kept[1]);
    try std.testing.expectEqualStrings("B", kept[2]);
}

test "a reconcile directory that is empty, absolute, escapes its root or is not in normal form is refused" {
    for ([_][]const u8{ "", "/A", "A/", "A//B", "A/../B", "..", "./A" }) |subtree| {
        try std.testing.expectError(error.InvalidReconcileDirectory, PendingReconcile.create(std.testing.allocator, .{
            .root_id = 1,
            .scope = .{ .subtrees = &.{subtree} },
        }));
    }
    try std.testing.expectError(error.InvalidReconcileDirectory, PendingReconcile.create(std.testing.allocator, .{
        .root_id = 1,
        .scope = .{ .subtrees = &.{} },
    }));
}
