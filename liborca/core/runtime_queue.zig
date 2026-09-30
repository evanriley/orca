const std = @import("std");
const audio = @import("../audio/root.zig");
const codec = @import("../codec/root.zig");
const track_source = @import("track_source.zig");
const runtime = @import("runtime.zig");
const runtime_listens = @import("runtime_listens.zig");
const runtime_zones = @import("runtime_zones.zig");

const LibraryHandle = runtime.LibraryHandle;
const OrcaRuntime = runtime.OrcaRuntime;
const PlayerHandle = runtime.PlayerHandle;
const PlayerObject = runtime.PlayerObject;
const QueueSnapshot = runtime.QueueSnapshot;
const QueueStats = runtime.QueueStats;
const RepeatMode = runtime.RepeatMode;
const TrackRef = runtime.TrackRef;

pub fn seekPlayer(self: *OrcaRuntime, player: PlayerHandle, frame: u64) !u32 {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    if (object_value.engine) |engine| {
        engine.quiesce();
        defer engine.release();
        return try object_value.player.seek(frame);
    }
    return try object_value.player.seek(frame);
}

pub fn playPlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    if (object_value.player.sources == null and object_value.queue.isEmpty())
        return error.PlayerHasNoSource;
    if (!runtime_zones.playerHasZone(self, player)) return error.PlayerHasNoOutput;
    object_value.player.play();
    if (object_value.engine) |engine| engine.wakeUp();
}

pub fn pausePlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    object_value.player.pause();
    if (object_value.engine) |engine| engine.wakeUp();
}

pub fn stopPlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
    try runtime.requireRunning(self);
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
    try runtime.requireRunning(self);
    return (try self.players.get(player)).player.snapshot();
}

pub fn playerLoadFile(
    self: *OrcaRuntime,
    player: PlayerHandle,
    io: std.Io,
    path: []const u8,
) !void {
    try runtime.requireRunning(self);
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
    const engine = try ensureEngine(self, player);
    // The engine is the Player's only decoder; swapping the SourceQueue
    // under it would race its own reads.
    engine.quiesce();
    defer engine.release();
    (try self.players.get(player)).player.replaceSource(owned);
}

pub fn playerDrained(self: *OrcaRuntime, player: PlayerHandle) !bool {
    try runtime.requireRunning(self);
    const engine = (try self.players.get(player)).engine orelse return false;
    return engine.isDrained();
}

pub fn playerBindLibrary(
    self: *OrcaRuntime,
    player: PlayerHandle,
    library: LibraryHandle,
    io: std.Io,
) !void {
    try runtime.requireRunning(self);
    const existing = try self.players.get(player);
    if (existing.opener) |opener| {
        if (opener.library.eql(library)) return;
    }
    const library_database = try runtime.libraryDatabase(self, library);
    _ = try runtime_listens.startListenWorker(self, library);
    const opener = try track_source.TrackSourceOpener.create(
        self.allocator,
        io,
        library,
        library_database,
    );
    errdefer opener.destroy();

    const object_value = try self.players.get(player);
    if (object_value.opener) |old| runtime_listens.endListen(self, object_value, old.library);
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

pub fn playerPlayTrack(
    self: *OrcaRuntime,
    player: PlayerHandle,
    library: LibraryHandle,
    io: std.Io,
    track_id: i64,
) !void {
    return self.playerPlayTracks(player, library, io, &.{track_id}, 0);
}

pub fn playerPlayTrackBound(
    self: *OrcaRuntime,
    player: PlayerHandle,
    library: LibraryHandle,
    track_id: i64,
) !void {
    return self.playerPlayTracksBound(player, library, &.{track_id}, 0);
}

pub fn playerPlayTracks(
    self: *OrcaRuntime,
    player: PlayerHandle,
    library: LibraryHandle,
    io: std.Io,
    track_ids: []const i64,
    start: u32,
) !void {
    try runtime.requireRunning(self);
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
    try runtime.requireRunning(self);
    try requireBoundLibrary(self, player, library);
    const refs = try trackRefs(self, library, track_ids);
    defer self.allocator.free(refs);
    const engine = try ensureEngine(self, player);
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

pub fn playerEnqueueTracks(
    self: *OrcaRuntime,
    player: PlayerHandle,
    library: LibraryHandle,
    io: std.Io,
    track_ids: []const i64,
) !void {
    try runtime.requireRunning(self);
    try self.playerBindLibrary(player, library, io);
    return self.playerEnqueueTracksBound(player, library, track_ids);
}

pub fn playerEnqueueTracksBound(
    self: *OrcaRuntime,
    player: PlayerHandle,
    library: LibraryHandle,
    track_ids: []const i64,
) !void {
    try runtime.requireRunning(self);
    try requireBoundLibrary(self, player, library);
    const refs = try trackRefs(self, library, track_ids);
    defer self.allocator.free(refs);
    const engine = try ensureEngine(self, player);
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

pub fn playerQueueJump(self: *OrcaRuntime, player: PlayerHandle, position: u32) !void {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    if (position >= object_value.queue.len()) return error.PositionOutOfRange;
    const engine = object_value.engine;
    if (engine) |value| value.quiesce();
    defer if (engine) |value| value.release();
    if (engine) |value| value.discardPending();
    object_value.queue.seekTo(position);
    try loadCursor(object_value);
    object_value.player.play();
}

pub fn playerQueueInsertNext(
    self: *OrcaRuntime,
    player: PlayerHandle,
    library: LibraryHandle,
    track_ids: []const i64,
) !void {
    try runtime.requireRunning(self);
    try requireBoundLibrary(self, player, library);
    if ((try self.players.get(player)).queue.isEmpty())
        return self.playerEnqueueTracksBound(player, library, track_ids);
    const refs = try trackRefs(self, library, track_ids);
    defer self.allocator.free(refs);
    const engine = try ensureEngine(self, player);
    engine.quiesce();
    defer engine.release();
    const queue = (try self.players.get(player)).queue;
    const committed = if (engine.pending_source != null) engine.pending_position else queue.decodePosition();
    const pending: ?*u32 = if (engine.pending_source != null) &engine.pending_position else null;
    try queue.insertAfter(committed, refs, pending);
}

pub fn playerQueueRemove(self: *OrcaRuntime, player: PlayerHandle, position: u32) !void {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    const queue = object_value.queue;
    if (position >= queue.len()) return error.PositionOutOfRange;
    const engine = object_value.engine;
    if (engine) |value| value.quiesce();
    defer if (engine) |value| value.release();
    const pending: ?*u32 = if (engine) |value|
        (if (value.pending_source != null) &value.pending_position else null)
    else
        null;
    const holds_audio = object_value.player.sources != null;
    if (holds_audio and (position == queue.cursorPosition() or position == queue.decodePosition()))
        return error.QueueEntryInUse;
    if (pending) |value| if (value.* == position) return error.QueueEntryInUse;
    try queue.removeAt(position, pending);
}

pub fn playerNext(self: *OrcaRuntime, player: PlayerHandle) !bool {
    try runtime.requireRunning(self);
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

pub fn playerPrevious(self: *OrcaRuntime, player: PlayerHandle) !bool {
    try runtime.requireRunning(self);
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
    try runtime.requireRunning(self);
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
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    if (object_value.engine) |engine| {
        engine.quiesce();
        defer engine.release();
        return object_value.queue.setShuffle(enabled);
    }
    return object_value.queue.setShuffle(enabled);
}

pub fn playerClearQueue(self: *OrcaRuntime, player: PlayerHandle) !void {
    try runtime.requireRunning(self);
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

pub fn playerQueueSnapshot(
    self: *OrcaRuntime,
    player: PlayerHandle,
) !QueueSnapshot {
    try runtime.requireRunning(self);
    return (try self.players.get(player)).queue.snapshot();
}

pub fn playerNowPlaying(self: *OrcaRuntime, player: PlayerHandle) !?TrackRef {
    try runtime.requireRunning(self);
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

pub fn playerQueueStats(self: *OrcaRuntime, player: PlayerHandle) !QueueStats {
    try runtime.requireRunning(self);
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

pub fn playerSeekToTail(
    self: *OrcaRuntime,
    player: PlayerHandle,
    tail_ms: u64,
) !bool {
    try runtime.requireRunning(self);
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
pub fn ensureEngine(self: *OrcaRuntime, player: PlayerHandle) !*audio.engine.PlayerEngine {
    if ((try self.players.get(player)).engine) |existing| return existing;
    const factory = runtime.outputFactory(self);
    const object_state = try self.players.get(player);
    const engine = try audio.engine.PlayerEngine.create(self.allocator, .{
        .player = object_state.player,
        .handle = player,
        .telemetry = &self.telemetry,
        .factory = factory,
        .queue = object_state.queue,
        .opener = if (object_state.opener) |opener| opener.opener() else null,
        .dsp = object_state.dsp,
    });
    errdefer engine.destroy();
    const work_handle = try self.work_registry.begin(runtime.playerOwnerTag(player));
    const registration = self.work_registry.registration(work_handle) catch unreachable;
    // `complete` waits for the worker, so a registration whose thread never
    // started has to be marked finished or the wait would never return.
    errdefer {
        registration.finish();
        self.work_registry.complete(work_handle) catch {};
    }
    engine.registration = registration;
    registration.waker = engine.waker();
    // The engine must never resolve a handle, so it is handed its zone set
    // before it starts and re-handed one on every attach or detach.
    try publishZonesTo(self, player, engine);
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

pub fn republishZones(self: *OrcaRuntime, player: PlayerHandle) !void {
    const object_value = self.players.get(player) catch return;
    const engine = object_value.engine orelse return;
    try publishZonesTo(self, player, engine);
}

/// Cancels and joins one Player's engine thread, then frees it. On return no
/// engine can reach this Player's Zones, which is the precondition for
/// closing their outputs.
pub fn stopEngine(self: *OrcaRuntime, object_value: *PlayerObject) void {
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
pub fn reapStoppedEngines(self: *OrcaRuntime) void {
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
