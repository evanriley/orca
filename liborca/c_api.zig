//! Controlled C-compatible boundary for Swift and other foreign frontends.
//! No internal Zig containers or object pointers cross this module.
const std = @import("std");
const core = @import("core/root.zig");

pub const Runtime = opaque {};

pub const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    runtime_not_running = 2,
    stale_handle = 3,
    out_of_memory = 4,
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
    title: StringView,
    album: StringView,
    album_artist: StringView,
};

pub const TrackCallback = *const fn (?*anyopaque, *const TrackView) callconv(.c) void;

pub const HealthIssueView = extern struct {
    kind: u8,
    severity: u8,
    _reserved: [6]u8 = @splat(0),
    path: StringView,
    details: StringView,
};

pub const HealthIssueCallback = *const fn (?*anyopaque, *const HealthIssueView) callconv(.c) void;

const RuntimeBox = struct {
    runtime: core.OrcaRuntime,
};

pub export fn orca_runtime_create() callconv(.c) ?*Runtime {
    const box = std.heap.c_allocator.create(RuntimeBox) catch return null;
    box.* = .{ .runtime = .init(std.heap.c_allocator) };
    return @ptrCast(box);
}

pub export fn orca_runtime_destroy(runtime: ?*Runtime) callconv(.c) void {
    const box = runtimeBox(runtime) orelse return;
    box.runtime.deinit();
    std.heap.c_allocator.destroy(box);
}

pub export fn orca_library_open(
    runtime: ?*Runtime,
    path: ?[*:0]const u8,
    output: ?*Handle,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    const path_pointer = path orelse return .invalid_argument;
    const destination = output orelse return .invalid_argument;
    const library = box.runtime.openLibrary(std.mem.span(path_pointer)) catch |err|
        return mapError(err);
    destination.* = exportLibraryHandle(library);
    return .ok;
}

pub export fn orca_library_close(runtime: ?*Runtime, library: Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    box.runtime.destroyLibrary(importLibrary(library)) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_library_track_count(
    runtime: ?*Runtime,
    library: Handle,
    output: ?*u64,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
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
    const visit = callback orelse return .invalid_argument;
    if (limit == 0 or limit > 512) return .invalid_argument;
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
        const view: TrackView = .{
            .id = item.id,
            .title = stringView(item.title),
            .album = stringView(item.album),
            .album_artist = stringView(item.album_artist),
        };
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
    const visit = callback orelse return .invalid_argument;
    if (limit == 0 or limit > 512) return .invalid_argument;
    var page = box.runtime.libraryHealthIssuePage(
        importLibrary(library),
        limit,
        offset,
    ) catch |err| return mapError(err);
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

pub export fn orca_player_create(
    runtime: ?*Runtime,
    output: ?*Handle,
) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    const destination = output orelse return .invalid_argument;
    const player = box.runtime.createPlayer() catch |err| return mapError(err);
    destination.* = exportHandle(player);
    return .ok;
}

pub export fn orca_player_destroy(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    box.runtime.destroyPlayer(importPlayer(player)) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_player_play(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    box.runtime.playPlayer(importPlayer(player)) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_player_pause(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
    box.runtime.pausePlayer(importPlayer(player)) catch |err| return mapError(err);
    return .ok;
}

pub export fn orca_player_stop(runtime: ?*Runtime, player: Handle) callconv(.c) Status {
    const box = runtimeBox(runtime) orelse return .invalid_argument;
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
    const destination = output orelse return .invalid_argument;
    const snapshot = box.runtime.playerSnapshot(importPlayer(player)) catch |err|
        return mapError(err);
    destination.* = .{
        .state = @backingInt(snapshot.state),
        .generation = snapshot.generation,
        .position_frames = snapshot.position_frames,
    };
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

fn mapError(err: anyerror) Status {
    return switch (err) {
        error.RuntimeNotRunning => .runtime_not_running,
        error.StaleHandle => .stale_handle,
        error.OutOfMemory => .out_of_memory,
        else => .internal,
    };
}

test "C ABI exposes opaque runtime and POD player snapshots" {
    const runtime = orca_runtime_create() orelse return error.OutOfMemory;
    defer orca_runtime_destroy(runtime);
    var player: Handle = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_create(runtime, &player));
    try std.testing.expectEqual(Status.ok, orca_player_play(runtime, player));
    var snapshot: PlayerSnapshot = undefined;
    try std.testing.expectEqual(Status.ok, orca_player_snapshot(runtime, player, &snapshot));
    try std.testing.expectEqual(@as(u8, 1), snapshot.state);
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
    try (try box.runtime.libraryDatabase(importLibrary(library))).tracks.insertBatch(&.{
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
    const database = try box.runtime.libraryDatabase(importLibrary(library));
    try database.health_issues.replacePath("track.flac", &.{.{
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
