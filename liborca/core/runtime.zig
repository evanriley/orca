const std = @import("std");
const analysis_chromaprint = @import("../analysis/chromaprint.zig");
const analysis_service = @import("../analysis/service.zig");
const artwork = @import("artwork.zig");
const audio = @import("../audio/root.zig");
const codec = @import("../codec/root.zig");
const control = @import("control.zig");
const database = @import("../database/root.zig");
const handle = @import("handle.zig");
const library_pass = @import("../library/root.zig");
const job = @import("job.zig");
const listen_worker = @import("listen_worker.zig");
const metadata = @import("../metadata/root.zig");
const network = @import("../network/root.zig");
const object = @import("object.zig");
const providers = @import("../providers/root.zig");
const storage = @import("../storage/root.zig");
const track_details = @import("track_details.zig");
const track_source = @import("track_source.zig");
const work = @import("work.zig");

pub const LibraryHandle = object.LibraryHandle;
pub const PlayerHandle = object.PlayerHandle;
pub const ZoneHandle = object.ZoneHandle;
pub const JobHandle = object.JobHandle;
pub const WorkHandle = work.WorkHandle;
pub const TrackRef = audio.playback_queue.TrackRef;
pub const RepeatMode = audio.playback_queue.RepeatMode;
pub const QueueSnapshot = audio.playback_queue.Snapshot;
pub const TrackDetails = track_details.TrackDetails;
pub const RecordingIdSource = track_details.RecordingIdSource;
pub const TrackLoudness = track_details.Loudness;
pub const PlayStats = database.PlayStats;
pub const Feedback = database.Feedback;
pub const FeedbackChange = database.FeedbackChange;
pub const ClientIdentity = network.client.Identity;
pub const CredentialStore = providers.credentials.Store;
pub const ScrobblerStatus = listen_worker.Status;
pub const ScrobblerState = providers.listenbrainz.State;
pub const BoundedText = providers.listenbrainz.BoundedText;

pub const State = enum(u8) {
    running,
    shutting_down,
    stopped,
};

const RuntimeObject = struct {};
const LibraryObject = struct {
    database: ?*database.LibraryDatabase = null,
    /// Started on the first artwork request, and again after any drain.
    artwork: ?*ArtworkLoader = null,
    /// Created on the first Player bind or scrobbling change and kept until
    /// the Library closes. Its worker restarts on the next listen after any
    /// drain.
    listens: ?*listen_worker.Listens = null,
    stored_counts: ?StoredCounts = null,
};

const StoredCounts = struct {
    pending: u64,
    feedback_pending: u64,
    delivered_total: u64,
    read_at_ms: i64,
};

const stored_counts_reuse_ms: i64 = 1000;

const ArtworkLoader = struct {
    loader: artwork.Loader,
    work_handle: WorkHandle,
};

pub const ArtworkSubject = artwork.Subject;
pub const ArtworkResult = artwork.Result;
const PlayerObject = struct {
    player: *audio.player.Player,
    /// Player-scope volume. Lives beside the Player rather than inside the
    /// engine so the level survives an engine that is stopped and respawned.
    gain: *audio.processing.Gain,
    /// Equalizer and crossfeed settings and state, wrapping `gain`. Lives
    /// beside the Player for the same reason: the settings outlive the engine.
    dsp: *audio.dsp.PlayerDsp,
    /// Track references, cursor, repeat and shuffle. Lives beside the Player
    /// and outlives any individual `SourceQueue`: `stop` releases decoders but
    /// never the list the user assembled.
    queue: *audio.playback_queue.PlaybackQueue,
    /// Resolves queue entries to audio. Bound to one Library, holding its own
    /// read-only connection, so the engine thread never touches a `handle.Pool`.
    opener: ?*track_source.TrackSourceOpener = null,
    /// The one decode producer for this Player. Spawned lazily when a source
    /// first arrives, registered with `work.Registry`, joined before the Player
    /// is freed.
    engine: ?*audio.engine.PlayerEngine = null,
    engine_work: ?WorkHandle = null,
    /// Sampled by the control lane while the Player is bound to a Library.
    listens: providers.listens.ListenTracker = .{},
};
const ZoneObject = struct {
    zone: *audio.zone_runtime.ZoneRuntime,
    attached_player: ?PlayerHandle = null,
};

/// Producer-side counters for the queue lane. Diagnostics, not transport
/// state: an authoritative consumer reads snapshots.
/// One field of `libraryEditTracks`: a value to set, or null to clear Orca's
/// value so the file's own tag applies again.
pub const TrackEdit = struct {
    field: metadata.Field,
    value: ?[]const u8,
};

pub const TrackEditPage = database.repository.FieldValuePage;

/// What forgetting a Library root removed.
pub const RemovedRoot = struct {
    files_forgotten: u64,
    tracks_removed: u64,
};

/// The Tracks an edit's files back once it is applied. An edit that moves a
/// track to another album or position reprojects it as a new Track, so the
/// ids a caller passed in may no longer exist. Caller-owned.
pub const EditedTracks = struct {
    allocator: std.mem.Allocator,
    ids: []i64,

    pub fn deinit(self: EditedTracks) void {
        self.allocator.free(self.ids);
    }
};

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
        .musicbrainz_recording_id => if (!metadata.isMusicBrainzId(value)) return error.InvalidEditValue,
        .title, .artist, .album, .album_artist, .date => {},
    }
}

/// One file's measurement from `libraryAnalyzeFile`.
pub const FileAnalysis = analysis_service.Analysis;
pub const TrackFingerprint = analysis_chromaprint.Fingerprinter.Outcome;

/// The Library's database, for liborca's own C ABI and tests. Clients use the
/// runtime's methods; the database is not part of the API.
pub fn databaseOf(runtime: *OrcaRuntime, library: LibraryHandle) !*database.LibraryDatabase {
    return runtime.libraryDatabase(library);
}

/// What `planTagWrite` would write, for a person to approve. Caller-owned.
pub const TagWritePlan = struct {
    arena: *std.heap.ArenaAllocator,
    /// Zero when there is nothing to write; there is then nothing to start.
    plan_id: u64,
    digest: metadata.mutation.Digest,
    files: []const TagWriteFile,
    skipped: []const TagWriteSkip,

    pub fn deinit(self: TagWritePlan) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

pub const TagWriteFile = struct {
    file_id: i64,
    path: []const u8,
    changes: []const TagWriteChange,
};

pub const TagWriteChange = struct {
    field: metadata.Field,
    before: ?[]const u8,
    after: ?[]const u8,
};

pub const TagWriteSkip = struct {
    file_id: i64,
    /// Empty when the file has no present location.
    path: []const u8,
    reason: TagWriteSkipReason,
};

pub const TagWriteSkipReason = enum {
    /// No location of the file is present to write to.
    missing,
    /// Orca has no tag writer for the file's format yet.
    format_not_writable,
    /// The bytes changed after the last scan; the scan must see them first, or
    /// the plan would be computed against tags the file no longer has.
    changed_since_scan,
};

/// Plans held between `planTagWrite` and `startTagWrite`. Few, because a plan
/// waits on a person.
const max_pending_tag_writes = 8;

/// A sealed plan and where each of its files lives, owned by the runtime until
/// a worker takes it.
const PendingTagWrite = struct {
    arena: std.heap.ArenaAllocator,
    library: LibraryHandle,
    plan: metadata.mutation.Plan,
    /// Index-aligned with `plan.actions`, allocated in `arena`.
    locations: []database.repository.PresentLocation,

    fn destroy(self: *PendingTagWrite) void {
        const allocator = self.arena.child_allocator;
        self.plan.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }
};

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
    };
}

/// Why a file cannot be written now, or null when it can.
fn tagWriteRefusal(
    io: std.Io,
    library_database: *database.LibraryDatabase,
    location: database.repository.PresentLocation,
) !?TagWriteSkipReason {
    if (!(metadata.executor.canWriteTags(io, location.uri) catch return .missing)) return .format_not_writable;
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

/// Re-reads one file Orca just rewrote, as a scan of its root would, and
/// reprojects it.
fn reobserve(
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

pub const QueueStats = struct {
    entries_started: u64,
    gapless_transitions: u64,
    format_switch_transitions: u64,
    open_failures: u64,
    /// Entries whose decoder failed part-way. The entry is ended and the queue
    /// moves on rather than stalling; a nonzero count is a real problem worth
    /// surfacing to a host.
    decode_errors: u64,
};

pub const ZoneStats = struct {
    output_state: audio.zone.OutputState,
    recovery_attempts: u32,
    underruns: u64,
    dropped_returns: u64,
    backend_quantum_frames: u32,
    rendered_entry_serial: u32,
};

/// How many finished job records keep their scanner counters queryable. A
/// bounded tail: a host reads the stats of the scan that just ended, not of
/// every scan the process ever ran.
const retained_job_records: usize = 8;

/// Ramp applied to a volume change, in frames. Long enough that a slider does
/// not click, short enough to feel immediate.
const volume_ramp_frames: u32 = 512;

/// How often the control lane samples bound Players for listens.
const listen_sample_interval_ms: i64 = 100;

pub const ScanRequest = struct {
    /// Which registered root to walk. Null walks every enabled root.
    root_id: ?i64 = null,
    batch_size: usize = 256,
};

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
};

pub const DuplicateScanRequest = struct {
    batch_size: usize = 256,
};

pub const MatchRequest = struct {
    batch_size: usize = 64,
    limit: ?u32 = null,
    /// Search only this Track, under the same rule as the whole library: one
    /// already identified, or already answered for, is not searched.
    track_id: ?i64 = null,
    /// Also fingerprint each Track's file and look it up on AcoustID, when an
    /// AcoustID application key is set.
    fingerprints: bool = true,
};

pub const AcoustIdUse = library_pass.matching.AcoustIdUse;
pub const AcoustIdSubmittable = database.AcoustIdSubmittable;
pub const AcoustIdSubmittablePage = database.AcoustIdSubmittablePage;
pub const SubmissionOutcome = library_pass.acoustid_submission.Outcome;

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

pub const MatchProposal = database.MatchProposal;
pub const MatchProposalPage = database.MatchProposalPage;
pub const MatchReviewItem = database.MatchReviewItem;
pub const MatchReviewPage = database.MatchReviewPage;
pub const MatchAcceptance = database.ProposalAcceptance;

pub const MatchingHooks = struct {
    transport: ?network.client.Transport = null,
    /// AcoustID's transport; `transport` when null.
    acoustid_transport: ?network.client.Transport = null,
    clock: ?network.client.Clock = null,
    wall_clock: ?network.client.Clock = null,
};

const AcoustIdSetup = struct {
    server: []const u8,
    client_key: ?[]const u8,
    credentials: ?CredentialStore,
};

const MatchingSetup = struct {
    io: std.Io,
    server: []const u8,
    identity: ClientIdentity,
    hooks: MatchingHooks,
    scope: database.MatchScope,
    /// Null when the job looks nothing up on AcoustID.
    acoustid: ?AcoustIdSetup,
};

const SubmissionSetup = struct {
    io: std.Io,
    identity: ClientIdentity,
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

fn validAcoustIdKey(key: []const u8) bool {
    if (key.len == 0 or key.len > providers.acoustid.max_key_bytes) return false;
    for (key) |byte| if (byte <= 0x20 or byte >= 0x7f) return false;
    return true;
}

/// Everything a job worker needs that is not the Library or the kind. One
/// struct rather than a widening parameter list, because every kind takes a
/// bounded batch size and each takes at most one thing besides.
const WorkerRequest = struct {
    root_id: ?i64 = null,
    batch_size: usize = 256,
    force: bool = false,
    /// A `.mutation` worker's plan, which the worker owns once started.
    tag_write: ?*PendingTagWrite = null,
    limit: ?u32 = null,
    matching: ?MatchingSetup = null,
    submission: ?SubmissionSetup = null,
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

    fn read(self: *const LiveMatchStats, progress: *const library_pass.matching.Progress) MatchStats {
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
        };
    }
};

/// One background worker behind a `JobHandle`.
///
/// Threading contract, the same one `core/work.zig` states: the worker thread
/// touches only this struct and the Library database it was handed. It never
/// resolves a handle, never reads a `handle.Pool`, and never touches the
/// runtime. The control lane cancels it, joins it through `work.Registry`, and
/// only then reads anything that is not an atomic here.
const JobWorker = struct {
    allocator: std.mem.Allocator,
    registration: *work.Registration,
    work_handle: WorkHandle,
    job: JobHandle,
    library: LibraryHandle,
    /// Borrowed. The control lane joins this worker before the Library it
    /// belongs to can be closed, which is what makes the raw pointer safe.
    database: *database.LibraryDatabase,
    kind: job.Kind,
    root_id: ?i64,
    batch_size: usize,
    force: bool,
    tag_write: ?*PendingTagWrite,
    limit: ?u32,
    matching: ?MatchingSetup,
    submission: ?SubmissionSetup,
    /// The worker's own `std.Io`. The ABI's belongs to the calling thread and
    /// is never borrowed across a thread boundary.
    threaded: std.Io.Threaded = .init_single_threaded,
    /// What the scanner polls. Set by `cancelJob` and by every runtime path
    /// that drains workers, because the registry flag alone cannot reach
    /// inside a filesystem walk.
    token: library_pass.CancellationToken = .{},
    /// Files the *current* root's walk has reached, written by the scanner.
    progress: std.atomic.Value(u64) = .init(0),
    /// A running matching pass's counters.
    match_progress: library_pass.matching.Progress = .{},
    stats: LiveScanStats = .{},
    match_stats: LiveMatchStats = .{},
    /// Written by the worker just before it finishes; read only after.
    submission_result: SubmissionStats = .{},
    failed: std.atomic.Value(bool) = .init(false),
    /// Control lane only: the thread has been joined and the record finalized.
    retired: bool = false,

    fn run(self: *JobWorker) void {
        defer {
            self.threaded.deinit();
            self.registration.finish();
        }
        switch (self.kind) {
            .scan => self.runScan(),
            .projection => self.runProjection(),
            .property_backfill => self.runPropertyBackfill(),
            .analysis => self.runAnalysis(),
            .duplicate_scan => self.runDuplicateScan(),
            .mutation => self.runTagWrite(),
            .metadata_lookup => self.runMatching(),
            .acoustid_submission => self.runSubmission(),
            else => self.failed.store(true, .release),
        }
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
    fn runPropertyBackfill(self: *JobWorker) void {
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
            .batch_size = self.batch_size,
            .force = self.force,
            .projection = &pass,
        };
        defer backfill.deinit();
        const result = backfill.run() catch {
            self.failed.store(true, .release);
            return;
        };
        self.progress.store(0, .release);
        _ = self.stats.files_seen.fetchAdd(result.files_seen, .acq_rel);
        _ = self.stats.changed.fetchAdd(result.changed, .acq_rel);
        _ = self.stats.unchanged.fetchAdd(result.unchanged, .acq_rel);
        _ = self.stats.unsupported.fetchAdd(result.unsupported, .acq_rel);
        _ = self.stats.errors.fetchAdd(result.errors, .acq_rel);
        _ = self.stats.batches_committed.fetchAdd(result.batches_committed, .acq_rel);
        if (result.cancelled) self.stats.cancelled.store(true, .release);
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
    fn runAnalysis(self: *JobWorker) void {
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
            .batch_size = self.batch_size,
        };
        const result = pass.run() catch {
            self.failed.store(true, .release);
            return;
        };
        self.progress.store(0, .release);
        _ = self.stats.files_seen.fetchAdd(result.files_seen, .acq_rel);
        _ = self.stats.changed.fetchAdd(result.changed, .acq_rel);
        _ = self.stats.unchanged.fetchAdd(result.unchanged, .acq_rel);
        _ = self.stats.unsupported.fetchAdd(result.unsupported, .acq_rel);
        _ = self.stats.errors.fetchAdd(result.errors, .acq_rel);
        _ = self.stats.batches_committed.fetchAdd(result.batches_committed, .acq_rel);
        if (result.cancelled) self.stats.cancelled.store(true, .release);
    }

    /// Finds the audio the Library holds more than once.
    ///
    /// Nothing is decoded and no file is opened: the pass compares
    /// measurements the analysis job already stored, through two indexes. That
    /// is why it is a job of its own rather than a phase of the analysis --
    /// the measuring takes hours and the comparing takes seconds, and a person
    /// who has analyzed their library should not have to analyze it again to
    /// ask the question a second time.
    ///
    /// The counters reuse `ScanStats` with this pass's own meaning, exactly as
    /// the backfill and the analysis do; `orca.h` documents the mapping.
    fn runDuplicateScan(self: *JobWorker) void {
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
            .batch_size = self.batch_size,
        };
        const result = pass.run() catch {
            self.failed.store(true, .release);
            return;
        };
        self.progress.store(0, .release);
        _ = self.stats.files_seen.fetchAdd(result.files_seen, .acq_rel);
        _ = self.stats.changed.fetchAdd(result.exact + result.likely, .acq_rel);
        _ = self.stats.unchanged.fetchAdd(result.unique, .acq_rel);
        _ = self.stats.unsupported.fetchAdd(result.uncomparable, .acq_rel);
        _ = self.stats.errors.fetchAdd(result.errors, .acq_rel);
        _ = self.stats.batches_committed.fetchAdd(result.batches_committed, .acq_rel);
        _ = self.stats.folders_visited.fetchAdd(result.buckets_truncated, .acq_rel);
        _ = self.stats.files_projected.fetchAdd(result.comparisons, .acq_rel);
        _ = self.stats.tracks_written.fetchAdd(result.exact, .acq_rel);
        _ = self.stats.releases_written.fetchAdd(result.likely, .acq_rel);
        if (result.cancelled) self.stats.cancelled.store(true, .release);
    }

    fn runMatching(self: *JobWorker) void {
        const setup = self.matching orelse {
            self.failed.store(true, .release);
            return;
        };
        var standard: network.StandardTransport = .init(self.allocator, setup.io);
        defer standard.deinit();
        var system_clock: network.SystemClock = .{ .io = setup.io };
        const clock = setup.hooks.clock orelse system_clock.clock();
        const wall_clock = setup.hooks.wall_clock orelse system_clock.wallClock();
        var gateway: network.Gateway = .{
            .transport = setup.hooks.transport orelse standard.transport(),
            .clock = clock,
            .config = .{ .identity = setup.identity },
            .cancel = &self.registration.cancel,
        };
        var musicbrainz: providers.musicbrainz.MusicBrainz = .{
            .gateway = &gateway,
            .cache = &self.database.provider_cache,
            .wall_clock = wall_clock,
            .server = setup.server,
        };
        var acoustid_gateway: network.Gateway = .{
            .transport = setup.hooks.acoustid_transport orelse setup.hooks.transport orelse standard.transport(),
            .clock = clock,
            .config = .{ .identity = setup.identity },
            .cancel = &self.registration.cancel,
        };
        const client_key = if (setup.acoustid) |acoustid| resolveClientKey(self.allocator, acoustid) catch {
            self.failed.store(true, .release);
            return;
        } else null;
        defer if (client_key) |key| providers.credentials.wipeAndFree(self.allocator, key);
        var acoustid: ?providers.acoustid.AcoustId = if (client_key) |key| .{
            .gateway = &acoustid_gateway,
            .cache = &self.database.provider_cache,
            .wall_clock = wall_clock,
            .server = setup.acoustid.?.server,
            .client_key = key,
        } else null;
        self.match_stats.acoustid.store(if (acoustid != null) .searched else if (setup.acoustid == null) .off else .no_client_key, .release);
        const codecs = codec.CodecRegistry.builtins();
        var pass: library_pass.LibraryMatching = .{
            .allocator = self.allocator,
            .proposals = &self.database.identification_proposals,
            .musicbrainz = &musicbrainz,
            .acoustid = if (acoustid) |*service| service else null,
            .acoustid_use = self.match_stats.acoustid.load(.acquire),
            .fingerprinter = .{
                .allocator = self.allocator,
                .io = self.threaded.io(),
                .codecs = &codecs,
                .cache = &self.database.analysis_cache,
                .cancellation = &self.token,
            },
            .cancellation = &self.token,
            .progress = &self.match_progress,
            .batch_size = self.batch_size,
            .limit = self.limit,
            .scope = setup.scope,
        };
        const result = pass.run() catch {
            self.failed.store(true, .release);
            return;
        };
        self.match_progress.tracks_seen.store(0, .release);
        self.match_progress.matched.store(0, .release);
        self.match_progress.fingerprinted.store(0, .release);
        _ = self.match_stats.tracks_examined.fetchAdd(result.tracks_seen, .acq_rel);
        _ = self.match_stats.matched.fetchAdd(result.matched, .acq_rel);
        _ = self.match_stats.unmatched.fetchAdd(result.unmatched, .acq_rel);
        _ = self.match_stats.insufficient_evidence.fetchAdd(result.insufficient, .acq_rel);
        _ = self.match_stats.refused.fetchAdd(result.refused, .acq_rel);
        _ = self.match_stats.proposals_stored.fetchAdd(result.proposals_stored, .acq_rel);
        _ = self.match_stats.requests.fetchAdd(result.requests_answered, .acq_rel);
        _ = self.match_stats.cache_hits.fetchAdd(result.cache_hits, .acq_rel);
        _ = self.match_stats.fingerprinted.fetchAdd(result.fingerprinted, .acq_rel);
        _ = self.match_stats.fingerprint_cache_hits.fetchAdd(result.fingerprint_cache_hits, .acq_rel);
        _ = self.match_stats.fingerprint_failures.fetchAdd(result.fingerprint_failures, .acq_rel);
        _ = self.match_stats.acoustid_requests.fetchAdd(result.acoustid_requests, .acq_rel);
        _ = self.match_stats.acoustid_cache_hits.fetchAdd(result.acoustid_cache_hits, .acq_rel);
        _ = self.match_stats.acoustid_refused.fetchAdd(result.acoustid_refused, .acq_rel);
        self.match_stats.acoustid.store(result.acoustid, .release);
        if (result.cancelled) self.match_stats.cancelled.store(true, .release);
        if (result.unavailable) self.failed.store(true, .release);
    }

    fn runSubmission(self: *JobWorker) void {
        const setup = self.submission orelse {
            self.failed.store(true, .release);
            return;
        };
        var standard: network.StandardTransport = .init(self.allocator, setup.io);
        defer standard.deinit();
        var system_clock: network.SystemClock = .{ .io = setup.io };
        var gateway: network.Gateway = .{
            .transport = setup.hooks.acoustid_transport orelse setup.hooks.transport orelse standard.transport(),
            .clock = setup.hooks.clock orelse system_clock.clock(),
            .config = .{ .identity = setup.identity },
            .cancel = &self.registration.cancel,
        };
        const client_key = resolveClientKey(self.allocator, setup.acoustid) catch {
            self.failed.store(true, .release);
            return;
        } orelse {
            self.submission_result = .{ .outcome = .needs_client_key };
            self.failed.store(true, .release);
            return;
        };
        defer providers.credentials.wipeAndFree(self.allocator, client_key);
        var acoustid: providers.acoustid.AcoustId = .{
            .gateway = &gateway,
            .cache = &self.database.provider_cache,
            .wall_clock = setup.hooks.wall_clock orelse system_clock.wallClock(),
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
        self.submission_result = .{
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
            .cancelled => self.stats.cancelled.store(true, .release),
            .needs_client_key, .invalid_client_key, .needs_user_key, .invalid_user_key, .unavailable => self.failed.store(true, .release),
        }
    }

    fn runScan(self: *JobWorker) void {
        const io = self.threaded.io();
        var roots = self.database.library_roots.list(self.allocator) catch {
            self.failed.store(true, .release);
            return;
        };
        defer roots.deinit();
        for (roots.items) |root| {
            if (self.cancelled()) {
                self.stats.cancelled.store(true, .release);
                break;
            }
            if (!root.enabled) continue;
            if (self.root_id) |wanted| {
                if (root.id != wanted) continue;
            }
            self.scanRoot(io, root) catch self.failed.store(true, .release);
        }
    }

    /// One root, walked exactly as `orca-cli scan` walks it: observe, project
    /// each committed batch, close the run, and — only on a run that finished —
    /// name the locations the walk never reached.
    fn scanRoot(
        self: *JobWorker,
        io: std.Io,
        root: database.repository.LibraryRoot,
    ) !void {
        self.progress.store(0, .release);
        const scan_run = try self.database.scan_runs.begin(root.id);
        var pass: library_pass.Projection = .{
            .allocator = self.allocator,
            .library = self.database,
        };
        var scanner: library_pass.Scanner = .{
            .allocator = self.allocator,
            .io = io,
            .files = &self.database.files,
            .locations = &self.database.locations,
            .observed_tags = &self.database.observed_tags,
            .write_lane = self.database.write_lane,
            .database_handle = self.database.database,
            .volume_id = root.volume_id,
            .root_id = root.id,
            .generation = scan_run.generation,
            .cancellation = &self.token,
            .batch_size = self.batch_size,
            .progress = &self.progress,
            .projection = &pass,
        };
        defer scanner.deinit();
        const result = try scanner.scan(root.path);
        try self.database.scan_runs.finish(
            scan_run.id,
            if (result.cancelled) .cancelled else .completed,
            .{
                .files_seen = result.files_seen,
                .changed = result.changed,
                .unchanged = result.unchanged,
                .unsupported = result.unsupported,
                .errors = result.errors,
            },
        );
        // Never on a cancelled run: a partial walk must not mark the files it
        // did not reach as missing.
        if (!result.cancelled) _ = try self.database.files.markMissingBelowGeneration(
            root.id,
            scan_run.generation,
        );
        self.progress.store(0, .release);
        _ = self.stats.files_seen.fetchAdd(result.files_seen, .acq_rel);
        _ = self.stats.changed.fetchAdd(result.changed, .acq_rel);
        _ = self.stats.unchanged.fetchAdd(result.unchanged, .acq_rel);
        _ = self.stats.unsupported.fetchAdd(result.unsupported, .acq_rel);
        _ = self.stats.errors.fetchAdd(result.errors, .acq_rel);
        _ = self.stats.batches_committed.fetchAdd(result.batches_committed, .acq_rel);
        if (result.cancelled) self.stats.cancelled.store(true, .release);
        self.noteProjection(result.projection);
    }

    fn runTagWrite(self: *JobWorker) void {
        const io = self.threaded.io();
        const pending = self.tag_write.?;
        _ = self.stats.files_seen.fetchAdd(pending.plan.actions.len, .acq_rel);
        var executor: metadata.executor.Executor = .{
            .allocator = self.allocator,
            .io = io,
            .journal = &self.database.mutation_journal,
        };
        if (executor.executePlan(&pending.plan, pending.plan.id)) {
            _ = self.stats.changed.fetchAdd(pending.plan.actions.len, .acq_rel);
        } else |_| {
            _ = self.stats.errors.fetchAdd(1, .acq_rel);
            self.failed.store(true, .release);
        }
        for (pending.locations) |location| {
            reobserve(self.allocator, io, self.database, location) catch {
                _ = self.stats.errors.fetchAdd(1, .acq_rel);
            };
        }
    }

    fn noteProjection(self: *JobWorker, result: library_pass.projection.Result) void {
        _ = self.stats.folders_visited.fetchAdd(result.folders_visited, .acq_rel);
        _ = self.stats.files_projected.fetchAdd(result.files_projected, .acq_rel);
        _ = self.stats.tracks_written.fetchAdd(result.tracks_written, .acq_rel);
        _ = self.stats.releases_written.fetchAdd(result.releases_written, .acq_rel);
    }

    fn filesProcessed(self: *const JobWorker) u64 {
        return switch (self.kind) {
            .metadata_lookup => self.matchStats().tracks_examined,
            .acoustid_submission => self.submissionStats().files_examined,
            else => self.stats.files_seen.load(.acquire) + self.progress.load(.acquire),
        };
    }

    fn scanStats(self: *const JobWorker) ScanStats {
        return self.stats.read(switch (self.kind) {
            .metadata_lookup, .acoustid_submission => 0,
            else => self.progress.load(.acquire),
        });
    }

    fn matchStats(self: *const JobWorker) MatchStats {
        return self.match_stats.read(&self.match_progress);
    }

    fn submissionStats(self: *const JobWorker) SubmissionStats {
        if (self.retired or self.registration.isFinished()) return self.submission_result;
        return .{ .files_examined = self.progress.load(.acquire) };
    }

    fn wasCancelled(self: *const JobWorker) bool {
        return self.stats.cancelled.load(.acquire) or self.match_stats.cancelled.load(.acquire);
    }
};

/// One lock-free read of everything a transport UI shows.
pub const PlayerStatus = struct {
    transport: audio.player.TransportState,
    repeat: RepeatMode,
    shuffle: bool,
    epoch: u32,
    position_ms: u64,
    duration_ms: u64,
    /// The **audible** entry, not the one the decoder has reached.
    track_id: ?i64,
    /// Serial of the audible entry; each play of a queue entry gets a new
    /// one. Zero when nothing is loaded.
    entry_serial: u32,
    queue_length: u32,
    queue_index: u32,
    volume: f32,
};

/// Open one file and read the cover image out of it.
///
/// A file the Library still lists but the filesystem no longer has is null,
/// not an error. The Library's record of where a file is is only as fresh as
/// the last scan, and reconciling that is the scanner's job — an artwork query
/// is a read and must not start writing `missing` states from under it.
/// Process-level root for liborca. Objects are invalidated in dependency order:
/// work, Zones, Players, then Libraries. `deinit` always performs shutdown.
pub const OrcaRuntime = struct {
    allocator: std.mem.Allocator,
    state: std.atomic.Value(State) = .init(.running),
    libraries: handle.Pool(LibraryObject, object.LibraryTag),
    players: handle.Pool(PlayerObject, object.PlayerTag),
    zones: handle.Pool(ZoneObject, object.ZoneTag),
    jobs: job.Manager,
    work_registry: work.Registry,
    commands: control.CommandQueue = .{},
    events: control.EventChannel = .{},
    telemetry: control.TelemetryChannel = .{},
    /// Host audio backend. Zones reach it only through `output.Factory`, so a
    /// platform without one simply never opens a stream.
    output_host: audio.backends.Host = .{},
    output_host_ready: bool = false,
    /// Replaces the host backend for embedders that supply their own output, and
    /// for tests that must be deterministic without an audio server. Must be set
    /// before any Player engine is spawned; engines capture it once.
    output_factory_override: ?audio.output.Factory = null,
    /// Fixed shuffle seed, for tests that need a reproducible permutation.
    shuffle_seed: ?u64 = null,
    shuffle_counter: u64 = 0,
    /// Background job workers, live and recently retired. Control lane only.
    job_workers: std.ArrayList(*JobWorker) = .empty,
    /// Tag-write plans awaiting approval. Control lane only.
    pending_tag_writes: [max_pending_tag_writes]?*PendingTagWrite = @splat(null),
    client_identity: ClientIdentity = .orca,
    credential_store: ?CredentialStore = null,
    listenbrainz_server: []const u8 = providers.listenbrainz.default_server,
    musicbrainz_server: []const u8 = providers.musicbrainz.default_server,
    /// Version of the three settings above, copied into every Library's
    /// listen config.
    listen_settings: u32 = 0,
    acoustid_server: []const u8 = providers.acoustid.default_server,
    acoustid_client_key: ?[]const u8 = null,
    /// One per runtime, created with the first listen worker and deinitialized
    /// after the last is joined. `Threaded.init` installs SIGIO and SIGPIPE
    /// handlers and `deinit` restores what it found, so a second instance torn
    /// down while this one has a request in flight would leave the host's
    /// dispositions -- the default one kills the process -- in place under it.
    network_threaded: ?*std.Io.Threaded = null,
    /// The one Library whose listens go to ListenBrainz, so a runtime never
    /// has two gateways to one service.
    scrobbling_library: ?LibraryHandle = null,
    /// The control lane's own `std.Io`, for clock reads and worker wakeups
    /// only.
    control_threaded: std.Io.Threaded = .init_single_threaded,
    last_listen_sample_ms: ?i64 = null,
    /// Replaced by tests that must not reach a network or wait in real time.
    listen_hooks: listen_worker.Hooks = .{},
    matching_hooks: MatchingHooks = .{},

    pub fn init(allocator: std.mem.Allocator) OrcaRuntime {
        return .{
            .allocator = allocator,
            .libraries = .init(allocator),
            .players = .init(allocator),
            .zones = .init(allocator),
            .jobs = .init(allocator),
            .work_registry = .init(allocator),
        };
    }

    /// The backend adapter stores a pointer back into the runtime, so it can
    /// only be wired once the runtime has its final address.
    pub fn setOutputFactory(self: *OrcaRuntime, factory: ?audio.output.Factory) void {
        self.output_factory_override = factory;
    }

    fn outputFactory(self: *OrcaRuntime) ?audio.output.Factory {
        if (self.output_factory_override) |factory| return factory;
        if (!self.output_host_ready) {
            self.output_host.init(self.allocator);
            self.output_host_ready = true;
        }
        return self.output_host.factory();
    }

    pub fn deinit(self: *OrcaRuntime) void {
        self.shutdown();
        self.work_registry.deinit();
        if (self.network_threaded) |threaded| {
            threaded.deinit();
            self.allocator.destroy(threaded);
        }
        if (self.output_host_ready) self.output_host.deinit();
        self.jobs.deinit();
        self.zones.deinit();
        self.players.deinit();
        self.libraries.deinit();
        self.* = undefined;
    }

    /// Refuses new commands, requests cancellation of every registered worker,
    /// BLOCKS until all of them have finished, and only then destroys objects in
    /// dependency order: Zones, Players, Libraries. Joining before destroying is
    /// what makes the destruction safe; see `core/work.zig`.
    pub fn shutdown(self: *OrcaRuntime) void {
        if (self.state.cmpxchgStrong(
            .running,
            .shutting_down,
            .acq_rel,
            .acquire,
        ) != null) return;

        // Commands are already refused above. Cancel, then join, then destroy.
        // Engine threads hold raw `*ZoneRuntime` and `*Player` pointers, so they
        // must be joined before either is freed — closing OutputSessions first,
        // because a live render callback reads Zone-owned memory.
        self.endListens(null);
        for (self.players.slots.items) |*slot| {
            if (slot.value) |*player| self.stopEngine(player);
        }
        self.cancelJobWorkers();
        self.work_registry.requestCancellation();
        self.wakeListenWorkers();
        self.work_registry.drain();
        self.finalizeDrainedJobWorkers();
        self.releaseDrainedArtworkLoaders();
        self.releaseDrainedListenWorkers();
        self.freeAllJobWorkers();
        self.discardPendingTagWrites(null);
        self.jobs.cancelAndDrain();
        for (self.zones.slots.items) |*slot| {
            if (slot.value) |zone| zone.zone.destroy();
        }
        self.zones.discardAll();
        for (self.players.slots.items) |*slot| {
            if (slot.value) |player| self.freePlayerObject(player);
        }
        self.players.discardAll();
        for (self.libraries.slots.items) |*slot| {
            if (slot.value) |*library| {
                self.closeLibraryDatabase(library);
                self.freeListens(library);
            }
        }
        self.libraries.discardAll();

        self.state.store(.stopped, .release);
    }

    pub fn createLibrary(self: *OrcaRuntime) !LibraryHandle {
        try self.requireRunning();
        return self.libraries.insert(.{});
    }

    pub fn openLibrary(
        self: *OrcaRuntime,
        io: std.Io,
        path: [:0]const u8,
    ) !LibraryHandle {
        try self.requireRunning();
        const library_database = try self.allocator.create(database.LibraryDatabase);
        errdefer self.allocator.destroy(library_database);
        library_database.* = try database.LibraryDatabase.open(self.allocator, io, path);
        errdefer library_database.close();
        return self.libraries.insert(.{ .database = library_database });
    }

    pub fn destroyLibrary(self: *OrcaRuntime, library: LibraryHandle) !void {
        try self.requireRunning();
        self.endListens(library);
        // A scan or projection worker holds this database by pointer, so it is
        // cancelled and joined before the connection can be closed. Work is not
        // yet scoped per object, so this conservatively drains every worker —
        // the same trade `joinWorkersBeforeDestroy` documents.
        self.cancelJobWorkers();
        self.joinWorkersBeforeDestroy();
        self.reapStoppedEngines();
        self.finalizeDrainedJobWorkers();
        // Openers hold a pointer into the Library they resolve through, so
        // every Player bound to it has to let go — with its engine stopped —
        // before the database is closed.
        self.unbindLibraryFromPlayers(library);
        self.discardPendingTagWrites(library);
        var removed = try self.libraries.remove(library);
        self.closeLibraryDatabase(&removed);
        self.freeListens(&removed);
        if (self.scrobbling_library) |scrobbling| {
            if (scrobbling.eql(library)) self.scrobbling_library = null;
        }
        self.restartScrobblingListenWorker();
    }

    fn unbindLibraryFromPlayers(self: *OrcaRuntime, library: LibraryHandle) void {
        for (self.players.slots.items) |*slot| {
            const object_value = if (slot.value) |*value| value else continue;
            const opener = object_value.opener orelse continue;
            if (!opener.library.eql(library)) continue;
            if (object_value.engine) |engine| {
                engine.quiesce();
                defer engine.release();
                engine.opener = null;
                engine.releasePending();
                object_value.player.releaseSources();
                object_value.opener = null;
                opener.destroy();
                continue;
            }
            object_value.player.releaseSources();
            object_value.opener = null;
            opener.destroy();
        }
    }

    fn libraryDatabase(
        self: *OrcaRuntime,
        library: LibraryHandle,
    ) !*database.LibraryDatabase {
        try self.requireRunning();
        return (try self.libraries.get(library)).database orelse error.LibraryHasNoDatabase;
    }

    /// Files that still owe the default loudness and fingerprint measurement.
    pub fn libraryUnanalyzedCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return (try self.libraryDatabase(library)).files.unanalyzedCount(
            analysis_service.diagnosticsSelector(.{}),
        );
    }

    /// Measures one file on the caller's thread and records the result in the
    /// Library's analysis cache, registering the file if no scan has seen it.
    /// The caller owns the returned analysis.
    pub fn libraryAnalyzeFile(
        self: *OrcaRuntime,
        library: LibraryHandle,
        io: std.Io,
        path: []const u8,
    ) !FileAnalysis {
        const library_database = try self.libraryDatabase(library);
        const codecs = codec.CodecRegistry.builtins();
        const service: analysis_service.Service = .{
            .allocator = self.allocator,
            .io = io,
            .codecs = &codecs,
            .cache = &library_database.analysis_cache,
        };
        const binding = try library_database.resolveOrCreateFile(io, path, .{});
        return service.analyzeFile(binding.file_id, path, .{});
    }

    /// The AcoustID fingerprint of the file a Track plays, from the Library's
    /// cache or decoded now: the first two minutes, on the caller's thread.
    /// Null when the Track has no file with a present location. A file that
    /// does not decode cleanly has no fingerprint and returns its error.
    pub fn libraryTrackFingerprint(
        self: *OrcaRuntime,
        library: LibraryHandle,
        io: std.Io,
        track_id: i64,
    ) !?TrackFingerprint {
        const library_database = try self.libraryDatabase(library);
        const facts = try library_database.tracks.fileFacts(self.allocator, track_id) orelse return error.TrackNotFound;
        defer facts.deinit();
        const location = try library_database.locations.presentOf(self.allocator, facts.file_id) orelse return null;
        defer self.allocator.free(location.uri);
        const codecs = codec.CodecRegistry.builtins();
        const fingerprinter: analysis_chromaprint.Fingerprinter = .{
            .allocator = self.allocator,
            .io = io,
            .codecs = &codecs,
            .cache = &library_database.analysis_cache,
        };
        return try fingerprinter.fingerprintFile(facts.file_id, location.uri);
    }

    pub fn libraryTrackCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return (try self.libraryDatabase(library)).tracks.count();
    }

    pub fn libraryTrackPage(
        self: *OrcaRuntime,
        library: LibraryHandle,
        query: []const u8,
        limit: u32,
        offset: u32,
    ) !database.TrackPage {
        return self.libraryTrackQuery(library, query, .{ .limit = limit, .offset = offset });
    }

    /// The browse listing: a bounded page of Tracks in a caller-named order,
    /// optionally scoped to one Artist or one Release.
    ///
    /// A full-text `query` and a relational filter are alternatives, not a
    /// combination: FTS5 orders by relevance, which no sort key or `tracks.id`
    /// tiebreaker can reconcile with. Asking for both is a caller bug rather
    /// than a silently-ignored argument.
    pub fn libraryTrackQuery(
        self: *OrcaRuntime,
        library: LibraryHandle,
        text_query: []const u8,
        page_query: database.TrackQuery,
    ) !database.TrackPage {
        const tracks = &(try self.libraryDatabase(library)).tracks;
        if (text_query.len == 0) return tracks.page(self.allocator, page_query);
        if (page_query.artist_id != null or page_query.release_id != null)
            return error.SearchDoesNotFilter;
        return tracks.search(self.allocator, text_query, page_query.limit, page_query.offset);
    }

    pub fn libraryTrackMatchCount(
        self: *OrcaRuntime,
        library: LibraryHandle,
        query: database.TrackQuery,
    ) !u64 {
        return (try self.libraryDatabase(library)).tracks.countMatching(query);
    }

    pub fn libraryArtistCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return (try self.libraryDatabase(library)).artists.count();
    }

    pub fn libraryArtistPage(
        self: *OrcaRuntime,
        library: LibraryHandle,
        query: database.ArtistQuery,
    ) !database.ArtistPage {
        return (try self.libraryDatabase(library)).artists.page(self.allocator, query);
    }

    /// How many Artists `libraryArtistPage` would return for the same query.
    /// A browser cannot show a total otherwise, and paging to exhaustion to
    /// count is what a bounded page exists to avoid.
    pub fn libraryArtistCountMatching(
        self: *OrcaRuntime,
        library: LibraryHandle,
        query: database.ArtistQuery,
    ) !u64 {
        return (try self.libraryDatabase(library)).artists.countMatching(query);
    }

    /// How many Releases `libraryReleasePage` would return for the same query.
    pub fn libraryReleaseCountMatching(
        self: *OrcaRuntime,
        library: LibraryHandle,
        query: database.ReleaseQuery,
    ) !u64 {
        return (try self.libraryDatabase(library)).releases.countMatching(query);
    }

    pub fn libraryArtist(
        self: *OrcaRuntime,
        library: LibraryHandle,
        artist_id: i64,
    ) !?database.ArtistSummary {
        return (try self.libraryDatabase(library)).artists.byId(self.allocator, artist_id);
    }

    pub fn libraryReleaseCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return (try self.libraryDatabase(library)).releases.count();
    }

    pub fn libraryReleasePage(
        self: *OrcaRuntime,
        library: LibraryHandle,
        query: database.ReleaseQuery,
    ) !database.ReleasePage {
        return (try self.libraryDatabase(library)).releases.page(self.allocator, query);
    }

    pub fn libraryRelease(
        self: *OrcaRuntime,
        library: LibraryHandle,
        release_id: i64,
    ) !?database.ReleaseSummary {
        return (try self.libraryDatabase(library)).releases.byId(self.allocator, release_id);
    }

    /// The cover image embedded in a Track's file, or null when it has none.
    ///
    /// Caller-owned bytes plus the media type those bytes actually are; free
    /// with `EmbeddedImage.deinit`. Read from the file on every call, and
    /// deliberately not cached and deliberately not stored: see
    /// `docs/metadata.md` for the measurements behind both decisions.
    ///
    /// A Track with no file, a file that has since gone, and a file with no
    /// cover are all the same answer — null. None of them is a failure a host
    /// should surface, and a missing cover is not a reason to fail a query the
    /// caller made about a track it can still play.
    /// The cover image for a Track's playable file, read on the caller's
    /// thread. `libraryRequestArtwork` is the same lookup off it.
    pub fn libraryTrackArtwork(
        self: *OrcaRuntime,
        library: LibraryHandle,
        io: std.Io,
        track_id: i64,
    ) !?metadata.EmbeddedImage {
        return artwork.trackArtwork(self.allocator, io, try self.libraryDatabase(library), track_id);
    }

    pub const max_release_artwork_candidates = artwork.max_release_candidates;

    /// The cover image for a Release, or null when none of its files has one,
    /// read on the caller's thread. See `artwork.releaseArtwork` for which
    /// file's cover that is.
    pub fn libraryReleaseArtwork(
        self: *OrcaRuntime,
        library: LibraryHandle,
        io: std.Io,
        release_id: i64,
    ) !?metadata.EmbeddedImage {
        return artwork.releaseArtwork(self.allocator, io, try self.libraryDatabase(library), release_id);
    }

    /// Asks for a cover without waiting for it. The lookup runs on the
    /// Library's artwork loader, and the result is collected with
    /// `libraryTakeArtwork`. At most `artwork.capacity` requests are
    /// outstanding per Library; beyond that this returns
    /// `error.ArtworkQueueFull` and the host asks again later.
    pub fn libraryRequestArtwork(
        self: *OrcaRuntime,
        library: LibraryHandle,
        io: std.Io,
        subject: ArtworkSubject,
    ) !u64 {
        try self.requireRunning();
        const object_value = try self.libraries.get(library);
        const loader = object_value.artwork orelse try self.startArtworkLoader(object_value);
        return loader.loader.request(io, subject);
    }

    /// A request that has not started is skipped without reading a file. One
    /// that has finished still arrives from `libraryTakeArtwork`.
    pub fn libraryCancelArtwork(self: *OrcaRuntime, library: LibraryHandle, request: u64) void {
        const object_value = self.libraries.get(library) catch return;
        const loader = object_value.artwork orelse return;
        loader.loader.cancel(request);
    }

    /// The next finished artwork request, if any. The caller owns the image.
    pub fn libraryTakeArtwork(self: *OrcaRuntime, library: LibraryHandle) ?ArtworkResult {
        const object_value = self.libraries.get(library) catch return null;
        const loader = object_value.artwork orelse return null;
        return loader.loader.take();
    }

    fn startArtworkLoader(self: *OrcaRuntime, object_value: *LibraryObject) !*ArtworkLoader {
        const library_database = object_value.database orelse return error.LibraryHasNoDatabase;
        const loader = try self.allocator.create(ArtworkLoader);
        errdefer self.allocator.destroy(loader);
        const work_handle = try self.work_registry.begin(work.unowned);
        const registration = self.work_registry.registration(work_handle) catch unreachable;
        errdefer {
            registration.finish();
            self.work_registry.complete(work_handle) catch {};
        }
        loader.* = .{
            .loader = .{
                .allocator = self.allocator,
                .database = library_database,
                .registration = registration,
            },
            .work_handle = work_handle,
        };
        registration.thread = try std.Thread.spawn(.{}, artwork.Loader.run, .{&loader.loader});
        object_value.artwork = loader;
        return loader;
    }

    /// Control lane, immediately after `work_registry.drain()`: the loaders'
    /// threads have been joined and their registrations freed, so each is
    /// released here and restarts on its Library's next request.
    fn releaseDrainedArtworkLoaders(self: *OrcaRuntime) void {
        for (self.libraries.slots.items) |*slot| {
            const object_value = if (slot.value) |*value| value else continue;
            const loader = object_value.artwork orelse continue;
            loader.loader.discardResults();
            self.allocator.destroy(loader);
            object_value.artwork = null;
        }
    }

    // ------------------------------------------------------------- listens

    /// Names the host in its listen history and in every ListenBrainz
    /// submission, from each listen worker's next pass. `identity`'s strings
    /// must outlive the runtime.
    pub fn setClientIdentity(self: *OrcaRuntime, identity: ClientIdentity) !void {
        try self.requireRunning();
        try identity.validate();
        self.client_identity = identity;
        self.publishListenSettings();
    }

    /// Where listen workers read the ListenBrainz user token, from each
    /// worker's next pass. `store.get` is called on a worker's thread;
    /// `store` must outlive the runtime.
    pub fn setCredentialStore(self: *OrcaRuntime, store: CredentialStore) !void {
        try self.requireRunning();
        self.credential_store = store;
        self.publishListenSettings();
    }

    /// Points scrobbling at a self-hosted or compatible ListenBrainz server,
    /// from each listen worker's next pass. `https` anywhere, or `http` to
    /// `127.0.0.1`, `[::1]` or `localhost` only, because the user token
    /// travels in every request. `base_url` must outlive the runtime.
    pub fn setListenBrainzServer(self: *OrcaRuntime, base_url: []const u8) !void {
        try self.requireRunning();
        try providers.url.validateServer(base_url);
        self.listenbrainz_server = base_url;
        self.publishListenSettings();
    }

    /// `base_url` must outlive the runtime.
    pub fn setMusicBrainzServer(self: *OrcaRuntime, base_url: []const u8) !void {
        try self.requireRunning();
        try providers.url.validateServer(base_url);
        self.musicbrainz_server = base_url;
    }

    /// The AcoustID application key matching and submission jobs use, unless
    /// the credential store holds one under `org.acoustid`/`client-key`.
    /// Without either, matching skips AcoustID. `key` must outlive the
    /// runtime.
    pub fn setAcoustIdClientKey(self: *OrcaRuntime, key: []const u8) !void {
        try self.requireRunning();
        if (!validAcoustIdKey(key)) return error.InvalidAcoustIdKey;
        self.acoustid_client_key = key;
    }

    /// Points AcoustID lookups and submissions at another server, under the
    /// same rule as `setListenBrainzServer`. `base_url` must outlive the
    /// runtime.
    pub fn setAcoustIdServer(self: *OrcaRuntime, base_url: []const u8) !void {
        try self.requireRunning();
        try providers.url.validateServer(base_url);
        self.acoustid_server = base_url;
    }

    fn withListenSettings(self: *OrcaRuntime, config: listen_worker.Config) listen_worker.Config {
        var updated = config;
        updated.identity = self.client_identity;
        updated.credentials = self.credential_store;
        updated.server = self.listenbrainz_server;
        updated.settings = self.listen_settings;
        return updated;
    }

    fn publishListenSettings(self: *OrcaRuntime) void {
        self.listen_settings +%= 1;
        for (self.libraries.slots.items) |*slot| {
            const object_value = if (slot.value) |*value| value else continue;
            const listens = object_value.listens orelse continue;
            listens.configure(self.control_threaded.io(), self.withListenSettings(listens.loadConfig()));
        }
    }

    /// Sends this Library's listens and feedback to ListenBrainz, or stops
    /// sending them. Listens are recorded locally either way; one recorded
    /// while this is off is never sent later. At most one Library per runtime
    /// scrobbles. `offline` keeps listens queued without making any request,
    /// and `now_playing` also announces the playing track.
    pub fn librarySetScrobbling(
        self: *OrcaRuntime,
        library: LibraryHandle,
        enabled: bool,
        offline: bool,
        now_playing: bool,
    ) !void {
        try self.requireRunning();
        const object_value = try self.libraries.get(library);
        if (object_value.database == null) return error.LibraryHasNoDatabase;
        if (enabled) {
            if (self.scrobbling_library) |other| {
                if (!other.eql(library)) return error.ScrobblingEnabledElsewhere;
            }
        }
        const listens = if (enabled)
            try self.startListenWorker(library)
        else
            try self.ensureListens(object_value);
        var config = listens.loadConfig();
        config.enabled = enabled;
        config.offline = offline;
        config.now_playing = now_playing;
        listens.configure(self.control_threaded.io(), config);
        if (enabled) {
            self.scrobbling_library = library;
        } else if (self.scrobbling_library) |scrobbling| {
            if (scrobbling.eql(library)) self.scrobbling_library = null;
        }
    }

    /// Tells the Library's worker the ListenBrainz token may have changed. The
    /// worker validates it once, the next time it could make a request, and
    /// reports the user name or the rejection in `libraryScrobblerStatus`.
    pub fn libraryScrobblerCredentialsChanged(self: *OrcaRuntime, library: LibraryHandle) !void {
        try self.requireRunning();
        const object_value = try self.libraries.get(library);
        if (object_value.database == null) return error.LibraryHasNoDatabase;
        (try self.ensureListens(object_value)).credentialsChanged(self.control_threaded.io());
    }

    /// The scrobbler's last published state. A Library without a running
    /// worker reports the queue counts from its database, at most once a
    /// second, and starts nothing.
    pub fn libraryScrobblerStatus(self: *OrcaRuntime, library: LibraryHandle) !ScrobblerStatus {
        try self.requireRunning();
        const object_value = try self.libraries.get(library);
        const listens = object_value.listens;
        if (listens) |existing| {
            if (existing.worker != null) return existing.snapshot();
        }
        var status: ScrobblerStatus = if (listens) |existing| existing.snapshot() else .{ .state = .disabled };
        const counts = self.storedCounts(object_value) orelse return status;
        status.pending = counts.pending;
        status.feedback_pending = counts.feedback_pending;
        status.delivered_total = counts.delivered_total;
        return status;
    }

    fn storedCounts(self: *OrcaRuntime, object_value: *LibraryObject) ?StoredCounts {
        const library_database = object_value.database orelse return null;
        const now_ms = self.sampleTime().mono_ms;
        if (object_value.stored_counts) |counts| {
            if (now_ms - counts.read_at_ms < stored_counts_reuse_ms) return counts;
        }
        const counts: StoredCounts = .{
            .pending = library_database.scrobbles.pendingCount() catch return object_value.stored_counts,
            .feedback_pending = library_database.feedback.pendingSyncCount() catch return object_value.stored_counts,
            .delivered_total = library_database.scrobbles.deliveredCount(providers.listenbrainz.service) catch
                return object_value.stored_counts,
            .read_at_ms = now_ms,
        };
        object_value.stored_counts = counts;
        return counts;
    }

    /// Listens recorded since the Library was opened: one atomic load, so a
    /// host may poll it every tick to learn when to reread its history.
    pub fn libraryListensRecorded(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        try self.requireRunning();
        const listens = (try self.libraries.get(library)).listens orelse return 0;
        return listens.recorded.load(.monotonic);
    }

    pub fn librarySetFeedback(
        self: *OrcaRuntime,
        library: LibraryHandle,
        track_ids: []const i64,
        feedback: Feedback,
    ) !FeedbackChange {
        const library_database = try self.libraryDatabase(library);
        const change = try library_database.feedback.set(track_ids, feedback);
        const listens = (try self.libraries.get(library)).listens orelse return change;
        if (change.updated == 0) return change;
        if (listens.loadConfig().enabled) _ = self.startListenWorker(library) catch {};
        listens.feedbackChanged(self.control_threaded.io());
        return change;
    }

    pub fn libraryMatchProposals(
        self: *OrcaRuntime,
        library: LibraryHandle,
        track_id: i64,
        limit: u32,
    ) !MatchProposalPage {
        return (try self.libraryDatabase(library)).identification_proposals.pendingForTrack(self.allocator, track_id, limit);
    }

    pub fn libraryAcceptMatch(self: *OrcaRuntime, library: LibraryHandle, proposal_id: i64) !MatchAcceptance {
        const acceptance = try (try self.libraryDatabase(library)).identification_proposals.acceptProposal(self.allocator, proposal_id);
        if (acceptance.values_written != 0) self.recordingIdsChanged(library);
        return acceptance;
    }

    pub fn libraryDismissMatch(self: *OrcaRuntime, library: LibraryHandle, proposal_id: i64) !void {
        try (try self.libraryDatabase(library)).identification_proposals.dismiss(proposal_id);
    }

    /// Tracks with a pending proposal, by artist, album and position, each
    /// with its best proposal.
    pub fn libraryMatchReviewPage(
        self: *OrcaRuntime,
        library: LibraryHandle,
        limit: u32,
        offset: u32,
    ) !MatchReviewPage {
        return (try self.libraryDatabase(library)).identification_proposals.reviewPage(self.allocator, limit, offset);
    }

    pub fn libraryMatchReviewCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return (try self.libraryDatabase(library)).identification_proposals.reviewCount();
    }

    /// Tracks a matching job with fingerprints would search: no recording ID,
    /// and not yet answered for by MusicBrainz, or by AcoustID when a key is
    /// set.
    pub fn libraryUnidentifiedCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return (try self.libraryDatabase(library)).identification_proposals.unidentifiedCount(
            .library,
            self.acoustIdInScope(true),
            null,
        );
    }

    /// How many matches `libraryAcceptConfidentMatches` would accept now.
    pub fn libraryConfidentMatchCount(self: *OrcaRuntime, library: LibraryHandle, minimum_confidence: f32) !u64 {
        return (try self.libraryDatabase(library)).identification_proposals.confidentCount(self.allocator, minimum_confidence);
    }

    pub fn libraryAcceptConfidentMatches(self: *OrcaRuntime, library: LibraryHandle, minimum_confidence: f32) !u64 {
        const accepted = try (try self.libraryDatabase(library)).identification_proposals.acceptConfident(self.allocator, minimum_confidence);
        if (accepted != 0) self.recordingIdsChanged(library);
        return accepted;
    }

    fn recordingIdsChanged(self: *OrcaRuntime, library: LibraryHandle) void {
        const object_value = self.libraries.get(library) catch return;
        object_value.stored_counts = null;
        const listens = object_value.listens orelse return;
        if (listens.loadConfig().enabled) _ = self.startListenWorker(library) catch {};
        listens.feedbackChanged(self.control_threaded.io());
    }

    pub fn libraryTrackFeedback(self: *OrcaRuntime, library: LibraryHandle, track_id: i64) !Feedback {
        return (try self.libraryDatabase(library)).feedback.forTrack(track_id);
    }

    /// How often the Track's file has been heard, and when last.
    pub fn libraryTrackPlayStats(self: *OrcaRuntime, library: LibraryHandle, track_id: i64) !PlayStats {
        return (try self.libraryDatabase(library)).listens.trackPlayStats(track_id);
    }

    fn ensureListens(self: *OrcaRuntime, object_value: *LibraryObject) !*listen_worker.Listens {
        if (object_value.listens) |existing| return existing;
        const created = try self.allocator.create(listen_worker.Listens);
        created.* = .{};
        created.configure(self.control_threaded.io(), self.withListenSettings(.{}));
        object_value.listens = created;
        return created;
    }

    /// Starts the Library's listen worker unless it is running.
    fn startListenWorker(self: *OrcaRuntime, library: LibraryHandle) !*listen_worker.Listens {
        const object_value = try self.libraries.get(library);
        const library_database = object_value.database orelse return error.LibraryHasNoDatabase;
        const listens = try self.ensureListens(object_value);
        if (listens.worker != null) return listens;
        const io = try self.networkIo();
        const worker = try self.allocator.create(listen_worker.Worker);
        errdefer self.allocator.destroy(worker);
        const work_handle = try self.work_registry.begin(libraryOwnerTag(library));
        const registration = self.work_registry.registration(work_handle) catch unreachable;
        errdefer {
            registration.finish();
            self.work_registry.complete(work_handle) catch {};
        }
        worker.* = .{
            .allocator = self.allocator,
            .io = io,
            .database = library_database,
            .listens = listens,
            .registration = registration,
            .hooks = self.listen_hooks,
        };
        registration.thread = try std.Thread.spawn(.{}, listen_worker.Worker.run, .{worker});
        listens.worker = worker;
        return listens;
    }

    fn networkIo(self: *OrcaRuntime) !std.Io {
        const threaded = self.network_threaded orelse created: {
            const created = try self.allocator.create(std.Io.Threaded);
            created.* = .init(self.allocator, .{});
            self.network_threaded = created;
            break :created created;
        };
        return threaded.io();
    }

    /// A full drain also joins the scrobbling Library's worker, and its queue
    /// may be waiting on a retry time that no listen will come to restart it
    /// for.
    fn restartScrobblingListenWorker(self: *OrcaRuntime) void {
        const library = self.scrobbling_library orelse return;
        const object_value = self.libraries.get(library) catch return;
        const listens = object_value.listens orelse return;
        if (!listens.loadConfig().enabled) return;
        _ = self.startListenWorker(library) catch {};
    }

    /// Control lane, immediately after `work_registry.drain()`: each worker
    /// recorded its ring before finishing, so it is released here and
    /// restarts on its Library's next listen.
    fn releaseDrainedListenWorkers(self: *OrcaRuntime) void {
        for (self.libraries.slots.items) |*slot| {
            const object_value = if (slot.value) |*value| value else continue;
            const listens = object_value.listens orelse continue;
            const worker = listens.worker orelse continue;
            self.allocator.destroy(worker);
            listens.worker = null;
        }
    }

    /// Between `requestCancellation` and `drain`, so a sleeping worker sees
    /// the cancellation now rather than at the end of its poll.
    fn wakeListenWorkers(self: *OrcaRuntime) void {
        for (self.libraries.slots.items) |*slot| {
            const object_value = if (slot.value) |*value| value else continue;
            const listens = object_value.listens orelse continue;
            listens.wake(self.control_threaded.io());
        }
    }

    fn freeListens(self: *OrcaRuntime, library: *LibraryObject) void {
        const listens = library.listens orelse return;
        std.debug.assert(listens.worker == null);
        self.allocator.destroy(listens);
        library.listens = null;
    }

    fn sampleTime(self: *OrcaRuntime) listen_worker.SampleTime {
        if (self.listen_hooks.sample_clock) |clock| return clock.now();
        const io = self.control_threaded.io();
        return .{
            .mono_ms = std.Io.Clock.awake.now(io).toMilliseconds(),
            .wall_s = std.Io.Clock.real.now(io).toSeconds(),
        };
    }

    /// One lock-free status read per bound Player, turned into listens and
    /// handed to the Library's worker. No SQLite, I/O or allocation here,
    /// except restarting a worker a drain released.
    fn sampleListens(self: *OrcaRuntime) void {
        for (self.players.slots.items) |*slot| {
            const object_value = if (slot.value) |*value| value else continue;
            if (object_value.opener != null) break;
        } else return;
        const now = self.sampleTime();
        if (self.last_listen_sample_ms) |last| {
            if (now.mono_ms - last < listen_sample_interval_ms) return;
        }
        self.last_listen_sample_ms = now.mono_ms;
        for (self.players.slots.items) |*slot| {
            const object_value = if (slot.value) |*value| value else continue;
            const opener = object_value.opener orelse continue;
            const read = readStatus(object_value);
            // A queue entry from a Library this Player was bound to before
            // names a Track id of that Library, not of this one.
            const track_id: ?i64 = if (read.audible) |ref|
                (if (ref.library.eql(opener.library)) ref.track_id else null)
            else
                null;
            const emission = object_value.listens.observe(.{
                .entry_serial = read.status.entry_serial,
                .track_id = track_id,
                .epoch = read.status.epoch,
                .playing = read.status.transport == .playing,
                .drained = object_value.player.drained.load(.acquire),
                .position_ms = read.status.position_ms,
                .duration_ms = read.status.duration_ms,
                .mono_ms = now.mono_ms,
                .wall_s = now.wall_s,
            });
            self.queueListen(opener.library, emission, now.mono_ms);
        }
    }

    /// Ends the listen a Player is in and hands its final time to `library`'s
    /// worker, before the Player stops resolving through that Library.
    fn endListen(self: *OrcaRuntime, object_value: *PlayerObject, library: LibraryHandle) void {
        const emission = object_value.listens.end();
        object_value.listens = .{};
        self.queueListen(library, emission, self.sampleTime().mono_ms);
    }

    /// `endListen` for every Player bound to `library`, or to any Library.
    fn endListens(self: *OrcaRuntime, library: ?LibraryHandle) void {
        for (self.players.slots.items) |*slot| {
            const object_value = if (slot.value) |*value| value else continue;
            const opener = object_value.opener orelse continue;
            if (library) |only| {
                if (!opener.library.eql(only)) continue;
            }
            self.endListen(object_value, opener.library);
        }
    }

    fn announcesNowPlaying(self: *OrcaRuntime, library: LibraryHandle) bool {
        const object_value = self.libraries.get(library) catch return false;
        const listens = object_value.listens orelse return false;
        const config = listens.loadConfig();
        return config.enabled and config.now_playing;
    }

    fn queueListen(self: *OrcaRuntime, library: LibraryHandle, emission: providers.listens.Emission, mono_ms: i64) void {
        const entry: listen_worker.Entry = switch (emission) {
            .none => return,
            .started => |listen| .{ .kind = .now_playing, .listen = listen, .mono_ms = mono_ms },
            .eligible => |listen| .{ .kind = .eligible, .listen = listen },
            .finished => |listen| .{ .kind = .finished, .listen = listen },
        };
        if (entry.kind == .now_playing and !self.announcesNowPlaying(library)) return;
        _ = self.startListenWorker(library) catch {};
        const object_value = self.libraries.get(library) catch return;
        const listens = object_value.listens orelse return;
        listens.push(self.control_threaded.io(), entry);
    }

    pub fn libraryHealthIssueCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return (try self.libraryDatabase(library)).health_issues.count();
    }

    pub fn libraryHealthIssuePage(
        self: *OrcaRuntime,
        library: LibraryHandle,
        limit: u32,
        offset: u32,
    ) !database.HealthIssuePage {
        return (try self.libraryDatabase(library)).health_issues.page(
            self.allocator,
            limit,
            offset,
        );
    }

    pub fn createPlayer(self: *OrcaRuntime) !PlayerHandle {
        try self.requireRunning();
        const player = try self.allocator.create(audio.player.Player);
        errdefer self.allocator.destroy(player);
        player.* = .{};
        const queue = try self.allocator.create(audio.playback_queue.PlaybackQueue);
        errdefer self.allocator.destroy(queue);
        queue.* = .init(self.allocator, self.nextShuffleSeed());
        errdefer queue.deinit();
        const gain = try self.allocator.create(audio.processing.Gain);
        errdefer self.allocator.destroy(gain);
        gain.* = .{};
        const dsp = try self.allocator.create(audio.dsp.PlayerDsp);
        errdefer self.allocator.destroy(dsp);
        dsp.* = .init(gain);
        return self.players.insert(.{
            .player = player,
            .queue = queue,
            .gain = gain,
            .dsp = dsp,
        });
    }

    /// Shuffle must be reproducible when a test asks for it and different
    /// between runs otherwise, so the seed comes from the runtime rather than a
    /// global. Address entropy plus a per-Player counter is enough for a
    /// listening order; nothing here is security-relevant.
    fn nextShuffleSeed(self: *OrcaRuntime) u64 {
        if (self.shuffle_seed) |seed| return seed;
        self.shuffle_counter +%= 1;
        return std.hash.Wyhash.hash(
            @intFromPtr(self) *% 0x9e37_79b9_7f4a_7c15,
            std.mem.asBytes(&self.shuffle_counter),
        );
    }

    pub fn destroyPlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
        try self.requireRunning();
        const destroyed = try self.players.get(player);
        if (destroyed.opener) |opener| self.endListen(destroyed, opener.library);
        self.stopEngine(destroyed);
        // Join only the workers bound to this Player. This used to drain the
        // whole registry, which cancelled every *other* Player's engine and
        // every running scan job as a side effect of destroying one Player --
        // the other engines respawned on their next load, so it read as a
        // stutter rather than as the fault it was, and an in-flight scan was
        // simply lost.
        self.work_registry.drainOwner(playerOwnerTag(player));
        const removed = try self.players.remove(player);
        self.freePlayerObject(removed);
        // Detaching also closes each Zone's output: an OutputSession whose
        // producer is gone would otherwise keep rendering whatever it had left.
        for (self.zones.slots.items) |*slot| {
            if (slot.value) |*zone| {
                if (zone.attached_player) |attached| {
                    if (attached.eql(player)) {
                        zone.attached_player = null;
                        zone.zone.output_requested.store(false, .release);
                        zone.zone.silenced.store(true, .release);
                        zone.zone.closeOutput();
                        zone.zone.resetPipe();
                        zone.zone.zone.close();
                        zone.zone.publishState();
                    }
                }
            }
        }
    }

    pub fn createZone(self: *OrcaRuntime) !ZoneHandle {
        try self.requireRunning();
        const zone = try audio.zone_runtime.ZoneRuntime.create(self.allocator);
        errdefer zone.destroy();
        return self.zones.insert(.{ .zone = zone });
    }

    /// Removes the Zone from its Player's published set, waits for the engine to
    /// acknowledge that removal, and only then closes the output and frees the
    /// Zone. The acknowledgement is the whole safety argument: `handle.Pool` has
    /// no locking, so a generational handle cannot protect a pointer an engine
    /// thread already dereferenced.
    pub fn destroyZone(self: *OrcaRuntime, zone: ZoneHandle) !void {
        try self.requireRunning();
        const object_value = try self.zones.get(zone);
        const attached = object_value.attached_player;
        object_value.attached_player = null;
        if (attached) |player| try self.republishZones(player);
        const removed = try self.zones.remove(zone);
        removed.zone.destroy();
    }

    pub fn attachZone(self: *OrcaRuntime, zone: ZoneHandle, player: PlayerHandle) !void {
        try self.requireRunning();
        _ = try self.players.get(player);
        const object_value = try self.zones.get(zone);
        const previous = object_value.attached_player;
        object_value.attached_player = player;
        errdefer object_value.attached_player = previous;
        if (previous) |old| {
            if (!old.eql(player)) try self.republishZones(old);
        }
        try self.republishZones(player);
    }

    pub fn detachZone(self: *OrcaRuntime, zone: ZoneHandle) !void {
        try self.requireRunning();
        const object_value = try self.zones.get(zone);
        const attached = object_value.attached_player orelse return;
        object_value.attached_player = null;
        try self.republishZones(attached);
        const detached = try self.zones.get(zone);
        detached.zone.output_requested.store(false, .release);
        detached.zone.silenced.store(true, .release);
        detached.zone.closeOutput();
        detached.zone.resetPipe();
        detached.zone.zone.close();
        detached.zone.publishState();
    }

    /// Asks the Zone's engine to open (or close) its output. Stream creation
    /// itself happens on the engine lane, never on the caller's thread.
    pub fn zoneRequestOutput(self: *OrcaRuntime, zone: ZoneHandle, device_id: u64) !void {
        try self.requireRunning();
        const object_value = try self.zones.get(zone);
        object_value.zone.requested_device_id.store(device_id, .release);
        object_value.zone.output_requested.store(true, .release);
        if (object_value.attached_player) |player| {
            if ((try self.players.get(player)).engine) |engine| engine.wakeUp();
        }
    }

    pub fn zoneCloseOutput(self: *OrcaRuntime, zone: ZoneHandle) !void {
        try self.requireRunning();
        const object_value = try self.zones.get(zone);
        object_value.zone.output_requested.store(false, .release);
        if (object_value.attached_player) |player| {
            if ((try self.players.get(player)).engine) |engine| {
                engine.wakeUp();
                return;
            }
        }
        object_value.zone.closeOutput();
        object_value.zone.resetPipe();
        object_value.zone.zone.close();
        object_value.zone.publishState();
    }

    /// Bounded, Orca-owned device snapshots. No backend type crosses this API.
    pub fn enumerateOutputDevices(
        self: *OrcaRuntime,
        devices: []audio.backend.Device,
    ) !usize {
        try self.requireRunning();
        const factory = self.outputFactory() orelse return 0;
        return factory.discover(devices);
    }

    pub fn setZonePolicy(
        self: *OrcaRuntime,
        zone: ZoneHandle,
        policy: audio.zone.RenderPolicy,
    ) !void {
        try self.requireRunning();
        const object_value = try self.zones.get(zone);
        try self.requireZoneIdle(object_value);
        object_value.zone.zone.policy = policy;
    }

    pub fn zoneRenderStrategy(
        self: *OrcaRuntime,
        zone: ZoneHandle,
    ) !audio.zone.RenderStrategy {
        try self.requireRunning();
        return (try self.zones.get(zone)).zone.zone.renderStrategy();
    }

    /// Reads the state the engine publishes, never the engine-owned `Zone`
    /// struct itself.
    pub fn zoneOutputState(self: *OrcaRuntime, zone: ZoneHandle) !audio.zone.OutputState {
        try self.requireRunning();
        return (try self.zones.get(zone)).zone.outputState();
    }

    pub fn zoneStats(self: *OrcaRuntime, zone: ZoneHandle) !ZoneStats {
        try self.requireRunning();
        const object_value = try self.zones.get(zone);
        return .{
            .output_state = object_value.zone.outputState(),
            .recovery_attempts = object_value.zone.published_recovery_attempts.load(.acquire),
            .underruns = object_value.zone.pipe.underruns.load(.monotonic),
            .dropped_returns = object_value.zone.pipe.dropped_returns.load(.monotonic),
            .backend_quantum_frames = object_value.zone.published_quantum_frames.load(.acquire),
            .rendered_entry_serial = object_value.zone.rendered_entry_serial.load(.monotonic),
        };
    }

    fn markZoneOutputLost(self: *OrcaRuntime, zone: ZoneHandle) !void {
        try self.requireRunning();
        const object_value = try self.zones.get(zone);
        try self.requireZoneIdle(object_value);
        object_value.zone.zone.deviceLost();
        object_value.zone.publishState();
    }

    fn beginZoneRecovery(self: *OrcaRuntime, zone: ZoneHandle) !void {
        try self.requireRunning();
        const object_value = try self.zones.get(zone);
        try self.requireZoneIdle(object_value);
        object_value.zone.zone.beginRecovery();
        object_value.zone.publishState();
    }

    fn failZoneRecovery(self: *OrcaRuntime, zone: ZoneHandle) !void {
        try self.requireRunning();
        const object_value = try self.zones.get(zone);
        try self.requireZoneIdle(object_value);
        object_value.zone.zone.recoveryFailed();
        object_value.zone.publishState();
    }

    /// Output state belongs to whichever lane currently owns the Zone. Once an
    /// engine holds it, only the engine may mutate it.
    fn requireZoneIdle(self: *OrcaRuntime, object_value: *ZoneObject) !void {
        const player = object_value.attached_player orelse return;
        if ((try self.players.get(player)).engine != null)
            return error.ZoneOwnedByEngine;
    }

    /// Seeking moves the decoder, which the engine thread is otherwise reading
    /// from, so the engine is stopped for the duration. The epoch bump is what
    /// makes the audio already prepared under the old position disappear.
    pub fn seekPlayer(self: *OrcaRuntime, player: PlayerHandle, frame: u64) !u32 {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        if (object_value.engine) |engine| {
            engine.quiesce();
            defer engine.release();
            return try object_value.player.seek(frame);
        }
        return try object_value.player.seek(frame);
    }

    /// Refuses a transport start that cannot produce audio.
    ///
    /// A Player with neither a loaded source nor a queue entry to load has
    /// nothing to play, and one with no attached Zone has nowhere to play it.
    /// Both used to "succeed" into a detached state machine that reported
    /// PLAYING while nothing was rendering; the C ABI smoke test now asserts
    /// the rejection instead.
    pub fn playPlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        if (object_value.player.sources == null and object_value.queue.isEmpty())
            return error.PlayerHasNoSource;
        if (!self.playerHasZone(player)) return error.PlayerHasNoOutput;
        object_value.player.play();
    }

    pub fn pausePlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
        try self.requireRunning();
        (try self.players.get(player)).player.pause();
    }

    /// Stops the transport and releases its decoders. Entries and cursor
    /// survive, so `stop` then `play` resumes the same queue at the same place.
    pub fn stopPlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        if (object_value.engine) |engine| {
            engine.quiesce();
            defer engine.release();
            engine.discardPending();
            object_value.player.stop();
            object_value.player.releaseSources();
            return;
        }
        object_value.player.stop();
        object_value.player.releaseSources();
    }

    pub fn playerSnapshot(self: *OrcaRuntime, player: PlayerHandle) !audio.player.Snapshot {
        try self.requireRunning();
        return (try self.players.get(player)).player.snapshot();
    }

    /// Opens `path`, detects its codec, and hands the resulting self-contained
    /// SourceSession to the Player, spawning its engine thread if this is the
    /// Player's first source. The `LocalFileSource` is heap-owned by the
    /// session, so nothing backing the decoder lives in the caller's frame.
    pub fn playerLoadFile(
        self: *OrcaRuntime,
        player: PlayerHandle,
        io: std.Io,
        path: []const u8,
    ) !void {
        try self.requireRunning();
        _ = try self.players.get(player);
        const source = try audio.loaded_source.LoadedSource.open(
            self.allocator,
            io,
            @import("../codec/registry.zig").CodecRegistry.builtins(),
            path,
        );
        var owned = source;
        errdefer owned.deinit();
        const format = owned.decoder.format;
        if (format.channels == 0 or format.channels > audio.zone_runtime.max_channels)
            return error.UnsupportedChannelCount;
        const engine = try self.ensureEngine(player);
        // The engine is the Player's only decoder; swapping the SourceQueue
        // under it would race its own reads.
        engine.quiesce();
        defer engine.release();
        (try self.players.get(player)).player.replaceSource(owned);
    }

    /// True once the source has decoded to its end and every Zone has handed
    /// back every block it was given.
    pub fn playerDrained(self: *OrcaRuntime, player: PlayerHandle) !bool {
        try self.requireRunning();
        const engine = (try self.players.get(player)).engine orelse return false;
        return engine.isDrained();
    }

    fn freePlayerObject(self: *OrcaRuntime, object_value: PlayerObject) void {
        if (object_value.opener) |opener| opener.destroy();
        self.allocator.destroy(object_value.dsp);
        self.allocator.destroy(object_value.gain);
        object_value.queue.deinit();
        self.allocator.destroy(object_value.queue);
        object_value.player.deinit();
        self.allocator.destroy(object_value.player);
    }

    // ----------------------------------------------------------- playback queue

    /// Binds this Player's queue to a Library, opening the independent
    /// read-only connection its entries are resolved through. Re-binding to a
    /// different Library replaces the opener, which is why it stops the engine
    /// first: the engine holds the opener by value.
    pub fn playerBindLibrary(
        self: *OrcaRuntime,
        player: PlayerHandle,
        library: LibraryHandle,
        io: std.Io,
    ) !void {
        try self.requireRunning();
        const existing = try self.players.get(player);
        if (existing.opener) |opener| {
            if (opener.library.eql(library)) return;
        }
        const library_database = try self.libraryDatabase(library);
        _ = try self.startListenWorker(library);
        const opener = try track_source.TrackSourceOpener.create(
            self.allocator,
            io,
            library,
            library_database,
        );
        errdefer opener.destroy();

        const object_value = try self.players.get(player);
        if (object_value.opener) |old| self.endListen(object_value, old.library);
        if (object_value.engine) |engine| {
            engine.quiesce();
            defer engine.release();
            if (object_value.opener) |old| old.destroy();
            object_value.opener = opener;
            engine.opener = opener.opener();
        } else {
            if (object_value.opener) |old| old.destroy();
            object_value.opener = opener;
        }
    }

    /// B3: `track id -> playing audio`. Resolves the Track's location on an
    /// independent read-only connection, opens a self-contained SourceSession
    /// for it, and hard-loads it. Never on a host's UI thread: this is the
    /// runtime's control lane, and the file I/O is deliberately here rather
    /// than anywhere near a render callback.
    pub fn playerPlayTrack(
        self: *OrcaRuntime,
        player: PlayerHandle,
        library: LibraryHandle,
        io: std.Io,
        track_id: i64,
    ) !void {
        return self.playerPlayTracks(player, library, io, &.{track_id}, 0);
    }

    /// The same call for a Player already bound to `library`. This is the form
    /// the command lane uses: binding is the step that needs an `std.Io`, and
    /// it has already happened by the time a `play_track` command executes.
    pub fn playerPlayTrackBound(
        self: *OrcaRuntime,
        player: PlayerHandle,
        library: LibraryHandle,
        track_id: i64,
    ) !void {
        return self.playerPlayTracksBound(player, library, &.{track_id}, 0);
    }

    /// `playNow`: replace the queue, load `start`, bump the epoch, play.
    pub fn playerPlayTracks(
        self: *OrcaRuntime,
        player: PlayerHandle,
        library: LibraryHandle,
        io: std.Io,
        track_ids: []const i64,
        start: u32,
    ) !void {
        try self.requireRunning();
        try self.playerBindLibrary(player, library, io);
        return self.playerPlayTracksBound(player, library, track_ids, start);
    }

    pub fn playerPlayTracksBound(
        self: *OrcaRuntime,
        player: PlayerHandle,
        library: LibraryHandle,
        track_ids: []const i64,
        start: u32,
    ) !void {
        try self.requireRunning();
        try self.requireBoundLibrary(player, library);
        const refs = try self.trackRefs(library, track_ids);
        defer self.allocator.free(refs);
        const engine = try self.ensureEngine(player);
        engine.quiesce();
        defer engine.release();
        engine.discardPending();
        const object_value = try self.players.get(player);
        try object_value.queue.replace(refs, start);
        // `replace` has already destroyed whatever this Player was playing, so
        // a start that cannot open its first entry has no consistent state to
        // fall back to. Leaving the transport running would advertise a
        // now-playing track that is not playing and cannot be made to play.
        // Unwind to genuinely stopped instead.
        errdefer {
            object_value.player.stop();
            object_value.player.releaseSources();
            object_value.queue.clear();
        }
        try loadCursor(object_value);
        object_value.player.play();
    }

    /// Appends to the queue. An idle Player starts on the first new entry —
    /// "enqueue into nothing" is how a host begins playback without a separate
    /// play call.
    pub fn playerEnqueueTracks(
        self: *OrcaRuntime,
        player: PlayerHandle,
        library: LibraryHandle,
        io: std.Io,
        track_ids: []const i64,
    ) !void {
        try self.requireRunning();
        try self.playerBindLibrary(player, library, io);
        return self.playerEnqueueTracksBound(player, library, track_ids);
    }

    pub fn playerEnqueueTracksBound(
        self: *OrcaRuntime,
        player: PlayerHandle,
        library: LibraryHandle,
        track_ids: []const i64,
    ) !void {
        try self.requireRunning();
        try self.requireBoundLibrary(player, library);
        const refs = try self.trackRefs(library, track_ids);
        defer self.allocator.free(refs);
        const engine = try self.ensureEngine(player);
        engine.quiesce();
        defer engine.release();
        const object_value = try self.players.get(player);
        const was_idle = object_value.player.sources == null;
        const first_new = object_value.queue.len();
        try object_value.queue.enqueue(refs);
        if (!was_idle or refs.len == 0) return;
        engine.discardPending();
        object_value.queue.seekTo(first_new);
        try loadCursor(object_value);
        object_value.player.play();
    }

    /// Plays the queue entry at playback position `position` now: a hard
    /// switch, like a skip.
    pub fn playerQueueJump(self: *OrcaRuntime, player: PlayerHandle, position: u32) !void {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        if (position >= object_value.queue.len()) return error.PositionOutOfRange;
        const engine = object_value.engine;
        if (engine) |value| value.quiesce();
        defer if (engine) |value| value.release();
        if (engine) |value| value.discardPending();
        object_value.queue.seekTo(position);
        try loadCursor(object_value);
        object_value.player.play();
    }

    /// Queues `track_ids` to play after the current entry, without
    /// interrupting it. If the engine has already lined up the entry after
    /// the current one — it does so when the current one finishes decoding,
    /// a few seconds before its end — they follow that entry instead, since
    /// its audio may already be on its way to the output. An empty queue is
    /// simply filled, as `playerEnqueueTracksBound` does.
    pub fn playerQueueInsertNext(
        self: *OrcaRuntime,
        player: PlayerHandle,
        library: LibraryHandle,
        track_ids: []const i64,
    ) !void {
        try self.requireRunning();
        try self.requireBoundLibrary(player, library);
        if ((try self.players.get(player)).queue.isEmpty())
            return self.playerEnqueueTracksBound(player, library, track_ids);
        const refs = try self.trackRefs(library, track_ids);
        defer self.allocator.free(refs);
        const engine = try self.ensureEngine(player);
        engine.quiesce();
        defer engine.release();
        const queue = (try self.players.get(player)).queue;
        const committed = if (engine.pending_source != null) engine.pending_position else queue.decodePosition();
        const pending: ?*u32 = if (engine.pending_source != null) &engine.pending_position else null;
        try queue.insertAfter(committed, refs, pending);
    }

    /// Removes the queue entry at playback position `position`. The entry
    /// playing and one the engine has already lined up are refused with
    /// `error.QueueEntryInUse`; skip past them first.
    pub fn playerQueueRemove(self: *OrcaRuntime, player: PlayerHandle, position: u32) !void {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        const queue = object_value.queue;
        if (position >= queue.len()) return error.PositionOutOfRange;
        const engine = object_value.engine;
        if (engine) |value| value.quiesce();
        defer if (engine) |value| value.release();
        const pending: ?*u32 = if (engine) |value|
            (if (value.pending_source != null) &value.pending_position else null)
        else
            null;
        const holds_audio = object_value.player.sources != null;
        if (holds_audio and (position == queue.cursorPosition() or position == queue.decodePosition()))
            return error.QueueEntryInUse;
        if (pending) |value| if (value.* == position) return error.QueueEntryInUse;
        try queue.removeAt(position, pending);
    }

    /// A user skip is a **hard** switch: the epoch bump makes the callback
    /// discard everything already prepared, so it is immediate rather than
    /// waiting for the current track to drain. Returns false at the end of a
    /// queue that is not repeating.
    pub fn playerNext(self: *OrcaRuntime, player: PlayerHandle) !bool {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        const engine = object_value.engine;
        if (engine) |value| value.quiesce();
        defer if (engine) |value| value.release();
        if (engine) |value| value.discardPending();
        const target = object_value.queue.nextPosition() orelse return false;
        object_value.queue.seekTo(target);
        try loadCursor(object_value);
        object_value.player.play();
        return true;
    }

    /// Past three seconds `previous` restarts the current entry; before it, the
    /// cursor moves back. The universal transport convention, and the reason a
    /// shuffle permutation matters: random-next has no history to move back to.
    pub fn playerPrevious(self: *OrcaRuntime, player: PlayerHandle) !bool {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        const engine = object_value.engine;
        if (engine) |value| value.quiesce();
        defer if (engine) |value| value.release();
        if (object_value.player.format()) |format| {
            if (format.sample_rate != 0) {
                const frames = object_value.player.snapshot().position_frames;
                const elapsed_ms = frames * 1000 / format.sample_rate;
                if (elapsed_ms > audio.playback_queue.restart_threshold_ms) {
                    _ = try object_value.player.seek(0);
                    return true;
                }
            }
        }
        const target = object_value.queue.previousPosition() orelse {
            if (object_value.player.sources != null) _ = try object_value.player.seek(0);
            return false;
        };
        if (engine) |value| value.discardPending();
        object_value.queue.seekTo(target);
        try loadCursor(object_value);
        object_value.player.play();
        return true;
    }

    pub fn playerSetRepeat(
        self: *OrcaRuntime,
        player: PlayerHandle,
        mode: RepeatMode,
    ) !void {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        if (object_value.engine) |engine| {
            engine.quiesce();
            defer engine.release();
            object_value.queue.setRepeat(mode);
            return;
        }
        object_value.queue.setRepeat(mode);
    }

    pub fn playerSetShuffle(
        self: *OrcaRuntime,
        player: PlayerHandle,
        enabled: bool,
    ) !void {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        if (object_value.engine) |engine| {
            engine.quiesce();
            defer engine.release();
            return object_value.queue.setShuffle(enabled);
        }
        return object_value.queue.setShuffle(enabled);
    }

    /// Empties the queue and releases the decoders with it.
    pub fn playerClearQueue(self: *OrcaRuntime, player: PlayerHandle) !void {
        try self.requireRunning();
        try self.stopPlayer(player);
        const object_value = try self.players.get(player);
        if (object_value.engine) |engine| {
            engine.quiesce();
            defer engine.release();
            object_value.queue.clear();
            return;
        }
        object_value.queue.clear();
    }

    /// Lock-free: entry count, audible cursor and decode cursor all come from
    /// atomics, so a host may poll this at UI rates without stopping the engine.
    pub fn playerQueueSnapshot(
        self: *OrcaRuntime,
        player: PlayerHandle,
    ) !QueueSnapshot {
        try self.requireRunning();
        return (try self.players.get(player)).queue.snapshot();
    }

    /// The entry actually being *heard*, which during a gapless transition is
    /// not the one the decoder has reached.
    ///
    /// Lock-free, deliberately: the entry list is mutated only by the control
    /// lane and the engine thread only ever reads it, so a control-lane reader
    /// cannot race one. Quiescing the producer to answer "what is playing"
    /// would park decoding on every UI poll.
    pub fn playerNowPlaying(self: *OrcaRuntime, player: PlayerHandle) !?TrackRef {
        try self.requireRunning();
        return (try self.players.get(player)).queue.current();
    }

    fn requireBoundLibrary(
        self: *OrcaRuntime,
        player: PlayerHandle,
        library: LibraryHandle,
    ) !void {
        const opener = (try self.players.get(player)).opener orelse
            return error.PlayerHasNoLibrary;
        if (!opener.library.eql(library)) return error.PlayerBoundToAnotherLibrary;
    }

    /// Reads engine-thread counters, so it stops the engine for the duration.
    /// Called after a run, never in a UI poll loop.
    pub fn playerQueueStats(self: *OrcaRuntime, player: PlayerHandle) !QueueStats {
        try self.requireRunning();
        const engine = (try self.players.get(player)).engine orelse return .{
            .entries_started = 0,
            .gapless_transitions = 0,
            .format_switch_transitions = 0,
            .open_failures = 0,
            .decode_errors = 0,
        };
        engine.quiesce();
        defer engine.release();
        return .{
            .entries_started = engine.entries_started,
            .gapless_transitions = engine.gapless_transitions,
            .format_switch_transitions = engine.format_switch_transitions,
            .open_failures = engine.open_failures,
            .decode_errors = engine.decode_errors,
        };
    }

    /// Seek to `tail_ms` before the end of the current entry. Exists so tests
    /// and the CLI can exercise a real album's transitions without waiting out
    /// every track in real time.
    pub fn playerSeekToTail(
        self: *OrcaRuntime,
        player: PlayerHandle,
        tail_ms: u64,
    ) !bool {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        const engine = object_value.engine;
        if (engine) |value| value.quiesce();
        defer if (engine) |value| value.release();
        const format = object_value.player.format() orelse return false;
        const total = object_value.player.frameCount() orelse return false;
        if (format.sample_rate == 0) return false;
        const tail_frames = tail_ms * format.sample_rate / 1000;
        _ = try object_value.player.seek(total -| tail_frames);
        return true;
    }

    fn trackRefs(
        self: *OrcaRuntime,
        library: LibraryHandle,
        track_ids: []const i64,
    ) ![]TrackRef {
        if (track_ids.len > audio.playback_queue.capacity) return error.PlaybackQueueFull;
        const refs = try self.allocator.alloc(TrackRef, track_ids.len);
        for (track_ids, refs) |id, *ref| ref.* = .{ .library = library, .track_id = id };
        return refs;
    }

    /// Opens the entry under the cursor and hard-loads it. The caller must have
    /// quiesced the engine: this replaces the Player's whole `SourceQueue`.
    fn loadCursor(object_value: *PlayerObject) !void {
        const opener = object_value.opener orelse return error.PlayerHasNoLibrary;
        const cursor = object_value.queue.cursorPosition();
        const ref = object_value.queue.current() orelse {
            object_value.player.releaseSources();
            return;
        };
        var session = try opener.openTrack(ref);
        const format = session.decoder.format;
        if (format.channels == 0 or format.channels > audio.zone_runtime.max_channels) {
            session.deinit();
            return error.UnsupportedChannelCount;
        }
        object_value.player.replaceSource(session);
        object_value.queue.seekTo(cursor);
        object_value.queue.noteEntrySerial(object_value.player.entrySerial(), cursor);
    }

    /// Spawns the Player's single decode producer. Registered with
    /// `work.Registry`, so `drain`, `destroyPlayer` and `shutdown` all join it
    /// rather than leaving it running against freed objects.
    fn ensureEngine(self: *OrcaRuntime, player: PlayerHandle) !*audio.engine.PlayerEngine {
        if ((try self.players.get(player)).engine) |existing| return existing;
        const factory = self.outputFactory();
        const object_state = try self.players.get(player);
        const engine = try audio.engine.PlayerEngine.create(self.allocator, .{
            .player = object_state.player,
            .handle = player,
            .telemetry = &self.telemetry,
            .factory = factory,
            .queue = object_state.queue,
            .opener = if (object_state.opener) |opener| opener.opener() else null,
            .dsp = object_state.dsp,
        });
        errdefer engine.destroy();
        const work_handle = try self.work_registry.begin(playerOwnerTag(player));
        const registration = self.work_registry.registration(work_handle) catch unreachable;
        // `complete` waits for the worker, so a registration whose thread never
        // started has to be marked finished or the wait would never return.
        errdefer {
            registration.finish();
            self.work_registry.complete(work_handle) catch {};
        }
        engine.registration = registration;
        // The engine must never resolve a handle, so it is handed its zone set
        // before it starts and re-handed one on every attach or detach.
        try self.publishZonesTo(player, engine);
        registration.thread = try std.Thread.spawn(
            .{},
            audio.engine.PlayerEngine.run,
            .{engine},
        );
        const object_value = try self.players.get(player);
        object_value.engine = engine;
        object_value.engine_work = work_handle;
        return engine;
    }

    fn publishZonesTo(
        self: *OrcaRuntime,
        player: PlayerHandle,
        engine: *audio.engine.PlayerEngine,
    ) !void {
        var zones: [audio.engine.max_zones]*audio.zone_runtime.ZoneRuntime = undefined;
        var count: usize = 0;
        for (self.zones.slots.items) |*slot| {
            if (slot.value) |zone| {
                const attached = zone.attached_player orelse continue;
                if (!attached.eql(player)) continue;
                if (count == zones.len) return error.TooManyZones;
                zones[count] = zone.zone;
                count += 1;
            }
        }
        try engine.publishZones(zones[0..count]);
    }

    fn republishZones(self: *OrcaRuntime, player: PlayerHandle) !void {
        const object_value = self.players.get(player) catch return;
        const engine = object_value.engine orelse return;
        try self.publishZonesTo(player, engine);
    }

    /// Cancels and joins one Player's engine thread, then frees it. On return no
    /// engine can reach this Player's Zones, which is the precondition for
    /// closing their outputs.
    fn stopEngine(self: *OrcaRuntime, object_value: *PlayerObject) void {
        const engine = object_value.engine orelse return;
        if (object_value.engine_work) |work_handle|
            self.work_registry.complete(work_handle) catch {};
        // The thread is joined, so a successor it had opened but never handed
        // to the Player is this lane's to release.
        engine.releasePending();
        engine.destroy();
        object_value.engine = null;
        object_value.engine_work = null;
    }

    /// A blanket `drain` cancels and joins every engine thread, so on return no
    /// engine object still has a live thread or a valid registration. They are
    /// reaped rather than left behind as pointers to threads that already exited.
    fn reapStoppedEngines(self: *OrcaRuntime) void {
        std.debug.assert(self.work_registry.count() == 0);
        for (self.players.slots.items) |*slot| {
            if (slot.value) |*object_value| {
                const engine = object_value.engine orelse continue;
                engine.releasePending();
                engine.destroy();
                object_value.engine = null;
                object_value.engine_work = null;
            }
        }
    }

    // --------------------------------------------------------------- roots

    /// Registers a Library root. Explicitly a user action, which is why this is
    /// the one path allowed to persist a volume identifier at a mount root.
    pub fn libraryAddRoot(
        self: *OrcaRuntime,
        library: LibraryHandle,
        io: std.Io,
        path: []const u8,
    ) !database.RootBinding {
        try self.requireRunning();
        const library_database = try self.libraryDatabase(library);
        return library_database.ensureRoot(io, path, .{ .allow_persist = true });
    }

    /// Forgets a root and everything that exists only under it: its files,
    /// their tags and Orca values, and the Tracks, Releases and Artists they
    /// backed. Nothing on disk is touched. A file also located under another
    /// root stays and is reprojected. Refused while any job on the Library
    /// runs, since each of them writes rows keyed by the files this deletes.
    pub fn libraryRemoveRoot(
        self: *OrcaRuntime,
        library: LibraryHandle,
        root_id: i64,
    ) !RemovedRoot {
        try self.requireRunning();
        const library_database = try self.libraryDatabase(library);
        for (self.job_workers.items) |worker| {
            if (!worker.retired and worker.library.eql(library)) return error.LibraryJobRunning;
        }
        const removal = try library_database.library_roots.remove(self.allocator, root_id);
        defer removal.deinit();
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
        return (try self.libraryDatabase(library)).library_roots.page(
            self.allocator,
            limit,
            offset,
        );
    }

    pub fn libraryTrackSummary(
        self: *OrcaRuntime,
        library: LibraryHandle,
        track_id: i64,
    ) !?database.TrackSummary {
        return (try self.libraryDatabase(library)).tracks.byId(self.allocator, track_id);
    }

    /// What the Library recorded about a Track and the file it plays: tags,
    /// format, size, location, stored loudness and whether the file carries a
    /// cover, or null when the Track does not exist. Read from the database
    /// alone: the file is neither opened nor hashed, so it describes the file
    /// as the last scan saw it.
    pub fn libraryTrackDetails(
        self: *OrcaRuntime,
        library: LibraryHandle,
        track_id: i64,
    ) !?TrackDetails {
        return track_details.load(self.allocator, try self.libraryDatabase(library), track_id);
    }

    /// Sets or clears Orca's own values for tracks, without touching their
    /// files: a set value is stored as a locked user edit on every file each
    /// track resolves to, so it outranks the files' tags and survives rescans,
    /// and a cleared one lets the tags apply again. The affected files are
    /// reprojected before this returns, on the caller's thread; a track may
    /// get a new id if the edit moves it to another release.
    pub fn libraryEditTracks(
        self: *OrcaRuntime,
        library: LibraryHandle,
        track_ids: []const i64,
        edits: []const TrackEdit,
    ) !EditedTracks {
        if (track_ids.len == 0 or track_ids.len > database.repository.max_page) return error.InvalidTrackSelection;
        if (edits.len == 0) return error.NoTrackEdits;
        for (edits) |edit| if (edit.value) |value| try validateEdit(edit.field, value);
        const library_database = try self.libraryDatabase(library);

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

    /// Orca's values for a track, read from its preferred file.
    pub fn libraryTrackEdits(
        self: *OrcaRuntime,
        library: LibraryHandle,
        track_id: i64,
    ) !TrackEditPage {
        const library_database = try self.libraryDatabase(library);
        const ids = try library_database.tracks.fileIds(self.allocator, track_id);
        defer self.allocator.free(ids);
        if (ids.len == 0) return error.TrackNotFound;
        return library_database.orca_metadata.values(self.allocator, ids[0]);
    }

    /// Builds and seals a plan that writes Orca's values for `track_ids` into
    /// their files, and returns it for approval. Nothing is written. A file is
    /// left out when it has nothing to write, and reported in `skipped` when it
    /// cannot be written now. The plan waits in the runtime for
    /// `startTagWrite`; at most eight wait at once.
    pub fn planTagWrite(
        self: *OrcaRuntime,
        library: LibraryHandle,
        io: std.Io,
        track_ids: []const i64,
    ) !TagWritePlan {
        if (track_ids.len == 0 or track_ids.len > database.repository.max_page) return error.InvalidTrackSelection;
        const library_database = try self.libraryDatabase(library);

        const preview_arena = try self.allocator.create(std.heap.ArenaAllocator);
        preview_arena.* = .init(self.allocator);
        var preview: TagWritePlan = .{ .arena = preview_arena, .plan_id = 0, .digest = @splat(0), .files = &.{}, .skipped = &.{} };
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
        var files: std.ArrayList(TagWriteFile) = .empty;
        var skipped: std.ArrayList(TagWriteSkip) = .empty;
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
                if (!value.field.writesToFiles()) continue;
                const before = try observedText(scratch, tags, value.field);
                if (before) |current| if (std.mem.eql(u8, current, value.text)) continue;
                try changes.append(scratch, .{ .field = value.field, .before = before, .after = value.text });
                try shown.append(owned, .{
                    .field = value.field,
                    .before = if (before) |text| try owned.dupe(u8, text) else null,
                    .after = try owned.dupe(u8, value.text),
                });
            }
            if (changes.items.len == 0) continue;
            try actions.append(scratch, .{ .write_tags = .{
                .path = location.uri,
                .expected = try metadata.file_mutation.identity(io, location.uri),
                .changes = changes.items,
            } });
            try locations.append(scratch, location);
            try files.append(owned, .{ .file_id = file_id, .path = try owned.dupe(u8, location.uri), .changes = shown.items });
        }
        preview.skipped = skipped.items;
        if (actions.items.len == 0) return preview;

        const slot = for (&self.pending_tag_writes) |*candidate| {
            if (candidate.* == null) break candidate;
        } else return error.TooManyPendingTagWrites;
        var plan_id = try library_database.mutation_journal.nextGroupId();
        for (self.pending_tag_writes) |held| if (held) |pending| {
            plan_id = @max(plan_id, pending.plan.id + 1);
        };

        const pending = try self.allocator.create(PendingTagWrite);
        errdefer self.allocator.destroy(pending);
        pending.* = .{
            .arena = .init(self.allocator),
            .library = library,
            .plan = try metadata.mutation.Plan.init(self.allocator, plan_id, actions.items),
            .locations = &.{},
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

        preview.files = files.items;
        preview.plan_id = plan_id;
        preview.digest = pending.plan.approval().digest;
        slot.* = pending;
        return preview;
    }

    /// Approves a pending plan by its digest and starts writing it as a job.
    /// A digest that does not match the plan leaves it pending and unwritten.
    /// The job is not cancellable once started: a journaled group finishes or
    /// rolls back as a whole. The files are re-observed and reprojected when
    /// it ends.
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
        const pending = slot.*.?;
        try pending.plan.approve(.{ .plan_id = plan_id, .digest = digest });
        const job_handle = try self.startJobWorker(library, .mutation, .{ .tag_write = pending });
        slot.* = null;
        return job_handle;
    }

    /// Drops a pending plan without writing anything.
    pub fn discardTagWrite(self: *OrcaRuntime, library: LibraryHandle, plan_id: u64) !void {
        for (&self.pending_tag_writes) |*candidate| {
            const pending = candidate.* orelse continue;
            if (pending.plan.id != plan_id or !pending.library.eql(library)) continue;
            pending.destroy();
            candidate.* = null;
            return;
        }
        return error.UnknownTagWritePlan;
    }

    /// Restores the files a tag write changed, on the caller's thread, and
    /// re-observes them. Orca's values are kept, so the library still shows
    /// the edit. A file changed again since the write is left alone and
    /// recorded for reconciliation rather than overwritten.
    pub fn undoTagWrite(self: *OrcaRuntime, library: LibraryHandle, io: std.Io, group_id: u64) !void {
        const library_database = try self.libraryDatabase(library);
        for (self.job_workers.items) |worker| {
            const pending = worker.tag_write orelse continue;
            if (!worker.retired and pending.plan.id == group_id) return error.TagWriteInProgress;
        }
        var executor: metadata.executor.Executor = .{
            .allocator = self.allocator,
            .io = io,
            .journal = &library_database.mutation_journal,
        };
        try executor.undoGroup(group_id);
        const operations = try library_database.mutation_journal.groupOperationIds(self.allocator, group_id);
        defer self.allocator.free(operations);
        for (operations) |operation_id| {
            var operation = try library_database.mutation_journal.get(self.allocator, operation_id);
            defer operation.deinit();
            const location = try library_database.locations.presentByUri(self.allocator, operation.source_path) orelse continue;
            defer self.allocator.free(location.uri);
            try reobserve(self.allocator, io, library_database, location);
        }
    }

    // ---------------------------------------------------------------- jobs

    /// Starts a filesystem scan on a registered `work.Registry` worker and
    /// returns immediately. Everything the scan needs — its own `std.Io`, its
    /// own cancellation token, the Library's serialized write lane — belongs to
    /// the worker, so the caller's thread is never blocked by a walk.
    ///
    /// **The scan projects as it commits.** Each committed batch hands its file
    /// ids to `library.Projection`, exactly as `orca-cli scan` does, because a
    /// scan whose results are not projected has not made the library browsable.
    /// `startLibraryProjection` exists for the other direction: reprojecting
    /// without a walk, after a metadata edit.
    pub fn startLibraryScan(
        self: *OrcaRuntime,
        library: LibraryHandle,
        request: ScanRequest,
    ) !JobHandle {
        return self.startJobWorker(library, .scan, .{
            .root_id = request.root_id,
            .batch_size = request.batch_size,
        });
    }

    pub fn startLibraryProjection(self: *OrcaRuntime, library: LibraryHandle) !JobHandle {
        return self.startJobWorker(library, .projection, .{});
    }

    /// Starts the property backfill: probes the headers of `files` rows whose
    /// declared audio properties are missing, and reprojects each repaired
    /// batch so the Tracks derived from them stop reading zero.
    ///
    /// Unlike a scan this job has an honest denominator before it starts —
    /// which rows still owe a probe is one indexed count — so its snapshot
    /// carries a total and a host may show a fraction.
    pub fn startLibraryPropertyBackfill(
        self: *OrcaRuntime,
        library: LibraryHandle,
        request: BackfillRequest,
    ) !JobHandle {
        return self.startJobWorker(library, .property_backfill, .{
            .batch_size = request.batch_size,
            .force = request.force,
        });
    }

    /// Starts the library-wide analysis: decodes every file the Library has
    /// not measured yet and stores its loudness, peak, clipping, silence,
    /// waveform and temporal fingerprint.
    ///
    /// Like the backfill and unlike a scan it has an honest denominator before
    /// it starts, so its snapshot carries a total. Unlike either, one unit of
    /// its work is a whole file decoded end to end, which is why it is
    /// cancellable and resumable rather than merely interruptible: a host is
    /// expected to stop it and start it again.
    ///
    /// There is no force mode, deliberately. A backfill needs one because a
    /// re-probe writes the same numbers and so cannot be told apart from a
    /// stale one; an analysis result carries its algorithm version, its
    /// parameters and the identity of the bytes it was taken from, so every
    /// reason to measure a file again is already a reason the selection sees.
    pub fn startLibraryAnalysis(
        self: *OrcaRuntime,
        library: LibraryHandle,
        request: AnalysisRequest,
    ) !JobHandle {
        return self.startJobWorker(library, .analysis, .{
            .batch_size = request.batch_size,
        });
    }

    /// Starts the duplicate scan: reports every file whose audio the Library
    /// also holds somewhere else.
    ///
    /// It reads measurements rather than files, so a full run over a measured
    /// library is seconds rather than the hours the analysis itself takes. Its
    /// denominator is every file in the Library, because every file is
    /// examined -- including the ones no analysis has reached, which are
    /// counted as uncomparable rather than quietly reported as unique.
    pub fn startLibraryDuplicateScan(
        self: *OrcaRuntime,
        library: LibraryHandle,
        request: DuplicateScanRequest,
    ) !JobHandle {
        return self.startJobWorker(library, .duplicate_scan, .{
            .batch_size = request.batch_size,
        });
    }

    /// At most one runs per runtime, so MusicBrainz sees one request a second,
    /// and not while an AcoustID submission runs, so AcoustID sees one client.
    pub fn startLibraryMatching(
        self: *OrcaRuntime,
        library: LibraryHandle,
        request: MatchRequest,
    ) !JobHandle {
        try self.requireRunning();
        if (self.runningJob(.metadata_lookup)) return error.MatchingAlreadyRunning;
        if (self.runningJob(.acoustid_submission)) return error.AcoustIdBusy;
        return self.startJobWorker(library, .metadata_lookup, .{
            .batch_size = request.batch_size,
            .limit = request.limit,
            .matching = .{
                .io = try self.networkIo(),
                .server = self.musicbrainz_server,
                .identity = self.client_identity,
                .hooks = self.matching_hooks,
                .scope = if (request.track_id) |track_id| .{ .track = track_id } else .library,
                .acoustid = if (request.fingerprints) self.acoustIdSetup() else null,
            },
        });
    }

    /// Fingerprints every file whose recording ID came from an accepted match
    /// or an edit and sends it to AcoustID, as the user whose key the
    /// credential store holds under `org.acoustid`/`user-key`. Fails with
    /// `needs_user_key` or `invalid_user_key` without marking anything sent.
    pub fn startAcoustIdSubmission(self: *OrcaRuntime, library: LibraryHandle) !JobHandle {
        try self.requireRunning();
        if (self.runningJob(.metadata_lookup) or self.runningJob(.acoustid_submission)) return error.AcoustIdBusy;
        return self.startJobWorker(library, .acoustid_submission, .{
            .submission = .{
                .io = try self.networkIo(),
                .identity = self.client_identity,
                .hooks = self.matching_hooks,
                .acoustid = self.acoustIdSetup(),
            },
        });
    }

    /// An AcoustID submission job's counters: files examined while it runs,
    /// everything once it has finished.
    pub fn jobSubmissionStats(self: *OrcaRuntime, job_handle: JobHandle) !SubmissionStats {
        for (self.job_workers.items) |worker| {
            if (!worker.job.eql(job_handle)) continue;
            return worker.submissionStats();
        }
        return error.StaleHandle;
    }

    /// Files an AcoustID submission would send now, fingerprints permitting.
    pub fn libraryAcoustIdSubmittableCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return (try self.libraryDatabase(library)).acoustid_submissions.submittableCount();
    }

    /// The files an AcoustID submission would send, by file id after `cursor`.
    pub fn libraryAcoustIdSubmittablePage(
        self: *OrcaRuntime,
        library: LibraryHandle,
        cursor: i64,
        limit: u32,
    ) !AcoustIdSubmittablePage {
        return (try self.libraryDatabase(library)).acoustid_submissions.submittablePage(self.allocator, cursor, limit);
    }

    fn runningJob(self: *const OrcaRuntime, kind: job.Kind) bool {
        for (self.job_workers.items) |worker| {
            if (!worker.retired and worker.kind == kind and !worker.registration.isFinished()) return true;
        }
        return false;
    }

    fn acoustIdSetup(self: *const OrcaRuntime) AcoustIdSetup {
        return .{
            .server = self.acoustid_server,
            .client_key = self.acoustid_client_key,
            .credentials = self.credential_store,
        };
    }

    /// Whether a matching job would look anything up on AcoustID: a key is set
    /// or the credential store may hold one.
    fn acoustIdInScope(self: *const OrcaRuntime, fingerprints: bool) bool {
        return fingerprints and (self.acoustid_client_key != null or self.credential_store != null);
    }

    fn startJobWorker(
        self: *OrcaRuntime,
        library: LibraryHandle,
        kind: job.Kind,
        request: WorkerRequest,
    ) !JobHandle {
        try self.requireRunning();
        if (request.batch_size == 0) return error.InvalidBatchSize;
        const library_database = try self.libraryDatabase(library);
        self.pruneRetiredJobWorkers();

        const total_units: ?u64 = switch (kind) {
            .property_backfill => try library_database.files
                .incompletePropertiesCount(request.force),
            .analysis => try library_database.files.unanalyzedCount(
                analysis_service.diagnosticsSelector(.{}),
            ),
            .duplicate_scan => try library_database.files.count(),
            .mutation => (request.tag_write orelse return error.InvalidJobRequest).plan.actions.len,
            .metadata_lookup => blk: {
                const setup = request.matching orelse return error.InvalidJobRequest;
                break :blk try library_database.identification_proposals.unidentifiedCount(
                    setup.scope,
                    setup.acoustid != null and self.acoustIdInScope(true),
                    request.limit,
                );
            },
            .acoustid_submission => try library_database.acoustid_submissions.submittableCount(),
            else => null,
        };
        const worker = try self.allocator.create(JobWorker);
        errdefer self.allocator.destroy(worker);
        const job_handle = try self.jobs.create(kind, total_units);
        errdefer self.jobs.finish(job_handle, .failed) catch {};
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
            .kind = kind,
            .root_id = request.root_id,
            .batch_size = request.batch_size,
            .force = request.force,
            .tag_write = request.tag_write,
            .limit = request.limit,
            .matching = request.matching,
            .submission = request.submission,
        };
        try self.job_workers.append(self.allocator, worker);
        errdefer _ = self.job_workers.pop();
        registration.thread = try std.Thread.spawn(.{}, JobWorker.run, .{worker});
        return job_handle;
    }

    /// Cooperative cancellation for one job. Both flags are set: the registry
    /// flag is what shutdown observes, and the scanner polls the token.
    pub fn cancelJob(self: *OrcaRuntime, job_handle: JobHandle) !void {
        try self.requireRunning();
        try self.jobs.requestCancellation(job_handle);
        for (self.job_workers.items) |worker| {
            if (worker.retired or !worker.job.eql(job_handle)) continue;
            worker.token.cancel();
            worker.registration.requestCancellation();
        }
    }

    /// Job snapshot with the worker's live counters folded in first, so a host
    /// polling progress never sees a stale count.
    pub fn jobSnapshotSynced(self: *OrcaRuntime, job_handle: JobHandle) !job.Snapshot {
        self.syncJobProgress();
        return self.jobs.snapshot(job_handle);
    }

    /// Scanner counters for a job, live while it runs and retained for a
    /// bounded number of finished jobs afterwards.
    pub fn jobScanStats(self: *OrcaRuntime, job_handle: JobHandle) !ScanStats {
        for (self.job_workers.items) |worker| {
            if (!worker.job.eql(job_handle)) continue;
            return worker.scanStats();
        }
        return error.StaleHandle;
    }

    /// A matching job's counters, live while it runs and retained for a
    /// bounded number of finished jobs afterwards.
    pub fn jobMatchStats(self: *OrcaRuntime, job_handle: JobHandle) !MatchStats {
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

    /// Control lane. Joins every worker whose thread has finished, records the
    /// job's terminal state and publishes one lossless `job_finished` event per
    /// job. Called from the runtime pump.
    pub fn reapFinishedJobs(self: *OrcaRuntime) void {
        self.syncJobProgress();
        for (self.job_workers.items) |worker| {
            if (worker.retired or !worker.registration.isFinished()) continue;
            // The completion event is lossless: a full channel means the host
            // has stopped polling, so the worker stays reapable until it drains.
            if (!self.events.hasCapacity()) return;
            self.work_registry.complete(worker.work_handle) catch {};
            self.finalizeJobWorker(worker, true);
        }
    }

    /// Records a joined worker's outcome. `publish` is false on the shutdown
    /// path, where no host will ever poll the event.
    fn finalizeJobWorker(self: *OrcaRuntime, worker: *JobWorker, publish: bool) void {
        worker.retired = true;
        const state: job.State = if (worker.failed.load(.acquire))
            .failed
        else if (worker.wasCancelled())
            .cancelled
        else
            .succeeded;
        self.jobs.observeProgress(worker.job, worker.filesProcessed()) catch {};
        self.jobs.finish(worker.job, state) catch {};
        if (!publish) return;
        self.events.publish(.{
            .request_id = 0,
            .outcome = .{ .job_finished = .{ .job = worker.job, .state = state } },
        }) catch {};
    }

    /// Control lane. Cancels every job worker's cooperative token. The registry
    /// flag alone cannot reach inside a scan — the scanner polls a
    /// `CancellationToken` — so the two are always set together.
    fn cancelJobWorkers(self: *OrcaRuntime) void {
        for (self.job_workers.items) |worker| {
            if (worker.retired) continue;
            worker.token.cancel();
        }
    }

    /// Control lane, immediately after `work_registry.drain()`: every worker
    /// thread has been joined and its registration already freed, so the
    /// records are finalized without touching the Registry again.
    fn finalizeDrainedJobWorkers(self: *OrcaRuntime) void {
        for (self.job_workers.items) |worker| {
            if (worker.retired) continue;
            self.finalizeJobWorker(worker, false);
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
            self.destroyJobWorker(worker);
            to_drop -= 1;
        }
    }

    fn freeAllJobWorkers(self: *OrcaRuntime) void {
        for (self.job_workers.items) |worker| self.destroyJobWorker(worker);
        self.job_workers.deinit(self.allocator);
        self.job_workers = .empty;
    }

    fn destroyJobWorker(self: *OrcaRuntime, worker: *JobWorker) void {
        if (worker.tag_write) |pending| pending.destroy();
        self.allocator.destroy(worker);
    }

    fn discardPendingTagWrites(self: *OrcaRuntime, library: ?LibraryHandle) void {
        for (&self.pending_tag_writes) |*slot| {
            const pending = slot.* orelse continue;
            if (library) |only| if (!pending.library.eql(only)) continue;
            pending.destroy();
            slot.* = null;
        }
    }

    // ------------------------------------------------------- player status

    /// Everything a transport UI needs, in one lock-free read. Position comes
    /// from the packed epoch+frames atomic the engine derives from the clock
    /// Zone, never from an event stream.
    pub fn playerStatus(self: *OrcaRuntime, player: PlayerHandle) !PlayerStatus {
        try self.requireRunning();
        return readStatus(try self.players.get(player)).status;
    }

    const StatusRead = struct {
        status: PlayerStatus,
        /// The queue entry `status.track_id` came from, read once with it.
        audible: ?TrackRef,
    };

    fn readStatus(object_value: *PlayerObject) StatusRead {
        const snapshot = object_value.player.snapshot();
        const queue_snapshot = object_value.queue.snapshot();
        const rate = object_value.player.published_sample_rate.load(.acquire);
        const frames = object_value.player.published_frame_count.load(.acquire);
        const current = object_value.queue.current();
        return .{
            .audible = current,
            .status = .{
                .transport = snapshot.state,
                .repeat = queue_snapshot.repeat,
                .shuffle = queue_snapshot.shuffle,
                .epoch = snapshot.epoch,
                .position_ms = if (rate == 0) 0 else snapshot.position_frames * 1000 / rate,
                .duration_ms = if (rate == 0) 0 else frames * 1000 / rate,
                .track_id = if (current) |ref| ref.track_id else null,
                .entry_serial = object_value.player.audible_entry_serial.load(.acquire),
                .queue_length = queue_snapshot.entries,
                .queue_index = queue_snapshot.cursor,
                .volume = object_value.gain.linear.load(.acquire),
            },
        };
    }

    /// Copies a bounded page of queue entries into a caller-owned buffer, in
    /// playback order, so the shuffle permutation is what a host displays.
    pub fn playerQueuePage(
        self: *OrcaRuntime,
        player: PlayerHandle,
        offset: u32,
        output: []TrackRef,
    ) !usize {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        var count: usize = 0;
        while (count < output.len) : (count += 1) {
            output[count] = object_value.queue.refAt(offset + @as(u32, @intCast(count))) orelse
                break;
        }
        return count;
    }

    /// One bounded page of the queue, as the rows a host displays.
    ///
    /// `playerQueuePage` hands back `TrackRef`s, which carry an id and nothing
    /// a person can read. The GTK queue pane consequently resolved titles from
    /// whichever library rows it happened to have loaded and printed
    /// "Track 14732" for the rest -- a frontend growing its own metadata
    /// resolution, which is the one thing frontends here must never do.
    ///
    /// Returned in queue order, so entry `n` of the result is queue position
    /// `offset + n`, and a shuffled queue reads as the order it will play.
    pub fn playerQueueTracks(
        self: *OrcaRuntime,
        player: PlayerHandle,
        allocator: std.mem.Allocator,
        offset: u32,
        limit: u32,
    ) !database.TrackPage {
        try self.requireRunning();
        if (limit == 0 or limit > database.repository.max_page)
            return error.PageOutOfRange;
        const object_value = try self.players.get(player);
        const opener = object_value.opener orelse return error.PlayerHasNoLibrary;
        const library = opener.library;
        const library_database = try self.libraryDatabase(library);

        var rows: std.ArrayList(database.TrackSummary) = .empty;
        errdefer {
            for (rows.items) |item| item.deinit(allocator);
            rows.deinit(allocator);
        }
        var index: u32 = 0;
        while (index < limit) : (index += 1) {
            const ref = object_value.queue.refAt(offset + index) orelse break;
            // A queue entry whose Track has since been removed keeps its place
            // rather than silently shortening the queue the host is showing.
            const summary = try library_database.tracks.byId(allocator, ref.track_id) orelse
                continue;
            try rows.append(allocator, summary);
        }
        return .{ .allocator = allocator, .items = try rows.toOwnedSlice(allocator) };
    }

    /// The Library this Player resolves its queue through, if it is bound.
    pub fn playerLibrary(self: *OrcaRuntime, player: PlayerHandle) !?LibraryHandle {
        try self.requireRunning();
        const opener = (try self.players.get(player)).opener orelse return null;
        return opener.library;
    }

    /// Linear volume applied to canonical PCM once, before fanout, so every
    /// Zone hears the same level. The control block outlives the engine, so a
    /// stop/start keeps the level the user set.
    pub fn playerSetVolume(
        self: *OrcaRuntime,
        player: PlayerHandle,
        linear: f32,
    ) !void {
        try self.requireRunning();
        if (!std.math.isFinite(linear) or linear < 0 or linear > 4) return error.InvalidVolume;
        (try self.players.get(player)).gain.setLinear(linear, volume_ramp_frames);
    }

    pub fn playerVolume(self: *OrcaRuntime, player: PlayerHandle) !f32 {
        try self.requireRunning();
        return (try self.players.get(player)).gain.linear.load(.acquire);
    }

    /// Whether entries are decoded with their own loudness correction.
    ///
    /// Takes effect as soon as the audio already decoded ahead of the listener
    /// drains — a fraction of a second, not the rest of the track. The decode
    /// lane reads the mode per canonical block, so a host that turns
    /// correction off hears it happen rather than wondering whether the
    /// control did anything. The level then steps rather than ramping: the
    /// correction changes by however much the entry was being corrected, and
    /// that step is the answer to an explicit request.
    pub fn playerSetReplayGainMode(
        self: *OrcaRuntime,
        player: PlayerHandle,
        mode: audio.processing.ReplayGainMode,
    ) !void {
        try self.requireRunning();
        (try self.players.get(player)).player.replay_gain_mode.store(mode, .release);
    }

    pub fn playerReplayGainMode(
        self: *OrcaRuntime,
        player: PlayerHandle,
    ) !audio.processing.ReplayGainMode {
        try self.requireRunning();
        return (try self.players.get(player)).player.replay_gain_mode.load(.acquire);
    }

    /// What the audio currently audible is being multiplied by: user volume
    /// times the loudness correction of the *audible* entry.
    ///
    /// The two halves come from two places because they are applied in two
    /// places. Volume is one Player-scope node; the correction belongs to the
    /// audio and is applied by the session that decoded it, which is what
    /// makes a gapless transition correct. This resolves the correction
    /// through the same audible entry serial that identity, duration and
    /// position resolve through, so all four describe one entry.
    ///
    /// Distinct from `playerVolume` on purpose. A host shows the volume it was
    /// given; this is what the audio is being multiplied by, and the two
    /// differing is exactly what "ReplayGain is doing something" looks like.
    pub fn playerEffectiveGain(self: *OrcaRuntime, player: PlayerHandle) !f32 {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        return object_value.gain.linear.load(.acquire) *
            object_value.player.effectiveReplayGain();
    }

    /// Turns the ten-band equalizer on with `equalizer`, or off with null. The
    /// engine is stopped while the settings are written, so it never reads a
    /// half-written equalizer; it rebuilds its filters on its next pass.
    pub fn playerSetEqualizer(
        self: *OrcaRuntime,
        player: PlayerHandle,
        equalizer: ?audio.dsp.Equalizer,
    ) !void {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        const engine = object_value.engine;
        if (engine) |value| value.quiesce();
        defer if (engine) |value| value.release();
        try object_value.dsp.setEqualizer(equalizer);
    }

    pub fn playerEqualizer(self: *OrcaRuntime, player: PlayerHandle) !?audio.dsp.Equalizer {
        try self.requireRunning();
        return (try self.players.get(player)).dsp.settings.equalizer;
    }

    /// Turns stereo crossfeed on with an `amount` in [0, 1], or off with null.
    /// Applies to two-channel audio only; other layouts pass through.
    pub fn playerSetCrossfeed(
        self: *OrcaRuntime,
        player: PlayerHandle,
        amount: ?f32,
    ) !void {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        const engine = object_value.engine;
        if (engine) |value| value.quiesce();
        defer if (engine) |value| value.release();
        try object_value.dsp.setCrossfeed(amount);
    }

    pub fn playerCrossfeed(self: *OrcaRuntime, player: PlayerHandle) !?f32 {
        try self.requireRunning();
        return (try self.players.get(player)).dsp.settings.crossfeed;
    }

    /// What the audio being decoded passes through on its way to the output,
    /// and whether that path could be bit-perfect.
    ///
    /// The source format and codec are the decode cursor's, which leads the
    /// audible entry by the render-ahead depth; the ReplayGain figure is the
    /// audible entry's. The engine is stopped while they are read, because the
    /// decoder and the Zone's open format are engine-thread state.
    pub fn playerSignalPath(self: *OrcaRuntime, player: PlayerHandle) !audio.dsp.SignalPath {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        const engine = object_value.engine;
        if (engine) |value| value.quiesce();
        defer if (engine) |value| value.release();
        const audible = object_value.player.audibleSource();
        return .describe(.{
            .source = if (audible) |value| value.format else null,
            .codec = if (audible) |value| value.codec else null,
            .replay_gain = object_value.player.effectiveReplayGain(),
            .equalizer = object_value.dsp.settings.equalizer,
            .crossfeed = object_value.dsp.settings.crossfeed,
            .volume = object_value.gain.linear.load(.acquire),
            .output = if (engine) |value| value.outputFormat() else null,
            .device_rate = if (engine) |value| value.deviceRate() else null,
        });
    }

    /// Seek in wall-clock milliseconds. The frame conversion needs the loaded
    /// source's rate, which is why a Player with nothing loaded is refused
    /// rather than silently seeking to frame zero.
    pub fn playerSeekMs(self: *OrcaRuntime, player: PlayerHandle, ms: u64) !u32 {
        try self.requireRunning();
        const rate = (try self.players.get(player)).player.published_sample_rate.load(.acquire);
        if (rate == 0) return error.PlayerHasNoSource;
        return self.seekPlayer(player, ms * rate / 1000);
    }

    // -------------------------------------------------------- zone helpers

    /// Applies the render policy and requested device latency, then asks the
    /// Zone's lane to open the output. Both settings are control-lane state and
    /// are refused once an engine owns the Zone.
    pub fn zoneOpenOutput(
        self: *OrcaRuntime,
        zone: ZoneHandle,
        device_id: u64,
        policy: audio.zone.RenderPolicy,
        latency_frames: u32,
    ) !void {
        try self.requireRunning();
        const object_value = try self.zones.get(zone);
        try self.requireZoneIdle(object_value);
        object_value.zone.zone.policy = policy;
        object_value.zone.zone.latency.requested_frames = latency_frames;
        return self.zoneRequestOutput(zone, device_id);
    }

    /// One call for a frontend with a single output: create a Zone, attach it
    /// to the Player, and open it. Device id 0 delegates to the server default.
    /// A single-output host never has to know Zones exist.
    pub fn playerOpenDefaultOutput(
        self: *OrcaRuntime,
        player: PlayerHandle,
        device_id: u64,
    ) !ZoneHandle {
        try self.requireRunning();
        _ = try self.players.get(player);
        const zone = try self.createZone();
        errdefer self.destroyZone(zone) catch {};
        try self.attachZone(zone, player);
        try self.zoneRequestOutput(zone, device_id);
        return zone;
    }

    fn playerHasZone(self: *OrcaRuntime, player: PlayerHandle) bool {
        for (self.zones.slots.items) |*slot| {
            if (slot.value) |zone| {
                const attached = zone.attached_player orelse continue;
                if (attached.eql(player)) return true;
            }
        }
        return false;
    }

    /// Stands in for the executors later phases will add: it registers work and
    /// starts a real worker thread that observes cancellation, so shutdown and
    /// destroy paths are exercised against a live worker rather than a bare
    /// handle. The worker only ever touches its own `work.Registration`.
    fn startDummyWork(self: *OrcaRuntime) !WorkHandle {
        try self.requireRunning();
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
        try self.requireRunning();
        try self.work_registry.complete(work_handle);
    }

    fn inFlightWorkCount(self: *const OrcaRuntime) usize {
        return self.work_registry.count();
    }

    pub fn submit(self: *OrcaRuntime, action: control.Action) !control.RequestId {
        try self.requireRunning();
        return self.commands.submit(action);
    }

    /// Executes at most one command on the runtime's serialized logical control
    /// lane. Returns false when there is no work or event backpressure applies.
    /// Each call also samples bound Players for listens, at most once per
    /// `listen_sample_interval_ms`.
    pub fn processNextCommand(self: *OrcaRuntime) bool {
        if (self.state.load(.acquire) != .running) return false;
        self.sampleListens();
        if (!self.events.hasCapacity()) return false;
        const command = self.commands.pop() orelse return false;
        const outcome = self.execute(command.action) catch |err| control.Outcome{
            .failed = mapFailure(err),
        };
        self.events.publish(.{
            .request_id = command.request_id,
            .outcome = outcome,
        }) catch unreachable;
        return true;
    }

    pub fn pollEvent(self: *OrcaRuntime) ?control.Event {
        return self.events.poll();
    }

    fn publishTelemetry(self: *OrcaRuntime, telemetry: control.Telemetry) !void {
        try self.requireRunning();
        try self.telemetry.publish(telemetry);
    }

    pub fn pollTelemetry(self: *OrcaRuntime) ?control.Telemetry {
        return self.telemetry.poll();
    }

    pub fn jobSnapshot(self: *const OrcaRuntime, job_handle: JobHandle) !job.Snapshot {
        return self.jobs.snapshot(job_handle);
    }

    fn execute(self: *OrcaRuntime, action: control.Action) !control.Outcome {
        return switch (action) {
            .create_library => .{ .library_created = try self.createLibrary() },
            .create_player => .{ .player_created = try self.createPlayer() },
            .create_zone => .{ .zone_created = try self.createZone() },
            .start_job => |options| blk: {
                const job_handle = try self.jobs.create(options.kind, options.total_units);
                try self.jobs.start(job_handle);
                break :blk .{ .job_started = job_handle };
            },
            .cancel_job => |job_handle| blk: {
                try self.jobs.requestCancellation(job_handle);
                break :blk .{ .job_cancellation_requested = job_handle };
            },
            .play_track => |request| blk: {
                try self.playerPlayTrackBound(
                    request.player,
                    request.library,
                    request.track_id,
                );
                break :blk .{ .track_playing = request.player };
            },
        };
    }

    fn mapFailure(err: anyerror) control.Failure {
        return switch (err) {
            error.RuntimeNotRunning => .runtime_not_running,
            error.StaleHandle => .stale_handle,
            error.OutOfMemory => .out_of_memory,
            error.InvalidJobTransition, error.JobAlreadyFinished => .invalid_transition,
            error.PlayerHasNoLibrary, error.PlayerBoundToAnotherLibrary => .player_not_bound,
            error.PlayerHasNoSource, error.PlayerHasNoOutput => .not_playable,
            error.TrackHasNoPlayableFile => .track_has_no_file,
            error.TrackFileMissing => .track_file_missing,
            error.CodecUnavailable, error.UnsupportedAudioFormat => .codec_unavailable,
            error.PlaybackQueueFull => .queue_full,
            else => .internal,
        };
    }

    /// Destroying a Player or a Zone carries the same requirement as shutdown:
    /// no worker may still be holding the object when it is freed. Work is not
    /// yet scoped per object, so a destroy conservatively cancels and joins
    /// every registered worker. Narrowing this to the workers that actually
    /// hold the destroyed object is a later refinement, never a relaxation.
    /// Identifies a Player to the work registry. Generation is part of the
    /// tag, so a registration left by a destroyed Player can never match the
    /// later occupant of the same slot.
    fn playerOwnerTag(player: PlayerHandle) work.Owner {
        return .{ .kind = .player, .index = player.index, .generation = player.generation };
    }

    fn libraryOwnerTag(library: LibraryHandle) work.Owner {
        return .{ .kind = .library, .index = library.index, .generation = library.generation };
    }

    fn joinWorkersBeforeDestroy(self: *OrcaRuntime) void {
        self.cancelJobWorkers();
        self.work_registry.requestCancellation();
        self.wakeListenWorkers();
        self.work_registry.drain();
        self.releaseDrainedArtworkLoaders();
        self.releaseDrainedListenWorkers();
    }

    fn closeLibraryDatabase(self: *OrcaRuntime, library: *LibraryObject) void {
        if (library.database) |library_database| {
            library_database.close();
            self.allocator.destroy(library_database);
            library.database = null;
        }
    }

    fn requireRunning(self: *const OrcaRuntime) error{RuntimeNotRunning}!void {
        if (self.state.load(.acquire) != .running) return error.RuntimeNotRunning;
    }
};

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
    try std.testing.expectEqual(@as(usize, 0), runtime.inFlightWorkCount());
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
    try std.testing.expectEqual(@as(usize, 0), runtime.inFlightWorkCount());
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
    const library_database = try runtime.libraryDatabase(library);
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
    const library_database = try runtime.libraryDatabase(library);

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
        _ = try runtime.startDummyWork();
        runtime.shutdown();
        runtime.shutdown();
        try std.testing.expectEqual(State.stopped, runtime.state.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), runtime.inFlightWorkCount());
        runtime.deinit();
    }
}

test "shutdown invalidates objects and rejects new work" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    const player = try runtime.createPlayer();
    const dummy_work = try runtime.startDummyWork();
    runtime.shutdown();

    try std.testing.expectError(error.RuntimeNotRunning, runtime.createPlayer());
    try std.testing.expectError(error.RuntimeNotRunning, runtime.destroyPlayer(player));
    try std.testing.expectError(error.RuntimeNotRunning, runtime.completeDummyWork(dummy_work));
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
    // Destroying a Player used to drain the entire work registry. Every other
    // Player's engine thread was cancelled and joined as collateral, and any
    // scan in flight was cancelled with them. The engines respawned on their
    // next load, which is why this looked like a stutter instead of a fault.
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    const keeper = try runtime.createPlayer();
    const doomed = try runtime.createPlayer();
    _ = try runtime.ensureEngine(keeper);
    _ = try runtime.ensureEngine(doomed);
    // Work unbound to any Player: a scan must outlive a Player being destroyed,
    // because it never touches one.
    const unrelated = try runtime.startDummyWork();
    try std.testing.expectEqual(@as(usize, 3), runtime.inFlightWorkCount());

    try runtime.destroyPlayer(doomed);

    try std.testing.expectError(error.StaleHandle, runtime.players.get(doomed));
    try std.testing.expect((try runtime.players.get(keeper)).engine != null);
    // Exactly the destroyed Player's registration was retired.
    try std.testing.expectEqual(@as(usize, 2), runtime.inFlightWorkCount());
    try std.testing.expect(!try runtime.work_registry.cancellationRequested(unrelated));

    try runtime.completeDummyWork(unrelated);
}

test "destroying a Player joins workers before freeing it" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    const player = try runtime.createPlayer();
    const work_handle = try runtime.work_registry.begin(OrcaRuntime.playerOwnerTag(player));
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
    try std.testing.expectEqual(@as(usize, 0), runtime.inFlightWorkCount());
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
    const library_database = try runtime.libraryDatabase(library);
    try library_database.tracks.upsertTracks(&.{.{ .title = "Runtime track" }});
    try std.testing.expectEqual(@as(u64, 1), try library_database.tracks.count());
    try runtime.destroyLibrary(library);
    try std.testing.expectError(error.StaleHandle, runtime.libraryDatabase(library));
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
    try runtime.markZoneOutputLost(robust);
    try runtime.beginZoneRecovery(robust);
    try runtime.failZoneRecovery(robust);
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
/// The waits here counted `std.Thread.yield()` calls, and a count of yields is
/// not a duration. On a loaded machine 8,000 yields elapse in a small fraction
/// of the time an engine needs to open an output, so
/// "…actually renders" failed intermittently with `expected .active, found
/// .closed` — the engine had not finished, not misbehaved. Load made it worse,
/// which is the signature of this mistake and the reason it survived: it is
/// green on an idle machine, and green is what people check.
///
/// Time is what these tests are waiting for, so time is what bounds them. The
/// sleep also stops a spin-wait from competing with the very thread it is
/// waiting for.
const TestDeadline = struct {
    remaining_ms: u64,

    fn init(milliseconds: u64) TestDeadline {
        return .{ .remaining_ms = milliseconds };
    }

    /// Sleeps a millisecond and reports whether there is time left. Written as
    /// a loop condition: `while (!ready and deadline.tick()) {}`.
    fn tick(self: *TestDeadline) bool {
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
        if (backend.liveStream()) |stream| stream.pump(&samples, 256);
        path = try runtime.playerSignalPath(player);
    }
    try std.testing.expect(path.source != null);
    const output = path.output orelse return error.OutputNeverOpened;
    try std.testing.expectEqual(audio.pcm.SampleFormat.float_32, output.sample_format);
    try std.testing.expectEqual(path.source.?.sample_rate, output.sample_rate);
    try std.testing.expectEqual(path.source.?.channels, output.channels);
    try std.testing.expect(!hasReason(path, .sample_processing));
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
    try std.testing.expect(hasReason(path, .sample_processing));
    try std.testing.expectEqual(@as(f32, 0.5), path.volume);

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
    try std.testing.expectEqual(@as(usize, 1), runtime.inFlightWorkCount());

    runtime.shutdown();

    // The registration is gone, which can only happen after the engine thread
    // called finish() — it was joined, not abandoned.
    try std.testing.expectEqual(@as(usize, 0), runtime.inFlightWorkCount());
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
    try std.testing.expectEqual(@as(usize, 1), runtime.inFlightWorkCount());
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
    try std.testing.expectError(error.ZoneOwnedByEngine, runtime.markZoneOutputLost(zone));
    try std.testing.expectError(error.ZoneOwnedByEngine, runtime.setZonePolicy(zone, .interactive));
}

// ------------------------------------------------------------- queue tests

/// Builds a Library whose Tracks point at real fixture files, so the queue is
/// exercised through the same `playableLocation` -> `LocalFileSource` ->
/// `CodecRegistry` path a projected corpus uses.
fn openFixtureLibrary(
    runtime: *OrcaRuntime,
    uri: [:0]const u8,
    paths: []const []const u8,
) !struct { library: LibraryHandle, ids: [4]i64 } {
    const library = try runtime.openLibrary(std.testing.io, uri);
    const library_database = try runtime.libraryDatabase(library);
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
    const library_database = try runtime.libraryDatabase(library);
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

// ----------------------------------------------------------- artwork tests

/// A Release whose Tracks point at real fixture files and whose observed tags
/// record what those files actually carry, so the candidate query is exercised
/// against the same columns a scan writes.
fn openArtworkLibrary(
    runtime: *OrcaRuntime,
    uri: [:0]const u8,
    paths: []const []const u8,
) !struct { library: LibraryHandle, release_id: i64, ids: [4]i64 } {
    const library = try runtime.openLibrary(std.testing.io, uri);
    const library_database = try runtime.libraryDatabase(library);
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
    const library_database = try runtime.libraryDatabase(fixtures.library);
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
    const library_database = try runtime.libraryDatabase(library);
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

fn copyFixtureInto(dir: std.Io.Dir, fixture: []const u8, name: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixture, std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(bytes);
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
}

fn awaitJob(runtime: *OrcaRuntime, job_handle: JobHandle) !job.State {
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

fn scannedTempLibrary(runtime: *OrcaRuntime, temporary: *std.testing.TmpDir, name: [:0]const u8) !LibraryHandle {
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

fn allTrackIds(runtime: *OrcaRuntime, library: LibraryHandle) ![]i64 {
    var page = try runtime.libraryTrackQuery(library, "", .{ .limit = 16 });
    defer page.deinit();
    const ids = try std.testing.allocator.alloc(i64, page.items.len);
    for (ids, page.items) |*id, item| id.* = item.id;
    return ids;
}

test "an approved tag write rewrites the files, the rescan agrees, and undo restores their bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempLibrary(&runtime, &temporary, "file:orca-runtime-tag-write?mode=memory&cache=shared");
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

    const library_database = try runtime.libraryDatabase(library);
    try runtime.undoTagWrite(library, std.testing.io, preview.plan_id);
    const restored_mp3 = try temporary.dir.readFileAlloc(std.testing.io, "a.mp3", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(restored_mp3);
    try std.testing.expectEqualSlices(u8, original_mp3, restored_mp3);
    const stored = (try library_database.observed_tags.get(std.testing.allocator, preview.files[0].file_id)).?;
    defer stored.deinit();
    try std.testing.expect(stored.values.album == null or !std.mem.eql(u8, stored.values.album.?, "Written Album"));

    const again = try runtime.planTagWrite(library, std.testing.io, ids);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 2), again.files.len);
    try runtime.discardTagWrite(library, again.plan_id);
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

// ------------------------------------------------------------- listen tests

/// The awake and wall clocks the control lane samples Players by, advanced by
/// the test rather than by time.
const FakeSampleClock = struct {
    mono_ms: i64 = 0,
    wall_base_s: i64 = 1_700_000_000,

    fn clock(self: *FakeSampleClock) listen_worker.SampleClock {
        return .{ .context = self, .now_fn = now };
    }

    fn now(context: *anyopaque) listen_worker.SampleTime {
        const self: *FakeSampleClock = @ptrCast(@alignCast(context));
        return .{ .mono_ms = self.mono_ms, .wall_s = self.wall_base_s + @divFloor(self.mono_ms, 1000) };
    }
};

/// ListenBrainz, its token store and the gateway's clock, as a listen worker
/// sees them. Every call arrives on the worker's thread.
const FakeListenBrainz = struct {
    /// Holds each request until the gateway cancels it.
    hang: bool = false,
    /// The last request's URL and user agent, complete once `requests`
    /// counts it.
    url: [128]u8 = undefined,
    url_len: usize = 0,
    user_agent: [160]u8 = undefined,
    user_agent_len: usize = 0,
    requests: std.atomic.Value(u32) = .init(0),
    listens_sent: std.atomic.Value(u32) = .init(0),
    now_playing_sent: std.atomic.Value(u32) = .init(0),
    feedback_sent: std.atomic.Value(u32) = .init(0),
    last_score: std.atomic.Value(i32) = .init(99),
    /// The recording id of the last feedback sent, complete once
    /// `feedback_sent` counts it.
    feedback_mbid: [36]u8 = @splat(0),
    feedback_status: std.atomic.Value(u16) = .init(200),
    during_feedback: ?struct { context: *anyopaque, run: *const fn (*anyopaque) void } = null,
    token_lookups: std.atomic.Value(u32) = .init(0),
    clock_reads: std.atomic.Value(u32) = .init(0),
    now_ms: std.atomic.Value(i64) = .init(0),

    const hang_limit_ms = 10_000;

    fn lastUrl(self: *const FakeListenBrainz) []const u8 {
        return self.url[0..self.url_len];
    }

    fn lastUserAgent(self: *const FakeListenBrainz) []const u8 {
        return self.user_agent[0..self.user_agent_len];
    }

    fn advance(self: *FakeListenBrainz, milliseconds: i64) void {
        _ = self.now_ms.fetchAdd(milliseconds, .acq_rel);
    }

    fn transport(self: *FakeListenBrainz) network.client.Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn clock(self: *FakeListenBrainz) network.client.Clock {
        return .{ .context = self, .now_ms_fn = nowMs, .sleep_ms_fn = sleepMs };
    }

    /// Unix time that moves with `clock`.
    fn wallClock(self: *FakeListenBrainz) network.client.Clock {
        return .{ .context = self, .now_ms_fn = wallMs, .sleep_ms_fn = sleepMs };
    }

    const wall_base_ms: i64 = 1_800_000_000_000;

    fn wallMs(context: *anyopaque) i64 {
        const self: *FakeListenBrainz = @ptrCast(@alignCast(context));
        return wall_base_ms + self.now_ms.load(.acquire);
    }

    fn store(self: *FakeListenBrainz) CredentialStore {
        return .{ .context = self, .get_fn = token };
    }

    fn perform(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: network.client.Request,
    ) anyerror!network.client.Response {
        const self: *FakeListenBrainz = @ptrCast(@alignCast(context));
        self.url_len = @min(request.url.len, self.url.len);
        @memcpy(self.url[0..self.url_len], request.url[0..self.url_len]);
        self.user_agent_len = @min(request.user_agent.len, self.user_agent.len);
        @memcpy(self.user_agent[0..self.user_agent_len], request.user_agent[0..self.user_agent_len]);
        const sent = request.body orelse "";
        if (std.mem.endsWith(u8, request.url, "/recording-feedback")) {
            if (self.during_feedback) |hook| {
                self.during_feedback = null;
                hook.run(hook.context);
            }
            if (std.mem.indexOf(u8, sent, "\"score\":")) |at| {
                const digits = std.mem.trimEnd(u8, sent[at + 8 ..], "}");
                self.last_score.store(std.fmt.parseInt(i32, digits, 10) catch 99, .release);
            }
            const mbid_key = "\"recording_mbid\":\"";
            if (std.mem.indexOf(u8, sent, mbid_key)) |at| {
                const start = at + mbid_key.len;
                if (sent.len >= start + self.feedback_mbid.len)
                    @memcpy(&self.feedback_mbid, sent[start..][0..self.feedback_mbid.len]);
            }
            _ = self.feedback_sent.fetchAdd(1, .acq_rel);
            _ = self.requests.fetchAdd(1, .acq_rel);
            return .{
                .allocator = allocator,
                .status = self.feedback_status.load(.acquire),
                .body = try allocator.dupe(u8, "{}"),
            };
        }
        if (std.mem.endsWith(u8, request.url, "/submit-listens")) {
            const counter = if (std.mem.indexOf(u8, sent, "\"playing_now\"") != null) &self.now_playing_sent else &self.listens_sent;
            _ = counter.fetchAdd(1, .acq_rel);
        }
        _ = self.requests.fetchAdd(1, .acq_rel);
        if (self.hang) {
            var waited: TestDeadline = .init(hang_limit_ms);
            while (waited.tick()) {
                if (request.cancel.?.load(.acquire)) return error.Canceled;
            }
            return error.Timeout;
        }
        const body = if (std.mem.endsWith(u8, request.url, "/validate-token"))
            "{\"valid\":true,\"user_name\":\"listener\"}"
        else
            "{}";
        return .{ .allocator = allocator, .status = 200, .body = try allocator.dupe(u8, body) };
    }

    fn nowMs(context: *anyopaque) i64 {
        const self: *FakeListenBrainz = @ptrCast(@alignCast(context));
        _ = self.clock_reads.fetchAdd(1, .acq_rel);
        return self.now_ms.load(.acquire);
    }

    fn sleepMs(context: *anyopaque, milliseconds: u64) anyerror!void {
        const self: *FakeListenBrainz = @ptrCast(@alignCast(context));
        _ = self.now_ms.fetchAdd(@intCast(milliseconds), .acq_rel);
    }

    fn token(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!?[]u8 {
        const self: *FakeListenBrainz = @ptrCast(@alignCast(context));
        _ = self.token_lookups.fetchAdd(1, .acq_rel);
        return try allocator.dupe(u8, "secret-token");
    }
};

/// A runtime whose listen sampling and ListenBrainz traffic are both fakes.
/// Players report playback through their status atomics, as an engine would,
/// without decoding anything.
const ListenRig = struct {
    runtime: OrcaRuntime,
    clock: FakeSampleClock = .{},
    listenbrainz: FakeListenBrainz = .{},

    const track_duration_ms = 180_000;

    fn init(self: *ListenRig) void {
        self.* = .{ .runtime = .init(std.testing.allocator) };
        self.runtime.listen_hooks = .{
            .transport = self.listenbrainz.transport(),
            .clock = self.listenbrainz.clock(),
            .wall_clock = self.listenbrainz.wallClock(),
            .sample_clock = self.clock.clock(),
            .poll_ms = 5,
        };
    }

    /// A Library holding one three-minute Track with a file behind it.
    fn openLibrary(self: *ListenRig, uri: [:0]const u8) !struct { library: LibraryHandle, track_id: i64 } {
        const library = try self.runtime.openLibrary(std.testing.io, uri);
        const library_database = try self.runtime.libraryDatabase(library);
        const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
        try library_database.tracks.upsertTracks(&.{.{
            .title = "Northern Sky",
            .artist = "Nick Drake",
            .album = "Bryter Layter",
            .duration_ms = track_duration_ms,
            .preferred_file_id = file_id,
        }});
        var page = try library_database.tracks.page(std.testing.allocator, .{ .limit = 1, .offset = 0 });
        defer page.deinit();
        return .{ .library = library, .track_id = page.items[0].id };
    }

    fn startPlaying(self: *ListenRig, player: PlayerHandle, library: LibraryHandle, track_id: i64, serial: u32) !void {
        const object_value = try self.runtime.players.get(player);
        try object_value.queue.replace(&.{.{ .library = library, .track_id = track_id }}, 0);
        object_value.player.published_sample_rate.store(1000, .release);
        object_value.player.published_frame_count.store(track_duration_ms, .release);
        object_value.player.audible_entry_serial.store(serial, .release);
        object_value.player.position_frames.store(0, .release);
        object_value.player.state.store(.playing, .release);
    }

    /// Plays on for `milliseconds`, pumping the control lane every 100 ms.
    fn play(self: *ListenRig, player: PlayerHandle, milliseconds: u64) !void {
        const object_value = try self.runtime.players.get(player);
        var elapsed: u64 = 0;
        while (elapsed < milliseconds) : (elapsed += 100) {
            self.clock.mono_ms += 100;
            _ = object_value.player.position_frames.fetchAdd(100, .acq_rel);
            _ = self.runtime.processNextCommand();
        }
    }

    fn awaitPlayCount(self: *ListenRig, library: LibraryHandle, track_id: i64, expected: u64) !PlayStats {
        var deadline: TestDeadline = .init(5_000);
        while (deadline.tick()) {
            const stats = try self.runtime.libraryTrackPlayStats(library, track_id);
            if (stats.play_count == expected) return stats;
        }
        return error.ListenNotRecorded;
    }

    /// Queues one listen for ListenBrainz directly, as another process sharing
    /// the database would, due at `due_at` Unix seconds.
    fn queueBacklog(self: *ListenRig, library: LibraryHandle, due_at: i64) !void {
        const library_database = try self.runtime.libraryDatabase(library);
        const event: providers.scrobble.Event = .{
            .title = "Northern Sky",
            .artist = "Nick Drake",
            .started_at = 1_700_000_000,
            .duration_ms = track_duration_ms,
            .listened_ms = 100_000,
        };
        const payload = try event.encode(std.testing.allocator);
        defer std.testing.allocator.free(payload);
        try library_database.scrobbles.enqueue(providers.listenbrainz.service, "listen:backlog", payload);
        var sql: [96]u8 = undefined;
        try library_database.database.exec(try std.fmt.bufPrintSentinel(
            &sql,
            "UPDATE scrobble_queue SET next_attempt_at = {d};",
            .{due_at},
            0,
        ));
    }

    fn awaitDelivered(self: *ListenRig, library: LibraryHandle, expected: u64) !void {
        var deadline: TestDeadline = .init(5_000);
        while ((try self.runtime.libraryScrobblerStatus(library)).delivered_total != expected) {
            if (!deadline.tick()) return error.ListenNotDelivered;
        }
    }

    fn identify(self: *ListenRig, library: LibraryHandle, track_id: i64, mbid: ?[]const u8) !void {
        const library_database = try self.runtime.libraryDatabase(library);
        try library_database.database.exec("INSERT INTO recordings(title) VALUES ('Northern Sky');");
        var sql: [256]u8 = undefined;
        try library_database.database.exec(try std.fmt.bufPrintSentinel(
            &sql,
            "UPDATE files SET recording_id = (SELECT max(id) FROM recordings) " ++
                "WHERE id = (SELECT preferred_file_id FROM tracks WHERE id = {d});" ++
                "UPDATE tracks SET recording_id = (SELECT max(id) FROM recordings) WHERE id = {d};",
            .{ track_id, track_id },
            0,
        ));
        var statement = try library_database.database.prepare("SELECT preferred_file_id FROM tracks WHERE id = ?1;");
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return error.SqlFailed;
        try library_database.observed_tags.upsert(.{ .file_id = statement.columnInt64(0), .values = .{
            .title = "Northern Sky",
            .musicbrainz_recording_id = mbid,
        } });
    }

    fn awaitCount(counter: *const std.atomic.Value(u32), expected: u32) !void {
        var deadline: TestDeadline = .init(5_000);
        while (counter.load(.acquire) < expected) {
            if (!deadline.tick()) return error.RequestNeverSent;
        }
    }

    fn awaitFeedbackSettled(self: *ListenRig, library: LibraryHandle) !void {
        var deadline: TestDeadline = .init(5_000);
        while ((try self.runtime.libraryScrobblerStatus(library)).feedback_pending != 0) {
            if (!deadline.tick()) return error.FeedbackNeverSettled;
        }
    }

    /// Lets the listen worker run at least `passes` more passes.
    fn awaitWorkerPasses(self: *ListenRig, passes: u32) !void {
        const target = self.listenbrainz.clock_reads.load(.acquire) + passes;
        var deadline: TestDeadline = .init(5_000);
        while (self.listenbrainz.clock_reads.load(.acquire) < target) {
            if (!deadline.tick()) return error.WorkerStalled;
        }
    }
};

test "a play heard past half its length records one listen, and without scrobbling queues and sends nothing" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-local?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);

    try rig.play(player, 80_000);
    try rig.awaitWorkerPasses(3);
    try std.testing.expectEqual(@as(u64, 0), (try rig.runtime.libraryTrackPlayStats(fixture.library, fixture.track_id)).play_count);
    try rig.play(player, 20_000);

    const stats = try rig.awaitPlayCount(fixture.library, fixture.track_id, 1);
    try std.testing.expectEqual(@as(u64, 1), try rig.runtime.libraryListensRecorded(fixture.library));
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), stats.last_played_at);
    const details = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer details.deinit();
    try std.testing.expectEqual(@as(u64, 1), details.play_count);
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), details.last_played_at);

    try rig.awaitWorkerPasses(3);
    const library_database = try rig.runtime.libraryDatabase(fixture.library);
    try std.testing.expectEqual(@as(u64, 0), try library_database.scrobbles.pendingCount());
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requests.load(.acquire));
    const status = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expect(!status.enabled);
    try std.testing.expectEqual(@as(u64, 1), status.recorded_total);
    try std.testing.expectEqual(@as(u64, 0), status.dropped);
}

test "a finished listen keeps the time heard until the track changed" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-finished?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);
    try rig.play(player, 150_000);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 8);
    try rig.play(player, 200);

    const library_database = try rig.runtime.libraryDatabase(fixture.library);
    var deadline: TestDeadline = .init(5_000);
    while (deadline.tick()) {
        var statement = try library_database.database.prepare("SELECT listened_ms FROM listens;");
        defer statement.deinit();
        if (try statement.step() == .row and statement.columnInt64(0) == 149_900) return;
    }
    return error.FinishedListenNotRecorded;
}

test "a queue that plays out keeps the whole time heard on its last listen" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-played-out?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);
    try rig.play(player, 100_000);
    _ = try rig.awaitPlayCount(fixture.library, fixture.track_id, 1);
    try rig.play(player, 80_000);
    (try rig.runtime.players.get(player)).player.drained.store(true, .release);
    try rig.play(player, 200);

    const library_database = try rig.runtime.libraryDatabase(fixture.library);
    var deadline: TestDeadline = .init(5_000);
    while (deadline.tick()) {
        var statement = try library_database.database.prepare("SELECT listened_ms FROM listens;");
        defer statement.deinit();
        if (try statement.step() == .row and statement.columnInt64(0) == 180_000) return;
    }
    return error.PlayedOutListenNotFinished;
}

test "a Library with no listen worker reports the queue stored in its database and starts none" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-stored-status?mode=memory&cache=shared");
    try rig.queueBacklog(fixture.library, 1_700_000_000);

    var status = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expectEqual(ScrobblerState.disabled, status.state);
    try std.testing.expect(!status.enabled);
    try std.testing.expectEqual(@as(u64, 1), status.pending);
    try std.testing.expectEqual(@as(u64, 0), status.delivered_total);
    try std.testing.expect((try rig.runtime.libraries.get(fixture.library)).listens == null);

    try rig.runtime.librarySetScrobbling(fixture.library, false, false, false);
    const library_database = try rig.runtime.libraryDatabase(fixture.library);
    try library_database.database.exec("UPDATE scrobble_queue SET state = 2;");
    status = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expectEqual(@as(u64, 1), status.pending);

    rig.clock.mono_ms += stored_counts_reuse_ms;
    status = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expectEqual(ScrobblerState.disabled, status.state);
    try std.testing.expectEqual(@as(u64, 0), status.pending);
    try std.testing.expectEqual(@as(u64, 1), status.delivered_total);
    try std.testing.expect((try rig.runtime.libraries.get(fixture.library)).listens.?.worker == null);
}

test "with scrobbling on, a listen is recorded, queued and delivered to ListenBrainz" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-scrobbled?mode=memory&cache=shared");
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);
    try rig.play(player, 100_000);

    _ = try rig.awaitPlayCount(fixture.library, fixture.track_id, 1);
    var deadline: TestDeadline = .init(5_000);
    while ((try rig.runtime.libraryScrobblerStatus(fixture.library)).delivered_total != 1) {
        if (!deadline.tick()) return error.ListenNotDelivered;
    }
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.requests.load(.acquire));
    const library_database = try rig.runtime.libraryDatabase(fixture.library);
    try std.testing.expectEqual(@as(u64, 0), try library_database.scrobbles.pendingCount());
    const status = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expect(status.enabled);
    try std.testing.expectEqual(ScrobblerState.idle, status.state);
}

test "destroying one Library leaves another Library's listens recorded" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const doomed = try rig.openLibrary("file:orca-listen-doomed?mode=memory&cache=shared");
    const kept = try rig.openLibrary("file:orca-listen-kept?mode=memory&cache=shared");
    const doomed_player = try rig.runtime.createPlayer();
    const kept_player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(doomed_player, doomed.library, std.testing.io);
    try rig.runtime.playerBindLibrary(kept_player, kept.library, std.testing.io);

    try rig.runtime.destroyLibrary(doomed.library);

    try rig.startPlaying(kept_player, kept.library, kept.track_id, 3);
    try rig.play(kept_player, 100_000);
    _ = try rig.awaitPlayCount(kept.library, kept.track_id, 1);
    try std.testing.expect((try rig.runtime.libraries.get(kept.library)).listens.?.worker != null);
}

test "shutdown interrupts a hung ListenBrainz request promptly and leaves the listen queued" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    rig.listenbrainz.hang = true;
    const uri = "file:orca-listen-hung?mode=memory&cache=shared";
    const fixture = try rig.openLibrary(uri);
    var witness = try database.LibraryDatabase.open(std.testing.allocator, std.testing.io, uri);
    defer witness.close();
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);
    try rig.play(player, 100_000);
    var deadline: TestDeadline = .init(5_000);
    while (rig.listenbrainz.requests.load(.acquire) == 0) {
        if (!deadline.tick()) return error.RequestNeverSent;
    }

    const started = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    rig.runtime.shutdown();
    const elapsed = std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - started;
    try std.testing.expect(elapsed < 500);

    try std.testing.expectEqual(@as(u64, 1), try witness.scrobbles.pendingCount());
    const now_s = std.Io.Clock.real.now(std.testing.io).toSeconds();
    const unleased = try witness.scrobbles.lease(std.testing.allocator, "listenbrainz", 42, now_s, now_s + 60, 10);
    defer {
        for (unleased) |entry| entry.deinit();
        std.testing.allocator.free(unleased);
    }
    try std.testing.expectEqual(@as(usize, 1), unleased.len);
    try std.testing.expectEqual(@as(u32, 0), unleased[0].attempt_count);
}

test "a Player and a Library with the same slot and generation own different work" {
    const player_owner = OrcaRuntime.playerOwnerTag(.{ .index = 0, .generation = 1 });
    const library_owner = OrcaRuntime.libraryOwnerTag(.{ .index = 0, .generation = 1 });
    try std.testing.expect(!player_owner.eql(library_owner));

    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-owners?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try std.testing.expect(player.index == fixture.library.index and player.generation == fixture.library.generation);
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    const worker = (try rig.runtime.libraries.get(fixture.library)).listens.?.worker.?;

    try rig.runtime.destroyPlayer(player);

    try std.testing.expectEqual(@as(usize, 1), rig.runtime.inFlightWorkCount());
    try std.testing.expect(!worker.registration.cancellationRequested());
}

test "only one Library at a time may scrobble" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const first = try rig.openLibrary("file:orca-listen-first?mode=memory&cache=shared");
    const second = try rig.openLibrary("file:orca-listen-second?mode=memory&cache=shared");
    try rig.runtime.librarySetScrobbling(first.library, true, false, false);
    try std.testing.expectError(
        error.ScrobblingEnabledElsewhere,
        rig.runtime.librarySetScrobbling(second.library, true, false, false),
    );
    try rig.runtime.librarySetScrobbling(second.library, false, false, false);
    try rig.runtime.librarySetScrobbling(first.library, false, false, false);
    try rig.runtime.librarySetScrobbling(second.library, true, false, false);
    try std.testing.expect(!(try rig.runtime.libraryScrobblerStatus(first.library)).enabled);
    try std.testing.expect((try rig.runtime.libraryScrobblerStatus(second.library)).enabled);
}

test "an idle scrobbling worker looks up no token and sends nothing" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    rig.runtime.listen_hooks.poll_ms = 1;
    const fixture = try rig.openLibrary("file:orca-listen-idle?mode=memory&cache=shared");
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try rig.awaitWorkerPasses(200);
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.token_lookups.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requests.load(.acquire));
}

test "a ListenBrainz server is refused unless it is https or loopback" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    try std.testing.expectError(error.InvalidServerUrl, rig.runtime.setListenBrainzServer("http://listenbrainz.example.org"));
    try std.testing.expectError(error.InvalidServerUrl, rig.runtime.setListenBrainzServer("http://127.0.0.1@example.org"));
    try rig.runtime.setListenBrainzServer("http://127.0.0.1:8080");
    try rig.runtime.setListenBrainzServer("https://lb.example.org");
    try std.testing.expectEqualStrings("https://lb.example.org", rig.runtime.listenbrainz_server);
}

test "a changed token is validated once, and only once scrobbling is on" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    rig.runtime.listen_hooks.poll_ms = 1;
    const fixture = try rig.openLibrary("file:orca-listen-validate?mode=memory&cache=shared");
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    for (0..3) |_| try rig.runtime.libraryScrobblerCredentialsChanged(fixture.library);
    try rig.awaitWorkerPasses(20);
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requests.load(.acquire));

    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    var deadline: TestDeadline = .init(5_000);
    while (true) {
        const status = try rig.runtime.libraryScrobblerStatus(fixture.library);
        if (std.mem.eql(u8, status.user_name.slice(), "listener")) break;
        if (!deadline.tick()) return error.TokenNeverValidated;
    }
    try rig.awaitWorkerPasses(20);
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.requests.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.token_lookups.load(.acquire));
}

test "identity, token store and server set while a worker runs apply to its next submission" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-identity?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try rig.awaitWorkerPasses(3);

    try std.testing.expectError(
        error.InvalidNetworkConfiguration,
        rig.runtime.setClientIdentity(.{ .name = "Player (beta)", .version = "1", .contact = "a@b.c" }),
    );
    try rig.runtime.setClientIdentity(.{ .name = "Player", .version = "1.0", .contact = "https://player.example" });
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.setListenBrainzServer("http://127.0.0.1:8080");

    try rig.startPlaying(player, fixture.library, fixture.track_id, 1);
    try rig.play(player, 100_000);
    try rig.awaitDelivered(fixture.library, 1);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/1/submit-listens", rig.listenbrainz.lastUrl());
    try std.testing.expect(std.mem.startsWith(u8, rig.listenbrainz.lastUserAgent(), "Player/1.0 ( https://player.example )"));
    try std.testing.expect(rig.listenbrainz.token_lookups.load(.acquire) >= 1);
    const library_database = try rig.runtime.libraryDatabase(fixture.library);
    var statement = try library_database.database.prepare("SELECT player_client FROM listens;");
    defer statement.deinit();
    try std.testing.expect(try statement.step() == .row);
    try std.testing.expectEqualStrings("Player", statement.columnText(0));
}

test "closing one Library leaves the network Io another Library's worker is using" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const doomed = try rig.openLibrary("file:orca-listen-io-doomed?mode=memory&cache=shared");
    const survivor = try rig.openLibrary("file:orca-listen-io-survivor?mode=memory&cache=shared");
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(survivor.library, true, false, false);
    const doomed_player = try rig.runtime.createPlayer();
    const survivor_player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(doomed_player, doomed.library, std.testing.io);
    try rig.runtime.playerBindLibrary(survivor_player, survivor.library, std.testing.io);
    const network_io = rig.runtime.network_threaded.?;

    try rig.runtime.destroyLibrary(doomed.library);

    try std.testing.expectEqual(network_io, rig.runtime.network_threaded.?);
    try rig.startPlaying(survivor_player, survivor.library, survivor.track_id, 1);
    try rig.play(survivor_player, 100_000);
    try rig.awaitDelivered(survivor.library, 1);
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.requests.load(.acquire));
}

test "a scrobbling Library's worker restarts after another Library closes and delivers its backlog when due" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const doomed = try rig.openLibrary("file:orca-listen-restart-doomed?mode=memory&cache=shared");
    const scrobbling = try rig.openLibrary("file:orca-listen-restart-scrobbling?mode=memory&cache=shared");
    const due_at = @divFloor(FakeListenBrainz.wall_base_ms, 1000) + 60;
    try rig.queueBacklog(scrobbling.library, due_at);
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(scrobbling.library, true, false, false);
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, doomed.library, std.testing.io);
    try rig.awaitWorkerPasses(3);

    try rig.runtime.destroyLibrary(doomed.library);

    try std.testing.expect((try rig.runtime.libraries.get(scrobbling.library)).listens.?.worker != null);
    try rig.awaitWorkerPasses(3);
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requests.load(.acquire));
    rig.listenbrainz.advance(61_000);
    try rig.awaitDelivered(scrobbling.library, 1);
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.requests.load(.acquire));
}

test "a listen that ends after its Library's worker was drained still records its final time" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const doomed = try rig.openLibrary("file:orca-listen-late-doomed?mode=memory&cache=shared");
    const kept = try rig.openLibrary("file:orca-listen-late-kept?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, kept.library, std.testing.io);
    try rig.startPlaying(player, kept.library, kept.track_id, 7);
    try rig.play(player, 150_000);
    _ = try rig.awaitPlayCount(kept.library, kept.track_id, 1);

    try rig.runtime.destroyLibrary(doomed.library);
    try std.testing.expect((try rig.runtime.libraries.get(kept.library)).listens.?.worker == null);
    try rig.runtime.destroyPlayer(player);

    const library_database = try rig.runtime.libraryDatabase(kept.library);
    var deadline: TestDeadline = .init(5_000);
    while (deadline.tick()) {
        var statement = try library_database.database.prepare("SELECT listened_ms FROM listens;");
        defer statement.deinit();
        if (try statement.step() == .row and statement.columnInt64(0) == 149_900) return;
    }
    return error.FinishedListenNotRecorded;
}

test "an idle scrobbling worker finds listens another process queued at its next recheck" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-recheck?mode=memory&cache=shared");
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try rig.awaitWorkerPasses(3);

    try rig.queueBacklog(fixture.library, 0);
    try rig.awaitWorkerPasses(20);
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requests.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.token_lookups.load(.acquire));

    rig.listenbrainz.advance(5 * 60 * 1000);
    try rig.awaitDelivered(fixture.library, 1);
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.requests.load(.acquire));
}

const feedback_mbid = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";

test "a Track loved while scrobbling is on reaches ListenBrainz through the worker" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-feedback-love?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, feedback_mbid);
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try rig.awaitWorkerPasses(3);

    const change = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .loved);

    try std.testing.expectEqual(@as(u32, 1), change.updated);
    try rig.awaitWorkerPasses(3);
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.feedback_sent.load(.acquire));
    rig.listenbrainz.advance(2_000);
    try ListenRig.awaitCount(&rig.listenbrainz.feedback_sent, 1);
    try rig.awaitFeedbackSettled(fixture.library);
    try std.testing.expectEqual(@as(i32, 1), rig.listenbrainz.last_score.load(.acquire));
    try std.testing.expectEqual(Feedback.loved, try rig.runtime.libraryTrackFeedback(fixture.library, fixture.track_id));
    try rig.awaitWorkerPasses(10);
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.feedback_sent.load(.acquire));
}

test "feedback given while scrobbling was off is reported pending and sent once it is turned on" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-feedback-later?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, feedback_mbid);
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());

    _ = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .hated);

    const stored = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expectEqual(@as(u64, 1), stored.feedback_pending);
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requests.load(.acquire));
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try ListenRig.awaitCount(&rig.listenbrainz.feedback_sent, 1);
    try rig.awaitFeedbackSettled(fixture.library);
    try std.testing.expectEqual(@as(i32, -1), rig.listenbrainz.last_score.load(.acquire));
}

test "love, dislike and love again while the love is being sent ends loved after at most two requests" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-feedback-flip?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, feedback_mbid);
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try rig.awaitWorkerPasses(3);
    const library_database = try rig.runtime.libraryDatabase(fixture.library);
    const Flip = struct {
        library: *database.LibraryDatabase,
        track_id: i64,

        fn run(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.library.feedback.set(&.{self.track_id}, .hated) catch return;
            _ = self.library.feedback.set(&.{self.track_id}, .loved) catch return;
        }
    };
    var flip: Flip = .{ .library = library_database, .track_id = fixture.track_id };
    rig.listenbrainz.during_feedback = .{ .context = &flip, .run = Flip.run };

    _ = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .loved);
    try rig.awaitWorkerPasses(3);
    rig.listenbrainz.advance(2_000);

    try ListenRig.awaitCount(&rig.listenbrainz.feedback_sent, 1);
    try rig.awaitFeedbackSettled(fixture.library);
    try rig.awaitWorkerPasses(10);
    try std.testing.expect(rig.listenbrainz.feedback_sent.load(.acquire) <= 2);
    try std.testing.expectEqual(@as(i32, 1), rig.listenbrainz.last_score.load(.acquire));
    try std.testing.expectEqual(Feedback.loved, try rig.runtime.libraryTrackFeedback(fixture.library, fixture.track_id));
}

test "a recording without a MusicBrainz id is loved locally, never sent, and costs an idle worker nothing" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    rig.runtime.listen_hooks.poll_ms = 1;
    const fixture = try rig.openLibrary("file:orca-feedback-untagged?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, null);
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);

    _ = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .loved);
    try rig.awaitWorkerPasses(200);

    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requests.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.token_lookups.load(.acquire));
    const status = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expectEqual(@as(u64, 0), status.feedback_pending);
    const details = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer details.deinit();
    try std.testing.expectEqual(Feedback.loved, details.feedback);
    try std.testing.expect(!details.feedback_syncable);
}

test "a rejected feedback change is recorded and not sent again" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-feedback-rejected?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, feedback_mbid);
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    rig.listenbrainz.feedback_status.store(400, .release);
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);

    try rig.awaitWorkerPasses(3);
    _ = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .loved);
    try rig.awaitWorkerPasses(3);
    rig.listenbrainz.advance(2_000);

    try ListenRig.awaitCount(&rig.listenbrainz.feedback_sent, 1);
    try rig.awaitFeedbackSettled(fixture.library);
    rig.listenbrainz.advance(10 * 60 * 1000);
    try rig.awaitWorkerPasses(20);
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.feedback_sent.load(.acquire));
    const details = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer details.deinit();
    try std.testing.expectEqual(Feedback.loved, details.feedback);
    try std.testing.expect(details.feedback_syncable);
}

test "track pages and details carry the feedback of the recording" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-feedback-pages?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, feedback_mbid);

    _ = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .hated);

    var page = try rig.runtime.libraryTrackQuery(fixture.library, "", .{ .limit = 8 });
    defer page.deinit();
    try std.testing.expectEqual(Feedback.hated, page.items[0].feedback);
    const details = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer details.deinit();
    try std.testing.expectEqual(Feedback.hated, details.feedback);
    try std.testing.expect(details.feedback_syncable);

    _ = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .none);
    try std.testing.expectEqual(Feedback.none, try rig.runtime.libraryTrackFeedback(fixture.library, fixture.track_id));
}

test "Now Playing is announced once a track has been heard for ten seconds, when the option is on" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-now-playing-on?mode=memory&cache=shared");
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, true);
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);

    try rig.play(player, 9_900);
    try rig.awaitWorkerPasses(5);
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.now_playing_sent.load(.acquire));
    try rig.play(player, 300);

    try ListenRig.awaitCount(&rig.listenbrainz.now_playing_sent, 1);
    try rig.play(player, 20_000);
    try rig.awaitWorkerPasses(10);
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.now_playing_sent.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.listens_sent.load(.acquire));
}

test "Now Playing is never sent unless the option and scrobbling are both on" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-now-playing-off?mode=memory&cache=shared");
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);

    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try rig.play(player, 20_000);
    try rig.runtime.librarySetScrobbling(fixture.library, false, false, true);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 8);
    try rig.play(player, 20_000);
    try rig.awaitWorkerPasses(20);

    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.now_playing_sent.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requests.load(.acquire));
}

const northern_sky_mbid = "0b3c4d5e-6f70-4812-9a3b-4c5d6e7f8091";
const pink_moon_mbid = "1d2e3f40-5162-4738-8a9b-0c1d2e3f4a5b";

fn recordingAnswer(comptime mbid: []const u8, comptime title: []const u8) []const u8 {
    return "{\"recordings\":[{\"id\":\"" ++ mbid ++ "\",\"score\":100,\"title\":\"" ++ title ++
        "\",\"length\":180000,\"artist-credit\":[{\"name\":\"Nick Drake\"}],\"releases\":[{" ++
        "\"id\":\"2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b\",\"title\":\"Bryter Layter\"," ++
        "\"media\":[{\"track-offset\":2,\"track\":[{\"number\":\"3\"}]}]}]}]}";
}

const northern_sky_answer = recordingAnswer(northern_sky_mbid, "Northern Sky");
const pink_moon_answer = recordingAnswer(pink_moon_mbid, "Pink Moon");

/// Every call arrives on the job's thread; a test reads `requests` while the
/// job runs and the rest only once it is reaped.
const FakeMusicBrainz = struct {
    answers: []const Answer = &.{},
    refusals: []const u16 = &.{},
    failure: ?anyerror = null,
    hang_from: ?u32 = null,
    requests: std.atomic.Value(u32) = .init(0),
    request_times_ms: [8]i64 = @splat(0),
    url: [256]u8 = undefined,
    url_len: usize = 0,
    now_ms: std.atomic.Value(i64) = .init(0),

    const Answer = struct { title: []const u8, body: []const u8 };
    const wall_base_ms: i64 = 1_800_000_000_000;

    fn hooks(self: *FakeMusicBrainz) MatchingHooks {
        return .{
            .transport = .{ .context = self, .perform_fn = perform },
            .clock = .{ .context = self, .now_ms_fn = nowMs, .sleep_ms_fn = sleepMs },
            .wall_clock = .{ .context = self, .now_ms_fn = wallMs, .sleep_ms_fn = sleepMs },
        };
    }

    fn lastUrl(self: *const FakeMusicBrainz) []const u8 {
        return self.url[0..self.url_len];
    }

    fn perform(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        request: network.client.Request,
    ) anyerror!network.client.Response {
        const self: *FakeMusicBrainz = @ptrCast(@alignCast(context));
        const index = self.requests.load(.acquire);
        if (index < self.request_times_ms.len) self.request_times_ms[index] = self.now_ms.load(.acquire);
        self.url_len = @min(request.url.len, self.url.len);
        @memcpy(self.url[0..self.url_len], request.url[0..self.url_len]);
        _ = self.requests.fetchAdd(1, .acq_rel);
        if (self.hang_from) |first| if (index >= first) {
            var waited: TestDeadline = .init(10_000);
            while (waited.tick()) {
                if (request.cancel.?.load(.acquire)) return error.Canceled;
            }
            return error.Timeout;
        };
        if (self.failure) |err| return err;
        if (index < self.refusals.len)
            return .{ .allocator = allocator, .status = self.refusals[index], .body = try allocator.dupe(u8, "") };
        const body = for (self.answers) |answer| {
            if (std.mem.indexOf(u8, request.url, answer.title) != null) break answer.body;
        } else "{\"recordings\":[]}";
        return .{ .allocator = allocator, .status = 200, .body = try allocator.dupe(u8, body) };
    }

    fn nowMs(context: *anyopaque) i64 {
        const self: *FakeMusicBrainz = @ptrCast(@alignCast(context));
        return self.now_ms.load(.acquire);
    }

    fn wallMs(context: *anyopaque) i64 {
        return wall_base_ms + nowMs(context);
    }

    fn sleepMs(context: *anyopaque, milliseconds: u64) anyerror!void {
        const self: *FakeMusicBrainz = @ptrCast(@alignCast(context));
        _ = self.now_ms.fetchAdd(@intCast(milliseconds), .acq_rel);
    }

    fn awaitRequests(self: *const FakeMusicBrainz, expected: u32) !void {
        var deadline: TestDeadline = .init(5_000);
        while (self.requests.load(.acquire) < expected) {
            if (!deadline.tick()) return error.RequestNeverSent;
        }
    }
};

fn addMatchTrack(library_database: *database.LibraryDatabase, title: []const u8, artist: []const u8, mbid: ?[]const u8) !i64 {
    const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
    try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = title,
        .musicbrainz_recording_id = mbid,
    } });
    try library_database.tracks.upsertTracks(&.{.{
        .title = title,
        .artist = artist,
        .album = "Bryter Layter",
        .duration_ms = 180_000,
        .preferred_file_id = file_id,
    }});
    const ids = try library_database.tracks.idsForFile(std.testing.allocator, file_id);
    defer std.testing.allocator.free(ids);
    return ids[0];
}

test "a matching job proposes recordings for the Tracks without one, one search a Track, and a rerun asks nothing already answered" {
    var fake: FakeMusicBrainz = .{ .answers = &.{
        .{ .title = "Northern%20Sky", .body = northern_sky_answer },
        .{ .title = "Pink%20Moon", .body = pink_moon_answer },
    } };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    try std.testing.expectError(error.InvalidServerUrl, runtime.setMusicBrainzServer("http://musicbrainz.org"));
    try runtime.setMusicBrainzServer("http://127.0.0.1:5000");
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-job?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(library);
    const northern_sky = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);
    _ = try addMatchTrack(library_database, "Hazey Jane II", "Nick Drake", "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a");
    _ = try addMatchTrack(library_database, "Untitled", "", null);
    const pink_moon = try addMatchTrack(library_database, "Pink Moon", "Nick Drake", null);
    try library_database.database.exec(
        "INSERT INTO recordings(title) VALUES ('Pink Moon');" ++
            "UPDATE files SET recording_id = (SELECT max(id) FROM recordings) " ++
            "WHERE id = (SELECT preferred_file_id FROM tracks WHERE title = 'Pink Moon');" ++
            "UPDATE tracks SET recording_id = (SELECT max(id) FROM recordings) WHERE title = 'Pink Moon';" ++
            "INSERT INTO files(audio_format, size_bytes, recording_id) VALUES (2, 512, (SELECT max(id) FROM recordings));",
    );
    _ = try addMatchTrack(library_database, "Unknown Song", "Nobody", null);

    const job_handle = try runtime.startLibraryMatching(library, .{ .batch_size = 2 });

    try std.testing.expectEqual(@as(?u64, 4), (try runtime.jobSnapshotSynced(job_handle)).total_units);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, job_handle));
    const stats = try runtime.jobMatchStats(job_handle);
    try std.testing.expectEqual(@as(u64, 4), stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 2), stats.matched);
    try std.testing.expectEqual(@as(u64, 1), stats.unmatched);
    try std.testing.expectEqual(@as(u64, 1), stats.insufficient_evidence);
    try std.testing.expectEqual(@as(u64, 3), stats.requests);
    try std.testing.expectEqual(@as(u64, 0), stats.cache_hits);
    try std.testing.expectEqual(@as(u64, 2), stats.proposals_stored);
    try std.testing.expectEqual(ScanStats{}, try runtime.jobScanStats(job_handle));
    try std.testing.expectEqual(@as(u32, 3), fake.requests.load(.acquire));
    try std.testing.expect(std.mem.startsWith(u8, fake.lastUrl(), "http://127.0.0.1:5000/ws/2/recording?fmt=json&limit=10&query="));

    const proposals = try runtime.libraryMatchProposals(library, northern_sky, 10);
    defer proposals.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposals.items.len);
    const proposal = proposals.items[0];
    try std.testing.expectEqualStrings(northern_sky_mbid, proposal.recording_mbid);
    try std.testing.expectEqualStrings("Nick Drake", proposal.artist);
    try std.testing.expectEqualStrings("Bryter Layter", proposal.album);
    try std.testing.expectEqualStrings("2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b", proposal.release_mbid.?);
    try std.testing.expectEqual(@as(?u32, 3), proposal.track_number);
    try std.testing.expectEqual(@as(?u64, 180_000), proposal.duration_ms);
    try std.testing.expectEqual(@as(?u8, 100), proposal.musicbrainz_score);
    try std.testing.expect(proposal.confidence > 0.9);
    const pink_proposals = try runtime.libraryMatchProposals(library, pink_moon, 10);
    defer pink_proposals.deinit();
    try std.testing.expectEqualStrings(pink_moon_mbid, pink_proposals.items[0].recording_mbid);

    runtime.reapFinishedJobs();
    const rerun = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, rerun));
    const rerun_stats = try runtime.jobMatchStats(rerun);
    try std.testing.expectEqual(@as(u64, 1), rerun_stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 1), rerun_stats.insufficient_evidence);
    try std.testing.expectEqual(@as(u64, 0), rerun_stats.requests);
    try std.testing.expectEqual(@as(u64, 0), rerun_stats.cache_hits);
    try std.testing.expectEqual(AcoustIdUse.no_client_key, rerun_stats.acoustid);
    try std.testing.expectEqual(@as(u32, 3), fake.requests.load(.acquire));
}

test "an accepted match gives the Track a recording id, which its love is sent to ListenBrainz under" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    var fake: FakeMusicBrainz = .{ .answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_answer }} };
    rig.runtime.matching_hooks = fake.hooks();
    const fixture = try rig.openLibrary("file:orca-matching-accept?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, null);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&rig.runtime, try rig.runtime.startLibraryMatching(fixture.library, .{})));
    const proposals = try rig.runtime.libraryMatchProposals(fixture.library, fixture.track_id, 10);
    defer proposals.deinit();
    const before = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer before.deinit();
    try std.testing.expect(!before.feedback_syncable);
    try std.testing.expectEqual(@as(?[]u8, null), before.musicbrainz_recording_id);

    const acceptance = try rig.runtime.libraryAcceptMatch(fixture.library, proposals.items[0].id);

    try std.testing.expectEqual(@as(u32, 1), acceptance.values_written);
    try std.testing.expectError(error.StaleIdentificationProposal, rig.runtime.libraryAcceptMatch(fixture.library, proposals.items[0].id));
    const after = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer after.deinit();
    try std.testing.expect(after.feedback_syncable);
    try std.testing.expectEqualStrings(northern_sky_mbid, after.musicbrainz_recording_id.?);
    try std.testing.expectEqual(@as(?RecordingIdSource, .match), after.musicbrainz_recording_id_source);

    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    _ = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .loved);
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try rig.awaitWorkerPasses(3);
    rig.listenbrainz.advance(2_000);
    try ListenRig.awaitCount(&rig.listenbrainz.feedback_sent, 1);
    try std.testing.expectEqualStrings(northern_sky_mbid, &rig.listenbrainz.feedback_mbid);
}

test "a Track's recording id names where it came from, and only a well-formed one can be set by hand" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-matching-source?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, northern_sky_mbid);
    const tagged = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer tagged.deinit();
    try std.testing.expectEqual(@as(?RecordingIdSource, .tag), tagged.musicbrainz_recording_id_source);

    try std.testing.expectError(error.InvalidEditValue, rig.runtime.libraryEditTracks(
        fixture.library,
        &.{fixture.track_id},
        &.{.{ .field = .musicbrainz_recording_id, .value = "not-a-recording" }},
    ));
    const library_database = try rig.runtime.libraryDatabase(fixture.library);
    const file_ids = try library_database.tracks.fileIds(std.testing.allocator, fixture.track_id);
    defer std.testing.allocator.free(file_ids);
    try library_database.orca_metadata.upsert(.{
        .file_id = file_ids[0],
        .field = .musicbrainz_recording_id,
        .value = pink_moon_mbid,
        .provenance = .user,
        .locked = true,
    });
    const edited = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer edited.deinit();
    try std.testing.expectEqualStrings(pink_moon_mbid, edited.musicbrainz_recording_id.?);
    try std.testing.expectEqual(@as(?RecordingIdSource, .edit), edited.musicbrainz_recording_id_source);
}

test "a matching job stops when cancelled mid-search, and another cannot start while it runs" {
    var fake: FakeMusicBrainz = .{ .answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_answer }}, .hang_from = 1 };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-cancel?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(library);
    const northern_sky = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);
    _ = try addMatchTrack(library_database, "Pink Moon", "Nick Drake", null);
    _ = try addMatchTrack(library_database, "River Man", "Nick Drake", null);

    const job_handle = try runtime.startLibraryMatching(library, .{});
    try fake.awaitRequests(2);
    try std.testing.expectEqual(@as(u64, 1), (try runtime.jobMatchStats(job_handle)).matched);
    try std.testing.expectError(error.MatchingAlreadyRunning, runtime.startLibraryMatching(library, .{}));
    try runtime.cancelJob(job_handle);

    try std.testing.expectEqual(job.State.cancelled, try awaitJob(&runtime, job_handle));
    const stats = try runtime.jobMatchStats(job_handle);
    try std.testing.expect(stats.cancelled);
    try std.testing.expectEqual(@as(u64, 1), stats.tracks_examined);
    try std.testing.expectEqual(@as(u32, 2), fake.requests.load(.acquire));
    const proposals = try runtime.libraryMatchProposals(library, northern_sky, 10);
    defer proposals.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposals.items.len);
    try std.testing.expectEqual(@as(u64, 2), try library_database.identification_proposals.unidentifiedCount(.library, false, null));

    fake.hang_from = null;
    const resumed = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, resumed));
    try std.testing.expectEqual(@as(u64, 2), (try runtime.jobMatchStats(resumed)).tracks_examined);
    try std.testing.expectEqual(@as(u32, 4), fake.requests.load(.acquire));
}

test "a refused search is waited out and retried, and an unreachable MusicBrainz stops the job without marking the Track" {
    var fake: FakeMusicBrainz = .{
        .answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_answer }},
        .refusals = &.{ 503, 429 },
    };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-backoff?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(library);
    const northern_sky = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);

    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, try runtime.startLibraryMatching(library, .{})));

    try std.testing.expectEqual(@as(u32, 3), fake.requests.load(.acquire));
    try std.testing.expect(fake.request_times_ms[1] - fake.request_times_ms[0] >= 60_000);
    try std.testing.expect(fake.request_times_ms[2] - fake.request_times_ms[1] >= 120_000);
    const proposals = try runtime.libraryMatchProposals(library, northern_sky, 10);
    defer proposals.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposals.items.len);

    _ = try addMatchTrack(library_database, "Pink Moon", "Nick Drake", null);
    fake.failure = error.ConnectionRefused;
    const unreachable_job = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.failed, try awaitJob(&runtime, unreachable_job));
    try std.testing.expectEqual(@as(u64, 0), (try runtime.jobMatchStats(unreachable_job)).tracks_examined);
    try std.testing.expectEqual(@as(u64, 1), try library_database.identification_proposals.unidentifiedCount(.library, false, null));

    fake.failure = null;
    const retried = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, retried));
    const retried_stats = try runtime.jobMatchStats(retried);
    try std.testing.expectEqual(@as(u64, 1), retried_stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 1), retried_stats.requests);
}

test "a tag write leaves out the recording id Orca holds for a file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try scannedTempLibrary(&runtime, &temporary, "file:orca-runtime-tag-write-mbid?mode=memory&cache=shared");
    const ids = try allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    const library_database = try runtime.libraryDatabase(library);
    for (ids) |track_id| {
        const file_ids = try library_database.tracks.fileIds(std.testing.allocator, track_id);
        defer std.testing.allocator.free(file_ids);
        for (file_ids) |file_id| try library_database.orca_metadata.upsert(.{
            .file_id = file_id,
            .field = .musicbrainz_recording_id,
            .value = northern_sky_mbid,
            .provenance = .provider,
        });
    }

    const preview = try runtime.planTagWrite(library, std.testing.io, ids);
    defer preview.deinit();

    try std.testing.expectEqual(@as(u64, 0), preview.plan_id);
    try std.testing.expectEqual(@as(usize, 0), preview.files.len);
}

fn addReviewTrack(
    library_database: *database.LibraryDatabase,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    track_number: ?i64,
) !i64 {
    const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
    try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = .{ .title = title } });
    try library_database.tracks.upsertTracks(&.{.{
        .title = title,
        .artist = artist,
        .album = album,
        .track_number = track_number,
        .duration_ms = 180_000,
        .preferred_file_id = file_id,
    }});
    const ids = try library_database.tracks.idsForFile(std.testing.allocator, file_id);
    defer std.testing.allocator.free(ids);
    return ids[0];
}

fn proposeMatch(library_database: *database.LibraryDatabase, track_id: i64, mbid: []const u8, confidence: f32, payload: []const u8) !void {
    const file_ids = try library_database.tracks.fileIds(std.testing.allocator, track_id);
    defer std.testing.allocator.free(file_ids);
    _ = try library_database.identification_proposals.put(.{
        .file_id = file_ids[0],
        .provider = "musicbrainz",
        .provider_id = mbid,
        .confidence = confidence,
        .payload = payload,
    });
    _ = try library_database.identification_proposals.recordSearch(std.testing.allocator, file_ids[0], .{ .musicbrainz = true }, &.{});
}

const review_payload = "{\"title\":\"Northern Sky\",\"artist\":\"Nick Drake\",\"album\":\"Bryter Layter\",\"duration_ms\":225000}";

test "the review list holds each Track awaiting review once, by artist, album and position, with its best match" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-review?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(library);
    const later_on_album = try addReviewTrack(library_database, "Northern Sky", "Nick Drake", "Bryter Layter", 8);
    const first_on_album = try addReviewTrack(library_database, "Hazey Jane II", "Nick Drake", "Bryter Layter", 2);
    const other_artist = try addReviewTrack(library_database, "Waterloo Sunset", "The Kinks", "Something Else", 12);
    const earlier_album = try addReviewTrack(library_database, "Pink Moon", "Nick Drake", "Pink Moon", 1);
    const nothing_pending = try addReviewTrack(library_database, "River Man", "Nick Drake", "Five Leaves Left", 5);
    try proposeMatch(library_database, later_on_album, northern_sky_mbid, 0.6, review_payload);
    try proposeMatch(library_database, later_on_album, pink_moon_mbid, 0.95, review_payload);
    try proposeMatch(library_database, first_on_album, northern_sky_mbid, 0.8, review_payload);
    try proposeMatch(library_database, other_artist, northern_sky_mbid, 0.7, review_payload);
    try proposeMatch(library_database, earlier_album, pink_moon_mbid, 0.9, review_payload);

    const page = try runtime.libraryMatchReviewPage(library, 512, 0);
    defer page.deinit();

    try std.testing.expectEqual(@as(u64, 4), try runtime.libraryMatchReviewCount(library));
    try std.testing.expectEqual(@as(u64, 1), try runtime.libraryUnidentifiedCount(library));
    try std.testing.expectEqual(@as(usize, 4), page.items.len);
    const expected_order = [_]i64{ first_on_album, later_on_album, earlier_album, other_artist };
    for (expected_order, page.items) |track_id, item| try std.testing.expectEqual(track_id, item.track_id);
    const two = page.items[1];
    try std.testing.expectEqualStrings("Northern Sky", two.title);
    try std.testing.expectEqual(@as(?i64, 180_000), two.duration_ms);
    try std.testing.expectEqual(@as(u32, 2), two.proposal_count);
    try std.testing.expectEqualStrings(pink_moon_mbid, two.best.recording_mbid);
    try std.testing.expectEqual(@as(?u64, 225_000), two.best.duration_ms);
    for (page.items) |item| try std.testing.expect(item.track_id != nothing_pending);

    const second = try runtime.libraryMatchReviewPage(library, 2, 2);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 2), second.items.len);
    try std.testing.expectEqual(earlier_album, second.items[0].track_id);
    try std.testing.expectError(error.PageOutOfRange, runtime.libraryMatchReviewPage(library, 513, 0));
    try std.testing.expectError(error.PageOutOfRange, runtime.libraryMatchReviewPage(library, 0, 0));
}

test "the confident count is exactly how many matches accepting confident ones then accepts" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-confident?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(library);
    const alone = try addReviewTrack(library_database, "Northern Sky", "Nick Drake", "Bryter Layter", 8);
    const contested = try addReviewTrack(library_database, "Pink Moon", "Nick Drake", "Pink Moon", 1);
    const ahead = try addReviewTrack(library_database, "River Man", "Nick Drake", "Five Leaves Left", 5);
    const doubtful = try addReviewTrack(library_database, "Fly", "Nick Drake", "Bryter Layter", 7);
    const unreadable = try addReviewTrack(library_database, "Poor Boy", "Nick Drake", "Bryter Layter", 6);
    try proposeMatch(library_database, alone, northern_sky_mbid, 0.95, review_payload);
    try proposeMatch(library_database, contested, northern_sky_mbid, 0.95, review_payload);
    try proposeMatch(library_database, contested, pink_moon_mbid, 0.92, review_payload);
    try proposeMatch(library_database, ahead, northern_sky_mbid, 0.95, review_payload);
    try proposeMatch(library_database, ahead, pink_moon_mbid, 0.5, review_payload);
    try proposeMatch(library_database, doubtful, northern_sky_mbid, 0.7, review_payload);
    try proposeMatch(library_database, unreadable, northern_sky_mbid, 0.99, "[");

    const counted = try runtime.libraryConfidentMatchCount(library, 0.9);
    const lower = try runtime.libraryConfidentMatchCount(library, 0.6);
    const accepted = try runtime.libraryAcceptConfidentMatches(library, 0.9);

    try std.testing.expectEqual(@as(u64, 2), counted);
    try std.testing.expectEqual(counted, accepted);
    try std.testing.expectEqual(@as(u64, 3), lower);
    try std.testing.expectEqual(@as(u64, 0), try runtime.libraryConfidentMatchCount(library, 0.9));
    try std.testing.expectError(error.InvalidMinimumConfidence, runtime.libraryConfidentMatchCount(library, 0));
}

test "a single-Track matching job searches only that Track, and one already identified or already answered for is not searched" {
    var fake: FakeMusicBrainz = .{ .answers = &.{
        .{ .title = "Northern%20Sky", .body = northern_sky_answer },
        .{ .title = "Pink%20Moon", .body = pink_moon_answer },
    } };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-single?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(library);
    const northern_sky = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);
    const pink_moon = try addMatchTrack(library_database, "Pink Moon", "Nick Drake", null);
    const tagged = try addMatchTrack(library_database, "Hazey Jane II", "Nick Drake", "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a");

    const job_handle = try runtime.startLibraryMatching(library, .{ .track_id = pink_moon });

    try std.testing.expectEqual(@as(?u64, 1), (try runtime.jobSnapshotSynced(job_handle)).total_units);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, job_handle));
    try std.testing.expectEqual(@as(u64, 1), (try runtime.jobMatchStats(job_handle)).matched);
    try std.testing.expectEqual(@as(u32, 1), fake.requests.load(.acquire));
    const untouched = try runtime.libraryMatchProposals(library, northern_sky, 10);
    defer untouched.deinit();
    try std.testing.expectEqual(@as(usize, 0), untouched.items.len);
    try std.testing.expectEqual(@as(u64, 1), try runtime.libraryUnidentifiedCount(library));

    for ([_]i64{ pink_moon, tagged }) |not_searched| {
        runtime.reapFinishedJobs();
        const skipped = try runtime.startLibraryMatching(library, .{ .track_id = not_searched });
        try std.testing.expectEqual(@as(?u64, 0), (try runtime.jobSnapshotSynced(skipped)).total_units);
        try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, skipped));
        try std.testing.expectEqual(@as(u64, 0), (try runtime.jobMatchStats(skipped)).tracks_examined);
    }
    try std.testing.expectEqual(@as(u32, 1), fake.requests.load(.acquire));
}

/// Answers AcoustID lookups and submissions on the job's thread; a test reads
/// what it recorded once the job is reaped.
const FakeAcoustId = struct {
    lookup_body: []const u8 = "{\"status\":\"ok\",\"fingerprints\":[]}",
    submit_status: u16 = 200,
    submit_body: []const u8 = "{\"status\":\"ok\",\"submissions\":[]}",
    lookups: std.atomic.Value(u32) = .init(0),
    submissions: std.atomic.Value(u32) = .init(0),
    form: [16 * 1024]u8 = undefined,
    form_len: usize = 0,

    fn transport(self: *FakeAcoustId) network.client.Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn lastForm(self: *const FakeAcoustId) []const u8 {
        return self.form[0..self.form_len];
    }

    fn perform(context: *anyopaque, allocator: std.mem.Allocator, request: network.client.Request) anyerror!network.client.Response {
        const self: *FakeAcoustId = @ptrCast(@alignCast(context));
        var input: std.Io.Reader = .fixed(request.body.?);
        const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
        defer allocator.free(window);
        var decompressor: std.compress.flate.Decompress = .init(&input, .gzip, window);
        var form = std.Io.Writer.Allocating.init(allocator);
        defer form.deinit();
        _ = try decompressor.reader.streamRemaining(&form.writer);
        self.form_len = @min(form.written().len, self.form.len);
        @memcpy(self.form[0..self.form_len], form.written()[0..self.form_len]);
        if (std.mem.endsWith(u8, request.url, "/v2/lookup")) {
            _ = self.lookups.fetchAdd(1, .acq_rel);
            return .{ .allocator = allocator, .status = 200, .body = try allocator.dupe(u8, self.lookup_body) };
        }
        _ = self.submissions.fetchAdd(1, .acq_rel);
        return .{ .allocator = allocator, .status = self.submit_status, .body = try allocator.dupe(u8, self.submit_body) };
    }
};

const AcoustIdUserKey = struct {
    key: ?[]const u8,

    fn store(self: *AcoustIdUserKey) CredentialStore {
        return .{ .context = self, .get_fn = get };
    }

    fn get(context: *anyopaque, allocator: std.mem.Allocator, service: []const u8, account: []const u8) anyerror!?[]u8 {
        const self: *AcoustIdUserKey = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, service, providers.acoustid.credential_service)) return null;
        if (!std.mem.eql(u8, account, providers.acoustid.user_key_account)) return null;
        return if (self.key) |key| try allocator.dupe(u8, key) else null;
    }
};

/// Fifteen seconds of a mono tone at 11025 Hz, long enough to fingerprint.
fn writeToneWave(dir: std.Io.Dir, name: []const u8, frequency: f32) !void {
    const rate = 11_025;
    const frames = 15 * rate;
    var bytes: [44 + frames * 2]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], bytes.len - 8, .little);
    @memcpy(bytes[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], 1, .little);
    std.mem.writeInt(u32, bytes[24..28], rate, .little);
    std.mem.writeInt(u32, bytes[28..32], rate * 2, .little);
    std.mem.writeInt(u16, bytes[32..34], 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], frames * 2, .little);
    for (0..frames) |frame| {
        const time = @as(f32, @floatFromInt(frame)) / rate;
        const wobble = frequency * (1 + 0.2 * @sin(2 * std.math.pi * 0.5 * time));
        const sample: i16 = @intFromFloat(9000 * @sin(2 * std.math.pi * wobble * time));
        std.mem.writeInt(i16, bytes[44 + frame * 2 ..][0..2], sample, .little);
    }
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = &bytes });
}

fn addAudioTrack(
    library_database: *database.LibraryDatabase,
    temporary: *std.testing.TmpDir,
    name: []const u8,
    title: []const u8,
    artist: []const u8,
) !i64 {
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ temporary.sub_path, name });
    defer std.testing.allocator.free(path);
    const binding = try library_database.resolveOrCreateFile(std.testing.io, path, .{ .stable_key = "test:acoustid" });
    try library_database.tracks.upsertTracks(&.{.{
        .title = title,
        .artist = artist,
        .album = "Bryter Layter",
        .duration_ms = 15_000,
        .preferred_file_id = binding.file_id,
    }});
    const ids = try library_database.tracks.idsForFile(std.testing.allocator, binding.file_id);
    defer std.testing.allocator.free(ids);
    return ids[0];
}

const two_fingerprint_answer =
    "{\"status\":\"ok\",\"fingerprints\":[" ++
    "{\"index\":0,\"results\":[{\"id\":\"t1\",\"score\":0.96,\"recordings\":[{\"id\":\"" ++ northern_sky_mbid ++
    "\",\"title\":\"Northern Sky\",\"duration\":15,\"artists\":[{\"id\":\"a1\",\"name\":\"Nick Drake\"}]}]}]}," ++
    "{\"index\":1,\"results\":[{\"id\":\"t2\",\"score\":0.93,\"recordings\":[{\"id\":\"" ++ pink_moon_mbid ++ "\"}]}]}]}";

test "a matching job fingerprints each file, asks AcoustID about them in one request, merges both services, and a rerun asks neither" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeToneWave(temporary.dir, "northern.wav", 440);
    try writeToneWave(temporary.dir, "untagged.wav", 620);
    var musicbrainz: FakeMusicBrainz = .{ .answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_answer }} };
    var acoustid: FakeAcoustId = .{ .lookup_body = two_fingerprint_answer };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = musicbrainz.hooks();
    runtime.matching_hooks.acoustid_transport = acoustid.transport();
    try std.testing.expectError(error.InvalidAcoustIdKey, runtime.setAcoustIdClientKey("with space"));
    try runtime.setAcoustIdClientKey("test-client");
    try runtime.setAcoustIdServer("http://127.0.0.1:5002");
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-acoustid?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(library);
    const northern_sky = try addAudioTrack(library_database, &temporary, "northern.wav", "Northern Sky", "Nick Drake");
    const untagged = try addAudioTrack(library_database, &temporary, "untagged.wav", "", "");

    const job_handle = try runtime.startLibraryMatching(library, .{});

    try std.testing.expectEqual(@as(?u64, 2), (try runtime.jobSnapshotSynced(job_handle)).total_units);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, job_handle));
    const stats = try runtime.jobMatchStats(job_handle);
    try std.testing.expectEqual(AcoustIdUse.searched, stats.acoustid);
    try std.testing.expectEqual(@as(u64, 2), stats.fingerprinted);
    try std.testing.expectEqual(@as(u64, 1), stats.acoustid_requests);
    try std.testing.expectEqual(@as(u64, 1), stats.requests);
    try std.testing.expectEqual(@as(u64, 2), stats.matched);
    try std.testing.expectEqual(@as(u32, 1), acoustid.lookups.load(.acquire));
    try std.testing.expect(std.mem.startsWith(u8, acoustid.lastForm(), "client=test-client&"));
    try std.testing.expect(std.mem.indexOf(u8, acoustid.lastForm(), "&duration.0=15&fingerprint.0=AQA") != null);
    try std.testing.expect(std.mem.indexOf(u8, acoustid.lastForm(), "&duration.1=15&fingerprint.1=AQA") != null);

    const both = try runtime.libraryMatchProposals(library, northern_sky, 10);
    defer both.deinit();
    try std.testing.expectEqual(@as(usize, 1), both.items.len);
    try std.testing.expectEqualStrings("musicbrainz+acoustid", both.items[0].provider);
    try std.testing.expectEqualStrings("Bryter Layter", both.items[0].album);
    try std.testing.expectApproxEqAbs(@as(f32, 0.96), both.items[0].acoustid_score.?, 0.0001);
    const fingerprint_only = try runtime.libraryMatchProposals(library, untagged, 10);
    defer fingerprint_only.deinit();
    try std.testing.expectEqual(@as(usize, 1), fingerprint_only.items.len);
    try std.testing.expectEqualStrings("acoustid", fingerprint_only.items[0].provider);
    try std.testing.expectEqualStrings("", fingerprint_only.items[0].title);

    runtime.reapFinishedJobs();
    const rerun = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, rerun));
    const rerun_stats = try runtime.jobMatchStats(rerun);
    try std.testing.expectEqual(@as(u64, 0), rerun_stats.requests + rerun_stats.acoustid_requests);
    try std.testing.expectEqual(@as(u64, 0), rerun_stats.fingerprinted);
    try std.testing.expectEqual(@as(u32, 1), acoustid.lookups.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), musicbrainz.requests.load(.acquire));

    _ = try runtime.libraryAcceptMatch(library, fingerprint_only.items[0].id);
    const details = (try runtime.libraryTrackDetails(library, untagged)).?;
    defer details.deinit();
    try std.testing.expectEqualStrings(pink_moon_mbid, details.musicbrainz_recording_id.?);
}

test "a file that fails to decode is not fingerprinted and its Track is still searched on MusicBrainz, and no fingerprints means no AcoustID" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/audio/tagged-reference.flac", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(bytes);
    const packed_bits = std.mem.readInt(u64, bytes[18..26], .big);
    std.mem.writeInt(u64, bytes[18..26], packed_bits + 1_000_000, .big);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "damaged.flac", .data = bytes });
    try writeToneWave(temporary.dir, "whole.wav", 440);
    var musicbrainz: FakeMusicBrainz = .{ .answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_answer }} };
    var acoustid: FakeAcoustId = .{};
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = musicbrainz.hooks();
    runtime.matching_hooks.acoustid_transport = acoustid.transport();
    try runtime.setAcoustIdClientKey("test-client");
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-damaged?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(library);
    const damaged = try addAudioTrack(library_database, &temporary, "damaged.flac", "Northern Sky", "Nick Drake");
    _ = try addAudioTrack(library_database, &temporary, "whole.wav", "Pink Moon", "Nick Drake");

    const without = try runtime.startLibraryMatching(library, .{ .fingerprints = false, .track_id = damaged + 1 });
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, without));
    try std.testing.expectEqual(AcoustIdUse.off, (try runtime.jobMatchStats(without)).acoustid);
    try std.testing.expectEqual(@as(u32, 0), acoustid.lookups.load(.acquire));

    runtime.reapFinishedJobs();
    const job_handle = try runtime.startLibraryMatching(library, .{ .track_id = damaged });
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, job_handle));
    const stats = try runtime.jobMatchStats(job_handle);
    try std.testing.expectEqual(@as(u64, 0), stats.fingerprinted);
    try std.testing.expectEqual(@as(u64, 1), stats.fingerprint_failures);
    try std.testing.expectEqual(@as(u64, 0), stats.acoustid_requests);
    try std.testing.expectEqual(@as(u64, 1), stats.matched);
    try std.testing.expectEqual(@as(i64, 0), try scalarOf(library_database, "SELECT count(*) FROM analysis_results WHERE kind = 3;"));
    try std.testing.expectEqual(@as(i64, 0), try scalarOf(library_database, "SELECT count(*) FROM identification_searches WHERE provider = 'acoustid';"));
}

fn scalarOf(library_database: *database.LibraryDatabase, sql: [:0]const u8) !i64 {
    var statement = try library_database.database.prepare(sql);
    defer statement.deinit();
    if (try statement.step() != .row) return error.NoRow;
    return statement.columnInt64(0);
}

test "a submission sends a chosen recording ID once, fails without marking anything when the user key is missing or refused, and cannot run beside matching" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeToneWave(temporary.dir, "chosen.wav", 440);
    try writeToneWave(temporary.dir, "doubted.wav", 530);
    var musicbrainz: FakeMusicBrainz = .{ .hang_from = 0 };
    var acoustid: FakeAcoustId = .{
        .submit_body = "{\"status\":\"ok\",\"submissions\":[{\"id\":71,\"status\":\"pending\",\"index\":\"0\"},{\"id\":72,\"status\":\"pending\",\"index\":\"1\"}]}",
    };
    var user: AcoustIdUserKey = .{ .key = null };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = musicbrainz.hooks();
    runtime.matching_hooks.acoustid_transport = acoustid.transport();
    try runtime.setAcoustIdClientKey("test-client");
    try runtime.setCredentialStore(user.store());
    const library = try runtime.openLibrary(std.testing.io, "file:orca-acoustid-submit?mode=memory&cache=shared");
    const library_database = try runtime.libraryDatabase(library);
    const chosen = try addAudioTrack(library_database, &temporary, "chosen.wav", "Northern Sky", "Nick Drake");
    const doubted = try addAudioTrack(library_database, &temporary, "doubted.wav", "Pink Moon", "Nick Drake");
    try proposeMatch(library_database, chosen, northern_sky_mbid, 0.95, "{\"title\":\"Northern Sky\",\"duration_ms\":15000}");
    try proposeMatch(library_database, doubted, pink_moon_mbid, 0.95, "{\"title\":\"Pink Moon\",\"duration_ms\":300000}");
    for ([_]i64{ chosen, doubted }) |track_id| {
        const page = try runtime.libraryMatchProposals(library, track_id, 1);
        defer page.deinit();
        _ = try runtime.libraryAcceptMatch(library, page.items[0].id);
    }
    try std.testing.expectEqual(@as(u64, 2), try runtime.libraryAcoustIdSubmittableCount(library));

    const matching = try runtime.startLibraryMatching(library, .{ .fingerprints = false });
    try std.testing.expectError(error.AcoustIdBusy, runtime.startAcoustIdSubmission(library));
    try runtime.cancelJob(matching);
    _ = try awaitJob(&runtime, matching);

    const without_key = try runtime.startAcoustIdSubmission(library);
    try std.testing.expectEqual(job.State.failed, try awaitJob(&runtime, without_key));
    try std.testing.expectEqual(SubmissionOutcome.needs_user_key, (try runtime.jobSubmissionStats(without_key)).outcome);
    try std.testing.expectEqual(@as(u32, 0), acoustid.submissions.load(.acquire));

    user.key = "user key";
    acoustid.submit_status = 400;
    const refused_body = "{\"status\":\"error\",\"error\":{\"code\":6,\"message\":\"invalid user API key\"}}";
    const accepted_body = acoustid.submit_body;
    acoustid.submit_body = refused_body;
    const refused = try runtime.startAcoustIdSubmission(library);
    try std.testing.expectEqual(job.State.failed, try awaitJob(&runtime, refused));
    try std.testing.expectEqual(SubmissionOutcome.invalid_user_key, (try runtime.jobSubmissionStats(refused)).outcome);
    try std.testing.expectEqual(@as(u64, 2), try runtime.libraryAcoustIdSubmittableCount(library));

    acoustid.submit_status = 200;
    acoustid.submit_body = accepted_body;
    const sent = try runtime.startAcoustIdSubmission(library);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, sent));
    const stats = try runtime.jobSubmissionStats(sent);
    try std.testing.expectEqual(SubmissionOutcome.completed, stats.outcome);
    try std.testing.expectEqual(@as(u64, 2), stats.submitted);
    try std.testing.expectEqual(@as(u64, 1), stats.sent_as_metadata);
    try std.testing.expectEqual(@as(u64, 1), stats.requests);
    const form = acoustid.lastForm();
    try std.testing.expect(std.mem.indexOf(u8, form, "&user=user%20key&") != null);
    try std.testing.expect(std.mem.indexOf(u8, form, "&mbid.0=" ++ northern_sky_mbid) != null);
    try std.testing.expect(std.mem.indexOf(u8, form, "&mbid.1=") == null);
    try std.testing.expect(std.mem.indexOf(u8, form, "&track.1=Pink%20Moon&artist.1=Nick%20Drake") != null);
    try std.testing.expectEqual(@as(i64, 72), try scalarOf(library_database, "SELECT submission_id FROM acoustid_submissions WHERE recording_mbid = '" ++ pink_moon_mbid ++ "';"));
    try std.testing.expectEqual(@as(u64, 0), try runtime.libraryAcoustIdSubmittableCount(library));

    const again = try runtime.startAcoustIdSubmission(library);
    try std.testing.expectEqual(job.State.succeeded, try awaitJob(&runtime, again));
    try std.testing.expectEqual(@as(u64, 0), (try runtime.jobSubmissionStats(again)).files_examined);
    try std.testing.expectEqual(@as(u32, 2), acoustid.submissions.load(.acquire));
}
