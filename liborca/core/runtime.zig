const std = @import("std");
const analysis_service = @import("../analysis/service.zig");
const audio = @import("../audio/root.zig");
const codec = @import("../codec/root.zig");
const control = @import("control.zig");
const database = @import("../database/root.zig");
const handle = @import("handle.zig");
const library_pass = @import("../library/root.zig");
const job = @import("job.zig");
const metadata = @import("../metadata/root.zig");
const object = @import("object.zig");
const storage = @import("../storage/root.zig");
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

pub const State = enum(u8) {
    running,
    shutting_down,
    stopped,
};

const RuntimeObject = struct {};
const LibraryObject = struct {
    database: ?*database.LibraryDatabase = null,
};
const PlayerObject = struct {
    player: *audio.player.Player,
    /// Player-scope volume. Lives beside the Player rather than inside the
    /// engine so the level survives an engine that is stopped and respawned.
    gain: *audio.processing.Gain,
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
        .title, .artist, .album, .album_artist, .date => {},
    }
}

/// One file's measurement from `libraryAnalyzeFile`.
pub const FileAnalysis = analysis_service.Analysis;

/// The Library's database, for liborca's own C ABI and tests. Clients use the
/// runtime's methods; the database is not part of the API.
pub fn databaseOf(runtime: *OrcaRuntime, library: LibraryHandle) !*database.LibraryDatabase {
    return runtime.libraryDatabase(library);
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

/// Everything a job worker needs that is not the Library or the kind. One
/// struct rather than a widening parameter list, because every kind takes a
/// bounded batch size and each takes at most one thing besides.
const WorkerRequest = struct {
    root_id: ?i64 = null,
    batch_size: usize = 256,
    force: bool = false,
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
    /// The worker's own `std.Io`. The ABI's belongs to the calling thread and
    /// is never borrowed across a thread boundary.
    threaded: std.Io.Threaded = .init_single_threaded,
    /// What the scanner polls. Set by `cancelJob` and by every runtime path
    /// that drains workers, because the registry flag alone cannot reach
    /// inside a filesystem walk.
    token: library_pass.CancellationToken = .{},
    /// Files the *current* root's walk has reached, written by the scanner.
    progress: std.atomic.Value(u64) = .init(0),
    stats: LiveScanStats = .{},
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

    fn noteProjection(self: *JobWorker, result: library_pass.projection.Result) void {
        _ = self.stats.folders_visited.fetchAdd(result.folders_visited, .acq_rel);
        _ = self.stats.files_projected.fetchAdd(result.files_projected, .acq_rel);
        _ = self.stats.tracks_written.fetchAdd(result.tracks_written, .acq_rel);
        _ = self.stats.releases_written.fetchAdd(result.releases_written, .acq_rel);
    }

    fn filesProcessed(self: *const JobWorker) u64 {
        return self.stats.files_seen.load(.acquire) + self.progress.load(.acquire);
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
fn readEmbeddedArtwork(
    allocator: std.mem.Allocator,
    io: std.Io,
    uri: []const u8,
) !?metadata.EmbeddedImage {
    var local = storage.LocalFileSource.open(io, uri) catch |err| switch (err) {
        error.FileNotFound, error.BadPathName, error.AccessDenied, error.IsDir => return null,
        else => return err,
    };
    defer local.close();
    return metadata.artwork.read(allocator, local.readable());
}

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
        for (self.players.slots.items) |*slot| {
            if (slot.value) |*player| self.stopEngine(player);
        }
        self.cancelJobWorkers();
        self.work_registry.requestCancellation();
        self.work_registry.drain();
        self.finalizeDrainedJobWorkers();
        self.freeAllJobWorkers();
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
            if (slot.value) |*library| self.closeLibraryDatabase(library);
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
        var removed = try self.libraries.remove(library);
        self.closeLibraryDatabase(&removed);
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
    pub fn libraryTrackArtwork(
        self: *OrcaRuntime,
        library: LibraryHandle,
        io: std.Io,
        track_id: i64,
    ) !?metadata.EmbeddedImage {
        const tracks = &(try self.libraryDatabase(library)).tracks;
        const resolved = (try tracks.playableLocation(self.allocator, track_id)) orelse
            return null;
        defer resolved.deinit();
        return readEmbeddedArtwork(self.allocator, io, resolved.uri);
    }

    /// How many of a Release's Tracks are opened before it is reported as
    /// having no usable cover.
    ///
    /// Only files the last scan observed artwork in are candidates at all, so
    /// this bound is reached only when a Release's leading tracks each declare
    /// a cover that no longer reads — a re-tagged file, a rejected image. Eight
    /// is generous for that and still bounded; without a bound, one Release
    /// with a hundred broken tracks would open a hundred files to answer "no".
    pub const max_release_artwork_candidates: usize = 8;

    /// The cover image for a Release, or null when none of its files has one.
    ///
    /// **A Release's artwork is its first track's, in listening order.** Real
    /// tag data disagrees within an album — different sizes, different crops,
    /// per-track covers on compilations — so the rule has to pick, and the
    /// three properties that matter are that it be *stable* across runs,
    /// *cheap*, and *the one a person would expect*. Ordering by disc, track
    /// number and then id is the unique order `tracks_position` already
    /// enforces, so the same Release yields the same cover every time; it costs
    /// one indexed query plus one file open; and the front cover on track one
    /// is the album cover in every collection anyone actually has.
    ///
    /// The alternatives were rejected for failing one of those: a majority vote
    /// would have to read every file in the Release, and "the largest image"
    /// would too, and both change their answer when one track is re-tagged.
    pub fn libraryReleaseArtwork(
        self: *OrcaRuntime,
        library: LibraryHandle,
        io: std.Io,
        release_id: i64,
    ) !?metadata.EmbeddedImage {
        const tracks = &(try self.libraryDatabase(library)).tracks;
        var candidates: [max_release_artwork_candidates]i64 = undefined;
        const count = try tracks.artworkCandidatesInto(release_id, &candidates);
        for (candidates[0..count]) |track_id| {
            // A candidate whose cover will not read is skipped rather than
            // fatal: the next track's cover is the same album's.
            const image = self.libraryTrackArtwork(library, io, track_id) catch continue;
            if (image) |present| return present;
        }
        return null;
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
        return self.players.insert(.{ .player = player, .queue = queue, .gain = gain });
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
        self.stopEngine(try self.players.get(player));
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
        const opener = try track_source.TrackSourceOpener.create(
            self.allocator,
            io,
            library,
            library_database,
        );
        errdefer opener.destroy();

        const object_value = try self.players.get(player);
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
            .player_processor = object_state.gain.processor(),
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

    pub fn libraryRemoveRoot(
        self: *OrcaRuntime,
        library: LibraryHandle,
        root_id: i64,
    ) !void {
        try self.requireRunning();
        try (try self.libraryDatabase(library)).library_roots.remove(root_id);
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
    ) !void {
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
            return worker.stats.read(worker.progress.load(.acquire));
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
        else if (worker.stats.cancelled.load(.acquire))
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
            self.allocator.destroy(worker);
            to_drop -= 1;
        }
    }

    fn freeAllJobWorkers(self: *OrcaRuntime) void {
        for (self.job_workers.items) |worker| self.allocator.destroy(worker);
        self.job_workers.deinit(self.allocator);
        self.job_workers = .empty;
    }

    // ------------------------------------------------------- player status

    /// Everything a transport UI needs, in one lock-free read. Position comes
    /// from the packed epoch+frames atomic the engine derives from the clock
    /// Zone, never from an event stream.
    pub fn playerStatus(self: *OrcaRuntime, player: PlayerHandle) !PlayerStatus {
        try self.requireRunning();
        const object_value = try self.players.get(player);
        const snapshot = object_value.player.snapshot();
        const queue_snapshot = object_value.queue.snapshot();
        const rate = object_value.player.published_sample_rate.load(.acquire);
        const frames = object_value.player.published_frame_count.load(.acquire);
        const current = object_value.queue.current();
        return .{
            .transport = snapshot.state,
            .repeat = queue_snapshot.repeat,
            .shuffle = queue_snapshot.shuffle,
            .epoch = snapshot.epoch,
            .position_ms = if (rate == 0) 0 else snapshot.position_frames * 1000 / rate,
            .duration_ms = if (rate == 0) 0 else frames * 1000 / rate,
            .track_id = if (current) |ref| ref.track_id else null,
            .queue_length = queue_snapshot.entries,
            .queue_index = queue_snapshot.cursor,
            .volume = object_value.gain.linear.load(.acquire),
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
    pub fn processNextCommand(self: *OrcaRuntime) bool {
        if (self.state.load(.acquire) != .running or !self.events.hasCapacity()) return false;
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
    fn playerOwnerTag(player: PlayerHandle) u64 {
        return (@as(u64, player.index) << 32) | @as(u64, player.generation);
    }

    fn joinWorkersBeforeDestroy(self: *OrcaRuntime) void {
        self.cancelJobWorkers();
        self.work_registry.requestCancellation();
        self.work_registry.drain();
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
    try runtime.libraryEditTracks(library, &.{track_id}, &.{
        .{ .field = .artist, .value = "Edited Artist" },
        .{ .field = .album, .value = "Edited Album" },
    });
    var edited = try runtime.libraryTrackQuery(library, "", .{ .limit = 4 });
    try std.testing.expectEqual(@as(usize, 1), edited.items.len);
    try std.testing.expectEqualStrings("Edited Artist", edited.items[0].artist);
    try std.testing.expectEqualStrings("Edited Album", edited.items[0].album);
    const edited_id = edited.items[0].id;
    edited.deinit();

    var values = try runtime.libraryTrackEdits(library, edited_id);
    try std.testing.expectEqual(@as(usize, 2), values.items.len);
    try std.testing.expect(values.items[0].locked);
    values.deinit();

    try runtime.libraryEditTracks(library, &.{edited_id}, &.{
        .{ .field = .artist, .value = null },
        .{ .field = .album, .value = null },
    });
    var reverted = try runtime.libraryTrackQuery(library, "", .{ .limit = 4 });
    defer reverted.deinit();
    try std.testing.expectEqual(@as(usize, 1), reverted.items.len);
    try std.testing.expectEqualStrings("File Artist", reverted.items[0].artist);
    try std.testing.expectEqual(@as(u64, 1), try library_database.artists.count());
}
