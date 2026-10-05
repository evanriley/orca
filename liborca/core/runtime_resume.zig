const std = @import("std");
const database = @import("../database/root.zig");
const listen_worker = @import("listen_worker.zig");
const runtime = @import("runtime.zig");
const runtime_listens = @import("runtime_listens.zig");
const runtime_queue = @import("runtime_queue.zig");
const runtime_status = @import("runtime_status.zig");

const LibraryHandle = runtime.LibraryHandle;
const OrcaRuntime = runtime.OrcaRuntime;
const PlayerHandle = runtime.PlayerHandle;
const PlayerObject = runtime.PlayerObject;
const RepeatMode = runtime.RepeatMode;
const TrackRef = runtime.TrackRef;
const SampleTime = listen_worker.SampleTime;

/// How long a Player whose state is saved plays between saves.
pub const save_interval_ms: i64 = 30 * std.time.ms_per_s;

/// Tracks longer than this keep where they were left until the host sets
/// another threshold.
pub const default_long_track_ms: u64 = 20 * std.time.ms_per_min;

const finished_capacity = 4;

pub const RestoreMode = enum(u8) { paused, playing, none };

pub const RestoreOutcome = struct {
    /// Queue entries restored.
    entries: u32,
    /// Playback position of the entry the queue resumes at.
    index: u32,
    /// Where in that entry playback resumes; zero from its start.
    position_ms: u64,
    /// Saved entries left out because neither their Track nor another Track
    /// of their Recording is left.
    skipped_missing: u32,
};

/// A Player's saving and resuming, kept beside it on the control lane.
pub const State = struct {
    /// Set once the host saves or restores: the Library this Player's queue
    /// and position are saved into while it plays and at shutdown.
    saves_into: ?LibraryHandle = null,
    last_save_ms: ?i64 = null,
    saved_while_playing: bool = false,
    long_track_ms: ?u64 = default_long_track_ms,
    /// Tracks that played to their end since positions were last written,
    /// noted where no SQLite may run.
    finished: [finished_capacity]TrackRef = undefined,
    finished_count: u8 = 0,
    resumed: ?Resumed = null,
};

pub const Resumed = struct {
    entry_serial: u32,
    position_ms: u64,
};

pub fn playerSaveState(self: *OrcaRuntime, player: PlayerHandle, library: LibraryHandle) !void {
    try runtime.requireRunning(self);
    try runtime_queue.requireBoundLibrary(self, player, library);
    const object_value = try self.players.get(player);
    object_value.persistence.saves_into = library;
    try saveInto(self, object_value, library, runtime_listens.sampleTime(self));
}

pub fn playerRestoreState(
    self: *OrcaRuntime,
    player: PlayerHandle,
    library: LibraryHandle,
    mode: RestoreMode,
) !RestoreOutcome {
    try runtime.requireRunning(self);
    try runtime_queue.requireBoundLibrary(self, player, library);
    const object_value = try self.players.get(player);
    object_value.persistence.saves_into = library;
    object_value.persistence.last_save_ms = runtime_listens.sampleTime(self).mono_ms;
    object_value.persistence.saved_while_playing = false;
    if (mode == .none) return .{ .entries = 0, .index = 0, .position_ms = 0, .skipped_missing = 0 };

    const library_database = try runtime.libraryDatabase(self, library);
    const saved = try library_database.player_state.load(self.allocator) orelse
        return .{ .entries = 0, .index = 0, .position_ms = 0, .skipped_missing = 0 };
    defer saved.deinit();
    const plan = try Plan.init(self.allocator, saved, library);
    defer plan.deinit(self.allocator);
    if (plan.refs.len == 0)
        return .{ .entries = 0, .index = 0, .position_ms = 0, .skipped_missing = plan.skipped };

    rememberAudible(self, object_value) catch {};
    const engine = try runtime_queue.ensureEngine(self, player);
    engine.quiesce();
    defer engine.release();
    engine.discardPending();
    runtime_queue.endAudibleEntry(self, object_value, .replaced);
    try object_value.queue.restore(plan.refs, plan.order, plan.cursor);
    object_value.queue.setRepeat(plan.repeat);
    var outcome: RestoreOutcome = .{
        .entries = @intCast(plan.refs.len),
        .index = plan.cursor,
        .position_ms = 0,
        .skipped_missing = plan.skipped,
    };
    runtime_queue.loadCursor(self, object_value) catch {
        object_value.player.stop();
        object_value.player.releaseSources();
        return outcome;
    };
    if (plan.position_ms) |position_ms| _ = resumeAt(object_value, position_ms);
    if (object_value.persistence.resumed) |resumed| outcome.position_ms = resumed.position_ms;
    switch (mode) {
        .paused => object_value.player.pause(),
        .playing => object_value.player.play(),
        .none => unreachable,
    }
    return outcome;
}

pub fn playerSetLongTrackMemory(self: *OrcaRuntime, player: PlayerHandle, threshold_ms: ?u64) !void {
    try runtime.requireRunning(self);
    const persistence = &(try self.players.get(player)).persistence;
    persistence.long_track_ms = threshold_ms;
    if (threshold_ms == null) persistence.finished_count = 0;
}

/// The saved queue in list order and, while shuffled, its playback order,
/// with the entries that resolve to no Track left out.
const Plan = struct {
    refs: []TrackRef,
    order: ?[]u32,
    cursor: u32,
    position_ms: ?u64,
    repeat: RepeatMode,
    skipped: u32,

    fn init(allocator: std.mem.Allocator, saved: database.repository.RestoredPlayerState, library: LibraryHandle) !Plan {
        const entries = saved.entries;
        const list_index = try allocator.alloc(u32, entries.len);
        defer allocator.free(list_index);
        const shuffled = saved.state.shuffle and try isPermutation(allocator, entries);
        for (entries, list_index, 0..) |entry, *index, position|
            index.* = if (shuffled) entry.entry else @intCast(position);

        const tracks = try allocator.alloc(?i64, entries.len);
        defer allocator.free(tracks);
        for (entries, list_index) |entry, index| tracks[index] = entry.track_id;
        const rank = try allocator.alloc(u32, entries.len);
        defer allocator.free(rank);
        var kept: u32 = 0;
        for (tracks, rank) |track, *value| {
            value.* = kept;
            if (track != null) kept += 1;
        }

        const refs = try allocator.alloc(TrackRef, kept);
        errdefer allocator.free(refs);
        for (tracks, rank) |track, value| {
            if (track) |track_id| refs[value] = .{ .library = library, .track_id = track_id };
        }
        const order: ?[]u32 = if (shuffled) try allocator.alloc(u32, kept) else null;
        var cursor: u32 = 0;
        var position_ms: ?u64 = null;
        var position: u32 = 0;
        for (entries, list_index, 0..) |entry, index, saved_position| {
            if (saved_position == saved.state.cursor) {
                cursor = position;
                if (entry.track_id != null and saved.state.position_ms != 0) position_ms = saved.state.position_ms;
            }
            if (entry.track_id == null) continue;
            if (order) |values| values[position] = rank[index];
            position += 1;
        }
        if (kept != 0 and cursor >= kept) cursor = kept - 1;
        return .{
            .refs = refs,
            .order = order,
            .cursor = cursor,
            .position_ms = position_ms,
            .repeat = std.enums.fromInt(RepeatMode, saved.state.repeat) orelse .off,
            .skipped = @intCast(entries.len - kept),
        };
    }

    fn deinit(self: Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.refs);
        if (self.order) |values| allocator.free(values);
    }

    fn isPermutation(allocator: std.mem.Allocator, entries: []const database.repository.RestoredQueueEntry) !bool {
        var seen = try std.bit_set.Dynamic.initEmpty(allocator, entries.len);
        defer seen.deinit(allocator);
        for (entries) |entry| {
            if (entry.entry >= entries.len or seen.isSet(entry.entry)) return false;
            seen.set(entry.entry);
        }
        return true;
    }
};

fn isPlaying(object_value: *const PlayerObject) bool {
    return object_value.player.state.load(.acquire) == .playing and
        !object_value.player.drained.load(.acquire);
}

/// Writes the Player's queue, entries from other Libraries left out, its
/// position and modes, after the positions `rememberAudible` keeps.
fn saveInto(self: *OrcaRuntime, object_value: *PlayerObject, library: LibraryHandle, now: SampleTime) !void {
    const persistence = &object_value.persistence;
    persistence.last_save_ms = now.mono_ms;
    persistence.saved_while_playing = isPlaying(object_value);
    const library_database = (try self.libraries.get(library)).database orelse
        return error.LibraryHasNoDatabase;
    try rememberAudible(self, object_value);

    const read = runtime_status.readStatus(object_value);
    const queue = object_value.queue;
    const list = queue.entries.items;
    const rank = try self.allocator.alloc(?u32, list.len);
    defer self.allocator.free(rank);
    var kept: u32 = 0;
    for (list, rank) |ref, *value| {
        value.* = if (ref.library.eql(library)) kept else null;
        if (value.* != null) kept += 1;
    }
    const entries = try self.allocator.alloc(database.repository.SavedQueueEntry, kept);
    defer self.allocator.free(entries);
    var count: u32 = 0;
    var cursor: u32 = 0;
    var cursor_kept = false;
    var position: u32 = 0;
    while (position < list.len) : (position += 1) {
        const index = queue.entryIndex(position) orelse break;
        if (position == read.status.queue_index) {
            cursor = count;
            cursor_kept = rank[index] != null;
        }
        const entry = rank[index] orelse continue;
        entries[count] = .{ .entry = entry, .track_id = list[index].track_id };
        count += 1;
    }
    if (kept != 0 and cursor >= kept) cursor = kept - 1;
    const heard = cursor_kept and read.status.entry_serial != 0 and !object_value.player.drained.load(.acquire);
    try library_database.player_state.save(.{
        .cursor = cursor,
        .position_ms = if (heard) read.status.position_ms else 0,
        .repeat = @backingInt(read.status.repeat),
        .shuffle = read.status.shuffle,
    }, entries[0..count], now.wall_s);
}

/// Forgets the positions of long Tracks that played to their end, then keeps
/// where the audible one is when it is long enough and still playing. Runs
/// on pause, seek, a change of track and each save; never from the render
/// callback or the listen sample.
pub fn rememberAudible(self: *OrcaRuntime, object_value: *PlayerObject) !void {
    const opener = object_value.opener orelse return;
    const library_database = (try self.libraries.get(opener.library)).database orelse return;
    runtime_queue.observeQueueHistory(object_value, runtime_queue.historyNowMs(self));
    try forgetFinished(object_value, library_database, opener.library);
    const threshold = object_value.persistence.long_track_ms orelse return;
    if (object_value.player.drained.load(.acquire)) return;
    const read = runtime_status.readStatus(object_value);
    if (read.status.entry_serial == 0) return;
    const ref = read.audible orelse return;
    if (!ref.library.eql(opener.library) or read.status.duration_ms <= threshold) return;
    try library_database.player_state.rememberTrackPosition(ref.track_id, read.status.position_ms);
}

fn forgetFinished(object_value: *PlayerObject, library_database: *database.LibraryDatabase, library: LibraryHandle) !void {
    const persistence = &object_value.persistence;
    const finished = persistence.finished[0..persistence.finished_count];
    persistence.finished_count = 0;
    for (finished) |ref| {
        if (ref.library.eql(library)) try library_database.player_state.forgetTrackPosition(ref.track_id);
    }
}

/// Called wherever queue history records an entry as finished.
pub fn noteFinished(persistence: *State, track: TrackRef) void {
    if (persistence.long_track_ms == null) return;
    if (persistence.finished_count == finished_capacity) {
        std.mem.copyForwards(TrackRef, persistence.finished[0 .. finished_capacity - 1], persistence.finished[1..]);
        persistence.finished_count -= 1;
    }
    persistence.finished[persistence.finished_count] = track;
    persistence.finished_count += 1;
}

/// After a hard load of `ref`, under the quiesce that load holds: resumes a
/// long Track where it was left.
pub fn resumeRemembered(self: *OrcaRuntime, object_value: *PlayerObject, ref: TrackRef) void {
    object_value.persistence.resumed = null;
    const threshold = object_value.persistence.long_track_ms orelse return;
    const opener = object_value.opener orelse return;
    if (!ref.library.eql(opener.library)) return;
    const format = object_value.player.format() orelse return;
    const frames = object_value.player.frameCount() orelse return;
    if (format.sample_rate == 0 or frames * 1000 / format.sample_rate <= threshold) return;
    const library_object = self.libraries.get(ref.library) catch return;
    const library_database = library_object.database orelse return;
    const position_ms = (library_database.player_state.trackPosition(ref.track_id) catch return) orelse return;
    _ = resumeAt(object_value, position_ms);
}

/// Seeks the entry just hard-loaded and reports it as resumed. A position
/// past its end leaves it at the start.
fn resumeAt(object_value: *PlayerObject, position_ms: u64) ?u64 {
    const player = object_value.player;
    const format = player.format() orelse return null;
    const frames = player.frameCount() orelse return null;
    const scaled = std.math.mul(u64, position_ms, format.sample_rate) catch return null;
    const frame = std.math.divCeil(u64, scaled, std.time.ms_per_s) catch return null;
    if (frame == 0 or frame >= frames) return null;
    _ = player.seek(frame) catch return null;
    object_value.persistence.resumed = .{
        .entry_serial = player.audible_entry_serial.load(.acquire),
        .position_ms = position_ms,
    };
    return position_ms;
}

/// The host's pump: forgets finished long Tracks, and saves each Player that
/// saves its state once `save_interval_ms` has passed while it played.
pub fn pumpResume(self: *OrcaRuntime) void {
    if (self.state.load(.acquire) != .running) return;
    var now: ?SampleTime = null;
    for (self.players.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        const persistence = &object_value.persistence;
        if (persistence.finished_count != 0) forgetFinishedNow(self, object_value);
        const library = persistence.saves_into orelse continue;
        const time = now orelse runtime_listens.sampleTime(self);
        now = time;
        if (saveDelayMs(object_value, time.mono_ms) != 0) continue;
        saveInto(self, object_value, library, time) catch {};
    }
}

fn forgetFinishedNow(self: *OrcaRuntime, object_value: *PlayerObject) void {
    defer object_value.persistence.finished_count = 0;
    const opener = object_value.opener orelse return;
    const library_object = self.libraries.get(opener.library) catch return;
    const library_database = library_object.database orelse return;
    forgetFinished(object_value, library_database, opener.library) catch {};
}

/// Milliseconds until `pumpResume` has a save or a finished Track to write,
/// or null while it has none.
pub fn resumePumpDueMs(self: *OrcaRuntime) ?u64 {
    var due: ?u64 = null;
    var now_ms: ?i64 = null;
    for (self.players.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        if (object_value.persistence.finished_count != 0) return 0;
        if (object_value.persistence.saves_into == null) continue;
        const now = now_ms orelse runtime_listens.sampleTime(self).mono_ms;
        now_ms = now;
        const delay = saveDelayMs(object_value, now) orelse continue;
        due = if (due) |current| @min(current, delay) else delay;
    }
    return due;
}

fn saveDelayMs(object_value: *const PlayerObject, now_ms: i64) ?u64 {
    const persistence = object_value.persistence;
    if (persistence.saves_into == null) return null;
    if (!isPlaying(object_value) and !persistence.saved_while_playing) return null;
    const last = persistence.last_save_ms orelse return 0;
    return @intCast(std.math.clamp(save_interval_ms - (now_ms - last), 0, save_interval_ms));
}

/// Before a Player stops resolving through its Library: saves it there when
/// it saves its state, keeps where a long Track was left, and stops saving.
pub fn leaveLibrary(self: *OrcaRuntime, object_value: *PlayerObject) void {
    leaveLibraryAt(self, object_value, runtime_listens.sampleTime(self));
}

fn leaveLibraryAt(self: *OrcaRuntime, object_value: *PlayerObject, now: SampleTime) void {
    const persistence = &object_value.persistence;
    if (persistence.saves_into) |library| {
        saveInto(self, object_value, library, now) catch {};
    } else {
        rememberAudible(self, object_value) catch {};
    }
    persistence.saves_into = null;
    persistence.last_save_ms = null;
    persistence.saved_while_playing = false;
}

/// Shutdown, once every worker is joined and before any Player is freed, so
/// the write lane is free and each queue is still whole.
pub fn saveAtShutdown(self: *OrcaRuntime) void {
    const now = runtime_listens.sampleTime(self);
    for (self.players.slots.items) |*slot| {
        const object_value = if (slot.value) |*value| value else continue;
        leaveLibraryAt(self, object_value, now);
    }
}
