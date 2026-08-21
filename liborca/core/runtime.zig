const std = @import("std");
const audio = @import("../audio/root.zig");
const control = @import("control.zig");
const database = @import("../database/root.zig");
const handle = @import("handle.zig");
const job = @import("job.zig");
const object = @import("object.zig");
const work = @import("work.zig");

pub const LibraryHandle = object.LibraryHandle;
pub const PlayerHandle = object.PlayerHandle;
pub const ZoneHandle = object.ZoneHandle;
pub const JobHandle = object.JobHandle;
pub const WorkHandle = work.WorkHandle;

pub const State = enum(u8) {
    running,
    shutting_down,
    stopped,
};

const RuntimeObject = struct {};
const LibraryObject = struct {
    database: ?*database.LibraryDatabase = null,
};
const PlayerObject = struct { player: *audio.player.Player };
const ZoneObject = struct {
    zone: *audio.zone.Zone,
    attached_player: ?PlayerHandle = null,
};

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

    pub fn deinit(self: *OrcaRuntime) void {
        self.shutdown();
        self.work_registry.deinit();
        self.jobs.deinit();
        self.zones.deinit();
        self.players.deinit();
        self.libraries.deinit();
        self.* = undefined;
    }

    pub fn shutdown(self: *OrcaRuntime) void {
        if (self.state.cmpxchgStrong(
            .running,
            .shutting_down,
            .acq_rel,
            .acquire,
        ) != null) return;

        self.work_registry.requestCancellation();
        self.work_registry.drain();
        self.jobs.cancelAndDrain();
        for (self.zones.slots.items) |*slot| {
            if (slot.value) |zone| self.allocator.destroy(zone.zone);
        }
        self.zones.discardAll();
        for (self.players.slots.items) |*slot| {
            if (slot.value) |player| {
                player.player.deinit();
                self.allocator.destroy(player.player);
            }
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

    pub fn openLibrary(self: *OrcaRuntime, path: [:0]const u8) !LibraryHandle {
        try self.requireRunning();
        const library_database = try self.allocator.create(database.LibraryDatabase);
        errdefer self.allocator.destroy(library_database);
        library_database.* = try database.LibraryDatabase.open(self.allocator, path);
        errdefer library_database.close();
        return self.libraries.insert(.{ .database = library_database });
    }

    pub fn destroyLibrary(self: *OrcaRuntime, library: LibraryHandle) !void {
        try self.requireRunning();
        var removed = try self.libraries.remove(library);
        self.closeLibraryDatabase(&removed);
    }

    pub fn libraryDatabase(
        self: *OrcaRuntime,
        library: LibraryHandle,
    ) !*database.LibraryDatabase {
        try self.requireRunning();
        return (try self.libraries.get(library)).database orelse error.LibraryHasNoDatabase;
    }

    pub fn createPlayer(self: *OrcaRuntime) !PlayerHandle {
        try self.requireRunning();
        const player = try self.allocator.create(audio.player.Player);
        errdefer self.allocator.destroy(player);
        player.* = .{};
        return self.players.insert(.{ .player = player });
    }

    pub fn destroyPlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
        try self.requireRunning();
        const removed = try self.players.remove(player);
        removed.player.deinit();
        self.allocator.destroy(removed.player);
        for (self.zones.slots.items) |*slot| {
            if (slot.value) |*zone| {
                if (zone.attached_player) |attached| {
                    if (attached.eql(player)) zone.attached_player = null;
                }
            }
        }
    }

    pub fn createZone(self: *OrcaRuntime) !ZoneHandle {
        try self.requireRunning();
        const zone = try self.allocator.create(audio.zone.Zone);
        errdefer self.allocator.destroy(zone);
        zone.* = .{
            .policy = .robust,
            .latency = .{
                .requested_frames = 0,
                .backend_quantum_frames = 0,
                .render_ahead_frames = 0,
                .dsp_frames = 0,
                .hardware_frames = null,
            },
        };
        return self.zones.insert(.{ .zone = zone });
    }

    pub fn destroyZone(self: *OrcaRuntime, zone: ZoneHandle) !void {
        try self.requireRunning();
        const removed = try self.zones.remove(zone);
        self.allocator.destroy(removed.zone);
    }

    pub fn attachZone(self: *OrcaRuntime, zone: ZoneHandle, player: PlayerHandle) !void {
        try self.requireRunning();
        _ = try self.players.get(player);
        (try self.zones.get(zone)).attached_player = player;
    }

    pub fn setZonePolicy(
        self: *OrcaRuntime,
        zone: ZoneHandle,
        policy: audio.zone.RenderPolicy,
    ) !void {
        try self.requireRunning();
        (try self.zones.get(zone)).zone.policy = policy;
    }

    pub fn zoneRenderStrategy(
        self: *OrcaRuntime,
        zone: ZoneHandle,
    ) !audio.zone.RenderStrategy {
        try self.requireRunning();
        return (try self.zones.get(zone)).zone.renderStrategy();
    }

    pub fn zoneOutputState(self: *OrcaRuntime, zone: ZoneHandle) !audio.zone.OutputState {
        try self.requireRunning();
        return (try self.zones.get(zone)).zone.output_state;
    }

    pub fn markZoneOutputLost(self: *OrcaRuntime, zone: ZoneHandle) !void {
        try self.requireRunning();
        (try self.zones.get(zone)).zone.deviceLost();
    }

    pub fn beginZoneRecovery(self: *OrcaRuntime, zone: ZoneHandle) !void {
        try self.requireRunning();
        (try self.zones.get(zone)).zone.beginRecovery();
    }

    pub fn failZoneRecovery(self: *OrcaRuntime, zone: ZoneHandle) !void {
        try self.requireRunning();
        (try self.zones.get(zone)).zone.recoveryFailed();
    }

    pub fn seekPlayer(self: *OrcaRuntime, player: PlayerHandle, frame: u64) !u64 {
        try self.requireRunning();
        return try (try self.players.get(player)).player.seek(frame);
    }

    pub fn playerSnapshot(self: *OrcaRuntime, player: PlayerHandle) !audio.player.Snapshot {
        try self.requireRunning();
        return (try self.players.get(player)).player.snapshot();
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

    pub fn publishTelemetry(self: *OrcaRuntime, telemetry: control.Telemetry) !void {
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
        };
    }

    fn mapFailure(err: anyerror) control.Failure {
        return switch (err) {
            error.RuntimeNotRunning => .runtime_not_running,
            error.StaleHandle => .stale_handle,
            error.OutOfMemory => .out_of_memory,
            error.InvalidJobTransition, error.JobAlreadyFinished => .invalid_transition,
            else => .internal,
        };
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
        "file:orca-runtime-library?mode=memory&cache=shared",
    );
    const library_database = try runtime.libraryDatabase(library);
    try library_database.tracks.insertBatch(&.{.{ .title = "Runtime track" }});
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
    const generation = try runtime.seekPlayer(player, 96_000);
    const snapshot = try runtime.playerSnapshot(player);
    try std.testing.expectEqual(generation, snapshot.generation);
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
    (try runtime.zones.get(robust)).zone.beginOpen(1);
    (try runtime.zones.get(interactive)).zone.beginOpen(2);
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
