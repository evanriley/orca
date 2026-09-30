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
};

pub fn readStatus(object_value: *PlayerObject) StatusRead {
    // The engine stores the cursor after the figures it describes, so it is read first.
    const queue_snapshot = object_value.queue.snapshot();
    const current = object_value.queue.refAt(queue_snapshot.cursor);
    const snapshot = object_value.player.snapshot();
    const rate = object_value.player.published_sample_rate.load(.acquire);
    const frames = object_value.player.published_frame_count.load(.acquire);
    return .{
        .audible = current,
        .status = .{
            .transport = snapshot.state,
            .repeat = queue_snapshot.repeat,
            .shuffle = queue_snapshot.shuffle,
            .epoch = snapshot.epoch,
            .position_ms = if (rate == 0) 0 else snapshot.position_frames * 1000 / rate,
            .duration_ms = if (rate == 0) 0 else frames * 1000 / rate,
            .track_id = if (current) |ref| ref.track_id else null,
            .entry_serial = object_value.player.audible_entry_serial.load(.acquire),
            .queue_length = queue_snapshot.entries,
            .queue_index = queue_snapshot.cursor,
            .volume = object_value.gain.linear.load(.acquire),
        },
    };
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

pub fn playerQueueTracks(
    self: *OrcaRuntime,
    player: PlayerHandle,
    allocator: std.mem.Allocator,
    offset: u32,
    limit: u32,
) !database.TrackPage {
    try runtime.requireRunning(self);
    if (limit == 0 or limit > database.repository.max_page)
        return error.PageOutOfRange;
    const object_value = try self.players.get(player);
    const opener = object_value.opener orelse return error.PlayerHasNoLibrary;
    const library = opener.library;
    const library_database = try runtime.libraryDatabase(self, library);

    var rows: std.ArrayList(database.TrackSummary) = .empty;
    errdefer {
        for (rows.items) |item| item.deinit(allocator);
        rows.deinit(allocator);
    }
    var index: u32 = 0;
    while (index < limit) : (index += 1) {
        const ref = object_value.queue.refAt(offset + index) orelse break;
        // A queue entry whose Track has since been removed keeps its place
        // rather than silently shortening the queue the host is showing.
        const summary = try library_database.tracks.byId(allocator, ref.track_id) orelse
            continue;
        try rows.append(allocator, summary);
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
    (try self.players.get(player)).player.replay_gain_mode.store(mode, .release);
}

pub fn playerReplayGainMode(
    self: *OrcaRuntime,
    player: PlayerHandle,
) !audio.processing.ReplayGainMode {
    try runtime.requireRunning(self);
    return (try self.players.get(player)).player.replay_gain_mode.load(.acquire);
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
    return .describe(.{
        .source = if (audible) |value| value.format else null,
        .source_declared = if (audible) |value| value.declared else false,
        .codec = if (audible) |value| value.codec else null,
        .replay_gain = object_value.player.effectiveReplayGain(),
        .equalizer = object_value.dsp.settings.equalizer,
        .crossfeed = object_value.dsp.settings.crossfeed,
        .volume = if (engine != null)
            object_value.gain.applied()
        else
            object_value.gain.linear.load(.acquire),
        .output = if (engine) |value| value.outputFormat() else null,
        .device_rate = if (engine) |value| value.deviceRate() else null,
    });
}

pub fn playerSeekMs(self: *OrcaRuntime, player: PlayerHandle, ms: u64) !u32 {
    try runtime.requireRunning(self);
    const rate = (try self.players.get(player)).player.published_sample_rate.load(.acquire);
    if (rate == 0) return error.PlayerHasNoSource;
    return self.seekPlayer(player, ms * rate / 1000);
}
