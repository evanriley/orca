const std = @import("std");
const audio = @import("../audio/root.zig");
const control = @import("control.zig");
const database = @import("../database/root.zig");
const library_pass = @import("../library/root.zig");
const runtime = @import("runtime.zig");
const runtime_listens = @import("runtime_listens.zig");
const runtime_queue = @import("runtime_queue.zig");
const work = @import("work.zig");

const discovery = library_pass.discovery;
const sqlite = database.sqlite;
const LibraryHandle = runtime.LibraryHandle;
const OrcaRuntime = runtime.OrcaRuntime;
const PlayerHandle = runtime.PlayerHandle;
const PlayerObject = runtime.PlayerObject;
const TrackRef = runtime.TrackRef;

/// The moment and seed a Radio preview ranks at. A null `now_s` reads the
/// clock; a null `seed` derives one from `now_s`.
pub const RadioPreviewSession = struct {
    now_s: ?i64 = null,
    seed: ?u64 = null,
};

pub fn libraryRadioPreview(
    self: *OrcaRuntime,
    library: LibraryHandle,
    allocator: std.mem.Allocator,
    seed: discovery.Seed,
    options: discovery.RadioOptions,
    limit: usize,
    session: RadioPreviewSession,
) !discovery.Picks {
    const library_database = try runtime.libraryDatabase(self, library);
    const now_s = session.now_s orelse std.Io.Clock.real.now(self.control_threaded.io()).toSeconds();
    const source: discovery.Source = .of(library_database);
    return discovery.pickRadio(allocator, &source, seed, options, .{
        .now_s = now_s,
        .seed = session.seed orelse @bitCast(now_s),
    }, limit);
}

pub fn libraryDiscoverySettings(self: *OrcaRuntime, library: LibraryHandle) !discovery.Settings {
    const library_database = try runtime.libraryDatabase(self, library);
    return discovery.readSettings(&library_database.settings);
}

pub fn setLibraryDiscoverySettings(self: *OrcaRuntime, library: LibraryHandle, settings: discovery.Settings) !void {
    const library_database = try runtime.libraryDatabase(self, library);
    try discovery.writeSettings(&library_database.settings, settings);
    (try self.libraries.get(library)).radio_continue = settings.radio_continue;
}

/// Radio picks kept lined up after the user's own entries.
pub const max_pending = 8;
/// The most picks `playerRadioPicks` reports.
pub const max_reported_picks = 32;
pub const max_title_bytes = 256;
/// A pick left within this many milliseconds of its start counts as skipped.
pub const skip_threshold_ms: u64 = 30_000;

const max_tracked = 64;
const max_disliked = 1024;
const max_picked = discovery.max_session_exclusions - max_disliked;
const retry_delay_ms = 1_000;
const less_like_this_artist = -0.5;
const less_like_this_genre = -0.25;
const skip_artist = -0.25;

pub const RadioState = enum(u8) {
    active = 0,
    /// Repeat is on, so nothing is added until it is turned off.
    paused_by_repeat = 1,
    /// Nothing more qualifies under the current options and feedback.
    exhausted = 2,
    /// The queue is at `playback_queue.capacity`.
    full = 3,
};

pub const RadioCounts = struct {
    picks_added: u32 = 0,
    user_queued: u32 = 0,
    less_like_this: u32 = 0,
    skips: u32 = 0,
};

pub const RadioStatus = struct {
    library: LibraryHandle,
    seed: discovery.Seed,
    /// The seed's Track or Release title, Artist or genre name, cut at
    /// `max_title_bytes`; empty for decade, loved and recent seeds.
    title_buffer: [max_title_bytes]u8,
    title_len: u16,
    options: discovery.RadioOptions,
    state: RadioState,
    counts: RadioCounts,
    /// Picks still to start playing.
    pending: u32,
    /// Started by `radio.continue` when the queue ran out.
    continued: bool,

    pub fn title(self: *const RadioStatus) []const u8 {
        return self.title_buffer[0..self.title_len];
    }
};

/// A Radio pick still in the queue: playing, lined up or pending.
pub const RadioQueuePick = struct {
    entry_id: u64,
    position: u32,
    track_id: i64,
    recording_id: i64,
    reason: discovery.PickReason,
};

const Tracked = struct {
    entry_id: u64,
    position: u32,
    track_id: i64,
    recording_id: i64,
    artist_id: ?i64,
    first_genre: ?i64,
    reason: discovery.PickReason,
};

fn BoundedList(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        fn appendDroppingOldest(self: *Self, value: T) void {
            if (self.len == capacity) {
                std.mem.copyForwards(T, self.items[0 .. capacity - 1], self.items[1..capacity]);
                self.len -= 1;
            }
            self.items[self.len] = value;
            self.len += 1;
        }

        fn orderedRemove(self: *Self, index: usize) void {
            std.mem.copyForwards(T, self.items[index .. self.len - 1], self.items[index + 1 .. self.len]);
            self.len -= 1;
        }
    };
}

const Adjustments = BoundedList(discovery.Adjustment, discovery.max_session_adjustments);

pub const Session = struct {
    player: PlayerHandle,
    library: LibraryHandle,
    seed: discovery.Seed,
    title_buffer: [max_title_bytes]u8 = undefined,
    title_len: u16 = 0,
    options: discovery.RadioOptions,
    continued: bool,
    jitter_seed: u64,
    /// Bumped by every change that makes an in-flight top-up's inputs stale.
    generation: u64 = 1,
    /// Set when the Player was idle at start: the first pick to arrive plays.
    play_on_arrival: bool = false,
    exhausted: bool = false,
    wants_top_up: bool = true,
    retry_at_ms: ?i64 = null,
    counts: RadioCounts = .{},
    tracked: BoundedList(Tracked, max_tracked) = .{},
    picked: BoundedList(discovery.RecentPick, max_picked) = .{},
    disliked: BoundedList(i64, max_disliked) = .{},
    artist_adjustments: Adjustments = .{},
    genre_adjustments: Adjustments = .{},
    worker: ?*TopUp = null,
};

/// One scoring run on a thread of its own, against a read-only connection.
/// The control lane creates it, reaps it once `registration` is finished and
/// frees it; the worker touches nothing else.
const TopUp = struct {
    allocator: std.mem.Allocator,
    reader: sqlite.Database,
    write_lane: *database.repository.WriteLane,
    registration: *work.Registration,
    work_handle: runtime.WorkHandle,
    host_signal: *control.HostSignal,
    generation: u64,
    seed: discovery.Seed,
    options: discovery.RadioOptions,
    now_s: i64,
    jitter_seed: u64,
    excluded: []i64,
    artist_adjustments: []discovery.Adjustment,
    genre_adjustments: []discovery.Adjustment,
    recent: []discovery.RecentPick,
    limit: usize,
    picks: ?discovery.Picks = null,
    first_genres: []?i64 = &.{},
    failure: ?anyerror = null,

    fn run(self: *TopUp) void {
        const signal = self.host_signal;
        defer signal.raise();
        defer self.registration.finish();
        if (self.registration.cancellationRequested()) return;
        self.compute() catch |err| {
            self.failure = err;
        };
    }

    fn compute(self: *TopUp) !void {
        const source: discovery.Source = .onConnection(self.reader, self.write_lane);
        var picks = try discovery.pickRadio(self.allocator, &source, self.seed, self.options, .{
            .now_s = self.now_s,
            .seed = self.jitter_seed,
            .excluded_recordings = self.excluded,
            .artist_adjustments = self.artist_adjustments,
            .genre_adjustments = self.genre_adjustments,
            .recent = self.recent,
        }, self.limit);
        errdefer picks.deinit();
        const genres = try self.allocator.alloc(?i64, picks.items.len);
        errdefer self.allocator.free(genres);
        var statement = try self.reader.prepare(
            "SELECT genre_id FROM track_genres WHERE track_id = ?1 ORDER BY ordinal LIMIT 1;",
        );
        defer statement.deinit();
        for (picks.items, genres) |pick, *genre| {
            try statement.reset();
            try statement.bindInt64(1, pick.track_id);
            genre.* = if (try statement.step() == .row) statement.columnInt64(0) else null;
        }
        self.picks = picks;
        self.first_genres = genres;
    }

    fn interrupt(context: *anyopaque) callconv(.c) void {
        const self: *TopUp = @ptrCast(@alignCast(context));
        self.reader.interrupt();
    }

    fn destroy(self: *TopUp) void {
        if (self.picks) |*picks| picks.deinit();
        self.allocator.free(self.first_genres);
        self.allocator.free(self.excluded);
        self.allocator.free(self.artist_adjustments);
        self.allocator.free(self.genre_adjustments);
        self.allocator.free(self.recent);
        self.reader.close();
        self.allocator.destroy(self);
    }
};

pub fn playerStartRadio(
    self: *OrcaRuntime,
    player: PlayerHandle,
    library: LibraryHandle,
    seed: discovery.Seed,
    options: discovery.RadioOptions,
) !void {
    try runtime.requireRunning(self);
    try runtime_queue.requireBoundLibrary(self, player, library);
    try discovery.validateRadio(seed, options);
    try startSession(self, player, library, seed, options, false);
}

fn startSession(
    self: *OrcaRuntime,
    player: PlayerHandle,
    library: LibraryHandle,
    seed: discovery.Seed,
    options: discovery.RadioOptions,
    continued: bool,
) !void {
    const library_database = try runtime.libraryDatabase(self, library);
    const session = try self.allocator.create(Session);
    errdefer self.allocator.destroy(session);
    const now = runtime_listens.sampleTime(self);
    session.* = .{
        .player = player,
        .library = library,
        .seed = seed,
        .options = options,
        .continued = continued,
        .jitter_seed = std.hash.Wyhash.hash(@bitCast(now.mono_ms), std.mem.asBytes(&player)),
    };
    session.title_len = try readSeedTitle(library_database.queryDatabase(), seed, &session.title_buffer);

    const object_value = try self.players.get(player);
    if (object_value.radio != null) {
        try removePendingPicks(self, object_value);
        endSession(self, object_value);
    }
    try runtime_queue.clearUpcoming(self, object_value);
    const idle = object_value.player.sources == null;
    if (idle) switch (seed) {
        .track => |track_id| try playSeedTrack(self, player, library, track_id),
        else => session.play_on_arrival = true,
    };
    (try self.players.get(player)).radio = session;
    spawnTopUp(self, session) catch {
        session.retry_at_ms = now.mono_ms + retry_delay_ms;
    };
}

fn playSeedTrack(self: *OrcaRuntime, player: PlayerHandle, library: LibraryHandle, track_id: i64) !void {
    const engine = try runtime_queue.ensureEngine(self, player);
    engine.quiesce();
    defer engine.release();
    const object_value = try self.players.get(player);
    const first_new = object_value.queue.len();
    try object_value.queue.enqueue(&.{.{ .library = library, .track_id = track_id }});
    engine.discardPending();
    object_value.queue.seekTo(first_new);
    try runtime_queue.loadCursor(self, object_value);
    object_value.player.play();
}

fn readSeedTitle(db: sqlite.Database, seed: discovery.Seed, buffer: *[max_title_bytes]u8) !u16 {
    const sql: [:0]const u8, const id = switch (seed) {
        .track => |id| .{ "SELECT title FROM tracks WHERE id = ?1;", id },
        .release => |id| .{ "SELECT title FROM releases WHERE id = ?1;", id },
        .artist => |id| .{ "SELECT name FROM artists WHERE id = ?1;", id },
        .genre => |id| .{ "SELECT name FROM genres WHERE id = ?1;", id },
        .decade, .loved, .recent => return 0,
    };
    var statement = try db.prepare(sql);
    defer statement.deinit();
    try statement.bindInt64(1, id);
    if (try statement.step() != .row) return error.UnknownRadioSeed;
    const text = utf8Prefix(statement.columnText(0), max_title_bytes);
    @memcpy(buffer[0..text.len], text);
    return @intCast(text.len);
}

fn utf8Prefix(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

pub fn playerStopRadio(self: *OrcaRuntime, player: PlayerHandle) !void {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    if (object_value.radio == null) return;
    try removePendingPicks(self, object_value);
    endSession(self, object_value);
    const queue = object_value.queue;
    object_value.radio_continue_after = if (queue.len() == 0) null else queue.idAt(queue.len() - 1);
}

pub fn playerSetRadioOptions(self: *OrcaRuntime, player: PlayerHandle, options: discovery.RadioOptions) !void {
    try runtime.requireRunning(self);
    try discovery.validateRadio(.loved, options);
    const object_value = try self.players.get(player);
    const session = object_value.radio orelse return error.RadioNotActive;
    try removePendingPicks(self, object_value);
    session.options = options;
    restartPicking(self, session);
}

pub fn playerRadioLessLikeThis(self: *OrcaRuntime, player: PlayerHandle, entry_id: u64) !void {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    const session = object_value.radio orelse return error.RadioNotActive;
    const index = trackedIndex(session, entry_id) orelse return error.NotARadioPick;
    const queue = object_value.queue;
    const position = locate(queue, &session.tracked.items[index]) orelse {
        session.tracked.orderedRemove(index);
        return error.NotARadioPick;
    };
    const pick = session.tracked.items[index];
    const engine = object_value.engine;
    if (engine) |value| value.quiesce();
    defer if (engine) |value| value.release();
    const holds_audio = object_value.player.sources != null;
    if (holds_audio and position == queue.cursorPosition()) {
        const moved = runtime_queue.skipObject(self, object_value, .next) catch false;
        if (!moved) {
            runtime_queue.endAudibleEntry(self, object_value, .skipped);
            if (engine) |value| value.discardPending();
            object_value.player.stop();
            object_value.player.releaseSources();
        }
        const now_at = queue.positionOfId(entry_id) orelse unreachable;
        const pending: ?*u32 = if (engine) |value|
            (if (value.pending_source != null) &value.pending_position else null)
        else
            null;
        try queue.removeAt(now_at, pending);
    } else {
        const pending: ?*u32 = if (engine) |value|
            (if (value.pending_source != null) &value.pending_position else null)
        else
            null;
        if (holds_audio and position == queue.decodePosition()) return error.QueueEntryInUse;
        if (pending) |value| if (value.* == position) return error.QueueEntryInUse;
        try queue.removeAt(position, pending);
    }
    if (engine) |value| value.refreshSharedRelease();
    session.tracked.orderedRemove(index);
    dislike(session, pick.recording_id);
    if (pick.artist_id) |artist| adjust(&session.artist_adjustments, artist, less_like_this_artist);
    if (pick.first_genre) |genre| adjust(&session.genre_adjustments, genre, less_like_this_genre);
    session.counts.less_like_this += 1;
    session.generation += 1;
}

pub fn playerRadioUndoFeedback(self: *OrcaRuntime, player: PlayerHandle) !void {
    try runtime.requireRunning(self);
    const session = (try self.players.get(player)).radio orelse return error.RadioNotActive;
    session.disliked = .{};
    session.artist_adjustments = .{};
    session.genre_adjustments = .{};
    session.counts.less_like_this = 0;
    session.counts.skips = 0;
    restartPicking(self, session);
}

pub fn playerRadio(self: *OrcaRuntime, player: PlayerHandle) !?RadioStatus {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    const session = object_value.radio orelse return null;
    prune(session, object_value.queue);
    var status: RadioStatus = .{
        .library = session.library,
        .seed = session.seed,
        .title_buffer = undefined,
        .title_len = session.title_len,
        .options = session.options,
        .state = state(session, object_value.queue),
        .counts = session.counts,
        .pending = pendingCount(session, object_value.queue),
        .continued = session.continued,
    };
    @memcpy(status.title_buffer[0..session.title_len], session.title_buffer[0..session.title_len]);
    return status;
}

/// The session's picks from the playing one on, in playback order.
pub fn playerRadioPicks(self: *OrcaRuntime, player: PlayerHandle, output: []RadioQueuePick) !usize {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    const session = object_value.radio orelse return 0;
    prune(session, object_value.queue);
    var order: [max_tracked]usize = undefined;
    for (order[0..session.tracked.len], 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, order[0..session.tracked.len], session, byPosition);
    const count = @min(output.len, max_reported_picks, session.tracked.len);
    for (output[0..count], order[0..count]) |*out, index| {
        const pick = session.tracked.items[index];
        out.* = .{
            .entry_id = pick.entry_id,
            .position = pick.position,
            .track_id = pick.track_id,
            .recording_id = pick.recording_id,
            .reason = pick.reason,
        };
    }
    return count;
}

fn byPosition(session: *const Session, a: usize, b: usize) bool {
    return session.tracked.items[a].position < session.tracked.items[b].position;
}

fn state(session: *const Session, queue: *const audio.playback_queue.PlaybackQueue) RadioState {
    if (queue.repeat != .off) return .paused_by_repeat;
    if (queue.len() >= audio.playback_queue.capacity) return .full;
    if (session.exhausted) return .exhausted;
    return .active;
}

fn restartPicking(self: *OrcaRuntime, session: *Session) void {
    session.exhausted = false;
    session.generation += 1;
    session.wants_top_up = true;
    session.retry_at_ms = null;
    if (session.worker == null) spawnTopUp(self, session) catch {
        session.retry_at_ms = runtime_listens.sampleTime(self).mono_ms + retry_delay_ms;
    };
}

fn trackedIndex(session: *const Session, entry_id: u64) ?usize {
    for (session.tracked.slice(), 0..) |pick, index| {
        if (pick.entry_id == entry_id) return index;
    }
    return null;
}

/// The pick's playback position now, refreshing its hint. Control lane: only
/// it changes entries, ids or order, so no quiesce is needed to read them.
fn locate(queue: *const audio.playback_queue.PlaybackQueue, pick: *Tracked) ?u32 {
    if (queue.idAt(pick.position) == pick.entry_id) return pick.position;
    pick.position = queue.positionOfId(pick.entry_id) orelse return null;
    return pick.position;
}

/// Forgets picks that left the queue or were played past.
fn prune(session: *Session, queue: *const audio.playback_queue.PlaybackQueue) void {
    const cursor = queue.cursorPosition();
    var index: usize = 0;
    while (index < session.tracked.len) {
        const position = locate(queue, &session.tracked.items[index]);
        if (position == null or position.? < cursor) {
            session.tracked.orderedRemove(index);
        } else index += 1;
    }
}

fn pendingCount(session: *const Session, queue: *const audio.playback_queue.PlaybackQueue) u32 {
    const cursor = queue.cursorPosition();
    var count: u32 = 0;
    for (session.tracked.slice()) |pick| {
        if (pick.position > cursor) count += 1;
    }
    return count;
}

fn dislike(session: *Session, recording_id: i64) void {
    for (session.disliked.slice()) |id| if (id == recording_id) return;
    session.disliked.appendDroppingOldest(recording_id);
}

fn adjust(adjustments: *Adjustments, id: i64, delta: f64) void {
    for (adjustments.items[0..adjustments.len]) |*adjustment| {
        if (adjustment.id == id) {
            adjustment.delta += delta;
            return;
        }
    }
    if (adjustments.len == discovery.max_session_adjustments) return;
    adjustments.items[adjustments.len] = .{ .id = id, .delta = delta };
    adjustments.len += 1;
}

fn forgetPicked(session: *Session, recording_id: i64) void {
    var index = session.picked.len;
    while (index > 0) {
        index -= 1;
        if (session.picked.items[index].recording_id == recording_id) {
            session.picked.orderedRemove(index);
            return;
        }
    }
}

/// Removes the picks that have not started and that the engine has not
/// committed to: never the audible entry, the decode-ahead entry or the
/// engine's opened successor.
fn removePendingPicks(self: *OrcaRuntime, object_value: *PlayerObject) !void {
    _ = self;
    const session = object_value.radio orelse return;
    const queue = object_value.queue;
    prune(session, queue);
    const engine = object_value.engine;
    if (engine) |value| value.quiesce();
    defer if (engine) |value| value.release();
    const pending: ?*u32 = if (engine) |value|
        (if (value.pending_source != null) &value.pending_position else null)
    else
        null;
    const holds_audio = object_value.player.sources != null;
    const cursor = queue.cursorPosition();
    var order: [max_tracked]usize = undefined;
    for (order[0..session.tracked.len], 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, order[0..session.tracked.len], session, byPosition);
    var removed = false;
    var remaining = session.tracked.len;
    while (remaining > 0) {
        remaining -= 1;
        const pick = session.tracked.items[order[remaining]];
        const position = pick.position;
        if (position <= cursor) break;
        if (holds_audio and position == queue.decodePosition()) continue;
        if (pending) |value| if (value.* == position) continue;
        try queue.removeAt(position, pending);
        forgetPicked(session, pick.recording_id);
        session.tracked.items[order[remaining]].entry_id = 0;
        removed = true;
    }
    if (removed) {
        var index: usize = 0;
        while (index < session.tracked.len) {
            if (session.tracked.items[index].entry_id == 0)
                session.tracked.orderedRemove(index)
            else
                index += 1;
        }
        if (engine) |value| value.refreshSharedRelease();
    }
}

/// Ends the session without touching the queue, joining a top-up in flight.
pub fn endSession(self: *OrcaRuntime, object_value: *PlayerObject) void {
    const session = object_value.radio orelse return;
    object_value.radio = null;
    freeSession(self, session);
}

pub fn freeSession(self: *OrcaRuntime, session: *Session) void {
    if (session.worker) |top_up| {
        self.work_registry.complete(top_up.work_handle) catch {};
        top_up.destroy();
    }
    self.allocator.destroy(session);
}

/// Control lane, immediately after `work_registry.drain()`: every top-up
/// thread has been joined and its registration freed.
pub fn releaseDrainedRadio(self: *OrcaRuntime) void {
    for (self.players.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        const session = object_value.radio orelse continue;
        const top_up = session.worker orelse continue;
        top_up.destroy();
        session.worker = null;
        session.wants_top_up = true;
    }
}

fn spawnTopUp(self: *OrcaRuntime, session: *Session) !void {
    std.debug.assert(session.worker == null);
    const library_database = try runtime.libraryDatabase(self, session.library);
    const allocator = self.allocator;
    const need = max_pending -| @min(max_pending, session.tracked.len);
    const top_up = try allocator.create(TopUp);
    errdefer allocator.destroy(top_up);

    const excluded = try allocator.alloc(i64, session.picked.len + session.disliked.len);
    errdefer allocator.free(excluded);
    for (session.picked.slice(), excluded[0..session.picked.len]) |pick, *id| id.* = pick.recording_id;
    @memcpy(excluded[session.picked.len..], session.disliked.slice());
    const artist_adjustments = try allocator.dupe(discovery.Adjustment, session.artist_adjustments.slice());
    errdefer allocator.free(artist_adjustments);
    const genre_adjustments = try allocator.dupe(discovery.Adjustment, session.genre_adjustments.slice());
    errdefer allocator.free(genre_adjustments);
    const recent_from = session.picked.len -| discovery.max_session_recent;
    const recent = try allocator.dupe(discovery.RecentPick, session.picked.slice()[recent_from..]);
    errdefer allocator.free(recent);

    const reader = try library_database.openReader();
    errdefer reader.close();
    const work_handle = try self.work_registry.begin(runtime.playerOwnerTag(session.player));
    const registration = self.work_registry.registration(work_handle) catch unreachable;
    errdefer {
        registration.finish();
        self.work_registry.complete(work_handle) catch {};
    }
    top_up.* = .{
        .allocator = allocator,
        .reader = reader,
        .write_lane = library_database.write_lane,
        .registration = registration,
        .work_handle = work_handle,
        .host_signal = &self.host_signal,
        .generation = session.generation,
        .seed = session.seed,
        .options = session.options,
        .now_s = runtime_listens.sampleTime(self).wall_s,
        .jitter_seed = session.jitter_seed,
        .excluded = excluded,
        .artist_adjustments = artist_adjustments,
        .genre_adjustments = genre_adjustments,
        .recent = recent,
        .limit = @max(need, 1),
    };
    registration.waker = .{ .context = top_up, .wake_fn = TopUp.interrupt };
    registration.thread = try std.Thread.spawn(.{}, TopUp.run, .{top_up});
    session.worker = top_up;
    session.wants_top_up = false;
    session.retry_at_ms = null;
}

/// The sampling pass's part: no SQLite, I/O or allocation. It only notes
/// that a session needs picks, or that `radio.continue` should start one.
pub fn samplePlayer(self: *OrcaRuntime, object_value: *PlayerObject) void {
    const queue = object_value.queue;
    const session = object_value.radio orelse {
        noteContinue(self, object_value);
        return;
    };
    prune(session, queue);
    if (session.worker != null or session.exhausted) return;
    if (state(session, queue) != .active) return;
    if (pendingCount(session, queue) < max_pending) session.wants_top_up = true;
}

fn noteContinue(self: *OrcaRuntime, object_value: *PlayerObject) void {
    const last_id = continueEntry(self, object_value) orelse return;
    if (object_value.radio_continue_after == last_id) return;
    object_value.radio_continue_after = last_id;
    object_value.radio_continue_wanted = true;
}

fn continueEntry(self: *OrcaRuntime, object_value: *PlayerObject) ?u64 {
    const opener = object_value.opener orelse return null;
    const library_object = self.libraries.get(opener.library) catch return null;
    if (!library_object.radio_continue) return null;
    const queue = object_value.queue;
    if (queue.repeat != .off or queue.isEmpty()) return null;
    if (object_value.player.sources == null) return null;
    if (object_value.player.state.load(.acquire) != .playing) return null;
    const last = queue.len() - 1;
    if (queue.cursorPosition() != last) return null;
    return queue.idAt(last);
}

/// Control lane, from `pump`: applies finished top-ups, starts wanted ones
/// and starts the sessions `radio.continue` asked for.
pub fn pumpRadio(self: *OrcaRuntime) void {
    if (self.state.load(.acquire) != .running) return;
    var index: usize = 0;
    while (index < self.players.slots.items.len) : (index += 1) {
        const object_value = if (self.players.slots.items[index].value) |*value| value else continue;
        const session = object_value.radio orelse {
            if (!object_value.radio_continue_wanted) continue;
            object_value.radio_continue_wanted = false;
            const wanted = continueEntry(self, object_value) orelse continue;
            if (object_value.radio_continue_after != wanted) continue;
            const opener = object_value.opener orelse continue;
            const player: PlayerHandle = .{
                .index = @intCast(index),
                .generation = self.players.slots.items[index].generation,
            };
            startSession(self, player, opener.library, .recent, .{}, true) catch {};
            continue;
        };
        if (session.worker) |top_up| {
            if (!top_up.registration.isFinished()) continue;
            self.work_registry.complete(top_up.work_handle) catch {};
            session.worker = null;
            defer top_up.destroy();
            applyTopUp(self, object_value, session, top_up);
            if (object_value.radio == null) continue;
        }
        if (!session.wants_top_up or session.worker != null) continue;
        if (session.retry_at_ms) |at| {
            if (runtime_listens.sampleTime(self).mono_ms < at) continue;
        }
        spawnTopUp(self, session) catch {
            session.retry_at_ms = runtime_listens.sampleTime(self).mono_ms + retry_delay_ms;
        };
    }
}

/// Milliseconds until a session's top-up retry is due, 0 when one is owed
/// now, or null.
pub fn radioPumpDueMs(self: *OrcaRuntime) ?u64 {
    var due: ?u64 = null;
    var now: ?i64 = null;
    for (self.players.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        if (object_value.radio_continue_wanted) return 0;
        const session = object_value.radio orelse continue;
        if (!session.wants_top_up or session.worker != null) continue;
        const at = session.retry_at_ms orelse return 0;
        const current = now orelse runtime_listens.sampleTime(self).mono_ms;
        now = current;
        const remaining: u64 = @intCast(@max(0, at - current));
        due = if (due) |value| @min(value, remaining) else remaining;
    }
    return due;
}

fn applyTopUp(self: *OrcaRuntime, object_value: *PlayerObject, session: *Session, top_up: *TopUp) void {
    if (top_up.generation != session.generation) {
        session.wants_top_up = true;
        return;
    }
    if (top_up.failure != null or top_up.picks == null) {
        session.wants_top_up = true;
        session.retry_at_ms = runtime_listens.sampleTime(self).mono_ms + retry_delay_ms;
        return;
    }
    const queue = object_value.queue;
    prune(session, queue);
    if (state(session, queue) != .active) return;
    const need = max_pending -| pendingCount(session, queue);
    if (need == 0) return;
    const picks = top_up.picks.?.items;
    if (picks.len == 0) {
        session.exhausted = true;
        if (session.continued and session.counts.picks_added == 0) endSession(self, object_value);
        return;
    }
    const take = @min(
        need,
        picks.len,
        audio.playback_queue.capacity - queue.len(),
        max_tracked - session.tracked.len,
    );
    if (take == 0) return;
    appendPicks(self, object_value, session, picks[0..take], top_up.first_genres[0..take]) catch {
        session.wants_top_up = true;
        session.retry_at_ms = runtime_listens.sampleTime(self).mono_ms + retry_delay_ms;
    };
}

fn appendPicks(
    self: *OrcaRuntime,
    object_value: *PlayerObject,
    session: *Session,
    picks: []const discovery.Pick,
    first_genres: []const ?i64,
) !void {
    var refs: [max_pending]TrackRef = undefined;
    for (picks, refs[0..picks.len]) |pick, *ref| ref.* = .{ .library = session.library, .track_id = pick.track_id };
    const engine = try runtime_queue.ensureEngine(self, session.player);
    engine.quiesce();
    defer engine.release();
    const queue = object_value.queue;
    const was_idle = object_value.player.sources == null;
    const first_new = queue.len();
    try queue.enqueue(refs[0..picks.len]);
    for (picks, first_genres, 0..) |pick, genre, offset| {
        const position: u32 = first_new + @as(u32, @intCast(offset));
        session.tracked.items[session.tracked.len] = .{
            .entry_id = queue.idAt(position).?,
            .position = position,
            .track_id = pick.track_id,
            .recording_id = pick.recording_id,
            .artist_id = pick.artist_id,
            .first_genre = genre,
            .reason = pick.reason,
        };
        session.tracked.len += 1;
        session.picked.appendDroppingOldest(.{
            .recording_id = pick.recording_id,
            .artist_id = pick.artist_id,
            .release_id = pick.release_id,
            .never_played = pick.never_played,
        });
    }
    session.counts.picks_added += @intCast(picks.len);
    if (pendingCount(session, queue) < max_pending) session.wants_top_up = true;
    if (!was_idle) {
        engine.refreshSharedRelease();
        return;
    }
    if (!session.play_on_arrival) return;
    session.play_on_arrival = false;
    engine.discardPending();
    queue.seekTo(first_new);
    try runtime_queue.loadCursor(self, object_value);
    object_value.player.play();
}

/// Where an enqueue during Radio goes: before the first pick the engine has
/// not committed to, so the user's entries play before Radio's. Null appends.
/// The caller has quiesced the engine.
pub fn userInsertAfter(object_value: *PlayerObject) ?u32 {
    const session = object_value.radio orelse return null;
    const queue = object_value.queue;
    prune(session, queue);
    const engine = object_value.engine;
    const holds_audio = object_value.player.sources != null;
    var committed = queue.cursorPosition();
    if (holds_audio) committed = @max(committed, queue.decodePosition());
    if (engine) |value| if (value.pending_source != null) {
        committed = @max(committed, value.pending_position);
    };
    var first: ?u32 = null;
    for (session.tracked.slice()) |pick| {
        if (pick.position <= committed) continue;
        first = if (first) |value| @min(value, pick.position) else pick.position;
    }
    const target = first orelse return null;
    return target - 1;
}

pub fn noteUserQueued(object_value: *PlayerObject, count: usize) void {
    const session = object_value.radio orelse return;
    session.counts.user_queued +|= @intCast(@min(count, std.math.maxInt(u32)));
}

pub const AudiblePick = struct {
    entry_id: u64,
    elapsed_ms: u64,
};

/// The audible entry and how long it has played, when a session could own
/// it. The caller has quiesced the engine.
pub fn audibleEntry(object_value: *PlayerObject) ?AudiblePick {
    if (object_value.radio == null or object_value.player.sources == null) return null;
    const entry_id = object_value.queue.idAt(object_value.queue.cursorPosition()) orelse return null;
    const format = object_value.player.format() orelse return null;
    if (format.sample_rate == 0) return null;
    return .{
        .entry_id = entry_id,
        .elapsed_ms = object_value.player.snapshot().position_frames * 1000 / format.sample_rate,
    };
}

/// After a user skip away from `left`: a Radio pick left within
/// `skip_threshold_ms` is excluded and its Artist weighed down.
pub fn noteSkip(object_value: *PlayerObject, left: AudiblePick) void {
    const session = object_value.radio orelse return;
    if (left.elapsed_ms >= skip_threshold_ms) return;
    const queue = object_value.queue;
    if (queue.idAt(queue.cursorPosition()) == left.entry_id) return;
    const index = trackedIndex(session, left.entry_id) orelse return;
    const pick = session.tracked.items[index];
    dislike(session, pick.recording_id);
    if (pick.artist_id) |artist| adjust(&session.artist_adjustments, artist, skip_artist);
    session.counts.skips += 1;
    session.generation += 1;
}

/// Before a shuffle toggle reorders the queue: the pending picks are
/// removed and picked again after it.
pub fn beforeShuffleChange(self: *OrcaRuntime, object_value: *PlayerObject) !void {
    const session = object_value.radio orelse return;
    try removePendingPicks(self, object_value);
    session.generation += 1;
    session.wants_top_up = true;
    session.exhausted = false;
}

test "a Radio preview ranks a scanned Library without a Player, and the discovery settings round-trip" {
    var owner = OrcaRuntime.init(std.testing.allocator);
    defer owner.deinit();
    const library = try owner.openLibrary(std.testing.io, "file:orca-radio-preview-runtime?mode=memory&cache=shared");
    const binding = try @import("runtime_tests.zig").addFixturesRoot(&owner, library);
    const job_handle = try owner.startLibraryScan(library, .{ .root_id = binding.root_id });
    while (true) {
        owner.reapFinishedJobs();
        const snapshot = try owner.jobSnapshotSynced(job_handle);
        if (snapshot.state == .succeeded) break;
        if (snapshot.state == .failed or snapshot.state == .cancelled) return error.ScanDidNotSucceed;
        std.Thread.yield() catch {};
    }

    try std.testing.expectEqual(discovery.Settings{}, try owner.libraryDiscoverySettings(library));
    const changed: discovery.Settings = .{ .radio_continue = false, .include_unplayed = false, .avoid_days = .none, .mix_count = .off };
    try owner.setLibraryDiscoverySettings(library, changed);
    try std.testing.expectEqual(changed, try owner.libraryDiscoverySettings(library));
    try owner.setLibraryDiscoverySettings(library, .{});

    const library_database = try runtime.libraryDatabase(&owner, library);
    var first_track = try library_database.database.prepare("SELECT min(id) FROM tracks;");
    defer first_track.deinit();
    _ = try first_track.step();
    const track_id = first_track.columnInt64(0);

    const session: RadioPreviewSession = .{ .now_s = 2_000_000_000, .seed = 7 };
    var picks = try owner.libraryRadioPreview(library, std.testing.allocator, .{ .track = track_id }, .{}, 10, session);
    defer picks.deinit();
    try std.testing.expect(picks.items.len > 0);
    for (picks.items) |pick| {
        try std.testing.expect(pick.track_id != track_id);
        try std.testing.expect(pick.reason.first != null);
    }
    var again = try owner.libraryRadioPreview(library, std.testing.allocator, .{ .track = track_id }, .{}, 10, session);
    defer again.deinit();
    try std.testing.expectEqual(picks.items.len, again.items.len);
    for (picks.items, again.items) |a, b| try std.testing.expectEqual(a.recording_id, b.recording_id);

    try std.testing.expectError(error.RadioLimitTooLarge, owner.libraryRadioPreview(library, std.testing.allocator, .loved, .{}, discovery.max_picks + 1, session));
    try std.testing.expectError(error.UnknownRadioSeed, owner.libraryRadioPreview(library, std.testing.allocator, .{ .artist = 1_000_000 }, .{}, 10, session));
}
