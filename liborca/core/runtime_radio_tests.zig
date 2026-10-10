const std = @import("std");
const audio = @import("../audio/root.zig");
const database = @import("../database/root.zig");
const network = @import("../network/root.zig");
const runtime_module = @import("runtime.zig");
const runtime_listens = @import("runtime_listens.zig");
const runtime_provider_tests = @import("runtime_provider_tests.zig");
const runtime_radio = @import("runtime_radio.zig");
const runtime_tests = @import("runtime_tests.zig");

const sqlite = database.sqlite;
const LibraryHandle = runtime_module.LibraryHandle;
const OrcaRuntime = runtime_module.OrcaRuntime;
const PlayerHandle = runtime_module.PlayerHandle;
const RadioQueuePick = runtime_module.RadioQueuePick;
const TrackRef = runtime_module.TrackRef;
const ZoneHandle = runtime_module.ZoneHandle;

const io = std.testing.io;
const rate = 11_025;
const track_count = 48;
const track_frames = 31 * rate;
const wall_base_ms = 1_800_000_000_000;

/// 48 Recordings by six Artists on eight Releases, each Track a hard link to
/// one 31-second silent file, a Player bound to the Library and a Zone on the
/// test backend.
const Rig = struct {
    backend: audio.output.TestBackend,
    runtime: OrcaRuntime,
    clock: network.testing.TestClock = .{ .wall_offset_ms = wall_base_ms },
    temporary: std.testing.TmpDir,
    library: LibraryHandle = undefined,
    player: PlayerHandle = undefined,
    zone: ZoneHandle = undefined,

    fn init(self: *Rig, uri: [:0]const u8) !void {
        self.* = .{
            .backend = .{ .allocator = std.testing.allocator },
            .runtime = .init(std.testing.allocator),
            .temporary = std.testing.tmpDir(.{}),
        };
        errdefer self.deinit();
        self.runtime.setOutputFactory(self.backend.factory());
        self.runtime.listen_hooks.sample_clock = runtime_provider_tests.sampleClock(&self.clock);
        try runtime_provider_tests.writeSilentWave(self.temporary.dir, "base.wav", track_frames);
        for (1..track_count + 1) |id| {
            var name: [16]u8 = undefined;
            const link = try std.fmt.bufPrint(&name, "t{d}.wav", .{id});
            try self.temporary.dir.hardLink("base.wav", self.temporary.dir, link, io, .{});
        }
        const folder = try runtime_tests.absoluteTestPath(".zig-cache/tmp/{s}", .{self.temporary.sub_path});
        defer std.testing.allocator.free(folder);

        self.library = try self.runtime.openLibrary(io, uri);
        const library_database = try self.libraryDatabase();
        const volume_id = try library_database.volumes.ensure(.{ .stable_key = "uuid:radio-fixture", .label = "Fixtures" });
        const sql = try std.fmt.allocPrintSentinel(std.testing.allocator,
            \\INSERT INTO artists(id, name, key) VALUES
            \\    (1, 'A', 'a'), (2, 'B', 'b'), (3, 'C', 'c'), (4, 'D', 'd'), (5, 'E', 'e'), (6, 'F', 'f');
            \\INSERT INTO releases(id, title, album_artist_id, release_date, release_type) VALUES
            \\    (1, 'One', 1, '1990', 'album'), (2, 'Two', 1, '1992', 'album'),
            \\    (3, 'Three', 2, '1991', 'album'), (4, 'Four', 3, '2005', 'album'),
            \\    (5, 'Five', 4, '2010', 'album'), (6, 'Six', 5, '1975', 'album'),
            \\    (7, 'Seven', 6, '1999', 'album'), (8, 'Eight', 3, '1994', 'album');
            \\WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < {d})
            \\INSERT INTO recordings(id, title) SELECT n, 'r' || n FROM seq;
            \\INSERT INTO files(id, recording_id, audio_format, size_bytes, quick_hash, content_hash, content_hash_algorithm, channels)
            \\    SELECT id, id, 1, 1, CAST(id AS BLOB), CAST(id AS BLOB), 1, 1 FROM recordings;
            \\INSERT INTO tracks(id, recording_id, release_id, title, artist_id, preferred_file_id, created_at)
            \\    SELECT id, id, (id - 1) / 6 + 1, 't' || id,
            \\        (SELECT album_artist_id FROM releases WHERE releases.id = (recordings.id - 1) / 6 + 1), id, 1000
            \\    FROM recordings;
            \\INSERT INTO locations(file_id, volume_id, uri, state)
            \\    SELECT id, {d}, '{s}/t' || id || '.wav', 'present' FROM files;
            \\INSERT INTO genres(id, name, key) VALUES (1, 'Hip Hop', 'hip hop'), (2, 'Jazz', 'jazz'), (3, 'Rock', 'rock');
            \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance)
            \\    SELECT id, CASE release_id WHEN 4 THEN 2 WHEN 5 THEN 2 WHEN 6 THEN 3 WHEN 7 THEN 3 ELSE 1 END, 0, 0 FROM tracks;
            \\INSERT INTO file_audio_features(file_id, source_identity, tempo_bpm, tempo_confidence, key_pitch, key_mode,
            \\    key_confidence, onset_rate, centroid_hz)
            \\    SELECT id, content_hash, 80 + id * 2, 0.5, id % 12, id % 2, 0.5, id * 0.1, 1000 + id * 10 FROM files;
            \\INSERT INTO recording_play_stats(recording_id, play_count, last_played_at)
            \\    SELECT id, 1 + id % 5, 1000 FROM recordings;
            \\INSERT INTO feedback(recording_id, score, updated_at) VALUES (7, 1, 1), (40, 1, 1);
        , .{ track_count, volume_id, folder }, 0);
        defer std.testing.allocator.free(sql);
        try library_database.database.exec(sql);

        self.player = try self.runtime.createPlayer();
        try self.runtime.playerBindLibrary(self.player, self.library, io);
        self.zone = try self.runtime.createZone();
        try self.runtime.attachZone(self.zone, self.player);
        try self.runtime.zoneRequestOutput(self.zone, 0);
    }

    fn deinit(self: *Rig) void {
        self.runtime.deinit();
        self.backend.deinit();
        self.temporary.cleanup();
    }

    fn libraryDatabase(self: *Rig) !*database.LibraryDatabase {
        return runtime_module.libraryDatabase(&self.runtime, self.library);
    }

    fn session(self: *Rig) ?*runtime_radio.Session {
        return (self.runtime.players.get(self.player) catch return null).radio;
    }

    /// Samples without pumping until `radio.continue` wants a session.
    fn sampleUntilContinueWanted(self: *Rig) !void {
        var deadline: runtime_tests.TestDeadline = .init(5_000);
        while (deadline.tick()) {
            self.clock.advance(1_000);
            runtime_listens.sampleListens(&self.runtime);
            if ((try self.runtime.players.get(self.player)).radio_continue_wanted) return;
        }
        return error.ContinueNeverWanted;
    }

    /// One host-loop turn a sampling interval later.
    fn turn(self: *Rig) void {
        self.clock.advance(1_000);
        self.runtime.pump();
    }

    fn settled(self: *Rig) bool {
        const value = self.session() orelse return true;
        return value.worker == null and !value.wants_top_up;
    }

    /// Turns until the session has no top-up running or owed.
    fn settle(self: *Rig) !void {
        var deadline: runtime_tests.TestDeadline = .init(5_000);
        while (deadline.tick()) {
            self.turn();
            if (self.settled()) return;
        }
        return error.RadioNeverSettled;
    }

    fn status(self: *Rig) !runtime_module.RadioStatus {
        return (try self.runtime.playerRadio(self.player)) orelse error.NoRadioSession;
    }

    fn picks(self: *Rig, output: []RadioQueuePick) ![]RadioQueuePick {
        return output[0..try self.runtime.playerRadioPicks(self.player, output)];
    }

    fn queue(self: *Rig, output: []TrackRef) ![]TrackRef {
        return output[0..try self.runtime.playerQueuePage(self.player, 0, output)];
    }

    fn cursor(self: *Rig) !u32 {
        return (try self.runtime.playerQueueSnapshot(self.player)).cursor;
    }

    fn artistOf(self: *Rig, track_id: i64) !i64 {
        const library_database = try self.libraryDatabase();
        var statement = try library_database.database.prepare("SELECT artist_id FROM tracks WHERE id = ?1;");
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        _ = try statement.step();
        return statement.columnInt64(0);
    }

    /// Plays the audible entry out so the queue advances on its own.
    fn finishCurrent(self: *Rig) !void {
        const before = try self.cursor();
        try std.testing.expect(try self.runtime.playerSeekToTail(self.player, 50));
        var samples: [512]f32 = @splat(0);
        var deadline: runtime_tests.TestDeadline = .init(5_000);
        while (deadline.tick()) {
            if (self.backend.liveStream()) |stream| stream.pump(&samples, 256);
            if (try self.cursor() != before) return;
        }
        return error.QueueNeverAdvanced;
    }
};

fn expectPicksMatchQueue(rig: *Rig) !void {
    var pick_buffer: [runtime_module.max_radio_reported_picks]RadioQueuePick = undefined;
    var queue_buffer: [64]TrackRef = undefined;
    const reported = try rig.picks(&pick_buffer);
    const entries = try rig.queue(&queue_buffer);
    const cursor = try rig.cursor();
    const queue = (try rig.runtime.players.get(rig.player)).queue;
    var previous: ?u32 = null;
    for (reported) |pick| {
        try std.testing.expect(pick.position >= cursor);
        if (previous) |value| try std.testing.expect(pick.position > value);
        previous = pick.position;
        try std.testing.expectEqual(pick.track_id, entries[pick.position].track_id);
        try std.testing.expectEqual(pick.entry_id, queue.idAt(pick.position).?);
        try std.testing.expect(pick.reason.first != null);
    }
}

fn findPick(reported: []const RadioQueuePick, entry_id: u64) ?RadioQueuePick {
    for (reported) |pick| if (pick.entry_id == entry_id) return pick;
    return null;
}

test "a Track seed on an idle Player plays first, eight picks line up and each finished pick is replaced" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-track-seed?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .track = 1 }, .{});
    try std.testing.expectEqual(@as(i64, 1), (try rig.runtime.playerNowPlaying(rig.player)).?.track_id);
    try rig.settle();
    var status = try rig.status();
    try std.testing.expectEqualStrings("t1", status.title());
    try std.testing.expectEqual(runtime_module.RadioState.active, status.state);
    try std.testing.expectEqual(@as(u32, runtime_module.max_radio_pending), status.pending);
    try std.testing.expectEqual(@as(u32, 8), status.counts.picks_added);
    try std.testing.expect(!status.continued);
    try std.testing.expectEqual(@as(u32, 9), (try rig.runtime.playerQueueSnapshot(rig.player)).entries);
    try expectPicksMatchQueue(&rig);

    for (0..2) |round| {
        try rig.finishCurrent();
        try rig.settle();
        status = try rig.status();
        try std.testing.expectEqual(@as(u32, 8), status.pending);
        try std.testing.expectEqual(@as(u32, @intCast(9 + round)), status.counts.picks_added);
        try expectPicksMatchQueue(&rig);
    }

    var pick_buffer: [runtime_module.max_radio_reported_picks]RadioQueuePick = undefined;
    const reported = try rig.picks(&pick_buffer);
    try std.testing.expectEqual(@as(usize, 9), reported.len);
    for (reported, 0..) |pick, index| {
        try std.testing.expect(pick.track_id != 1);
        for (reported[index + 1 ..]) |other| try std.testing.expect(other.recording_id != pick.recording_id);
    }
}

test "every seed kind starts a session with its title, and a non-Track seed on an idle Player plays its first pick" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-seeds?mode=memory&cache=shared");
    defer rig.deinit();

    const cases = [_]struct { seed: runtime_module.RadioSeed, title: []const u8 }{
        .{ .seed = .{ .release = 2 }, .title = "Two" },
        .{ .seed = .{ .artist = 3 }, .title = "C" },
        .{ .seed = .{ .genre = 2 }, .title = "Jazz" },
        .{ .seed = .{ .decade = 1990 }, .title = "" },
        .{ .seed = .loved, .title = "" },
        .{ .seed = .recent, .title = "" },
    };
    for (cases) |case| {
        try rig.runtime.playerClearQueue(rig.player);
        try std.testing.expectEqual(@as(?runtime_module.RadioStatus, null), try rig.runtime.playerRadio(rig.player));
        try rig.runtime.playerStartRadio(rig.player, rig.library, case.seed, .{});
        try rig.settle();
        const status = try rig.status();
        try std.testing.expectEqualStrings(case.title, status.title());
        try std.testing.expectEqual(std.meta.activeTag(case.seed), std.meta.activeTag(status.seed));
        try std.testing.expectEqual(@as(u32, 8), status.pending);
        try std.testing.expectEqual(@as(u32, 0), try rig.cursor());
        const playing = (try rig.runtime.playerNowPlaying(rig.player)).?;
        var pick_buffer: [runtime_module.max_radio_reported_picks]RadioQueuePick = undefined;
        const reported = try rig.picks(&pick_buffer);
        try std.testing.expectEqual(@as(usize, 9), reported.len);
        try std.testing.expectEqual(playing.track_id, reported[0].track_id);
        try std.testing.expectEqual(@as(u32, 0), reported[0].position);
    }

    try std.testing.expectError(error.UnknownRadioSeed, rig.runtime.playerStartRadio(rig.player, rig.library, .{ .artist = 999 }, .{}));
    try std.testing.expectError(error.InvalidDecade, rig.runtime.playerStartRadio(rig.player, rig.library, .{ .decade = 1995 }, .{}));
}

test "the user's queued entries play before Radio's, and options replace only the pending picks" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-enqueue?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .track = 1 }, .{});
    try rig.settle();
    try rig.runtime.playerEnqueueTracksBound(rig.player, rig.library, &.{ 44, 45 });
    try rig.runtime.playerQueueInsertNext(rig.player, rig.library, &.{46});
    var queue_buffer: [64]TrackRef = undefined;
    var entries = try rig.queue(&queue_buffer);
    try std.testing.expectEqual(@as(usize, 12), entries.len);
    try std.testing.expectEqual(@as(i64, 1), entries[0].track_id);
    try std.testing.expectEqual(@as(i64, 46), entries[1].track_id);
    try std.testing.expectEqual(@as(i64, 44), entries[2].track_id);
    try std.testing.expectEqual(@as(i64, 45), entries[3].track_id);
    var status = try rig.status();
    try std.testing.expectEqual(@as(u32, 3), status.counts.user_queued);
    try std.testing.expectEqual(@as(u32, 8), status.pending);
    try expectPicksMatchQueue(&rig);

    var before_buffer: [runtime_module.max_radio_reported_picks]RadioQueuePick = undefined;
    const before = try rig.picks(&before_buffer);
    try rig.runtime.playerSetRadioOptions(rig.player, .{ .explore = 100, .focus = .{ .{ .genre = 2 }, null, null, null } });
    try rig.settle();
    status = try rig.status();
    try std.testing.expectEqual(@as(u8, 100), status.options.explore);
    entries = try rig.queue(&queue_buffer);
    try std.testing.expectEqual(@as(i64, 1), entries[0].track_id);
    try std.testing.expectEqual(@as(i64, 46), entries[1].track_id);
    try std.testing.expectEqual(@as(i64, 44), entries[2].track_id);
    try std.testing.expectEqual(@as(i64, 45), entries[3].track_id);
    var after_buffer: [runtime_module.max_radio_reported_picks]RadioQueuePick = undefined;
    const after = try rig.picks(&after_buffer);
    try std.testing.expect(after.len > 0);
    for (after) |pick| {
        try std.testing.expect(findPick(before, pick.entry_id) == null);
        try std.testing.expect(pick.position >= 4);
    }
    try expectPicksMatchQueue(&rig);
}

test "Stop Radio removes the pending picks and keeps the playing and user-queued entries" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-stop?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .track = 1 }, .{});
    try rig.settle();
    try rig.runtime.playerEnqueueTracksBound(rig.player, rig.library, &.{44});
    try rig.runtime.playerStopRadio(rig.player);
    try std.testing.expectEqual(@as(?runtime_module.RadioStatus, null), try rig.runtime.playerRadio(rig.player));
    var queue_buffer: [64]TrackRef = undefined;
    const entries = try rig.queue(&queue_buffer);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(i64, 1), entries[0].track_id);
    try std.testing.expectEqual(@as(i64, 44), entries[1].track_id);
    try std.testing.expectEqual(@as(i64, 1), (try rig.runtime.playerNowPlaying(rig.player)).?.track_id);
    try rig.runtime.playerStopRadio(rig.player);
}

test "starting Radio over a playing queue replaces the upcoming entries with the picks" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-replace-upcoming?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerPlayTracksBound(rig.player, rig.library, &.{ 20, 21, 22, 23, 24 }, 0);
    try std.testing.expectEqual(@as(u32, 5), (try rig.runtime.playerQueueSnapshot(rig.player)).entries);

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .track = 1 }, .{});
    try rig.settle();
    const status = try rig.status();
    try std.testing.expectEqual(@as(u32, 8), status.pending);
    var queue_buffer: [64]TrackRef = undefined;
    const entries = try rig.queue(&queue_buffer);
    try std.testing.expectEqual(@as(usize, 9), entries.len);
    try std.testing.expectEqual(@as(i64, 20), entries[0].track_id);
    const playing = (try rig.runtime.playerNowPlaying(rig.player)).?;
    try std.testing.expectEqual(@as(i64, 20), playing.track_id);
    try std.testing.expectEqual(audio.player.TransportState.playing, (try rig.runtime.playerSnapshot(rig.player)).state);
    var pick_buffer: [runtime_module.max_radio_reported_picks]RadioQueuePick = undefined;
    const reported = try rig.picks(&pick_buffer);
    try std.testing.expectEqual(@as(usize, 8), reported.len);
    try std.testing.expectEqual(@as(u32, 1), reported[0].position);
    try expectPicksMatchQueue(&rig);
}

test "an idle Player's queue is emptied when a non-Track seed starts Radio" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-idle-nontrack?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerEnqueueTracksBound(rig.player, rig.library, &.{ 30, 31, 32 });
    try rig.runtime.stopPlayer(rig.player);
    try std.testing.expectEqual(@as(u32, 3), (try rig.runtime.playerQueueSnapshot(rig.player)).entries);

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .artist = 3 }, .{});
    try rig.settle();
    const status = try rig.status();
    try std.testing.expectEqual(@as(u32, 8), status.pending);
    var queue_buffer: [64]TrackRef = undefined;
    const entries = try rig.queue(&queue_buffer);
    try std.testing.expectEqual(@as(usize, 9), entries.len);
    const playing = (try rig.runtime.playerNowPlaying(rig.player)).?;
    try std.testing.expectEqual(entries[0].track_id, playing.track_id);
    try std.testing.expectEqual(@as(u32, 0), try rig.cursor());
    try std.testing.expectEqual(audio.player.TransportState.playing, (try rig.runtime.playerSnapshot(rig.player)).state);
    try expectPicksMatchQueue(&rig);
}

test "a Track seed on an idle Player with queued entries replaces them" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-idle-track?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerEnqueueTracksBound(rig.player, rig.library, &.{ 30, 31, 32 });
    try rig.runtime.stopPlayer(rig.player);

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .track = 5 }, .{});
    try rig.settle();
    const status = try rig.status();
    try std.testing.expectEqual(@as(u32, 8), status.pending);
    var queue_buffer: [64]TrackRef = undefined;
    const entries = try rig.queue(&queue_buffer);
    try std.testing.expectEqual(@as(usize, 9), entries.len);
    try std.testing.expectEqual(@as(i64, 5), entries[0].track_id);
    try std.testing.expectEqual(@as(i64, 5), (try rig.runtime.playerNowPlaying(rig.player)).?.track_id);
    try expectPicksMatchQueue(&rig);
}

test "restarting Radio with another seed removes user-queued entries after the committed span" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-restart?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .track = 1 }, .{});
    try rig.settle();
    try rig.runtime.playerEnqueueTracksBound(rig.player, rig.library, &.{ 44, 45 });
    var queue_buffer: [64]TrackRef = undefined;
    var entries = try rig.queue(&queue_buffer);
    try std.testing.expectEqual(@as(usize, 11), entries.len);
    try std.testing.expectEqual(@as(i64, 44), entries[1].track_id);
    try std.testing.expectEqual(@as(i64, 45), entries[2].track_id);
    const queue = (try rig.runtime.players.get(rig.player)).queue;
    const removed_a = queue.idAt(1).?;
    const removed_b = queue.idAt(2).?;

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .artist = 3 }, .{});
    try rig.settle();
    const status = try rig.status();
    try std.testing.expectEqual(@as(u32, 8), status.pending);
    entries = try rig.queue(&queue_buffer);
    try std.testing.expectEqual(@as(usize, 9), entries.len);
    try std.testing.expectEqual(@as(i64, 1), entries[0].track_id);
    try std.testing.expect(queue.positionOfId(removed_a) == null);
    try std.testing.expect(queue.positionOfId(removed_b) == null);
    try expectPicksMatchQueue(&rig);
}

test "starting Radio on a paused Player removes the queue behind the pause and resumes into the picks" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-paused?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerPlayTracksBound(rig.player, rig.library, &.{ 20, 21, 22, 23, 24 }, 0);
    try rig.runtime.pausePlayer(rig.player);

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .track = 1 }, .{});
    try rig.settle();
    const status = try rig.status();
    try std.testing.expectEqual(@as(u32, 8), status.pending);
    var queue_buffer: [64]TrackRef = undefined;
    const entries = try rig.queue(&queue_buffer);
    try std.testing.expectEqual(@as(usize, 9), entries.len);
    try std.testing.expectEqual(@as(i64, 20), entries[0].track_id);
    try std.testing.expectEqual(@as(u32, 0), try rig.cursor());
    try std.testing.expectEqual(audio.player.TransportState.paused, (try rig.runtime.playerSnapshot(rig.player)).state);
    try std.testing.expectEqual(@as(i64, 20), (try rig.runtime.playerNowPlaying(rig.player)).?.track_id);
    try expectPicksMatchQueue(&rig);

    try rig.runtime.playPlayer(rig.player);
    try rig.finishCurrent();
    try std.testing.expectEqual(@as(u32, 1), try rig.cursor());
    try std.testing.expectEqual(entries[1].track_id, (try rig.runtime.playerNowPlaying(rig.player)).?.track_id);
}

test "starting Radio on a shuffled Player removes the entries past the committed position" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-shuffled?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerPlayTracksBound(rig.player, rig.library, &.{ 20, 21, 22, 23, 24 }, 0);
    try rig.runtime.playerSetShuffle(rig.player, true);

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .track = 1 }, .{});
    try rig.settle();
    const status = try rig.status();
    try std.testing.expectEqual(@as(u32, 8), status.pending);
    var queue_buffer: [64]TrackRef = undefined;
    const entries = try rig.queue(&queue_buffer);
    try std.testing.expectEqual(@as(usize, 9), entries.len);
    try std.testing.expectEqual(@as(i64, 20), entries[0].track_id);
    try std.testing.expectEqual(@as(u32, 0), try rig.cursor());
    try std.testing.expectEqual(audio.player.TransportState.playing, (try rig.runtime.playerSnapshot(rig.player)).state);
    try std.testing.expectEqual(@as(i64, 20), (try rig.runtime.playerNowPlaying(rig.player)).?.track_id);
    try expectPicksMatchQueue(&rig);
}

test "less like this removes the pick and keeps its Artist out of the next top-up; undo restores the weights only" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-less?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .track = 1 }, .{});
    try rig.settle();
    var before_buffer: [runtime_module.max_radio_reported_picks]RadioQueuePick = undefined;
    const before = try rig.picks(&before_buffer);
    const target = before[2];
    const artist = try rig.artistOf(target.track_id);
    try rig.runtime.playerRadioLessLikeThis(rig.player, target.entry_id);
    try std.testing.expectEqual(@as(u32, 8), (try rig.runtime.playerQueueSnapshot(rig.player)).entries);
    try std.testing.expectError(error.NotARadioPick, rig.runtime.playerRadioLessLikeThis(rig.player, target.entry_id));
    var status = try rig.status();
    try std.testing.expectEqual(@as(u32, 1), status.counts.less_like_this);
    try std.testing.expectEqual(@as(u32, 7), status.pending);

    try rig.settle();
    var after_buffer: [runtime_module.max_radio_reported_picks]RadioQueuePick = undefined;
    const after = try rig.picks(&after_buffer);
    try std.testing.expectEqual(@as(u32, 8), (try rig.status()).pending);
    try std.testing.expect(findPick(after, target.entry_id) == null);
    var fresh: usize = 0;
    for (after) |pick| {
        if (findPick(before, pick.entry_id) != null) continue;
        fresh += 1;
        try std.testing.expect(try rig.artistOf(pick.track_id) != artist);
        try std.testing.expect(pick.recording_id != target.recording_id);
    }
    try std.testing.expectEqual(@as(usize, 1), fresh);
    try expectPicksMatchQueue(&rig);

    const session = rig.session().?;
    try std.testing.expectEqual(@as(usize, 1), session.disliked.len);
    try std.testing.expectEqual(@as(usize, 1), session.artist_adjustments.len);
    try std.testing.expectEqual(@as(f64, -0.5), session.artist_adjustments.items[0].delta);
    try std.testing.expectEqual(@as(usize, 1), session.genre_adjustments.len);
    try std.testing.expectEqual(@as(f64, -0.25), session.genre_adjustments.items[0].delta);

    try rig.runtime.playerRadioUndoFeedback(rig.player);
    status = try rig.status();
    try std.testing.expectEqual(@as(u32, 0), status.counts.less_like_this);
    try std.testing.expectEqual(@as(usize, 0), session.disliked.len);
    try std.testing.expectEqual(@as(usize, 0), session.artist_adjustments.len);
    try std.testing.expectEqual(@as(usize, 0), session.genre_adjustments.len);
    try rig.settle();
    const restored = try rig.picks(&before_buffer);
    try std.testing.expect(findPick(restored, target.entry_id) == null);
    try std.testing.expectEqual(@as(u32, 9), (try rig.runtime.playerQueueSnapshot(rig.player)).entries);

    const seed_entry = (try rig.runtime.players.get(rig.player)).queue.idAt(0).?;
    try std.testing.expectError(error.NotARadioPick, rig.runtime.playerRadioLessLikeThis(rig.player, seed_entry));

    try std.testing.expect(try rig.runtime.playerNext(rig.player));
    const playing = (try rig.picks(&after_buffer))[0];
    try std.testing.expectEqual(@as(u32, 1), playing.position);
    try rig.runtime.playerRadioLessLikeThis(rig.player, playing.entry_id);
    try std.testing.expectEqual(@as(u32, 1), try rig.cursor());
    try std.testing.expect((try rig.runtime.players.get(rig.player)).queue.positionOfId(playing.entry_id) == null);
    try std.testing.expect((try rig.runtime.playerNowPlaying(rig.player)).?.track_id != playing.track_id);
    try std.testing.expectEqual(audio.player.TransportState.playing, (try rig.runtime.playerSnapshot(rig.player)).state);
    try std.testing.expectEqual(@as(u32, 1), (try rig.status()).counts.less_like_this);
    try rig.settle();
    try std.testing.expectEqual(@as(u32, 8), (try rig.status()).pending);
    try expectPicksMatchQueue(&rig);
}

test "a Radio pick skipped within 30 seconds is excluded and its Artist weighed down; one skipped later is not" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-skip?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .track = 1 }, .{});
    try rig.settle();
    try std.testing.expect(try rig.runtime.playerNext(rig.player));
    try std.testing.expectEqual(@as(u32, 0), (try rig.status()).counts.skips);

    var pick_buffer: [runtime_module.max_radio_reported_picks]RadioQueuePick = undefined;
    const early = (try rig.picks(&pick_buffer))[0];
    try std.testing.expectEqual(@as(u32, 1), early.position);
    _ = try rig.runtime.playerSeekMs(rig.player, 29_000);
    try std.testing.expect(try rig.runtime.playerNext(rig.player));
    var status = try rig.status();
    try std.testing.expectEqual(@as(u32, 1), status.counts.skips);
    const session = rig.session().?;
    try std.testing.expectEqual(early.recording_id, session.disliked.items[0]);
    try std.testing.expectEqual(@as(f64, -0.25), session.artist_adjustments.items[0].delta);
    try std.testing.expectEqual(try rig.artistOf(early.track_id), session.artist_adjustments.items[0].id);

    _ = try rig.runtime.playerSeekMs(rig.player, 30_000);
    try std.testing.expect(try rig.runtime.playerNext(rig.player));
    status = try rig.status();
    try std.testing.expectEqual(@as(u32, 1), status.counts.skips);

    try rig.runtime.playerQueueJump(rig.player, (try rig.cursor()) + 2);
    status = try rig.status();
    try std.testing.expectEqual(@as(u32, 2), status.counts.skips);

    try rig.runtime.playerRadioUndoFeedback(rig.player);
    status = try rig.status();
    try std.testing.expectEqual(@as(u32, 0), status.counts.skips);
    try std.testing.expectEqual(@as(usize, 0), session.disliked.len);
}

test "replacing play ends the session, and repeat pauses top-ups until it is off" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-replace?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .track = 1 }, .{});
    try rig.settle();
    try rig.runtime.playerSetRepeat(rig.player, .all);
    try std.testing.expectEqual(runtime_module.RadioState.paused_by_repeat, (try rig.status()).state);
    const last = (try rig.runtime.playerQueueSnapshot(rig.player)).entries - 1;
    try rig.runtime.playerQueueRemove(rig.player, last);
    for (0..5) |_| rig.turn();
    try std.testing.expect(rig.settled());
    try std.testing.expectEqual(@as(u32, 7), (try rig.status()).pending);
    try rig.runtime.playerSetRepeat(rig.player, .one);
    for (0..3) |_| rig.turn();
    try std.testing.expectEqual(@as(u32, 7), (try rig.status()).pending);
    try rig.runtime.playerSetRepeat(rig.player, .off);
    try rig.settle();
    try std.testing.expectEqual(@as(u32, 8), (try rig.status()).pending);
    try std.testing.expectEqual(runtime_module.RadioState.active, (try rig.status()).state);

    try rig.runtime.playerPlayTracksBound(rig.player, rig.library, &.{ 20, 21 }, 0);
    try std.testing.expectEqual(@as(?runtime_module.RadioStatus, null), try rig.runtime.playerRadio(rig.player));
    try std.testing.expectEqual(@as(u32, 2), (try rig.runtime.playerQueueSnapshot(rig.player)).entries);

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .artist = 2 }, .{});
    try rig.runtime.playerClearQueue(rig.player);
    try std.testing.expectEqual(@as(?runtime_module.RadioStatus, null), try rig.runtime.playerRadio(rig.player));

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .track = 3 }, .{});
    try rig.runtime.playerSaveState(rig.player, rig.library);
    try rig.settle();
    _ = try rig.runtime.playerRestoreState(rig.player, rig.library, .paused);
    try std.testing.expectEqual(@as(?runtime_module.RadioStatus, null), try rig.runtime.playerRadio(rig.player));
}

test "radio.continue starts a recent-listening session when the last entry starts, and only when it is on" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-continue?mode=memory&cache=shared");
    defer rig.deinit();

    var settings = try rig.runtime.libraryDiscoverySettings(rig.library);
    settings.radio_continue = false;
    try rig.runtime.setLibraryDiscoverySettings(rig.library, settings);
    try rig.runtime.playerPlayTracksBound(rig.player, rig.library, &.{ 10, 11 }, 1);
    for (0..5) |_| rig.turn();
    try std.testing.expectEqual(@as(?runtime_module.RadioStatus, null), try rig.runtime.playerRadio(rig.player));

    settings.radio_continue = true;
    try rig.runtime.setLibraryDiscoverySettings(rig.library, settings);
    rig.turn();
    try rig.settle();
    const status = try rig.status();
    try std.testing.expect(status.continued);
    try std.testing.expectEqual(runtime_module.RadioSeed.recent, status.seed);
    try std.testing.expectEqual(@as(u32, 8), status.pending);
    try std.testing.expectEqual(@as(u32, 10), (try rig.runtime.playerQueueSnapshot(rig.player)).entries);

    try rig.runtime.playerStopRadio(rig.player);
    for (0..5) |_| rig.turn();
    try std.testing.expectEqual(@as(?runtime_module.RadioStatus, null), try rig.runtime.playerRadio(rig.player));
}

test "a continue the sampling pass wanted is dropped when play replaces or stops the queue before the pump" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-continue-dropped?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerPlayTracksBound(rig.player, rig.library, &.{ 10, 11 }, 1);
    try rig.sampleUntilContinueWanted();
    try rig.runtime.playerPlayTracksBound(rig.player, rig.library, &.{ 12, 13, 14 }, 0);
    rig.runtime.pump();
    try std.testing.expectEqual(@as(?runtime_module.RadioStatus, null), try rig.runtime.playerRadio(rig.player));

    try rig.runtime.playerPlayTracksBound(rig.player, rig.library, &.{ 15, 16 }, 1);
    try rig.sampleUntilContinueWanted();
    try rig.runtime.stopPlayer(rig.player);
    rig.runtime.pump();
    try std.testing.expectEqual(@as(?runtime_module.RadioStatus, null), try rig.runtime.playerRadio(rig.player));
}

test "closing the Library during a top-up joins the worker and ends the session" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-close?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .track = 1 }, .{});
    try std.testing.expect(rig.session().?.worker != null);
    try rig.runtime.destroyLibrary(rig.library);
    try std.testing.expectEqual(@as(?runtime_module.RadioStatus, null), try rig.runtime.playerRadio(rig.player));
    try std.testing.expectEqual(@as(usize, 0), runtime_tests.inFlightWorkCount(&rig.runtime));
    rig.turn();
}

test "shutdown during a top-up joins the worker" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-shutdown?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .genre = 1 }, .{});
    try std.testing.expect(rig.session().?.worker != null);
    rig.runtime.shutdown();
}

test "picks report true positions and reasons after moves and removals" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-positions?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .track = 1 }, .{});
    try rig.settle();
    var before_buffer: [runtime_module.max_radio_reported_picks]RadioQueuePick = undefined;
    const before = try rig.picks(&before_buffer);
    try rig.runtime.playerQueueMove(rig.player, 8, 2);
    try rig.runtime.playerQueueRemove(rig.player, 5);
    var after_buffer: [runtime_module.max_radio_reported_picks]RadioQueuePick = undefined;
    const after = try rig.picks(&after_buffer);
    try std.testing.expectEqual(before.len - 1, after.len);
    try expectPicksMatchQueue(&rig);
    for (after) |pick| {
        const original = findPick(before, pick.entry_id).?;
        try std.testing.expectEqual(original.track_id, pick.track_id);
        try std.testing.expectEqualDeep(original.reason, pick.reason);
    }
    try std.testing.expectEqual(before[7].entry_id, after[1].entry_id);
    try std.testing.expectEqual(@as(u32, 2), after[1].position);
    try std.testing.expectEqual(@as(u32, 7), (try rig.status()).pending);

    try rig.runtime.playerSetShuffle(rig.player, true);
    try rig.settle();
    try std.testing.expectEqual(@as(u32, 8), (try rig.status()).pending);
    try expectPicksMatchQueue(&rig);
}

fn countStatement(_: c_uint, context: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const started: *u32 = @ptrCast(@alignCast(context.?));
    started.* += 1;
    return 0;
}

test "the sampling pass runs no SQL, and a top-up lands within the sampling interval its worker finished in" {
    var rig: Rig = undefined;
    try rig.init("file:orca-radio-sampling?mode=memory&cache=shared");
    defer rig.deinit();

    try rig.runtime.playerStartRadio(rig.player, rig.library, .{ .track = 1 }, .{});
    try rig.settle();
    const last = (try rig.runtime.playerQueueSnapshot(rig.player)).entries - 1;
    try rig.runtime.playerQueueRemove(rig.player, last);

    const library_database = try rig.libraryDatabase();
    const opener = (try rig.runtime.players.get(rig.player)).opener.?;
    var statements: u32 = 0;
    try std.testing.expectEqual(sqlite.c.SQLITE_OK, sqlite.c.sqlite3_trace_v2(library_database.database.handle, sqlite.c.SQLITE_TRACE_STMT, countStatement, &statements));
    try std.testing.expectEqual(sqlite.c.SQLITE_OK, sqlite.c.sqlite3_trace_v2(opener.tracks.db.handle, sqlite.c.SQLITE_TRACE_STMT, countStatement, &statements));
    rig.clock.advance(1_000);
    runtime_listens.sampleListens(&rig.runtime);
    try std.testing.expectEqual(@as(u32, 0), statements);
    try std.testing.expectEqual(@as(?u64, 0), runtime_radio.radioPumpDueMs(&rig.runtime));
    try std.testing.expectEqual(sqlite.c.SQLITE_OK, sqlite.c.sqlite3_trace_v2(library_database.database.handle, 0, null, null));
    try std.testing.expectEqual(sqlite.c.SQLITE_OK, sqlite.c.sqlite3_trace_v2(opener.tracks.db.handle, 0, null, null));

    rig.runtime.pump();
    const top_up = rig.session().?.worker.?;
    var deadline: runtime_tests.TestDeadline = .init(5_000);
    while (!top_up.registration.isFinished() and deadline.tick()) {}
    try std.testing.expect(rig.runtime.host_signal.isPending());
    try std.testing.expectEqual(@as(?u64, 0), rig.runtime.nextPumpTimeoutMs());
    rig.runtime.pump();
    try std.testing.expectEqual(@as(u32, 8), (try rig.status()).pending);
}
