const std = @import("std");
const audio = @import("../audio/root.zig");
const codec = @import("../codec/root.zig");
const database = @import("../database/root.zig");
const queue_history = @import("queue.zig");
const track_source = @import("track_source.zig");
const runtime = @import("runtime.zig");
const runtime_listens = @import("runtime_listens.zig");
const runtime_radio = @import("runtime_radio.zig");
const runtime_resume = @import("runtime_resume.zig");
const runtime_status = @import("runtime_status.zig");
const runtime_zones = @import("runtime_zones.zig");

const LibraryHandle = runtime.LibraryHandle;
const OrcaRuntime = runtime.OrcaRuntime;
const PlayerHandle = runtime.PlayerHandle;
const PlayerObject = runtime.PlayerObject;
const QueueHistoryEntry = runtime.QueueHistoryEntry;
const QueueSnapshot = runtime.QueueSnapshot;
const QueueStats = runtime.QueueStats;
const RepeatMode = runtime.RepeatMode;
const TrackRef = runtime.TrackRef;

pub fn seekPlayer(self: *OrcaRuntime, player: PlayerHandle, frame: u64) !u32 {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    const epoch = try seekObject(object_value, frame);
    runtime_resume.rememberAudible(self, object_value) catch {};
    return epoch;
}

fn seekObject(object_value: *PlayerObject, frame: u64) !u32 {
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
    runtime_resume.rememberAudible(self, object_value) catch {};
}

pub fn stopPlayer(self: *OrcaRuntime, player: PlayerHandle) !void {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    runtime_resume.rememberAudible(self, object_value) catch {};
    forgetAudibleEntry(self, object_value);
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
    runtime_resume.rememberAudible(self, try self.players.get(player)) catch {};
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
    runtime_radio.endSession(self, try self.players.get(player));
    const engine = try ensureEngine(self, player);
    // The engine is the Player's only decoder; swapping the SourceQueue
    // under it would race its own reads.
    engine.quiesce();
    defer engine.release();
    const object_value = try self.players.get(player);
    endAudibleEntry(self, object_value, .replaced);
    object_value.player.replaceSource(owned);
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
    runtime_radio.endSession(self, object_value);
    runtime_resume.leaveLibrary(self, object_value);
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
    runtime_resume.rememberAudible(self, try self.players.get(player)) catch {};
    runtime_radio.endSession(self, try self.players.get(player));
    const engine = try ensureEngine(self, player);
    engine.quiesce();
    defer engine.release();
    engine.discardPending();
    const object_value = try self.players.get(player);
    endAudibleEntry(self, object_value, .replaced);
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
    try loadCursor(self, object_value);
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
    var first_new = object_value.queue.len();
    if (runtime_radio.userInsertAfter(object_value)) |after| {
        const pending: ?*u32 = if (engine.pending_source != null) &engine.pending_position else null;
        try object_value.queue.insertAfter(after, refs, pending);
        first_new = after + 1;
    } else try object_value.queue.enqueue(refs);
    runtime_radio.noteUserQueued(object_value, refs.len);
    if (!was_idle) engine.refreshSharedRelease();
    if (!was_idle or refs.len == 0) return;
    engine.discardPending();
    object_value.queue.seekTo(first_new);
    try loadCursor(self, object_value);
    object_value.player.play();
}

pub fn playerQueueJump(self: *OrcaRuntime, player: PlayerHandle, position: u32) !void {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    if (position >= object_value.queue.len()) return error.PositionOutOfRange;
    runtime_resume.rememberAudible(self, object_value) catch {};
    const engine = object_value.engine;
    if (engine) |value| value.quiesce();
    defer if (engine) |value| value.release();
    const opener = object_value.opener orelse return error.PlayerHasNoLibrary;
    const session = openQueueEntry(object_value, opener, position) catch |err| {
        countOpenFailure(object_value);
        return err;
    };
    const left = runtime_radio.audibleEntry(object_value);
    if (engine) |value| value.discardPending();
    endAudibleEntry(self, object_value, .skipped);
    loadOpenedEntry(self, object_value, session, position);
    object_value.player.play();
    if (left) |value| runtime_radio.noteSkip(object_value, value);
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
    runtime_radio.noteUserQueued(try self.players.get(player), refs.len);
    engine.refreshSharedRelease();
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
    if (engine) |value| value.refreshSharedRelease();
}

/// Starting Radio replaces the upcoming queue: with audio held, every entry
/// past the engine's committed span (cursor, decode-ahead and any opened
/// successor) is removed; idle, every entry is removed.
pub fn clearUpcoming(self: *OrcaRuntime, object_value: *PlayerObject) !void {
    _ = self;
    const queue = object_value.queue;
    const engine = object_value.engine;
    if (engine) |value| value.quiesce();
    defer if (engine) |value| value.release();
    const pending: ?*u32 = if (engine) |value|
        (if (value.pending_source != null) &value.pending_position else null)
    else
        null;
    var floor: u32 = 0;
    const holds_audio = object_value.player.sources != null;
    var committed = queue.cursorPosition();
    if (holds_audio) committed = @max(committed, queue.decodePosition());
    if (pending) |value| committed = @max(committed, value.*);
    if (holds_audio) floor = committed + 1;
    var position = queue.len();
    while (position > floor) {
        position -= 1;
        try queue.removeAt(position, pending);
    }
    if (engine) |value| value.refreshSharedRelease();
}

pub fn playerQueueMove(self: *OrcaRuntime, player: PlayerHandle, from: u32, to: u32) !void {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    const queue = object_value.queue;
    if (from >= queue.len() or to >= queue.len()) return error.PositionOutOfRange;
    if (from == to) return;
    const engine = object_value.engine;
    if (engine) |value| value.quiesce();
    defer if (engine) |value| value.release();
    const pending: ?*u32 = if (engine) |value|
        (if (value.pending_source != null) &value.pending_position else null)
    else
        null;
    const holds_audio = object_value.player.sources != null;
    const cursor = queue.cursorPosition();
    if (holds_audio and (from == cursor or from == queue.decodePosition()))
        return error.QueueEntryInUse;
    if (pending) |value| if (value.* == from) return error.QueueEntryInUse;
    const committed: ?u32 = if (pending) |value|
        value.*
    else if (holds_audio)
        queue.decodePosition()
    else
        null;
    if (committed) |value| {
        if (landsInCommittedSpan(withoutEntry(cursor, from), withoutEntry(value, from), to))
            return error.QueueEntryInUse;
    }
    try queue.move(from, to, pending);
    if (engine) |value| value.refreshSharedRelease();
}

fn withoutEntry(position: u32, removed: u32) u32 {
    return if (position > removed) position - 1 else position;
}

fn landsInCommittedSpan(cursor: u32, committed: u32, to: u32) bool {
    if (committed >= cursor) return cursor < to and to <= committed;
    return to > cursor or to <= committed;
}

pub fn playerNext(self: *OrcaRuntime, player: PlayerHandle) !bool {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    runtime_resume.rememberAudible(self, object_value) catch {};
    const engine = object_value.engine;
    if (engine) |value| value.quiesce();
    defer if (engine) |value| value.release();
    const left = runtime_radio.audibleEntry(object_value);
    const moved = try skipObject(self, object_value, .next);
    if (moved) if (left) |value| runtime_radio.noteSkip(object_value, value);
    return moved;
}

pub fn playerPrevious(self: *OrcaRuntime, player: PlayerHandle) !bool {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    runtime_resume.rememberAudible(self, object_value) catch {};
    const serial = object_value.player.audible_entry_serial.load(.acquire);
    const moved = try previousObject(self, object_value);
    if (object_value.player.audible_entry_serial.load(.acquire) == serial)
        runtime_resume.rememberAudible(self, object_value) catch {};
    return moved;
}

fn previousObject(self: *OrcaRuntime, object_value: *PlayerObject) !bool {
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
    if (object_value.queue.previousPosition() == null) {
        if (object_value.player.sources != null) _ = try object_value.player.seek(0);
        return false;
    }
    return skipObject(self, object_value, .previous);
}

pub const SkipDirection = enum { next, previous };

fn stepPosition(queue: *const audio.playback_queue.PlaybackQueue, position: u32, direction: SkipDirection) ?u32 {
    return switch (direction) {
        .next => queue.nextPositionAfter(position),
        .previous => queue.previousPositionBefore(position),
    };
}

/// The caller must have quiesced the engine. Nothing moves until an entry has
/// opened, so a skip whose every candidate fails leaves the old entry playing.
pub fn skipObject(self: *OrcaRuntime, object_value: *PlayerObject, direction: SkipDirection) !bool {
    const queue = object_value.queue;
    const cursor = queue.cursorPosition();
    var candidate = stepPosition(queue, cursor, direction) orelse return false;
    const opener = object_value.opener orelse return error.PlayerHasNoLibrary;
    var attempts: u32 = 0;
    var stepped_over: ?struct { track_id: i64, err: anyerror } = null;
    const session = while (true) {
        if (openQueueEntry(object_value, opener, candidate)) |opened| break opened else |err| {
            countOpenFailure(object_value);
            attempts += 1;
            if (attempts >= audio.engine.max_consecutive_open_failures) return err;
            const following = stepPosition(queue, candidate, direction) orelse return err;
            if (following == cursor) return err;
            stepped_over = .{ .track_id = queue.refAt(candidate).?.track_id, .err = err };
            candidate = following;
        }
    };
    if (object_value.engine) |engine| engine.discardPending();
    endAudibleEntry(self, object_value, .skipped);
    loadOpenedEntry(self, object_value, session, candidate);
    if (stepped_over) |failure| object_value.player.open_failure.record(failure.track_id, failure.err);
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
    if (object_value.queue.shuffle != enabled) try runtime_radio.beforeShuffleChange(self, object_value);
    if (object_value.engine) |engine| {
        engine.quiesce();
        defer engine.release();
        try object_value.queue.setShuffle(enabled);
        engine.refreshSharedRelease();
        return;
    }
    return object_value.queue.setShuffle(enabled);
}

pub fn playerClearQueue(self: *OrcaRuntime, player: PlayerHandle) !void {
    try runtime.requireRunning(self);
    runtime_radio.endSession(self, try self.players.get(player));
    endAudibleEntry(self, try self.players.get(player), .replaced);
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
    return runtime_status.readStatus(try self.players.get(player)).audible;
}

pub fn playerQueueHistory(
    self: *OrcaRuntime,
    player: PlayerHandle,
    offset: u32,
    output: []QueueHistoryEntry,
) !usize {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    observeQueueHistory(object_value, historyNowMs(self));
    var count: usize = 0;
    while (count < output.len) : (count += 1) {
        output[count] = object_value.history.newest(@as(usize, offset) + count) orelse break;
    }
    return count;
}

pub const QueueHistoryTrack = struct {
    position: u32,
    id: i64,
    ended_at_ms: i64,
    reason: queue_history.QueueHistoryReason,
    track: ?database.TrackSummary,

    pub fn deinit(self: QueueHistoryTrack, allocator: std.mem.Allocator) void {
        if (self.track) |track| track.deinit(allocator);
    }
};

pub const QueueHistoryTrackPage = struct {
    allocator: std.mem.Allocator,
    items: []QueueHistoryTrack,

    pub fn deinit(self: QueueHistoryTrackPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub fn playerQueueHistoryTracks(
    self: *OrcaRuntime,
    player: PlayerHandle,
    allocator: std.mem.Allocator,
    offset: u32,
    limit: u32,
) !QueueHistoryTrackPage {
    try runtime.requireRunning(self);
    if (limit == 0 or limit > database.repository.max_page)
        return error.PageOutOfRange;
    const object_value = try self.players.get(player);
    observeQueueHistory(object_value, historyNowMs(self));

    var rows: std.ArrayList(QueueHistoryTrack) = .empty;
    errdefer {
        for (rows.items) |item| item.deinit(allocator);
        rows.deinit(allocator);
    }
    var index: u32 = 0;
    while (index < limit) : (index += 1) {
        const position = std.math.add(u32, offset, index) catch break;
        const entry = object_value.history.newest(position) orelse break;
        const track = try runtime_status.trackSummaryOf(self, allocator, entry.track);
        errdefer if (track) |summary| summary.deinit(allocator);
        try rows.append(allocator, .{
            .position = position,
            .id = entry.track.track_id,
            .ended_at_ms = entry.ended_at_ms,
            .reason = entry.reason,
            .track = track,
        });
    }
    return .{ .allocator = allocator, .items = try rows.toOwnedSlice(allocator) };
}

pub fn playerClearQueueHistory(self: *OrcaRuntime, player: PlayerHandle) !void {
    try runtime.requireRunning(self);
    (try self.players.get(player)).history.clear();
}

pub fn playerSaveQueueAsPlaylist(
    self: *OrcaRuntime,
    player: PlayerHandle,
    library: LibraryHandle,
    name: []const u8,
) !i64 {
    try runtime.requireRunning(self);
    try requireBoundLibrary(self, player, library);
    const playback_queue = (try self.players.get(player)).queue;
    var track_ids: std.ArrayList(i64) = .empty;
    defer track_ids.deinit(self.allocator);
    var position = playback_queue.cursorPosition();
    while (playback_queue.refAt(position)) |ref| : (position += 1) {
        if (ref.library.eql(library)) try track_ids.append(self.allocator, ref.track_id);
    }
    if (track_ids.items.len == 0) return error.QueueEmpty;

    const playlists = &(try runtime.libraryDatabase(self, library)).playlists;
    const playlist_id = try playlists.create(name);
    errdefer playlists.delete(playlist_id) catch {};
    var start: usize = 0;
    while (start < track_ids.items.len) : (start += database.repository.max_page) {
        const end = @min(start + database.repository.max_page, track_ids.items.len);
        _ = try playlists.insert(playlist_id, track_ids.items[start..end], null);
    }
    return playlist_id;
}

pub fn observeQueueHistory(object_value: *PlayerObject, now_ms: i64) void {
    const entry = runtime_status.readAudibleEntry(object_value) orelse return;
    const history = &object_value.history;
    const appended_before = history.next;
    history.observe(entry.entry_serial, entry.track, entry.drained, now_ms);
    if (history.next == appended_before) return;
    const ended = history.newest(0) orelse return;
    if (ended.reason == .finished) runtime_resume.noteFinished(&object_value.persistence, ended.track);
}

pub fn endAudibleEntry(self: *OrcaRuntime, object_value: *PlayerObject, reason: queue_history.QueueHistoryReason) void {
    const now_ms = historyNowMs(self);
    observeQueueHistory(object_value, now_ms);
    object_value.history.end(reason, now_ms);
}

pub fn forgetAudibleEntry(self: *OrcaRuntime, object_value: *PlayerObject) void {
    observeQueueHistory(object_value, historyNowMs(self));
    object_value.history.forget();
}

pub fn historyNowMs(self: *OrcaRuntime) i64 {
    if (self.listen_hooks.sample_clock) |clock| return clock.now().wall_s * std.time.ms_per_s;
    return std.Io.Clock.real.now(self.control_threaded.io()).toMilliseconds();
}

pub fn requireBoundLibrary(
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

/// Opens the entry under the cursor and hard-loads it, resuming a long Track
/// where it was left. The caller must have quiesced the engine: this
/// replaces the Player's whole `SourceQueue`.
pub fn loadCursor(self: *OrcaRuntime, object_value: *PlayerObject) !void {
    const opener = object_value.opener orelse return error.PlayerHasNoLibrary;
    const cursor = object_value.queue.cursorPosition();
    if (object_value.queue.current() == null) {
        object_value.player.releaseSources();
        return;
    }
    const session = try openQueueEntry(object_value, opener, cursor);
    loadOpenedEntry(self, object_value, session, cursor);
}

fn openQueueEntry(
    object_value: *PlayerObject,
    opener: *track_source.TrackSourceOpener,
    position: u32,
) !audio.source_session.SourceSession {
    const ref = object_value.queue.refAt(position) orelse return error.PositionOutOfRange;
    var session = opener.openTrack(ref) catch |err| {
        object_value.player.open_failure.record(ref.track_id, err);
        return err;
    };
    const format = session.decoder.format;
    if (format.channels == 0 or format.channels > audio.zone_runtime.max_channels) {
        session.deinit();
        object_value.player.open_failure.record(ref.track_id, error.UnsupportedChannelCount);
        return error.UnsupportedChannelCount;
    }
    session.replay_gain.shares_release = object_value.queue.sharesRelease(position, opener.opener());
    return session;
}

fn loadOpenedEntry(
    self: *OrcaRuntime,
    object_value: *PlayerObject,
    session: audio.source_session.SourceSession,
    position: u32,
) void {
    const ref = object_value.queue.refAt(position).?;
    audio.engine.loadQueueEntry(object_value.player, object_value.queue, session, position);
    runtime_resume.resumeRemembered(self, object_value, ref);
}

fn countOpenFailure(object_value: *PlayerObject) void {
    if (object_value.engine) |engine| engine.open_failures += 1;
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
        .host_signal = &self.host_signal,
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
    registration.thread = try engine.spawn();
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
