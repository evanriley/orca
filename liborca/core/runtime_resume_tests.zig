const std = @import("std");
const audio = @import("../audio/root.zig");
const database = @import("../database/root.zig");
const network = @import("../network/root.zig");
const runtime_module = @import("runtime.zig");
const runtime_provider_tests = @import("runtime_provider_tests.zig");
const runtime_tests = @import("runtime_tests.zig");

const LibraryHandle = runtime_module.LibraryHandle;
const OrcaRuntime = runtime_module.OrcaRuntime;
const PlayerHandle = runtime_module.PlayerHandle;
const ZoneHandle = runtime_module.ZoneHandle;

const io = std.testing.io;
const rate = 11_025;
const track_frames = 4 * rate;
const wall_base_ms = 1_800_000_000_000;

fn framesAt(ms: u64) u64 {
    return ms * rate / std.time.ms_per_s;
}

/// Three four-second silent Tracks scanned into a Library, a Player bound to
/// it and a Zone on the test backend.
const Rig = struct {
    backend: audio.output.TestBackend,
    runtime: OrcaRuntime,
    clock: network.testing.TestClock = .{ .wall_offset_ms = wall_base_ms },
    temporary: std.testing.TmpDir,
    library: LibraryHandle = undefined,
    player: PlayerHandle = undefined,
    zone: ZoneHandle = undefined,
    ids: [3]i64 = undefined,

    fn init(self: *Rig, uri: [:0]const u8) !void {
        self.* = .{
            .backend = .{ .allocator = std.testing.allocator },
            .runtime = .init(std.testing.allocator),
            .temporary = std.testing.tmpDir(.{}),
        };
        self.runtime.setOutputFactory(self.backend.factory());
        self.runtime.listen_hooks.sample_clock = runtime_provider_tests.sampleClock(&self.clock);
        for ([_][]const u8{ "a.wav", "b.wav", "c.wav" }) |name|
            try runtime_provider_tests.writeSilentWave(self.temporary.dir, name, track_frames);
        self.library = try runtime_tests.scannedTempFolder(&self.runtime, &self.temporary, uri);
        const ids = try runtime_tests.allTrackIds(&self.runtime, self.library);
        defer std.testing.allocator.free(ids);
        try std.testing.expectEqual(@as(usize, 3), ids.len);
        @memcpy(&self.ids, ids);
        self.player = try self.newPlayer();
    }

    fn newPlayer(self: *Rig) !PlayerHandle {
        const player = try self.runtime.createPlayer();
        try self.runtime.playerBindLibrary(player, self.library, io);
        return player;
    }

    fn startOutput(self: *Rig) !*audio.output.TestBackend.Stream {
        self.zone = try self.runtime.createZone();
        try self.runtime.attachZone(self.zone, self.player);
        try self.runtime.zoneRequestOutput(self.zone, 0);
        var deadline: runtime_tests.TestDeadline = .init(5_000);
        while (try self.runtime.zoneOutputState(self.zone) != .active and deadline.tick()) {}
        return self.backend.liveStream() orelse error.OutputNeverOpened;
    }

    fn deinit(self: *Rig) void {
        self.runtime.deinit();
        self.backend.deinit();
        self.temporary.cleanup();
    }

    fn libraryDatabase(self: *Rig) !*database.LibraryDatabase {
        return runtime_module.libraryDatabase(&self.runtime, self.library);
    }
};

test "shutdown saves a playing Player's queue and position before any Player is torn down" {
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const path = try runtime_tests.tempDatabasePath(&data);
    defer std.testing.allocator.free(path);
    var rig: Rig = undefined;
    try rig.init(path);
    var running = true;
    defer if (running) rig.deinit();

    try rig.runtime.playerPlayTracksBound(rig.player, rig.library, &rig.ids, 1);
    try rig.runtime.playerSetRepeat(rig.player, .all);
    _ = try rig.startOutput();
    try rig.runtime.playerSaveState(rig.player, rig.library);
    _ = try rig.runtime.seekPlayer(rig.player, framesAt(1_500));
    rig.clock.advance(10_000);
    var roots = try rig.runtime.libraryRootPage(rig.library, 1, 0);
    defer roots.deinit();
    _ = try rig.runtime.startLibraryScan(rig.library, .{ .root_id = roots.items[0].id });
    try std.testing.expectEqual(audio.player.TransportState.playing, (try rig.runtime.playerStatus(rig.player)).transport);

    running = false;
    rig.deinit();
    var reopened = try database.LibraryDatabase.open(std.testing.allocator, io, path);
    defer reopened.close();
    const saved = (try reopened.player_state.load(std.testing.allocator)).?;
    defer saved.deinit();
    try std.testing.expectEqual(@as(i64, (wall_base_ms + 10_000) / 1000), saved.saved_at);
    try std.testing.expectEqual(@as(u32, 1), saved.state.cursor);
    try std.testing.expectEqual(@as(u64, 1_499), saved.state.position_ms);
    try std.testing.expectEqual(@backingInt(runtime_module.RepeatMode.all), saved.state.repeat);
    try std.testing.expect(!saved.state.shuffle);
    try std.testing.expectEqual(@as(usize, 3), saved.entries.len);
    for (saved.entries, rig.ids, 0..) |entry, track_id, index| {
        try std.testing.expectEqual(@as(u32, @intCast(index)), entry.entry);
        try std.testing.expectEqual(@as(?i64, track_id), entry.track_id);
    }
}

test "a Player whose state the host never saved or restored leaves no saved queue at shutdown" {
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const path = try runtime_tests.tempDatabasePath(&data);
    defer std.testing.allocator.free(path);
    var rig: Rig = undefined;
    try rig.init(path);
    var running = true;
    defer if (running) rig.deinit();
    try rig.runtime.playerPlayTracksBound(rig.player, rig.library, &rig.ids, 0);
    _ = try rig.startOutput();

    running = false;
    rig.deinit();
    var reopened = try database.LibraryDatabase.open(std.testing.allocator, io, path);
    defer reopened.close();
    try std.testing.expectEqual(null, try reopened.player_state.load(std.testing.allocator));
}

fn savedPosition(rig: *Rig) !struct { position_ms: u64, saved_at: i64 } {
    const saved = (try (try rig.libraryDatabase()).player_state.load(std.testing.allocator)).?;
    defer saved.deinit();
    return .{ .position_ms = saved.state.position_ms, .saved_at = saved.saved_at };
}

test "the pump saves a playing Player every thirty seconds and once more after it pauses" {
    var rig: Rig = undefined;
    try rig.init("file:orca-resume-periodic?mode=memory&cache=shared");
    defer rig.deinit();
    try rig.runtime.playerPlayTracksBound(rig.player, rig.library, &rig.ids, 0);
    _ = try rig.startOutput();
    try rig.runtime.playerSaveState(rig.player, rig.library);
    _ = try rig.runtime.seekPlayer(rig.player, framesAt(1_000));

    rig.clock.advance(29_999);
    rig.runtime.pump();
    try std.testing.expectEqual(@as(u64, 0), (try savedPosition(&rig)).position_ms);
    try std.testing.expect(rig.runtime.nextPumpTimeoutMs().? <= 1);
    rig.clock.advance(1);
    rig.runtime.pump();
    try std.testing.expectEqual(@as(u64, 1_000), (try savedPosition(&rig)).position_ms);
    try std.testing.expectEqual(@as(i64, (wall_base_ms + 30_000) / 1000), (try savedPosition(&rig)).saved_at);

    try rig.runtime.pausePlayer(rig.player);
    _ = try rig.runtime.seekPlayer(rig.player, framesAt(2_000));
    rig.clock.advance(30_000);
    rig.runtime.pump();
    try std.testing.expectEqual(@as(u64, 2_000), (try savedPosition(&rig)).position_ms);
    _ = try rig.runtime.seekPlayer(rig.player, framesAt(3_000));
    rig.clock.advance(60_000);
    rig.runtime.pump();
    try std.testing.expectEqual(@as(u64, 2_000), (try savedPosition(&rig)).position_ms);
}

test "a restore after a Track is deleted skips and counts it, resuming paused where the destroyed Player was" {
    var rig: Rig = undefined;
    try rig.init("file:orca-resume-restore?mode=memory&cache=shared");
    defer rig.deinit();
    try rig.runtime.playerPlayTracksBound(rig.player, rig.library, &rig.ids, 1);
    try rig.runtime.playerSetShuffle(rig.player, false);
    try rig.runtime.playerSaveState(rig.player, rig.library);
    _ = try rig.runtime.seekPlayer(rig.player, framesAt(1_500));
    try rig.runtime.destroyPlayer(rig.player);
    try std.testing.expectEqual(@as(u64, 1_499), (try savedPosition(&rig)).position_ms);

    const library_database = try rig.libraryDatabase();
    var statement = try library_database.database.prepare("DELETE FROM tracks WHERE id = ?1;");
    defer statement.deinit();
    try statement.bindInt64(1, rig.ids[0]);
    try std.testing.expectEqual(.done, try statement.step());

    rig.player = try rig.newPlayer();
    const outcome = try rig.runtime.playerRestoreState(rig.player, rig.library, .paused);
    try std.testing.expectEqual(runtime_module.RestoreOutcome{
        .entries = 2,
        .index = 0,
        .position_ms = 1_499,
        .skipped_missing = 1,
    }, outcome);
    var queue: [4]runtime_module.TrackRef = undefined;
    try std.testing.expectEqual(@as(usize, 2), try rig.runtime.playerQueuePage(rig.player, 0, &queue));
    try std.testing.expectEqual(rig.ids[1], queue[0].track_id);
    try std.testing.expectEqual(rig.ids[2], queue[1].track_id);
    const status = try rig.runtime.playerStatus(rig.player);
    try std.testing.expectEqual(audio.player.TransportState.paused, status.transport);
    try std.testing.expectEqual(@as(?i64, rig.ids[1]), status.track_id);
    try std.testing.expectEqual(@as(u64, 1_499), status.position_ms);
    try std.testing.expectEqual(@as(?u64, 1_499), status.resumed_from_ms);

    const other = try rig.newPlayer();
    try std.testing.expectEqual(runtime_module.RestoreOutcome{
        .entries = 0,
        .index = 0,
        .position_ms = 0,
        .skipped_missing = 0,
    }, try rig.runtime.playerRestoreState(other, rig.library, .none));
    try std.testing.expectEqual(@as(u32, 0), (try rig.runtime.playerQueueSnapshot(other)).entries);
}

test "a long Track resumes where it was left and forgets the place once it plays to its end" {
    var rig: Rig = undefined;
    try rig.init("file:orca-resume-long-track?mode=memory&cache=shared");
    defer rig.deinit();
    const first = rig.ids[0];
    const positions = &(try rig.libraryDatabase()).player_state;
    try rig.runtime.playerSetLongTrackMemory(rig.player, 1_000);
    try rig.runtime.playerPlayTracksBound(rig.player, rig.library, rig.ids[0..2], 0);
    const stream = try rig.startOutput();
    _ = try rig.runtime.seekPlayer(rig.player, framesAt(3_500));
    try std.testing.expectEqual(@as(?u64, 3_499), try positions.trackPosition(first));
    try std.testing.expectEqual(@as(?u64, null), (try rig.runtime.playerStatus(rig.player)).resumed_from_ms);

    try rig.runtime.playerQueueJump(rig.player, 1);
    try std.testing.expectEqual(@as(?u64, null), (try rig.runtime.playerStatus(rig.player)).resumed_from_ms);
    try rig.runtime.playerQueueJump(rig.player, 0);
    const resumed = try rig.runtime.playerStatus(rig.player);
    try std.testing.expectEqual(@as(?u64, 3_499), resumed.resumed_from_ms);
    try std.testing.expectEqual(@as(u64, 3_499), resumed.position_ms);
    try std.testing.expectEqual(@as(?u64, 3_499), try positions.trackPosition(first));

    var samples: [256]f32 = undefined;
    var deadline: runtime_tests.TestDeadline = .init(10_000);
    while ((try rig.runtime.playerStatus(rig.player)).track_id != rig.ids[1]) {
        if (!deadline.tick()) return error.TrackNeverEnded;
        stream.pump(&samples, samples.len);
        rig.clock.advance(100);
        rig.runtime.pump();
    }
    rig.clock.advance(100);
    rig.runtime.pump();
    try std.testing.expectEqual(@as(?u64, null), try positions.trackPosition(first));
    try std.testing.expectEqual(@as(?u64, null), (try rig.runtime.playerStatus(rig.player)).resumed_from_ms);

    try rig.runtime.playerSetLongTrackMemory(rig.player, null);
    const kept = try positions.trackPosition(rig.ids[1]);
    _ = try rig.runtime.seekPlayer(rig.player, framesAt(2_000));
    try std.testing.expectEqual(kept, try positions.trackPosition(rig.ids[1]));
}
