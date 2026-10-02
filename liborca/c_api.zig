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
        error.LibraryHasNoDatabase,
        error.ZoneOwnedByEngine,
        error.InvalidJobTransition,
        error.JobAlreadyFinished,
        error.WorkersRunning,
        => .invalid_state,
        error.AlreadyWatching => .invalid_state,
        error.TrackHasNoPlayableFile, error.TrackFileMissing, error.UnknownRoot => .not_found,
        error.PlaybackQueueFull, error.LibraryJobRunning, error.LibraryScanRunning, error.MutationInProgress => .busy,
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
