const std = @import("std");
const codec = @import("../codec/root.zig");
const control = @import("control.zig");
const artist_info = @import("artist_info.zig");
const release_info = @import("release_info.zig");
const cover_art = @import("cover_art.zig");
const database = @import("../database/root.zig");
const job = @import("job.zig");
const lyrics_fetch = @import("lyrics_fetch.zig");
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
const OwnedServer = providers.url.OwnedServer;

pub const AcoustIdUse = library_pass.matching.AcoustIdUse;
pub const BusyService = library_pass.matching.BusyService;
pub const SubmissionOutcome = library_pass.acoustid_submission.Outcome;
pub const CoverArtOutcome = cover_art.Outcome;
pub const Lyrics = metadata.lyrics.Lyrics;

pub const LyricsOptions = struct {
    /// Ask LRCLIB when the Track has no synced lyrics of its own and nothing
    /// is cached for its current values.
    fetch: bool = false,
};

pub const LyricsOutcome = lyrics_fetch.Outcome;

pub const LyricsSetup = struct {
    io: std.Io,
    identity: OwnedIdentity,
    hooks: MatchingHooks,
    server: OwnedServer,
};

pub const LyricsRequest = struct {
    track_id: i64,
    options: LyricsOptions = .{},
    setup: ?LyricsSetup = null,
};

pub const ArtistInfoOutcome = artist_info.Outcome;

pub const ArtistInfoSetup = struct {
    io: std.Io,
    identity: OwnedIdentity,
    hooks: MatchingHooks,
    musicbrainz_server: OwnedServer,
    wikidata_server: OwnedServer,
    commons_server: OwnedServer,
    /// Null asks the language's own Wikipedia.
    wikipedia_server: ?OwnedServer,
    listenbrainz_server: OwnedServer,
    listenbrainz_labs_server: OwnedServer,
    coverartarchive_server: OwnedServer,
};

/// A Wikipedia language code the request owns.
pub const ArtistInfoLanguage = struct {
    bytes: [12]u8 = undefined,
    len: u8 = 0,

    pub fn init(language: []const u8) error{InvalidLanguage}!ArtistInfoLanguage {
        if (!providers.wikidata.isLanguage(language)) return error.InvalidLanguage;
        var result: ArtistInfoLanguage = .{ .len = @intCast(language.len) };
        @memcpy(result.bytes[0..language.len], language);
        return result;
    }

    pub fn view(self: *const ArtistInfoLanguage) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const ArtistInfoRequest = struct {
    artist_id: i64,
    language: ArtistInfoLanguage,
    force: bool = false,
    offline: bool = false,
    include_releases: bool = false,
    setup: ArtistInfoSetup,
};

pub const ReleaseInfoTarget = union(enum) {
    /// One Release's description, and its genres unless turned off.
    release: i64,
    /// Genres only, for at most this many Releases with a MusicBrainz
    /// release ID and a Track with no genre.
    missing_genres: u32,
};

pub const ReleaseInfoRequest = struct {
    target: ReleaseInfoTarget,
    language: ArtistInfoLanguage,
    force: bool = false,
    offline: bool = false,
    setup: ArtistInfoSetup,
};

pub const ScanRequest = struct {
    /// Which registered root to walk. Null walks every enabled root.
    root_id: ?i64 = null,
    batch_size: usize = 256,
    /// Reads every file again, tags and audio properties included, even when
    /// its path and identity are unchanged. Files, Tracks and their ids are
    /// kept; only what each file says is observed afresh.
    reprobe_all: bool = false,
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

pub const ConsistencyRequest = struct {
    /// Releases per bounded commit.
    batch_size: usize = 128,
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

/// The file a failed tag write stopped at, and why.
pub const TagWriteFailure = struct {
    file_id: i64,
    /// The plan's action for the file, in the order the plan lists its files.
    action_index: u32,
    reason: TagWriteFailureReason,
};

pub const TagWriteFailureReason = enum {
    /// Orca may not create or replace files in the file's folder or in the
    /// Library's backup directory.
    permission_denied,
    /// The file, or the Library's backup directory, is on a read-only file
    /// system.
    read_only_file_system,
    /// The disk had no room for the staged copy or the backup.
    no_space,
    /// The file changed after the plan was made, so the plan no longer
    /// describes it.
    changed_since_plan,
    other,
};

fn tagWriteFailureReason(err: anyerror) TagWriteFailureReason {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        error.ReadOnlyFileSystem => .read_only_file_system,
        error.NoSpaceLeft => .no_space,
        error.FileIdentityChanged => .changed_since_plan,
        else => .other,
    };
}

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
    server: OwnedServer,
    client_key: ?OwnedAcoustIdKey,
    credentials: ?CredentialStore,
};

pub const MatchingSetup = struct {
    io: std.Io,
    server: OwnedServer,
    identity: OwnedIdentity,
    hooks: MatchingHooks,
    scope: database.MatchScope,
    mode: library_pass.matching.Mode = .search,
    /// Null when the job looks nothing up on AcoustID.
    acoustid: ?AcoustIdSetup,
    cover_art_server: OwnedServer,
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
    return try allocator.dupe(u8, key.view());
}

pub fn validAcoustIdKey(key: []const u8) bool {
    if (key.len == 0 or key.len > providers.acoustid.max_key_bytes) return false;
    for (key) |byte| if (byte <= 0x20 or byte >= 0x7f) return false;
    return true;
}

pub const OwnedAcoustIdKey = struct {
    bytes: [providers.acoustid.max_key_bytes]u8,
    len: u16,

    pub fn init(key: []const u8) error{InvalidAcoustIdKey}!OwnedAcoustIdKey {
        if (!validAcoustIdKey(key)) return error.InvalidAcoustIdKey;
        var owned: OwnedAcoustIdKey = .{ .bytes = @splat(0), .len = @intCast(key.len) };
        @memcpy(owned.bytes[0..key.len], key);
        return owned;
    }

    pub fn view(self: *const OwnedAcoustIdKey) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A sealed plan and where each of its files lives, owned by the runtime until
/// a worker takes it.
pub const PendingTagWrite = struct {
    arena: std.heap.ArenaAllocator,
    library: LibraryHandle,
    plan: metadata.mutation.Plan,
    /// Index-aligned with `plan.actions`, allocated in `arena`.
    locations: []database.repository.PresentLocation,
    /// Index-aligned with `plan.actions`, allocated in `arena`.
    file_ids: []i64,
    /// Taken by `startTagWrite` and released once the plan has executed.
    journal_lock: ?metadata.JournalLock = null,

    pub fn destroy(self: *PendingTagWrite, io: std.Io) void {
        if (self.journal_lock) |*lock| lock.release(io);
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
        .health_issues = &library_database.health_issues,
    };
    defer scanner.deinit();
    const result = try scanner.observeFiles(&.{location.uri});
    if (result.errors != 0) return error.ReadFailed;
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
    /// What a `cover_art` Job does with the Release.
    cover_art_task: CoverArtTask = .front,
};

/// What a cover art Job does with its Release.
pub const CoverArtTask = union(enum) {
    /// Fetches its front cover when nothing else shows one.
    front,
    /// Lists the archive's images for it as candidates.
    candidates,
    /// Uses a stored candidate as one of its covers.
    use: struct { caa_id: i64, kind: database.ReleaseArtworkKind },
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
    lyrics: LyricsRequest,
    artist_info: ArtistInfoRequest,
    release_info: ReleaseInfoRequest,
    consistency: ConsistencyRequest,

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
            .lyrics => .lyrics,
            .artist_info => .artist_info,
            .release_info => .release_info,
            .consistency => .consistency,
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
            .consistency => |request| request.batch_size,
            .projection, .mutation, .acoustid_submission, .lyrics, .artist_info, .release_info => null,
        };
    }

    /// Whether a host's Job of this kind takes its Library's one slot, and so
    /// waits behind the Job holding it.
    pub fn queues(self: Request) bool {
        return switch (self) {
            .lyrics, .artist_info => false,
            .release_info => |request| request.target == .missing_genres,
            else => true,
        };
    }

    /// Whether the worker reaches a `CancellationToken.checkpoint`, which is
    /// what holds a paused Job.
    pub fn pausable(self: Request) bool {
        return switch (self) {
            .scan, .reconcile, .property_backfill, .analysis, .duplicate_scan, .metadata_lookup, .acoustid_submission, .consistency => true,
            .release_info => |request| request.target == .missing_genres,
            .projection, .mutation, .lyrics, .artist_info => false,
        };
    }
};

/// What a scan job observed, mirroring `scanner.Result` plus what the
/// projection made of it.
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
    current_path: job.BoundedText(512) = .{},
    stage: ScanStage = .discover,
    albums_found: u64 = 0,
};

pub const ScanStage = enum(u8) {
    discover,
    read_tags,
    done,
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
    stage: std.atomic.Value(ScanStage) = .init(.discover),
    found_releases: library_pass.projection.FoundReleases = .{},
    total_files: std.atomic.Value(u64) = .init(0),
    total_known: std.atomic.Value(bool) = .init(false),

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
            .stage = self.stage.load(.acquire),
            .albums_found = self.found_releases.count.load(.acquire),
        };
    }
};

const DuplicateStats = struct {
    files_seen: u64,
    exact: u64,
    identical: u64,
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
            .changed = self.exact + self.identical + self.likely,
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
    identical: std.atomic.Value(u64) = .init(0),
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
            .identical = self.identical.load(.acquire),
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
    /// Tracks a re-identify found again as the recording they are
    /// identified as.
    confirmed: u64 = 0,
    /// A verification's files with an outcome stored, and those outcomes.
    verified: u64 = 0,
    agreed: u64 = 0,
    disagreed: u64 = 0,
    unconfirmed: u64 = 0,
    /// Files a verification passed over for having no quick hash.
    skipped: u64 = 0,
    correction_groups: u64 = 0,
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
    /// A candidates Job's candidates asked for so far, of
    /// `cover_art_candidates`, which stays zero until the archive's indexes
    /// are read.
    cover_art_candidates_examined: u64 = 0,
    cover_art_candidates: u64 = 0,
    /// Candidates kept without a size, their full image not fetched or not
    /// read.
    cover_art_candidates_unmeasured: u64 = 0,
};

const LiveMatchStats = struct {
    tracks_examined: std.atomic.Value(u64) = .init(0),
    matched: std.atomic.Value(u64) = .init(0),
    unmatched: std.atomic.Value(u64) = .init(0),
    insufficient_evidence: std.atomic.Value(u64) = .init(0),
    refused: std.atomic.Value(u64) = .init(0),
    proposals_stored: std.atomic.Value(u64) = .init(0),
    confirmed: std.atomic.Value(u64) = .init(0),
    verified: std.atomic.Value(u64) = .init(0),
    agreed: std.atomic.Value(u64) = .init(0),
    disagreed: std.atomic.Value(u64) = .init(0),
    unconfirmed: std.atomic.Value(u64) = .init(0),
    skipped: std.atomic.Value(u64) = .init(0),
    correction_groups: std.atomic.Value(u64) = .init(0),
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
    cover_art_candidates: cover_art.CandidateProgress = .{},
    /// A running matching pass's counters.
    progress: library_pass.matching.Progress = .{},
    /// The Release a Match Album's files are on once it is done. Written by
    /// the worker just before it finishes; read only after.
    album_release_id: ?i64 = null,

    fn read(self: *const LiveMatchStats) MatchStats {
        const progress = &self.progress;
        return .{
            .tracks_examined = self.tracks_examined.load(.acquire) + progress.tracks_seen.load(.acquire),
            .matched = self.matched.load(.acquire) + progress.matched.load(.acquire),
            .unmatched = self.unmatched.load(.acquire),
            .insufficient_evidence = self.insufficient_evidence.load(.acquire),
            .refused = self.refused.load(.acquire),
            .proposals_stored = self.proposals_stored.load(.acquire),
            .confirmed = self.confirmed.load(.acquire),
            .verified = self.verified.load(.acquire) + progress.verified.load(.acquire),
            .agreed = self.agreed.load(.acquire),
            .disagreed = self.disagreed.load(.acquire),
            .unconfirmed = self.unconfirmed.load(.acquire),
            .skipped = self.skipped.load(.acquire),
            .correction_groups = self.correction_groups.load(.acquire),
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
            .cover_art_candidates_examined = self.cover_art_candidates.examined.load(.acquire),
            .cover_art_candidates = self.cover_art_candidates.total.load(.acquire),
            .cover_art_candidates_unmeasured = self.cover_art_candidates.unmeasured.load(.acquire),
        };
    }
};

const LiveSubmissionStats = struct {
    /// Written by the worker just before it finishes; read only after.
    result: SubmissionStats = .{},
    cancelled: std.atomic.Value(bool) = .init(false),
};

const LiveLyricsStats = struct {
    outcome: std.atomic.Value(LyricsOutcome) = .init(.not_requested),
    /// Written by the worker just before it finishes; read only after, and
    /// owned by whoever takes it.
    result: ?Lyrics = null,
};

const LiveArtistInfoStats = struct {
    outcome: std.atomic.Value(ArtistInfoOutcome) = .init(.not_requested),
    stores: std.atomic.Value(u32) = .init(0),
};

pub const Stats = union(enum) {
    scan: LiveScanStats,
    duplicates: LiveDuplicateStats,
    matching: LiveMatchStats,
    submission: LiveSubmissionStats,
    lyrics: LiveLyricsStats,
    artist_info: LiveArtistInfoStats,

    pub fn init(request: Request) Stats {
        return switch (request) {
            .scan, .reconcile, .projection, .property_backfill, .analysis, .mutation, .consistency => .{ .scan = .{} },
            .duplicate_scan => .{ .duplicates = .{} },
            .metadata_lookup => .{ .matching = .{} },
            .acoustid_submission => .{ .submission = .{} },
            .lyrics => .{ .lyrics = .{} },
            .artist_info, .release_info => .{ .artist_info = .{} },
        };
    }
};

/// The gateways and clients an artist or release info job asks through:
/// one gateway per service, each holding its service's lease while it asks.
const InfoServices = struct {
    standard: network.StandardTransport,
    system_clock: network.SystemClock,
    random_source: std.Random.IoSource,
    wall_clock: network.client.Clock,
    gateways: [names.len]network.Gateway,
    musicbrainz: providers.musicbrainz.MusicBrainz,
    clients: [4]providers.cached_get.CachedGet,
    coverartarchive: providers.coverartarchive.CoverArtArchive,
    setup: *const ArtistInfoSetup,

    const names = [_][]const u8{
        providers.musicbrainz.service,
        providers.wikidata.service,
        providers.wikimedia_commons.service,
        providers.wikipedia.service,
        providers.listenbrainz_labs.service,
        providers.listenbrainz.service,
        providers.coverartarchive.service,
    };

    const intervals_ms = [names.len]u64{
        providers.musicbrainz.minimum_interval_ms,
        providers.wikidata.minimum_interval_ms,
        providers.wikimedia_commons.minimum_interval_ms,
        providers.wikipedia.minimum_interval_ms,
        providers.listenbrainz_labs.minimum_interval_ms,
        providers.listenbrainz.minimum_interval_ms,
        providers.coverartarchive.minimum_interval_ms,
    };

    fn init(self: *InfoServices, worker: *JobWorker, setup: *const ArtistInfoSetup, offline: bool, bounded: bool) void {
        self.setup = setup;
        self.standard = .init(worker.allocator, setup.io);
        self.system_clock = .{ .io = setup.io };
        self.random_source = .{ .io = setup.io };
        self.wall_clock = setup.hooks.wall_clock orelse self.system_clock.wallClock();
        const shared_state = providers.shared_state.store(&worker.database.provider_state);
        for (&self.gateways, names, intervals_ms) |*gateway, service, interval_ms| gateway.* = .{
            .transport = setup.hooks.transport orelse self.standard.transport(),
            .clock = setup.hooks.clock orelse self.system_clock.clock(),
            .wall_clock = self.wall_clock,
            .random = setup.hooks.random orelse self.random_source.interface(),
            .config = .{ .identity = setup.identity.view(), .offline = offline, .minimum_interval_ms = interval_ms },
            .cancel = &worker.registration.cancel,
            .sharing = .{ .store = shared_state, .service = service },
        };
        if (bounded) {
            const deadline = self.gateways[0].clock.nowMs() +| artist_info.fetch_deadline_ms;
            for (&self.gateways) |*gateway| gateway.deadline_ms = deadline;
        }
        self.gateways[2].config.max_response_bytes = providers.wikimedia_commons.max_image_bytes;
        if (setup.hooks.cover_art_transport) |transport| self.gateways[6].transport = transport;
        self.gateways[6].config.max_response_bytes = providers.coverartarchive.max_image_bytes;
        self.coverartarchive = .{ .gateway = &self.gateways[6], .server = setup.coverartarchive_server.view() };
        self.musicbrainz = .{
            .gateway = &self.gateways[0],
            .cache = &worker.database.provider_cache,
            .wall_clock = self.wall_clock,
            .server = setup.musicbrainz_server.view(),
        };
        for (&self.clients, self.gateways[1..5], names[1..5]) |*client, *gateway, service| client.* = .{
            .gateway = gateway,
            .cache = &worker.database.provider_cache,
            .wall_clock = self.wall_clock,
            .service = service,
        };
        self.clients[3].cache_ttl_seconds = providers.listenbrainz_labs.cache_ttl_seconds;
    }

    fn deinit(self: *InfoServices) void {
        for (&self.gateways) |*gateway| gateway.releaseLease();
        self.standard.deinit();
    }

    fn view(self: *InfoServices) artist_info.Services {
        return .{
            .musicbrainz = &self.musicbrainz,
            .wikidata = &self.clients[0],
            .wikidata_server = self.setup.wikidata_server.view(),
            .commons = &self.clients[1],
            .commons_server = self.setup.commons_server.view(),
            .wikipedia = &self.clients[2],
            .wikipedia_server = if (self.setup.wikipedia_server) |*server| server.view() else null,
            .listenbrainz = &self.gateways[5],
            .listenbrainz_server = self.setup.listenbrainz_server.view(),
            .labs = &self.clients[3],
            .labs_server = self.setup.listenbrainz_labs_server.view(),
            .coverartarchive = &self.coverartarchive,
        };
    }
};

pub const Origin = enum { host, watcher, maintenance };

pub const PublishedProgress = struct {
    completed_units: u64,
    total_units: ?u64,
    state: job.State,
};

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
    current_item: library_pass.CurrentItem = .{},
    stats: Stats,
    failed: std.atomic.Value(bool) = .init(false),
    volume_changed: std.atomic.Value(bool) = .init(false),
    /// Control lane only: the thread has been joined and the record finalized.
    retired: bool = false,
    /// Control lane only: what the last `job_progress` telemetry carried.
    published: ?PublishedProgress = null,
    /// Written by the worker just before it finishes; read only after.
    tag_write_failure: ?TagWriteFailure = null,
    /// Released before `registration.finish`: a walk started once this Job
    /// is final must find the lock free, even in this process.
    walk_lock: ?library_pass.WalkLock = null,
    /// Raised after `finish`, which is safe only because the control lane
    /// joins the thread, not merely waits for `finish`, before it frees this
    /// struct or the runtime.
    host_signal: *control.HostSignal,

    pub fn run(self: *JobWorker) void {
        defer {
            switch (self.stats) {
                .scan => |*stats| {
                    stats.found_releases.freeIds(self.allocator);
                    stats.stage.store(.done, .release);
                },
                else => {},
            }
            if (self.walk_lock) |*lock| {
                lock.release(self.threaded.io());
                self.walk_lock = null;
            }
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
            .lyrics => |request| self.runLyrics(request),
            .artist_info => |*request| self.runArtistInfo(request),
            .release_info => |*request| self.runReleaseInfo(request),
            .consistency => |request| self.runConsistency(request),
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

    pub fn wakeFromPause(context: *anyopaque) callconv(.c) void {
        const token: *library_pass.CancellationToken = @ptrCast(@alignCast(context));
        token.cancel();
    }

    fn cancelled(self: *const JobWorker) bool {
        return self.token.checkpoint() or self.registration.cancellationRequested();
    }

    fn runLyrics(self: *JobWorker, request: LyricsRequest) void {
        const stats = &self.stats.lyrics;
        if (self.cancelled()) return stats.outcome.store(.cancelled, .release);
        var fetch: lyrics_fetch.Fetch = .{
            .allocator = self.allocator,
            .io = self.threaded.io(),
            .library = self.database,
        };
        const setup = request.setup orelse return self.finishLyrics(&fetch, request.track_id);
        var standard: network.StandardTransport = .init(self.allocator, setup.io);
        defer standard.deinit();
        var system_clock: network.SystemClock = .{ .io = setup.io };
        const random_source: std.Random.IoSource = .{ .io = setup.io };
        const wall_clock = setup.hooks.wall_clock orelse system_clock.wallClock();
        var gateway: network.Gateway = .{
            .transport = setup.hooks.transport orelse standard.transport(),
            .clock = setup.hooks.clock orelse system_clock.clock(),
            .wall_clock = wall_clock,
            .random = setup.hooks.random orelse random_source.interface(),
            .config = .{
                .identity = setup.identity.view(),
                .minimum_interval_ms = providers.lrclib.minimum_interval_ms,
                .max_response_bytes = providers.lrclib.max_response_bytes,
            },
            .cancel = &self.registration.cancel,
            .sharing = .{
                .store = providers.shared_state.store(&self.database.provider_state),
                .service = providers.lrclib.service,
            },
        };
        gateway.deadline_ms = gateway.clock.nowMs() +| lyrics_fetch.fetch_deadline_ms;
        defer gateway.releaseLease();
        var archive: providers.lrclib.Lrclib = .{ .gateway = &gateway, .server = setup.server.view() };
        fetch.lrclib = &archive;
        fetch.wall_clock = wall_clock;
        self.finishLyrics(&fetch, request.track_id);
    }

    fn runArtistInfo(self: *JobWorker, request: *const ArtistInfoRequest) void {
        const stats = &self.stats.artist_info;
        if (self.cancelled()) return stats.outcome.store(.cancelled, .release);
        var services: InfoServices = undefined;
        services.init(self, &request.setup, request.offline, !request.include_releases);
        defer services.deinit();
        var fetch: artist_info.Fetch = .{
            .allocator = self.allocator,
            .io = self.threaded.io(),
            .library = self.database,
            .services = services.view(),
            .wall_clock = services.wall_clock,
            .language = request.language.view(),
            .force = request.force,
            .offline = request.offline,
            .include_releases = request.include_releases,
            .stores = &stats.stores,
        };
        const outcome = fetch.run(request.artist_id) catch {
            self.failed.store(true, .release);
            return;
        };
        stats.outcome.store(if (self.cancelled()) .cancelled else outcome, .release);
    }

    fn runReleaseInfo(self: *JobWorker, request: *const ReleaseInfoRequest) void {
        const stats = &self.stats.artist_info;
        if (self.cancelled()) return stats.outcome.store(.cancelled, .release);
        var services: InfoServices = undefined;
        services.init(self, &request.setup, request.offline, request.target == .release);
        defer services.deinit();
        var fetch: release_info.Fetch = .{
            .allocator = self.allocator,
            .library = self.database,
            .services = services.view(),
            .wall_clock = services.wall_clock,
            .language = request.language.view(),
            .force = request.force,
        };
        const outcome = self.fetchReleaseInfo(&fetch, request.target) catch {
            self.failed.store(true, .release);
            return;
        };
        stats.outcome.store(if (self.cancelled()) .cancelled else outcome, .release);
    }

    fn fetchReleaseInfo(self: *JobWorker, fetch: *release_info.Fetch, target: ReleaseInfoTarget) !ArtistInfoOutcome {
        const limit = switch (target) {
            .release => |release_id| return fetch.run(release_id),
            .missing_genres => |limit| limit,
        };
        fetch.genres_only = true;
        const releases = try self.database.genres.releasesWithoutGenres(self.allocator, limit);
        defer self.allocator.free(releases);
        var failure: ?ArtistInfoOutcome = null;
        for (releases) |release_id| {
            if (self.cancelled()) return .cancelled;
            const outcome = try fetch.run(release_id);
            switch (outcome) {
                .fetched, .cached, .no_musicbrainz_id, .not_found => {},
                .cancelled => return .cancelled,
                else => failure = failure orelse outcome,
            }
            _ = self.progress.fetchAdd(1, .acq_rel);
        }
        return failure orelse .fetched;
    }

    fn finishLyrics(self: *JobWorker, fetch: *lyrics_fetch.Fetch, track_id: i64) void {
        const stats = &self.stats.lyrics;
        const result = fetch.run(track_id) catch {
            self.failed.store(true, .release);
            return;
        };
        if (result.outcome == .cancelled or self.cancelled()) {
            if (result.lyrics) |lyrics| lyrics.deinit();
            return stats.outcome.store(.cancelled, .release);
        }
        stats.result = result.lyrics;
        stats.outcome.store(result.outcome, .release);
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
    ///
    /// The covers observed before Orca measured covers are measured after,
    /// in the same Job, and their counts join the files'.
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
            .current_item = &self.current_item,
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
        self.noteProjection(result.projection);
        if (result.cancelled) {
            stats.cancelled.store(true, .release);
            return;
        }
        var covers: library_pass.ArtworkBackfill = .{
            .allocator = self.allocator,
            .io = self.threaded.io(),
            .locations = &self.database.locations,
            .write_lane = self.database.write_lane,
            .database_handle = self.database.database,
            .cancellation = &self.token,
            .current_item = &self.current_item,
            .progress = &self.progress,
            .batch_size = request.batch_size,
        };
        const measured = covers.run() catch {
            self.failed.store(true, .release);
            return;
        };
        self.progress.store(0, .release);
        _ = stats.files_seen.fetchAdd(measured.covers_seen, .acq_rel);
        _ = stats.changed.fetchAdd(measured.measured, .acq_rel);
        _ = stats.unsupported.fetchAdd(measured.skipped, .acq_rel);
        _ = stats.batches_committed.fetchAdd(measured.batches_committed, .acq_rel);
        if (measured.cancelled) stats.cancelled.store(true, .release);
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
            .current_item = &self.current_item,
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
        _ = stats.identical.fetchAdd(result.identical, .acq_rel);
        _ = stats.likely.fetchAdd(result.likely, .acq_rel);
        _ = stats.unique.fetchAdd(result.unique, .acq_rel);
        _ = stats.uncomparable.fetchAdd(result.uncomparable, .acq_rel);
        _ = stats.errors.fetchAdd(result.errors, .acq_rel);
        _ = stats.batches_committed.fetchAdd(result.batches_committed, .acq_rel);
        _ = stats.buckets_truncated.fetchAdd(result.buckets_truncated, .acq_rel);
        _ = stats.comparisons.fetchAdd(result.comparisons, .acq_rel);
        if (result.cancelled) stats.cancelled.store(true, .release);
    }

    fn runConsistency(self: *JobWorker, request: ConsistencyRequest) void {
        const stats = &self.stats.scan;
        var pass: library_pass.ConsistencyPass = .{
            .allocator = self.allocator,
            .library = self.database,
            .cancellation = &self.token,
            .progress = &self.progress,
            .batch_size = request.batch_size,
        };
        const result = pass.run() catch {
            self.failed.store(true, .release);
            return;
        };
        self.progress.store(0, .release);
        _ = stats.files_seen.fetchAdd(result.releases_seen, .acq_rel);
        _ = stats.changed.fetchAdd(result.issues, .acq_rel);
        _ = stats.batches_committed.fetchAdd(result.batches_committed, .acq_rel);
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
        const album_id: ?i64 = switch (setup.scope) {
            .release => |id| if (request.lookups and setup.mode != .verify) id else null,
            .library, .track => null,
        };
        var album_files_buffer: [database.repository.max_page]i64 = undefined;
        const album_files: []const i64 = if (album_id) |id|
            self.database.releases.playFileIds(&album_files_buffer, id) catch &.{}
        else
            &.{};
        defer if (album_id != null) self.recordAlbumRelease(album_files);
        if (request.lookups and !self.runLookups(request, services)) return;
        if (setup.mode == .verify) return;
        const release_id = switch (setup.scope) {
            .release => |id| id,
            .library, .track => return,
        };
        var written: std.ArrayList(i64) = .empty;
        defer written.deinit(self.allocator);
        if (request.lookups and !self.applyMatches(request, release_id, &written)) return self.reproject(written.items);
        if (request.cover_art) {
            if (self.cancelled()) {
                stats.cancelled.store(true, .release);
            } else {
                self.runCoverArt(setup, services, release_id, request.cover_art_task);
            }
        }
        self.reproject(written.items);
    }

    fn recordAlbumRelease(self: *JobWorker, album_files: []const i64) void {
        self.stats.matching.album_release_id = self.database.releases.holdingMost(self.allocator, album_files) catch null;
    }

    /// Match Album after its lookups: accepts the confident matches when
    /// asked, then applies the Release's consensus. False when the job has
    /// to stop here.
    fn applyMatches(self: *JobWorker, request: MatchingRequest, release_id: i64, written: *std.ArrayList(i64)) bool {
        const stats = &self.stats.matching;
        const proposals = &self.database.identification_proposals;
        if (request.accept_minimum_confidence) |minimum| {
            if (self.cancelled()) {
                stats.cancelled.store(true, .release);
                return false;
            }
            const acceptance = proposals.acceptConfidentInRelease(self.allocator, minimum, release_id) catch {
                self.failed.store(true, .release);
                return false;
            };
            defer acceptance.deinit();
            stats.accepted.store(acceptance.accepted, .release);
            written.appendSlice(self.allocator, acceptance.file_ids) catch {
                self.failed.store(true, .release);
                return false;
            };
        }
        _ = proposals.applyReleaseConsensus(self.allocator, release_id, written) catch {
            self.failed.store(true, .release);
            return false;
        };
        return true;
    }

    /// Reprojects the files a Match Album gave values, after its cover fetch,
    /// so the fetch stored the cover under the Release id it started with.
    fn reproject(self: *JobWorker, file_ids: []const i64) void {
        if (file_ids.len == 0) return;
        var pass: library_pass.Projection = .{
            .allocator = self.allocator,
            .library = self.database,
        };
        _ = pass.run(.{ .files = file_ids }) catch self.failed.store(true, .release);
    }

    const Services = struct {
        transport: network.client.Transport,
        clock: network.client.Clock,
        wall_clock: network.client.Clock,
        random: std.Random,
        shared_state: network.client.StateStore,
    };

    fn runCoverArt(self: *JobWorker, setup: MatchingSetup, services: Services, release_id: i64, task: CoverArtTask) void {
        const stats = &self.stats.matching;
        var gateway: network.Gateway = .{
            .transport = setup.hooks.cover_art_transport orelse services.transport,
            .clock = services.clock,
            .wall_clock = services.wall_clock,
            .random = services.random,
            .config = .{
                .identity = setup.identity.view(),
                .minimum_interval_ms = providers.coverartarchive.minimum_interval_ms,
                .max_response_bytes = switch (task) {
                    .front => providers.coverartarchive.max_image_bytes,
                    .candidates, .use => metadata.model.max_image_bytes,
                },
            },
            .cancel = &self.registration.cancel,
            .sharing = .{ .store = services.shared_state, .service = providers.coverartarchive.service },
        };
        defer gateway.releaseLease();
        var archive: providers.coverartarchive.CoverArtArchive = .{
            .gateway = &gateway,
            .server = setup.cover_art_server.view(),
        };
        const ran: anyerror!CoverArtOutcome = switch (task) {
            .front => front: {
                var fetch: cover_art.Fetch = .{
                    .allocator = self.allocator,
                    .io = self.threaded.io(),
                    .library = self.database,
                    .archive = &archive,
                    .wall_clock = services.wall_clock,
                };
                break :front fetch.run(release_id);
            },
            .candidates => candidates: {
                var fetch: cover_art.Candidates = .{
                    .allocator = self.allocator,
                    .library = self.database,
                    .archive = &archive,
                    .wall_clock = services.wall_clock,
                    .progress = &stats.cover_art_candidates,
                };
                break :candidates fetch.run(release_id);
            },
            .use => |use| use: {
                var fetch: cover_art.Use = .{
                    .allocator = self.allocator,
                    .library = self.database,
                    .archive = &archive,
                    .wall_clock = services.wall_clock,
                };
                break :use fetch.run(release_id, use.caa_id, use.kind);
            },
        };
        const outcome = ran catch {
            self.failed.store(true, .release);
            return;
        };
        stats.cover_art.store(outcome, .release);
        switch (outcome) {
            .cancelled => stats.cancelled.store(true, .release),
            .refused, .unavailable, .busy => self.failed.store(true, .release),
            .not_found => if (task == .use) self.failed.store(true, .release),
            .not_requested, .embedded, .fetched, .cached, .cached_miss, .no_release_id, .folder, .chosen, .partial => {},
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
            .config = .{ .identity = setup.identity.view(), .minimum_interval_ms = providers.musicbrainz.minimum_interval_ms },
            .cancel = &self.registration.cancel,
            .sharing = .{ .store = shared_state, .service = providers.musicbrainz.service },
        };
        defer gateway.releaseLease();
        var musicbrainz: providers.musicbrainz.MusicBrainz = .{
            .gateway = &gateway,
            .cache = &self.database.provider_cache,
            .wall_clock = wall_clock,
            .server = setup.server.view(),
        };
        var acoustid_gateway: network.Gateway = .{
            .transport = setup.hooks.acoustid_transport orelse services.transport,
            .clock = clock,
            .wall_clock = wall_clock,
            .random = random,
            .config = .{ .identity = setup.identity.view(), .minimum_interval_ms = providers.acoustid.minimum_interval_ms },
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
            .server = setup.acoustid.?.server.view(),
            .client_key = key,
        } else null;
        stats.acoustid.store(if (acoustid != null) .searched else if (setup.acoustid == null) .off else .no_client_key, .release);
        const codecs = codec.CodecRegistry.builtins();
        var pass: library_pass.LibraryMatching = .{
            .allocator = self.allocator,
            .proposals = &self.database.identification_proposals,
            .verifications = &self.database.recording_verifications,
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
            .mode = setup.mode,
        };
        const result = pass.run() catch {
            self.failed.store(true, .release);
            return false;
        };
        stats.progress.tracks_seen.store(0, .release);
        stats.progress.matched.store(0, .release);
        stats.progress.fingerprinted.store(0, .release);
        stats.progress.verified.store(0, .release);
        _ = stats.tracks_examined.fetchAdd(result.tracks_seen, .acq_rel);
        _ = stats.matched.fetchAdd(result.matched, .acq_rel);
        _ = stats.unmatched.fetchAdd(result.unmatched, .acq_rel);
        _ = stats.insufficient_evidence.fetchAdd(result.insufficient, .acq_rel);
        _ = stats.refused.fetchAdd(result.refused, .acq_rel);
        _ = stats.proposals_stored.fetchAdd(result.proposals_stored, .acq_rel);
        _ = stats.confirmed.fetchAdd(result.confirmed, .acq_rel);
        _ = stats.verified.fetchAdd(result.verified, .acq_rel);
        _ = stats.agreed.fetchAdd(result.agreed, .acq_rel);
        _ = stats.disagreed.fetchAdd(result.disagreed, .acq_rel);
        _ = stats.unconfirmed.fetchAdd(result.unconfirmed, .acq_rel);
        _ = stats.skipped.fetchAdd(result.skipped, .acq_rel);
        _ = stats.correction_groups.fetchAdd(result.correction_groups, .acq_rel);
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
        const without_acoustid = setup.mode == .verify and result.acoustid != .searched;
        if (result.unavailable or result.busy != .none or without_acoustid) self.failed.store(true, .release);
        return !result.cancelled and !result.unavailable and result.busy == .none and !without_acoustid;
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
            .config = .{ .identity = setup.identity.view(), .minimum_interval_ms = providers.acoustid.minimum_interval_ms },
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
            .server = setup.acoustid.server.view(),
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
        self.countScanFiles(io, roots.items, request.root_id);
        for (roots.items) |root| {
            if (self.cancelled()) {
                self.stats.scan.cancelled.store(true, .release);
                break;
            }
            if (!root.enabled) continue;
            if (request.root_id) |wanted| {
                if (root.id != wanted) continue;
            }
            self.scanRoot(io, root, request.batch_size, request.reprobe_all) catch self.failed.store(true, .release);
        }
        self.settleTotal();
    }

    fn countScanFiles(self: *JobWorker, io: std.Io, roots: []const database.repository.LibraryRoot, root_id: ?i64) void {
        var total: u64 = 0;
        for (roots) |root| {
            if (!root.enabled) continue;
            if (root_id) |wanted| {
                if (root.id != wanted) continue;
            }
            total += self.countRootFiles(io, root, null) orelse return;
        }
        self.publishTotal(total);
    }

    fn countRootFiles(self: *JobWorker, io: std.Io, root: database.repository.LibraryRoot, subtree: ?[]const u8) ?u64 {
        return library_pass.scanner.countFiles(
            io,
            self.allocator,
            root.path,
            subtree,
            library_pass.watch.Ignore.forLibrary(self.database),
            &self.token,
        ) catch 0;
    }

    fn publishTotal(self: *JobWorker, total: u64) void {
        self.stats.scan.total_files.store(total, .release);
        self.stats.scan.total_known.store(true, .release);
    }

    fn settleTotal(self: *JobWorker) void {
        const stats = &self.stats.scan;
        if (!stats.total_known.load(.acquire)) return;
        if (stats.cancelled.load(.acquire) or self.failed.load(.acquire)) return;
        stats.total_files.store(stats.files_seen.load(.acquire), .release);
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
            .whole_root => {
                if (self.countRootFiles(io, root, null)) |total| self.publishTotal(total);
                self.scanRoot(io, root, request.batch_size, false) catch self.failed.store(true, .release);
            },
            .subtrees => |subtrees| {
                self.countSubtreeFiles(io, root, subtrees);
                self.reconcileSubtrees(io, root, subtrees, request.batch_size) catch self.failed.store(true, .release);
            },
        }
        self.settleTotal();
    }

    fn countSubtreeFiles(self: *JobWorker, io: std.Io, root: database.repository.LibraryRoot, subtrees: []const []const u8) void {
        var total: u64 = 0;
        for (subtrees) |subtree| total += self.countRootFiles(io, root, subtree) orelse return;
        self.publishTotal(total);
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
            .current_item = &self.current_item,
            .batch_size = batch_size,
            .progress = &self.progress,
            .projection = pass,
            .ignore = library_pass.watch.Ignore.forLibrary(self.database),
            .health_issues = &self.database.health_issues,
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
        reprobe: bool,
    ) !void {
        self.progress.store(0, .release);
        try self.requireRecordedVolume(io, root);
        const scan_run = try self.beginScanRun(root.id);
        var run_finished = false;
        errdefer if (!run_finished) self.failScanRun(scan_run.id, .{});
        var pass: library_pass.Projection = .{
            .allocator = self.allocator,
            .library = self.database,
            .found_releases = &self.stats.scan.found_releases,
        };
        var scanner = self.rootScanner(io, root, scan_run.generation, batch_size, &pass);
        scanner.reprobe = reprobe;
        defer scanner.deinit();
        self.stats.scan.stage.store(.read_tags, .release);
        const result = try scanner.scan(root.path);
        try self.database.scan_runs.finish(
            scan_run.id,
            if (result.cancelled) .cancelled else .completed,
            scanCounters(result),
        );
        run_finished = true;
        // Never on a cancelled run: a partial walk must not mark the files it
        // did not reach as missing.
        const marked_missing = if (result.cancelled) 0 else try self.database.files.markMissingBelowGeneration(
            root.id,
            scan_run.generation,
        );
        self.noteScan(result);
        _ = self.stats.scan.marked_missing.fetchAdd(marked_missing, .acq_rel);
    }

    fn beginScanRun(self: *JobWorker, root_id: i64) !database.repository.ScanRun {
        // Only under the walk lock: without it a running run may be another runtime's live walk.
        if (self.walk_lock != null) _ = try self.database.scan_runs.failStaleRuns(root_id);
        return self.database.scan_runs.begin(root_id);
    }

    fn failScanRun(self: *JobWorker, run_id: i64, counters: database.repository.ScanCounters) void {
        self.database.scan_runs.finish(run_id, .failed, counters) catch {};
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
        var totals: library_pass.scanner.Result = .{};
        var walk_failed = false;
        const scan_run = try self.beginScanRun(root.id);
        var run_finished = false;
        errdefer if (!run_finished) self.failScanRun(scan_run.id, scanCounters(totals));
        var pass: library_pass.Projection = .{
            .allocator = self.allocator,
            .library = self.database,
            .found_releases = &stats.found_releases,
        };
        var scanner = self.rootScanner(io, root, scan_run.generation, batch_size, &pass);
        defer scanner.deinit();
        stats.stage.store(.read_tags, .release);
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
        run_finished = true;
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
        const written = written: {
            defer {
                pending.journal_lock.?.release(io);
                pending.journal_lock = null;
            }
            const lock = &pending.journal_lock.?;
            self.database.recoverPendingMutations(io, lock) catch break :written false;
            var executor: metadata.executor.Executor = .{
                .allocator = self.allocator,
                .io = io,
                .journal = &self.database.mutation_journal,
                .journal_lock = lock,
                .backup_directory = self.database.backup_directory,
            };
            executor.executePlan(&pending.plan, pending.plan.id) catch |err| {
                if (executor.failed_action_index) |index| self.tag_write_failure = .{
                    .file_id = pending.file_ids[index],
                    .action_index = index,
                    .reason = tagWriteFailureReason(err),
                };
                break :written false;
            };
            break :written true;
        };
        if (written) {
            _ = stats.changed.fetchAdd(pending.plan.actions.len, .acq_rel);
        } else {
            _ = stats.errors.fetchAdd(1, .acq_rel);
            self.failed.store(true, .release);
        }
        for (pending.locations) |location| {
            reobserve(self.allocator, io, self.database, location) catch {
                _ = stats.errors.fetchAdd(1, .acq_rel);
            };
        }
        if (written) self.markWritten(pending) catch {
            _ = stats.errors.fetchAdd(1, .acq_rel);
        };
    }

    /// Runs after `reobserve`: a written copy of a shared file has by then
    /// become a file of its own, and the mark belongs on that file.
    fn markWritten(self: *JobWorker, pending: *const PendingTagWrite) !void {
        for (pending.plan.actions, pending.locations) |action, location| switch (action) {
            .write_tags => |write| {
                const file_id = try self.database.files.resolveByUri(location.volume_id, location.uri) orelse continue;
                for (write.changes) |change| {
                    const value = change.after orelse continue;
                    try self.database.orca_metadata.markWritten(file_id, change.field, value);
                }
            },
            .move => {},
        };
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
            .matching => matching: {
                const stats = self.matchStats();
                break :matching stats.tracks_examined + stats.cover_art_candidates_examined;
            },
            .submission => self.submissionStats().files_examined,
            .scan => |*stats| stats.files_seen.load(.acquire) + self.progress.load(.acquire),
            .duplicates => |*stats| stats.files_seen.load(.acquire) + self.progress.load(.acquire),
            .lyrics => 0,
            .artist_info => switch (self.request) {
                .release_info => self.progress.load(.acquire),
                else => 0,
            },
        };
    }

    pub fn totalUnits(self: *const JobWorker, completed_units: u64) ?u64 {
        return switch (self.stats) {
            .scan => |*stats| if (stats.total_known.load(.acquire))
                @max(stats.total_files.load(.acquire), completed_units)
            else
                null,
            .matching => |*stats| switch (stats.cover_art_candidates.total.load(.acquire)) {
                0 => null,
                else => |total| @max(total, completed_units),
            },
            .duplicates, .submission, .lyrics, .artist_info => null,
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
            .matching, .lyrics, .artist_info => .{},
            .submission => |*stats| .{ .cancelled = stats.cancelled.load(.acquire) },
        };
    }

    pub fn matchStats(self: *const JobWorker) MatchStats {
        return switch (self.stats) {
            .matching => |*stats| stats.read(),
            .scan, .duplicates, .submission, .lyrics, .artist_info => .{},
        };
    }

    /// Null while the job runs and for a job that is not a Match Album.
    pub fn matchRelease(self: *const JobWorker) ?i64 {
        if (!self.retired and !self.registration.isFinished()) return null;
        return switch (self.stats) {
            .matching => |*stats| stats.album_release_id,
            .scan, .duplicates, .submission, .lyrics, .artist_info => null,
        };
    }

    pub fn submissionStats(self: *const JobWorker) SubmissionStats {
        if (self.retired or self.registration.isFinished()) return switch (self.stats) {
            .submission => |*stats| stats.result,
            .scan, .duplicates, .matching, .lyrics, .artist_info => .{},
        };
        return .{ .files_examined = self.progress.load(.acquire) };
    }

    /// `not_requested` while the job runs and for a job that is not a lyrics
    /// job.
    pub fn lyricsOutcome(self: *const JobWorker) LyricsOutcome {
        if (!self.retired and !self.registration.isFinished()) return .not_requested;
        return switch (self.stats) {
            .lyrics => |*stats| stats.outcome.load(.acquire),
            .scan, .duplicates, .matching, .submission, .artist_info => .not_requested,
        };
    }

    /// `not_requested` while the job runs and for a job that is not an
    /// artist info job.
    pub fn artistInfoOutcome(self: *const JobWorker) ArtistInfoOutcome {
        if (!self.retired and !self.registration.isFinished()) return .not_requested;
        return switch (self.stats) {
            .artist_info => |*stats| stats.outcome.load(.acquire),
            .scan, .duplicates, .matching, .submission, .lyrics => .not_requested,
        };
    }

    /// How many times an artist info job has stored part of what it found,
    /// as it goes; 0 for a job of another kind.
    pub fn artistInfoStores(self: *const JobWorker) u32 {
        return switch (self.stats) {
            .artist_info => |*stats| stats.stores.load(.acquire),
            .scan, .duplicates, .matching, .submission, .lyrics => 0,
        };
    }

    /// The lyrics a finished lyrics job found, once: ownership moves to the
    /// caller.
    pub fn takeLyrics(self: *JobWorker) ?Lyrics {
        if (!self.retired and !self.registration.isFinished()) return null;
        return switch (self.stats) {
            .lyrics => |*stats| taken: {
                const lyrics = stats.result;
                stats.result = null;
                break :taken lyrics;
            },
            .scan, .duplicates, .matching, .submission, .artist_info => null,
        };
    }

    pub fn tagWriteFailure(self: *const JobWorker) ?TagWriteFailure {
        if (self.retired or self.registration.isFinished()) return self.tag_write_failure;
        return null;
    }

    pub fn wasCancelled(self: *const JobWorker) bool {
        return switch (self.stats) {
            .scan => |*stats| stats.cancelled.load(.acquire),
            .duplicates => |*stats| stats.cancelled.load(.acquire),
            .matching => |*stats| stats.cancelled.load(.acquire),
            .submission => |*stats| stats.cancelled.load(.acquire),
            .lyrics => |*stats| stats.outcome.load(.acquire) == .cancelled,
            .artist_info => |*stats| stats.outcome.load(.acquire) == .cancelled,
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
    totals.images += result.images;
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

test "artist info gateways are spaced at each service's published interval" {
    const expected = [_]struct { service: []const u8, interval_ms: u64 }{
        .{ .service = "musicbrainz", .interval_ms = 1000 },
        .{ .service = "wikidata", .interval_ms = 300 },
        .{ .service = "wikimedia-commons", .interval_ms = 300 },
        .{ .service = "wikipedia", .interval_ms = 300 },
        .{ .service = "listenbrainz-labs", .interval_ms = 1000 },
        .{ .service = "listenbrainz", .interval_ms = 1000 },
        .{ .service = "coverartarchive", .interval_ms = 250 },
    };
    try std.testing.expectEqual(expected.len, InfoServices.names.len);
    for (expected, InfoServices.names, InfoServices.intervals_ms) |want, name, interval_ms| {
        try std.testing.expectEqualStrings(want.service, name);
        try std.testing.expectEqual(want.interval_ms, interval_ms);
    }
}
