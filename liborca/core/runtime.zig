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
const PlayerObject = struct {
    player: *audio.player.Player,
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

pub const ZoneStats = struct {
    output_state: audio.zone.OutputState,
    recovery_attempts: u32,
    underruns: u64,
    dropped_returns: u64,
    backend_quantum_frames: u32,
    rendered_entry_serial: u32,
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
    /// Host audio backend. Zones reach it only through `output.Factory`, so a
    /// platform without one simply never opens a stream.
    output_host: audio.backends.Host = .{},
    output_host_ready: bool = false,
    /// Replaces the host backend for embedders that supply their own output, and
    /// for tests that must be deterministic without an audio server. Must be set
    /// before any Player engine is spawned; engines capture it once.
    output_factory_override: ?audio.output.Factory = null,

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
        self.work_registry.requestCancellation();
        self.work_registry.drain();
        self.jobs.cancelAndDrain();
        for (self.zones.slots.items) |*slot| {
            if (slot.value) |zone| zone.zone.destroy();
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
        const tracks = &(try self.libraryDatabase(library)).tracks;
        return if (query.len == 0)
            tracks.page(self.allocator, limit, offset)
        else
            tracks.search(self.allocator, query, limit, offset);
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
        return self.players.insert(.{ .player = player });
    }

    pub fn destroyPlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
        try self.requireRunning();
        self.stopEngine(try self.players.get(player));
        self.joinWorkersBeforeDestroy();
        self.reapStoppedEngines();
        const removed = try self.players.remove(player);
        removed.player.deinit();
        self.allocator.destroy(removed.player);
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

    pub fn markZoneOutputLost(self: *OrcaRuntime, zone: ZoneHandle) !void {
        try self.requireRunning();
        const object_value = try self.zones.get(zone);
        try self.requireZoneIdle(object_value);
        object_value.zone.zone.deviceLost();
        object_value.zone.publishState();
    }

    pub fn beginZoneRecovery(self: *OrcaRuntime, zone: ZoneHandle) !void {
        try self.requireRunning();
        const object_value = try self.zones.get(zone);
        try self.requireZoneIdle(object_value);
        object_value.zone.zone.beginRecovery();
        object_value.zone.publishState();
    }

    pub fn failZoneRecovery(self: *OrcaRuntime, zone: ZoneHandle) !void {
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

    pub fn playPlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
        try self.requireRunning();
        (try self.players.get(player)).player.play();
    }

    pub fn pausePlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
        try self.requireRunning();
        (try self.players.get(player)).player.pause();
    }

    pub fn stopPlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
        try self.requireRunning();
        (try self.players.get(player)).player.stop();
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

    /// Spawns the Player's single decode producer. Registered with
    /// `work.Registry`, so `drain`, `destroyPlayer` and `shutdown` all join it
    /// rather than leaving it running against freed objects.
    fn ensureEngine(self: *OrcaRuntime, player: PlayerHandle) !*audio.engine.PlayerEngine {
        if ((try self.players.get(player)).engine) |existing| return existing;
        const factory = self.outputFactory();
        const engine = try audio.engine.PlayerEngine.create(self.allocator, .{
            .player = (try self.players.get(player)).player,
            .handle = player,
            .telemetry = &self.telemetry,
            .factory = factory,
        });
        errdefer engine.destroy();
        const work_handle = try self.work_registry.begin();
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
                engine.destroy();
                object_value.engine = null;
                object_value.engine_work = null;
            }
        }
    }

    /// Stands in for the executors later phases will add: it registers work and
    /// starts a real worker thread that observes cancellation, so shutdown and
    /// destroy paths are exercised against a live worker rather than a bare
    /// handle. The worker only ever touches its own `work.Registration`.
    pub fn startDummyWork(self: *OrcaRuntime) !WorkHandle {
        try self.requireRunning();
        const work_handle = try self.work_registry.begin();
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

    /// Destroying a Player or a Zone carries the same requirement as shutdown:
    /// no worker may still be holding the object when it is freed. Work is not
    /// yet scoped per object, so a destroy conservatively cancels and joins
    /// every registered worker. Narrowing this to the workers that actually
    /// hold the destroyed object is a later refinement, never a relaxation.
    fn joinWorkersBeforeDestroy(self: *OrcaRuntime) void {
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
    const work_handle = try runtime.work_registry.begin();
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

test "destroying a Player joins workers before freeing it" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    const player = try runtime.createPlayer();
    const work_handle = try runtime.work_registry.begin();
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
    var waited: usize = 0;
    while (try runtime.zoneOutputState(zone) != .active and waited < 8000) : (waited += 1)
        std.Thread.yield() catch {};
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

    var waited: usize = 0;
    while (try runtime.zoneOutputState(removed) != .active and waited < 8000) : (waited += 1)
        std.Thread.yield() catch {};
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
