const std = @import("std");
const handle = @import("handle.zig");
const work = @import("work.zig");

const LibraryTag = struct {};
const PlayerTag = struct {};
const ZoneTag = struct {};

pub const LibraryHandle = handle.Handle(LibraryTag);
pub const PlayerHandle = handle.Handle(PlayerTag);
pub const ZoneHandle = handle.Handle(ZoneTag);
pub const WorkHandle = work.WorkHandle;

pub const State = enum {
    running,
    shutting_down,
    stopped,
};

const RuntimeObject = struct {};

/// Process-level root for liborca. Objects are invalidated in dependency order:
/// work, Zones, Players, then Libraries. `deinit` always performs shutdown.
pub const OrcaRuntime = struct {
    allocator: std.mem.Allocator,
    state: State = .running,
    libraries: handle.Pool(RuntimeObject, LibraryTag),
    players: handle.Pool(RuntimeObject, PlayerTag),
    zones: handle.Pool(RuntimeObject, ZoneTag),
    work_registry: work.Registry,

    pub fn init(allocator: std.mem.Allocator) OrcaRuntime {
        return .{
            .allocator = allocator,
            .libraries = .init(allocator),
            .players = .init(allocator),
            .zones = .init(allocator),
            .work_registry = .init(allocator),
        };
    }

    pub fn deinit(self: *OrcaRuntime) void {
        self.shutdown();
        self.work_registry.deinit();
        self.zones.deinit();
        self.players.deinit();
        self.libraries.deinit();
        self.* = undefined;
    }

    pub fn shutdown(self: *OrcaRuntime) void {
        if (self.state == .stopped) return;
        self.state = .shutting_down;

        self.work_registry.requestCancellation();
        self.work_registry.drain();
        self.zones.discardAll();
        self.players.discardAll();
        self.libraries.discardAll();

        self.state = .stopped;
    }

    pub fn createLibrary(self: *OrcaRuntime) !LibraryHandle {
        try self.requireRunning();
        return self.libraries.insert(.{});
    }

    pub fn destroyLibrary(self: *OrcaRuntime, library: LibraryHandle) !void {
        try self.requireRunning();
        _ = try self.libraries.remove(library);
    }

    pub fn createPlayer(self: *OrcaRuntime) !PlayerHandle {
        try self.requireRunning();
        return self.players.insert(.{});
    }

    pub fn destroyPlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
        try self.requireRunning();
        _ = try self.players.remove(player);
    }

    pub fn createZone(self: *OrcaRuntime) !ZoneHandle {
        try self.requireRunning();
        return self.zones.insert(.{});
    }

    pub fn destroyZone(self: *OrcaRuntime, zone: ZoneHandle) !void {
        try self.requireRunning();
        _ = try self.zones.remove(zone);
    }

    pub fn startDummyWork(self: *OrcaRuntime) !WorkHandle {
        try self.requireRunning();
        return self.work_registry.begin();
    }

    pub fn completeDummyWork(self: *OrcaRuntime, work_handle: WorkHandle) !void {
        try self.requireRunning();
        try self.work_registry.complete(work_handle);
    }

    pub fn inFlightWorkCount(self: *const OrcaRuntime) usize {
        return self.work_registry.count();
    }

    fn requireRunning(self: *const OrcaRuntime) error{RuntimeNotRunning}!void {
        if (self.state != .running) return error.RuntimeNotRunning;
    }
};

test "runtime can repeatedly start and stop without leaking" {
    for (0..100) |_| {
        var runtime = OrcaRuntime.init(std.testing.allocator);
        _ = try runtime.createLibrary();
        _ = try runtime.createPlayer();
        _ = try runtime.createZone();
        _ = try runtime.startDummyWork();
        runtime.shutdown();
        runtime.shutdown();
        try std.testing.expectEqual(State.stopped, runtime.state);
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
