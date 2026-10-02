//! Controlled C-compatible boundary for Swift and other foreign frontends.
//! No internal Zig containers or object pointers cross this module.
//!
//! Threading: every `orca_*` call for one runtime must come from a single
//! thread, `orca_runtime_poll_event` included. Debug builds enforce it rather
//! than merely documenting it — see `RuntimeBox.foreignThread`. The runtime
//! behind this boundary is genuinely multithreaded (a decode engine per Player,
//! a registered worker per scan) and its object pools take no lock, so a GUI
//! timer racing `orca_runtime_destroy` is a real use-after-free and not a
//! theoretical one.
const builtin = @import("builtin");
const std = @import("std");
const analysis_pass = @import("library/analysis_pass.zig");
const audio = @import("audio/root.zig");
const control = @import("core/control.zig");
const core = @import("core/root.zig");
const database = @import("database/root.zig");
const job = @import("core/job.zig");
const metadata = @import("metadata/root.zig");
const network = @import("network/root.zig");
const providers = @import("providers/root.zig");
const version = @import("version.zig");

pub const Runtime = opaque {};

pub const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    runtime_not_running = 2,
    stale_handle = 3,
    out_of_memory = 4,
    invalid_state = 5,
    not_found = 6,
    busy = 7,
    unsupported = 8,
    wrong_thread = 9,
    already_done = 10,
    needs_reconciliation = 11,
    gone = 12,
    internal = 255,
};

pub const Handle = extern struct {
    index: u32,
    generation: u32,
};

pub const StringView = extern struct {
    pointer: [*]const u8,
    length: usize,
};

pub const TrackView = extern struct {
    id: i64,
    duration_ms: i64,
    track_number: i64,
    disc_number: i64,
    has_duration: u8,
    has_track_number: u8,
    has_disc_number: u8,
    has_file: u8,
    feedback: u8,
    has_rating: u8,
    rating: u8,
    _reserved: [1]u8 = @splat(0),
    title: StringView,
    artist: StringView,
    album: StringView,
    album_artist: StringView,
};

pub const TrackCallback = *const fn (?*anyopaque, *const TrackView) callconv(.c) void;

pub const TrackSortKey = enum(u8) {
    id = 0,
    artist = 1,
    album = 2,
    title = 3,
    track_number = 4,
    duration = 5,
    date_added = 6,
    rating = 7,
    loved = 8,
};

/// The POD form of `database.TrackQuery`. Negative ids mean "no filter",
/// because a filter is either present or absent and a nullable pointer per
/// field would be worse for every caller.
pub const TrackQueryView = extern struct {
    artist_id: i64,
    release_id: i64,
    sort: u8,
    descending: u8,
    loved_only: u8,
    _reserved: [1]u8 = @splat(0),
    limit: u32,
    offset: u32,
};

/// A string a host hands in, whose pointer may be null when it is empty.
/// Outgoing views use `StringView`, which is never null.
const StringInput = extern struct {
    pointer: ?[*]const u8,
    length: usize,
};

pub const ArtistView = extern struct {
    id: i64,
    release_count: u32,
    track_count: u32,
    name: StringView,
    sort_name: StringView,
};

pub const ArtistCallback = *const fn (?*anyopaque, *const ArtistView) callconv(.c) void;

pub const ReleaseView = extern struct {
    id: i64,
    album_artist_id: i64,
    disc_count: i64,
    total_duration_ms: i64,
    track_count: u32,
    has_album_artist_id: u8,
    has_disc_count: u8,
    is_compilation: u8,
    loved: u8,
    _reserved: [2]u8 = @splat(0),
    title: StringView,
    album_artist: StringView,
    release_date: StringView,
};

pub const ReleaseCallback = *const fn (?*anyopaque, *const ReleaseView) callconv(.c) void;

pub const ReleaseQueryView = extern struct {
    album_artist_id: i64,
    sort: u8,
    loved_only: u8,
    _reserved: [2]u8 = @splat(0),
    limit: u32,
    offset: u32,
};

pub const ArtistQueryView = extern struct {
    filter: StringInput,
    limit: u32,
    offset: u32,
};

pub const TrackSummaryView = extern struct {
    track: TrackView,
    release_id: i64,
    artist_id: i64,
    recording_id: i64,
    has_release_id: u8,
    has_artist_id: u8,
    has_recording_id: u8,
    _reserved: [5]u8 = @splat(0),
};

pub const TrackSummaryCallback = *const fn (?*anyopaque, *const TrackSummaryView) callconv(.c) void;

pub const IdSource = enum(u8) {
    none = 0,
    tag = 1,
    match = 2,
    edit = 3,
};

pub const TrackDetailsView = extern struct {
    track_id: i64,
    track_number: i64,
    disc_number: i64,
    duration_ms: i64,
    size_bytes: i64,
    last_played_at: i64,
    play_count: u64,
    title: StringView,
    artist: StringView,
    album: StringView,
    album_artist: StringView,
    date: StringView,
    codec: StringView,
    path: StringView,
    musicbrainz_recording_id: StringView,
    musicbrainz_release_id: StringView,
    musicbrainz_release_group_id: StringView,
    musicbrainz_release_track_id: StringView,
    musicbrainz_album_artist_id: StringView,
    sample_rate: u32,
    bit_depth: u32,
    channels: u32,
    bitrate_kbps: u32,
    integrated_lufs: f32,
    replay_gain_db: f32,
    sample_peak: f32,
    has_track_number: u8,
    has_disc_number: u8,
    has_compilation: u8,
    compilation: u8,
    lossy: u8,
    has_sample_rate: u8,
    has_bit_depth: u8,
    has_channels: u8,
    has_duration: u8,
    has_size_bytes: u8,
    has_bitrate_kbps: u8,
    file_missing: u8,
    has_loudness: u8,
    has_artwork: u8,
    has_last_played_at: u8,
    feedback: u8,
    feedback_syncable: u8,
    has_rating: u8,
    rating: u8,
    musicbrainz_recording_id_source: u8,
    musicbrainz_release_id_source: u8,
    musicbrainz_release_group_id_source: u8,
    musicbrainz_release_track_id_source: u8,
    musicbrainz_album_artist_id_source: u8,
    _reserved: [4]u8 = @splat(0),
};

pub const TrackDetailsCallback = *const fn (?*anyopaque, *const TrackDetailsView) callconv(.c) void;

pub const ChangeCount = extern struct {
    updated: u32,
    skipped: u32,
};

pub const PlaylistView = extern struct {
    id: i64,
    duration_ms: i64,
    created_at: i64,
    updated_at: i64,
    entries: u32,
    available: u32,
    name: StringView,
};

pub const PlaylistCallback = *const fn (?*anyopaque, *const PlaylistView) callconv(.c) void;

pub const PlaylistEntryView = extern struct {
    recording_id: i64,
    position: u32,
    has_track: u8,
    _reserved: [3]u8 = @splat(0),
    track: TrackView,
};

pub const PlaylistEntryCallback = *const fn (?*anyopaque, *const PlaylistEntryView) callconv(.c) void;

pub const PlaylistImport = extern struct {
    playlist_id: i64,
    matched_by_path: u32,
    matched_by_info: u32,
    unmatched: u32,
    _reserved: u32 = 0,
};

pub const LineCallback = *const fn (?*anyopaque, StringView) callconv(.c) void;

pub const ImageView = extern struct {
    bytes: [*]const u8,
    length: usize,
    mime_type: StringView,
    kind: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const ImageCallback = *const fn (?*anyopaque, *const ImageView) callconv(.c) void;

pub const ArtworkResultView = extern struct {
    request: u64,
    subject_id: i64,
    subject: u8,
    has_image: u8,
    _reserved: [6]u8 = @splat(0),
    image: ImageView,
};

pub const ArtworkResultCallback = *const fn (?*anyopaque, *const ArtworkResultView) callconv(.c) void;

pub const TrackEditView = extern struct {
    field: u8,
    has_value: u8,
    _reserved: [6]u8 = @splat(0),
    value: StringInput,
};

pub const IdCallback = *const fn (?*anyopaque, [*]const i64, usize) callconv(.c) void;

pub const FieldValueView = extern struct {
    field: u8,
    provenance: u8,
    locked: u8,
    _reserved: [5]u8 = @splat(0),
    text: StringView,
};

pub const FieldValueCallback = *const fn (?*anyopaque, *const FieldValueView) callconv(.c) void;

pub const TagWriteDigest = extern struct {
    bytes: [@sizeOf(metadata.mutation.Digest)]u8,
};

pub const TagWriteChangeView = extern struct {
    field: u8,
    provenance: u8,
    has_before: u8,
    _reserved: [5]u8 = @splat(0),
    before: StringView,
    after: StringView,
};

pub const TagWriteFileView = extern struct {
    file_id: i64,
    path: StringView,
    changes: [*]const TagWriteChangeView,
    change_count: usize,
};

pub const TagWriteConflictView = extern struct {
    file_id: i64,
    field: u8,
    provenance: u8,
    _reserved: [6]u8 = @splat(0),
    path: StringView,
    file_value: StringView,
    orca_value: StringView,
};

pub const TagWriteSkipView = extern struct {
    file_id: i64,
    reason: u8,
    _reserved: [7]u8 = @splat(0),
    path: StringView,
};

pub const TagWritePlanView = extern struct {
    plan_id: u64,
    digest: TagWriteDigest,
    files: [*]const TagWriteFileView,
    file_count: usize,
    conflicts: [*]const TagWriteConflictView,
    conflict_count: usize,
    skipped: [*]const TagWriteSkipView,
    skip_count: usize,
};

pub const TagWritePlanCallback = *const fn (?*anyopaque, *const TagWritePlanView) callconv(.c) void;

pub const PlayStatsView = extern struct {
    play_count: u64,
    last_played_at: i64,
    has_last_played_at: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const HealthIssueView = extern struct {
    kind: u8,
    severity: u8,
    _reserved: [6]u8 = @splat(0),
    path: StringView,
    details: StringView,
};

pub const HealthIssueCallback = *const fn (?*anyopaque, *const HealthIssueView) callconv(.c) void;

pub const HealthItemView = extern struct {
    file_id: i64,
    track_id: i64,
    release_id: i64,
    related_file_id: i64,
    kind: u8,
    severity: u8,
    action: u8,
    has_track_id: u8,
    has_release_id: u8,
    has_related_file_id: u8,
    _reserved: [2]u8 = @splat(0),
    path: StringView,
    details: StringView,
};

pub const HealthItemCallback = *const fn (?*anyopaque, *const HealthItemView) callconv(.c) void;

pub const HealthFileView = extern struct {
    file_id: i64,
    size_bytes: i64,
    duration_ms: i64,
    sample_rate: u32,
    bit_depth: u32,
    channels: u32,
    missing: u8,
    has_path: u8,
    has_size_bytes: u8,
    has_duration_ms: u8,
    has_sample_rate: u8,
    has_bit_depth: u8,
    has_channels: u8,
    _reserved: [5]u8 = @splat(0),
    path: StringView,
    codec: StringView,
};

pub const HealthFileCallback = *const fn (?*anyopaque, *const HealthFileView) callconv(.c) void;

pub const RootView = extern struct {
    id: i64,
    volume_id: i64,
    enabled: u8,
    _reserved: [7]u8 = @splat(0),
    path: StringView,
};

pub const RootCallback = *const fn (?*anyopaque, *const RootView) callconv(.c) void;

pub const DeviceView = extern struct {
    id: u64,
    name: StringView,
};

pub const DeviceCallback = *const fn (?*anyopaque, *const DeviceView) callconv(.c) void;

pub const QueueEntryView = extern struct {
    position: u32,
    is_current: u8,
    _reserved: [3]u8 = @splat(0),
    track_id: i64,
};

pub const QueueEntryCallback = *const fn (?*anyopaque, *const QueueEntryView) callconv(.c) void;

pub const QueueStats = extern struct {
    entries_started: u64,
    gapless_transitions: u64,
    format_switch_transitions: u64,
    open_failures: u64,
    decode_errors: u64,
};

pub const NowPlayingView = extern struct {
    track_id: i64,
    duration_ms: i64,
    has_duration: u8,
    _reserved: [7]u8 = @splat(0),
    title: StringView,
    artist: StringView,
    album: StringView,
    album_artist: StringView,
};

pub const NowPlayingCallback = *const fn (?*anyopaque, *const NowPlayingView) callconv(.c) void;

pub const PlayerStatus = extern struct {
    transport: u8,
    repeat: u8,
    shuffle: u8,
    has_track: u8,
    epoch: u32,
    position_ms: u64,
    duration_ms: u64,
    track_id: i64,
    queue_length: u32,
    queue_index: u32,
    volume: f32,
    _reserved: [4]u8 = @splat(0),
};

pub const EqualizerView = extern struct {
    gains_db: [audio.dsp.band_count]f32,
    preamp_db: f32,
};

pub const PcmFormatView = extern struct {
    sample_rate: u32,
    channels: u16,
    bits_per_sample: u16,
    bytes_per_frame: u16,
    sample_format: u8,
    _reserved: [1]u8 = @splat(0),
};

const signal_max_reasons = 8;

comptime {
    std.debug.assert(audio.dsp.SignalPath.max_reasons <= signal_max_reasons);
}

pub const SignalPathView = extern struct {
    source: PcmFormatView,
    output: PcmFormatView,
    equalizer: EqualizerView,
    replay_gain_db: f32,
    crossfeed: f32,
    volume: f32,
    device_rate: u32,
    reason_count: u32,
    reasons: [signal_max_reasons]u8,
    has_source: u8,
    source_declared: u8,
    has_output: u8,
    has_replay_gain: u8,
    has_equalizer: u8,
    has_crossfeed: u8,
    has_device_rate: u8,
    bit_perfect_eligible: u8,
    widened_exactly: u8,
    _reserved: [7]u8 = @splat(0),
    codec: StringView,
};

pub const SignalPathCallback = *const fn (?*anyopaque, *const SignalPathView) callconv(.c) void;

pub const ZoneStatus = extern struct {
    output_state: u8,
    _reserved: [3]u8 = @splat(0),
    recovery_attempts: u32,
    backend_quantum_frames: u32,
    rendered_entry_serial: u32,
    underruns: u64,
    dropped_returns: u64,
};

pub const JobSnapshot = extern struct {
    kind: u8,
    state: u8,
    has_total: u8,
    _reserved: [5]u8 = @splat(0),
    completed_units: u64,
    total_units: u64,
};

pub const ScanStats = extern struct {
    files_seen: u64,
    changed: u64,
    unchanged: u64,
    unsupported: u64,
    errors: u64,
    batches_committed: u64,
    folders_visited: u64,
    files_projected: u64,
    tracks_written: u64,
    releases_written: u64,
    cancelled: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const ScanOptions = extern struct {
    batch_size: u32,
    _reserved: [4]u8 = @splat(0),
};

pub const AnalysisOptions = extern struct {
    /// Files per selected page and per bounded commit. Zero selects the
    /// default, which is much smaller than a scan's because one unit of this
    /// job's work is a whole file decoded end to end.
    batch_size: u32,
    /// Files decoded at once. Zero selects `orca_analysis_default_threads`.
    threads: u16 = 0,
    _reserved: [2]u8 = @splat(0),
};

pub const DuplicateScanOptions = extern struct {
    /// Files per selected page and per bounded commit. Zero selects the
    /// default.
    batch_size: u32,
    _reserved: [4]u8 = @splat(0),
};

pub const BackfillOptions = extern struct {
    batch_size: u32,
    /// Nonzero re-probes rows that already declare properties.
    force: u8 = 0,
    _reserved: [3]u8 = @splat(0),
};

pub const EventKind = enum(u8) {
    none = 0,
    command_completed = 1,
    job_progress = 2,
    job_finished = 3,
    player_position = 4,
    library_changed = 5,
};

pub const CommandCompletedEvent = extern struct {
    request_id: u64,
    outcome: u8,
    failure: u8,
    _reserved: [6]u8 = @splat(0),
    object: Handle,
};

pub const JobProgressEvent = extern struct {
    job: Handle,
    has_total: u8,
    _reserved: [7]u8 = @splat(0),
    completed_units: u64,
    total_units: u64,
};

pub const JobFinishedEvent = extern struct {
    job: Handle,
    state: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const PlayerPositionEvent = extern struct {
    player: Handle,
    _reserved: u32 = 0,
    frames: u64,
};

pub const LibraryChangedEvent = extern struct {
    library: Handle,
};

/// A named `extern union` rather than opaque a/b/c fields: ABI-stable, it
/// imports cleanly into Swift, and it keeps the header self-documenting.
pub const EventPayload = extern union {
    command_completed: CommandCompletedEvent,
    job_progress: JobProgressEvent,
    job_finished: JobFinishedEvent,
    player_position: PlayerPositionEvent,
    library_changed: LibraryChangedEvent,
};

pub const WatchOptions = extern struct {
    quiet_ms: u32,
    max_delay_ms: u32,
    degraded_rescan_ms: u32,
    _reserved: [4]u8 = @splat(0),
};

pub const WatchStatus = extern struct {
    state: u8,
    watch_limit_reached: u8,
    reconcile_pending: u8,
    reconcile_running: u8,
    roots_watched: u32,
    roots_unavailable: u32,
    roots_degraded: u32,
    directories_watched: u64,
};

pub const Event = extern struct {
    kind: u8,
    _reserved: [7]u8 = @splat(0),
    payload: EventPayload,
};

pub const MatchOptions = extern struct {
    batch_size: u32,
    limit: u32,
    track_id: i64,
    release_id: i64,
    accept_minimum_confidence: f32,
    mode: u8,
    has_limit: u8,
    has_track_id: u8,
    has_release_id: u8,
    skip_fingerprints: u8,
    has_accept_minimum_confidence: u8,
    cover_art: u8,
    _reserved: [5]u8 = @splat(0),
};

pub const MatchStatsView = extern struct {
    tracks_examined: u64,
    matched: u64,
    unmatched: u64,
    insufficient_evidence: u64,
    refused: u64,
    proposals_stored: u64,
    confirmed: u64,
    verified: u64,
    agreed: u64,
    disagreed: u64,
    unconfirmed: u64,
    skipped: u64,
    correction_groups: u64,
    requests: u64,
    cache_hits: u64,
    fingerprinted: u64,
    fingerprint_cache_hits: u64,
    fingerprint_failures: u64,
    acoustid_requests: u64,
    acoustid_cache_hits: u64,
    acoustid_refused: u64,
    accepted: u64,
    acoustid: u8,
    busy: u8,
    cover_art: u8,
    cancelled: u8,
    _reserved: [4]u8 = @splat(0),
};

pub const SubmissionStatsView = extern struct {
    files_examined: u64,
    submitted: u64,
    sent_as_metadata: u64,
    fingerprinted: u64,
    fingerprint_cache_hits: u64,
    fingerprint_failures: u64,
    rejected: u64,
    requests: u64,
    outcome: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const AcoustIdSubmittableView = extern struct {
    file_id: i64,
    track_id: i64,
    track_number: i64,
    disc_number: i64,
    duration_ms: i64,
    size_bytes: i64,
    recording_length_ms: u64,
    year: u32,
    has_track_number: u8,
    has_disc_number: u8,
    has_year: u8,
    has_duration_ms: u8,
    has_recording_length_ms: u8,
    has_path: u8,
    _reserved: [2]u8 = @splat(0),
    recording_mbid: StringView,
    title: StringView,
    artist: StringView,
    album: StringView,
    album_artist: StringView,
    codec: StringView,
    path: StringView,
};

pub const AcoustIdSubmittableCallback = *const fn (?*anyopaque, *const AcoustIdSubmittableView) callconv(.c) void;

pub const MatchProposalView = extern struct {
    id: i64,
    duration_ms: u64,
    provider: StringView,
    recording_mbid: StringView,
    title: StringView,
    artist: StringView,
    album: StringView,
    release_mbid: StringView,
    track_title: StringView,
    track_artist: StringView,
    release_title: StringView,
    release_artist: StringView,
    release_date: StringView,
    release_group_mbid: StringView,
    release_track_mbid: StringView,
    corrects: StringView,
    confidence: f32,
    acoustid_score: f32,
    track_number: u32,
    disc_number: u32,
    musicbrainz_score: u8,
    has_track_number: u8,
    has_disc_number: u8,
    has_release_mbid: u8,
    has_duration_ms: u8,
    has_musicbrainz_score: u8,
    has_acoustid_score: u8,
    has_track_title: u8,
    has_track_artist: u8,
    has_release_title: u8,
    has_release_artist: u8,
    has_release_date: u8,
    has_release_group_mbid: u8,
    has_release_track_mbid: u8,
    has_corrects: u8,
    _reserved: [1]u8 = @splat(0),
};

pub const MatchProposalCallback = *const fn (?*anyopaque, *const MatchProposalView) callconv(.c) void;

pub const MatchAcceptanceView = extern struct {
    file_id: i64,
    values_written: u32,
    _reserved: [4]u8 = @splat(0),
};

pub const ConfidentAcceptanceView = extern struct {
    accepted: u64,
    values_written: u64,
};

pub const MatchReviewView = extern struct {
    track_id: i64,
    duration_ms: i64,
    proposal_count: u32,
    has_duration_ms: u8,
    _reserved: [3]u8 = @splat(0),
    title: StringView,
    artist: StringView,
    album: StringView,
    best: MatchProposalView,
};

pub const MatchReviewCallback = *const fn (?*anyopaque, *const MatchReviewView) callconv(.c) void;

pub const HeardRecordingView = extern struct {
    mbid: StringView,
    score: f32,
    _reserved: [4]u8 = @splat(0),
};

pub const TrackVerificationView = extern struct {
    verified_at: i64,
    recording_mbid: StringView,
    heard: [*]const HeardRecordingView,
    heard_count: usize,
    outcome: u8,
    stale: u8,
    dismissed: u8,
    _reserved: [5]u8 = @splat(0),
};

pub const TrackVerificationCallback = *const fn (?*anyopaque, *const TrackVerificationView) callconv(.c) void;

pub const CorrectionMemberView = extern struct {
    proposal_id: i64,
    track_id: i64,
    file_id: i64,
    track_number: i64,
    disc_number: i64,
    title: StringView,
    proposed_title: StringView,
    recording_mbid: StringView,
    corrects: StringView,
    proposed_track_number: u32,
    proposed_disc_number: u32,
    has_track_id: u8,
    has_track_number: u8,
    has_disc_number: u8,
    has_proposed_track_number: u8,
    has_proposed_disc_number: u8,
    has_corrects: u8,
    _reserved: [2]u8 = @splat(0),
};

pub const CorrectionGroupView = extern struct {
    group_id: i64,
    release_id: i64,
    has_release_id: u8,
    _reserved: [7]u8 = @splat(0),
    album: StringView,
    album_artist: StringView,
    members: [*]const CorrectionMemberView,
    member_count: usize,
};

pub const CorrectionGroupCallback = *const fn (?*anyopaque, *const CorrectionGroupView) callconv(.c) void;

/// A foreign frontend cannot hand Orca a `std.Io`, so the boundary owns one.
/// It is the synchronous, allocation-free implementation: liborca performs no
/// async I/O, and a host's event loop must never be co-opted by the ABI.
const RuntimeBox = struct {
    runtime: core.OrcaRuntime,
    threaded: std.Io.Threaded,
    /// The thread that created this runtime. Every later call must come from
    /// it. Recorded unconditionally; only checked in debug builds, where the
    /// cost of one comparison per call buys a whole class of bug report.
    owner_thread: std.Thread.Id,
    last_error: [last_error_capacity:0]u8 = @splat(0),
    credential: CredentialSlot = .{},

    fn io(self: *RuntimeBox) std.Io {
        return self.threaded.io();
    }

    fn reject(
        self: *RuntimeBox,
        comptime source: std.builtin.SourceLocation,
        status: Status,
        message: []const u8,
    ) Status {
        self.recordError(source.fn_name, message);
        return status;
    }

    fn fail(self: *RuntimeBox, comptime source: std.builtin.SourceLocation, err: anyerror) Status {
        self.recordError(source.fn_name, @errorName(err));
        return mapError(err);
    }

    fn recordError(self: *RuntimeBox, function: []const u8, message: []const u8) void {
        var length: usize = 0;
        for ([_][]const u8{ function, ": ", message }) |part| {
            const copied = @min(part.len, last_error_capacity - length);
            @memcpy(self.last_error[length..][0..copied], part[0..copied]);
            length += copied;
        }
        if (length < last_error_capacity) self.last_error[length] = 0;
    }

    /// True when the caller is violating the single-thread contract. Release
    /// builds never report a violation: the check exists to catch the mistake
    /// during development, not to make the boundary thread-safe.
    fn foreignThread(self: *const RuntimeBox) bool {
        if (builtin.mode != .Debug) return false;
        return std.Thread.getCurrentId() != self.owner_thread;
    }
};

const last_error_capacity = 255;

pub export fn orca_version() callconv(.c) [*:0]const u8 {
    return std.fmt.comptimePrint("{f}", .{version.value});
}

pub export fn orca_analysis_available_threads() callconv(.c) u16 {
    return analysis_pass.availableThreads();
}

pub export fn orca_analysis_default_threads() callconv(.c) u16 {
    return analysis_pass.defaultThreads();
}

pub export fn orca_runtime_last_error(runtime: ?*const Runtime) callconv(.c) [*:0]const u8 {
    const box: *const RuntimeBox = @ptrCast(@alignCast(runtime orelse return ""));
    if (box.foreignThread()) return "";
    return &box.last_error;
}

pub export fn orca_runtime_create() callconv(.c) ?*Runtime {
    const box = std.heap.c_allocator.create(RuntimeBox) catch return null;
    box.* = .{
        .runtime = .init(std.heap.c_allocator),
        .threaded = .init_single_threaded,
        .owner_thread = std.Thread.getCurrentId(),
    };
    return @ptrCast(box);
}

pub export fn orca_runtime_destroy(runtime: ?*Runtime) callconv(.c) void {
    const box = runtimeBox(runtime) orelse return;
    box.runtime.deinit();
    box.threaded.deinit();
    std.heap.c_allocator.destroy(box);
}

pub export fn orca_library_open(
    runtime: ?*Runtime,
    path: ?[*:0]const u8,
    output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const path_pointer = path orelse return box.reject(@src(), .invalid_argument, "path is null");
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const library = box.runtime.openLibrary(box.io(), std.mem.span(path_pointer)) catch |err|
        return box.fail(@src(), err);
    destination.* = exportLibraryHandle(library);
    return .ok;
}

pub export fn orca_library_close(runtime: ?*Runtime, library: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.destroyLibrary(importLibrary(library)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_track_count(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    destination.* = box.runtime.libraryTrackCount(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_query_tracks(
    runtime: ?*Runtime,
    library: Handle,
    query_pointer: ?[*]const u8,
    query_length: usize,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?TrackCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    const query = if (query_pointer) |pointer|
        pointer[0..query_length]
    else if (query_length == 0)
        ""
    else
        return box.reject(@src(), .invalid_argument, "query is null and query_length is not zero");
    var page = box.runtime.libraryTrackPage(
        importLibrary(library),
        query,
        limit,
        offset,
    ) catch |err| return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view = trackView(item);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_health_issue_count(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    destination.* = box.runtime.libraryHealthIssueCount(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_query_health_issues(
    runtime: ?*Runtime,
    library: Handle,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?HealthIssueCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    var page = box.runtime.libraryHealthIssuePage(
        importLibrary(library),
        limit,
        offset,
    ) catch |err| return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view: HealthIssueView = .{
            .kind = @intFromEnum(item.kind),
            .severity = @intFromEnum(item.severity),
            .path = stringView(item.path),
            .details = stringView(item.details),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_query_health_items(
    runtime: ?*Runtime,
    library: Handle,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?HealthItemCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    var page = box.runtime.libraryHealthIssuePage(
        importLibrary(library),
        limit,
        offset,
    ) catch |err| return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view: HealthItemView = .{
            .file_id = item.file_id,
            .track_id = item.track_id orelse 0,
            .release_id = item.release_id orelse 0,
            .related_file_id = item.related_file_id orelse 0,
            .kind = exportHealthIssueKind(item.kind),
            .severity = exportHealthSeverity(item.severity),
            .action = exportHealthAction(item.action),
            .has_track_id = @intFromBool(item.track_id != null),
            .has_release_id = @intFromBool(item.release_id != null),
            .has_related_file_id = @intFromBool(item.related_file_id != null),
            .path = stringView(item.path),
            .details = stringView(item.details),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_dismiss_health_issue(
    runtime: ?*Runtime,
    library: Handle,
    file_id: i64,
    kind: u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const issue_kind = importHealthIssueKind(kind) orelse
        return box.reject(@src(), .invalid_argument, "kind is not an orca_health_issue_kind");
    box.runtime.libraryDismissHealthIssue(importLibrary(library), file_id, issue_kind) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_restore_health_issue(
    runtime: ?*Runtime,
    library: Handle,
    file_id: i64,
    kind: u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const issue_kind = importHealthIssueKind(kind) orelse
        return box.reject(@src(), .invalid_argument, "kind is not an orca_health_issue_kind");
    box.runtime.libraryRestoreHealthIssue(importLibrary(library), file_id, issue_kind) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_health_file(
    runtime: ?*Runtime,
    library: Handle,
    file_id: i64,
    context: ?*anyopaque,
    callback: ?HealthFileCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const found = box.runtime.libraryHealthFile(importLibrary(library), box.runtime.allocator, file_id) catch |err|
        return box.fail(@src(), err);
    const file = found orelse return box.reject(@src(), .not_found, "no such file");
    defer file.deinit();
    const view: HealthFileView = .{
        .file_id = file.file_id,
        .size_bytes = file.size_bytes orelse 0,
        .duration_ms = file.duration_ms orelse 0,
        .sample_rate = file.sample_rate orelse 0,
        .bit_depth = file.bit_depth orelse 0,
        .channels = file.channels orelse 0,
        .missing = @intFromBool(file.missing),
        .has_path = @intFromBool(file.path != null),
        .has_size_bytes = @intFromBool(file.size_bytes != null),
        .has_duration_ms = @intFromBool(file.duration_ms != null),
        .has_sample_rate = @intFromBool(file.sample_rate != null),
        .has_bit_depth = @intFromBool(file.bit_depth != null),
        .has_channels = @intFromBool(file.channels != null),
        .path = stringView(file.path orelse ""),
        .codec = stringView(file.codec),
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_artist_count(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    destination.* = box.runtime.libraryArtistCount(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_query_artists(
    runtime: ?*Runtime,
    library: Handle,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?ArtistCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    var page = box.runtime.libraryArtistPage(importLibrary(library), .{
        .limit = limit,
        .offset = offset,
    }) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view = artistView(item);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_artist_get(
    runtime: ?*Runtime,
    library: Handle,
    artist_id: i64,
    context: ?*anyopaque,
    callback: ?ArtistCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const found = box.runtime.libraryArtist(importLibrary(library), artist_id) catch |err|
        return box.fail(@src(), err);
    const item = found orelse return .ok;
    defer item.deinit(box.runtime.allocator);
    const view = artistView(item);
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_release_count(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    destination.* = box.runtime.libraryReleaseCount(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_query_releases(
    runtime: ?*Runtime,
    library: Handle,
    album_artist_id: i64,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?ReleaseCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    var page = box.runtime.libraryReleasePage(importLibrary(library), .{
        .album_artist_id = optionalId(album_artist_id),
        .limit = limit,
        .offset = offset,
    }) catch |err| return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view = releaseView(item);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_release_get(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    context: ?*anyopaque,
    callback: ?ReleaseCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const found = box.runtime.libraryRelease(importLibrary(library), release_id) catch |err|
        return box.fail(@src(), err);
    const item = found orelse return .ok;
    defer item.deinit(box.runtime.allocator);
    const view = releaseView(item);
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_browse_tracks(
    runtime: ?*Runtime,
    library: Handle,
    query: ?*const TrackQueryView,
    context: ?*anyopaque,
    callback: ?TrackCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const request = importTrackQuery(query orelse
        return box.reject(@src(), .invalid_argument, "query is null")) orelse
        return box.reject(@src(), .invalid_argument, invalid_track_query);
    var page = box.runtime.libraryTrackQuery(importLibrary(library), "", request) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view = trackView(item);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_track_match_count(
    runtime: ?*Runtime,
    library: Handle,
    query: ?*const TrackQueryView,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const request = importTrackQuery(query orelse
        return box.reject(@src(), .invalid_argument, "query is null")) orelse
        return box.reject(@src(), .invalid_argument, invalid_track_query);
    destination.* = box.runtime.libraryTrackMatchCount(importLibrary(library), request) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_browse_releases(
    runtime: ?*Runtime,
    library: Handle,
    query: ?*const ReleaseQueryView,
    context: ?*anyopaque,
    callback: ?ReleaseCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const request = importReleaseQuery(query orelse
        return box.reject(@src(), .invalid_argument, "query is null")) orelse
        return box.reject(@src(), .invalid_argument, invalid_release_query);
    var page = box.runtime.libraryReleasePage(importLibrary(library), request) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view = releaseView(item);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_release_count_matching(
    runtime: ?*Runtime,
    library: Handle,
    query: ?*const ReleaseQueryView,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const request = importReleaseQuery(query orelse
        return box.reject(@src(), .invalid_argument, "query is null")) orelse
        return box.reject(@src(), .invalid_argument, invalid_release_query);
    destination.* = box.runtime.libraryReleaseCountMatching(importLibrary(library), request) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_browse_artists(
    runtime: ?*Runtime,
    library: Handle,
    query: ?*const ArtistQueryView,
    context: ?*anyopaque,
    callback: ?ArtistCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const request = importArtistQuery(query orelse
        return box.reject(@src(), .invalid_argument, "query is null")) orelse
        return box.reject(@src(), .invalid_argument, invalid_artist_query);
    var page = box.runtime.libraryArtistPage(importLibrary(library), request) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view = artistView(item);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_artist_count_matching(
    runtime: ?*Runtime,
    library: Handle,
    query: ?*const ArtistQueryView,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const request = importArtistQuery(query orelse
        return box.reject(@src(), .invalid_argument, "query is null")) orelse
        return box.reject(@src(), .invalid_argument, invalid_artist_query);
    destination.* = box.runtime.libraryArtistCountMatching(importLibrary(library), request) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_track_get(
    runtime: ?*Runtime,
    library: Handle,
    track_id: i64,
    context: ?*anyopaque,
    callback: ?TrackSummaryCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const found = box.runtime.libraryTrackSummary(importLibrary(library), track_id) catch |err|
        return box.fail(@src(), err);
    const item = found orelse return box.reject(@src(), .not_found, "no such track");
    defer item.deinit(box.runtime.allocator);
    const view: TrackSummaryView = .{
        .track = trackView(item),
        .release_id = item.release_id orelse 0,
        .artist_id = item.artist_id orelse 0,
        .recording_id = item.recording_id orelse 0,
        .has_release_id = @intFromBool(item.release_id != null),
        .has_artist_id = @intFromBool(item.artist_id != null),
        .has_recording_id = @intFromBool(item.recording_id != null),
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_track_details(
    runtime: ?*Runtime,
    library: Handle,
    track_id: i64,
    context: ?*anyopaque,
    callback: ?TrackDetailsCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const found = box.runtime.libraryTrackDetails(importLibrary(library), track_id) catch |err|
        return box.fail(@src(), err);
    const details = found orelse return box.reject(@src(), .not_found, "no such track");
    defer details.deinit();
    const view = trackDetailsView(&details);
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_track_play_stats(
    runtime: ?*Runtime,
    library: Handle,
    track_id: i64,
    output: ?*PlayStatsView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const stats = box.runtime.libraryTrackPlayStats(importLibrary(library), track_id) catch |err|
        return box.fail(@src(), err);
    destination.* = .{
        .play_count = stats.play_count,
        .last_played_at = stats.last_played_at orelse 0,
        .has_last_played_at = @intFromBool(stats.last_played_at != null),
    };
    return .ok;
}

pub export fn orca_library_listens_recorded(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    destination.* = box.runtime.libraryListensRecorded(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_set_feedback(
    runtime: ?*Runtime,
    library: Handle,
    track_ids: ?[*]const i64,
    count: usize,
    feedback: u8,
    output: ?*ChangeCount,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const value = importFeedback(feedback) orelse
        return box.reject(@src(), .invalid_argument, "feedback is not an orca_feedback");
    const list = editIdSlice(track_ids, count) orelse
        return box.reject(@src(), .invalid_argument, invalid_edit_ids);
    const change = box.runtime.librarySetFeedback(importLibrary(library), list, value) catch |err|
        return box.fail(@src(), err);
    destination.* = .{ .updated = change.updated, .skipped = change.skipped };
    return .ok;
}

pub export fn orca_library_track_feedback(
    runtime: ?*Runtime,
    library: Handle,
    track_id: i64,
    feedback: ?*u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = feedback orelse return box.reject(@src(), .invalid_argument, "feedback is null");
    destination.* = exportFeedback(box.runtime.libraryTrackFeedback(importLibrary(library), track_id) catch |err|
        return box.fail(@src(), err));
    return .ok;
}

pub export fn orca_library_set_rating(
    runtime: ?*Runtime,
    library: Handle,
    track_ids: ?[*]const i64,
    count: usize,
    rating: u8,
    output: ?*ChangeCount,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    if (rating > database.repository.max_rating) return box.reject(@src(), .invalid_argument, "rating must be 0 to clear, or 1 to 100");
    const list = editIdSlice(track_ids, count) orelse
        return box.reject(@src(), .invalid_argument, invalid_edit_ids);
    const change = box.runtime.librarySetRating(importLibrary(library), list, if (rating == 0) null else rating) catch |err|
        return box.fail(@src(), err);
    destination.* = .{ .updated = change.updated, .skipped = change.skipped };
    return .ok;
}

pub export fn orca_library_set_release_love(
    runtime: ?*Runtime,
    library: Handle,
    release_ids: ?[*]const i64,
    count: usize,
    loved: u8,
    output: ?*ChangeCount,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    if (loved > 1) return box.reject(@src(), .invalid_argument, "loved must be 0 or 1");
    const list = editIdSlice(release_ids, count) orelse
        return box.reject(@src(), .invalid_argument, invalid_edit_ids);
    const change = box.runtime.librarySetReleaseLove(importLibrary(library), list, loved == 1) catch |err|
        return box.fail(@src(), err);
    destination.* = .{ .updated = change.updated, .skipped = change.skipped };
    return .ok;
}

pub export fn orca_library_unanalyzed_count(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    destination.* = box.runtime.libraryUnanalyzedCount(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_query_playlists(
    runtime: ?*Runtime,
    library: Handle,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?PlaylistCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    var page = box.runtime.libraryPlaylists(importLibrary(library), limit, offset) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view: PlaylistView = .{
            .id = item.id,
            .duration_ms = item.duration_ms,
            .created_at = item.created_at,
            .updated_at = item.updated_at,
            .entries = item.entries,
            .available = item.available,
            .name = stringView(item.name),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_create_playlist(
    runtime: ?*Runtime,
    library: Handle,
    name: ?[*]const u8,
    name_length: usize,
    playlist_id: ?*i64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = playlist_id orelse return box.reject(@src(), .invalid_argument, "playlist_id is null");
    const text = stringInput(name, name_length) orelse
        return box.reject(@src(), .invalid_argument, "name is null and name_length is not zero");
    destination.* = box.runtime.libraryCreatePlaylist(importLibrary(library), text) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_rename_playlist(
    runtime: ?*Runtime,
    library: Handle,
    playlist_id: i64,
    name: ?[*]const u8,
    name_length: usize,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const text = stringInput(name, name_length) orelse
        return box.reject(@src(), .invalid_argument, "name is null and name_length is not zero");
    box.runtime.libraryRenamePlaylist(importLibrary(library), playlist_id, text) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_delete_playlist(runtime: ?*Runtime, library: Handle, playlist_id: i64) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.libraryDeletePlaylist(importLibrary(library), playlist_id) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_query_playlist_entries(
    runtime: ?*Runtime,
    library: Handle,
    playlist_id: i64,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?PlaylistEntryCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    var page = box.runtime.libraryPlaylistEntries(importLibrary(library), playlist_id, limit, offset) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view: PlaylistEntryView = .{
            .recording_id = item.recording_id,
            .position = item.position,
            .has_track = @intFromBool(item.track != null),
            .track = if (item.track) |track| trackView(track) else std.mem.zeroes(TrackView),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_playlist_insert(
    runtime: ?*Runtime,
    library: Handle,
    playlist_id: i64,
    track_ids: ?[*]const i64,
    count: usize,
    at: i64,
    output: ?*ChangeCount,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const list = editIdSlice(track_ids, count) orelse
        return box.reject(@src(), .invalid_argument, invalid_edit_ids);
    const position: ?u32 = if (at < 0)
        null
    else
        std.math.cast(u32, at) orelse return box.reject(@src(), .invalid_argument, "at is past the end of the playlist");
    const insertion = box.runtime.libraryPlaylistInsert(importLibrary(library), playlist_id, list, position) catch |err|
        return box.fail(@src(), err);
    destination.* = .{ .updated = insertion.added, .skipped = insertion.skipped };
    return .ok;
}

pub export fn orca_library_playlist_remove(
    runtime: ?*Runtime,
    library: Handle,
    playlist_id: i64,
    positions: ?[*]const u32,
    count: usize,
    removed: ?*u32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = removed orelse return box.reject(@src(), .invalid_argument, "removed is null");
    const list: []const u32 = if (count == 0)
        &.{}
    else if (positions) |pointer|
        if (count > max_page)
            return box.reject(@src(), .invalid_argument, "count exceeds 512")
        else
            pointer[0..count]
    else
        return box.reject(@src(), .invalid_argument, "positions is null and count is not zero");
    destination.* = box.runtime.libraryPlaylistRemove(importLibrary(library), playlist_id, list) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_playlist_move(
    runtime: ?*Runtime,
    library: Handle,
    playlist_id: i64,
    from: u32,
    to: u32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.libraryPlaylistMove(importLibrary(library), playlist_id, from, to) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_import_playlist(
    runtime: ?*Runtime,
    library: Handle,
    path: ?[*]const u8,
    path_length: usize,
    name: ?[*]const u8,
    name_length: usize,
    output: ?*PlaylistImport,
    context: ?*anyopaque,
    unmatched: ?LineCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const file_path = stringInput(path, path_length) orelse
        return box.reject(@src(), .invalid_argument, "path is null and path_length is not zero");
    if (file_path.len == 0) return box.reject(@src(), .invalid_argument, "path is empty");
    const playlist_name: ?[]const u8 = if (name == null and name_length == 0)
        null
    else
        stringInput(name, name_length) orelse
            return box.reject(@src(), .invalid_argument, "name is null and name_length is not zero");
    const imported = box.runtime.libraryImportPlaylist(importLibrary(library), box.io(), file_path, playlist_name) catch |err|
        return if (err == error.FileNotFound)
            box.reject(@src(), .not_found, "the playlist file does not exist")
        else
            box.fail(@src(), err);
    defer imported.deinit();
    destination.* = .{
        .playlist_id = imported.playlist_id,
        .matched_by_path = imported.matched_by_path,
        .matched_by_info = imported.matched_by_info,
        .unmatched = imported.unmatched,
    };
    if (unmatched) |visit| {
        for (imported.unmatched_lines) |line| visit(context, stringView(line));
    }
    return .ok;
}

pub export fn orca_library_export_playlist(
    runtime: ?*Runtime,
    library: Handle,
    playlist_id: i64,
    path: ?[*]const u8,
    path_length: usize,
    path_style: u8,
    replace: u8,
    written: ?*u32,
    skipped: ?*u32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const written_destination = written orelse return box.reject(@src(), .invalid_argument, "written is null");
    const skipped_destination = skipped orelse return box.reject(@src(), .invalid_argument, "skipped is null");
    const file_path = stringInput(path, path_length) orelse
        return box.reject(@src(), .invalid_argument, "path is null and path_length is not zero");
    if (file_path.len == 0) return box.reject(@src(), .invalid_argument, "path is empty");
    const paths = importPlaylistPathStyle(path_style) orelse
        return box.reject(@src(), .invalid_argument, "path_style is not an orca_playlist_path_style");
    if (replace > 1) return box.reject(@src(), .invalid_argument, "replace must be 0 or 1");
    const exported = box.runtime.libraryExportPlaylist(
        importLibrary(library),
        box.io(),
        playlist_id,
        file_path,
        .{ .paths = paths, .replace = replace == 1 },
    ) catch |err| return switch (err) {
        error.FileNotFound => box.reject(@src(), .not_found, "the folder to export into does not exist"),
        error.PathAlreadyExists => box.reject(@src(), .invalid_state, "the file exists; pass replace to overwrite it"),
        else => box.fail(@src(), err),
    };
    written_destination.* = exported.written;
    skipped_destination.* = exported.skipped;
    return .ok;
}

pub export fn orca_library_track_artwork(
    runtime: ?*Runtime,
    library: Handle,
    track_id: i64,
    context: ?*anyopaque,
    callback: ?ImageCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const found = box.runtime.libraryTrackArtwork(importLibrary(library), box.io(), track_id) catch |err|
        return box.fail(@src(), err);
    const image = found orelse return box.reject(@src(), .not_found, "the track has no cover");
    defer image.deinit();
    const view = imageView(image);
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_release_artwork(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    context: ?*anyopaque,
    callback: ?ImageCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const found = box.runtime.libraryReleaseArtwork(importLibrary(library), box.io(), release_id) catch |err|
        return box.fail(@src(), err);
    const image = found orelse return box.reject(@src(), .not_found, "the release has no cover");
    defer image.deinit();
    const view = imageView(image);
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_request_artwork(
    runtime: ?*Runtime,
    library: Handle,
    subject: u8,
    id: i64,
    request: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = request orelse return box.reject(@src(), .invalid_argument, "request is null");
    const kind = importArtworkSubject(subject) orelse
        return box.reject(@src(), .invalid_argument, "subject is not an orca_artwork_subject");
    const wanted: core.runtime.ArtworkSubject = switch (kind) {
        .track => .{ .track = id },
        .release => .{ .release = id },
    };
    destination.* = box.runtime.libraryRequestArtwork(importLibrary(library), box.io(), wanted) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_cancel_artwork(runtime: ?*Runtime, library: Handle, request: u64) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    _ = core.runtime.libraryDatabase(&box.runtime, importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    box.runtime.libraryCancelArtwork(importLibrary(library), request);
    return .ok;
}

pub export fn orca_library_take_artwork(
    runtime: ?*Runtime,
    library: Handle,
    context: ?*anyopaque,
    callback: ?ArtworkResultCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    _ = core.runtime.libraryDatabase(&box.runtime, importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    const result = box.runtime.libraryTakeArtwork(importLibrary(library)) orelse
        return box.reject(@src(), .not_found, "no artwork request has finished");
    defer if (result.image) |image| image.deinit();
    const view: ArtworkResultView = .{
        .request = result.request,
        .subject_id = switch (result.subject) {
            .track, .release => |id| id,
        },
        .subject = exportArtworkSubject(result.subject),
        .has_image = @intFromBool(result.image != null),
        .image = if (result.image) |image| imageView(image) else .{
            .bytes = "",
            .length = 0,
            .mime_type = stringView(""),
            .kind = 0,
        },
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_edit_tracks(
    runtime: ?*Runtime,
    library: Handle,
    track_ids: ?[*]const i64,
    count: usize,
    edits: ?[*]const TrackEditView,
    edit_count: usize,
    context: ?*anyopaque,
    callback: ?IdCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const list = editIdSlice(track_ids, count) orelse
        return box.reject(@src(), .invalid_argument, invalid_edit_ids);
    if (edit_count > max_track_edits) return box.reject(@src(), .invalid_argument, "edit_count exceeds 64");
    var imported: [max_track_edits]core.runtime.TrackEdit = undefined;
    if (edit_count != 0) {
        const given = edits orelse
            return box.reject(@src(), .invalid_argument, "edits is null and edit_count is not zero");
        for (imported[0..edit_count], given[0..edit_count]) |*edit, view| {
            const field = importMetadataField(view.field) orelse
                return box.reject(@src(), .invalid_argument, "field is not an orca_metadata_field");
            edit.* = .{
                .field = field,
                .value = if (view.has_value == 0) null else stringInput(view.value.pointer, view.value.length) orelse
                    return box.reject(@src(), .invalid_argument, "value is null and its length is not zero"),
            };
        }
    }
    const edited = box.runtime.libraryEditTracks(importLibrary(library), list, imported[0..edit_count]) catch |err|
        return box.fail(@src(), err);
    defer edited.deinit();
    if (callback) |visit| visit(context, edited.ids.ptr, edited.ids.len);
    return .ok;
}

pub export fn orca_library_query_track_edits(
    runtime: ?*Runtime,
    library: Handle,
    track_id: i64,
    context: ?*anyopaque,
    callback: ?FieldValueCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var page = box.runtime.libraryTrackEdits(importLibrary(library), track_id) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view: FieldValueView = .{
            .field = exportMetadataField(item.field),
            .provenance = exportProvenance(item.provenance),
            .locked = @intFromBool(item.locked),
            .text = stringView(item.text),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_plan_tag_write(
    runtime: ?*Runtime,
    library: Handle,
    track_ids: ?[*]const i64,
    count: usize,
    context: ?*anyopaque,
    callback: ?TagWritePlanCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const list = editIdSlice(track_ids, count) orelse
        return box.reject(@src(), .invalid_argument, invalid_edit_ids);
    const plan = box.runtime.planTagWrite(importLibrary(library), box.io(), list) catch |err|
        return box.fail(@src(), err);
    defer plan.deinit();
    var scratch: std.heap.ArenaAllocator = .init(box.runtime.allocator);
    defer scratch.deinit();
    const view = tagWritePlanView(scratch.allocator(), &plan) catch |err| {
        if (plan.plan_id != 0) box.runtime.discardTagWrite(importLibrary(library), plan.plan_id) catch {};
        return box.fail(@src(), err);
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_start_tag_write(
    runtime: ?*Runtime,
    library: Handle,
    plan_id: u64,
    digest: ?*const TagWriteDigest,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    const approval = digest orelse return box.reject(@src(), .invalid_argument, "digest is null");
    const started = box.runtime.startTagWrite(importLibrary(library), plan_id, approval.bytes) catch |err|
        return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
    return .ok;
}

pub export fn orca_library_discard_tag_write(runtime: ?*Runtime, library: Handle, plan_id: u64) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.discardTagWrite(importLibrary(library), plan_id) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_undo_tag_write(runtime: ?*Runtime, library: Handle, group_id: u64) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.undoTagWrite(importLibrary(library), box.io(), group_id) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_prune_tag_write_backups(
    runtime: ?*Runtime,
    library: Handle,
    older_than_s: u64,
    backups: ?*u64,
    bytes: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const backup_count = backups orelse return box.reject(@src(), .invalid_argument, "backups is null");
    const byte_count = bytes orelse return box.reject(@src(), .invalid_argument, "bytes is null");
    const pruned = box.runtime.pruneTagWriteBackups(importLibrary(library), box.io(), older_than_s) catch |err|
        return box.fail(@src(), err);
    backup_count.* = pruned.backups;
    byte_count.* = pruned.bytes;
    return .ok;
}

fn tagWritePlanView(allocator: std.mem.Allocator, plan: *const core.runtime.TagWritePlan) !TagWritePlanView {
    var change_total: usize = 0;
    for (plan.files) |file| change_total += file.changes.len;
    const changes = try allocator.alloc(TagWriteChangeView, change_total);
    const files = try allocator.alloc(TagWriteFileView, plan.files.len);
    var next: usize = 0;
    for (files, plan.files) |*file_view, file| {
        const owned = changes[next..][0..file.changes.len];
        next += file.changes.len;
        for (owned, file.changes) |*change_view, change| change_view.* = .{
            .field = exportMetadataField(change.field),
            .provenance = exportProvenance(change.provenance),
            .has_before = @intFromBool(change.before != null),
            .before = stringView(change.before orelse ""),
            .after = stringView(change.after orelse ""),
        };
        file_view.* = .{
            .file_id = file.file_id,
            .path = stringView(file.path),
            .changes = owned.ptr,
            .change_count = owned.len,
        };
    }
    const conflicts = try allocator.alloc(TagWriteConflictView, plan.conflicts.len);
    for (conflicts, plan.conflicts) |*conflict_view, conflict| conflict_view.* = .{
        .file_id = conflict.file_id,
        .field = exportMetadataField(conflict.field),
        .provenance = exportProvenance(conflict.provenance),
        .path = stringView(conflict.path),
        .file_value = stringView(conflict.file_value),
        .orca_value = stringView(conflict.orca_value),
    };
    const skipped = try allocator.alloc(TagWriteSkipView, plan.skipped.len);
    for (skipped, plan.skipped) |*skip_view, skip| skip_view.* = .{
        .file_id = skip.file_id,
        .reason = exportTagWriteSkipReason(skip.reason),
        .path = stringView(skip.path),
    };
    return .{
        .plan_id = plan.plan_id,
        .digest = .{ .bytes = plan.digest },
        .files = files.ptr,
        .file_count = files.len,
        .conflicts = conflicts.ptr,
        .conflict_count = conflicts.len,
        .skipped = skipped.ptr,
        .skip_count = skipped.len,
    };
}

pub export fn orca_player_create(
    runtime: ?*Runtime,
    output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const player = box.runtime.createPlayer() catch |err| return box.fail(@src(), err);
    destination.* = exportHandle(player);
    return .ok;
}

pub export fn orca_player_destroy(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.destroyPlayer(importPlayer(player)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_play(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playPlayer(importPlayer(player)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_pause(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.pausePlayer(importPlayer(player)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_stop(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.stopPlayer(importPlayer(player)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_seek(
    runtime: ?*Runtime,
    player: Handle,
    frame: u64,
    generation: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const next = box.runtime.seekPlayer(importPlayer(player), frame) catch |err|
        return box.fail(@src(), err);
    if (generation) |output| output.* = next;
    return .ok;
}

pub export fn orca_runtime_pump(runtime: ?*Runtime) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.pump();
    return .ok;
}

pub export fn orca_runtime_poll_event(
    runtime: ?*Runtime,
    event: ?*Event,
    remaining: ?*u32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = event orelse return box.reject(@src(), .invalid_argument, "event is null");
    destination.* = .{ .kind = @intFromEnum(EventKind.none), .payload = undefined };
    // Lossless completions first, coalesced hints second: a host must never
    // learn that a job finished before it learns the command that started it
    // succeeded.
    if (box.runtime.pollEvent()) |completion| {
        destination.* = exportCompletion(completion);
    } else while (box.runtime.pollTelemetry()) |telemetry| {
        destination.* = exportTelemetry(telemetry) orelse continue;
        break;
    }
    if (remaining) |output| output.* = @intCast(
        box.runtime.events.count() + box.runtime.telemetry.count(),
    );
    return .ok;
}

pub const WakeCallback = *const fn (?*anyopaque) callconv(.c) void;

pub export fn orca_runtime_set_wake_callback(
    runtime: ?*Runtime,
    callback: ?WakeCallback,
    context: ?*anyopaque,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const waker: ?control.HostWaker = if (callback) |wake| .{ .context = context, .wake_fn = wake } else null;
    box.runtime.setWaker(waker) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub const pump_no_timeout: i64 = -1;

pub export fn orca_runtime_pump_timeout(runtime: ?*Runtime, timeout_ms: ?*i64) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = timeout_ms orelse return box.reject(@src(), .invalid_argument, "timeout_ms is null");
    destination.* = if (box.runtime.nextPumpTimeoutMs()) |milliseconds|
        std.math.cast(i64, milliseconds) orelse std.math.maxInt(i64)
    else
        pump_no_timeout;
    return .ok;
}

pub const credential_max_bytes = 1024;

pub const ProviderService = enum { listenbrainz, musicbrainz, acoustid, cover_art_archive };

pub fn importProviderService(value: u8) ?ProviderService {
    return switch (value) {
        0 => .listenbrainz,
        1 => .musicbrainz,
        2 => .acoustid,
        3 => .cover_art_archive,
        else => null,
    };
}

pub const CredentialResult = enum { found, not_found, unavailable, too_large };

pub fn importCredentialResult(value: c_int) ?CredentialResult {
    return switch (value) {
        0 => .found,
        1 => .not_found,
        2 => .unavailable,
        3 => .too_large,
        else => null,
    };
}

pub const CredentialCallback = *const fn (
    ?*anyopaque,
    [*:0]const u8,
    [*:0]const u8,
    [*]u8,
    usize,
    *usize,
) callconv(.c) c_int;

const CredentialSlot = struct {
    callback: ?CredentialCallback = null,
    context: ?*anyopaque = null,
};

fn hostCredential(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    service: []const u8,
    account: []const u8,
) anyerror!?[]u8 {
    const slot: *const CredentialSlot = @ptrCast(@alignCast(context));
    const callback = slot.callback orelse return null;
    const service_text = try allocator.dupeZ(u8, service);
    defer allocator.free(service_text);
    const account_text = try allocator.dupeZ(u8, account);
    defer allocator.free(account_text);
    const scratch = try allocator.alloc(u8, credential_max_bytes);
    defer providers.credentials.wipeAndFree(allocator, scratch);
    var length: usize = 0;
    const result = callback(slot.context, service_text.ptr, account_text.ptr, scratch.ptr, scratch.len, &length);
    switch (importCredentialResult(result) orelse return error.CredentialUnavailable) {
        .found => {
            if (length > scratch.len) return error.CredentialTooLarge;
            return try allocator.dupe(u8, scratch[0..length]);
        },
        .not_found => return null,
        .unavailable => return error.CredentialUnavailable,
        .too_large => return error.CredentialTooLarge,
    }
}

pub export fn orca_runtime_set_client_identity(
    runtime: ?*Runtime,
    name: ?[*:0]const u8,
    client_version: ?[*:0]const u8,
    contact: ?[*:0]const u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const name_text = name orelse return box.reject(@src(), .invalid_argument, "name is null");
    const version_text = client_version orelse return box.reject(@src(), .invalid_argument, "version is null");
    const contact_text = contact orelse return box.reject(@src(), .invalid_argument, "contact is null");
    box.runtime.setClientIdentity(.{
        .name = std.mem.span(name_text),
        .version = std.mem.span(version_text),
        .contact = std.mem.span(contact_text),
    }) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_runtime_set_provider_server(
    runtime: ?*Runtime,
    service: u8,
    base_url: ?[*:0]const u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const provider = importProviderService(service) orelse
        return box.reject(@src(), .invalid_argument, "unknown provider service");
    const server: ?[]const u8 = if (base_url) |text| std.mem.span(text) else null;
    const set = switch (provider) {
        .listenbrainz => box.runtime.setListenBrainzServer(server),
        .musicbrainz => box.runtime.setMusicBrainzServer(server),
        .acoustid => box.runtime.setAcoustIdServer(server),
        .cover_art_archive => box.runtime.setCoverArtArchiveServer(server),
    };
    set catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_runtime_set_acoustid_client_key(runtime: ?*Runtime, key: ?[*:0]const u8) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const value: ?[]const u8 = if (key) |text| std.mem.span(text) else null;
    box.runtime.setAcoustIdClientKey(value) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_runtime_set_credential_callback(
    runtime: ?*Runtime,
    callback: ?CredentialCallback,
    context: ?*anyopaque,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    if (box.runtime.work_registry.count() != 0) return box.fail(@src(), error.WorkersRunning);
    const store: ?providers.credentials.Store = if (callback != null)
        .{ .context = &box.credential, .get_fn = hostCredential }
    else
        null;
    box.runtime.setCredentialStore(store) catch |err| return box.fail(@src(), err);
    box.credential = .{ .callback = callback, .context = context };
    return .ok;
}

pub export fn orca_library_scrobbler_credentials_changed(runtime: ?*Runtime, library: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.libraryScrobblerCredentialsChanged(importLibrary(library)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_start_match(
    runtime: ?*Runtime,
    library: Handle,
    options: ?*const MatchOptions,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    var request: core.runtime.MatchRequest = .{};
    if (options) |value| {
        if (value.batch_size != 0) request.batch_size = value.batch_size;
        request.mode = importMatchMode(value.mode) orelse
            return box.reject(@src(), .invalid_argument, "mode is not an orca_match_mode");
        if (value.has_limit != 0) request.limit = value.limit;
        if (value.has_track_id != 0) request.track_id = value.track_id;
        if (value.has_release_id != 0) request.release_id = value.release_id;
        request.fingerprints = value.skip_fingerprints == 0;
        if (value.has_accept_minimum_confidence != 0) request.accept_minimum_confidence = value.accept_minimum_confidence;
        request.cover_art = value.cover_art != 0;
    }
    const started = box.runtime.startLibraryMatching(importLibrary(library), request) catch |err|
        return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
    return .ok;
}

pub export fn orca_library_start_cover_art_fetch(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    const started = box.runtime.startReleaseCoverArtFetch(importLibrary(library), release_id) catch |err|
        return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
    return .ok;
}

pub export fn orca_job_match_stats(
    runtime: ?*Runtime,
    job_handle: Handle,
    output: ?*MatchStatsView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const stats = box.runtime.jobMatchStats(importJob(job_handle)) catch |err| return box.fail(@src(), err);
    destination.* = .{
        .tracks_examined = stats.tracks_examined,
        .matched = stats.matched,
        .unmatched = stats.unmatched,
        .insufficient_evidence = stats.insufficient_evidence,
        .refused = stats.refused,
        .proposals_stored = stats.proposals_stored,
        .confirmed = stats.confirmed,
        .verified = stats.verified,
        .agreed = stats.agreed,
        .disagreed = stats.disagreed,
        .unconfirmed = stats.unconfirmed,
        .skipped = stats.skipped,
        .correction_groups = stats.correction_groups,
        .requests = stats.requests,
        .cache_hits = stats.cache_hits,
        .fingerprinted = stats.fingerprinted,
        .fingerprint_cache_hits = stats.fingerprint_cache_hits,
        .fingerprint_failures = stats.fingerprint_failures,
        .acoustid_requests = stats.acoustid_requests,
        .acoustid_cache_hits = stats.acoustid_cache_hits,
        .acoustid_refused = stats.acoustid_refused,
        .accepted = stats.accepted,
        .acoustid = exportAcoustIdUse(stats.acoustid),
        .busy = exportBusyService(stats.busy),
        .cover_art = exportCoverArtOutcome(stats.cover_art),
        .cancelled = @intFromBool(stats.cancelled),
    };
    return .ok;
}

pub export fn orca_library_start_acoustid_submission(
    runtime: ?*Runtime,
    library: Handle,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    const started = box.runtime.startAcoustIdSubmission(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
    return .ok;
}

pub export fn orca_job_submission_stats(
    runtime: ?*Runtime,
    job_handle: Handle,
    output: ?*SubmissionStatsView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const stats = box.runtime.jobSubmissionStats(importJob(job_handle)) catch |err| return box.fail(@src(), err);
    destination.* = .{
        .files_examined = stats.files_examined,
        .submitted = stats.submitted,
        .sent_as_metadata = stats.sent_as_metadata,
        .fingerprinted = stats.fingerprinted,
        .fingerprint_cache_hits = stats.fingerprint_cache_hits,
        .fingerprint_failures = stats.fingerprint_failures,
        .rejected = stats.rejected,
        .requests = stats.requests,
        .outcome = exportSubmissionOutcome(stats.outcome),
    };
    return .ok;
}

pub export fn orca_library_acoustid_submittable_count(runtime: ?*Runtime, library: Handle, output: ?*u64) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    destination.* = box.runtime.libraryAcoustIdSubmittableCount(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_query_acoustid_submittable(
    runtime: ?*Runtime,
    library: Handle,
    cursor: i64,
    limit: u32,
    context: ?*anyopaque,
    callback: ?AcoustIdSubmittableCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    const page = box.runtime.libraryAcoustIdSubmittablePage(importLibrary(library), cursor, limit) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |*item| {
        const path = item.path orelse "";
        const view: AcoustIdSubmittableView = .{
            .file_id = item.file_id,
            .track_id = item.track_id,
            .track_number = item.track_number orelse 0,
            .disc_number = item.disc_number orelse 0,
            .duration_ms = item.duration_ms orelse 0,
            .size_bytes = item.size_bytes,
            .recording_length_ms = item.recording_length_ms orelse 0,
            .year = item.year orelse 0,
            .has_track_number = @intFromBool(item.track_number != null),
            .has_disc_number = @intFromBool(item.disc_number != null),
            .has_year = @intFromBool(item.year != null),
            .has_duration_ms = @intFromBool(item.duration_ms != null),
            .has_recording_length_ms = @intFromBool(item.recording_length_ms != null),
            .has_path = @intFromBool(item.path != null),
            .recording_mbid = stringView(item.recording_mbid),
            .title = stringView(item.title),
            .artist = stringView(item.artist),
            .album = stringView(item.album),
            .album_artist = stringView(item.album_artist),
            .codec = stringView(item.codec),
            .path = stringView(path),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_query_match_proposals(
    runtime: ?*Runtime,
    library: Handle,
    track_id: i64,
    context: ?*anyopaque,
    callback: ?MatchProposalCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const page = box.runtime.libraryMatchProposals(importLibrary(library), track_id, max_page) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |*proposal| {
        const view = matchProposalView(proposal);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_accept_match(
    runtime: ?*Runtime,
    library: Handle,
    proposal_id: i64,
    output: ?*MatchAcceptanceView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const acceptance = box.runtime.libraryAcceptMatch(importLibrary(library), proposal_id) catch |err|
        return box.fail(@src(), err);
    destination.* = .{ .file_id = acceptance.file_id, .values_written = acceptance.values_written };
    return .ok;
}

pub export fn orca_library_dismiss_match(runtime: ?*Runtime, library: Handle, proposal_id: i64) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.libraryDismissMatch(importLibrary(library), proposal_id) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_query_match_review(
    runtime: ?*Runtime,
    library: Handle,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?MatchReviewCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    const page = box.runtime.libraryMatchReviewPage(importLibrary(library), limit, offset) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |*item| {
        const view: MatchReviewView = .{
            .track_id = item.track_id,
            .duration_ms = item.duration_ms orelse 0,
            .proposal_count = item.proposal_count,
            .has_duration_ms = @intFromBool(item.duration_ms != null),
            .title = stringView(item.title),
            .artist = stringView(item.artist),
            .album = stringView(item.album),
            .best = matchProposalView(&item.best),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_match_review_count(runtime: ?*Runtime, library: Handle, output: ?*u64) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    destination.* = box.runtime.libraryMatchReviewCount(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_unidentified_count(runtime: ?*Runtime, library: Handle, output: ?*u64) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    destination.* = box.runtime.libraryUnidentifiedCount(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_confident_match_count(
    runtime: ?*Runtime,
    library: Handle,
    minimum_confidence: f32,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    destination.* = box.runtime.libraryConfidentMatchCount(importLibrary(library), minimum_confidence) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_accept_confident_matches(
    runtime: ?*Runtime,
    library: Handle,
    minimum_confidence: f32,
    output: ?*ConfidentAcceptanceView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const acceptance = box.runtime.libraryAcceptConfidentMatches(importLibrary(library), minimum_confidence) catch |err|
        return box.fail(@src(), err);
    destination.* = .{ .accepted = acceptance.accepted, .values_written = acceptance.values_written };
    return .ok;
}

pub export fn orca_library_apply_matched_release(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    values_written: ?*u32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = values_written orelse return box.reject(@src(), .invalid_argument, "values_written is null");
    destination.* = box.runtime.libraryApplyMatchedRelease(importLibrary(library), release_id) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_track_verification(
    runtime: ?*Runtime,
    library: Handle,
    track_id: i64,
    context: ?*anyopaque,
    callback: ?TrackVerificationCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const found = box.runtime.libraryTrackVerification(importLibrary(library), box.runtime.allocator, track_id) catch |err|
        return box.fail(@src(), err);
    const verification = found orelse return box.reject(@src(), .not_found, "the Track was never verified");
    defer verification.deinit();
    var heard: [database.repository.max_heard]HeardRecordingView = undefined;
    const heard_count = @min(verification.heard.len, heard.len);
    for (heard[0..heard_count], verification.heard[0..heard_count]) |*view, recording| view.* = .{
        .mbid = stringView(recording.mbid),
        .score = recording.score,
    };
    const view: TrackVerificationView = .{
        .verified_at = verification.verified_at,
        .recording_mbid = stringView(verification.recording_mbid),
        .heard = &heard,
        .heard_count = heard_count,
        .outcome = exportVerificationOutcome(verification.outcome),
        .stale = @intFromBool(verification.stale),
        .dismissed = @intFromBool(verification.dismissed),
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_query_correction_groups(
    runtime: ?*Runtime,
    library: Handle,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?CorrectionGroupCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    const page = box.runtime.libraryCorrectionGroups(importLibrary(library), box.runtime.allocator, limit, offset) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    var scratch: std.heap.ArenaAllocator = .init(box.runtime.allocator);
    defer scratch.deinit();
    for (page.items) |group| {
        _ = scratch.reset(.retain_capacity);
        const members = scratch.allocator().alloc(CorrectionMemberView, group.proposals.len) catch |err|
            return box.fail(@src(), err);
        for (members, group.proposals) |*view, member| view.* = .{
            .proposal_id = member.proposal_id,
            .track_id = member.track_id orelse 0,
            .file_id = member.file_id,
            .track_number = member.track_number orelse 0,
            .disc_number = member.disc_number orelse 0,
            .title = stringView(member.title),
            .proposed_title = stringView(member.proposed_title),
            .recording_mbid = stringView(member.recording_mbid),
            .corrects = stringView(member.corrects orelse ""),
            .proposed_track_number = member.proposed_track_number orelse 0,
            .proposed_disc_number = member.proposed_disc_number orelse 0,
            .has_track_id = @intFromBool(member.track_id != null),
            .has_track_number = @intFromBool(member.track_number != null),
            .has_disc_number = @intFromBool(member.disc_number != null),
            .has_proposed_track_number = @intFromBool(member.proposed_track_number != null),
            .has_proposed_disc_number = @intFromBool(member.proposed_disc_number != null),
            .has_corrects = @intFromBool(member.corrects != null),
        };
        const view: CorrectionGroupView = .{
            .group_id = group.group_id,
            .release_id = group.release_id orelse 0,
            .has_release_id = @intFromBool(group.release_id != null),
            .album = stringView(group.album),
            .album_artist = stringView(group.album_artist),
            .members = members.ptr,
            .member_count = members.len,
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_accept_correction_group(
    runtime: ?*Runtime,
    library: Handle,
    group_id: i64,
    output: ?*ConfidentAcceptanceView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const acceptance = box.runtime.libraryAcceptCorrectionGroup(importLibrary(library), group_id) catch |err|
        return box.fail(@src(), err);
    destination.* = .{ .accepted = acceptance.accepted, .values_written = acceptance.values_written };
    return .ok;
}

pub export fn orca_library_dismiss_correction_group(runtime: ?*Runtime, library: Handle, group_id: i64) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.libraryDismissCorrectionGroup(importLibrary(library), group_id) catch |err| return box.fail(@src(), err);
    return .ok;
}

fn matchProposalView(proposal: *const core.runtime.MatchProposal) MatchProposalView {
    return .{
        .id = proposal.id,
        .duration_ms = proposal.duration_ms orelse 0,
        .provider = stringView(proposal.provider),
        .recording_mbid = stringView(proposal.recording_mbid),
        .title = stringView(proposal.title),
        .artist = stringView(proposal.artist),
        .album = stringView(proposal.album),
        .release_mbid = stringView(proposal.release_mbid orelse ""),
        .track_title = stringView(proposal.track_title orelse ""),
        .track_artist = stringView(proposal.track_artist orelse ""),
        .release_title = stringView(proposal.release_title orelse ""),
        .release_artist = stringView(proposal.release_artist orelse ""),
        .release_date = stringView(proposal.release_date orelse ""),
        .release_group_mbid = stringView(proposal.release_group_mbid orelse ""),
        .release_track_mbid = stringView(proposal.release_track_mbid orelse ""),
        .corrects = stringView(proposal.corrects orelse ""),
        .confidence = proposal.confidence,
        .acoustid_score = proposal.acoustid_score orelse 0,
        .track_number = proposal.track_number orelse 0,
        .disc_number = proposal.disc_number orelse 0,
        .musicbrainz_score = proposal.musicbrainz_score orelse 0,
        .has_track_number = @intFromBool(proposal.track_number != null),
        .has_disc_number = @intFromBool(proposal.disc_number != null),
        .has_release_mbid = @intFromBool(proposal.release_mbid != null),
        .has_duration_ms = @intFromBool(proposal.duration_ms != null),
        .has_musicbrainz_score = @intFromBool(proposal.musicbrainz_score != null),
        .has_acoustid_score = @intFromBool(proposal.acoustid_score != null),
        .has_track_title = @intFromBool(proposal.track_title != null),
        .has_track_artist = @intFromBool(proposal.track_artist != null),
        .has_release_title = @intFromBool(proposal.release_title != null),
        .has_release_artist = @intFromBool(proposal.release_artist != null),
        .has_release_date = @intFromBool(proposal.release_date != null),
        .has_release_group_mbid = @intFromBool(proposal.release_group_mbid != null),
        .has_release_track_mbid = @intFromBool(proposal.release_track_mbid != null),
        .has_corrects = @intFromBool(proposal.corrects != null),
    };
}

pub fn importMatchMode(value: u8) ?core.runtime.MatchMode {
    return switch (value) {
        0 => .search,
        1 => .reidentify,
        2 => .verify,
        else => null,
    };
}

pub fn exportAcoustIdUse(use: core.runtime.AcoustIdUse) u8 {
    return switch (use) {
        .searched => 0,
        .off => 1,
        .no_client_key => 2,
        .invalid_client_key => 3,
    };
}

pub fn exportBusyService(service: core.runtime.BusyService) u8 {
    return switch (service) {
        .none => 0,
        .musicbrainz => 1,
        .acoustid => 2,
    };
}

pub fn exportCoverArtOutcome(outcome: core.runtime.CoverArtOutcome) u8 {
    return switch (outcome) {
        .not_requested => 0,
        .embedded => 1,
        .fetched => 2,
        .cached => 3,
        .cached_miss => 4,
        .not_found => 5,
        .no_release_id => 6,
        .refused => 7,
        .unavailable => 8,
        .busy => 9,
        .cancelled => 10,
    };
}

pub fn exportSubmissionOutcome(outcome: core.runtime.SubmissionOutcome) u8 {
    return switch (outcome) {
        .completed => 0,
        .cancelled => 1,
        .needs_client_key => 2,
        .invalid_client_key => 3,
        .needs_user_key => 4,
        .invalid_user_key => 5,
        .unavailable => 6,
        .busy => 7,
    };
}

pub fn exportVerificationOutcome(outcome: core.runtime.VerificationOutcome) u8 {
    return switch (outcome) {
        .agrees => 0,
        .disagrees => 1,
        .unconfirmed => 2,
        .no_fingerprint => 3,
    };
}

pub export fn orca_library_add_root(
    runtime: ?*Runtime,
    library: Handle,
    path: ?[*:0]const u8,
    root_id: ?*i64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const path_pointer = path orelse return box.reject(@src(), .invalid_argument, "path is null");
    const binding = box.runtime.libraryAddRoot(
        importLibrary(library),
        box.io(),
        std.mem.span(path_pointer),
    ) catch |err| return box.fail(@src(), err);
    if (root_id) |output| output.* = binding.root_id;
    return .ok;
}

pub export fn orca_library_remove_root(
    runtime: ?*Runtime,
    library: Handle,
    root_id: i64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    _ = box.runtime.libraryRemoveRoot(importLibrary(library), root_id) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_query_roots(
    runtime: ?*Runtime,
    library: Handle,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?RootCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    var page = box.runtime.libraryRootPage(importLibrary(library), limit, offset) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view: RootView = .{
            .id = item.id,
            .volume_id = item.volume_id,
            .enabled = @intFromBool(item.enabled),
            .path = stringView(item.path),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_start_scan(
    runtime: ?*Runtime,
    library: Handle,
    root_id: i64,
    options: ?*const ScanOptions,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    var request: core.runtime.ScanRequest = .{
        .root_id = if (root_id < 0) null else root_id,
    };
    if (options) |value| {
        if (value.batch_size != 0) request.batch_size = value.batch_size;
    }
    const started = box.runtime.startLibraryScan(importLibrary(library), request) catch |err|
        return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
    return .ok;
}

/// Walks `count` directories under root `root_id`, or the whole root when
/// `count` is zero, and marks missing only what was under what it walked.
pub export fn orca_library_start_reconcile(
    runtime: ?*Runtime,
    library: Handle,
    root_id: i64,
    directories: ?[*]const ?[*:0]const u8,
    count: usize,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    var request: core.runtime.ReconcileRequest = .{ .root_id = root_id };
    const subtrees = std.heap.c_allocator.alloc([]const u8, count) catch |err| return box.fail(@src(), err);
    defer std.heap.c_allocator.free(subtrees);
    if (count != 0) {
        const pointers = directories orelse return box.reject(@src(), .invalid_argument, "directories is null and count is not zero");
        for (subtrees, pointers[0..count]) |*subtree, pointer| {
            subtree.* = std.mem.span(pointer orelse return box.reject(@src(), .invalid_argument, "a directory is null"));
        }
        request.scope = .{ .subtrees = subtrees };
    }
    const started = box.runtime.startLibraryReconcile(importLibrary(library), request) catch |err|
        return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
    return .ok;
}

/// Watches the Library's enabled roots. `options` may be null, and a zero
/// field selects its default.
pub export fn orca_library_watch(
    runtime: ?*Runtime,
    library: Handle,
    options: ?*const WatchOptions,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    var watch_options: core.runtime.WatchOptions = .{};
    if (options) |value| {
        if (value.quiet_ms != 0) watch_options.quiet_ms = value.quiet_ms;
        if (value.max_delay_ms != 0) watch_options.max_delay_ms = value.max_delay_ms;
        if (value.degraded_rescan_ms != 0) watch_options.degraded_rescan_ms = value.degraded_rescan_ms;
    }
    box.runtime.libraryWatch(importLibrary(library), watch_options) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_unwatch(runtime: ?*Runtime, library: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.libraryUnwatch(importLibrary(library)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_watch_status(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*WatchStatus,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const status = box.runtime.libraryWatchStatus(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    destination.* = .{
        .state = exportWatchState(status.state),
        .watch_limit_reached = @intFromBool(status.watch_limit_reached),
        .reconcile_pending = @intFromBool(status.reconcile_pending),
        .reconcile_running = @intFromBool(status.reconcile_running),
        .roots_watched = status.roots_watched,
        .roots_unavailable = status.roots_unavailable,
        .roots_degraded = status.roots_degraded,
        .directories_watched = status.directories_watched,
    };
    return .ok;
}

pub export fn orca_library_start_projection(
    runtime: ?*Runtime,
    library: Handle,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    const started = box.runtime.startLibraryProjection(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
    return .ok;
}

/// Starts the property backfill. `options` may be null.
///
/// Reachable from the ABI for the same reason a scan is: a capability only a
/// unit test can invoke is not a capability the product has. The stats are
/// read back through `orca_library_scan_stats`, whose fields carry the
/// backfill's own meaning — see `orca_backfill_options` in the header.
pub export fn orca_library_start_property_backfill(
    runtime: ?*Runtime,
    library: Handle,
    options: ?*const BackfillOptions,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    var request: core.runtime.BackfillRequest = .{};
    if (options) |value| {
        if (value.batch_size != 0) request.batch_size = value.batch_size;
        request.force = value.force != 0;
    }
    const started = box.runtime.startLibraryPropertyBackfill(
        importLibrary(library),
        request,
    ) catch |err| return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
    return .ok;
}

/// Starts the library-wide analysis. `options` may be null.
///
/// Reachable from the ABI for the same reason a scan and a backfill are: a
/// capability only a unit test can invoke is not a capability the product has.
/// The stats come back through `orca_library_scan_stats` with this pass's own
/// meaning — see `orca_analysis_options` in the header.
pub export fn orca_library_start_analysis(
    runtime: ?*Runtime,
    library: Handle,
    options: ?*const AnalysisOptions,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    var request: core.runtime.AnalysisRequest = .{};
    if (options) |value| {
        if (value.batch_size != 0) request.batch_size = value.batch_size;
        if (value.threads != 0) request.threads = value.threads;
    }
    const started = box.runtime.startLibraryAnalysis(
        importLibrary(library),
        request,
    ) catch |err| return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
    return .ok;
}

/// Starts the duplicate scan. `options` may be null.
///
/// Reachable from the ABI for the same reason every other pass is: a
/// capability only a unit test can invoke is not a capability the product has.
/// The stats come back through `orca_library_scan_stats` with this pass's own
/// meaning -- see `orca_duplicate_scan_options` in the header.
pub export fn orca_library_start_duplicate_scan(
    runtime: ?*Runtime,
    library: Handle,
    options: ?*const DuplicateScanOptions,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    var request: core.runtime.DuplicateScanRequest = .{};
    if (options) |value| {
        if (value.batch_size != 0) request.batch_size = value.batch_size;
    }
    const started = box.runtime.startLibraryDuplicateScan(
        importLibrary(library),
        request,
    ) catch |err| return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
    return .ok;
}

pub export fn orca_job_cancel(runtime: ?*Runtime, job_handle: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.cancelJob(importJob(job_handle)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_job_snapshot_get(
    runtime: ?*Runtime,
    job_handle: Handle,
    output: ?*JobSnapshot,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const snapshot = box.runtime.jobSnapshotSynced(importJob(job_handle)) catch |err|
        return box.fail(@src(), err);
    destination.* = .{
        .kind = exportJobKind(snapshot.kind),
        .state = @intFromEnum(snapshot.state),
        .has_total = @intFromBool(snapshot.total_units != null),
        .completed_units = snapshot.completed_units,
        .total_units = snapshot.total_units orelse 0,
    };
    return .ok;
}

pub export fn orca_library_scan_stats(
    runtime: ?*Runtime,
    job_handle: Handle,
    output: ?*ScanStats,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const stats = box.runtime.jobScanStats(importJob(job_handle)) catch |err|
        return box.fail(@src(), err);
    destination.* = .{
        .files_seen = stats.files_seen,
        .changed = stats.changed,
        .unchanged = stats.unchanged,
        .unsupported = stats.unsupported,
        .errors = stats.errors,
        .batches_committed = stats.batches_committed,
        .folders_visited = stats.folders_visited,
        .files_projected = stats.files_projected,
        .tracks_written = stats.tracks_written,
        .releases_written = stats.releases_written,
        .cancelled = @intFromBool(stats.cancelled),
    };
    return .ok;
}

pub export fn orca_player_set_library(
    runtime: ?*Runtime,
    player: Handle,
    library: Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playerBindLibrary(
        importPlayer(player),
        importLibrary(library),
        box.io(),
    ) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_play_track(
    runtime: ?*Runtime,
    player: Handle,
    track_id: i64,
    request_id: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const player_handle = importPlayer(player);
    const library = (box.runtime.playerLibrary(player_handle) catch |err|
        return box.fail(@src(), err)) orelse return box.reject(@src(), .invalid_state, "player has no library");
    const submitted = box.runtime.submit(.{ .play_track = .{
        .player = player_handle,
        .library = library,
        .track_id = track_id,
    } }) catch |err| return box.fail(@src(), err);
    if (request_id) |output| output.* = submitted;
    return .ok;
}

pub export fn orca_player_play_tracks(
    runtime: ?*Runtime,
    player: Handle,
    ids: ?[*]const i64,
    count: usize,
    start: u32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const player_handle = importPlayer(player);
    const library = (box.runtime.playerLibrary(player_handle) catch |err|
        return box.fail(@src(), err)) orelse return box.reject(@src(), .invalid_state, "player has no library");
    const list = trackIdSlice(ids, count) orelse
        return box.reject(@src(), .invalid_argument, "ids is null or count exceeds the queue capacity");
    box.runtime.playerPlayTracksBound(player_handle, library, list, start) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_enqueue_tracks(
    runtime: ?*Runtime,
    player: Handle,
    ids: ?[*]const i64,
    count: usize,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const player_handle = importPlayer(player);
    const library = (box.runtime.playerLibrary(player_handle) catch |err|
        return box.fail(@src(), err)) orelse return box.reject(@src(), .invalid_state, "player has no library");
    const list = trackIdSlice(ids, count) orelse
        return box.reject(@src(), .invalid_argument, "ids is null or count exceeds the queue capacity");
    box.runtime.playerEnqueueTracksBound(player_handle, library, list) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_play_playlist(
    runtime: ?*Runtime,
    player: Handle,
    playlist_id: i64,
    start: u32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const player_handle = importPlayer(player);
    const library = (box.runtime.playerLibrary(player_handle) catch |err|
        return box.fail(@src(), err)) orelse return box.reject(@src(), .invalid_state, "player has no library");
    box.runtime.playerPlayPlaylist(player_handle, library, box.io(), playlist_id, start) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_next(
    runtime: ?*Runtime,
    player: Handle,
    moved: ?*u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const advanced = box.runtime.playerNext(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    if (moved) |output| output.* = @intFromBool(advanced);
    return .ok;
}

pub export fn orca_player_previous(
    runtime: ?*Runtime,
    player: Handle,
    moved: ?*u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const advanced = box.runtime.playerPrevious(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    if (moved) |output| output.* = @intFromBool(advanced);
    return .ok;
}

pub export fn orca_player_clear_queue(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playerClearQueue(importPlayer(player)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_set_repeat(
    runtime: ?*Runtime,
    player: Handle,
    mode: u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    if (mode > 2) return box.reject(@src(), .invalid_argument, "mode must be 0, 1 or 2");
    box.runtime.playerSetRepeat(
        importPlayer(player),
        @enumFromInt(mode),
    ) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_set_shuffle(
    runtime: ?*Runtime,
    player: Handle,
    enabled: u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playerSetShuffle(importPlayer(player), enabled != 0) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_set_volume(
    runtime: ?*Runtime,
    player: Handle,
    linear: f32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playerSetVolume(importPlayer(player), linear) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_volume(
    runtime: ?*Runtime,
    player: Handle,
    output: ?*f32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    destination.* = box.runtime.playerVolume(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

/// 0 turns loudness correction off, 1 corrects each entry by its own measured
/// loudness. Any other value is refused rather than treated as one of those.
/// Takes effect once the audio decoded ahead of the listener drains.
pub export fn orca_player_set_replay_gain_mode(
    runtime: ?*Runtime,
    player: Handle,
    mode: u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const resolved = importReplayGainMode(mode) orelse
        return box.reject(@src(), .invalid_argument, "mode must be 0 or 1");
    box.runtime.playerSetReplayGainMode(importPlayer(player), resolved) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_replay_gain_mode(
    runtime: ?*Runtime,
    player: Handle,
    output: ?*u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const mode = box.runtime.playerReplayGainMode(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    destination.* = @intFromEnum(mode);
    return .ok;
}

/// What the audio currently audible is being multiplied by: volume times the
/// loudness correction of the entry actually being heard. Equal to the volume
/// when there is no correction.
pub export fn orca_player_effective_gain(
    runtime: ?*Runtime,
    player: Handle,
    output: ?*f32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    destination.* = box.runtime.playerEffectiveGain(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_equalizer_preset_get(preset: u8, output: ?*EqualizerView) callconv(.c) Status {
    const destination = output orelse return .invalid_argument;
    const kind = importEqualizerPreset(preset) orelse return .invalid_argument;
    destination.* = exportEqualizer(audio.dsp.Equalizer.preset(kind));
    return .ok;
}

pub export fn orca_player_set_equalizer(
    runtime: ?*Runtime,
    player: Handle,
    equalizer: ?*const EqualizerView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const setting: ?audio.dsp.Equalizer = if (equalizer) |value| importEqualizer(value) else null;
    box.runtime.playerSetEqualizer(importPlayer(player), setting) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_equalizer(
    runtime: ?*Runtime,
    player: Handle,
    output: ?*EqualizerView,
    enabled: ?*u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const enabled_destination = enabled orelse return box.reject(@src(), .invalid_argument, "enabled is null");
    const setting = box.runtime.playerEqualizer(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    destination.* = if (setting) |value| exportEqualizer(value) else std.mem.zeroes(EqualizerView);
    enabled_destination.* = @intFromBool(setting != null);
    return .ok;
}

pub export fn orca_player_set_crossfeed(
    runtime: ?*Runtime,
    player: Handle,
    enabled: u8,
    amount: f32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const setting: ?f32 = if (enabled != 0) amount else null;
    box.runtime.playerSetCrossfeed(importPlayer(player), setting) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_crossfeed(
    runtime: ?*Runtime,
    player: Handle,
    enabled: ?*u8,
    amount: ?*f32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const enabled_destination = enabled orelse return box.reject(@src(), .invalid_argument, "enabled is null");
    const amount_destination = amount orelse return box.reject(@src(), .invalid_argument, "amount is null");
    const setting = box.runtime.playerCrossfeed(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    enabled_destination.* = @intFromBool(setting != null);
    amount_destination.* = setting orelse 0;
    return .ok;
}

pub export fn orca_player_signal_path(
    runtime: ?*Runtime,
    player: Handle,
    context: ?*anyopaque,
    callback: ?SignalPathCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const path = box.runtime.playerSignalPath(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    const view = exportSignalPath(&path);
    visit(context, &view);
    return .ok;
}

pub export fn orca_player_seek_ms(
    runtime: ?*Runtime,
    player: Handle,
    milliseconds: u64,
    epoch: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const next = box.runtime.playerSeekMs(importPlayer(player), milliseconds) catch |err|
        return box.fail(@src(), err);
    if (epoch) |output| output.* = next;
    return .ok;
}

pub export fn orca_player_status_get(
    runtime: ?*Runtime,
    player: Handle,
    output: ?*PlayerStatus,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const status = box.runtime.playerStatus(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    destination.* = .{
        .transport = @intFromEnum(status.transport),
        .repeat = @intFromEnum(status.repeat),
        .shuffle = @intFromBool(status.shuffle),
        .has_track = @intFromBool(status.track_id != null),
        .epoch = status.epoch,
        .position_ms = status.position_ms,
        .duration_ms = status.duration_ms,
        .track_id = status.track_id orelse 0,
        .queue_length = status.queue_length,
        .queue_index = status.queue_index,
        .volume = status.volume,
    };
    return .ok;
}

pub export fn orca_player_now_playing(
    runtime: ?*Runtime,
    player: Handle,
    context: ?*anyopaque,
    callback: ?NowPlayingCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const player_handle = importPlayer(player);
    const current = (box.runtime.playerNowPlaying(player_handle) catch |err|
        return box.fail(@src(), err)) orelse return .ok;
    const summary = (box.runtime.libraryTrackSummary(
        current.library,
        current.track_id,
    ) catch |err| return box.fail(@src(), err)) orelse return .ok;
    defer summary.deinit(box.runtime.allocator);
    const view: NowPlayingView = .{
        .track_id = summary.id,
        .duration_ms = summary.duration_ms orelse 0,
        .has_duration = @intFromBool(summary.duration_ms != null),
        .title = stringView(summary.title),
        .artist = stringView(summary.artist),
        .album = stringView(summary.album),
        .album_artist = stringView(summary.album_artist),
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_player_query_queue(
    runtime: ?*Runtime,
    player: Handle,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?QueueEntryCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    const player_handle = importPlayer(player);
    const status = box.runtime.playerStatus(player_handle) catch |err| return box.fail(@src(), err);
    var entries: [max_page]core.runtime.TrackRef = undefined;
    const count = box.runtime.playerQueuePage(
        player_handle,
        offset,
        entries[0..limit],
    ) catch |err| return box.fail(@src(), err);
    for (entries[0..count], 0..) |entry, index| {
        const position: u32 = offset + @as(u32, @intCast(index));
        const view: QueueEntryView = .{
            .position = position,
            .is_current = @intFromBool(position == status.queue_index),
            .track_id = entry.track_id,
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_player_query_queue_tracks(
    runtime: ?*Runtime,
    player: Handle,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?TrackCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    var page = box.runtime.playerQueueTracks(
        importPlayer(player),
        box.runtime.allocator,
        offset,
        limit,
    ) catch |err| return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view = trackView(item);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_player_queue_jump(
    runtime: ?*Runtime,
    player: Handle,
    position: u32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playerQueueJump(importPlayer(player), position) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_queue_insert_next(
    runtime: ?*Runtime,
    player: Handle,
    ids: ?[*]const i64,
    count: usize,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const player_handle = importPlayer(player);
    const library = (box.runtime.playerLibrary(player_handle) catch |err|
        return box.fail(@src(), err)) orelse return box.reject(@src(), .invalid_state, "player has no library");
    const list = trackIdSlice(ids, count) orelse
        return box.reject(@src(), .invalid_argument, "ids is null or count exceeds the queue capacity");
    box.runtime.playerQueueInsertNext(player_handle, library, list) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_queue_remove(
    runtime: ?*Runtime,
    player: Handle,
    position: u32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playerQueueRemove(importPlayer(player), position) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_queue_stats(
    runtime: ?*Runtime,
    player: Handle,
    output: ?*QueueStats,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const stats = box.runtime.playerQueueStats(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    destination.* = .{
        .entries_started = stats.entries_started,
        .gapless_transitions = stats.gapless_transitions,
        .format_switch_transitions = stats.format_switch_transitions,
        .open_failures = stats.open_failures,
        .decode_errors = stats.decode_errors,
    };
    return .ok;
}

pub export fn orca_enumerate_output_devices(
    runtime: ?*Runtime,
    context: ?*anyopaque,
    callback: ?DeviceCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var devices: [max_devices]audio.backend.Device = undefined;
    const count = box.runtime.enumerateOutputDevices(&devices) catch |err|
        return box.fail(@src(), err);
    for (devices[0..count]) |*device| {
        const view: DeviceView = .{ .id = device.id, .name = stringView(device.nameSlice()) };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_zone_create(runtime: ?*Runtime, output: ?*Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const zone = box.runtime.createZone() catch |err| return box.fail(@src(), err);
    destination.* = exportZoneHandle(zone);
    return .ok;
}

pub export fn orca_zone_destroy(runtime: ?*Runtime, zone: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.destroyZone(importZone(zone)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_zone_attach_player(
    runtime: ?*Runtime,
    zone: Handle,
    player: Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.attachZone(importZone(zone), importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_zone_detach(runtime: ?*Runtime, zone: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.detachZone(importZone(zone)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_zone_open_output(
    runtime: ?*Runtime,
    zone: Handle,
    device_id: u64,
    policy: u8,
    latency_frames: u32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const render_policy = importRenderPolicy(policy) orelse
        return box.reject(@src(), .invalid_argument, "policy must be 0 or 1");
    box.runtime.zoneOpenOutput(
        importZone(zone),
        device_id,
        render_policy,
        latency_frames,
    ) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_zone_close_output(runtime: ?*Runtime, zone: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.zoneCloseOutput(importZone(zone)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_zone_status_get(
    runtime: ?*Runtime,
    zone: Handle,
    output: ?*ZoneStatus,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const stats = box.runtime.zoneStats(importZone(zone)) catch |err| return box.fail(@src(), err);
    destination.* = .{
        .output_state = @intFromEnum(stats.output_state),
        .recovery_attempts = stats.recovery_attempts,
        .backend_quantum_frames = stats.backend_quantum_frames,
        .rendered_entry_serial = stats.rendered_entry_serial,
        .underruns = stats.underruns,
        .dropped_returns = stats.dropped_returns,
    };
    return .ok;
}

pub export fn orca_player_open_default_output(
    runtime: ?*Runtime,
    player: Handle,
    device_id: u64,
    zone_out: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const zone = box.runtime.playerOpenDefaultOutput(importPlayer(player), device_id) catch |err|
        return box.fail(@src(), err);
    if (zone_out) |output| output.* = exportZoneHandle(zone);
    return .ok;
}

fn runtimeBox(runtime: ?*Runtime) ?*RuntimeBox {
    return @ptrCast(@alignCast(runtime orelse return null));
}

/// A call refused for its thread must not write the last error: the owning
/// thread may be reading it.
fn enter(runtime: ?*Runtime) ?*RuntimeBox {
    const box = runtimeBox(runtime) orelse return null;
    if (box.foreignThread()) return null;
    box.last_error[0] = 0;
    return box;
}

fn refusal(runtime: ?*Runtime) Status {
    return if (runtime == null) .invalid_argument else .wrong_thread;
}

fn exportHandle(handle: core.PlayerHandle) Handle {
    return .{ .index = handle.index, .generation = handle.generation };
}

fn exportLibraryHandle(handle: core.LibraryHandle) Handle {
    return .{ .index = handle.index, .generation = handle.generation };
}

fn importPlayer(handle: Handle) core.PlayerHandle {
    return .{ .index = handle.index, .generation = handle.generation };
}

fn importLibrary(handle: Handle) core.LibraryHandle {
    return .{ .index = handle.index, .generation = handle.generation };
}

fn stringView(value: []const u8) StringView {
    return .{ .pointer = value.ptr, .length = value.len };
}

fn optionalId(value: i64) ?i64 {
    return if (value < 0) null else value;
}

fn stringInput(pointer: ?[*]const u8, length: usize) ?[]const u8 {
    if (pointer) |text| return text[0..length];
    return if (length == 0) "" else null;
}

pub fn importPlaylistPathStyle(value: u8) ?core.runtime.PlaylistPathStyle {
    return switch (value) {
        0 => .absolute,
        1 => .relative,
        else => null,
    };
}

pub fn importArtworkSubject(value: u8) ?std.meta.Tag(core.runtime.ArtworkSubject) {
    return switch (value) {
        0 => .track,
        1 => .release,
        else => null,
    };
}

pub fn exportArtworkSubject(subject: core.runtime.ArtworkSubject) u8 {
    return switch (subject) {
        .track => 0,
        .release => 1,
    };
}

pub fn exportArtworkKind(kind: metadata.ArtworkKind) u8 {
    return switch (kind) {
        .front_cover => 0,
        .back_cover => 1,
        .other => 2,
    };
}

fn imageView(image: metadata.EmbeddedImage) ImageView {
    return .{
        .bytes = image.bytes.ptr,
        .length = image.bytes.len,
        .mime_type = stringView(image.mime_type),
        .kind = exportArtworkKind(image.kind),
    };
}

const invalid_track_query = "query limit must be between 1 and 512 and sort a known orca_track_sort";

/// Reject a malformed query at the boundary rather than clamping it: a limit
/// of zero or a sort byte this build does not know is a caller bug, and
/// silently substituting a default would hide it behind plausible-looking
/// rows.
fn importTrackQuery(query: *const TrackQueryView) ?database.TrackQuery {
    if (query.limit == 0 or query.limit > max_page) return null;
    const sort = std.enums.fromInt(TrackSortKey, query.sort) orelse return null;
    return .{
        .artist_id = optionalId(query.artist_id),
        .release_id = optionalId(query.release_id),
        .sort = switch (sort) {
            .id => .id,
            .artist => .artist,
            .album => .album,
            .title => .title,
            .track_number => .track_number,
            .duration => .duration,
            .date_added => .date_added,
            .rating => .rating,
            .loved => .loved,
        },
        .loved_only = query.loved_only != 0,
        .direction = if (query.descending != 0) .descending else .ascending,
        .limit = query.limit,
        .offset = query.offset,
    };
}

const invalid_release_query = "query limit must be between 1 and 512 and sort a known orca_release_sort";

fn importReleaseQuery(query: *const ReleaseQueryView) ?database.ReleaseQuery {
    if (query.limit == 0 or query.limit > max_page) return null;
    return .{
        .album_artist_id = optionalId(query.album_artist_id),
        .sort = importReleaseSort(query.sort) orelse return null,
        .loved_only = query.loved_only != 0,
        .limit = query.limit,
        .offset = query.offset,
    };
}

pub fn importReleaseSort(sort: u8) ?database.ReleaseSort {
    return switch (sort) {
        0 => .title,
        1 => .artist,
        2 => .year,
        3 => .recently_added,
        4 => .loved,
        else => null,
    };
}

const invalid_artist_query = "query limit must be between 1 and 512 and filter not null unless empty";

fn importArtistQuery(query: *const ArtistQueryView) ?database.ArtistQuery {
    if (query.limit == 0 or query.limit > max_page) return null;
    const filter: []const u8 = if (query.filter.pointer) |pointer|
        pointer[0..query.filter.length]
    else if (query.filter.length == 0)
        ""
    else
        return null;
    return .{ .filter = filter, .limit = query.limit, .offset = query.offset };
}

pub fn exportFeedback(feedback: database.Feedback) u8 {
    return switch (feedback) {
        .none => 0,
        .loved => 1,
        .hated => 2,
    };
}

fn exportIdSource(source: ?core.track_details.RecordingIdSource) IdSource {
    const known = source orelse return .none;
    return switch (known) {
        .tag => .tag,
        .match => .match,
        .edit => .edit,
    };
}

fn artistView(item: database.ArtistSummary) ArtistView {
    return .{
        .id = item.id,
        .release_count = item.release_count,
        .track_count = item.track_count,
        .name = stringView(item.name),
        .sort_name = stringView(item.sort_name),
    };
}

fn releaseView(item: database.ReleaseSummary) ReleaseView {
    return .{
        .id = item.id,
        .album_artist_id = item.album_artist_id orelse 0,
        .disc_count = item.disc_count orelse 0,
        .total_duration_ms = item.total_duration_ms,
        .track_count = item.track_count,
        .has_album_artist_id = @intFromBool(item.album_artist_id != null),
        .has_disc_count = @intFromBool(item.disc_count != null),
        .is_compilation = @intFromBool(item.is_compilation),
        .loved = @intFromBool(item.loved),
        .title = stringView(item.title),
        .album_artist = stringView(item.album_artist),
        .release_date = stringView(item.release_date orelse ""),
    };
}

fn trackView(item: database.TrackSummary) TrackView {
    return .{
        .id = item.id,
        .duration_ms = item.duration_ms orelse 0,
        .track_number = item.track_number orelse 0,
        .disc_number = item.disc_number orelse 0,
        .has_duration = @intFromBool(item.duration_ms != null),
        .has_track_number = @intFromBool(item.track_number != null),
        .has_disc_number = @intFromBool(item.disc_number != null),
        .has_file = @intFromBool(item.has_playable_file),
        .feedback = exportFeedback(item.feedback),
        .has_rating = @intFromBool(item.rating != null),
        .rating = item.rating orelse 0,
        .title = stringView(item.title),
        .artist = stringView(item.artist),
        .album = stringView(item.album),
        .album_artist = stringView(item.album_artist),
    };
}

fn trackDetailsView(details: *const core.track_details.TrackDetails) TrackDetailsView {
    const loudness = details.loudness;
    return .{
        .track_id = details.track_id,
        .track_number = details.track_number orelse 0,
        .disc_number = details.disc_number orelse 0,
        .duration_ms = details.duration_ms orelse 0,
        .size_bytes = details.size_bytes orelse 0,
        .last_played_at = details.last_played_at orelse 0,
        .play_count = details.play_count,
        .title = stringView(details.title),
        .artist = stringView(details.artist),
        .album = stringView(details.album),
        .album_artist = stringView(details.album_artist),
        .date = stringView(details.date orelse ""),
        .codec = stringView(details.codec),
        .path = stringView(details.path orelse ""),
        .musicbrainz_recording_id = stringView(details.musicbrainz_recording_id orelse ""),
        .musicbrainz_release_id = stringView(details.musicbrainz_release_id orelse ""),
        .musicbrainz_release_group_id = stringView(details.musicbrainz_release_group_id orelse ""),
        .musicbrainz_release_track_id = stringView(details.musicbrainz_release_track_id orelse ""),
        .musicbrainz_album_artist_id = stringView(details.musicbrainz_album_artist_id orelse ""),
        .sample_rate = details.sample_rate orelse 0,
        .bit_depth = details.bit_depth orelse 0,
        .channels = details.channels orelse 0,
        .bitrate_kbps = details.bitrate_kbps orelse 0,
        .integrated_lufs = if (loudness) |value| value.integrated_lufs else 0,
        .replay_gain_db = if (loudness) |value| value.replay_gain_db else 0,
        .sample_peak = if (loudness) |value| value.sample_peak else 0,
        .has_track_number = @intFromBool(details.track_number != null),
        .has_disc_number = @intFromBool(details.disc_number != null),
        .has_compilation = @intFromBool(details.compilation != null),
        .compilation = @intFromBool(details.compilation orelse false),
        .lossy = @intFromBool(details.lossy),
        .has_sample_rate = @intFromBool(details.sample_rate != null),
        .has_bit_depth = @intFromBool(details.bit_depth != null),
        .has_channels = @intFromBool(details.channels != null),
        .has_duration = @intFromBool(details.duration_ms != null),
        .has_size_bytes = @intFromBool(details.size_bytes != null),
        .has_bitrate_kbps = @intFromBool(details.bitrate_kbps != null),
        .file_missing = @intFromBool(details.file_missing),
        .has_loudness = @intFromBool(loudness != null),
        .has_artwork = @intFromBool(details.has_artwork),
        .has_last_played_at = @intFromBool(details.last_played_at != null),
        .feedback = exportFeedback(details.feedback),
        .feedback_syncable = @intFromBool(details.feedback_syncable),
        .has_rating = @intFromBool(details.rating != null),
        .rating = details.rating orelse 0,
        .musicbrainz_recording_id_source = @intFromEnum(exportIdSource(details.musicbrainz_recording_id_source)),
        .musicbrainz_release_id_source = @intFromEnum(exportIdSource(details.musicbrainz_release_id_source)),
        .musicbrainz_release_group_id_source = @intFromEnum(exportIdSource(details.musicbrainz_release_group_id_source)),
        .musicbrainz_release_track_id_source = @intFromEnum(exportIdSource(details.musicbrainz_release_track_id_source)),
        .musicbrainz_album_artist_id_source = @intFromEnum(exportIdSource(details.musicbrainz_album_artist_id_source)),
    };
}

/// A null pointer is only legal for an empty list; anything else is a caller
/// bug the boundary refuses rather than dereferences.
fn trackIdSlice(ids: ?[*]const i64, count: usize) ?[]const i64 {
    if (count == 0) return &.{};
    const pointer = ids orelse return null;
    if (count > audio.playback_queue.capacity) return null;
    return pointer[0..count];
}

const invalid_edit_ids = "ids is null or count exceeds 512";

fn editIdSlice(ids: ?[*]const i64, count: usize) ?[]const i64 {
    if (count == 0) return &.{};
    const pointer = ids orelse return null;
    if (count > max_page) return null;
    return pointer[0..count];
}

const max_track_edits = 64;

pub fn exportMetadataField(field: metadata.Field) u8 {
    return switch (field) {
        .title => 0,
        .artist => 1,
        .album => 2,
        .track_number => 3,
        .album_artist => 4,
        .disc_number => 5,
        .date => 6,
        .compilation => 7,
        .musicbrainz_recording_id => 8,
        .musicbrainz_release_id => 9,
        .musicbrainz_release_group_id => 10,
        .musicbrainz_release_track_id => 11,
        .musicbrainz_album_artist_id => 12,
    };
}

pub fn importMetadataField(value: u8) ?metadata.Field {
    return switch (value) {
        0 => .title,
        1 => .artist,
        2 => .album,
        3 => .track_number,
        4 => .album_artist,
        5 => .disc_number,
        6 => .date,
        7 => .compilation,
        8 => .musicbrainz_recording_id,
        9 => .musicbrainz_release_id,
        10 => .musicbrainz_release_group_id,
        11 => .musicbrainz_release_track_id,
        12 => .musicbrainz_album_artist_id,
        else => null,
    };
}

pub fn exportProvenance(provenance: metadata.Provenance) u8 {
    return switch (provenance) {
        .observed_file => 0,
        .user => 1,
        .provider => 2,
        .inference => 3,
        .analysis => 4,
    };
}

pub fn exportTagWriteSkipReason(reason: core.runtime.TagWriteSkipReason) u8 {
    return switch (reason) {
        .missing => 0,
        .format_not_writable => 1,
        .changed_since_scan => 2,
    };
}

pub fn exportHealthIssueKind(kind: database.HealthIssueKind) u8 {
    return switch (kind) {
        .missing_metadata => 0,
        .missing_track_number => 1,
        .album_artist_anomaly => 2,
        .artwork_problem => 3,
        .missing_analysis => 4,
        .clipping => 5,
        .excessive_silence => 6,
        .technical_anomaly => 7,
        .corrupt_audio => 8,
        .exact_duplicate => 9,
        .likely_duplicate => 10,
        .unreadable_file => 11,
        .recording_mismatch => 12,
    };
}

pub fn importHealthIssueKind(value: u8) ?database.HealthIssueKind {
    return switch (value) {
        0 => .missing_metadata,
        1 => .missing_track_number,
        2 => .album_artist_anomaly,
        3 => .artwork_problem,
        4 => .missing_analysis,
        5 => .clipping,
        6 => .excessive_silence,
        7 => .technical_anomaly,
        8 => .corrupt_audio,
        9 => .exact_duplicate,
        10 => .likely_duplicate,
        11 => .unreadable_file,
        12 => .recording_mismatch,
        else => null,
    };
}

pub fn exportHealthSeverity(severity: database.HealthSeverity) u8 {
    return switch (severity) {
        .information => 0,
        .warning => 1,
        .error_severity => 2,
    };
}

pub fn exportHealthAction(action: database.HealthAction) u8 {
    return switch (action) {
        .match_or_edit => 0,
        .fetch_cover_art => 1,
        .compare_duplicate => 2,
        .review_correction => 3,
        .reveal_file => 4,
    };
}

fn importFeedback(value: u8) ?database.Feedback {
    return switch (value) {
        0 => .none,
        1 => .loved,
        2 => .hated,
        else => null,
    };
}

fn exportJobHandle(handle: core.JobHandle) Handle {
    return .{ .index = handle.index, .generation = handle.generation };
}

fn exportZoneHandle(handle: core.ZoneHandle) Handle {
    return .{ .index = handle.index, .generation = handle.generation };
}

fn importJob(handle: Handle) core.JobHandle {
    return .{ .index = handle.index, .generation = handle.generation };
}

fn importZone(handle: Handle) core.ZoneHandle {
    return .{ .index = handle.index, .generation = handle.generation };
}

pub fn importReplayGainMode(mode: u8) ?audio.processing.ReplayGainMode {
    return switch (mode) {
        0 => .off,
        1 => .track,
        else => null,
    };
}

pub fn importEqualizerPreset(preset: u8) ?audio.dsp.Preset {
    return switch (preset) {
        0 => .flat,
        1 => .bass,
        2 => .treble,
        3 => .vocal,
        4 => .loudness,
        else => null,
    };
}

pub fn exportSampleFormat(format: audio.pcm.SampleFormat) u8 {
    return switch (format) {
        .unsigned_8 => 0,
        .signed_16 => 1,
        .signed_24 => 2,
        .signed_32 => 3,
        .float_32 => 4,
        .float_64 => 5,
    };
}

pub fn exportSignalReason(reason: audio.signal_path.Reason) u8 {
    return switch (reason) {
        .sample_processing => 0,
        .sample_rate_conversion => 1,
        .channel_layout_conversion => 2,
        .sample_format_conversion => 3,
        .lossy_source => 4,
    };
}

fn exportEqualizer(equalizer: audio.dsp.Equalizer) EqualizerView {
    return .{ .gains_db = equalizer.gains_db, .preamp_db = equalizer.preamp_db };
}

fn importEqualizer(equalizer: *const EqualizerView) audio.dsp.Equalizer {
    return .{ .gains_db = equalizer.gains_db, .preamp_db = equalizer.preamp_db };
}

fn exportPcmFormat(format: ?audio.pcm.Format) PcmFormatView {
    const value = format orelse return std.mem.zeroes(PcmFormatView);
    return .{
        .sample_rate = value.sample_rate,
        .channels = value.channels,
        .bits_per_sample = value.bits_per_sample,
        .bytes_per_frame = value.bytes_per_frame,
        .sample_format = exportSampleFormat(value.sample_format),
    };
}

fn exportSignalPath(path: *const audio.dsp.SignalPath) SignalPathView {
    var view: SignalPathView = .{
        .source = exportPcmFormat(path.source),
        .output = exportPcmFormat(path.output),
        .equalizer = if (path.equalizer) |value| exportEqualizer(value) else std.mem.zeroes(EqualizerView),
        .replay_gain_db = path.replay_gain_db orelse 0,
        .crossfeed = path.crossfeed orelse 0,
        .volume = path.volume,
        .device_rate = path.device_rate orelse 0,
        .reason_count = @intCast(path.reason_count),
        .reasons = @splat(0),
        .has_source = @intFromBool(path.source != null),
        .source_declared = @intFromBool(path.source_declared),
        .has_output = @intFromBool(path.output != null),
        .has_replay_gain = @intFromBool(path.replay_gain_db != null),
        .has_equalizer = @intFromBool(path.equalizer != null),
        .has_crossfeed = @intFromBool(path.crossfeed != null),
        .has_device_rate = @intFromBool(path.device_rate != null),
        .bit_perfect_eligible = @intFromBool(path.bit_perfect_eligible),
        .widened_exactly = @intFromBool(path.widened_exactly),
        .codec = stringView(path.codec orelse ""),
    };
    for (path.reasonList(), 0..) |reason, index| view.reasons[index] = exportSignalReason(reason);
    return view;
}

pub fn importRenderPolicy(policy: u8) ?audio.zone.RenderPolicy {
    return switch (policy) {
        0 => .robust,
        1 => .interactive,
        else => null,
    };
}

pub fn exportWatchState(state: core.runtime.WatchState) u8 {
    return switch (state) {
        .off => 0,
        .watching => 1,
        .degraded => 2,
        .unsupported => 3,
    };
}

fn exportFailure(failure: control.Failure) u8 {
    return switch (failure) {
        .runtime_not_running => 0,
        .stale_handle => 1,
        .out_of_memory => 2,
        .invalid_transition => 3,
        .player_not_bound => 4,
        .track_has_no_file => 5,
        .track_file_missing => 6,
        .codec_unavailable => 7,
        .queue_full => 8,
        .not_playable => 9,
        .internal => 255,
    };
}

pub fn exportJobKind(kind: job.Kind) u8 {
    return switch (kind) {
        .scan => 0,
        .projection => 1,
        .property_backfill => 2,
        .analysis => 3,
        .duplicate_scan => 4,
        .reconcile => 5,
        .metadata_lookup => 6,
        .acoustid_submission => 7,
        .mutation => 8,
        .artwork, .conversion, .ripping, .dummy => 255,
    };
}

/// One lossless completion, flattened into the POD union. The handle field is
/// zeroed for outcomes that name no object, so a host never reads a handle that
/// means nothing.
pub fn exportCompletion(event: control.Event) Event {
    var completed: CommandCompletedEvent = .{
        .request_id = event.request_id,
        .outcome = 255,
        .failure = 255,
        .object = .{ .index = 0, .generation = 0 },
    };
    switch (event.outcome) {
        .library_created => |value| {
            completed.outcome = 0;
            completed.object = exportLibraryHandle(value);
        },
        .player_created => |value| {
            completed.outcome = 1;
            completed.object = exportHandle(value);
        },
        .zone_created => |value| {
            completed.outcome = 2;
            completed.object = exportZoneHandle(value);
        },
        .job_started => |value| {
            completed.outcome = 3;
            completed.object = exportJobHandle(value);
        },
        .job_cancellation_requested => |value| {
            completed.outcome = 4;
            completed.object = exportJobHandle(value);
        },
        .track_playing => |value| {
            completed.outcome = 5;
            completed.object = exportHandle(value);
        },
        .job_finished => |value| return .{
            .kind = @intFromEnum(EventKind.job_finished),
            .payload = .{ .job_finished = .{
                .job = exportJobHandle(value.job),
                .state = @intFromEnum(value.state),
            } },
        },
        .failed => |failure| {
            completed.outcome = 255;
            completed.failure = exportFailure(failure);
        },
    }
    return .{
        .kind = @intFromEnum(EventKind.command_completed),
        .payload = .{ .command_completed = completed },
    };
}

fn exportTelemetry(telemetry: control.Telemetry) ?Event {
    return switch (telemetry) {
        .player_position => |position| .{
            .kind = @intFromEnum(EventKind.player_position),
            .payload = .{ .player_position = .{
                .player = exportHandle(position.player),
                .frames = position.frames,
            } },
        },
        .job_progress => |progress| .{
            .kind = @intFromEnum(EventKind.job_progress),
            .payload = .{ .job_progress = .{
                .job = exportJobHandle(progress.job),
                .has_total = @intFromBool(progress.total_units != null),
                .completed_units = progress.completed_units,
                .total_units = progress.total_units orelse 0,
            } },
        },
        .library_changed => |changed| .{
            .kind = @intFromEnum(EventKind.library_changed),
            .payload = .{ .library_changed = .{ .library = exportLibraryHandle(changed.library) } },
        },
    };
}

fn mapError(err: anyerror) Status {
    return switch (err) {
        error.RuntimeNotRunning => .runtime_not_running,
        error.StaleHandle => .stale_handle,
        error.OutOfMemory => .out_of_memory,
        error.PlayerHasNoSource,
        error.PlayerHasNoOutput,
        error.PlayerHasNoLibrary,
        error.PlayerBoundToAnotherLibrary,
        error.QueueEntryInUse,
        error.LibraryHasNoDatabase,
        error.ZoneOwnedByEngine,
        error.InvalidJobTransition,
        error.JobAlreadyFinished,
        error.WorkersRunning,
        => .invalid_state,
        error.AlreadyWatching => .invalid_state,
        error.PlaylistNameTaken, error.PlaylistFull, error.PlaylistEmpty => .invalid_state,
        error.NoBackupDirectory, error.MutationGroupNotCommitted, error.ClientIdentityRequired, error.TagTargetUnavailable => .invalid_state,
        error.TrackHasNoPlayableFile, error.TrackFileMissing, error.UnknownRoot, error.UnknownPlaylist, error.UnknownFile => .not_found,
        error.TrackNotFound, error.UnknownTagWritePlan, error.MutationGroupNotFound => .not_found,
        error.PlaybackQueueFull, error.ArtworkQueueFull, error.LibraryJobRunning, error.LibraryScanRunning, error.MutationInProgress => .busy,
        error.TooManyPendingTagWrites, error.TagWriteInProgress => .busy,
        error.MatchingAlreadyRunning, error.AcoustIdBusy => .busy,
        error.AcoustIdRequired, error.StaleIdentificationProposal, error.StaleCorrectionGroup, error.ProposalInGroup => .invalid_state,
        error.UnknownRelease, error.UnknownIdentificationProposal, error.UnknownCorrectionGroup => .not_found,
        error.MutationGroupAlreadyUndone => .already_done,
        error.MutationNeedsReconciliation => .needs_reconciliation,
        error.TagWriteBackupPruned => .gone,
        error.CodecUnavailable,
        error.UnsupportedAudioFormat,
        error.UnsupportedChannelCount,
        error.WatchingUnsupported,
        => .unsupported,
        error.InvalidVolume,
        error.InvalidBatchSize,
        error.InvalidLibraryRoot,
        error.InvalidWatchOptions,
        error.InvalidReconcileDirectory,
        error.PositionOutOfRange,
        error.InvalidPlaylistName,
        error.PlaylistTooLarge,
        error.EqualizerGainOutOfRange,
        error.EqualizerPreampOutOfRange,
        error.CrossfeedAmountOutOfRange,
        error.InvalidTrackSelection,
        error.NoTrackEdits,
        error.InvalidEditValue,
        error.InvalidMutationGroup,
        error.MutationApprovalMismatch,
        error.InvalidServerUrl,
        error.InvalidAcoustIdKey,
        error.InvalidNetworkConfiguration,
        error.InvalidMatchRequest,
        error.InvalidMinimumConfidence,
        error.PageOutOfRange,
        => .invalid_argument,
        else => .internal,
    };
}

/// Bounded page size shared by every query on this boundary: a frontend model
/// stays virtualized, and no callback loop can run unbounded.
const max_page: u32 = 512;
/// Devices are enumerated into a fixed frame buffer; a host with more outputs
/// than this sees the first `max_devices`.
const max_devices: usize = 32;

test "a Player with nothing to play and nowhere to play it refuses to start" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    try std.testing.expectEqual(Status.invalid_state, orca_player_play(runtime, player));
    var status: PlayerStatus = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_status_get(runtime, player, &status));
    try std.testing.expectEqual(@as(u8, 0), status.transport);
    try std.testing.expectEqual(@as(u8, 0), status.has_track);
    try std.testing.expectEqual(@as(u32, 0), status.queue_length);
    try std.testing.expectEqual(@as(f32, 1), status.volume);
    try std.testing.expectEqual(Status.ok, orca_player_set_volume(runtime, player, 0.5));
    var volume: f32 = 0;
    try std.testing.expectEqual(Status.ok, orca_player_volume(runtime, player, &volume));
    try std.testing.expectEqual(@as(f32, 0.5), volume);
    // Milliseconds cannot be converted without a loaded source, and the
    // boundary says so rather than seeking to frame zero.
    try std.testing.expectEqual(
        Status.invalid_state,
        orca_player_seek_ms(runtime, player, 1000, null),
    );
    var generation: u64 = 0;
    try std.testing.expectEqual(Status.ok, orca_player_seek(runtime, player, 48_000, &generation));
    try std.testing.expect(generation > 1);
    try std.testing.expectEqual(Status.ok, orca_player_destroy(runtime, player));
    try std.testing.expectEqual(Status.stale_handle, orca_player_status_get(runtime, player, &status));
}

test "C ABI library query is bounded and callback-scoped" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api?mode=memory&cache=shared",
        &library,
    ));
    const box = runtimeBox(runtime).?;
    try (try core.runtime.databaseOf(&box.runtime, importLibrary(library))).tracks.upsertTracks(&.{
        .{ .title = "First", .album = "Generated", .album_artist = "Orca" },
        .{ .title = "Second", .album = "Generated", .album_artist = "Orca" },
    });
    var count: u64 = 0;
    try std.testing.expectEqual(Status.ok, orca_library_track_count(runtime, library, &count));
    try std.testing.expectEqual(@as(u64, 2), count);
    var visited: usize = 0;
    try std.testing.expectEqual(Status.ok, orca_library_query_tracks(
        runtime,
        library,
        null,
        0,
        1,
        1,
        &visited,
        countTrack,
    ));
    try std.testing.expectEqual(@as(usize, 1), visited);
    const library_database = try core.runtime.databaseOf(&box.runtime, importLibrary(library));
    const file_id = try library_database.files.create(.{ .size_bytes = 1024 });
    _ = try library_database.locations.upsert(.{
        .file_id = file_id,
        .volume_id = @import("database/root.zig").LibraryDatabase.null_volume,
        .uri = "track.flac",
    });
    try library_database.health_issues.replaceFile(file_id, &.{.{
        .kind = .clipping,
        .severity = .warning,
        .details = "clipped",
    }});
    try std.testing.expectEqual(Status.ok, orca_library_health_issue_count(runtime, library, &count));
    try std.testing.expectEqual(@as(u64, 1), count);
    visited = 0;
    try std.testing.expectEqual(Status.ok, orca_library_query_health_issues(
        runtime,
        library,
        10,
        0,
        &visited,
        countHealthIssue,
    ));
    try std.testing.expectEqual(@as(usize, 1), visited);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

test "the wake callback fires on a submitted command and the pump timeout follows it" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var counter: control.CountingWaker = .{};
    const waker = counter.waker();
    try std.testing.expectEqual(Status.ok, orca_runtime_set_wake_callback(runtime, waker.wake_fn, waker.context));
    var timeout: i64 = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_pump_timeout(runtime, null));
    try std.testing.expectEqual(Status.ok, orca_runtime_pump_timeout(runtime, &timeout));
    try std.testing.expectEqual(pump_no_timeout, timeout);

    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-wake?mode=memory&cache=shared", &library));
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    try std.testing.expectEqual(Status.ok, orca_player_set_library(runtime, player, library));
    var request_id: u64 = 0;
    try std.testing.expectEqual(Status.ok, orca_player_play_track(runtime, player, 1, &request_id));
    try std.testing.expectEqual(@as(u32, 1), counter.count());
    try std.testing.expectEqual(Status.ok, orca_runtime_pump_timeout(runtime, &timeout));
    try std.testing.expectEqual(@as(i64, 0), timeout);

    try std.testing.expectEqual(Status.ok, orca_runtime_pump(runtime));
    var event: Event = undefined;
    var completed = false;
    while (true) {
        try std.testing.expectEqual(Status.ok, orca_runtime_poll_event(runtime, &event, null));
        if (event.kind == @intFromEnum(EventKind.none)) break;
        if (event.kind == @intFromEnum(EventKind.command_completed) and
            event.payload.command_completed.request_id == request_id) completed = true;
    }
    try std.testing.expect(completed);
    try std.testing.expectEqual(Status.ok, orca_runtime_pump_timeout(runtime, &timeout));
    try std.testing.expectEqual(pump_no_timeout, timeout);

    try std.testing.expectEqual(Status.invalid_state, orca_runtime_set_wake_callback(runtime, null, null));
    try std.testing.expectEqualStrings(
        "orca_runtime_set_wake_callback: WorkersRunning",
        std.mem.span(orca_runtime_last_error(runtime)),
    );
}

test "orca_version is liborca's version" {
    try std.testing.expectEqualStrings(
        std.fmt.comptimePrint("{f}", .{version.value}),
        std.mem.span(orca_version()),
    );
}

test "a failing call leaves its function and reason as the last error, and the next successful call clears it" {
    try std.testing.expectEqualStrings("", std.mem.span(orca_runtime_last_error(null)));
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    try std.testing.expectEqualStrings("", std.mem.span(orca_runtime_last_error(runtime)));

    var library: Handle = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_open(runtime, null, &library));
    try std.testing.expectEqualStrings("orca_library_open: path is null", std.mem.span(orca_runtime_last_error(runtime)));

    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    try std.testing.expectEqualStrings("", std.mem.span(orca_runtime_last_error(runtime)));

    try std.testing.expectEqual(Status.invalid_state, orca_player_play(runtime, player));
    try std.testing.expectEqualStrings("orca_player_play: PlayerHasNoSource", std.mem.span(orca_runtime_last_error(runtime)));
}

test "a call refused for its thread leaves the owner's last error untouched" {
    if (builtin.mode != .Debug) return error.SkipZigTest;
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_open(runtime, null, &library));

    var status: Status = .ok;
    const thread = try std.Thread.spawn(.{}, playFromAnotherThread, .{ runtime, &status });
    thread.join();

    try std.testing.expectEqual(Status.wrong_thread, status);
    try std.testing.expectEqualStrings("orca_library_open: path is null", std.mem.span(orca_runtime_last_error(runtime)));
}

fn playFromAnotherThread(runtime: *Runtime, status: *Status) void {
    status.* = orca_player_play(runtime, .{ .index = 0, .generation = 0 });
}

test "a last error longer than its buffer is truncated and stays terminated" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;
    box.recordError("orca_library_open", "x" ** 400);
    const message = std.mem.span(orca_runtime_last_error(runtime));
    try std.testing.expectEqual(@as(usize, last_error_capacity), message.len);
    try std.testing.expect(std.mem.startsWith(u8, message, "orca_library_open: xxx"));
}

test "browse queries refuse an unknown sort, an unbounded limit and null pointers" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-browse?mode=memory&cache=shared",
        &library,
    ));
    var visited: usize = 0;
    var count: u64 = 0;

    var releases: ReleaseQueryView = .{ .album_artist_id = -1, .sort = 5, .loved_only = 0, .limit = 8, .offset = 0 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_releases(runtime, library, &releases, &visited, countRelease));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_count_matching(runtime, library, &releases, &count));
    releases.sort = 4;
    releases.limit = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_releases(runtime, library, &releases, &visited, countRelease));
    releases.limit = max_page + 1;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_releases(runtime, library, &releases, &visited, countRelease));
    releases.limit = max_page;
    try std.testing.expectEqual(Status.ok, orca_library_browse_releases(runtime, library, &releases, &visited, countRelease));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_releases(runtime, library, null, &visited, countRelease));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_releases(runtime, library, &releases, &visited, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_count_matching(runtime, library, null, &count));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_count_matching(runtime, library, &releases, null));

    var artists: ArtistQueryView = .{ .filter = .{ .pointer = null, .length = 3 }, .limit = 8, .offset = 0 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_artists(runtime, library, &artists, &visited, countArtist));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_count_matching(runtime, library, &artists, &count));
    artists.filter.length = 0;
    try std.testing.expectEqual(Status.ok, orca_library_artist_count_matching(runtime, library, &artists, &count));
    artists.limit = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_artists(runtime, library, &artists, &visited, countArtist));
    artists.limit = max_page + 1;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_artists(runtime, library, &artists, &visited, countArtist));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_artists(runtime, library, null, &visited, countArtist));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_count_matching(runtime, library, null, &count));
    artists.limit = 8;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_count_matching(runtime, library, &artists, null));

    var tracks: TrackQueryView = .{ .artist_id = -1, .release_id = -1, .sort = 9, .descending = 0, .loved_only = 1, .limit = 8, .offset = 0 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_tracks(runtime, library, &tracks, &visited, countTrack));
    tracks.sort = @intFromEnum(TrackSortKey.loved);
    try std.testing.expectEqual(Status.ok, orca_library_track_match_count(runtime, library, &tracks, &count));

    try std.testing.expectEqual(@as(usize, 0), visited);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_play_stats(runtime, library, 1, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_listens_recorded(runtime, library, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_unanalyzed_count(runtime, library, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_get(runtime, library, 1, null, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_details(runtime, library, 1, null, null));
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

test "health actions refuse an unknown kind, a missing file and a null callback, and change nothing" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-health-actions?mode=memory&cache=shared",
        &library,
    ));
    const box = runtimeBox(runtime).?;
    const library_database = try core.runtime.databaseOf(&box.runtime, importLibrary(library));
    const file_id = try library_database.files.create(.{ .size_bytes = 1024 });
    try library_database.health_issues.replaceFile(file_id, &.{.{
        .kind = .clipping,
        .severity = .warning,
        .details = "clipped",
    }});
    const clipping: u8 = exportHealthIssueKind(.clipping);

    try std.testing.expectEqual(Status.invalid_argument, orca_library_dismiss_health_issue(runtime, library, file_id, 200));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_restore_health_issue(runtime, library, file_id, 13));
    try std.testing.expectEqual(Status.not_found, orca_library_dismiss_health_issue(runtime, library, file_id + 100, clipping));
    try std.testing.expectEqual(Status.ok, orca_library_restore_health_issue(runtime, library, file_id + 100, clipping));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_health_items(runtime, library, 1, 0, null, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_health_items(runtime, library, 0, 0, null, countHealthItem));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_health_items(runtime, library, 513, 0, null, countHealthItem));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_health_file(runtime, library, file_id, null, null));

    var visited: usize = 0;
    try std.testing.expectEqual(Status.not_found, orca_library_health_file(runtime, library, file_id + 100, &visited, countHealthFile));
    try std.testing.expectEqual(@as(usize, 0), visited);
    try std.testing.expectEqual(Status.ok, orca_library_health_file(runtime, library, file_id, &visited, countHealthFile));
    try std.testing.expectEqual(@as(usize, 1), visited);

    visited = 0;
    try std.testing.expectEqual(Status.ok, orca_library_dismiss_health_issue(runtime, library, file_id, clipping));
    try std.testing.expectEqual(Status.ok, orca_library_query_health_items(runtime, library, 10, 0, &visited, countHealthItem));
    try std.testing.expectEqual(@as(usize, 0), visited);
    try std.testing.expectEqual(Status.ok, orca_library_restore_health_issue(runtime, library, file_id, clipping));
    try std.testing.expectEqual(Status.ok, orca_library_query_health_items(runtime, library, 10, 0, &visited, countHealthItem));
    try std.testing.expectEqual(@as(usize, 1), visited);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

test "a Track the Library does not hold is not found, and its callback never runs" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-track-get?mode=memory&cache=shared",
        &library,
    ));
    const box = runtimeBox(runtime).?;
    try (try core.runtime.databaseOf(&box.runtime, importLibrary(library))).tracks.upsertTracks(&.{
        .{ .title = "Only", .album = "Generated", .album_artist = "Orca" },
    });
    var visited: usize = 0;
    try std.testing.expectEqual(Status.ok, orca_library_track_get(runtime, library, 1, &visited, countSummary));
    try std.testing.expectEqual(Status.ok, orca_library_track_details(runtime, library, 1, &visited, countDetails));
    try std.testing.expectEqual(@as(usize, 2), visited);
    try std.testing.expectEqual(Status.not_found, orca_library_track_get(runtime, library, 2, &visited, countSummary));
    try std.testing.expectEqualStrings("orca_library_track_get: no such track", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(Status.not_found, orca_library_track_details(runtime, library, 2, &visited, countDetails));
    try std.testing.expectEqual(@as(usize, 2), visited);
    var stats: PlayStatsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_track_play_stats(runtime, library, 2, &stats));
    try std.testing.expectEqual(@as(u64, 0), stats.play_count);
    try std.testing.expectEqual(@as(u8, 0), stats.has_last_played_at);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

fn countRelease(context: ?*anyopaque, release: *const ReleaseView) callconv(.c) void {
    _ = release;
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
}

fn countArtist(context: ?*anyopaque, artist: *const ArtistView) callconv(.c) void {
    _ = artist;
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
}

fn countSummary(context: ?*anyopaque, summary: *const TrackSummaryView) callconv(.c) void {
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
    std.debug.assert(summary.track.feedback == 0 and summary.track.has_rating == 0);
}

fn countDetails(context: ?*anyopaque, details: *const TrackDetailsView) callconv(.c) void {
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
    std.debug.assert(details.title.length != 0 and details.has_loudness == 0);
}

fn countTrack(context: ?*anyopaque, track: *const TrackView) callconv(.c) void {
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
    std.debug.assert(track.title.length != 0);
}

fn countHealthItem(context: ?*anyopaque, item: *const HealthItemView) callconv(.c) void {
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
    std.debug.assert(item.file_id > 0);
}

fn countHealthFile(context: ?*anyopaque, file: *const HealthFileView) callconv(.c) void {
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
    std.debug.assert(file.file_id > 0);
}

fn countHealthIssue(context: ?*anyopaque, issue: *const HealthIssueView) callconv(.c) void {
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
    std.debug.assert(issue.path.length != 0);
}

test "feedback, rating and release love edits refuse bad arguments and leave the Library untouched" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-edits?mode=memory&cache=shared",
        &library,
    ));
    const ids = [_]i64{1};
    var change: ChangeCount = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_feedback(runtime, library, &ids, 1, 3, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_feedback(runtime, library, null, 1, 1, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_feedback(runtime, library, &ids, 1, 1, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_rating(runtime, library, &ids, 1, 101, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_rating(runtime, library, null, 1, 80, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_rating(runtime, library, &ids, 1, 80, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_release_love(runtime, library, &ids, 1, 2, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_release_love(runtime, library, null, 1, 1, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_release_love(runtime, library, &ids, 1, 1, null));
    const too_many = [_]i64{1} ** (max_page + 1);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_rating(runtime, library, &too_many, too_many.len, 80, &change));
    var feedback: u8 = 9;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_feedback(runtime, library, 1, null));
    try std.testing.expectEqual(Status.ok, orca_library_track_feedback(runtime, library, 1, &feedback));
    try std.testing.expectEqual(@as(u8, 0), feedback);

    change = .{ .updated = 7, .skipped = 7 };
    try std.testing.expectEqual(Status.ok, orca_library_set_rating(runtime, library, null, 0, 80, &change));
    try std.testing.expectEqual(ChangeCount{ .updated = 0, .skipped = 0 }, change);
    try std.testing.expectEqual(Status.ok, orca_library_set_rating(runtime, library, &ids, 1, 80, &change));
    try std.testing.expectEqual(ChangeCount{ .updated = 0, .skipped = 1 }, change);
    try std.testing.expectEqual(Status.ok, orca_library_set_release_love(runtime, library, &ids, 1, 1, &change));
    try std.testing.expectEqual(ChangeCount{ .updated = 0, .skipped = 1 }, change);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

test "queue edits refuse a Player without a Library, null ids and positions past the end" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    const ids = [_]i64{1};
    var visited: usize = 0;
    try std.testing.expectEqual(Status.invalid_state, orca_player_queue_insert_next(runtime, player, &ids, 1));
    try std.testing.expectEqual(Status.invalid_state, orca_player_query_queue_tracks(runtime, player, 8, 0, &visited, countTrack));

    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-queue-edits?mode=memory&cache=shared", &library));
    try std.testing.expectEqual(Status.ok, orca_player_set_library(runtime, player, library));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_queue_insert_next(runtime, player, null, 1));
    try std.testing.expectEqual(
        Status.invalid_argument,
        orca_player_queue_insert_next(runtime, player, &ids, audio.playback_queue.capacity + 1),
    );
    try std.testing.expectEqual(Status.invalid_argument, orca_player_queue_jump(runtime, player, 0));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_play_tracks(runtime, player, &ids, 1, 1));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_queue_remove(runtime, player, 0));
    try std.testing.expectEqualStrings(
        "orca_player_queue_remove: PositionOutOfRange",
        std.mem.span(orca_runtime_last_error(runtime)),
    );

    try std.testing.expectEqual(Status.invalid_argument, orca_player_query_queue_tracks(runtime, player, 0, 0, &visited, countTrack));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_query_queue_tracks(runtime, player, max_page + 1, 0, &visited, countTrack));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_query_queue_tracks(runtime, player, 8, 0, &visited, null));
    try std.testing.expectEqual(Status.ok, orca_player_query_queue_tracks(runtime, player, 8, 0, &visited, countTrack));
    try std.testing.expectEqual(@as(usize, 0), visited);
}

fn countPlaylist(context: ?*anyopaque, playlist: *const PlaylistView) callconv(.c) void {
    _ = playlist;
    const visited: *usize = @ptrCast(@alignCast(context.?));
    visited.* += 1;
}

fn countPlaylistEntry(context: ?*anyopaque, entry: *const PlaylistEntryView) callconv(.c) void {
    _ = entry;
    const visited: *usize = @ptrCast(@alignCast(context.?));
    visited.* += 1;
}

test "playlist edits refuse bad arguments, blank or taken names and unknown playlists" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-playlists?mode=memory&cache=shared", &library));
    var id: i64 = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_create_playlist(runtime, library, null, 3, &id));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_create_playlist(runtime, library, "Mix", 3, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_create_playlist(runtime, library, "   ", 3, &id));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_create_playlist(runtime, library, null, 0, &id));
    try std.testing.expectEqual(Status.ok, orca_library_create_playlist(runtime, library, "Mix", 3, &id));
    try std.testing.expectEqual(Status.invalid_state, orca_library_create_playlist(runtime, library, " Mix ", 5, &id));
    try std.testing.expectEqualStrings(
        "orca_library_create_playlist: PlaylistNameTaken",
        std.mem.span(orca_runtime_last_error(runtime)),
    );

    var visited: usize = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlists(runtime, library, 0, 0, &visited, countPlaylist));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlists(runtime, library, max_page + 1, 0, &visited, countPlaylist));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlists(runtime, library, 8, 0, &visited, null));
    try std.testing.expectEqual(Status.ok, orca_library_query_playlists(runtime, library, 8, 0, &visited, countPlaylist));
    try std.testing.expectEqual(@as(usize, 1), visited);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlist_entries(runtime, library, id, 0, 0, &visited, countPlaylistEntry));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlist_entries(runtime, library, id, 8, 0, &visited, null));

    const unknown: i64 = id + 1000;
    const ids = [_]i64{12345};
    const positions = [_]u32{0};
    var change: ChangeCount = undefined;
    var removed: u32 = 9;
    var written: u32 = 0;
    var skipped: u32 = 0;
    try std.testing.expectEqual(Status.not_found, orca_library_rename_playlist(runtime, library, unknown, "Other", 5));
    try std.testing.expectEqual(Status.not_found, orca_library_delete_playlist(runtime, library, unknown));
    try std.testing.expectEqual(Status.not_found, orca_library_query_playlist_entries(runtime, library, unknown, 8, 0, &visited, countPlaylistEntry));
    try std.testing.expectEqual(Status.not_found, orca_library_playlist_insert(runtime, library, unknown, &ids, 1, -1, &change));
    try std.testing.expectEqual(Status.not_found, orca_library_playlist_remove(runtime, library, unknown, &positions, 1, &removed));
    try std.testing.expectEqual(Status.not_found, orca_library_playlist_move(runtime, library, unknown, 0, 0));
    try std.testing.expectEqual(Status.not_found, orca_library_export_playlist(runtime, library, unknown, "unused.m3u", 10, 0, 0, &written, &skipped));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_rename_playlist(runtime, library, id, "", 0));

    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_insert(runtime, library, id, null, 1, -1, &change));
    const too_many = [_]i64{1} ** (max_page + 1);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_insert(runtime, library, id, &too_many, too_many.len, -1, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_insert(runtime, library, id, &ids, 1, -1, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_insert(runtime, library, id, &ids, 1, 1, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_insert(runtime, library, id, &ids, 1, std.math.maxInt(u32) + 1, &change));
    try std.testing.expectEqual(Status.ok, orca_library_playlist_insert(runtime, library, id, &ids, 1, -1, &change));
    try std.testing.expectEqual(ChangeCount{ .updated = 0, .skipped = 1 }, change);

    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_remove(runtime, library, id, null, 1, &removed));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_remove(runtime, library, id, &positions, 1, null));
    const too_many_positions = [_]u32{0} ** (max_page + 1);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_remove(runtime, library, id, &too_many_positions, too_many_positions.len, &removed));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_remove(runtime, library, id, &positions, 1, &removed));
    try std.testing.expectEqual(Status.ok, orca_library_playlist_remove(runtime, library, id, null, 0, &removed));
    try std.testing.expectEqual(@as(u32, 0), removed);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_move(runtime, library, id, 0, 0));

    try std.testing.expectEqual(Status.invalid_argument, orca_library_export_playlist(runtime, library, id, "unused.m3u", 10, 2, 0, &written, &skipped));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_export_playlist(runtime, library, id, "unused.m3u", 10, 0, 2, &written, &skipped));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_export_playlist(runtime, library, id, null, 10, 0, 0, &written, &skipped));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_export_playlist(runtime, library, id, "", 0, 0, 0, &written, &skipped));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_export_playlist(runtime, library, id, "unused.m3u", 10, 0, 0, null, &skipped));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_export_playlist(runtime, library, id, "unused.m3u", 10, 0, 0, &written, null));
    try std.testing.expectEqual(Status.not_found, orca_library_export_playlist(runtime, library, id, "/nonexistent/orca-c-api/out.m3u", 31, 0, 0, &written, &skipped));

    var imported: PlaylistImport = undefined;
    const missing = "/nonexistent/orca-c-api/missing.m3u";
    try std.testing.expectEqual(Status.invalid_argument, orca_library_import_playlist(runtime, library, missing, missing.len, null, 0, null, null, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_import_playlist(runtime, library, "", 0, null, 0, &imported, null, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_import_playlist(runtime, library, missing, missing.len, null, 2, &imported, null, null));
    try std.testing.expectEqual(Status.not_found, orca_library_import_playlist(runtime, library, missing, missing.len, null, 0, &imported, null, null));

    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    try std.testing.expectEqual(Status.invalid_state, orca_player_play_playlist(runtime, player, id, 0));
    try std.testing.expectEqual(Status.ok, orca_player_set_library(runtime, player, library));
    try std.testing.expectEqual(Status.not_found, orca_player_play_playlist(runtime, player, unknown, 0));
    try std.testing.expectEqual(Status.invalid_state, orca_player_play_playlist(runtime, player, id, 0));
    try std.testing.expectEqualStrings(
        "orca_player_play_playlist: PlaylistEmpty",
        std.mem.span(orca_runtime_last_error(runtime)),
    );

    try std.testing.expectEqual(Status.ok, orca_library_delete_playlist(runtime, library, id));
    visited = 0;
    try std.testing.expectEqual(Status.ok, orca_library_query_playlists(runtime, library, 8, 0, &visited, countPlaylist));
    try std.testing.expectEqual(@as(usize, 0), visited);
    try std.testing.expectEqual(Status.ok, orca_player_destroy(runtime, player));
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

test "queue stats are all zero before a Player has played, and a destroyed Player has none" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_queue_stats(runtime, player, null));
    var stats: QueueStats = .{
        .entries_started = 7,
        .gapless_transitions = 7,
        .format_switch_transitions = 7,
        .open_failures = 7,
        .decode_errors = 7,
    };
    try std.testing.expectEqual(Status.ok, orca_player_queue_stats(runtime, player, &stats));
    try std.testing.expectEqual(QueueStats{
        .entries_started = 0,
        .gapless_transitions = 0,
        .format_switch_transitions = 0,
        .open_failures = 0,
        .decode_errors = 0,
    }, stats);
    try std.testing.expectEqual(Status.ok, orca_player_destroy(runtime, player));
    try std.testing.expectEqual(Status.stale_handle, orca_player_queue_stats(runtime, player, &stats));
}

test "an unknown equalizer preset or a null output is refused, and a preset leaves headroom for its largest boost" {
    var equalizer: EqualizerView = std.mem.zeroes(EqualizerView);
    try std.testing.expectEqual(Status.invalid_argument, orca_equalizer_preset_get(5, &equalizer));
    try std.testing.expectEqual(Status.invalid_argument, orca_equalizer_preset_get(255, &equalizer));
    try std.testing.expectEqual(Status.invalid_argument, orca_equalizer_preset_get(0, null));
    try std.testing.expectEqual(@as(f32, 0), equalizer.preamp_db);
    try std.testing.expectEqual(Status.ok, orca_equalizer_preset_get(1, &equalizer));
    try std.testing.expectEqual(@as(f32, 6), equalizer.gains_db[0]);
    try std.testing.expectEqual(@as(f32, -6), equalizer.preamp_db);
}

test "a NaN or out-of-range equalizer or crossfeed is refused and leaves the previous setting in place" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));

    var bass: EqualizerView = undefined;
    try std.testing.expectEqual(Status.ok, orca_equalizer_preset_get(1, &bass));
    try std.testing.expectEqual(Status.ok, orca_player_set_equalizer(runtime, player, &bass));

    var invalid = bass;
    invalid.gains_db[3] = std.math.nan(f32);
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_equalizer(runtime, player, &invalid));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(orca_runtime_last_error(runtime)), "orca_player_set_equalizer") != null);
    invalid = bass;
    invalid.gains_db[0] = 12.5;
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_equalizer(runtime, player, &invalid));
    invalid = bass;
    invalid.preamp_db = std.math.nan(f32);
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_equalizer(runtime, player, &invalid));
    invalid.preamp_db = -24.5;
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_equalizer(runtime, player, &invalid));

    var read_back: EqualizerView = undefined;
    var enabled: u8 = 9;
    try std.testing.expectEqual(Status.invalid_argument, orca_player_equalizer(runtime, player, null, &enabled));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_equalizer(runtime, player, &read_back, null));
    try std.testing.expectEqual(Status.ok, orca_player_equalizer(runtime, player, &read_back, &enabled));
    try std.testing.expectEqual(@as(u8, 1), enabled);
    try std.testing.expectEqual(bass, read_back);

    try std.testing.expectEqual(Status.ok, orca_player_set_crossfeed(runtime, player, 1, 0.25));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_crossfeed(runtime, player, 1, std.math.nan(f32)));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_crossfeed(runtime, player, 1, -0.1));
    try std.testing.expectEqual(Status.ok, orca_player_set_crossfeed(runtime, player, 0, std.math.nan(f32)));
    var amount: f32 = 9;
    try std.testing.expectEqual(Status.invalid_argument, orca_player_crossfeed(runtime, player, null, &amount));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_crossfeed(runtime, player, &enabled, null));
    try std.testing.expectEqual(Status.ok, orca_player_crossfeed(runtime, player, &enabled, &amount));
    try std.testing.expectEqual(@as(u8, 0), enabled);
    try std.testing.expectEqual(@as(f32, 0), amount);

    try std.testing.expectEqual(Status.ok, orca_player_set_equalizer(runtime, player, null));
    try std.testing.expectEqual(Status.ok, orca_player_equalizer(runtime, player, &read_back, &enabled));
    try std.testing.expectEqual(@as(u8, 0), enabled);
    try std.testing.expectEqual(std.mem.zeroes(EqualizerView), read_back);
}

fn captureSignalPath(context: ?*anyopaque, view: *const SignalPathView) callconv(.c) void {
    const destination: *SignalPathView = @ptrCast(@alignCast(context.?));
    destination.* = view.*;
}

test "a Player with no output reports a signal path with no source, no output and only the processing it applies" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_signal_path(runtime, player, null, null));

    var path: SignalPathView = std.mem.zeroes(SignalPathView);
    try std.testing.expectEqual(Status.ok, orca_player_signal_path(runtime, player, &path, captureSignalPath));
    try std.testing.expectEqual(@as(u8, 0), path.has_source);
    try std.testing.expectEqual(@as(u8, 0), path.has_output);
    try std.testing.expectEqual(@as(u8, 0), path.has_equalizer);
    try std.testing.expectEqual(@as(u32, 0), path.reason_count);
    try std.testing.expectEqual(@as(u8, 1), path.bit_perfect_eligible);
    try std.testing.expectEqual(@as(usize, 0), path.codec.length);

    try std.testing.expectEqual(Status.ok, orca_player_set_crossfeed(runtime, player, 1, 0.5));
    try std.testing.expectEqual(Status.ok, orca_player_signal_path(runtime, player, &path, captureSignalPath));
    try std.testing.expectEqual(@as(u8, 1), path.has_crossfeed);
    try std.testing.expectEqual(@as(f32, 0.5), path.crossfeed);
    try std.testing.expectEqual(@as(u32, 1), path.reason_count);
    try std.testing.expectEqual(exportSignalReason(.sample_processing), path.reasons[0]);
    try std.testing.expectEqual(@as(u8, 0), path.bit_perfect_eligible);

    try std.testing.expectEqual(Status.ok, orca_player_destroy(runtime, player));
    try std.testing.expectEqual(Status.stale_handle, orca_player_signal_path(runtime, player, &path, captureSignalPath));
}

fn countImage(context: ?*anyopaque, image: *const ImageView) callconv(.c) void {
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
    std.debug.assert(image.length != 0);
}

fn captureArtworkResult(context: ?*anyopaque, result: *const ArtworkResultView) callconv(.c) void {
    const captured: *ArtworkResultView = @ptrCast(@alignCast(context.?));
    captured.* = result.*;
}

fn awaitArtworkResult(runtime: *Runtime, library: Handle, captured: *ArtworkResultView) !void {
    for (0..5_000) |_| {
        switch (orca_library_take_artwork(runtime, library, captured, captureArtworkResult)) {
            .ok => return,
            .not_found => try std.testing.io.sleep(.fromMilliseconds(1), .awake),
            else => |status| return std.testing.expectEqual(Status.ok, status),
        }
    }
    return error.ArtworkRequestNeverFinished;
}

test "artwork calls refuse null outputs and unknown subjects, find no cover for an unknown Track, and refuse a closed Library" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-artwork-arguments?mode=memory&cache=shared",
        &library,
    ));
    var images: usize = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_artwork(runtime, library, 1, &images, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_artwork(runtime, library, 1, &images, null));
    try std.testing.expectEqual(Status.not_found, orca_library_track_artwork(runtime, library, 1, &images, countImage));
    try std.testing.expectEqual(Status.not_found, orca_library_release_artwork(runtime, library, 1, &images, countImage));
    try std.testing.expectEqual(@as(usize, 0), images);

    var request: u64 = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_request_artwork(runtime, library, 2, 1, &request));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_request_artwork(runtime, library, 0, 1, null));
    var captured: ArtworkResultView = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_take_artwork(runtime, library, &captured, null));
    try std.testing.expectEqual(Status.not_found, orca_library_take_artwork(runtime, library, &captured, captureArtworkResult));
    try std.testing.expectEqual(Status.ok, orca_library_cancel_artwork(runtime, library, 12345));

    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
    try std.testing.expectEqual(Status.stale_handle, orca_library_cancel_artwork(runtime, library, 1));
    try std.testing.expectEqual(Status.stale_handle, orca_library_take_artwork(runtime, library, &captured, captureArtworkResult));
    try std.testing.expectEqual(Status.stale_handle, orca_library_request_artwork(runtime, library, 0, 1, &request));
    try std.testing.expectEqual(Status.stale_handle, orca_library_track_artwork(runtime, library, 1, &images, countImage));
}

test "artwork requests past 64 outstanding are busy until a result is taken, and a coverless subject arrives without an image" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-artwork-busy?mode=memory&cache=shared",
        &library,
    ));
    var first: u64 = 0;
    try std.testing.expectEqual(Status.ok, orca_library_request_artwork(runtime, library, 1, 7, &first));
    var request: u64 = 0;
    for (1..core.artwork.capacity) |_| {
        try std.testing.expectEqual(Status.ok, orca_library_request_artwork(runtime, library, 0, 3, &request));
    }
    try std.testing.expectEqual(Status.busy, orca_library_request_artwork(runtime, library, 0, 3, &request));

    var captured: ArtworkResultView = undefined;
    try awaitArtworkResult(runtime, library, &captured);
    try std.testing.expectEqual(first, captured.request);
    try std.testing.expectEqual(@as(u8, 1), captured.subject);
    try std.testing.expectEqual(@as(i64, 7), captured.subject_id);
    try std.testing.expectEqual(@as(u8, 0), captured.has_image);
    try std.testing.expectEqual(@as(usize, 0), captured.image.length);
    try std.testing.expectEqual(Status.ok, orca_library_request_artwork(runtime, library, 0, 3, &request));
    try std.testing.expectEqual(Status.busy, orca_library_request_artwork(runtime, library, 0, 3, &request));
}

test "an undone, unreconciled or pruned tag write and a write still running each report their own status" {
    try std.testing.expectEqual(Status.already_done, mapError(error.MutationGroupAlreadyUndone));
    try std.testing.expectEqual(Status.needs_reconciliation, mapError(error.MutationNeedsReconciliation));
    try std.testing.expectEqual(Status.gone, mapError(error.TagWriteBackupPruned));
    try std.testing.expectEqual(Status.busy, mapError(error.TagWriteInProgress));
    try std.testing.expectEqual(Status.busy, mapError(error.TooManyPendingTagWrites));
    try std.testing.expectEqual(Status.not_found, mapError(error.MutationGroupNotFound));
    try std.testing.expectEqual(Status.invalid_state, mapError(error.MutationGroupNotCommitted));
    try std.testing.expectEqual(Status.invalid_state, mapError(error.TagTargetUnavailable));
    try std.testing.expectEqual(Status.invalid_argument, mapError(error.MutationApprovalMismatch));
}

test "tag edits and writes refuse bad arguments, unknown Tracks and plans, and a Library with no database file" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-tag-arguments?mode=memory&cache=shared",
        &library,
    ));
    const ids = [_]i64{1};
    const title = "Edited";
    const edit: TrackEditView = .{
        .field = exportMetadataField(.title),
        .has_value = 1,
        .value = .{ .pointer = title.ptr, .length = title.len },
    };
    var unknown_field = edit;
    unknown_field.field = 13;
    var null_value = edit;
    null_value.value = .{ .pointer = null, .length = 3 };
    const zero = "0";
    var bad_track_number = edit;
    bad_track_number.field = exportMetadataField(.track_number);
    bad_track_number.value = .{ .pointer = zero.ptr, .length = zero.len };
    const too_many_edits = [_]TrackEditView{edit} ** (max_track_edits + 1);
    const too_many_ids = [_]i64{1} ** (max_page + 1);
    var calls: usize = 0;

    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, null, 1, &.{edit}, 1, &calls, countIds));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, &too_many_ids, too_many_ids.len, &.{edit}, 1, &calls, countIds));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, &ids, 1, &.{edit}, 0, &calls, countIds));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, &ids, 1, &too_many_edits, too_many_edits.len, &calls, countIds));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, &ids, 1, null, 1, &calls, countIds));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, &ids, 1, &.{unknown_field}, 1, &calls, countIds));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, &ids, 1, &.{null_value}, 1, &calls, countIds));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_edit_tracks(runtime, library, &ids, 1, &.{bad_track_number}, 1, &calls, countIds));
    try std.testing.expectEqual(Status.not_found, orca_library_edit_tracks(runtime, library, &ids, 1, &.{edit}, 1, &calls, countIds));
    try std.testing.expectEqual(@as(usize, 0), calls);

    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_track_edits(runtime, library, 1, &calls, null));
    try std.testing.expectEqual(Status.not_found, orca_library_query_track_edits(runtime, library, 1, &calls, countFieldValue));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_plan_tag_write(runtime, library, &ids, 1, &calls, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_plan_tag_write(runtime, library, &ids, 0, &calls, countPlan));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_plan_tag_write(runtime, library, null, 1, &calls, countPlan));
    try std.testing.expectEqual(Status.not_found, orca_library_plan_tag_write(runtime, library, &ids, 1, &calls, countPlan));
    try std.testing.expectEqual(@as(usize, 0), calls);

    const digest: TagWriteDigest = .{ .bytes = @splat(0) };
    var started: Handle = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_tag_write(runtime, library, 1, null, &started));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_tag_write(runtime, library, 1, &digest, null));
    try std.testing.expectEqual(Status.not_found, orca_library_start_tag_write(runtime, library, 1, &digest, &started));
    try std.testing.expectEqual(Status.not_found, orca_library_discard_tag_write(runtime, library, 1));

    var backups: u64 = 7;
    var bytes: u64 = 7;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_prune_tag_write_backups(runtime, library, 0, null, &bytes));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_prune_tag_write_backups(runtime, library, 0, &backups, null));
    try std.testing.expectEqual(Status.invalid_state, orca_library_prune_tag_write_backups(runtime, library, 0, &backups, &bytes));
    try std.testing.expectEqual(@as(u64, 7), backups);
    try std.testing.expectEqual(Status.invalid_state, orca_library_undo_tag_write(runtime, library, 1));

    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
    try std.testing.expectEqual(Status.stale_handle, orca_library_edit_tracks(runtime, library, &ids, 1, &.{edit}, 1, &calls, countIds));
    try std.testing.expectEqual(Status.stale_handle, orca_library_query_track_edits(runtime, library, 1, &calls, countFieldValue));
    try std.testing.expectEqual(Status.stale_handle, orca_library_plan_tag_write(runtime, library, &ids, 1, &calls, countPlan));
    try std.testing.expectEqual(Status.stale_handle, orca_library_undo_tag_write(runtime, library, 1));
    try std.testing.expectEqual(Status.stale_handle, orca_library_prune_tag_write_backups(runtime, library, 0, &backups, &bytes));
}

test "an edit is held locked as the user's, and a Library with no database file keeps the plan it shows but refuses to write it" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const scanned = try core.runtime_tests.scannedTempLibrary(
        &box.runtime,
        &temporary,
        "file:orca-c-api-tag-plan?mode=memory&cache=shared",
    );
    const library = exportLibraryHandle(scanned);
    const track_ids = try core.runtime_tests.allTrackIds(&box.runtime, scanned);
    defer std.testing.allocator.free(track_ids);
    try std.testing.expectEqual(@as(usize, 3), track_ids.len);

    const title = "C ABI Title";
    const edit: TrackEditView = .{
        .field = exportMetadataField(.title),
        .has_value = 1,
        .value = .{ .pointer = title.ptr, .length = title.len },
    };
    var edited: CapturedIds = .{};
    try std.testing.expectEqual(Status.ok, orca_library_edit_tracks(runtime, library, track_ids.ptr, track_ids.len, &.{edit}, 1, &edited, captureIds));
    try std.testing.expectEqual(@as(usize, 3), edited.count);

    var value: CapturedFieldValue = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_track_edits(runtime, library, edited.ids[0], &value, captureFieldValue));
    try std.testing.expectEqual(@as(usize, 1), value.count);
    try std.testing.expectEqual(exportMetadataField(.title), value.field);
    try std.testing.expectEqual(exportProvenance(.user), value.provenance);
    try std.testing.expectEqual(@as(u8, 1), value.locked);
    try std.testing.expectEqualStrings(title, value.text[0..value.text_length]);

    var plan: CapturedPlan = .{ .title = title };
    try std.testing.expectEqual(Status.ok, orca_library_plan_tag_write(runtime, library, &edited.ids, edited.count, &plan, capturePlan));
    try std.testing.expectEqual(@as(usize, 1), plan.calls);
    try std.testing.expect(plan.plan_id != 0);
    try std.testing.expectEqual(@as(usize, 2), plan.file_count);
    try std.testing.expectEqual(@as(usize, 2), plan.title_changes);
    try std.testing.expectEqual(@as(usize, 1), plan.skip_count);
    try std.testing.expectEqual(exportTagWriteSkipReason(.format_not_writable), plan.skip_reason);
    try std.testing.expectEqual(@as(usize, 0), plan.conflict_count);

    var started: Handle = undefined;
    try std.testing.expectEqual(Status.invalid_state, orca_library_start_tag_write(runtime, library, plan.plan_id, &plan.digest, &started));
    try std.testing.expectEqual(Status.ok, orca_library_discard_tag_write(runtime, library, plan.plan_id));
    try std.testing.expectEqual(Status.not_found, orca_library_discard_tag_write(runtime, library, plan.plan_id));

    const clear: TrackEditView = .{ .field = exportMetadataField(.title), .has_value = 0, .value = .{ .pointer = null, .length = 0 } };
    try std.testing.expectEqual(Status.ok, orca_library_edit_tracks(runtime, library, &edited.ids, edited.count, &.{clear}, 1, null, null));
    value = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_track_edits(runtime, library, edited.ids[0], &value, captureFieldValue));
    try std.testing.expectEqual(@as(usize, 0), value.count);
    plan = .{ .title = title };
    try std.testing.expectEqual(Status.ok, orca_library_plan_tag_write(runtime, library, &edited.ids, edited.count, &plan, capturePlan));
    try std.testing.expectEqual(@as(u64, 0), plan.plan_id);
    try std.testing.expectEqual(@as(usize, 0), plan.file_count);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

const CapturedIds = struct {
    ids: [8]i64 = @splat(0),
    count: usize = 0,
};

fn captureIds(context: ?*anyopaque, ids: [*]const i64, count: usize) callconv(.c) void {
    const captured: *CapturedIds = @ptrCast(@alignCast(context.?));
    const kept = @min(count, captured.ids.len);
    @memcpy(captured.ids[0..kept], ids[0..kept]);
    captured.count = count;
}

fn countIds(context: ?*anyopaque, ids: [*]const i64, count: usize) callconv(.c) void {
    _ = ids;
    _ = count;
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
}

const CapturedFieldValue = struct {
    count: usize = 0,
    field: u8 = 0,
    provenance: u8 = 0,
    locked: u8 = 0,
    text: [64]u8 = @splat(0),
    text_length: usize = 0,
};

fn captureFieldValue(context: ?*anyopaque, value: *const FieldValueView) callconv(.c) void {
    const captured: *CapturedFieldValue = @ptrCast(@alignCast(context.?));
    captured.count += 1;
    captured.field = value.field;
    captured.provenance = value.provenance;
    captured.locked = value.locked;
    captured.text_length = @min(value.text.length, captured.text.len);
    @memcpy(captured.text[0..captured.text_length], value.text.pointer[0..captured.text_length]);
}

fn countFieldValue(context: ?*anyopaque, value: *const FieldValueView) callconv(.c) void {
    _ = value;
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
}

const CapturedPlan = struct {
    title: []const u8,
    calls: usize = 0,
    plan_id: u64 = 0,
    digest: TagWriteDigest = .{ .bytes = @splat(0) },
    file_count: usize = 0,
    title_changes: usize = 0,
    skip_count: usize = 0,
    skip_reason: u8 = 255,
    conflict_count: usize = 0,
};

fn capturePlan(context: ?*anyopaque, plan: *const TagWritePlanView) callconv(.c) void {
    const captured: *CapturedPlan = @ptrCast(@alignCast(context.?));
    captured.calls += 1;
    captured.plan_id = plan.plan_id;
    captured.digest = plan.digest;
    captured.file_count = plan.file_count;
    captured.skip_count = plan.skip_count;
    captured.conflict_count = plan.conflict_count;
    for (plan.files[0..plan.file_count]) |file| {
        for (file.changes[0..file.change_count]) |change| {
            if (change.field == exportMetadataField(.title) and
                change.provenance == exportProvenance(.user) and
                change.has_before == 1 and
                std.mem.eql(u8, change.after.pointer[0..change.after.length], captured.title))
                captured.title_changes += 1;
        }
    }
    if (plan.skip_count != 0) captured.skip_reason = plan.skipped[0].reason;
}

fn countPlan(context: ?*anyopaque, plan: *const TagWritePlanView) callconv(.c) void {
    _ = plan;
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
}

const FakeKeyring = struct {
    result: c_int = 0,
    secret: []const u8 = "host-secret",
    rotated: std.atomic.Value(bool) = .init(false),
    reported_length: ?usize = null,
    capacity: usize = 0,
    calls: std.atomic.Value(u32) = .init(0),
    late_calls: std.atomic.Value(u32) = .init(0),
    destroyed: std.atomic.Value(bool) = .init(false),
    thread: std.atomic.Value(std.Thread.Id) = .init(0),
    service: [32]u8 = @splat(0),
    account: [32]u8 = @splat(0),

    fn lookup(
        context: ?*anyopaque,
        service: [*:0]const u8,
        account: [*:0]const u8,
        buffer: [*]u8,
        capacity: usize,
        length: *usize,
    ) callconv(.c) c_int {
        const self: *FakeKeyring = @ptrCast(@alignCast(context.?));
        if (self.destroyed.load(.acquire)) _ = self.late_calls.fetchAdd(1, .acq_rel);
        self.capacity = capacity;
        const service_text = std.mem.span(service);
        const account_text = std.mem.span(account);
        @memcpy(self.service[0..service_text.len], service_text);
        @memcpy(self.account[0..account_text.len], account_text);
        self.thread.store(std.Thread.getCurrentId(), .release);
        const secret = if (self.rotated.load(.acquire)) "changed-secret" else self.secret;
        const written = @min(secret.len, capacity);
        @memcpy(buffer[0..written], secret[0..written]);
        length.* = self.reported_length orelse written;
        _ = self.calls.fetchAdd(1, .acq_rel);
        return self.result;
    }

    fn serviceName(self: *const FakeKeyring) []const u8 {
        return std.mem.sliceTo(&self.service, 0);
    }

    fn accountName(self: *const FakeKeyring) []const u8 {
        return std.mem.sliceTo(&self.account, 0);
    }
};

fn expectNoSecret(backing: []const u8, secret: []const u8) !void {
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, backing, secret));
}

test "a credential the host finds is returned whole, and no copy of it is left behind once freed" {
    var backing: [4096]u8 = @splat(0);
    var fixed: std.heap.FixedBufferAllocator = .init(&backing);
    var keyring: FakeKeyring = .{};
    var slot: CredentialSlot = .{ .callback = FakeKeyring.lookup, .context = &keyring };

    const secret = (try hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token")).?;
    try std.testing.expectEqualStrings("host-secret", secret);
    try std.testing.expectEqual(credential_max_bytes, keyring.capacity);
    try std.testing.expectEqualStrings("org.listenbrainz", keyring.serviceName());
    try std.testing.expectEqualStrings("user-token", keyring.accountName());
    providers.credentials.wipeAndFree(fixed.allocator(), secret);
    try expectNoSecret(&backing, "host-secret");

    var full: [credential_max_bytes]u8 = @splat('k');
    keyring.secret = &full;
    const largest = (try hostCredential(&slot, fixed.allocator(), "org.acoustid", "user-key")).?;
    try std.testing.expectEqual(credential_max_bytes, largest.len);
    providers.credentials.wipeAndFree(fixed.allocator(), largest);
    try expectNoSecret(&backing, &full);
}

test "a missing credential is absent, while an unavailable or oversized one is an error, and none leaves the secret behind" {
    var backing: [4096]u8 = @splat(0);
    var fixed: std.heap.FixedBufferAllocator = .init(&backing);
    var keyring: FakeKeyring = .{};
    var slot: CredentialSlot = .{ .callback = FakeKeyring.lookup, .context = &keyring };

    keyring.result = @intFromEnum(CredentialResult.not_found);
    try std.testing.expectEqual(@as(?[]u8, null), try hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token"));
    try expectNoSecret(&backing, "host-secret");

    keyring.result = @intFromEnum(CredentialResult.unavailable);
    try std.testing.expectError(error.CredentialUnavailable, hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token"));
    try expectNoSecret(&backing, "host-secret");

    keyring.result = @intFromEnum(CredentialResult.too_large);
    try std.testing.expectError(error.CredentialTooLarge, hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token"));
    try expectNoSecret(&backing, "host-secret");

    keyring.result = @intFromEnum(CredentialResult.found);
    keyring.reported_length = credential_max_bytes + 1;
    try std.testing.expectError(error.CredentialTooLarge, hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token"));
    try expectNoSecret(&backing, "host-secret");

    keyring.reported_length = null;
    keyring.result = 7;
    try std.testing.expectError(error.CredentialUnavailable, hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token"));
    try expectNoSecret(&backing, "host-secret");
    try std.testing.expectEqual(@as(u32, 5), keyring.calls.load(.acquire));

    slot = .{};
    try std.testing.expectEqual(@as(?[]u8, null), try hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token"));
    try std.testing.expectEqual(@as(u32, 5), keyring.calls.load(.acquire));
}

test "a provider server is copied out of the caller's buffer, refused unless https or loopback http, and NULL restores the default" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;

    var caller: [64:0]u8 = @splat(0);
    const local = "http://127.0.0.1:8080/mb";
    @memcpy(caller[0..local.len], local);
    try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 1, &caller));
    const stored = box.runtime.musicbrainz_server.view();
    try std.testing.expect(@intFromPtr(stored.ptr) < @intFromPtr(&caller) or
        @intFromPtr(stored.ptr) >= @intFromPtr(&caller) + caller.len);
    @memset(caller[0..local.len], 'x');
    try std.testing.expectEqualStrings(local, box.runtime.musicbrainz_server.view());

    for ([_][*:0]const u8{
        "http://127.0.0.1@example.org",
        "http://example.org",
        "https://user:secret@example.org",
        "ftp://example.org",
    }) |refused| {
        try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_provider_server(runtime, 1, refused));
        try std.testing.expectEqualStrings(
            "orca_runtime_set_provider_server: InvalidServerUrl",
            std.mem.span(orca_runtime_last_error(runtime)),
        );
        try std.testing.expectEqualStrings(local, box.runtime.musicbrainz_server.view());
    }
    var long: [providers.url.max_server_bytes + 1:0]u8 = @splat('a');
    @memcpy(long[0.."https://".len], "https://");
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_provider_server(runtime, 1, &long));
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_provider_server(runtime, 4, "https://example.org"));
    try std.testing.expectEqualStrings(
        "orca_runtime_set_provider_server: unknown provider service",
        std.mem.span(orca_runtime_last_error(runtime)),
    );

    try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 0, "https://lb.example.org"));
    try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 2, "http://[::1]:9/acoustid"));
    try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 3, "http://localhost:9"));
    try std.testing.expectEqualStrings("https://lb.example.org", box.runtime.listenbrainz_server.view());
    try std.testing.expectEqualStrings("http://[::1]:9/acoustid", box.runtime.acoustid_server.view());
    try std.testing.expectEqualStrings("http://localhost:9", box.runtime.coverartarchive_server.view());

    for (0..4) |service| try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, @intCast(service), null));
    try std.testing.expectEqualStrings(providers.listenbrainz.default_server, box.runtime.listenbrainz_server.view());
    try std.testing.expectEqualStrings(providers.musicbrainz.default_server, box.runtime.musicbrainz_server.view());
    try std.testing.expectEqualStrings(providers.acoustid.default_server, box.runtime.acoustid_server.view());
    try std.testing.expectEqualStrings(providers.coverartarchive.default_server, box.runtime.coverartarchive_server.view());
}

test "the client identity and AcoustID key are copied, and invalid ones are refused" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;

    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_client_identity(runtime, null, "1.0", "https://host.invalid"));
    try std.testing.expectEqualStrings("orca_runtime_set_client_identity: name is null", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_client_identity(runtime, "Host", null, "https://host.invalid"));
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_client_identity(runtime, "Host", "1.0", null));
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_client_identity(runtime, "Player (beta)", "1.0", "https://host.invalid"));
    try std.testing.expectEqualStrings(
        "orca_runtime_set_client_identity: InvalidNetworkConfiguration",
        std.mem.span(orca_runtime_last_error(runtime)),
    );
    try std.testing.expectEqual(@as(?core.runtime.ClientIdentity, null), if (box.runtime.client_identity) |owned| owned.view() else null);

    var name = "Host".*;
    try std.testing.expectEqual(Status.ok, orca_runtime_set_client_identity(runtime, &name, "1.0", "https://host.invalid"));
    name = "Xxxx".*;
    try std.testing.expectEqualStrings("Host", box.runtime.client_identity.?.view().name);

    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_acoustid_client_key(runtime, "with space"));
    try std.testing.expectEqualStrings(
        "orca_runtime_set_acoustid_client_key: InvalidAcoustIdKey",
        std.mem.span(orca_runtime_last_error(runtime)),
    );
    var key = "AbC123".*;
    try std.testing.expectEqual(Status.ok, orca_runtime_set_acoustid_client_key(runtime, &key));
    key = "zzzzzz".*;
    try std.testing.expectEqualStrings("AbC123", box.runtime.acoustid_client_key.?.view());
    try std.testing.expectEqual(Status.ok, orca_runtime_set_acoustid_client_key(runtime, null));
    try std.testing.expect(box.runtime.acoustid_client_key == null);
}

test "the credential callback answers a listen worker on its own thread, cannot change while work exists, and is never called after destroy" {
    var transport: network.testing.ScriptedTransport = .{
        .otherwise = .{ .respond = .{ .body = "{\"valid\":true,\"user_name\":\"listener\"}" } },
    };
    defer transport.deinit();
    var clock: network.testing.TestClock = .{ .wall_offset_ms = 1_800_000_000_000 };
    var keyring: FakeKeyring = .{};

    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    var destroyed = false;
    defer if (!destroyed) orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;

    try std.testing.expectEqual(Status.ok, orca_runtime_set_credential_callback(runtime, FakeKeyring.lookup, &keyring));
    try std.testing.expectEqual(Status.ok, orca_runtime_set_client_identity(runtime, "Host", "1.0", "https://host.invalid"));
    try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 0, "http://127.0.0.1:8080"));
    box.runtime.listen_hooks = .{
        .transport = transport.transport(),
        .clock = clock.clock(),
        .wall_clock = clock.wallClock(),
        .poll_ms = 1,
    };
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-credentials?mode=memory&cache=shared", &library));
    try box.runtime.librarySetScrobbling(importLibrary(library), true, false, false);
    try std.testing.expectEqual(Status.ok, orca_library_scrobbler_credentials_changed(runtime, library));

    var deadline: core.runtime_tests.TestDeadline = .init(5_000);
    while (transport.requestCount() < 1) {
        if (!deadline.tick()) return error.TokenNeverValidated;
    }
    try std.testing.expect(std.mem.startsWith(u8, transport.lastUrl(), "http://127.0.0.1:8080/1/validate-token"));
    try std.testing.expectEqualStrings("Token host-secret", transport.lastAuthorization());
    try std.testing.expectEqualStrings("org.listenbrainz", keyring.serviceName());
    try std.testing.expectEqualStrings("user-token", keyring.accountName());
    try std.testing.expect(keyring.thread.load(.acquire) != std.Thread.getCurrentId());

    try std.testing.expectEqual(Status.invalid_state, orca_runtime_set_credential_callback(runtime, FakeKeyring.lookup, &keyring));
    try std.testing.expectEqualStrings(
        "orca_runtime_set_credential_callback: WorkersRunning",
        std.mem.span(orca_runtime_last_error(runtime)),
    );
    try std.testing.expectEqual(Status.invalid_state, orca_runtime_set_credential_callback(runtime, null, null));

    const lookups = keyring.calls.load(.acquire);
    keyring.rotated.store(true, .release);
    try std.testing.expectEqual(Status.ok, orca_library_scrobbler_credentials_changed(runtime, library));
    deadline = .init(5_000);
    while (transport.requestCount() < 2) {
        if (!deadline.tick()) return error.ChangedTokenNeverValidated;
    }
    try std.testing.expect(keyring.calls.load(.acquire) > lookups);
    try std.testing.expectEqualStrings("Token changed-secret", transport.lastAuthorization());
    try std.testing.expectEqual(Status.stale_handle, orca_library_scrobbler_credentials_changed(runtime, .{ .index = library.index, .generation = library.generation + 1 }));

    orca_runtime_destroy(runtime);
    destroyed = true;
    keyring.destroyed.store(true, .release);
    var settle: core.runtime_tests.TestDeadline = .init(20);
    while (settle.tick()) {}
    try std.testing.expectEqual(@as(u32, 0), keyring.late_calls.load(.acquire));
}

const provider_tests = core.runtime_provider_tests;

const MatchingRig = struct {
    musicbrainz: provider_tests.FakeMusicBrainz = .{},
    acoustid: provider_tests.FakeAcoustId = .{},
    cover: provider_tests.FakeCoverArt = .{},
    temporary: std.testing.TmpDir,
    runtime: *Runtime,
    library: Handle = undefined,
    library_database: *database.LibraryDatabase = undefined,

    fn init(self: *MatchingRig, uri: [*:0]const u8, acoustid_key: ?[*:0]const u8) !void {
        const runtime = orca_runtime_create() orelse return error.OutOfMemory;
        self.* = .{ .temporary = std.testing.tmpDir(.{}), .runtime = runtime };
        errdefer self.deinit();
        const box = runtimeBox(runtime).?;
        try std.testing.expectEqual(Status.ok, orca_runtime_set_client_identity(runtime, "Host", "1.0", "https://host.invalid"));
        try std.testing.expectEqual(Status.ok, orca_runtime_set_acoustid_client_key(runtime, acoustid_key));
        box.runtime.matching_hooks = self.musicbrainz.hooks();
        box.runtime.matching_hooks.acoustid_transport = self.acoustid.transport();
        self.cover.attach(&box.runtime.matching_hooks);
        try std.testing.expectEqual(Status.ok, orca_library_open(runtime, uri, &self.library));
        self.library_database = try core.runtime.libraryDatabase(&box.runtime, importLibrary(self.library));
    }

    fn deinit(self: *MatchingRig) void {
        orca_runtime_destroy(self.runtime);
        self.cover.deinit();
        self.temporary.cleanup();
    }

    fn finish(self: *MatchingRig, job_handle: Handle) !job.State {
        return core.runtime_tests.awaitJob(&runtimeBox(self.runtime).?.runtime, importJob(job_handle));
    }

    fn addTone(self: *MatchingRig, name: []const u8, frequency: f32, title: []const u8, recording_mbid: []const u8, release_id: i64) !i64 {
        try provider_tests.writeToneWave(self.temporary.dir, name, frequency);
        const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ self.temporary.sub_path, name });
        defer std.testing.allocator.free(path);
        const binding = try self.library_database.resolveOrCreateFile(std.testing.io, path, .{ .stable_key = "test:c-verify" });
        try self.library_database.observed_tags.upsert(.{ .file_id = binding.file_id, .values = .{
            .title = title,
            .artist = "Nick Drake",
            .album = "Bryter Layter",
            .musicbrainz_recording_id = recording_mbid,
        } });
        try self.library_database.tracks.upsertTracks(&.{.{
            .release_id = release_id,
            .title = title,
            .artist = "Nick Drake",
            .album = "Bryter Layter",
            .duration_ms = 15_000,
            .preferred_file_id = binding.file_id,
        }});
        return provider_tests.trackOfFile(self.library_database, binding.file_id);
    }

    fn addUntaggedTone(self: *MatchingRig, name: []const u8, frequency: f32, title: []const u8) !i64 {
        try provider_tests.writeToneWave(self.temporary.dir, name, frequency);
        const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ self.temporary.sub_path, name });
        defer std.testing.allocator.free(path);
        const binding = try self.library_database.resolveOrCreateFile(std.testing.io, path, .{ .stable_key = "test:c-submit" });
        try self.library_database.tracks.upsertTracks(&.{.{
            .title = title,
            .artist = "Nick Drake",
            .album = "Bryter Layter",
            .duration_ms = 15_000,
            .preferred_file_id = binding.file_id,
        }});
        return provider_tests.trackOfFile(self.library_database, binding.file_id);
    }

    fn lastError(self: *MatchingRig) []const u8 {
        return std.mem.span(orca_runtime_last_error(self.runtime));
    }
};

const CapturedText = struct {
    bytes: [64]u8 = undefined,
    length: usize = 0,

    fn set(self: *CapturedText, view: StringView) void {
        self.length = @min(view.length, self.bytes.len);
        @memcpy(self.bytes[0..self.length], view.pointer[0..self.length]);
    }

    fn text(self: *const CapturedText) []const u8 {
        return self.bytes[0..self.length];
    }
};

const CapturedProposal = struct {
    count: usize = 0,
    id: i64 = 0,
    provider: CapturedText = .{},
    recording_mbid: CapturedText = .{},
    release_title: CapturedText = .{},
    has_release_mbid: u8 = 0,
    has_corrects: u8 = 0,
    confidence: f32 = 0,
};

fn captureProposal(context: ?*anyopaque, proposal: *const MatchProposalView) callconv(.c) void {
    const captured: *CapturedProposal = @ptrCast(@alignCast(context.?));
    captured.count += 1;
    if (captured.count != 1) return;
    captured.id = proposal.id;
    captured.provider.set(proposal.provider);
    captured.recording_mbid.set(proposal.recording_mbid);
    captured.release_title.set(proposal.release_title);
    captured.has_release_mbid = proposal.has_release_mbid;
    captured.has_corrects = proposal.has_corrects;
    captured.confidence = proposal.confidence;
}

const CapturedReview = struct {
    count: usize = 0,
    track_ids: [2]i64 = @splat(0),
    proposal_counts: [2]u32 = @splat(0),
    titles: [2]CapturedText = @splat(.{}),
    best_recordings: [2]CapturedText = @splat(.{}),
};

fn captureReview(context: ?*anyopaque, item: *const MatchReviewView) callconv(.c) void {
    const captured: *CapturedReview = @ptrCast(@alignCast(context.?));
    defer captured.count += 1;
    if (captured.count >= captured.track_ids.len) return;
    captured.track_ids[captured.count] = item.track_id;
    captured.proposal_counts[captured.count] = item.proposal_count;
    captured.titles[captured.count].set(item.title);
    captured.best_recordings[captured.count].set(item.best.recording_mbid);
}

const CapturedRecording = struct {
    count: usize = 0,
    recording_mbid: CapturedText = .{},
    source: u8 = 0,
};

fn captureRecording(context: ?*anyopaque, details: *const TrackDetailsView) callconv(.c) void {
    const captured: *CapturedRecording = @ptrCast(@alignCast(context.?));
    captured.count += 1;
    captured.recording_mbid.set(details.musicbrainz_recording_id);
    captured.source = details.musicbrainz_recording_id_source;
}

const CapturedVerification = struct {
    count: usize = 0,
    outcome: u8 = 255,
    recording_mbid: CapturedText = .{},
    heard_count: usize = 0,
    strongest: CapturedText = .{},
    strongest_score: f32 = 0,
    stale: u8 = 255,
};

fn captureVerification(context: ?*anyopaque, verification: *const TrackVerificationView) callconv(.c) void {
    const captured: *CapturedVerification = @ptrCast(@alignCast(context.?));
    captured.count += 1;
    captured.outcome = verification.outcome;
    captured.recording_mbid.set(verification.recording_mbid);
    captured.heard_count = verification.heard_count;
    if (verification.heard_count != 0) {
        captured.strongest.set(verification.heard[0].mbid);
        captured.strongest_score = verification.heard[0].score;
    }
    captured.stale = verification.stale;
}

const CapturedGroup = struct {
    count: usize = 0,
    group_id: i64 = 0,
    release_id: i64 = 0,
    has_release_id: u8 = 0,
    album: CapturedText = .{},
    member_count: usize = 0,
    first_proposal_id: i64 = 0,
    members_with_corrects: usize = 0,
    members_with_track: usize = 0,
};

fn captureGroup(context: ?*anyopaque, group: *const CorrectionGroupView) callconv(.c) void {
    const captured: *CapturedGroup = @ptrCast(@alignCast(context.?));
    captured.count += 1;
    captured.group_id = group.group_id;
    captured.release_id = group.release_id;
    captured.has_release_id = group.has_release_id;
    captured.album.set(group.album);
    captured.member_count = group.member_count;
    captured.members_with_corrects = 0;
    captured.members_with_track = 0;
    for (group.members[0..group.member_count]) |member| {
        captured.members_with_corrects += member.has_corrects;
        captured.members_with_track += member.has_track_id;
    }
    if (group.member_count != 0) captured.first_proposal_id = group.members[0].proposal_id;
}

const CapturedImage = struct {
    count: usize = 0,
    bytes: [64]u8 = undefined,
    length: usize = 0,
};

fn captureImage(context: ?*anyopaque, image: *const ImageView) callconv(.c) void {
    const captured: *CapturedImage = @ptrCast(@alignCast(context.?));
    captured.count += 1;
    captured.length = @min(image.length, captured.bytes.len);
    @memcpy(captured.bytes[0..captured.length], image.bytes[0..captured.length]);
}

const CapturedSubmittable = struct {
    count: usize = 0,
    last_file_id: i64 = 0,
    track_id: i64 = 0,
    recording_mbid: CapturedText = .{},
    title: CapturedText = .{},
    artist: CapturedText = .{},
    codec: CapturedText = .{},
    path: CapturedText = .{},
    has_path: u8 = 0,
    has_duration_ms: u8 = 0,
    duration_ms: i64 = 0,
    has_track_number: u8 = 255,
    has_year: u8 = 255,
    has_recording_length_ms: u8 = 255,
    size_bytes: i64 = 0,
};

fn captureSubmittable(context: ?*anyopaque, item: *const AcoustIdSubmittableView) callconv(.c) void {
    const captured: *CapturedSubmittable = @ptrCast(@alignCast(context.?));
    captured.count += 1;
    captured.last_file_id = item.file_id;
    captured.track_id = item.track_id;
    captured.recording_mbid.set(item.recording_mbid);
    captured.title.set(item.title);
    captured.artist.set(item.artist);
    captured.codec.set(item.codec);
    captured.path.set(item.path);
    captured.has_path = item.has_path;
    captured.has_duration_ms = item.has_duration_ms;
    captured.duration_ms = item.duration_ms;
    captured.has_track_number = item.has_track_number;
    captured.has_year = item.has_year;
    captured.has_recording_length_ms = item.has_recording_length_ms;
    captured.size_bytes = item.size_bytes;
}

const nick_drake_answers = [_]std.meta.Elem(@FieldType(provider_tests.FakeMusicBrainz, "answers")){
    .{ .title = "Northern%20Sky", .body = provider_tests.northern_sky_answer },
    .{ .title = "Pink%20Moon", .body = provider_tests.pink_moon_answer },
};

test "a match started through the C ABI stores proposals that review lists, accept applies and dismiss discards" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-match-review?mode=memory&cache=shared", null);
    defer rig.deinit();
    rig.musicbrainz.answers = &nick_drake_answers;
    const northern_sky = try provider_tests.addMatchTrack(rig.library_database, "Northern Sky", "Nick Drake", null);
    const pink_moon = try provider_tests.addMatchTrack(rig.library_database, "Pink Moon", "Nick Drake", null);
    var count: u64 = 0;
    try std.testing.expectEqual(Status.ok, orca_library_unidentified_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 2), count);

    var matching: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, null, &matching));
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(matching));
    var snapshot: JobSnapshot = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_snapshot_get(rig.runtime, matching, &snapshot));
    try std.testing.expectEqual(exportJobKind(.metadata_lookup), snapshot.kind);
    var stats: MatchStatsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_match_stats(rig.runtime, matching, &stats));
    try std.testing.expectEqual(@as(u64, 2), stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 2), stats.matched);
    try std.testing.expectEqual(@as(u64, 2), stats.proposals_stored);
    try std.testing.expect(stats.requests >= 2);
    try std.testing.expectEqual(exportAcoustIdUse(.no_client_key), stats.acoustid);
    try std.testing.expectEqual(exportCoverArtOutcome(.not_requested), stats.cover_art);
    try std.testing.expectEqual(@as(u8, 0), stats.cancelled);
    try std.testing.expectEqual(Status.ok, orca_library_unidentified_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 0), count);

    try std.testing.expectEqual(Status.ok, orca_library_match_review_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 2), count);
    var review: CapturedReview = .{};
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_match_review(rig.runtime, rig.library, 0, 0, &review, captureReview));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_match_review(rig.runtime, rig.library, 513, 0, &review, captureReview));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_match_review(rig.runtime, rig.library, 10, 0, null, null));
    try std.testing.expectEqual(Status.ok, orca_library_query_match_review(rig.runtime, rig.library, 10, 0, &review, captureReview));
    try std.testing.expectEqual(@as(usize, 2), review.count);
    for (review.track_ids, review.titles, review.best_recordings, review.proposal_counts) |track_id, title, best, proposal_count| {
        try std.testing.expectEqual(@as(u32, 1), proposal_count);
        if (track_id == northern_sky) {
            try std.testing.expectEqualStrings("Northern Sky", title.text());
            try std.testing.expectEqualStrings(provider_tests.northern_sky_mbid, best.text());
        } else {
            try std.testing.expectEqual(pink_moon, track_id);
            try std.testing.expectEqualStrings(provider_tests.pink_moon_mbid, best.text());
        }
    }

    var proposal: CapturedProposal = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_match_proposals(rig.runtime, rig.library, northern_sky, &proposal, captureProposal));
    try std.testing.expectEqual(@as(usize, 1), proposal.count);
    try std.testing.expectEqualStrings("musicbrainz", proposal.provider.text());
    try std.testing.expectEqualStrings(provider_tests.northern_sky_mbid, proposal.recording_mbid.text());
    try std.testing.expectEqualStrings("Bryter Layter", proposal.release_title.text());
    try std.testing.expectEqual(@as(u8, 1), proposal.has_release_mbid);
    try std.testing.expectEqual(@as(u8, 0), proposal.has_corrects);

    var acceptance: MatchAcceptanceView = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_accept_match(rig.runtime, rig.library, proposal.id, null));
    try std.testing.expectEqual(Status.ok, orca_library_accept_match(rig.runtime, rig.library, proposal.id, &acceptance));
    try std.testing.expect(acceptance.values_written > 0);
    try std.testing.expectEqual(Status.invalid_state, orca_library_accept_match(rig.runtime, rig.library, proposal.id, &acceptance));
    try std.testing.expectEqualStrings("orca_library_accept_match: StaleIdentificationProposal", rig.lastError());
    try std.testing.expectEqual(Status.not_found, orca_library_accept_match(rig.runtime, rig.library, 1_000_000, &acceptance));
    try std.testing.expectEqualStrings("orca_library_accept_match: UnknownIdentificationProposal", rig.lastError());
    var recording: CapturedRecording = .{};
    const accepted_track = try provider_tests.trackOfFile(rig.library_database, acceptance.file_id);
    try std.testing.expectEqual(Status.ok, orca_library_track_details(rig.runtime, rig.library, accepted_track, &recording, captureRecording));
    try std.testing.expectEqualStrings(provider_tests.northern_sky_mbid, recording.recording_mbid.text());
    try std.testing.expectEqual(@intFromEnum(IdSource.match), recording.source);

    proposal = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_match_proposals(rig.runtime, rig.library, pink_moon, &proposal, captureProposal));
    try std.testing.expectEqual(@as(usize, 1), proposal.count);
    try std.testing.expectEqual(Status.ok, orca_library_dismiss_match(rig.runtime, rig.library, proposal.id));
    try std.testing.expectEqual(Status.invalid_state, orca_library_dismiss_match(rig.runtime, rig.library, proposal.id));
    try std.testing.expectEqual(Status.not_found, orca_library_dismiss_match(rig.runtime, rig.library, 1_000_000));
    try std.testing.expectEqual(Status.ok, orca_library_match_review_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    proposal = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_match_proposals(rig.runtime, rig.library, pink_moon, &proposal, captureProposal));
    try std.testing.expectEqual(@as(usize, 0), proposal.count);

    var verification: CapturedVerification = .{};
    try std.testing.expectEqual(Status.not_found, orca_library_track_verification(rig.runtime, rig.library, pink_moon, &verification, captureVerification));
    try std.testing.expectEqual(@as(usize, 0), verification.count);
}

test "a scoped match through the C ABI follows its options, and confident acceptance and apply-release take what it found" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-match-confident?mode=memory&cache=shared", null);
    defer rig.deinit();
    rig.musicbrainz.answers = &nick_drake_answers;
    const northern_sky = try provider_tests.addMatchTrack(rig.library_database, "Northern Sky", "Nick Drake", null);
    _ = try provider_tests.addMatchTrack(rig.library_database, "Pink Moon", "Nick Drake", null);

    const options: MatchOptions = .{
        .batch_size = 0,
        .limit = 0,
        .track_id = northern_sky,
        .release_id = 0,
        .accept_minimum_confidence = 0,
        .mode = 0,
        .has_limit = 0,
        .has_track_id = 1,
        .has_release_id = 0,
        .skip_fingerprints = 1,
        .has_accept_minimum_confidence = 0,
        .cover_art = 0,
    };
    var matching: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(matching));
    var stats: MatchStatsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_match_stats(rig.runtime, matching, &stats));
    try std.testing.expectEqual(@as(u64, 1), stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 1), stats.proposals_stored);
    try std.testing.expectEqual(exportAcoustIdUse(.off), stats.acoustid);

    var count: u64 = 0;
    for ([_]f32{ 0, -0.5, 1.5, std.math.nan(f32) }) |invalid| {
        try std.testing.expectEqual(Status.invalid_argument, orca_library_confident_match_count(rig.runtime, rig.library, invalid, &count));
        try std.testing.expectEqualStrings("orca_library_confident_match_count: InvalidMinimumConfidence", rig.lastError());
    }
    var acceptance: ConfidentAcceptanceView = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_accept_confident_matches(rig.runtime, rig.library, 2, &acceptance));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_accept_confident_matches(rig.runtime, rig.library, 0.5, null));
    try std.testing.expectEqual(Status.ok, orca_library_confident_match_count(rig.runtime, rig.library, 0.01, &count));
    try std.testing.expectEqual(@as(u64, 1), count);
    try std.testing.expectEqual(Status.ok, orca_library_accept_confident_matches(rig.runtime, rig.library, 0.01, &acceptance));
    try std.testing.expectEqual(@as(u64, 1), acceptance.accepted);
    try std.testing.expect(acceptance.values_written > 0);
    try std.testing.expectEqual(Status.ok, orca_library_confident_match_count(rig.runtime, rig.library, 0.01, &count));
    try std.testing.expectEqual(@as(u64, 0), count);

    const release = try provider_tests.addRelease(rig.library_database, "Bryter Layter", provider_tests.bryter_layter_mbid);
    var values_written: u32 = std.math.maxInt(u32);
    try std.testing.expectEqual(Status.ok, orca_library_apply_matched_release(rig.runtime, rig.library, release, &values_written));
    try std.testing.expectEqual(@as(u32, 0), values_written);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_apply_matched_release(rig.runtime, rig.library, release, null));
    try std.testing.expectEqual(Status.not_found, orca_library_apply_matched_release(rig.runtime, rig.library, 1_000_000, &values_written));
    try std.testing.expectEqualStrings("orca_library_apply_matched_release: UnknownRelease", rig.lastError());
}

test "a match through the C ABI refuses bad options and a second job, and a job that is not a match has empty match stats" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-match-refusals?mode=memory&cache=shared", null);
    defer rig.deinit();
    rig.musicbrainz.hang_from = 0;
    _ = try provider_tests.addMatchTrack(rig.library_database, "Northern Sky", "Nick Drake", null);
    const album = try provider_tests.addRelease(rig.library_database, "Bryter Layter", provider_tests.bryter_layter_mbid);
    var matching: Handle = undefined;
    const zero: MatchOptions = .{
        .batch_size = 0,
        .limit = 0,
        .track_id = 0,
        .release_id = 0,
        .accept_minimum_confidence = 0,
        .mode = 0,
        .has_limit = 0,
        .has_track_id = 0,
        .has_release_id = 0,
        .skip_fingerprints = 0,
        .has_accept_minimum_confidence = 0,
        .cover_art = 0,
    };

    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_match(rig.runtime, rig.library, null, null));
    var options = zero;
    options.mode = 3;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    options = zero;
    options.has_track_id = 1;
    options.has_release_id = 1;
    options.release_id = album;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    try std.testing.expectEqualStrings("orca_library_start_match: InvalidMatchRequest", rig.lastError());
    options = zero;
    options.mode = 1;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    options = zero;
    options.cover_art = 1;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    options = zero;
    options.has_release_id = 1;
    options.release_id = album;
    options.has_accept_minimum_confidence = 1;
    options.accept_minimum_confidence = 1.5;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    try std.testing.expectEqualStrings("orca_library_start_match: InvalidMinimumConfidence", rig.lastError());
    options = zero;
    options.mode = 2;
    try std.testing.expectEqual(Status.invalid_state, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    try std.testing.expectEqualStrings("orca_library_start_match: AcoustIdRequired", rig.lastError());
    options = zero;
    options.has_release_id = 1;
    options.release_id = 1_000_000;
    try std.testing.expectEqual(Status.not_found, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    try std.testing.expectEqualStrings("orca_library_start_match: UnknownRelease", rig.lastError());
    try std.testing.expectEqual(Status.not_found, orca_library_start_cover_art_fetch(rig.runtime, rig.library, 1_000_000, &matching));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_cover_art_fetch(rig.runtime, rig.library, album, null));

    var stats: MatchStatsView = undefined;
    try std.testing.expectEqual(Status.stale_handle, orca_job_match_stats(rig.runtime, .{ .index = 7, .generation = 3 }, &stats));
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, null, &matching));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_match_stats(rig.runtime, matching, null));
    var second: Handle = undefined;
    try std.testing.expectEqual(Status.busy, orca_library_start_match(rig.runtime, rig.library, null, &second));
    try std.testing.expectEqualStrings("orca_library_start_match: MatchingAlreadyRunning", rig.lastError());
    try std.testing.expectEqual(Status.busy, orca_library_start_cover_art_fetch(rig.runtime, rig.library, album, &second));
    try std.testing.expectEqual(Status.ok, orca_job_cancel(rig.runtime, matching));
    try std.testing.expectEqual(job.State.cancelled, try rig.finish(matching));
    try std.testing.expectEqual(Status.ok, orca_job_match_stats(rig.runtime, matching, &stats));
    try std.testing.expectEqual(@as(u8, 1), stats.cancelled);

    var scan: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_projection(rig.runtime, rig.library, &scan));
    _ = try rig.finish(scan);
    try std.testing.expectEqual(Status.ok, orca_job_match_stats(rig.runtime, scan, &stats));
    try std.testing.expectEqual(@as(u64, 0), stats.tracks_examined);
    try std.testing.expectEqual(exportAcoustIdUse(.off), stats.acoustid);

    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var anonymous: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-match-anonymous?mode=memory&cache=shared", &anonymous));
    try std.testing.expectEqual(Status.invalid_state, orca_library_start_match(runtime, anonymous, null, &matching));
    try std.testing.expectEqualStrings("orca_library_start_match: ClientIdentityRequired", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(Status.invalid_state, orca_library_start_cover_art_fetch(runtime, anonymous, 1, &matching));
}

test "a verification through the C ABI forms an album group of corrections that is listed with its members and accepted only whole" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-verify-accept?mode=memory&cache=shared", "test-client");
    defer rig.deinit();
    const album = try provider_tests.addRelease(rig.library_database, "Bryter Layter", provider_tests.bryter_layter_mbid);
    const sounds_northern = try rig.addTone("northern.wav", 300, "Pink Moon", provider_tests.pink_moon_mbid, album);
    _ = try rig.addTone("pink.wav", 420, "Northern Sky", provider_tests.northern_sky_mbid, album);
    rig.acoustid.lookup_body = provider_tests.acoustIdAnswer(
        provider_tests.heardBy("0", provider_tests.heardResult("0.97", provider_tests.northern_sky_heard)) ++ "," ++
            provider_tests.heardBy("1", provider_tests.heardResult("0.96", provider_tests.pink_moon_heard)),
    );

    var verification: CapturedVerification = .{};
    try std.testing.expectEqual(Status.not_found, orca_library_track_verification(rig.runtime, rig.library, sounds_northern, &verification, captureVerification));
    var options: MatchOptions = .{
        .batch_size = 0,
        .limit = 0,
        .track_id = 0,
        .release_id = album,
        .accept_minimum_confidence = 0,
        .mode = 2,
        .has_limit = 0,
        .has_track_id = 0,
        .has_release_id = 1,
        .skip_fingerprints = 0,
        .has_accept_minimum_confidence = 0,
        .cover_art = 0,
    };
    var verifying: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, &options, &verifying));
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(verifying));
    var stats: MatchStatsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_match_stats(rig.runtime, verifying, &stats));
    try std.testing.expectEqual(@as(u64, 2), stats.verified);
    try std.testing.expectEqual(@as(u64, 2), stats.disagreed);
    try std.testing.expectEqual(@as(u64, 1), stats.correction_groups);
    try std.testing.expectEqual(exportAcoustIdUse(.searched), stats.acoustid);

    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_verification(rig.runtime, rig.library, sounds_northern, null, null));
    try std.testing.expectEqual(Status.ok, orca_library_track_verification(rig.runtime, rig.library, sounds_northern, &verification, captureVerification));
    try std.testing.expectEqual(@as(usize, 1), verification.count);
    try std.testing.expectEqual(exportVerificationOutcome(.disagrees), verification.outcome);
    try std.testing.expectEqualStrings(provider_tests.pink_moon_mbid, verification.recording_mbid.text());
    try std.testing.expectEqual(@as(usize, 1), verification.heard_count);
    try std.testing.expectEqualStrings(provider_tests.northern_sky_mbid, verification.strongest.text());
    try std.testing.expectApproxEqAbs(@as(f32, 0.97), verification.strongest_score, 0.001);
    try std.testing.expectEqual(@as(u8, 0), verification.stale);

    var group: CapturedGroup = .{};
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_correction_groups(rig.runtime, rig.library, 0, 0, &group, captureGroup));
    try std.testing.expectEqual(Status.ok, orca_library_query_correction_groups(rig.runtime, rig.library, 10, 0, &group, captureGroup));
    try std.testing.expectEqual(@as(usize, 1), group.count);
    try std.testing.expectEqual(@as(usize, 2), group.member_count);
    try std.testing.expectEqual(@as(usize, 2), group.members_with_corrects);
    try std.testing.expectEqual(@as(usize, 2), group.members_with_track);
    try std.testing.expectEqual(@as(u8, 1), group.has_release_id);
    try std.testing.expectEqual(album, group.release_id);
    try std.testing.expectEqualStrings("Bryter Layter", group.album.text());
    var proposal: CapturedProposal = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_match_proposals(rig.runtime, rig.library, sounds_northern, &proposal, captureProposal));
    try std.testing.expectEqual(@as(u8, 1), proposal.has_corrects);

    var single: MatchAcceptanceView = undefined;
    try std.testing.expectEqual(Status.invalid_state, orca_library_accept_match(rig.runtime, rig.library, group.first_proposal_id, &single));
    try std.testing.expectEqualStrings("orca_library_accept_match: ProposalInGroup", rig.lastError());
    var acceptance: ConfidentAcceptanceView = undefined;
    try std.testing.expectEqual(Status.not_found, orca_library_accept_correction_group(rig.runtime, rig.library, 1_000_000, &acceptance));
    try std.testing.expectEqualStrings("orca_library_accept_correction_group: UnknownCorrectionGroup", rig.lastError());
    try std.testing.expectEqual(Status.invalid_argument, orca_library_accept_correction_group(rig.runtime, rig.library, group.group_id, null));
    try std.testing.expectEqual(Status.ok, orca_library_accept_correction_group(rig.runtime, rig.library, group.group_id, &acceptance));
    try std.testing.expectEqual(@as(u64, 2), acceptance.accepted);
    try std.testing.expect(acceptance.values_written > 0);
    try std.testing.expectEqual(Status.invalid_state, orca_library_accept_correction_group(rig.runtime, rig.library, group.group_id, &acceptance));
    try std.testing.expectEqualStrings("orca_library_accept_correction_group: StaleCorrectionGroup", rig.lastError());
    try std.testing.expectEqual(Status.invalid_state, orca_library_dismiss_correction_group(rig.runtime, rig.library, group.group_id));
    group = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_correction_groups(rig.runtime, rig.library, 10, 0, &group, captureGroup));
    try std.testing.expectEqual(@as(usize, 0), group.count);

    options.has_release_id = 0;
    options.has_accept_minimum_confidence = 1;
    options.accept_minimum_confidence = 0.9;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_match(rig.runtime, rig.library, &options, &verifying));
}

test "an album group of corrections dismissed through the C ABI leaves every member's recording ID as it was" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-verify-dismiss?mode=memory&cache=shared", "test-client");
    defer rig.deinit();
    const album = try provider_tests.addRelease(rig.library_database, "Bryter Layter", provider_tests.bryter_layter_mbid);
    const sounds_northern = try rig.addTone("northern.wav", 300, "Pink Moon", provider_tests.pink_moon_mbid, album);
    _ = try rig.addTone("pink.wav", 420, "Northern Sky", provider_tests.northern_sky_mbid, album);
    rig.acoustid.lookup_body = provider_tests.acoustIdAnswer(
        provider_tests.heardBy("0", provider_tests.heardResult("0.97", provider_tests.northern_sky_heard)) ++ "," ++
            provider_tests.heardBy("1", provider_tests.heardResult("0.96", provider_tests.pink_moon_heard)),
    );
    const options: MatchOptions = .{
        .batch_size = 0,
        .limit = 0,
        .track_id = 0,
        .release_id = album,
        .accept_minimum_confidence = 0,
        .mode = 2,
        .has_limit = 0,
        .has_track_id = 0,
        .has_release_id = 1,
        .skip_fingerprints = 0,
        .has_accept_minimum_confidence = 0,
        .cover_art = 0,
    };
    var verifying: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, &options, &verifying));
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(verifying));
    var group: CapturedGroup = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_correction_groups(rig.runtime, rig.library, 10, 0, &group, captureGroup));
    try std.testing.expectEqual(@as(usize, 1), group.count);

    try std.testing.expectEqual(Status.not_found, orca_library_dismiss_correction_group(rig.runtime, rig.library, 1_000_000));
    try std.testing.expectEqual(Status.invalid_state, orca_library_dismiss_match(rig.runtime, rig.library, group.first_proposal_id));
    try std.testing.expectEqual(Status.ok, orca_library_dismiss_correction_group(rig.runtime, rig.library, group.group_id));
    try std.testing.expectEqual(Status.invalid_state, orca_library_dismiss_correction_group(rig.runtime, rig.library, group.group_id));
    group = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_correction_groups(rig.runtime, rig.library, 10, 0, &group, captureGroup));
    try std.testing.expectEqual(@as(usize, 0), group.count);
    var recording: CapturedRecording = .{};
    try std.testing.expectEqual(Status.ok, orca_library_track_details(rig.runtime, rig.library, sounds_northern, &recording, captureRecording));
    try std.testing.expectEqualStrings(provider_tests.pink_moon_mbid, recording.recording_mbid.text());
    try std.testing.expectEqual(@intFromEnum(IdSource.tag), recording.source);
}

test "a cover fetched through the C ABI is a metadata lookup whose stats say fetched, and the Release's artwork then returns it" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-cover-fetch?mode=memory&cache=shared", null);
    defer rig.deinit();
    const album = try provider_tests.addRelease(rig.library_database, "Bryter Layter", provider_tests.bryter_layter_mbid);
    _ = try provider_tests.addAlbumTrack(rig.library_database, album, "Northern Sky");
    var image: CapturedImage = .{};
    try std.testing.expectEqual(Status.not_found, orca_library_release_artwork(rig.runtime, rig.library, album, &image, captureImage));

    var fetching: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_cover_art_fetch(rig.runtime, rig.library, album, &fetching));
    var snapshot: JobSnapshot = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_snapshot_get(rig.runtime, fetching, &snapshot));
    try std.testing.expectEqual(exportJobKind(.metadata_lookup), snapshot.kind);
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(fetching));
    var stats: MatchStatsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_match_stats(rig.runtime, fetching, &stats));
    try std.testing.expectEqual(exportCoverArtOutcome(.fetched), stats.cover_art);
    try std.testing.expectEqual(@as(u64, 0), stats.requests);
    try std.testing.expectEqual(@as(u32, 1), rig.cover.requestCount());

    try std.testing.expectEqual(Status.ok, orca_library_release_artwork(rig.runtime, rig.library, album, &image, captureImage));
    try std.testing.expectEqual(@as(usize, 1), image.count);
    try std.testing.expectEqualStrings(provider_tests.jpeg_cover, image.bytes[0..image.length]);
}

test "a submission started through the C ABI sends an accepted recording ID once, and fails without a user key leaving it unsent" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-submission?mode=memory&cache=shared", "test-client");
    defer rig.deinit();
    rig.musicbrainz.answers = &nick_drake_answers;
    rig.acoustid.submit_body = "{\"status\":\"ok\",\"submissions\":[{\"id\":71,\"status\":\"pending\",\"index\":\"0\"}]}";
    var keyring: FakeKeyring = .{ .result = @intFromEnum(CredentialResult.not_found), .secret = "userkey" };
    try std.testing.expectEqual(Status.ok, orca_runtime_set_credential_callback(rig.runtime, FakeKeyring.lookup, &keyring));
    const northern_sky = try rig.addUntaggedTone("northern.wav", 440, "Northern Sky");

    var count: u64 = 7;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_acoustid_submittable_count(rig.runtime, rig.library, null));
    try std.testing.expectEqual(Status.stale_handle, orca_library_acoustid_submittable_count(rig.runtime, .{ .index = 7, .generation = 3 }, &count));
    try std.testing.expectEqual(Status.ok, orca_library_acoustid_submittable_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 0), count);

    var matching: Handle = undefined;
    const options: MatchOptions = .{
        .batch_size = 0,
        .limit = 0,
        .track_id = 0,
        .release_id = 0,
        .accept_minimum_confidence = 0,
        .mode = 0,
        .has_limit = 0,
        .has_track_id = 0,
        .has_release_id = 0,
        .skip_fingerprints = 1,
        .has_accept_minimum_confidence = 0,
        .cover_art = 0,
    };
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(matching));
    var proposal: CapturedProposal = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_match_proposals(rig.runtime, rig.library, northern_sky, &proposal, captureProposal));
    try std.testing.expectEqual(@as(usize, 1), proposal.count);
    var acceptance: MatchAcceptanceView = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_accept_match(rig.runtime, rig.library, proposal.id, &acceptance));

    try std.testing.expectEqual(Status.ok, orca_library_acoustid_submittable_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 1), count);
    var submittable: CapturedSubmittable = .{};
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_acoustid_submittable(rig.runtime, rig.library, 0, 0, &submittable, captureSubmittable));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_acoustid_submittable(rig.runtime, rig.library, 0, 513, &submittable, captureSubmittable));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_acoustid_submittable(rig.runtime, rig.library, 0, 10, &submittable, null));
    try std.testing.expectEqual(Status.stale_handle, orca_library_query_acoustid_submittable(rig.runtime, .{ .index = 7, .generation = 3 }, 0, 10, &submittable, captureSubmittable));
    try std.testing.expectEqual(Status.ok, orca_library_query_acoustid_submittable(rig.runtime, rig.library, 0, 10, &submittable, captureSubmittable));
    try std.testing.expectEqual(@as(usize, 1), submittable.count);
    try std.testing.expectEqual(acceptance.file_id, submittable.last_file_id);
    try std.testing.expectEqual(try provider_tests.trackOfFile(rig.library_database, acceptance.file_id), submittable.track_id);
    try std.testing.expectEqualStrings(provider_tests.northern_sky_mbid, submittable.recording_mbid.text());
    try std.testing.expectEqualStrings("Northern Sky", submittable.title.text());
    try std.testing.expectEqualStrings("Nick Drake", submittable.artist.text());
    try std.testing.expectEqual(@as(u8, 1), submittable.has_path);
    try std.testing.expect(std.mem.endsWith(u8, submittable.path.text(), "northern.wav"));
    try std.testing.expectEqual(@as(u8, 0), submittable.has_duration_ms);
    try std.testing.expectEqual(@as(i64, 0), submittable.duration_ms);
    try std.testing.expectEqual(@as(u8, 1), submittable.has_track_number);
    try std.testing.expectEqual(@as(u8, 1), submittable.has_recording_length_ms);
    try std.testing.expect(submittable.size_bytes > 0);
    submittable = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_acoustid_submittable(rig.runtime, rig.library, acceptance.file_id, 10, &submittable, captureSubmittable));
    try std.testing.expectEqual(@as(usize, 0), submittable.count);

    var submitting: Handle = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_acoustid_submission(rig.runtime, rig.library, null));
    try std.testing.expectEqual(Status.stale_handle, orca_library_start_acoustid_submission(rig.runtime, .{ .index = 7, .generation = 3 }, &submitting));
    try std.testing.expectEqual(Status.ok, orca_library_start_acoustid_submission(rig.runtime, rig.library, &submitting));
    var snapshot: JobSnapshot = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_snapshot_get(rig.runtime, submitting, &snapshot));
    try std.testing.expectEqual(exportJobKind(.acoustid_submission), snapshot.kind);
    try std.testing.expectEqual(job.State.failed, try rig.finish(submitting));
    var stats: SubmissionStatsView = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_job_submission_stats(rig.runtime, submitting, null));
    try std.testing.expectEqual(Status.stale_handle, orca_job_submission_stats(rig.runtime, .{ .index = 7, .generation = 3 }, &stats));
    try std.testing.expectEqual(Status.ok, orca_job_submission_stats(rig.runtime, submitting, &stats));
    try std.testing.expectEqual(exportSubmissionOutcome(.needs_user_key), stats.outcome);
    try std.testing.expectEqual(@as(u64, 0), stats.submitted);
    try std.testing.expectEqual(@as(u32, 0), rig.acoustid.submissions.load(.acquire));
    try std.testing.expectEqual(Status.ok, orca_library_acoustid_submittable_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 1), count);

    keyring.result = @intFromEnum(CredentialResult.unavailable);
    try std.testing.expectEqual(Status.ok, orca_library_start_acoustid_submission(rig.runtime, rig.library, &submitting));
    try std.testing.expectEqual(job.State.failed, try rig.finish(submitting));
    try std.testing.expectEqual(Status.ok, orca_job_submission_stats(rig.runtime, submitting, &stats));
    try std.testing.expectEqual(exportSubmissionOutcome(.needs_user_key), stats.outcome);
    try std.testing.expectEqual(@as(u32, 0), rig.acoustid.submissions.load(.acquire));

    keyring.result = @intFromEnum(CredentialResult.found);
    try std.testing.expectEqual(Status.ok, orca_library_start_acoustid_submission(rig.runtime, rig.library, &submitting));
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(submitting));
    try std.testing.expectEqual(Status.ok, orca_job_submission_stats(rig.runtime, submitting, &stats));
    try std.testing.expectEqual(exportSubmissionOutcome(.completed), stats.outcome);
    try std.testing.expectEqual(@as(u64, 1), stats.files_examined);
    try std.testing.expectEqual(@as(u64, 1), stats.submitted);
    try std.testing.expectEqual(@as(u64, 1), stats.fingerprinted);
    try std.testing.expectEqual(@as(u64, 0), stats.rejected);
    try std.testing.expectEqual(@as(u64, 1), stats.requests);
    try std.testing.expectEqual(@as(u32, 1), rig.acoustid.submissions.load(.acquire));
    try std.testing.expect(std.mem.indexOf(u8, rig.acoustid.lastForm(), "&user=userkey&") != null);
    try std.testing.expectEqual(Status.ok, orca_library_acoustid_submittable_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    submittable = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_acoustid_submittable(rig.runtime, rig.library, 0, 10, &submittable, captureSubmittable));
    try std.testing.expectEqual(@as(usize, 0), submittable.count);
}

test "a submission refuses to start beside a running match or without a client identity, and its stats are zero for another job" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-submission-busy?mode=memory&cache=shared", "test-client");
    defer rig.deinit();
    rig.musicbrainz.hang_from = 0;
    rig.musicbrainz.answers = &nick_drake_answers;
    _ = try rig.addUntaggedTone("northern.wav", 440, "Northern Sky");

    var matching: Handle = undefined;
    var options = std.mem.zeroes(MatchOptions);
    options.skip_fingerprints = 1;
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, &options, &matching));
    var submitting: Handle = undefined;
    try std.testing.expectEqual(Status.busy, orca_library_start_acoustid_submission(rig.runtime, rig.library, &submitting));
    try std.testing.expectEqualStrings("orca_library_start_acoustid_submission: AcoustIdBusy", rig.lastError());
    var stats: SubmissionStatsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_submission_stats(rig.runtime, matching, &stats));
    try std.testing.expectEqual(@as(u64, 0), stats.files_examined);
    try std.testing.expectEqual(exportSubmissionOutcome(.completed), stats.outcome);
    try std.testing.expectEqual(Status.ok, orca_job_cancel(rig.runtime, matching));
    _ = try rig.finish(matching);

    const unnamed = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(unnamed);
    var unnamed_library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(unnamed, "file:orca-c-api-submission-unnamed?mode=memory&cache=shared", &unnamed_library));
    try std.testing.expectEqual(Status.invalid_state, orca_library_start_acoustid_submission(unnamed, unnamed_library, &submitting));
    try std.testing.expectEqualStrings("orca_library_start_acoustid_submission: ClientIdentityRequired", std.mem.span(orca_runtime_last_error(unnamed)));
}
