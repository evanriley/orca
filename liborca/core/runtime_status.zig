const std = @import("std");
const audio = @import("../audio/root.zig");
const database = @import("../database/root.zig");
const runtime = @import("runtime.zig");

const LibraryHandle = runtime.LibraryHandle;
const OrcaRuntime = runtime.OrcaRuntime;
const PlayerHandle = runtime.PlayerHandle;
const PlayerObject = runtime.PlayerObject;
const PlayerStatus = runtime.PlayerStatus;
const TrackRef = runtime.TrackRef;

/// Ramp applied to a volume change, in frames. Long enough that a slider does
/// not click, short enough to feel immediate.
const volume_ramp_frames: u32 = 512;

pub fn playerStatus(self: *OrcaRuntime, player: PlayerHandle) !PlayerStatus {
    try runtime.requireRunning(self);
    return readStatus(try self.players.get(player)).status;
}

const StatusRead = struct {
    status: PlayerStatus,
    /// The queue entry `status.track_id` came from, read once with it.
    audible: ?TrackRef,
    resolved: bool,
};

pub fn readStatus(object_value: *PlayerObject) StatusRead {
    const queue_snapshot = object_value.queue.snapshot();
    const snapshot = object_value.player.snapshot();
    const rate = object_value.player.published_sample_rate.load(.acquire);
    const frames = object_value.player.published_frame_count.load(.acquire);
    // The serial leaves an entry, and a hard load moves the cursor, before the
    // next entry's figures are published, so both are read after them and
    // never pair an entry with its successor's figures.
    const entry = readAudibleEntry(object_value);
    const idle = if (entry) |value| value.entry_serial == 0 else false;
    const position: ?u32 = if (idle) object_value.queue.cursorPosition() else if (entry) |value| value.position else null;
    const current: ?TrackRef = if (idle) object_value.queue.refAt(position.?) else if (entry) |value| value.track else null;
    const entry_serial = if (entry) |value| value.entry_serial else object_value.player.audible_entry_serial.load(.acquire);
    const resumed = object_value.persistence.resumed;
    return .{
        .audible = current,
        .resolved = entry != null,
        .status = .{
            .transport = snapshot.state,
            .repeat = queue_snapshot.repeat,
            .shuffle = queue_snapshot.shuffle,
            .epoch = snapshot.epoch,
            .position_ms = if (rate == 0) 0 else snapshot.position_frames * 1000 / rate,
            .duration_ms = if (rate == 0) 0 else frames * 1000 / rate,
            .track_id = if (current) |ref| ref.track_id else null,
            .entry_serial = entry_serial,
            .queue_length = queue_snapshot.entries,
            .queue_index = position orelse queue_snapshot.cursor,
            .volume = object_value.gain.linear.load(.acquire),
            .last_failure = if (object_value.player.open_failure.read()) |failure| .{
                .track_id = failure.track_id,
                .reason = .of(failure.err),
            } else null,
            .resumed_from_ms = if (resumed) |value|
                (if (entry_serial != 0 and value.entry_serial == entry_serial) value.position_ms else null)
            else
                null,
        },
    };
}

pub const AudibleEntry = struct {
    entry_serial: u32,
    position: ?u32,
    track: ?TrackRef,
    drained: bool,
};

/// Resolves the audible entry through the serial the engine publishes, never
/// the cursor: across a gapless transition the engine moves the cursor after
/// the serial, so a cursor read can still name the entry before it. A serial
/// that moves on while it is being resolved is retried, then given up as null.
pub fn readAudibleEntry(object_value: *PlayerObject) ?AudibleEntry {
    const queue = object_value.queue;
    for (0..3) |_| {
        const entry_serial = object_value.player.audible_entry_serial.load(.acquire);
        const position = queue.positionForSerial(entry_serial);
        const track = if (position) |value| queue.refAt(value) else null;
        const drained = object_value.player.drained.load(.acquire);
        if (object_value.player.audible_entry_serial.load(.acquire) != entry_serial) continue;
        return .{ .entry_serial = entry_serial, .position = position, .track = track, .drained = drained };
    }
    return null;
}

pub fn playerQueuePage(
    self: *OrcaRuntime,
    player: PlayerHandle,
    offset: u32,
    output: []TrackRef,
) !usize {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    var count: usize = 0;
    while (count < output.len) : (count += 1) {
        output[count] = object_value.queue.refAt(offset + @as(u32, @intCast(count))) orelse
            break;
    }
    return count;
}

pub const QueueTrack = struct {
    position: u32,
    id: i64,
    track: ?database.TrackSummary,

    pub fn deinit(self: QueueTrack, allocator: std.mem.Allocator) void {
        if (self.track) |track| track.deinit(allocator);
    }
};

pub const QueueTrackPage = struct {
    allocator: std.mem.Allocator,
    items: []QueueTrack,

    pub fn deinit(self: QueueTrackPage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

pub fn playerQueueTracks(
    self: *OrcaRuntime,
    player: PlayerHandle,
    allocator: std.mem.Allocator,
    offset: u32,
    limit: u32,
) !QueueTrackPage {
    try runtime.requireRunning(self);
    if (limit == 0 or limit > database.repository.max_page)
        return error.PageOutOfRange;
    const object_value = try self.players.get(player);
    const opener = object_value.opener orelse return error.PlayerHasNoLibrary;
    const library = opener.library;
    const library_database = try runtime.libraryDatabase(self, library);

    var rows: std.ArrayList(QueueTrack) = .empty;
    errdefer {
        for (rows.items) |item| item.deinit(allocator);
        rows.deinit(allocator);
    }
    var index: u32 = 0;
    while (index < limit) : (index += 1) {
        const position = std.math.add(u32, offset, index) catch break;
        const ref = object_value.queue.refAt(position) orelse break;
        // An entry whose Track was removed from the Library keeps its row, with
        // no summary, so row `n` stays queue position `offset + n`.
        const track = try library_database.tracks.byId(allocator, ref.track_id);
        errdefer if (track) |summary| summary.deinit(allocator);
        try rows.append(allocator, .{ .position = position, .id = ref.track_id, .track = track });
    }
    return .{ .allocator = allocator, .items = try rows.toOwnedSlice(allocator) };
}

pub fn playerLibrary(self: *OrcaRuntime, player: PlayerHandle) !?LibraryHandle {
    try runtime.requireRunning(self);
    const opener = (try self.players.get(player)).opener orelse return null;
    return opener.library;
}

pub fn playerSetVolume(
    self: *OrcaRuntime,
    player: PlayerHandle,
    linear: f32,
) !void {
    try runtime.requireRunning(self);
    if (!std.math.isFinite(linear) or linear < 0 or linear > 4) return error.InvalidVolume;
    (try self.players.get(player)).gain.setLinear(linear, volume_ramp_frames);
}

pub fn playerVolume(self: *OrcaRuntime, player: PlayerHandle) !f32 {
    try runtime.requireRunning(self);
    return (try self.players.get(player)).gain.linear.load(.acquire);
}

pub fn playerSetReplayGainMode(
    self: *OrcaRuntime,
    player: PlayerHandle,
    mode: audio.processing.ReplayGainMode,
) !void {
    try runtime.requireRunning(self);
    (try self.players.get(player)).player.updateReplayGainSettings(.mode, mode);
}

pub fn playerReplayGainMode(
    self: *OrcaRuntime,
    player: PlayerHandle,
) !audio.processing.ReplayGainMode {
    try runtime.requireRunning(self);
    return (try self.players.get(player)).player.replayGainMode();
}

pub fn playerSetReplayGainPreamp(self: *OrcaRuntime, player: PlayerHandle, decibels: f32) !void {
    try runtime.requireRunning(self);
    (try self.players.get(player)).player.updateReplayGainSettings(
        .preamp_db,
        audio.processing.ReplayGainSettings.clampPreamp(decibels),
    );
}

pub fn playerSetReplayGainFallback(
    self: *OrcaRuntime,
    player: PlayerHandle,
    fallback: audio.processing.UntaggedFallback,
) !void {
    try runtime.requireRunning(self);
    (try self.players.get(player)).player.updateReplayGainSettings(.fallback, fallback);
}

pub fn playerSetPeakProtection(self: *OrcaRuntime, player: PlayerHandle, enabled: bool) !void {
    try runtime.requireRunning(self);
    (try self.players.get(player)).player.updateReplayGainSettings(.peak_protection, enabled);
}

pub fn playerReplayGainSettings(
    self: *OrcaRuntime,
    player: PlayerHandle,
) !audio.processing.ReplayGainSettings {
    try runtime.requireRunning(self);
    return (try self.players.get(player)).player.replayGainSettings();
}

pub fn playerSetStopAfterCurrent(self: *OrcaRuntime, player: PlayerHandle, enabled: bool) !void {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    const engine = object_value.engine orelse {
        object_value.player.stop_after_current.store(enabled, .release);
        return;
    };
    engine.quiesce();
    defer engine.release();
    engine.setStopAfterCurrent(enabled);
}

pub fn playerStopAfterCurrent(self: *OrcaRuntime, player: PlayerHandle) !bool {
    try runtime.requireRunning(self);
    return (try self.players.get(player)).player.stop_after_current.load(.acquire);
}

pub fn playerEffectiveGain(self: *OrcaRuntime, player: PlayerHandle) !f32 {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    return object_value.gain.linear.load(.acquire) *
        object_value.player.effectiveReplayGain();
}

pub fn playerSetEqualizer(
    self: *OrcaRuntime,
    player: PlayerHandle,
    equalizer: ?audio.dsp.Equalizer,
) !void {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    const engine = object_value.engine;
    if (engine) |value| value.quiesce();
    defer if (engine) |value| value.release();
    try object_value.dsp.setEqualizer(equalizer);
}

pub fn playerEqualizer(self: *OrcaRuntime, player: PlayerHandle) !?audio.dsp.Equalizer {
    try runtime.requireRunning(self);
    return (try self.players.get(player)).dsp.settings.equalizer;
}

pub fn playerSetParametricEqualizer(
    self: *OrcaRuntime,
    player: PlayerHandle,
    equalizer: ?audio.dsp.ParametricEqualizer,
) !void {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    const engine = object_value.engine;
    if (engine) |value| value.quiesce();
    defer if (engine) |value| value.release();
    try object_value.dsp.setParametricEqualizer(equalizer);
}

pub fn playerParametricEqualizer(self: *OrcaRuntime, player: PlayerHandle) !?audio.dsp.ParametricEqualizer {
    try runtime.requireRunning(self);
    return (try self.players.get(player)).dsp.settings.parametric;
}

pub fn playerSetCrossfeed(
    self: *OrcaRuntime,
    player: PlayerHandle,
    amount: ?f32,
) !void {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    const engine = object_value.engine;
    if (engine) |value| value.quiesce();
    defer if (engine) |value| value.release();
    try object_value.dsp.setCrossfeed(amount);
}

pub fn playerCrossfeed(self: *OrcaRuntime, player: PlayerHandle) !?f32 {
    try runtime.requireRunning(self);
    return (try self.players.get(player)).dsp.settings.crossfeed;
}

pub fn playerSignalPath(self: *OrcaRuntime, player: PlayerHandle) !audio.dsp.SignalPath {
    try runtime.requireRunning(self);
    const object_value = try self.players.get(player);
    const engine = object_value.engine;
    if (engine) |value| value.quiesce();
    defer if (engine) |value| value.release();
    const audible = object_value.player.audibleSource();
    const corrections = object_value.player.audibleReplayGain();
    const settings = object_value.player.replayGainSettings();
    const applied = corrections.applied(settings);
    var path = audio.dsp.SignalPath.describe(.{
        .source = if (audible) |value| value.format else null,
        .source_declared = if (audible) |value| value.declared else false,
        .codec = if (audible) |value| value.codec else null,
        .replay_gain = applied.multiplier,
        .replay_gain_source = applied.source,
        .replay_gain_track = if (corrections.track != null) track: {
            var track_settings = settings;
            track_settings.mode = .track;
            break :track corrections.applied(track_settings).multiplier;
        } else null,
        .replay_gain_settings = settings,
        .replay_gain_limited = applied.limited,
        .equalizer = object_value.dsp.settings.equalizer,
        .parametric = object_value.dsp.settings.parametric,
        .crossfeed = object_value.dsp.settings.crossfeed,
        .volume = if (engine != null)
            object_value.gain.applied()
        else
            object_value.gain.linear.load(.acquire),
        .output = if (engine) |value| value.outputFormat() else null,
        .device_rate = if (engine) |value| value.deviceRate() else null,
        .device_quantum_frames = if (engine) |value| value.deviceQuantum() else null,
        .device_format = if (engine) |value| value.deviceFormat() else null,
    });
    if (engine) |value| path.output_kind = value.outputDeviceKind();
    return path;
}

pub fn playerSeekMs(self: *OrcaRuntime, player: PlayerHandle, ms: u64) !u32 {
    try runtime.requireRunning(self);
    const rate = (try self.players.get(player)).player.published_sample_rate.load(.acquire);
    if (rate == 0) return error.PlayerHasNoSource;
    return self.seekPlayer(player, ms * rate / 1000);
}
