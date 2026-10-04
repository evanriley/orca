const std = @import("std");
const analysis_chromaprint = @import("../analysis/chromaprint.zig");
const analysis_service = @import("../analysis/service.zig");
const artist_info = @import("artist_info.zig");
const release_info = @import("release_info.zig");
const artwork = @import("artwork.zig");
const audio = @import("../audio/root.zig");
const codec = @import("../codec/root.zig");
const control = @import("control.zig");
const database = @import("../database/root.zig");
const handle = @import("handle.zig");
const library_pass = @import("../library/root.zig");
const job = @import("job.zig");
const job_worker = @import("job_worker.zig");
const listen_worker = @import("listen_worker.zig");
const metadata = @import("../metadata/root.zig");
const network = @import("../network/root.zig");
const object = @import("object.zig");
const provider_sources = @import("provider_sources.zig");
const providers = @import("../providers/root.zig");
const queue_history = @import("queue.zig");
const runtime_artist_info = @import("runtime_artist_info.zig");
const runtime_genres = @import("runtime_genres.zig");
const runtime_listens = @import("runtime_listens.zig");
const runtime_maintenance = @import("runtime_maintenance.zig");
const runtime_playlists = @import("runtime_playlists.zig");
const runtime_zones = @import("runtime_zones.zig");
const runtime_queue = @import("runtime_queue.zig");
const runtime_roots = @import("runtime_roots.zig");
const runtime_jobs = @import("runtime_jobs.zig");
const runtime_status = @import("runtime_status.zig");
const runtime_watch = @import("runtime_watch.zig");
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
pub const QueueHistoryEntry = queue_history.QueueHistoryEntry;
pub const QueueHistoryReason = queue_history.QueueHistoryReason;
pub const queue_history_capacity = queue_history.queue_history_capacity;
pub const TrackDetails = track_details.TrackDetails;
pub const RecordingIdSource = track_details.RecordingIdSource;
pub const TrackLoudness = track_details.Loudness;
pub const PlayStats = database.PlayStats;
pub const Feedback = database.Feedback;
pub const FeedbackChange = database.FeedbackChange;
pub const RatingChange = database.RatingChange;
pub const ReleaseLoveChange = database.ReleaseLoveChange;
pub const PlaylistSummary = database.PlaylistSummary;
pub const PlaylistPage = database.PlaylistPage;
pub const PlaylistEntry = database.PlaylistEntry;
pub const PlaylistEntryPage = database.PlaylistEntryPage;
pub const PlaylistInsertion = database.PlaylistInsertion;
pub const PlaylistKind = database.PlaylistKind;
pub const PlaylistCreator = database.PlaylistCreator;
pub const PlaylistSort = database.PlaylistSort;
pub const PlaylistQuery = database.PlaylistQuery;
pub const PlaylistUpdate = database.PlaylistUpdate;
pub const PlaylistFormats = database.PlaylistFormats;
pub const CodecCount = database.CodecCount;
pub const SmartPlaylistPreview = database.SmartPlaylistPreview;
pub const PlaylistImport = runtime_playlists.PlaylistImport;
pub const PlaylistExport = runtime_playlists.PlaylistExport;
pub const PlaylistExportOptions = runtime_playlists.PlaylistExportOptions;
pub const PlaylistPathStyle = runtime_playlists.PlaylistPathStyle;
pub const ClientIdentity = network.client.Identity;
pub const CredentialStore = providers.credentials.Store;
pub const ScrobblerStatus = listen_worker.Status;
pub const ScrobblerState = providers.listenbrainz.State;
pub const BoundedText = providers.listenbrainz.BoundedText;
pub const HostWaker = control.HostWaker;

pub const State = enum(u8) {
    running,
    shutting_down,
    stopped,
};

const RuntimeObject = struct {};
pub const LibraryObject = struct {
    database: ?*database.LibraryDatabase = null,
    /// Started on the first artwork request, and again after any drain.
    artwork: ?*ArtworkLoader = null,
    /// Created on the first Player bind or scrobbling change and kept until
    /// the Library closes. Its worker restarts on the next listen after any
    /// drain.
    listens: ?*listen_worker.Listens = null,
    stored_counts: ?runtime_listens.StoredCounts = null,
    /// Null while the Library is not watched, and between a drain and the
    /// re-arm that follows it.
    watch: ?*runtime_watch.LibraryWatch = null,
    /// Set while the host wants the Library watched; survives drains.
    watch_options: ?runtime_watch.WatchOptions = null,
    /// Set while idle maintenance is enabled; survives drains.
    maintenance: ?runtime_maintenance.LibraryMaintenance = null,
};

pub const ArtworkLoader = struct {
    loader: artwork.Loader,
    work_handle: WorkHandle,
};

pub const WatchOptions = runtime_watch.WatchOptions;
pub const WatchState = runtime_watch.WatchState;
pub const WatchStatus = runtime_watch.WatchStatus;
pub const MaintenanceOptions = runtime_maintenance.MaintenanceOptions;
pub const MaintenanceState = runtime_maintenance.MaintenanceState;
pub const MaintenanceBlock = runtime_maintenance.MaintenanceBlock;
pub const MaintenanceUnit = runtime_maintenance.MaintenanceUnit;
pub const MaintenanceStatus = runtime_maintenance.MaintenanceStatus;
pub const JobOrigin = job_worker.Origin;

pub const ArtworkSubject = artwork.Subject;
pub const ArtworkResult = artwork.Result;
pub const PlayerObject = struct {
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
    history: queue_history.QueueHistory = .{},
};
pub const ZoneObject = struct {
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

/// One file's measurement from `libraryAnalyzeFile`.
pub const FileAnalysis = analysis_service.Analysis;
pub const TrackFingerprint = analysis_chromaprint.Fingerprinter.Outcome;

/// The Library's database, for liborca's own C ABI and tests. Clients use the
/// runtime's methods; the database is not part of the API.
pub fn databaseOf(runtime: *OrcaRuntime, library: LibraryHandle) !*database.LibraryDatabase {
    return libraryDatabase(runtime, library);
}

/// What `planTagWrite` would write, for a person to approve. Caller-owned.
pub const TagWritePlan = struct {
    arena: *std.heap.ArenaAllocator,
    /// Zero when there is nothing to write; there is then nothing to start.
    plan_id: u64,
    digest: metadata.mutation.Digest,
    files: []const TagWriteFile,
    skipped: []const TagWriteSkip,
    /// Orca values that are not written because the file's own tag says
    /// something else and the value is not locked.
    conflicts: []const TagWriteConflict,

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
    /// The file's genres replaced by the user's, or null when they stay.
    genres: ?TagWriteGenres,
};

/// `before` is what the file states, value by value; `after` is the genres
/// the user gave the Track.
pub const TagWriteGenres = metadata.mutation.GenreChange;

pub const TagWriteChange = struct {
    field: metadata.Field,
    before: ?[]const u8,
    after: ?[]const u8,
    /// Where Orca's value came from: `user` for an edit, `provider` for an
    /// accepted match.
    provenance: metadata.Provenance,
};

pub const TagWriteConflict = struct {
    file_id: i64,
    path: []const u8,
    field: metadata.Field,
    file_value: []const u8,
    orca_value: []const u8,
    provenance: metadata.Provenance,
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
    /// Orca cannot create files in the file's folder, which a write needs for
    /// its staged copy.
    folder_not_writable,
};

/// What `pruneTagWriteBackups` deleted: how many backups, and their bytes.
pub const PruneSummary = metadata.executor.PruneSummary;

/// Plans held between `planTagWrite` and `startTagWrite`. Few, because a plan
/// waits on a person.
pub const max_pending_tag_writes = 8;

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

pub const ScanRequest = job_worker.ScanRequest;
pub const ReconcileRequest = job_worker.ReconcileRequest;
pub const ReconcileScope = job_worker.ReconcileScope;
pub const BackfillRequest = job_worker.BackfillRequest;
pub const AnalysisRequest = job_worker.AnalysisRequest;
pub const DuplicateScanRequest = job_worker.DuplicateScanRequest;

pub const MatchMode = library_pass.matching.Mode;

pub const MatchRequest = struct {
    batch_size: usize = 64,
    limit: ?u32 = null,
    /// `.reidentify` needs `track_id` or `release_id`, and takes no
    /// `accept_minimum_confidence`. `.verify` needs AcoustID, refused with
    /// `error.AcoustIdRequired`, and takes neither
    /// `accept_minimum_confidence` nor `cover_art`.
    mode: MatchMode = .search,
    /// Search only this Track. With `.search`, under the same rule as the
    /// whole library: one already identified, or already answered for, is not
    /// searched.
    track_id: ?i64 = null,
    /// Search only this Release's Tracks, under the same rule. Not with
    /// `track_id`.
    release_id: ?i64 = null,
    /// Also fingerprint each Track's file and look it up on AcoustID, when an
    /// AcoustID application key is set.
    fingerprints: bool = true,
    /// With `release_id`: after the lookups, accept the Release's matches
    /// `libraryAcceptConfidentMatches` would accept at this confidence.
    accept_minimum_confidence: ?f32 = null,
    /// With `release_id`: then fetch its front cover, as
    /// `startReleaseCoverArtFetch` does.
    cover_art: bool = false,
};

pub const CoverArtOutcome = job_worker.CoverArtOutcome;
pub const Lyrics = job_worker.Lyrics;
pub const LyricsOptions = job_worker.LyricsOptions;
pub const LyricsOutcome = job_worker.LyricsOutcome;
pub const ArtistInfoOutcome = job_worker.ArtistInfoOutcome;
pub const ArtistInfoOptions = artist_info.Options;
pub const ReleaseInfoOptions = release_info.Options;
pub const ReleaseInfoOutcome = job_worker.ArtistInfoOutcome;

/// Which providers may fill genres for Tracks with none, kept per Library.
pub const GenreFill = struct {
    /// MusicBrainz genres, CC BY-NC-SA 3.0. On unless turned off.
    musicbrainz: bool = true,
};

pub const GenreFillOptions = struct {
    /// At most this many Releases, 1 to `database.repository.max_page`.
    limit: u32 = database.repository.max_page,
    /// Make no request; use answers already cached.
    offline: bool = false,
};

pub const AcoustIdUse = library_pass.matching.AcoustIdUse;
pub const BusyService = library_pass.matching.BusyService;
pub const AcoustIdSubmittable = database.AcoustIdSubmittable;
pub const AcoustIdSubmittablePage = database.AcoustIdSubmittablePage;
pub const SubmissionOutcome = library_pass.acoustid_submission.Outcome;

pub const SubmissionStats = job_worker.SubmissionStats;
pub const TagWriteFailure = job_worker.TagWriteFailure;
pub const TagWriteFailureReason = job_worker.TagWriteFailureReason;
pub const ScanStats = job_worker.ScanStats;
pub const MatchStats = job_worker.MatchStats;
pub const MatchingHooks = job_worker.MatchingHooks;
const PendingTagWrite = job_worker.PendingTagWrite;
const JobWorker = job_worker.JobWorker;

pub const MatchProposal = database.MatchProposal;
pub const MatchProposalPage = database.MatchProposalPage;
pub const MatchReviewItem = database.MatchReviewItem;
pub const MatchReviewPage = database.MatchReviewPage;
pub const MatchAcceptance = database.ProposalAcceptance;

pub const ConfidentMatchAcceptance = struct {
    accepted: u64,
    /// Every value stored, on any file, the Releases' other files included.
    values_written: u64,
};

pub const CorrectionGroup = database.CorrectionGroup;
pub const CorrectionGroupMember = database.CorrectionGroupMember;
pub const CorrectionGroupPage = database.CorrectionGroupPage;
pub const CorrectionGroupAcceptance = ConfidentMatchAcceptance;
pub const TrackVerification = database.TrackVerification;
pub const VerificationOutcome = database.VerificationOutcome;
pub const HeardRecording = database.HeardRecording;

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
    host_signal: control.HostSignal = .{},
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
    /// A host's provider job waiting for a maintenance unit to stop.
    /// Control lane only.
    pending_host_job: ?runtime_jobs.PendingHostJob = null,
    /// Null until the host calls `setClientIdentity`.
    client_identity: ?network.client.OwnedIdentity = null,
    credential_store: ?CredentialStore = null,
    listenbrainz_server: providers.url.OwnedServer = .fixed(providers.listenbrainz.default_server),
    musicbrainz_server: providers.url.OwnedServer = .fixed(providers.musicbrainz.default_server),
    /// Version of the three settings above, copied into every Library's
    /// listen config.
    listen_settings: u32 = 0,
    acoustid_server: providers.url.OwnedServer = .fixed(providers.acoustid.default_server),
    acoustid_client_key: ?job_worker.OwnedAcoustIdKey = null,
    coverartarchive_server: providers.url.OwnedServer = .fixed(providers.coverartarchive.default_server),
    lrclib_server: providers.url.OwnedServer = .fixed(providers.lrclib.default_server),
    wikidata_server: providers.url.OwnedServer = .fixed(providers.wikidata.default_server),
    wikimedia_commons_server: providers.url.OwnedServer = .fixed(providers.wikimedia_commons.default_server),
    /// Null asks each language's own Wikipedia.
    wikipedia_server: ?providers.url.OwnedServer = null,
    listenbrainz_labs_server: providers.url.OwnedServer = .fixed(providers.listenbrainz_labs.default_server),
    /// One per runtime, created with the first listen worker and deinitialized
    /// after the last is joined. `Threaded.init` installs SIGIO and SIGPIPE
    /// handlers and `deinit` restores what it found, so a second instance torn
    /// down while this one has a request in flight would leave the host's
    /// dispositions -- the default one kills the process -- in place under it.
    network_threaded: ?*std.Io.Threaded = null,
    /// The one Library whose listens go to ListenBrainz, so a runtime never
    /// has two gateways to one service.
    scrobbling_library: ?LibraryHandle = null,
    /// The control lane's own `std.Io`, for clock reads, worker wakeups and
    /// taking and releasing a tag write's journal lock only.
    control_threaded: std.Io.Threaded = .init_single_threaded,
    last_listen_sample_ms: ?i64 = null,
    /// Fixes every random smart playlist order until
    /// `libraryReshufflePlaylists`; drawn on first use.
    playlist_shuffle_seed: ?u64 = null,
    /// Replaced by tests that must not reach a network or wait in real time.
    listen_hooks: listen_worker.Hooks = .{},
    matching_hooks: MatchingHooks = .{},
    /// Caps the watches each watcher adds, as `fs.inotify.max_user_watches`
    /// would, so tests can reach the limit.
    watch_limit: ?u32 = null,

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
        runtime_listens.endListens(self, null);
        for (self.players.slots.items) |*slot| {
            if (slot.value) |*player| runtime_queue.stopEngine(self, player);
        }
        runtime_jobs.cancelJobWorkers(self);
        self.work_registry.requestCancellation();
        runtime_listens.wakeListenWorkers(self);
        self.work_registry.drain();
        runtime_jobs.finalizeDrainedJobWorkers(self);
        self.releaseDrainedArtworkLoaders();
        runtime_listens.releaseDrainedListenWorkers(self);
        runtime_watch.releaseDrainedWatchers(self);
        runtime_jobs.freeAllJobWorkers(self);
        runtime_jobs.discardPendingTagWrites(self, null);
        runtime_jobs.dropQueuedHostJob(self, null);
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
                runtime_listens.freeListens(self, library);
            }
        }
        self.libraries.discardAll();

        self.state.store(.stopped, .release);
    }

    pub fn createLibrary(self: *OrcaRuntime) !LibraryHandle {
        try requireRunning(self);
        return self.libraries.insert(.{});
    }

    pub fn openLibrary(
        self: *OrcaRuntime,
        io: std.Io,
        path: [:0]const u8,
    ) !LibraryHandle {
        try requireRunning(self);
        const library_database = try self.allocator.create(database.LibraryDatabase);
        errdefer self.allocator.destroy(library_database);
        library_database.* = try database.LibraryDatabase.open(self.allocator, io, path);
        errdefer library_database.close();
        return self.libraries.insert(.{ .database = library_database });
    }

    pub fn destroyLibrary(self: *OrcaRuntime, library: LibraryHandle) !void {
        try requireRunning(self);
        runtime_listens.endListens(self, library);
        // A scan or projection worker holds this database by pointer, so it is
        // cancelled and joined before the connection can be closed. Work is not
        // yet scoped per object, so this conservatively drains every worker —
        // the same trade `joinWorkersBeforeDestroy` documents.
        runtime_jobs.cancelJobWorkers(self);
        self.joinWorkersBeforeDestroy();
        defer runtime_watch.rearmWatchers(self);
        runtime_queue.reapStoppedEngines(self);
        runtime_jobs.finalizeDrainedJobWorkers(self);
        // Openers hold a pointer into the Library they resolve through, so
        // every Player bound to it has to let go — with its engine stopped —
        // before the database is closed.
        self.unbindLibraryFromPlayers(library);
        runtime_jobs.discardPendingTagWrites(self, library);
        runtime_jobs.dropQueuedHostJob(self, library);
        var removed = try self.libraries.remove(library);
        self.closeLibraryDatabase(&removed);
        runtime_listens.freeListens(self, &removed);
        if (self.scrobbling_library) |scrobbling| {
            if (scrobbling.eql(library)) self.scrobbling_library = null;
        }
        runtime_listens.restartScrobblingListenWorker(self);
    }

    fn unbindLibraryFromPlayers(self: *OrcaRuntime, library: LibraryHandle) void {
        for (self.players.slots.items) |*slot| {
            const object_value = if (slot.value) |*value| value else continue;
            const opener = object_value.opener orelse continue;
            if (!opener.library.eql(library)) continue;
            runtime_queue.forgetAudibleEntry(self, object_value);
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

    /// Files that still owe the default loudness and fingerprint measurement.
    pub fn libraryUnanalyzedCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return (try libraryDatabase(self, library)).files.unanalyzedCount(
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
        const library_database = try libraryDatabase(self, library);
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
        const library_database = try libraryDatabase(self, library);
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
        return (try libraryDatabase(self, library)).tracks.count();
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
    /// scoped by every filter `page_query` sets.
    ///
    /// A full-text `query` keeps those filters but orders the matches by
    /// relevance: FTS5 ranks, and no sort key or `tracks.id` tiebreaker can be
    /// reconciled with a rank, so `page_query.sort` and `direction` do not
    /// apply to a search.
    pub fn libraryTrackQuery(
        self: *OrcaRuntime,
        library: LibraryHandle,
        text_query: []const u8,
        page_query: database.TrackQuery,
    ) !database.TrackPage {
        const tracks = &(try libraryDatabase(self, library)).tracks;
        if (text_query.len == 0) return tracks.page(self.allocator, page_query);
        return tracks.search(self.allocator, text_query, page_query);
    }

    /// The Artists, Releases, Tracks, Playlists and Genres where every word of
    /// `text` begins a word of the name or `SearchHit.subtitle`, ignoring case
    /// and diacritics, up to each kind's cap in `limits`, with each kind's
    /// detail and the hit to feature as `SearchResults.top`. Within their caps,
    /// the Playlists holding Tracks of the first Artist hit and that Artist's
    /// main genre follow, with `SearchHit.reason` saying why. Text with no
    /// word gives no hits.
    pub fn librarySearch(
        self: *OrcaRuntime,
        library: LibraryHandle,
        text: []const u8,
        limits: database.SearchLimits,
    ) !database.SearchResults {
        return (try libraryDatabase(self, library)).search.find(self.allocator, text, limits);
    }

    pub fn libraryTrackMatchCount(
        self: *OrcaRuntime,
        library: LibraryHandle,
        query: database.TrackQuery,
    ) !u64 {
        return (try libraryDatabase(self, library)).tracks.countMatching(query);
    }

    /// How many Tracks `libraryTrackQuery` would page through for the same
    /// search text and filters, and their summed duration.
    pub fn libraryTrackQueryTotals(
        self: *OrcaRuntime,
        library: LibraryHandle,
        text_query: []const u8,
        query: database.TrackQuery,
    ) !database.TrackTotals {
        const tracks = &(try libraryDatabase(self, library)).tracks;
        if (text_query.len == 0) return tracks.totals(query);
        return tracks.searchTotals(text_query, query);
    }

    /// The ids of the playable Tracks among `query.limit` rows from
    /// `query.offset` of the listing `libraryTrackQuery` pages through for the
    /// same text and filters, in its order: a whole playback queue's worth,
    /// up to `database.max_track_id_window` rows. Caller-owned, freed with
    /// `allocator`.
    pub fn libraryTrackQueryPlayableIds(
        self: *OrcaRuntime,
        library: LibraryHandle,
        allocator: std.mem.Allocator,
        text_query: []const u8,
        query: database.TrackQuery,
    ) ![]i64 {
        return (try libraryDatabase(self, library)).tracks.playableIds(allocator, text_query, query);
    }

    pub fn libraryArtistCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return (try libraryDatabase(self, library)).artists.count();
    }

    pub fn libraryArtistPage(
        self: *OrcaRuntime,
        library: LibraryHandle,
        query: database.ArtistQuery,
    ) !database.ArtistPage {
        return (try libraryDatabase(self, library)).artists.page(self.allocator, query);
    }

    /// How many Artists `libraryArtistPage` would return for the same query.
    /// A browser cannot show a total otherwise, and paging to exhaustion to
    /// count is what a bounded page exists to avoid.
    pub fn libraryArtistCountMatching(
        self: *OrcaRuntime,
        library: LibraryHandle,
        query: database.ArtistQuery,
    ) !u64 {
        return (try libraryDatabase(self, library)).artists.countMatching(query);
    }

    /// How many Releases `libraryReleasePage` would return for the same query.
    pub fn libraryReleaseCountMatching(
        self: *OrcaRuntime,
        library: LibraryHandle,
        query: database.ReleaseQuery,
    ) !u64 {
        return (try libraryDatabase(self, library)).releases.countMatching(query);
    }

    /// How many Releases `libraryReleasePage` would return for the same
    /// query, the album Artists they are filed under and the bytes their
    /// Tracks play.
    pub fn libraryReleaseQueryTotals(
        self: *OrcaRuntime,
        library: LibraryHandle,
        query: database.ReleaseQuery,
    ) !database.ReleaseTotals {
        return (try libraryDatabase(self, library)).releases.totals(query);
    }

    /// The letters that begin the names of the Releases `libraryReleasePage`
    /// would return, each with the offset of its first Release there, so a
    /// host can jump to a letter by paging from it. Only the title and artist
    /// sorts have letters; caller-owned, free with `allocator`.
    pub fn libraryReleaseLetterIndex(
        self: *OrcaRuntime,
        library: LibraryHandle,
        allocator: std.mem.Allocator,
        query: database.ReleaseQuery,
    ) ![]database.LetterBucket {
        return (try libraryDatabase(self, library)).releases.letterIndex(allocator, query);
    }

    pub fn libraryArtist(
        self: *OrcaRuntime,
        library: LibraryHandle,
        artist_id: i64,
    ) !?database.ArtistSummary {
        return (try libraryDatabase(self, library)).artists.byId(self.allocator, artist_id);
    }

    /// The Artist's release, track and appearance counts and summed
    /// duration, or null for an unknown Artist.
    pub fn libraryArtistTotals(
        self: *OrcaRuntime,
        library: LibraryHandle,
        artist_id: i64,
    ) !?database.ArtistTotals {
        return (try libraryDatabase(self, library)).artists.totals(artist_id);
    }

    pub fn libraryReleaseCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return (try libraryDatabase(self, library)).releases.count();
    }

    pub fn libraryReleasePage(
        self: *OrcaRuntime,
        library: LibraryHandle,
        query: database.ReleaseQuery,
    ) !database.ReleasePage {
        return (try libraryDatabase(self, library)).releases.page(self.allocator, query);
    }

    pub fn libraryRelease(
        self: *OrcaRuntime,
        library: LibraryHandle,
        release_id: i64,
    ) !?database.ReleaseSummary {
        return (try libraryDatabase(self, library)).releases.byId(self.allocator, release_id);
    }

    /// The cover image embedded in a Track's file, else the one fetched for
    /// its Release, or null when there is neither.
    ///
    /// Caller-owned bytes plus the media type those bytes actually are; free
    /// with `EmbeddedImage.deinit`. An embedded cover is read from the file on
    /// every call, and deliberately not cached and deliberately not stored:
    /// see `docs/metadata.md` for the measurements behind both decisions.
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
        return artwork.trackArtwork(self.allocator, io, try libraryDatabase(self, library), track_id);
    }

    pub const max_release_artwork_candidates = artwork.max_release_candidates;

    /// The cover image for a Release, or the one fetched for it when none of
    /// its files has one, read on the caller's thread. See `artwork.releaseArtwork` for which
    /// file's cover that is.
    pub fn libraryReleaseArtwork(
        self: *OrcaRuntime,
        library: LibraryHandle,
        io: std.Io,
        release_id: i64,
    ) !?metadata.EmbeddedImage {
        return artwork.releaseArtwork(self.allocator, io, try libraryDatabase(self, library), release_id);
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
        try requireRunning(self);
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
                .host_signal = &self.host_signal,
            },
            .work_handle = work_handle,
        };
        registration.waker = loader.loader.waker();
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
            loader.loader.deinit();
            self.allocator.destroy(loader);
            object_value.artwork = null;
        }
    }

    /// Names the host to MusicBrainz, AcoustID and ListenBrainz and in its
    /// listen history, from each listen worker's next pass. Required before
    /// matching, AcoustID submission or scrobbling. The strings are copied.
    pub fn setClientIdentity(self: *OrcaRuntime, identity: ClientIdentity) !void {
        return runtime_listens.setClientIdentity(self, identity);
    }

    /// Where listen workers read the ListenBrainz user token, from each
    /// worker's next pass, and jobs started afterwards the AcoustID keys; null
    /// removes it. `store.get` is called on a worker's thread; `store` must
    /// outlive the runtime.
    pub fn setCredentialStore(self: *OrcaRuntime, store: ?CredentialStore) !void {
        return runtime_listens.setCredentialStore(self, store);
    }

    /// Points scrobbling at a self-hosted or compatible ListenBrainz server,
    /// from each listen worker's next pass. `https` anywhere, or `http` to
    /// `127.0.0.1`, `[::1]` or `localhost` only, because the user token
    /// travels in every request; at most `providers.url.max_server_bytes`.
    /// `base_url` is copied; null restores the default server.
    pub fn setListenBrainzServer(self: *OrcaRuntime, base_url: ?[]const u8) !void {
        return runtime_listens.setListenBrainzServer(self, base_url);
    }

    /// Points matching jobs started afterwards at another MusicBrainz server,
    /// under the same rule as `setListenBrainzServer`.
    pub fn setMusicBrainzServer(self: *OrcaRuntime, base_url: ?[]const u8) !void {
        return runtime_listens.setMusicBrainzServer(self, base_url);
    }

    /// The AcoustID application key matching and submission jobs use, unless
    /// the credential store holds one under `org.acoustid`/`client-key`.
    /// Without either, matching skips AcoustID. `key` is copied; null clears
    /// it. Applies to jobs started afterwards.
    pub fn setAcoustIdClientKey(self: *OrcaRuntime, key: ?[]const u8) !void {
        return runtime_listens.setAcoustIdClientKey(self, key);
    }

    /// Points AcoustID lookups and submissions started afterwards at another
    /// server, under the same rule as `setListenBrainzServer`.
    pub fn setAcoustIdServer(self: *OrcaRuntime, base_url: ?[]const u8) !void {
        return runtime_listens.setAcoustIdServer(self, base_url);
    }

    /// Points cover fetches started afterwards at another Cover Art Archive,
    /// under the same rule as `setListenBrainzServer`. A loopback server may
    /// redirect to itself.
    pub fn setCoverArtArchiveServer(self: *OrcaRuntime, base_url: ?[]const u8) !void {
        return runtime_listens.setCoverArtArchiveServer(self, base_url);
    }

    /// Points lyrics fetches started afterwards at another LRCLIB server,
    /// under the same rule as `setListenBrainzServer`.
    pub fn setLrclibServer(self: *OrcaRuntime, base_url: ?[]const u8) !void {
        return runtime_listens.setLrclibServer(self, base_url);
    }

    /// Points artist info fetches started afterwards at another Wikidata,
    /// under the same rule as `setListenBrainzServer`.
    pub fn setWikidataServer(self: *OrcaRuntime, base_url: ?[]const u8) !void {
        return runtime_listens.setWikidataServer(self, base_url);
    }

    /// Points artist info fetches started afterwards at another Wikimedia
    /// Commons API, under the same rule as `setListenBrainzServer`. Its
    /// images come from `upload.wikimedia.org`, or from a loopback server's
    /// own host.
    pub fn setWikimediaCommonsServer(self: *OrcaRuntime, base_url: ?[]const u8) !void {
        return runtime_listens.setWikimediaCommonsServer(self, base_url);
    }

    /// Points artist info fetches started afterwards at one server for every
    /// Wikipedia language, under the same rule as `setListenBrainzServer`.
    /// Null asks `https://{language}.wikipedia.org`.
    pub fn setWikipediaServer(self: *OrcaRuntime, base_url: ?[]const u8) !void {
        return runtime_listens.setWikipediaServer(self, base_url);
    }

    /// Points the related artists of artist info fetches started afterwards
    /// at another ListenBrainz Labs API, under the same rule as
    /// `setListenBrainzServer`.
    pub fn setListenBrainzLabsServer(self: *OrcaRuntime, base_url: ?[]const u8) !void {
        return runtime_listens.setListenBrainzLabsServer(self, base_url);
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
        return runtime_listens.librarySetScrobbling(self, library, enabled, offline, now_playing);
    }

    /// Tells the Library's worker the ListenBrainz token may have changed. The
    /// worker validates it once, the next time it could make a request, and
    /// reports the user name or the rejection in `libraryScrobblerStatus`.
    pub fn libraryScrobblerCredentialsChanged(self: *OrcaRuntime, library: LibraryHandle) !void {
        return runtime_listens.libraryScrobblerCredentialsChanged(self, library);
    }

    /// The scrobbler's last published state. A Library without a running
    /// worker reports the queue counts from its database, at most once a
    /// second, and starts nothing.
    pub fn libraryScrobblerStatus(self: *OrcaRuntime, library: LibraryHandle) !ScrobblerStatus {
        return runtime_listens.libraryScrobblerStatus(self, library);
    }

    /// Listens recorded since the Library was opened: one atomic load, so a
    /// host may poll it every tick to learn when to reread its history.
    pub fn libraryListensRecorded(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return runtime_listens.libraryListensRecorded(self, library);
    }

    pub fn librarySetFeedback(
        self: *OrcaRuntime,
        library: LibraryHandle,
        track_ids: []const i64,
        feedback: Feedback,
    ) !FeedbackChange {
        return runtime_listens.librarySetFeedback(self, library, track_ids, feedback);
    }

    pub fn libraryMatchProposals(
        self: *OrcaRuntime,
        library: LibraryHandle,
        track_id: i64,
        limit: u32,
    ) !MatchProposalPage {
        return runtime_listens.libraryMatchProposals(self, library, track_id, limit);
    }

    pub fn libraryAcceptMatch(self: *OrcaRuntime, library: LibraryHandle, proposal_id: i64) !MatchAcceptance {
        return runtime_listens.libraryAcceptMatch(self, library, proposal_id);
    }

    pub fn libraryDismissMatch(self: *OrcaRuntime, library: LibraryHandle, proposal_id: i64) !void {
        return runtime_listens.libraryDismissMatch(self, library, proposal_id);
    }

    /// Album groups a verification proposed: corrections of one Release's
    /// files, accepted or dismissed only together.
    pub fn libraryCorrectionGroups(
        self: *OrcaRuntime,
        library: LibraryHandle,
        allocator: std.mem.Allocator,
        limit: u32,
        offset: u32,
    ) !CorrectionGroupPage {
        return runtime_listens.libraryCorrectionGroups(self, library, allocator, limit, offset);
    }

    /// Accepts every pending correction of the group, in one transaction, and
    /// reprojects the files given values.
    pub fn libraryAcceptCorrectionGroup(self: *OrcaRuntime, library: LibraryHandle, group_id: i64) !CorrectionGroupAcceptance {
        return runtime_listens.libraryAcceptCorrectionGroup(self, library, group_id);
    }

    pub fn libraryDismissCorrectionGroup(self: *OrcaRuntime, library: LibraryHandle, group_id: i64) !void {
        return runtime_listens.libraryDismissCorrectionGroup(self, library, group_id);
    }

    /// The Track's file's last verification, or null when it was never
    /// verified.
    pub fn libraryTrackVerification(
        self: *OrcaRuntime,
        library: LibraryHandle,
        allocator: std.mem.Allocator,
        track_id: i64,
    ) !?TrackVerification {
        return runtime_listens.libraryTrackVerification(self, library, allocator, track_id);
    }

    /// Tracks with a pending proposal, by artist, album and position, each
    /// with its best proposal.
    pub fn libraryMatchReviewPage(
        self: *OrcaRuntime,
        library: LibraryHandle,
        limit: u32,
        offset: u32,
    ) !MatchReviewPage {
        return runtime_listens.libraryMatchReviewPage(self, library, limit, offset);
    }

    pub fn libraryMatchReviewCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return runtime_listens.libraryMatchReviewCount(self, library);
    }

    /// Tracks a matching job with fingerprints would search: no recording ID,
    /// and not yet answered for by MusicBrainz, or by AcoustID when a key is
    /// set.
    pub fn libraryUnidentifiedCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return runtime_listens.libraryUnidentifiedCount(self, library);
    }

    /// How many matches `libraryAcceptConfidentMatches` would accept now.
    pub fn libraryConfidentMatchCount(self: *OrcaRuntime, library: LibraryHandle, minimum_confidence: f32) !u64 {
        return runtime_listens.libraryConfidentMatchCount(self, library, minimum_confidence);
    }

    pub fn libraryAcceptConfidentMatches(self: *OrcaRuntime, library: LibraryHandle, minimum_confidence: f32) !ConfidentMatchAcceptance {
        return runtime_listens.libraryAcceptConfidentMatches(self, library, minimum_confidence);
    }

    /// Stores what the MusicBrainz release a Release's accepted matches
    /// agree on says, when every Track names it, and reprojects. For a
    /// Release that came to agree without an accept: after an edit moved a
    /// stray file out, or a rescan. Returns how many values were stored.
    pub fn libraryApplyMatchedRelease(self: *OrcaRuntime, library: LibraryHandle, release_id: i64) !u32 {
        return runtime_listens.libraryApplyMatchedRelease(self, library, release_id);
    }

    pub fn libraryTrackFeedback(self: *OrcaRuntime, library: LibraryHandle, track_id: i64) !Feedback {
        return runtime_listens.libraryTrackFeedback(self, library, track_id);
    }

    pub fn librarySetRating(
        self: *OrcaRuntime,
        library: LibraryHandle,
        track_ids: []const i64,
        rating: ?u8,
    ) !RatingChange {
        return runtime_playlists.librarySetRating(self, library, track_ids, rating);
    }

    /// Loves or clears whole Releases. Album love is kept in the Library only:
    /// it is never queued for ListenBrainz.
    pub fn librarySetReleaseLove(
        self: *OrcaRuntime,
        library: LibraryHandle,
        release_ids: []const i64,
        loved: bool,
    ) !ReleaseLoveChange {
        return runtime_playlists.librarySetReleaseLove(self, library, release_ids, loved);
    }

    /// Loves or clears Artists. Artist love is kept in the Library only: it
    /// is never queued for ListenBrainz.
    pub fn librarySetArtistLove(
        self: *OrcaRuntime,
        library: LibraryHandle,
        artist_ids: []const i64,
        loved: bool,
    ) !database.ArtistLoveChange {
        return runtime_artist_info.librarySetArtistLove(self, library, artist_ids, loved);
    }

    pub fn libraryArtistLoved(self: *OrcaRuntime, library: LibraryHandle, artist_id: i64) !bool {
        return runtime_artist_info.libraryArtistLoved(self, library, artist_id);
    }

    /// What `startArtistInfoFetch` last kept for an Artist, without the photo
    /// bytes; null when nothing was ever fetched. The caller frees it with
    /// `deinit`.
    pub fn libraryArtistInfo(self: *OrcaRuntime, library: LibraryHandle, artist_id: i64) !?database.ArtistInfo {
        return runtime_artist_info.libraryArtistInfo(self, library, artist_id);
    }

    /// The Artist's kept photo, local or from Wikimedia Commons, or null.
    /// The caller frees it with `deinit`.
    pub fn libraryArtistPhoto(self: *OrcaRuntime, library: LibraryHandle, artist_id: i64) !?metadata.EmbeddedImage {
        return runtime_artist_info.libraryArtistPhoto(self, library, artist_id);
    }

    /// The Artist's kept links, by kind and then URL. The caller frees them
    /// with `deinit`.
    pub fn libraryArtistLinks(self: *OrcaRuntime, library: LibraryHandle, artist_id: i64) !database.ArtistLinks {
        return runtime_artist_info.libraryArtistLinks(self, library, artist_id);
    }

    /// The Artist's related artists from ListenBrainz Labs, most similar
    /// first, at most `database.related_artists_max`, each with the Library
    /// Artist it names when one exists. The caller frees them with `deinit`.
    pub fn libraryRelatedArtists(self: *OrcaRuntime, library: LibraryHandle, artist_id: i64) !database.RelatedArtists {
        return runtime_artist_info.libraryRelatedArtists(self, library, artist_id);
    }

    /// The photo `startArtistInfoFetch` kept for a related artist outside
    /// the Library, by MusicBrainz artist ID compared without case; null when
    /// none is kept or it was found to have none. Reads only the Library.
    /// The caller frees it with `deinit`.
    pub fn libraryRelatedArtistPhoto(self: *OrcaRuntime, library: LibraryHandle, musicbrainz_artist_id: []const u8) !?metadata.EmbeddedImage {
        return runtime_artist_info.libraryRelatedArtistPhoto(self, library, musicbrainz_artist_id);
    }

    /// Where the photo `libraryRelatedArtistPhoto` returns came from and the
    /// credit it needs: its Commons page, licence, licence URL and author.
    /// Null when no photo is kept. The caller frees it with `deinit`.
    pub fn libraryRelatedArtistPhotoInfo(self: *OrcaRuntime, library: LibraryHandle, musicbrainz_artist_id: []const u8) !?database.RelatedArtistPhotoInfo {
        return runtime_artist_info.libraryRelatedArtistPhotoInfo(self, library, musicbrainz_artist_id);
    }

    /// The MusicBrainz release groups `startArtistInfoFetch` kept for an
    /// Artist that none of its Releases or appearances in the Library
    /// belongs to, newest first, at most `database.artist_release_groups_max`.
    /// The caller frees each with `deinit` and the slice with `allocator`.
    pub fn libraryArtistElsewhere(self: *OrcaRuntime, library: LibraryHandle, allocator: std.mem.Allocator, artist_id: i64) ![]database.ElsewhereRelease {
        return runtime_artist_info.libraryArtistElsewhere(self, library, allocator, artist_id);
    }

    /// What `startReleaseInfoFetch` last kept for a Release; null when
    /// nothing was ever fetched. The caller frees it with `deinit`.
    pub fn libraryReleaseInfo(self: *OrcaRuntime, library: LibraryHandle, release_id: i64) !?database.ReleaseInfo {
        return runtime_artist_info.libraryReleaseInfo(self, library, release_id);
    }

    /// Lets artist and release info fetches fill genres from MusicBrainz for
    /// Tracks with none, or stops them. Kept in the Library.
    pub fn setGenreFill(self: *OrcaRuntime, library: LibraryHandle, fill: GenreFill) !void {
        return runtime_artist_info.setGenreFill(self, library, fill);
    }

    pub fn libraryGenreFill(self: *OrcaRuntime, library: LibraryHandle) !GenreFill {
        return runtime_artist_info.libraryGenreFill(self, library);
    }

    /// Genres that some Track carries, with their counts.
    pub fn libraryGenrePage(self: *OrcaRuntime, library: LibraryHandle, query: database.GenreQuery) !database.GenrePage {
        return runtime_genres.libraryGenrePage(self, library, query);
    }

    pub fn libraryGenreCount(self: *OrcaRuntime, library: LibraryHandle, filter: []const u8) !u64 {
        return runtime_genres.libraryGenreCount(self, library, filter);
    }

    /// Null when no Track carries the genre.
    pub fn libraryGenre(self: *OrcaRuntime, library: LibraryHandle, genre_id: i64) !?database.GenreSummary {
        return runtime_genres.libraryGenre(self, library, genre_id);
    }

    pub fn libraryTrackGenres(self: *OrcaRuntime, library: LibraryHandle, track_id: i64) !database.GenreNames {
        return runtime_genres.libraryTrackGenres(self, library, track_id);
    }

    pub fn libraryReleaseGenres(
        self: *OrcaRuntime,
        library: LibraryHandle,
        release_id: i64,
        limit: u32,
    ) !database.GenreCounts {
        return runtime_genres.libraryReleaseGenres(self, library, release_id, limit);
    }

    pub fn libraryArtistGenres(
        self: *OrcaRuntime,
        library: LibraryHandle,
        artist_id: i64,
        limit: u32,
    ) !database.GenreCounts {
        return runtime_genres.libraryArtistGenres(self, library, artist_id, limit);
    }

    /// Gives each Track exactly `names` as the user's genres, which outrank
    /// its file's on every later scan. Empty `names` restores the file's.
    /// Kept in the library until `planTagWrite` writes them into the files.
    pub fn librarySetTrackGenres(
        self: *OrcaRuntime,
        library: LibraryHandle,
        track_ids: []const i64,
        names: []const []const u8,
    ) !void {
        return runtime_genres.librarySetTrackGenres(self, library, track_ids, names);
    }

    /// The genre's most played Releases that have a cover, for a cover mosaic.
    pub fn libraryGenreArtwork(self: *OrcaRuntime, library: LibraryHandle, genre_id: i64, limit: u32) !database.ReleaseIds {
        return runtime_genres.libraryGenreArtwork(self, library, genre_id, limit);
    }

    pub fn libraryPlaylists(self: *OrcaRuntime, library: LibraryHandle, limit: u32, offset: u32) !PlaylistPage {
        return runtime_playlists.libraryPlaylists(self, library, limit, offset);
    }

    /// A page of playlists filtered and sorted as `query` asks. A smart
    /// playlist's counts, length and genres are its rules evaluated now.
    pub fn libraryPlaylistPage(self: *OrcaRuntime, library: LibraryHandle, query: PlaylistQuery) !PlaylistPage {
        return runtime_playlists.libraryPlaylistPage(self, library, query);
    }

    /// How many playlists `query` selects, ignoring its sort and page.
    pub fn libraryPlaylistCount(self: *OrcaRuntime, library: LibraryHandle, query: PlaylistQuery) !u64 {
        return runtime_playlists.libraryPlaylistCount(self, library, query);
    }

    pub fn libraryPlaylist(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64) !PlaylistSummary {
        return runtime_playlists.libraryPlaylist(self, library, playlist_id);
    }

    /// Changes a playlist's description, pin, love or tags; the library
    /// keeps them and no file is written.
    pub fn libraryUpdatePlaylist(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64, change: PlaylistUpdate) !void {
        return runtime_playlists.libraryUpdatePlaylist(self, library, playlist_id, change);
    }

    /// Creates a playlist whose Tracks are chosen by `rules_json`, the
    /// format `docs/api.md` describes. Its entries cannot be edited.
    pub fn libraryCreateSmartPlaylist(self: *OrcaRuntime, library: LibraryHandle, name: []const u8, rules_json: []const u8) !i64 {
        return runtime_playlists.libraryCreateSmartPlaylist(self, library, name, rules_json);
    }

    pub fn librarySetSmartPlaylistRules(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64, rules_json: []const u8) !void {
        return runtime_playlists.librarySetSmartPlaylistRules(self, library, playlist_id, rules_json);
    }

    /// A smart playlist's rules as stored, owned by the runtime's allocator;
    /// null for a manual playlist.
    pub fn librarySmartPlaylistRules(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64) !?[]u8 {
        return runtime_playlists.librarySmartPlaylistRules(self, library, playlist_id);
    }

    /// A playlist's tags in the order they were given, owned by the
    /// runtime's allocator.
    pub fn libraryPlaylistTags(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64) ![][]u8 {
        return runtime_playlists.libraryPlaylistTags(self, library, playlist_id);
    }

    /// How many Tracks `rules_json` matches now, up to its limit, without
    /// saving it.
    pub fn librarySmartPlaylistCount(self: *OrcaRuntime, library: LibraryHandle, rules_json: []const u8) !u64 {
        return runtime_playlists.librarySmartPlaylistCount(self, library, rules_json);
    }

    /// What `rules_json` selects now, without saving it: the count and total
    /// length up to its limit and the first `sample_limit` (at most 512)
    /// Tracks in its order, owned by `allocator`.
    pub fn librarySmartPlaylistPreview(
        self: *OrcaRuntime,
        library: LibraryHandle,
        allocator: std.mem.Allocator,
        rules_json: []const u8,
        sample_limit: u32,
    ) !SmartPlaylistPreview {
        return runtime_playlists.librarySmartPlaylistPreview(self, library, allocator, rules_json, sample_limit);
    }

    /// Draws new random orders for every smart playlist sorted at random.
    /// Until then each one keeps its order across reads, so its pages agree.
    pub fn libraryReshufflePlaylists(self: *OrcaRuntime) void {
        runtime_playlists.libraryReshufflePlaylists(self);
    }

    /// The codecs a playlist's available entries play and how many of them
    /// are analyzed, owned by `allocator`.
    pub fn libraryPlaylistFormats(self: *OrcaRuntime, library: LibraryHandle, allocator: std.mem.Allocator, playlist_id: i64) !PlaylistFormats {
        return runtime_playlists.libraryPlaylistFormats(self, library, allocator, playlist_id);
    }

    pub fn libraryCreatePlaylist(self: *OrcaRuntime, library: LibraryHandle, name: []const u8) !i64 {
        return runtime_playlists.libraryCreatePlaylist(self, library, name);
    }

    pub fn libraryRenamePlaylist(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64, name: []const u8) !void {
        return runtime_playlists.libraryRenamePlaylist(self, library, playlist_id, name);
    }

    pub fn libraryDeletePlaylist(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64) !void {
        return runtime_playlists.libraryDeletePlaylist(self, library, playlist_id);
    }

    /// An entry plays the Track of its recording with the lowest id; one
    /// whose recording has no Track left has a null `track`.
    pub fn libraryPlaylistEntries(
        self: *OrcaRuntime,
        library: LibraryHandle,
        playlist_id: i64,
        limit: u32,
        offset: u32,
    ) !PlaylistEntryPage {
        return runtime_playlists.libraryPlaylistEntries(self, library, playlist_id, limit, offset);
    }

    /// Adds the Tracks' recordings at `at`, or at the end when it is null.
    pub fn libraryPlaylistInsert(
        self: *OrcaRuntime,
        library: LibraryHandle,
        playlist_id: i64,
        track_ids: []const i64,
        at: ?u32,
    ) !PlaylistInsertion {
        return runtime_playlists.libraryPlaylistInsert(self, library, playlist_id, track_ids, at);
    }

    pub fn libraryPlaylistRemove(
        self: *OrcaRuntime,
        library: LibraryHandle,
        playlist_id: i64,
        positions: []const u32,
    ) !u32 {
        return runtime_playlists.libraryPlaylistRemove(self, library, playlist_id, positions);
    }

    pub fn libraryPlaylistMove(self: *OrcaRuntime, library: LibraryHandle, playlist_id: i64, from: u32, to: u32) !void {
        return runtime_playlists.libraryPlaylistMove(self, library, playlist_id, from, to);
    }

    /// `playerPlayTracks` with the playlist's available entries; `start`
    /// counts only those.
    pub fn playerPlayPlaylist(
        self: *OrcaRuntime,
        player: PlayerHandle,
        library: LibraryHandle,
        io: std.Io,
        playlist_id: i64,
        start: u32,
    ) !void {
        return runtime_playlists.playerPlayPlaylist(self, player, library, io, playlist_id, start);
    }

    /// Creates a playlist from an M3U or M3U8 file, matching each entry by
    /// path, then by its #EXTINF artist, title and length. Nothing is scanned.
    pub fn libraryImportPlaylist(
        self: *OrcaRuntime,
        library: LibraryHandle,
        io: std.Io,
        path: []const u8,
        name: ?[]const u8,
    ) !PlaylistImport {
        return runtime_playlists.libraryImportPlaylist(self, library, io, path, name);
    }

    /// Writes the playlist's available entries to `path` as UTF-8 M3U,
    /// replacing it atomically.
    pub fn libraryExportPlaylist(
        self: *OrcaRuntime,
        library: LibraryHandle,
        io: std.Io,
        playlist_id: i64,
        path: []const u8,
        options: PlaylistExportOptions,
    ) !PlaylistExport {
        return runtime_playlists.libraryExportPlaylist(self, library, io, playlist_id, path, options);
    }

    /// How often the Track's file has been heard, and when last.
    pub fn libraryTrackPlayStats(self: *OrcaRuntime, library: LibraryHandle, track_id: i64) !PlayStats {
        return runtime_listens.libraryTrackPlayStats(self, library, track_id);
    }

    /// The Library's counts and sizes, and when it was last scanned and
    /// analysed.
    pub fn libraryStats(self: *OrcaRuntime, library: LibraryHandle) !database.LibraryStats {
        return (try libraryDatabase(self, library)).stats.stats();
    }

    /// The services Orca takes data from, in `ProviderSourceId` order.
    pub fn providerSources(self: *const OrcaRuntime) []const provider_sources.ProviderSource {
        _ = self;
        return provider_sources.provider_sources;
    }

    pub fn libraryHealthIssueCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return (try libraryDatabase(self, library)).health_issues.count();
    }

    pub fn libraryHealthIssuePage(
        self: *OrcaRuntime,
        library: LibraryHandle,
        limit: u32,
        offset: u32,
    ) !database.HealthIssuePage {
        return (try libraryDatabase(self, library)).health_issues.page(
            self.allocator,
            limit,
            offset,
        );
    }

    /// The page of `libraryHealthIssuePage` holding only issues of `kind`.
    pub fn libraryHealthIssuePageOfKind(
        self: *OrcaRuntime,
        library: LibraryHandle,
        kind: database.HealthIssueKind,
        limit: u32,
        offset: u32,
    ) !database.HealthIssuePage {
        return (try libraryDatabase(self, library)).health_issues.pageOfKind(
            self.allocator,
            kind,
            limit,
            offset,
        );
    }

    /// Each kind with a visible issue: how many, and the highest severity.
    pub fn libraryHealthSummary(self: *OrcaRuntime, library: LibraryHandle) !database.HealthSummary {
        return (try libraryDatabase(self, library)).health_issues.summary();
    }

    /// Hides one issue of a file until the file's bytes change.
    pub fn libraryDismissHealthIssue(
        self: *OrcaRuntime,
        library: LibraryHandle,
        file_id: i64,
        kind: database.HealthIssueKind,
    ) !void {
        return (try libraryDatabase(self, library)).health_issues.dismiss(file_id, kind);
    }

    /// Shows a dismissed issue again.
    pub fn libraryRestoreHealthIssue(
        self: *OrcaRuntime,
        library: LibraryHandle,
        file_id: i64,
        kind: database.HealthIssueKind,
    ) !void {
        return (try libraryDatabase(self, library)).health_issues.restore(file_id, kind);
    }

    /// The file behind an issue as the Library last saw it, or null when it
    /// does not exist.
    pub fn libraryHealthFile(
        self: *OrcaRuntime,
        library: LibraryHandle,
        allocator: std.mem.Allocator,
        file_id: i64,
    ) !?database.HealthFile {
        return (try libraryDatabase(self, library)).health_issues.file(allocator, file_id);
    }

    pub fn createPlayer(self: *OrcaRuntime) !PlayerHandle {
        try requireRunning(self);
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
        try requireRunning(self);
        const destroyed = try self.players.get(player);
        if (destroyed.opener) |opener| runtime_listens.endListen(self, destroyed, opener.library);
        runtime_queue.stopEngine(self, destroyed);
        // Only this Player's workers: draining the registry would cancel other
        // Players' engines and every running job.
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
                        zone.zone.retire();
                    }
                }
            }
        }
    }

    pub fn createZone(self: *OrcaRuntime) !ZoneHandle {
        return runtime_zones.createZone(self);
    }

    /// Removes the Zone from its Player's published set, waits for the engine to
    /// acknowledge that removal, and only then closes the output and frees the
    /// Zone. The acknowledgement is the whole safety argument: `handle.Pool` has
    /// no locking, so a generational handle cannot protect a pointer an engine
    /// thread already dereferenced.
    pub fn destroyZone(self: *OrcaRuntime, zone: ZoneHandle) !void {
        return runtime_zones.destroyZone(self, zone);
    }

    /// Moving a Zone to another Player closes its output and discards the
    /// previous Player's prepared audio before returning; the new Player
    /// reopens the output in its own format. Attaching a Zone to the Player it
    /// is already on changes nothing.
    pub fn attachZone(self: *OrcaRuntime, zone: ZoneHandle, player: PlayerHandle) !void {
        return runtime_zones.attachZone(self, zone, player);
    }

    pub fn detachZone(self: *OrcaRuntime, zone: ZoneHandle) !void {
        return runtime_zones.detachZone(self, zone);
    }

    /// Asks the Zone's engine to open (or close) its output. Stream creation
    /// itself happens on the engine lane, never on the caller's thread.
    pub fn zoneRequestOutput(self: *OrcaRuntime, zone: ZoneHandle, device_id: u64) !void {
        return runtime_zones.zoneRequestOutput(self, zone, device_id);
    }

    pub fn zoneCloseOutput(self: *OrcaRuntime, zone: ZoneHandle) !void {
        return runtime_zones.zoneCloseOutput(self, zone);
    }

    /// Bounded, Orca-owned device snapshots. No backend type crosses this API.
    /// `.identity` returns ids, names and kinds without asking any device;
    /// `.capabilities` also waits for each device's formats, which can take
    /// hundreds of milliseconds when one does not answer.
    pub fn enumerateOutputDevices(
        self: *OrcaRuntime,
        devices: []audio.backend.Device,
        detail: audio.backend.DiscoveryDetail,
    ) !usize {
        return runtime_zones.enumerateOutputDevices(self, devices, detail);
    }

    pub fn setZonePolicy(
        self: *OrcaRuntime,
        zone: ZoneHandle,
        policy: audio.zone.RenderPolicy,
    ) !void {
        return runtime_zones.setZonePolicy(self, zone, policy);
    }

    pub fn zoneRenderStrategy(
        self: *OrcaRuntime,
        zone: ZoneHandle,
    ) !audio.zone.RenderStrategy {
        return runtime_zones.zoneRenderStrategy(self, zone);
    }

    /// Reads the state the engine publishes, never the engine-owned `Zone`
    /// struct itself.
    pub fn zoneOutputState(self: *OrcaRuntime, zone: ZoneHandle) !audio.zone.OutputState {
        return runtime_zones.zoneOutputState(self, zone);
    }

    pub fn zoneStats(self: *OrcaRuntime, zone: ZoneHandle) !ZoneStats {
        return runtime_zones.zoneStats(self, zone);
    }

    /// Seeking moves the decoder, which the engine thread is otherwise reading
    /// from, so the engine is stopped for the duration. The epoch bump is what
    /// makes the audio already prepared under the old position disappear.
    pub fn seekPlayer(self: *OrcaRuntime, player: PlayerHandle, frame: u64) !u32 {
        return runtime_queue.seekPlayer(self, player, frame);
    }

    /// Refuses a transport start that cannot produce audio.
    ///
    /// A Player with neither a loaded source nor a queue entry to load has
    /// nothing to play, and one with no attached Zone has nowhere to play it.
    pub fn playPlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
        return runtime_queue.playPlayer(self, player);
    }

    pub fn pausePlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
        return runtime_queue.pausePlayer(self, player);
    }

    /// Stops the transport and releases its decoders. Entries and cursor
    /// survive, so `stop` then `play` resumes the same queue at the same place.
    pub fn stopPlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
        return runtime_queue.stopPlayer(self, player);
    }

    pub fn playerSnapshot(self: *OrcaRuntime, player: PlayerHandle) !audio.player.Snapshot {
        return runtime_queue.playerSnapshot(self, player);
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
        return runtime_queue.playerLoadFile(self, player, io, path);
    }

    /// True once the source has decoded to its end and every Zone with a
    /// requested output, other than one whose recovery is exhausted, has handed
    /// back every block it was given.
    pub fn playerDrained(self: *OrcaRuntime, player: PlayerHandle) !bool {
        return runtime_queue.playerDrained(self, player);
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
        return runtime_queue.playerBindLibrary(self, player, library, io);
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
        return runtime_queue.playerPlayTrack(self, player, library, io, track_id);
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
        return runtime_queue.playerPlayTrackBound(self, player, library, track_id);
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
        return runtime_queue.playerPlayTracks(self, player, library, io, track_ids, start);
    }

    pub fn playerPlayTracksBound(
        self: *OrcaRuntime,
        player: PlayerHandle,
        library: LibraryHandle,
        track_ids: []const i64,
        start: u32,
    ) !void {
        return runtime_queue.playerPlayTracksBound(self, player, library, track_ids, start);
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
        return runtime_queue.playerEnqueueTracks(self, player, library, io, track_ids);
    }

    pub fn playerEnqueueTracksBound(
        self: *OrcaRuntime,
        player: PlayerHandle,
        library: LibraryHandle,
        track_ids: []const i64,
    ) !void {
        return runtime_queue.playerEnqueueTracksBound(self, player, library, track_ids);
    }

    /// Plays the queue entry at playback position `position` now: a hard
    /// switch, like a skip.
    pub fn playerQueueJump(self: *OrcaRuntime, player: PlayerHandle, position: u32) !void {
        return runtime_queue.playerQueueJump(self, player, position);
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
        return runtime_queue.playerQueueInsertNext(self, player, library, track_ids);
    }

    /// Removes the queue entry at playback position `position`. The entry
    /// playing and one the engine has already lined up are refused with
    /// `error.QueueEntryInUse`; skip past them first.
    pub fn playerQueueRemove(self: *OrcaRuntime, player: PlayerHandle, position: u32) !void {
        return runtime_queue.playerQueueRemove(self, player, position);
    }

    /// Moves the queue entry at playback position `from` so that it plays at
    /// position `to`, both in playback order. Under shuffle only the shuffled
    /// order changes: turning shuffle off afterwards restores list order. The
    /// entries `playerQueueRemove` refuses cannot move, and nothing can land
    /// between the entry playing and the one the engine has already lined up;
    /// both are refused with `error.QueueEntryInUse`. Moving `from` onto
    /// itself does nothing.
    pub fn playerQueueMove(self: *OrcaRuntime, player: PlayerHandle, from: u32, to: u32) !void {
        return runtime_queue.playerQueueMove(self, player, from, to);
    }

    /// A user skip is a **hard** switch: the epoch bump makes the callback
    /// discard everything already prepared, so it is immediate rather than
    /// waiting for the current track to drain. Returns false at the end of a
    /// queue that is not repeating.
    pub fn playerNext(self: *OrcaRuntime, player: PlayerHandle) !bool {
        return runtime_queue.playerNext(self, player);
    }

    /// Past three seconds `previous` restarts the current entry; before it, the
    /// cursor moves back. The universal transport convention, and the reason a
    /// shuffle permutation matters: random-next has no history to move back to.
    pub fn playerPrevious(self: *OrcaRuntime, player: PlayerHandle) !bool {
        return runtime_queue.playerPrevious(self, player);
    }

    pub fn playerSetRepeat(
        self: *OrcaRuntime,
        player: PlayerHandle,
        mode: RepeatMode,
    ) !void {
        return runtime_queue.playerSetRepeat(self, player, mode);
    }

    pub fn playerSetShuffle(
        self: *OrcaRuntime,
        player: PlayerHandle,
        enabled: bool,
    ) !void {
        return runtime_queue.playerSetShuffle(self, player, enabled);
    }

    /// Empties the queue and releases the decoders with it.
    pub fn playerClearQueue(self: *OrcaRuntime, player: PlayerHandle) !void {
        return runtime_queue.playerClearQueue(self, player);
    }

    /// Lock-free: entry count, audible cursor and decode cursor all come from
    /// atomics, so a host may poll this at UI rates without stopping the engine.
    pub fn playerQueueSnapshot(
        self: *OrcaRuntime,
        player: PlayerHandle,
    ) !QueueSnapshot {
        return runtime_queue.playerQueueSnapshot(self, player);
    }

    /// The entry actually being *heard*, which during a gapless transition is
    /// not the one the decoder has reached.
    ///
    /// Lock-free, deliberately: the entry list is mutated only by the control
    /// lane and the engine thread only ever reads it, so a control-lane reader
    /// cannot race one. Quiescing the producer to answer "what is playing"
    /// would park decoding on every UI poll.
    pub fn playerNowPlaying(self: *OrcaRuntime, player: PlayerHandle) !?TrackRef {
        return runtime_queue.playerNowPlaying(self, player);
    }

    /// The entries this Player stopped playing, newest first, from `offset`.
    /// Held in memory only: a new runtime starts with none.
    pub fn playerQueueHistory(
        self: *OrcaRuntime,
        player: PlayerHandle,
        offset: u32,
        output: []QueueHistoryEntry,
    ) !usize {
        return runtime_queue.playerQueueHistory(self, player, offset, output);
    }

    /// `playerQueueHistory` as the rows a host displays, newest first. An
    /// entry whose Library is closed or whose Track is gone is left out.
    pub fn playerQueueHistoryTracks(
        self: *OrcaRuntime,
        player: PlayerHandle,
        allocator: std.mem.Allocator,
        offset: u32,
        limit: u32,
    ) !database.TrackPage {
        return runtime_queue.playerQueueHistoryTracks(self, player, allocator, offset, limit);
    }

    pub fn playerClearQueueHistory(self: *OrcaRuntime, player: PlayerHandle) !void {
        return runtime_queue.playerClearQueueHistory(self, player);
    }

    /// Creates a playlist named `name` holding the current entry and every
    /// entry after it, in playback order, and returns its id.
    pub fn playerSaveQueueAsPlaylist(
        self: *OrcaRuntime,
        player: PlayerHandle,
        library: LibraryHandle,
        name: []const u8,
    ) !i64 {
        return runtime_queue.playerSaveQueueAsPlaylist(self, player, library, name);
    }

    /// Reads engine-thread counters, so it stops the engine for the duration.
    /// Called after a run, never in a UI poll loop.
    pub fn playerQueueStats(self: *OrcaRuntime, player: PlayerHandle) !QueueStats {
        return runtime_queue.playerQueueStats(self, player);
    }

    /// Seek to `tail_ms` before the end of the current entry. Exists so tests
    /// and the CLI can exercise a real album's transitions without waiting out
    /// every track in real time.
    pub fn playerSeekToTail(
        self: *OrcaRuntime,
        player: PlayerHandle,
        tail_ms: u64,
    ) !bool {
        return runtime_queue.playerSeekToTail(self, player, tail_ms);
    }

    /// Registers a Library root. Explicitly a user action, which is why this is
    /// the one path allowed to persist a volume identifier at a mount root.
    pub fn libraryAddRoot(
        self: *OrcaRuntime,
        library: LibraryHandle,
        io: std.Io,
        path: []const u8,
    ) !database.RootBinding {
        return runtime_roots.libraryAddRoot(self, library, io, path);
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
        return runtime_roots.libraryRemoveRoot(self, library, root_id);
    }

    pub fn libraryRootPage(
        self: *OrcaRuntime,
        library: LibraryHandle,
        limit: u32,
        offset: u32,
    ) !database.repository.LibraryRootPage {
        return runtime_roots.libraryRootPage(self, library, limit, offset);
    }

    /// One page of a folder below library root `root_id`: subfolders with
    /// recursive totals, then files with their Tracks. `relative_path` is
    /// empty for the root itself; missing locations are left out.
    pub fn libraryFolderPage(
        self: *OrcaRuntime,
        library: LibraryHandle,
        root_id: i64,
        relative_path: []const u8,
        limit: u32,
        offset: u32,
    ) !database.repository.FolderPage {
        return runtime_roots.libraryFolderPage(self, library, root_id, relative_path, limit, offset);
    }

    /// `playerPlayTracks` with every Track below the folder, in path order,
    /// at most `max_playlist_entries`, after setting shuffle to `shuffle`.
    pub fn playerPlayFolder(
        self: *OrcaRuntime,
        player: PlayerHandle,
        library: LibraryHandle,
        io: std.Io,
        root_id: i64,
        relative_path: []const u8,
        shuffle: bool,
    ) !void {
        return runtime_roots.playerPlayFolder(self, player, library, io, root_id, relative_path, shuffle);
    }

    pub fn libraryTrackSummary(
        self: *OrcaRuntime,
        library: LibraryHandle,
        track_id: i64,
    ) !?database.TrackSummary {
        return runtime_roots.libraryTrackSummary(self, library, track_id);
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
        return runtime_roots.libraryTrackDetails(self, library, track_id);
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
        return runtime_roots.libraryEditTracks(self, library, track_ids, edits);
    }

    /// Orca's values for a track, read from its preferred file.
    pub fn libraryTrackEdits(
        self: *OrcaRuntime,
        library: LibraryHandle,
        track_id: i64,
    ) !TrackEditPage {
        return runtime_roots.libraryTrackEdits(self, library, track_id);
    }

    /// Builds and seals a plan that writes Orca's values for `track_ids` into
    /// their files, and returns it for approval. Nothing is written. A locked
    /// value is written when it differs from the file's tag; an unlocked one
    /// only when the file has no tag for its field, and otherwise is reported
    /// in `conflicts` and left out. A file is left out when it has nothing to
    /// write, and reported in `skipped` when it cannot be written now. The
    /// plan waits in the runtime for `startTagWrite`; at most eight wait at
    /// once.
    pub fn planTagWrite(
        self: *OrcaRuntime,
        library: LibraryHandle,
        io: std.Io,
        track_ids: []const i64,
    ) !TagWritePlan {
        return runtime_roots.planTagWrite(self, library, io, track_ids);
    }

    /// Approves a pending plan by its digest and starts writing it as a job.
    /// A digest that does not match the plan leaves it pending and unwritten.
    /// The job is not cancellable once started: a journaled group finishes or
    /// rolls back as a whole. The files are re-observed and reprojected when
    /// it ends. A Library with no database file has nowhere to keep the
    /// originals and returns `error.NoBackupDirectory`. While another process,
    /// or another write, undo or prune in this one, holds the Library's
    /// journal lock it returns `error.MutationInProgress` and the plan stays
    /// pending. The job first finishes any mutation an interrupted holder
    /// left, and fails without writing if that recovery fails.
    pub fn startTagWrite(
        self: *OrcaRuntime,
        library: LibraryHandle,
        plan_id: u64,
        digest: metadata.mutation.Digest,
    ) !JobHandle {
        return runtime_roots.startTagWrite(self, library, plan_id, digest);
    }

    /// Drops a pending plan without writing anything.
    pub fn discardTagWrite(self: *OrcaRuntime, library: LibraryHandle, plan_id: u64) !void {
        return runtime_roots.discardTagWrite(self, library, plan_id);
    }

    /// The genres a pending plan writes into one of its files, as its
    /// `TagWritePlan` showed them, or null when the plan leaves the file's
    /// genres alone or does not write the file. Borrowed from the plan until
    /// it is started or discarded; a Zig host reads `TagWriteFile.genres`
    /// instead.
    pub fn tagWriteGenres(self: *OrcaRuntime, library: LibraryHandle, plan_id: u64, file_id: i64) !?TagWriteGenres {
        return runtime_roots.tagWriteGenres(self, library, plan_id, file_id);
    }

    /// Restores the files a tag write changed, on the caller's thread, and
    /// re-observes them. Orca's values are kept, so the library still shows
    /// the edit. A file changed again since the write, or whose backup is
    /// missing or damaged, is left alone and recorded for reconciliation
    /// rather than overwritten. A write whose backups were pruned returns
    /// `error.TagWriteBackupPruned` and changes nothing. An undo that was
    /// interrupted finishes; one that already finished re-observes the files
    /// and returns `error.MutationGroupAlreadyUndone`. Returns
    /// `error.MutationInProgress` while the journal lock is held elsewhere.
    /// Finishes any mutation an interrupted holder left before undoing.
    pub fn undoTagWrite(self: *OrcaRuntime, library: LibraryHandle, io: std.Io, group_id: u64) !void {
        return runtime_roots.undoTagWrite(self, library, io, group_id);
    }

    /// Deletes the originals kept for tag writes whose every file committed
    /// at least `older_than_s` seconds ago; zero prunes every committed write.
    /// A pruned write can no longer be undone. Writes awaiting reconciliation
    /// or being undone keep their backups. Returns `error.MutationInProgress`
    /// while the journal lock is held elsewhere. Finishes any mutation an
    /// interrupted holder left before pruning.
    pub fn pruneTagWriteBackups(self: *OrcaRuntime, library: LibraryHandle, io: std.Io, older_than_s: u64) !PruneSummary {
        return runtime_roots.pruneTagWriteBackups(self, library, io, older_than_s);
    }

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
        return runtime_jobs.startLibraryScan(self, library, request);
    }

    /// Starts a scan of one root, or of some directories under it, that marks
    /// missing only what those walks no longer found. Refused with
    /// `error.LibraryScanRunning` while a scan or reconcile of the Library
    /// runs, as `startLibraryScan` is.
    pub fn startLibraryReconcile(
        self: *OrcaRuntime,
        library: LibraryHandle,
        request: ReconcileRequest,
    ) !JobHandle {
        return runtime_jobs.startLibraryReconcile(self, library, request);
    }

    pub fn startLibraryProjection(self: *OrcaRuntime, library: LibraryHandle) !JobHandle {
        return runtime_jobs.startLibraryProjection(self, library);
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
        return runtime_jobs.startLibraryPropertyBackfill(self, library, request);
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
        return runtime_jobs.startLibraryAnalysis(self, library, request);
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
        return runtime_jobs.startLibraryDuplicateScan(self, library, request);
    }

    /// At most one runs per runtime, so MusicBrainz sees one request a second,
    /// and not while an AcoustID submission runs, so AcoustID sees one client.
    /// Started while a maintenance unit runs, it cancels the unit and is
    /// returned queued; `pump` starts it once the unit's `job_finished` is
    /// published. Its stats read as empty until then.
    pub fn startLibraryMatching(
        self: *OrcaRuntime,
        library: LibraryHandle,
        request: MatchRequest,
    ) !JobHandle {
        return runtime_jobs.startLibraryMatching(self, library, request);
    }

    /// Fetches a Release's front cover from the Cover Art Archive into the
    /// Library, unless one of its files carries a cover, under the release ID
    /// its tags give or most of its accepted matches name. `jobMatchStats`
    /// reports the `CoverArtOutcome`. Refused with
    /// `error.MatchingAlreadyRunning` beside a matching job; queued like
    /// `startLibraryMatching` beside a maintenance unit.
    pub fn startReleaseCoverArtFetch(self: *OrcaRuntime, library: LibraryHandle, release_id: i64) !JobHandle {
        return runtime_jobs.startReleaseCoverArtFetch(self, library, release_id);
    }

    /// Reads a Track's lyrics on a job worker: a synced `.lrc` sidecar beside
    /// its file, else synced lyrics embedded in the file, else synced lyrics
    /// from LRCLIB, else plain lyrics from the sidecar, then from the file,
    /// then from LRCLIB, else LRCLIB's word that the Track is instrumental.
    /// LRCLIB is asked only with `options.fetch`, which needs
    /// `setClientIdentity` (`error.ClientIdentityRequired`); without it, only
    /// an answer the Library already keeps for the Track's current title,
    /// artist, album and duration is used. `jobLyricsOutcome` reports what
    /// the job found, or with `fetch` what asking LRCLIB came to, and
    /// `jobTakeLyrics` hands the lyrics over once it has finished.
    pub fn startTrackLyrics(self: *OrcaRuntime, library: LibraryHandle, track_id: i64, options: LyricsOptions) !JobHandle {
        return runtime_jobs.startTrackLyrics(self, library, track_id, options);
    }

    /// A lyrics job's outcome once it has finished; `not_requested` while it
    /// runs. A Track that does not exist, or has no file and no kept LRCLIB
    /// answer, is `not_found`.
    /// Fails with `error.NotALyricsJob` for another kind of job.
    pub fn jobLyricsOutcome(self: *OrcaRuntime, job_handle: JobHandle) !LyricsOutcome {
        return runtime_jobs.jobLyricsOutcome(self, job_handle);
    }

    /// The lyrics a finished lyrics job found. Ownership moves to the caller,
    /// who frees them with `deinit`; a second call returns null.
    pub fn jobTakeLyrics(self: *OrcaRuntime, job_handle: JobHandle) !?Lyrics {
        return runtime_jobs.jobTakeLyrics(self, job_handle);
    }

    /// Fetches an Artist's photo, biography, years active and links on a job
    /// worker and keeps them in the Library: an image in the Artist's folder,
    /// else the Wikimedia Commons image MusicBrainz or Wikidata names, with
    /// its licence and credit; the lead of the Artist's Wikipedia article in
    /// `options.language`, else in English; and MusicBrainz's years and
    /// links. Info fetched for the same MusicBrainz artist ID less than 30
    /// days ago is kept without a request unless `options.force`.
    /// `options.offline` makes no request and uses only answers already
    /// cached. Needs `setClientIdentity` (`error.ClientIdentityRequired`);
    /// fails with `error.UnknownArtist` or `error.InvalidLanguage` before
    /// starting. `jobArtistInfoOutcome` reports what the job came to.
    pub fn startArtistInfoFetch(self: *OrcaRuntime, library: LibraryHandle, artist_id: i64, options: ArtistInfoOptions) !JobHandle {
        return runtime_jobs.startArtistInfoFetch(self, library, artist_id, options);
    }

    /// An artist info job's outcome once it has finished; `not_requested`
    /// while it runs. Fails with `error.NotAnArtistInfoJob` for another kind
    /// of job.
    pub fn jobArtistInfoOutcome(self: *OrcaRuntime, job_handle: JobHandle) !ArtistInfoOutcome {
        return runtime_jobs.jobArtistInfoOutcome(self, job_handle);
    }

    /// Fetches a Release's description on a job worker and keeps it in the
    /// Library: MusicBrainz names the release group, whose Wikidata item, or
    /// failing that its Wikipedia link, names the article whose lead in
    /// `options.language`, else in English, is kept. Unless `setGenreFill`
    /// turned it off, the release group's MusicBrainz genres go on the
    /// Release's Tracks with no genre from a file or an edit. Info fetched
    /// for the same release ID less than 30 days ago is kept without a
    /// request unless `options.force`. Needs `setClientIdentity`
    /// (`error.ClientIdentityRequired`); fails with `error.UnknownRelease`
    /// or `error.InvalidLanguage` before starting. `jobReleaseInfoOutcome`
    /// reports what the job came to.
    pub fn startReleaseInfoFetch(self: *OrcaRuntime, library: LibraryHandle, release_id: i64, options: ReleaseInfoOptions) !JobHandle {
        return runtime_jobs.startReleaseInfoFetch(self, library, release_id, options);
    }

    /// Fills genres from MusicBrainz, whatever `setGenreFill` says, for at
    /// most `options.limit` Releases with a MusicBrainz release ID and a
    /// Track with no genre, as a release info job that keeps no
    /// description. The job's completed units count the Releases asked
    /// about. Needs `setClientIdentity`; fails with `error.InvalidLimit`.
    pub fn startGenreFill(self: *OrcaRuntime, library: LibraryHandle, options: GenreFillOptions) !JobHandle {
        return runtime_jobs.startGenreFill(self, library, options);
    }

    /// A release info job's outcome once it has finished; `not_requested`
    /// while it runs. Fails with `error.NotAReleaseInfoJob` for another
    /// kind of job.
    pub fn jobReleaseInfoOutcome(self: *OrcaRuntime, job_handle: JobHandle) !ReleaseInfoOutcome {
        return runtime_jobs.jobReleaseInfoOutcome(self, job_handle);
    }

    /// Fingerprints every file whose recording ID came from an accepted match
    /// or an edit and sends it to AcoustID, as the user whose key the
    /// credential store holds under `org.acoustid`/`user-key`. Fails with
    /// `needs_user_key` or `invalid_user_key` without marking anything sent.
    /// Queued like `startLibraryMatching` beside a maintenance unit.
    pub fn startAcoustIdSubmission(self: *OrcaRuntime, library: LibraryHandle) !JobHandle {
        return runtime_jobs.startAcoustIdSubmission(self, library);
    }

    /// An AcoustID submission job's counters: files examined while it runs,
    /// everything once it has finished.
    pub fn jobSubmissionStats(self: *OrcaRuntime, job_handle: JobHandle) !SubmissionStats {
        return runtime_jobs.jobSubmissionStats(self, job_handle);
    }

    /// Files an AcoustID submission would send now, fingerprints permitting.
    pub fn libraryAcoustIdSubmittableCount(self: *OrcaRuntime, library: LibraryHandle) !u64 {
        return runtime_jobs.libraryAcoustIdSubmittableCount(self, library);
    }

    /// The files an AcoustID submission would send, by file id after `cursor`.
    pub fn libraryAcoustIdSubmittablePage(
        self: *OrcaRuntime,
        library: LibraryHandle,
        cursor: i64,
        limit: u32,
    ) !AcoustIdSubmittablePage {
        return runtime_jobs.libraryAcoustIdSubmittablePage(self, library, cursor, limit);
    }

    /// Cooperative cancellation for one job. Both flags are set: the registry
    /// flag is what shutdown observes, and the scanner polls the token.
    pub fn cancelJob(self: *OrcaRuntime, job_handle: JobHandle) !void {
        return runtime_jobs.cancelJob(self, job_handle);
    }

    /// Job snapshot with the worker's live counters folded in first, so a host
    /// polling progress never sees a stale count.
    pub fn jobSnapshotSynced(self: *OrcaRuntime, job_handle: JobHandle) !job.Snapshot {
        return runtime_jobs.jobSnapshotSynced(self, job_handle);
    }

    /// Scanner counters for a job, live while it runs and retained for a
    /// bounded number of finished jobs afterwards.
    pub fn jobScanStats(self: *OrcaRuntime, job_handle: JobHandle) !ScanStats {
        return runtime_jobs.jobScanStats(self, job_handle);
    }

    /// The root a reconcile job walks, or null for a job of another kind.
    pub fn jobReconcileRoot(self: *OrcaRuntime, job_handle: JobHandle) !?i64 {
        return runtime_jobs.jobReconcileRoot(self, job_handle);
    }

    /// Which file a failed tag write stopped at and why, once the job has
    /// finished; null while it runs, after it succeeded, or when it failed
    /// before reaching a file. `error.NotATagWriteJob` for a job of another
    /// kind.
    pub fn jobTagWriteFailure(self: *OrcaRuntime, job_handle: JobHandle) !?TagWriteFailure {
        return runtime_jobs.jobTagWriteFailure(self, job_handle);
    }

    /// Watches the Library's roots and reconciles what changes under them,
    /// one reconcile at a time and never beside a scan, reconcile,
    /// projection or tag write of the Library. Each root is reconciled whole once armed. Linux only: elsewhere this
    /// returns `error.WatchingUnsupported`. A Library already watched returns
    /// `error.AlreadyWatching`. The reconciles start from `pump`.
    pub fn libraryWatch(self: *OrcaRuntime, library: LibraryHandle, options: WatchOptions) !void {
        return runtime_watch.libraryWatch(self, library, options);
    }

    /// Stops watching: joins the watcher and any reconcile it started, and
    /// drops the changes still waiting.
    pub fn libraryUnwatch(self: *OrcaRuntime, library: LibraryHandle) !void {
        return runtime_watch.libraryUnwatch(self, library);
    }

    pub fn libraryWatchStatus(self: *OrcaRuntime, library: LibraryHandle) !WatchStatus {
        return runtime_watch.libraryWatchStatus(self, library);
    }

    /// Verifies the Library's recording IDs a unit at a time while no
    /// Player plays and no other job runs: the next Release every
    /// `interval_ms`, or at most twenty Tracks on no Release once none is
    /// left. Off until enabled; enabling makes a unit due at once, and
    /// disabling cancels a running one. Units start from `pump`, one per
    /// runtime, and their findings land in Health.
    pub fn libraryMaintenance(self: *OrcaRuntime, library: LibraryHandle, options: MaintenanceOptions) !void {
        return runtime_maintenance.libraryMaintenance(self, library, options);
    }

    pub fn libraryMaintenanceStatus(self: *OrcaRuntime, library: LibraryHandle) !MaintenanceStatus {
        return runtime_maintenance.libraryMaintenanceStatus(self, library);
    }

    /// Who started a job: the host, a watcher's automatic reconcile, or
    /// idle maintenance.
    pub fn jobOrigin(self: *OrcaRuntime, job_handle: JobHandle) !JobOrigin {
        return runtime_jobs.jobOrigin(self, job_handle);
    }

    /// A matching job's counters, live while it runs and retained for a
    /// bounded number of finished jobs afterwards.
    pub fn jobMatchStats(self: *OrcaRuntime, job_handle: JobHandle) !MatchStats {
        return runtime_jobs.jobMatchStats(self, job_handle);
    }

    /// The Release that holds most of a finished Match Album's files: the
    /// files of the album's Tracks when the job started, so a host can follow
    /// an album that accepting a release ID moved to a new Release id. The
    /// same id when the album kept its key. Null while the job runs, for a
    /// job that is not a release-scoped search or re-identify, and when no
    /// Release holds the files.
    pub fn jobMatchRelease(self: *OrcaRuntime, job_handle: JobHandle) !?i64 {
        return runtime_jobs.jobMatchRelease(self, job_handle);
    }

    /// Control lane. Joins every worker whose thread has finished, records the
    /// job's terminal state and publishes one lossless `job_finished` event per
    /// job. Called from the runtime pump.
    pub fn reapFinishedJobs(self: *OrcaRuntime) void {
        return runtime_jobs.reapFinishedJobs(self);
    }

    /// Everything a transport UI needs, in one lock-free read. Position comes
    /// from the packed epoch+frames atomic the engine derives from the clock
    /// Zone, never from an event stream.
    pub fn playerStatus(self: *OrcaRuntime, player: PlayerHandle) !PlayerStatus {
        return runtime_status.playerStatus(self, player);
    }

    /// Copies a bounded page of queue entries into a caller-owned buffer, in
    /// playback order, so the shuffle permutation is what a host displays.
    pub fn playerQueuePage(
        self: *OrcaRuntime,
        player: PlayerHandle,
        offset: u32,
        output: []TrackRef,
    ) !usize {
        return runtime_status.playerQueuePage(self, player, offset, output);
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
        return runtime_status.playerQueueTracks(self, player, allocator, offset, limit);
    }

    /// The Library this Player resolves its queue through, if it is bound.
    pub fn playerLibrary(self: *OrcaRuntime, player: PlayerHandle) !?LibraryHandle {
        return runtime_status.playerLibrary(self, player);
    }

    /// Linear volume applied to canonical PCM once, before fanout, so every
    /// Zone hears the same level. The control block outlives the engine, so a
    /// stop/start keeps the level the user set.
    pub fn playerSetVolume(
        self: *OrcaRuntime,
        player: PlayerHandle,
        linear: f32,
    ) !void {
        return runtime_status.playerSetVolume(self, player, linear);
    }

    pub fn playerVolume(self: *OrcaRuntime, player: PlayerHandle) !f32 {
        return runtime_status.playerVolume(self, player);
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
        return runtime_status.playerSetReplayGainMode(self, player, mode);
    }

    pub fn playerReplayGainMode(
        self: *OrcaRuntime,
        player: PlayerHandle,
    ) !audio.processing.ReplayGainMode {
        return runtime_status.playerReplayGainMode(self, player);
    }

    /// Adds `decibels` to every measured correction, before the peak cap.
    /// Clamped to ±15 dB. Takes effect as promptly as a mode change.
    pub fn playerSetReplayGainPreamp(self: *OrcaRuntime, player: PlayerHandle, decibels: f32) !void {
        return runtime_status.playerSetReplayGainPreamp(self, player, decibels);
    }

    /// What an entry with no usable measurement plays at while correction is
    /// on. The preamp does not apply to it.
    pub fn playerSetReplayGainFallback(
        self: *OrcaRuntime,
        player: PlayerHandle,
        fallback: audio.processing.UntaggedFallback,
    ) !void {
        return runtime_status.playerSetReplayGainFallback(self, player, fallback);
    }

    /// Whether corrections are capped at `1 / peak`, so a boost never drives
    /// an entry's measured peak past full scale. On by default.
    pub fn playerSetPeakProtection(self: *OrcaRuntime, player: PlayerHandle, enabled: bool) !void {
        return runtime_status.playerSetPeakProtection(self, player, enabled);
    }

    /// Mode, preamp, untagged fallback and peak protection as one value.
    pub fn playerReplayGainSettings(
        self: *OrcaRuntime,
        player: PlayerHandle,
    ) !audio.processing.ReplayGainSettings {
        return runtime_status.playerReplayGainSettings(self, player);
    }

    /// Stops the transport when the entry being heard ends, then clears
    /// itself. The following entry is not started; a later play starts it.
    /// Arming during a gapless transition that has already begun decoding the
    /// following entry re-opens the audible one, with a short gap.
    pub fn playerSetStopAfterCurrent(self: *OrcaRuntime, player: PlayerHandle, enabled: bool) !void {
        return runtime_status.playerSetStopAfterCurrent(self, player, enabled);
    }

    pub fn playerStopAfterCurrent(self: *OrcaRuntime, player: PlayerHandle) !bool {
        return runtime_status.playerStopAfterCurrent(self, player);
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
        return runtime_status.playerEffectiveGain(self, player);
    }

    /// Turns the ten-band equalizer on with `equalizer`, or off with null. The
    /// engine is stopped while the settings are written, so it never reads a
    /// half-written equalizer; it rebuilds its filters on its next pass.
    /// Turning it on turns the parametric equalizer off.
    pub fn playerSetEqualizer(
        self: *OrcaRuntime,
        player: PlayerHandle,
        equalizer: ?audio.dsp.Equalizer,
    ) !void {
        return runtime_status.playerSetEqualizer(self, player, equalizer);
    }

    pub fn playerEqualizer(self: *OrcaRuntime, player: PlayerHandle) !?audio.dsp.Equalizer {
        return runtime_status.playerEqualizer(self, player);
    }

    /// Turns the parametric equalizer on with `equalizer`, or off with null,
    /// under the same stop as `playerSetEqualizer`. Turning it on turns the
    /// ten-band equalizer off, and turning that on turns this off; null turns
    /// off only this one. Out-of-range or non-finite values are refused and
    /// the last setting kept.
    pub fn playerSetParametricEqualizer(
        self: *OrcaRuntime,
        player: PlayerHandle,
        equalizer: ?audio.dsp.ParametricEqualizer,
    ) !void {
        return runtime_status.playerSetParametricEqualizer(self, player, equalizer);
    }

    pub fn playerParametricEqualizer(self: *OrcaRuntime, player: PlayerHandle) !?audio.dsp.ParametricEqualizer {
        return runtime_status.playerParametricEqualizer(self, player);
    }

    /// Turns stereo crossfeed on with an `amount` in [0, 1], or off with null.
    /// Applies to two-channel audio only; other layouts pass through.
    pub fn playerSetCrossfeed(
        self: *OrcaRuntime,
        player: PlayerHandle,
        amount: ?f32,
    ) !void {
        return runtime_status.playerSetCrossfeed(self, player, amount);
    }

    pub fn playerCrossfeed(self: *OrcaRuntime, player: PlayerHandle) !?f32 {
        return runtime_status.playerCrossfeed(self, player);
    }

    /// What the audio being heard passes through on its way to the output,
    /// and whether that path could be bit-perfect.
    ///
    /// The source format, codec and ReplayGain figure are the audible entry's,
    /// and the volume is the gain being applied, not the target it ramps
    /// toward. The engine is stopped while they are read, because the entry
    /// ring, the gain ramp and the Zone's open format are engine-thread state.
    pub fn playerSignalPath(self: *OrcaRuntime, player: PlayerHandle) !audio.dsp.SignalPath {
        return runtime_status.playerSignalPath(self, player);
    }

    /// Seek in wall-clock milliseconds. The frame conversion needs the loaded
    /// source's rate, which is why a Player with nothing loaded is refused
    /// rather than silently seeking to frame zero.
    pub fn playerSeekMs(self: *OrcaRuntime, player: PlayerHandle, ms: u64) !u32 {
        return runtime_status.playerSeekMs(self, player, ms);
    }

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
        return runtime_zones.zoneOpenOutput(self, zone, device_id, policy, latency_frames);
    }

    /// One call for a frontend with a single output: create a Zone, attach it
    /// to the Player, and open it. Device id 0 delegates to the server default.
    /// A single-output host never has to know Zones exist.
    pub fn playerOpenDefaultOutput(
        self: *OrcaRuntime,
        player: PlayerHandle,
        device_id: u64,
    ) !ZoneHandle {
        return runtime_zones.playerOpenDefaultOutput(self, player, device_id);
    }

    pub fn submit(self: *OrcaRuntime, action: control.Action) !control.RequestId {
        try requireRunning(self);
        const request_id = try self.commands.submit(action);
        self.host_signal.raise();
        return request_id;
    }

    /// Installs, or with null removes, what liborca calls when the host's
    /// loop should pump: after `submit`, and when a worker publishes a change
    /// the host did not make. Refused once any worker thread exists, because
    /// those threads read the waker without a lock; call it right after
    /// `init`. The waker is never called after `deinit` returns.
    pub fn setWaker(self: *OrcaRuntime, waker: ?HostWaker) error{ RuntimeNotRunning, WorkersRunning }!void {
        try requireRunning(self);
        if (self.work_registry.count() != 0) return error.WorkersRunning;
        self.host_signal.waker = waker;
    }

    /// How long the host may wait for the waker before it pumps again: 0 to
    /// pump now, null to wait for the waker alone. Read after draining
    /// events and immediately before waiting. A bound Player that is playing
    /// needs a listen sample at least every second, a running job's
    /// progress is worth reading every `job_progress_interval_ms`, and an
    /// enabled maintenance schedule needs its next unit started.
    pub fn nextPumpTimeoutMs(self: *OrcaRuntime) ?u64 {
        if (self.state.load(.acquire) != .running) return null;
        if (self.host_signal.isPending() or self.commands.count() != 0 or
            self.events.count() != 0 or self.telemetry.count() != 0) return 0;
        var due: ?u64 = runtime_listens.listenSampleDueMs(self);
        for ([_]?u64{
            runtime_jobs.jobPumpDueMs(self),
            runtime_jobs.queuedJobPumpDueMs(self),
            runtime_watch.watchPumpDueMs(self),
            runtime_maintenance.maintenancePumpDueMs(self),
        }) |candidate| {
            const value = candidate orelse continue;
            due = if (due) |current| @min(current, value) else value;
        }
        return due;
    }

    /// One turn of the host's loop: executes the commands already submitted,
    /// at most the command queue's capacity so a host that keeps submitting
    /// cannot trap its loop here, joins finished job workers, starts a host
    /// job that waited for a maintenance unit, takes what watchers reported
    /// and starts their reconciles, then starts a due maintenance unit.
    pub fn pump(self: *OrcaRuntime) void {
        var executed: usize = 0;
        while (executed < control.CommandQueue.capacity and self.processNextCommand()) executed += 1;
        self.reapFinishedJobs();
        runtime_jobs.startQueuedHostJob(self);
        runtime_watch.pumpWatchers(self);
        runtime_maintenance.pumpMaintenance(self);
    }

    /// Executes at most one command on the runtime's serialized logical control
    /// lane. Returns false when there is no work or event backpressure applies.
    /// Each call also samples Players for queue history and bound Players
    /// for listens, at most once per `listen_sample_interval_ms`.
    pub fn processNextCommand(self: *OrcaRuntime) bool {
        if (self.state.load(.acquire) != .running) return false;
        self.host_signal.clear();
        runtime_listens.sampleListens(self);
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
        try requireRunning(self);
        try self.telemetry.publish(telemetry);
    }

    pub fn pollTelemetry(self: *OrcaRuntime) ?control.Telemetry {
        return self.telemetry.poll();
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

    fn joinWorkersBeforeDestroy(self: *OrcaRuntime) void {
        runtime_jobs.cancelJobWorkers(self);
        self.work_registry.requestCancellation();
        runtime_listens.wakeListenWorkers(self);
        self.work_registry.drain();
        self.releaseDrainedArtworkLoaders();
        runtime_listens.releaseDrainedListenWorkers(self);
        runtime_watch.releaseDrainedWatchers(self);
    }

    fn closeLibraryDatabase(self: *OrcaRuntime, library: *LibraryObject) void {
        if (library.database) |library_database| {
            library_database.close();
            self.allocator.destroy(library_database);
            library.database = null;
        }
    }
};

pub fn outputFactory(self: *OrcaRuntime) ?audio.output.Factory {
    if (self.output_factory_override) |factory| return factory;
    if (!self.output_host_ready) {
        self.output_host.init(self.allocator);
        self.output_host_ready = true;
    }
    return self.output_host.factory();
}

pub fn libraryDatabase(
    self: *OrcaRuntime,
    library: LibraryHandle,
) !*database.LibraryDatabase {
    try requireRunning(self);
    return (try self.libraries.get(library)).database orelse error.LibraryHasNoDatabase;
}

/// Destroying a Player or a Zone carries the same requirement as shutdown:
/// no worker may still be holding the object when it is freed. Work is not
/// yet scoped per object, so a destroy conservatively cancels and joins
/// every registered worker. Narrowing this to the workers that actually
/// hold the destroyed object is a later refinement, never a relaxation.
/// Identifies a Player to the work registry. Generation is part of the
/// tag, so a registration left by a destroyed Player can never match the
/// later occupant of the same slot.
pub fn playerOwnerTag(player: PlayerHandle) work.Owner {
    return .{ .kind = .player, .index = player.index, .generation = player.generation };
}

pub fn libraryOwnerTag(library: LibraryHandle) work.Owner {
    return .{ .kind = .library, .index = library.index, .generation = library.generation };
}

pub fn requireRunning(self: *const OrcaRuntime) error{RuntimeNotRunning}!void {
    if (self.state.load(.acquire) != .running) return error.RuntimeNotRunning;
}
