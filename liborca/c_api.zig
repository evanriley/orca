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

fn importPlayer(handle: Handle) core.PlayerHandle {
    return .{ .index = handle.index, .generation = handle.generation };
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
