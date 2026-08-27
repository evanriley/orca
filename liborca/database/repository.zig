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
            \\FROM track_search
            \\JOIN tracks ON tracks.id = track_search.rowid
            \\WHERE track_search MATCH ?1
            \\ORDER BY rank
            \\LIMIT ?2 OFFSET ?3;
        );
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

    /// One Track by id, for the "what is playing right now" question. Bounded
    /// by construction: a single row, copied out, with no statement escaping.
    pub fn byId(
        self: *const TrackRepository,
        allocator: std.mem.Allocator,
        track_id: i64,
    ) !?TrackSummary {
        var statement = try self.db.prepare(track_columns ++
            \\FROM tracks WHERE tracks.id = ?1;
        );
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
    \\       )
    \\
;

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
    return track_columns ++ "FROM tracks\n" ++ where ++
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
    \\SELECT artists.id, artists.name, COALESCE(artists.sort_name, ''),
    \\       (SELECT count(*) FROM releases
    \\         WHERE releases.album_artist_id = artists.id
    \\            OR releases.id IN
    \\               (SELECT release_id FROM tracks WHERE tracks.artist_id = artists.id)),
    \\       (SELECT count(*) FROM tracks
    \\         WHERE tracks.artist_id = artists.id
    \\            OR tracks.release_id IN
    \\               (SELECT id FROM releases WHERE album_artist_id = artists.id))
    \\
;

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
    limit: u32 = max_page,
    offset: u32 = 0,
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
        var statement = if (query.album_artist_id == null)
            try self.db.prepare(release_columns ++
                \\FROM releases
                \\ORDER BY releases.title COLLATE NOCASE, releases.id
                \\LIMIT ?1 OFFSET ?2;
            )
        else
            try self.db.prepare(release_columns ++
                "FROM releases\nWHERE " ++ by_release_artist ++
                "\nORDER BY releases.title COLLATE NOCASE, releases.id" ++
                "\nLIMIT ?1 OFFSET ?2;");
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

    pub fn remove(self: *LibraryRootRepository, root_id: i64) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare("DELETE FROM library_roots WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, root_id);
        if (try statement.step() != .done) return error.SqlFailed;
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
        try bindAnalysisSelector(statement, selector);

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
        try bindAnalysisSelector(statement, selector);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
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
                try statement.bindInt64(28, @backingInt(artwork.kind));
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
        try statement.bindInt64(2, @backingInt(input.field));
        try statement.bindText(3, input.value);
        try statement.bindInt64(4, @backingInt(input.provenance));
        try statement.bindInt64(5, @intFromBool(input.locked));
        try statement.bindInt64(6, @backingInt(metadata.Provenance.user));
        if (try statement.step() != .done) return error.SqlFailed;
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
        try statement.bindInt64(2, @backingInt(field));
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
        try statement.bindInt64(4, @backingInt(input.kind));
        try statement.bindText(5, input.source_path);
        try statement.bindOptionalText(6, input.destination_path);
        try statement.bindOptionalText(7, input.stage_path);
        try statement.bindOptionalText(8, input.backup_path);
        try statement.bindInt64(9, @intCast(input.expected_size));
        try statement.bindInt64(10, input.expected_modified_ns);
        try statement.bindInt64(11, @backingInt(MutationState.planned));
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
        try statement.bindInt64(1, @backingInt(next));
        try statement.bindOptionalText(2, message);
        try statement.bindInt64(3, operation_id);
        try statement.bindInt64(4, @backingInt(expected));
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
        try statement.bindInt64(1, @backingInt(MutationState.committed));
        try statement.bindInt64(2, @intCast(committed_size));
        try statement.bindInt64(3, committed_modified_ns);
        try statement.bindInt64(4, operation_id);
        try statement.bindInt64(5, @backingInt(MutationState.staged));
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
        try statement.bindInt64(4, @backingInt(expected_state));
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
        try statement.bindInt64(1, @backingInt(MutationState.planned));
        try statement.bindInt64(2, @backingInt(MutationState.staged));
        try statement.bindInt64(3, @backingInt(MutationState.failed));
        var ids: std.ArrayList(u64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row)
            try ids.append(allocator, @intCast(statement.columnInt64(0)));
        return ids.toOwnedSlice(allocator);
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
            try insert.bindInt64(2, @backingInt(issue.kind));
            try insert.bindInt64(3, @backingInt(issue.severity));
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
        try statement.bindInt64(2, @backingInt(issue.kind));
        try statement.bindInt64(3, @backingInt(issue.severity));
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
        try statement.bindInt64(2, @backingInt(kind));
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
        var statement = try self.db.prepare(
            \\INSERT INTO scrobble_queue(service, event_key, payload)
            \\VALUES (?1, ?2, ?3) ON CONFLICT(service, event_key) DO NOTHING;
        );
        defer statement.deinit();
        try statement.bindText(1, service);
        try statement.bindText(2, event_key);
        try statement.bindBlob(3, payload);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    pub fn ready(
        self: *const ScrobbleQueueRepository,
        allocator: std.mem.Allocator,
        service: []const u8,
        now: i64,
        limit: u32,
    ) ![]ScrobbleQueueEntry {
        var statement = try self.db.prepare(
            \\SELECT id, service, event_key, payload, attempt_count FROM scrobble_queue
            \\WHERE service=?1 AND state=0 AND next_attempt_at<=?2 ORDER BY id LIMIT ?3;
        );
        defer statement.deinit();
        try statement.bindText(1, service);
        try statement.bindInt64(2, now);
        try statement.bindInt64(3, limit);
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
        return entries.toOwnedSlice(allocator);
    }

    pub fn markSucceeded(self: *ScrobbleQueueRepository, id: i64) !void {
        try self.setResult(id, 2, 0, "");
    }

    pub fn markRetry(
        self: *ScrobbleQueueRepository,
        id: i64,
        next_attempt_at: i64,
        details: []const u8,
    ) !void {
        try self.setResult(id, 0, next_attempt_at, details);
    }

    pub fn pendingCount(self: *const ScrobbleQueueRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM scrobble_queue WHERE state=0;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    fn setResult(
        self: *ScrobbleQueueRepository,
        id: i64,
        state: u8,
        next_attempt_at: i64,
        details: []const u8,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE scrobble_queue SET state=?1, attempt_count=attempt_count+1,
            \\    next_attempt_at=?2, last_error=?3, updated_at=unixepoch()
            \\WHERE id=?4 AND state=0;
        );
        defer statement.deinit();
        try statement.bindInt64(1, state);
        try statement.bindInt64(2, next_attempt_at);
        try statement.bindText(3, details);
        try statement.bindInt64(4, id);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleScrobbleEvent;
    }
};

pub const IdentificationProposalRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn put(self: *IdentificationProposalRepository, input: IdentificationProposalInput) !void {
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
            \\    updated_at=excluded.updated_at;
        );
        defer statement.deinit();
        try statement.bindInt64(1, input.file_id);
        try statement.bindText(2, input.provider);
        try statement.bindText(3, input.provider_id);
        try statement.bindDouble(4, input.confidence);
        try statement.bindBlob(5, input.payload);
        if (try statement.step() != .done) return error.SqlFailed;
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

    /// Accepts a proposal into Orca metadata only. Locked values survive, and
    /// writing those values back to a media file remains a separate mutation.
    pub fn accept(
        self: *IdentificationProposalRepository,
        proposal_id: i64,
        file_id: i64,
        values: []const OrcaMetadataInput,
    ) !void {
        for (values) |value| {
            if (value.file_id != file_id or value.provenance != .provider or
                value.value.len == 0) return error.InvalidProviderMetadata;
        }
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var update = try self.db.prepare(
            \\UPDATE identification_proposals SET state=1, updated_at=unixepoch()
            \\WHERE id=?1 AND file_id=?2 AND state=0;
        );
        defer update.deinit();
        try update.bindInt64(1, proposal_id);
        try update.bindInt64(2, file_id);
        if (try update.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleIdentificationProposal;
        var metadata_statement = try self.db.prepare(
            \\INSERT INTO orca_metadata_values(file_id, field, value, provenance, locked, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, 0, unixepoch())
            \\ON CONFLICT(file_id, field) DO UPDATE SET value=excluded.value,
            \\    provenance=excluded.provenance, updated_at=excluded.updated_at
            \\WHERE orca_metadata_values.locked=0;
        );
        defer metadata_statement.deinit();
        for (values) |value| {
            try metadata_statement.bindInt64(1, file_id);
            try metadata_statement.bindInt64(2, @backingInt(value.field));
            try metadata_statement.bindText(3, value.value);
            try metadata_statement.bindInt64(4, @backingInt(metadata.Provenance.provider));
            if (try metadata_statement.step() != .done) return error.SqlFailed;
            try metadata_statement.reset();
        }
        try self.db.exec("COMMIT;");
    }
};

/// Binds ?3 to ?6 of `unanalyzed_predicate`. The cursor and limit stay ?1 and
/// ?2 so the selector can be appended to any paged query without renumbering.
fn bindAnalysisSelector(statement: sqlite.Statement, selector: AnalysisSelector) !void {
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
