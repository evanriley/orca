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
const discovery = @import("library/discovery.zig");
const daily_mixes = @import("library/daily_mixes.zig");
const folder_estimate = @import("library/folder_estimate.zig");
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
    removed: u8 = 0,
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
    play_count = 9,
    last_played = 10,
    year = 11,
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

/// `TrackQueryView` with explicit `has_*` flags in place of negative ids, and
/// room for a genre filter.
pub const TrackQueryV2View = extern struct {
    artist_id: i64,
    release_id: i64,
    genre_id: i64,
    year_min: i32 = 0,
    year_max: i32 = 0,
    min_sample_rate: u32 = 0,
    sort: u8,
    descending: u8,
    loved_only: u8,
    has_artist_id: u8,
    has_release_id: u8,
    has_genre_id: u8,
    has_year_min: u8 = 0,
    has_year_max: u8 = 0,
    format: u8 = @backingInt(TrackFormatFilter.any),
    explicit_only: u8 = 0,
    _reserved: [2]u8 = @splat(0),
    limit: u32,
    offset: u32,
    text: StringInput = .{ .pointer = null, .length = 0 },
};

pub const TrackFormatFilter = enum(u8) {
    any = 0,
    lossless = 1,
    lossy = 2,
};

pub const TrackFactsView = extern struct {
    codec: StringView,
    added_at: i64,
    last_played_at: i64,
    play_count: u64,
    track_total: i64,
    disc_total: i64,
    sample_rate: u32,
    bit_depth: u32,
    year: i32,
    lossy: u8,
    explicit: u8,
    has_added_at: u8,
    has_last_played_at: u8,
    has_track_total: u8,
    has_disc_total: u8,
    has_year: u8,
    _reserved: [5]u8 = @splat(0),
};

pub const TrackSummaryFactsCallback = *const fn (?*anyopaque, *const TrackSummaryView, *const TrackFactsView) callconv(.c) void;

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

pub const ArtistViewV2 = extern struct {
    base: ArtistView,
    loved: u8,
    has_photo: u8,
    _reserved: [6]u8 = @splat(0),
};

pub const ArtistV2Callback = *const fn (?*anyopaque, *const ArtistViewV2) callconv(.c) void;

pub const ArtistInfoOptionsView = extern struct {
    language: StringInput,
    force: u8,
    offline: u8,
    include_releases: u8 = 0,
    _reserved: [5]u8 = @splat(0),
};

pub const ArtistInfoView = extern struct {
    fetched_at: i64,
    begin_year: i32,
    end_year: i32,
    has_begin_year: u8,
    has_end_year: u8,
    ended: u8,
    has_photo: u8,
    photo_source: u8,
    has_biography: u8,
    outcome: u8,
    has_listeners: u8,
    musicbrainz_artist_id: StringView,
    wikidata_id: StringView,
    artist_type: StringView,
    biography: StringView,
    biography_url: StringView,
    biography_licence: StringView,
    biography_language: StringView,
    photo_url: StringView,
    photo_licence: StringView,
    photo_licence_url: StringView,
    photo_credit: StringView,
    listeners: i64,
};

pub const ArtistInfoCallback = *const fn (?*anyopaque, *const ArtistInfoView) callconv(.c) void;

pub const RelatedArtistView = extern struct {
    name: StringView,
    mbid: StringView,
    library_artist_id: i64,
    has_library_artist_id: u8,
    has_photo: u8,
    _reserved: [2]u8 = @splat(0),
    score: u32,
};

pub const RelatedArtistsCallback = *const fn (?*anyopaque, [*]const RelatedArtistView, usize) callconv(.c) void;

pub const RelatedArtistPhotoInfoView = extern struct {
    fetched_at: i64,
    photo_source: u8,
    _reserved: [7]u8 = @splat(0),
    photo_url: StringView,
    photo_licence: StringView,
    photo_licence_url: StringView,
    photo_credit: StringView,
};

pub const RelatedArtistPhotoInfoCallback = *const fn (?*anyopaque, *const RelatedArtistPhotoInfoView) callconv(.c) void;

pub const ReleaseInfoOptionsView = extern struct {
    language: StringInput,
    force: u8,
    offline: u8,
    _reserved: [6]u8 = @splat(0),
};

pub const ReleaseInfoView = extern struct {
    fetched_at: i64,
    has_description: u8,
    description_source: u8,
    outcome: u8,
    _reserved: [5]u8 = @splat(0),
    description: StringView,
    description_url: StringView,
    description_licence: StringView,
    description_language: StringView,
    musicbrainz_release_id: StringView,
    musicbrainz_release_group_id: StringView,
};

pub const ReleaseInfoCallback = *const fn (?*anyopaque, *const ReleaseInfoView) callconv(.c) void;

pub const GenreFillView = extern struct {
    musicbrainz: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const GenreFillOptionsView = extern struct {
    limit: u32,
    offline: u8,
    _reserved: [3]u8 = @splat(0),
};

pub const ArtistLinkView = extern struct {
    kind: u8,
    _reserved: [7]u8 = @splat(0),
    url: StringView,
};

pub const ArtistLinksCallback = *const fn (?*anyopaque, [*]const ArtistLinkView, usize) callconv(.c) void;

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
    explicit: u8,
    _reserved: [1]u8 = @splat(0),
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

pub const ReleaseQueryV2View = extern struct {
    album_artist_id: i64,
    genre_id: i64,
    year_min: i32 = 0,
    year_max: i32 = 0,
    sort: u8,
    loved_only: u8,
    has_album_artist_id: u8,
    has_genre_id: u8,
    high_resolution_only: u8 = 0,
    needs_review_only: u8 = 0,
    lossless_only: u8 = 0,
    has_year_min: u8 = 0,
    has_year_max: u8 = 0,
    artwork: u8 = @backingInt(ReleaseArtworkFilter.any),
    kind: u8 = @backingInt(ReleaseKindFilter.any),
    has_appearing_artist_id: u8 = 0,
    own_releases_only: u8 = 0,
    _reserved: [3]u8 = @splat(0),
    limit: u32,
    offset: u32,
    text: StringInput = .{ .pointer = null, .length = 0 },
    appearing_artist_id: i64 = 0,
};

pub const ReleaseArtworkFilter = enum(u8) {
    any = 0,
    present = 1,
    absent = 2,
};

pub const ReleaseKindFilter = enum(u8) {
    any = 0,
    album = 1,
    ep_or_single = 2,
    other = 3,
};

pub const ArtistTotalsView = extern struct {
    duration_ms: u64,
    release_count: u32,
    track_count: u32,
    appearance_count: u32,
    _reserved: [4]u8 = @splat(0),
};

pub const ReleaseFactsView = extern struct {
    codec: StringView,
    release_type: StringView,
    max_sample_rate: u32,
    max_bit_depth: u32,
    pending_reviews: u32,
    lossless: u8,
    _reserved: [3]u8 = @splat(0),
};

pub const ReleaseFactsCallback = *const fn (?*anyopaque, *const ReleaseView, *const ReleaseFactsView) callconv(.c) void;

pub const ArtistSortKey = enum(u8) {
    name = 0,
    track_count = 1,
    recently_loved = 2,
    recently_added = 3,
};

pub const ArtistQueryV2View = extern struct {
    filter: StringInput,
    genre_id: i64,
    limit: u32,
    offset: u32,
    sort: u8,
    has_genre_id: u8,
    loved_only: u8,
    _reserved: [5]u8 = @splat(0),
};

pub const GenreSortKey = enum(u8) {
    name = 0,
    track_count = 1,
};

pub const GenreQueryView = extern struct {
    filter: StringInput,
    limit: u32,
    offset: u32,
    sort: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const GenreView = extern struct {
    id: i64,
    total_duration_ms: i64,
    track_count: u32,
    release_count: u32,
    artist_count: u32,
    _reserved: [4]u8 = @splat(0),
    name: StringView,
};

pub const GenreCallback = *const fn (?*anyopaque, *const GenreView) callconv(.c) void;

pub const SearchLimitsView = extern struct {
    artists: u8,
    releases: u8,
    tracks: u8,
    playlists: u8,
    genres: u8,
    _reserved: [3]u8 = @splat(0),
};

pub const SearchHitView = extern struct {
    id: i64,
    title: StringView,
    subtitle: StringView,
    rank: f32,
    kind: u8,
    _reserved: [3]u8 = @splat(0),
};

pub const SearchHitCallback = *const fn (?*anyopaque, *const SearchHitView) callconv(.c) void;

pub const GenreCountView = extern struct {
    id: i64,
    track_count: u32,
    _reserved: [4]u8 = @splat(0),
    name: StringView,
};

pub const GenreCountCallback = *const fn (?*anyopaque, *const GenreCountView) callconv(.c) void;

pub const StringCallback = *const fn (?*anyopaque, *const StringView) callconv(.c) void;

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

pub const RecordingSummaryView = extern struct {
    id: i64,
    title: StringView,
    artist: StringView,
    artist_id: i64,
    has_artist_id: u8,
    reserved: [7]u8 = @splat(0),
};

pub const RecordingSummaryCallback = *const fn (?*anyopaque, *const RecordingSummaryView) callconv(.c) void;

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

pub const TrackDetailsExtraView = extern struct {
    track_total: i64,
    disc_total: i64,
    added_at: i64,
    modified_at: i64,
    has_track_total: u8,
    has_disc_total: u8,
    has_added_at: u8,
    has_modified_at: u8,
    track_total_inferred: u8,
    explicit: u8,
    _reserved: [2]u8 = @splat(0),
};

pub const TrackDetailsV2Callback = *const fn (?*anyopaque, *const TrackDetailsView, *const TrackDetailsExtraView) callconv(.c) void;

pub const TrackDetailsTextView = extern struct {
    composer: StringView,
    comment: StringView,
};

pub const TrackDetailsV3Callback = *const fn (
    ?*anyopaque,
    *const TrackDetailsView,
    *const TrackDetailsExtraView,
    *const TrackDetailsTextView,
) callconv(.c) void;

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

pub const PlaylistSortKey = enum(u8) {
    name = 0,
    recently_updated = 1,
    created = 2,
    entries = 3,
};

pub const PlaylistQueryView = extern struct {
    filter: StringInput,
    limit: u32,
    offset: u32,
    sort: u8,
    has_kind: u8,
    kind: u8,
    pinned_only: u8,
    has_creator: u8,
    creator: u8,
    _reserved: [2]u8 = @splat(0),
};

pub const PlaylistFactsView = extern struct {
    description: StringView,
    pinned: u8,
    loved: u8,
    kind: u8,
    creator: u8,
    mixed_artists: u8,
    tag_count: u8,
    _reserved: [2]u8 = @splat(0),
};

pub const PlaylistV2Callback = *const fn (?*anyopaque, *const PlaylistView, *const PlaylistFactsView) callconv(.c) void;

pub const PlaylistUpdateView = extern struct {
    description: StringInput,
    tags: ?[*]const StringInput,
    tag_count: usize,
    has_description: u8,
    has_pinned: u8,
    pinned: u8,
    has_loved: u8,
    loved: u8,
    has_tags: u8,
    _reserved: [2]u8 = @splat(0),
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

pub const LyricsLineView = extern struct {
    start_ms: i64,
    text: StringView,
};

pub const LyricsView = extern struct {
    source: u8,
    kind: u8,
    _reserved: [6]u8 = @splat(0),
    language: StringView,
    lines: [*]const LyricsLineView,
    line_count: usize,
};

pub const LyricsCallback = *const fn (?*anyopaque, *const LyricsView) callconv(.c) void;

pub const lyrics_fetch_flag: u8 = 1;

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

pub const TagWriteGenresView = extern struct {
    file_id: i64,
    before: [*]const StringView,
    before_count: usize,
    after: [*]const StringView,
    after_count: usize,
};

pub const TagWriteGenresCallback = *const fn (?*anyopaque, *const TagWriteGenresView) callconv(.c) void;

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

pub const TagWriteFailureView = extern struct {
    file_id: i64,
    action_index: u32,
    reason: u8,
    _reserved: [3]u8 = @splat(0),
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

pub const TagWriteGroupView = extern struct {
    group_id: u64,
    written_at: i64,
    file_count: u64,
    state: u8,
    can_undo: u8,
    expired: u8,
    _reserved: [5]u8 = @splat(0),
    title: StringView,
};

pub const TagWriteGroupCallback = *const fn (?*anyopaque, *const TagWriteGroupView) callconv(.c) void;

pub const TagWriteDiffView = extern struct {
    subject: u8,
    field: u8,
    _reserved: [6]u8 = @splat(0),
    file: StringView,
    restores: StringView,
    current: StringView,
};

pub const TagWriteGroupDetailView = extern struct {
    group: TagWriteGroupView,
    diffs: [*]const TagWriteDiffView,
    diff_count: usize,
    more_files: u64,
    field_count: u64,
};

pub const TagWriteGroupDetailCallback = *const fn (?*anyopaque, *const TagWriteGroupDetailView) callconv(.c) void;

pub const PlayStatsView = extern struct {
    play_count: u64,
    last_played_at: i64,
    has_last_played_at: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const AudioFeaturesView = extern struct {
    tempo_bpm: f64,
    tempo_confidence: f64,
    key_confidence: f64,
    onset_rate: f64,
    centroid_hz: f64,
    energy: f64,
    key_pitch: u8,
    key_mode: u8,
    has_tempo: u8,
    has_key: u8,
    has_onset_rate: u8,
    has_centroid: u8,
    has_energy: u8,
    _reserved: [1]u8 = @splat(0),
};

pub const RadioSeedView = extern struct {
    id: i64,
    kind: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const RadioFocusView = extern struct {
    id: i64,
    kind: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const RadioOptionsView = extern struct {
    focus: [discovery.max_focus]RadioFocusView,
    focus_count: u8,
    explore: u8,
    has_include_unplayed: u8,
    include_unplayed: u8,
    has_avoid_recent: u8,
    avoid_recent: u8,
    include_live: u8,
    _reserved: [1]u8 = @splat(0),
};

pub const RadioPreviewSessionView = extern struct {
    now_s: i64,
    seed: u64,
    has_now: u8,
    has_seed: u8,
    _reserved: [6]u8 = @splat(0),
};

pub const RadioComponentsView = extern struct {
    artist: f64,
    genre: f64,
    audio: f64,
    co_listening: f64,
    era: f64,
    taste: f64,
    jitter: f64,
};

pub const ReasonPartView = extern struct {
    a: i64,
    b: i64,
    kind: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const RadioPickView = extern struct {
    track_id: i64,
    recording_id: i64,
    artist_id: i64,
    release_id: i64,
    score: f64,
    components: RadioComponentsView,
    reasons: [2]ReasonPartView,
    reason_count: u8,
    has_artist_id: u8,
    has_release_id: u8,
    never_played: u8,
    _reserved: [4]u8 = @splat(0),
};

pub const RadioPreviewView = extern struct {
    picks: [*]const RadioPickView,
    count: usize,
    weights: RadioComponentsView,
    relaxed_recent: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const RadioPreviewCallback = *const fn (?*anyopaque, *const RadioPreviewView) callconv(.c) void;

pub const RadioStatusView = extern struct {
    library: Handle,
    seed: RadioSeedView,
    options: RadioOptionsView,
    title: StringView,
    picks_added: u32,
    user_queued: u32,
    less_like_this: u32,
    skips: u32,
    pending: u32,
    state: u8,
    continued: u8,
    _reserved: [2]u8 = @splat(0),
};

pub const RadioStatusCallback = *const fn (?*anyopaque, *const RadioStatusView) callconv(.c) void;

pub const RadioQueuePickView = extern struct {
    entry_id: u64,
    track_id: i64,
    recording_id: i64,
    reasons: [2]ReasonPartView,
    position: u32,
    reason_count: u8,
    _reserved: [3]u8 = @splat(0),
};

pub const RadioQueuePicksView = extern struct {
    picks: [*]const RadioQueuePickView,
    count: usize,
};

pub const RadioQueuePicksCallback = *const fn (?*anyopaque, *const RadioQueuePicksView) callconv(.c) void;

pub const DiscoverySettingsView = extern struct {
    radio_continue: u8,
    include_unplayed: u8,
    avoid_days: u8,
    mix_count: u8,
    _reserved: [4]u8 = @splat(0),
};

pub const DailyMixesRequestView = extern struct {
    now_s: i64,
    utc_offset_s: i64,
    force: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const DailyMixArtistView = extern struct {
    id: i64,
    name: StringView,
};

pub const DailyMixView = extern struct {
    id: i64,
    genre_id: i64,
    name: StringView,
    artists: [daily_mixes.max_mix_artists]DailyMixArtistView,
    cover_release_ids: [daily_mixes.max_covers]i64,
    duration_ms: u64,
    entry_count: u32,
    signals: u32,
    left_out_recent: u32,
    left_out_not_for_me: u32,
    left_out_hated: u32,
    left_out_live: u32,
    left_out_other_mix: u32,
    left_out_diversity: u32,
    favorite_count: u32,
    rarely_played_count: u32,
    never_played_count: u32,
    ordinal: u8,
    kind: u8,
    has_genre_id: u8,
    artist_count: u8,
    cover_count: u8,
    _reserved: [1]u8 = @splat(0),
    decade: u16,
};

pub const DailyMixesView = extern struct {
    mixes: [*]const DailyMixView,
    count: usize,
    generated_at: i64,
    local_day: i64,
    state: u8,
    has_generated_at: u8,
    has_local_day: u8,
    _reserved: [5]u8 = @splat(0),
};

pub const DailyMixesCallback = *const fn (?*anyopaque, *const DailyMixesView) callconv(.c) void;

pub const DailyMixEntryView = extern struct {
    track_id: i64,
    recording_id: i64,
    duration_ms: i64,
    reasons: [2]ReasonPartView,
    reason_count: u8,
    has_duration: u8,
    _reserved: [6]u8 = @splat(0),
};

pub const DailyMixEntriesView = extern struct {
    entries: [*]const DailyMixEntryView,
    count: usize,
};

pub const DailyMixEntriesCallback = *const fn (?*anyopaque, *const DailyMixEntriesView) callconv(.c) void;

pub const HomeTopArtistView = extern struct {
    artist_id: i64,
    name: StringView,
    plays: u32,
    _reserved: [4]u8 = @splat(0),
};

pub const ListeningWeekView = extern struct {
    first_local_day: i64,
    day_listened_ms: [core.runtime.home_week_days]u64,
    listened_ms: u64,
    previous_listened_ms: u64,
    top_artist: HomeTopArtistView,
    plays: u32,
    artists: u32,
    releases: u32,
    previous_plays: u32,
    has_top_artist: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const ListeningWeekCallback = *const fn (?*anyopaque, *const ListeningWeekView) callconv(.c) void;

pub const HomeTopArtistsView = extern struct {
    artists: [*]const HomeTopArtistView,
    count: usize,
};

pub const HomeTopArtistsCallback = *const fn (?*anyopaque, *const HomeTopArtistsView) callconv(.c) void;

pub const HomePlayedReleaseView = extern struct {
    release_id: i64,
    title: StringView,
    artist: StringView,
    last_played_at: i64,
    plays: u32,
    _reserved: [4]u8 = @splat(0),
};

pub const HomePlayedReleasesView = extern struct {
    releases: [*]const HomePlayedReleaseView,
    count: usize,
};

pub const HomePlayedReleasesCallback = *const fn (?*anyopaque, *const HomePlayedReleasesView) callconv(.c) void;

pub const HomeTrackView = extern struct {
    track_id: i64,
    artist_id: i64,
    release_id: i64,
    title: StringView,
    artist: StringView,
    release: StringView,
    added_at: i64,
    plays: u32,
    has_artist_id: u8,
    has_release_id: u8,
    _reserved: [2]u8 = @splat(0),
};

pub const HomeTracksView = extern struct {
    tracks: [*]const HomeTrackView,
    count: usize,
};

pub const HomeTracksCallback = *const fn (?*anyopaque, *const HomeTracksView) callconv(.c) void;

pub const HomeReleaseView = extern struct {
    release_id: i64,
    title: StringView,
    artist: StringView,
    year: i32,
    release_class: u8,
    has_year: u8,
    _reserved: [2]u8 = @splat(0),
};

pub const HomeReleasesView = extern struct {
    releases: [*]const HomeReleaseView,
    count: usize,
};

pub const HomeReleasesCallback = *const fn (?*anyopaque, *const HomeReleasesView) callconv(.c) void;

pub const AnniversaryView = extern struct {
    release_id: i64,
    title: StringView,
    artist: StringView,
    year: i32,
    years_ago: u32,
    day_offset: i8,
    round: u8,
    _reserved: [6]u8 = @splat(0),
};

pub const AnniversariesView = extern struct {
    anniversaries: [*]const AnniversaryView,
    count: usize,
};

pub const AnniversariesCallback = *const fn (?*anyopaque, *const AnniversariesView) callconv(.c) void;

pub const HomeFormatsView = extern struct {
    releases: u64,
    tracks: u64,
    duration_ms: u64,
    flac: u64,
    alac: u64,
    mp3: u64,
    other: u64,
};

pub const OnThisDayView = extern struct {
    top_release: HomePlayedReleaseView,
    added_this_week: u32,
    added_this_year: u32,
    tracks: u32,
    never_played_tracks: u32,
    never_played_percent: u8,
    has_top_release: u8,
    _reserved: [6]u8 = @splat(0),
};

pub const OnThisDayCallback = *const fn (?*anyopaque, *const OnThisDayView) callconv(.c) void;

pub const HistoryAgeView = extern struct {
    first_listen_at: i64,
    listen_days: u32,
    has_first_listen_at: u8,
    recording_enabled: u8,
    _reserved: [2]u8 = @splat(0),
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

pub const HealthKindSummaryView = extern struct {
    count: u64,
    kind: u8,
    severity: u8,
    _reserved: [6]u8 = @splat(0),
};

pub const HealthKindSummaryCallback = *const fn (?*anyopaque, *const HealthKindSummaryView) callconv(.c) void;

pub const HealthKindSummaryViewV2 = extern struct {
    base: HealthKindSummaryView,
    files: u64,
    bytes: u64,
};

pub const HealthKindSummaryV2Callback = *const fn (?*anyopaque, *const HealthKindSummaryViewV2) callconv(.c) void;

pub const LibraryStatsView = extern struct {
    artists: u64,
    releases: u64,
    tracks: u64,
    files: u64,
    total_bytes: u64,
    total_duration_ms: u64,
    last_scan_finished_at: i64,
    last_analysis_at: i64,
    has_last_scan_finished_at: u8,
    has_last_analysis_at: u8,
    _reserved: [6]u8 = @splat(0),
};

pub const LibraryStatsViewV2 = extern struct {
    base: LibraryStatsView,
    last_duplicate_scan_at: i64,
    listens: u64,
    has_last_duplicate_scan_at: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const CacheSizeView = extern struct {
    artwork_bytes: u64,
    photo_bytes: u64,
    lyrics_bytes: u64,
    info_bytes: u64,
};

pub const ProviderSourceView = extern struct {
    id: u8,
    _reserved: [7]u8 = @splat(0),
    name: StringView,
    url: StringView,
    supplies: StringView,
    licence: StringView,
    licence_url: StringView,
};

pub const ProviderSourceCallback = *const fn (?*anyopaque, *const ProviderSourceView) callconv(.c) void;

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

pub const DuplicateGroupView = extern struct {
    id: i64,
    bytes_redundant: u64,
    copies: u32,
    similarity: f32,
    same_recording: u8,
    has_similarity: u8,
    verdict: u8,
    _reserved: [5]u8 = @splat(0),
    title: StringView,
    artist: StringView,
};

pub const DuplicateGroupCallback = *const fn (?*anyopaque, *const DuplicateGroupView) callconv(.c) void;

pub const DuplicateGroupTotalsView = extern struct {
    groups: u64,
    bytes: u64,
};

pub const DuplicateCopyView = extern struct {
    file_id: i64,
    track_id: i64,
    playlist_count: u64,
    locations: u32,
    has_track_id: u8,
    suggested_keep: u8,
    _reserved: [2]u8 = @splat(0),
};

pub const DuplicateCopyCallback = *const fn (?*anyopaque, *const DuplicateCopyView, ?*const TrackDetailsView) callconv(.c) void;

pub const DuplicateMergeView = extern struct {
    track_id: i64,
    values: u32,
    rating: u8,
    feedback: u8,
    genres: u8,
    _reserved: [1]u8 = @splat(0),
};

pub const RootView = extern struct {
    id: i64,
    volume_id: i64,
    enabled: u8,
    _reserved: [7]u8 = @splat(0),
    path: StringView,
};

pub const RootCallback = *const fn (?*anyopaque, *const RootView) callconv(.c) void;

pub const RootViewV2 = extern struct {
    base: RootView,
    track_count: u64,
    unavailable_tracks: u64,
    available: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const RootV2Callback = *const fn (?*anyopaque, *const RootViewV2) callconv(.c) void;

pub const FolderEntryView = extern struct {
    track_id: i64,
    file_id: i64,
    total_duration_ms: i64,
    file_count: u32,
    track_count: u32,
    kind: u8,
    has_track_id: u8,
    has_file_id: u8,
    _reserved: [5]u8 = @splat(0),
    name: StringView,
};

pub const FolderEntryCallback = *const fn (?*anyopaque, *const FolderEntryView) callconv(.c) void;

pub const DeviceView = extern struct {
    id: u64,
    name: StringView,
};

pub const DeviceCallback = *const fn (?*anyopaque, *const DeviceView) callconv(.c) void;

pub const DeviceViewV2 = extern struct {
    base: DeviceView,
    kind: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const DeviceV2Callback = *const fn (?*anyopaque, *const DeviceViewV2) callconv(.c) void;

pub const DeviceViewV3 = extern struct {
    base: DeviceViewV2,
    has_capabilities: u8,
    state: u8,
    bit_depths: u8,
    channels_max: u8,
    rate_min_hz: u32,
    rate_max_hz: u32,
    _reserved: [4]u8 = @splat(0),
};

pub const DeviceV3Callback = *const fn (?*anyopaque, *const DeviceViewV3) callconv(.c) void;

pub const QueueEntryView = extern struct {
    position: u32,
    is_current: u8,
    _reserved: [3]u8 = @splat(0),
    track_id: i64,
};

pub const QueueEntryCallback = *const fn (?*anyopaque, *const QueueEntryView) callconv(.c) void;

pub const QueueHistoryCallback = *const fn (?*anyopaque, *const TrackSummaryView, i64, u8) callconv(.c) void;

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

pub const PlayerStatusV2 = extern struct {
    base: PlayerStatus,
    failure_track_id: i64,
    has_failure: u8,
    failure_reason: u8,
    _reserved: [6]u8 = @splat(0),
};

pub const PlayerStatusV3 = extern struct {
    base: PlayerStatusV2,
    resumed_from_ms: u64,
    has_resumed: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const RestoreOutcomeView = extern struct {
    entries: u32,
    index: u32,
    position_ms: u64,
    skipped_missing: u32,
    _reserved: [4]u8 = @splat(0),
};

pub const EqualizerView = extern struct {
    gains_db: [audio.dsp.band_count]f32,
    preamp_db: f32,
};

pub const ParametricFilterView = extern struct {
    kind: u8,
    enabled: u8,
    _reserved: [2]u8 = @splat(0),
    frequency_hz: f32,
    gain_db: f32,
    q: f32,
};

pub const ParametricEqualizerView = extern struct {
    filters: [audio.dsp.max_parametric_filters]ParametricFilterView,
    count: u8,
    _reserved: [3]u8 = @splat(0),
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

pub const DeviceFormatView = extern struct {
    sample_rate: u32,
    channels: u16,
    bits_per_sample: u8,
    sample_format: u8,
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
    output_kind: u8,
    has_device_quantum: u8,
    replay_gain_source: u8,
    device_quantum_frames: u32,
    codec: StringView,
};

pub const SignalPathViewV2 = extern struct {
    base: SignalPathView,
    parametric: ParametricEqualizerView,
    has_parametric: u8,
    has_replay_gain_track: u8,
    _reserved: [2]u8 = @splat(0),
    replay_gain_track_db: f32,
    preamp_db: f32,
    peak_protection: u8,
    fallback: u8,
    peak_limited: u8,
    _reserved2: [1]u8 = @splat(0),
    device_format: DeviceFormatView,
};

comptime {
    std.debug.assert(@sizeOf(SignalPathView) == 128);
    std.debug.assert(@sizeOf(SignalPathViewV2) == 416);
}

pub const ReplayGainSettingsView = extern struct {
    preamp_db: f32,
    mode: u8,
    fallback: u8,
    peak_protection: u8,
    _reserved: [1]u8 = @splat(0),
};

pub const SignalPathCallback = *const fn (?*anyopaque, *const SignalPathView) callconv(.c) void;
pub const SignalPathV2Callback = *const fn (?*anyopaque, *const SignalPathViewV2) callconv(.c) void;

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

pub const JobDetails = extern struct {
    started_at: i64,
    estimated_remaining_ms: u64,
    has_started_at: u8,
    paused: u8,
    has_estimated_remaining_ms: u8,
    _reserved: [5]u8 = @splat(0),
    current_item: StringView,
    detail: StringView,
};

pub const JobDetailsCallback = *const fn (?*anyopaque, *const JobDetails) callconv(.c) void;

pub const QueuedJobView = extern struct {
    job: Handle,
    after: Handle,
    kind: u8,
    has_after: u8,
    _reserved: [6]u8 = @splat(0),
};

pub const QueuedJobCallback = *const fn (?*anyopaque, *const QueuedJobView) callconv(.c) void;

pub const JobHistoryView = extern struct {
    id: i64,
    started_at: i64,
    finished_at: i64,
    completed_units: u64,
    total_units: u64,
    undo_group_id: u64,
    kind: u8,
    state: u8,
    has_total: u8,
    has_undo_group_id: u8,
    retryable: u8,
    _reserved: [3]u8 = @splat(0),
    error_text: StringView,
    summary: StringView,
};

pub const JobHistoryCallback = *const fn (?*anyopaque, *const JobHistoryView) callconv(.c) void;

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

pub const ScanStatsV2 = extern struct {
    base: ScanStats,
    albums_found: u64,
    stage: u8,
    _reserved: [1]u8 = @splat(0),
    current_path_length: u16,
    _reserved2: [4]u8 = @splat(0),
    current_path: [512]u8,
};

pub const ScanStatsV3 = extern struct {
    base: ScanStatsV2,
    symlinks_skipped: u64,
};

pub const FolderEstimate = extern struct {
    audio_files: u64,
    truncated: u8,
    _reserved: [7]u8 = @splat(0),
};

pub const ScanOptions = extern struct {
    batch_size: u32,
    reprobe_all: u8 = 0,
    _reserved: [3]u8 = @splat(0),
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

pub const BackfillPendingView = extern struct {
    files: u64,
    covers: u64,
};

pub const measurement_loudness_and_checks: u32 = 1;
pub const measurement_fingerprint: u32 = 2;
pub const measurement_features: u32 = 4;

pub const AnalysisCoverageView = extern struct {
    never_analyzed: u64,
    outdated: u64,
    measurement_set: u64,
    missing: u32,
    _reserved: [4]u8 = @splat(0),
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

pub const MaintenanceOptions = extern struct {
    interval_ms: u32,
    enabled: u8,
    _reserved: [3]u8 = @splat(0),
};

pub const MaintenanceStatus = extern struct {
    next_due_ms: u64,
    units_run: u64,
    last_release_id: i64,
    last_stats: MatchStatsView,
    enabled: u8,
    state: u8,
    blocked: u8,
    has_blocked: u8,
    has_next_due_ms: u8,
    has_last: u8,
    has_last_release_id: u8,
    last_state: u8,
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

pub const MatchStatsViewV2 = extern struct {
    base: MatchStatsView,
    releases_to_review: u64,
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

pub const ReleaseMatchView = extern struct {
    release_id: i64,
    track_count: u32,
    bucket: u8,
    has_best: u8,
    has_candidate_track_count: u8,
    from_tags: u8,
    title: StringView,
    artist: StringView,
    release_mbid: StringView,
    candidate_title: StringView,
    candidate_date: StringView,
    candidate_track_count: u32,
    confidence: f32,
};

pub const ReleaseMatchCallback = *const fn (?*anyopaque, *const ReleaseMatchView) callconv(.c) void;

pub const ReleaseMatchCountsView = extern struct {
    confident: u64,
    needs_review: u64,
    unmatched: u64,
};

pub const ReleaseMatchViewV2 = extern struct {
    base: ReleaseMatchView,
    placed: u32,
    needs_pairing: u32,
    has_placement: u8,
    candidate_unread: u8,
    _reserved: [6]u8 = @splat(0),
};

pub const ReleaseMatchV2Callback = *const fn (?*anyopaque, *const ReleaseMatchViewV2) callconv(.c) void;

pub const ReleaseMatchCountsViewV2 = extern struct {
    base: ReleaseMatchCountsView,
    reviewed: u64,
};

pub const RecordingSource = enum(u8) {
    none = 0,
    in_effect = 1,
    accepted_match = 2,
    pending_match = 3,
};

pub const AlignedTrackView = extern struct {
    track_id: i64,
    duration_ms: i64,
    track_number: u32,
    disc_number: u32,
    has_duration_ms: u8,
    has_track_number: u8,
    has_disc_number: u8,
    _reserved: [5]u8 = @splat(0),
    title: StringView,
};

pub const ReleaseTrackPlacementView = extern struct {
    disc: u32,
    position: u32,
    length_ms: u64,
    length_delta_ms: i64,
    has_length_ms: u8,
    status: u8,
    recording_source: u8,
    has_track: u8,
    title_equal: u8,
    length_close: u8,
    position_equal: u8,
    has_length_delta_ms: u8,
    title: StringView,
    artist_credit: StringView,
    recording_mbid: StringView,
    release_track_mbid: StringView,
    track: AlignedTrackView,
};

pub const ReleaseAlignmentView = extern struct {
    release_id: i64,
    fetched_at: i64,
    medium_count: u32,
    paired: u32,
    automatic: u32,
    suggested: u32,
    not_in_files: u32,
    _reserved: [4]u8 = @splat(0),
    release_mbid: StringView,
    title: StringView,
    artist_credit: StringView,
    release_date: StringView,
    release_group_mbid: StringView,
    rows: [*]const ReleaseTrackPlacementView,
    row_count: usize,
    not_on_release: [*]const AlignedTrackView,
    not_on_release_count: usize,
};

pub const ReleaseAlignmentCallback = *const fn (?*anyopaque, *const ReleaseAlignmentView) callconv(.c) void;

pub const ReleaseTrackPairingView = extern struct {
    release_id: i64,
    track_id: i64,
    created_at: i64,
    disc: u32,
    position: u32,
    origin: u8,
    in_snapshot: u8,
    has_position: u8,
    _reserved: [5]u8 = @splat(0),
    release_mbid: StringView,
    release_track_mbid: StringView,
    recording_mbid: StringView,
};

pub const ReleaseTrackPairingCallback = *const fn (?*anyopaque, *const ReleaseTrackPairingView) callconv(.c) void;

pub const LeftAloneTrackView = extern struct {
    track_id: i64,
    reason: u8,
    _reserved: [7]u8 = @splat(0),
    title: StringView,
};

pub const ReleaseApplyView = extern struct {
    reviewed_release_id: i64,
    values_written: u32,
    track_values: u32,
    release_values_only: u32,
    artist_ids_unknown: u8,
    has_reviewed_release_id: u8,
    _reserved: [2]u8 = @splat(0),
    release_mbid: StringView,
    left_alone: [*]const LeftAloneTrackView,
    left_alone_count: usize,
};

pub const ReleaseApplyCallback = *const fn (?*anyopaque, *const ReleaseApplyView) callconv(.c) void;

pub const MatchEvidenceView = extern struct {
    fingerprints_matched: u32,
    tracks: u32,
    durations_within_1s: u8,
    artist_agrees: u8,
    title_agrees: u8,
    date_agrees: u8,
    _reserved: [4]u8 = @splat(0),
    note: StringView,
};

pub const MatchEvidenceCallback = *const fn (?*anyopaque, *const MatchEvidenceView) callconv(.c) void;

pub const ReleaseFieldDiffView = extern struct {
    field: u8,
    differs: u8,
    _reserved: [6]u8 = @splat(0),
    local: StringView,
    candidate: StringView,
};

pub const ReleaseTrackAlignmentView = extern struct {
    track_id: i64,
    delta_ms: i64,
    position: u32,
    has_delta_ms: u8,
    fingerprint: u8,
    differs: u8,
    _reserved: [1]u8 = @splat(0),
    local_title: StringView,
    candidate_title: StringView,
    local_artist: StringView,
    candidate_artist: StringView,
};

pub const ReleaseMatchDiffView = extern struct {
    release_mbid: StringView,
    fields: [*]const ReleaseFieldDiffView,
    field_count: usize,
    tracks: [*]const ReleaseTrackAlignmentView,
    track_count: usize,
    aligned: u32,
    _reserved: [4]u8 = @splat(0),
};

pub const ReleaseMatchDiffCallback = *const fn (?*anyopaque, *const ReleaseMatchDiffView) callconv(.c) void;

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

pub const ScrobblerStatusView = extern struct {
    next_attempt_at: i64,
    blocked_until: i64,
    pending: u64,
    feedback_pending: u64,
    delivered_total: u64,
    recorded_total: u64,
    dropped: u64,
    enabled: u8,
    state: u8,
    has_next_attempt_at: u8,
    has_blocked_until: u8,
    _reserved: [4]u8 = @splat(0),
    user_name: StringView,
    last_error: StringView,
};

pub const ScrobblerStatusCallback = *const fn (?*anyopaque, *const ScrobblerStatusView) callconv(.c) void;

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
        if (builtin.mode != .debug) return false;
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
    if (box.foreignThread()) {
        std.log.warn("orca_runtime_destroy called from a thread other than the runtime's creating thread; the runtime was not destroyed", .{});
        return;
    }
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
            .kind = @backingInt(item.kind),
            .severity = @backingInt(item.severity),
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
        const view = healthItemView(item);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_query_health_items_of_kind(
    runtime: ?*Runtime,
    library: Handle,
    kind: u8,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?HealthItemCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const issue_kind = importHealthIssueKind(kind) orelse
        return box.reject(@src(), .invalid_argument, "kind is not an orca_health_issue_kind");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    var page = box.runtime.libraryHealthIssuePageOfKind(
        importLibrary(library),
        issue_kind,
        limit,
        offset,
    ) catch |err| return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view = healthItemView(item);
        visit(context, &view);
    }
    return .ok;
}

fn healthItemView(item: database.HealthIssue) HealthItemView {
    return .{
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
}

pub export fn orca_library_health_summary(
    runtime: ?*Runtime,
    library: Handle,
    context: ?*anyopaque,
    callback: ?HealthKindSummaryCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const summary = box.runtime.libraryHealthSummary(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    for (summary.items()) |entry| {
        const view: HealthKindSummaryView = .{
            .count = entry.count,
            .kind = exportHealthIssueKind(entry.kind),
            .severity = exportHealthSeverity(entry.severity),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_health_summary_v2(
    runtime: ?*Runtime,
    library: Handle,
    context: ?*anyopaque,
    callback: ?HealthKindSummaryV2Callback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const summary = box.runtime.libraryHealthSummary(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    for (summary.items()) |entry| {
        const view: HealthKindSummaryViewV2 = .{
            .base = .{
                .count = entry.count,
                .kind = exportHealthIssueKind(entry.kind),
                .severity = exportHealthSeverity(entry.severity),
            },
            .files = entry.files,
            .bytes = entry.bytes,
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_stats(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*LibraryStatsView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const stats = box.runtime.libraryStats(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    destination.* = exportLibraryStats(stats);
    return .ok;
}

fn exportLibraryStats(stats: database.LibraryStats) LibraryStatsView {
    return .{
        .artists = stats.artists,
        .releases = stats.releases,
        .tracks = stats.tracks,
        .files = stats.files,
        .total_bytes = stats.total_bytes,
        .total_duration_ms = stats.total_duration_ms,
        .last_scan_finished_at = stats.last_scan_finished_at orelse 0,
        .last_analysis_at = stats.last_analysis_at orelse 0,
        .has_last_scan_finished_at = @intFromBool(stats.last_scan_finished_at != null),
        .has_last_analysis_at = @intFromBool(stats.last_analysis_at != null),
    };
}

pub export fn orca_library_stats_v2(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*LibraryStatsViewV2,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const stats = box.runtime.libraryStats(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    destination.* = .{
        .base = exportLibraryStats(stats),
        .last_duplicate_scan_at = stats.last_duplicate_scan_at orelse 0,
        .listens = stats.listens,
        .has_last_duplicate_scan_at = @intFromBool(stats.last_duplicate_scan_at != null),
    };
    return .ok;
}

fn exportCacheSize(size: core.runtime.CacheSize) CacheSizeView {
    return .{
        .artwork_bytes = size.artwork_bytes,
        .photo_bytes = size.photo_bytes,
        .lyrics_bytes = size.lyrics_bytes,
        .info_bytes = size.info_bytes,
    };
}

pub export fn orca_library_cache_size(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*CacheSizeView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const size = box.runtime.libraryCacheSize(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    destination.* = exportCacheSize(size);
    return .ok;
}

pub export fn orca_library_clear_cache(
    runtime: ?*Runtime,
    library: Handle,
    cleared: ?*CacheSizeView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const size = box.runtime.libraryClearCache(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    if (cleared) |destination| destination.* = exportCacheSize(size);
    return .ok;
}

pub export fn orca_provider_sources(
    runtime: ?*Runtime,
    context: ?*anyopaque,
    callback: ?ProviderSourceCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    for (box.runtime.providerSources()) |source| {
        const view: ProviderSourceView = .{
            .id = exportProviderSourceId(source.id),
            .name = stringView(source.name),
            .url = stringView(source.url),
            .supplies = stringView(source.supplies),
            .licence = stringView(source.licence),
            .licence_url = stringView(source.licence_url orelse ""),
        };
        visit(context, &view);
    }
    return .ok;
}

pub fn exportProviderSourceId(id: core.provider_sources.ProviderSourceId) u8 {
    return switch (id) {
        .musicbrainz => 0,
        .musicbrainz_genres => 1,
        .cover_art_archive => 2,
        .acoustid => 3,
        .listenbrainz => 4,
        .lrclib => 5,
        .wikidata => 6,
        .wikimedia_commons => 7,
        .wikipedia => 8,
    };
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

pub export fn orca_library_query_duplicate_groups(
    runtime: ?*Runtime,
    library: Handle,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?DuplicateGroupCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    var page = box.runtime.libraryDuplicateGroupPage(importLibrary(library), box.runtime.allocator, limit, offset) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |group| {
        var view = duplicateGroupView(group.id, group.same_recording, group.similarity, group.verdict, group.copies, group.bytes_redundant);
        view.title = stringView(group.title);
        view.artist = stringView(group.artist);
        visit(context, &view);
    }
    return .ok;
}

fn duplicateGroupView(
    id: i64,
    same_recording: bool,
    similarity: ?f32,
    verdict: database.DuplicateVerdict,
    copies: u32,
    bytes_redundant: u64,
) DuplicateGroupView {
    return .{
        .id = id,
        .bytes_redundant = bytes_redundant,
        .copies = copies,
        .similarity = similarity orelse 0,
        .same_recording = @intFromBool(same_recording),
        .has_similarity = @intFromBool(similarity != null),
        .verdict = exportHealthIssueKind(verdict.kind()),
        .title = stringView(""),
        .artist = stringView(""),
    };
}

pub export fn orca_library_duplicate_group_totals(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*DuplicateGroupTotalsView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const totals = box.runtime.libraryDuplicateGroupTotals(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    destination.* = .{ .groups = totals.groups, .bytes = totals.bytes };
    return .ok;
}

pub export fn orca_library_query_duplicate_group(
    runtime: ?*Runtime,
    library: Handle,
    group_id: i64,
    group: ?*DuplicateGroupView,
    context: ?*anyopaque,
    callback: ?DuplicateCopyCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var copies = box.runtime.libraryDuplicateGroup(importLibrary(library), box.runtime.allocator, group_id) catch |err|
        return box.fail(@src(), err);
    defer copies.deinit();
    if (group) |destination| destination.* = duplicateGroupView(
        group_id,
        copies.same_recording,
        copies.similarity,
        copies.verdict,
        copies.copies,
        copies.bytes_redundant,
    );
    for (copies.items) |copy| {
        const view: DuplicateCopyView = .{
            .file_id = copy.file_id,
            .track_id = copy.track_id orelse 0,
            .playlist_count = copy.playlist_count,
            .locations = copy.locations,
            .has_track_id = @intFromBool(copy.track_id != null),
            .suggested_keep = @intFromBool(copy.suggested_keep),
        };
        if (copy.details) |*details| {
            const details_view = trackDetailsView(details);
            visit(context, &view, &details_view);
        } else visit(context, &view, null);
    }
    return .ok;
}

pub export fn orca_library_keep_both_duplicates(
    runtime: ?*Runtime,
    library: Handle,
    file_id: i64,
    other_file_id: i64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.libraryKeepBoth(importLibrary(library), file_id, other_file_id) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_ignore_duplicate_group(
    runtime: ?*Runtime,
    library: Handle,
    group_id: i64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.libraryIgnoreDuplicateGroup(importLibrary(library), group_id) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_merge_duplicate_metadata(
    runtime: ?*Runtime,
    library: Handle,
    keep_track_id: i64,
    from_track_id: i64,
    output: ?*DuplicateMergeView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const merged = box.runtime.libraryMergeDuplicateMetadata(importLibrary(library), keep_track_id, from_track_id) catch |err|
        return box.fail(@src(), err);
    if (output) |destination| destination.* = .{
        .track_id = merged.track_id,
        .values = merged.values,
        .rating = @intFromBool(merged.rating),
        .feedback = @intFromBool(merged.feedback),
        .genres = @intFromBool(merged.genres),
    };
    return .ok;
}

pub export fn orca_library_duplicate_copy_playlists(
    runtime: ?*Runtime,
    library: Handle,
    file_id: i64,
    context: ?*anyopaque,
    callback: ?StringCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const names = box.runtime.libraryDuplicateCopyPlaylists(importLibrary(library), box.runtime.allocator, file_id) catch |err|
        return box.fail(@src(), err);
    defer {
        for (names) |name| box.runtime.allocator.free(name);
        box.runtime.allocator.free(names);
    }
    for (names) |name| {
        const view = stringView(name);
        visit(context, &view);
    }
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

pub export fn orca_library_artist_totals(
    runtime: ?*Runtime,
    library: Handle,
    artist_id: i64,
    output: ?*ArtistTotalsView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const found = box.runtime.libraryArtistTotals(importLibrary(library), artist_id) catch |err|
        return box.fail(@src(), err);
    const totals = found orelse return box.reject(@src(), .not_found, "no such artist");
    destination.* = .{
        .duration_ms = totals.duration_ms,
        .release_count = totals.release_count,
        .track_count = totals.track_count,
        .appearance_count = totals.appearance_count,
    };
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

pub export fn orca_library_browse_tracks_v2(
    runtime: ?*Runtime,
    library: Handle,
    query: ?*const TrackQueryV2View,
    context: ?*anyopaque,
    callback: ?TrackSummaryFactsCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const view = query orelse return box.reject(@src(), .invalid_argument, "query is null");
    const request = importTrackQueryV2(view) orelse
        return box.reject(@src(), .invalid_argument, invalid_track_query_v2);
    const text = stringInput(view.text.pointer, view.text.length).?;
    var page = box.runtime.libraryTrackQuery(importLibrary(library), text, request) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const summary = trackSummaryView(item);
        const facts = trackFactsView(item);
        visit(context, &summary, &facts);
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

pub export fn orca_library_track_match_count_v2(
    runtime: ?*Runtime,
    library: Handle,
    query: ?*const TrackQueryV2View,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const view = query orelse return box.reject(@src(), .invalid_argument, "query is null");
    const request = importTrackQueryV2(view) orelse
        return box.reject(@src(), .invalid_argument, invalid_track_query_v2);
    if (view.text.length != 0) return box.reject(@src(), .invalid_argument, "a track search has no count; text must be empty");
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

pub export fn orca_library_browse_releases_v2(
    runtime: ?*Runtime,
    library: Handle,
    query: ?*const ReleaseQueryV2View,
    context: ?*anyopaque,
    callback: ?ReleaseFactsCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const request = importReleaseQueryV2(query orelse
        return box.reject(@src(), .invalid_argument, "query is null")) orelse
        return box.reject(@src(), .invalid_argument, invalid_release_query_v2);
    var page = box.runtime.libraryReleasePage(importLibrary(library), request) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view = releaseView(item);
        const facts = releaseFactsView(item);
        visit(context, &view, &facts);
    }
    return .ok;
}

pub export fn orca_library_release_count_matching_v2(
    runtime: ?*Runtime,
    library: Handle,
    query: ?*const ReleaseQueryV2View,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const request = importReleaseQueryV2(query orelse
        return box.reject(@src(), .invalid_argument, "query is null")) orelse
        return box.reject(@src(), .invalid_argument, invalid_release_query_v2);
    destination.* = box.runtime.libraryReleaseCountMatching(importLibrary(library), request) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_query_artists_v2(
    runtime: ?*Runtime,
    library: Handle,
    query: ?*const ArtistQueryV2View,
    context: ?*anyopaque,
    callback: ?ArtistV2Callback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const request = importArtistQueryV2(query orelse
        return box.reject(@src(), .invalid_argument, "query is null")) orelse
        return box.reject(@src(), .invalid_argument, invalid_artist_query_v2);
    var page = box.runtime.libraryArtistPage(importLibrary(library), request) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view: ArtistViewV2 = .{
            .base = artistView(item),
            .loved = @intFromBool(item.loved),
            .has_photo = @intFromBool(item.has_photo),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_artist_count_matching_v2(
    runtime: ?*Runtime,
    library: Handle,
    query: ?*const ArtistQueryV2View,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const request = importArtistQueryV2(query orelse
        return box.reject(@src(), .invalid_argument, "query is null")) orelse
        return box.reject(@src(), .invalid_argument, invalid_artist_query_v2);
    destination.* = box.runtime.libraryArtistCountMatching(importLibrary(library), request) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_query_genres(
    runtime: ?*Runtime,
    library: Handle,
    query: ?*const GenreQueryView,
    context: ?*anyopaque,
    callback: ?GenreCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const request = importGenreQuery(query orelse
        return box.reject(@src(), .invalid_argument, "query is null")) orelse
        return box.reject(@src(), .invalid_argument, invalid_genre_query);
    var page = box.runtime.libraryGenrePage(importLibrary(library), request) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view = genreView(item);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_search(
    runtime: ?*Runtime,
    library: Handle,
    text: ?[*]const u8,
    text_length: usize,
    limits: ?*const SearchLimitsView,
    context: ?*anyopaque,
    callback: ?SearchHitCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const words = stringInput(text, text_length) orelse
        return box.reject(@src(), .invalid_argument, "text is null and text_length is not zero");
    var results = box.runtime.librarySearch(importLibrary(library), words, importSearchLimits(limits)) catch |err|
        return box.fail(@src(), err);
    defer results.deinit();
    for (results.hits) |hit| {
        if (hit.reason != .name) continue;
        const view: SearchHitView = .{
            .id = hit.id,
            .title = stringView(hit.title),
            .subtitle = stringView(hit.subtitle),
            .rank = hit.rank,
            .kind = exportSearchKind(hit.kind),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_genre_count(
    runtime: ?*Runtime,
    library: Handle,
    filter: ?[*]const u8,
    filter_length: usize,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const text = stringInput(filter, filter_length) orelse
        return box.reject(@src(), .invalid_argument, "filter is null and filter_length is not zero");
    destination.* = box.runtime.libraryGenreCount(importLibrary(library), text) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_genre_get(
    runtime: ?*Runtime,
    library: Handle,
    genre_id: i64,
    context: ?*anyopaque,
    callback: ?GenreCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const found = box.runtime.libraryGenre(importLibrary(library), genre_id) catch |err|
        return box.fail(@src(), err);
    const item = found orelse return box.reject(@src(), .not_found, "no Track carries that genre");
    defer item.deinit(box.runtime.allocator);
    const view = genreView(item);
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_track_genres(
    runtime: ?*Runtime,
    library: Handle,
    track_id: i64,
    context: ?*anyopaque,
    callback: ?StringCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const names = box.runtime.libraryTrackGenres(importLibrary(library), track_id) catch |err|
        return box.fail(@src(), err);
    defer names.deinit();
    for (names.items) |item| {
        const view = stringView(item.name);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_release_genres(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    limit: u32,
    context: ?*anyopaque,
    callback: ?GenreCountCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    const counts = box.runtime.libraryReleaseGenres(importLibrary(library), release_id, limit) catch |err|
        return box.fail(@src(), err);
    defer counts.deinit();
    visitGenreCounts(counts, context, visit);
    return .ok;
}

pub export fn orca_library_artist_genres(
    runtime: ?*Runtime,
    library: Handle,
    artist_id: i64,
    limit: u32,
    context: ?*anyopaque,
    callback: ?GenreCountCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    const counts = box.runtime.libraryArtistGenres(importLibrary(library), artist_id, limit) catch |err|
        return box.fail(@src(), err);
    defer counts.deinit();
    visitGenreCounts(counts, context, visit);
    return .ok;
}

fn visitGenreCounts(counts: database.GenreCounts, context: ?*anyopaque, visit: GenreCountCallback) void {
    for (counts.items) |item| {
        const view: GenreCountView = .{ .id = item.id, .track_count = item.track_count, .name = stringView(item.name) };
        visit(context, &view);
    }
}

pub export fn orca_library_set_track_genres(
    runtime: ?*Runtime,
    library: Handle,
    track_ids: ?[*]const i64,
    count: usize,
    names: ?[*]const StringInput,
    name_count: usize,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const list = editIdSlice(track_ids, count) orelse
        return box.reject(@src(), .invalid_argument, invalid_edit_ids);
    if (name_count > database.max_track_genres) return box.reject(@src(), .invalid_argument, "name_count exceeds 16");
    var imported: [database.max_track_genres][]const u8 = undefined;
    if (name_count != 0) {
        const given = names orelse
            return box.reject(@src(), .invalid_argument, "names is null and name_count is not zero");
        for (imported[0..name_count], given[0..name_count]) |*name, view| {
            name.* = stringInput(view.pointer, view.length) orelse
                return box.reject(@src(), .invalid_argument, "a name is null and its length is not zero");
        }
    }
    box.runtime.librarySetTrackGenres(importLibrary(library), list, imported[0..name_count]) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_genre_artwork(
    runtime: ?*Runtime,
    library: Handle,
    genre_id: i64,
    limit: u32,
    context: ?*anyopaque,
    callback: ?IdCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    const releases = box.runtime.libraryGenreArtwork(importLibrary(library), genre_id, limit) catch |err|
        return box.fail(@src(), err);
    defer releases.deinit();
    visit(context, releases.ids.ptr, releases.ids.len);
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
    const view = trackSummaryView(item);
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_recording_get(
    runtime: ?*Runtime,
    library: Handle,
    recording_id: i64,
    context: ?*anyopaque,
    callback: ?RecordingSummaryCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const found = box.runtime.libraryRecordingSummary(importLibrary(library), recording_id) catch |err|
        return box.fail(@src(), err);
    const item = found orelse return box.reject(@src(), .not_found, "no such recording");
    defer item.deinit(box.runtime.allocator);
    const view: RecordingSummaryView = .{
        .id = item.id,
        .title = stringView(item.title),
        .artist = stringView(item.artist),
        .artist_id = item.artist_id orelse 0,
        .has_artist_id = @intFromBool(item.artist_id != null),
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

pub export fn orca_library_track_details_v2(
    runtime: ?*Runtime,
    library: Handle,
    track_id: i64,
    context: ?*anyopaque,
    callback: ?TrackDetailsV2Callback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const found = box.runtime.libraryTrackDetails(importLibrary(library), track_id) catch |err|
        return box.fail(@src(), err);
    const details = found orelse return box.reject(@src(), .not_found, "no such track");
    defer details.deinit();
    const view = trackDetailsView(&details);
    const extra = trackDetailsExtraView(&details);
    visit(context, &view, &extra);
    return .ok;
}

pub export fn orca_library_track_details_v3(
    runtime: ?*Runtime,
    library: Handle,
    track_id: i64,
    context: ?*anyopaque,
    callback: ?TrackDetailsV3Callback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const found = box.runtime.libraryTrackDetails(importLibrary(library), track_id) catch |err|
        return box.fail(@src(), err);
    const details = found orelse return box.reject(@src(), .not_found, "no such track");
    defer details.deinit();
    const view = trackDetailsView(&details);
    const extra = trackDetailsExtraView(&details);
    const text: TrackDetailsTextView = .{
        .composer = stringView(details.composer orelse ""),
        .comment = stringView(details.comment orelse ""),
    };
    visit(context, &view, &extra, &text);
    return .ok;
}

fn trackDetailsExtraView(details: *const core.track_details.TrackDetails) TrackDetailsExtraView {
    return .{
        .track_total = details.track_total orelse 0,
        .disc_total = details.disc_total orelse 0,
        .added_at = details.added_at orelse 0,
        .modified_at = details.modified_at orelse 0,
        .has_track_total = @intFromBool(details.track_total != null),
        .has_disc_total = @intFromBool(details.disc_total != null),
        .has_added_at = @intFromBool(details.added_at != null),
        .has_modified_at = @intFromBool(details.modified_at != null),
        .track_total_inferred = @intFromBool(details.track_total_inferred),
        .explicit = exportExplicit(details.explicit),
    };
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

pub export fn orca_library_track_audio_features(
    runtime: ?*Runtime,
    library: Handle,
    track_id: i64,
    output: ?*AudioFeaturesView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const found = box.runtime.libraryTrackAudioFeatures(importLibrary(library), track_id) catch |err|
        return box.fail(@src(), err);
    const features = found orelse return box.reject(@src(), .not_found, "no audio features for this track");
    destination.* = .{
        .tempo_bpm = if (features.tempo) |tempo| tempo.bpm else 0,
        .tempo_confidence = if (features.tempo) |tempo| tempo.confidence else 0,
        .key_confidence = if (features.key) |key| key.confidence else 0,
        .onset_rate = features.onset_rate orelse 0,
        .centroid_hz = features.centroid_hz orelse 0,
        .energy = features.energy orelse 0,
        .key_pitch = if (features.key) |key| key.pitch else 0,
        .key_mode = if (features.key) |key| @backingInt(key.mode) else 0,
        .has_tempo = @intFromBool(features.tempo != null),
        .has_key = @intFromBool(features.key != null),
        .has_onset_rate = @intFromBool(features.onset_rate != null),
        .has_centroid = @intFromBool(features.centroid_hz != null),
        .has_energy = @intFromBool(features.energy != null),
    };
    return .ok;
}

pub fn importRadioSeedKind(value: u8) ?std.meta.Tag(discovery.Seed) {
    return std.enums.fromInt(std.meta.Tag(discovery.Seed), value);
}

pub fn importRadioFocusKind(value: u8) ?std.meta.Tag(discovery.Focus) {
    return std.enums.fromInt(std.meta.Tag(discovery.Focus), value);
}

fn importRadioSeed(seed: *const RadioSeedView) ?discovery.Seed {
    return switch (importRadioSeedKind(seed.kind) orelse return null) {
        .track => .{ .track = seed.id },
        .release => .{ .release = seed.id },
        .artist => .{ .artist = seed.id },
        .genre => .{ .genre = seed.id },
        .decade => .{ .decade = seed.id },
        .loved => .loved,
        .recent => .recent,
    };
}

fn importOptionalFlag(has: u8, value: u8) error{Invalid}!?bool {
    if (has > 1 or value > 1) return error.Invalid;
    return if (has == 1) value == 1 else null;
}

fn importRadioOptions(options: *const RadioOptionsView) ?discovery.RadioOptions {
    if (options.focus_count > discovery.max_focus or options.include_live > 1) return null;
    var result: discovery.RadioOptions = .{
        .explore = options.explore,
        .include_unplayed = importOptionalFlag(options.has_include_unplayed, options.include_unplayed) catch return null,
        .avoid_recent = importOptionalFlag(options.has_avoid_recent, options.avoid_recent) catch return null,
        .include_live = options.include_live == 1,
    };
    for (options.focus[0..options.focus_count], result.focus[0..options.focus_count]) |view, *focus| {
        focus.* = switch (importRadioFocusKind(view.kind) orelse return null) {
            .genre => .{ .genre = view.id },
            .decade => .{ .decade = view.id },
            .low_energy => .low_energy,
            .high_energy => .high_energy,
        };
    }
    return result;
}

fn exportRadioComponents(components: discovery.Components) RadioComponentsView {
    return .{
        .artist = components.artist,
        .genre = components.genre,
        .audio = components.audio,
        .co_listening = components.co_listening,
        .era = components.era,
        .taste = components.taste,
        .jitter = components.jitter,
    };
}

fn exportReasonPart(part: ?discovery.ReasonPart) ReasonPartView {
    const found = part orelse return .{ .a = 0, .b = 0, .kind = 0 };
    return .{ .a = found.a, .b = found.b, .kind = @backingInt(found.kind) };
}

pub export fn orca_library_radio_preview(
    runtime: ?*Runtime,
    library: Handle,
    seed: ?*const RadioSeedView,
    options: ?*const RadioOptionsView,
    session: ?*const RadioPreviewSessionView,
    limit: u32,
    context: ?*anyopaque,
    callback: ?RadioPreviewCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const seed_view = seed orelse return box.reject(@src(), .invalid_argument, "seed is null");
    const radio_seed = importRadioSeed(seed_view) orelse
        return box.reject(@src(), .invalid_argument, "seed kind must be a known orca_radio_seed_kind");
    var radio_options: discovery.RadioOptions = .{};
    if (options) |view| radio_options = importRadioOptions(view) orelse
        return box.reject(@src(), .invalid_argument, "options need at most 4 focus entries of known kinds and flags 0 or 1");
    var preview_session: core.runtime.RadioPreviewSession = .{};
    if (session) |view| {
        if (view.has_now > 1 or view.has_seed > 1)
            return box.reject(@src(), .invalid_argument, "session flags must be 0 or 1");
        if (view.has_now == 1) preview_session.now_s = view.now_s;
        if (view.has_seed == 1) preview_session.seed = view.seed;
    }
    if (limit > discovery.max_picks) return box.reject(@src(), .invalid_argument, "limit must be at most 512");
    var picks = box.runtime.libraryRadioPreview(importLibrary(library), box.runtime.allocator, radio_seed, radio_options, limit, preview_session) catch |err|
        return box.fail(@src(), err);
    defer picks.deinit();
    const views = box.runtime.allocator.alloc(RadioPickView, picks.items.len) catch |err|
        return box.fail(@src(), err);
    defer box.runtime.allocator.free(views);
    for (views, picks.items) |*view, pick| view.* = .{
        .track_id = pick.track_id,
        .recording_id = pick.recording_id,
        .artist_id = pick.artist_id orelse 0,
        .release_id = pick.release_id orelse 0,
        .score = pick.score,
        .components = exportRadioComponents(pick.components),
        .reasons = .{ exportReasonPart(pick.reason.first), exportReasonPart(pick.reason.second) },
        .reason_count = @as(u8, @intFromBool(pick.reason.first != null)) + @intFromBool(pick.reason.second != null),
        .has_artist_id = @intFromBool(pick.artist_id != null),
        .has_release_id = @intFromBool(pick.release_id != null),
        .never_played = @intFromBool(pick.never_played),
    };
    const preview: RadioPreviewView = .{
        .picks = views.ptr,
        .count = views.len,
        .weights = exportRadioComponents(picks.weights),
        .relaxed_recent = @intFromBool(picks.relaxed_recent),
    };
    visit(context, &preview);
    return .ok;
}

pub export fn orca_library_discovery_settings(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*DiscoverySettingsView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const settings = box.runtime.libraryDiscoverySettings(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    destination.* = .{
        .radio_continue = @intFromBool(settings.radio_continue),
        .include_unplayed = @intFromBool(settings.include_unplayed),
        .avoid_days = @backingInt(settings.avoid_days),
        .mix_count = @backingInt(settings.mix_count),
    };
    return .ok;
}

pub export fn orca_library_set_discovery_settings(
    runtime: ?*Runtime,
    library: Handle,
    settings: ?*const DiscoverySettingsView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const view = settings orelse return box.reject(@src(), .invalid_argument, "settings is null");
    const invalid = "radio_continue and include_unplayed must be 0 or 1, avoid_days 0, 1, 3 or 7, and mix_count 0, 4 or 6";
    if (view.radio_continue > 1 or view.include_unplayed > 1) return box.reject(@src(), .invalid_argument, invalid);
    const avoid_days = std.enums.fromInt(discovery.AvoidDays, view.avoid_days) orelse
        return box.reject(@src(), .invalid_argument, invalid);
    const mix_count = std.enums.fromInt(discovery.MixCount, view.mix_count) orelse
        return box.reject(@src(), .invalid_argument, invalid);
    box.runtime.setLibraryDiscoverySettings(importLibrary(library), .{
        .radio_continue = view.radio_continue == 1,
        .include_unplayed = view.include_unplayed == 1,
        .avoid_days = avoid_days,
        .mix_count = mix_count,
    }) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_start_daily_mixes(
    runtime: ?*Runtime,
    library: Handle,
    request: ?*const DailyMixesRequestView,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    const given = request orelse return box.reject(@src(), .invalid_argument, "request is null");
    if (given.force > 1) return box.reject(@src(), .invalid_argument, "force must be 0 or 1");
    const started = box.runtime.startDailyMixes(importLibrary(library), .{
        .now_s = given.now_s,
        .utc_offset_s = given.utc_offset_s,
        .force = given.force == 1,
    }) catch |err| return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
    return .ok;
}

pub export fn orca_library_daily_mixes(
    runtime: ?*Runtime,
    library: Handle,
    now_s: i64,
    utc_offset_s: i64,
    context: ?*anyopaque,
    callback: ?DailyMixesCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const snapshot = box.runtime.libraryDailyMixes(importLibrary(library), now_s, utc_offset_s) catch |err|
        return box.fail(@src(), err);
    var views: [daily_mixes.max_mixes]DailyMixView = undefined;
    for (views[0..snapshot.count], snapshot.items()) |*view, *mix| {
        view.* = .{
            .id = mix.id,
            .genre_id = mix.genre_id orelse 0,
            .name = stringView(mix.name()),
            .artists = @splat(.{ .id = 0, .name = stringView("") }),
            .cover_release_ids = @splat(0),
            .duration_ms = mix.duration_ms,
            .entry_count = mix.entry_count,
            .signals = mix.signals,
            .left_out_recent = mix.left_out.recent,
            .left_out_not_for_me = mix.left_out.not_for_me,
            .left_out_hated = mix.left_out.hated,
            .left_out_live = mix.left_out.live,
            .left_out_other_mix = mix.left_out.other_mix,
            .left_out_diversity = mix.left_out.diversity,
            .favorite_count = mix.makeup.favorite,
            .rarely_played_count = mix.makeup.rarely_played,
            .never_played_count = mix.makeup.never_played,
            .ordinal = mix.ordinal,
            .kind = @backingInt(mix.kind),
            .has_genre_id = @intFromBool(mix.genre_id != null),
            .artist_count = mix.artist_count,
            .cover_count = mix.cover_count,
            .decade = std.math.cast(u16, mix.decade orelse 0) orelse 0,
        };
        for (view.artists[0..mix.artist_count], mix.mixArtists()) |*artist_view, *artist|
            artist_view.* = .{ .id = artist.id, .name = stringView(artist.name()) };
        @memcpy(view.cover_release_ids[0..mix.cover_count], mix.coverReleases());
    }
    const result: DailyMixesView = .{
        .mixes = &views,
        .count = snapshot.count,
        .generated_at = snapshot.generated_at orelse 0,
        .local_day = snapshot.local_day orelse 0,
        .state = @backingInt(snapshot.state),
        .has_generated_at = @intFromBool(snapshot.generated_at != null),
        .has_local_day = @intFromBool(snapshot.local_day != null),
    };
    visit(context, &result);
    return .ok;
}

pub export fn orca_library_daily_mix_entries(
    runtime: ?*Runtime,
    library: Handle,
    mix_id: i64,
    context: ?*anyopaque,
    callback: ?DailyMixEntriesCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var entries: [daily_mixes.max_entries]daily_mixes.Entry = undefined;
    const count = box.runtime.libraryDailyMixEntries(importLibrary(library), mix_id, &entries) catch |err|
        return box.fail(@src(), err);
    var views: [daily_mixes.max_entries]DailyMixEntryView = undefined;
    for (views[0..count], entries[0..count]) |*view, entry| view.* = .{
        .track_id = entry.track_id,
        .recording_id = entry.recording_id,
        .duration_ms = entry.duration_ms orelse 0,
        .reasons = .{ exportReasonPart(entry.reason.first), exportReasonPart(entry.reason.second) },
        .reason_count = @as(u8, @intFromBool(entry.reason.first != null)) + @intFromBool(entry.reason.second != null),
        .has_duration = @intFromBool(entry.duration_ms != null),
    };
    const result: DailyMixEntriesView = .{ .entries = &views, .count = count };
    visit(context, &result);
    return .ok;
}

fn exportHomeTopArtist(artist: *const core.runtime.HomeTopArtist) HomeTopArtistView {
    return .{ .artist_id = artist.artist_id, .name = stringView(artist.name.slice()), .plays = artist.plays };
}

fn exportHomePlayedRelease(release: *const core.runtime.HomePlayedRelease) HomePlayedReleaseView {
    return .{
        .release_id = release.release_id,
        .title = stringView(release.title.slice()),
        .artist = stringView(release.artist.slice()),
        .last_played_at = release.last_played_at,
        .plays = release.plays,
    };
}

fn exportHomeTrack(track: *const core.runtime.HomeTrack) HomeTrackView {
    return .{
        .track_id = track.track_id,
        .artist_id = track.artist_id orelse 0,
        .release_id = track.release_id orelse 0,
        .title = stringView(track.title.slice()),
        .artist = stringView(track.artist.slice()),
        .release = stringView(track.release.slice()),
        .added_at = track.added_at,
        .plays = track.plays,
        .has_artist_id = @intFromBool(track.artist_id != null),
        .has_release_id = @intFromBool(track.release_id != null),
    };
}

fn exportHomeRelease(release: *const core.runtime.HomeRelease) HomeReleaseView {
    return .{
        .release_id = release.release_id,
        .title = stringView(release.title.slice()),
        .artist = stringView(release.artist.slice()),
        .year = release.year orelse 0,
        .release_class = @backingInt(release.release_class),
        .has_year = @intFromBool(release.year != null),
    };
}

fn exportAnniversary(anniversary: *const core.runtime.HomeAnniversary) AnniversaryView {
    return .{
        .release_id = anniversary.release_id,
        .title = stringView(anniversary.title.slice()),
        .artist = stringView(anniversary.artist.slice()),
        .year = anniversary.year,
        .years_ago = anniversary.years_ago,
        .day_offset = anniversary.day_offset,
        .round = @intFromBool(anniversary.round),
    };
}

pub export fn orca_library_listening_week(
    runtime: ?*Runtime,
    library: Handle,
    now_s: i64,
    utc_offset_s: i64,
    context: ?*anyopaque,
    callback: ?ListeningWeekCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const week = box.runtime.libraryListeningWeek(importLibrary(library), .{ .now_s = now_s, .utc_offset_s = utc_offset_s }) catch |err|
        return box.fail(@src(), err);
    const view: ListeningWeekView = .{
        .first_local_day = week.first_local_day,
        .day_listened_ms = week.day_listened_ms,
        .listened_ms = week.listened_ms,
        .previous_listened_ms = week.previous_listened_ms,
        .top_artist = if (week.top_artist) |*artist| exportHomeTopArtist(artist) else .{ .artist_id = 0, .name = stringView(""), .plays = 0 },
        .plays = week.plays,
        .artists = week.artists,
        .releases = week.releases,
        .previous_plays = week.previous_plays,
        .has_top_artist = @intFromBool(week.top_artist != null),
    };
    visit(context, &view);
    return .ok;
}

fn visitPlayedReleases(
    box: *RuntimeBox,
    found: anyerror!usize,
    releases: []const core.runtime.HomePlayedRelease,
    context: ?*anyopaque,
    visit: HomePlayedReleasesCallback,
    comptime src: std.builtin.SourceLocation,
) Status {
    const count = found catch |err| return box.fail(src, err);
    var views: [core.runtime.home_max_items]HomePlayedReleaseView = undefined;
    for (views[0..count], releases[0..count]) |*view, *release| view.* = exportHomePlayedRelease(release);
    const result: HomePlayedReleasesView = .{ .releases = &views, .count = count };
    visit(context, &result);
    return .ok;
}

pub export fn orca_library_recent_releases(
    runtime: ?*Runtime,
    library: Handle,
    now_s: i64,
    utc_offset_s: i64,
    context: ?*anyopaque,
    callback: ?HomePlayedReleasesCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var releases: [core.runtime.home_max_items]core.runtime.HomePlayedRelease = undefined;
    const found = box.runtime.libraryRecentReleases(importLibrary(library), .{ .now_s = now_s, .utc_offset_s = utc_offset_s }, &releases);
    return visitPlayedReleases(box, found, &releases, context, visit, @src());
}

pub export fn orca_library_rediscover(
    runtime: ?*Runtime,
    library: Handle,
    now_s: i64,
    utc_offset_s: i64,
    context: ?*anyopaque,
    callback: ?HomePlayedReleasesCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var releases: [core.runtime.home_max_items]core.runtime.HomePlayedRelease = undefined;
    const found = box.runtime.libraryRediscover(importLibrary(library), .{ .now_s = now_s, .utc_offset_s = utc_offset_s }, &releases);
    return visitPlayedReleases(box, found, &releases, context, visit, @src());
}

fn visitHomeTracks(
    box: *RuntimeBox,
    found: anyerror!usize,
    tracks: []const core.runtime.HomeTrack,
    context: ?*anyopaque,
    visit: HomeTracksCallback,
    comptime src: std.builtin.SourceLocation,
) Status {
    const count = found catch |err| return box.fail(src, err);
    var views: [core.runtime.home_max_items]HomeTrackView = undefined;
    for (views[0..count], tracks[0..count]) |*view, *track| view.* = exportHomeTrack(track);
    const result: HomeTracksView = .{ .tracks = &views, .count = count };
    visit(context, &result);
    return .ok;
}

pub export fn orca_library_never_played(
    runtime: ?*Runtime,
    library: Handle,
    context: ?*anyopaque,
    callback: ?HomeTracksCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var tracks: [core.runtime.home_max_items]core.runtime.HomeTrack = undefined;
    const found = box.runtime.libraryNeverPlayed(importLibrary(library), &tracks);
    return visitHomeTracks(box, found, &tracks, context, visit, @src());
}

pub export fn orca_library_deep_cuts(
    runtime: ?*Runtime,
    library: Handle,
    now_s: i64,
    utc_offset_s: i64,
    context: ?*anyopaque,
    callback: ?HomeTracksCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var tracks: [core.runtime.home_max_items]core.runtime.HomeTrack = undefined;
    const found = box.runtime.libraryDeepCuts(importLibrary(library), .{ .now_s = now_s, .utc_offset_s = utc_offset_s }, &tracks);
    return visitHomeTracks(box, found, &tracks, context, visit, @src());
}

pub export fn orca_library_unplayed_releases(
    runtime: ?*Runtime,
    library: Handle,
    now_s: i64,
    utc_offset_s: i64,
    context: ?*anyopaque,
    callback: ?HomeReleasesCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var releases: [core.runtime.home_max_items]core.runtime.HomeRelease = undefined;
    const count = box.runtime.libraryUnplayedReleases(importLibrary(library), .{ .now_s = now_s, .utc_offset_s = utc_offset_s }, &releases) catch |err|
        return box.fail(@src(), err);
    var views: [core.runtime.home_max_items]HomeReleaseView = undefined;
    for (views[0..count], releases[0..count]) |*view, *release| view.* = exportHomeRelease(release);
    const result: HomeReleasesView = .{ .releases = &views, .count = count };
    visit(context, &result);
    return .ok;
}

pub export fn orca_library_release_anniversaries(
    runtime: ?*Runtime,
    library: Handle,
    now_s: i64,
    utc_offset_s: i64,
    context: ?*anyopaque,
    callback: ?AnniversariesCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var anniversaries: [core.runtime.home_max_items]core.runtime.HomeAnniversary = undefined;
    const count = box.runtime.libraryReleaseAnniversaries(importLibrary(library), .{ .now_s = now_s, .utc_offset_s = utc_offset_s }, &anniversaries) catch |err|
        return box.fail(@src(), err);
    var views: [core.runtime.home_max_items]AnniversaryView = undefined;
    for (views[0..count], anniversaries[0..count]) |*view, *anniversary| view.* = exportAnniversary(anniversary);
    const result: AnniversariesView = .{ .anniversaries = &views, .count = count };
    visit(context, &result);
    return .ok;
}

pub export fn orca_library_top_artists(
    runtime: ?*Runtime,
    library: Handle,
    now_s: i64,
    utc_offset_s: i64,
    days: u32,
    context: ?*anyopaque,
    callback: ?HomeTopArtistsCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var artists: [core.runtime.home_max_items]core.runtime.HomeTopArtist = undefined;
    const count = box.runtime.libraryTopArtists(importLibrary(library), .{ .now_s = now_s, .utc_offset_s = utc_offset_s }, days, &artists) catch |err|
        return box.fail(@src(), err);
    var views: [core.runtime.home_max_items]HomeTopArtistView = undefined;
    for (views[0..count], artists[0..count]) |*view, *artist| view.* = exportHomeTopArtist(artist);
    const result: HomeTopArtistsView = .{ .artists = &views, .count = count };
    visit(context, &result);
    return .ok;
}

pub export fn orca_library_formats(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*HomeFormatsView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const formats = box.runtime.libraryFormats(importLibrary(library)) catch |err| return box.fail(@src(), err);
    destination.* = .{
        .releases = formats.releases,
        .tracks = formats.tracks,
        .duration_ms = formats.duration_ms,
        .flac = formats.flac,
        .alac = formats.alac,
        .mp3 = formats.mp3,
        .other = formats.other,
    };
    return .ok;
}

pub export fn orca_library_on_this_day(
    runtime: ?*Runtime,
    library: Handle,
    now_s: i64,
    utc_offset_s: i64,
    context: ?*anyopaque,
    callback: ?OnThisDayCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const day = box.runtime.libraryOnThisDay(importLibrary(library), .{ .now_s = now_s, .utc_offset_s = utc_offset_s }) catch |err|
        return box.fail(@src(), err);
    const view: OnThisDayView = .{
        .top_release = if (day.top_release) |*release| exportHomePlayedRelease(release) else .{
            .release_id = 0,
            .title = stringView(""),
            .artist = stringView(""),
            .last_played_at = 0,
            .plays = 0,
        },
        .added_this_week = day.added_this_week,
        .added_this_year = day.added_this_year,
        .tracks = day.tracks,
        .never_played_tracks = day.never_played_tracks,
        .never_played_percent = day.never_played_percent,
        .has_top_release = @intFromBool(day.top_release != null),
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_history_age(
    runtime: ?*Runtime,
    library: Handle,
    now_s: i64,
    utc_offset_s: i64,
    output: ?*HistoryAgeView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const age = box.runtime.libraryHistoryAge(importLibrary(library), .{ .now_s = now_s, .utc_offset_s = utc_offset_s }) catch |err|
        return box.fail(@src(), err);
    destination.* = .{
        .first_listen_at = age.first_listen_at orelse 0,
        .listen_days = age.listen_days,
        .has_first_listen_at = @intFromBool(age.first_listen_at != null),
        .recording_enabled = @intFromBool(age.recording_enabled),
    };
    return .ok;
}

pub export fn orca_library_not_for_me(runtime: ?*Runtime, library: Handle, track_id: i64, now_s: i64) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.libraryNotForMe(importLibrary(library), track_id, now_s) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_clear_not_for_me(runtime: ?*Runtime, library: Handle, track_id: i64) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.libraryClearNotForMe(importLibrary(library), track_id) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_reset_recommendations(runtime: ?*Runtime, library: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.libraryResetRecommendations(importLibrary(library)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_save_daily_mix(
    runtime: ?*Runtime,
    library: Handle,
    mix_id: i64,
    name: ?[*]const u8,
    name_length: usize,
    playlist_id: ?*i64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = playlist_id orelse return box.reject(@src(), .invalid_argument, "playlist_id is null");
    const text = stringInput(name, name_length) orelse
        return box.reject(@src(), .invalid_argument, "name is null and name_length is not zero");
    destination.* = box.runtime.librarySaveDailyMix(importLibrary(library), mix_id, text) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

fn exportRadioSeed(seed: discovery.Seed) RadioSeedView {
    const id: i64 = switch (seed) {
        .track, .release, .artist, .genre, .decade => |value| value,
        .loved, .recent => 0,
    };
    return .{ .id = id, .kind = @backingInt(std.meta.activeTag(seed)) };
}

fn exportRadioOptions(options: discovery.RadioOptions) RadioOptionsView {
    var view: RadioOptionsView = .{
        .focus = @splat(.{ .id = 0, .kind = 0 }),
        .focus_count = 0,
        .explore = options.explore,
        .has_include_unplayed = @intFromBool(options.include_unplayed != null),
        .include_unplayed = @intFromBool(options.include_unplayed orelse false),
        .has_avoid_recent = @intFromBool(options.avoid_recent != null),
        .avoid_recent = @intFromBool(options.avoid_recent orelse false),
        .include_live = @intFromBool(options.include_live),
    };
    for (options.focus) |entry| {
        const focus = entry orelse continue;
        const id: i64 = switch (focus) {
            .genre, .decade => |value| value,
            .low_energy, .high_energy => 0,
        };
        view.focus[view.focus_count] = .{ .id = id, .kind = @backingInt(std.meta.activeTag(focus)) };
        view.focus_count += 1;
    }
    return view;
}

pub export fn orca_player_start_radio(
    runtime: ?*Runtime,
    player: Handle,
    seed: ?*const RadioSeedView,
    options: ?*const RadioOptionsView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const seed_view = seed orelse return box.reject(@src(), .invalid_argument, "seed is null");
    const radio_seed = importRadioSeed(seed_view) orelse
        return box.reject(@src(), .invalid_argument, "seed kind must be a known orca_radio_seed_kind");
    var radio_options: discovery.RadioOptions = .{};
    if (options) |view| radio_options = importRadioOptions(view) orelse
        return box.reject(@src(), .invalid_argument, "options need at most 4 focus entries of known kinds and flags 0 or 1");
    const player_handle = importPlayer(player);
    const library = (box.runtime.playerLibrary(player_handle) catch |err|
        return box.fail(@src(), err)) orelse return box.reject(@src(), .invalid_state, "player has no library");
    box.runtime.playerStartRadio(player_handle, library, radio_seed, radio_options) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_stop_radio(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playerStopRadio(importPlayer(player)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_set_radio_options(
    runtime: ?*Runtime,
    player: Handle,
    options: ?*const RadioOptionsView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    var radio_options: discovery.RadioOptions = .{};
    if (options) |view| radio_options = importRadioOptions(view) orelse
        return box.reject(@src(), .invalid_argument, "options need at most 4 focus entries of known kinds and flags 0 or 1");
    box.runtime.playerSetRadioOptions(importPlayer(player), radio_options) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_radio_less_like_this(
    runtime: ?*Runtime,
    player: Handle,
    entry_id: u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playerRadioLessLikeThis(importPlayer(player), entry_id) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_radio_undo_feedback(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playerRadioUndoFeedback(importPlayer(player)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_radio_status(
    runtime: ?*Runtime,
    player: Handle,
    context: ?*anyopaque,
    callback: ?RadioStatusCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const status = (box.runtime.playerRadio(importPlayer(player)) catch |err|
        return box.fail(@src(), err)) orelse return .ok;
    const view: RadioStatusView = .{
        .library = exportLibraryHandle(status.library),
        .seed = exportRadioSeed(status.seed),
        .options = exportRadioOptions(status.options),
        .title = stringView(status.title()),
        .picks_added = status.counts.picks_added,
        .user_queued = status.counts.user_queued,
        .less_like_this = status.counts.less_like_this,
        .skips = status.counts.skips,
        .pending = status.pending,
        .state = @backingInt(status.state),
        .continued = @intFromBool(status.continued),
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_player_radio_picks(
    runtime: ?*Runtime,
    player: Handle,
    context: ?*anyopaque,
    callback: ?RadioQueuePicksCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var picks: [core.runtime.max_radio_reported_picks]core.runtime.RadioQueuePick = undefined;
    const count = box.runtime.playerRadioPicks(importPlayer(player), &picks) catch |err|
        return box.fail(@src(), err);
    var views: [core.runtime.max_radio_reported_picks]RadioQueuePickView = undefined;
    for (views[0..count], picks[0..count]) |*view, pick| view.* = .{
        .entry_id = pick.entry_id,
        .track_id = pick.track_id,
        .recording_id = pick.recording_id,
        .reasons = .{ exportReasonPart(pick.reason.first), exportReasonPart(pick.reason.second) },
        .position = pick.position,
        .reason_count = @as(u8, @intFromBool(pick.reason.first != null)) + @intFromBool(pick.reason.second != null),
    };
    const result: RadioQueuePicksView = .{ .picks = &views, .count = count };
    visit(context, &result);
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

pub export fn orca_library_set_listen_policy(runtime: ?*Runtime, library: Handle, policy: u8) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const value = importListenPolicy(policy) orelse
        return box.reject(@src(), .invalid_argument, "policy is not an orca_listen_policy");
    box.runtime.librarySetListenPolicy(importLibrary(library), value) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_listen_policy(runtime: ?*Runtime, library: Handle, output: ?*u8) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const policy = box.runtime.libraryListenPolicy(importLibrary(library)) catch |err| return box.fail(@src(), err);
    destination.* = exportListenPolicy(policy);
    return .ok;
}

pub export fn orca_library_set_listen_recording(runtime: ?*Runtime, library: Handle, enabled: u8) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    if (enabled > 1) return box.reject(@src(), .invalid_argument, "enabled must be 0 or 1");
    box.runtime.librarySetListenRecording(importLibrary(library), enabled == 1) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_listen_recording(runtime: ?*Runtime, library: Handle, output: ?*u8) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const enabled = box.runtime.libraryListenRecording(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    destination.* = @intFromBool(enabled);
    return .ok;
}

pub export fn orca_library_clear_listens(runtime: ?*Runtime, library: Handle, removed: ?*u64) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const count = box.runtime.libraryClearListens(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    if (removed) |destination| destination.* = count;
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

pub export fn orca_library_set_artist_love(
    runtime: ?*Runtime,
    library: Handle,
    artist_ids: ?[*]const i64,
    count: usize,
    loved: u8,
    output: ?*ChangeCount,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    if (loved > 1) return box.reject(@src(), .invalid_argument, "loved must be 0 or 1");
    const list = editIdSlice(artist_ids, count) orelse
        return box.reject(@src(), .invalid_argument, invalid_edit_ids);
    const change = box.runtime.librarySetArtistLove(importLibrary(library), list, loved == 1) catch |err|
        return box.fail(@src(), err);
    destination.* = .{ .updated = change.updated, .skipped = change.skipped };
    return .ok;
}

pub export fn orca_library_artist_loved(runtime: ?*Runtime, library: Handle, artist_id: i64, output: ?*u8) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const loved = box.runtime.libraryArtistLoved(importLibrary(library), artist_id) catch |err|
        return box.fail(@src(), err);
    destination.* = @intFromBool(loved);
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

pub export fn orca_library_analysis_coverage(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*AnalysisCoverageView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const coverage = box.runtime.libraryAnalysisCoverage(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    destination.* = .{
        .never_analyzed = coverage.never_analyzed,
        .outdated = coverage.outdated,
        .measurement_set = coverage.measurement_set,
        .missing = (if (coverage.missing.loudness_and_checks) measurement_loudness_and_checks else 0) |
            (if (coverage.missing.fingerprint) measurement_fingerprint else 0) |
            (if (coverage.missing.features) measurement_features else 0),
    };
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
        const view = playlistView(item);
        visit(context, &view);
    }
    return .ok;
}

fn playlistView(item: database.PlaylistSummary) PlaylistView {
    return .{
        .id = item.id,
        .duration_ms = item.duration_ms,
        .created_at = item.created_at,
        .updated_at = item.updated_at,
        .entries = item.entries,
        .available = item.available,
        .name = stringView(item.name),
    };
}

fn playlistFactsView(item: database.PlaylistSummary) PlaylistFactsView {
    return .{
        .description = stringView(item.description),
        .pinned = @intFromBool(item.pinned),
        .loved = @intFromBool(item.loved),
        .kind = @backingInt(item.kind),
        .creator = @backingInt(item.creator),
        .mixed_artists = @intFromBool(item.mixed_artists),
        .tag_count = @intCast(item.tags.len),
    };
}

const invalid_playlist_query = "query limit must be between 1 and 512, sort a known orca_playlist_sort, kind and creator known values, " ++
    "flags 0 or 1, and filter not null unless empty";

fn importPlaylistQuery(query: *const PlaylistQueryView) ?database.PlaylistQuery {
    if (query.limit == 0 or query.limit > max_page) return null;
    if (query.has_kind > 1 or query.pinned_only > 1 or query.has_creator > 1) return null;
    const filter = stringInput(query.filter.pointer, query.filter.length) orelse return null;
    const sort: database.PlaylistSort = switch (std.enums.fromInt(PlaylistSortKey, query.sort) orelse return null) {
        .name => .name,
        .recently_updated => .recently_updated,
        .created => .created,
        .entries => .entries,
    };
    return .{
        .filter = filter,
        .kind = if (query.has_kind == 1) std.enums.fromInt(database.PlaylistKind, query.kind) orelse return null else null,
        .pinned_only = query.pinned_only == 1,
        .created_by = if (query.has_creator == 1) std.enums.fromInt(database.PlaylistCreator, query.creator) orelse return null else null,
        .sort = sort,
        .limit = query.limit,
        .offset = query.offset,
    };
}

pub export fn orca_library_query_playlists_v2(
    runtime: ?*Runtime,
    library: Handle,
    query: ?*const PlaylistQueryView,
    context: ?*anyopaque,
    callback: ?PlaylistV2Callback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const request = importPlaylistQuery(query orelse
        return box.reject(@src(), .invalid_argument, "query is null")) orelse
        return box.reject(@src(), .invalid_argument, invalid_playlist_query);
    var page = box.runtime.libraryPlaylistPage(importLibrary(library), request) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view = playlistView(item);
        const facts = playlistFactsView(item);
        visit(context, &view, &facts);
    }
    return .ok;
}

pub export fn orca_library_playlist_count(
    runtime: ?*Runtime,
    library: Handle,
    query: ?*const PlaylistQueryView,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const request = importPlaylistQuery(query orelse
        return box.reject(@src(), .invalid_argument, "query is null")) orelse
        return box.reject(@src(), .invalid_argument, invalid_playlist_query);
    destination.* = box.runtime.libraryPlaylistCount(importLibrary(library), request) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_playlist_get(
    runtime: ?*Runtime,
    library: Handle,
    playlist_id: i64,
    context: ?*anyopaque,
    callback: ?PlaylistV2Callback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const item = box.runtime.libraryPlaylist(importLibrary(library), playlist_id) catch |err|
        return box.fail(@src(), err);
    defer item.deinit(box.runtime.allocator);
    const view = playlistView(item);
    const facts = playlistFactsView(item);
    visit(context, &view, &facts);
    return .ok;
}

pub export fn orca_library_playlist_tags(
    runtime: ?*Runtime,
    library: Handle,
    playlist_id: i64,
    context: ?*anyopaque,
    callback: ?StringCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const tags = box.runtime.libraryPlaylistTags(importLibrary(library), playlist_id) catch |err|
        return box.fail(@src(), err);
    defer {
        for (tags) |tag| box.runtime.allocator.free(tag);
        box.runtime.allocator.free(tags);
    }
    for (tags) |tag| {
        const view = stringView(tag);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_playlist_genres(
    runtime: ?*Runtime,
    library: Handle,
    playlist_id: i64,
    context: ?*anyopaque,
    callback: ?StringCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const item = box.runtime.libraryPlaylist(importLibrary(library), playlist_id) catch |err|
        return box.fail(@src(), err);
    defer item.deinit(box.runtime.allocator);
    for (item.top_genres) |genre| {
        const view = stringView(genre);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_update_playlist(
    runtime: ?*Runtime,
    library: Handle,
    playlist_id: i64,
    update: ?*const PlaylistUpdateView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const given = update orelse return box.reject(@src(), .invalid_argument, "update is null");
    if (given.has_description > 1 or given.has_pinned > 1 or given.pinned > 1 or
        given.has_loved > 1 or given.loved > 1 or given.has_tags > 1)
        return box.reject(@src(), .invalid_argument, "update flags must be 0 or 1");
    var change: database.PlaylistUpdate = .{};
    if (given.has_description == 1) change.description = stringInput(given.description.pointer, given.description.length) orelse
        return box.reject(@src(), .invalid_argument, "description is null and its length is not zero");
    if (given.has_pinned == 1) change.pinned = given.pinned == 1;
    if (given.has_loved == 1) change.loved = given.loved == 1;
    var tags: [database.max_playlist_tags][]const u8 = undefined;
    if (given.has_tags == 1) {
        if (given.tag_count > database.max_playlist_tags) return box.reject(@src(), .invalid_argument, "tag_count exceeds 8");
        if (given.tag_count != 0) {
            const views = given.tags orelse
                return box.reject(@src(), .invalid_argument, "tags is null and tag_count is not zero");
            for (tags[0..given.tag_count], views[0..given.tag_count]) |*tag, view| {
                tag.* = stringInput(view.pointer, view.length) orelse
                    return box.reject(@src(), .invalid_argument, "a tag is null and its length is not zero");
            }
        }
        change.tags = tags[0..given.tag_count];
    }
    box.runtime.libraryUpdatePlaylist(importLibrary(library), playlist_id, change) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_create_smart_playlist(
    runtime: ?*Runtime,
    library: Handle,
    name: ?[*]const u8,
    name_length: usize,
    rules: ?[*]const u8,
    rules_length: usize,
    playlist_id: ?*i64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = playlist_id orelse return box.reject(@src(), .invalid_argument, "playlist_id is null");
    const text = stringInput(name, name_length) orelse
        return box.reject(@src(), .invalid_argument, "name is null and name_length is not zero");
    const rules_json = stringInput(rules, rules_length) orelse
        return box.reject(@src(), .invalid_argument, "rules is null and rules_length is not zero");
    destination.* = box.runtime.libraryCreateSmartPlaylist(importLibrary(library), text, rules_json) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_set_smart_playlist_rules(
    runtime: ?*Runtime,
    library: Handle,
    playlist_id: i64,
    rules: ?[*]const u8,
    rules_length: usize,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const rules_json = stringInput(rules, rules_length) orelse
        return box.reject(@src(), .invalid_argument, "rules is null and rules_length is not zero");
    box.runtime.librarySetSmartPlaylistRules(importLibrary(library), playlist_id, rules_json) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_smart_playlist_rules(
    runtime: ?*Runtime,
    library: Handle,
    playlist_id: i64,
    context: ?*anyopaque,
    callback: ?StringCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const stored = box.runtime.librarySmartPlaylistRules(importLibrary(library), playlist_id) catch |err|
        return box.fail(@src(), err);
    const rules_json = stored orelse return box.reject(@src(), .invalid_state, "the playlist is not a smart playlist");
    defer box.runtime.allocator.free(rules_json);
    const view = stringView(rules_json);
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_smart_playlist_count(
    runtime: ?*Runtime,
    library: Handle,
    rules: ?[*]const u8,
    rules_length: usize,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const rules_json = stringInput(rules, rules_length) orelse
        return box.reject(@src(), .invalid_argument, "rules is null and rules_length is not zero");
    destination.* = box.runtime.librarySmartPlaylistCount(importLibrary(library), rules_json) catch |err|
        return box.fail(@src(), err);
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
        .artist => .{ .artist = id },
        .release_group => return box.reject(@src(), .unsupported, "release group covers are not in the C ABI"),
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
            .track, .release, .artist => |id| id,
            .release_group => return box.reject(@src(), .unsupported, "release group covers are not in the C ABI"),
        },
        .subject = exportArtworkSubject(result.subject).?,
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

pub export fn orca_library_start_lyrics(
    runtime: ?*Runtime,
    library: Handle,
    track_id: i64,
    flags: u8,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    if (flags & ~lyrics_fetch_flag != 0) return box.reject(@src(), .invalid_argument, "flags holds an unknown bit");
    const started = box.runtime.startTrackLyrics(importLibrary(library), track_id, .{
        .fetch = flags & lyrics_fetch_flag != 0,
    }) catch |err| return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
    return .ok;
}

pub export fn orca_job_lyrics_outcome(runtime: ?*Runtime, job_handle: Handle, output: ?*u8) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const outcome = box.runtime.jobLyricsOutcome(importJob(job_handle)) catch |err| return box.fail(@src(), err);
    destination.* = exportLyricsOutcome(outcome);
    return .ok;
}

pub export fn orca_job_lyrics(
    runtime: ?*Runtime,
    job_handle: Handle,
    context: ?*anyopaque,
    callback: ?LyricsCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const taken = box.runtime.jobTakeLyrics(importJob(job_handle)) catch |err| return box.fail(@src(), err);
    const lyrics = taken orelse return box.reject(@src(), .not_found, "the job holds no lyrics");
    defer lyrics.deinit();
    const lines = box.runtime.allocator.alloc(LyricsLineView, lyrics.lines.len) catch |err|
        return box.fail(@src(), err);
    defer box.runtime.allocator.free(lines);
    for (lines, lyrics.lines) |*line, source_line| line.* = .{
        .start_ms = if (source_line.start_ms) |start_ms| start_ms else -1,
        .text = stringView(source_line.text),
    };
    const view: LyricsView = .{
        .source = exportLyricsSource(lyrics.source),
        .kind = exportLyricsKind(lyrics.kind),
        .language = if (lyrics.language) |*code| stringView(code) else stringView(""),
        .lines = lines.ptr,
        .line_count = lines.len,
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_start_artist_info(
    runtime: ?*Runtime,
    library: Handle,
    artist_id: i64,
    options: ?*const ArtistInfoOptionsView,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    const given = options orelse return box.reject(@src(), .invalid_argument, "options is null");
    const language = stringInput(given.language.pointer, given.language.length) orelse
        return box.reject(@src(), .invalid_argument, "language is null with a nonzero length");
    if (given.force > 1 or given.offline > 1 or given.include_releases > 1)
        return box.reject(@src(), .invalid_argument, "force, offline and include_releases must be 0 or 1");
    const started = box.runtime.startArtistInfoFetch(importLibrary(library), artist_id, .{
        .language = if (language.len == 0) "en" else language,
        .force = given.force == 1,
        .offline = given.offline == 1,
        .include_releases = given.include_releases == 1,
    }) catch |err| return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
    return .ok;
}

pub export fn orca_job_artist_info_outcome(runtime: ?*Runtime, job_handle: Handle, output: ?*u8) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const outcome = box.runtime.jobArtistInfoOutcome(importJob(job_handle)) catch |err| return box.fail(@src(), err);
    destination.* = @backingInt(outcome);
    return .ok;
}

pub export fn orca_job_artist_info_stores(runtime: ?*Runtime, job_handle: Handle, output: ?*u32) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    destination.* = box.runtime.jobArtistInfoStores(importJob(job_handle)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_artist_info(
    runtime: ?*Runtime,
    library: Handle,
    artist_id: i64,
    context: ?*anyopaque,
    callback: ?ArtistInfoCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var found = (box.runtime.libraryArtistInfo(importLibrary(library), artist_id) catch |err|
        return box.fail(@src(), err)) orelse return box.reject(@src(), .not_found, "no info was fetched for the artist");
    defer found.deinit();
    const record = &found.record;
    const view: ArtistInfoView = .{
        .fetched_at = record.fetched_at,
        .begin_year = record.begin_year orelse 0,
        .end_year = record.end_year orelse 0,
        .has_begin_year = @intFromBool(record.begin_year != null),
        .has_end_year = @intFromBool(record.end_year != null),
        .ended = @intFromBool(record.ended),
        .has_photo = @intFromBool(record.photo_source != null),
        .photo_source = if (record.photo_source) |source| @backingInt(source) else 0,
        .has_biography = @intFromBool(record.biography != null),
        .outcome = record.outcome,
        .musicbrainz_artist_id = stringView(record.musicbrainz_artist_id orelse ""),
        .wikidata_id = stringView(record.wikidata_id orelse ""),
        .artist_type = stringView(record.artist_type orelse ""),
        .biography = stringView(record.biography orelse ""),
        .biography_url = stringView(record.biography_url orelse ""),
        .biography_licence = stringView(record.biography_licence orelse ""),
        .biography_language = stringView(record.biography_language orelse ""),
        .photo_url = stringView(record.photo_url orelse ""),
        .photo_licence = stringView(record.photo_licence orelse ""),
        .photo_licence_url = stringView(record.photo_licence_url orelse ""),
        .photo_credit = stringView(record.photo_credit orelse ""),
        .has_listeners = @intFromBool(record.listeners != null),
        .listeners = if (record.listeners) |count| std.math.cast(i64, count) orelse std.math.maxInt(i64) else 0,
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_related_artists(
    runtime: ?*Runtime,
    library: Handle,
    artist_id: i64,
    context: ?*anyopaque,
    callback: ?RelatedArtistsCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var related = box.runtime.libraryRelatedArtists(importLibrary(library), artist_id) catch |err|
        return box.fail(@src(), err);
    defer related.deinit();
    var views: [database.related_artists_max]RelatedArtistView = undefined;
    for (views[0..related.items.len], related.items) |*view, artist| view.* = .{
        .name = stringView(artist.name),
        .mbid = stringView(artist.mbid),
        .library_artist_id = artist.library_artist_id orelse 0,
        .has_library_artist_id = @intFromBool(artist.library_artist_id != null),
        .has_photo = @intFromBool(artist.has_photo),
        .score = artist.score,
    };
    visit(context, &views, related.items.len);
    return .ok;
}

pub export fn orca_library_related_artist_photo(
    runtime: ?*Runtime,
    library: Handle,
    musicbrainz_artist_id: ?[*]const u8,
    musicbrainz_artist_id_length: usize,
    context: ?*anyopaque,
    callback: ?ImageCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const mbid = stringInput(musicbrainz_artist_id, musicbrainz_artist_id_length) orelse
        return box.reject(@src(), .invalid_argument, "musicbrainz_artist_id is null with a nonzero length");
    const found = box.runtime.libraryRelatedArtistPhoto(importLibrary(library), mbid) catch |err|
        return box.fail(@src(), err);
    const image = found orelse return box.reject(@src(), .not_found, "the related artist has no photo");
    defer image.deinit();
    const view = imageView(image);
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_related_artist_photo_info(
    runtime: ?*Runtime,
    library: Handle,
    musicbrainz_artist_id: ?[*]const u8,
    musicbrainz_artist_id_length: usize,
    context: ?*anyopaque,
    callback: ?RelatedArtistPhotoInfoCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const mbid = stringInput(musicbrainz_artist_id, musicbrainz_artist_id_length) orelse
        return box.reject(@src(), .invalid_argument, "musicbrainz_artist_id is null with a nonzero length");
    var found = (box.runtime.libraryRelatedArtistPhotoInfo(importLibrary(library), mbid) catch |err|
        return box.fail(@src(), err)) orelse return box.reject(@src(), .not_found, "the related artist has no photo");
    defer found.deinit();
    const record = &found.record;
    const view: RelatedArtistPhotoInfoView = .{
        .fetched_at = record.fetched_at,
        .photo_source = @backingInt(record.source),
        .photo_url = stringView(record.url orelse ""),
        .photo_licence = stringView(record.licence orelse ""),
        .photo_licence_url = stringView(record.licence_url orelse ""),
        .photo_credit = stringView(record.credit orelse ""),
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_start_release_info(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    options: ?*const ReleaseInfoOptionsView,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    const given = options orelse return box.reject(@src(), .invalid_argument, "options is null");
    const language = stringInput(given.language.pointer, given.language.length) orelse
        return box.reject(@src(), .invalid_argument, "language is null with a nonzero length");
    if (given.force > 1 or given.offline > 1)
        return box.reject(@src(), .invalid_argument, "force and offline must be 0 or 1");
    const started = box.runtime.startReleaseInfoFetch(importLibrary(library), release_id, .{
        .language = if (language.len == 0) "en" else language,
        .force = given.force == 1,
        .offline = given.offline == 1,
    }) catch |err| return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
    return .ok;
}

pub export fn orca_job_release_info_outcome(runtime: ?*Runtime, job_handle: Handle, output: ?*u8) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const outcome = box.runtime.jobReleaseInfoOutcome(importJob(job_handle)) catch |err| return box.fail(@src(), err);
    destination.* = @backingInt(outcome);
    return .ok;
}

pub export fn orca_library_release_info(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    context: ?*anyopaque,
    callback: ?ReleaseInfoCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var found = (box.runtime.libraryReleaseInfo(importLibrary(library), release_id) catch |err|
        return box.fail(@src(), err)) orelse return box.reject(@src(), .not_found, "no info was fetched for the release");
    defer found.deinit();
    const record = &found.record;
    const view: ReleaseInfoView = .{
        .fetched_at = record.fetched_at,
        .has_description = @intFromBool(record.description != null),
        .description_source = if (record.description_source) |source| @backingInt(source) else 0,
        .outcome = record.outcome,
        .description = stringView(record.description orelse ""),
        .description_url = stringView(record.description_url orelse ""),
        .description_licence = stringView(record.description_licence orelse ""),
        .description_language = stringView(record.description_language orelse ""),
        .musicbrainz_release_id = stringView(record.musicbrainz_release_id orelse ""),
        .musicbrainz_release_group_id = stringView(record.musicbrainz_release_group_id orelse ""),
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_set_genre_fill(runtime: ?*Runtime, library: Handle, fill: ?*const GenreFillView) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const given = fill orelse return box.reject(@src(), .invalid_argument, "fill is null");
    if (given.musicbrainz > 1) return box.reject(@src(), .invalid_argument, "musicbrainz must be 0 or 1");
    box.runtime.setGenreFill(importLibrary(library), .{ .musicbrainz = given.musicbrainz == 1 }) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_genre_fill(runtime: ?*Runtime, library: Handle, output: ?*GenreFillView) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const fill = box.runtime.libraryGenreFill(importLibrary(library)) catch |err| return box.fail(@src(), err);
    destination.* = .{ .musicbrainz = @intFromBool(fill.musicbrainz) };
    return .ok;
}

pub export fn orca_library_start_genre_fill(
    runtime: ?*Runtime,
    library: Handle,
    options: ?*const GenreFillOptionsView,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    const given = options orelse return box.reject(@src(), .invalid_argument, "options is null");
    if (given.offline > 1) return box.reject(@src(), .invalid_argument, "offline must be 0 or 1");
    const started = box.runtime.startGenreFill(importLibrary(library), .{
        .limit = given.limit,
        .offline = given.offline == 1,
    }) catch |err| return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
    return .ok;
}

pub export fn orca_library_artist_photo(
    runtime: ?*Runtime,
    library: Handle,
    artist_id: i64,
    context: ?*anyopaque,
    callback: ?ImageCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const found = box.runtime.libraryArtistPhoto(importLibrary(library), artist_id) catch |err|
        return box.fail(@src(), err);
    const image = found orelse return box.reject(@src(), .not_found, "the artist has no photo");
    defer image.deinit();
    const view = imageView(image);
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_artist_links(
    runtime: ?*Runtime,
    library: Handle,
    artist_id: i64,
    context: ?*anyopaque,
    callback: ?ArtistLinksCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var links = box.runtime.libraryArtistLinks(importLibrary(library), artist_id) catch |err|
        return box.fail(@src(), err);
    defer links.deinit();
    var views: [database.artist_links_max]ArtistLinkView = undefined;
    for (views[0..links.items.len], links.items) |*view, link| view.* = .{
        .kind = @backingInt(link.kind),
        .url = stringView(link.url),
    };
    visit(context, &views, links.items.len);
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

pub export fn orca_job_tag_write_failure(
    runtime: ?*Runtime,
    job_handle: Handle,
    output: ?*TagWriteFailureView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const found = box.runtime.jobTagWriteFailure(importJob(job_handle)) catch |err| return box.fail(@src(), err);
    const failure = found orelse return box.reject(@src(), .not_found, "the job recorded no failure");
    const file = failure.file orelse core.runtime.TagWriteFailureFile{ .file_id = 0, .action_index = 0 };
    destination.* = .{
        .file_id = file.file_id,
        .action_index = file.action_index,
        .reason = exportTagWriteFailureReason(failure.reason),
    };
    return .ok;
}

pub export fn orca_library_discard_tag_write(runtime: ?*Runtime, library: Handle, plan_id: u64) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.discardTagWrite(importLibrary(library), plan_id) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_query_tag_write_genres(
    runtime: ?*Runtime,
    library: Handle,
    plan_id: u64,
    file_id: i64,
    context: ?*anyopaque,
    callback: ?TagWriteGenresCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const found = box.runtime.tagWriteGenres(importLibrary(library), plan_id, file_id) catch |err|
        return box.fail(@src(), err);
    const genres = found orelse return box.reject(@src(), .not_found, "the plan leaves the file's genres alone");
    var scratch: std.heap.ArenaAllocator = .init(box.runtime.allocator);
    defer scratch.deinit();
    const before = stringViews(scratch.allocator(), genres.before) catch |err| return box.fail(@src(), err);
    const after = stringViews(scratch.allocator(), genres.after) catch |err| return box.fail(@src(), err);
    const view: TagWriteGenresView = .{
        .file_id = file_id,
        .before = before.ptr,
        .before_count = before.len,
        .after = after.ptr,
        .after_count = after.len,
    };
    visit(context, &view);
    return .ok;
}

fn stringViews(allocator: std.mem.Allocator, values: []const []const u8) ![]const StringView {
    const views = try allocator.alloc(StringView, values.len);
    for (views, values) |*view, value| view.* = stringView(value);
    return views;
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

pub fn exportTagWriteGroupState(state: core.runtime.TagWriteGroupState) u8 {
    return switch (state) {
        .applied => 0,
        .undoing => 1,
        .undone => 2,
        .rolled_back => 3,
        .failed => 4,
        .needs_reconciliation => 5,
    };
}

pub fn exportTagWriteDiffSubject(subject: std.meta.Tag(core.runtime.TagWriteDiffSubject)) u8 {
    return switch (subject) {
        .field => 0,
        .genres => 1,
        .unknown => 2,
    };
}

fn tagWriteGroupView(group: *const core.runtime.TagWriteGroup) TagWriteGroupView {
    return .{
        .group_id = group.group_id,
        .written_at = group.written_at,
        .file_count = group.file_count,
        .state = exportTagWriteGroupState(group.state),
        .can_undo = @intFromBool(group.can_undo),
        .expired = @intFromBool(group.expired),
        .title = stringView(group.title.slice()),
    };
}

pub export fn orca_library_query_tag_write_groups(
    runtime: ?*Runtime,
    library: Handle,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?TagWriteGroupCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    const groups = box.runtime.libraryTagWriteGroupPage(importLibrary(library), box.runtime.allocator, limit, offset) catch |err|
        return box.fail(@src(), err);
    defer groups.deinit();
    for (groups.items) |*group| {
        const view = tagWriteGroupView(group);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_query_tag_write_group(
    runtime: ?*Runtime,
    library: Handle,
    group_id: u64,
    context: ?*anyopaque,
    callback: ?TagWriteGroupDetailCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const detail = box.runtime.libraryTagWriteGroup(importLibrary(library), box.runtime.allocator, box.io(), group_id) catch |err|
        return box.fail(@src(), err);
    defer detail.deinit();
    const diffs = box.runtime.allocator.alloc(TagWriteDiffView, detail.diffs.len) catch |err| return box.fail(@src(), err);
    defer box.runtime.allocator.free(diffs);
    for (diffs, detail.diffs) |*view, diff| view.* = .{
        .subject = exportTagWriteDiffSubject(diff.subject),
        .field = switch (diff.subject) {
            .field => |field| exportMetadataField(field),
            .genres, .unknown => 0,
        },
        .file = stringView(diff.file),
        .restores = stringView(diff.restores),
        .current = stringView(diff.current),
    };
    const view: TagWriteGroupDetailView = .{
        .group = tagWriteGroupView(&detail.group),
        .diffs = diffs.ptr,
        .diff_count = diffs.len,
        .more_files = detail.more_files,
        .field_count = detail.field_count,
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_export_tag_write_history(
    runtime: ?*Runtime,
    library: Handle,
    path: ?[*]const u8,
    path_length: usize,
    replace: u8,
    exported: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = exported orelse return box.reject(@src(), .invalid_argument, "exported is null");
    const file_path = stringInput(path, path_length) orelse
        return box.reject(@src(), .invalid_argument, "path is null and path_length is not zero");
    if (file_path.len == 0) return box.reject(@src(), .invalid_argument, "path is empty");
    if (replace > 1) return box.reject(@src(), .invalid_argument, "replace must be 0 or 1");
    const written = box.runtime.exportTagWriteHistory(importLibrary(library), box.io(), file_path, .{ .replace = replace == 1 }) catch |err| return switch (err) {
        error.FileNotFound => box.reject(@src(), .not_found, "the folder to export into does not exist"),
        error.PathAlreadyExists => box.reject(@src(), .invalid_state, "the file exists; pass replace to overwrite it"),
        else => box.fail(@src(), err),
    };
    destination.* = written.groups;
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
    destination.* = .{ .kind = @backingInt(EventKind.none), .payload = undefined };
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

pub const ProviderService = enum { listenbrainz, musicbrainz, acoustid, cover_art_archive, lrclib, wikidata, wikimedia_commons, wikipedia, listenbrainz_labs };

pub fn importProviderService(value: u8) ?ProviderService {
    return switch (value) {
        0 => .listenbrainz,
        1 => .musicbrainz,
        2 => .acoustid,
        3 => .cover_art_archive,
        4 => .lrclib,
        5 => .wikidata,
        6 => .wikimedia_commons,
        7 => .wikipedia,
        8 => .listenbrainz_labs,
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
    const service_text = try allocator.dupeSentinel(u8, service, 0);
    defer allocator.free(service_text);
    const account_text = try allocator.dupeSentinel(u8, account, 0);
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
        .lrclib => box.runtime.setLrclibServer(server),
        .wikidata => box.runtime.setWikidataServer(server),
        .wikimedia_commons => box.runtime.setWikimediaCommonsServer(server),
        .wikipedia => box.runtime.setWikipediaServer(server),
        .listenbrainz_labs => box.runtime.setListenBrainzLabsServer(server),
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

pub export fn orca_library_set_scrobbling(
    runtime: ?*Runtime,
    library: Handle,
    enabled: u8,
    offline: u8,
    now_playing: u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    if (enabled > 1) return box.reject(@src(), .invalid_argument, "enabled must be 0 or 1");
    if (offline > 1) return box.reject(@src(), .invalid_argument, "offline must be 0 or 1");
    if (now_playing > 1) return box.reject(@src(), .invalid_argument, "now_playing must be 0 or 1");
    box.runtime.librarySetScrobbling(importLibrary(library), enabled == 1, offline == 1, now_playing == 1) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub fn exportScrobblerState(state: core.runtime.ScrobblerState) u8 {
    return switch (state) {
        .disabled => 0,
        .idle => 1,
        .needs_token => 2,
        .validating => 3,
        .invalid_token => 4,
        .submitting => 5,
        .backing_off => 6,
        .rate_limited => 7,
        .offline => 8,
        .busy => 9,
    };
}

pub export fn orca_library_scrobbler_status(
    runtime: ?*Runtime,
    library: Handle,
    context: ?*anyopaque,
    callback: ?ScrobblerStatusCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const deliver = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const status = box.runtime.libraryScrobblerStatus(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    const view: ScrobblerStatusView = .{
        .next_attempt_at = status.next_attempt_at orelse 0,
        .blocked_until = status.blocked_until orelse 0,
        .pending = status.pending,
        .feedback_pending = status.feedback_pending,
        .delivered_total = status.delivered_total,
        .recorded_total = status.recorded_total,
        .dropped = status.dropped,
        .enabled = @intFromBool(status.enabled),
        .state = exportScrobblerState(status.state),
        .has_next_attempt_at = @intFromBool(status.next_attempt_at != null),
        .has_blocked_until = @intFromBool(status.blocked_until != null),
        .user_name = stringView(status.user_name.slice()),
        .last_error = stringView(status.last_error.slice()),
    };
    deliver(context, &view);
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
    destination.* = exportMatchStats(stats);
    return .ok;
}

pub export fn orca_job_match_stats_v2(
    runtime: ?*Runtime,
    job_handle: Handle,
    output: ?*MatchStatsViewV2,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const stats = box.runtime.jobMatchStats(importJob(job_handle)) catch |err| return box.fail(@src(), err);
    destination.* = .{ .base = exportMatchStats(stats), .releases_to_review = stats.releases_to_review };
    return .ok;
}

pub export fn orca_job_match_release(
    runtime: ?*Runtime,
    job_handle: Handle,
    release_id: ?*i64,
    has_release_id: ?*u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const release_destination = release_id orelse return box.reject(@src(), .invalid_argument, "release_id is null");
    const has_destination = has_release_id orelse return box.reject(@src(), .invalid_argument, "has_release_id is null");
    const release = box.runtime.jobMatchRelease(importJob(job_handle)) catch |err| return box.fail(@src(), err);
    release_destination.* = release orelse 0;
    has_destination.* = @intFromBool(release != null);
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

pub export fn orca_library_acoustid_submitted_count(runtime: ?*Runtime, library: Handle, output: ?*u64) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    destination.* = box.runtime.libraryAcoustIdSubmittedCount(importLibrary(library)) catch |err|
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
    destination.* = box.runtime.libraryApplyMatchedRelease(importLibrary(library), release_id, null) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_apply_matched_release_fields(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    fields: u32,
    values_written: ?*u32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = values_written orelse return box.reject(@src(), .invalid_argument, "values_written is null");
    const field_set = releaseFieldSet(fields) orelse return box.reject(@src(), .invalid_argument, "fields has a bit past ORCA_RELEASE_FIELD_TRACK_TITLES");
    destination.* = box.runtime.libraryApplyMatchedRelease(importLibrary(library), release_id, field_set) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

fn releaseFieldSet(bits: u32) ?database.ReleaseFieldSet {
    const field_count = @typeInfo(database.ReleaseField).@"enum".field_names.len;
    if (bits >> field_count != 0) return null;
    var set: database.ReleaseFieldSet = .empty;
    for (0..field_count) |index| {
        if (bits & (@as(u32, 1) << @intCast(index)) != 0) set.insert(importReleaseField(@intCast(index)) orelse return null);
    }
    return set;
}

fn optionalMbid(release_mbid: ?[*:0]const u8) ?[]const u8 {
    return if (release_mbid) |text| std.mem.span(text) else null;
}

pub export fn orca_library_query_release_matches(
    runtime: ?*Runtime,
    library: Handle,
    bucket: u8,
    confident_at: f32,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?ReleaseMatchCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const which = importReleaseMatchBucket(bucket) orelse
        return box.reject(@src(), .invalid_argument, "bucket is not an orca_release_match_bucket");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    const page = box.runtime.libraryReleaseMatchPage(importLibrary(library), box.runtime.allocator, which, confident_at, null, limit, offset) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view = releaseMatchView(item);
        visit(context, &view);
    }
    return .ok;
}

fn releaseMatchView(item: database.ReleaseMatchItem) ReleaseMatchView {
    const best = item.best;
    return .{
        .release_id = item.release_id,
        .track_count = item.track_count,
        .bucket = @backingInt(item.bucket),
        .has_best = @intFromBool(best != null),
        .has_candidate_track_count = @intFromBool(best != null and best.?.track_count != null),
        .from_tags = @intFromBool(item.from_tags),
        .title = stringView(item.title),
        .artist = stringView(item.artist),
        .release_mbid = stringView(if (best) |candidate| candidate.release_mbid else ""),
        .candidate_title = stringView(if (best) |candidate| candidate.title else ""),
        .candidate_date = stringView(if (best) |candidate| candidate.date orelse "" else ""),
        .candidate_track_count = if (best) |candidate| candidate.track_count orelse 0 else 0,
        .confidence = if (best) |candidate| candidate.confidence orelse 0 else 0,
    };
}

pub export fn orca_library_query_release_matches_v2(
    runtime: ?*Runtime,
    library: Handle,
    bucket: u8,
    confident_at: f32,
    filter: ?[*:0]const u8,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?ReleaseMatchV2Callback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const which = importReleaseMatchBucket(bucket) orelse
        return box.reject(@src(), .invalid_argument, "bucket is not an orca_release_match_bucket");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    const text: ?[]const u8 = if (filter) |value| std.mem.span(value) else null;
    const page = box.runtime.libraryReleaseMatchPage(importLibrary(library), box.runtime.allocator, which, confident_at, text, limit, offset) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view: ReleaseMatchViewV2 = .{
            .base = releaseMatchView(item),
            .placed = if (item.placement) |placement| placement.placed else 0,
            .needs_pairing = if (item.placement) |placement| placement.needs_pairing else 0,
            .has_placement = @intFromBool(item.placement != null),
            .candidate_unread = @intFromBool(item.best != null and item.best.?.unread()),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_release_match_counts(
    runtime: ?*Runtime,
    library: Handle,
    confident_at: f32,
    output: ?*ReleaseMatchCountsView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const counts = box.runtime.libraryReleaseMatchCounts(importLibrary(library), confident_at, null) catch |err|
        return box.fail(@src(), err);
    destination.* = .{ .confident = counts.confident, .needs_review = counts.needs_review, .unmatched = counts.unmatched };
    return .ok;
}

pub export fn orca_library_release_match_counts_v2(
    runtime: ?*Runtime,
    library: Handle,
    confident_at: f32,
    filter: ?[*:0]const u8,
    output: ?*ReleaseMatchCountsViewV2,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const text: ?[]const u8 = if (filter) |value| std.mem.span(value) else null;
    const counts = box.runtime.libraryReleaseMatchCounts(importLibrary(library), confident_at, text) catch |err|
        return box.fail(@src(), err);
    destination.* = .{
        .base = .{ .confident = counts.confident, .needs_review = counts.needs_review, .unmatched = counts.unmatched },
        .reviewed = counts.reviewed,
    };
    return .ok;
}

pub export fn orca_library_release_match_bucket(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    confident_at: f32,
    output: ?*u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const bucket = box.runtime.libraryReleaseMatchBucket(importLibrary(library), release_id, confident_at) catch |err|
        return box.fail(@src(), err);
    destination.* = exportReleaseMatchBucket(bucket);
    return .ok;
}

pub export fn orca_library_release_match_evidence(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    release_mbid: ?[*:0]const u8,
    context: ?*anyopaque,
    callback: ?MatchEvidenceCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const evidence = box.runtime.libraryReleaseMatchEvidence(importLibrary(library), release_id, optionalMbid(release_mbid)) catch |err|
        return box.fail(@src(), err);
    const view: MatchEvidenceView = .{
        .fingerprints_matched = evidence.fingerprints_matched,
        .tracks = evidence.tracks,
        .durations_within_1s = @intFromBool(evidence.durations_within_1s),
        .artist_agrees = @intFromBool(evidence.artist_agrees),
        .title_agrees = @intFromBool(evidence.title_agrees),
        .date_agrees = @intFromBool(evidence.date_agrees),
        .note = stringView(evidence.note.slice()),
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_release_match_diff(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    release_mbid: ?[*:0]const u8,
    context: ?*anyopaque,
    callback: ?ReleaseMatchDiffCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const allocator = box.runtime.allocator;
    const diff = box.runtime.libraryReleaseMatchDiff(importLibrary(library), allocator, release_id, optionalMbid(release_mbid)) catch |err|
        return box.fail(@src(), err);
    defer diff.deinit();
    const fields = allocator.alloc(ReleaseFieldDiffView, diff.fields.len) catch |err| return box.fail(@src(), err);
    defer allocator.free(fields);
    for (fields, diff.fields) |*view, field| view.* = .{
        .field = @backingInt(field.field),
        .differs = @intFromBool(field.differs),
        .local = stringView(field.local),
        .candidate = stringView(field.candidate),
    };
    const tracks = allocator.alloc(ReleaseTrackAlignmentView, diff.tracks.len) catch |err| return box.fail(@src(), err);
    defer allocator.free(tracks);
    for (tracks, diff.tracks) |*view, track| view.* = .{
        .track_id = track.track_id,
        .delta_ms = track.delta_ms orelse 0,
        .position = track.position,
        .has_delta_ms = @intFromBool(track.delta_ms != null),
        .fingerprint = @intFromBool(track.fingerprint),
        .differs = @intFromBool(track.differs),
        .local_title = stringView(track.local_title),
        .candidate_title = stringView(track.candidate_title),
        .local_artist = stringView(track.local_artist),
        .candidate_artist = stringView(track.candidate_artist),
    };
    const view: ReleaseMatchDiffView = .{
        .release_mbid = stringView(diff.release_mbid),
        .fields = fields.ptr,
        .field_count = fields.len,
        .tracks = tracks.ptr,
        .track_count = tracks.len,
        .aligned = diff.aligned,
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_dismiss_release_candidate(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    release_mbid: ?[*:0]const u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const mbid = release_mbid orelse return box.reject(@src(), .invalid_argument, "release_mbid is null");
    box.runtime.libraryDismissReleaseCandidate(importLibrary(library), release_id, std.mem.span(mbid)) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_release_alignment(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    release_mbid: ?[*:0]const u8,
    context: ?*anyopaque,
    callback: ?ReleaseAlignmentCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const allocator = box.runtime.allocator;
    const alignment = box.runtime.libraryReleaseAlignment(importLibrary(library), allocator, release_id, optionalMbid(release_mbid)) catch |err|
        return box.fail(@src(), err);
    defer alignment.deinit();
    const rows = allocator.alloc(ReleaseTrackPlacementView, alignment.rows.len) catch |err| return box.fail(@src(), err);
    defer allocator.free(rows);
    var counts: [4]u32 = @splat(0);
    for (rows, alignment.rows) |*view, row| {
        counts[@backingInt(row.status)] += 1;
        const evidence = row.evidence;
        view.* = .{
            .disc = row.disc,
            .position = row.position,
            .length_ms = row.length_ms orelse 0,
            .length_delta_ms = evidence.length_delta_ms orelse 0,
            .has_length_ms = @intFromBool(row.length_ms != null),
            .status = @backingInt(row.status),
            .recording_source = @backingInt(exportRecordingSource(evidence.recording_source)),
            .has_track = @intFromBool(row.track != null),
            .title_equal = @intFromBool(evidence.title_equal),
            .length_close = @intFromBool(evidence.length_close),
            .position_equal = @intFromBool(evidence.position_equal),
            .has_length_delta_ms = @intFromBool(evidence.length_delta_ms != null),
            .title = stringView(row.title),
            .artist_credit = stringView(row.artist_credit),
            .recording_mbid = stringView(row.recording_mbid),
            .release_track_mbid = stringView(row.release_track_mbid),
            .track = alignedTrackView(row.track),
        };
    }
    const not_on_release = allocator.alloc(AlignedTrackView, alignment.not_on_release.len) catch |err| return box.fail(@src(), err);
    defer allocator.free(not_on_release);
    for (not_on_release, alignment.not_on_release) |*view, track| view.* = alignedTrackView(track);
    const view: ReleaseAlignmentView = .{
        .release_id = alignment.release_id,
        .fetched_at = alignment.fetched_at,
        .medium_count = alignment.medium_count,
        .paired = counts[@backingInt(core.runtime.PlacementStatus.paired)],
        .automatic = counts[@backingInt(core.runtime.PlacementStatus.automatic)],
        .suggested = counts[@backingInt(core.runtime.PlacementStatus.suggested)],
        .not_in_files = counts[@backingInt(core.runtime.PlacementStatus.not_in_files)],
        .release_mbid = stringView(alignment.release_mbid),
        .title = stringView(alignment.title),
        .artist_credit = stringView(alignment.artist_credit),
        .release_date = stringView(alignment.release_date orelse ""),
        .release_group_mbid = stringView(alignment.release_group_mbid orelse ""),
        .rows = rows.ptr,
        .row_count = rows.len,
        .not_on_release = not_on_release.ptr,
        .not_on_release_count = not_on_release.len,
    };
    visit(context, &view);
    return .ok;
}

fn alignedTrackView(aligned: ?core.runtime.AlignedTrack) AlignedTrackView {
    const track = aligned orelse return .{
        .track_id = 0,
        .duration_ms = 0,
        .track_number = 0,
        .disc_number = 0,
        .has_duration_ms = 0,
        .has_track_number = 0,
        .has_disc_number = 0,
        .title = stringView(""),
    };
    return .{
        .track_id = track.track_id,
        .duration_ms = track.duration_ms orelse 0,
        .track_number = track.track_number orelse 0,
        .disc_number = track.disc_number orelse 0,
        .has_duration_ms = @intFromBool(track.duration_ms != null),
        .has_track_number = @intFromBool(track.track_number != null),
        .has_disc_number = @intFromBool(track.disc_number != null),
        .title = stringView(track.title),
    };
}

pub fn exportRecordingSource(source: ?core.runtime.RecordingSource) RecordingSource {
    const known = source orelse return .none;
    return switch (known) {
        .in_effect => .in_effect,
        .accepted_match => .accepted_match,
        .pending_match => .pending_match,
    };
}

pub export fn orca_library_pair_release_track(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    release_mbid: ?[*:0]const u8,
    track_id: i64,
    release_track_mbid: ?[*:0]const u8,
    origin: ?*u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const release_track = release_track_mbid orelse return box.reject(@src(), .invalid_argument, "release_track_mbid is null");
    const destination = origin orelse return box.reject(@src(), .invalid_argument, "origin is null");
    const paired = box.runtime.libraryPairReleaseTrack(importLibrary(library), release_id, optionalMbid(release_mbid), track_id, std.mem.span(release_track)) catch |err|
        return box.fail(@src(), err);
    destination.* = @backingInt(paired);
    return .ok;
}

pub export fn orca_library_unpair_release_track(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    track_id: i64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.libraryUnpairReleaseTrack(importLibrary(library), release_id, track_id) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_query_release_track_pairings(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    context: ?*anyopaque,
    callback: ?ReleaseTrackPairingCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var pairings = box.runtime.libraryReleaseTrackPairings(importLibrary(library), box.runtime.allocator, release_id) catch |err|
        return box.fail(@src(), err);
    defer pairings.deinit();
    for (pairings.items) |pairing| {
        const view: ReleaseTrackPairingView = .{
            .release_id = pairing.release_id,
            .track_id = pairing.track_id,
            .created_at = pairing.created_at,
            .disc = pairing.disc orelse 0,
            .position = pairing.position orelse 0,
            .origin = @backingInt(pairing.origin),
            .in_snapshot = @intFromBool(pairing.in_snapshot),
            .has_position = @intFromBool(pairing.disc != null and pairing.position != null),
            .release_mbid = stringView(pairing.release_mbid),
            .release_track_mbid = stringView(pairing.release_track_mbid),
            .recording_mbid = stringView(pairing.recording_mbid),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_apply_release(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    fields: u32,
    context: ?*anyopaque,
    callback: ?ReleaseApplyCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const field_set = releaseFieldSet(fields) orelse return box.reject(@src(), .invalid_argument, "fields has a bit past ORCA_RELEASE_FIELD_TRACK_TITLES");
    const allocator = box.runtime.allocator;
    const outcome = box.runtime.libraryApplyRelease(importLibrary(library), allocator, release_id, field_set) catch |err|
        return box.fail(@src(), err);
    defer outcome.deinit();
    const left_alone = allocator.alloc(LeftAloneTrackView, outcome.left_alone.len) catch |err| return box.fail(@src(), err);
    defer allocator.free(left_alone);
    for (left_alone, outcome.left_alone) |*view, track| view.* = .{
        .track_id = track.track_id,
        .reason = @backingInt(track.reason),
        .title = stringView(track.title),
    };
    const view: ReleaseApplyView = .{
        .reviewed_release_id = outcome.reviewed_release_id orelse 0,
        .values_written = outcome.values_written,
        .track_values = outcome.track_values,
        .release_values_only = outcome.release_values_only,
        .artist_ids_unknown = @intFromBool(outcome.artist_ids_unknown),
        .has_reviewed_release_id = @intFromBool(outcome.reviewed_release_id != null),
        .release_mbid = stringView(outcome.release_mbid),
        .left_alone = left_alone.ptr,
        .left_alone_count = left_alone.len,
    };
    visit(context, &view);
    return .ok;
}

pub export fn orca_library_mark_release_reviewed(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
    release_mbid: ?[*:0]const u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.libraryMarkReleaseReviewed(importLibrary(library), release_id, optionalMbid(release_mbid)) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_unmark_release_reviewed(
    runtime: ?*Runtime,
    library: Handle,
    release_id: i64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.libraryUnmarkReleaseReviewed(importLibrary(library), release_id) catch |err|
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

pub fn exportScanStage(stage: core.runtime.ScanStage) u8 {
    return switch (stage) {
        .discover => 0,
        .read_tags => 1,
        .done => 2,
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
        .folder => 11,
        .chosen => 12,
        .partial => 13,
    };
}

pub fn exportLyricsOutcome(outcome: core.runtime.LyricsOutcome) u8 {
    return switch (outcome) {
        .local => 0,
        .fetched => 1,
        .cached => 2,
        .cached_miss => 3,
        .not_found => 4,
        .no_metadata => 5,
        .refused => 6,
        .unavailable => 7,
        .busy => 8,
        .cancelled => 9,
        .not_requested => 10,
    };
}

pub fn exportLyricsSource(source: metadata.lyrics.Source) u8 {
    return switch (source) {
        .sidecar => 0,
        .embedded => 1,
        .lrclib => 2,
    };
}

pub fn exportLyricsKind(kind: metadata.lyrics.Kind) u8 {
    return switch (kind) {
        .synced => 0,
        .plain => 1,
        .instrumental => 2,
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
        .credential_unavailable => 8,
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

pub export fn orca_library_relocate_root(
    runtime: ?*Runtime,
    library: Handle,
    root_id: i64,
    path: ?[*:0]const u8,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const path_pointer = path orelse return box.reject(@src(), .invalid_argument, "path is null");
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    const started = box.runtime.libraryRelocateRoot(
        importLibrary(library),
        box.io(),
        root_id,
        std.mem.span(path_pointer),
    ) catch |err| return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
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
        const view = exportRoot(item);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_query_roots_v2(
    runtime: ?*Runtime,
    library: Handle,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?RootV2Callback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    var page = box.runtime.libraryRootPage(importLibrary(library), limit, offset) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view: RootViewV2 = .{
            .base = exportRoot(item),
            .track_count = item.track_count,
            .unavailable_tracks = item.unavailable_tracks,
            .available = @intFromBool(item.available),
        };
        visit(context, &view);
    }
    return .ok;
}

fn exportRoot(root: database.repository.LibraryRoot) RootView {
    return .{
        .id = root.id,
        .volume_id = root.volume_id,
        .enabled = @intFromBool(root.enabled),
        .path = stringView(root.path),
    };
}

pub export fn orca_library_missing_file_count(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    destination.* = box.runtime.libraryMissingFileCount(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_query_folder(
    runtime: ?*Runtime,
    library: Handle,
    root_id: i64,
    path: ?[*]const u8,
    path_length: usize,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?FolderEntryCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    const relative_path = stringInput(path, path_length) orelse
        return box.reject(@src(), .invalid_argument, "path is null and path_length is not zero");
    var page = box.runtime.libraryFolderPage(importLibrary(library), root_id, relative_path, limit, offset) catch |err|
        return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view: FolderEntryView = .{
            .track_id = item.track_id orelse 0,
            .file_id = item.file_id orelse 0,
            .total_duration_ms = item.total_duration_ms,
            .file_count = item.file_count,
            .track_count = item.track_count,
            .kind = exportFolderEntryKind(item.kind),
            .has_track_id = @intFromBool(item.track_id != null),
            .has_file_id = @intFromBool(item.file_id != null),
            .name = stringView(item.name),
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
        request.reprobe_all = value.reprobe_all != 0;
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

pub export fn orca_library_set_maintenance(
    runtime: ?*Runtime,
    library: Handle,
    options: ?*const MaintenanceOptions,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    var maintenance_options: core.runtime.MaintenanceOptions = .{ .enabled = false };
    if (options) |value| {
        maintenance_options.enabled = switch (value.enabled) {
            0 => false,
            1 => true,
            else => return box.reject(@src(), .invalid_argument, "enabled is not 0 or 1"),
        };
        if (value.interval_ms != 0) maintenance_options.interval_ms = value.interval_ms;
    }
    box.runtime.libraryMaintenance(importLibrary(library), maintenance_options) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_maintenance_status(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*MaintenanceStatus,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const status = box.runtime.libraryMaintenanceStatus(importLibrary(library)) catch |err|
        return box.fail(@src(), err);
    destination.* = exportMaintenanceStatus(status);
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

pub export fn orca_library_backfill_pending(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*BackfillPendingView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const availability = box.runtime.libraryAvailability(importLibrary(library), box.io()) catch |err|
        return box.fail(@src(), err);
    defer availability.deinit();
    const pending = box.runtime.libraryBackfillPending(importLibrary(library), &availability) catch |err|
        return box.fail(@src(), err);
    destination.* = .{ .files = pending.files, .covers = pending.covers };
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
        .state = @backingInt(snapshot.state),
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
    destination.* = exportScanStats(&stats);
    return .ok;
}

pub export fn orca_library_scan_stats_v2(
    runtime: ?*Runtime,
    job_handle: Handle,
    output: ?*ScanStatsV2,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const stats = box.runtime.jobScanStats(importJob(job_handle)) catch |err|
        return box.fail(@src(), err);
    destination.* = exportScanStatsV2(&stats);
    return .ok;
}

pub export fn orca_library_scan_stats_v3(
    runtime: ?*Runtime,
    job_handle: Handle,
    output: ?*ScanStatsV3,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const stats = box.runtime.jobScanStats(importJob(job_handle)) catch |err|
        return box.fail(@src(), err);
    destination.* = .{
        .base = exportScanStatsV2(&stats),
        .symlinks_skipped = stats.symlinks_skipped,
    };
    return .ok;
}

fn exportScanStatsV2(stats: *const core.runtime.ScanStats) ScanStatsV2 {
    return .{
        .base = exportScanStats(stats),
        .albums_found = stats.albums_found,
        .stage = exportScanStage(stats.stage),
        .current_path_length = stats.current_path.len,
        .current_path = stats.current_path.bytes,
    };
}

fn exportScanStats(stats: *const core.runtime.ScanStats) ScanStats {
    return .{
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
}

pub export fn orca_estimate_audio_files(
    runtime: ?*Runtime,
    path: ?[*:0]const u8,
    limit: u32,
    output: ?*FolderEstimate,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const path_pointer = path orelse return box.reject(@src(), .invalid_argument, "path is null");
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    var token: folder_estimate.CancellationToken = .{};
    const estimate = folder_estimate.estimateAudioFiles(
        box.io(),
        std.heap.c_allocator,
        std.mem.span(path_pointer),
        &token,
        if (limit == 0) folder_estimate.default_limit else limit,
    ) catch |err| return box.fail(@src(), err);
    destination.* = .{
        .audio_files = estimate.audio_files,
        .truncated = @intFromBool(estimate.truncated),
    };
    return .ok;
}

pub export fn orca_job_origin_get(
    runtime: ?*Runtime,
    job_handle: Handle,
    origin: ?*u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = origin orelse return box.reject(@src(), .invalid_argument, "origin is null");
    destination.* = exportJobOrigin(box.runtime.jobOrigin(importJob(job_handle)) catch |err|
        return box.fail(@src(), err));
    return .ok;
}

pub export fn orca_job_reconcile_root(
    runtime: ?*Runtime,
    job_handle: Handle,
    root_id: ?*i64,
    has_root_id: ?*u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const root_destination = root_id orelse return box.reject(@src(), .invalid_argument, "root_id is null");
    const has_destination = has_root_id orelse return box.reject(@src(), .invalid_argument, "has_root_id is null");
    const root = box.runtime.jobReconcileRoot(importJob(job_handle)) catch |err| return box.fail(@src(), err);
    root_destination.* = root orelse 0;
    has_destination.* = @intFromBool(root != null);
    return .ok;
}

pub export fn orca_job_details_get(
    runtime: ?*Runtime,
    job_handle: Handle,
    context: ?*anyopaque,
    callback: ?JobDetailsCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const snapshot = box.runtime.jobSnapshotSynced(importJob(job_handle)) catch |err|
        return box.fail(@src(), err);
    const details: JobDetails = .{
        .started_at = snapshot.started_at orelse 0,
        .estimated_remaining_ms = snapshot.estimated_remaining_ms orelse 0,
        .has_started_at = @intFromBool(snapshot.started_at != null),
        .paused = @intFromBool(snapshot.paused),
        .has_estimated_remaining_ms = @intFromBool(snapshot.estimated_remaining_ms != null),
        .current_item = stringView(snapshot.current_item.slice()),
        .detail = stringView(snapshot.detail.slice()),
    };
    visit(context, &details);
    return .ok;
}

pub export fn orca_job_pause(runtime: ?*Runtime, job_handle: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.pauseJob(importJob(job_handle)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_job_resume(runtime: ?*Runtime, job_handle: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.resumeJob(importJob(job_handle)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_pause_jobs(runtime: ?*Runtime, library: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.pauseAll(importLibrary(library)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_resume_jobs(runtime: ?*Runtime, library: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.resumeAll(importLibrary(library)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_library_jobs_paused(
    runtime: ?*Runtime,
    library: Handle,
    paused: ?*u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = paused orelse return box.reject(@src(), .invalid_argument, "paused is null");
    destination.* = @intFromBool(box.runtime.libraryJobsPaused(importLibrary(library)) catch |err|
        return box.fail(@src(), err));
    return .ok;
}

pub export fn orca_library_query_job_queue(
    runtime: ?*Runtime,
    library: Handle,
    context: ?*anyopaque,
    callback: ?QueuedJobCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const queued = box.runtime.jobQueuePage(importLibrary(library), box.runtime.allocator) catch |err|
        return box.fail(@src(), err);
    defer box.runtime.allocator.free(queued);
    for (queued) |entry| {
        const view: QueuedJobView = .{
            .job = exportJobHandle(entry.job),
            .after = if (entry.after) |after| exportJobHandle(after) else .{ .index = 0, .generation = 0 },
            .kind = exportJobKind(entry.kind),
            .has_after = @intFromBool(entry.after != null),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_query_job_history(
    runtime: ?*Runtime,
    library: Handle,
    filter: u8,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?JobHistoryCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const history_filter = importJobHistoryFilter(filter) orelse
        return box.reject(@src(), .invalid_argument, "filter is not an orca_job_history_filter");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    const entries = box.runtime.jobHistoryPage(
        importLibrary(library),
        box.runtime.allocator,
        history_filter,
        limit,
        offset,
    ) catch |err| return box.fail(@src(), err);
    defer box.runtime.allocator.free(entries);
    for (entries) |*entry| {
        const view: JobHistoryView = .{
            .id = entry.id,
            .started_at = entry.started_at,
            .finished_at = entry.finished_at,
            .completed_units = entry.completed_units,
            .total_units = entry.total_units orelse 0,
            .undo_group_id = entry.undo_group_id orelse 0,
            .kind = exportJobKind(entry.kind),
            .state = @backingInt(entry.state),
            .has_total = @intFromBool(entry.total_units != null),
            .has_undo_group_id = @intFromBool(entry.undo_group_id != null),
            .retryable = @intFromBool(entry.retryable),
            .error_text = stringView(entry.error_text.slice()),
            .summary = stringView(entry.summary.slice()),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_library_retry_job(
    runtime: ?*Runtime,
    library: Handle,
    history_id: i64,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = job_output orelse return box.reject(@src(), .invalid_argument, "job is null");
    const started = box.runtime.jobRetry(importLibrary(library), history_id) catch |err|
        return box.fail(@src(), err);
    destination.* = exportJobHandle(started);
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

pub export fn orca_player_play_folder(
    runtime: ?*Runtime,
    player: Handle,
    root_id: i64,
    path: ?[*]const u8,
    path_length: usize,
    shuffle: u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const player_handle = importPlayer(player);
    const library = (box.runtime.playerLibrary(player_handle) catch |err|
        return box.fail(@src(), err)) orelse return box.reject(@src(), .invalid_state, "player has no library");
    const relative_path = stringInput(path, path_length) orelse
        return box.reject(@src(), .invalid_argument, "path is null and path_length is not zero");
    box.runtime.playerPlayFolder(player_handle, library, box.io(), root_id, relative_path, shuffle != 0) catch |err|
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
        @fromBackingInt(@intCast(mode)),
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

/// An orca_replay_gain_mode value. Any other value is refused rather than
/// treated as one of those. Takes effect once the audio decoded ahead of the
/// listener drains.
pub export fn orca_player_set_replay_gain_mode(
    runtime: ?*Runtime,
    player: Handle,
    mode: u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const resolved = importReplayGainMode(mode) orelse
        return box.reject(@src(), .invalid_argument, "mode must be 0 to 3");
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
    destination.* = @backingInt(mode);
    return .ok;
}

pub export fn orca_player_set_replay_gain_preamp(
    runtime: ?*Runtime,
    player: Handle,
    decibels: f32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playerSetReplayGainPreamp(importPlayer(player), decibels) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_set_replay_gain_fallback(
    runtime: ?*Runtime,
    player: Handle,
    fallback: u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const resolved = importUntaggedFallback(fallback) orelse
        return box.reject(@src(), .invalid_argument, "fallback must be 0 or 1");
    box.runtime.playerSetReplayGainFallback(importPlayer(player), resolved) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_set_peak_protection(
    runtime: ?*Runtime,
    player: Handle,
    enabled: u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playerSetPeakProtection(importPlayer(player), enabled != 0) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_replay_gain_settings(
    runtime: ?*Runtime,
    player: Handle,
    output: ?*ReplayGainSettingsView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const settings = box.runtime.playerReplayGainSettings(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    destination.* = .{
        .preamp_db = settings.preamp_db,
        .mode = @backingInt(settings.mode),
        .fallback = exportUntaggedFallback(settings.fallback),
        .peak_protection = @intFromBool(settings.peak_protection),
    };
    return .ok;
}

pub export fn orca_player_set_stop_after_current(
    runtime: ?*Runtime,
    player: Handle,
    enabled: u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playerSetStopAfterCurrent(importPlayer(player), enabled != 0) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_stop_after_current(
    runtime: ?*Runtime,
    player: Handle,
    output: ?*u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const enabled = box.runtime.playerStopAfterCurrent(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    destination.* = @intFromBool(enabled);
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

pub export fn orca_player_signal_path_v2(
    runtime: ?*Runtime,
    player: Handle,
    context: ?*anyopaque,
    callback: ?SignalPathV2Callback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    const path = box.runtime.playerSignalPath(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    const view = exportSignalPathV2(&path);
    visit(context, &view);
    return .ok;
}

pub export fn orca_player_set_parametric_equalizer(
    runtime: ?*Runtime,
    player: Handle,
    equalizer: ?*const ParametricEqualizerView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const setting: ?audio.dsp.ParametricEqualizer = if (equalizer) |value|
        importParametricEqualizer(value) orelse
            return box.reject(@src(), .invalid_argument, "unknown filter kind or too many filters")
    else
        null;
    box.runtime.playerSetParametricEqualizer(importPlayer(player), setting) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_parametric_equalizer_get(
    runtime: ?*Runtime,
    player: Handle,
    output: ?*ParametricEqualizerView,
    has: ?*u8,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const has_destination = has orelse return box.reject(@src(), .invalid_argument, "has is null");
    const setting = box.runtime.playerParametricEqualizer(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    destination.* = if (setting) |*value| exportParametricEqualizer(value) else std.mem.zeroes(ParametricEqualizerView);
    has_destination.* = @intFromBool(setting != null);
    return .ok;
}

pub export fn orca_parametric_equalizer_response(
    equalizer: ?*const ParametricEqualizerView,
    sample_rate: u32,
    frequencies_hz: ?[*]const f32,
    gains_db: ?[*]f32,
    count: usize,
) callconv(.c) Status {
    const view = equalizer orelse return .invalid_argument;
    if (sample_rate == 0) return .invalid_argument;
    const setting = importParametricEqualizer(view) orelse return .invalid_argument;
    setting.validate() catch |err| return mapError(err);
    if (count == 0) return .ok;
    const frequencies = frequencies_hz orelse return .invalid_argument;
    const gains = gains_db orelse return .invalid_argument;
    setting.response(sample_rate, frequencies[0..count], gains[0..count]);
    return .ok;
}

pub export fn orca_parametric_equalizer_parse_apo(
    text: ?[*]const u8,
    length: usize,
    output: ?*ParametricEqualizerView,
) callconv(.c) Status {
    const destination = output orelse return .invalid_argument;
    const bytes: []const u8 = if (length == 0) "" else (text orelse return .invalid_argument)[0..length];
    const setting = audio.eq_text.parseEqualizerApo(bytes) catch |err| return mapError(err);
    destination.* = exportParametricEqualizer(&setting);
    return .ok;
}

pub export fn orca_parametric_equalizer_write_apo(
    equalizer: ?*const ParametricEqualizerView,
    buffer: ?[*]u8,
    capacity: usize,
    written: ?*usize,
) callconv(.c) Status {
    const view = equalizer orelse return .invalid_argument;
    const written_destination = written orelse return .invalid_argument;
    const setting = importParametricEqualizer(view) orelse return .invalid_argument;
    setting.validate() catch |err| return mapError(err);
    var scratch: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&scratch);
    audio.eq_text.writeEqualizerApo(&writer, setting) catch return .internal;
    const text = writer.buffered();
    written_destination.* = text.len;
    if (text.len > capacity) return .invalid_argument;
    const destination = buffer orelse return .invalid_argument;
    @memcpy(destination[0..text.len], text);
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
    destination.* = exportPlayerStatus(status);
    return .ok;
}

pub export fn orca_player_status_get_v2(
    runtime: ?*Runtime,
    player: Handle,
    output: ?*PlayerStatusV2,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const status = box.runtime.playerStatus(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    destination.* = exportPlayerStatusV2(status);
    return .ok;
}

pub export fn orca_player_status_get_v3(
    runtime: ?*Runtime,
    player: Handle,
    output: ?*PlayerStatusV3,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = output orelse return box.reject(@src(), .invalid_argument, "output is null");
    const status = box.runtime.playerStatus(importPlayer(player)) catch |err|
        return box.fail(@src(), err);
    destination.* = .{
        .base = exportPlayerStatusV2(status),
        .resumed_from_ms = status.resumed_from_ms orelse 0,
        .has_resumed = @intFromBool(status.resumed_from_ms != null),
    };
    return .ok;
}

fn exportPlayerStatusV2(status: core.runtime.PlayerStatus) PlayerStatusV2 {
    return .{
        .base = exportPlayerStatus(status),
        .failure_track_id = if (status.last_failure) |failure| failure.track_id else 0,
        .has_failure = @intFromBool(status.last_failure != null),
        .failure_reason = if (status.last_failure) |failure| exportPlaybackFailureReason(failure.reason) else 0,
    };
}

pub fn exportPlaybackFailureReason(reason: core.runtime.PlaybackFailure.Reason) u8 {
    return switch (reason) {
        .file_missing => 0,
        .folder_unavailable => 1,
        .codec_unavailable => 2,
        .decode_error => 3,
        .unsupported_channels => 4,
    };
}

fn exportPlayerStatus(status: core.runtime.PlayerStatus) PlayerStatus {
    return .{
        .transport = @backingInt(status.transport),
        .repeat = @backingInt(status.repeat),
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
        const view = if (item.track) |track| trackView(track) else removedTrackView(item.id);
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_player_query_queue_history(
    runtime: ?*Runtime,
    player: Handle,
    limit: u32,
    offset: u32,
    context: ?*anyopaque,
    callback: ?QueueHistoryCallback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    if (limit == 0 or limit > max_page) return box.reject(@src(), .invalid_argument, "limit must be between 1 and 512");
    var page = box.runtime.playerQueueHistoryTracks(
        importPlayer(player),
        box.runtime.allocator,
        offset,
        limit,
    ) catch |err| return box.fail(@src(), err);
    defer page.deinit();
    for (page.items) |item| {
        const view: TrackSummaryView = if (item.track) |track|
            trackSummaryView(track)
        else
            .{
                .track = removedTrackView(item.id),
                .release_id = 0,
                .artist_id = 0,
                .recording_id = 0,
                .has_release_id = 0,
                .has_artist_id = 0,
                .has_recording_id = 0,
            };
        visit(context, &view, item.ended_at_ms, @backingInt(item.reason));
    }
    return .ok;
}

pub export fn orca_player_clear_queue_history(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playerClearQueueHistory(importPlayer(player)) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_save_queue_as_playlist(
    runtime: ?*Runtime,
    player: Handle,
    name: ?[*]const u8,
    name_length: usize,
    playlist_id: ?*i64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const destination = playlist_id orelse return box.reject(@src(), .invalid_argument, "playlist_id is null");
    const text = stringInput(name, name_length) orelse
        return box.reject(@src(), .invalid_argument, "name is null and name_length is not zero");
    const player_handle = importPlayer(player);
    const library = (box.runtime.playerLibrary(player_handle) catch |err|
        return box.fail(@src(), err)) orelse return box.reject(@src(), .invalid_state, "player has no library");
    destination.* = box.runtime.playerSaveQueueAsPlaylist(player_handle, library, text) catch |err|
        return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_save_state(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const player_handle = importPlayer(player);
    const library = (box.runtime.playerLibrary(player_handle) catch |err|
        return box.fail(@src(), err)) orelse return box.reject(@src(), .invalid_state, "player has no library");
    box.runtime.playerSaveState(player_handle, library) catch |err| return box.fail(@src(), err);
    return .ok;
}

pub export fn orca_player_restore_state(
    runtime: ?*Runtime,
    player: Handle,
    mode: u8,
    outcome: ?*RestoreOutcomeView,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const restore_mode = std.enums.fromInt(core.runtime.RestoreMode, mode) orelse
        return box.reject(@src(), .invalid_argument, "mode must be 0, 1 or 2");
    const player_handle = importPlayer(player);
    const library = (box.runtime.playerLibrary(player_handle) catch |err|
        return box.fail(@src(), err)) orelse return box.reject(@src(), .invalid_state, "player has no library");
    const restored = box.runtime.playerRestoreState(player_handle, library, restore_mode) catch |err|
        return box.fail(@src(), err);
    if (outcome) |destination| destination.* = .{
        .entries = restored.entries,
        .index = restored.index,
        .position_ms = restored.position_ms,
        .skipped_missing = restored.skipped_missing,
    };
    return .ok;
}

pub export fn orca_player_set_long_track_memory(
    runtime: ?*Runtime,
    player: Handle,
    enabled: u8,
    threshold_ms: u64,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playerSetLongTrackMemory(
        importPlayer(player),
        if (enabled != 0) threshold_ms else null,
    ) catch |err| return box.fail(@src(), err);
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

pub export fn orca_player_queue_move(
    runtime: ?*Runtime,
    player: Handle,
    from: u32,
    to: u32,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    box.runtime.playerQueueMove(importPlayer(player), from, to) catch |err|
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
    const count = box.runtime.enumerateOutputDevices(&devices, .identity) catch |err|
        return box.fail(@src(), err);
    for (devices[0..count]) |*device| {
        const view: DeviceView = .{ .id = device.id, .name = stringView(device.nameSlice()) };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_enumerate_output_devices_v2(
    runtime: ?*Runtime,
    context: ?*anyopaque,
    callback: ?DeviceV2Callback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var devices: [max_devices]audio.backend.Device = undefined;
    const count = box.runtime.enumerateOutputDevices(&devices, .identity) catch |err|
        return box.fail(@src(), err);
    for (devices[0..count]) |*device| {
        const view: DeviceViewV2 = .{
            .base = .{ .id = device.id, .name = stringView(device.nameSlice()) },
            .kind = exportDeviceKind(device.kind),
        };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_enumerate_output_devices_v3(
    runtime: ?*Runtime,
    context: ?*anyopaque,
    callback: ?DeviceV3Callback,
) callconv(.c) Status {
    const box = enter(runtime) orelse return refusal(runtime);
    const visit = callback orelse return box.reject(@src(), .invalid_argument, "callback is null");
    var devices: [max_devices]audio.backend.Device = undefined;
    const count = box.runtime.enumerateOutputDevices(&devices, .capabilities) catch |err|
        return box.fail(@src(), err);
    for (devices[0..count]) |*device| {
        var view: DeviceViewV3 = .{
            .base = .{
                .base = .{ .id = device.id, .name = stringView(device.nameSlice()) },
                .kind = exportDeviceKind(device.kind),
            },
            .has_capabilities = 0,
            .state = 0,
            .bit_depths = 0,
            .channels_max = 0,
            .rate_min_hz = 0,
            .rate_max_hz = 0,
        };
        if (device.capabilities) |capabilities| {
            view.has_capabilities = 1;
            view.state = exportDeviceState(capabilities.state);
            view.bit_depths = capabilities.bit_depths;
            view.channels_max = capabilities.channels_max;
            view.rate_min_hz = capabilities.rate_min;
            view.rate_max_hz = capabilities.rate_max;
        }
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
        .output_state = @backingInt(stats.output_state),
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
        2 => .artist,
        else => null,
    };
}

pub fn exportArtworkSubject(subject: core.runtime.ArtworkSubject) ?u8 {
    return switch (subject) {
        .track => 0,
        .release => 1,
        .artist => 2,
        .release_group => null,
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
    return .{
        .artist_id = optionalId(query.artist_id),
        .release_id = optionalId(query.release_id),
        .sort = importTrackSort(query.sort) orelse return null,
        .loved_only = query.loved_only != 0,
        .direction = if (query.descending != 0) .descending else .ascending,
        .limit = query.limit,
        .offset = query.offset,
    };
}

const invalid_track_query_v2 = "query limit must be between 1 and 512, sort a known orca_track_sort, format a known orca_track_format and text not null unless empty";

fn importTrackQueryV2(query: *const TrackQueryV2View) ?database.TrackQuery {
    if (query.limit == 0 or query.limit > max_page) return null;
    _ = stringInput(query.text.pointer, query.text.length) orelse return null;
    return .{
        .artist_id = if (query.has_artist_id != 0) query.artist_id else null,
        .release_id = if (query.has_release_id != 0) query.release_id else null,
        .genre_id = if (query.has_genre_id != 0) query.genre_id else null,
        .sort = importTrackSort(query.sort) orelse return null,
        .loved_only = query.loved_only != 0,
        .year_min = if (query.has_year_min != 0) query.year_min else null,
        .year_max = if (query.has_year_max != 0) query.year_max else null,
        .lossless = switch (importTrackFormatFilter(query.format) orelse return null) {
            .any => null,
            .lossless => true,
            .lossy => false,
        },
        .min_sample_rate = if (query.min_sample_rate != 0) query.min_sample_rate else null,
        .explicit_only = query.explicit_only != 0,
        .direction = if (query.descending != 0) .descending else .ascending,
        .limit = query.limit,
        .offset = query.offset,
    };
}

pub fn importTrackFormatFilter(value: u8) ?TrackFormatFilter {
    return std.enums.fromInt(TrackFormatFilter, value);
}

fn importTrackSort(sort: u8) ?database.TrackSort {
    const key = std.enums.fromInt(TrackSortKey, sort) orelse return null;
    return switch (key) {
        .id => .id,
        .artist => .artist,
        .album => .album,
        .title => .title,
        .track_number => .track_number,
        .duration => .duration,
        .date_added => .date_added,
        .rating => .rating,
        .loved => .loved,
        .play_count => .play_count,
        .last_played => .last_played,
        .year => .year,
    };
}

pub fn exportSearchKind(kind: database.SearchKind) u8 {
    return @backingInt(kind);
}

pub fn exportFolderEntryKind(kind: database.FolderEntryKind) u8 {
    return @backingInt(kind);
}

pub fn exportExplicit(advisory: metadata.Explicit) u8 {
    return @backingInt(advisory);
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
        5 => .most_played,
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

const invalid_release_query_v2 = "query limit must be between 1 and 512, sort a known orca_release_sort, artwork a known orca_release_artwork, kind a known orca_release_kind and text not null unless empty";

fn importReleaseQueryV2(query: *const ReleaseQueryV2View) ?database.ReleaseQuery {
    if (query.limit == 0 or query.limit > max_page) return null;
    return .{
        .album_artist_id = if (query.has_album_artist_id != 0) query.album_artist_id else null,
        .own_releases_only = query.own_releases_only != 0,
        .appearing_artist_id = if (query.has_appearing_artist_id != 0) query.appearing_artist_id else null,
        .release_kind = switch (importReleaseKindFilter(query.kind) orelse return null) {
            .any => null,
            .album => .album,
            .ep_or_single => .ep_or_single,
            .other => .other,
        },
        .genre_id = if (query.has_genre_id != 0) query.genre_id else null,
        .sort = importReleaseSort(query.sort) orelse return null,
        .loved_only = query.loved_only != 0,
        .high_resolution_only = query.high_resolution_only != 0,
        .needs_review_only = query.needs_review_only != 0,
        .lossless_only = query.lossless_only != 0,
        .year_min = if (query.has_year_min != 0) query.year_min else null,
        .year_max = if (query.has_year_max != 0) query.year_max else null,
        .has_artwork = switch (importReleaseArtworkFilter(query.artwork) orelse return null) {
            .any => null,
            .present => true,
            .absent => false,
        },
        .text = stringInput(query.text.pointer, query.text.length) orelse return null,
        .limit = query.limit,
        .offset = query.offset,
    };
}

pub fn importReleaseArtworkFilter(value: u8) ?ReleaseArtworkFilter {
    return std.enums.fromInt(ReleaseArtworkFilter, value);
}

pub fn importReleaseKindFilter(value: u8) ?ReleaseKindFilter {
    return std.enums.fromInt(ReleaseKindFilter, value);
}

fn importSearchLimits(limits: ?*const SearchLimitsView) database.SearchLimits {
    const view = limits orelse return .{};
    return .{
        .artists = view.artists,
        .releases = view.releases,
        .tracks = view.tracks,
        .playlists = view.playlists,
        .genres = view.genres,
    };
}

const invalid_artist_query_v2 = "query limit must be between 1 and 512, sort a known orca_artist_sort, loved_only 0 or 1, and filter not null unless empty";

fn importArtistQueryV2(query: *const ArtistQueryV2View) ?database.ArtistQuery {
    if (query.limit == 0 or query.limit > max_page) return null;
    const filter = stringInput(query.filter.pointer, query.filter.length) orelse return null;
    const sort: database.ArtistSort = switch (std.enums.fromInt(ArtistSortKey, query.sort) orelse return null) {
        .name => .name,
        .track_count => .track_count,
        .recently_loved => .recently_loved,
        .recently_added => .recently_added,
    };
    if (query.loved_only > 1) return null;
    return .{
        .filter = filter,
        .genre_id = if (query.has_genre_id != 0) query.genre_id else null,
        .loved_only = query.loved_only == 1,
        .sort = sort,
        .limit = query.limit,
        .offset = query.offset,
    };
}

const invalid_genre_query = "query limit must be between 1 and 512, sort a known orca_genre_sort, and filter not null unless empty";

fn importGenreQuery(query: *const GenreQueryView) ?database.GenreQuery {
    if (query.limit == 0 or query.limit > max_page) return null;
    const filter = stringInput(query.filter.pointer, query.filter.length) orelse return null;
    const sort: database.GenreSort = switch (std.enums.fromInt(GenreSortKey, query.sort) orelse return null) {
        .name => .name,
        .track_count => .track_count,
    };
    return .{ .filter = filter, .sort = sort, .limit = query.limit, .offset = query.offset };
}

fn genreView(item: database.GenreSummary) GenreView {
    return .{
        .id = item.id,
        .total_duration_ms = item.total_duration_ms,
        .track_count = item.track_count,
        .release_count = item.release_count,
        .artist_count = item.artist_count,
        .name = stringView(item.name),
    };
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
        .explicit = exportExplicit(item.explicit),
        .title = stringView(item.title),
        .album_artist = stringView(item.album_artist),
        .release_date = stringView(item.release_date orelse ""),
    };
}

fn releaseFactsView(item: database.ReleaseSummary) ReleaseFactsView {
    return .{
        .codec = stringView(item.codec),
        .release_type = stringView(item.release_type orelse ""),
        .max_sample_rate = item.max_sample_rate orelse 0,
        .max_bit_depth = item.max_bit_depth orelse 0,
        .pending_reviews = item.pending_reviews,
        .lossless = @intFromBool(item.lossless),
    };
}

fn trackSummaryView(item: database.TrackSummary) TrackSummaryView {
    return .{
        .track = trackView(item),
        .release_id = item.release_id orelse 0,
        .artist_id = item.artist_id orelse 0,
        .recording_id = item.recording_id orelse 0,
        .has_release_id = @intFromBool(item.release_id != null),
        .has_artist_id = @intFromBool(item.artist_id != null),
        .has_recording_id = @intFromBool(item.recording_id != null),
    };
}

fn trackFactsView(item: database.TrackSummary) TrackFactsView {
    return .{
        .codec = stringView(item.codec),
        .added_at = item.added_at orelse 0,
        .last_played_at = item.last_played_at orelse 0,
        .play_count = item.play_count,
        .track_total = item.track_total orelse 0,
        .disc_total = item.disc_total orelse 0,
        .sample_rate = item.sample_rate orelse 0,
        .bit_depth = item.bit_depth orelse 0,
        .year = item.year orelse 0,
        .lossy = @intFromBool(item.lossy),
        .explicit = exportExplicit(item.explicit),
        .has_added_at = @intFromBool(item.added_at != null),
        .has_last_played_at = @intFromBool(item.last_played_at != null),
        .has_track_total = @intFromBool(item.track_total != null),
        .has_disc_total = @intFromBool(item.disc_total != null),
        .has_year = @intFromBool(item.year != null),
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

fn removedTrackView(track_id: i64) TrackView {
    var view = std.mem.zeroes(TrackView);
    view.id = track_id;
    view.removed = 1;
    return view;
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
        .musicbrainz_recording_id_source = @backingInt(exportIdSource(details.musicbrainz_recording_id_source)),
        .musicbrainz_release_id_source = @backingInt(exportIdSource(details.musicbrainz_release_id_source)),
        .musicbrainz_release_group_id_source = @backingInt(exportIdSource(details.musicbrainz_release_group_id_source)),
        .musicbrainz_release_track_id_source = @backingInt(exportIdSource(details.musicbrainz_release_track_id_source)),
        .musicbrainz_album_artist_id_source = @backingInt(exportIdSource(details.musicbrainz_album_artist_id_source)),
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
        .explicit => 13,
        .composer => 14,
        .comment => 15,
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
        13 => .explicit,
        14 => .composer,
        15 => .comment,
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
        .folder_not_writable => 3,
        .file_read_only => 4,
    };
}

pub fn exportTagWriteFailureReason(reason: core.runtime.TagWriteFailureReason) u8 {
    return switch (reason) {
        .permission_denied => 0,
        .read_only_file_system => 1,
        .no_space => 2,
        .changed_since_plan => 3,
        .other => 4,
        .file_read_only => 5,
        .backup_exists => 6,
        .recovery_failed => 7,
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
        .identical_audio => 13,
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
        13 => .identical_audio,
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

pub fn exportListenPolicy(policy: core.runtime.ListenPolicy) u8 {
    return switch (policy) {
        .half_or_four_minutes => 0,
        .thirty_seconds => 1,
        .full_track => 2,
    };
}

fn importListenPolicy(value: u8) ?core.runtime.ListenPolicy {
    return switch (value) {
        0 => .half_or_four_minutes,
        1 => .thirty_seconds,
        2 => .full_track,
        else => null,
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
        2 => .album,
        3 => .smart,
        else => null,
    };
}

pub fn importUntaggedFallback(value: u8) ?audio.processing.UntaggedFallback {
    return switch (value) {
        0 => .minus_6_db,
        1 => .as_is,
        else => null,
    };
}

pub fn exportUntaggedFallback(fallback: audio.processing.UntaggedFallback) u8 {
    return switch (fallback) {
        .minus_6_db => 0,
        .as_is => 1,
    };
}

pub fn exportReplayGainSource(source: audio.processing.ReplayGainSource) u8 {
    return switch (source) {
        .none => 0,
        .track => 1,
        .album => 2,
        .track_fallback => 3,
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
        .signed_8 => 6,
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
        .path_unknown => 5,
    };
}

fn exportEqualizer(equalizer: audio.dsp.Equalizer) EqualizerView {
    return .{ .gains_db = equalizer.gains_db, .preamp_db = equalizer.preamp_db };
}

fn importEqualizer(equalizer: *const EqualizerView) audio.dsp.Equalizer {
    return .{ .gains_db = equalizer.gains_db, .preamp_db = equalizer.preamp_db };
}

pub fn importFilterKind(kind: u8) ?audio.dsp.FilterKind {
    return switch (kind) {
        0 => .peak,
        1 => .low_shelf,
        2 => .high_shelf,
        3 => .low_pass,
        4 => .high_pass,
        5 => .notch,
        else => null,
    };
}

pub fn exportFilterKind(kind: audio.dsp.FilterKind) u8 {
    return switch (kind) {
        .peak => 0,
        .low_shelf => 1,
        .high_shelf => 2,
        .low_pass => 3,
        .high_pass => 4,
        .notch => 5,
    };
}

fn exportParametricEqualizer(equalizer: *const audio.dsp.ParametricEqualizer) ParametricEqualizerView {
    var view = std.mem.zeroes(ParametricEqualizerView);
    view.count = equalizer.count;
    view.preamp_db = equalizer.preamp_db;
    for (equalizer.filterList(), view.filters[0..equalizer.count]) |filter, *destination| destination.* = .{
        .kind = exportFilterKind(filter.kind),
        .enabled = @intFromBool(filter.enabled),
        .frequency_hz = filter.frequency_hz,
        .gain_db = filter.gain_db,
        .q = filter.q,
    };
    return view;
}

fn importParametricEqualizer(view: *const ParametricEqualizerView) ?audio.dsp.ParametricEqualizer {
    if (view.count > audio.dsp.max_parametric_filters) return null;
    var equalizer: audio.dsp.ParametricEqualizer = .{
        .filters = @splat(.{ .kind = .peak, .frequency_hz = 0, .q = 0, .enabled = false }),
        .count = view.count,
        .preamp_db = view.preamp_db,
    };
    for (view.filters[0..view.count], equalizer.filters[0..view.count]) |filter, *destination| destination.* = .{
        .kind = importFilterKind(filter.kind) orelse return null,
        .enabled = filter.enabled != 0,
        .frequency_hz = filter.frequency_hz,
        .gain_db = filter.gain_db,
        .q = filter.q,
    };
    return equalizer;
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

pub fn exportDeviceSampleFormat(format: audio.backend.DeviceSampleFormat) u8 {
    return switch (format) {
        .signed_16 => 1,
        .signed_24 => 2,
        .signed_24_32 => 3,
        .signed_32 => 4,
        .float_32 => 5,
    };
}

pub fn exportDeviceFormat(format: ?audio.backend.DeviceFormat) DeviceFormatView {
    const value = format orelse return std.mem.zeroes(DeviceFormatView);
    return .{
        .sample_rate = value.sample_rate,
        .channels = value.channels,
        .bits_per_sample = value.sample_format.bitsPerSample(),
        .sample_format = exportDeviceSampleFormat(value.sample_format),
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
        .output_kind = exportDeviceKind(path.output_kind),
        .has_device_quantum = @intFromBool(path.device_quantum_frames != null),
        .replay_gain_source = exportReplayGainSource(path.replay_gain_source),
        .device_quantum_frames = path.device_quantum_frames orelse 0,
        .codec = stringView(path.codec orelse ""),
    };
    for (path.reasonList(), 0..) |reason, index| view.reasons[index] = exportSignalReason(reason);
    return view;
}

fn exportSignalPathV2(path: *const audio.dsp.SignalPath) SignalPathViewV2 {
    return .{
        .base = exportSignalPath(path),
        .parametric = if (path.parametric) |*value| exportParametricEqualizer(value) else std.mem.zeroes(ParametricEqualizerView),
        .has_parametric = @intFromBool(path.parametric != null),
        .has_replay_gain_track = @intFromBool(path.replay_gain_track_db != null),
        .replay_gain_track_db = path.replay_gain_track_db orelse 0,
        .preamp_db = path.preamp_db,
        .peak_protection = @intFromBool(path.peak_protection),
        .fallback = exportUntaggedFallback(path.fallback),
        .peak_limited = @intFromBool(path.peak_limited),
        .device_format = exportDeviceFormat(path.device_format),
    };
}

pub fn exportDeviceKind(kind: audio.backend.DeviceKind) u8 {
    return switch (kind) {
        .unknown => 0,
        .usb => 1,
        .pci => 2,
        .bluetooth => 3,
        .hdmi => 4,
        .virtual => 5,
    };
}

pub fn exportDeviceState(state: audio.backend.DeviceState) u8 {
    return switch (state) {
        .active => 0,
        .suspended => 1,
        .unavailable => 2,
    };
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

fn exportMatchStats(stats: core.runtime.MatchStats) MatchStatsView {
    return .{
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
}

pub fn exportMaintenanceState(state: core.runtime.MaintenanceState) u8 {
    return switch (state) {
        .off => 0,
        .waiting => 1,
        .running => 2,
        .blocked => 3,
    };
}

pub fn exportMaintenanceBlock(block: core.runtime.MaintenanceBlock) u8 {
    return switch (block) {
        .client_identity_required => 0,
        .acoustid_required => 1,
        .provider_busy => 2,
    };
}

pub fn exportJobOrigin(origin: core.runtime.JobOrigin) u8 {
    return switch (origin) {
        .host => 0,
        .watcher => 1,
        .maintenance => 2,
    };
}

fn exportMaintenanceStatus(status: core.runtime.MaintenanceStatus) MaintenanceStatus {
    const last = status.last;
    const last_release_id = if (last) |unit| unit.release_id else null;
    return .{
        .next_due_ms = status.next_due_ms orelse 0,
        .units_run = status.units_run,
        .last_release_id = last_release_id orelse 0,
        .last_stats = if (last) |unit| exportMatchStats(unit.stats) else std.mem.zeroes(MatchStatsView),
        .enabled = @intFromBool(status.enabled),
        .state = exportMaintenanceState(status.state),
        .blocked = if (status.blocked) |block| exportMaintenanceBlock(block) else 0,
        .has_blocked = @intFromBool(status.blocked != null),
        .has_next_due_ms = @intFromBool(status.next_due_ms != null),
        .has_last = @intFromBool(last != null),
        .has_last_release_id = @intFromBool(last_release_id != null),
        .last_state = if (last) |unit| @backingInt(unit.state) else 0,
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
        .track_folder_unavailable => 10,
        .internal => 255,
    };
}

pub fn exportReleaseMatchBucket(bucket: database.ReleaseMatchBucket) u8 {
    return switch (bucket) {
        .confident => 0,
        .needs_review => 1,
        .unmatched => 2,
        .reviewed => 3,
    };
}

pub fn importReleaseMatchBucket(value: u8) ?database.ReleaseMatchBucket {
    return switch (value) {
        0 => .confident,
        1 => .needs_review,
        2 => .unmatched,
        3 => .reviewed,
        else => null,
    };
}

pub fn importReleaseField(value: u8) ?database.ReleaseField {
    return switch (value) {
        0 => .album,
        1 => .album_artist,
        2 => .release_date,
        3 => .release_type,
        4 => .release_id,
        5 => .genre,
        6 => .artwork,
        7 => .track_titles,
        else => null,
    };
}

pub fn importJobHistoryFilter(value: u8) ?core.runtime.JobHistoryFilter {
    return switch (value) {
        0 => .all,
        1 => .scans,
        2 => .analysis,
        3 => .file_changes,
        4 => .problems,
        else => null,
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
        .lyrics => 9,
        .artist_info => 10,
        .release_info => 11,
        .consistency => 12,
        .daily_mixes => 13,
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
            .kind = @backingInt(EventKind.job_finished),
            .payload = .{ .job_finished = .{
                .job = exportJobHandle(value.job),
                .state = @backingInt(value.state),
            } },
        },
        .failed => |failure| {
            completed.outcome = 255;
            completed.failure = exportFailure(failure);
        },
    }
    return .{
        .kind = @backingInt(EventKind.command_completed),
        .payload = .{ .command_completed = completed },
    };
}

fn exportTelemetry(telemetry: control.Telemetry) ?Event {
    return switch (telemetry) {
        .player_position => |position| .{
            .kind = @backingInt(EventKind.player_position),
            .payload = .{ .player_position = .{
                .player = exportHandle(position.player),
                .frames = position.frames,
            } },
        },
        .job_progress => |progress| .{
            .kind = @backingInt(EventKind.job_progress),
            .payload = .{ .job_progress = .{
                .job = exportJobHandle(progress.job),
                .has_total = @intFromBool(progress.total_units != null),
                .completed_units = progress.completed_units,
                .total_units = progress.total_units orelse 0,
            } },
        },
        .library_changed => |changed| .{
            .kind = @backingInt(EventKind.library_changed),
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
        error.QueueEmpty,
        error.LibraryHasNoDatabase,
        error.ZoneOwnedByEngine,
        error.InvalidJobTransition,
        error.JobAlreadyFinished,
        error.WorkersRunning,
        error.ScrobblingEnabledElsewhere,
        => .invalid_state,
        error.AlreadyWatching, error.SqliteLocksNotInstalled => .invalid_state,
        error.PlaylistNameTaken, error.PlaylistFull, error.PlaylistEmpty, error.FolderEmpty => .invalid_state,
        error.PlaylistIsSmart, error.PlaylistIsManual => .invalid_state,
        error.NoBackupDirectory, error.MutationGroupNotCommitted, error.ClientIdentityRequired, error.TagTargetUnavailable => .invalid_state,
        error.TrackHasNoPlayableFile, error.TrackFileMissing, error.TrackFolderUnavailable, error.UnknownRoot, error.UnknownPlaylist, error.UnknownFile => .not_found,
        error.TrackNotFound, error.UnknownTagWritePlan, error.MutationGroupNotFound, error.UnknownDailyMix => .not_found,
        error.PlaybackQueueFull, error.ArtworkQueueFull, error.LibraryJobRunning, error.LibraryScanRunning, error.MutationInProgress => .busy,
        error.TooManyPendingTagWrites, error.TagWriteInProgress => .busy,
        error.MatchingAlreadyRunning, error.AcoustIdBusy, error.JobQueueFull => .busy,
        error.JobNotPausable, error.JobNotRetryable => .invalid_state,
        error.UnknownJobHistory => .not_found,
        error.UnknownTagWriteGroup => .not_found,
        error.AcoustIdRequired, error.StaleIdentificationProposal, error.StaleCorrectionGroup, error.ProposalInGroup => .invalid_state,
        error.UnknownRelease, error.UnknownIdentificationProposal, error.UnknownCorrectionGroup, error.UnknownArtist => .not_found,
        error.UnknownDuplicateGroup, error.NoReleaseCandidate, error.UnknownRadioSeed => .not_found,
        error.NotARadioPick => .not_found,
        error.RadioNotActive => .invalid_state,
        error.TrackNotOnRelease, error.UnknownReleaseTrack => .not_found,
        error.NoReleaseTracklist, error.ReleaseTrackAlreadyPaired, error.ReleaseNotPlaced => .invalid_state,
        error.ReleaseTooLarge => .unsupported,
        error.MutationGroupAlreadyUndone, error.TrackNotPaired, error.ReleaseNotReviewed => .already_done,
        error.MutationNeedsReconciliation => .needs_reconciliation,
        error.TagWriteBackupPruned => .gone,
        error.CodecUnavailable,
        error.UnsupportedAudioFormat,
        error.UnsupportedChannelCount,
        error.WatchingUnsupported,
        error.UnsupportedFilterType,
        => .unsupported,
        error.InvalidVolume,
        error.InvalidBatchSize,
        error.InvalidLibraryRoot,
        error.RootPathOverlaps,
        error.InvalidWatchOptions,
        error.InvalidReconcileDirectory,
        error.InvalidFolderPath,
        error.PositionOutOfRange,
        error.InvalidPlaylistName,
        error.PlaylistTooLarge,
        error.EqualizerGainOutOfRange,
        error.EqualizerPreampOutOfRange,
        error.TooManyFilters,
        error.ParametricPreampOutOfRange,
        error.FilterFrequencyOutOfRange,
        error.FilterGainOutOfRange,
        error.FilterQOutOfRange,
        error.InvalidEqualizerApo,
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
        error.InvalidMusicBrainzId,
        error.InvalidMaintenanceOptions,
        error.PageOutOfRange,
        error.TooManyGenres,
        error.InvalidGenre,
        error.SearchTextTooLong,
        error.InvalidSearchLimits,
        error.NotATagWriteJob,
        error.NotALyricsJob,
        error.NotAnArtistInfoJob,
        error.NotAReleaseInfoJob,
        error.InvalidLimit,
        error.InvalidLanguage,
        error.InvalidPlaylistTag,
        error.TooManyPlaylistTags,
        error.PlaylistDescriptionTooLong,
        error.InvalidSmartPlaylistRules,
        error.UnknownRuleField,
        error.UnknownRuleOperator,
        error.RuleOperatorMismatch,
        error.InvalidRuleValue,
        error.RuleNestingTooDeep,
        error.TooManyRules,
        error.InvalidRulePlaylist,
        error.NotDuplicates,
        error.SameDuplicateTrack,
        error.InvalidExplore,
        error.InvalidDecade,
        error.RadioLimitTooLarge,
        error.RadioSessionTooLarge,
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
        if (event.kind == @backingInt(EventKind.none)) break;
        if (event.kind == @backingInt(EventKind.command_completed) and
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
    if (builtin.mode != .debug) return error.SkipZigTest;
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

test "a destroy from another thread is refused in debug builds and leaves the runtime usable" {
    if (builtin.mode != .debug) return error.SkipZigTest;
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_open(runtime, null, &library));

    const thread = try std.Thread.spawn(.{}, orca_runtime_destroy, .{runtime});
    thread.join();

    try std.testing.expectEqualStrings("orca_library_open: path is null", std.mem.span(orca_runtime_last_error(runtime)));
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-foreign-destroy?mode=memory&cache=shared", &library));
}

test "two runtimes share the SQLite lock replacement and destroying one leaves it for the other" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const first = orca_runtime_create() orelse return error.OutOfMemory;
    const second = orca_runtime_create() orelse {
        orca_runtime_destroy(first);
        return error.OutOfMemory;
    };
    defer orca_runtime_destroy(second);
    try std.testing.expect(database.sqlite_locks.active());
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(first, "file:orca-c-api-first-runtime?mode=memory&cache=shared", &library));
    try std.testing.expectEqual(Status.ok, orca_library_open(second, "file:orca-c-api-second-runtime?mode=memory&cache=shared", &library));

    orca_runtime_destroy(first);

    try std.testing.expect(database.sqlite_locks.active());
    try std.testing.expectEqual(Status.ok, orca_library_open(second, "file:orca-c-api-after-first-runtime?mode=memory&cache=shared", &library));
}

test "a last error longer than its buffer is truncated and stays terminated" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;
    box.recordError("orca_library_open", &@as([400]u8, @splat('x')));
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

    var releases: ReleaseQueryView = .{ .album_artist_id = -1, .sort = 6, .loved_only = 0, .limit = 8, .offset = 0 };
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

    var tracks: TrackQueryView = .{ .artist_id = -1, .release_id = -1, .sort = 12, .descending = 0, .loved_only = 1, .limit = 8, .offset = 0 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_tracks(runtime, library, &tracks, &visited, countTrack));
    tracks.sort = @backingInt(TrackSortKey.loved);
    try std.testing.expectEqual(Status.ok, orca_library_track_match_count(runtime, library, &tracks, &count));

    var tracks_v2: TrackQueryV2View = .{ .artist_id = 0, .release_id = 0, .genre_id = 0, .sort = 12, .descending = 0, .loved_only = 0, .has_artist_id = 0, .has_release_id = 0, .has_genre_id = 0, .limit = 8, .offset = 0 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_tracks_v2(runtime, library, &tracks_v2, &visited, countSummaryFacts));
    tracks_v2.sort = @backingInt(TrackSortKey.year);
    tracks_v2.has_genre_id = 1;
    tracks_v2.genre_id = 1;
    try std.testing.expectEqual(Status.ok, orca_library_browse_tracks_v2(runtime, library, &tracks_v2, &visited, countSummaryFacts));
    tracks_v2.has_genre_id = 0;
    tracks_v2.limit = max_page + 1;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_tracks_v2(runtime, library, &tracks_v2, &visited, countSummaryFacts));
    tracks_v2.limit = 8;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_tracks_v2(runtime, library, null, &visited, countSummaryFacts));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_tracks_v2(runtime, library, &tracks_v2, &visited, null));
    try std.testing.expectEqual(Status.ok, orca_library_browse_tracks_v2(runtime, library, &tracks_v2, &visited, countSummaryFacts));
    tracks_v2.format = @backingInt(TrackFormatFilter.lossless);
    tracks_v2.has_year_min = 1;
    tracks_v2.year_min = 1990;
    tracks_v2.min_sample_rate = 44_100;
    tracks_v2.explicit_only = 1;
    try std.testing.expectEqual(Status.ok, orca_library_browse_tracks_v2(runtime, library, &tracks_v2, &visited, countSummaryFacts));
    try std.testing.expectEqual(Status.ok, orca_library_track_match_count_v2(runtime, library, &tracks_v2, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_match_count_v2(runtime, library, &tracks_v2, null));
    tracks_v2.format = 3;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_tracks_v2(runtime, library, &tracks_v2, &visited, countSummaryFacts));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_match_count_v2(runtime, library, &tracks_v2, &count));
    tracks_v2.format = @backingInt(TrackFormatFilter.any);

    var releases_v2: ReleaseQueryV2View = .{ .album_artist_id = 0, .genre_id = 1, .sort = 6, .loved_only = 0, .has_album_artist_id = 0, .has_genre_id = 1, .limit = 8, .offset = 0 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_releases_v2(runtime, library, &releases_v2, &visited, countReleaseFacts));
    releases_v2.sort = 5;
    try std.testing.expectEqual(Status.ok, orca_library_browse_releases_v2(runtime, library, &releases_v2, &visited, countReleaseFacts));
    try std.testing.expectEqual(Status.ok, orca_library_release_count_matching_v2(runtime, library, &releases_v2, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    releases_v2.artwork = 3;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_browse_releases_v2(runtime, library, &releases_v2, &visited, countReleaseFacts));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_count_matching_v2(runtime, library, &releases_v2, &count));
    releases_v2.artwork = @backingInt(ReleaseArtworkFilter.absent);
    releases_v2.kind = 4;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_count_matching_v2(runtime, library, &releases_v2, &count));
    releases_v2.kind = @backingInt(ReleaseKindFilter.ep_or_single);
    releases_v2.has_appearing_artist_id = 1;
    releases_v2.appearing_artist_id = 1;
    try std.testing.expectEqual(Status.ok, orca_library_release_count_matching_v2(runtime, library, &releases_v2, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    releases_v2.has_album_artist_id = 1;
    releases_v2.album_artist_id = 1;
    releases_v2.own_releases_only = 1;
    try std.testing.expectEqual(Status.ok, orca_library_release_count_matching_v2(runtime, library, &releases_v2, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    releases_v2.has_album_artist_id = 0;
    releases_v2.own_releases_only = 0;
    releases_v2.has_year_min = 1;
    releases_v2.year_min = 2010;
    releases_v2.high_resolution_only = 1;
    try std.testing.expectEqual(Status.ok, orca_library_release_count_matching_v2(runtime, library, &releases_v2, &count));
    releases_v2.limit = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_count_matching_v2(runtime, library, &releases_v2, &count));

    var artists_v2: ArtistQueryV2View = .{ .filter = .{ .pointer = null, .length = 0 }, .genre_id = 1, .limit = 8, .offset = 0, .sort = 4, .has_genre_id = 1, .loved_only = 0 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_artists_v2(runtime, library, &artists_v2, &visited, countArtistV2));
    artists_v2.sort = @backingInt(ArtistSortKey.track_count);
    try std.testing.expectEqual(Status.ok, orca_library_query_artists_v2(runtime, library, &artists_v2, &visited, countArtistV2));
    artists_v2.loved_only = 2;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_count_matching_v2(runtime, library, &artists_v2, &count));
    artists_v2.loved_only = 1;
    try std.testing.expectEqual(Status.ok, orca_library_artist_count_matching_v2(runtime, library, &artists_v2, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    artists_v2.filter.length = 2;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_count_matching_v2(runtime, library, &artists_v2, &count));
    var totals: ArtistTotalsView = undefined;
    try std.testing.expectEqual(Status.not_found, orca_library_artist_totals(runtime, library, 1, &totals));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_totals(runtime, library, 1, null));
    artists_v2.filter.length = 0;
    artists_v2.sort = @backingInt(ArtistSortKey.recently_added);
    try std.testing.expectEqual(Status.ok, orca_library_query_artists_v2(runtime, library, &artists_v2, &visited, countArtistV2));

    var genres: GenreQueryView = .{ .filter = .{ .pointer = null, .length = 0 }, .limit = 8, .offset = 0, .sort = 2 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_genres(runtime, library, &genres, &visited, countGenre));
    genres.sort = @backingInt(GenreSortKey.track_count);
    try std.testing.expectEqual(Status.ok, orca_library_query_genres(runtime, library, &genres, &visited, countGenre));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_genres(runtime, library, null, &visited, countGenre));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_genre_count(runtime, library, null, 3, &count));
    try std.testing.expectEqual(Status.ok, orca_library_genre_count(runtime, library, null, 0, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    try std.testing.expectEqual(Status.not_found, orca_library_genre_get(runtime, library, 1, &visited, countGenre));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_genres(runtime, library, 1, 0, &visited, countGenreCount));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_genre_artwork(runtime, library, 1, max_page + 1, &visited, null));
    const too_many: [database.max_track_genres + 1]StringInput = @splat(.{ .pointer = "Rock", .length = 4 });
    const one_track = [_]i64{1};
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_track_genres(runtime, library, &one_track, 1, &too_many, too_many.len));
    try std.testing.expectEqual(Status.not_found, orca_library_set_track_genres(runtime, library, &one_track, 1, &too_many, 1));

    try std.testing.expectEqual(@as(usize, 0), visited);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_play_stats(runtime, library, 1, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_listens_recorded(runtime, library, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_unanalyzed_count(runtime, library, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_analysis_coverage(runtime, library, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_backfill_pending(runtime, library, null));
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
    try std.testing.expectEqual(Status.invalid_argument, orca_library_restore_health_issue(runtime, library, file_id, 14));
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

fn captureHealthSummaryV2(context: ?*anyopaque, view: *const HealthKindSummaryViewV2) callconv(.c) void {
    const captured: *HealthKindSummaryViewV2 = @ptrCast(@alignCast(context.?));
    captured.* = view.*;
}

test "library stats and the sized health summary reach the C ABI, and a null output or callback is refused" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-library-stats?mode=memory&cache=shared",
        &library,
    ));
    var stats: LibraryStatsView = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_stats(runtime, library, null));
    try std.testing.expectEqual(Status.ok, orca_library_stats(runtime, library, &stats));
    try std.testing.expectEqual(@as(u64, 0), stats.files);
    try std.testing.expectEqual(@as(u8, 0), stats.has_last_scan_finished_at);
    try std.testing.expectEqual(@as(u8, 0), stats.has_last_analysis_at);

    const box = runtimeBox(runtime).?;
    const library_database = try core.runtime.databaseOf(&box.runtime, importLibrary(library));
    const kept = try library_database.files.create(.{ .size_bytes = 3_000 });
    const copy = try library_database.files.create(.{ .size_bytes = 3_000 });
    for ([_]i64{ kept, copy }, [_][]const u8{ "music/kept.flac", "music/copy.flac" }) |file_id, uri|
        _ = try library_database.locations.upsert(.{ .file_id = file_id, .volume_id = database.LibraryDatabase.null_volume, .uri = uri });
    try library_database.health_issues.replaceFile(kept, &.{.{ .kind = .exact_duplicate, .severity = .warning, .related_file_id = copy }});
    try library_database.health_issues.replaceFile(copy, &.{.{ .kind = .exact_duplicate, .severity = .warning, .related_file_id = kept }});

    try std.testing.expectEqual(Status.ok, orca_library_stats(runtime, library, &stats));
    try std.testing.expectEqual(@as(u64, 2), stats.files);
    try std.testing.expectEqual(@as(u64, 6_000), stats.total_bytes);

    var summary: HealthKindSummaryViewV2 = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_health_summary_v2(runtime, library, null, null));
    try std.testing.expectEqual(Status.ok, orca_library_health_summary_v2(runtime, library, &summary, captureHealthSummaryV2));
    try std.testing.expectEqual(exportHealthIssueKind(.exact_duplicate), summary.base.kind);
    try std.testing.expectEqual(@as(u64, 2), summary.base.count);
    try std.testing.expectEqual(@as(u64, 2), summary.files);
    try std.testing.expectEqual(@as(u64, 3_000), summary.bytes);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

test "listen settings, history clearing, the cache and the second library stats reach the C ABI" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(
        runtime,
        "file:orca-c-api-listen-settings?mode=memory&cache=shared",
        &library,
    ));

    var policy: u8 = 9;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_listen_policy(runtime, library, null));
    try std.testing.expectEqual(Status.ok, orca_library_listen_policy(runtime, library, &policy));
    try std.testing.expectEqual(@as(u8, 0), policy);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_listen_policy(runtime, library, 3));
    try std.testing.expectEqual(Status.ok, orca_library_set_listen_policy(runtime, library, 1));
    try std.testing.expectEqual(Status.ok, orca_library_listen_policy(runtime, library, &policy));
    try std.testing.expectEqual(@as(u8, 1), policy);

    var recording: u8 = 9;
    try std.testing.expectEqual(Status.ok, orca_library_listen_recording(runtime, library, &recording));
    try std.testing.expectEqual(@as(u8, 1), recording);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_listen_recording(runtime, library, 2));
    try std.testing.expectEqual(Status.ok, orca_library_set_listen_recording(runtime, library, 0));
    try std.testing.expectEqual(Status.ok, orca_library_listen_recording(runtime, library, &recording));
    try std.testing.expectEqual(@as(u8, 0), recording);

    const box = runtimeBox(runtime).?;
    const library_database = try core.runtime.databaseOf(&box.runtime, importLibrary(library));
    try library_database.database.exec(
        \\INSERT INTO listens(file_id, started_at, listened_ms, title, artist) VALUES (NULL, 1, 1, 'a', 'b'), (NULL, 2, 1, 'a', 'b');
        \\INSERT INTO job_history(kind, started_at, finished_at, state, completed_units) VALUES ('duplicate_scan', 5, 7, 'succeeded', 1);
        \\INSERT INTO releases(id, title) VALUES (1, 'Covered');
        \\INSERT INTO release_artwork(release_id, musicbrainz_release_id, image, mime, fetched_at) VALUES (1, 'r', x'010203', 'image/jpeg', 1);
    );

    var stats: LibraryStatsViewV2 = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_stats_v2(runtime, library, null));
    try std.testing.expectEqual(Status.ok, orca_library_stats_v2(runtime, library, &stats));
    try std.testing.expectEqual(@as(u64, 2), stats.listens);
    try std.testing.expectEqual(@as(u8, 1), stats.has_last_duplicate_scan_at);
    try std.testing.expectEqual(@as(i64, 7), stats.last_duplicate_scan_at);
    try std.testing.expectEqual(@as(u64, 1), stats.base.releases);

    var removed: u64 = 0;
    try std.testing.expectEqual(Status.ok, orca_library_clear_listens(runtime, library, &removed));
    try std.testing.expectEqual(@as(u64, 2), removed);
    try std.testing.expectEqual(Status.ok, orca_library_clear_listens(runtime, library, null));

    var size: CacheSizeView = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_cache_size(runtime, library, null));
    try std.testing.expectEqual(Status.ok, orca_library_cache_size(runtime, library, &size));
    try std.testing.expectEqual(@as(u64, 3), size.artwork_bytes);
    var cleared: CacheSizeView = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_clear_cache(runtime, library, &cleared));
    try std.testing.expectEqual(@as(u64, 3), cleared.artwork_bytes);
    try std.testing.expectEqual(Status.ok, orca_library_clear_cache(runtime, library, null));
    try std.testing.expectEqual(Status.ok, orca_library_cache_size(runtime, library, &size));
    try std.testing.expectEqual(@as(u64, 0), size.artwork_bytes);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

const ProviderSourceCapture = struct {
    count: usize = 0,
    first_id: u8 = 255,
    first_name: [32]u8 = undefined,
    first_name_length: usize = 0,
    empty_licence_urls: usize = 0,
};

fn captureProviderSource(context: ?*anyopaque, view: *const ProviderSourceView) callconv(.c) void {
    const capture: *ProviderSourceCapture = @ptrCast(@alignCast(context.?));
    if (capture.count == 0) {
        capture.first_id = view.id;
        const name = view.name.pointer[0..view.name.length];
        @memcpy(capture.first_name[0..name.len], name);
        capture.first_name_length = name.len;
    }
    if (view.licence_url.length == 0) capture.empty_licence_urls += 1;
    capture.count += 1;
}

test "provider sources reach the C ABI in id order, and a null callback is refused" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    try std.testing.expectEqual(Status.invalid_argument, orca_provider_sources(runtime, null, null));
    var capture: ProviderSourceCapture = .{};
    try std.testing.expectEqual(Status.ok, orca_provider_sources(runtime, &capture, captureProviderSource));
    try std.testing.expectEqual(@as(usize, 9), capture.count);
    try std.testing.expectEqual(@as(u8, 0), capture.first_id);
    try std.testing.expectEqualStrings("MusicBrainz", capture.first_name[0..capture.first_name_length]);
    try std.testing.expectEqual(@as(usize, 3), capture.empty_licence_urls);
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
    var features: AudioFeaturesView = undefined;
    try std.testing.expectEqual(Status.not_found, orca_library_track_audio_features(runtime, library, 1, &features));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_track_audio_features(runtime, library, 1, null));
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

fn countArtistV2(context: ?*anyopaque, artist: *const ArtistViewV2) callconv(.c) void {
    _ = artist;
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
}

fn countGenre(context: ?*anyopaque, genre: *const GenreView) callconv(.c) void {
    _ = genre;
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
}

fn countGenreCount(context: ?*anyopaque, genre: *const GenreCountView) callconv(.c) void {
    _ = genre;
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

fn countReleaseFacts(context: ?*anyopaque, release: *const ReleaseView, facts: *const ReleaseFactsView) callconv(.c) void {
    _ = facts;
    countRelease(context, release);
}

fn countSummaryFacts(context: ?*anyopaque, summary: *const TrackSummaryView, facts: *const TrackFactsView) callconv(.c) void {
    _ = facts;
    countTrack(context, &summary.track);
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
    const too_many: [max_page + 1]i64 = @splat(1);
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
    try std.testing.expectEqual(Status.invalid_argument, orca_player_queue_move(runtime, player, 0, 0));
    try std.testing.expectEqualStrings(
        "orca_player_queue_move: PositionOutOfRange",
        std.mem.span(orca_runtime_last_error(runtime)),
    );

    try std.testing.expectEqual(Status.invalid_argument, orca_player_query_queue_tracks(runtime, player, 0, 0, &visited, countTrack));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_query_queue_tracks(runtime, player, max_page + 1, 0, &visited, countTrack));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_query_queue_tracks(runtime, player, 8, 0, &visited, null));
    try std.testing.expectEqual(Status.ok, orca_player_query_queue_tracks(runtime, player, 8, 0, &visited, countTrack));
    try std.testing.expectEqual(@as(usize, 0), visited);
}

fn countHistoryEntry(context: ?*anyopaque, summary: *const TrackSummaryView, ended_at: i64, reason: u8) callconv(.c) void {
    _ = summary;
    _ = ended_at;
    _ = reason;
    const visited: *usize = @ptrCast(@alignCast(context.?));
    visited.* += 1;
}

test "queue history starts empty and saving refuses a Player without a Library or a current entry" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    var visited: usize = 0;
    var playlist_id: i64 = 0;
    try std.testing.expectEqual(Status.invalid_state, orca_player_save_queue_as_playlist(runtime, player, "queue", 5, &playlist_id));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_query_queue_history(runtime, player, 0, 0, &visited, countHistoryEntry));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_query_queue_history(runtime, player, max_page + 1, 0, &visited, countHistoryEntry));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_query_queue_history(runtime, player, 8, 0, &visited, null));
    try std.testing.expectEqual(Status.ok, orca_player_query_queue_history(runtime, player, 8, 0, &visited, countHistoryEntry));
    try std.testing.expectEqual(@as(usize, 0), visited);
    try std.testing.expectEqual(Status.ok, orca_player_clear_queue_history(runtime, player));

    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-queue-history?mode=memory&cache=shared", &library));
    try std.testing.expectEqual(Status.ok, orca_player_set_library(runtime, player, library));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_save_queue_as_playlist(runtime, player, "queue", 5, null));
    try std.testing.expectEqual(Status.invalid_state, orca_player_save_queue_as_playlist(runtime, player, "queue", 5, &playlist_id));
    try std.testing.expectEqualStrings(
        "orca_player_save_queue_as_playlist: QueueEmpty",
        std.mem.span(orca_runtime_last_error(runtime)),
    );
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
    const too_many: [max_page + 1]i64 = @splat(1);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_insert(runtime, library, id, &too_many, too_many.len, -1, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_insert(runtime, library, id, &ids, 1, -1, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_insert(runtime, library, id, &ids, 1, 1, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_insert(runtime, library, id, &ids, 1, std.math.maxInt(u32) + 1, &change));
    try std.testing.expectEqual(Status.ok, orca_library_playlist_insert(runtime, library, id, &ids, 1, -1, &change));
    try std.testing.expectEqual(ChangeCount{ .updated = 0, .skipped = 1 }, change);

    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_remove(runtime, library, id, null, 1, &removed));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_remove(runtime, library, id, &positions, 1, null));
    const too_many_positions: [max_page + 1]u32 = @splat(0);
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
const PlaylistFactsSeen = struct {
    visited: usize = 0,
    kind: u8 = 255,
    pinned: u8 = 255,
    tag_count: u8 = 255,
    description_length: usize = 0,
};

fn recordPlaylistFacts(context: ?*anyopaque, playlist: *const PlaylistView, facts: *const PlaylistFactsView) callconv(.c) void {
    _ = playlist;
    const seen: *PlaylistFactsSeen = @ptrCast(@alignCast(context.?));
    seen.visited += 1;
    seen.kind = facts.kind;
    seen.pinned = facts.pinned;
    seen.tag_count = facts.tag_count;
    seen.description_length = facts.description.length;
}

fn countStrings(context: ?*anyopaque, value: *const StringView) callconv(.c) void {
    _ = value;
    const visited: *usize = @ptrCast(@alignCast(context.?));
    visited.* += 1;
}

test "playlist metadata and smart playlists reach the C ABI and refuse bad arguments" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-smart-playlists?mode=memory&cache=shared", &library));
    var manual: i64 = 0;
    try std.testing.expectEqual(Status.ok, orca_library_create_playlist(runtime, library, "Mix", 3, &manual));

    const tags = [_]StringInput{ .{ .pointer = "focus", .length = 5 }, .{ .pointer = "lofi", .length = 4 } };
    var update: PlaylistUpdateView = .{
        .description = .{ .pointer = "For work", .length = 8 },
        .tags = &tags,
        .tag_count = tags.len,
        .has_description = 1,
        .has_pinned = 1,
        .pinned = 1,
        .has_loved = 0,
        .loved = 0,
        .has_tags = 1,
    };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_update_playlist(runtime, library, manual, null));
    try std.testing.expectEqual(Status.not_found, orca_library_update_playlist(runtime, library, manual + 1000, &update));
    try std.testing.expectEqual(Status.ok, orca_library_update_playlist(runtime, library, manual, &update));
    update.has_pinned = 2;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_update_playlist(runtime, library, manual, &update));
    update.has_pinned = 0;
    update.tag_count = max_page;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_update_playlist(runtime, library, manual, &update));
    update.tag_count = 1;
    update.tags = null;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_update_playlist(runtime, library, manual, &update));

    var visited: usize = 0;
    try std.testing.expectEqual(Status.ok, orca_library_playlist_tags(runtime, library, manual, &visited, countStrings));
    try std.testing.expectEqual(@as(usize, 2), visited);
    try std.testing.expectEqual(Status.not_found, orca_library_playlist_tags(runtime, library, manual + 1000, &visited, countStrings));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_tags(runtime, library, manual, &visited, null));

    const bad_field = "{\"v\":1,\"match\":\"all\",\"rules\":[{\"field\":\"mood\",\"op\":\"is\",\"value\":\"x\"}]}";
    const rules = "{\"v\":1,\"match\":\"all\",\"rules\":[{\"field\":\"year\",\"op\":\"gte\",\"value\":1990}]}";
    var smart: i64 = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_create_smart_playlist(runtime, library, "Nineties", 8, bad_field, bad_field.len, &smart));
    try std.testing.expectEqualStrings(
        "orca_library_create_smart_playlist: UnknownRuleField",
        std.mem.span(orca_runtime_last_error(runtime)),
    );
    try std.testing.expectEqual(Status.invalid_argument, orca_library_create_smart_playlist(runtime, library, "Nineties", 8, rules, rules.len, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_create_smart_playlist(runtime, library, "Nineties", 8, null, 4, &smart));
    try std.testing.expectEqual(Status.ok, orca_library_create_smart_playlist(runtime, library, "Nineties", 8, rules, rules.len, &smart));

    visited = 0;
    try std.testing.expectEqual(Status.ok, orca_library_smart_playlist_rules(runtime, library, smart, &visited, countStrings));
    try std.testing.expectEqual(@as(usize, 1), visited);
    try std.testing.expectEqual(Status.invalid_state, orca_library_smart_playlist_rules(runtime, library, manual, &visited, countStrings));
    try std.testing.expectEqual(Status.ok, orca_library_set_smart_playlist_rules(runtime, library, smart, rules, rules.len));
    try std.testing.expectEqual(Status.invalid_state, orca_library_set_smart_playlist_rules(runtime, library, manual, rules, rules.len));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_smart_playlist_rules(runtime, library, smart, bad_field, bad_field.len));

    const ids = [_]i64{1};
    var change: ChangeCount = undefined;
    try std.testing.expectEqual(Status.invalid_state, orca_library_playlist_insert(runtime, library, smart, &ids, 1, -1, &change));
    try std.testing.expectEqual(Status.invalid_state, orca_library_playlist_move(runtime, library, smart, 0, 0));

    var count: u64 = 99;
    try std.testing.expectEqual(Status.ok, orca_library_smart_playlist_count(runtime, library, rules, rules.len, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_smart_playlist_count(runtime, library, rules, rules.len, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_smart_playlist_count(runtime, library, "{", 1, &count));

    var query: PlaylistQueryView = .{
        .filter = .{ .pointer = null, .length = 0 },
        .limit = 8,
        .offset = 0,
        .sort = @backingInt(PlaylistSortKey.name),
        .has_kind = 1,
        .kind = @backingInt(database.PlaylistKind.smart),
        .pinned_only = 0,
        .has_creator = 0,
        .creator = 0,
    };
    var seen: PlaylistFactsSeen = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_playlists_v2(runtime, library, &query, &seen, recordPlaylistFacts));
    try std.testing.expectEqual(@as(usize, 1), seen.visited);
    try std.testing.expectEqual(@as(u8, 1), seen.kind);
    try std.testing.expectEqual(Status.ok, orca_library_playlist_count(runtime, library, &query, &count));
    try std.testing.expectEqual(@as(u64, 1), count);

    query.has_kind = 0;
    query.pinned_only = 1;
    seen = .{};
    try std.testing.expectEqual(Status.ok, orca_library_query_playlists_v2(runtime, library, &query, &seen, recordPlaylistFacts));
    try std.testing.expectEqual(@as(usize, 1), seen.visited);
    try std.testing.expectEqual(@as(u8, 1), seen.pinned);
    try std.testing.expectEqual(@as(u8, 2), seen.tag_count);
    try std.testing.expectEqual(@as(usize, 8), seen.description_length);

    seen = .{};
    try std.testing.expectEqual(Status.ok, orca_library_playlist_get(runtime, library, smart, &seen, recordPlaylistFacts));
    try std.testing.expectEqual(@as(u8, 1), seen.kind);
    try std.testing.expectEqual(Status.not_found, orca_library_playlist_get(runtime, library, smart + 1000, &seen, recordPlaylistFacts));
    visited = 0;
    try std.testing.expectEqual(Status.ok, orca_library_playlist_genres(runtime, library, manual, &visited, countStrings));
    try std.testing.expectEqual(@as(usize, 0), visited);

    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlists_v2(runtime, library, null, &seen, recordPlaylistFacts));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlists_v2(runtime, library, &query, &seen, null));
    query.sort = 9;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlists_v2(runtime, library, &query, &seen, recordPlaylistFacts));
    query.sort = 0;
    query.limit = max_page + 1;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_playlist_count(runtime, library, &query, &count));
    query.limit = 8;
    query.has_creator = 1;
    query.creator = 7;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_playlists_v2(runtime, library, &query, &seen, recordPlaylistFacts));
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

fn captureSignalPathV2(context: ?*anyopaque, view: *const SignalPathViewV2) callconv(.c) void {
    const destination: *SignalPathViewV2 = @ptrCast(@alignCast(context.?));
    destination.* = view.*;
}

test "a Player with no output reports a signal path with no source, no output and an unknown path" {
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
    try std.testing.expectEqual(@as(u32, 1), path.reason_count);
    try std.testing.expectEqual(exportSignalReason(.path_unknown), path.reasons[0]);
    try std.testing.expectEqual(@as(u8, 5), path.reasons[0]);
    try std.testing.expectEqual(@as(u8, 0), path.bit_perfect_eligible);
    try std.testing.expectEqual(@as(usize, 0), path.codec.length);
    try std.testing.expectEqual(exportDeviceKind(.unknown), path.output_kind);
    try std.testing.expectEqual(@as(u8, 0), path.has_device_quantum);
    try std.testing.expectEqual(exportReplayGainSource(.none), path.replay_gain_source);

    try std.testing.expectEqual(Status.invalid_argument, orca_player_signal_path_v2(runtime, player, null, null));
    var path_v2: SignalPathViewV2 = std.mem.zeroes(SignalPathViewV2);
    try std.testing.expectEqual(Status.ok, orca_player_signal_path_v2(runtime, player, &path_v2, captureSignalPathV2));
    try std.testing.expectEqual(path.bit_perfect_eligible, path_v2.base.bit_perfect_eligible);
    try std.testing.expectEqual(path.reason_count, path_v2.base.reason_count);
    try std.testing.expectEqual(@as(u8, 0), path_v2.has_parametric);
    try std.testing.expectEqual(@as(u8, 0), path_v2.has_replay_gain_track);
    try std.testing.expectEqual(std.mem.zeroes(DeviceFormatView), path_v2.device_format);

    try std.testing.expectEqual(Status.ok, orca_player_set_crossfeed(runtime, player, 1, 0.5));
    try std.testing.expectEqual(Status.ok, orca_player_signal_path(runtime, player, &path, captureSignalPath));
    try std.testing.expectEqual(@as(u8, 1), path.has_crossfeed);
    try std.testing.expectEqual(@as(f32, 0.5), path.crossfeed);
    try std.testing.expectEqual(@as(u32, 2), path.reason_count);
    try std.testing.expectEqual(exportSignalReason(.sample_processing), path.reasons[0]);
    try std.testing.expectEqual(exportSignalReason(.path_unknown), path.reasons[1]);
    try std.testing.expectEqual(@as(u8, 0), path.bit_perfect_eligible);

    try std.testing.expectEqual(Status.ok, orca_player_destroy(runtime, player));
    try std.testing.expectEqual(Status.stale_handle, orca_player_signal_path(runtime, player, &path, captureSignalPath));
}

test "ReplayGain settings read back clamped, refuse unknown values and reach the signal path" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));

    try std.testing.expectEqual(Status.ok, orca_player_set_replay_gain_mode(runtime, player, 3));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_replay_gain_mode(runtime, player, 4));
    try std.testing.expectEqual(Status.ok, orca_player_set_replay_gain_preamp(runtime, player, 40));
    try std.testing.expectEqual(Status.ok, orca_player_set_replay_gain_fallback(runtime, player, 0));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_set_replay_gain_fallback(runtime, player, 2));
    try std.testing.expectEqual(Status.ok, orca_player_set_peak_protection(runtime, player, 0));
    try std.testing.expectEqual(Status.invalid_argument, orca_player_replay_gain_settings(runtime, player, null));

    var settings: ReplayGainSettingsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_replay_gain_settings(runtime, player, &settings));
    try std.testing.expectEqual(ReplayGainSettingsView{ .preamp_db = 15, .mode = 3, .fallback = 0, .peak_protection = 0 }, settings);

    var path: SignalPathViewV2 = std.mem.zeroes(SignalPathViewV2);
    try std.testing.expectEqual(Status.ok, orca_player_signal_path_v2(runtime, player, &path, captureSignalPathV2));
    try std.testing.expectEqual(@as(f32, 15), path.preamp_db);
    try std.testing.expectEqual(@as(u8, 0), path.peak_protection);
    try std.testing.expectEqual(exportUntaggedFallback(.minus_6_db), path.fallback);
    try std.testing.expectEqual(@as(u8, 0), path.peak_limited);

    var armed: u8 = 9;
    try std.testing.expectEqual(Status.ok, orca_player_set_stop_after_current(runtime, player, 1));
    try std.testing.expectEqual(Status.ok, orca_player_stop_after_current(runtime, player, &armed));
    try std.testing.expectEqual(@as(u8, 1), armed);
    try std.testing.expectEqual(Status.invalid_argument, orca_player_stop_after_current(runtime, player, null));

    try std.testing.expectEqual(Status.ok, orca_player_destroy(runtime, player));
    try std.testing.expectEqual(Status.stale_handle, orca_player_set_replay_gain_preamp(runtime, player, 0));
    try std.testing.expectEqual(Status.stale_handle, orca_player_set_stop_after_current(runtime, player, 0));
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
    try std.testing.expectEqual(Status.invalid_argument, orca_library_request_artwork(runtime, library, 3, 1, &request));
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

const CapturedLyrics = struct {
    calls: usize = 0,
    source: u8 = 255,
    kind: u8 = 255,
    language: [3]u8 = @splat(0),
    language_length: usize = 0,
    line_count: usize = 0,
    first_start_ms: i64 = 0,
    last_start_ms: i64 = 0,
    first_text: [64]u8 = @splat(0),
    first_text_length: usize = 0,
};

fn captureLyrics(context: ?*anyopaque, view: *const LyricsView) callconv(.c) void {
    const captured: *CapturedLyrics = @ptrCast(@alignCast(context.?));
    captured.calls += 1;
    captured.source = view.source;
    captured.kind = view.kind;
    captured.language_length = @min(view.language.length, captured.language.len);
    @memcpy(captured.language[0..captured.language_length], view.language.pointer[0..captured.language_length]);
    captured.line_count = view.line_count;
    if (view.line_count == 0) return;
    const lines = view.lines[0..view.line_count];
    captured.first_start_ms = lines[0].start_ms;
    captured.last_start_ms = lines[lines.len - 1].start_ms;
    captured.first_text_length = @min(lines[0].text.length, captured.first_text.len);
    @memcpy(captured.first_text[0..captured.first_text_length], lines[0].text.pointer[0..captured.first_text_length]);
}

fn finishedLyricsJob(runtime: *Runtime, fixture: []const u8, audio_name: []const u8, sidecar: ?[]const u8, name: [:0]const u8) !Handle {
    const box = runtimeBox(runtime).?;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try core.runtime_tests.copyFixtureInto(temporary.dir, fixture, audio_name);
    if (sidecar) |path| try core.runtime_tests.copyFixtureInto(temporary.dir, path, "a.lrc");
    const scanned = try core.runtime_tests.scannedTempFolder(&box.runtime, &temporary, name);
    const track_ids = try core.runtime_tests.allTrackIds(&box.runtime, scanned);
    defer std.testing.allocator.free(track_ids);
    try std.testing.expectEqual(@as(usize, 1), track_ids.len);
    var lyrics_job: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_lyrics(runtime, exportLibraryHandle(scanned), track_ids[0], 0, &lyrics_job));
    try std.testing.expectEqual(job.State.succeeded, try core.runtime_tests.awaitJob(&box.runtime, importJob(lyrics_job)));
    return lyrics_job;
}

test "a lyrics job hands its synced lines over once through the C ABI, and plain lines start at -1" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);

    const synced = try finishedLyricsJob(runtime, "fixtures/audio/fingerprint-reference.mp3", "a.mp3", "fixtures/audio/fingerprint-reference.lrc", "file:orca-c-api-lyrics-sidecar?mode=memory&cache=shared");
    var outcome: u8 = 255;
    try std.testing.expectEqual(Status.ok, orca_job_lyrics_outcome(runtime, synced, &outcome));
    try std.testing.expectEqual(exportLyricsOutcome(.local), outcome);
    var captured: CapturedLyrics = .{};
    try std.testing.expectEqual(Status.ok, orca_job_lyrics(runtime, synced, &captured, captureLyrics));
    try std.testing.expectEqual(@as(usize, 1), captured.calls);
    try std.testing.expectEqual(exportLyricsSource(.sidecar), captured.source);
    try std.testing.expectEqual(exportLyricsKind(.synced), captured.kind);
    try std.testing.expectEqual(@as(usize, 0), captured.language_length);
    try std.testing.expectEqual(@as(usize, 4), captured.line_count);
    try std.testing.expectEqual(@as(i64, 1000), captured.first_start_ms);
    try std.testing.expectEqual(@as(i64, 8000), captured.last_start_ms);
    try std.testing.expectEqualStrings("One second in", captured.first_text[0..captured.first_text_length]);
    captured = .{};
    try std.testing.expectEqual(Status.not_found, orca_job_lyrics(runtime, synced, &captured, captureLyrics));
    try std.testing.expectEqual(@as(usize, 0), captured.calls);

    const plain = try finishedLyricsJob(runtime, "fixtures/audio/lyrics-plain.m4a", "a.m4a", null, "file:orca-c-api-lyrics-plain?mode=memory&cache=shared");
    try std.testing.expectEqual(Status.ok, orca_job_lyrics(runtime, plain, &captured, captureLyrics));
    try std.testing.expectEqual(exportLyricsSource(.embedded), captured.source);
    try std.testing.expectEqual(exportLyricsKind(.plain), captured.kind);
    try std.testing.expectEqual(@as(usize, 2), captured.line_count);
    try std.testing.expectEqual(@as(i64, -1), captured.first_start_ms);
    try std.testing.expectEqual(@as(i64, -1), captured.last_start_ms);

    const tagged = try finishedLyricsJob(runtime, "fixtures/audio/lyrics-sylt.mp3", "a.mp3", null, "file:orca-c-api-lyrics-sylt?mode=memory&cache=shared");
    captured = .{};
    try std.testing.expectEqual(Status.ok, orca_job_lyrics(runtime, tagged, &captured, captureLyrics));
    try std.testing.expectEqual(exportLyricsKind(.synced), captured.kind);
    try std.testing.expectEqualStrings("eng", captured.language[0..captured.language_length]);
}

test "lyrics calls refuse null outputs, unknown flags, fetching without an identity, stale jobs and jobs of another kind" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-lyrics-arguments?mode=memory&cache=shared", &library));
    var lyrics_job: Handle = undefined;
    var outcome: u8 = 255;
    var captured: CapturedLyrics = .{};

    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_lyrics(null, library, 1, 0, &lyrics_job));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_lyrics_outcome(null, library, &outcome));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_lyrics(null, library, &captured, captureLyrics));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_lyrics(runtime, library, 1, 0, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_lyrics(runtime, library, 1, 2, &lyrics_job));
    try std.testing.expectEqualStrings("orca_library_start_lyrics: flags holds an unknown bit", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(Status.invalid_state, orca_library_start_lyrics(runtime, library, 1, lyrics_fetch_flag, &lyrics_job));
    try std.testing.expectEqualStrings("orca_library_start_lyrics: ClientIdentityRequired", std.mem.span(orca_runtime_last_error(runtime)));

    const stale: Handle = .{ .index = 7, .generation = 3 };
    try std.testing.expectEqual(Status.stale_handle, orca_job_lyrics_outcome(runtime, stale, &outcome));
    try std.testing.expectEqual(Status.stale_handle, orca_job_lyrics(runtime, stale, &captured, captureLyrics));

    try std.testing.expectEqual(Status.ok, orca_library_start_lyrics(runtime, library, 1_000_000, 0, &lyrics_job));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_lyrics_outcome(runtime, lyrics_job, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_lyrics(runtime, lyrics_job, &captured, null));
    const box = runtimeBox(runtime).?;
    try std.testing.expectEqual(job.State.succeeded, try core.runtime_tests.awaitJob(&box.runtime, importJob(lyrics_job)));
    try std.testing.expectEqual(Status.ok, orca_job_lyrics_outcome(runtime, lyrics_job, &outcome));
    try std.testing.expectEqual(exportLyricsOutcome(.not_found), outcome);
    try std.testing.expectEqual(Status.not_found, orca_job_lyrics(runtime, lyrics_job, &captured, captureLyrics));
    var snapshot: JobSnapshot = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_snapshot_get(runtime, lyrics_job, &snapshot));
    try std.testing.expectEqual(@as(u8, 9), snapshot.kind);

    var projection: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_projection(runtime, library, &projection));
    _ = try core.runtime_tests.awaitJob(&box.runtime, importJob(projection));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_lyrics_outcome(runtime, projection, &outcome));
    try std.testing.expectEqualStrings("orca_job_lyrics_outcome: NotALyricsJob", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_lyrics(runtime, projection, &captured, captureLyrics));
    try std.testing.expectEqual(@as(usize, 0), captured.calls);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

const RelatedPhotoCredit = struct {
    calls: usize = 0,
    source: u8 = 0,
    fetched_at: i64 = 0,
    licence: [32]u8 = undefined,
    licence_len: usize = 0,
    credit: [32]u8 = undefined,
    credit_len: usize = 0,
};

fn captureRelatedPhotoCredit(context: ?*anyopaque, view: *const RelatedArtistPhotoInfoView) callconv(.c) void {
    const credit: *RelatedPhotoCredit = @ptrCast(@alignCast(context.?));
    credit.calls += 1;
    credit.source = view.photo_source;
    credit.fetched_at = view.fetched_at;
    credit.licence_len = view.photo_licence.length;
    @memcpy(credit.licence[0..credit.licence_len], view.photo_licence.pointer[0..credit.licence_len]);
    credit.credit_len = view.photo_credit.length;
    @memcpy(credit.credit[0..credit.credit_len], view.photo_credit.pointer[0..credit.credit_len]);
}

fn countArtistInfo(context: ?*anyopaque, view: *const ArtistInfoView) callconv(.c) void {
    _ = view;
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
}

fn countArtistLinks(context: ?*anyopaque, links: [*]const ArtistLinkView, count: usize) callconv(.c) void {
    _ = links;
    const total: *usize = @ptrCast(@alignCast(context.?));
    total.* += count;
}

test "artist info and love calls refuse null outputs, out-of-range flags, bad languages, unknown artists and jobs of another kind" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-artist-info-arguments?mode=memory&cache=shared", &library));
    var started: Handle = undefined;
    var outcome: u8 = 255;
    var calls: usize = 0;
    var change: ChangeCount = undefined;
    var loved: u8 = 255;
    const ids = [_]i64{1};
    var options: ArtistInfoOptionsView = .{ .language = .{ .pointer = null, .length = 0 }, .force = 0, .offline = 1 };

    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_artist_info(null, library, 1, &options, &started));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_artist_info(runtime, library, 1, &options, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_artist_info(runtime, library, 1, null, &started));
    options.force = 2;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_artist_info(runtime, library, 1, &options, &started));
    options.force = 0;
    options.language = .{ .pointer = null, .length = 2 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_artist_info(runtime, library, 1, &options, &started));
    options.language = .{ .pointer = "en.evil.org", .length = 11 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_artist_info(runtime, library, 1, &options, &started));
    try std.testing.expectEqualStrings("orca_library_start_artist_info: InvalidLanguage", std.mem.span(orca_runtime_last_error(runtime)));
    options.language = .{ .pointer = null, .length = 0 };
    try std.testing.expectEqual(Status.not_found, orca_library_start_artist_info(runtime, library, 1, &options, &started));
    try std.testing.expectEqualStrings("orca_library_start_artist_info: UnknownArtist", std.mem.span(orca_runtime_last_error(runtime)));

    try std.testing.expectEqual(Status.invalid_argument, orca_job_artist_info_outcome(runtime, library, null));
    const stale: Handle = .{ .index = 7, .generation = 3 };
    try std.testing.expectEqual(Status.stale_handle, orca_job_artist_info_outcome(runtime, stale, &outcome));
    var projection: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_projection(runtime, library, &projection));
    _ = try core.runtime_tests.awaitJob(&runtimeBox(runtime).?.runtime, importJob(projection));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_artist_info_outcome(runtime, projection, &outcome));
    try std.testing.expectEqualStrings("orca_job_artist_info_outcome: NotAnArtistInfoJob", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(@as(u8, 255), outcome);
    var stores: u32 = 0;
    try std.testing.expectEqual(Status.invalid_argument, orca_job_artist_info_stores(runtime, projection, &stores));
    try std.testing.expectEqualStrings("orca_job_artist_info_stores: NotAnArtistInfoJob", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(Status.stale_handle, orca_job_artist_info_stores(runtime, stale, &stores));

    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_info(runtime, library, 1, &calls, null));
    try std.testing.expectEqual(Status.not_found, orca_library_artist_info(runtime, library, 1, &calls, countArtistInfo));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_photo(runtime, library, 1, &calls, null));
    try std.testing.expectEqual(Status.not_found, orca_library_artist_photo(runtime, library, 1, &calls, countImage));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_links(runtime, library, 1, &calls, null));
    try std.testing.expectEqual(Status.ok, orca_library_artist_links(runtime, library, 1, &calls, countArtistLinks));
    try std.testing.expectEqual(@as(usize, 0), calls);

    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_artist_love(runtime, library, &ids, 1, 1, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_artist_love(runtime, library, &ids, 1, 2, &change));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_artist_love(runtime, library, null, 1, 1, &change));
    try std.testing.expectEqual(Status.ok, orca_library_set_artist_love(runtime, library, &ids, 1, 1, &change));
    try std.testing.expectEqual(@as(u32, 0), change.updated);
    try std.testing.expectEqual(@as(u32, 1), change.skipped);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_artist_loved(runtime, library, 1, null));
    try std.testing.expectEqual(Status.ok, orca_library_artist_loved(runtime, library, 1, &loved));
    try std.testing.expectEqual(@as(u8, 0), loved);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

fn countReleaseInfo(context: ?*anyopaque, view: *const ReleaseInfoView) callconv(.c) void {
    _ = view;
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
}

fn countRelatedArtists(context: ?*anyopaque, artists: [*]const RelatedArtistView, count: usize) callconv(.c) void {
    _ = artists;
    const total: *usize = @ptrCast(@alignCast(context.?));
    total.* += count;
}

test "release info, related artist and genre fill calls refuse null outputs, out-of-range flags, unknown releases and jobs of another kind" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-release-info-arguments?mode=memory&cache=shared", &library));
    var started: Handle = undefined;
    var outcome: u8 = 255;
    var calls: usize = 0;
    var options: ReleaseInfoOptionsView = .{ .language = .{ .pointer = null, .length = 0 }, .force = 0, .offline = 1 };

    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_release_info(runtime, library, 1, &options, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_release_info(runtime, library, 1, null, &started));
    options.offline = 2;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_release_info(runtime, library, 1, &options, &started));
    options.offline = 1;
    try std.testing.expectEqual(Status.not_found, orca_library_start_release_info(runtime, library, 1, &options, &started));
    try std.testing.expectEqualStrings("orca_library_start_release_info: UnknownRelease", std.mem.span(orca_runtime_last_error(runtime)));

    try std.testing.expectEqual(Status.invalid_argument, orca_job_release_info_outcome(runtime, library, null));
    var projection: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_projection(runtime, library, &projection));
    _ = try core.runtime_tests.awaitJob(&runtimeBox(runtime).?.runtime, importJob(projection));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_release_info_outcome(runtime, projection, &outcome));
    try std.testing.expectEqualStrings("orca_job_release_info_outcome: NotAReleaseInfoJob", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(@as(u8, 255), outcome);

    try std.testing.expectEqual(Status.invalid_argument, orca_library_release_info(runtime, library, 1, &calls, null));
    try std.testing.expectEqual(Status.not_found, orca_library_release_info(runtime, library, 1, &calls, countReleaseInfo));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_related_artists(runtime, library, 1, &calls, null));
    try std.testing.expectEqual(Status.ok, orca_library_related_artists(runtime, library, 1, &calls, countRelatedArtists));
    try std.testing.expectEqual(@as(usize, 0), calls);

    const related_mbid = "cccccccc-0000-4000-8000-000000000003";
    try std.testing.expectEqual(Status.invalid_argument, orca_library_related_artist_photo(runtime, library, related_mbid, related_mbid.len, &calls, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_related_artist_photo(runtime, library, null, 4, &calls, countImage));
    try std.testing.expectEqual(Status.not_found, orca_library_related_artist_photo(runtime, library, related_mbid, related_mbid.len, &calls, countImage));
    var credit: RelatedPhotoCredit = .{};
    try std.testing.expectEqual(Status.invalid_argument, orca_library_related_artist_photo_info(runtime, library, related_mbid, related_mbid.len, &credit, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_related_artist_photo_info(runtime, library, null, 4, &credit, captureRelatedPhotoCredit));
    try std.testing.expectEqual(Status.not_found, orca_library_related_artist_photo_info(runtime, library, related_mbid, related_mbid.len, &credit, captureRelatedPhotoCredit));
    const library_database = try core.runtime.libraryDatabase(&runtimeBox(runtime).?.runtime, importLibrary(library));
    const png = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 0 };
    try library_database.artist_info.storeRelatedPhoto(related_mbid, &.{
        .image = .{ .bytes = &png, .mime_type = "image/png" },
        .record = .{ .licence = "CC BY 4.0", .credit = "A. Photographer" },
    }, 10);
    try std.testing.expectEqual(Status.ok, orca_library_related_artist_photo(runtime, library, "CCCCCCCC-0000-4000-8000-000000000003", related_mbid.len, &calls, countImage));
    try std.testing.expectEqual(@as(usize, 1), calls);
    calls = 0;
    try std.testing.expectEqual(Status.ok, orca_library_related_artist_photo_info(runtime, library, related_mbid, related_mbid.len, &credit, captureRelatedPhotoCredit));
    try std.testing.expectEqual(@as(usize, 1), credit.calls);
    try std.testing.expectEqual(@as(u8, 1), credit.source);
    try std.testing.expectEqual(@as(i64, 10), credit.fetched_at);
    try std.testing.expectEqualStrings("CC BY 4.0", credit.licence[0..credit.licence_len]);
    try std.testing.expectEqualStrings("A. Photographer", credit.credit[0..credit.credit_len]);

    var fill: GenreFillView = .{ .musicbrainz = 0 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_genre_fill(runtime, library, null));
    try std.testing.expectEqual(Status.ok, orca_library_genre_fill(runtime, library, &fill));
    try std.testing.expectEqual(@as(u8, 1), fill.musicbrainz);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_genre_fill(runtime, library, null));
    fill.musicbrainz = 2;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_genre_fill(runtime, library, &fill));
    fill.musicbrainz = 0;
    try std.testing.expectEqual(Status.ok, orca_library_set_genre_fill(runtime, library, &fill));
    fill.musicbrainz = 1;
    try std.testing.expectEqual(Status.ok, orca_library_genre_fill(runtime, library, &fill));
    try std.testing.expectEqual(@as(u8, 0), fill.musicbrainz);

    var fill_options: GenreFillOptionsView = .{ .limit = 0, .offline = 1 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_genre_fill(runtime, library, &fill_options, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_genre_fill(runtime, library, null, &started));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_genre_fill(runtime, library, &fill_options, &started));
    try std.testing.expectEqualStrings("orca_library_start_genre_fill: InvalidLimit", std.mem.span(orca_runtime_last_error(runtime)));
    fill_options.limit = 1;
    fill_options.offline = 2;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_genre_fill(runtime, library, &fill_options, &started));
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
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

test "a relocate onto another root's folder is an invalid argument, and over an unfinished or unreconciled write its own status" {
    try std.testing.expectEqual(Status.invalid_argument, mapError(error.RootPathOverlaps));
    try std.testing.expectEqual(Status.busy, mapError(error.MutationInProgress));
    try std.testing.expectEqual(Status.needs_reconciliation, mapError(error.MutationNeedsReconciliation));
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
    const too_many_edits: [max_track_edits + 1]TrackEditView = @splat(edit);
    const too_many_ids: [max_page + 1]i64 = @splat(1);
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
    try std.testing.expectEqual(Status.invalid_argument, orca_library_query_tag_write_genres(runtime, library, 1, 1, &calls, null));
    try std.testing.expectEqual(Status.not_found, orca_library_query_tag_write_genres(runtime, library, 1, 1, &calls, countGenres));
    try std.testing.expectEqual(@as(usize, 0), calls);

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
    try std.testing.expectEqual(Status.stale_handle, orca_library_query_tag_write_genres(runtime, library, 1, 1, &calls, countGenres));
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
    var genre_calls: usize = 0;
    try std.testing.expectEqual(Status.not_found, orca_library_query_tag_write_genres(runtime, library, plan.plan_id, plan.first_file_id, &genre_calls, countGenres));
    try std.testing.expectEqual(@as(usize, 0), genre_calls);

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

test "a folder Orca cannot create files in is skipped, and a write that failed there reports its file and reason" {
    if (builtin.os.tag != .linux or std.os.linux.geteuid() == 0) return error.SkipZigTest;
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try core.runtime_tests.tempDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    try core.runtime_tests.copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "b.flac");
    const scanned = try core.runtime_tests.scannedTempFolder(&box.runtime, &temporary, database_path);
    const library = exportLibraryHandle(scanned);
    const track_ids = try core.runtime_tests.allTrackIds(&box.runtime, scanned);
    defer std.testing.allocator.free(track_ids);
    const title = "C ABI Title";
    const edited = try box.runtime.libraryEditTracks(scanned, track_ids, &.{.{ .field = .title, .value = title }});
    defer edited.deinit();

    var held: CapturedPlan = .{ .title = title };
    try std.testing.expectEqual(Status.ok, orca_library_plan_tag_write(runtime, library, edited.ids.ptr, edited.ids.len, &held, capturePlan));
    try std.testing.expectEqual(@as(usize, 1), held.file_count);
    try temporary.parent_dir.setFilePermissions(std.testing.io, &temporary.sub_path, .fromMode(0o555), .{});
    defer temporary.parent_dir.setFilePermissions(std.testing.io, &temporary.sub_path, .default_dir, .{}) catch {};

    var skipped: CapturedPlan = .{ .title = title };
    try std.testing.expectEqual(Status.ok, orca_library_plan_tag_write(runtime, library, edited.ids.ptr, edited.ids.len, &skipped, capturePlan));
    try std.testing.expectEqual(@as(u64, 0), skipped.plan_id);
    try std.testing.expectEqual(@as(usize, 1), skipped.skip_count);
    try std.testing.expectEqual(@as(u8, 3), skipped.skip_reason);

    var failed: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_tag_write(runtime, library, held.plan_id, &held.digest, &failed));
    try std.testing.expectEqual(job.State.failed, try core.runtime_tests.awaitJob(&box.runtime, importJob(failed)));
    var failure: TagWriteFailureView = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_tag_write_failure(runtime, failed, &failure));
    try std.testing.expectEqual(held.first_file_id, failure.file_id);
    try std.testing.expectEqual(@as(u32, 0), failure.action_index);
    try std.testing.expectEqual(@as(u8, 0), failure.reason);
    try std.testing.expectEqual(Status.invalid_argument, orca_job_tag_write_failure(runtime, failed, null));

    try temporary.parent_dir.setFilePermissions(std.testing.io, &temporary.sub_path, .default_dir, .{});
    var writable: CapturedPlan = .{ .title = title };
    try std.testing.expectEqual(Status.ok, orca_library_plan_tag_write(runtime, library, edited.ids.ptr, edited.ids.len, &writable, capturePlan));
    var written: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_tag_write(runtime, library, writable.plan_id, &writable.digest, &written));
    try std.testing.expectEqual(job.State.succeeded, try core.runtime_tests.awaitJob(&box.runtime, importJob(written)));
    try std.testing.expectEqual(Status.not_found, orca_job_tag_write_failure(runtime, written, &failure));

    const scan = try box.runtime.startLibraryScan(scanned, .{});
    try std.testing.expectEqual(job.State.succeeded, try core.runtime_tests.awaitJob(&box.runtime, scan));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_tag_write_failure(runtime, exportJobHandle(scan), &failure));
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
    first_file_id: i64 = 0,
};

fn capturePlan(context: ?*anyopaque, plan: *const TagWritePlanView) callconv(.c) void {
    const captured: *CapturedPlan = @ptrCast(@alignCast(context.?));
    captured.calls += 1;
    captured.plan_id = plan.plan_id;
    captured.digest = plan.digest;
    captured.file_count = plan.file_count;
    captured.skip_count = plan.skip_count;
    captured.conflict_count = plan.conflict_count;
    if (plan.file_count != 0) captured.first_file_id = plan.files[0].file_id;
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

fn countGenres(context: ?*anyopaque, genres: *const TagWriteGenresView) callconv(.c) void {
    _ = genres;
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

    keyring.result = @backingInt(CredentialResult.not_found);
    try std.testing.expectEqual(@as(?[]u8, null), try hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token"));
    try expectNoSecret(&backing, "host-secret");

    keyring.result = @backingInt(CredentialResult.unavailable);
    try std.testing.expectError(error.CredentialUnavailable, hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token"));
    try expectNoSecret(&backing, "host-secret");

    keyring.result = @backingInt(CredentialResult.too_large);
    try std.testing.expectError(error.CredentialTooLarge, hostCredential(&slot, fixed.allocator(), "org.listenbrainz", "user-token"));
    try expectNoSecret(&backing, "host-secret");

    keyring.result = @backingInt(CredentialResult.found);
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
        "http://[::1]:9/acoustid",
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
    try std.testing.expectEqual(Status.invalid_argument, orca_runtime_set_provider_server(runtime, 99, "https://example.org"));
    try std.testing.expectEqualStrings(
        "orca_runtime_set_provider_server: unknown provider service",
        std.mem.span(orca_runtime_last_error(runtime)),
    );

    try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 0, "https://lb.example.org"));
    try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 2, "https://acoustid.example.org/v2"));
    try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 3, "http://localhost:9"));
    try std.testing.expectEqualStrings("https://lb.example.org", box.runtime.listenbrainz_server.view());
    try std.testing.expectEqualStrings("https://acoustid.example.org/v2", box.runtime.acoustid_server.view());
    try std.testing.expectEqualStrings("http://localhost:9", box.runtime.coverartarchive_server.view());

    try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 4, "http://127.0.0.1:9/lrclib"));
    try std.testing.expectEqualStrings("http://127.0.0.1:9/lrclib", box.runtime.lrclib_server.view());

    for (0..5) |service| try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, @intCast(service), null));
    try std.testing.expectEqualStrings(providers.listenbrainz.default_server, box.runtime.listenbrainz_server.view());
    try std.testing.expectEqualStrings(providers.musicbrainz.default_server, box.runtime.musicbrainz_server.view());
    try std.testing.expectEqualStrings(providers.acoustid.default_server, box.runtime.acoustid_server.view());
    try std.testing.expectEqualStrings(providers.coverartarchive.default_server, box.runtime.coverartarchive_server.view());
    try std.testing.expectEqualStrings(providers.lrclib.default_server, box.runtime.lrclib_server.view());
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
    var stats_v2: MatchStatsViewV2 = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_match_stats_v2(rig.runtime, matching, &stats_v2));
    try std.testing.expectEqual(stats, stats_v2.base);
    try std.testing.expectEqual(@as(u64, 0), stats_v2.releases_to_review);
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
    try std.testing.expectEqual(@backingInt(IdSource.match), recording.source);

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

test "a match through the C ABI refuses bad options and a second job, a job that is not a match has empty match stats, and only a finished Match Album names its Release" {
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

    var release_id: i64 = -1;
    var has_release_id: u8 = 1;
    try std.testing.expectEqual(Status.invalid_argument, orca_job_match_release(rig.runtime, matching, null, &has_release_id));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_match_release(rig.runtime, matching, &release_id, null));
    try std.testing.expectEqual(Status.stale_handle, orca_job_match_release(rig.runtime, .{ .index = 7, .generation = 3 }, &release_id, &has_release_id));
    try std.testing.expectEqual(Status.ok, orca_job_match_release(rig.runtime, matching, &release_id, &has_release_id));
    try std.testing.expectEqual(@as(u8, 0), has_release_id);
    try std.testing.expectEqual(@as(i64, 0), release_id);
    try std.testing.expectEqual(Status.ok, orca_job_match_release(rig.runtime, scan, &release_id, &has_release_id));
    try std.testing.expectEqual(@as(u8, 0), has_release_id);
    rig.musicbrainz.hang_from = null;
    _ = try provider_tests.addAlbumTrack(rig.library_database, album, "Pink Moon");
    options = zero;
    options.has_release_id = 1;
    options.release_id = album;
    var album_match: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_start_match(rig.runtime, rig.library, &options, &album_match));
    try std.testing.expectEqual(job.State.succeeded, try rig.finish(album_match));
    try std.testing.expectEqual(Status.ok, orca_job_match_release(rig.runtime, album_match, &release_id, &has_release_id));
    try std.testing.expectEqual(@as(u8, 1), has_release_id);
    try std.testing.expectEqual(album, release_id);

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
    try std.testing.expectEqual(@backingInt(IdSource.tag), recording.source);
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
    var keyring: FakeKeyring = .{ .result = @backingInt(CredentialResult.not_found), .secret = "userkey" };
    try std.testing.expectEqual(Status.ok, orca_runtime_set_credential_callback(rig.runtime, FakeKeyring.lookup, &keyring));
    const northern_sky = try rig.addUntaggedTone("northern.wav", 440, "Northern Sky");

    var count: u64 = 7;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_acoustid_submittable_count(rig.runtime, rig.library, null));
    try std.testing.expectEqual(Status.stale_handle, orca_library_acoustid_submittable_count(rig.runtime, .{ .index = 7, .generation = 3 }, &count));
    try std.testing.expectEqual(Status.ok, orca_library_acoustid_submittable_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 0), count);
    count = 7;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_acoustid_submitted_count(rig.runtime, rig.library, null));
    try std.testing.expectEqual(Status.stale_handle, orca_library_acoustid_submitted_count(rig.runtime, .{ .index = 7, .generation = 3 }, &count));
    try std.testing.expectEqual(Status.ok, orca_library_acoustid_submitted_count(rig.runtime, rig.library, &count));
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

    keyring.result = @backingInt(CredentialResult.unavailable);
    try std.testing.expectEqual(Status.ok, orca_library_start_acoustid_submission(rig.runtime, rig.library, &submitting));
    try std.testing.expectEqual(job.State.failed, try rig.finish(submitting));
    try std.testing.expectEqual(Status.ok, orca_job_submission_stats(rig.runtime, submitting, &stats));
    try std.testing.expectEqual(exportSubmissionOutcome(.credential_unavailable), stats.outcome);
    try std.testing.expectEqual(@as(u8, 8), stats.outcome);
    try std.testing.expectEqual(@as(u32, 0), rig.acoustid.submissions.load(.acquire));

    keyring.result = @backingInt(CredentialResult.too_large);
    try std.testing.expectEqual(Status.ok, orca_library_start_acoustid_submission(rig.runtime, rig.library, &submitting));
    try std.testing.expectEqual(job.State.failed, try rig.finish(submitting));
    try std.testing.expectEqual(Status.ok, orca_job_submission_stats(rig.runtime, submitting, &stats));
    try std.testing.expectEqual(exportSubmissionOutcome(.credential_unavailable), stats.outcome);
    try std.testing.expectEqual(@as(u32, 0), rig.acoustid.submissions.load(.acquire));
    try std.testing.expectEqual(Status.ok, orca_library_acoustid_submittable_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 1), count);

    keyring.result = @backingInt(CredentialResult.found);
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
    try std.testing.expectEqual(Status.ok, orca_library_acoustid_submitted_count(rig.runtime, rig.library, &count));
    try std.testing.expectEqual(@as(u64, 1), count);
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

const CapturedScrobblerStatus = struct {
    calls: usize = 0,
    view: ScrobblerStatusView = std.mem.zeroes(ScrobblerStatusView),
    user_name: CapturedText = .{},
    last_error: CapturedText = .{},
};

fn captureScrobblerStatus(context: ?*anyopaque, status: *const ScrobblerStatusView) callconv(.c) void {
    const captured: *CapturedScrobblerStatus = @ptrCast(@alignCast(context.?));
    captured.calls += 1;
    captured.view = status.*;
    captured.user_name.set(status.user_name);
    captured.last_error.set(status.last_error);
}

const ScrobbleRig = struct {
    transport: network.testing.ScriptedTransport = .{
        .otherwise = .{ .respond = .{ .body = "{\"valid\":true,\"user_name\":\"listener\"}" } },
    },
    clock: network.testing.TestClock = .{ .wall_offset_ms = 1_800_000_000_000 },
    sample_clock: network.testing.TestClock = .{ .wall_offset_ms = 1_700_000_000_000 },
    keyring: FakeKeyring = .{},
    runtime: *Runtime,
    library: Handle = undefined,
    track_id: i64 = 0,

    fn init(self: *ScrobbleRig, uri: [*:0]const u8) !void {
        const runtime = orca_runtime_create() orelse return error.OutOfMemory;
        self.* = .{ .runtime = runtime };
        errdefer self.deinit();
        const box = runtimeBox(runtime).?;
        try std.testing.expectEqual(Status.ok, orca_runtime_set_credential_callback(runtime, FakeKeyring.lookup, &self.keyring));
        try std.testing.expectEqual(Status.ok, orca_runtime_set_client_identity(runtime, "Host", "1.0", "https://host.invalid"));
        try std.testing.expectEqual(Status.ok, orca_runtime_set_provider_server(runtime, 0, "http://127.0.0.1:8080"));
        box.runtime.listen_hooks = .{
            .transport = self.transport.transport(),
            .clock = self.clock.clock(),
            .wall_clock = self.clock.wallClock(),
            .sample_clock = provider_tests.sampleClock(&self.sample_clock),
            .poll_ms = 5,
        };
        try std.testing.expectEqual(Status.ok, orca_library_open(runtime, uri, &self.library));
        const library_database = try core.runtime.libraryDatabase(&box.runtime, importLibrary(self.library));
        self.track_id = try provider_tests.addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);
    }

    fn deinit(self: *ScrobbleRig) void {
        orca_runtime_destroy(self.runtime);
        self.transport.deinit();
    }

    fn status(self: *ScrobbleRig) !CapturedScrobblerStatus {
        var captured: CapturedScrobblerStatus = .{};
        try std.testing.expectEqual(Status.ok, orca_library_scrobbler_status(self.runtime, self.library, &captured, captureScrobblerStatus));
        try std.testing.expectEqual(@as(usize, 1), captured.calls);
        return captured;
    }

    fn hearListen(self: *ScrobbleRig) !void {
        const box = runtimeBox(self.runtime).?;
        var player: Handle = undefined;
        try std.testing.expectEqual(Status.ok, orca_player_create(self.runtime, &player));
        try std.testing.expectEqual(Status.ok, orca_player_set_library(self.runtime, player, self.library));
        const object_value = try box.runtime.players.get(importPlayer(player));
        try object_value.queue.replace(&.{.{ .library = importLibrary(self.library), .track_id = self.track_id }}, 0);
        object_value.queue.noteEntrySerial(7, 0);
        object_value.player.published_sample_rate.store(1000, .release);
        object_value.player.published_frame_count.store(180_000, .release);
        object_value.player.audible_entry_serial.store(7, .release);
        object_value.player.position_frames.store(0, .release);
        object_value.player.state.store(.playing, .release);
        var elapsed: u64 = 0;
        while (elapsed < 100_000) : (elapsed += 100) {
            self.sample_clock.advance(100);
            _ = object_value.player.position_frames.fetchAdd(100, .acq_rel);
            _ = box.runtime.processNextCommand();
        }
        var deadline: core.runtime_tests.TestDeadline = .init(5_000);
        while ((try self.status()).view.recorded_total < 1) {
            if (!deadline.tick()) return error.ListenNotRecorded;
        }
    }

    fn awaitStatus(self: *ScrobbleRig, comptime reached: fn (*const CapturedScrobblerStatus) bool) !CapturedScrobblerStatus {
        var deadline: core.runtime_tests.TestDeadline = .init(5_000);
        while (true) {
            const captured = try self.status();
            if (reached(&captured)) return captured;
            if (!deadline.tick()) return error.ScrobblerNeverReachedState;
        }
    }

    fn lastError(self: *ScrobbleRig) []const u8 {
        return std.mem.span(orca_runtime_last_error(self.runtime));
    }
};

fn deliveredWithUser(captured: *const CapturedScrobblerStatus) bool {
    return captured.view.delivered_total == 1 and std.mem.eql(u8, captured.user_name.text(), "listener");
}

fn heldOffline(captured: *const CapturedScrobblerStatus) bool {
    return captured.view.pending == 1 and captured.view.state == exportScrobblerState(.offline);
}

fn deliveredOnce(captured: *const CapturedScrobblerStatus) bool {
    return captured.view.delivered_total == 1 and captured.view.pending == 0;
}

test "scrobbling turned on through the C ABI validates the host's token and delivers a heard listen to ListenBrainz" {
    var rig: ScrobbleRig = undefined;
    try rig.init("file:orca-c-api-scrobbled?mode=memory&cache=shared");
    defer rig.deinit();

    var before = try rig.status();
    try std.testing.expectEqual(@as(u8, 0), before.view.enabled);
    try std.testing.expectEqual(exportScrobblerState(.disabled), before.view.state);

    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, rig.library, 1, 0, 0));
    try std.testing.expectEqual(Status.ok, orca_library_scrobbler_credentials_changed(rig.runtime, rig.library));
    try rig.hearListen();

    const delivered = try rig.awaitStatus(deliveredWithUser);
    try std.testing.expectEqual(@as(u8, 1), delivered.view.enabled);
    try std.testing.expectEqual(@as(u64, 0), delivered.view.pending);
    try std.testing.expectEqual(@as(u64, 1), delivered.view.recorded_total);
    try std.testing.expectEqual(@as(u64, 0), delivered.view.dropped);
    try std.testing.expectEqual(@as(u8, 0), delivered.view.has_blocked_until);
    try std.testing.expectEqualStrings("", delivered.last_error.text());
    try std.testing.expectEqualStrings("Token host-secret", rig.transport.lastAuthorization());
    try std.testing.expect(std.mem.endsWith(u8, rig.transport.lastUrl(), "/1/submit-listens"));
    try std.testing.expectEqualStrings("org.listenbrainz", rig.keyring.serviceName());
    try std.testing.expectEqualStrings("user-token", rig.keyring.accountName());

    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, rig.library, 0, 0, 0));
    before = try rig.status();
    try std.testing.expectEqual(@as(u8, 0), before.view.enabled);
    try std.testing.expectEqual(exportScrobblerState(.disabled), before.view.state);
    try std.testing.expectEqual(@as(u64, 1), before.view.delivered_total);
}

test "offline scrobbling keeps a heard listen pending without any request, and going online sends it" {
    var rig: ScrobbleRig = undefined;
    try rig.init("file:orca-c-api-scrobbled-offline?mode=memory&cache=shared");
    defer rig.deinit();

    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, rig.library, 1, 1, 1));
    try std.testing.expectEqual(Status.ok, orca_library_scrobbler_credentials_changed(rig.runtime, rig.library));
    try rig.hearListen();

    const held = try rig.awaitStatus(heldOffline);
    try std.testing.expectEqual(@as(u8, 1), held.view.enabled);
    try std.testing.expectEqual(@as(u64, 0), held.view.delivered_total);
    try std.testing.expectEqualStrings("", held.user_name.text());
    try std.testing.expectEqual(@as(u32, 0), rig.transport.requestCount());

    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, rig.library, 1, 0, 0));
    _ = try rig.awaitStatus(deliveredOnce);
    try std.testing.expect(rig.transport.requestCount() >= 1);
}

test "scrobbling refuses flags other than 0 or 1, a host that has not named itself, a second Library and a null callback" {
    var rig: ScrobbleRig = undefined;
    try rig.init("file:orca-c-api-scrobble-refusals?mode=memory&cache=shared");
    defer rig.deinit();

    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_scrobbling(rig.runtime, rig.library, 2, 0, 0));
    try std.testing.expectEqualStrings("orca_library_set_scrobbling: enabled must be 0 or 1", rig.lastError());
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_scrobbling(rig.runtime, rig.library, 1, 2, 0));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_scrobbling(rig.runtime, rig.library, 1, 0, 255));
    try std.testing.expectEqual(@as(u8, 0), (try rig.status()).view.enabled);
    try std.testing.expectEqual(Status.invalid_argument, orca_library_scrobbler_status(rig.runtime, rig.library, null, null));

    var second: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(rig.runtime, "file:orca-c-api-scrobble-second?mode=memory&cache=shared", &second));
    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, rig.library, 1, 1, 0));
    try std.testing.expectEqual(Status.invalid_state, orca_library_set_scrobbling(rig.runtime, second, 1, 1, 0));
    try std.testing.expectEqualStrings("orca_library_set_scrobbling: ScrobblingEnabledElsewhere", rig.lastError());
    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, second, 0, 0, 0));
    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, rig.library, 0, 0, 0));
    try std.testing.expectEqual(Status.ok, orca_library_set_scrobbling(rig.runtime, second, 1, 1, 0));

    const stale: Handle = .{ .index = rig.library.index, .generation = rig.library.generation + 1 };
    try std.testing.expectEqual(Status.stale_handle, orca_library_set_scrobbling(rig.runtime, stale, 1, 0, 0));
    var captured: CapturedScrobblerStatus = .{};
    try std.testing.expectEqual(Status.stale_handle, orca_library_scrobbler_status(rig.runtime, stale, &captured, captureScrobblerStatus));
    try std.testing.expectEqual(@as(usize, 0), captured.calls);
    try std.testing.expectEqual(@as(u32, 0), rig.transport.requestCount());

    const unnamed = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(unnamed);
    var unnamed_library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(unnamed, "file:orca-c-api-scrobble-unnamed?mode=memory&cache=shared", &unnamed_library));
    try std.testing.expectEqual(Status.invalid_state, orca_library_set_scrobbling(unnamed, unnamed_library, 1, 1, 0));
    try std.testing.expectEqualStrings("orca_library_set_scrobbling: ClientIdentityRequired", std.mem.span(orca_runtime_last_error(unnamed)));
}

fn maintenanceStatus(runtime: *Runtime, library: Handle) !MaintenanceStatus {
    var status: MaintenanceStatus = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_maintenance_status(runtime, library, &status));
    return status;
}

test "a maintenance unit enabled through the C ABI is a metadata lookup of origin maintenance whose stats the status reports as its last unit" {
    var rig: MatchingRig = undefined;
    try rig.init("file:orca-c-api-maintenance?mode=memory&cache=shared", "test-client");
    defer rig.deinit();
    const album = try provider_tests.addRelease(rig.library_database, "Bryter Layter", null);
    _ = try rig.addTone("northern.wav", 300, "Northern Sky", provider_tests.northern_sky_mbid, album);
    rig.acoustid.lookup_body = provider_tests.acoustIdAnswer(
        provider_tests.heardBy("0", provider_tests.heardResult("0.95", provider_tests.northern_sky_heard)),
    );

    const off = try maintenanceStatus(rig.runtime, rig.library);
    try std.testing.expectEqual(@as(u8, 0), off.enabled);
    try std.testing.expectEqual(exportMaintenanceState(.off), off.state);
    try std.testing.expectEqual(@as(u8, 0), off.has_last);
    try std.testing.expectEqual(@as(u8, 0), off.has_next_due_ms);

    try std.testing.expectEqual(Status.ok, orca_library_set_maintenance(rig.runtime, rig.library, &.{ .interval_ms = 0, .enabled = 1 }));
    const due = try maintenanceStatus(rig.runtime, rig.library);
    try std.testing.expectEqual(exportMaintenanceState(.waiting), due.state);
    try std.testing.expectEqual(@as(u8, 1), due.has_next_due_ms);
    try std.testing.expectEqual(@as(u64, 0), due.next_due_ms);

    try std.testing.expectEqual(Status.ok, orca_runtime_pump(rig.runtime));
    try std.testing.expectEqual(exportMaintenanceState(.running), (try maintenanceStatus(rig.runtime, rig.library)).state);
    const running = core.runtime_jobs.maintenanceUnitRunning(&runtimeBox(rig.runtime).?.runtime) orelse return error.UnitNotRunning;
    const unit = exportJobHandle(running.job);
    var origin: u8 = 255;
    try std.testing.expectEqual(Status.ok, orca_job_origin_get(rig.runtime, unit, &origin));
    try std.testing.expectEqual(exportJobOrigin(.maintenance), origin);
    var snapshot: JobSnapshot = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_snapshot_get(rig.runtime, unit, &snapshot));
    try std.testing.expectEqual(exportJobKind(.metadata_lookup), snapshot.kind);
    var root_id: i64 = -1;
    var has_root_id: u8 = 1;
    try std.testing.expectEqual(Status.ok, orca_job_reconcile_root(rig.runtime, unit, &root_id, &has_root_id));
    try std.testing.expectEqual(@as(i64, 0), root_id);
    try std.testing.expectEqual(@as(u8, 0), has_root_id);

    try std.testing.expectEqual(job.State.succeeded, try rig.finish(unit));
    var deadline: core.runtime_tests.TestDeadline = .init(10_000);
    var waiting = try maintenanceStatus(rig.runtime, rig.library);
    while (waiting.units_run < 1) {
        if (!deadline.tick()) return error.UnitDidNotFinish;
        try std.testing.expectEqual(Status.ok, orca_runtime_pump(rig.runtime));
        waiting = try maintenanceStatus(rig.runtime, rig.library);
    }
    try std.testing.expectEqual(@as(u8, 1), waiting.enabled);
    try std.testing.expectEqual(exportMaintenanceState(.waiting), waiting.state);
    try std.testing.expectEqual(@as(u8, 0), waiting.has_blocked);
    try std.testing.expectEqual(@as(u8, 1), waiting.has_next_due_ms);
    try std.testing.expect(waiting.next_due_ms > 0 and waiting.next_due_ms <= 5 * 60 * 1000);
    try std.testing.expectEqual(@as(u8, 1), waiting.has_last);
    try std.testing.expectEqual(@as(u8, @backingInt(job.State.succeeded)), waiting.last_state);
    try std.testing.expectEqual(@as(u8, 1), waiting.has_last_release_id);
    try std.testing.expectEqual(album, waiting.last_release_id);
    try std.testing.expectEqual(@as(u64, 1), waiting.last_stats.verified);
    try std.testing.expectEqual(exportAcoustIdUse(.searched), waiting.last_stats.acoustid);
    var unit_stats: MatchStatsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_match_stats(rig.runtime, unit, &unit_stats));
    try std.testing.expectEqual(unit_stats, waiting.last_stats);
    try std.testing.expectEqual(Status.ok, orca_job_origin_get(rig.runtime, unit, &origin));
    try std.testing.expectEqual(exportJobOrigin(.maintenance), origin);

    try std.testing.expectEqual(Status.ok, orca_library_set_maintenance(rig.runtime, rig.library, null));
    const disabled = try maintenanceStatus(rig.runtime, rig.library);
    try std.testing.expectEqual(@as(u8, 0), disabled.enabled);
    try std.testing.expectEqual(exportMaintenanceState(.off), disabled.state);
    try std.testing.expectEqual(@as(u8, 0), disabled.has_last);
}

test "maintenance refuses an enabled flag other than 0 or 1, null outputs and stale handles, and reports why it is blocked" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-maintenance-refusals?mode=memory&cache=shared", &library));

    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_maintenance(runtime, library, &.{ .interval_ms = 0, .enabled = 2 }));
    try std.testing.expectEqualStrings("orca_library_set_maintenance: enabled is not 0 or 1", std.mem.span(orca_runtime_last_error(runtime)));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_maintenance_status(runtime, library, null));
    const stale: Handle = .{ .index = library.index, .generation = library.generation + 1 };
    try std.testing.expectEqual(Status.stale_handle, orca_library_set_maintenance(runtime, stale, &.{ .interval_ms = 0, .enabled = 1 }));
    var status: MaintenanceStatus = undefined;
    try std.testing.expectEqual(Status.stale_handle, orca_library_maintenance_status(runtime, stale, &status));

    var origin: u8 = 0;
    var root_id: i64 = 0;
    var has_root_id: u8 = 0;
    const unknown_job: Handle = .{ .index = 7, .generation = 3 };
    try std.testing.expectEqual(Status.stale_handle, orca_job_origin_get(runtime, unknown_job, &origin));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_origin_get(runtime, unknown_job, null));
    try std.testing.expectEqual(Status.stale_handle, orca_job_reconcile_root(runtime, unknown_job, &root_id, &has_root_id));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_reconcile_root(runtime, unknown_job, null, &has_root_id));
    try std.testing.expectEqual(Status.invalid_argument, orca_job_reconcile_root(runtime, unknown_job, &root_id, null));

    try std.testing.expectEqual(Status.ok, orca_library_set_maintenance(runtime, library, &.{ .interval_ms = 60_000, .enabled = 1 }));
    try std.testing.expectEqual(Status.ok, orca_runtime_pump(runtime));
    status = try maintenanceStatus(runtime, library);
    try std.testing.expectEqual(exportMaintenanceState(.blocked), status.state);
    try std.testing.expectEqual(@as(u8, 1), status.has_blocked);
    try std.testing.expectEqual(exportMaintenanceBlock(.client_identity_required), status.blocked);
    try std.testing.expectEqual(@as(u8, 1), status.has_next_due_ms);
    try std.testing.expect(status.next_due_ms > 0 and status.next_due_ms <= 60_000);

    try std.testing.expectEqual(Status.ok, orca_runtime_set_client_identity(runtime, "Host", "1.0", "https://host.invalid"));
    try std.testing.expectEqual(Status.ok, orca_library_set_maintenance(runtime, library, &.{ .interval_ms = 60_000, .enabled = 1 }));
    try std.testing.expectEqual(Status.ok, orca_runtime_pump(runtime));
    status = try maintenanceStatus(runtime, library);
    try std.testing.expectEqual(exportMaintenanceState(.blocked), status.state);
    try std.testing.expectEqual(exportMaintenanceBlock(.acoustid_required), status.blocked);
    try std.testing.expectEqual(@as(u8, 0), status.has_last);

    try std.testing.expectEqual(Status.ok, orca_library_set_maintenance(runtime, library, &.{ .interval_ms = 0, .enabled = 0 }));
    try std.testing.expectEqual(exportMaintenanceState(.off), (try maintenanceStatus(runtime, library)).state);
}

fn countRadioPicks(context: ?*anyopaque, preview: *const RadioPreviewView) callconv(.c) void {
    const visited: *usize = @ptrCast(@alignCast(context.?));
    visited.* += 1 + preview.count;
}

test "the discovery settings round-trip and refuse values outside their sets, and a Radio preview checks its seed" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-radio?mode=memory&cache=shared", &library));
    var settings: DiscoverySettingsView = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_discovery_settings(runtime, library, &settings));
    try std.testing.expectEqual(DiscoverySettingsView{ .radio_continue = 1, .include_unplayed = 1, .avoid_days = 3, .mix_count = 6 }, settings);
    const changed: DiscoverySettingsView = .{ .radio_continue = 0, .include_unplayed = 0, .avoid_days = 7, .mix_count = 4 };
    try std.testing.expectEqual(Status.ok, orca_library_set_discovery_settings(runtime, library, &changed));
    try std.testing.expectEqual(Status.ok, orca_library_discovery_settings(runtime, library, &settings));
    try std.testing.expectEqual(changed, settings);
    for ([_]DiscoverySettingsView{
        .{ .radio_continue = 2, .include_unplayed = 0, .avoid_days = 3, .mix_count = 6 },
        .{ .radio_continue = 1, .include_unplayed = 1, .avoid_days = 2, .mix_count = 6 },
        .{ .radio_continue = 1, .include_unplayed = 1, .avoid_days = 3, .mix_count = 5 },
    }) |invalid| try std.testing.expectEqual(Status.invalid_argument, orca_library_set_discovery_settings(runtime, library, &invalid));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_set_discovery_settings(runtime, library, null));
    try std.testing.expectEqual(Status.ok, orca_library_discovery_settings(runtime, library, &settings));
    try std.testing.expectEqual(changed, settings);

    var visited: usize = 0;
    const loved: RadioSeedView = .{ .id = 0, .kind = @backingInt(std.meta.Tag(discovery.Seed).loved) };
    try std.testing.expectEqual(Status.ok, orca_library_radio_preview(runtime, library, &loved, null, null, 10, &visited, countRadioPicks));
    try std.testing.expectEqual(@as(usize, 1), visited);
    const unknown_track: RadioSeedView = .{ .id = 5, .kind = @backingInt(std.meta.Tag(discovery.Seed).track) };
    try std.testing.expectEqual(Status.not_found, orca_library_radio_preview(runtime, library, &unknown_track, null, null, 10, &visited, countRadioPicks));
    const unknown_kind: RadioSeedView = .{ .id = 0, .kind = 7 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_radio_preview(runtime, library, &unknown_kind, null, null, 10, &visited, countRadioPicks));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_radio_preview(runtime, library, &loved, null, null, 513, &visited, countRadioPicks));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_radio_preview(runtime, library, &loved, null, null, 10, &visited, null));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_radio_preview(runtime, library, null, null, null, 10, &visited, countRadioPicks));
    var options = std.mem.zeroes(RadioOptionsView);
    options.explore = 101;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_radio_preview(runtime, library, &loved, &options, null, 10, &visited, countRadioPicks));
    options.explore = 35;
    options.focus_count = 5;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_radio_preview(runtime, library, &loved, &options, null, 10, &visited, countRadioPicks));
    options.focus_count = 1;
    options.focus[0] = .{ .id = 0, .kind = 4 };
    try std.testing.expectEqual(Status.invalid_argument, orca_library_radio_preview(runtime, library, &loved, &options, null, 10, &visited, countRadioPicks));
    options.focus[0] = .{ .id = 0, .kind = @backingInt(std.meta.Tag(discovery.Focus).high_energy) };
    const session: RadioPreviewSessionView = .{ .now_s = 2_000_000_000, .seed = 1, .has_now = 1, .has_seed = 1 };
    try std.testing.expectEqual(Status.ok, orca_library_radio_preview(runtime, library, &loved, &options, &session, 10, &visited, countRadioPicks));
    try std.testing.expectEqual(@as(usize, 2), visited);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}

const CapturedDailyMixes = struct {
    calls: usize = 0,
    state: u8 = 255,
    count: usize = 0,
    first: DailyMixView = undefined,
    first_name: [32]u8 = undefined,
    first_name_length: usize = 0,
    last: DailyMixView = undefined,
    last_name: [32]u8 = undefined,
    last_name_length: usize = 0,
};

fn captureDailyMixes(context: ?*anyopaque, view: *const DailyMixesView) callconv(.c) void {
    const captured: *CapturedDailyMixes = @ptrCast(@alignCast(context.?));
    captured.calls += 1;
    captured.state = view.state;
    captured.count = view.count;
    if (view.count == 0) return;
    captured.first = view.mixes[0];
    captured.first_name_length = @min(view.mixes[0].name.length, captured.first_name.len);
    @memcpy(captured.first_name[0..captured.first_name_length], view.mixes[0].name.pointer[0..captured.first_name_length]);
    const last = view.mixes[view.count - 1];
    captured.last = last;
    captured.last_name_length = @min(last.name.length, captured.last_name.len);
    @memcpy(captured.last_name[0..captured.last_name_length], last.name.pointer[0..captured.last_name_length]);
}

const CapturedDailyMixEntries = struct {
    calls: usize = 0,
    entries: [daily_mixes.max_entries]DailyMixEntryView = undefined,
    count: usize = 0,
};

fn captureDailyMixEntries(context: ?*anyopaque, view: *const DailyMixEntriesView) callconv(.c) void {
    const captured: *CapturedDailyMixEntries = @ptrCast(@alignCast(context.?));
    captured.calls += 1;
    captured.count = view.count;
    @memcpy(captured.entries[0..view.count], view.entries[0..view.count]);
}

test "Daily Mixes are made, listed, read, marked Not for me, reset and saved through the C ABI" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    const box = runtimeBox(runtime).?;
    var library: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_library_open(runtime, "file:orca-c-api-daily-mixes?mode=memory&cache=shared", &library));
    const now_s: i64 = 2_000_000_000;

    var mixes: CapturedDailyMixes = .{};
    try std.testing.expectEqual(Status.ok, orca_library_daily_mixes(runtime, library, now_s, 0, &mixes, captureDailyMixes));
    try std.testing.expectEqual(@as(usize, 1), mixes.calls);
    try std.testing.expectEqual(@backingInt(daily_mixes.State.not_enough_history), mixes.state);

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(std.testing.allocator);
    try sql.appendSlice(std.testing.allocator, "INSERT INTO genres(id, name, key) VALUES (1, 'Jazz', 'jazz');\n");
    for (1..4) |artist| try sql.print(std.testing.allocator, "INSERT INTO artists(id, name, key) VALUES ({d}, 'Artist {d}', 'artist {d}');\n", .{ artist, artist, artist });
    for (1..46) |id| {
        const artist = (id - 1) / 15 + 1;
        try sql.print(std.testing.allocator,
            \\INSERT INTO releases(id, title) VALUES ({d}, 'Release {d}');
            \\INSERT INTO recordings(id, title) VALUES ({d}, 'r{d}');
            \\INSERT INTO files(id, recording_id, audio_format, size_bytes) VALUES ({d}, {d}, 1, 1);
            \\INSERT INTO tracks(id, recording_id, release_id, title, artist_id, preferred_file_id, duration_ms, created_at)
            \\    VALUES ({d}, {d}, {d}, 't{d}', {d}, {d}, 180000, 1000);
            \\INSERT INTO locations(file_id, volume_id, uri, state) VALUES ({d}, {d}, '/m/{d}', 'present');
            \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES ({d}, 1, 0, 0);
            \\
        , .{ id, id, id, id, id, id, id, id, id, id, artist, id, id, database.LibraryDatabase.null_volume, id, id });
        for (0..2) |play| try sql.print(
            std.testing.allocator,
            "INSERT INTO listens(file_id, recording_id, started_at, listened_ms, title, artist) VALUES ({d}, {d}, {d}, 1000, 't', 'a');\n",
            .{ id, id, now_s - @as(i64, @intCast(1 + (id + play) % 3)) * 86_400 - @as(i64, @intCast(id)) },
        );
    }
    try sql.appendSlice(std.testing.allocator,
        \\INSERT INTO recording_play_stats(recording_id, play_count, last_played_at)
        \\    SELECT recording_id, count(*), max(started_at) FROM listens GROUP BY recording_id;
    );
    try sql.append(std.testing.allocator, 0);
    const library_database = try core.runtime.libraryDatabase(&box.runtime, importLibrary(library));
    try library_database.database.exec(sql.items[0 .. sql.items.len - 1 :0]);

    var mix_job: Handle = undefined;
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_daily_mixes(runtime, library, &.{ .now_s = now_s, .utc_offset_s = 0, .force = 2 }, &mix_job));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_daily_mixes(runtime, library, null, &mix_job));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_start_daily_mixes(runtime, library, &.{ .now_s = now_s, .utc_offset_s = 0, .force = 1 }, null));
    try std.testing.expectEqual(Status.ok, orca_library_start_daily_mixes(runtime, library, &.{ .now_s = now_s, .utc_offset_s = 0, .force = 1 }, &mix_job));
    try std.testing.expectEqual(job.State.succeeded, try core.runtime_tests.awaitJob(&box.runtime, importJob(mix_job)));
    var snapshot: JobSnapshot = undefined;
    try std.testing.expectEqual(Status.ok, orca_job_snapshot_get(runtime, mix_job, &snapshot));
    try std.testing.expectEqual(@as(u8, 13), snapshot.kind);

    try std.testing.expectEqual(Status.ok, orca_library_daily_mixes(runtime, library, now_s, 0, &mixes, captureDailyMixes));
    try std.testing.expectEqual(@backingInt(daily_mixes.State.ready), mixes.state);
    try std.testing.expectEqual(@as(usize, 1), mixes.count);
    try std.testing.expectEqualStrings("Jazz", mixes.first_name[0..mixes.first_name_length]);
    try std.testing.expectEqual(@backingInt(daily_mixes.Kind.genre), mixes.first.kind);
    try std.testing.expectEqual(@as(u8, 1), mixes.first.has_genre_id);
    try std.testing.expectEqual(@as(i64, 1), mixes.first.genre_id);
    try std.testing.expectEqual(@as(u8, 3), mixes.first.artist_count);
    try std.testing.expectEqual(@as(u32, 25), mixes.first.entry_count);
    try std.testing.expectEqual(@as(u64, 25 * 180_000), mixes.first.duration_ms);
    try std.testing.expect(mixes.first.cover_count > 0);
    try std.testing.expectEqual(@as(u16, 0), mixes.first.decade);
    const mix_id = mixes.first.id;

    var entries: CapturedDailyMixEntries = .{};
    try std.testing.expectEqual(Status.ok, orca_library_daily_mix_entries(runtime, library, mix_id, &entries, captureDailyMixEntries));
    try std.testing.expectEqual(@as(usize, 25), entries.count);
    const before = entries.entries;
    for (before[0..entries.count]) |entry| {
        try std.testing.expect(entry.reason_count >= 1);
        try std.testing.expectEqual(@as(u8, 1), entry.has_duration);
        try std.testing.expectEqual(@as(i64, 180_000), entry.duration_ms);
    }
    try std.testing.expectEqual(Status.not_found, orca_library_daily_mix_entries(runtime, library, mix_id + 100, &entries, captureDailyMixEntries));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_daily_mix_entries(runtime, library, mix_id, &entries, null));

    const hidden = before[1].track_id;
    try std.testing.expectEqual(Status.ok, orca_library_not_for_me(runtime, library, hidden, now_s));
    try std.testing.expectEqual(Status.ok, orca_library_daily_mix_entries(runtime, library, mix_id, &entries, captureDailyMixEntries));
    try std.testing.expectEqual(@as(usize, 24), entries.count);
    try std.testing.expectEqual(before[0].track_id, entries.entries[0].track_id);
    try std.testing.expectEqual(before[2].track_id, entries.entries[1].track_id);
    try std.testing.expectEqual(Status.not_found, orca_library_not_for_me(runtime, library, 1_000_000, now_s));

    try std.testing.expectEqual(Status.ok, orca_library_clear_not_for_me(runtime, library, hidden));
    try std.testing.expectEqual(Status.ok, orca_library_daily_mix_entries(runtime, library, mix_id, &entries, captureDailyMixEntries));
    try std.testing.expectEqual(@as(usize, 25), entries.count);
    try std.testing.expectEqual(hidden, entries.entries[1].track_id);
    try std.testing.expectEqual(Status.not_found, orca_library_clear_not_for_me(runtime, library, 1_000_000));

    try std.testing.expectEqual(Status.ok, orca_library_not_for_me(runtime, library, hidden, now_s));
    try std.testing.expectEqual(Status.ok, orca_library_reset_recommendations(runtime, library));
    try std.testing.expectEqual(Status.ok, orca_library_daily_mix_entries(runtime, library, mix_id, &entries, captureDailyMixEntries));
    try std.testing.expectEqual(@as(usize, 25), entries.count);

    var playlist_id: i64 = 0;
    const name = "Jazz mix";
    try std.testing.expectEqual(Status.ok, orca_library_save_daily_mix(runtime, library, mix_id, name, name.len, &playlist_id));
    try std.testing.expect(playlist_id > 0);
    var saved = try library_database.database.prepare("SELECT count(*) FROM playlist_entries WHERE playlist_id = ?1;");
    defer saved.deinit();
    try saved.bindInt64(1, playlist_id);
    try std.testing.expect(try saved.step() == .row);
    try std.testing.expectEqual(@as(i64, 25), saved.columnInt64(0));
    try std.testing.expectEqual(Status.not_found, orca_library_save_daily_mix(runtime, library, mix_id + 100, name, name.len, &playlist_id));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_save_daily_mix(runtime, library, mix_id, null, 3, &playlist_id));
    try std.testing.expectEqual(Status.invalid_argument, orca_library_save_daily_mix(runtime, library, mix_id, name, name.len, null));

    try library_database.database.exec("UPDATE releases SET release_date = '1994-05-01';");
    try std.testing.expectEqual(Status.ok, orca_library_start_daily_mixes(runtime, library, &.{ .now_s = now_s, .utc_offset_s = 0, .force = 1 }, &mix_job));
    try std.testing.expectEqual(job.State.succeeded, try core.runtime_tests.awaitJob(&box.runtime, importJob(mix_job)));
    try std.testing.expectEqual(Status.ok, orca_library_daily_mixes(runtime, library, now_s, 0, &mixes, captureDailyMixes));
    try std.testing.expectEqual(@as(usize, 2), mixes.count);
    try std.testing.expectEqualStrings("Jazz", mixes.first_name[0..mixes.first_name_length]);
    try std.testing.expectEqualStrings("1990s", mixes.last_name[0..mixes.last_name_length]);
    try std.testing.expectEqual(@backingInt(daily_mixes.Kind.decade), mixes.last.kind);
    try std.testing.expectEqual(@as(u16, 1990), mixes.last.decade);
    try std.testing.expectEqual(@as(u8, 0), mixes.last.has_genre_id);
    try std.testing.expect(mixes.last.entry_count > 0);
    try std.testing.expectEqual(Status.ok, orca_library_close(runtime, library));
}
