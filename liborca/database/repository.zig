const std = @import("std");
const sqlite = @import("sqlite.zig");
const metadata = @import("../metadata/model.zig");
const quick_hash = @import("../storage/quick_hash.zig");
const text_key = @import("text_key.zig");

/// The one logical write lane per Library.
///
/// A scan worker holds this across a bounded 256-row transaction while UI
/// threads read, so waiting must park rather than spin. `std.Thread.Mutex` does
/// not exist in this toolchain; `std.Io.Mutex` does, and it futex-waits, so the
/// lane carries the `io` its Library was opened with.
pub const WriteLane = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    /// Uncancelable on purpose: a half-applied write transaction is not a state
    /// this lane is allowed to leave behind.
    pub fn acquire(self: *WriteLane) void {
        self.mutex.lockUncancelable(self.io);
    }

    /// Takes the lane only if it is free. For a writer that would rather skip
    /// its write than wait — the decode producer is the case this exists for,
    /// since a job worker holds this lane across a whole batch commit and a
    /// producer parked behind one starves the render callback into underruns.
    pub fn tryAcquire(self: *WriteLane) bool {
        return self.mutex.tryLock();
    }

    pub fn release(self: *WriteLane) void {
        self.mutex.unlock(self.io);
    }
};

/// The projection's input. A Track is a position on a Release, so this is
/// written by `library/projection.zig` after resolving artists, releases and
/// recordings — never by the scanner, which only observes files.
pub const TrackInput = struct {
    recording_id: ?i64 = null,
    release_id: ?i64 = null,
    /// The Artist row this Track is filed under, resolved from the same key
    /// `ArtistRepository` stores. One primary artist per Track, deliberately —
    /// see the note on migration 9.
    artist_id: ?i64 = null,
    title: []const u8,
    artist: []const u8 = "",
    album: []const u8 = "",
    album_artist: []const u8 = "",
    duration_ms: ?i64 = null,
    track_number: ?i64 = null,
    disc_number: ?i64 = null,
    /// Denormalized cache of the encoding playback should reach for, so
    /// starting a Track is one indexed lookup instead of a three-way join.
    preferred_file_id: ?i64 = null,
};

/// The projection's artist input. Identity is `key` — the normalized name —
/// unless a MusicBrainz artist id is present, which outranks it.
pub const ArtistUpsert = struct {
    key: []const u8,
    name: []const u8,
    /// The folded key an artist listing orders by — `text_key.sortKey`, which
    /// drops a leading English article so "The Beatles" files under B. Stored
    /// rather than computed per query so one index serves the whole listing.
    sort_name: []const u8 = "",
    musicbrainz_artist_id: ?[]const u8 = null,
};

/// The projection's release input, keyed by the composite `release_key` the
/// projection derives from album, album artist and the strongest available
/// release identifier.
pub const ReleaseUpsert = struct {
    release_key: []const u8,
    title: []const u8,
    album_artist: []const u8 = "",
    release_date: ?[]const u8 = null,
    /// The Artist row this release is filed under. One album artist per
    /// release, deliberately — see the note on migration 9.
    album_artist_id: ?i64 = null,
    is_compilation: bool = false,
    disc_count: ?i64 = null,
    musicbrainz_release_id: ?[]const u8 = null,
};

/// A performance, distinct from the Track position that presents it and from
/// the files that encode it.
pub const RecordingInput = struct {
    title: []const u8,
    duration_ms: ?i64 = null,
};

pub const VolumeInput = struct {
    stable_key: []const u8,
    label: []const u8 = "",
};

pub const LibraryRoot = struct {
    id: i64,
    volume_id: i64,
    path: []u8,
    enabled: bool,

    pub fn deinit(self: LibraryRoot, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const LibraryRootPage = struct {
    allocator: std.mem.Allocator,
    items: []LibraryRoot,

    pub fn deinit(self: LibraryRootPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const ScanRunState = enum {
    running,
    completed,
    cancelled,
    failed,

    pub fn text(self: ScanRunState) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) ?ScanRunState {
        return std.meta.stringToEnum(ScanRunState, value);
    }
};

pub const ScanRun = struct {
    id: i64,
    root_id: i64,
    /// Monotonic per root. A location not stamped with the generation of a
    /// completed run is a sweep candidate, never a deletion candidate.
    generation: i64,
};

pub const ScanCounters = struct {
    files_seen: u64 = 0,
    changed: u64 = 0,
    unchanged: u64 = 0,
    unsupported: u64 = 0,
    errors: u64 = 0,
};

pub const FileUpsert = struct {
    audio_format: u8 = 0,
    codec: []const u8 = "",
    size_bytes: i64 = 0,
    sample_rate: ?i64 = null,
    bit_depth: ?i64 = null,
    channels: ?i64 = null,
    duration_ms: ?i64 = null,
    quick_hash: ?[]const u8 = null,
    audio_hash: ?[]const u8 = null,
    content_hash: ?[]const u8 = null,
};

/// The `files` rows a property backfill still owes a probe.
///
/// This is textually **one** string, shared by migration 10's partial index
/// and by `FileRepository.incompletePropertiesPage`. SQLite uses a partial
/// index only when the query's WHERE clause contains the index's own
/// predicate, and it matches that by expression, not by meaning: a paraphrase
/// here would silently turn row selection into a full scan of the largest
/// table in the schema.
///
/// `bit_depth` is deliberately not one of the terms. A transform codec has no
/// integer sample width to declare, so a null there is an answer rather than a
/// gap — 2,213 of the reference library's 22,060 rows are lossy, and including
/// it would re-probe every one of them on every run for ever.
pub const incomplete_properties_predicate =
    "duration_ms IS NULL OR sample_rate IS NULL OR channels IS NULL OR codec = ''";

/// Audio facts a probe learned about one already-recorded file.
///
/// Narrower than `FileUpsert` on purpose: a backfill reads headers, so it has
/// nothing to say about size, container or quick hash, and must not overwrite
/// what the scanner observed about them with defaults it made up.
pub const FilePropertyUpdate = struct {
    codec: []const u8 = "",
    sample_rate: ?i64 = null,
    bit_depth: ?i64 = null,
    channels: ?i64 = null,
    duration_ms: ?i64 = null,
    /// The container the probe actually found, when it disagrees with what the
    /// row says. Null leaves the stored value alone, so a probe that could not
    /// determine the container never overwrites a good answer with a guess.
    audio_format: ?i64 = null,
};

/// One incomplete file and where to read it.
pub const IncompleteFile = struct {
    id: i64,
    /// Empty when no location on any known volume names this file, which is a
    /// row the backfill can only count and move past.
    uri: []u8,
};

pub const IncompleteFilePage = struct {
    allocator: std.mem.Allocator,
    items: []IncompleteFile,

    pub fn deinit(self: IncompleteFilePage) void {
        for (self.items) |item| self.allocator.free(item.uri);
        self.allocator.free(self.items);
    }
};

/// Where a reader should open a file: a present location in preference to an
/// unverified one, and a missing one only if there is nothing better, because
/// a drive that is back should be read rather than skipped. Empty when no
/// location on any known volume names the file.
///
/// One definition, because every pass that repairs `files` by id needs exactly
/// this rule and two spellings of it would drift.
const location_uri_column =
    \\(SELECT locations.uri FROM locations WHERE locations.file_id = files.id
    \\ ORDER BY CASE locations.state WHEN 'present' THEN 0
    \\               WHEN 'unverified' THEN 1 ELSE 2 END, locations.id
    \\ LIMIT 1)
;

/// Which measurement a library-wide analysis is asking about.
///
/// Everything except the file and its identity: the caller supplies the
/// algorithm it would run and the parameters it would run under, so a
/// selection asks "which files lack *this* measurement" rather than "which
/// files lack any measurement".
pub const AnalysisSelector = struct {
    kind: u8,
    algorithm_id: []const u8,
    algorithm_version: u32,
    parameter_hash: [32]u8,
};

/// The `files` rows that still owe a library-wide analysis.
///
/// One string, shared by `FileRepository.unanalyzedPage`, `unanalyzedCount`
/// and the plan test that proves neither is a table scan. Parameters ?3 to ?6
/// are the `AnalysisSelector`; ?1 and ?2 stay the caller's cursor and limit,
/// as they are for every other page in this file.
///
/// This is an anti-join against `analysis_results`' own primary key rather
/// than a flag on `files`, because that key *is* the answer. It already
/// encodes all three reasons a stored measurement stops counting — the bytes
/// changed (`source_identity`), the algorithm changed (`algorithm_version`),
/// the parameters changed (`parameter_hash`) — and a duplicate marker on
/// `files` would be a second source of truth that could disagree with the
/// results it claims to describe. `analysis_results` is `WITHOUT ROWID` with
/// exactly those six columns as its primary key, so each row of `files` costs
/// one full-prefix B-tree probe and no index has to be invented for this.
///
/// `source_identity = files.quick_hash` compares the measurement against the
/// identity the *Library* recorded, not against the bytes on disk. A file
/// whose bytes moved without a rescan therefore keeps being selected: that is
/// correct — its stored measurement no longer describes it — and the pass
/// declines to measure it until a scan has caught up, rather than filing a new
/// measurement the selection would go on missing for ever.
///
/// The *playback* lookup is stricter, and deliberately asymmetric: it keys on
/// the identity of the bytes it just opened, because adopting a correction for
/// audio a file no longer contains is a wrong answer, while re-selecting a
/// file for measurement is only wasted work.
pub const unanalyzed_predicate =
    \\NOT EXISTS (SELECT 1 FROM analysis_results
    \\    WHERE analysis_results.file_id = files.id
    \\      AND analysis_results.kind = ?3
    \\      AND analysis_results.algorithm_id = ?4
    \\      AND analysis_results.algorithm_version = ?5
    \\      AND analysis_results.parameter_hash = ?6
    \\      AND analysis_results.source_identity = files.quick_hash)
;

/// One file that still owes an analysis, where to read it, and what the
/// Library believes its bytes are.
pub const AnalysisCandidate = struct {
    id: i64,
    /// Empty when no location on any known volume names this file.
    uri: []u8,
    /// Null when the Library has never fingerprinted this file, which is a row
    /// no measurement can be keyed against until a scan gives it an identity.
    source_identity: ?quick_hash.Digest,
};

pub const AnalysisCandidatePage = struct {
    allocator: std.mem.Allocator,
    items: []AnalysisCandidate,

    pub fn deinit(self: AnalysisCandidatePage) void {
        for (self.items) |item| self.allocator.free(item.uri);
        self.allocator.free(self.items);
    }
};

/// One file a duplicate scan will examine, and the two keys it can be
/// bucketed by.
///
/// Both are nullable and both nulls mean something the scan must report rather
/// than swallow: no `audio_hash` means the analysis pass has never decoded
/// this file, so nothing can be said about what it sounds like; no
/// `duration_ms` means no scan or probe has ever established how long it is,
/// so it cannot be placed in a duration window.
pub const DuplicateCandidate = struct {
    id: i64,
    audio_hash: ?[32]u8,
    duration_ms: ?i64,
    /// The identity the Library recorded, which is the key its stored
    /// fingerprint is filed under. Null for a file no scan has hashed.
    source_identity: ?quick_hash.Digest,
};

/// A file inside a duplicate scan's plausible bucket, with everything needed
/// to compare against it: its stored fingerprint is keyed on
/// `source_identity`, and `audio_hash` says whether the exact bucket has
/// already accounted for it.
pub const DuplicatePeer = struct {
    id: i64,
    source_identity: ?quick_hash.Digest,
    audio_hash: ?[32]u8,
};

pub const DuplicateCandidatePage = struct {
    allocator: std.mem.Allocator,
    items: []DuplicateCandidate,

    pub fn deinit(self: DuplicateCandidatePage) void {
        self.allocator.free(self.items);
    }
};

pub const LocationState = enum {
    present,
    missing,
    unverified,

    pub fn text(self: LocationState) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) ?LocationState {
        return std.meta.stringToEnum(LocationState, value);
    }
};

pub const LocationUpsert = struct {
    file_id: i64,
    volume_id: i64,
    root_id: ?i64 = null,
    uri: []const u8,
    native_device: ?i64 = null,
    native_inode: ?i64 = null,
    size_bytes: i64 = 0,
    modified_ns: i64 = 0,
    state: LocationState = .present,
    last_seen_generation: i64 = 0,
};

pub const StorageIdentityKey = struct {
    volume_id: i64,
    native_inode: i64,
    size_bytes: i64,
    modified_ns: i64,
};

/// Everything playback needs to open a Track's bytes without a second query.
pub const ResolvedLocation = struct {
    allocator: std.mem.Allocator,
    file_id: i64,
    volume_stable_key: []u8,
    uri: []u8,
    audio_format: u8,

    pub fn deinit(self: ResolvedLocation) void {
        self.allocator.free(self.volume_stable_key);
        self.allocator.free(self.uri);
    }
};

/// What the Library recorded about the file a Track resolves to, read in one
/// row so a host can describe a Track without one query per fact.
pub const TrackFileFacts = struct {
    allocator: std.mem.Allocator,
    file_id: i64,
    codec: []u8,
    size_bytes: i64,
    sample_rate: ?i64,
    bit_depth: ?i64,
    channels: ?i64,
    duration_ms: ?i64,
    quick_hash: ?quick_hash.Digest,
    /// The uri of the best location that is not missing, or null when every
    /// location is.
    path: ?[]u8,
    /// Whether the last scan observed a non-empty cover in the file.
    has_artwork: bool,
    /// The Release's date and compilation flag, as the projection resolved them
    /// from every file of the Release and any user edits. Null without a
    /// Release.
    release_date: ?[]u8,
    compilation: ?bool,

    pub fn deinit(self: TrackFileFacts) void {
        self.allocator.free(self.codec);
        if (self.path) |value| self.allocator.free(value);
        if (self.release_date) |value| self.allocator.free(value);
    }
};

/// Observed tags as the readers produce them, addressed by file identity.
///
/// The tag set is `metadata.ObservedTags` verbatim: anything a reader can
/// report is storable, because the previous schema silently dropped every
/// field it had no column for — including the MusicBrainz release id, which is
/// the strongest key the projection has for grouping files into a Release.
pub const ObservedTagsInput = struct {
    file_id: i64,
    values: metadata.ObservedTags,
};

/// Stored observed tags plus the arena their text lives in, mirroring
/// `library.tag_reader.Tags` so a round trip costs the caller one `deinit`.
pub const StoredObservedTags = struct {
    arena: *std.heap.ArenaAllocator,
    values: metadata.ObservedTags,

    pub fn deinit(self: StoredObservedTags) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

pub const OrcaMetadataInput = struct {
    file_id: i64,
    field: metadata.Field,
    value: []const u8,
    provenance: metadata.Provenance,
    locked: bool = false,
};

pub const FieldValue = struct {
    field: metadata.Field,
    text: []u8,
    provenance: metadata.Provenance,
    locked: bool,
};

pub const FieldValuePage = struct {
    allocator: std.mem.Allocator,
    items: []FieldValue,

    pub fn deinit(self: *FieldValuePage) void {
        for (self.items) |item| self.allocator.free(item.text);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const PresentLocation = struct {
    uri: []u8,
    volume_id: i64,
    root_id: ?i64,
    generation: i64,
};

pub const StoredMetadataValue = struct {
    text: []u8,
    provenance: metadata.Provenance,
    locked: bool,

    pub fn deinit(self: StoredMetadataValue, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const MutationKind = enum { write_tags, move };

pub const MutationState = enum {
    planned,
    staged,
    committed,
    rolled_back,
    failed,
    needs_reconciliation,
};

/// A journal record keeps its paths — a filesystem operation's subject
/// genuinely is a path, which is not an identity violation — and carries
/// `file_id` so the journal can restore musical identity after a move.
pub const MutationOperationInput = struct {
    plan_id: u64,
    group_id: u64,
    action_index: u32,
    kind: MutationKind,
    file_id: ?i64 = null,
    source_path: []const u8,
    destination_path: ?[]const u8 = null,
    stage_path: ?[]const u8 = null,
    backup_path: ?[]const u8 = null,
    expected_size: u64,
    expected_modified_ns: i64,
    expected_quick_hash: quick_hash.Digest,
};

pub const MutationOperation = struct {
    allocator: std.mem.Allocator,
    id: i64,
    kind: MutationKind,
    file_id: ?i64,
    source_path: []u8,
    destination_path: ?[]u8,
    stage_path: ?[]u8,
    backup_path: ?[]u8,
    expected_size: u64,
    expected_modified_ns: i64,
    expected_quick_hash: ?quick_hash.Digest,
    committed_size: ?u64,
    committed_modified_ns: ?i64,
    committed_quick_hash: ?quick_hash.Digest,
    state: MutationState,

    pub fn deinit(self: MutationOperation) void {
        self.allocator.free(self.source_path);
        if (self.destination_path) |value| self.allocator.free(value);
        if (self.stage_path) |value| self.allocator.free(value);
        if (self.backup_path) |value| self.allocator.free(value);
    }
};

/// Analysis is cached against `files.id` and the file's quick hash, not its
/// size and modification time: writing a tag changes both of those and must not
/// invalidate a loudness measurement of audio that did not change.
pub const AnalysisCacheKey = struct {
    file_id: i64,
    kind: u8,
    algorithm_id: []const u8,
    algorithm_version: u32,
    parameter_hash: [32]u8,
    source_identity: quick_hash.Digest,
};

pub const HealthIssueKind = enum(u8) {
    missing_metadata,
    missing_track_number,
    album_artist_anomaly,
    artwork_problem,
    missing_analysis,
    clipping,
    excessive_silence,
    technical_anomaly,
    corrupt_audio,
    exact_duplicate,
    likely_duplicate,
    /// The file behind a row could not be opened or would not decode. Owned by
    /// the property backfill alone, which is why it is not `corrupt_audio`:
    /// that kind belongs to the analyzer, which decodes the whole stream, and
    /// a header-only pass must not be able to clear a finding made by reading
    /// audio it never looked at.
    unreadable_file,
};

pub const HealthSeverity = enum(u8) { information, warning, error_severity };

pub const HealthIssueInput = struct {
    kind: HealthIssueKind,
    severity: HealthSeverity,
    details: []const u8 = "",
};

pub const HealthIssue = struct {
    file_id: i64,
    /// The location a host should show for this issue, empty when the file has
    /// no location on any known volume. Presentation only — identity is
    /// `file_id`.
    path: []u8,
    kind: HealthIssueKind,
    severity: HealthSeverity,
    details: []u8,

    pub fn deinit(self: HealthIssue, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.details);
    }
};

pub const HealthIssuePage = struct {
    allocator: std.mem.Allocator,
    items: []HealthIssue,

    pub fn deinit(self: HealthIssuePage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub const ProviderCacheEntry = struct {
    allocator: std.mem.Allocator,
    status: u16,
    body: []u8,
    expires_at: i64,

    pub fn deinit(self: ProviderCacheEntry) void {
        self.allocator.free(self.body);
    }
};

pub const ScrobbleQueueEntry = struct {
    allocator: std.mem.Allocator,
    id: i64,
    service: []u8,
    event_key: []u8,
    payload: []u8,
    attempt_count: u32,

    pub fn deinit(self: ScrobbleQueueEntry) void {
        self.allocator.free(self.service);
        self.allocator.free(self.event_key);
        self.allocator.free(self.payload);
    }
};

pub const ListenInput = struct {
    file_id: i64,
    recording_id: ?i64 = null,
    started_at: i64,
    listened_ms: u64,
    duration_ms: ?u64 = null,
    title: []const u8,
    artist: []const u8,
    album: []const u8 = "",
    recording_mbid: ?[]const u8 = null,
    player_client: []const u8 = "",
};

pub const PlayStats = struct {
    play_count: u64,
    last_played_at: ?i64,
};

pub const Feedback = enum {
    none,
    loved,
    hated,

    pub fn score(self: Feedback) i8 {
        return switch (self) {
            .none => 0,
            .loved => 1,
            .hated => -1,
        };
    }

    pub fn fromScore(value: i64) ?Feedback {
        return switch (value) {
            0 => .none,
            1 => .loved,
            -1 => .hated,
            else => null,
        };
    }
};

pub const FeedbackChange = struct {
    updated: u32 = 0,
    skipped: u32 = 0,
};

pub const FeedbackSync = struct {
    allocator: std.mem.Allocator,
    recording_id: i64,
    feedback: Feedback,
    recording_mbid: []u8,

    pub fn deinit(self: FeedbackSync) void {
        self.allocator.free(self.recording_mbid);
    }
};

pub const ListenSubject = struct {
    allocator: std.mem.Allocator,
    file_id: ?i64,
    recording_id: ?i64,
    title: []u8,
    artist: []u8,
    album: []u8,
    duration_ms: ?i64,
    track_number: ?i64,
    recording_mbid: ?[]u8,
    release_mbid: ?[]u8,
    artist_mbid: ?[]u8,

    pub fn deinit(self: ListenSubject) void {
        self.allocator.free(self.title);
        self.allocator.free(self.artist);
        self.allocator.free(self.album);
        if (self.recording_mbid) |value| self.allocator.free(value);
        if (self.release_mbid) |value| self.allocator.free(value);
        if (self.artist_mbid) |value| self.allocator.free(value);
    }
};

pub const ProposalState = enum(u8) { pending, accepted, dismissed };

pub const IdentificationProposalInput = struct {
    file_id: i64,
    provider: []const u8,
    provider_id: []const u8,
    confidence: f32,
    payload: []const u8,
};

pub const IdentificationProposal = struct {
    allocator: std.mem.Allocator,
    id: i64,
    provider: []u8,
    provider_id: []u8,
    confidence: f32,
    payload: []u8,

    pub fn deinit(self: IdentificationProposal) void {
        self.allocator.free(self.provider);
        self.allocator.free(self.provider_id);
        self.allocator.free(self.payload);
    }
};

/// What a provider said about a candidate, stored as a proposal's JSON
/// payload. Every field has a default so older payloads still parse.
pub const ProposalPayload = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    track_number: ?u32 = null,
    release_mbid: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    mb_score: ?u8 = null,
    /// AcoustID's own score for the fingerprint match, 0 to 1.
    acoustid_score: ?f32 = null,
    /// Orca's confidence from each provider's evidence alone.
    musicbrainz_confidence: ?f32 = null,
    acoustid_confidence: ?f32 = null,

    pub fn parse(
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) error{ InvalidProposalPayload, OutOfMemory }!std.json.Parsed(ProposalPayload) {
        return std.json.parseFromSlice(ProposalPayload, allocator, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidProposalPayload,
        };
    }

    pub fn encode(self: ProposalPayload, allocator: std.mem.Allocator) ![]u8 {
        var writer = std.Io.Writer.Allocating.init(allocator);
        errdefer writer.deinit();
        try std.json.Stringify.value(self, .{ .emit_null_optional_fields = false }, &writer.writer);
        var list = writer.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    /// Independent evidence from each provider combined: the chance that
    /// neither is right, taken away from one. Two providers agreeing is more
    /// confident than either alone.
    pub fn combinedConfidence(self: ProposalPayload) f32 {
        var doubt: f32 = 1;
        inline for (.{ self.musicbrainz_confidence, self.acoustid_confidence }) |confidence| {
            if (confidence) |value| doubt *= 1 - std.math.clamp(value, 0, 1);
        }
        return 1 - doubt;
    }
};

pub const IdentificationProvider = enum {
    musicbrainz,
    acoustid,

    pub fn text(self: IdentificationProvider) []const u8 {
        return @tagName(self);
    }
};

/// The providers that found a proposal, stored in
/// `identification_proposals.provider` as `musicbrainz`, `acoustid` or
/// `musicbrainz+acoustid`.
pub const ProviderSet = struct {
    musicbrainz: bool = false,
    acoustid: bool = false,

    pub fn text(self: ProviderSet) []const u8 {
        if (self.musicbrainz and self.acoustid) return "musicbrainz+acoustid";
        if (self.musicbrainz) return "musicbrainz";
        if (self.acoustid) return "acoustid";
        return "";
    }

    pub fn parse(stored: []const u8) ProviderSet {
        var set: ProviderSet = .{};
        var names = std.mem.tokenizeScalar(u8, stored, '+');
        while (names.next()) |name| {
            if (std.mem.eql(u8, name, "musicbrainz")) set.musicbrainz = true;
            if (std.mem.eql(u8, name, "acoustid")) set.acoustid = true;
        }
        return set;
    }

    pub fn with(self: ProviderSet, other: ProviderSet) ProviderSet {
        return .{
            .musicbrainz = self.musicbrainz or other.musicbrainz,
            .acoustid = self.acoustid or other.acoustid,
        };
    }

    pub fn isEmpty(self: ProviderSet) bool {
        return !self.musicbrainz and !self.acoustid;
    }
};

/// What one search found for one recording: which providers found it, and
/// what they said, with each finder's confidence filled in.
pub const ProposalEvidence = struct {
    recording_mbid: []const u8,
    found_by: ProviderSet,
    payload: ProposalPayload,
};

/// An existing proposal with new evidence folded in. MusicBrainz describes the
/// recording whenever it found it; AcoustID only when MusicBrainz has not.
/// A payload written before per-provider confidences existed lends its row's
/// confidence to the one provider it names.
pub fn mergeProposalPayload(
    existing: ProposalPayload,
    existing_providers: ProviderSet,
    existing_confidence: f32,
    evidence: ProposalEvidence,
) ProposalPayload {
    var merged = existing;
    if (merged.musicbrainz_confidence == null and existing_providers.musicbrainz and !existing_providers.acoustid)
        merged.musicbrainz_confidence = existing_confidence;
    if (merged.acoustid_confidence == null and existing_providers.acoustid and !existing_providers.musicbrainz)
        merged.acoustid_confidence = existing_confidence;
    const found = evidence.payload;
    if (evidence.found_by.musicbrainz or !existing_providers.musicbrainz) {
        merged.title = found.title;
        merged.artist = found.artist;
        merged.album = found.album;
        merged.track_number = found.track_number;
        merged.release_mbid = found.release_mbid;
        merged.duration_ms = found.duration_ms;
        merged.mb_score = found.mb_score;
    }
    if (evidence.found_by.musicbrainz) merged.musicbrainz_confidence = found.musicbrainz_confidence;
    if (evidence.found_by.acoustid) {
        merged.acoustid_score = found.acoustid_score;
        merged.acoustid_confidence = found.acoustid_confidence;
    }
    return merged;
}

pub const MatchProposal = struct {
    id: i64,
    provider: []const u8,
    recording_mbid: []const u8,
    confidence: f32,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    track_number: ?u32,
    release_mbid: ?[]const u8,
    duration_ms: ?u64,
    musicbrainz_score: ?u8,
    acoustid_score: ?f32,
};

pub const MatchProposalPage = struct {
    arena: *std.heap.ArenaAllocator,
    items: []MatchProposal,

    pub fn deinit(self: MatchProposalPage) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

pub const ProposalAcceptance = struct {
    file_id: i64,
    values_written: u32,
};

pub const MatchCandidate = struct {
    track_id: i64,
    file_id: i64,
    title: []u8,
    artist: []u8,
    album: []u8,
    duration_ms: ?i64,
    /// Where the file is, or null when no location of it is present.
    path: ?[]u8,
    needs_musicbrainz: bool,
    needs_acoustid: bool,

    fn deinit(self: MatchCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.artist);
        allocator.free(self.album);
        if (self.path) |value| allocator.free(value);
    }
};

pub const MatchCandidatePage = struct {
    allocator: std.mem.Allocator,
    items: []MatchCandidate,

    pub fn deinit(self: MatchCandidatePage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

/// Which Tracks a matching pass considers.
pub const MatchScope = union(enum) {
    library,
    track: i64,

    fn lowerBound(self: MatchScope, cursor: i64) i64 {
        return switch (self) {
            .library => cursor,
            .track => |track_id| @max(cursor, track_id - 1),
        };
    }

    fn upperBound(self: MatchScope) i64 {
        return switch (self) {
            .library => std.math.maxInt(i64),
            .track => |track_id| track_id,
        };
    }
};

/// A Track with pending proposals, as the review list shows it: the Track's
/// own tags beside its best proposal.
pub const MatchReviewItem = struct {
    track_id: i64,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    duration_ms: ?i64,
    proposal_count: u32,
    best: MatchProposal,
};

pub const MatchReviewPage = struct {
    arena: *std.heap.ArenaAllocator,
    items: []MatchReviewItem,

    pub fn deinit(self: MatchReviewPage) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

pub const RecordingMbid = struct {
    text: []u8,
    provenance: metadata.Provenance,

    pub fn deinit(self: RecordingMbid, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const TrackSummary = struct {
    id: i64,
    title: []u8,
    artist: []u8,
    album: []u8,
    album_artist: []u8,
    duration_ms: ?i64,
    track_number: ?i64,
    disc_number: ?i64,
    /// Whether the Track resolves to a file with a location, so a host can grey
    /// out a row without asking a second question per Track.
    has_playable_file: bool,
    release_id: ?i64 = null,
    /// The credited Artist, when the projection resolved one.
    artist_id: ?i64 = null,
    recording_id: ?i64 = null,
    feedback: Feedback = .none,

    pub fn deinit(self: TrackSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.artist);
        allocator.free(self.album);
        allocator.free(self.album_artist);
    }
};

pub const TrackPage = struct {
    allocator: std.mem.Allocator,
    items: []TrackSummary,

    pub fn deinit(self: TrackPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

/// What a Track listing is ordered by.
///
/// Every one of these names an index created by migration 9, and every ORDER BY
/// they produce ends in `tracks.id`. Both matter. Without the unique tiebreaker
/// a LIMIT/OFFSET walk over a column with ties — 3,251 Tracks in the reference
/// library share a title with another — is free to return one row on two pages
/// and skip a third, because SQLite may order equal keys differently between
/// two evaluations of the same statement.
pub const TrackSort = enum {
    /// Insertion order. The cheapest listing there is, and the default, so a
    /// caller that has no opinion pays for none.
    id,
    artist,
    album,
    title,
    /// Disc, then track number, which is the order an album is listened to.
    track_number,
    duration,
    date_added,
};

pub const SortDirection = enum {
    ascending,
    descending,

    fn suffix(self: SortDirection) []const u8 {
        return switch (self) {
            .ascending => "",
            .descending => " DESC",
        };
    }
};

/// One bounded, ordered, filtered request for a page of Tracks.
///
/// A filter is a relational one — `artist_id`, `release_id` — never a text
/// match against the denormalized columns, so an artist browse and an album
/// browse ask the question the schema can actually index.
pub const TrackQuery = struct {
    artist_id: ?i64 = null,
    release_id: ?i64 = null,
    sort: TrackSort = .id,
    direction: SortDirection = .ascending,
    limit: u32 = max_page,
    offset: u32 = 0,
};

/// The largest page any repository hands back, matching the C ABI's own bound.
pub const max_page = 512;

pub const TrackRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Upsert by position, because a Track *is* a position on a Release: the
    /// same `(release_id, disc, track)` re-projected must update the row it
    /// already has rather than duplicate it. Rows without a Release or a track
    /// number have no position to collide on and always insert, which is what
    /// `tracks_position` (`COALESCE(track_number, -id)`) encodes.
    pub fn upsertTracks(self: *TrackRepository, tracks: []const TrackInput) !void {
        if (tracks.len == 0) return;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try self.upsertTracksLocked(tracks);
        try self.db.exec("COMMIT;");
    }

    /// Same as `upsertTracks` for a caller that already holds the write lane
    /// and an open transaction. The projection resolves artists, releases,
    /// recordings and tracks for one folder as a single bounded commit.
    pub fn upsertTracksLocked(self: *TrackRepository, tracks: []const TrackInput) !void {
        if (tracks.len == 0) return;
        var update = try self.db.prepare(
            \\UPDATE tracks SET
            \\    recording_id=?1, title=?2, artist=?3, album=?4, album_artist=?5,
            \\    duration_ms=?6, preferred_file_id=?7, artist_id=?11
            \\WHERE release_id=?8 AND COALESCE(disc_number, 1)=?9 AND track_number=?10;
        );
        defer update.deinit();
        var insert = try self.db.prepare(
            \\INSERT INTO tracks(
            \\    recording_id, release_id, title, artist, album, album_artist,
            \\    duration_ms, track_number, disc_number, preferred_file_id, artist_id
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);
        );
        defer insert.deinit();
        for (tracks) |track| {
            if (track.release_id != null and track.track_number != null) {
                try update.bindOptionalInt64(1, track.recording_id);
                try update.bindText(2, track.title);
                try update.bindText(3, track.artist);
                try update.bindText(4, track.album);
                try update.bindText(5, track.album_artist);
                try update.bindOptionalInt64(6, track.duration_ms);
                try update.bindOptionalInt64(7, track.preferred_file_id);
                try update.bindOptionalInt64(8, track.release_id);
                try update.bindInt64(9, track.disc_number orelse 1);
                try update.bindOptionalInt64(10, track.track_number);
                try update.bindOptionalInt64(11, track.artist_id);
                if (try update.step() != .done) return error.SqlFailed;
                const updated = self.db.changes() != 0;
                try update.reset();
                if (updated) continue;
            }
            try insert.bindOptionalInt64(1, track.recording_id);
            try insert.bindOptionalInt64(2, track.release_id);
            try insert.bindText(3, track.title);
            try insert.bindText(4, track.artist);
            try insert.bindText(5, track.album);
            try insert.bindText(6, track.album_artist);
            try insert.bindOptionalInt64(7, track.duration_ms);
            try insert.bindOptionalInt64(8, track.track_number);
            try insert.bindOptionalInt64(9, track.disc_number);
            try insert.bindOptionalInt64(10, track.preferred_file_id);
            try insert.bindOptionalInt64(11, track.artist_id);
            if (try insert.step() != .done) return error.SqlFailed;
            try insert.reset();
        }
    }

    pub fn setRatings(self: *TrackRepository, ids: []const i64, rating: u8) !void {
        if (rating > 100) return error.InvalidRating;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var statement = try self.db.prepare("UPDATE tracks SET rating=?1 WHERE id=?2;");
        defer statement.deinit();
        for (ids) |id| {
            try statement.bindInt64(1, rating);
            try statement.bindInt64(2, id);
            if (try statement.step() != .done) return error.SqlFailed;
            try statement.reset();
        }
        try self.db.exec("COMMIT;");
    }

    pub fn search(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: u32,
        offset: u32,
    ) !TrackPage {
        var statement = try self.db.prepare(track_columns ++
            "FROM track_search\n" ++
            "JOIN tracks ON tracks.id = track_search.rowid\n" ++
            feedback_join ++
            "WHERE track_search MATCH ?1\n" ++
            "ORDER BY rank\n" ++
            "LIMIT ?2 OFFSET ?3;");
        defer statement.deinit();
        try statement.bindText(1, query);
        try statement.bindInt64(2, limit);
        try statement.bindInt64(3, offset);
        return collectTrackPage(allocator, statement);
    }

    /// One bounded page of Tracks, in an order the caller named.
    ///
    /// Both halves of `query` are load-bearing. The sort decides which index
    /// SQLite walks, and because every generated ORDER BY ends in `tracks.id`
    /// the walk is a total order — so page N+1 continues exactly where page N
    /// stopped, even across the thousands of Tracks that share a title with
    /// another. The filters are relational: `artist_id` and `release_id`, not
    /// a text match against the denormalized columns.
    pub fn page(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        query: TrackQuery,
    ) !TrackPage {
        if (query.limit == 0 or query.limit > max_page) return error.PageOutOfRange;
        const filter: TrackFilter = if (query.artist_id != null and query.release_id != null)
            .artist_and_release
        else if (query.artist_id != null)
            .artist
        else if (query.release_id != null)
            .release
        else
            .none;
        var statement = try self.db.prepare(
            trackQueryText(filter, query.sort, query.direction),
        );
        defer statement.deinit();
        try statement.bindInt64(1, query.limit);
        try statement.bindInt64(2, query.offset);
        if (query.artist_id) |artist_id| try statement.bindInt64(3, artist_id);
        if (query.release_id) |release_id| try statement.bindInt64(4, release_id);
        return collectTrackPage(allocator, statement);
    }

    /// How many Tracks a filtered listing has to page through, so a host can
    /// size a scrollbar without walking the listing.
    /// Counts what `page` would return. It shares `by_artist` with the paged
    /// query rather than restating the predicate, because it had its own copy
    /// and the two drifted the moment the definition of an artist's tracks
    /// widened: the list showed an artist's album tracks while the count above
    /// it said zero. Parameter positions match `buildTrackQuery` for the same
    /// reason.
    pub fn countMatching(self: *const TrackRepository, query: TrackQuery) !u64 {
        var statement = try self.db.prepare(
            "SELECT count(*) FROM tracks\n" ++
                "WHERE (?3 IS NULL OR " ++ by_artist ++ ")\n" ++
                "  AND (?4 IS NULL OR tracks.release_id = ?4);",
        );
        defer statement.deinit();
        try statement.bindOptionalInt64(3, query.artist_id);
        try statement.bindOptionalInt64(4, query.release_id);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn recordingMbid(self: *const TrackRepository, allocator: std.mem.Allocator, track_id: i64) !?RecordingMbid {
        var statement = try self.db.prepare(
            "SELECT orca.value, orca.provenance, orca.locked, observed.musicbrainz_recording_id\n" ++
                "FROM (SELECT " ++ track_play_file ++ " AS file_id FROM tracks WHERE tracks.id = ?1) AS track\n" ++
                "LEFT JOIN orca_metadata_values AS orca\n" ++
                "    ON orca.file_id = track.file_id AND orca.field = " ++ recording_mbid_field ++ "\n" ++
                "LEFT JOIN observed_file_tags AS observed ON observed.file_id = track.file_id;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return null;
        const orca: ?metadata.Value = if (statement.columnIsNull(0) or statement.columnText(0).len == 0) null else .{
            .text = statement.columnText(0),
            .provenance = std.enums.fromInt(metadata.Provenance, statement.columnInt64(1)) orelse
                return error.InvalidStoredProvenance,
            .locked = statement.columnInt64(2) != 0,
        };
        const observed: ?metadata.Value = if (statement.columnIsNull(3) or statement.columnText(3).len == 0) null else .{
            .text = statement.columnText(3),
            .provenance = .observed_file,
        };
        const resolved = metadata.resolveValue(observed, orca, .prefer_file) orelse return null;
        return .{ .text = try allocator.dupe(u8, resolved.text), .provenance = resolved.provenance };
    }

    /// The files a Track resolves to: its preferred file and every other
    /// encoding of its recording. Bounded by `max_page`.
    pub fn fileIds(self: *const TrackRepository, allocator: std.mem.Allocator, track_id: i64) ![]i64 {
        var statement = try self.db.prepare(
            \\SELECT preferred_file_id FROM tracks WHERE id=?1 AND preferred_file_id IS NOT NULL
            \\UNION
            \\SELECT f.id FROM files f JOIN tracks t ON f.recording_id = t.recording_id
            \\WHERE t.id=?1
            \\LIMIT ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        try statement.bindInt64(2, max_page);
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row) try ids.append(allocator, statement.columnInt64(0));
        return ids.toOwnedSlice(allocator);
    }

    /// The Tracks a file backs: as their preferred file, or through their
    /// Recording. The reverse of `fileIds`.
    pub fn idsForFile(self: *const TrackRepository, allocator: std.mem.Allocator, file_id: i64) ![]i64 {
        var statement = try self.db.prepare(
            \\SELECT id FROM tracks WHERE preferred_file_id=?1
            \\UNION
            \\SELECT t.id FROM tracks t JOIN files f ON f.recording_id = t.recording_id
            \\WHERE f.id=?1
            \\LIMIT ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, max_page);
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row) try ids.append(allocator, statement.columnInt64(0));
        return ids.toOwnedSlice(allocator);
    }

    /// One Track by id, for the "what is playing right now" question. Bounded
    /// by construction: a single row, copied out, with no statement escaping.
    pub fn byId(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
    ) !?TrackSummary {
        var statement = try self.db.prepare(track_columns ++ "FROM tracks\n" ++ feedback_join ++
            "WHERE tracks.id = ?1;");
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        var page_result = try collectTrackPage(allocator, statement);
        if (page_result.items.len == 0) {
            page_result.deinit();
            return null;
        }
        const first = page_result.items[0];
        for (page_result.items[1..]) |extra| extra.deinit(allocator);
        allocator.free(page_result.items);
        return first;
    }

    /// Where a Track's bytes actually live. This is the call that turns "a row
    /// in a list" into "audio a Player can open", so it answers with the
    /// volume's stable key rather than assuming a local path, and prefers a
    /// location that a scan has confirmed.
    pub fn playableLocation(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
    ) !?ResolvedLocation {
        var statement = try self.db.prepare(
            \\SELECT locations.file_id, volumes.stable_key, locations.uri, files.audio_format
            \\FROM tracks
            \\JOIN files ON files.id = COALESCE(
            \\    tracks.preferred_file_id,
            \\    (SELECT id FROM files WHERE recording_id = tracks.recording_id ORDER BY id LIMIT 1)
            \\)
            \\JOIN locations ON locations.file_id = files.id
            \\JOIN volumes ON volumes.id = locations.volume_id
            \\WHERE tracks.id = ?1
            \\ORDER BY CASE locations.state
            \\    WHEN 'present' THEN 0 WHEN 'unverified' THEN 1 ELSE 2 END, locations.id
            \\LIMIT 1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return null;
        const stable_key = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(stable_key);
        const uri = try allocator.dupe(u8, statement.columnText(2));
        errdefer allocator.free(uri);
        return .{
            .allocator = allocator,
            .file_id = statement.columnInt64(0),
            .volume_stable_key = stable_key,
            .uri = uri,
            .audio_format = std.math.cast(u8, statement.columnInt64(3)) orelse
                return error.InvalidStoredAudioFormat,
        };
    }

    /// The recorded facts of the file a Track resolves to, or null when the
    /// Track does not exist or has no file. One row: nothing on disk is read.
    pub fn fileFacts(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
    ) !?TrackFileFacts {
        var statement = try self.db.prepare(
            \\SELECT files.id, files.codec, files.size_bytes, files.sample_rate,
            \\       files.bit_depth, files.channels, files.duration_ms, files.quick_hash,
            \\       (SELECT locations.uri FROM locations
            \\        WHERE locations.file_id = files.id AND locations.state <> 'missing'
            \\        ORDER BY CASE locations.state WHEN 'present' THEN 0 ELSE 1 END, locations.id
            \\        LIMIT 1),
            \\       COALESCE(observed_file_tags.artwork_byte_size, 0) > 0
            \\           AND observed_file_tags.artwork_mime_type IS NOT NULL,
            \\       releases.release_date, releases.is_compilation
            \\FROM tracks
            \\JOIN files ON files.id = COALESCE(
            \\    tracks.preferred_file_id,
            \\    (SELECT id FROM files WHERE recording_id = tracks.recording_id ORDER BY id LIMIT 1)
            \\)
            \\LEFT JOIN observed_file_tags ON observed_file_tags.file_id = files.id
            \\LEFT JOIN releases ON releases.id = tracks.release_id
            \\WHERE tracks.id = ?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return null;
        const codec = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(codec);
        const path: ?[]u8 = if (statement.columnIsNull(8))
            null
        else
            try allocator.dupe(u8, statement.columnText(8));
        errdefer if (path) |value| allocator.free(value);
        const release_date: ?[]u8 = if (statement.columnIsNull(10))
            null
        else
            try allocator.dupe(u8, statement.columnText(10));
        errdefer if (release_date) |value| allocator.free(value);
        return .{
            .allocator = allocator,
            .file_id = statement.columnInt64(0),
            .codec = codec,
            .size_bytes = statement.columnInt64(2),
            .sample_rate = optionalInt64(statement, 3),
            .bit_depth = optionalInt64(statement, 4),
            .channels = optionalInt64(statement, 5),
            .duration_ms = optionalInt64(statement, 6),
            .quick_hash = digestColumn(statement, 7),
            .path = path,
            .has_artwork = statement.columnInt64(9) != 0,
            .release_date = release_date,
            .compilation = if (statement.columnIsNull(11)) null else statement.columnInt64(11) != 0,
        };
    }

    /// Which of a Release's Tracks might supply its cover, in listening order.
    ///
    /// Fills `out` and returns how many ids were written, so the answer is
    /// bounded by the caller's buffer and allocates nothing.
    ///
    /// The predicate is what the *scan* observed — `artwork_mime_type` is not
    /// null and the payload is not empty — rather than what a file turns out to
    /// contain. That is what makes this cheap: a Release whose files carry no
    /// artwork answers with one indexed query and opens no files at all, where
    /// finding out by reading would mean opening every track to learn nothing.
    /// The observation can be stale, so it selects candidates rather than
    /// deciding; the bytes are still read from the file.
    ///
    /// The order is `tracks_position`'s: disc, then track number, then id. It
    /// is a total order over a Release, so the same Release yields the same
    /// cover on every run — which is the whole point when its tracks disagree.
    pub fn artworkCandidatesInto(
        self: *const TrackRepository,
        release_id: i64,
        out: []i64,
    ) !usize {
        if (out.len == 0) return 0;
        var statement = try self.db.prepare(
            \\SELECT tracks.id
            \\FROM tracks
            \\JOIN files ON files.id = COALESCE(
            \\    tracks.preferred_file_id,
            \\    (SELECT id FROM files WHERE recording_id = tracks.recording_id ORDER BY id LIMIT 1)
            \\)
            \\JOIN observed_file_tags ON observed_file_tags.file_id = files.id
            \\WHERE tracks.release_id = ?1
            \\  AND observed_file_tags.artwork_mime_type IS NOT NULL
            \\  AND COALESCE(observed_file_tags.artwork_byte_size, 0) > 0
            \\ORDER BY COALESCE(tracks.disc_number, 1),
            \\         COALESCE(tracks.track_number, -tracks.id),
            \\         tracks.id
            \\LIMIT ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        try statement.bindInt64(2, @intCast(out.len));
        var written: usize = 0;
        while (written < out.len and try statement.step() == .row) : (written += 1)
            out[written] = statement.columnInt64(0);
        return written;
    }

    pub fn count(self: *const TrackRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM tracks;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn countWithRating(self: *const TrackRepository, rating: u8) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM tracks WHERE rating=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, rating);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

const track_columns =
    \\SELECT tracks.id, tracks.title, tracks.artist, tracks.album, tracks.album_artist,
    \\       tracks.duration_ms, tracks.track_number, tracks.disc_number,
    \\       EXISTS(
    \\           SELECT 1 FROM locations
    \\           WHERE locations.file_id = tracks.preferred_file_id
    \\             AND locations.state <> 'missing'
    \\       ),
    \\       tracks.release_id, tracks.artist_id, COALESCE(feedback.score, 0), tracks.recording_id
    \\
;

const feedback_join = "LEFT JOIN feedback ON feedback.recording_id = tracks.recording_id\n";

const TrackFilter = enum { none, artist, release, artist_and_release };

/// A NULL track number sorts after every real one rather than before every
/// one, which is what "the untagged tail of the album" means. The same
/// expression appears in `tracks_sort_*` and `tracks_by_*`, so SQLite can
/// satisfy the ORDER BY from the index instead of building a temp B-tree.
const null_position = "2147483647";

fn positionTerms(comptime direction: SortDirection) []const u8 {
    const suffix = comptime direction.suffix();
    return "COALESCE(tracks.disc_number, 1)" ++ suffix ++
        ", COALESCE(tracks.track_number, " ++ null_position ++ ")" ++ suffix;
}

fn orderTerms(comptime sort: TrackSort, comptime direction: SortDirection) []const u8 {
    const suffix = comptime direction.suffix();
    const tiebreak = ", tracks.id" ++ suffix;
    return switch (sort) {
        .id => "tracks.id" ++ suffix,
        .artist => "tracks.artist COLLATE NOCASE" ++ suffix ++
            ", tracks.album COLLATE NOCASE" ++ suffix ++
            ", " ++ positionTerms(direction) ++ tiebreak,
        .album => "tracks.album COLLATE NOCASE" ++ suffix ++
            ", " ++ positionTerms(direction) ++ tiebreak,
        .title => "tracks.title COLLATE NOCASE" ++ suffix ++ tiebreak,
        .track_number => positionTerms(direction) ++ tiebreak,
        .duration => "tracks.duration_ms" ++ suffix ++ tiebreak,
        .date_added => "tracks.created_at" ++ suffix ++ tiebreak,
    };
}

/// What it means for a Track to be an artist's.
///
/// Credited to them, *or* on a Release they are the album artist of. The
/// narrow definition -- credit only -- leaves 26 artists in a real 2,468-artist
/// library owning an album and no songs, and they are not tag defects that
/// normalization should paper over:
///
///   Enschway              album, with tracks credited "Enschway, Jupe"
///   Grayarea              album, with tracks credited "Grayarea feat. Erik ..."
///   Jesu                  album, with tracks credited "Jesu / Sun Kil Moon"
///   Eli "Paperboy" Reed   album artist quoted, track artist not
///   Hearts & Colors       album artist "&", track artists ","
///   Eddy Grant            33 files in this library carry no ARTIST tag at all
///
/// "Grayarea" and "Grayarea feat. Erik" genuinely are different credited
/// artists; merging them would destroy information. Widening what counts as
/// the artist's own shelf costs nothing and covers every case above, including
/// the untagged files, without guessing at any tag.
const by_artist =
    "(tracks.artist_id = ?3 OR tracks.release_id IN " ++
    "(SELECT id FROM releases WHERE album_artist_id = ?3))";

/// What it means for a Release to be an artist's, mirroring `by_artist`.
///
/// Theirs as album artist, *or* carrying a track credited to them. The strict
/// definition made the two sides disagree: an artist's tracks already included
/// everything on a release they front, so a featured-only artist showed tracks
/// and an empty release list. Widening one side and not the other was an
/// oversight, and the asymmetry was visible the moment a browser put the two
/// lists next to each other.
const by_release_artist =
    "(releases.album_artist_id = ?3 OR releases.id IN " ++
    "(SELECT release_id FROM tracks WHERE tracks.artist_id = ?3))";

fn buildTrackQuery(
    comptime filter: TrackFilter,
    comptime sort: TrackSort,
    comptime direction: SortDirection,
) [:0]const u8 {
    const where = switch (filter) {
        .none => "",
        .artist => "WHERE " ++ by_artist ++ "\n",
        .release => "WHERE tracks.release_id = ?4\n",
        .artist_and_release => "WHERE " ++ by_artist ++ " AND tracks.release_id = ?4\n",
    };
    return track_columns ++ "FROM tracks\n" ++ feedback_join ++ where ++
        "ORDER BY " ++ orderTerms(sort, direction) ++ "\nLIMIT ?1 OFFSET ?2;";
}

/// Every (filter, sort, direction) combination as its own prepared-once
/// statement text. There are 56 of them; concatenating SQL at runtime instead
/// would mean an allocation and a string the caller could influence, and this
/// boundary refuses both on principle.
fn trackQueryText(
    filter: TrackFilter,
    sort: TrackSort,
    direction: SortDirection,
) [:0]const u8 {
    return switch (filter) {
        inline else => |resolved_filter| switch (sort) {
            inline else => |resolved_sort| switch (direction) {
                inline else => |resolved_direction| comptime buildTrackQuery(
                    resolved_filter,
                    resolved_sort,
                    resolved_direction,
                ),
            },
        },
    };
}

fn collectTrackPage(allocator: std.mem.Allocator, statement: sqlite.Statement) !TrackPage {
    var results: std.ArrayList(TrackSummary) = .empty;
    errdefer {
        for (results.items) |item| item.deinit(allocator);
        results.deinit(allocator);
    }
    while (try statement.step() == .row) {
        const title = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(title);
        const artist = try allocator.dupe(u8, statement.columnText(2));
        errdefer allocator.free(artist);
        const album = try allocator.dupe(u8, statement.columnText(3));
        errdefer allocator.free(album);
        const album_artist = try allocator.dupe(u8, statement.columnText(4));
        errdefer allocator.free(album_artist);
        try results.append(allocator, .{
            .id = statement.columnInt64(0),
            .title = title,
            .artist = artist,
            .album = album,
            .album_artist = album_artist,
            .duration_ms = optionalInt64(statement, 5),
            .track_number = optionalInt64(statement, 6),
            .disc_number = optionalInt64(statement, 7),
            .has_playable_file = statement.columnInt64(8) != 0,
            .release_id = optionalInt64(statement, 9),
            .artist_id = optionalInt64(statement, 10),
            .feedback = Feedback.fromScore(statement.columnInt64(11)) orelse return error.InvalidStoredFeedback,
            .recording_id = optionalInt64(statement, 12),
        });
    }
    return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
}

pub const VolumeRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Volumes are identified by a key the platform adapter resolved, never by
    /// `st_dev`, which is not stable across reboots or remounts.
    pub fn ensure(self: *VolumeRepository, input: VolumeInput) !i64 {
        if (input.stable_key.len == 0) return error.InvalidVolumeKey;
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.ensureLocked(input);
    }

    /// Same as `ensure` for a caller that already holds the write lane.
    pub fn ensureLocked(self: *VolumeRepository, input: VolumeInput) !i64 {
        var statement = try self.db.prepare(
            \\INSERT INTO volumes(stable_key, label, last_seen_at)
            \\VALUES (?1, ?2, unixepoch())
            \\ON CONFLICT(stable_key) DO UPDATE SET
            \\    label=CASE WHEN excluded.label='' THEN volumes.label ELSE excluded.label END,
            \\    last_seen_at=excluded.last_seen_at
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindText(1, input.stable_key);
        try statement.bindText(2, input.label);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    pub fn find(self: *const VolumeRepository, stable_key: []const u8) !?i64 {
        var statement = try self.db.prepare("SELECT id FROM volumes WHERE stable_key=?1;");
        defer statement.deinit();
        try statement.bindText(1, stable_key);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    pub fn stableKey(
        self: *const VolumeRepository,
        allocator: std.mem.Allocator,
        volume_id: i64,
    ) !?[]u8 {
        var statement = try self.db.prepare("SELECT stable_key FROM volumes WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        if (try statement.step() != .row) return null;
        return try allocator.dupe(u8, statement.columnText(0));
    }
};

/// Artists as the projection resolves them.
///
/// An Artist as a browse listing shows one: the name to display, the key it is
/// filed under, and how much of the library is theirs.
pub const ArtistSummary = struct {
    id: i64,
    name: []u8,
    /// The folded sort key. A host displays `name` and trusts this only for
    /// section headers, because it is lowercased and article-stripped.
    sort_name: []u8,
    release_count: u32,
    track_count: u32,

    pub fn deinit(self: ArtistSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.sort_name);
    }
};

pub const ArtistPage = struct {
    allocator: std.mem.Allocator,
    items: []ArtistSummary,

    pub fn deinit(self: ArtistPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

/// Identity is the normalized name (`artists.key`), which is what makes
/// `Sigur Rós`, `sigur rós` and `Sigur  Rós` one artist. A MusicBrainz artist
/// id, when the files carry one, outranks that: it recognizes the same artist
/// under a differently spelled name, and it is looked up first.
pub const ArtistRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn ensure(self: *ArtistRepository, input: ArtistUpsert) !?i64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        const id = try self.ensureLocked(input);
        try self.db.exec("COMMIT;");
        return id;
    }

    /// Null for a nameless artist: an empty name is an absent artist, not an
    /// artist whose name happens to be empty, and collapsing every untagged
    /// file onto one shared row would be worse than having no row.
    pub fn ensureLocked(self: *ArtistRepository, input: ArtistUpsert) !?i64 {
        if (input.key.len == 0) return null;
        if (input.musicbrainz_artist_id) |mbid| if (mbid.len != 0) {
            var lookup = try self.db.prepare(
                "SELECT id FROM artists WHERE musicbrainz_artist_id=?1 LIMIT 1;",
            );
            defer lookup.deinit();
            try lookup.bindText(1, mbid);
            if (try lookup.step() == .row) return lookup.columnInt64(0);
        };
        var statement = try self.db.prepare(
            \\INSERT INTO artists(name, key, sort_name, musicbrainz_artist_id)
            \\VALUES (?1, ?2, ?4, ?3)
            \\ON CONFLICT(key) DO UPDATE SET
            \\    name = CASE WHEN excluded.name = '' THEN artists.name ELSE excluded.name END,
            \\    sort_name = CASE
            \\        WHEN excluded.name = '' THEN artists.sort_name ELSE excluded.sort_name END,
            \\    musicbrainz_artist_id =
            \\        COALESCE(artists.musicbrainz_artist_id, excluded.musicbrainz_artist_id)
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindText(1, input.name);
        try statement.bindText(2, input.key);
        try statement.bindOptionalText(3, presentText(input.musicbrainz_artist_id));
        try statement.bindText(4, input.sort_name);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    /// One bounded page of Artists in sort-key order, optionally narrowed to
    /// those whose name contains `filter`.
    ///
    /// `sort_name` is unique enough for a person but not for a database, so
    /// the order ends in `artists.id` — the same total-order rule the Track
    /// listing follows, for the same reason.
    ///
    /// The needle is folded exactly as `artists.key` was, so typing `el-p`
    /// finds `El‐P` spelled with U+2010 and `stevie nicks` finds `Stevie
    /// Nicks`. Matching uses `instr` rather than `LIKE` so a name containing
    /// `%` or `_` is a literal rather than a wildcard, and the fold is done on
    /// the stack because a search box calls this on every keystroke.
    ///
    /// A filtered listing scans the artist table. That is deliberate: an
    /// infix match cannot use an index, the table is 2,468 rows on a
    /// 22,060-track library, and artists grow far more slowly than tracks. If
    /// that ever stops being true the answer is an FTS table, not an index.
    pub fn page(
        self: *const ArtistRepository,
        allocator: std.mem.Allocator,
        query: ArtistQuery,
    ) !ArtistPage {
        if (query.limit == 0 or query.limit > max_page) return error.PageOutOfRange;
        var folded: [text_key.key_buffer_size]u8 = undefined;
        const needle = text_key.normalizeInto(&folded, query.filter);
        var statement = if (needle.len == 0)
            try self.db.prepare(artist_columns ++
                \\FROM artists
                \\ORDER BY artists.sort_name, artists.id
                \\LIMIT ?1 OFFSET ?2;
            )
        else
            try self.db.prepare(artist_columns ++
                \\FROM artists
                \\WHERE instr(artists.key, ?3) > 0
                \\ORDER BY artists.sort_name, artists.id
                \\LIMIT ?1 OFFSET ?2;
            );
        defer statement.deinit();
        try statement.bindInt64(1, query.limit);
        try statement.bindInt64(2, query.offset);
        if (needle.len != 0) try statement.bindText(3, needle);
        return collectArtistPage(allocator, statement);
    }

    /// Counts what `page` would return, sharing its folding and its predicate.
    pub fn countMatching(self: *const ArtistRepository, query: ArtistQuery) !u64 {
        var folded: [text_key.key_buffer_size]u8 = undefined;
        const needle = text_key.normalizeInto(&folded, query.filter);
        if (needle.len == 0) return self.count();
        var statement = try self.db.prepare(
            "SELECT count(*) FROM artists WHERE instr(artists.key, ?1) > 0;",
        );
        defer statement.deinit();
        try statement.bindText(1, needle);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn byId(
        self: *const ArtistRepository,
        allocator: std.mem.Allocator,
        artist_id: i64,
    ) !?ArtistSummary {
        var statement = try self.db.prepare(artist_columns ++
            \\FROM artists WHERE artists.id = ?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, artist_id);
        var found = try collectArtistPage(allocator, statement);
        if (found.items.len == 0) {
            found.deinit();
            return null;
        }
        const first = found.items[0];
        for (found.items[1..]) |extra| extra.deinit(allocator);
        allocator.free(found.items);
        return first;
    }

    pub fn count(self: *const ArtistRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM artists;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

/// The per-artist counts are correlated subqueries rather than a GROUP BY
/// join: each is one range count over `tracks_by_artist` / `releases_by_artist`
/// for a page of at most 512 rows, and a join would have to aggregate the whole
/// table before the LIMIT could apply.
const artist_columns =
    "SELECT artists.id, artists.name, COALESCE(artists.sort_name, ''),\n" ++
    "       (SELECT count(*) FROM releases WHERE " ++ artistOwns(by_release_artist) ++ "),\n" ++
    "       (SELECT count(*) FROM tracks WHERE " ++ artistOwns(by_artist) ++ ")\n";

/// Rewrites one of the shared artist predicates from its bound-parameter form
/// to the correlated form the artist listing needs.
///
/// The counts beside an artist's name had a third copy of both rules, written
/// out with `artists.id` where the predicate has `?3`. They agreed, but the
/// count beside a name and the pane it labels disagreeing is exactly the bug
/// `countMatching` already produced once, and three copies is a worse position
/// than the two that caused it.
fn artistOwns(comptime predicate: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var rest = predicate;
        while (std.mem.indexOf(u8, rest, "?3")) |at| {
            out = out ++ rest[0..at] ++ "artists.id";
            rest = rest[at + 2 ..];
        }
        return out ++ rest;
    }
}

fn collectArtistPage(allocator: std.mem.Allocator, statement: sqlite.Statement) !ArtistPage {
    var results: std.ArrayList(ArtistSummary) = .empty;
    errdefer {
        for (results.items) |item| item.deinit(allocator);
        results.deinit(allocator);
    }
    while (try statement.step() == .row) {
        const name = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(name);
        const sort_name = try allocator.dupe(u8, statement.columnText(2));
        errdefer allocator.free(sort_name);
        try results.append(allocator, .{
            .id = statement.columnInt64(0),
            .name = name,
            .sort_name = sort_name,
            .release_count = @intCast(statement.columnInt64(3)),
            .track_count = @intCast(statement.columnInt64(4)),
        });
    }
    return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
}

/// A Release as a browse listing shows one.
pub const ReleaseSummary = struct {
    id: i64,
    title: []u8,
    album_artist: []u8,
    album_artist_id: ?i64,
    release_date: ?[]const u8,
    is_compilation: bool,
    disc_count: ?i64,
    track_count: u32,
    /// Summed over the Tracks that declare one; a Track whose duration is
    /// unknown contributes nothing rather than a zero-length lie.
    total_duration_ms: i64,

    pub fn deinit(self: ReleaseSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.album_artist);
        if (self.release_date) |date| allocator.free(date);
    }
};

pub const ReleasePage = struct {
    allocator: std.mem.Allocator,
    items: []ReleaseSummary,

    pub fn deinit(self: ReleasePage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

/// One bounded request for a page of Releases, optionally scoped to an Artist.
pub const ArtistQuery = struct {
    /// Free text. Folded the way `artists.key` was folded before matching, so
    /// a search is spelling-insensitive in the same way identity is.
    filter: []const u8 = "",
    limit: u32 = max_page,
    offset: u32 = 0,
};

pub const ReleaseQuery = struct {
    album_artist_id: ?i64 = null,
    sort: ReleaseSort = .title,
    limit: u32 = max_page,
    offset: u32 = 0,
};

/// The orders a Release listing comes in. Each ends in `releases.id`, so it is
/// total and LIMIT/OFFSET paging is exact.
pub const ReleaseSort = enum {
    title,
    /// Album artist, then oldest first within an artist: a shelf.
    artist,
    /// Newest first; undated Releases last.
    year,
    /// Most recently created first.
    recently_added,

    fn terms(comptime self: ReleaseSort) []const u8 {
        return switch (self) {
            .title => "releases.title COLLATE NOCASE, releases.id",
            .artist => "releases.album_artist COLLATE NOCASE, releases.release_date IS NULL, " ++
                "releases.release_date, releases.title COLLATE NOCASE, releases.id",
            .year => "releases.release_date IS NULL, releases.release_date DESC, " ++
                "releases.title COLLATE NOCASE, releases.id",
            .recently_added => "releases.id DESC",
        };
    }
};

const release_columns =
    \\SELECT releases.id, releases.title, releases.album_artist, releases.album_artist_id,
    \\       releases.release_date, releases.is_compilation, releases.disc_count,
    \\       (SELECT count(*) FROM tracks WHERE tracks.release_id = releases.id),
    \\       (SELECT COALESCE(sum(tracks.duration_ms), 0) FROM tracks
    \\        WHERE tracks.release_id = releases.id)
    \\
;

fn collectReleasePage(allocator: std.mem.Allocator, statement: sqlite.Statement) !ReleasePage {
    var results: std.ArrayList(ReleaseSummary) = .empty;
    errdefer {
        for (results.items) |item| item.deinit(allocator);
        results.deinit(allocator);
    }
    while (try statement.step() == .row) {
        const title = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(title);
        const album_artist = try allocator.dupe(u8, statement.columnText(2));
        errdefer allocator.free(album_artist);
        const release_date = try dupeNullable(allocator, statement, 4);
        errdefer if (release_date) |date| allocator.free(date);
        try results.append(allocator, .{
            .id = statement.columnInt64(0),
            .title = title,
            .album_artist = album_artist,
            .album_artist_id = optionalInt64(statement, 3),
            .release_date = release_date,
            .is_compilation = statement.columnInt64(5) != 0,
            .disc_count = optionalInt64(statement, 6),
            .track_count = @intCast(statement.columnInt64(7)),
            .total_duration_ms = statement.columnInt64(8),
        });
    }
    return .{ .allocator = allocator, .items = try results.toOwnedSlice(allocator) };
}

/// Releases as the projection resolves them, keyed by `release_key`.
pub const ReleaseRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn upsert(self: *ReleaseRepository, input: ReleaseUpsert) !i64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        const id = try self.upsertLocked(input);
        try self.db.exec("COMMIT;");
        return id;
    }

    /// `disc_count` only ever grows: one folder of a two-disc set projected on
    /// its own must not shrink a release the other folder already widened.
    pub fn upsertLocked(self: *ReleaseRepository, input: ReleaseUpsert) !i64 {
        var statement = try self.db.prepare(
            \\INSERT INTO releases(
            \\    title, album_artist, release_date, is_compilation,
            \\    disc_count, release_key, musicbrainz_release_id, album_artist_id
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            \\ON CONFLICT(release_key) DO UPDATE SET
            \\    title=excluded.title,
            \\    album_artist=excluded.album_artist,
            \\    album_artist_id=excluded.album_artist_id,
            \\    release_date=COALESCE(excluded.release_date, releases.release_date),
            \\    is_compilation=excluded.is_compilation,
            \\    disc_count=max(
            \\        COALESCE(excluded.disc_count, 1),
            \\        COALESCE(releases.disc_count, 1)
            \\    ),
            \\    musicbrainz_release_id=COALESCE(
            \\        excluded.musicbrainz_release_id,
            \\        releases.musicbrainz_release_id
            \\    )
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindText(1, input.title);
        try statement.bindText(2, input.album_artist);
        try statement.bindOptionalText(3, presentText(input.release_date));
        try statement.bindInt64(4, @intFromBool(input.is_compilation));
        try statement.bindOptionalInt64(5, input.disc_count);
        try statement.bindText(6, input.release_key);
        try statement.bindOptionalText(7, presentText(input.musicbrainz_release_id));
        try statement.bindOptionalInt64(8, input.album_artist_id);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    /// One bounded page of Releases, optionally scoped to one Artist, ordered
    /// by title with `releases.id` as the tiebreaker so paging is total.
    pub fn page(
        self: *const ReleaseRepository,
        allocator: std.mem.Allocator,
        query: ReleaseQuery,
    ) !ReleasePage {
        if (query.limit == 0 or query.limit > max_page) return error.PageOutOfRange;
        var statement = switch (query.sort) {
            inline else => |sort| if (query.album_artist_id == null)
                try self.db.prepare(release_columns ++
                    "FROM releases\nORDER BY " ++ comptime sort.terms() ++ "\nLIMIT ?1 OFFSET ?2;")
            else
                try self.db.prepare(release_columns ++
                    "FROM releases\nWHERE " ++ by_release_artist ++
                    "\nORDER BY " ++ comptime sort.terms() ++ "\nLIMIT ?1 OFFSET ?2;"),
        };
        defer statement.deinit();
        try statement.bindInt64(1, query.limit);
        try statement.bindInt64(2, query.offset);
        if (query.album_artist_id) |artist_id| try statement.bindInt64(3, artist_id);
        return collectReleasePage(allocator, statement);
    }

    /// Counts what `page` would return. Shares `by_release_artist` with it
    /// rather than restating the predicate: `TrackRepository.countMatching`
    /// had its own copy and drifted from the page it counted the moment the
    /// definition widened, so the list showed rows the count above it denied.
    pub fn countMatching(self: *const ReleaseRepository, query: ReleaseQuery) !u64 {
        var statement = try self.db.prepare(
            "SELECT count(*) FROM releases\nWHERE ?3 IS NULL OR " ++
                by_release_artist ++ ";",
        );
        defer statement.deinit();
        try statement.bindOptionalInt64(3, query.album_artist_id);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn byId(
        self: *const ReleaseRepository,
        allocator: std.mem.Allocator,
        release_id: i64,
    ) !?ReleaseSummary {
        var statement = try self.db.prepare(release_columns ++
            \\FROM releases WHERE releases.id = ?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        var found = try collectReleasePage(allocator, statement);
        if (found.items.len == 0) {
            found.deinit();
            return null;
        }
        const first = found.items[0];
        for (found.items[1..]) |extra| extra.deinit(allocator);
        allocator.free(found.items);
        return first;
    }

    pub fn count(self: *const ReleaseRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM releases;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

/// Recordings — performances — which files encode and tracks position.
///
/// The schema carries no key column for a recording, so the projection keeps
/// the mapping itself and reuses whatever `files.recording_id` already says.
/// This repository therefore inserts and updates; it never resolves.
pub const RecordingRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn insertLocked(self: *RecordingRepository, input: RecordingInput) !i64 {
        var statement = try self.db.prepare(
            "INSERT INTO recordings(title, duration_ms) VALUES (?1, ?2) RETURNING id;",
        );
        defer statement.deinit();
        try statement.bindText(1, input.title);
        try statement.bindOptionalInt64(2, input.duration_ms);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    pub fn updateLocked(self: *RecordingRepository, id: i64, input: RecordingInput) !void {
        var statement = try self.db.prepare(
            "UPDATE recordings SET title=?1, duration_ms=COALESCE(?2, duration_ms) WHERE id=?3;",
        );
        defer statement.deinit();
        try statement.bindText(1, input.title);
        try statement.bindOptionalInt64(2, input.duration_ms);
        try statement.bindInt64(3, id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    pub fn count(self: *const RecordingRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM recordings;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

pub const RootRemoval = struct {
    allocator: std.mem.Allocator,
    files_forgotten: u64,
    tracks_removed: u64,
    /// Files that were also located outside the removed root and so remain.
    surviving_file_ids: []i64,

    pub fn deinit(self: RootRemoval) void {
        self.allocator.free(self.surviving_file_ids);
    }
};

pub const OrphanPruneCounts = struct {
    releases: u64 = 0,
    artists: u64 = 0,
};

/// Deletes the candidate releases no track references, then the artists among
/// the candidates and those releases' album artists that no track or release
/// references. Runs inside the caller's transaction; candidates may repeat.
pub fn pruneOrphanedReleasesAndArtists(
    db: sqlite.Database,
    allocator: std.mem.Allocator,
    release_candidates: []const i64,
    artist_candidates: []const i64,
) !OrphanPruneCounts {
    var counts: OrphanPruneCounts = .{};
    if (release_candidates.len == 0) return counts;

    var artists: std.ArrayList(i64) = .empty;
    defer artists.deinit(allocator);
    try artists.appendSlice(allocator, artist_candidates);

    var release_in_use = try db.prepare("SELECT 1 FROM tracks WHERE release_id = ?1 LIMIT 1;");
    defer release_in_use.deinit();
    var release_artist = try db.prepare("SELECT album_artist_id FROM releases WHERE id = ?1;");
    defer release_artist.deinit();
    var delete_release = try db.prepare("DELETE FROM releases WHERE id = ?1;");
    defer delete_release.deinit();
    for (release_candidates) |release_id| {
        try release_in_use.bindInt64(1, release_id);
        const in_use = try release_in_use.step() == .row;
        try release_in_use.reset();
        if (in_use) continue;
        try release_artist.bindInt64(1, release_id);
        const found = try release_artist.step() == .row;
        if (found and !release_artist.columnIsNull(0)) try artists.append(allocator, release_artist.columnInt64(0));
        try release_artist.reset();
        if (!found) continue;
        try delete_release.bindInt64(1, release_id);
        if (try delete_release.step() != .done) return error.SqlFailed;
        try delete_release.reset();
        counts.releases += 1;
    }

    var artist_in_use = try db.prepare(
        \\SELECT 1 WHERE EXISTS (SELECT 1 FROM tracks WHERE artist_id = ?1)
        \\   OR EXISTS (SELECT 1 FROM releases WHERE album_artist_id = ?1);
    );
    defer artist_in_use.deinit();
    var delete_artist = try db.prepare("DELETE FROM artists WHERE id = ?1;");
    defer delete_artist.deinit();
    for (artists.items) |artist_id| {
        try artist_in_use.bindInt64(1, artist_id);
        const in_use = try artist_in_use.step() == .row;
        try artist_in_use.reset();
        if (in_use) continue;
        try delete_artist.bindInt64(1, artist_id);
        if (try delete_artist.step() != .done) return error.SqlFailed;
        try delete_artist.reset();
        if (db.changes() == 1) counts.artists += 1;
    }
    return counts;
}

pub const LibraryRootRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn add(self: *LibraryRootRepository, volume_id: i64, path: []const u8) !i64 {
        if (path.len == 0) return error.InvalidLibraryRoot;
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.addLocked(volume_id, path);
    }

    pub fn addLocked(self: *LibraryRootRepository, volume_id: i64, path: []const u8) !i64 {
        var statement = try self.db.prepare(
            \\INSERT INTO library_roots(volume_id, path, enabled) VALUES (?1, ?2, 1)
            \\ON CONFLICT(path) DO UPDATE SET volume_id=excluded.volume_id
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindText(2, path);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    /// Forgets the root and everything that exists only under it, in one
    /// transaction. Only rows are deleted; no file on disk is touched.
    ///
    /// A file with a location under another root, or under no root, survives
    /// and is returned so the caller can reproject it: its tracks may have
    /// been backed by a sibling that is now gone.
    pub fn remove(
        self: *LibraryRootRepository,
        allocator: std.mem.Allocator,
        root_id: i64,
    ) !RootRemoval {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};

        {
            var exists = try self.db.prepare("SELECT 1 FROM library_roots WHERE id=?1;");
            defer exists.deinit();
            try exists.bindInt64(1, root_id);
            if (try exists.step() != .row) return error.UnknownRoot;
        }

        try self.db.exec("CREATE TEMP TABLE forgotten_files(id INTEGER PRIMARY KEY);");
        const files_forgotten = try self.execWithRoot(
            \\INSERT INTO temp.forgotten_files(id)
            \\SELECT DISTINCT file_id FROM locations AS under
            \\WHERE root_id = ?1 AND NOT EXISTS (
            \\    SELECT 1 FROM locations AS elsewhere
            \\    WHERE elsewhere.file_id = under.file_id AND elsewhere.root_id IS NOT ?1
            \\);
        , root_id);

        var surviving: std.ArrayList(i64) = .empty;
        errdefer surviving.deinit(allocator);
        {
            var statement = try self.db.prepare(
                \\SELECT DISTINCT file_id FROM locations
                \\WHERE root_id = ?1 AND file_id NOT IN (SELECT id FROM temp.forgotten_files);
            );
            defer statement.deinit();
            try statement.bindInt64(1, root_id);
            while (try statement.step() == .row) try surviving.append(allocator, statement.columnInt64(0));
        }

        var releases: std.ArrayList(i64) = .empty;
        defer releases.deinit(allocator);
        var artists: std.ArrayList(i64) = .empty;
        defer artists.deinit(allocator);
        {
            var statement = try self.db.prepare(
                \\SELECT DISTINCT release_id, artist_id FROM tracks
                \\WHERE preferred_file_id IN (SELECT id FROM temp.forgotten_files);
            );
            defer statement.deinit();
            while (try statement.step() == .row) {
                if (!statement.columnIsNull(0)) try releases.append(allocator, statement.columnInt64(0));
                if (!statement.columnIsNull(1)) try artists.append(allocator, statement.columnInt64(1));
            }
        }

        try self.db.exec("DELETE FROM tracks WHERE preferred_file_id IN (SELECT id FROM temp.forgotten_files);");
        const tracks_removed = self.db.changes();
        _ = try pruneOrphanedReleasesAndArtists(self.db, allocator, releases.items, artists.items);

        try self.db.exec("UPDATE mutation_operations SET file_id = NULL WHERE file_id IN (SELECT id FROM temp.forgotten_files);");
        _ = try self.execWithRoot("DELETE FROM locations WHERE root_id = ?1;", root_id);
        try self.db.exec("DELETE FROM files WHERE id IN (SELECT id FROM temp.forgotten_files);");
        _ = try self.execWithRoot("DELETE FROM library_roots WHERE id = ?1;", root_id);
        try self.db.exec("DROP TABLE temp.forgotten_files;");
        try self.db.exec("COMMIT;");
        return .{
            .allocator = allocator,
            .files_forgotten = files_forgotten,
            .tracks_removed = tracks_removed,
            .surviving_file_ids = try surviving.toOwnedSlice(allocator),
        };
    }

    fn execWithRoot(self: *LibraryRootRepository, sql: [:0]const u8, root_id: i64) !u64 {
        var statement = try self.db.prepare(sql);
        defer statement.deinit();
        try statement.bindInt64(1, root_id);
        if (try statement.step() != .done) return error.SqlFailed;
        return self.db.changes();
    }

    pub fn setEnabled(self: *LibraryRootRepository, root_id: i64, enabled: bool) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare("UPDATE library_roots SET enabled=?1 WHERE id=?2;");
        defer statement.deinit();
        try statement.bindInt64(1, @intFromBool(enabled));
        try statement.bindInt64(2, root_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    pub fn list(
        self: *const LibraryRootRepository,
        allocator: std.mem.Allocator,
    ) !LibraryRootPage {
        var statement = try self.db.prepare(
            "SELECT id, volume_id, path, enabled FROM library_roots ORDER BY id;",
        );
        defer statement.deinit();
        var roots: std.ArrayList(LibraryRoot) = .empty;
        errdefer {
            for (roots.items) |root| root.deinit(allocator);
            roots.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const path = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(path);
            try roots.append(allocator, .{
                .id = statement.columnInt64(0),
                .volume_id = statement.columnInt64(1),
                .path = path,
                .enabled = statement.columnInt64(3) != 0,
            });
        }
        return .{ .allocator = allocator, .items = try roots.toOwnedSlice(allocator) };
    }

    /// Bounded page, for the ABI: a host never receives an unbounded list, even
    /// of something as small as a root set.
    pub fn page(
        self: *const LibraryRootRepository,
        allocator: std.mem.Allocator,
        limit: u32,
        offset: u32,
    ) !LibraryRootPage {
        var statement = try self.db.prepare(
            \\SELECT id, volume_id, path, enabled FROM library_roots
            \\ORDER BY id LIMIT ?1 OFFSET ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        try statement.bindInt64(2, offset);
        var roots: std.ArrayList(LibraryRoot) = .empty;
        errdefer {
            for (roots.items) |root| root.deinit(allocator);
            roots.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const path = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(path);
            try roots.append(allocator, .{
                .id = statement.columnInt64(0),
                .volume_id = statement.columnInt64(1),
                .path = path,
                .enabled = statement.columnInt64(3) != 0,
            });
        }
        return .{ .allocator = allocator, .items = try roots.toOwnedSlice(allocator) };
    }
};

pub const ScanRunRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Opens a run with the next generation for this root. Generations are
    /// per-root and monotonic so a sweep can name exactly the locations this
    /// run did not reach.
    pub fn begin(self: *ScanRunRepository, root_id: i64) !ScanRun {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO scan_runs(root_id, generation, started_at, state)
            \\VALUES (
            \\    ?1,
            \\    COALESCE((SELECT max(generation) FROM scan_runs WHERE root_id=?1), 0) + 1,
            \\    unixepoch(),
            \\    'running'
            \\) RETURNING id, generation;
        );
        defer statement.deinit();
        try statement.bindInt64(1, root_id);
        if (try statement.step() != .row) return error.SqlFailed;
        return .{
            .id = statement.columnInt64(0),
            .root_id = root_id,
            .generation = statement.columnInt64(1),
        };
    }

    pub fn finish(
        self: *ScanRunRepository,
        run_id: i64,
        result: ScanRunState,
        counters: ScanCounters,
    ) !void {
        if (result == .running) return error.InvalidScanRunState;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE scan_runs SET state=?1, finished_at=unixepoch(),
            \\    files_seen=?2, changed=?3, unchanged=?4, unsupported=?5, errors=?6
            \\WHERE id=?7 AND state='running';
        );
        defer statement.deinit();
        try statement.bindText(1, result.text());
        try statement.bindInt64(2, @intCast(counters.files_seen));
        try statement.bindInt64(3, @intCast(counters.changed));
        try statement.bindInt64(4, @intCast(counters.unchanged));
        try statement.bindInt64(5, @intCast(counters.unsupported));
        try statement.bindInt64(6, @intCast(counters.errors));
        try statement.bindInt64(7, run_id);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleScanRun;
    }

    pub fn cancel(self: *ScanRunRepository, run_id: i64, counters: ScanCounters) !void {
        return self.finish(run_id, .cancelled, counters);
    }

    pub fn outcome(self: *const ScanRunRepository, run_id: i64) !ScanRunState {
        var statement = try self.db.prepare("SELECT state FROM scan_runs WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, run_id);
        if (try statement.step() != .row) return error.ScanRunNotFound;
        return ScanRunState.parse(statement.columnText(0)) orelse
            error.InvalidStoredScanRunState;
    }
};

/// Byte facts about one encoding, and the identity tiers that re-find it.
pub const FileRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn create(self: *FileRepository, input: FileUpsert) !i64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.createLocked(input);
    }

    pub fn createLocked(self: *FileRepository, input: FileUpsert) !i64 {
        var statement = try self.db.prepare(
            \\INSERT INTO files(
            \\    audio_format, codec, size_bytes, sample_rate, bit_depth, channels,
            \\    duration_ms, quick_hash, audio_hash, content_hash, first_seen_at
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, unixepoch())
            \\RETURNING id;
        );
        defer statement.deinit();
        try bindFile(statement, input);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    pub fn update(self: *FileRepository, file_id: i64, input: FileUpsert) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.updateLocked(file_id, input);
    }

    pub fn updateLocked(self: *FileRepository, file_id: i64, input: FileUpsert) !void {
        var statement = try self.db.prepare(
            \\UPDATE files SET audio_format=?1, codec=?2, size_bytes=?3, sample_rate=?4,
            \\    bit_depth=?5, channels=?6, duration_ms=?7, quick_hash=?8,
            \\    audio_hash=COALESCE(?9, audio_hash), content_hash=COALESCE(?10, content_hash)
            \\WHERE id=?11;
        );
        defer statement.deinit();
        try bindFile(statement, input);
        try statement.bindInt64(11, file_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Records what a probe read from a file's headers, and nothing else.
    ///
    /// `update` would also rewrite `audio_format`, `size_bytes` and
    /// `quick_hash` from a caller that never computed them. A backfill reads
    /// headers only, so it writes only what headers say and leaves the
    /// scanner's observations of the bytes alone.
    pub fn updatePropertiesLocked(
        self: *FileRepository,
        file_id: i64,
        input: FilePropertyUpdate,
    ) !void {
        var statement = try self.db.prepare(
            \\UPDATE files SET codec=?1, sample_rate=?2, bit_depth=?3, channels=?4,
            \\    duration_ms=?5, audio_format=COALESCE(?7, audio_format)
            \\WHERE id=?6;
        );
        defer statement.deinit();
        try statement.bindText(1, input.codec);
        try statement.bindOptionalInt64(2, input.sample_rate);
        try statement.bindOptionalInt64(3, input.bit_depth);
        try statement.bindOptionalInt64(4, input.channels);
        try statement.bindOptionalInt64(5, input.duration_ms);
        try statement.bindInt64(6, file_id);
        try statement.bindOptionalInt64(7, input.audio_format);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// One bounded page of files that still owe a probe, past `after_id`.
    ///
    /// The cursor is the file id rather than an offset, so a page whose rows
    /// the caller could not repair does not make the next page re-serve them,
    /// and a run interrupted half way resumes from where it stopped without
    /// any checkpoint of its own. `all` re-serves every file regardless of
    /// what it already declares, which is the force mode's whole meaning.
    ///
    /// Each row carries the location a reader should open: a present one in
    /// preference to an unverified one, and a missing one only if there is
    /// nothing better, because a drive that is back gets probed rather than
    /// skipped.
    pub fn incompletePropertiesPage(
        self: *const FileRepository,
        allocator: std.mem.Allocator,
        after_id: i64,
        limit: u32,
        all: bool,
    ) !IncompleteFilePage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(if (all)
            "SELECT files.id, " ++ location_uri_column ++
                " FROM files WHERE files.id > ?1 ORDER BY files.id LIMIT ?2;"
        else
            "SELECT files.id, " ++ location_uri_column ++
                " FROM files WHERE files.id > ?1 AND (" ++
                incomplete_properties_predicate ++ ") ORDER BY files.id LIMIT ?2;");
        defer statement.deinit();
        try statement.bindInt64(1, after_id);
        try statement.bindInt64(2, limit);

        var items: std.ArrayList(IncompleteFile) = .empty;
        errdefer {
            for (items.items) |item| allocator.free(item.uri);
            items.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const uri = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(uri);
            try items.append(allocator, .{ .id = statement.columnInt64(0), .uri = uri });
        }
        return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    }

    /// How many files still owe a probe. A backfill, unlike a filesystem walk,
    /// has an honest denominator before it starts, so its job snapshot reports
    /// a fraction rather than a bare count.
    pub fn incompletePropertiesCount(self: *const FileRepository, all: bool) !u64 {
        var statement = try self.db.prepare(if (all)
            "SELECT count(*) FROM files;"
        else
            "SELECT count(*) FROM files WHERE " ++ incomplete_properties_predicate ++ ";");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// One bounded page of files that still owe the measurement `selector`
    /// names, past `after_id`.
    ///
    /// The cursor is the file id for the same reason the backfill's is: a row
    /// this run declines to measure does not make the next page re-serve it,
    /// and an interrupted run resumes from where it stopped with no checkpoint
    /// of its own. Which rows still owe work is a property of the rows.
    pub fn unanalyzedPage(
        self: *const FileRepository,
        allocator: std.mem.Allocator,
        after_id: i64,
        limit: u32,
        selector: AnalysisSelector,
    ) !AnalysisCandidatePage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(
            "SELECT files.id, files.quick_hash, " ++ location_uri_column ++
                " FROM files WHERE files.id > ?1 AND (" ++ unanalyzed_predicate ++
                ") ORDER BY files.id LIMIT ?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, after_id);
        try statement.bindInt64(2, limit);
        try bindAnalysisSelector(statement, &selector);

        var items: std.ArrayList(AnalysisCandidate) = .empty;
        errdefer {
            for (items.items) |item| allocator.free(item.uri);
            items.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const uri = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(uri);
            try items.append(allocator, .{
                .id = statement.columnInt64(0),
                .source_identity = digestColumn(statement, 1),
                .uri = uri,
            });
        }
        return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    }

    /// How many files still owe that measurement. Like the backfill and unlike
    /// a filesystem walk, a library-wide analysis has an honest denominator
    /// before it starts, so its job snapshot reports a fraction.
    pub fn unanalyzedCount(
        self: *const FileRepository,
        selector: AnalysisSelector,
    ) !u64 {
        var statement = try self.db.prepare(
            "SELECT count(*) FROM files WHERE " ++ unanalyzed_predicate ++ ";",
        );
        defer statement.deinit();
        // The count asks the same question with no cursor and no limit, so ?1
        // and ?2 are simply unbound; SQLite reads an unbound parameter as
        // NULL, and neither appears in this statement.
        try bindAnalysisSelector(statement, &selector);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// One bounded page of files for a duplicate scan, past `after_id`.
    ///
    /// Deliberately unfiltered. A scan that selected only files carrying an
    /// `audio_hash` would report "no duplicates" on a library nobody has
    /// analyzed, which is a lie of omission rather than an answer; and it
    /// would never revisit a file to retire a finding that no longer holds.
    /// Every row is examined, and the ones nothing can be said about are
    /// counted.
    pub fn duplicateCandidatePage(
        self: *const FileRepository,
        allocator: std.mem.Allocator,
        after_id: i64,
        limit: u32,
    ) !DuplicateCandidatePage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(
            "SELECT id, audio_hash, duration_ms, quick_hash FROM files" ++
                " WHERE id > ?1 ORDER BY id LIMIT ?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, after_id);
        try statement.bindInt64(2, limit);

        var items: std.ArrayList(DuplicateCandidate) = .empty;
        errdefer items.deinit(allocator);
        while (try statement.step() == .row) try items.append(allocator, .{
            .id = statement.columnInt64(0),
            .audio_hash = audioHashColumn(statement, 1),
            .duration_ms = if (statement.columnIsNull(2)) null else statement.columnInt64(2),
            .source_identity = digestColumn(statement, 3),
        });
        return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    }

    /// The other files whose decoded audio hashes to exactly this, into a
    /// caller-owned buffer.
    ///
    /// This is the exact-duplicate bucket, and it is a search of
    /// `files_audio_hash` rather than a comparison against anything: two files
    /// whose decoded samples hash identically *are* the same audio, whatever
    /// their containers, bitrates or tags say.
    ///
    /// The buffer is the caller's and the query is limited to its length, so
    /// one pathological bucket cannot allocate without bound. A returned count
    /// equal to `buffer.len` means the bucket was truncated.
    pub fn audioHashPeersInto(
        self: *const FileRepository,
        buffer: []i64,
        audio_hash: []const u8,
        exclude_id: i64,
    ) !usize {
        if (buffer.len == 0) return 0;
        var statement = try self.db.prepare(
            "SELECT id FROM files WHERE audio_hash = ?1 AND id <> ?2 ORDER BY id LIMIT ?3;",
        );
        defer statement.deinit();
        try statement.bindBlob(1, audio_hash);
        try statement.bindInt64(2, exclude_id);
        try statement.bindInt64(3, @intCast(buffer.len));
        var found: usize = 0;
        while (try statement.step() == .row) : (found += 1) buffer[found] = statement.columnInt64(0);
        return found;
    }

    /// The other files whose duration falls inside `[low, high]`, into a
    /// caller-owned buffer.
    ///
    /// This is the *plausible* bucket, the one a temporal fingerprint is then
    /// compared inside. Length is the cheapest necessary condition for two
    /// files being the same recording and the only one an index can answer, so
    /// it decides who is worth comparing; the fingerprint decides whether they
    /// match. Served by `files_duration`, which covers both columns.
    ///
    /// Bounded exactly like `audioHashPeersInto`, and for the same reason.
    pub fn durationPeersInto(
        self: *const FileRepository,
        buffer: []DuplicatePeer,
        low: i64,
        high: i64,
        exclude_id: i64,
    ) !usize {
        if (buffer.len == 0) return 0;
        var statement = try self.db.prepare(
            "SELECT id, quick_hash, audio_hash FROM files" ++
                " WHERE duration_ms >= ?1 AND duration_ms <= ?2" ++
                " AND id <> ?3 ORDER BY duration_ms, id LIMIT ?4;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, low);
        try statement.bindInt64(2, high);
        try statement.bindInt64(3, exclude_id);
        try statement.bindInt64(4, @intCast(buffer.len));
        var found: usize = 0;
        while (try statement.step() == .row) : (found += 1) buffer[found] = .{
            .id = statement.columnInt64(0),
            .source_identity = digestColumn(statement, 1),
            .audio_hash = audioHashColumn(statement, 2),
        };
        return found;
    }

    /// Tier 4 of the identity cascade, written by the analysis job rather than
    /// the scanner: a hash of the audio payload alone survives Orca's own tag
    /// writes, which change size, mtime and quick hash but not the audio.
    pub fn setAudioHash(self: *FileRepository, file_id: i64, digest: []const u8) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare("UPDATE files SET audio_hash=?1 WHERE id=?2;");
        defer statement.deinit();
        try statement.bindBlob(1, digest);
        try statement.bindInt64(2, file_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// The same write from inside a caller's transaction, so an analysis pass
    /// can commit a file's identity, its results and its health together.
    pub fn setAudioHashLocked(
        self: *FileRepository,
        file_id: i64,
        digest: []const u8,
    ) !void {
        var statement = try self.db.prepare("UPDATE files SET audio_hash=?1 WHERE id=?2;");
        defer statement.deinit();
        try statement.bindBlob(1, digest);
        try statement.bindInt64(2, file_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    pub fn stampGeneration(self: *FileRepository, file_id: i64, generation: i64) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            "UPDATE files SET last_scan_generation=?1 WHERE id=?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, generation);
        try statement.bindInt64(2, file_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Tier 1: the same path on the same volume.
    pub fn resolveByUri(
        self: *const FileRepository,
        volume_id: i64,
        uri: []const u8,
    ) !?i64 {
        var statement = try self.db.prepare(
            "SELECT file_id FROM locations WHERE volume_id=?1 AND uri=?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindText(2, uri);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    /// Tier 2: the same inode, size and mtime somewhere else on the volume —
    /// a rename or a move within one filesystem.
    pub fn resolveByIdentity(self: *const FileRepository, key: StorageIdentityKey) !?i64 {
        var statement = try self.db.prepare(
            \\SELECT file_id FROM locations
            \\WHERE volume_id=?1 AND native_inode=?2 AND size_bytes=?3 AND modified_ns=?4
            \\ORDER BY CASE state WHEN 'missing' THEN 0 ELSE 1 END, id
            \\LIMIT 1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, key.volume_id);
        try statement.bindInt64(2, key.native_inode);
        try statement.bindInt64(3, key.size_bytes);
        try statement.bindInt64(4, key.modified_ns);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    /// Tier 3: the same leading and trailing bytes and length — a copy, a
    /// cross-volume move, or a restore from backup.
    pub fn resolveByQuickHash(self: *const FileRepository, digest: []const u8) !?i64 {
        var statement = try self.db.prepare(
            "SELECT id FROM files WHERE quick_hash=?1 ORDER BY id LIMIT 1;",
        );
        defer statement.deinit();
        try statement.bindBlob(1, digest);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    /// Sweep after a completed, uncancelled run: locations under this root that
    /// the run did not reach become `missing`. Never a delete — an unmounted
    /// drive must not eat a library.
    pub fn markMissingBelowGeneration(
        self: *FileRepository,
        root_id: i64,
        generation: i64,
    ) !u64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE locations SET state='missing', missing_since=unixepoch()
            \\WHERE root_id=?1 AND last_seen_generation<?2 AND state<>'missing';
        );
        defer statement.deinit();
        try statement.bindInt64(1, root_id);
        try statement.bindInt64(2, generation);
        if (try statement.step() != .done) return error.SqlFailed;
        return self.db.changes();
    }

    /// Attach a file to the performance it encodes. Written only by the
    /// projection: a file is an encoding, and which performance it encodes is
    /// a resolution decision, not a filesystem observation.
    pub fn setRecordingLocked(
        self: *FileRepository,
        file_id: i64,
        recording_id: ?i64,
    ) !void {
        var statement = try self.db.prepare(
            "UPDATE files SET recording_id=?1 WHERE id=?2 AND recording_id IS NOT ?1;",
        );
        defer statement.deinit();
        try statement.bindOptionalInt64(1, recording_id);
        try statement.bindInt64(2, file_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    pub fn count(self: *const FileRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM files;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

fn bindFile(statement: sqlite.Statement, input: FileUpsert) !void {
    try statement.bindInt64(1, input.audio_format);
    try statement.bindText(2, input.codec);
    try statement.bindInt64(3, input.size_bytes);
    try statement.bindOptionalInt64(4, input.sample_rate);
    try statement.bindOptionalInt64(5, input.bit_depth);
    try statement.bindOptionalInt64(6, input.channels);
    try statement.bindOptionalInt64(7, input.duration_ms);
    try bindOptionalBlob(statement, 8, input.quick_hash);
    try bindOptionalBlob(statement, 9, input.audio_hash);
    try bindOptionalBlob(statement, 10, input.content_hash);
}

pub const LocationRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn upsert(self: *LocationRepository, input: LocationUpsert) !i64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.upsertLocked(input);
    }

    pub fn upsertLocked(self: *LocationRepository, input: LocationUpsert) !i64 {
        var statement = try self.db.prepare(
            \\INSERT INTO locations(
            \\    file_id, volume_id, root_id, uri, native_device, native_inode,
            \\    size_bytes, modified_ns, state, missing_since, last_seen_generation
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, NULL, ?10)
            \\ON CONFLICT(volume_id, uri) DO UPDATE SET
            \\    file_id=excluded.file_id,
            \\    root_id=COALESCE(excluded.root_id, locations.root_id),
            \\    native_device=excluded.native_device,
            \\    native_inode=excluded.native_inode,
            \\    size_bytes=excluded.size_bytes,
            \\    modified_ns=excluded.modified_ns,
            \\    state=excluded.state,
            \\    missing_since=NULL,
            \\    last_seen_generation=excluded.last_seen_generation
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindInt64(1, input.file_id);
        try statement.bindInt64(2, input.volume_id);
        try statement.bindOptionalInt64(3, input.root_id);
        try statement.bindText(4, input.uri);
        try statement.bindOptionalInt64(5, input.native_device);
        try statement.bindOptionalInt64(6, input.native_inode);
        try statement.bindInt64(7, input.size_bytes);
        try statement.bindInt64(8, input.modified_ns);
        try statement.bindText(9, input.state.text());
        try statement.bindInt64(10, input.last_seen_generation);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    /// Move locations a migration left on the fallback volume onto the real
    /// volume and root a scan just resolved.
    ///
    /// A migration cannot know what volume a path lives on — the storage may
    /// not even be mounted — so it parks every migrated location on the
    /// `legacy` volume in the `unverified` state. The first scan that resolves
    /// a real volume for a root claims the ones under it. Without this the
    /// scanner's `(volume_id, uri)` lookup misses every migrated row and
    /// re-imports the entire library as new files, silently orphaning every
    /// preserved lock, analysis result and health issue on the old rows.
    ///
    /// `UPDATE OR IGNORE` because a location may already exist at that URI on
    /// the target volume; the live row wins and the legacy row is left for the
    /// operator to see rather than being destroyed here.
    pub fn claimLegacyLocations(
        self: *LocationRepository,
        legacy_volume_id: i64,
        volume_id: i64,
        root_id: i64,
        root_path: []const u8,
    ) !u64 {
        if (legacy_volume_id == volume_id) return 0;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE OR IGNORE locations SET volume_id=?1, root_id=?2
            \\WHERE volume_id=?3 AND state='unverified'
            \\  AND (uri=?4 OR substr(uri, 1, length(?4) + 1) = ?4 || '/');
        );
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindInt64(2, root_id);
        try statement.bindInt64(3, legacy_volume_id);
        try statement.bindText(4, root_path);
        if (try statement.step() != .done) return error.SqlFailed;
        return self.db.changes();
    }

    /// A move within a volume: the uri changes and `files.id` does not, so
    /// metadata, locks, analysis and health attached to the file survive.
    pub fn move(self: *LocationRepository, location_id: i64, destination: []const u8) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE locations SET uri=?1, state='present', missing_since=NULL
            \\WHERE id=?2;
        );
        defer statement.deinit();
        try statement.bindText(1, destination);
        try statement.bindInt64(2, location_id);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.LocationNotFound;
    }

    pub fn find(self: *const LocationRepository, volume_id: i64, path: []const u8) !?i64 {
        var statement = try self.db.prepare(
            "SELECT id FROM locations WHERE volume_id=?1 AND uri=?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindText(2, path);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    /// Tier 1 of the identity cascade in one query: this path, on this volume,
    /// with the filesystem facts a scan already recorded. A hit means no
    /// format, tag or hash work is needed for this entry at all.
    ///
    /// Only a `present` location can be unchanged. An `unverified` one — every
    /// location a migration produced — has never been confirmed by a scan and
    /// carries whatever tags the old schema had room for, so it is re-observed
    /// once and promoted rather than trusted on sight.
    /// The id of the present Location this identity already describes, or null
    /// when the entry is new or its bytes changed.
    ///
    /// The caller must stamp what this returns through `markSeenLocked`. A scan
    /// that skips an unchanged file without recording that it *saw* it leaves
    /// the Location below the run's generation, and the post-run sweep then
    /// marks a file that is sitting right there as `missing`.
    pub fn unchangedLocationId(
        self: *const LocationRepository,
        volume_id: i64,
        path: []const u8,
        key: StorageIdentityKey,
    ) !?i64 {
        var statement = try self.db.prepare(
            \\SELECT id FROM locations
            \\WHERE volume_id=?1 AND uri=?2 AND native_inode=?3
            \\  AND size_bytes=?4 AND modified_ns=?5 AND state='present';
        );
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindText(2, path);
        try statement.bindInt64(3, key.native_inode);
        try statement.bindInt64(4, key.size_bytes);
        try statement.bindInt64(5, key.modified_ns);
        return switch (try statement.step()) {
            .row => statement.columnInt64(0),
            .done => null,
        };
    }

    /// Record that this run reached these Locations, so the sweep does not
    /// mistake them for absent. Caller holds the write lane.
    pub fn markSeenLocked(
        self: *LocationRepository,
        ids: []const i64,
        generation: i64,
    ) !void {
        if (ids.len == 0) return;
        var statement = try self.db.prepare(
            \\UPDATE locations SET last_seen_generation=?2 WHERE id=?1;
        );
        defer statement.deinit();
        for (ids) |id| {
            try statement.reset();
            try statement.bindInt64(1, id);
            try statement.bindInt64(2, generation);
            if (try statement.step() != .done) return error.SqlFailed;
        }
    }

    pub fn uri(
        self: *const LocationRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
    ) !?[]u8 {
        var statement = try self.db.prepare(
            "SELECT uri FROM locations WHERE file_id=?1 ORDER BY id LIMIT 1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .row) return null;
        return try allocator.dupe(u8, statement.columnText(0));
    }

    /// The present location at `uri` on any volume, for re-observing a path
    /// the mutation journal names.
    pub fn presentByUri(
        self: *const LocationRepository,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !?PresentLocation {
        var statement = try self.db.prepare(
            \\SELECT uri, volume_id, root_id, last_seen_generation FROM locations
            \\WHERE uri=?1 AND state='present' ORDER BY id LIMIT 1;
        );
        defer statement.deinit();
        try statement.bindText(1, path);
        if (try statement.step() != .row) return null;
        return .{
            .uri = try allocator.dupe(u8, statement.columnText(0)),
            .volume_id = statement.columnInt64(1),
            .root_id = if (statement.columnIsNull(2)) null else statement.columnInt64(2),
            .generation = if (statement.columnIsNull(3)) 0 else statement.columnInt64(3),
        };
    }

    /// Where a file's bytes are now, with the root and generation a scanner
    /// needs to re-observe it in place. Null when no location is present.
    pub fn presentOf(
        self: *const LocationRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
    ) !?PresentLocation {
        var statement = try self.db.prepare(
            \\SELECT uri, volume_id, root_id, last_seen_generation FROM locations
            \\WHERE file_id=?1 AND state='present' ORDER BY id LIMIT 1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .row) return null;
        return .{
            .uri = try allocator.dupe(u8, statement.columnText(0)),
            .volume_id = statement.columnInt64(1),
            .root_id = if (statement.columnIsNull(2)) null else statement.columnInt64(2),
            .generation = if (statement.columnIsNull(3)) 0 else statement.columnInt64(3),
        };
    }

    /// The second path at which Orca holds this file's bytes, when there is
    /// one.
    ///
    /// A byte-identical copy never becomes a second `files` row: the scanner's
    /// identity cascade resolves it by quick hash to the row that already
    /// exists, so the Library models it as one file at two locations. That is
    /// still the same audio stored twice, and it is what a person asking about
    /// duplicates means, so the duplicate scan reads it here rather than
    /// pretending the copy does not exist.
    ///
    /// Only `present` locations count. A file that *moved* leaves a `missing`
    /// row behind and a `present` one ahead, and reporting that pair as a
    /// duplicate would name a path that is not there.
    pub fn secondPresentPath(
        self: *const LocationRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
    ) !?[]u8 {
        var statement = try self.db.prepare(
            "SELECT uri FROM locations WHERE file_id=?1 AND state='present'" ++
                " ORDER BY id LIMIT 1 OFFSET 1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .row) return null;
        return try allocator.dupe(u8, statement.columnText(0));
    }

    /// Records that a file the Library still lists is not where it says.
    ///
    /// Called from the decode producer when a track will not open, so it
    /// **declines the write rather than waiting for it**. A job worker holds
    /// the write lane across an entire batch commit; a producer parked behind
    /// one stops feeding the render callback, which zero-fills and counts
    /// underruns. Missing audio is a worse answer than a stale row.
    ///
    /// Skipping costs nothing that matters: the scanner is the authority on
    /// location state and reconciles it properly, and the next attempt on this
    /// track tries again. Returns whether the row was written.
    pub fn markMissingIfLaneFree(self: *LocationRepository, file_id: i64) !bool {
        if (!self.write_lane.tryAcquire()) return false;
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE locations SET state='missing', missing_since=unixepoch()
            \\WHERE file_id=?1 AND state<>'missing';
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .done) return error.SqlFailed;
        return true;
    }

    pub fn stateOf(self: *const LocationRepository, location_id: i64) !LocationState {
        var statement = try self.db.prepare("SELECT state FROM locations WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, location_id);
        if (try statement.step() != .row) return error.LocationNotFound;
        return LocationState.parse(statement.columnText(0)) orelse
            error.InvalidStoredLocationState;
    }

    pub fn count(self: *const LocationRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM locations;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// Locations a scan has confirmed are where the library says they are.
    pub fn countPresent(self: *const LocationRepository) !u64 {
        var statement = try self.db.prepare(
            "SELECT count(*) FROM locations WHERE state='present';",
        );
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

/// Observed tags for one file: what the file itself says, nothing resolved.
///
/// Every field `metadata.ObservedTags` can carry has a column, because the
/// previous path-keyed table stored four of them and discarded the rest at this
/// boundary. Genres are the one multi-valued field, and they get their own
/// ordinal-keyed child table rather than a delimiter-packed string: order and
/// multiplicity survive a round trip exactly, and "every file tagged Ambient"
/// stays an indexable query instead of a substring match.
pub const ObservedTagsRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn upsert(self: *ObservedTagsRepository, input: ObservedTagsInput) !void {
        return self.upsertBatch(&.{input});
    }

    pub fn upsertBatch(self: *ObservedTagsRepository, inputs: []const ObservedTagsInput) !void {
        if (inputs.len == 0) return;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try self.upsertBatchLocked(inputs);
        try self.db.exec("COMMIT;");
    }

    /// Same as `upsertBatch` for a caller that already holds the write lane and
    /// an open transaction — a scan batch writes files, locations and tags as
    /// one bounded commit.
    pub fn upsertBatchLocked(
        self: *ObservedTagsRepository,
        inputs: []const ObservedTagsInput,
    ) !void {
        var statement = try self.db.prepare(
            \\INSERT INTO observed_file_tags(
            \\    file_id, title, artist, album, album_artist, composer,
            \\    track_number, track_total, disc_number, disc_total,
            \\    date, original_date, compilation, label, media, isrc,
            \\    release_country, release_type, release_status,
            \\    musicbrainz_recording_id, musicbrainz_release_id,
            \\    musicbrainz_release_group_id, musicbrainz_release_track_id,
            \\    musicbrainz_artist_id, musicbrainz_album_artist_id,
            \\    artwork_mime_type, artwork_byte_size, artwork_kind, observed_at
            \\) VALUES (
            \\    ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15,
            \\    ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28,
            \\    unixepoch()
            \\) ON CONFLICT(file_id) DO UPDATE SET
            \\    title=excluded.title, artist=excluded.artist, album=excluded.album,
            \\    album_artist=excluded.album_artist, composer=excluded.composer,
            \\    track_number=excluded.track_number, track_total=excluded.track_total,
            \\    disc_number=excluded.disc_number, disc_total=excluded.disc_total,
            \\    date=excluded.date, original_date=excluded.original_date,
            \\    compilation=excluded.compilation, label=excluded.label,
            \\    media=excluded.media, isrc=excluded.isrc,
            \\    release_country=excluded.release_country,
            \\    release_type=excluded.release_type,
            \\    release_status=excluded.release_status,
            \\    musicbrainz_recording_id=excluded.musicbrainz_recording_id,
            \\    musicbrainz_release_id=excluded.musicbrainz_release_id,
            \\    musicbrainz_release_group_id=excluded.musicbrainz_release_group_id,
            \\    musicbrainz_release_track_id=excluded.musicbrainz_release_track_id,
            \\    musicbrainz_artist_id=excluded.musicbrainz_artist_id,
            \\    musicbrainz_album_artist_id=excluded.musicbrainz_album_artist_id,
            \\    artwork_mime_type=excluded.artwork_mime_type,
            \\    artwork_byte_size=excluded.artwork_byte_size,
            \\    artwork_kind=excluded.artwork_kind,
            \\    observed_at=excluded.observed_at;
        );
        defer statement.deinit();
        var delete_genres = try self.db.prepare(
            "DELETE FROM observed_file_genres WHERE file_id=?1;",
        );
        defer delete_genres.deinit();
        var insert_genre = try self.db.prepare(
            "INSERT INTO observed_file_genres(file_id, ordinal, value) VALUES (?1, ?2, ?3);",
        );
        defer insert_genre.deinit();
        for (inputs) |input| {
            const tags = input.values;
            try statement.bindInt64(1, input.file_id);
            try statement.bindOptionalText(2, presentText(tags.title));
            try statement.bindOptionalText(3, presentText(tags.artist));
            try statement.bindOptionalText(4, presentText(tags.album));
            try statement.bindOptionalText(5, presentText(tags.album_artist));
            try statement.bindOptionalText(6, presentText(tags.composer));
            try statement.bindOptionalInt64(7, optionalCount(tags.track_number));
            try statement.bindOptionalInt64(8, optionalCount(tags.track_total));
            try statement.bindOptionalInt64(9, optionalCount(tags.disc_number));
            try statement.bindOptionalInt64(10, optionalCount(tags.disc_total));
            try statement.bindOptionalText(11, presentText(tags.date));
            try statement.bindOptionalText(12, presentText(tags.original_date));
            try statement.bindOptionalInt64(
                13,
                if (tags.compilation) |flag| @intFromBool(flag) else null,
            );
            try statement.bindOptionalText(14, presentText(tags.label));
            try statement.bindOptionalText(15, presentText(tags.media));
            try statement.bindOptionalText(16, presentText(tags.isrc));
            try statement.bindOptionalText(17, presentText(tags.release_country));
            try statement.bindOptionalText(18, presentText(tags.release_type));
            try statement.bindOptionalText(19, presentText(tags.release_status));
            try statement.bindOptionalText(20, presentText(tags.musicbrainz_recording_id));
            try statement.bindOptionalText(21, presentText(tags.musicbrainz_release_id));
            try statement.bindOptionalText(22, presentText(tags.musicbrainz_release_group_id));
            try statement.bindOptionalText(23, presentText(tags.musicbrainz_release_track_id));
            try statement.bindOptionalText(24, presentText(tags.musicbrainz_artist_id));
            try statement.bindOptionalText(25, presentText(tags.musicbrainz_album_artist_id));
            if (tags.artwork) |artwork| {
                try statement.bindText(26, artwork.mime_type);
                try statement.bindInt64(27, @intCast(artwork.byte_size));
                try statement.bindInt64(28, @intFromEnum(artwork.kind));
            } else {
                try statement.bindOptionalText(26, null);
                try statement.bindOptionalInt64(27, null);
                try statement.bindOptionalInt64(28, null);
            }
            if (try statement.step() != .done) return error.SqlFailed;
            try statement.reset();

            try delete_genres.bindInt64(1, input.file_id);
            if (try delete_genres.step() != .done) return error.SqlFailed;
            try delete_genres.reset();
            for (tags.genres, 0..) |genre, ordinal| {
                if (genre.len == 0) continue;
                try insert_genre.bindInt64(1, input.file_id);
                try insert_genre.bindInt64(2, @intCast(ordinal));
                try insert_genre.bindText(3, genre);
                if (try insert_genre.step() != .done) return error.SqlFailed;
                try insert_genre.reset();
            }
        }
    }

    pub fn get(
        self: *const ObservedTagsRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
    ) !?StoredObservedTags {
        var statement = try self.db.prepare(
            \\SELECT title, artist, album, album_artist, composer,
            \\       track_number, track_total, disc_number, disc_total,
            \\       date, original_date, compilation, label, media, isrc,
            \\       release_country, release_type, release_status,
            \\       musicbrainz_recording_id, musicbrainz_release_id,
            \\       musicbrainz_release_group_id, musicbrainz_release_track_id,
            \\       musicbrainz_artist_id, musicbrainz_album_artist_id,
            \\       artwork_mime_type, artwork_byte_size, artwork_kind
            \\FROM observed_file_tags WHERE file_id=?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .row) return null;

        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = .init(allocator);
        errdefer arena.deinit();
        const scratch = arena.allocator();
        var values: metadata.ObservedTags = .{
            .title = try dupeNullable(scratch, statement, 0),
            .artist = try dupeNullable(scratch, statement, 1),
            .album = try dupeNullable(scratch, statement, 2),
            .album_artist = try dupeNullable(scratch, statement, 3),
            .composer = try dupeNullable(scratch, statement, 4),
            .track_number = countColumn(statement, 5),
            .track_total = countColumn(statement, 6),
            .disc_number = countColumn(statement, 7),
            .disc_total = countColumn(statement, 8),
            .date = try dupeNullable(scratch, statement, 9),
            .original_date = try dupeNullable(scratch, statement, 10),
            .compilation = if (statement.columnIsNull(11))
                null
            else
                statement.columnInt64(11) != 0,
            .label = try dupeNullable(scratch, statement, 12),
            .media = try dupeNullable(scratch, statement, 13),
            .isrc = try dupeNullable(scratch, statement, 14),
            .release_country = try dupeNullable(scratch, statement, 15),
            .release_type = try dupeNullable(scratch, statement, 16),
            .release_status = try dupeNullable(scratch, statement, 17),
            .musicbrainz_recording_id = try dupeNullable(scratch, statement, 18),
            .musicbrainz_release_id = try dupeNullable(scratch, statement, 19),
            .musicbrainz_release_group_id = try dupeNullable(scratch, statement, 20),
            .musicbrainz_release_track_id = try dupeNullable(scratch, statement, 21),
            .musicbrainz_artist_id = try dupeNullable(scratch, statement, 22),
            .musicbrainz_album_artist_id = try dupeNullable(scratch, statement, 23),
        };
        if (try dupeNullable(scratch, statement, 24)) |mime_type| values.artwork = .{
            .mime_type = mime_type,
            .byte_size = @intCast(statement.columnInt64(25)),
            .kind = std.enums.fromInt(metadata.ArtworkKind, statement.columnInt64(26)) orelse
                .other,
        };
        values.genres = try self.genres(scratch, file_id);
        return .{ .arena = arena, .values = values };
    }

    fn genres(
        self: *const ObservedTagsRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
    ) ![]const []const u8 {
        var statement = try self.db.prepare(
            "SELECT value FROM observed_file_genres WHERE file_id=?1 ORDER BY ordinal;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        var values: std.ArrayList([]const u8) = .empty;
        errdefer values.deinit(allocator);
        while (try statement.step() == .row)
            try values.append(allocator, try allocator.dupe(u8, statement.columnText(0)));
        return values.toOwnedSlice(allocator);
    }

    pub fn count(self: *const ObservedTagsRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM observed_file_tags;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

fn presentText(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len == 0) null else text;
}

fn optionalCount(value: ?u32) ?i64 {
    return if (value) |number| @intCast(number) else null;
}

fn countColumn(statement: sqlite.Statement, column: c_int) ?u32 {
    if (statement.columnIsNull(column)) return null;
    return std.math.cast(u32, statement.columnInt64(column));
}

fn dupeNullable(
    allocator: std.mem.Allocator,
    statement: sqlite.Statement,
    column: c_int,
) !?[]const u8 {
    if (statement.columnIsNull(column)) return null;
    return try allocator.dupe(u8, statement.columnText(column));
}

fn optionalInt64(statement: sqlite.Statement, column: c_int) ?i64 {
    if (statement.columnIsNull(column)) return null;
    return statement.columnInt64(column);
}

fn bindOptionalBlob(statement: sqlite.Statement, index: c_int, value: ?[]const u8) !void {
    if (value) |bytes| return statement.bindBlob(index, bytes);
    return statement.bindOptionalText(index, null);
}

pub const OrcaMetadataRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn upsert(self: *OrcaMetadataRepository, input: OrcaMetadataInput) !void {
        if (input.file_id == 0 or input.value.len == 0 or input.provenance == .observed_file)
            return error.InvalidOrcaMetadata;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO orca_metadata_values(file_id, field, value, provenance, locked, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, unixepoch())
            \\ON CONFLICT(file_id, field) DO UPDATE SET
            \\    value=excluded.value,
            \\    provenance=excluded.provenance,
            \\    locked=excluded.locked,
            \\    updated_at=excluded.updated_at
            \\WHERE orca_metadata_values.locked=0 OR excluded.provenance=?6;
        );
        defer statement.deinit();
        try statement.bindInt64(1, input.file_id);
        try statement.bindInt64(2, @intFromEnum(input.field));
        try statement.bindText(3, input.value);
        try statement.bindInt64(4, @intFromEnum(input.provenance));
        try statement.bindInt64(5, @intFromBool(input.locked));
        try statement.bindInt64(6, @intFromEnum(metadata.Provenance.user));
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Drops Orca's value for one field, so the file's own tag applies again.
    pub fn remove(self: *OrcaMetadataRepository, file_id: i64, field: metadata.Field) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            "DELETE FROM orca_metadata_values WHERE file_id=?1 AND field=?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, @intFromEnum(field));
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Every field Orca holds a value for on one file, in field order.
    pub fn values(
        self: *const OrcaMetadataRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
    ) !FieldValuePage {
        var statement = try self.db.prepare(
            \\SELECT field, value, provenance, locked FROM orca_metadata_values
            \\WHERE file_id=?1 ORDER BY field;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        var items: std.ArrayList(FieldValue) = .empty;
        errdefer {
            for (items.items) |item| allocator.free(item.text);
            items.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const field = std.enums.fromInt(metadata.Field, statement.columnInt64(0)) orelse continue;
            const provenance = std.enums.fromInt(metadata.Provenance, statement.columnInt64(2)) orelse
                return error.InvalidStoredProvenance;
            const text = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(text);
            try items.append(allocator, .{
                .field = field,
                .text = text,
                .provenance = provenance,
                .locked = statement.columnInt64(3) != 0,
            });
        }
        return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    }

    pub fn get(
        self: *const OrcaMetadataRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
        field: metadata.Field,
    ) !?StoredMetadataValue {
        var statement = try self.db.prepare(
            \\SELECT value, provenance, locked FROM orca_metadata_values
            \\WHERE file_id=?1 AND field=?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, @intFromEnum(field));
        if (try statement.step() != .row) return null;
        const provenance = std.enums.fromInt(
            metadata.Provenance,
            statement.columnInt64(1),
        ) orelse return error.InvalidStoredProvenance;
        return .{
            .text = try allocator.dupe(u8, statement.columnText(0)),
            .provenance = provenance,
            .locked = statement.columnInt64(2) != 0,
        };
    }
};

pub const MutationJournalRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// The journal is the only record that a file mutation is in flight, so its
    /// writes must reach stable storage before the filesystem changes they
    /// describe. `synchronous=NORMAL` does not fsync a WAL commit, so journal
    /// writes raise durability for their own transaction and restore the
    /// library-wide setting afterwards.
    fn beginDurable(self: *MutationJournalRepository) !void {
        try self.db.exec("PRAGMA synchronous=FULL;");
    }

    fn endDurable(self: *MutationJournalRepository) void {
        self.db.exec("PRAGMA synchronous=NORMAL;") catch {};
    }

    pub fn prepare(self: *MutationJournalRepository, input: MutationOperationInput) !i64 {
        if (input.plan_id == 0 or input.group_id == 0 or input.source_path.len == 0)
            return error.InvalidMutationOperation;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.beginDurable();
        defer self.endDurable();
        var statement = try self.db.prepare(
            \\INSERT INTO mutation_operations(
            \\    plan_id, group_id, action_index, kind, source_path, destination_path,
            \\    stage_path, backup_path, expected_size, expected_modified_ns, state,
            \\    file_id, expected_quick_hash
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13);
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intCast(input.plan_id));
        try statement.bindInt64(2, @intCast(input.group_id));
        try statement.bindInt64(3, input.action_index);
        try statement.bindInt64(4, @intFromEnum(input.kind));
        try statement.bindText(5, input.source_path);
        try statement.bindOptionalText(6, input.destination_path);
        try statement.bindOptionalText(7, input.stage_path);
        try statement.bindOptionalText(8, input.backup_path);
        try statement.bindInt64(9, @intCast(input.expected_size));
        try statement.bindInt64(10, input.expected_modified_ns);
        try statement.bindInt64(11, @intFromEnum(MutationState.planned));
        try statement.bindOptionalInt64(12, input.file_id);
        try statement.bindBlob(13, &input.expected_quick_hash);
        if (try statement.step() != .done) return error.SqlFailed;
        return self.db.lastInsertRowId();
    }

    pub fn transition(
        self: *MutationJournalRepository,
        operation_id: i64,
        expected: MutationState,
        next: MutationState,
        message: ?[]const u8,
    ) !void {
        if (!validMutationTransition(expected, next)) return error.InvalidMutationTransition;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.beginDurable();
        defer self.endDurable();
        var statement = try self.db.prepare(
            \\UPDATE mutation_operations
            \\SET state=?1, error=?2, updated_at=unixepoch()
            \\WHERE id=?3 AND state=?4;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intFromEnum(next));
        try statement.bindOptionalText(2, message);
        try statement.bindInt64(3, operation_id);
        try statement.bindInt64(4, @intFromEnum(expected));
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleMutationOperation;
    }

    pub fn state(self: *const MutationJournalRepository, operation_id: i64) !MutationState {
        var statement = try self.db.prepare(
            "SELECT state FROM mutation_operations WHERE id=?1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, operation_id);
        if (try statement.step() != .row) return error.MutationOperationNotFound;
        return std.enums.fromInt(MutationState, statement.columnInt64(0)) orelse
            error.InvalidStoredMutationState;
    }

    pub fn commit(
        self: *MutationJournalRepository,
        operation_id: i64,
        committed_size: u64,
        committed_modified_ns: i64,
        committed_quick_hash: quick_hash.Digest,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.beginDurable();
        defer self.endDurable();
        var statement = try self.db.prepare(
            \\UPDATE mutation_operations
            \\SET state=?1, committed_size=?2, committed_modified_ns=?3,
            \\    committed_quick_hash=?6, updated_at=unixepoch()
            \\WHERE id=?4 AND state=?5;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intFromEnum(MutationState.committed));
        try statement.bindInt64(2, @intCast(committed_size));
        try statement.bindInt64(3, committed_modified_ns);
        try statement.bindInt64(4, operation_id);
        try statement.bindInt64(5, @intFromEnum(MutationState.staged));
        try statement.bindBlob(6, &committed_quick_hash);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleMutationOperation;
    }

    pub fn recordResultIdentity(
        self: *MutationJournalRepository,
        operation_id: i64,
        expected_state: MutationState,
        size: u64,
        modified_ns: i64,
        digest: quick_hash.Digest,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.beginDurable();
        defer self.endDurable();
        var statement = try self.db.prepare(
            \\UPDATE mutation_operations
            \\SET committed_size=?1, committed_modified_ns=?2, committed_quick_hash=?5,
            \\    updated_at=unixepoch()
            \\WHERE id=?3 AND state=?4;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intCast(size));
        try statement.bindInt64(2, modified_ns);
        try statement.bindInt64(3, operation_id);
        try statement.bindInt64(4, @intFromEnum(expected_state));
        try statement.bindBlob(5, &digest);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleMutationOperation;
    }

    pub fn get(
        self: *const MutationJournalRepository,
        allocator: std.mem.Allocator,
        operation_id: i64,
    ) !MutationOperation {
        var statement = try self.db.prepare(
            \\SELECT kind, source_path, destination_path, stage_path, backup_path,
            \\       expected_size, expected_modified_ns,
            \\       committed_size, committed_modified_ns, state,
            \\       file_id, expected_quick_hash, committed_quick_hash
            \\FROM mutation_operations WHERE id=?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, operation_id);
        if (try statement.step() != .row) return error.MutationOperationNotFound;
        const kind = std.enums.fromInt(MutationKind, statement.columnInt64(0)) orelse
            return error.InvalidStoredMutationKind;
        const source_path = try allocator.dupe(u8, statement.columnText(1));
        errdefer allocator.free(source_path);
        const destination_path = try duplicateNullableColumn(allocator, statement, 2);
        errdefer if (destination_path) |value| allocator.free(value);
        const stage_path = try duplicateNullableColumn(allocator, statement, 3);
        errdefer if (stage_path) |value| allocator.free(value);
        const backup_path = try duplicateNullableColumn(allocator, statement, 4);
        errdefer if (backup_path) |value| allocator.free(value);
        const state_value = std.enums.fromInt(MutationState, statement.columnInt64(9)) orelse
            return error.InvalidStoredMutationState;
        return .{
            .allocator = allocator,
            .id = operation_id,
            .kind = kind,
            .file_id = optionalInt64(statement, 10),
            .source_path = source_path,
            .destination_path = destination_path,
            .stage_path = stage_path,
            .backup_path = backup_path,
            .expected_size = @intCast(statement.columnInt64(5)),
            .expected_modified_ns = statement.columnInt64(6),
            .expected_quick_hash = digestColumn(statement, 11),
            .committed_size = if (statement.columnIsNull(7)) null else @intCast(statement.columnInt64(7)),
            .committed_modified_ns = if (statement.columnIsNull(8)) null else statement.columnInt64(8),
            .committed_quick_hash = digestColumn(statement, 12),
            .state = state_value,
        };
    }

    /// Groups holding at least one operation that has not reached a terminal
    /// state. Startup recovery drives exactly these to a terminal state before a
    /// Library becomes available.
    pub fn nonterminalGroupIds(
        self: *const MutationJournalRepository,
        allocator: std.mem.Allocator,
    ) ![]u64 {
        var statement = try self.db.prepare(
            \\SELECT DISTINCT group_id FROM mutation_operations
            \\WHERE state IN (?1, ?2, ?3) ORDER BY group_id;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intFromEnum(MutationState.planned));
        try statement.bindInt64(2, @intFromEnum(MutationState.staged));
        try statement.bindInt64(3, @intFromEnum(MutationState.failed));
        var ids: std.ArrayList(u64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row)
            try ids.append(allocator, @intCast(statement.columnInt64(0)));
        return ids.toOwnedSlice(allocator);
    }

    /// A group and plan id no journaled operation uses yet. Stage and backup
    /// paths are named after the plan id, so it must not repeat.
    pub fn nextGroupId(self: *const MutationJournalRepository) !u64 {
        var statement = try self.db.prepare(
            "SELECT COALESCE(MAX(MAX(group_id), MAX(plan_id)), 0) + 1 FROM mutation_operations;",
        );
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn groupOperationIds(
        self: *const MutationJournalRepository,
        allocator: std.mem.Allocator,
        group_id: u64,
    ) ![]i64 {
        var statement = try self.db.prepare(
            \\SELECT id FROM mutation_operations
            \\WHERE group_id=?1 ORDER BY action_index DESC;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intCast(group_id));
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row)
            try ids.append(allocator, statement.columnInt64(0));
        return ids.toOwnedSlice(allocator);
    }
};

pub const AnalysisCacheRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// The full key, every column of it. `source_identity` is not optional
    /// here and never should be: a stored measurement that is returned for
    /// bytes it was not taken from is a wrong answer presented as a right one,
    /// and both readers below exist to hand that answer to something that will
    /// act on it.
    const by_key =
        \\SELECT result FROM analysis_results
        \\WHERE file_id=?1 AND kind=?2 AND algorithm_id=?3
        \\  AND algorithm_version=?4 AND parameter_hash=?5
        \\  AND source_identity=?6;
    ;

    pub fn get(
        self: *const AnalysisCacheRepository,
        allocator: std.mem.Allocator,
        key: AnalysisCacheKey,
    ) !?[]u8 {
        var statement = try self.db.prepare(by_key);
        defer statement.deinit();
        try bindAnalysisKey(statement, &key);
        if (try statement.step() != .row) return null;
        return try allocator.dupe(u8, statement.columnBlob(0));
    }

    /// The result stored under `key`, copied into a caller-owned buffer, or
    /// null when there is none.
    ///
    /// The buffer is the caller's because the one caller that needs this is
    /// loading a queue entry on the control lane and wants a fixed-size header
    /// out of a blob whose bulk is a waveform it will never read. The returned
    /// length is the row's full length and may exceed `buffer.len`, which is
    /// how a caller learns it saw only a prefix. A caller that wants the whole
    /// result uses `get`.
    pub fn resultInto(
        self: *const AnalysisCacheRepository,
        key: AnalysisCacheKey,
        buffer: []u8,
    ) !?usize {
        var statement = try self.db.prepare(by_key);
        defer statement.deinit();
        try bindAnalysisKey(statement, &key);
        if (try statement.step() != .row) return null;
        const stored = statement.columnBlob(0);
        const copied = @min(stored.len, buffer.len);
        @memcpy(buffer[0..copied], stored[0..copied]);
        return stored.len;
    }

    pub fn put(self: *AnalysisCacheRepository, key: AnalysisCacheKey, result: []const u8) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.putLocked(key, result);
    }

    /// The same write from inside a caller's transaction. A library-wide
    /// analysis commits a whole batch of files at once — results, identity and
    /// health together — so it holds the lane itself rather than taking it once
    /// per row.
    pub fn putLocked(
        self: *AnalysisCacheRepository,
        key: AnalysisCacheKey,
        result: []const u8,
    ) !void {
        var statement = try self.db.prepare(
            \\INSERT INTO analysis_results(
            \\    file_id, kind, algorithm_id, algorithm_version, parameter_hash,
            \\    source_identity, result
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            \\ON CONFLICT DO UPDATE SET result=excluded.result, created_at=unixepoch();
        );
        defer statement.deinit();
        try bindAnalysisKey(statement, &key);
        try statement.bindBlob(7, result);
        if (try statement.step() != .done) return error.SqlFailed;
    }
};

pub const HealthIssueRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Replaces all derived health state for one file in a single transaction.
    /// An empty issue list marks the file healthy.
    pub fn replaceFile(
        self: *HealthIssueRepository,
        file_id: i64,
        issues: []const HealthIssueInput,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var delete = try self.db.prepare("DELETE FROM library_health_issues WHERE file_id=?1;");
        defer delete.deinit();
        try delete.bindInt64(1, file_id);
        if (try delete.step() != .done) return error.SqlFailed;
        var insert = try self.db.prepare(
            \\INSERT INTO library_health_issues(file_id, kind, severity, details, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, unixepoch());
        );
        defer insert.deinit();
        for (issues) |issue| {
            try insert.bindInt64(1, file_id);
            try insert.bindInt64(2, @intFromEnum(issue.kind));
            try insert.bindInt64(3, @intFromEnum(issue.severity));
            try insert.bindText(4, issue.details);
            if (try insert.step() != .done) return error.SqlFailed;
            try insert.reset();
        }
        try self.db.exec("COMMIT;");
    }

    /// Record one derived issue without disturbing the others.
    ///
    /// `replaceFile` is the analyzer's call: it owns every issue it can decide.
    /// The projection decides exactly one kind — `missing_track_number` — so it
    /// must not be able to erase a loudness or corruption finding on its way
    /// past.
    pub fn recordLocked(
        self: *HealthIssueRepository,
        file_id: i64,
        issue: HealthIssueInput,
    ) !void {
        var statement = try self.db.prepare(
            \\INSERT INTO library_health_issues(file_id, kind, severity, details, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, unixepoch())
            \\ON CONFLICT(file_id, kind) DO UPDATE SET
            \\    severity=excluded.severity,
            \\    details=excluded.details,
            \\    updated_at=excluded.updated_at;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, @intFromEnum(issue.kind));
        try statement.bindInt64(3, @intFromEnum(issue.severity));
        try statement.bindText(4, issue.details);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Retire one issue kind for one file, so a reprojection that resolves the
    /// problem also clears the report of it.
    pub fn clearLocked(
        self: *HealthIssueRepository,
        file_id: i64,
        kind: HealthIssueKind,
    ) !void {
        var statement = try self.db.prepare(
            "DELETE FROM library_health_issues WHERE file_id=?1 AND kind=?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, @intFromEnum(kind));
        if (try statement.step() != .done) return error.SqlFailed;
    }

    pub fn page(
        self: *const HealthIssueRepository,
        allocator: std.mem.Allocator,
        limit: u32,
        offset: u32,
    ) !HealthIssuePage {
        var statement = try self.db.prepare(
            \\SELECT library_health_issues.file_id, kind, severity, details,
            \\       COALESCE((
            \\           SELECT uri FROM locations
            \\           WHERE locations.file_id = library_health_issues.file_id
            \\           ORDER BY locations.id LIMIT 1
            \\       ), '')
            \\FROM library_health_issues
            \\ORDER BY severity DESC, kind, file_id LIMIT ?1 OFFSET ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        try statement.bindInt64(2, offset);
        var issues: std.ArrayList(HealthIssue) = .empty;
        errdefer {
            for (issues.items) |issue| issue.deinit(allocator);
            issues.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const path = try allocator.dupe(u8, statement.columnText(4));
            errdefer allocator.free(path);
            const details = try allocator.dupe(u8, statement.columnText(3));
            errdefer allocator.free(details);
            try issues.append(allocator, .{
                .file_id = statement.columnInt64(0),
                .path = path,
                .kind = std.enums.fromInt(HealthIssueKind, statement.columnInt64(1)) orelse
                    return error.InvalidStoredHealthIssue,
                .severity = std.enums.fromInt(HealthSeverity, statement.columnInt64(2)) orelse
                    return error.InvalidStoredHealthSeverity,
                .details = details,
            });
        }
        return .{ .allocator = allocator, .items = try issues.toOwnedSlice(allocator) };
    }

    pub fn count(self: *const HealthIssueRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM library_health_issues;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

pub const ProviderCacheRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn get(
        self: *const ProviderCacheRepository,
        allocator: std.mem.Allocator,
        provider: []const u8,
        request_key: []const u8,
        now: i64,
        allow_stale: bool,
    ) !?ProviderCacheEntry {
        var statement = try self.db.prepare(
            \\SELECT status, body, expires_at FROM provider_cache
            \\WHERE provider=?1 AND request_key=?2
            \\  AND (?3 OR expires_at>?4);
        );
        defer statement.deinit();
        try statement.bindText(1, provider);
        try statement.bindText(2, request_key);
        try statement.bindInt64(3, @intFromBool(allow_stale));
        try statement.bindInt64(4, now);
        if (try statement.step() != .row) return null;
        return .{
            .allocator = allocator,
            .status = std.math.cast(u16, statement.columnInt64(0)) orelse
                return error.InvalidStoredHttpStatus,
            .body = try allocator.dupe(u8, statement.columnBlob(1)),
            .expires_at = statement.columnInt64(2),
        };
    }

    pub fn put(
        self: *ProviderCacheRepository,
        provider: []const u8,
        request_key: []const u8,
        status: u16,
        body: []const u8,
        expires_at: i64,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO provider_cache(provider, request_key, status, body, expires_at, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, unixepoch())
            \\ON CONFLICT(provider, request_key) DO UPDATE SET
            \\    status=excluded.status, body=excluded.body,
            \\    expires_at=excluded.expires_at, updated_at=excluded.updated_at;
        );
        defer statement.deinit();
        try statement.bindText(1, provider);
        try statement.bindText(2, request_key);
        try statement.bindInt64(3, status);
        try statement.bindBlob(4, body);
        try statement.bindInt64(5, expires_at);
        if (try statement.step() != .done) return error.SqlFailed;
    }
};

pub const ScrobbleQueueRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn enqueue(
        self: *ScrobbleQueueRepository,
        service: []const u8,
        event_key: []const u8,
        payload: []const u8,
    ) !void {
        if (service.len == 0 or event_key.len == 0 or payload.len == 0)
            return error.InvalidScrobbleEvent;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try enqueueScrobbleLocked(self.db, service, event_key, payload);
    }

    /// Claims up to `limit` events for `owner` until `lease_until`: pending
    /// events whose retry time has come, and events whose earlier lease has
    /// expired. One statement, so two owners never receive the same row.
    pub fn lease(
        self: *ScrobbleQueueRepository,
        allocator: std.mem.Allocator,
        service: []const u8,
        owner: i64,
        now: i64,
        lease_until: i64,
        limit: u32,
    ) ![]ScrobbleQueueEntry {
        if (lease_until <= now) return error.InvalidScrobbleLease;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE scrobble_queue
            \\SET state=1, lease_owner=?3, lease_expires_at=?4, updated_at=unixepoch()
            \\WHERE id IN (
            \\    SELECT id FROM scrobble_queue
            \\    WHERE service=?1
            \\      AND ((state=0 AND next_attempt_at<=?2) OR (state=1 AND lease_expires_at<=?2))
            \\    ORDER BY id LIMIT ?5)
            \\RETURNING id, service, event_key, payload, attempt_count;
        );
        defer statement.deinit();
        try statement.bindText(1, service);
        try statement.bindInt64(2, now);
        try statement.bindInt64(3, owner);
        try statement.bindInt64(4, lease_until);
        try statement.bindInt64(5, limit);
        var entries: std.ArrayList(ScrobbleQueueEntry) = .empty;
        errdefer {
            for (entries.items) |entry| entry.deinit();
            entries.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const owned_service = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(owned_service);
            const event_key = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(event_key);
            const payload = try allocator.dupe(u8, statement.columnBlob(3));
            errdefer allocator.free(payload);
            try entries.append(allocator, .{
                .allocator = allocator,
                .id = statement.columnInt64(0),
                .service = owned_service,
                .event_key = event_key,
                .payload = payload,
                .attempt_count = @intCast(statement.columnInt64(4)),
            });
        }
        std.mem.sort(ScrobbleQueueEntry, entries.items, {}, entryIdLessThan);
        return entries.toOwnedSlice(allocator);
    }

    fn entryIdLessThan(_: void, left: ScrobbleQueueEntry, right: ScrobbleQueueEntry) bool {
        return left.id < right.id;
    }

    pub fn markDelivered(self: *ScrobbleQueueRepository, id: i64, owner: i64) !void {
        try self.finishLease(id, owner, .delivered, 1, null, "");
    }

    pub fn markRetry(
        self: *ScrobbleQueueRepository,
        id: i64,
        owner: i64,
        next_attempt_at: i64,
        details: []const u8,
    ) !void {
        try self.finishLease(id, owner, .pending, 1, next_attempt_at, details);
    }

    pub fn markRejected(
        self: *ScrobbleQueueRepository,
        id: i64,
        owner: i64,
        details: []const u8,
    ) !void {
        try self.finishLease(id, owner, .rejected, 1, null, details);
    }

    /// Hands a claimed event back without counting an attempt, for work that
    /// was abandoned before anything was sent.
    pub fn release(self: *ScrobbleQueueRepository, id: i64, owner: i64) !void {
        try self.finishLease(id, owner, .pending, 0, null, null);
    }

    /// Events not yet delivered or rejected, whether waiting or leased.
    pub fn pendingCount(self: *const ScrobbleQueueRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM scrobble_queue WHERE state IN (0, 1);");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn deliveredCount(self: *const ScrobbleQueueRepository, service: []const u8) !u64 {
        var statement = try self.db.prepare(
            "SELECT count(*) FROM scrobble_queue WHERE service=?1 AND state=2;",
        );
        defer statement.deinit();
        try statement.bindText(1, service);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// When a worker should next look for work: the earliest retry time of a
    /// pending event or the earliest expiry of a lease, whichever comes first.
    pub fn nextAttemptAt(self: *const ScrobbleQueueRepository, service: []const u8) !?i64 {
        var statement = try self.db.prepare(
            \\SELECT min(due) FROM (
            \\    SELECT min(next_attempt_at) AS due FROM scrobble_queue WHERE service=?1 AND state=0
            \\    UNION ALL
            \\    SELECT min(lease_expires_at) FROM scrobble_queue WHERE service=?1 AND state=1);
        );
        defer statement.deinit();
        try statement.bindText(1, service);
        if (try statement.step() != .row) return error.SqlFailed;
        if (statement.columnIsNull(0)) return null;
        return statement.columnInt64(0);
    }

    const LeaseOutcome = enum(u8) { pending = 0, delivered = 2, rejected = 3 };

    fn finishLease(
        self: *ScrobbleQueueRepository,
        id: i64,
        owner: i64,
        outcome: LeaseOutcome,
        attempts: u8,
        next_attempt_at: ?i64,
        details: ?[]const u8,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE scrobble_queue SET state=?1, attempt_count=attempt_count+?2,
            \\    next_attempt_at=COALESCE(?3, next_attempt_at), last_error=COALESCE(?4, last_error),
            \\    lease_owner=NULL, lease_expires_at=NULL, updated_at=unixepoch()
            \\WHERE id=?5 AND state=1 AND lease_owner=?6;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @intFromEnum(outcome));
        try statement.bindInt64(2, attempts);
        try statement.bindOptionalInt64(3, next_attempt_at);
        try statement.bindOptionalText(4, details);
        try statement.bindInt64(5, id);
        try statement.bindInt64(6, owner);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleScrobbleEvent;
    }
};

fn enqueueScrobbleLocked(
    db: sqlite.Database,
    service: []const u8,
    event_key: []const u8,
    payload: []const u8,
) !void {
    var statement = try db.prepare(
        \\INSERT INTO scrobble_queue(service, event_key, payload)
        \\VALUES (?1, ?2, ?3) ON CONFLICT(service, event_key) DO NOTHING;
    );
    defer statement.deinit();
    try statement.bindText(1, service);
    try statement.bindText(2, event_key);
    try statement.bindBlob(3, payload);
    if (try statement.step() != .done) return error.SqlFailed;
}

/// The file a Track plays: its preferred file, else the first file of its
/// Recording, matching `TrackRepository.playableLocation`.
pub const track_play_file =
    \\COALESCE(
    \\    tracks.preferred_file_id,
    \\    (SELECT id FROM files WHERE recording_id = tracks.recording_id ORDER BY id LIMIT 1))
;

const recording_mbid_field = std.fmt.comptimePrint("{d}", .{@intFromEnum(metadata.Field.musicbrainz_recording_id)});

/// A locked Orca value, else the file's tag, else an Orca value: the order
/// `TrackRepository.recordingMbid` applies through `metadata.resolveValue`.
/// The two must agree, or details and sync name different recordings.
pub fn effectiveRecordingMbid(comptime file_id: []const u8) []const u8 {
    return "COALESCE(" ++
        "(SELECT NULLIF(value, '') FROM orca_metadata_values WHERE orca_metadata_values.file_id = " ++ file_id ++
        " AND orca_metadata_values.field = " ++ recording_mbid_field ++ " AND orca_metadata_values.locked = 1), " ++
        "(SELECT NULLIF(musicbrainz_recording_id, '') FROM observed_file_tags WHERE observed_file_tags.file_id = " ++ file_id ++ "), " ++
        "(SELECT NULLIF(value, '') FROM orca_metadata_values WHERE orca_metadata_values.file_id = " ++ file_id ++
        " AND orca_metadata_values.field = " ++ recording_mbid_field ++ "))";
}

pub const ListenRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Records a listen, or returns null when this file already has one that
    /// started at the same second.
    pub fn record(self: *ListenRepository, input: ListenInput) !?i64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.insertLocked(input);
    }

    /// Records a listen and queues `payload` for `service` in one transaction,
    /// so a listen is never stored without its delivery or the reverse. A
    /// listen that already existed queues nothing.
    pub fn recordAndQueue(
        self: *ListenRepository,
        input: ListenInput,
        service: []const u8,
        payload: []const u8,
    ) !?i64 {
        if (service.len == 0 or payload.len == 0) return error.InvalidScrobbleEvent;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        const id = try self.insertLocked(input);
        if (id) |listen_id| {
            var key_buffer: [32]u8 = undefined;
            const event_key = std.fmt.bufPrint(&key_buffer, "listen:{d}", .{listen_id}) catch unreachable;
            try enqueueScrobbleLocked(self.db, service, event_key, payload);
        }
        try self.db.exec("COMMIT;");
        return id;
    }

    fn insertLocked(self: *ListenRepository, input: ListenInput) !?i64 {
        const listened_ms = std.math.cast(i64, input.listened_ms) orelse return error.InvalidListen;
        const duration_ms = if (input.duration_ms) |value|
            std.math.cast(i64, value) orelse return error.InvalidListen
        else
            null;
        var statement = try self.db.prepare(
            \\INSERT INTO listens(
            \\    file_id, recording_id, started_at, listened_ms, duration_ms,
            \\    title, artist, album, recording_mbid, player_client)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            \\ON CONFLICT(file_id, started_at) DO NOTHING
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindInt64(1, input.file_id);
        try statement.bindOptionalInt64(2, input.recording_id);
        try statement.bindInt64(3, input.started_at);
        try statement.bindInt64(4, listened_ms);
        try statement.bindOptionalInt64(5, duration_ms);
        try statement.bindText(6, input.title);
        try statement.bindText(7, input.artist);
        try statement.bindText(8, input.album);
        try statement.bindOptionalText(9, input.recording_mbid);
        try statement.bindText(10, input.player_client);
        const inserted = try statement.step() == .row;
        const id = if (inserted) statement.columnInt64(0) else null;
        if (inserted and try statement.step() != .done) return error.SqlFailed;
        return id;
    }

    /// Raises a recorded listen's `listened_ms` to `listened_ms`; a smaller
    /// value leaves it. No listen for this file and start is not an error.
    pub fn updateListened(self: *ListenRepository, file_id: i64, started_at: i64, listened_ms: u64) !void {
        const value = std.math.cast(i64, listened_ms) orelse return error.InvalidListen;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            "UPDATE listens SET listened_ms = max(listened_ms, ?3) WHERE file_id = ?1 AND started_at = ?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, started_at);
        try statement.bindInt64(3, value);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Plays of the file a Track resolves to. Keyed on the file, so the count
    /// survives an edit that reprojects the Track under a new id.
    pub fn trackPlayStats(self: *const ListenRepository, track_id: i64) !PlayStats {
        var statement = try self.db.prepare(
            "SELECT count(*), max(started_at) FROM listens WHERE file_id = " ++
                "(SELECT " ++ track_play_file ++ " FROM tracks WHERE tracks.id = ?1);",
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        return readPlayStats(statement);
    }

    pub fn filePlayStats(self: *const ListenRepository, file_id: i64) !PlayStats {
        var statement = try self.db.prepare(
            "SELECT count(*), max(started_at) FROM listens WHERE file_id = ?1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        return readPlayStats(statement);
    }

    fn readPlayStats(statement: sqlite.Statement) !PlayStats {
        if (try statement.step() != .row) return error.SqlFailed;
        return .{
            .play_count = @intCast(statement.columnInt64(0)),
            .last_played_at = if (statement.columnIsNull(1)) null else statement.columnInt64(1),
        };
    }

    /// What a listen of this Track needs: the metadata the library shows for
    /// it and the MusicBrainz ids recorded for the file it plays. Null when the
    /// Track does not exist.
    pub fn listenSubject(
        self: *const ListenRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
    ) !?ListenSubject {
        var statement = try self.db.prepare(
            "WITH subject AS (\n" ++
                "    SELECT " ++ track_play_file ++ " AS file_id, tracks.recording_id,\n" ++
                "           tracks.title, tracks.artist, tracks.album,\n" ++
                "           tracks.duration_ms, tracks.track_number\n" ++
                "    FROM tracks WHERE tracks.id = ?1)\n" ++
                "SELECT subject.file_id, subject.recording_id, subject.title, subject.artist,\n" ++
                "       subject.album, subject.duration_ms, subject.track_number,\n" ++
                "       " ++ comptime effectiveRecordingMbid("subject.file_id") ++ ",\n" ++
                "       observed_file_tags.musicbrainz_release_id,\n" ++
                "       observed_file_tags.musicbrainz_artist_id\n" ++
                "FROM subject LEFT JOIN observed_file_tags ON observed_file_tags.file_id = subject.file_id;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return null;
        const title = try allocator.dupe(u8, statement.columnText(2));
        errdefer allocator.free(title);
        const artist = try allocator.dupe(u8, statement.columnText(3));
        errdefer allocator.free(artist);
        const album = try allocator.dupe(u8, statement.columnText(4));
        errdefer allocator.free(album);
        const recording_mbid = try dupeNonEmpty(allocator, statement, 7);
        errdefer if (recording_mbid) |value| allocator.free(value);
        const release_mbid = try dupeNonEmpty(allocator, statement, 8);
        errdefer if (release_mbid) |value| allocator.free(value);
        const artist_mbid = try dupeNonEmpty(allocator, statement, 9);
        errdefer if (artist_mbid) |value| allocator.free(value);
        return .{
            .allocator = allocator,
            .file_id = optionalInt64(statement, 0),
            .recording_id = optionalInt64(statement, 1),
            .title = title,
            .artist = artist,
            .album = album,
            .duration_ms = optionalInt64(statement, 5),
            .track_number = optionalInt64(statement, 6),
            .recording_mbid = recording_mbid,
            .release_mbid = release_mbid,
            .artist_mbid = artist_mbid,
        };
    }

    fn dupeNonEmpty(allocator: std.mem.Allocator, statement: sqlite.Statement, column: c_int) !?[]u8 {
        if (statement.columnIsNull(column)) return null;
        const value = statement.columnText(column);
        if (value.len == 0) return null;
        return try allocator.dupe(u8, value);
    }
};

pub const feedback_settle_seconds: i64 = 2;

pub const feedback_next_sql =
    "SELECT feedback.recording_id, feedback.score, " ++ effectiveRecordingMbid("files.id") ++ " AS mbid\n" ++
    "FROM feedback\n" ++
    "CROSS JOIN files ON files.recording_id = feedback.recording_id\n" ++
    "WHERE feedback.score IS NOT feedback.synced_score\n" ++
    "  AND feedback.updated_at <= ?1\n" ++
    "  AND mbid IS NOT NULL\n" ++
    "ORDER BY feedback.updated_at, feedback.recording_id,\n" ++
    "         EXISTS(SELECT 1 FROM tracks WHERE tracks.preferred_file_id = files.id) DESC, files.id\n" ++
    "LIMIT 1;";

pub const feedback_pending_sql =
    "SELECT count(*) FROM feedback\n" ++
    "WHERE score IS NOT synced_score AND EXISTS (\n" ++
    "    SELECT 1 FROM files WHERE files.recording_id = feedback.recording_id\n" ++
    "      AND " ++ effectiveRecordingMbid("files.id") ++ " IS NOT NULL);";

pub const feedback_syncable_sql =
    "SELECT EXISTS (\n" ++
    "    SELECT 1 FROM files\n" ++
    "    WHERE files.recording_id = (SELECT recording_id FROM tracks WHERE id = ?1)\n" ++
    "      AND " ++ effectiveRecordingMbid("files.id") ++ " IS NOT NULL);";

pub const FeedbackRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn set(self: *FeedbackRepository, track_ids: []const i64, feedback: Feedback) !FeedbackChange {
        if (track_ids.len > max_page) return error.PageOutOfRange;
        var change: FeedbackChange = .{};
        if (track_ids.len == 0) return change;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var find = try self.db.prepare("SELECT recording_id FROM tracks WHERE id=?1;");
        defer find.deinit();
        var assign = try self.db.prepare(
            \\INSERT INTO feedback(recording_id, score, updated_at) VALUES (?1, ?2, unixepoch())
            \\ON CONFLICT(recording_id) DO UPDATE SET
            \\    score=excluded.score, updated_at=excluded.updated_at, last_error='';
        );
        defer assign.deinit();
        var retract = try self.db.prepare(
            \\UPDATE feedback SET score=0, updated_at=unixepoch()
            \\WHERE recording_id=?1 AND COALESCE(synced_score, 0) <> 0 AND last_error = '';
        );
        defer retract.deinit();
        var forget = try self.db.prepare(
            "DELETE FROM feedback WHERE recording_id=?1 AND (COALESCE(synced_score, 0) = 0 OR last_error <> '');",
        );
        defer forget.deinit();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        for (track_ids) |track_id| {
            try find.bindInt64(1, track_id);
            const found = try find.step() == .row;
            const recording_id = if (found) optionalInt64(find, 0) else null;
            try find.reset();
            const recording = recording_id orelse {
                change.skipped += 1;
                continue;
            };
            switch (feedback) {
                .none => {
                    try retract.bindInt64(1, recording);
                    if (try retract.step() != .done) return error.SqlFailed;
                    var changed = self.db.changes();
                    try retract.reset();
                    try forget.bindInt64(1, recording);
                    if (try forget.step() != .done) return error.SqlFailed;
                    changed += self.db.changes();
                    try forget.reset();
                    if (changed != 0) change.updated += 1;
                },
                .loved, .hated => {
                    try assign.bindInt64(1, recording);
                    try assign.bindInt64(2, feedback.score());
                    if (try assign.step() != .done) return error.SqlFailed;
                    try assign.reset();
                    change.updated += 1;
                },
            }
        }
        try self.db.exec("COMMIT;");
        return change;
    }

    pub fn forTrack(self: *const FeedbackRepository, track_id: i64) !Feedback {
        var statement = try self.db.prepare(
            \\SELECT feedback.score FROM tracks
            \\JOIN feedback ON feedback.recording_id = tracks.recording_id
            \\WHERE tracks.id = ?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return .none;
        return Feedback.fromScore(statement.columnInt64(0)) orelse error.InvalidStoredFeedback;
    }

    pub fn canSync(self: *const FeedbackRepository, track_id: i64) !bool {
        var statement = try self.db.prepare(feedback_syncable_sql);
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return false;
        return statement.columnInt64(0) != 0;
    }

    pub fn nextToSync(self: *const FeedbackRepository, allocator: std.mem.Allocator, now: i64) !?FeedbackSync {
        var statement = try self.db.prepare(feedback_next_sql);
        defer statement.deinit();
        try statement.bindInt64(1, now -| feedback_settle_seconds);
        if (try statement.step() != .row) return null;
        const mbid = try allocator.dupe(u8, statement.columnText(2));
        return .{
            .allocator = allocator,
            .recording_id = statement.columnInt64(0),
            .feedback = Feedback.fromScore(statement.columnInt64(1)) orelse {
                allocator.free(mbid);
                return error.InvalidStoredFeedback;
            },
            .recording_mbid = mbid,
        };
    }

    pub fn pendingSyncCount(self: *const FeedbackRepository) !u64 {
        var statement = try self.db.prepare(feedback_pending_sql);
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn markSynced(self: *FeedbackRepository, recording_id: i64, sent: Feedback) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var update = try self.db.prepare(
            "UPDATE feedback SET synced_score=?2, synced_at=unixepoch(), last_error='' WHERE recording_id=?1;",
        );
        defer update.deinit();
        try update.bindInt64(1, recording_id);
        try update.bindInt64(2, sent.score());
        if (try update.step() != .done) return error.SqlFailed;
        if (self.db.changes() == 0 and sent != .none) {
            // The user cleared this while it was being sent; the clear still has to go out.
            var restore = try self.db.prepare(
                \\INSERT INTO feedback(recording_id, score, updated_at, synced_score, synced_at)
                \\SELECT id, 0, unixepoch(), ?2, unixepoch() FROM recordings WHERE id=?1;
            );
            defer restore.deinit();
            try restore.bindInt64(1, recording_id);
            try restore.bindInt64(2, sent.score());
            if (try restore.step() != .done) return error.SqlFailed;
        }
        try self.forgetSettledLocked(recording_id);
        try self.db.exec("COMMIT;");
    }

    pub fn markRejected(self: *FeedbackRepository, recording_id: i64, sent: Feedback, details: []const u8) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var update = try self.db.prepare(
            "UPDATE feedback SET synced_score=?2, last_error=?3 WHERE recording_id=?1;",
        );
        defer update.deinit();
        try update.bindInt64(1, recording_id);
        try update.bindInt64(2, sent.score());
        try update.bindText(3, details);
        if (try update.step() != .done) return error.SqlFailed;
        try self.forgetSettledLocked(recording_id);
        try self.db.exec("COMMIT;");
    }

    fn forgetSettledLocked(self: *FeedbackRepository, recording_id: i64) !void {
        var statement = try self.db.prepare(
            "DELETE FROM feedback WHERE recording_id=?1 AND score=0 AND COALESCE(synced_score, 0) = 0;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, recording_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }
};

pub const IdentificationProposalRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn put(self: *IdentificationProposalRepository, input: IdentificationProposalInput) !ProposalState {
        if (input.file_id == 0 or input.provider.len == 0 or input.provider_id.len == 0 or
            input.payload.len == 0 or !std.math.isFinite(input.confidence) or
            input.confidence < 0 or input.confidence > 1) return error.InvalidIdentificationProposal;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO identification_proposals(
            \\    file_id, provider, provider_id, confidence, payload, state, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, 0, unixepoch())
            \\ON CONFLICT(file_id, provider, provider_id) DO UPDATE SET
            \\    confidence=excluded.confidence, payload=excluded.payload,
            \\    updated_at=excluded.updated_at
            \\RETURNING state;
        );
        defer statement.deinit();
        try statement.bindInt64(1, input.file_id);
        try statement.bindText(2, input.provider);
        try statement.bindText(3, input.provider_id);
        try statement.bindDouble(4, input.confidence);
        try statement.bindBlob(5, input.payload);
        if (try statement.step() != .row) return error.SqlFailed;
        const state = std.enums.fromInt(ProposalState, statement.columnInt64(0)) orelse
            return error.InvalidStoredProposalState;
        if (try statement.step() != .done) return error.SqlFailed;
        return state;
    }

    pub fn pending(
        self: *const IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
        limit: u32,
    ) ![]IdentificationProposal {
        var statement = try self.db.prepare(
            \\SELECT id, provider, provider_id, confidence, payload
            \\FROM identification_proposals WHERE file_id=?1 AND state=0
            \\ORDER BY confidence DESC, id LIMIT ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, limit);
        var proposals: std.ArrayList(IdentificationProposal) = .empty;
        errdefer {
            for (proposals.items) |proposal| proposal.deinit();
            proposals.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const provider = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(provider);
            const provider_id = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(provider_id);
            const payload = try allocator.dupe(u8, statement.columnBlob(4));
            errdefer allocator.free(payload);
            try proposals.append(allocator, .{
                .allocator = allocator,
                .id = statement.columnInt64(0),
                .provider = provider,
                .provider_id = provider_id,
                .confidence = @floatCast(statement.columnDouble(3)),
                .payload = payload,
            });
        }
        return proposals.toOwnedSlice(allocator);
    }

    pub fn acceptProposal(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        proposal_id: i64,
    ) !ProposalAcceptance {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        const acceptance = try self.acceptLocked(allocator, proposal_id);
        try self.db.exec("COMMIT;");
        return acceptance;
    }

    /// Nothing is written before the proposal has been read and its payload
    /// parsed, so a refusal leaves the open transaction as it found it.
    fn acceptLocked(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        proposal_id: i64,
    ) !ProposalAcceptance {
        const acceptable = try self.readAcceptable(allocator, proposal_id);
        defer allocator.free(acceptable.recording_mbid);
        const file_id = acceptable.file_id;
        const recording_mbid = acceptable.recording_mbid;

        var store = try self.db.prepare(
            \\INSERT INTO orca_metadata_values(file_id, field, value, provenance, locked, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, 0, unixepoch())
            \\ON CONFLICT(file_id, field) DO UPDATE SET value=excluded.value,
            \\    provenance=excluded.provenance, updated_at=excluded.updated_at
            \\WHERE orca_metadata_values.locked=0;
        );
        defer store.deinit();
        try store.bindInt64(1, file_id);
        try store.bindInt64(2, @intFromEnum(metadata.Field.musicbrainz_recording_id));
        try store.bindText(3, recording_mbid);
        try store.bindInt64(4, @intFromEnum(metadata.Provenance.provider));
        if (try store.step() != .done) return error.SqlFailed;
        const values_written: u32 = @intCast(self.db.changes());

        var settle = try self.db.prepare(
            \\UPDATE identification_proposals
            \\SET state = CASE WHEN id=?1 THEN ?3 ELSE ?4 END, updated_at=unixepoch()
            \\WHERE file_id=?2 AND state=?5;
        );
        defer settle.deinit();
        try settle.bindInt64(1, proposal_id);
        try settle.bindInt64(2, file_id);
        try settle.bindInt64(3, @intFromEnum(ProposalState.accepted));
        try settle.bindInt64(4, @intFromEnum(ProposalState.dismissed));
        try settle.bindInt64(5, @intFromEnum(ProposalState.pending));
        if (try settle.step() != .done) return error.SqlFailed;
        return .{ .file_id = file_id, .values_written = values_written };
    }

    /// A pending proposal whose recording id and payload read back. The caller
    /// frees `recording_mbid`.
    fn readAcceptable(
        self: *const IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        proposal_id: i64,
    ) !struct { file_id: i64, recording_mbid: []u8 } {
        var select = try self.db.prepare(
            "SELECT file_id, provider_id, payload, state FROM identification_proposals WHERE id=?1;",
        );
        defer select.deinit();
        try select.bindInt64(1, proposal_id);
        if (try select.step() != .row) return error.UnknownIdentificationProposal;
        if (select.columnInt64(3) != @intFromEnum(ProposalState.pending)) return error.StaleIdentificationProposal;
        const recording_mbid = try allocator.dupe(u8, select.columnText(1));
        errdefer allocator.free(recording_mbid);
        if (!metadata.isMusicBrainzId(recording_mbid)) return error.InvalidProposalPayload;
        const payload = try ProposalPayload.parse(allocator, select.columnBlob(2));
        payload.deinit();
        return .{ .file_id = select.columnInt64(0), .recording_mbid = recording_mbid };
    }

    pub fn dismiss(self: *IdentificationProposalRepository, proposal_id: i64) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var update = try self.db.prepare(
            "UPDATE identification_proposals SET state=?2, updated_at=unixepoch() WHERE id=?1 AND state=?3;",
        );
        defer update.deinit();
        try update.bindInt64(1, proposal_id);
        try update.bindInt64(2, @intFromEnum(ProposalState.dismissed));
        try update.bindInt64(3, @intFromEnum(ProposalState.pending));
        if (try update.step() != .done) return error.SqlFailed;
        if (self.db.changes() == 1) return;
        var exists = try self.db.prepare("SELECT 1 FROM identification_proposals WHERE id=?1;");
        defer exists.deinit();
        try exists.bindInt64(1, proposal_id);
        return if (try exists.step() == .row) error.StaleIdentificationProposal else error.UnknownIdentificationProposal;
    }

    pub fn acceptConfident(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        minimum_confidence: f32,
    ) !u64 {
        if (!std.math.isFinite(minimum_confidence) or minimum_confidence <= 0 or minimum_confidence > 1)
            return error.InvalidMinimumConfidence;
        var accepted: u64 = 0;
        var cursor: i64 = 0;
        var batch: [max_page]i64 = undefined;
        while (true) {
            const selected = try self.confidentBatch(minimum_confidence, cursor, &batch);
            if (selected.len == 0) return accepted;
            cursor = selected[selected.len - 1];
            self.write_lane.acquire();
            defer self.write_lane.release();
            try self.db.exec("BEGIN IMMEDIATE;");
            errdefer self.db.exec("ROLLBACK;") catch {};
            for (selected) |proposal_id| {
                _ = self.acceptLocked(allocator, proposal_id) catch |err| switch (err) {
                    error.InvalidProposalPayload, error.StaleIdentificationProposal => continue,
                    else => return err,
                };
                accepted += 1;
            }
            try self.db.exec("COMMIT;");
        }
    }

    fn confidentBatch(
        self: *IdentificationProposalRepository,
        minimum_confidence: f32,
        cursor: i64,
        batch: *[max_page]i64,
    ) ![]i64 {
        var statement = try self.db.prepare(confident_batch_sql);
        defer statement.deinit();
        try statement.bindDouble(1, minimum_confidence);
        try statement.bindInt64(2, cursor);
        try statement.bindInt64(3, batch.len);
        try statement.bindInt64(4, @intFromEnum(ProposalState.pending));
        var count: usize = 0;
        while (try statement.step() == .row) : (count += 1) batch[count] = statement.columnInt64(0);
        return batch[0..count];
    }

    /// How many proposals `acceptConfident` would accept now: the same
    /// selection, read back the same way.
    pub fn confidentCount(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        minimum_confidence: f32,
    ) !u64 {
        if (!std.math.isFinite(minimum_confidence) or minimum_confidence <= 0 or minimum_confidence > 1)
            return error.InvalidMinimumConfidence;
        var acceptable: u64 = 0;
        var cursor: i64 = 0;
        var batch: [max_page]i64 = undefined;
        while (true) {
            const selected = try self.confidentBatch(minimum_confidence, cursor, &batch);
            if (selected.len == 0) return acceptable;
            cursor = selected[selected.len - 1];
            for (selected) |proposal_id| {
                const readable = self.readAcceptable(allocator, proposal_id) catch |err| switch (err) {
                    error.InvalidProposalPayload, error.StaleIdentificationProposal => continue,
                    else => return err,
                };
                allocator.free(readable.recording_mbid);
                acceptable += 1;
            }
        }
    }

    pub fn pendingForTrack(
        self: *const IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
        limit: u32,
    ) !MatchProposalPage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(
            "SELECT id, provider, provider_id, confidence, payload FROM identification_proposals\n" ++
                "WHERE file_id = (SELECT " ++ track_play_file ++ " FROM tracks WHERE tracks.id = ?1)\n" ++
                "  AND state = ?3\n" ++
                "ORDER BY confidence DESC, id LIMIT ?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        try statement.bindInt64(2, limit);
        try statement.bindInt64(3, @intFromEnum(ProposalState.pending));

        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        const page: MatchProposalPage = .{ .arena = arena, .items = &.{} };
        errdefer page.deinit();
        const owned = arena.allocator();
        var items: std.ArrayList(MatchProposal) = .empty;
        while (try statement.step() == .row) try items.append(owned, try readMatchProposal(owned, statement, 0));
        return .{ .arena = arena, .items = items.items };
    }

    /// Tracks whose play file has a pending proposal, by artist, album and
    /// position, each with its best proposal.
    pub fn reviewPage(
        self: *const IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        limit: u32,
        offset: u32,
    ) !MatchReviewPage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(review_page_sql);
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        try statement.bindInt64(2, offset);
        try statement.bindInt64(3, @intFromEnum(ProposalState.pending));

        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        const page: MatchReviewPage = .{ .arena = arena, .items = &.{} };
        errdefer page.deinit();
        const owned = arena.allocator();
        var items: std.ArrayList(MatchReviewItem) = .empty;
        while (try statement.step() == .row) {
            try items.append(owned, .{
                .track_id = statement.columnInt64(0),
                .title = try owned.dupe(u8, statement.columnText(1)),
                .artist = try owned.dupe(u8, statement.columnText(2)),
                .album = try owned.dupe(u8, statement.columnText(3)),
                .duration_ms = optionalInt64(statement, 4),
                .proposal_count = @intCast(statement.columnInt64(5)),
                .best = try readMatchProposal(owned, statement, 6),
            });
        }
        return .{ .arena = arena, .items = items.items };
    }

    pub fn reviewCount(self: *const IdentificationProposalRepository) !u64 {
        var statement = try self.db.prepare(review_count_sql);
        defer statement.deinit();
        try statement.bindInt64(3, @intFromEnum(ProposalState.pending));
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// Stores what one search of a file found and records the providers that
    /// answered it, in one transaction, so a file is never marked searched
    /// without its proposals. A proposal for a recording the file already has
    /// one for is updated in place and keeps its state, so a dismissed or
    /// accepted one stays so. Returns how many of the proposals are pending.
    pub fn recordSearch(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
        answered: ProviderSet,
        evidence: []const ProposalEvidence,
    ) !u32 {
        for (evidence) |item| {
            if (!metadata.isMusicBrainzId(item.recording_mbid) or item.found_by.isEmpty())
                return error.InvalidIdentificationProposal;
        }
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var pending_count: u32 = 0;
        for (evidence) |*item| {
            if (try self.mergeLocked(allocator, file_id, item) == .pending) pending_count += 1;
        }
        inline for (.{ IdentificationProvider.musicbrainz, IdentificationProvider.acoustid }) |provider| {
            if (@field(answered, @tagName(provider))) try self.markSearchedLocked(file_id, provider);
        }
        try self.db.exec("COMMIT;");
        return pending_count;
    }

    fn mergeLocked(
        self: *IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
        evidence: *const ProposalEvidence,
    ) !ProposalState {
        var select = try self.db.prepare(
            \\SELECT id, provider, confidence, payload, state FROM identification_proposals
            \\WHERE file_id=?1 AND provider_id=?2 ORDER BY id LIMIT 1;
        );
        defer select.deinit();
        try select.bindInt64(1, file_id);
        try select.bindText(2, evidence.recording_mbid);
        if (try select.step() != .row) {
            const payload = try evidence.payload.encode(allocator);
            defer allocator.free(payload);
            var insert = try self.db.prepare(
                \\INSERT INTO identification_proposals(
                \\    file_id, provider, provider_id, confidence, payload, state, updated_at)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, unixepoch());
            );
            defer insert.deinit();
            try insert.bindInt64(1, file_id);
            try insert.bindText(2, evidence.found_by.text());
            try insert.bindText(3, evidence.recording_mbid);
            try insert.bindDouble(4, evidence.payload.combinedConfidence());
            try insert.bindBlob(5, payload);
            try insert.bindInt64(6, @intFromEnum(ProposalState.pending));
            if (try insert.step() != .done) return error.SqlFailed;
            return .pending;
        }
        const proposal_id = select.columnInt64(0);
        const existing_providers = ProviderSet.parse(select.columnText(1));
        const existing_confidence: f32 = @floatCast(select.columnDouble(2));
        const state = std.enums.fromInt(ProposalState, select.columnInt64(4)) orelse
            return error.InvalidStoredProposalState;
        const parsed = ProposalPayload.parse(allocator, select.columnBlob(3)) catch |err| switch (err) {
            error.InvalidProposalPayload => null,
            error.OutOfMemory => return err,
        };
        defer if (parsed) |value| value.deinit();
        const merged = mergeProposalPayload(
            if (parsed) |value| value.value else .{},
            existing_providers,
            existing_confidence,
            evidence.*,
        );
        const payload = try merged.encode(allocator);
        defer allocator.free(payload);
        const providers = existing_providers.with(evidence.found_by);
        var update = try self.db.prepare(
            \\UPDATE identification_proposals
            \\SET provider=?2, confidence=?3, payload=?4, updated_at=unixepoch() WHERE id=?1;
        );
        defer update.deinit();
        try update.bindInt64(1, proposal_id);
        try update.bindText(2, providers.text());
        try update.bindDouble(3, merged.combinedConfidence());
        try update.bindBlob(4, payload);
        if (try update.step() != .done) return error.SqlFailed;
        return state;
    }

    fn markSearchedLocked(self: *IdentificationProposalRepository, file_id: i64, provider: IdentificationProvider) !void {
        var statement = try self.db.prepare(
            \\INSERT INTO identification_searches(file_id, provider, searched_at)
            \\VALUES (?1, ?2, unixepoch())
            \\ON CONFLICT(file_id, provider) DO UPDATE SET searched_at=excluded.searched_at;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindText(2, provider.text());
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Tracks a matching job still has to search: those some provider in
    /// scope has not answered for. MusicBrainz is always in scope; AcoustID
    /// only when `acoustid` is set.
    pub fn unidentifiedPage(
        self: *const IdentificationProposalRepository,
        allocator: std.mem.Allocator,
        scope: MatchScope,
        acoustid: bool,
        cursor: i64,
        limit: u32,
    ) !MatchCandidatePage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(unidentified_page_sql);
        defer statement.deinit();
        try statement.bindInt64(1, scope.lowerBound(cursor));
        try statement.bindInt64(2, limit);
        try statement.bindInt64(3, @intFromBool(acoustid));
        try statement.bindInt64(4, scope.upperBound());
        var items: std.ArrayList(MatchCandidate) = .empty;
        errdefer {
            for (items.items) |item| item.deinit(allocator);
            items.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const title = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(title);
            const artist = try allocator.dupe(u8, statement.columnText(3));
            errdefer allocator.free(artist);
            const album = try allocator.dupe(u8, statement.columnText(4));
            errdefer allocator.free(album);
            const path = try duplicateNullableColumn(allocator, statement, 6);
            errdefer if (path) |value| allocator.free(value);
            try items.append(allocator, .{
                .track_id = statement.columnInt64(0),
                .file_id = statement.columnInt64(1),
                .title = title,
                .artist = artist,
                .album = album,
                .duration_ms = optionalInt64(statement, 5),
                .path = path,
                .needs_musicbrainz = statement.columnInt64(7) != 0,
                .needs_acoustid = statement.columnInt64(8) != 0,
            });
        }
        return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    }

    pub fn unidentifiedCount(
        self: *const IdentificationProposalRepository,
        scope: MatchScope,
        acoustid: bool,
        limit: ?u32,
    ) !u64 {
        var statement = try self.db.prepare(unidentified_count_sql);
        defer statement.deinit();
        try statement.bindInt64(1, scope.lowerBound(0));
        try statement.bindInt64(2, if (limit) |bound| bound else -1);
        try statement.bindInt64(3, @intFromBool(acoustid));
        try statement.bindInt64(4, scope.upperBound());
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

/// A file whose recording ID Orca could send to AcoustID with its fingerprint,
/// as `AcoustIdSubmissionRepository` reads it.
pub const AcoustIdSubmittable = struct {
    file_id: i64,
    track_id: i64,
    recording_mbid: []const u8,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    album_artist: []const u8,
    track_number: ?i64,
    disc_number: ?i64,
    year: ?u32,
    duration_ms: ?i64,
    codec: []const u8,
    size_bytes: i64,
    /// Where the file is, or null when no location of it is present.
    path: ?[]const u8,
    /// The recording's length, from the accepted match that gave the ID.
    recording_length_ms: ?u64,

    /// How far a file's length may be from its recording's before the ID is
    /// doubted and the file's metadata is sent instead, as Picard does.
    pub const maximum_length_difference_ms: u64 = 30_000;

    /// Whether AcoustID is sent the recording ID rather than the metadata. An
    /// unknown length on either side sends the ID.
    pub fn sendsRecordingId(self: AcoustIdSubmittable, file_duration_ms: ?u64) bool {
        const recording = self.recording_length_ms orelse return true;
        const file = file_duration_ms orelse return true;
        const difference = if (file > recording) file - recording else recording - file;
        return difference <= maximum_length_difference_ms;
    }
};

pub const AcoustIdSubmittablePage = struct {
    arena: *std.heap.ArenaAllocator,
    items: []AcoustIdSubmittable,

    pub fn deinit(self: AcoustIdSubmittablePage) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

pub const AcoustIdSubmission = struct {
    file_id: i64,
    recording_mbid: []const u8,
    submission_id: ?i64,
};

pub const AcoustIdSubmissionRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Files after `cursor`, by id, whose recording ID in effect is Orca's own
    /// value from an accepted match or an edit, differs from the file's tag,
    /// and has not been sent for that file.
    pub fn submittablePage(
        self: *const AcoustIdSubmissionRepository,
        allocator: std.mem.Allocator,
        cursor: i64,
        limit: u32,
    ) !AcoustIdSubmittablePage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(acoustid_submittable_page_sql);
        defer statement.deinit();
        try statement.bindInt64(1, cursor);
        try statement.bindInt64(2, limit);
        try bindAcoustIdSubmittable(statement);
        try statement.bindInt64(6, @intFromEnum(ProposalState.accepted));

        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        const page: AcoustIdSubmittablePage = .{ .arena = arena, .items = &.{} };
        errdefer page.deinit();
        const owned = arena.allocator();
        var items: std.ArrayList(AcoustIdSubmittable) = .empty;
        while (try statement.step() == .row) {
            const accepted = ProposalPayload.parse(owned, statement.columnBlob(14)) catch |err| switch (err) {
                error.InvalidProposalPayload => null,
                error.OutOfMemory => return err,
            };
            try items.append(owned, .{
                .file_id = statement.columnInt64(0),
                .track_id = statement.columnInt64(1),
                .recording_mbid = try owned.dupe(u8, statement.columnText(2)),
                .title = try owned.dupe(u8, statement.columnText(3)),
                .artist = try owned.dupe(u8, statement.columnText(4)),
                .album = try owned.dupe(u8, statement.columnText(5)),
                .album_artist = try owned.dupe(u8, statement.columnText(6)),
                .track_number = optionalInt64(statement, 7),
                .disc_number = optionalInt64(statement, 8),
                .year = releaseYear(statement.columnText(9)),
                .duration_ms = optionalInt64(statement, 10),
                .codec = try owned.dupe(u8, statement.columnText(11)),
                .size_bytes = statement.columnInt64(12),
                .path = try duplicateNullableColumn(owned, statement, 13),
                .recording_length_ms = if (accepted) |value| value.value.duration_ms else null,
            });
        }
        return .{ .arena = arena, .items = items.items };
    }

    pub fn submittableCount(self: *const AcoustIdSubmissionRepository) !u64 {
        var statement = try self.db.prepare(acoustid_submittable_count_sql);
        defer statement.deinit();
        try statement.bindInt64(1, 0);
        try bindAcoustIdSubmittable(statement);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// Records what AcoustID accepted, in one transaction.
    pub fn record(self: *AcoustIdSubmissionRepository, submissions: []const AcoustIdSubmission) !void {
        if (submissions.len == 0) return;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var statement = try self.db.prepare(
            \\INSERT INTO acoustid_submissions(file_id, recording_mbid, submission_id, submitted_at)
            \\VALUES (?1, ?2, ?3, unixepoch())
            \\ON CONFLICT(file_id, recording_mbid) DO UPDATE SET
            \\    submission_id=excluded.submission_id, submitted_at=excluded.submitted_at;
        );
        defer statement.deinit();
        for (submissions) |submission| {
            try statement.reset();
            try statement.bindInt64(1, submission.file_id);
            try statement.bindText(2, submission.recording_mbid);
            try statement.bindOptionalInt64(3, submission.submission_id);
            if (try statement.step() != .done) return error.SqlFailed;
        }
        try self.db.exec("COMMIT;");
    }
};

fn releaseYear(release_date: []const u8) ?u32 {
    if (release_date.len < 4) return null;
    const year = std.fmt.parseUnsigned(u32, release_date[0..4], 10) catch return null;
    return if (year == 0) null else year;
}

/// Binds ?3 to ?5 of `acoustid_submittable`.
fn bindAcoustIdSubmittable(statement: sqlite.Statement) !void {
    try statement.bindInt64(3, @intFromEnum(metadata.Field.musicbrainz_recording_id));
    try statement.bindInt64(4, @intFromEnum(metadata.Provenance.provider));
    try statement.bindInt64(5, @intFromEnum(metadata.Provenance.user));
}

/// Files with ids above ?1 whose recording ID in effect is an Orca value of
/// field ?3 with provenance ?4 or ?5, not the file's own tag, not yet sent.
pub const acoustid_submittable =
    "FROM orca_metadata_values AS chosen\n" ++
    "JOIN files ON files.id = chosen.file_id\n" ++
    "JOIN tracks ON tracks.id = (SELECT id FROM tracks WHERE tracks.preferred_file_id = files.id ORDER BY id LIMIT 1)\n" ++
    "WHERE chosen.file_id > ?1 AND chosen.field = ?3 AND chosen.provenance IN (?4, ?5)\n" ++
    "  AND NULLIF(chosen.value, '') IS NOT NULL\n" ++
    "  AND " ++ effectiveRecordingMbid("files.id") ++ " = chosen.value\n" ++
    "  AND NOT EXISTS (SELECT 1 FROM observed_file_tags WHERE observed_file_tags.file_id = files.id\n" ++
    "      AND observed_file_tags.musicbrainz_recording_id = chosen.value)\n" ++
    "  AND NOT EXISTS (SELECT 1 FROM acoustid_submissions WHERE acoustid_submissions.file_id = files.id\n" ++
    "      AND acoustid_submissions.recording_mbid = chosen.value)";

pub const acoustid_submittable_page_sql =
    "SELECT files.id, tracks.id, chosen.value, tracks.title, tracks.artist, tracks.album, tracks.album_artist,\n" ++
    "       tracks.track_number, tracks.disc_number,\n" ++
    "       COALESCE((SELECT release_date FROM releases WHERE releases.id = tracks.release_id), ''),\n" ++
    "       files.duration_ms, files.codec, files.size_bytes,\n" ++
    "       (SELECT uri FROM locations WHERE locations.file_id = files.id AND locations.state = 'present'\n" ++
    "        ORDER BY locations.id LIMIT 1),\n" ++
    "       (SELECT payload FROM identification_proposals WHERE identification_proposals.file_id = files.id\n" ++
    "        AND identification_proposals.provider_id = chosen.value AND identification_proposals.state = ?6\n" ++
    "        ORDER BY identification_proposals.updated_at DESC LIMIT 1)\n" ++
    acoustid_submittable ++ "\nORDER BY chosen.file_id LIMIT ?2;";

pub const acoustid_submittable_count_sql = "SELECT count(*) " ++ acoustid_submittable ++ ";";

/// Reads `id, provider, provider_id, confidence, payload` starting at `first`.
/// A payload that does not parse leaves the provider's fields empty.
fn readMatchProposal(owned: std.mem.Allocator, statement: sqlite.Statement, first: c_int) !MatchProposal {
    const payload = ProposalPayload.parse(owned, statement.columnBlob(first + 4)) catch |err| switch (err) {
        error.InvalidProposalPayload => null,
        error.OutOfMemory => return err,
    };
    const said: ProposalPayload = if (payload) |parsed| parsed.value else .{};
    return .{
        .id = statement.columnInt64(first),
        .provider = try owned.dupe(u8, statement.columnText(first + 1)),
        .recording_mbid = try owned.dupe(u8, statement.columnText(first + 2)),
        .confidence = @floatCast(statement.columnDouble(first + 3)),
        .title = said.title,
        .artist = said.artist,
        .album = said.album,
        .track_number = said.track_number,
        .release_mbid = said.release_mbid,
        .duration_ms = said.duration_ms,
        .musicbrainz_score = said.mb_score,
        .acoustid_score = said.acoustid_score,
    };
}

const confident_batch_sql =
    \\SELECT candidate.id FROM identification_proposals AS candidate
    \\WHERE candidate.state = ?4 AND candidate.confidence >= ?1 AND candidate.id > ?2
    \\  AND NOT EXISTS (
    \\    SELECT 1 FROM identification_proposals AS rival
    \\    WHERE rival.file_id = candidate.file_id AND rival.state = ?4
    \\      AND rival.confidence >= ?1 AND rival.id <> candidate.id)
    \\ORDER BY candidate.id LIMIT ?3;
;

/// The best pending proposal (state ?3) for the Track in scope as `tracks`, in
/// the order `pendingForTrack` lists them.
const best_pending_proposal =
    "(SELECT id FROM identification_proposals\n" ++
    "    WHERE file_id = " ++ track_play_file ++ " AND state = ?3\n" ++
    "    ORDER BY confidence DESC, id LIMIT 1)";

pub const review_page_sql =
    "SELECT tracks.id, tracks.title, tracks.artist, tracks.album, tracks.duration_ms,\n" ++
    "       (SELECT count(*) FROM identification_proposals AS pending\n" ++
    "        WHERE pending.file_id = best.file_id AND pending.state = ?3),\n" ++
    "       best.id, best.provider, best.provider_id, best.confidence, best.payload\n" ++
    "FROM tracks JOIN identification_proposals AS best ON best.id = " ++ best_pending_proposal ++ "\n" ++
    "ORDER BY " ++ orderTerms(.artist, .ascending) ++ "\nLIMIT ?1 OFFSET ?2;";

pub const review_count_sql =
    "SELECT count(*) FROM tracks WHERE " ++ best_pending_proposal ++ " IS NOT NULL;";

fn searched(comptime provider: IdentificationProvider) []const u8 {
    return "EXISTS (SELECT 1 FROM identification_searches\n" ++
        "    WHERE identification_searches.file_id = track.file_id\n" ++
        "      AND identification_searches.provider = '" ++ provider.text() ++ "')";
}

const needs_musicbrainz = "NOT " ++ searched(.musicbrainz);
/// ?3 is whether AcoustID is in scope.
const needs_acoustid = "(?3 AND NOT " ++ searched(.acoustid) ++ ")";

/// Tracks with ids in (?1, ?4] whose play file has no recording id and has not
/// been answered for by MusicBrainz, or by AcoustID when ?3 is set. The
/// matching job's page and its count share it so they agree.
pub const unidentified_tracks =
    "(SELECT tracks.id, " ++ track_play_file ++ " AS file_id,\n" ++
    "        tracks.title, tracks.artist, tracks.album, tracks.duration_ms\n" ++
    "    FROM tracks WHERE tracks.id > ?1 AND tracks.id <= ?4) AS track\n" ++
    "WHERE track.file_id IS NOT NULL\n" ++
    "  AND " ++ effectiveRecordingMbid("track.file_id") ++ " IS NULL\n" ++
    "  AND (" ++ needs_musicbrainz ++ " OR " ++ needs_acoustid ++ ")";

pub const unidentified_page_sql =
    "SELECT track.id, track.file_id, track.title, track.artist, track.album, track.duration_ms,\n" ++
    "       (SELECT locations.uri FROM locations\n" ++
    "        WHERE locations.file_id = track.file_id AND locations.state = 'present'\n" ++
    "        ORDER BY locations.id LIMIT 1),\n" ++
    "       " ++ needs_musicbrainz ++ ", " ++ needs_acoustid ++ "\n" ++
    "FROM " ++ unidentified_tracks ++ "\nORDER BY track.id LIMIT ?2;";

pub const unidentified_count_sql =
    "SELECT count(*) FROM (SELECT 1 FROM " ++ unidentified_tracks ++ " LIMIT ?2);";

/// Binds ?3 to ?6 of `unanalyzed_predicate`. The cursor and limit stay ?1 and
/// ?2 so the selector can be appended to any paged query without renumbering.
fn bindAnalysisSelector(statement: sqlite.Statement, selector: *const AnalysisSelector) !void {
    try statement.bindInt64(3, selector.kind);
    try statement.bindText(4, selector.algorithm_id);
    try statement.bindInt64(5, selector.algorithm_version);
    try statement.bindBlob(6, &selector.parameter_hash);
}

fn bindAnalysisKey(statement: sqlite.Statement, key: *const AnalysisCacheKey) !void {
    try statement.bindInt64(1, key.file_id);
    try statement.bindInt64(2, key.kind);
    try statement.bindText(3, key.algorithm_id);
    try statement.bindInt64(4, key.algorithm_version);
    try statement.bindBlob(5, &key.parameter_hash);
    try statement.bindBlob(6, &key.source_identity);
}

fn digestColumn(statement: sqlite.Statement, column: c_int) ?quick_hash.Digest {
    const bytes = statement.columnBlob(column);
    if (bytes.len != @typeInfo(quick_hash.Digest).array.len) return null;
    var digest: quick_hash.Digest = undefined;
    @memcpy(&digest, bytes);
    return digest;
}

/// A 32-byte BLAKE3 column, or null when the row has none or the stored blob
/// is not one. A short blob is corruption rather than an answer, and treating
/// it as null keeps a duplicate scan from bucketing files together on a
/// truncated key.
fn audioHashColumn(statement: sqlite.Statement, column: c_int) ?[32]u8 {
    const bytes = statement.columnBlob(column);
    if (bytes.len != 32) return null;
    var digest: [32]u8 = undefined;
    @memcpy(&digest, bytes);
    return digest;
}

fn duplicateNullableColumn(
    allocator: std.mem.Allocator,
    statement: sqlite.Statement,
    column: c_int,
) !?[]u8 {
    if (statement.columnIsNull(column)) return null;
    return try allocator.dupe(u8, statement.columnText(column));
}

fn validMutationTransition(from: MutationState, to: MutationState) bool {
    if (to == .needs_reconciliation) return from != .rolled_back and
        from != .needs_reconciliation;
    return switch (from) {
        .planned => to == .staged or to == .failed,
        .staged => to == .committed or to == .rolled_back or to == .failed,
        .failed => to == .rolled_back,
        .committed => to == .rolled_back,
        .rolled_back, .needs_reconciliation => false,
    };
}
