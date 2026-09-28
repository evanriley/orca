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
const audio = @import("audio/root.zig");
const control = @import("core/control.zig");
const core = @import("core/root.zig");
const database = @import("database/root.zig");
const job = @import("core/job.zig");

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

pub const PlayerSnapshot = extern struct {
    state: u8,
    _reserved: [7]u8 = @splat(0),
    generation: u64,
    position_frames: u64,
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
    _reserved: [4]u8 = @splat(0),
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
};

/// The POD form of `database.TrackQuery`. Negative ids mean "no filter",
/// because a filter is either present or absent and a nullable pointer per
/// field would be worse for every caller.
pub const TrackQueryView = extern struct {
    artist_id: i64,
    release_id: i64,
    sort: u8,
    descending: u8,
    _reserved: [2]u8 = @splat(0),
    limit: u32,
    offset: u32,
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
    _reserved: [3]u8 = @splat(0),
    title: StringView,
    album_artist: StringView,
    release_date: StringView,
};

pub const ReleaseCallback = *const fn (?*anyopaque, *const ReleaseView) callconv(.c) void;

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
    _reserved: [4]u8 = @splat(0),
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

/// A named `extern union` rather than opaque a/b/c fields: ABI-stable, it
/// imports cleanly into Swift, and it keeps the header self-documenting.
pub const EventPayload = extern union {
    command_completed: CommandCompletedEvent,
    job_progress: JobProgressEvent,
    job_finished: JobFinishedEvent,
    player_position: PlayerPositionEvent,
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

    fn io(self: *RuntimeBox) std.Io {
        return self.threaded.io();
    }

    /// True when the caller is violating the single-thread contract. Release
    /// builds never report a violation: the check exists to catch the mistake
    /// during development, not to make the boundary thread-safe.
    fn foreignThread(self: *const RuntimeBox) bool {
        if (builtin.mode != .Debug) return false;
        return std.Thread.getCurrentId() != self.owner_thread;
    }
};

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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const path_pointer = path orelse return .invalid_argument;
    const destination = output orelse return .invalid_argument;
    const library = box.runtime.openLibrary(box.io(), std.mem.span(path_pointer)) catch |err|
        return mapError(err);
    destination.* = exportLibraryHandle(library);
    return .ok;
}

pub export fn orca_library_close(runtime: ?*Runtime, library: Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    box.runtime.destroyLibrary(importLibrary(library)) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_library_track_count(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*u64,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = output orelse return .invalid_argument;
    destination.* = box.runtime.libraryTrackCount(importLibrary(library)) catch |err|
        return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const visit = callback orelse return .invalid_argument;
    if (limit == 0 or limit > max_page) return .invalid_argument;
    const query = if (query_pointer) |pointer|
        pointer[0..query_length]
    else if (query_length == 0)
        ""
    else
        return .invalid_argument;
    var page = box.runtime.libraryTrackPage(
        importLibrary(library),
        query,
        limit,
        offset,
    ) catch |err| return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = output orelse return .invalid_argument;
    destination.* = box.runtime.libraryHealthIssueCount(importLibrary(library)) catch |err|
        return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const visit = callback orelse return .invalid_argument;
    if (limit == 0 or limit > max_page) return .invalid_argument;
    var page = box.runtime.libraryHealthIssuePage(
        importLibrary(library),
        limit,
        offset,
    ) catch |err| return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = output orelse return .invalid_argument;
    destination.* = box.runtime.libraryArtistCount(importLibrary(library)) catch |err|
        return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const visit = callback orelse return .invalid_argument;
    if (limit == 0 or limit > max_page) return .invalid_argument;
    var page = box.runtime.libraryArtistPage(importLibrary(library), .{
        .limit = limit,
        .offset = offset,
    }) catch |err|
        return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const visit = callback orelse return .invalid_argument;
    const found = box.runtime.libraryArtist(importLibrary(library), artist_id) catch |err|
        return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = output orelse return .invalid_argument;
    destination.* = box.runtime.libraryReleaseCount(importLibrary(library)) catch |err|
        return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const visit = callback orelse return .invalid_argument;
    if (limit == 0 or limit > max_page) return .invalid_argument;
    var page = box.runtime.libraryReleasePage(importLibrary(library), .{
        .album_artist_id = optionalId(album_artist_id),
        .limit = limit,
        .offset = offset,
    }) catch |err| return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const visit = callback orelse return .invalid_argument;
    const found = box.runtime.libraryRelease(importLibrary(library), release_id) catch |err|
        return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const visit = callback orelse return .invalid_argument;
    const request = importTrackQuery(query orelse return .invalid_argument) orelse
        return .invalid_argument;
    var page = box.runtime.libraryTrackQuery(importLibrary(library), "", request) catch |err|
        return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = output orelse return .invalid_argument;
    const request = importTrackQuery(query orelse return .invalid_argument) orelse
        return .invalid_argument;
    destination.* = box.runtime.libraryTrackMatchCount(importLibrary(library), request) catch |err|
        return mapError(err);
    return .ok;
}

pub export fn orca_player_create(
    runtime: ?*Runtime,
    output: ?*Handle,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = output orelse return .invalid_argument;
    const player = box.runtime.createPlayer() catch |err| return mapError(err);
    destination.* = exportHandle(player);
    return .ok;
}

pub export fn orca_player_destroy(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    box.runtime.destroyPlayer(importPlayer(player)) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_player_play(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    box.runtime.playPlayer(importPlayer(player)) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_player_pause(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    box.runtime.pausePlayer(importPlayer(player)) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_player_stop(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    box.runtime.stopPlayer(importPlayer(player)) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_player_seek(
    runtime: ?*Runtime,
    player: Handle,
    frame: u64,
    generation: ?*u64,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const next = box.runtime.seekPlayer(importPlayer(player), frame) catch |err|
        return mapError(err);
    if (generation) |output| output.* = next;
    return .ok;
}

pub export fn orca_player_snapshot(
    runtime: ?*Runtime,
    player: Handle,
    output: ?*PlayerSnapshot,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = output orelse return .invalid_argument;
    const snapshot = box.runtime.playerSnapshot(importPlayer(player)) catch |err|
        return mapError(err);
    destination.* = .{
        .state = @intFromEnum(snapshot.state),
        .generation = snapshot.epoch,
        .position_frames = snapshot.position_frames,
    };
    return .ok;
}

// ------------------------------------------------------------------ runtime

pub export fn orca_runtime_pump(runtime: ?*Runtime) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    // Bounded: one pump drains at most the command queue's capacity, so a host
    // that keeps submitting can never trap its own event loop in here.
    var executed: usize = 0;
    while (executed < 256 and box.runtime.processNextCommand()) executed += 1;
    box.runtime.reapFinishedJobs();
    return .ok;
}

pub export fn orca_runtime_poll_event(
    runtime: ?*Runtime,
    event: ?*Event,
    remaining: ?*u32,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = event orelse return .invalid_argument;
    destination.* = .{ .kind = @intFromEnum(EventKind.none), .payload = undefined };
    // Lossless completions first, coalesced hints second: a host must never
    // learn that a job finished before it learns the command that started it
    // succeeded.
    if (box.runtime.pollEvent()) |completion| {
        destination.* = exportCompletion(completion);
    } else if (box.runtime.pollTelemetry()) |telemetry| {
        destination.* = exportTelemetry(telemetry);
    }
    if (remaining) |output| output.* = @intCast(
        box.runtime.events.count() + box.runtime.telemetry.count(),
    );
    return .ok;
}

// ------------------------------------------------------------------ library

pub export fn orca_library_add_root(
    runtime: ?*Runtime,
    library: Handle,
    path: ?[*:0]const u8,
    root_id: ?*i64,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const path_pointer = path orelse return .invalid_argument;
    const binding = box.runtime.libraryAddRoot(
        importLibrary(library),
        box.io(),
        std.mem.span(path_pointer),
    ) catch |err| return mapError(err);
    if (root_id) |output| output.* = binding.root_id;
    return .ok;
}

pub export fn orca_library_remove_root(
    runtime: ?*Runtime,
    library: Handle,
    root_id: i64,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    _ = box.runtime.libraryRemoveRoot(importLibrary(library), root_id) catch |err|
        return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const visit = callback orelse return .invalid_argument;
    if (limit == 0 or limit > max_page) return .invalid_argument;
    var page = box.runtime.libraryRootPage(importLibrary(library), limit, offset) catch |err|
        return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = job_output orelse return .invalid_argument;
    var request: core.runtime.ScanRequest = .{
        .root_id = if (root_id < 0) null else root_id,
    };
    if (options) |value| {
        if (value.batch_size != 0) request.batch_size = value.batch_size;
    }
    const started = box.runtime.startLibraryScan(importLibrary(library), request) catch |err|
        return mapError(err);
    destination.* = exportJobHandle(started);
    return .ok;
}

pub export fn orca_library_start_projection(
    runtime: ?*Runtime,
    library: Handle,
    job_output: ?*Handle,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = job_output orelse return .invalid_argument;
    const started = box.runtime.startLibraryProjection(importLibrary(library)) catch |err|
        return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = job_output orelse return .invalid_argument;
    var request: core.runtime.BackfillRequest = .{};
    if (options) |value| {
        if (value.batch_size != 0) request.batch_size = value.batch_size;
        request.force = value.force != 0;
    }
    const started = box.runtime.startLibraryPropertyBackfill(
        importLibrary(library),
        request,
    ) catch |err| return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = job_output orelse return .invalid_argument;
    var request: core.runtime.AnalysisRequest = .{};
    if (options) |value| {
        if (value.batch_size != 0) request.batch_size = value.batch_size;
    }
    const started = box.runtime.startLibraryAnalysis(
        importLibrary(library),
        request,
    ) catch |err| return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = job_output orelse return .invalid_argument;
    var request: core.runtime.DuplicateScanRequest = .{};
    if (options) |value| {
        if (value.batch_size != 0) request.batch_size = value.batch_size;
    }
    const started = box.runtime.startLibraryDuplicateScan(
        importLibrary(library),
        request,
    ) catch |err| return mapError(err);
    destination.* = exportJobHandle(started);
    return .ok;
}

pub export fn orca_job_cancel(runtime: ?*Runtime, job_handle: Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    box.runtime.cancelJob(importJob(job_handle)) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_job_snapshot_get(
    runtime: ?*Runtime,
    job_handle: Handle,
    output: ?*JobSnapshot,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = output orelse return .invalid_argument;
    const snapshot = box.runtime.jobSnapshotSynced(importJob(job_handle)) catch |err|
        return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = output orelse return .invalid_argument;
    const stats = box.runtime.jobScanStats(importJob(job_handle)) catch |err|
        return mapError(err);
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

// ------------------------------------------------------------------- player

pub export fn orca_player_set_library(
    runtime: ?*Runtime,
    player: Handle,
    library: Handle,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    box.runtime.playerBindLibrary(
        importPlayer(player),
        importLibrary(library),
        box.io(),
    ) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_player_play_track(
    runtime: ?*Runtime,
    player: Handle,
    track_id: i64,
    request_id: ?*u64,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const player_handle = importPlayer(player);
    const library = (box.runtime.playerLibrary(player_handle) catch |err|
        return mapError(err)) orelse return .invalid_state;
    const submitted = box.runtime.submit(.{ .play_track = .{
        .player = player_handle,
        .library = library,
        .track_id = track_id,
    } }) catch |err| return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const player_handle = importPlayer(player);
    const library = (box.runtime.playerLibrary(player_handle) catch |err|
        return mapError(err)) orelse return .invalid_state;
    const list = trackIdSlice(ids, count) orelse return .invalid_argument;
    box.runtime.playerPlayTracksBound(player_handle, library, list, start) catch |err|
        return mapError(err);
    return .ok;
}

pub export fn orca_player_enqueue_tracks(
    runtime: ?*Runtime,
    player: Handle,
    ids: ?[*]const i64,
    count: usize,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const player_handle = importPlayer(player);
    const library = (box.runtime.playerLibrary(player_handle) catch |err|
        return mapError(err)) orelse return .invalid_state;
    const list = trackIdSlice(ids, count) orelse return .invalid_argument;
    box.runtime.playerEnqueueTracksBound(player_handle, library, list) catch |err|
        return mapError(err);
    return .ok;
}

pub export fn orca_player_next(
    runtime: ?*Runtime,
    player: Handle,
    moved: ?*u8,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const advanced = box.runtime.playerNext(importPlayer(player)) catch |err|
        return mapError(err);
    if (moved) |output| output.* = @intFromBool(advanced);
    return .ok;
}

pub export fn orca_player_previous(
    runtime: ?*Runtime,
    player: Handle,
    moved: ?*u8,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const advanced = box.runtime.playerPrevious(importPlayer(player)) catch |err|
        return mapError(err);
    if (moved) |output| output.* = @intFromBool(advanced);
    return .ok;
}

pub export fn orca_player_clear_queue(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    box.runtime.playerClearQueue(importPlayer(player)) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_player_set_repeat(
    runtime: ?*Runtime,
    player: Handle,
    mode: u8,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    if (mode > 2) return .invalid_argument;
    box.runtime.playerSetRepeat(
        importPlayer(player),
        @enumFromInt(mode),
    ) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_player_set_shuffle(
    runtime: ?*Runtime,
    player: Handle,
    enabled: u8,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    box.runtime.playerSetShuffle(importPlayer(player), enabled != 0) catch |err|
        return mapError(err);
    return .ok;
}

pub export fn orca_player_set_volume(
    runtime: ?*Runtime,
    player: Handle,
    linear: f32,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    box.runtime.playerSetVolume(importPlayer(player), linear) catch |err|
        return mapError(err);
    return .ok;
}

pub export fn orca_player_volume(
    runtime: ?*Runtime,
    player: Handle,
    output: ?*f32,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = output orelse return .invalid_argument;
    destination.* = box.runtime.playerVolume(importPlayer(player)) catch |err|
        return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const resolved: audio.processing.ReplayGainMode = switch (mode) {
        0 => .off,
        1 => .track,
        else => return .invalid_argument,
    };
    box.runtime.playerSetReplayGainMode(importPlayer(player), resolved) catch |err|
        return mapError(err);
    return .ok;
}

pub export fn orca_player_replay_gain_mode(
    runtime: ?*Runtime,
    player: Handle,
    output: ?*u8,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = output orelse return .invalid_argument;
    const mode = box.runtime.playerReplayGainMode(importPlayer(player)) catch |err|
        return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = output orelse return .invalid_argument;
    destination.* = box.runtime.playerEffectiveGain(importPlayer(player)) catch |err|
        return mapError(err);
    return .ok;
}

pub export fn orca_player_seek_ms(
    runtime: ?*Runtime,
    player: Handle,
    milliseconds: u64,
    epoch: ?*u64,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const next = box.runtime.playerSeekMs(importPlayer(player), milliseconds) catch |err|
        return mapError(err);
    if (epoch) |output| output.* = next;
    return .ok;
}

pub export fn orca_player_status_get(
    runtime: ?*Runtime,
    player: Handle,
    output: ?*PlayerStatus,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = output orelse return .invalid_argument;
    const status = box.runtime.playerStatus(importPlayer(player)) catch |err|
        return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const visit = callback orelse return .invalid_argument;
    const player_handle = importPlayer(player);
    const current = (box.runtime.playerNowPlaying(player_handle) catch |err|
        return mapError(err)) orelse return .ok;
    const summary = (box.runtime.libraryTrackSummary(
        current.library,
        current.track_id,
    ) catch |err| return mapError(err)) orelse return .ok;
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const visit = callback orelse return .invalid_argument;
    if (limit == 0 or limit > max_page) return .invalid_argument;
    const player_handle = importPlayer(player);
    const status = box.runtime.playerStatus(player_handle) catch |err| return mapError(err);
    var entries: [max_page]core.runtime.TrackRef = undefined;
    const count = box.runtime.playerQueuePage(
        player_handle,
        offset,
        entries[0..limit],
    ) catch |err| return mapError(err);
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

// ----------------------------------------------------------- devices, zones

pub export fn orca_enumerate_output_devices(
    runtime: ?*Runtime,
    context: ?*anyopaque,
    callback: ?DeviceCallback,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const visit = callback orelse return .invalid_argument;
    var devices: [max_devices]audio.backend.Device = undefined;
    const count = box.runtime.enumerateOutputDevices(&devices) catch |err|
        return mapError(err);
    for (devices[0..count]) |*device| {
        const view: DeviceView = .{ .id = device.id, .name = stringView(device.nameSlice()) };
        visit(context, &view);
    }
    return .ok;
}

pub export fn orca_zone_create(runtime: ?*Runtime, output: ?*Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = output orelse return .invalid_argument;
    const zone = box.runtime.createZone() catch |err| return mapError(err);
    destination.* = exportZoneHandle(zone);
    return .ok;
}

pub export fn orca_zone_destroy(runtime: ?*Runtime, zone: Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    box.runtime.destroyZone(importZone(zone)) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_zone_attach_player(
    runtime: ?*Runtime,
    zone: Handle,
    player: Handle,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    box.runtime.attachZone(importZone(zone), importPlayer(player)) catch |err|
        return mapError(err);
    return .ok;
}

pub export fn orca_zone_detach(runtime: ?*Runtime, zone: Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    box.runtime.detachZone(importZone(zone)) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_zone_open_output(
    runtime: ?*Runtime,
    zone: Handle,
    device_id: u64,
    policy: u8,
    latency_frames: u32,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const render_policy: audio.zone.RenderPolicy = switch (policy) {
        0 => .robust,
        1 => .interactive,
        else => return .invalid_argument,
    };
    box.runtime.zoneOpenOutput(
        importZone(zone),
        device_id,
        render_policy,
        latency_frames,
    ) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_zone_close_output(runtime: ?*Runtime, zone: Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    box.runtime.zoneCloseOutput(importZone(zone)) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_zone_status_get(
    runtime: ?*Runtime,
    zone: Handle,
    output: ?*ZoneStatus,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const destination = output orelse return .invalid_argument;
    const stats = box.runtime.zoneStats(importZone(zone)) catch |err| return mapError(err);
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
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    if (box.foreignThread()) return .wrong_thread;
    const zone = box.runtime.playerOpenDefaultOutput(importPlayer(player), device_id) catch |err|
        return mapError(err);
    if (zone_out) |output| output.* = exportZoneHandle(zone);
    return .ok;
}

fn runtimeBox(runtime: ?*Runtime) ?*RuntimeBox {
    return @ptrCast(@alignCast(runtime orelse return null));
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
        },
        .direction = if (query.descending != 0) .descending else .ascending,
        .limit = query.limit,
        .offset = query.offset,
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
        .title = stringView(item.title),
        .artist = stringView(item.artist),
        .album = stringView(item.album),
        .album_artist = stringView(item.album_artist),
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

fn exportJobKind(kind: job.Kind) u8 {
    return switch (kind) {
        .scan => 0,
        .projection => 1,
        .property_backfill => 2,
        .analysis => 3,
        .duplicate_scan => 4,
        else => 255,
    };
}

/// One lossless completion, flattened into the POD union. The handle field is
/// zeroed for outcomes that name no object, so a host never reads a handle that
/// means nothing.
fn exportCompletion(event: control.Event) Event {
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
            completed.failure = @intFromEnum(failure);
        },
    }
    return .{
        .kind = @intFromEnum(EventKind.command_completed),
        .payload = .{ .command_completed = completed },
    };
}

fn exportTelemetry(telemetry: control.Telemetry) Event {
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
        => .invalid_state,
        error.TrackHasNoPlayableFile, error.TrackFileMissing, error.UnknownRoot => .not_found,
        error.PlaybackQueueFull, error.LibraryJobRunning => .busy,
        error.CodecUnavailable,
        error.UnsupportedAudioFormat,
        error.UnsupportedChannelCount,
        => .unsupported,
        error.InvalidVolume, error.InvalidBatchSize, error.InvalidLibraryRoot => .invalid_argument,
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
    // The defect this boundary used to lock in: a detached state machine
    // reported PLAYING with no source loaded and no Zone attached.
    try std.testing.expectEqual(Status.invalid_state, orca_player_play(runtime, player));
    var snapshot: PlayerSnapshot = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_snapshot(runtime, player, &snapshot));
    try std.testing.expectEqual(@as(u8, 0), snapshot.state);
    var status: PlayerStatus = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_status_get(runtime, player, &status));
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
    try std.testing.expectEqual(Status.stale_handle, orca_player_snapshot(runtime, player, &snapshot));
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
