const std = @import("std");
const artist_info = @import("artist_info.zig");
const audio = @import("../audio/root.zig");
const codec = @import("../codec/root.zig");
const control = @import("control.zig");
const database = @import("../database/root.zig");
const job = @import("job.zig");
const library_pass = @import("../library/root.zig");
const listen_worker = @import("listen_worker.zig");
const lyrics_fetch = @import("lyrics_fetch.zig");
const metadata = @import("../metadata/root.zig");
const network = @import("../network/root.zig");
const providers = @import("../providers/root.zig");
const work = @import("work.zig");
const runtime_jobs = @import("runtime_jobs.zig");
const runtime_listens = @import("runtime_listens.zig");
const runtime_module = @import("runtime.zig");
const runtime_queue = @import("runtime_queue.zig");
const runtime_tests = @import("runtime_tests.zig");

const AcoustIdUse = runtime_module.AcoustIdUse;
const MaintenanceStatus = runtime_module.MaintenanceStatus;
const MaintenanceUnit = runtime_module.MaintenanceUnit;
const BusyService = runtime_module.BusyService;
const CredentialStore = runtime_module.CredentialStore;
const Feedback = runtime_module.Feedback;
const LibraryHandle = runtime_module.LibraryHandle;
const MatchingHooks = runtime_module.MatchingHooks;
const OrcaRuntime = runtime_module.OrcaRuntime;
const PlayStats = runtime_module.PlayStats;
const PlayerHandle = runtime_module.PlayerHandle;
const RecordingIdSource = runtime_module.RecordingIdSource;
const ReleaseField = runtime_module.ReleaseField;
const ArtworkSize = runtime_module.ArtworkSize;
const ReleaseFieldSet = runtime_module.ReleaseFieldSet;
const ReleaseMatchBucket = runtime_module.ReleaseMatchBucket;
const ReleaseMatchCounts = runtime_module.ReleaseMatchCounts;
const ScanStats = runtime_module.ScanStats;
const ScrobblerState = runtime_module.ScrobblerState;
const SubmissionOutcome = runtime_module.SubmissionOutcome;
const libraryDatabase = runtime_module.libraryDatabase;

pub fn sampleClock(clock: *network.testing.TestClock) listen_worker.SampleClock {
    return .{ .context = clock, .now_fn = sampleNow };
}

fn sampleNow(context: *anyopaque) listen_worker.SampleTime {
    const clock: *network.testing.TestClock = @ptrCast(@alignCast(context));
    return .{ .mono_ms = clock.now(), .wall_s = @divFloor(clock.wallNow(), 1000) };
}

/// ListenBrainz and its token store, as a listen worker sees them. Every call
/// arrives on the worker's thread.
const FakeListenBrainz = struct {
    transport: network.testing.ScriptedTransport = .{},
    clock: network.testing.TestClock = .{ .wall_offset_ms = wall_base_ms },
    hang: bool = false,
    listens_sent: std.atomic.Value(u32) = .init(0),
    now_playing_sent: std.atomic.Value(u32) = .init(0),
    feedback_sent: std.atomic.Value(u32) = .init(0),
    last_score: std.atomic.Value(i32) = .init(99),
    /// The recording id of the last feedback sent, complete once
    /// `feedback_sent` counts it.
    feedback_mbid: [36]u8 = @splat(0),
    feedback_status: std.atomic.Value(u16) = .init(200),
    during_feedback: ?struct { context: *anyopaque, run: *const fn (*anyopaque) void } = null,
    token_lookups: std.atomic.Value(u32) = .init(0),

    const wall_base_ms: i64 = 1_800_000_000_000;

    fn attach(self: *FakeListenBrainz) void {
        self.transport.responder = .{ .context = self, .respond_fn = respond };
    }

    fn requestCount(self: *const FakeListenBrainz) u32 {
        return self.transport.requestCount();
    }

    fn advance(self: *FakeListenBrainz, milliseconds: i64) void {
        self.clock.advance(milliseconds);
    }

    fn store(self: *FakeListenBrainz) CredentialStore {
        return .{ .context = self, .get_fn = token };
    }

    fn respond(context: *anyopaque, exchange: network.testing.Exchange, _: ?network.testing.Reply) anyerror!network.testing.Reply {
        const self: *FakeListenBrainz = @ptrCast(@alignCast(context));
        const url = exchange.request.url;
        const sent = exchange.form;
        if (std.mem.endsWith(u8, url, "/recording-feedback")) {
            if (self.during_feedback) |hook| {
                self.during_feedback = null;
                hook.run(hook.context);
            }
            if (std.mem.indexOf(u8, sent, "\"score\":")) |at| {
                const digits = std.mem.trimEnd(u8, sent[at + 8 ..], "}");
                self.last_score.store(std.fmt.parseInt(i32, digits, 10) catch 99, .release);
            }
            const mbid_key = "\"recording_mbid\":\"";
            if (std.mem.indexOf(u8, sent, mbid_key)) |at| {
                const start = at + mbid_key.len;
                if (sent.len >= start + self.feedback_mbid.len)
                    @memcpy(&self.feedback_mbid, sent[start..][0..self.feedback_mbid.len]);
            }
            _ = self.feedback_sent.fetchAdd(1, .acq_rel);
            return .{ .respond = .{ .status = self.feedback_status.load(.acquire) } };
        }
        if (std.mem.endsWith(u8, url, "/submit-listens")) {
            const counter = if (std.mem.indexOf(u8, sent, "\"playing_now\"") != null) &self.now_playing_sent else &self.listens_sent;
            _ = counter.fetchAdd(1, .acq_rel);
        }
        if (self.hang) return .hang;
        if (std.mem.endsWith(u8, url, "/validate-token"))
            return .{ .respond = .{ .body = "{\"valid\":true,\"user_name\":\"listener\"}" } };
        return .{ .respond = .{} };
    }

    fn token(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!?[]u8 {
        const self: *FakeListenBrainz = @ptrCast(@alignCast(context));
        _ = self.token_lookups.fetchAdd(1, .acq_rel);
        return try allocator.dupe(u8, "secret-token");
    }
};

/// A runtime whose listen sampling and ListenBrainz traffic are both fakes.
/// Players report playback through their status atomics, as an engine would,
/// without decoding anything.
const ListenRig = struct {
    runtime: OrcaRuntime,
    clock: network.testing.TestClock = .{ .wall_offset_ms = 1_700_000_000_000 },
    listenbrainz: FakeListenBrainz = .{},

    const track_duration_ms = 180_000;

    fn init(self: *ListenRig) void {
        self.* = .{ .runtime = .init(std.testing.allocator) };
        self.runtime.setClientIdentity(network.testing.test_identity) catch unreachable;
        self.listenbrainz.attach();
        self.runtime.listen_hooks = .{
            .transport = self.listenbrainz.transport.transport(),
            .clock = self.listenbrainz.clock.clock(),
            .wall_clock = self.listenbrainz.clock.wallClock(),
            .sample_clock = sampleClock(&self.clock),
            .poll_ms = 5,
        };
    }

    /// A Library holding one three-minute Track with a file behind it.
    fn openLibrary(self: *ListenRig, uri: [:0]const u8) !struct { library: LibraryHandle, track_id: i64 } {
        const library = try self.runtime.openLibrary(std.testing.io, uri);
        const library_database = try libraryDatabase(&self.runtime, library);
        try library_database.database.exec("INSERT INTO recordings(id, title) VALUES (1, 'Northern Sky');");
        const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
        try library_database.database.exec("UPDATE files SET recording_id = 1;");
        try library_database.tracks.upsertTracks(&.{.{
            .recording_id = 1,
            .title = "Northern Sky",
            .artist = "Nick Drake",
            .album = "Bryter Layter",
            .duration_ms = track_duration_ms,
            .preferred_file_id = file_id,
        }});
        var page = try library_database.tracks.page(std.testing.allocator, .{ .limit = 1, .offset = 0 });
        defer page.deinit();
        return .{ .library = library, .track_id = page.items[0].id };
    }

    fn startPlaying(self: *ListenRig, player: PlayerHandle, library: LibraryHandle, track_id: i64, serial: u32) !void {
        const object_value = try self.runtime.players.get(player);
        try object_value.queue.replace(&.{.{ .library = library, .track_id = track_id }}, 0);
        object_value.queue.noteEntrySerial(serial, 0);
        object_value.player.published_sample_rate.store(1000, .release);
        object_value.player.published_frame_count.store(track_duration_ms, .release);
        object_value.player.audible_entry_serial.store(serial, .release);
        object_value.player.position_frames.store(0, .release);
        object_value.player.state.store(.playing, .release);
    }

    /// Plays on for `milliseconds`, pumping the control lane every 100 ms.
    fn play(self: *ListenRig, player: PlayerHandle, milliseconds: u64) !void {
        const object_value = try self.runtime.players.get(player);
        var elapsed: u64 = 0;
        while (elapsed < milliseconds) : (elapsed += 100) {
            self.clock.advance(100);
            _ = object_value.player.position_frames.fetchAdd(100, .acq_rel);
            _ = self.runtime.processNextCommand();
        }
    }

    fn awaitPlayCount(self: *ListenRig, library: LibraryHandle, track_id: i64, expected: u64) !PlayStats {
        var deadline: runtime_tests.TestDeadline = .init(5_000);
        while (deadline.tick()) {
            const stats = try self.runtime.libraryTrackPlayStats(library, track_id);
            if (stats.play_count == expected) return stats;
        }
        return error.ListenNotRecorded;
    }

    /// Queues one listen for ListenBrainz directly, as another process sharing
    /// the database would, due at `due_at` Unix seconds.
    fn queueBacklog(self: *ListenRig, library: LibraryHandle, due_at: i64) !void {
        const library_database = try libraryDatabase(&self.runtime, library);
        const event: providers.scrobble.Event = .{
            .title = "Northern Sky",
            .artist = "Nick Drake",
            .started_at = 1_700_000_000,
            .duration_ms = track_duration_ms,
            .listened_ms = 100_000,
        };
        const payload = try event.encode(std.testing.allocator);
        defer std.testing.allocator.free(payload);
        try library_database.scrobbles.enqueue(providers.listenbrainz.service, "listen:backlog", payload);
        var sql: [96]u8 = undefined;
        try library_database.database.exec(try std.fmt.bufPrintSentinel(
            &sql,
            "UPDATE scrobble_queue SET next_attempt_at = {d};",
            .{due_at},
            0,
        ));
    }

    fn awaitDelivered(self: *ListenRig, library: LibraryHandle, expected: u64) !void {
        var deadline: runtime_tests.TestDeadline = .init(5_000);
        while ((try self.runtime.libraryScrobblerStatus(library)).delivered_total != expected) {
            if (!deadline.tick()) return error.ListenNotDelivered;
        }
    }

    fn identify(self: *ListenRig, library: LibraryHandle, track_id: i64, mbid: ?[]const u8) !void {
        const library_database = try libraryDatabase(&self.runtime, library);
        try library_database.database.exec("INSERT INTO recordings(title) VALUES ('Northern Sky');");
        var sql: [256]u8 = undefined;
        try library_database.database.exec(try std.fmt.bufPrintSentinel(
            &sql,
            "UPDATE files SET recording_id = (SELECT max(id) FROM recordings) " ++
                "WHERE id = (SELECT preferred_file_id FROM tracks WHERE id = {d});" ++
                "UPDATE tracks SET recording_id = (SELECT max(id) FROM recordings) WHERE id = {d};",
            .{ track_id, track_id },
            0,
        ));
        var statement = try library_database.database.prepare("SELECT preferred_file_id FROM tracks WHERE id = ?1;");
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return error.SqlFailed;
        try library_database.observed_tags.upsert(.{ .file_id = statement.columnInt64(0), .values = .{
            .title = "Northern Sky",
            .musicbrainz_recording_id = mbid,
        } });
    }

    fn awaitCount(counter: *const std.atomic.Value(u32), expected: u32) !void {
        var deadline: runtime_tests.TestDeadline = .init(5_000);
        while (counter.load(.acquire) < expected) {
            if (!deadline.tick()) return error.RequestNeverSent;
        }
    }

    fn awaitFeedbackSettled(self: *ListenRig, library: LibraryHandle) !void {
        var deadline: runtime_tests.TestDeadline = .init(5_000);
        while ((try self.runtime.libraryScrobblerStatus(library)).feedback_pending != 0) {
            if (!deadline.tick()) return error.FeedbackNeverSettled;
        }
    }

    /// Lets the listen worker run at least `passes` more passes.
    fn awaitWorkerPasses(self: *ListenRig, passes: u32) !void {
        const target = self.listenbrainz.clock.reads.load(.acquire) + passes;
        var deadline: runtime_tests.TestDeadline = .init(5_000);
        while (self.listenbrainz.clock.reads.load(.acquire) < target) {
            if (!deadline.tick()) return error.WorkerStalled;
        }
    }
};

test "a play heard past half its length records one listen, and without scrobbling queues and sends nothing" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-local?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);

    try rig.play(player, 80_000);
    try rig.awaitWorkerPasses(3);
    try std.testing.expectEqual(@as(u64, 0), (try rig.runtime.libraryTrackPlayStats(fixture.library, fixture.track_id)).play_count);
    try rig.play(player, 20_000);

    const stats = try rig.awaitPlayCount(fixture.library, fixture.track_id, 1);
    try std.testing.expectEqual(@as(u64, 1), try rig.runtime.libraryListensRecorded(fixture.library));
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), stats.last_played_at);
    const details = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer details.deinit();
    try std.testing.expectEqual(@as(u64, 1), details.play_count);
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), details.last_played_at);

    try rig.awaitWorkerPasses(3);
    const library_database = try libraryDatabase(&rig.runtime, fixture.library);
    try std.testing.expectEqual(@as(u64, 0), try library_database.scrobbles.pendingCount());
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requestCount());
    const status = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expect(!status.enabled);
    try std.testing.expectEqual(@as(u64, 1), status.recorded_total);
    try std.testing.expectEqual(@as(u64, 0), status.dropped);
}

test "queue history records each entry that stops playing and never records a listen of its own" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-queue-history?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    const object_value = try rig.runtime.players.get(player);

    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);
    try rig.play(player, 10_000);
    const first_ended_s = @divFloor(rig.clock.wallNow(), 1000);
    object_value.queue.noteEntrySerial(8, 0);
    object_value.player.audible_entry_serial.store(8, .release);
    object_value.player.position_frames.store(0, .release);
    try rig.play(player, 100);

    var entries: [4]runtime_module.QueueHistoryEntry = undefined;
    try std.testing.expectEqual(@as(usize, 1), try rig.runtime.playerQueueHistory(player, 0, &entries));
    try std.testing.expectEqual(runtime_module.QueueHistoryReason.finished, entries[0].reason);
    try std.testing.expectEqual(fixture.track_id, entries[0].track.track_id);
    try std.testing.expectEqual(first_ended_s * std.time.ms_per_s, entries[0].ended_at_ms);
    try rig.awaitWorkerPasses(3);
    try std.testing.expectEqual(@as(u64, 0), try rig.runtime.libraryListensRecorded(fixture.library));

    try rig.play(player, 100_000);
    object_value.player.drained.store(true, .release);
    try rig.play(player, 200);
    _ = try rig.awaitPlayCount(fixture.library, fixture.track_id, 1);
    try rig.play(player, 1_000);
    try rig.awaitWorkerPasses(3);

    try std.testing.expectEqual(@as(usize, 2), try rig.runtime.playerQueueHistory(player, 0, &entries));
    try std.testing.expectEqual(runtime_module.QueueHistoryReason.finished, entries[0].reason);
    try std.testing.expect(entries[0].ended_at_ms > entries[1].ended_at_ms);
    try std.testing.expectEqual(@as(u64, 1), try rig.runtime.libraryListensRecorded(fixture.library));
    try std.testing.expectEqual(@as(u64, 1), (try rig.runtime.libraryTrackPlayStats(fixture.library, fixture.track_id)).play_count);

    try rig.runtime.playerClearQueueHistory(player);
    try std.testing.expectEqual(@as(usize, 0), try rig.runtime.playerQueueHistory(player, 0, &entries));
}

test "queue history names the Track each serial played while the cursor lags, and records nothing for an entry no sample saw" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const player = try rig.runtime.createPlayer();
    const object_value = try rig.runtime.players.get(player);
    const library: LibraryHandle = .{ .index = 0, .generation = 1 };
    try object_value.queue.replace(&.{
        .{ .library = library, .track_id = 1 },
        .{ .library = library, .track_id = 2 },
        .{ .library = library, .track_id = 3 },
    }, 0);
    object_value.queue.noteEntrySerial(7, 0);
    object_value.queue.noteEntrySerial(8, 1);
    object_value.queue.noteEntrySerial(9, 2);
    object_value.player.audible_entry_serial.store(7, .release);
    object_value.player.state.store(.playing, .release);
    try rig.play(player, 200);

    object_value.player.audible_entry_serial.store(8, .release);
    object_value.player.audible_entry_serial.store(9, .release);
    try rig.play(player, 200);
    try std.testing.expectEqual(@as(i64, 1), object_value.queue.current().?.track_id);
    object_value.player.drained.store(true, .release);
    try rig.play(player, 200);

    var entries: [4]runtime_module.QueueHistoryEntry = undefined;
    try std.testing.expectEqual(@as(usize, 2), try rig.runtime.playerQueueHistory(player, 0, &entries));
    try std.testing.expectEqual(@as(i64, 3), entries[0].track.track_id);
    try std.testing.expectEqual(runtime_module.QueueHistoryReason.finished, entries[0].reason);
    try std.testing.expectEqual(@as(i64, 1), entries[1].track.track_id);
    try std.testing.expectEqual(runtime_module.QueueHistoryReason.finished, entries[1].reason);
}

test "a listen sampled while the cursor lags the audible serial is credited to the Track that serial played" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-cursor-lag?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&rig.runtime, fixture.library);
    const heard = try addMatchTrack(library_database, "Hazey Jane I", "Nick Drake", null);
    try library_database.database.exec(
        "INSERT INTO recordings(title) VALUES ('Hazey Jane I');" ++
            "UPDATE files SET recording_id = (SELECT max(id) FROM recordings) " ++
            "WHERE id = (SELECT preferred_file_id FROM tracks WHERE title = 'Hazey Jane I');" ++
            "UPDATE tracks SET recording_id = (SELECT max(id) FROM recordings) WHERE title = 'Hazey Jane I';",
    );
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    const object_value = try rig.runtime.players.get(player);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);
    try object_value.queue.enqueue(&.{.{ .library = fixture.library, .track_id = heard }});
    try rig.play(player, 1_000);

    object_value.queue.noteEntrySerial(8, 1);
    object_value.player.audible_entry_serial.store(8, .release);
    object_value.player.position_frames.store(0, .release);
    try rig.play(player, 100_000);

    _ = try rig.awaitPlayCount(fixture.library, heard, 1);
    try std.testing.expectEqual(@as(u32, 0), object_value.queue.cursorPosition());
    try std.testing.expectEqual(@as(u64, 0), (try rig.runtime.libraryTrackPlayStats(fixture.library, fixture.track_id)).play_count);
    try std.testing.expectEqual(@as(u64, 1), try rig.runtime.libraryListensRecorded(fixture.library));
}

test "player status names the Track the audible serial played while the cursor lags, no Track for a serial the queue never held, and the cursor's entry once nothing is audible" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const player = try runtime.createPlayer();
    const object_value = try runtime.players.get(player);
    const library: LibraryHandle = .{ .index = 0, .generation = 1 };
    try object_value.queue.replace(&.{
        .{ .library = library, .track_id = 1 },
        .{ .library = library, .track_id = 2 },
    }, 0);
    object_value.queue.noteEntrySerial(7, 0);
    object_value.queue.noteEntrySerial(8, 1);
    object_value.player.audible_entry_serial.store(8, .release);

    const lagging = try runtime.playerStatus(player);
    try std.testing.expectEqual(@as(u32, 0), object_value.queue.cursorPosition());
    try std.testing.expectEqual(@as(?i64, 2), lagging.track_id);
    try std.testing.expectEqual(@as(u32, 8), lagging.entry_serial);
    try std.testing.expectEqual(@as(u32, 1), lagging.queue_index);
    try std.testing.expectEqual(@as(i64, 2), (try runtime.playerNowPlaying(player)).?.track_id);

    object_value.player.audible_entry_serial.store(9, .release);
    try std.testing.expectEqual(@as(?i64, null), (try runtime.playerStatus(player)).track_id);
    try std.testing.expectEqual(@as(?runtime_module.TrackRef, null), try runtime.playerNowPlaying(player));

    object_value.player.audible_entry_serial.store(0, .release);
    const stopped = try runtime.playerStatus(player);
    try std.testing.expectEqual(@as(?i64, 1), stopped.track_id);
    try std.testing.expectEqual(@as(u32, 0), stopped.queue_index);
}

fn eightTrackQueue(runtime: *OrcaRuntime, player: PlayerHandle, start: u32) !*audio.playback_queue.PlaybackQueue {
    const library: LibraryHandle = .{ .index = 0, .generation = 1 };
    var refs: [8]runtime_module.TrackRef = undefined;
    for (&refs, 1..) |*ref, track_id| ref.* = .{ .library = library, .track_id = @intCast(track_id) };
    const queue = (try runtime.players.get(player)).queue;
    try queue.replace(&refs, start);
    return queue;
}

test "turning shuffle off while a shuffled entry plays reports the Track that is playing" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.shuffle_seed = 0xfeed;
    const player = try runtime.createPlayer();
    const object_value = try runtime.players.get(player);
    try runtime.playerSetShuffle(player, true);
    const queue = try eightTrackQueue(&runtime, player, 0);
    const position: u32 = 5;
    try std.testing.expect(queue.entryIndex(position).? != position);
    queue.seekTo(position);
    queue.noteEntrySerial(7, position);
    object_value.player.audible_entry_serial.store(7, .release);
    const playing = queue.current().?.track_id;

    try runtime.playerSetShuffle(player, false);
    queue.observeRenderedSerial(7);
    const status = try runtime.playerStatus(player);
    try std.testing.expectEqual(@as(?i64, playing), status.track_id);
    try std.testing.expectEqual(@as(u32, @intCast(playing - 1)), status.queue_index);
    try std.testing.expectEqual(playing, queue.current().?.track_id);
    try std.testing.expectEqual(playing, (try runtime.playerNowPlaying(player)).?.track_id);
}

test "turning shuffle on while an entry plays keeps reporting it, then reports the successor already decoding once that is heard" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.shuffle_seed = 0xfeed;
    const player = try runtime.createPlayer();
    const object_value = try runtime.players.get(player);
    const queue = try eightTrackQueue(&runtime, player, 3);
    queue.noteEntrySerial(7, 3);
    queue.advanceDecodeTo(4);
    queue.noteEntrySerial(8, 4);
    object_value.player.audible_entry_serial.store(7, .release);

    try runtime.playerSetShuffle(player, true);
    try std.testing.expect(queue.refAt(4).?.track_id != 5);
    queue.observeRenderedSerial(7);
    const shuffled = try runtime.playerStatus(player);
    try std.testing.expectEqual(@as(?i64, 4), shuffled.track_id);
    try std.testing.expectEqual(@as(u32, 3), shuffled.queue_index);

    object_value.player.audible_entry_serial.store(8, .release);
    queue.observeRenderedSerial(8);
    try std.testing.expectEqual(@as(?i64, 5), (try runtime.playerStatus(player)).track_id);
    try std.testing.expectEqual(@as(i64, 5), queue.current().?.track_id);
}

const SecondsDecoder = struct {
    seconds: u64,

    fn decoder(self: *SecondsDecoder) codec.decoder.Decoder {
        return .{
            .context = self,
            .codec = codec.decoder.codec_id.pcm_float,
            .vtable = &.{ .read_frames = read, .seek = seek, .deinit = release },
            .format = .{
                .sample_format = .float_32,
                .channels = 1,
                .sample_rate = 1_000,
                .bits_per_sample = 32,
                .bytes_per_frame = 4,
            },
            .frame_count = self.seconds * 1_000,
        };
    }

    fn read(_: *anyopaque, _: []f32) !usize {
        return 0;
    }

    fn seek(_: *anyopaque, _: u64) !void {}

    fn release(_: *anyopaque) void {}
};

const HardLoader = struct {
    object_value: *runtime_module.PlayerObject,
    decoders: []SecondsDecoder,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *HardLoader) void {
        for (self.decoders, 0..) |*decoder, position| audio.engine.loadQueueEntry(
            self.object_value.player,
            self.object_value.queue,
            audio.source_session.SourceSession.init(decoder.decoder()),
            @intCast(position),
        );
        self.done.store(true, .release);
    }
};

test "a status read while entries hard-load never pairs a Track with a later entry's duration" {
    const decoders = try std.testing.allocator.alloc(SecondsDecoder, audio.playback_queue.capacity);
    defer std.testing.allocator.free(decoders);
    const refs = try std.testing.allocator.alloc(runtime_module.TrackRef, decoders.len);
    defer std.testing.allocator.free(refs);
    for (decoders, refs, 1..) |*decoder, *ref, track_id| {
        decoder.* = .{ .seconds = track_id };
        ref.* = .{ .library = .{ .index = 0, .generation = 1 }, .track_id = @intCast(track_id) };
    }
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const player = try runtime.createPlayer();
    const object_value = try runtime.players.get(player);

    var torn: u32 = 0;
    for (0..4) |_| {
        object_value.player.releaseSources();
        try object_value.queue.replace(refs, 0);
        var loader: HardLoader = .{ .object_value = object_value, .decoders = decoders };
        const thread = try std.Thread.spawn(.{}, HardLoader.run, .{&loader});
        while (!loader.done.load(.acquire)) {
            const status = try runtime.playerStatus(player);
            const track_id = status.track_id orelse continue;
            if (status.duration_ms > @as(u64, @intCast(track_id)) * 1_000) torn += 1;
        }
        thread.join();
    }
    try std.testing.expectEqual(@as(u32, 0), torn);
}

fn expectQueueOrder(queue: *const audio.playback_queue.PlaybackQueue, expected: []const i64) !void {
    try std.testing.expectEqual(expected.len, queue.len());
    for (expected, 0..) |track_id, position|
        try std.testing.expectEqual(track_id, queue.refAt(@intCast(position)).?.track_id);
}

test "the playing, decoding and pending entries refuse to move, and nothing lands between the playing entry and the one already lined up" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const player = try runtime.createPlayer();
    const object_value = try runtime.players.get(player);
    const queue = try eightTrackQueue(&runtime, player, 2);

    try runtime.playerQueueMove(player, 2, 6);
    try std.testing.expectEqual(@as(u32, 6), queue.cursorPosition());
    try runtime.playerQueueMove(player, 6, 2);
    try expectQueueOrder(queue, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });

    var decoders: [3]SecondsDecoder = .{ .{ .seconds = 3 }, .{ .seconds = 4 }, .{ .seconds = 5 } };
    const engine = try runtime_queue.ensureEngine(&runtime, player);
    engine.quiesce();
    audio.engine.loadQueueEntry(object_value.player, queue, audio.source_session.SourceSession.init(decoders[0].decoder()), 2);
    try object_value.player.primeNextSource(audio.source_session.SourceSession.init(decoders[1].decoder()));
    queue.advanceDecodeTo(3);
    const decoding_serial = object_value.player.sources.?.next_entry_serial;
    queue.noteEntrySerial(decoding_serial, 3);
    engine.pending_source = audio.source_session.SourceSession.init(decoders[2].decoder());
    engine.pending_position = 4;
    const playing_serial = object_value.player.audible_entry_serial.load(.acquire);
    engine.release();

    for ([_]u32{ 2, 3, 4 }) |from|
        try std.testing.expectError(error.QueueEntryInUse, runtime.playerQueueMove(player, from, 6));
    try std.testing.expectError(error.QueueEntryInUse, runtime.playerQueueMove(player, 6, 3));
    try std.testing.expectError(error.QueueEntryInUse, runtime.playerQueueMove(player, 6, 4));
    try std.testing.expectError(error.QueueEntryInUse, runtime.playerQueueMove(player, 0, 3));
    try expectQueueOrder(queue, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });

    try runtime.playerQueueMove(player, 6, 2);
    try runtime.playerQueueMove(player, 7, 6);
    try runtime.playerQueueMove(player, 3, 3);
    try expectQueueOrder(queue, &.{ 1, 2, 7, 3, 4, 5, 8, 6 });
    try std.testing.expectEqual(@as(u32, 3), queue.cursorPosition());
    try std.testing.expectEqual(@as(u32, 4), queue.decodePosition());
    try std.testing.expectEqual(@as(?u32, 3), queue.positionForSerial(playing_serial));
    try std.testing.expectEqual(@as(?u32, 4), queue.positionForSerial(decoding_serial));
    engine.quiesce();
    const pending_position = engine.pending_position;
    engine.release();
    try std.testing.expectEqual(@as(u32, 5), pending_position);
    try std.testing.expectError(error.PositionOutOfRange, runtime.playerQueueMove(player, 8, 0));
    try std.testing.expectError(error.PositionOutOfRange, runtime.playerQueueMove(player, 0, 8));

    try runtime.playerSetRepeat(player, .all);
    engine.quiesce();
    engine.releasePending();
    object_value.player.releaseSources();
    _ = try eightTrackQueue(&runtime, player, 7);
    audio.engine.loadQueueEntry(object_value.player, queue, audio.source_session.SourceSession.init(decoders[0].decoder()), 7);
    try object_value.player.primeNextSource(audio.source_session.SourceSession.init(decoders[1].decoder()));
    queue.advanceDecodeTo(0);
    engine.release();

    try std.testing.expectError(error.QueueEntryInUse, runtime.playerQueueMove(player, 3, 0));
    try std.testing.expectError(error.QueueEntryInUse, runtime.playerQueueMove(player, 3, 7));
    try runtime.playerQueueMove(player, 3, 1);
    try expectQueueOrder(queue, &.{ 1, 4, 2, 3, 5, 6, 7, 8 });
    try std.testing.expectEqual(@as(u32, 7), queue.cursorPosition());
    try std.testing.expectEqual(@as(u32, 0), queue.decodePosition());
}

/// Opens each Track as silence `framesOf(track_id)` frames long, so the
/// length of a loaded decoder names the Track it was opened for.
const LengthOpener = struct {
    allocator: std.mem.Allocator,

    const Backing = struct {
        allocator: std.mem.Allocator,
        frames: u64,
        position: u64 = 0,

        fn decoder(self: *Backing) codec.decoder.Decoder {
            return .{
                .context = self,
                .codec = codec.decoder.codec_id.pcm_float,
                .vtable = &.{ .read_frames = read, .seek = seek, .deinit = finish },
                .format = .{
                    .sample_format = .float_32,
                    .channels = 1,
                    .sample_rate = 48_000,
                    .bits_per_sample = 32,
                    .bytes_per_frame = 4,
                },
                .frame_count = self.frames,
            };
        }

        fn read(context: *anyopaque, output: []f32) !usize {
            const self: *Backing = @ptrCast(@alignCast(context));
            const frames = @min(output.len, self.frames - self.position);
            @memset(output[0..frames], 0);
            self.position += frames;
            return frames;
        }

        fn seek(context: *anyopaque, frame: u64) !void {
            const self: *Backing = @ptrCast(@alignCast(context));
            self.position = frame;
        }

        fn finish(_: *anyopaque) void {}

        fn release(context: *anyopaque) void {
            const self: *Backing = @ptrCast(@alignCast(context));
            self.allocator.destroy(self);
        }
    };

    fn framesOf(track_id: i64) u64 {
        return @as(u64, @intCast(track_id)) * 2_048;
    }

    fn opener(self: *LengthOpener) audio.playback_queue.TrackOpener {
        return .{ .context = self, .open_fn = open };
    }

    fn open(context: *anyopaque, ref: audio.playback_queue.TrackRef) anyerror!audio.source_session.SourceSession {
        const self: *LengthOpener = @ptrCast(@alignCast(context));
        const backing = try self.allocator.create(Backing);
        backing.* = .{ .allocator = self.allocator, .frames = framesOf(ref.track_id) };
        return audio.source_session.SourceSession.initOwned(
            backing.decoder(),
            .{ .context = backing, .release = Backing.release },
        );
    }
};

/// Control lane, under `quiesce`. Frames in the decoder loaded under `serial`,
/// while the Player still remembers it.
fn framesLoadedFor(player: *const audio.player.Player, serial: u32) ?u64 {
    if (player.sources) |*sources| {
        if (sources.current_entry_serial == serial) return sources.current.decoder.frame_count;
        if (sources.next) |*next| {
            if (sources.next_entry_serial == serial) return next.decoder.frame_count;
        }
    }
    for (player.entry_info) |record| {
        if (record.serial == serial) return record.frame_count;
    }
    return null;
}

test "a host reading status while it moves queue entries never pairs a Track with another entry" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var lengths: LengthOpener = .{ .allocator = std.testing.allocator };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());
    const player = try runtime.createPlayer();
    const object_value = try runtime.players.get(player);
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    _ = try eightTrackQueue(&runtime, player, 0);
    try runtime.playerSetRepeat(player, .all);
    const engine = try runtime_queue.ensureEngine(&runtime, player);
    engine.quiesce();
    engine.opener = lengths.opener();
    engine.release();
    try runtime.zoneRequestOutput(zone, 0);
    try runtime.playPlayer(player);
    var deadline: runtime_tests.TestDeadline = .init(5_000);
    while (try runtime.zoneOutputState(zone) != .active and deadline.tick()) {}
    const stream = backend.liveStream() orelse return error.OutputNeverOpened;

    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    var samples: [256]f32 = undefined;
    var moved: u32 = 0;
    var checked: u32 = 0;
    var mispaired: u32 = 0;
    for (0..4_000) |_| {
        stream.pump(&samples, samples.len);
        const from = random.uintLessThan(u32, 8);
        const to = random.uintLessThan(u32, 8);
        if (runtime.playerQueueMove(player, from, to)) |_| {
            if (from != to) moved += 1;
        } else |err| if (err != error.QueueEntryInUse) return err;
        const status = try runtime.playerStatus(player);
        const track_id = status.track_id orelse continue;
        if (status.entry_serial == 0) continue;
        engine.quiesce();
        const loaded = framesLoadedFor(object_value.player, status.entry_serial);
        engine.release();
        const frames = loaded orelse continue;
        checked += 1;
        if (frames != LengthOpener.framesOf(track_id)) mispaired += 1;
    }
    try std.testing.expectEqual(@as(u32, 0), mispaired);
    try std.testing.expect(moved >= 200);
    try std.testing.expect(checked >= 2_000);
}

pub fn writeSilentWave(dir: std.Io.Dir, name: []const u8, frames: u32) !void {
    const bytes = try std.testing.allocator.alloc(u8, 44 + frames * 2);
    defer std.testing.allocator.free(bytes);
    writeWaveHeader(bytes, 11_025, frames);
    @memset(bytes[44..], 0);
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
}

test "moved entries play in their new order and the queue history records them in that order" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());
    const library = try runtime.openLibrary(std.testing.io, "file:orca-queue-move?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    var ids: [6]i64 = undefined;
    for (&ids, 0..) |*id, index| {
        var name_buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "move-{d}.wav", .{index});
        try writeSilentWave(temporary.dir, name, 22_050 + @as(u32, @intCast(index)) * 1_000);
        id.* = try addAudioTrack(library_database, &temporary, name, name, "");
    }
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.playerBindLibrary(player, library, std.testing.io);
    try runtime.playerPlayTracksBound(player, library, &ids, 0);
    try runtime.playerQueueMove(player, 4, 1);
    try runtime.playerQueueMove(player, 5, 3);
    try runtime.zoneRequestOutput(zone, 0);
    var deadline: runtime_tests.TestDeadline = .init(5_000);
    while (try runtime.zoneOutputState(zone) != .active and deadline.tick()) {}
    const stream = backend.liveStream() orelse return error.OutputNeverOpened;

    var history: [8]runtime_module.QueueHistoryEntry = undefined;
    var heard: [8]i64 = undefined;
    var heard_count: usize = 0;
    var moved_into_played = false;
    var samples: [256]f32 = undefined;
    deadline = .init(20_000);
    while (!try runtime.playerDrained(player)) {
        if (!deadline.tick()) return error.QueueNeverPlayedOut;
        stream.pump(&samples, samples.len);
        _ = try runtime.playerQueueHistory(player, 0, &history);
        const track_id = (try runtime.playerStatus(player)).track_id orelse continue;
        if (heard_count > 0 and heard[heard_count - 1] == track_id) continue;
        if (heard_count == heard.len) return error.TooManyTracksHeard;
        heard[heard_count] = track_id;
        heard_count += 1;
        if (track_id == ids[4] and !moved_into_played) {
            try runtime.playerQueueMove(player, 5, 0);
            moved_into_played = true;
        }
    }

    try std.testing.expectEqualSlices(i64, &.{ ids[0], ids[4], ids[1], ids[5], ids[2] }, heard[0..heard_count]);
    var queued: [6]runtime_module.TrackRef = undefined;
    try std.testing.expectEqual(@as(usize, 6), try runtime.playerQueuePage(player, 0, &queued));
    for (queued, [_]i64{ ids[3], ids[0], ids[4], ids[1], ids[5], ids[2] }) |ref, track_id|
        try std.testing.expectEqual(track_id, ref.track_id);
    try std.testing.expectEqual(@as(usize, 5), try runtime.playerQueueHistory(player, 0, &history));
    for (history[0..5], [_]i64{ ids[2], ids[5], ids[1], ids[4], ids[0] }) |entry, track_id| {
        try std.testing.expectEqual(track_id, entry.track.track_id);
        try std.testing.expectEqual(runtime_module.QueueHistoryReason.finished, entry.reason);
    }
}

test "a Player whose Library closes mid-entry keeps its history and never records the entry cut off" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const first = try rig.openLibrary("file:orca-history-closed-first?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, first.library, std.testing.io);
    const object_value = try rig.runtime.players.get(player);
    try rig.startPlaying(player, first.library, first.track_id, 7);
    try rig.play(player, 1_000);
    object_value.queue.noteEntrySerial(8, 0);
    object_value.player.audible_entry_serial.store(8, .release);
    try rig.play(player, 1_000);

    try rig.runtime.destroyLibrary(first.library);
    try rig.play(player, 1_000);
    var entries: [4]runtime_module.QueueHistoryEntry = undefined;
    try std.testing.expectEqual(@as(usize, 1), try rig.runtime.playerQueueHistory(player, 0, &entries));

    const second = try rig.openLibrary("file:orca-history-closed-second?mode=memory&cache=shared");
    try rig.runtime.playerBindLibrary(player, second.library, std.testing.io);
    try rig.startPlaying(player, second.library, second.track_id, 9);
    try rig.play(player, 1_000);
    object_value.player.drained.store(true, .release);
    try rig.play(player, 200);

    try std.testing.expectEqual(@as(usize, 2), try rig.runtime.playerQueueHistory(player, 0, &entries));
    try std.testing.expect(entries[0].track.library.eql(second.library));
    try std.testing.expect(entries[1].track.library.eql(first.library));
    try std.testing.expectEqual(runtime_module.QueueHistoryReason.finished, entries[0].reason);
    try std.testing.expectEqual(runtime_module.QueueHistoryReason.finished, entries[1].reason);
}

test "a finished listen keeps the time heard until the track changed" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-finished?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);
    try rig.play(player, 150_000);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 8);
    try rig.play(player, 200);

    const library_database = try libraryDatabase(&rig.runtime, fixture.library);
    var deadline: runtime_tests.TestDeadline = .init(5_000);
    while (deadline.tick()) {
        var statement = try library_database.database.prepare("SELECT listened_ms FROM listens;");
        defer statement.deinit();
        if (try statement.step() == .row and statement.columnInt64(0) == 149_900) return;
    }
    return error.FinishedListenNotRecorded;
}

test "a queue that plays out keeps the whole time heard on its last listen" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-played-out?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);
    try rig.play(player, 100_000);
    _ = try rig.awaitPlayCount(fixture.library, fixture.track_id, 1);
    try rig.play(player, 80_000);
    (try rig.runtime.players.get(player)).player.drained.store(true, .release);
    try rig.play(player, 200);

    const library_database = try libraryDatabase(&rig.runtime, fixture.library);
    var deadline: runtime_tests.TestDeadline = .init(5_000);
    while (deadline.tick()) {
        var statement = try library_database.database.prepare("SELECT listened_ms FROM listens;");
        defer statement.deinit();
        if (try statement.step() == .row and statement.columnInt64(0) == 180_000) return;
    }
    return error.PlayedOutListenNotFinished;
}

test "a bound Player that plays asks for a pump within a second of its last listen sample" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-timeout?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try std.testing.expectEqual(@as(?u64, null), rig.runtime.nextPumpTimeoutMs());

    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);
    try std.testing.expectEqual(@as(?u64, 0), rig.runtime.nextPumpTimeoutMs());
    rig.runtime.pump();
    try std.testing.expectEqual(@as(?u64, 1000), rig.runtime.nextPumpTimeoutMs());
    rig.clock.advance(300);
    try std.testing.expectEqual(@as(?u64, 700), rig.runtime.nextPumpTimeoutMs());
    rig.clock.advance(700);
    try std.testing.expectEqual(@as(?u64, 0), rig.runtime.nextPumpTimeoutMs());

    try rig.runtime.pausePlayer(player);
    try std.testing.expectEqual(@as(?u64, null), rig.runtime.nextPumpTimeoutMs());
}

test "a played-out queue stops asking for listen samples once its listen has ended" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-timeout-played-out?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);
    try rig.play(player, 1_000);

    (try rig.runtime.players.get(player)).player.drained.store(true, .release);
    rig.clock.advance(1000);
    try std.testing.expectEqual(@as(?u64, 0), rig.runtime.nextPumpTimeoutMs());
    rig.runtime.pump();
    try std.testing.expectEqual(@as(?u64, null), rig.runtime.nextPumpTimeoutMs());
}

test "a Library with no listen worker reports the queue stored in its database and starts none" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-stored-status?mode=memory&cache=shared");
    try rig.queueBacklog(fixture.library, 1_700_000_000);

    var status = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expectEqual(ScrobblerState.disabled, status.state);
    try std.testing.expect(!status.enabled);
    try std.testing.expectEqual(@as(u64, 1), status.pending);
    try std.testing.expectEqual(@as(u64, 0), status.delivered_total);
    try std.testing.expect((try rig.runtime.libraries.get(fixture.library)).listens == null);

    try rig.runtime.librarySetScrobbling(fixture.library, false, false, false);
    const library_database = try libraryDatabase(&rig.runtime, fixture.library);
    try library_database.database.exec("UPDATE scrobble_queue SET state = 2;");
    status = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expectEqual(@as(u64, 1), status.pending);

    rig.clock.advance(runtime_listens.stored_counts_reuse_ms);
    status = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expectEqual(ScrobblerState.disabled, status.state);
    try std.testing.expectEqual(@as(u64, 0), status.pending);
    try std.testing.expectEqual(@as(u64, 1), status.delivered_total);
    try std.testing.expect((try rig.runtime.libraries.get(fixture.library)).listens.?.worker == null);
}

test "a Library without a running worker reports the ListenBrainz block its database records, until it ends" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-stored-block?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&rig.runtime, fixture.library);
    const wall_s = @divFloor(rig.clock.wallNow(), 1000);
    try library_database.provider_state.put(providers.listenbrainz.service, .{
        .blocked_until_ms = (wall_s + 600) * 1000 + 1,
        .backoff_ms = 60_000,
    });

    const blocked = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expectEqual(ScrobblerState.disabled, blocked.state);
    try std.testing.expectEqual(@as(?i64, wall_s + 601), blocked.blocked_until);

    rig.clock.advance(601 * 1000);
    try std.testing.expectEqual(@as(?i64, null), (try rig.runtime.libraryScrobblerStatus(fixture.library)).blocked_until);
}

test "with scrobbling on, a listen is recorded, queued and delivered to ListenBrainz" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-scrobbled?mode=memory&cache=shared");
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);
    try rig.play(player, 100_000);

    _ = try rig.awaitPlayCount(fixture.library, fixture.track_id, 1);
    var deadline: runtime_tests.TestDeadline = .init(5_000);
    while ((try rig.runtime.libraryScrobblerStatus(fixture.library)).delivered_total != 1) {
        if (!deadline.tick()) return error.ListenNotDelivered;
    }
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.requestCount());
    const library_database = try libraryDatabase(&rig.runtime, fixture.library);
    try std.testing.expectEqual(@as(u64, 0), try library_database.scrobbles.pendingCount());
    const status = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expect(status.enabled);
    try std.testing.expectEqual(ScrobblerState.idle, status.state);
}

test "destroying one Library leaves another Library's listens recorded" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const doomed = try rig.openLibrary("file:orca-listen-doomed?mode=memory&cache=shared");
    const kept = try rig.openLibrary("file:orca-listen-kept?mode=memory&cache=shared");
    const doomed_player = try rig.runtime.createPlayer();
    const kept_player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(doomed_player, doomed.library, std.testing.io);
    try rig.runtime.playerBindLibrary(kept_player, kept.library, std.testing.io);

    try rig.runtime.destroyLibrary(doomed.library);

    try rig.startPlaying(kept_player, kept.library, kept.track_id, 3);
    try rig.play(kept_player, 100_000);
    _ = try rig.awaitPlayCount(kept.library, kept.track_id, 1);
    try std.testing.expect((try rig.runtime.libraries.get(kept.library)).listens.?.worker != null);
}

test "shutdown interrupts a hung ListenBrainz request promptly and leaves the listen queued" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    rig.listenbrainz.hang = true;
    const uri = "file:orca-listen-hung?mode=memory&cache=shared";
    const fixture = try rig.openLibrary(uri);
    var witness = try database.LibraryDatabase.open(std.testing.allocator, std.testing.io, uri);
    defer witness.close();
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);
    try rig.play(player, 100_000);
    var deadline: runtime_tests.TestDeadline = .init(5_000);
    while (rig.listenbrainz.requestCount() == 0) {
        if (!deadline.tick()) return error.RequestNeverSent;
    }

    const started = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    rig.runtime.shutdown();
    const elapsed = std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - started;
    try std.testing.expect(elapsed < 500);

    try std.testing.expectEqual(@as(u64, 1), try witness.scrobbles.pendingCount());
    const now_s = std.Io.Clock.real.now(std.testing.io).toSeconds();
    const unleased = try witness.scrobbles.lease(std.testing.allocator, "listenbrainz", 42, now_s, now_s + 60, 10);
    defer {
        for (unleased) |entry| entry.deinit();
        std.testing.allocator.free(unleased);
    }
    try std.testing.expectEqual(@as(usize, 1), unleased.len);
    try std.testing.expectEqual(@as(u32, 0), unleased[0].attempt_count);
}

test "a Player and a Library with the same slot and generation own different work" {
    const player_owner = runtime_module.playerOwnerTag(.{ .index = 0, .generation = 1 });
    const library_owner = runtime_module.libraryOwnerTag(.{ .index = 0, .generation = 1 });
    try std.testing.expect(!player_owner.eql(library_owner));

    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-owners?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try std.testing.expect(player.index == fixture.library.index and player.generation == fixture.library.generation);
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    const worker = (try rig.runtime.libraries.get(fixture.library)).listens.?.worker.?;

    try rig.runtime.destroyPlayer(player);

    try std.testing.expectEqual(@as(usize, 1), runtime_tests.inFlightWorkCount(&rig.runtime));
    try std.testing.expect(!worker.registration.cancellationRequested());
}

test "only one Library at a time may scrobble" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const first = try rig.openLibrary("file:orca-listen-first?mode=memory&cache=shared");
    const second = try rig.openLibrary("file:orca-listen-second?mode=memory&cache=shared");
    try rig.runtime.librarySetScrobbling(first.library, true, false, false);
    try std.testing.expectError(
        error.ScrobblingEnabledElsewhere,
        rig.runtime.librarySetScrobbling(second.library, true, false, false),
    );
    try rig.runtime.librarySetScrobbling(second.library, false, false, false);
    try rig.runtime.librarySetScrobbling(first.library, false, false, false);
    try rig.runtime.librarySetScrobbling(second.library, true, false, false);
    try std.testing.expect(!(try rig.runtime.libraryScrobblerStatus(first.library)).enabled);
    try std.testing.expect((try rig.runtime.libraryScrobblerStatus(second.library)).enabled);
}

test "an idle scrobbling worker looks up no token and sends nothing" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    rig.runtime.listen_hooks.poll_ms = 1;
    const fixture = try rig.openLibrary("file:orca-listen-idle?mode=memory&cache=shared");
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try rig.awaitWorkerPasses(200);
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.token_lookups.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requestCount());
}

test "a ListenBrainz server is refused unless it is https or loopback" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    try std.testing.expectError(error.InvalidServerUrl, rig.runtime.setListenBrainzServer("http://listenbrainz.example.org"));
    try std.testing.expectError(error.InvalidServerUrl, rig.runtime.setListenBrainzServer("http://127.0.0.1@example.org"));
    try rig.runtime.setListenBrainzServer("http://127.0.0.1:8080");
    try rig.runtime.setListenBrainzServer("https://lb.example.org");
    try std.testing.expectEqualStrings("https://lb.example.org", rig.runtime.listenbrainz_server.view());
}

test "a changed token is validated once, and only once scrobbling is on" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    rig.runtime.listen_hooks.poll_ms = 1;
    const fixture = try rig.openLibrary("file:orca-listen-validate?mode=memory&cache=shared");
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    for (0..3) |_| try rig.runtime.libraryScrobblerCredentialsChanged(fixture.library);
    try rig.awaitWorkerPasses(20);
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requestCount());

    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    var deadline: runtime_tests.TestDeadline = .init(5_000);
    while (true) {
        const status = try rig.runtime.libraryScrobblerStatus(fixture.library);
        if (std.mem.eql(u8, status.user_name.slice(), "listener")) break;
        if (!deadline.tick()) return error.TokenNeverValidated;
    }
    try rig.awaitWorkerPasses(20);
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.requestCount());
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.token_lookups.load(.acquire));
}

test "identity, token store and server set while a worker runs apply to its next submission, the identity as a copy" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-identity?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try rig.awaitWorkerPasses(3);

    try std.testing.expectError(
        error.InvalidNetworkConfiguration,
        rig.runtime.setClientIdentity(.{ .name = "Player (beta)", .version = "1", .contact = "a@b.c" }),
    );
    var name = "Player".*;
    try rig.runtime.setClientIdentity(.{ .name = &name, .version = "1.0", .contact = "https://player.example" });
    @memset(&name, 'x');
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.setListenBrainzServer("http://127.0.0.1:8080");

    try rig.startPlaying(player, fixture.library, fixture.track_id, 1);
    try rig.play(player, 100_000);
    try rig.awaitDelivered(fixture.library, 1);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/1/submit-listens", rig.listenbrainz.transport.lastUrl());
    try std.testing.expect(std.mem.startsWith(u8, rig.listenbrainz.transport.lastUserAgent(), "Player/1.0 ( https://player.example )"));
    try std.testing.expect(rig.listenbrainz.token_lookups.load(.acquire) >= 1);
    const library_database = try libraryDatabase(&rig.runtime, fixture.library);
    var statement = try library_database.database.prepare("SELECT player_client FROM listens;");
    defer statement.deinit();
    try std.testing.expect(try statement.step() == .row);
    try std.testing.expectEqualStrings("Player", statement.columnText(0));
}

test "closing one Library leaves the network Io another Library's worker is using" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const doomed = try rig.openLibrary("file:orca-listen-io-doomed?mode=memory&cache=shared");
    const survivor = try rig.openLibrary("file:orca-listen-io-survivor?mode=memory&cache=shared");
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(survivor.library, true, false, false);
    const doomed_player = try rig.runtime.createPlayer();
    const survivor_player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(doomed_player, doomed.library, std.testing.io);
    try rig.runtime.playerBindLibrary(survivor_player, survivor.library, std.testing.io);
    const network_io = rig.runtime.network_threaded.?;

    try rig.runtime.destroyLibrary(doomed.library);

    try std.testing.expectEqual(network_io, rig.runtime.network_threaded.?);
    try rig.startPlaying(survivor_player, survivor.library, survivor.track_id, 1);
    try rig.play(survivor_player, 100_000);
    try rig.awaitDelivered(survivor.library, 1);
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.requestCount());
}

test "a scrobbling Library's worker restarts after another Library closes and delivers its backlog when due" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const doomed = try rig.openLibrary("file:orca-listen-restart-doomed?mode=memory&cache=shared");
    const scrobbling = try rig.openLibrary("file:orca-listen-restart-scrobbling?mode=memory&cache=shared");
    const due_at = @divFloor(FakeListenBrainz.wall_base_ms, 1000) + 60;
    try rig.queueBacklog(scrobbling.library, due_at);
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(scrobbling.library, true, false, false);
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, doomed.library, std.testing.io);
    try rig.awaitWorkerPasses(3);

    try rig.runtime.destroyLibrary(doomed.library);

    try std.testing.expect((try rig.runtime.libraries.get(scrobbling.library)).listens.?.worker != null);
    try rig.awaitWorkerPasses(3);
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requestCount());
    rig.listenbrainz.advance(61_000);
    try rig.awaitDelivered(scrobbling.library, 1);
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.requestCount());
}

test "a listen that ends after its Library's worker was drained still records its final time" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const doomed = try rig.openLibrary("file:orca-listen-late-doomed?mode=memory&cache=shared");
    const kept = try rig.openLibrary("file:orca-listen-late-kept?mode=memory&cache=shared");
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, kept.library, std.testing.io);
    try rig.startPlaying(player, kept.library, kept.track_id, 7);
    try rig.play(player, 150_000);
    _ = try rig.awaitPlayCount(kept.library, kept.track_id, 1);

    try rig.runtime.destroyLibrary(doomed.library);
    try std.testing.expect((try rig.runtime.libraries.get(kept.library)).listens.?.worker == null);
    try rig.runtime.destroyPlayer(player);

    const library_database = try libraryDatabase(&rig.runtime, kept.library);
    var deadline: runtime_tests.TestDeadline = .init(5_000);
    while (deadline.tick()) {
        var statement = try library_database.database.prepare("SELECT listened_ms FROM listens;");
        defer statement.deinit();
        if (try statement.step() == .row and statement.columnInt64(0) == 149_900) return;
    }
    return error.FinishedListenNotRecorded;
}

test "an idle scrobbling worker finds listens another process queued at its next recheck" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-listen-recheck?mode=memory&cache=shared");
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try rig.awaitWorkerPasses(3);

    try rig.queueBacklog(fixture.library, 0);
    try rig.awaitWorkerPasses(20);
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requestCount());
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.token_lookups.load(.acquire));

    rig.listenbrainz.advance(5 * 60 * 1000);
    try rig.awaitDelivered(fixture.library, 1);
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.requestCount());
}

const feedback_mbid = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";

test "a Track loved while scrobbling is on reaches ListenBrainz through the worker" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-feedback-love?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, feedback_mbid);
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try rig.awaitWorkerPasses(3);

    const change = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .loved);

    try std.testing.expectEqual(@as(u32, 1), change.updated);
    try rig.awaitWorkerPasses(3);
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.feedback_sent.load(.acquire));
    rig.listenbrainz.advance(2_000);
    try ListenRig.awaitCount(&rig.listenbrainz.feedback_sent, 1);
    try rig.awaitFeedbackSettled(fixture.library);
    try std.testing.expectEqual(@as(i32, 1), rig.listenbrainz.last_score.load(.acquire));
    try std.testing.expectEqual(Feedback.loved, try rig.runtime.libraryTrackFeedback(fixture.library, fixture.track_id));
    try rig.awaitWorkerPasses(10);
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.feedback_sent.load(.acquire));
}

test "feedback given while scrobbling was off is reported pending and sent once it is turned on" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-feedback-later?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, feedback_mbid);
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());

    _ = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .hated);

    const stored = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expectEqual(@as(u64, 1), stored.feedback_pending);
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requestCount());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try ListenRig.awaitCount(&rig.listenbrainz.feedback_sent, 1);
    try rig.awaitFeedbackSettled(fixture.library);
    try std.testing.expectEqual(@as(i32, -1), rig.listenbrainz.last_score.load(.acquire));
}

test "loving a Release leaves the feedback queued for ListenBrainz as it was and asks nothing" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-release-love?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, feedback_mbid);
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    const library_database = try libraryDatabase(&rig.runtime, fixture.library);
    const album = try library_database.releases.upsert(.{ .release_key = "bryter layter", .title = "Bryter Layter" });
    _ = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .loved);
    const before = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expectEqual(@as(u64, 1), before.feedback_pending);

    const change = try rig.runtime.librarySetReleaseLove(fixture.library, &.{ album, album + 1 }, true);

    try std.testing.expectEqual(@as(u32, 1), change.updated);
    try std.testing.expectEqual(@as(u32, 1), change.skipped);
    const after = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expectEqual(before.feedback_pending, after.feedback_pending);
    try std.testing.expectEqual(@as(i64, 1), try database.columns.scalar(library_database.database, "SELECT count(*) FROM feedback;"));
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requestCount());
    var loved = try rig.runtime.libraryReleasePage(fixture.library, .{ .loved_only = true });
    defer loved.deinit();
    try std.testing.expectEqual(@as(usize, 1), loved.items.len);
    try std.testing.expectEqual(album, loved.items[0].id);
    try std.testing.expectEqual(@as(u64, 1), try rig.runtime.libraryReleaseCountMatching(fixture.library, .{ .loved_only = true }));
    var found = try rig.runtime.libraryTrackQuery(fixture.library, "Northern", .{ .loved_only = true });
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqual(fixture.track_id, found.items[0].id);
}

test "love, dislike and love again while the love is being sent ends loved after at most two requests" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-feedback-flip?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, feedback_mbid);
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try rig.awaitWorkerPasses(3);
    const library_database = try libraryDatabase(&rig.runtime, fixture.library);
    const Flip = struct {
        library: *database.LibraryDatabase,
        track_id: i64,

        fn run(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.library.feedback.set(&.{self.track_id}, .hated) catch return;
            _ = self.library.feedback.set(&.{self.track_id}, .loved) catch return;
        }
    };
    var flip: Flip = .{ .library = library_database, .track_id = fixture.track_id };
    rig.listenbrainz.during_feedback = .{ .context = &flip, .run = Flip.run };

    _ = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .loved);
    try rig.awaitWorkerPasses(3);
    rig.listenbrainz.advance(2_000);

    try ListenRig.awaitCount(&rig.listenbrainz.feedback_sent, 1);
    try rig.awaitFeedbackSettled(fixture.library);
    try rig.awaitWorkerPasses(10);
    try std.testing.expect(rig.listenbrainz.feedback_sent.load(.acquire) <= 2);
    try std.testing.expectEqual(@as(i32, 1), rig.listenbrainz.last_score.load(.acquire));
    try std.testing.expectEqual(Feedback.loved, try rig.runtime.libraryTrackFeedback(fixture.library, fixture.track_id));
}

test "a recording without a MusicBrainz id is loved locally, never sent, and costs an idle worker nothing" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    rig.runtime.listen_hooks.poll_ms = 1;
    const fixture = try rig.openLibrary("file:orca-feedback-untagged?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, null);
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);

    _ = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .loved);
    try rig.awaitWorkerPasses(200);

    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requestCount());
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.token_lookups.load(.acquire));
    const status = try rig.runtime.libraryScrobblerStatus(fixture.library);
    try std.testing.expectEqual(@as(u64, 0), status.feedback_pending);
    const details = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer details.deinit();
    try std.testing.expectEqual(Feedback.loved, details.feedback);
    try std.testing.expect(!details.feedback_syncable);
}

test "a rejected feedback change is recorded and not sent again" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-feedback-rejected?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, feedback_mbid);
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    rig.listenbrainz.feedback_status.store(400, .release);
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);

    try rig.awaitWorkerPasses(3);
    _ = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .loved);
    try rig.awaitWorkerPasses(3);
    rig.listenbrainz.advance(2_000);

    try ListenRig.awaitCount(&rig.listenbrainz.feedback_sent, 1);
    try rig.awaitFeedbackSettled(fixture.library);
    rig.listenbrainz.advance(10 * 60 * 1000);
    try rig.awaitWorkerPasses(20);
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.feedback_sent.load(.acquire));
    const details = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer details.deinit();
    try std.testing.expectEqual(Feedback.loved, details.feedback);
    try std.testing.expect(details.feedback_syncable);
}

test "track pages and details carry the feedback of the recording" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-feedback-pages?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, feedback_mbid);

    _ = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .hated);

    var page = try rig.runtime.libraryTrackQuery(fixture.library, "", .{ .limit = 8 });
    defer page.deinit();
    try std.testing.expectEqual(Feedback.hated, page.items[0].feedback);
    const details = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer details.deinit();
    try std.testing.expectEqual(Feedback.hated, details.feedback);
    try std.testing.expect(details.feedback_syncable);

    _ = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .none);
    try std.testing.expectEqual(Feedback.none, try rig.runtime.libraryTrackFeedback(fixture.library, fixture.track_id));
}

test "Now Playing is announced once a track has been heard for ten seconds, when the option is on" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-now-playing-on?mode=memory&cache=shared");
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, true);
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);

    try rig.play(player, 9_900);
    try rig.awaitWorkerPasses(5);
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.now_playing_sent.load(.acquire));
    try rig.play(player, 300);

    try ListenRig.awaitCount(&rig.listenbrainz.now_playing_sent, 1);
    try rig.play(player, 20_000);
    try rig.awaitWorkerPasses(10);
    try std.testing.expectEqual(@as(u32, 1), rig.listenbrainz.now_playing_sent.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.listens_sent.load(.acquire));
}

test "Now Playing is never sent unless the option and scrobbling are both on" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-now-playing-off?mode=memory&cache=shared");
    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    const player = try rig.runtime.createPlayer();
    try rig.runtime.playerBindLibrary(player, fixture.library, std.testing.io);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 7);

    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try rig.play(player, 20_000);
    try rig.runtime.librarySetScrobbling(fixture.library, false, false, true);
    try rig.startPlaying(player, fixture.library, fixture.track_id, 8);
    try rig.play(player, 20_000);
    try rig.awaitWorkerPasses(20);

    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.now_playing_sent.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), rig.listenbrainz.requestCount());
}

pub const northern_sky_mbid = "0b3c4d5e-6f70-4812-9a3b-4c5d6e7f8091";
pub const pink_moon_mbid = "1d2e3f40-5162-4738-8a9b-0c1d2e3f4a5b";

fn recordingEntry(comptime mbid: []const u8, comptime title: []const u8) []const u8 {
    return "{\"id\":\"" ++ mbid ++ "\",\"score\":100,\"title\":\"" ++ title ++
        "\",\"length\":180000,\"artist-credit\":[{\"name\":\"Nick Drake\"}],\"releases\":[{" ++
        "\"id\":\"2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b\",\"title\":\"Bryter Layter\"," ++
        "\"media\":[{\"track-offset\":2,\"track\":[{\"number\":\"3\"}]}]}]}";
}

fn recordingAnswer(comptime mbid: []const u8, comptime title: []const u8) []const u8 {
    return "{\"recordings\":[" ++ recordingEntry(mbid, title) ++ "]}";
}

pub const northern_sky_answer = recordingAnswer(northern_sky_mbid, "Northern Sky");
pub const pink_moon_answer = recordingAnswer(pink_moon_mbid, "Pink Moon");

const nick_drake_mbid = "5c6d7e8f-9a0b-4c1d-8e2f-3a4b5c6d7e8f";
const bryter_layter_group_mbid = "4b5c6d7e-8f90-4a1b-8c2d-3e4f5a6b7c8d";
const northern_sky_track_mbid = "6d7e8f9a-0b1c-4d2e-8f3a-4b5c6d7e8f9a";
const pink_moon_track_mbid = "7e8f9a0b-1c2d-4e3f-8a4b-5c6d7e8f9a0b";

fn releaseTrack(comptime track_mbid: []const u8, comptime position: []const u8, comptime title: []const u8, comptime recording_mbid: []const u8) []const u8 {
    return "{\"id\":\"" ++ track_mbid ++ "\",\"position\":" ++ position ++ ",\"number\":\"" ++ position ++
        "\",\"title\":\"" ++ title ++ "\",\"artist-credit\":[{\"name\":\"Nick Drake\",\"joinphrase\":\"\"," ++
        "\"artist\":{\"id\":\"" ++ nick_drake_mbid ++ "\"}}],\"recording\":{\"id\":\"" ++ recording_mbid ++ "\"}}";
}

/// The release `recordingAnswer` names, as a release lookup answers.
const bryter_layter_release = "{\"id\":\"" ++ bryter_layter_mbid ++ "\",\"title\":\"Bryter Layter\",\"date\":\"1971-03-01\"," ++
    "\"artist-credit\":[{\"name\":\"Nick Drake\",\"joinphrase\":\"\",\"artist\":{\"id\":\"" ++ nick_drake_mbid ++ "\"}}]," ++
    "\"release-group\":{\"id\":\"" ++ bryter_layter_group_mbid ++ "\"},\"media\":[{\"position\":1,\"tracks\":[" ++
    releaseTrack(northern_sky_track_mbid, "3", "Northern Sky", northern_sky_mbid) ++ "," ++
    releaseTrack(pink_moon_track_mbid, "4", "Pink Moon", pink_moon_mbid) ++ "]}]}";

/// Every call arrives on the job's thread; a test reads the request count
/// while the job runs and the rest only once it is reaped.
pub const FakeMusicBrainz = struct {
    transport: network.testing.ScriptedTransport = .{},
    clock: network.testing.TestClock = .{ .wall_offset_ms = wall_base_ms },
    answers: []const Answer = &.{},
    refusals: []const u16 = &.{},
    failure: ?anyerror = null,
    hang_from: ?u32 = null,
    /// What a release lookup answers, and with which status.
    release_status: u16 = 200,
    release_body: []const u8 = bryter_layter_release,

    const Answer = struct { title: []const u8, body: []const u8 };
    const wall_base_ms: i64 = 1_800_000_000_000;

    pub fn hooks(self: *FakeMusicBrainz) MatchingHooks {
        self.transport.clock = &self.clock;
        self.transport.responder = .{ .context = self, .respond_fn = respond };
        return .{
            .transport = self.transport.transport(),
            .clock = self.clock.clock(),
            .wall_clock = self.clock.wallClock(),
        };
    }

    pub fn requestCount(self: *const FakeMusicBrainz) u32 {
        return self.transport.requestCount();
    }

    fn respond(context: *anyopaque, exchange: network.testing.Exchange, _: ?network.testing.Reply) anyerror!network.testing.Reply {
        const self: *FakeMusicBrainz = @ptrCast(@alignCast(context));
        if (self.hang_from) |first| if (exchange.index >= first) return .hang;
        if (self.failure) |err| return .{ .fail = err };
        if (exchange.index < self.refusals.len)
            return .{ .respond = .{ .status = self.refusals[exchange.index], .body = "" } };
        if (std.mem.indexOf(u8, exchange.request.url, "/ws/2/release/") != null)
            return .{ .respond = .{ .status = self.release_status, .body = self.release_body } };
        const body = for (self.answers) |answer| {
            if (std.mem.indexOf(u8, exchange.request.url, answer.title) != null) break answer.body;
        } else "{\"recordings\":[]}";
        return .{ .respond = .{ .body = body } };
    }

    fn awaitRequests(self: *const FakeMusicBrainz, expected: u32) !void {
        var deadline: runtime_tests.TestDeadline = .init(5_000);
        while (self.requestCount() < expected) {
            if (!deadline.tick()) return error.RequestNeverSent;
        }
    }
};

pub fn addMatchTrack(library_database: *database.LibraryDatabase, title: []const u8, artist: []const u8, mbid: ?[]const u8) !i64 {
    const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
    try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = title,
        .musicbrainz_recording_id = mbid,
    } });
    try library_database.tracks.upsertTracks(&.{.{
        .title = title,
        .artist = artist,
        .album = "Bryter Layter",
        .duration_ms = 180_000,
        .preferred_file_id = file_id,
    }});
    const ids = try library_database.tracks.idsForFile(std.testing.allocator, file_id);
    defer std.testing.allocator.free(ids);
    return ids[0];
}

test "a matching job proposes recordings for the Tracks without one, one search a Track, and a rerun asks nothing already answered" {
    var fake: FakeMusicBrainz = .{ .answers = &.{
        .{ .title = "Northern%20Sky", .body = northern_sky_answer },
        .{ .title = "Pink%20Moon", .body = pink_moon_answer },
    } };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    try std.testing.expectError(error.InvalidServerUrl, runtime.setMusicBrainzServer("http://musicbrainz.org"));
    try runtime.setMusicBrainzServer("http://127.0.0.1:5000");
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-job?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);
    _ = try addMatchTrack(library_database, "Hazey Jane II", "Nick Drake", "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a");
    _ = try addMatchTrack(library_database, "Untitled", "", null);
    const pink_moon = try addMatchTrack(library_database, "Pink Moon", "Nick Drake", null);
    try library_database.database.exec(
        "INSERT INTO recordings(title) VALUES ('Pink Moon');" ++
            "UPDATE files SET recording_id = (SELECT max(id) FROM recordings) " ++
            "WHERE id = (SELECT preferred_file_id FROM tracks WHERE title = 'Pink Moon');" ++
            "UPDATE tracks SET recording_id = (SELECT max(id) FROM recordings) WHERE title = 'Pink Moon';" ++
            "INSERT INTO files(audio_format, size_bytes, recording_id) VALUES (2, 512, (SELECT max(id) FROM recordings));",
    );
    _ = try addMatchTrack(library_database, "Unknown Song", "Nobody", null);

    const job_handle = try runtime.startLibraryMatching(library, .{ .batch_size = 2 });

    try std.testing.expectEqual(@as(?u64, 4), (try runtime.jobSnapshotSynced(job_handle)).total_units);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, job_handle));
    const stats = try runtime.jobMatchStats(job_handle);
    try std.testing.expectEqual(@as(u64, 4), stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 2), stats.matched);
    try std.testing.expectEqual(@as(u64, 1), stats.unmatched);
    try std.testing.expectEqual(@as(u64, 1), stats.insufficient_evidence);
    try std.testing.expectEqual(@as(u64, 4), stats.requests);
    try std.testing.expectEqual(@as(u64, 0), stats.cache_hits);
    try std.testing.expectEqual(@as(u64, 2), stats.proposals_stored);
    try std.testing.expectEqual(ScanStats{}, try runtime.jobScanStats(job_handle));
    try std.testing.expectEqual(@as(u32, 4), fake.requestCount());
    try std.testing.expect(std.mem.startsWith(u8, fake.transport.lastUrl(), "http://127.0.0.1:5000/ws/2/recording?fmt=json&limit=10&query="));

    const proposals = try runtime.libraryMatchProposals(library, northern_sky, 10);
    defer proposals.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposals.items.len);
    const proposal = proposals.items[0];
    try std.testing.expectEqualStrings(northern_sky_mbid, proposal.recording_mbid);
    try std.testing.expectEqualStrings("Nick Drake", proposal.artist);
    try std.testing.expectEqualStrings("Bryter Layter", proposal.album);
    try std.testing.expectEqualStrings("2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b", proposal.release_mbid.?);
    try std.testing.expectEqual(@as(?u32, 3), proposal.track_number);
    try std.testing.expectEqual(@as(?u64, 180_000), proposal.duration_ms);
    try std.testing.expectEqual(@as(?u8, 100), proposal.musicbrainz_score);
    try std.testing.expect(proposal.confidence > 0.9);
    const pink_proposals = try runtime.libraryMatchProposals(library, pink_moon, 10);
    defer pink_proposals.deinit();
    try std.testing.expectEqualStrings(pink_moon_mbid, pink_proposals.items[0].recording_mbid);

    runtime.reapFinishedJobs();
    const rerun = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, rerun));
    const rerun_stats = try runtime.jobMatchStats(rerun);
    try std.testing.expectEqual(@as(u64, 1), rerun_stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 1), rerun_stats.insufficient_evidence);
    try std.testing.expectEqual(@as(u64, 0), rerun_stats.requests);
    try std.testing.expectEqual(@as(u64, 0), rerun_stats.cache_hits);
    try std.testing.expectEqual(AcoustIdUse.no_client_key, rerun_stats.acoustid);
    try std.testing.expectEqual(@as(u32, 4), fake.requestCount());
}

test "an accepted match gives the Track a recording id, which its love is sent to ListenBrainz under" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    var fake: FakeMusicBrainz = .{ .answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_answer }} };
    rig.runtime.matching_hooks = fake.hooks();
    const fixture = try rig.openLibrary("file:orca-matching-accept?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, null);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&rig.runtime, try rig.runtime.startLibraryMatching(fixture.library, .{})));
    const proposals = try rig.runtime.libraryMatchProposals(fixture.library, fixture.track_id, 10);
    defer proposals.deinit();
    const before = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer before.deinit();
    try std.testing.expect(!before.feedback_syncable);
    try std.testing.expectEqual(@as(?[]u8, null), before.musicbrainz_recording_id);

    const acceptance = try rig.runtime.libraryAcceptMatch(fixture.library, proposals.items[0].id);

    try std.testing.expect(acceptance.values_written >= 1);
    try std.testing.expectError(error.StaleIdentificationProposal, rig.runtime.libraryAcceptMatch(fixture.library, proposals.items[0].id));
    const after = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer after.deinit();
    try std.testing.expect(after.feedback_syncable);
    try std.testing.expectEqualStrings(northern_sky_mbid, after.musicbrainz_recording_id.?);
    try std.testing.expectEqual(@as(?RecordingIdSource, .match), after.musicbrainz_recording_id_source);

    try rig.runtime.setCredentialStore(rig.listenbrainz.store());
    _ = try rig.runtime.librarySetFeedback(fixture.library, &.{fixture.track_id}, .loved);
    try rig.runtime.librarySetScrobbling(fixture.library, true, false, false);
    try rig.awaitWorkerPasses(3);
    rig.listenbrainz.advance(2_000);
    try ListenRig.awaitCount(&rig.listenbrainz.feedback_sent, 1);
    try std.testing.expectEqualStrings(northern_sky_mbid, &rig.listenbrainz.feedback_mbid);
}

test "a Track's recording id names where it came from, and only a well-formed one can be set by hand" {
    var rig: ListenRig = undefined;
    rig.init();
    defer rig.runtime.deinit();
    const fixture = try rig.openLibrary("file:orca-matching-source?mode=memory&cache=shared");
    try rig.identify(fixture.library, fixture.track_id, northern_sky_mbid);
    const tagged = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer tagged.deinit();
    try std.testing.expectEqual(@as(?RecordingIdSource, .tag), tagged.musicbrainz_recording_id_source);

    try std.testing.expectError(error.InvalidEditValue, rig.runtime.libraryEditTracks(
        fixture.library,
        &.{fixture.track_id},
        &.{.{ .field = .musicbrainz_recording_id, .value = "not-a-recording" }},
    ));
    const library_database = try libraryDatabase(&rig.runtime, fixture.library);
    const file_ids = try library_database.tracks.fileIds(std.testing.allocator, fixture.track_id);
    defer std.testing.allocator.free(file_ids);
    try library_database.orca_metadata.upsert(.{
        .file_id = file_ids[0],
        .field = .musicbrainz_recording_id,
        .value = pink_moon_mbid,
        .provenance = .user,
        .locked = true,
    });
    const edited = (try rig.runtime.libraryTrackDetails(fixture.library, fixture.track_id)).?;
    defer edited.deinit();
    try std.testing.expectEqualStrings(pink_moon_mbid, edited.musicbrainz_recording_id.?);
    try std.testing.expectEqual(@as(?RecordingIdSource, .edit), edited.musicbrainz_recording_id_source);
}

test "a matching job stops when cancelled mid-search, and another cannot start while it runs" {
    var fake: FakeMusicBrainz = .{ .answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_answer }}, .hang_from = 2 };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-cancel?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);
    _ = try addMatchTrack(library_database, "Pink Moon", "Nick Drake", null);
    _ = try addMatchTrack(library_database, "River Man", "Nick Drake", null);

    const job_handle = try runtime.startLibraryMatching(library, .{});
    try fake.awaitRequests(3);
    try std.testing.expectEqual(@as(u64, 1), (try runtime.jobMatchStats(job_handle)).matched);
    try std.testing.expectError(error.MatchingAlreadyRunning, runtime.startLibraryMatching(library, .{}));
    try runtime.cancelJob(job_handle);

    try std.testing.expectEqual(job.State.cancelled, try runtime_tests.awaitJob(&runtime, job_handle));
    const stats = try runtime.jobMatchStats(job_handle);
    try std.testing.expect(stats.cancelled);
    try std.testing.expectEqual(@as(u64, 1), stats.tracks_examined);
    try std.testing.expectEqual(@as(u32, 3), fake.requestCount());
    const proposals = try runtime.libraryMatchProposals(library, northern_sky, 10);
    defer proposals.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposals.items.len);
    try std.testing.expectEqual(@as(u64, 2), try library_database.identification_proposals.unidentifiedCount(.library, .unidentified, false, null));

    fake.hang_from = null;
    const resumed = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, resumed));
    try std.testing.expectEqual(@as(u64, 2), (try runtime.jobMatchStats(resumed)).tracks_examined);
    try std.testing.expectEqual(@as(u32, 5), fake.requestCount());
}

test "a job worker keeps the pump timeout at 100 ms until it is reaped" {
    var fake: FakeMusicBrainz = .{ .hang_from = 0 };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var counter: control.CountingWaker = .{};
    try runtime.setWaker(counter.waker());
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-timeout?mode=memory&cache=shared");
    _ = try addMatchTrack(try libraryDatabase(&runtime, library), "Northern Sky", "Nick Drake", null);
    try std.testing.expectEqual(@as(?u64, null), runtime.nextPumpTimeoutMs());

    const job_handle = try runtime.startLibraryMatching(library, .{});
    try fake.awaitRequests(1);
    try std.testing.expectEqual(@as(?u64, runtime_jobs.job_progress_interval_ms), runtime.nextPumpTimeoutMs());
    try std.testing.expectEqual(@as(u32, 0), counter.count());

    try runtime.cancelJob(job_handle);
    var deadline: runtime_tests.TestDeadline = .init(5_000);
    while (counter.count() == 0 and deadline.tick()) {}
    try std.testing.expectEqual(@as(u32, 1), counter.count());
    try std.testing.expectEqual(@as(?u64, 0), runtime.nextPumpTimeoutMs());
    runtime.pump();
    var finished = false;
    while (runtime.pollEvent()) |event| switch (event.outcome) {
        .job_finished => |value| finished = finished or value.job.eql(job_handle),
        else => {},
    };
    try std.testing.expect(finished);
    try std.testing.expectEqual(@as(?u64, null), runtime.nextPumpTimeoutMs());
}

test "matching, AcoustID submission and scrobbling are refused until the host names itself, and nothing is sent" {
    var fake: FakeMusicBrainz = .{ .answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_answer }} };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-anonymous?mode=memory&cache=shared");
    _ = try addMatchTrack(try libraryDatabase(&runtime, library), "Northern Sky", "Nick Drake", null);

    try std.testing.expectError(error.ClientIdentityRequired, runtime.startLibraryMatching(library, .{}));
    try std.testing.expectError(error.ClientIdentityRequired, runtime.startAcoustIdSubmission(library));
    try std.testing.expectError(error.ClientIdentityRequired, runtime.librarySetScrobbling(library, true, false, false));
    try runtime.librarySetScrobbling(library, false, false, false);
    try std.testing.expectEqual(@as(usize, 0), runtime.job_workers.items.len);
    try std.testing.expectEqual(@as(u32, 0), fake.requestCount());

    try runtime.setClientIdentity(network.testing.test_identity);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, try runtime.startLibraryMatching(library, .{})));
    try std.testing.expectEqual(@as(u32, 2), fake.requestCount());
    try std.testing.expect(std.mem.startsWith(u8, fake.transport.lastUserAgent(), "Orca/"));
}

test "a refused search is waited out and retried, and an unreachable MusicBrainz stops the job without marking the Track" {
    var fake: FakeMusicBrainz = .{
        .answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_answer }},
        .refusals = &.{ 503, 429 },
    };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-backoff?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);

    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, try runtime.startLibraryMatching(library, .{})));

    try std.testing.expectEqual(@as(u32, 4), fake.requestCount());
    try expectWaited(&fake.transport, 1, 5_000);
    try std.testing.expect(fake.transport.request_times_ms[2] - fake.transport.request_times_ms[1] >= 60_000);
    const proposals = try runtime.libraryMatchProposals(library, northern_sky, 10);
    defer proposals.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposals.items.len);

    _ = try addMatchTrack(library_database, "Pink Moon", "Nick Drake", null);
    fake.failure = error.ConnectionRefused;
    const unreachable_job = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.failed, try runtime_tests.awaitJob(&runtime, unreachable_job));
    try std.testing.expectEqual(@as(u64, 0), (try runtime.jobMatchStats(unreachable_job)).tracks_examined);
    try std.testing.expectEqual(@as(u64, 1), try library_database.identification_proposals.unidentifiedCount(.library, .unidentified, false, null));

    fake.failure = null;
    const retried = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, retried));
    const retried_stats = try runtime.jobMatchStats(retried);
    try std.testing.expectEqual(@as(u64, 1), retried_stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 1), retried_stats.requests);
}

/// That request `index` followed the one before it by a jittered `nominal_ms`.
fn expectWaited(transport: *const network.testing.ScriptedTransport, index: usize, nominal_ms: i64) !void {
    try expectJittered(transport.request_times_ms[index] - transport.request_times_ms[index - 1], nominal_ms);
}

fn expectJittered(waited_ms: i64, nominal_ms: i64) !void {
    try std.testing.expect(waited_ms >= @divFloor(nominal_ms, 2) and waited_ms <= nominal_ms + @divFloor(nominal_ms, 2));
}

fn matchAfterOutages(fake: *FakeMusicBrainz, name: [:0]const u8) !job.State {
    fake.answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_answer }};
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, name);
    const library_database = try libraryDatabase(&runtime, library);
    _ = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);
    const state = try runtime_tests.awaitJob(&runtime, try runtime.startLibraryMatching(library, .{}));
    const unmarked: u64 = if (state == .succeeded) 0 else 1;
    try std.testing.expectEqual(unmarked, try library_database.identification_proposals.unidentifiedCount(.library, .unidentified, false, null));
    return state;
}

test "a search MusicBrainz could not answer is asked again after about 5 s, then about 30 s, and a third failure stops the job without marking the Track" {
    var once: FakeMusicBrainz = .{ .refusals = &.{503} };
    try std.testing.expectEqual(job.State.succeeded, try matchAfterOutages(&once, "file:orca-matching-outage-once?mode=memory&cache=shared"));
    try std.testing.expectEqual(@as(u32, 3), once.requestCount());
    try expectWaited(&once.transport, 1, 5_000);

    var twice: FakeMusicBrainz = .{ .refusals = &.{ 503, 503 } };
    try std.testing.expectEqual(job.State.succeeded, try matchAfterOutages(&twice, "file:orca-matching-outage-twice?mode=memory&cache=shared"));
    try std.testing.expectEqual(@as(u32, 4), twice.requestCount());
    try expectWaited(&twice.transport, 1, 5_000);
    try expectWaited(&twice.transport, 2, 30_000);

    var thrice: FakeMusicBrainz = .{ .refusals = &.{ 503, 503, 503 } };
    try std.testing.expectEqual(job.State.failed, try matchAfterOutages(&thrice, "file:orca-matching-outage-thrice?mode=memory&cache=shared"));
    try std.testing.expectEqual(@as(u32, 3), thrice.requestCount());
    try std.testing.expect(thrice.clock.slept() <= 7_500 + 45_000);
}

/// A test clock whose sleeps, once `armed_after` requests were sent, hold
/// until the test releases them, so it can act during a wait.
const GatedClock = struct {
    base: *network.testing.TestClock,
    transport: *const network.testing.ScriptedTransport,
    armed_after: u32,
    waiting: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),

    fn clock(self: *GatedClock) network.client.Clock {
        return .{ .context = self, .now_ms_fn = now, .sleep_ms_fn = sleep };
    }

    fn now(context: *anyopaque) i64 {
        const self: *GatedClock = @ptrCast(@alignCast(context));
        return self.base.now();
    }

    fn sleep(context: *anyopaque, milliseconds: u64) anyerror!void {
        const self: *GatedClock = @ptrCast(@alignCast(context));
        if (self.transport.requestCount() >= self.armed_after and !self.released.load(.acquire)) {
            self.waiting.store(true, .release);
            var deadline: runtime_tests.TestDeadline = .init(10_000);
            while (!self.released.load(.acquire) and deadline.tick()) {}
        }
        self.base.advance(@intCast(milliseconds));
    }

    fn awaitWaiting(self: *const GatedClock) !void {
        var deadline: runtime_tests.TestDeadline = .init(5_000);
        while (!self.waiting.load(.acquire)) if (!deadline.tick()) return error.NeverWaited;
    }
};

test "a matching job cancelled during the 30 s wait after an outage ends within a poll" {
    var fake: FakeMusicBrainz = .{ .refusals = &.{ 503, 503, 503 } };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    var gate: GatedClock = .{ .base = &fake.clock, .transport = &fake.transport, .armed_after = 2 };
    runtime.matching_hooks.clock = gate.clock();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-outage-cancel?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    _ = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);

    const handle = try runtime.startLibraryMatching(library, .{});
    try gate.awaitWaiting();
    const cancelled_at = fake.clock.now();
    try runtime.cancelJob(handle);
    gate.released.store(true, .release);
    try std.testing.expectEqual(job.State.cancelled, try runtime_tests.awaitJob(&runtime, handle));
    try std.testing.expectEqual(@as(u32, 2), fake.requestCount());
    try std.testing.expect(fake.clock.now() - cancelled_at <= 250);
}

test "a search MusicBrainz refused counts as refused, and the next job counts it again without asking" {
    var fake: FakeMusicBrainz = .{
        .answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_answer }},
        .refusals = &.{400},
    };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-refused?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    _ = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);

    const first = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, first));
    const first_stats = try runtime.jobMatchStats(first);
    try std.testing.expectEqual(@as(u64, 1), first_stats.refused);
    try std.testing.expectEqual(@as(u64, 1), first_stats.requests);

    runtime.reapFinishedJobs();
    const second = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, second));
    const second_stats = try runtime.jobMatchStats(second);
    try std.testing.expectEqual(@as(u64, 1), second_stats.refused);
    try std.testing.expectEqual(@as(u64, 0), second_stats.requests);
    try std.testing.expectEqual(@as(u64, 1), second_stats.cache_hits);
    try std.testing.expectEqual(@as(u32, 1), fake.requestCount());
}

test "a matching job waits for MusicBrainz while another process holds it, fails as busy when the hold outlasts the wait, and searches once it lets go" {
    var fake: FakeMusicBrainz = .{ .answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_answer }} };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-busy?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    _ = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);
    const now_ms = FakeMusicBrainz.wall_base_ms;
    try std.testing.expect(try library_database.provider_state.claimLease(
        providers.musicbrainz.service,
        99,
        now_ms,
        now_ms + 2 * network.client.lease_duration_ms,
    ));

    const busy = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.failed, try runtime_tests.awaitJob(&runtime, busy));
    const busy_stats = try runtime.jobMatchStats(busy);
    try std.testing.expectEqual(BusyService.musicbrainz, busy_stats.busy);
    try std.testing.expectEqual(@as(u64, 0), busy_stats.tracks_examined);
    try std.testing.expectEqual(@as(u32, 0), fake.requestCount());
    try std.testing.expect(fake.clock.now() >= network.client.lease_duration_ms);

    try library_database.provider_state.releaseLease(providers.musicbrainz.service, 99);
    runtime.reapFinishedJobs();
    const searched = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, searched));
    try std.testing.expectEqual(BusyService.none, (try runtime.jobMatchStats(searched)).busy);
    try std.testing.expectEqual(@as(u32, 2), fake.requestCount());
    try std.testing.expect(try library_database.provider_state.claimLease(
        providers.musicbrainz.service,
        99,
        now_ms,
        now_ms + network.client.lease_duration_ms,
    ));
}

fn setRecordingIds(
    library_database: *database.LibraryDatabase,
    track_ids: []const i64,
    value: []const u8,
    provenance: metadata.Provenance,
) !void {
    for (track_ids) |track_id| {
        const file_ids = try library_database.tracks.fileIds(std.testing.allocator, track_id);
        defer std.testing.allocator.free(file_ids);
        for (file_ids) |file_id| try library_database.orca_metadata.upsert(.{
            .file_id = file_id,
            .field = .musicbrainz_recording_id,
            .value = value,
            .provenance = provenance,
            .locked = provenance == .user,
        });
    }
}

fn acceptRecordingIds(
    library_database: *database.LibraryDatabase,
    track_ids: []const i64,
    value: []const u8,
) !void {
    var find = try library_database.database.prepare(
        "SELECT id FROM identification_proposals WHERE file_id=?1 AND provider_id=?2;",
    );
    defer find.deinit();
    for (track_ids) |track_id| {
        const file_ids = try library_database.tracks.fileIds(std.testing.allocator, track_id);
        defer std.testing.allocator.free(file_ids);
        for (file_ids) |file_id| {
            _ = try library_database.identification_proposals.put(.{
                .file_id = file_id,
                .provider = "musicbrainz",
                .provider_id = value,
                .confidence = 0.95,
                .payload = "{\"album\":\"Bryter Layter\"}",
            });
            try find.reset();
            try find.bindInt64(1, file_id);
            try find.bindText(2, value);
            try std.testing.expectEqual(database.sqlite.Step.row, try find.step());
            _ = try library_database.identification_proposals.acceptProposal(std.testing.allocator, find.columnInt64(0));
        }
    }
}

fn writePlan(runtime: *OrcaRuntime, library: LibraryHandle, ids: []const i64) !void {
    const plan = try runtime.planTagWrite(library, std.testing.io, ids);
    defer plan.deinit();
    try std.testing.expect(plan.files.len > 0);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(runtime, try runtime.startTagWrite(library, plan.plan_id, plan.digest)));
}

fn tagWriteDatabasePath(data: *std.testing.TmpDir) ![:0]u8 {
    return std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/library.db", .{data.sub_path}, 0);
}

test "a matched recording id is written into files without one, and they stay submittable to AcoustID" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try tagWriteDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime_tests.scannedTempLibrary(&runtime, &temporary, database_path);
    const ids = try runtime_tests.allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    const library_database = try libraryDatabase(&runtime, library);
    try acceptRecordingIds(library_database, ids, northern_sky_mbid);
    const submittable = try runtime.libraryAcoustIdSubmittableCount(library);
    try std.testing.expectEqual(@as(u64, 3), submittable);

    const preview = try runtime.planTagWrite(library, std.testing.io, ids);
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 2), preview.files.len);
    try std.testing.expectEqual(@as(usize, 0), preview.conflicts.len);
    for (preview.files) |file| {
        try std.testing.expectEqual(@as(usize, 1), file.changes.len);
        const change = file.changes[0];
        try std.testing.expectEqual(.musicbrainz_recording_id, change.field);
        try std.testing.expect(change.before == null);
        try std.testing.expectEqualStrings(northern_sky_mbid, change.after.?);
        try std.testing.expectEqual(.provider, change.provenance);
    }
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, try runtime.startTagWrite(library, preview.plan_id, preview.digest)));

    for (preview.files) |file| {
        const stored = (try library_database.observed_tags.get(std.testing.allocator, file.file_id)).?;
        defer stored.deinit();
        try std.testing.expectEqualStrings(northern_sky_mbid, stored.values.musicbrainz_recording_id.?);
    }
    try std.testing.expectEqual(@as(i64, 2), try database.columns.scalar(
        library_database.database,
        "SELECT count(*) FROM orca_metadata_values WHERE written_at IS NOT NULL;",
    ));
    try std.testing.expectEqual(submittable, try runtime.libraryAcoustIdSubmittableCount(library));

    const again = try runtime.planTagWrite(library, std.testing.io, ids);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 0), again.files.len);
    try std.testing.expectEqual(@as(usize, 0), again.conflicts.len);

    try runtime.undoTagWrite(library, std.testing.io, preview.plan_id);
    try std.testing.expectEqual(submittable, try runtime.libraryAcoustIdSubmittableCount(library));
}

test "a matched recording id that disagrees with the file's tag is a conflict, and the file's locked edits are still written" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try tagWriteDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime_tests.scannedTempLibrary(&runtime, &temporary, database_path);
    const ids = try runtime_tests.allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    const library_database = try libraryDatabase(&runtime, library);
    const tagged_mbid = "11111111-2222-4333-8444-555555555555";
    try setRecordingIds(library_database, ids, tagged_mbid, .user);
    try writePlan(&runtime, library, ids);
    try std.testing.expectEqual(@as(u64, 3), try runtime.libraryAcoustIdSubmittableCount(library));

    for (ids) |track_id| {
        const file_ids = try library_database.tracks.fileIds(std.testing.allocator, track_id);
        defer std.testing.allocator.free(file_ids);
        for (file_ids) |file_id| try library_database.orca_metadata.remove(file_id, .musicbrainz_recording_id);
    }
    try setRecordingIds(library_database, ids, northern_sky_mbid, .provider);
    const edited = try runtime.libraryEditTracks(library, ids, &.{.{ .field = .title, .value = "Locked Title" }});
    defer edited.deinit();

    const preview = try runtime.planTagWrite(library, std.testing.io, edited.ids);
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 2), preview.files.len);
    for (preview.files) |file| {
        try std.testing.expectEqual(@as(usize, 1), file.changes.len);
        try std.testing.expectEqual(.title, file.changes[0].field);
        try std.testing.expectEqual(.user, file.changes[0].provenance);
    }
    try std.testing.expectEqual(@as(usize, 2), preview.conflicts.len);
    for (preview.conflicts) |conflict| {
        try std.testing.expectEqual(.musicbrainz_recording_id, conflict.field);
        try std.testing.expectEqualStrings(tagged_mbid, conflict.file_value);
        try std.testing.expectEqualStrings(northern_sky_mbid, conflict.orca_value);
        try std.testing.expectEqual(.provider, conflict.provenance);
        try std.testing.expect(conflict.path.len > 0);
    }
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, try runtime.startTagWrite(library, preview.plan_id, preview.digest)));
    for (preview.files) |file| {
        const stored = (try library_database.observed_tags.get(std.testing.allocator, file.file_id)).?;
        defer stored.deinit();
        try std.testing.expectEqualStrings("Locked Title", stored.values.title.?);
        try std.testing.expectEqualStrings(tagged_mbid, stored.values.musicbrainz_recording_id.?);
    }
}

fn addReviewTrack(
    library_database: *database.LibraryDatabase,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    track_number: ?i64,
) !i64 {
    const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
    try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = .{ .title = title } });
    try library_database.tracks.upsertTracks(&.{.{
        .title = title,
        .artist = artist,
        .album = album,
        .track_number = track_number,
        .duration_ms = 180_000,
        .preferred_file_id = file_id,
    }});
    const ids = try library_database.tracks.idsForFile(std.testing.allocator, file_id);
    defer std.testing.allocator.free(ids);
    return ids[0];
}

fn proposeMatch(library_database: *database.LibraryDatabase, track_id: i64, mbid: []const u8, confidence: f32, payload: []const u8) !void {
    const file_ids = try library_database.tracks.fileIds(std.testing.allocator, track_id);
    defer std.testing.allocator.free(file_ids);
    _ = try library_database.identification_proposals.put(.{
        .file_id = file_ids[0],
        .provider = "musicbrainz",
        .provider_id = mbid,
        .confidence = confidence,
        .payload = payload,
    });
    _ = try library_database.identification_proposals.recordSearch(std.testing.allocator, file_ids[0], .{ .musicbrainz = true }, &.{});
}

const review_payload = "{\"title\":\"Northern Sky\",\"artist\":\"Nick Drake\",\"album\":\"Bryter Layter\",\"duration_ms\":225000}";

test "the review list holds each Track awaiting review once, by artist, album and position, with its best match" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-review?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const later_on_album = try addReviewTrack(library_database, "Northern Sky", "Nick Drake", "Bryter Layter", 8);
    const first_on_album = try addReviewTrack(library_database, "Hazey Jane II", "Nick Drake", "Bryter Layter", 2);
    const other_artist = try addReviewTrack(library_database, "Waterloo Sunset", "The Kinks", "Something Else", 12);
    const earlier_album = try addReviewTrack(library_database, "Pink Moon", "Nick Drake", "Pink Moon", 1);
    const nothing_pending = try addReviewTrack(library_database, "River Man", "Nick Drake", "Five Leaves Left", 5);
    try proposeMatch(library_database, later_on_album, northern_sky_mbid, 0.6, review_payload);
    try proposeMatch(library_database, later_on_album, pink_moon_mbid, 0.95, review_payload);
    try proposeMatch(library_database, first_on_album, northern_sky_mbid, 0.8, review_payload);
    try proposeMatch(library_database, other_artist, northern_sky_mbid, 0.7, review_payload);
    try proposeMatch(library_database, earlier_album, pink_moon_mbid, 0.9, review_payload);

    const page = try runtime.libraryMatchReviewPage(library, 512, 0);
    defer page.deinit();

    try std.testing.expectEqual(@as(u64, 4), try runtime.libraryMatchReviewCount(library));
    try std.testing.expectEqual(@as(u64, 1), try runtime.libraryUnidentifiedCount(library));
    try std.testing.expectEqual(@as(usize, 4), page.items.len);
    const expected_order = [_]i64{ first_on_album, later_on_album, earlier_album, other_artist };
    for (expected_order, page.items) |track_id, item| try std.testing.expectEqual(track_id, item.track_id);
    const two = page.items[1];
    try std.testing.expectEqualStrings("Northern Sky", two.title);
    try std.testing.expectEqual(@as(?i64, 180_000), two.duration_ms);
    try std.testing.expectEqual(@as(u32, 2), two.proposal_count);
    try std.testing.expectEqualStrings(pink_moon_mbid, two.best.recording_mbid);
    try std.testing.expectEqual(@as(?u64, 225_000), two.best.duration_ms);
    for (page.items) |item| try std.testing.expect(item.track_id != nothing_pending);

    const second = try runtime.libraryMatchReviewPage(library, 2, 2);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 2), second.items.len);
    try std.testing.expectEqual(earlier_album, second.items[0].track_id);
    try std.testing.expectError(error.PageOutOfRange, runtime.libraryMatchReviewPage(library, 513, 0));
    try std.testing.expectError(error.PageOutOfRange, runtime.libraryMatchReviewPage(library, 0, 0));
}

test "the confident count is exactly how many matches accepting confident ones then accepts" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-confident?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const alone = try addReviewTrack(library_database, "Northern Sky", "Nick Drake", "Bryter Layter", 8);
    const contested = try addReviewTrack(library_database, "Pink Moon", "Nick Drake", "Pink Moon", 1);
    const ahead = try addReviewTrack(library_database, "River Man", "Nick Drake", "Five Leaves Left", 5);
    const doubtful = try addReviewTrack(library_database, "Fly", "Nick Drake", "Bryter Layter", 7);
    const unreadable = try addReviewTrack(library_database, "Poor Boy", "Nick Drake", "Bryter Layter", 6);
    try proposeMatch(library_database, alone, northern_sky_mbid, 0.95, review_payload);
    try proposeMatch(library_database, contested, northern_sky_mbid, 0.95, review_payload);
    try proposeMatch(library_database, contested, pink_moon_mbid, 0.92, review_payload);
    try proposeMatch(library_database, ahead, northern_sky_mbid, 0.95, review_payload);
    try proposeMatch(library_database, ahead, pink_moon_mbid, 0.5, review_payload);
    try proposeMatch(library_database, doubtful, northern_sky_mbid, 0.7, review_payload);
    try proposeMatch(library_database, unreadable, northern_sky_mbid, 0.99, "[");

    const counted = try runtime.libraryConfidentMatchCount(library, 0.9);
    const lower = try runtime.libraryConfidentMatchCount(library, 0.6);
    const accepted = try runtime.libraryAcceptConfidentMatches(library, 0.9);

    try std.testing.expectEqual(@as(u64, 3), counted);
    try std.testing.expectEqual(counted, accepted.accepted);
    try std.testing.expectEqual(@as(u64, 4), lower);
    try std.testing.expectEqual(@as(u64, 0), try runtime.libraryConfidentMatchCount(library, 0.9));
    try std.testing.expectError(error.InvalidMinimumConfidence, runtime.libraryConfidentMatchCount(library, 0));
}

test "a single-Track matching job searches only that Track, and one already identified or already answered for is not searched" {
    var fake: FakeMusicBrainz = .{ .answers = &.{
        .{ .title = "Northern%20Sky", .body = northern_sky_answer },
        .{ .title = "Pink%20Moon", .body = pink_moon_answer },
    } };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-single?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);
    const pink_moon = try addMatchTrack(library_database, "Pink Moon", "Nick Drake", null);
    const tagged = try addMatchTrack(library_database, "Hazey Jane II", "Nick Drake", "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a");

    const job_handle = try runtime.startLibraryMatching(library, .{ .track_id = pink_moon });

    try std.testing.expectEqual(@as(?u64, 1), (try runtime.jobSnapshotSynced(job_handle)).total_units);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, job_handle));
    try std.testing.expectEqual(@as(u64, 1), (try runtime.jobMatchStats(job_handle)).matched);
    try std.testing.expectEqual(@as(u32, 2), fake.requestCount());
    const untouched = try runtime.libraryMatchProposals(library, northern_sky, 10);
    defer untouched.deinit();
    try std.testing.expectEqual(@as(usize, 0), untouched.items.len);
    try std.testing.expectEqual(@as(u64, 1), try runtime.libraryUnidentifiedCount(library));

    for ([_]i64{ pink_moon, tagged }) |not_searched| {
        runtime.reapFinishedJobs();
        const skipped = try runtime.startLibraryMatching(library, .{ .track_id = not_searched });
        try std.testing.expectEqual(@as(?u64, 0), (try runtime.jobSnapshotSynced(skipped)).total_units);
        try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, skipped));
        try std.testing.expectEqual(@as(u64, 0), (try runtime.jobMatchStats(skipped)).tracks_examined);
    }
    try std.testing.expectEqual(@as(u32, 2), fake.requestCount());
}

const northern_sky_remaster_mbid = "3a4b5c6d-7e8f-4a9b-8c0d-1e2f3a4b5c6d";
const northern_sky_two_answer = "{\"recordings\":[" ++ recordingEntry(northern_sky_mbid, "Northern Sky") ++ "," ++
    recordingEntry(northern_sky_remaster_mbid, "Northern Sky") ++ "]}";

fn proposalState(library_database: *database.LibraryDatabase, comptime recording_mbid: []const u8) !i64 {
    return database.columns.scalar(
        library_database.database,
        "SELECT state FROM identification_proposals WHERE provider_id = '" ++ recording_mbid ++ "';",
    );
}

test "re-identify searches a Track its tag already identifies, confirms that recording without proposing it, and proposes another" {
    var fake: FakeMusicBrainz = .{ .answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_two_answer }} };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-reidentify-track?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", northern_sky_mbid);
    const files = try library_database.tracks.fileIds(std.testing.allocator, northern_sky);
    defer std.testing.allocator.free(files);
    _ = try library_database.identification_proposals.recordSearch(std.testing.allocator, files[0], .{ .musicbrainz = true }, &.{});
    try library_database.database.exec("UPDATE identification_searches SET searched_at = 0;");

    const search = try runtime.startLibraryMatching(library, .{ .track_id = northern_sky });
    try std.testing.expectEqual(@as(?u64, 0), (try runtime.jobSnapshotSynced(search)).total_units);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, search));
    try std.testing.expectEqual(@as(u64, 0), (try runtime.jobMatchStats(search)).tracks_examined);
    try std.testing.expectEqual(@as(u32, 0), fake.requestCount());
    runtime.reapFinishedJobs();

    const job_handle = try runtime.startLibraryMatching(library, .{ .track_id = northern_sky, .mode = .reidentify });

    try std.testing.expectEqual(@as(?u64, 1), (try runtime.jobSnapshotSynced(job_handle)).total_units);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, job_handle));
    const stats = try runtime.jobMatchStats(job_handle);
    try std.testing.expectEqual(@as(u64, 1), stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 1), stats.confirmed);
    try std.testing.expectEqual(@as(u64, 1), stats.matched);
    try std.testing.expectEqual(@as(u64, 0), stats.unmatched);
    try std.testing.expectEqual(@as(u64, 1), stats.proposals_stored);
    try std.testing.expectEqual(@as(u32, 2), fake.requestCount());
    const proposals = try runtime.libraryMatchProposals(library, northern_sky, 10);
    defer proposals.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposals.items.len);
    try std.testing.expectEqualStrings(northern_sky_remaster_mbid, proposals.items[0].recording_mbid);
    try std.testing.expectEqual(@as(i64, 0), try database.columns.scalar(
        library_database.database,
        "SELECT count(*) FROM identification_proposals WHERE provider_id = '" ++ northern_sky_mbid ++ "';",
    ));
    try std.testing.expectEqual(@as(i64, 1), try database.columns.scalar(
        library_database.database,
        "SELECT count(*) FROM identification_searches WHERE provider = 'musicbrainz' AND searched_at > 0;",
    ));

    try runtime.libraryDismissMatch(library, proposals.items[0].id);
    runtime.reapFinishedJobs();
    const again = try runtime.startLibraryMatching(library, .{ .track_id = northern_sky, .mode = .reidentify });
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, again));
    const again_stats = try runtime.jobMatchStats(again);
    try std.testing.expectEqual(@as(u64, 1), again_stats.confirmed);
    try std.testing.expectEqual(@as(u64, 0), again_stats.matched);
    try std.testing.expectEqual(@as(u64, 0), again_stats.unmatched);
    try std.testing.expectEqual(@as(usize, 0), try pendingCount(&runtime, library, northern_sky));
    try std.testing.expectEqual(@as(i64, @backingInt(database.ProposalState.dismissed)), try proposalState(library_database, northern_sky_remaster_mbid));
}

test "re-identify is refused for the whole library and with bulk acceptance, and nothing is sent" {
    var fake: FakeMusicBrainz = .{};
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-reidentify-refused?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const album = try addRelease(library_database, "Bryter Layter", null);
    _ = try addAlbumTrack(library_database, album, "Northern Sky");

    try std.testing.expectError(error.InvalidMatchRequest, runtime.startLibraryMatching(library, .{ .mode = .reidentify }));
    try std.testing.expectError(error.InvalidMatchRequest, runtime.startLibraryMatching(library, .{
        .mode = .reidentify,
        .release_id = album,
        .accept_minimum_confidence = 0.9,
    }));
    try std.testing.expectEqual(@as(u32, 0), fake.requestCount());
}

test "re-identifying a Release searches its identified files and points their proposals at the release most of them list" {
    var fake: FakeMusicBrainz = .{};
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-reidentify-release?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try observeFile(library_database, "/music/drake/01.flac", "Northern Sky", "Nick Drake");
    const pink_moon = try observeFile(library_database, "/music/drake/02.flac", "Pink Moon", "Nick Drake");
    for ([_]i64{ northern_sky, pink_moon }) |file_id| {
        try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = .{
            .title = if (file_id == northern_sky) "Northern Sky" else "Pink Moon",
            .artist = "Nick Drake",
            .musicbrainz_recording_id = feedback_mbid,
        } });
    }
    try projectAll(library_database);
    const album = try releaseOfFile(library_database, northern_sky);

    const other_edition = "9c8b7a6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d";
    const both_editions = [_][]const u8{ other_edition, bryter_layter_mbid };
    const one_edition = [_][]const u8{bryter_layter_mbid};
    for ([_]struct { file: i64, recording: []const u8, title: []const u8, best: []const u8, listed: []const []const u8 }{
        .{ .file = northern_sky, .recording = northern_sky_mbid, .title = "Northern Sky", .best = other_edition, .listed = &both_editions },
        .{ .file = pink_moon, .recording = pink_moon_mbid, .title = "Pink Moon", .best = bryter_layter_mbid, .listed = &one_edition },
    }) |found| {
        const evidence = [_]database.ProposalEvidence{.{
            .recording_mbid = found.recording,
            .found_by = .{ .musicbrainz = true },
            .payload = .{
                .title = found.title,
                .artist = "Nick Drake",
                .release_mbid = found.best,
                .release_mbids = found.listed,
                .mb_score = 100,
                .musicbrainz_confidence = 0.95,
            },
        }};
        _ = try library_database.identification_proposals.recordSearch(std.testing.allocator, found.file, .{ .musicbrainz = true }, &evidence);
    }

    const job_handle = try runtime.startLibraryMatching(library, .{ .release_id = album, .mode = .reidentify });

    try std.testing.expectEqual(@as(?u64, 2), (try runtime.jobSnapshotSynced(job_handle)).total_units);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, job_handle));
    const stats = try runtime.jobMatchStats(job_handle);
    try std.testing.expectEqual(@as(u64, 2), stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 0), stats.accepted);
    try std.testing.expectEqual(@as(u32, 3), fake.requestCount());
    try std.testing.expect(std.mem.indexOf(u8, fake.transport.lastUrl(), "/ws/2/release/" ++ bryter_layter_mbid) != null);
    try std.testing.expectEqual(@as(i64, 2), try database.columns.scalar(
        library_database.database,
        "SELECT count(*) FROM identification_proposals WHERE state = 0 AND payload LIKE '%\"release_mbid\":\"" ++ bryter_layter_mbid ++ "\"%';",
    ));
}

/// Answers AcoustID lookups and submissions on the job's thread; a test reads
/// what it recorded once the job is reaped.
pub const FakeAcoustId = struct {
    http: network.testing.ScriptedTransport = .{},
    /// Lookups from this one on hang until the job is cancelled.
    hang_lookups_from: ?u32 = null,
    /// While set, a lookup waits whether or not its job is cancelled, so the
    /// job's thread outlives its cancellation.
    held: std.atomic.Value(bool) = .init(false),
    lookup_status: u16 = 200,
    lookup_body: []const u8 = "{\"status\":\"ok\",\"fingerprints\":[]}",
    submit_status: u16 = 200,
    submit_body: []const u8 = "{\"status\":\"ok\",\"submissions\":[]}",
    /// Statuses the first submissions are answered with, in order.
    submit_outages: []const u16 = &.{},
    lookups: std.atomic.Value(u32) = .init(0),
    submissions: std.atomic.Value(u32) = .init(0),

    pub fn transport(self: *FakeAcoustId) network.client.Transport {
        self.http.responder = .{ .context = self, .respond_fn = respond };
        return self.http.transport();
    }

    pub fn lastForm(self: *const FakeAcoustId) []const u8 {
        return self.http.lastForm();
    }

    fn respond(context: *anyopaque, exchange: network.testing.Exchange, _: ?network.testing.Reply) anyerror!network.testing.Reply {
        const self: *FakeAcoustId = @ptrCast(@alignCast(context));
        if (std.mem.endsWith(u8, exchange.request.url, "/v2/lookup")) {
            const index = self.lookups.fetchAdd(1, .acq_rel);
            if (self.hang_lookups_from) |first| if (index >= first) return .hang;
            var deadline: runtime_tests.TestDeadline = .init(10_000);
            while (self.held.load(.acquire) and deadline.tick()) {}
            return .{ .respond = .{ .status = self.lookup_status, .body = self.lookup_body } };
        }
        const index = self.submissions.fetchAdd(1, .acq_rel);
        if (index < self.submit_outages.len) return .{ .respond = .{ .status = self.submit_outages[index], .body = "" } };
        return .{ .respond = .{ .status = self.submit_status, .body = self.submit_body } };
    }
};

const AcoustIdUserKey = struct {
    key: ?[]const u8,

    fn store(self: *AcoustIdUserKey) CredentialStore {
        return .{ .context = self, .get_fn = get };
    }

    fn get(context: *anyopaque, allocator: std.mem.Allocator, service: []const u8, account: []const u8) anyerror!?[]u8 {
        const self: *AcoustIdUserKey = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, service, providers.acoustid.credential_service)) return null;
        if (!std.mem.eql(u8, account, providers.acoustid.user_key_account)) return null;
        return if (self.key) |key| try allocator.dupe(u8, key) else null;
    }
};

/// Fifteen seconds of a mono tone at 11025 Hz, long enough to fingerprint.
pub fn writeToneWave(dir: std.Io.Dir, name: []const u8, frequency: f32) !void {
    const rate = 11_025;
    const frames = 15 * rate;
    var bytes: [44 + frames * 2]u8 = undefined;
    writeWaveHeader(&bytes, rate, frames);
    for (0..frames) |frame| {
        const time = @as(f32, @floatFromInt(frame)) / rate;
        const wobble = frequency * (1 + 0.2 * @sin(2 * std.math.pi * 0.5 * time));
        const sample: i16 = @intFromFloat(9000 * @sin(2 * std.math.pi * wobble * time));
        std.mem.writeInt(i16, bytes[44 + frame * 2 ..][0..2], sample, .little);
    }
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = &bytes });
}

/// A 16-bit mono PCM WAVE header for `frames` frames at `rate`, written over
/// the first 44 of `bytes`.
fn writeWaveHeader(bytes: []u8, rate: u32, frames: u32) void {
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 36 + frames * 2, .little);
    @memcpy(bytes[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], 1, .little);
    std.mem.writeInt(u32, bytes[24..28], rate, .little);
    std.mem.writeInt(u32, bytes[28..32], rate * 2, .little);
    std.mem.writeInt(u16, bytes[32..34], 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], frames * 2, .little);
}

fn addAudioTrack(
    library_database: *database.LibraryDatabase,
    temporary: *std.testing.TmpDir,
    name: []const u8,
    title: []const u8,
    artist: []const u8,
) !i64 {
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ temporary.sub_path, name });
    defer std.testing.allocator.free(path);
    const binding = try library_database.resolveOrCreateFile(std.testing.io, path, .{ .stable_key = "test:acoustid" });
    try library_database.tracks.upsertTracks(&.{.{
        .title = title,
        .artist = artist,
        .album = "Bryter Layter",
        .duration_ms = 15_000,
        .preferred_file_id = binding.file_id,
    }});
    const ids = try library_database.tracks.idsForFile(std.testing.allocator, binding.file_id);
    defer std.testing.allocator.free(ids);
    return ids[0];
}

const two_fingerprint_answer =
    "{\"status\":\"ok\",\"fingerprints\":[" ++
    "{\"index\":0,\"results\":[{\"id\":\"t1\",\"score\":0.96,\"recordings\":[{\"id\":\"" ++ northern_sky_mbid ++
    "\",\"title\":\"Northern Sky\",\"duration\":15,\"artists\":[{\"id\":\"a1\",\"name\":\"Nick Drake\"}]}]}]}," ++
    "{\"index\":1,\"results\":[{\"id\":\"t2\",\"score\":0.93,\"recordings\":[{\"id\":\"" ++ pink_moon_mbid ++ "\"}]}]}]}";

test "a matching job fingerprints each file, asks AcoustID about them in one request, merges both services, and a rerun asks neither" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeToneWave(temporary.dir, "northern.wav", 440);
    try writeToneWave(temporary.dir, "untagged.wav", 620);
    var musicbrainz: FakeMusicBrainz = .{ .answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_answer }} };
    var acoustid: FakeAcoustId = .{ .lookup_body = two_fingerprint_answer };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = musicbrainz.hooks();
    runtime.matching_hooks.acoustid_transport = acoustid.transport();
    try std.testing.expectError(error.InvalidAcoustIdKey, runtime.setAcoustIdClientKey("with space"));
    try runtime.setAcoustIdClientKey("test-client");
    try runtime.setAcoustIdServer("http://127.0.0.1:5002");
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-acoustid?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try addAudioTrack(library_database, &temporary, "northern.wav", "Northern Sky", "Nick Drake");
    const untagged = try addAudioTrack(library_database, &temporary, "untagged.wav", "", "");

    const job_handle = try runtime.startLibraryMatching(library, .{});

    try std.testing.expectEqual(@as(?u64, 2), (try runtime.jobSnapshotSynced(job_handle)).total_units);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, job_handle));
    const stats = try runtime.jobMatchStats(job_handle);
    try std.testing.expectEqual(AcoustIdUse.searched, stats.acoustid);
    try std.testing.expectEqual(@as(u64, 2), stats.fingerprinted);
    try std.testing.expectEqual(@as(u64, 1), stats.acoustid_requests);
    try std.testing.expectEqual(@as(u64, 2), stats.requests);
    try std.testing.expectEqual(@as(u64, 2), stats.matched);
    try std.testing.expectEqual(@as(u32, 1), acoustid.lookups.load(.acquire));
    try std.testing.expect(std.mem.startsWith(u8, acoustid.lastForm(), "client=test-client&"));
    try std.testing.expect(std.mem.indexOf(u8, acoustid.lastForm(), "&duration.0=15&fingerprint.0=AQA") != null);
    try std.testing.expect(std.mem.indexOf(u8, acoustid.lastForm(), "&duration.1=15&fingerprint.1=AQA") != null);

    const both = try runtime.libraryMatchProposals(library, northern_sky, 10);
    defer both.deinit();
    try std.testing.expectEqual(@as(usize, 1), both.items.len);
    try std.testing.expectEqualStrings("musicbrainz+acoustid", both.items[0].provider);
    try std.testing.expectEqualStrings("Bryter Layter", both.items[0].album);
    try std.testing.expectApproxEqAbs(@as(f32, 0.96), both.items[0].acoustid_score.?, 0.0001);
    const fingerprint_only = try runtime.libraryMatchProposals(library, untagged, 10);
    defer fingerprint_only.deinit();
    try std.testing.expectEqual(@as(usize, 1), fingerprint_only.items.len);
    try std.testing.expectEqualStrings("acoustid", fingerprint_only.items[0].provider);
    try std.testing.expectEqualStrings("", fingerprint_only.items[0].title);

    runtime.reapFinishedJobs();
    const rerun = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, rerun));
    const rerun_stats = try runtime.jobMatchStats(rerun);
    try std.testing.expectEqual(@as(u64, 0), rerun_stats.requests + rerun_stats.acoustid_requests);
    try std.testing.expectEqual(@as(u64, 0), rerun_stats.fingerprinted);
    try std.testing.expectEqual(@as(u32, 1), acoustid.lookups.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), musicbrainz.requestCount());

    const untagged_files = try library_database.tracks.fileIds(std.testing.allocator, untagged);
    defer std.testing.allocator.free(untagged_files);
    _ = try runtime.libraryAcceptMatch(library, fingerprint_only.items[0].id);
    const reprojected = try library_database.tracks.idsForFile(std.testing.allocator, untagged_files[0]);
    defer std.testing.allocator.free(reprojected);
    const details = (try runtime.libraryTrackDetails(library, reprojected[0])).?;
    defer details.deinit();
    try std.testing.expectEqualStrings(pink_moon_mbid, details.musicbrainz_recording_id.?);
}

test "a file that fails to decode is not fingerprinted and its Track is still searched on MusicBrainz, and no fingerprints means no AcoustID" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/audio/tagged-reference.flac", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(bytes);
    const packed_bits = std.mem.readInt(u64, bytes[18..26], .big);
    std.mem.writeInt(u64, bytes[18..26], packed_bits + 1_000_000, .big);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "damaged.flac", .data = bytes });
    try writeToneWave(temporary.dir, "whole.wav", 440);
    var musicbrainz: FakeMusicBrainz = .{ .answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_answer }} };
    var acoustid: FakeAcoustId = .{};
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = musicbrainz.hooks();
    runtime.matching_hooks.acoustid_transport = acoustid.transport();
    try runtime.setAcoustIdClientKey("test-client");
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-damaged?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const damaged = try addAudioTrack(library_database, &temporary, "damaged.flac", "Northern Sky", "Nick Drake");
    _ = try addAudioTrack(library_database, &temporary, "whole.wav", "Pink Moon", "Nick Drake");

    const without = try runtime.startLibraryMatching(library, .{ .fingerprints = false, .track_id = damaged + 1 });
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, without));
    try std.testing.expectEqual(AcoustIdUse.off, (try runtime.jobMatchStats(without)).acoustid);
    try std.testing.expectEqual(@as(u32, 0), acoustid.lookups.load(.acquire));

    runtime.reapFinishedJobs();
    const job_handle = try runtime.startLibraryMatching(library, .{ .track_id = damaged });
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, job_handle));
    const stats = try runtime.jobMatchStats(job_handle);
    try std.testing.expectEqual(@as(u64, 0), stats.fingerprinted);
    try std.testing.expectEqual(@as(u64, 1), stats.fingerprint_failures);
    try std.testing.expectEqual(@as(u64, 0), stats.acoustid_requests);
    try std.testing.expectEqual(@as(u64, 1), stats.matched);
    try std.testing.expectEqual(@as(i64, 0), try database.columns.scalar(library_database.database, "SELECT count(*) FROM analysis_results WHERE kind = 3;"));
    try std.testing.expectEqual(@as(i64, 0), try database.columns.scalar(library_database.database, "SELECT count(*) FROM identification_searches WHERE provider = 'acoustid';"));
}

test "a submission fails as busy when another process holds AcoustID past its wait and marks nothing sent" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeToneWave(temporary.dir, "chosen.wav", 440);
    var musicbrainz: FakeMusicBrainz = .{};
    var acoustid: FakeAcoustId = .{};
    var user: AcoustIdUserKey = .{ .key = "user key" };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = musicbrainz.hooks();
    runtime.matching_hooks.acoustid_transport = acoustid.transport();
    try runtime.setAcoustIdClientKey("test-client");
    try runtime.setCredentialStore(user.store());
    const library = try runtime.openLibrary(std.testing.io, "file:orca-acoustid-submit-busy?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const chosen = try addAudioTrack(library_database, &temporary, "chosen.wav", "Northern Sky", "Nick Drake");
    try proposeMatch(library_database, chosen, northern_sky_mbid, 0.95, "{\"title\":\"Northern Sky\",\"duration_ms\":15000}");
    {
        const page = try runtime.libraryMatchProposals(library, chosen, 1);
        defer page.deinit();
        _ = try runtime.libraryAcceptMatch(library, page.items[0].id);
    }
    const now_ms = FakeMusicBrainz.wall_base_ms;
    try std.testing.expect(try library_database.provider_state.claimLease(
        providers.acoustid.service,
        99,
        now_ms,
        now_ms + 2 * network.client.lease_duration_ms,
    ));

    const busy = try runtime.startAcoustIdSubmission(library);
    try std.testing.expectEqual(job.State.failed, try runtime_tests.awaitJob(&runtime, busy));
    try std.testing.expectEqual(SubmissionOutcome.busy, (try runtime.jobSubmissionStats(busy)).outcome);
    try std.testing.expectEqual(@as(u32, 0), acoustid.submissions.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), try runtime.libraryAcoustIdSubmittableCount(library));
}

fn submitAfterOutages(musicbrainz: *FakeMusicBrainz, acoustid: *FakeAcoustId, name: [:0]const u8) !SubmissionOutcome {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeToneWave(temporary.dir, "chosen.wav", 440);
    acoustid.submit_body = "{\"status\":\"ok\",\"submissions\":[{\"id\":71,\"status\":\"pending\",\"index\":\"0\"}]}";
    var user: AcoustIdUserKey = .{ .key = "user key" };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = musicbrainz.hooks();
    runtime.matching_hooks.acoustid_transport = acoustid.transport();
    acoustid.http.clock = &musicbrainz.clock;
    try runtime.setAcoustIdClientKey("test-client");
    try runtime.setCredentialStore(user.store());
    const library = try runtime.openLibrary(std.testing.io, name);
    const library_database = try libraryDatabase(&runtime, library);
    const chosen = try addAudioTrack(library_database, &temporary, "chosen.wav", "Northern Sky", "Nick Drake");
    try proposeMatch(library_database, chosen, northern_sky_mbid, 0.95, "{\"title\":\"Northern Sky\",\"duration_ms\":15000}");
    {
        const page = try runtime.libraryMatchProposals(library, chosen, 1);
        defer page.deinit();
        _ = try runtime.libraryAcceptMatch(library, page.items[0].id);
    }

    const submission = try runtime.startAcoustIdSubmission(library);
    const state = try runtime_tests.awaitJob(&runtime, submission);
    const outcome = (try runtime.jobSubmissionStats(submission)).outcome;
    try std.testing.expectEqual(outcome == .completed, state == .succeeded);
    const unsent: u64 = if (outcome == .completed) 0 else 1;
    try std.testing.expectEqual(unsent, try runtime.libraryAcoustIdSubmittableCount(library));
    return outcome;
}

test "a submission AcoustID could not take is sent again after about 5 s, then about 30 s, and a third failure marks nothing sent" {
    var musicbrainz: FakeMusicBrainz = .{};
    var once: FakeAcoustId = .{ .submit_outages = &.{503} };
    try std.testing.expectEqual(SubmissionOutcome.completed, try submitAfterOutages(&musicbrainz, &once, "file:orca-acoustid-submit-outage-once?mode=memory&cache=shared"));
    try std.testing.expectEqual(@as(u32, 2), once.submissions.load(.acquire));
    try expectWaited(&once.http, 1, 5_000);

    var twice: FakeAcoustId = .{ .submit_outages = &.{ 503, 503 } };
    try std.testing.expectEqual(SubmissionOutcome.completed, try submitAfterOutages(&musicbrainz, &twice, "file:orca-acoustid-submit-outage-twice?mode=memory&cache=shared"));
    try std.testing.expectEqual(@as(u32, 3), twice.submissions.load(.acquire));
    try expectWaited(&twice.http, 1, 5_000);
    try expectWaited(&twice.http, 2, 30_000);

    var thrice: FakeAcoustId = .{ .submit_outages = &.{ 503, 503, 503 } };
    try std.testing.expectEqual(SubmissionOutcome.unavailable, try submitAfterOutages(&musicbrainz, &thrice, "file:orca-acoustid-submit-outage-thrice?mode=memory&cache=shared"));
    try std.testing.expectEqual(@as(u32, 3), thrice.submissions.load(.acquire));
    try expectWaited(&thrice.http, 2, 30_000);

    var limited: FakeAcoustId = .{ .submit_outages = &.{ 503, 429 } };
    try std.testing.expectEqual(SubmissionOutcome.completed, try submitAfterOutages(&musicbrainz, &limited, "file:orca-acoustid-submit-outage-limited?mode=memory&cache=shared"));
    try std.testing.expectEqual(@as(u32, 3), limited.submissions.load(.acquire));
    try expectWaited(&limited.http, 1, 5_000);
    try std.testing.expect(limited.http.request_times_ms[2] - limited.http.request_times_ms[1] >= 60_000);
}

test "a submission sends a chosen recording ID once, fails without marking anything when the user key is missing or refused, and cannot run beside matching" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeToneWave(temporary.dir, "chosen.wav", 440);
    try writeToneWave(temporary.dir, "doubted.wav", 530);
    var musicbrainz: FakeMusicBrainz = .{ .hang_from = 0 };
    var acoustid: FakeAcoustId = .{
        .submit_body = "{\"status\":\"ok\",\"submissions\":[{\"id\":71,\"status\":\"pending\",\"index\":\"0\"},{\"id\":72,\"status\":\"pending\",\"index\":\"1\"}]}",
    };
    var user: AcoustIdUserKey = .{ .key = null };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = musicbrainz.hooks();
    runtime.matching_hooks.acoustid_transport = acoustid.transport();
    try runtime.setAcoustIdClientKey("test-client");
    try runtime.setCredentialStore(user.store());
    const library = try runtime.openLibrary(std.testing.io, "file:orca-acoustid-submit?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const chosen = try addAudioTrack(library_database, &temporary, "chosen.wav", "Northern Sky", "Nick Drake");
    const doubted = try addAudioTrack(library_database, &temporary, "doubted.wav", "Pink Moon", "Nick Drake");
    try proposeMatch(library_database, chosen, northern_sky_mbid, 0.95, "{\"title\":\"Northern Sky\",\"artist\":\"Nick Drake\",\"duration_ms\":15000}");
    try proposeMatch(library_database, doubted, pink_moon_mbid, 0.95, "{\"title\":\"Pink Moon\",\"artist\":\"Nick Drake\",\"duration_ms\":300000}");
    var proposal_ids: [2]i64 = undefined;
    for ([_]i64{ chosen, doubted }, &proposal_ids) |track_id, *proposal_id| {
        const page = try runtime.libraryMatchProposals(library, track_id, 1);
        defer page.deinit();
        proposal_id.* = page.items[0].id;
    }
    for (proposal_ids) |proposal_id| _ = try runtime.libraryAcceptMatch(library, proposal_id);
    try std.testing.expectEqual(@as(u64, 2), try runtime.libraryAcoustIdSubmittableCount(library));

    const matching = try runtime.startLibraryMatching(library, .{ .fingerprints = false });
    try std.testing.expectError(error.AcoustIdBusy, runtime.startAcoustIdSubmission(library));
    try runtime.cancelJob(matching);
    _ = try runtime_tests.awaitJob(&runtime, matching);

    const without_key = try runtime.startAcoustIdSubmission(library);
    try std.testing.expectEqual(job.State.failed, try runtime_tests.awaitJob(&runtime, without_key));
    try std.testing.expectEqual(SubmissionOutcome.needs_user_key, (try runtime.jobSubmissionStats(without_key)).outcome);
    try std.testing.expectEqual(@as(u32, 0), acoustid.submissions.load(.acquire));

    user.key = "user key";
    acoustid.submit_status = 400;
    const refused_body = "{\"status\":\"error\",\"error\":{\"code\":6,\"message\":\"invalid user API key\"}}";
    const accepted_body = acoustid.submit_body;
    acoustid.submit_body = refused_body;
    const refused = try runtime.startAcoustIdSubmission(library);
    try std.testing.expectEqual(job.State.failed, try runtime_tests.awaitJob(&runtime, refused));
    try std.testing.expectEqual(SubmissionOutcome.invalid_user_key, (try runtime.jobSubmissionStats(refused)).outcome);
    try std.testing.expectEqual(@as(u64, 2), try runtime.libraryAcoustIdSubmittableCount(library));

    acoustid.submit_status = 200;
    acoustid.submit_body = accepted_body;
    const sent = try runtime.startAcoustIdSubmission(library);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, sent));
    const stats = try runtime.jobSubmissionStats(sent);
    try std.testing.expectEqual(SubmissionOutcome.completed, stats.outcome);
    try std.testing.expectEqual(@as(u64, 2), stats.submitted);
    try std.testing.expectEqual(@as(u64, 1), stats.sent_as_metadata);
    try std.testing.expectEqual(@as(u64, 1), stats.requests);
    const form = acoustid.lastForm();
    try std.testing.expect(std.mem.indexOf(u8, form, "&user=user%20key&") != null);
    try std.testing.expect(std.mem.indexOf(u8, form, "&mbid.0=" ++ northern_sky_mbid) != null);
    try std.testing.expect(std.mem.indexOf(u8, form, "&mbid.1=") == null);
    try std.testing.expect(std.mem.indexOf(u8, form, "&track.1=Pink%20Moon&artist.1=Nick%20Drake") != null);
    try std.testing.expectEqual(@as(i64, 72), try database.columns.scalar(library_database.database, "SELECT submission_id FROM acoustid_submissions WHERE recording_mbid = '" ++ pink_moon_mbid ++ "';"));
    try std.testing.expectEqual(@as(u64, 0), try runtime.libraryAcoustIdSubmittableCount(library));

    const again = try runtime.startAcoustIdSubmission(library);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, again));
    try std.testing.expectEqual(@as(u64, 0), (try runtime.jobSubmissionStats(again)).files_examined);
    try std.testing.expectEqual(@as(u32, 2), acoustid.submissions.load(.acquire));
}

pub const bryter_layter_mbid = "2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b";
pub const jpeg_cover = "\xff\xd8\xff\xe0\x00\x10JFIF cover";

/// The Cover Art Archive, answering every request alike on the job's thread.
pub const FakeCoverArt = struct {
    http: network.testing.ScriptedTransport = .{},
    status: u16 = 200,
    body: []const u8 = jpeg_cover,
    /// Redirects answered, in order, before the image.
    locations: []const []const u8 = &.{},

    pub fn attach(self: *FakeCoverArt, hooks: *MatchingHooks) void {
        self.http.keep_history = true;
        self.http.responder = .{ .context = self, .respond_fn = respond };
        hooks.cover_art_transport = self.http.transport();
    }

    pub fn deinit(self: *FakeCoverArt) void {
        self.http.deinit();
    }

    pub fn requestCount(self: *const FakeCoverArt) u32 {
        return self.http.requestCount();
    }

    fn respond(context: *anyopaque, exchange: network.testing.Exchange, _: ?network.testing.Reply) anyerror!network.testing.Reply {
        const self: *FakeCoverArt = @ptrCast(@alignCast(context));
        if (exchange.index < self.locations.len)
            return .{ .respond = .{ .status = 307, .body = "", .location = self.locations[exchange.index] } };
        return .{ .respond = .{ .status = self.status, .body = self.body } };
    }
};

pub fn addRelease(library_database: *database.LibraryDatabase, title: []const u8, mbid: ?[]const u8) !i64 {
    return library_database.releases.upsert(.{ .release_key = title, .title = title, .musicbrainz_release_id = mbid });
}

pub fn addAlbumTrack(library_database: *database.LibraryDatabase, release_id: i64, title: []const u8) !i64 {
    const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
    try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = .{ .title = title } });
    try library_database.tracks.upsertTracks(&.{.{
        .release_id = release_id,
        .title = title,
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .duration_ms = 180_000,
        .preferred_file_id = file_id,
    }});
    const ids = try library_database.tracks.idsForFile(std.testing.allocator, file_id);
    defer std.testing.allocator.free(ids);
    return ids[0];
}

fn pendingCount(runtime: *OrcaRuntime, library: LibraryHandle, track_id: i64) !usize {
    const proposals = try runtime.libraryMatchProposals(library, track_id, 10);
    defer proposals.deinit();
    return proposals.items.len;
}

fn recordingIdOf(runtime: *OrcaRuntime, library: LibraryHandle, track_id: i64) ![36]u8 {
    const details = (try runtime.libraryTrackDetails(library, track_id)).?;
    defer details.deinit();
    return (details.musicbrainz_recording_id orelse return error.NoRecordingId)[0..36].*;
}

test "a release-scoped matching job searches only that Release's Tracks and accepts only its confident matches, never a correction of a locked recording ID" {
    var fake: FakeMusicBrainz = .{ .answers = &.{
        .{ .title = "Northern%20Sky", .body = northern_sky_answer },
        .{ .title = "Pink%20Moon", .body = pink_moon_answer },
    } };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-release?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const album = try addRelease(library_database, "Bryter Layter", null);
    const other = try addRelease(library_database, "Pink Moon", null);
    const northern_sky = try addAlbumTrack(library_database, album, "Northern Sky");
    const locked = try addAlbumTrack(library_database, album, "Hazey Jane I");
    const pink_moon = try addAlbumTrack(library_database, other, "Pink Moon");
    const locked_files = try library_database.tracks.fileIds(std.testing.allocator, locked);
    defer std.testing.allocator.free(locked_files);
    try library_database.orca_metadata.upsert(.{
        .file_id = locked_files[0],
        .field = .musicbrainz_recording_id,
        .value = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a",
        .provenance = .user,
        .locked = true,
    });
    const payload = try (database.ProposalPayload{ .release_mbid = bryter_layter_mbid, .musicbrainz_confidence = 0.95 }).encode(std.testing.allocator);
    defer std.testing.allocator.free(payload);
    _ = try library_database.identification_proposals.put(.{
        .file_id = locked_files[0],
        .provider = "musicbrainz",
        .provider_id = pink_moon_mbid,
        .confidence = 0.95,
        .payload = payload,
    });

    try std.testing.expectError(error.InvalidMatchRequest, runtime.startLibraryMatching(library, .{ .cover_art = true }));
    try std.testing.expectError(error.InvalidMatchRequest, runtime.startLibraryMatching(library, .{ .track_id = northern_sky, .release_id = album }));
    try std.testing.expectError(error.UnknownRelease, runtime.startLibraryMatching(library, .{ .release_id = other + 100 }));
    const job_handle = try runtime.startLibraryMatching(library, .{ .release_id = album, .accept_minimum_confidence = 0.9 });

    try std.testing.expectEqual(@as(?u64, 1), (try runtime.jobSnapshotSynced(job_handle)).total_units);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, job_handle));
    const stats = try runtime.jobMatchStats(job_handle);
    try std.testing.expectEqual(@as(u64, 1), stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 1), stats.accepted);
    try std.testing.expectEqual(runtime_module.CoverArtOutcome.not_requested, stats.cover_art);
    try std.testing.expectEqual(@as(u32, 2), fake.requestCount());
    try std.testing.expectEqualStrings(northern_sky_mbid, &try recordingIdOf(&runtime, library, northern_sky));
    try std.testing.expectEqualStrings("8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a", &try recordingIdOf(&runtime, library, locked));
    try std.testing.expectEqual(@as(usize, 1), try pendingCount(&runtime, library, locked));
    try std.testing.expectEqual(@as(usize, 0), try pendingCount(&runtime, library, pink_moon));

    runtime.reapFinishedJobs();
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, try runtime.startLibraryMatching(library, .{})));
    try std.testing.expectEqual(@as(usize, 1), try pendingCount(&runtime, library, pink_moon));
    runtime.reapFinishedJobs();
    const again = try runtime.startLibraryMatching(library, .{ .release_id = album, .accept_minimum_confidence = 0.9 });
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, again));
    try std.testing.expectEqual(@as(u64, 0), (try runtime.jobMatchStats(again)).accepted);
    try std.testing.expectEqual(@as(usize, 1), try pendingCount(&runtime, library, pink_moon));
}

/// A file in a folder with only the tags given, as the scanner would leave it.
fn observeFile(library_database: *database.LibraryDatabase, uri: []const u8, title: []const u8, artist: []const u8) !i64 {
    const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
    _ = try library_database.locations.upsert(.{
        .file_id = file_id,
        .volume_id = database.LibraryDatabase.null_volume,
        .uri = uri,
        .state = .present,
    });
    try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = .{ .title = title, .artist = artist } });
    return file_id;
}

fn projectAll(library_database: *database.LibraryDatabase) !void {
    var projection: library_pass.Projection = .{ .allocator = std.testing.allocator, .library = library_database };
    _ = try projection.run(.all);
}

fn releaseOfFile(library_database: *database.LibraryDatabase, file_id: i64) !i64 {
    var statement = try library_database.database.prepare("SELECT release_id FROM tracks WHERE preferred_file_id = ?1;");
    defer statement.deinit();
    try statement.bindInt64(1, file_id);
    try std.testing.expectEqual(database.sqlite.Step.row, try statement.step());
    return statement.columnInt64(0);
}

pub fn trackOfFile(library_database: *database.LibraryDatabase, file_id: i64) !i64 {
    const ids = try library_database.tracks.idsForFile(std.testing.allocator, file_id);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 1), ids.len);
    return ids[0];
}

/// What a search and a lookup of Bryter Layter say about one of its tracks.
fn bryterLayterPayload(title: []const u8, track_mbid: []const u8, position: u32) database.ProposalPayload {
    var payload: database.ProposalPayload = .{
        .title = title,
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .release_mbid = bryter_layter_mbid,
        .mb_score = 100,
        .musicbrainz_confidence = 0.95,
    };
    payload.enrich(bryter_layter_mbid, .{
        .track_title = title,
        .track_artist = "Nick Drake",
        .release_title = "Bryter Layter",
        .release_artist = "Nick Drake",
        .release_artist_mbid = nick_drake_mbid,
        .release_date = "1971-03-01",
        .release_group_mbid = bryter_layter_group_mbid,
        .release_track_mbid = track_mbid,
        .track_number = position,
        .disc_number = 1,
    });
    return payload;
}

fn putPayload(library_database: *database.LibraryDatabase, file_id: i64, recording_mbid: []const u8, payload: database.ProposalPayload) !i64 {
    const encoded = try payload.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    _ = try library_database.identification_proposals.put(.{
        .file_id = file_id,
        .provider = "musicbrainz",
        .provider_id = recording_mbid,
        .confidence = 0.95,
        .payload = encoded,
    });
    var statement = try library_database.database.prepare("SELECT id FROM identification_proposals WHERE file_id = ?1 AND provider_id = ?2;");
    defer statement.deinit();
    try statement.bindInt64(1, file_id);
    try statement.bindText(2, recording_mbid);
    try std.testing.expectEqual(database.sqlite.Step.row, try statement.step());
    return statement.columnInt64(0);
}

fn orcaValue(library_database: *database.LibraryDatabase, file_id: i64, field: metadata.Field) !?[]u8 {
    const stored = (try library_database.orca_metadata.get(std.testing.allocator, file_id, field)) orelse return null;
    return stored.text;
}

fn expectOrcaValue(library_database: *database.LibraryDatabase, file_id: i64, field: metadata.Field, expected: ?[]const u8) !void {
    const stored = try orcaValue(library_database, file_id, field);
    defer if (stored) |text| std.testing.allocator.free(text);
    if (expected) |text| {
        try std.testing.expectEqualStrings(text, stored orelse return error.TestExpectedValue);
    } else try std.testing.expectEqual(@as(?[]u8, null), stored);
}

test "Match Album points every file at the release most of them list, accepts, and the cover follows the album to its new Release id" {
    var fake: FakeMusicBrainz = .{};
    var cover: FakeCoverArt = .{ .locations = &.{
        "https://archive.org/download/mbid-x/front.jpg",
        "https://dn710702.ca.archive.org/0/items/mbid-x/front.jpg",
    } };
    defer cover.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    cover.attach(&runtime.matching_hooks);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-match-album-cover?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try observeFile(library_database, "/music/drake/01.flac", "Northern Sky", "Nick Drake");
    const pink_moon = try observeFile(library_database, "/music/drake/02.flac", "Pink Moon", "Nick Drake");
    try projectAll(library_database);
    const album = try releaseOfFile(library_database, northern_sky);
    try std.testing.expectEqual(album, try releaseOfFile(library_database, pink_moon));
    try std.testing.expect((try runtime.libraryReleaseArtwork(library, std.testing.io, album)) == null);

    const other_edition = "9c8b7a6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d";
    const both_editions = [_][]const u8{ other_edition, bryter_layter_mbid };
    const one_edition = [_][]const u8{bryter_layter_mbid};
    for ([_]struct { file: i64, recording: []const u8, title: []const u8, best: []const u8, listed: []const []const u8 }{
        .{ .file = northern_sky, .recording = northern_sky_mbid, .title = "Northern Sky", .best = other_edition, .listed = &both_editions },
        .{ .file = pink_moon, .recording = pink_moon_mbid, .title = "Pink Moon", .best = bryter_layter_mbid, .listed = &one_edition },
    }) |found| {
        const evidence = [_]database.ProposalEvidence{.{
            .recording_mbid = found.recording,
            .found_by = .{ .musicbrainz = true },
            .payload = .{
                .title = found.title,
                .artist = "Nick Drake",
                .release_mbid = found.best,
                .release_mbids = found.listed,
                .mb_score = 100,
                .musicbrainz_confidence = 0.95,
            },
        }};
        _ = try library_database.identification_proposals.recordSearch(std.testing.allocator, found.file, .{ .musicbrainz = true }, &evidence);
    }

    const job_handle = try runtime.startLibraryMatching(library, .{
        .release_id = album,
        .accept_minimum_confidence = 0.9,
        .cover_art = true,
    });

    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, job_handle));
    const stats = try runtime.jobMatchStats(job_handle);
    try std.testing.expectEqual(@as(u64, 2), stats.accepted);
    try std.testing.expectEqual(runtime_module.CoverArtOutcome.fetched, stats.cover_art);
    try std.testing.expectEqual(@as(u32, 1), fake.requestCount());
    try std.testing.expect(std.mem.indexOf(u8, fake.transport.lastUrl(), "/ws/2/release/" ++ bryter_layter_mbid) != null);
    try std.testing.expectEqual(@as(u32, 3), cover.requestCount());
    try std.testing.expectEqualStrings(
        "https://coverartarchive.org/release/" ++ bryter_layter_mbid ++ "/front-500",
        cover.http.history.items[0].url,
    );
    try std.testing.expectEqual(@as(i64, 2), try database.columns.scalar(
        library_database.database,
        "SELECT count(*) FROM identification_proposals WHERE state = 1 AND payload LIKE '%\"release_mbid\":\"" ++ bryter_layter_mbid ++ "\"%';",
    ));
    try expectOrcaValue(library_database, northern_sky, .musicbrainz_release_id, bryter_layter_mbid);
    try expectOrcaValue(library_database, northern_sky, .track_number, "3");

    const regrouped = try releaseOfFile(library_database, northern_sky);
    try std.testing.expect(regrouped != album);
    try std.testing.expectEqual(regrouped, try releaseOfFile(library_database, pink_moon));
    try std.testing.expect((try runtime.libraryRelease(library, album)) == null);
    const release = (try runtime.libraryRelease(library, regrouped)).?;
    defer release.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Bryter Layter", release.title);
    try std.testing.expectEqualStrings("Nick Drake", release.album_artist);
    const release_cover = (try runtime.libraryReleaseArtwork(library, std.testing.io, regrouped)).?;
    defer release_cover.deinit();
    try std.testing.expectEqualStrings("image/jpeg", release_cover.mime_type);
    try std.testing.expectEqualStrings(jpeg_cover, release_cover.bytes);
    const track_cover = (try runtime.libraryTrackArtwork(library, std.testing.io, try trackOfFile(library_database, northern_sky))).?;
    defer track_cover.deinit();
    try std.testing.expectEqualStrings(jpeg_cover, track_cover.bytes);

    runtime.reapFinishedJobs();
    const refetch = try runtime.startReleaseCoverArtFetch(library, regrouped);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, refetch));
    try std.testing.expectEqual(runtime_module.CoverArtOutcome.cached, (try runtime.jobMatchStats(refetch)).cover_art);
    try std.testing.expectEqual(@as(u32, 3), cover.requestCount());
}

test "Match Album breaks a tie between editions for the Official one with the album's track count" {
    var fake: FakeMusicBrainz = .{};
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-match-album-edition?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try observeFile(library_database, "/music/drake/01.flac", "Northern Sky", "Nick Drake");
    const pink_moon = try observeFile(library_database, "/music/drake/02.flac", "Pink Moon", "Nick Drake");
    try projectAll(library_database);
    const album = try releaseOfFile(library_database, northern_sky);

    const bootleg = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d";
    const reissue = "1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9";
    const editions = [_][]const u8{ bootleg, reissue, bryter_layter_mbid };
    const facts = [_]database.ReleaseFact{
        .{ .mbid = bootleg, .status = "Bootleg", .date = "1970", .track_count = 2 },
        .{ .mbid = reissue, .status = "Official", .date = "2000", .track_count = 14 },
        .{ .mbid = bryter_layter_mbid, .status = "Official", .date = "1971-03-01", .track_count = 2 },
    };
    for ([_]struct { file: i64, recording: []const u8, title: []const u8 }{
        .{ .file = northern_sky, .recording = northern_sky_mbid, .title = "Northern Sky" },
        .{ .file = pink_moon, .recording = pink_moon_mbid, .title = "Pink Moon" },
    }) |found| {
        const evidence = [_]database.ProposalEvidence{.{
            .recording_mbid = found.recording,
            .found_by = .{ .musicbrainz = true },
            .payload = .{
                .title = found.title,
                .artist = "Nick Drake",
                .release_mbid = bootleg,
                .release_mbids = &editions,
                .release_facts = &facts,
                .mb_score = 100,
                .musicbrainz_confidence = 0.95,
            },
        }};
        _ = try library_database.identification_proposals.recordSearch(std.testing.allocator, found.file, .{ .musicbrainz = true }, &evidence);
    }

    const job_handle = try runtime.startLibraryMatching(library, .{ .release_id = album, .accept_minimum_confidence = 0.9 });

    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, job_handle));
    try std.testing.expectEqual(@as(u64, 2), (try runtime.jobMatchStats(job_handle)).accepted);
    try std.testing.expectEqual(@as(u32, 1), fake.requestCount());
    try std.testing.expect(std.mem.indexOf(u8, fake.transport.lastUrl(), "/ws/2/release/" ++ bryter_layter_mbid) != null);
    try expectOrcaValue(library_database, northern_sky, .musicbrainz_release_id, bryter_layter_mbid);
    try expectOrcaValue(library_database, pink_moon, .musicbrainz_release_id, bryter_layter_mbid);
}

test "a Match Album whose accept adds a release ID reports the Release its files moved to, and the old Release no longer resolves" {
    var fake: FakeMusicBrainz = .{};
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-match-album-moved?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try observeFile(library_database, "/music/drake/01.flac", "Northern Sky", "Nick Drake");
    const pink_moon = try observeFile(library_database, "/music/drake/02.flac", "Pink Moon", "Nick Drake");
    try projectAll(library_database);
    const album = try releaseOfFile(library_database, northern_sky);
    const editions = [_][]const u8{bryter_layter_mbid};
    for ([_]struct { file: i64, recording: []const u8, title: []const u8 }{
        .{ .file = northern_sky, .recording = northern_sky_mbid, .title = "Northern Sky" },
        .{ .file = pink_moon, .recording = pink_moon_mbid, .title = "Pink Moon" },
    }) |found| {
        const evidence = [_]database.ProposalEvidence{.{
            .recording_mbid = found.recording,
            .found_by = .{ .musicbrainz = true },
            .payload = .{
                .title = found.title,
                .artist = "Nick Drake",
                .release_mbid = bryter_layter_mbid,
                .release_mbids = &editions,
                .mb_score = 100,
                .musicbrainz_confidence = 0.95,
            },
        }};
        _ = try library_database.identification_proposals.recordSearch(std.testing.allocator, found.file, .{ .musicbrainz = true }, &evidence);
    }

    const job_handle = try runtime.startLibraryMatching(library, .{ .release_id = album, .accept_minimum_confidence = 0.9 });

    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, job_handle));
    try std.testing.expectEqual(@as(u64, 2), (try runtime.jobMatchStats(job_handle)).accepted);
    const moved_to = try releaseOfFile(library_database, northern_sky);
    try std.testing.expect(moved_to != album);
    try std.testing.expectEqual(@as(?i64, moved_to), try runtime.jobMatchRelease(job_handle));
    try std.testing.expect((try runtime.libraryRelease(library, album)) == null);
    const release = (try runtime.libraryRelease(library, moved_to)).?;
    defer release.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Bryter Layter", release.title);
}

test "a Match Album that changes no key reports the Release it started on, and a job that is not a finished Match Album reports none" {
    var fake: FakeMusicBrainz = .{ .hang_from = 0 };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-match-album-kept?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try observeFile(library_database, "/music/drake/01.flac", "Northern Sky", "Nick Drake");
    _ = try observeFile(library_database, "/music/drake/02.flac", "Pink Moon", "Nick Drake");
    try projectAll(library_database);
    const album = try releaseOfFile(library_database, northern_sky);

    const hanging = try runtime.startLibraryMatching(library, .{ .release_id = album, .accept_minimum_confidence = 0.9 });
    try fake.awaitRequests(1);
    try std.testing.expectEqual(@as(?i64, null), try runtime.jobMatchRelease(hanging));
    try runtime.cancelJob(hanging);
    try std.testing.expectEqual(job.State.cancelled, try runtime_tests.awaitJob(&runtime, hanging));
    try std.testing.expectEqual(@as(?i64, album), try runtime.jobMatchRelease(hanging));
    fake.hang_from = null;

    runtime.reapFinishedJobs();
    const unchanged = try runtime.startLibraryMatching(library, .{ .release_id = album, .accept_minimum_confidence = 0.9 });
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, unchanged));
    try std.testing.expectEqual(@as(u64, 0), (try runtime.jobMatchStats(unchanged)).accepted);
    try std.testing.expectEqual(@as(?i64, album), try runtime.jobMatchRelease(unchanged));
    try std.testing.expectEqual(album, try releaseOfFile(library_database, northern_sky));

    runtime.reapFinishedJobs();
    const whole_library = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, whole_library));
    try std.testing.expectEqual(@as(?i64, null), try runtime.jobMatchRelease(whole_library));
    runtime.reapFinishedJobs();
    const one_track = try runtime.startLibraryMatching(library, .{ .track_id = try trackOfFile(library_database, northern_sky) });
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, one_track));
    try std.testing.expectEqual(@as(?i64, null), try runtime.jobMatchRelease(one_track));
    runtime.reapFinishedJobs();
    const projection = try runtime.startLibraryProjection(library);
    _ = try runtime_tests.awaitJob(&runtime, projection);
    try std.testing.expectEqual(@as(?i64, null), try runtime.jobMatchRelease(projection));
    try std.testing.expectError(error.StaleHandle, runtime.jobMatchRelease(.{ .index = 999, .generation = 7 }));
}

test "accepting one file of a two-file Release stores its title and artist only, and accepting the other stores the release's values on both" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-accept-release-values?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try observeFile(library_database, "/music/drake/01.flac", "Northern Sky", "Nick Drake");
    const pink_moon = try observeFile(library_database, "/music/drake/02.flac", "Pink Moon", "Nick Drake");
    try projectAll(library_database);
    const untitled = try releaseOfFile(library_database, northern_sky);
    const first = try putPayload(library_database, northern_sky, northern_sky_mbid, bryterLayterPayload("Northern Sky", northern_sky_track_mbid, 3));
    const second = try putPayload(library_database, pink_moon, pink_moon_mbid, bryterLayterPayload("Pink Moon", pink_moon_track_mbid, 4));

    try std.testing.expectEqual(@as(u32, 3), (try runtime.libraryAcceptMatch(library, first)).values_written);
    try expectOrcaValue(library_database, northern_sky, .title, "Northern Sky");
    try expectOrcaValue(library_database, northern_sky, .artist, "Nick Drake");
    try expectOrcaValue(library_database, northern_sky, .album, null);
    try expectOrcaValue(library_database, pink_moon, .title, null);
    try std.testing.expectEqual(untitled, try releaseOfFile(library_database, northern_sky));

    try std.testing.expectEqual(@as(u32, 3 + 2 * 9), (try runtime.libraryAcceptMatch(library, second)).values_written);
    for ([_]struct { file: i64, position: []const u8, track_mbid: []const u8 }{
        .{ .file = northern_sky, .position = "3", .track_mbid = northern_sky_track_mbid },
        .{ .file = pink_moon, .position = "4", .track_mbid = pink_moon_track_mbid },
    }) |expected| {
        try expectOrcaValue(library_database, expected.file, .album, "Bryter Layter");
        try expectOrcaValue(library_database, expected.file, .album_artist, "Nick Drake");
        try expectOrcaValue(library_database, expected.file, .date, "1971-03-01");
        try expectOrcaValue(library_database, expected.file, .disc_number, "1");
        try expectOrcaValue(library_database, expected.file, .track_number, expected.position);
        try expectOrcaValue(library_database, expected.file, .musicbrainz_release_id, bryter_layter_mbid);
        try expectOrcaValue(library_database, expected.file, .musicbrainz_release_group_id, bryter_layter_group_mbid);
        try expectOrcaValue(library_database, expected.file, .musicbrainz_release_track_id, expected.track_mbid);
        try expectOrcaValue(library_database, expected.file, .musicbrainz_album_artist_id, nick_drake_mbid);
        try expectOrcaValue(library_database, expected.file, .compilation, null);
    }

    var tracks = try library_database.tracks.page(std.testing.allocator, .{ .limit = 16, .offset = 0, .sort = .track_number });
    defer tracks.deinit();
    try std.testing.expectEqual(@as(usize, 2), tracks.items.len);
    for (tracks.items, [_]i64{ 3, 4 }) |track, position| {
        try std.testing.expectEqualStrings("Bryter Layter", track.album);
        try std.testing.expectEqual(@as(?i64, position), track.track_number);
    }
    var releases = try runtime.libraryReleasePage(library, .{});
    defer releases.deinit();
    try std.testing.expectEqual(@as(usize, 1), releases.items.len);
    try std.testing.expectEqualStrings("Bryter Layter", releases.items[0].title);
    try std.testing.expect(releases.items[0].id != untitled);
    const details = (try runtime.libraryTrackDetails(library, try trackOfFile(library_database, northern_sky))).?;
    defer details.deinit();
    try std.testing.expectEqualStrings(bryter_layter_mbid, details.musicbrainz_release_id.?);
    try std.testing.expectEqual(@as(?RecordingIdSource, .match), details.musicbrainz_release_id_source);
    try std.testing.expectEqualStrings(nick_drake_mbid, details.musicbrainz_album_artist_id.?);

    try std.testing.expectEqual(@as(u32, 0), try runtime.libraryApplyMatchedRelease(library, releases.items[0].id, null));
}

test "an accept keeps a locked title, still stores the other values, and a Various Artists release marks a compilation" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-accept-locked-title?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const file = try observeFile(library_database, "/music/mix/01.flac", "Northern Sky", "Nick Drake");
    try projectAll(library_database);
    try library_database.orca_metadata.upsert(.{ .file_id = file, .field = .title, .value = "My Title", .provenance = .user, .locked = true });
    var payload = bryterLayterPayload("Northern Sky", northern_sky_track_mbid, 3);
    payload.release_artist = "Various Artists";
    payload.release_artist_mbid = database.repository.various_artists_mbid;
    payload.release_date = "";

    const acceptance = try runtime.libraryAcceptMatch(library, try putPayload(library_database, file, northern_sky_mbid, payload));

    try std.testing.expectEqual(@as(u32, 2 + 9), acceptance.values_written);
    const title = (try library_database.orca_metadata.get(std.testing.allocator, file, .title)).?;
    defer title.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("My Title", title.text);
    try std.testing.expect(title.locked);
    try expectOrcaValue(library_database, file, .artist, "Nick Drake");
    try expectOrcaValue(library_database, file, .date, null);
    try expectOrcaValue(library_database, file, .compilation, "1");
    try expectOrcaValue(library_database, file, .album_artist, "Various Artists");
}

test "a stray file accepted on another release blocks the album's values until an edit moves it out and apply-release runs" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-accept-stray?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try observeFile(library_database, "/music/drake/01.flac", "Northern Sky", "Nick Drake");
    const pink_moon = try observeFile(library_database, "/music/drake/02.flac", "Pink Moon", "Nick Drake");
    const stray = try observeFile(library_database, "/music/drake/03.flac", "Hazey Jane I", "Nick Drake");
    try projectAll(library_database);
    var elsewhere = bryterLayterPayload("Hazey Jane I", "8e9f0a1b-2c3d-4e4f-8a5b-6c7d8e9f0a1b", 2);
    elsewhere.enrich("9c8b7a6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d", .{
        .release_title = "Fruit Tree",
        .release_track_mbid = "8e9f0a1b-2c3d-4e4f-8a5b-6c7d8e9f0a1b",
        .track_number = 2,
        .disc_number = 1,
    });
    _ = try runtime.libraryAcceptMatch(library, try putPayload(library_database, northern_sky, northern_sky_mbid, bryterLayterPayload("Northern Sky", northern_sky_track_mbid, 3)));
    _ = try runtime.libraryAcceptMatch(library, try putPayload(library_database, pink_moon, pink_moon_mbid, bryterLayterPayload("Pink Moon", pink_moon_track_mbid, 4)));
    _ = try runtime.libraryAcceptMatch(library, try putPayload(library_database, stray, "0b3c4d5e-6f70-4812-9a3b-4c5d6e7f8092", elsewhere));
    try expectOrcaValue(library_database, northern_sky, .album, null);
    const album = try releaseOfFile(library_database, northern_sky);
    try std.testing.expectEqual(@as(u32, 0), try runtime.libraryApplyMatchedRelease(library, album, null));

    const moved = try runtime.libraryEditTracks(library, &.{try trackOfFile(library_database, stray)}, &.{.{ .field = .album, .value = "Strays" }});
    moved.deinit();
    try std.testing.expectEqual(@as(u32, 2 * 9), try runtime.libraryApplyMatchedRelease(library, album, null));

    try expectOrcaValue(library_database, northern_sky, .album, "Bryter Layter");
    try expectOrcaValue(library_database, pink_moon, .musicbrainz_release_id, bryter_layter_mbid);
    try expectOrcaValue(library_database, stray, .musicbrainz_release_id, null);
    try std.testing.expect(try releaseOfFile(library_database, northern_sky) != album);
    try std.testing.expectError(error.UnknownRelease, runtime.libraryApplyMatchedRelease(library, album, null));
}

test "library matching looks the best release up before storing a search, asks nothing again within thirty days, stops on an unreachable lookup and stores a missing release unlooked" {
    var fake: FakeMusicBrainz = .{ .answers = &.{
        .{ .title = "Northern%20Sky", .body = northern_sky_answer },
        .{ .title = "Pink%20Moon", .body = pink_moon_answer },
    } };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-matching-enrich?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);

    const first = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, first));
    try std.testing.expectEqual(@as(u64, 2), (try runtime.jobMatchStats(first)).requests);
    {
        const proposals = try runtime.libraryMatchProposals(library, northern_sky, 10);
        defer proposals.deinit();
        const proposal = proposals.items[0];
        try std.testing.expectEqualStrings(bryter_layter_mbid, proposal.release_mbid.?);
        try std.testing.expectEqualStrings("Bryter Layter", proposal.release_title.?);
        try std.testing.expectEqualStrings("1971-03-01", proposal.release_date.?);
        try std.testing.expectEqualStrings(northern_sky_track_mbid, proposal.release_track_mbid.?);
        try std.testing.expectEqual(@as(?u32, 1), proposal.disc_number);
        try std.testing.expectEqual(@as(?u32, 3), proposal.track_number);
    }

    try library_database.database.exec("DELETE FROM identification_searches;");
    runtime.reapFinishedJobs();
    const cached = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, cached));
    const cached_stats = try runtime.jobMatchStats(cached);
    try std.testing.expectEqual(@as(u64, 0), cached_stats.requests);
    try std.testing.expectEqual(@as(u64, 2), cached_stats.cache_hits);
    try std.testing.expectEqual(@as(u32, 2), fake.requestCount());

    const pink_moon = try addMatchTrack(library_database, "Pink Moon", "Nick Drake", null);
    try library_database.database.exec("DELETE FROM provider_cache WHERE request_key LIKE '%/ws/2/release/%';");
    fake.release_status = 503;
    fake.release_body = "";
    runtime.reapFinishedJobs();
    const unreachable_job = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.failed, try runtime_tests.awaitJob(&runtime, unreachable_job));
    try std.testing.expectEqual(@as(u32, 2 + 1 + 3), fake.requestCount());
    try std.testing.expectEqual(@as(usize, 0), try pendingCount(&runtime, library, pink_moon));
    try std.testing.expectEqual(@as(u64, 1), try library_database.identification_proposals.unidentifiedCount(.library, .unidentified, false, null));

    fake.release_status = 404;
    fake.release_body = "{\"error\":\"Not Found\"}";
    runtime.reapFinishedJobs();
    const missing = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, missing));
    try std.testing.expectEqual(@as(u32, 2 + 1 + 3 + 1), fake.requestCount());
    const proposals = try runtime.libraryMatchProposals(library, pink_moon, 10);
    defer proposals.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposals.items.len);
    try std.testing.expectEqualStrings(bryter_layter_mbid, proposals.items[0].release_mbid.?);
    try std.testing.expectEqual(@as(?[]const u8, null), proposals.items[0].release_title);
}

test "a cover the archive does not have is not asked for again for 30 days, and is asked for after" {
    var fake: FakeMusicBrainz = .{};
    var cover: FakeCoverArt = .{ .status = 404, .body = "" };
    defer cover.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    cover.attach(&runtime.matching_hooks);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-cover-negative?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const album = try addRelease(library_database, "Bryter Layter", bryter_layter_mbid);
    _ = try addAlbumTrack(library_database, album, "Northern Sky");

    for ([_]runtime_module.CoverArtOutcome{ .not_found, .cached_miss }) |expected| {
        runtime.reapFinishedJobs();
        const fetch = try runtime.startReleaseCoverArtFetch(library, album);
        try std.testing.expectEqual(@as(?u64, 0), (try runtime.jobSnapshotSynced(fetch)).total_units);
        try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, fetch));
        try std.testing.expectEqual(expected, (try runtime.jobMatchStats(fetch)).cover_art);
        try std.testing.expectEqual(@as(u32, 1), cover.requestCount());
    }
    try std.testing.expect(!(try library_database.release_artwork.get(album)).?.has_image);
    try std.testing.expectEqual(@as(u32, 0), fake.requestCount());

    fake.clock.advance(30 * std.time.ms_per_day - 1000);
    runtime.reapFinishedJobs();
    const early = try runtime.startReleaseCoverArtFetch(library, album);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, early));
    try std.testing.expectEqual(runtime_module.CoverArtOutcome.cached_miss, (try runtime.jobMatchStats(early)).cover_art);

    fake.clock.advance(1000);
    cover.status = 200;
    cover.body = jpeg_cover;
    runtime.reapFinishedJobs();
    const later = try runtime.startReleaseCoverArtFetch(library, album);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, later));
    try std.testing.expectEqual(runtime_module.CoverArtOutcome.fetched, (try runtime.jobMatchStats(later)).cover_art);
    try std.testing.expectEqual(@as(u32, 2), cover.requestCount());
}

test "a cover fetch without a release ID asks nothing, and a second redirect to plain http stores nothing and fails" {
    var fake: FakeMusicBrainz = .{};
    var cover: FakeCoverArt = .{ .locations = &.{
        "https://archive.org/download/mbid-x/front.jpg",
        "http://dn710702.ca.archive.org/0/items/mbid-x/front.jpg",
    } };
    defer cover.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    cover.attach(&runtime.matching_hooks);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-cover-refused?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const untagged = try addRelease(library_database, "Five Leaves Left", null);
    const tagged = try addRelease(library_database, "Bryter Layter", bryter_layter_mbid);

    const unnamed = try runtime.startReleaseCoverArtFetch(library, untagged);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, unnamed));
    try std.testing.expectEqual(runtime_module.CoverArtOutcome.no_release_id, (try runtime.jobMatchStats(unnamed)).cover_art);
    try std.testing.expectEqual(@as(u32, 0), cover.requestCount());

    runtime.reapFinishedJobs();
    const redirected = try runtime.startReleaseCoverArtFetch(library, tagged);
    try std.testing.expectEqual(job.State.failed, try runtime_tests.awaitJob(&runtime, redirected));
    try std.testing.expectEqual(runtime_module.CoverArtOutcome.refused, (try runtime.jobMatchStats(redirected)).cover_art);
    try std.testing.expectEqual(@as(u32, 2), cover.requestCount());
    try std.testing.expect((try library_database.release_artwork.get(tagged)) == null);
}

const candidate_group_mbid = "7a8b9c0d-1e2f-4a3b-8c4d-5e6f7a8b9c0d";
const candidate_group_release_mbid = "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f";

const candidate_release_index =
    \\{"images": [
    \\  {"id": 101, "types": ["Front"], "front": true, "approved": true},
    \\  {"id": 102, "types": ["Back"], "back": true, "approved": true},
    \\  {"id": 103, "types": ["Booklet"], "approved": false}
    \\], "release": "https://musicbrainz.org/release/
++ bryter_layter_mbid ++ "\"}";

const candidate_group_index =
    \\{"images": [
    \\  {"id": 101, "types": ["Front"], "front": true, "approved": true},
    \\  {"id": 201, "types": ["Front"], "front": true, "approved": true},
    \\  {"id": 202, "types": ["Back"], "back": true, "approved": true}
    \\], "release": "https://musicbrainz.org/release/
++ candidate_group_release_mbid ++ "\"}";

fn candidatePng(comptime width: u32, comptime height: u32) []const u8 {
    return comptime png: {
        var bytes: [33]u8 = undefined;
        @memcpy(bytes[0..8], "\x89PNG\r\n\x1a\n");
        std.mem.writeInt(u32, bytes[8..12], 13, .big);
        @memcpy(bytes[12..16], "IHDR");
        std.mem.writeInt(u32, bytes[16..20], width, .big);
        std.mem.writeInt(u32, bytes[20..24], height, .big);
        @memcpy(bytes[24..33], "\x08\x02\x00\x00\x00\x00\x00\x00\x00");
        const final = bytes;
        break :png &final;
    };
}

/// The Cover Art Archive holding a release's images and its release group's,
/// answered by URL: each full image by its ID, every thumbnail alike, and
/// image 103's full image no longer held.
const FakeCandidateArchive = struct {
    http: network.testing.ScriptedTransport = .{},
    group_status: u16 = 200,
    /// Statuses image 102's thumbnail is answered with, in order, before it.
    thumbnail_statuses: []const u16 = &.{},
    thumbnail_requests: usize = 0,

    fn attach(self: *FakeCandidateArchive, hooks: *MatchingHooks) void {
        self.http.keep_history = true;
        self.http.responder = .{ .context = self, .respond_fn = respond };
        hooks.cover_art_transport = self.http.transport();
    }

    fn deinit(self: *FakeCandidateArchive) void {
        self.http.deinit();
    }

    fn requestCount(self: *const FakeCandidateArchive) u32 {
        return self.http.requestCount();
    }

    fn respond(context: *anyopaque, exchange: network.testing.Exchange, _: ?network.testing.Reply) anyerror!network.testing.Reply {
        const self: *FakeCandidateArchive = @ptrCast(@alignCast(context));
        const url = exchange.request.url;
        if (std.mem.indexOf(u8, url, "/release-group/" ++ candidate_group_mbid ++ "/") != null) {
            if (self.group_status != 200) return .{ .respond = .{ .status = self.group_status, .body = "" } };
            return .{ .respond = .{ .body = candidate_group_index } };
        }
        const name = url[std.mem.lastIndexOfScalar(u8, url, '/').? + 1 ..];
        if (name.len == 0) return .{ .respond = .{ .body = candidate_release_index } };
        if (std.mem.eql(u8, name, "102-250")) {
            defer self.thumbnail_requests += 1;
            if (self.thumbnail_requests < self.thumbnail_statuses.len)
                return .{ .respond = .{ .status = self.thumbnail_statuses[self.thumbnail_requests], .body = "" } };
        }
        if (std.mem.endsWith(u8, name, "-250")) return .{ .respond = .{ .body = jpeg_cover } };
        const body: []const u8 = if (std.mem.eql(u8, name, "101"))
            candidatePng(1200, 1200)
        else if (std.mem.eql(u8, name, "201"))
            candidatePng(600, 600)
        else if (std.mem.eql(u8, name, "102"))
            candidatePng(300, 300)
        else
            return .{ .respond = .{ .status = 404, .body = "" } };
        return .{ .respond = .{ .body = body } };
    }
};

/// A Release named by `bryter_layter_mbid` whose one file names
/// `candidate_group_mbid`, with its candidates listed.
fn listCandidates(runtime: *OrcaRuntime, archive: *FakeCandidateArchive, fake: *FakeMusicBrainz, name: [:0]const u8) !struct { library: LibraryHandle, album: i64, listing: runtime_module.JobHandle } {
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    archive.attach(&runtime.matching_hooks);
    const library = try runtime.openLibrary(std.testing.io, name);
    const library_database = try libraryDatabase(runtime, library);
    const album = try addRelease(library_database, "Bryter Layter", bryter_layter_mbid);
    _ = try addAlbumTrack(library_database, album, "Northern Sky");
    try library_database.database.exec("UPDATE observed_file_tags SET musicbrainz_release_group_id = '" ++ candidate_group_mbid ++ "';");
    const listing = try runtime.startCoverArtCandidates(library, album);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(runtime, listing));
    return .{ .library = library, .album = album, .listing = listing };
}

test "a Release's cover art candidates are its release's images and its release group's other fronts, each measured from its full image and kept only as a thumbnail" {
    var fake: FakeMusicBrainz = .{};
    var archive: FakeCandidateArchive = .{};
    defer archive.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const listed = try listCandidates(&runtime, &archive, &fake, "file:orca-cover-candidates?mode=memory&cache=shared");

    const stats = try runtime.jobMatchStats(listed.listing);
    try std.testing.expectEqual(runtime_module.CoverArtOutcome.fetched, stats.cover_art);
    try std.testing.expectEqual(@as(u64, 4), stats.cover_art_candidates);
    try std.testing.expectEqual(@as(u64, 4), stats.cover_art_candidates_examined);
    try std.testing.expectEqual(@as(u64, 1), stats.cover_art_candidates_unmeasured);
    try std.testing.expectEqual(@as(u32, 2 + 4 * 2), archive.requestCount());
    try std.testing.expectEqual(@as(u32, 0), fake.requestCount());

    const candidates = try runtime.libraryCoverArtCandidates(listed.library, std.testing.allocator, listed.album);
    defer {
        for (candidates) |candidate| candidate.deinit(std.testing.allocator);
        std.testing.allocator.free(candidates);
    }
    const Expected = struct { caa_id: i64, kind: database.CoverArtCandidateKind, release: []const u8, size: ?u32 };
    const expected = [_]Expected{
        .{ .caa_id = 101, .kind = .front, .release = bryter_layter_mbid, .size = 1200 },
        .{ .caa_id = 201, .kind = .release_group, .release = candidate_group_release_mbid, .size = 600 },
        .{ .caa_id = 102, .kind = .back, .release = bryter_layter_mbid, .size = 300 },
        .{ .caa_id = 103, .kind = .booklet, .release = bryter_layter_mbid, .size = null },
    };
    try std.testing.expectEqual(expected.len, candidates.len);
    for (expected, candidates) |want, candidate| {
        try std.testing.expectEqual(want.caa_id, candidate.caa_id);
        try std.testing.expectEqual(want.kind, candidate.kind);
        try std.testing.expectEqualStrings(want.release, &candidate.musicbrainz_release_id);
        try std.testing.expectEqual(want.size, candidate.width);
        try std.testing.expectEqual(want.size, candidate.height);
        try std.testing.expectEqualStrings(if (want.size == null) "" else "image/png", candidate.mime orelse "");
        try std.testing.expectEqualStrings(jpeg_cover, candidate.thumbnail.?);
    }
    try std.testing.expect((try runtime.libraryStoredReleaseArtwork(listed.library, listed.album, .front)) == null);
}

test "a release group index that will not come keeps the release's own candidates and says the group's are missing" {
    var fake: FakeMusicBrainz = .{};
    var archive: FakeCandidateArchive = .{ .group_status = 503 };
    defer archive.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const listed = try listCandidates(&runtime, &archive, &fake, "file:orca-cover-candidates-partial?mode=memory&cache=shared");

    try std.testing.expectEqual(runtime_module.CoverArtOutcome.partial, (try runtime.jobMatchStats(listed.listing)).cover_art);
    const candidates = try runtime.libraryCoverArtCandidates(listed.library, std.testing.allocator, listed.album);
    defer {
        for (candidates) |candidate| candidate.deinit(std.testing.allocator);
        std.testing.allocator.free(candidates);
    }
    const expected = [_]i64{ 101, 102, 103 };
    try std.testing.expectEqual(expected.len, candidates.len);
    for (expected, candidates) |caa_id, candidate| {
        try std.testing.expectEqual(caa_id, candidate.caa_id);
        try std.testing.expectEqualStrings(bryter_layter_mbid, &candidate.musicbrainz_release_id);
    }
}

fn expectCandidates(runtime: *OrcaRuntime, library: LibraryHandle, album: i64, expected: []const struct { caa_id: i64, thumbnail: bool }) !void {
    const candidates = try runtime.libraryCoverArtCandidates(library, std.testing.allocator, album);
    defer {
        for (candidates) |candidate| candidate.deinit(std.testing.allocator);
        std.testing.allocator.free(candidates);
    }
    try std.testing.expectEqual(expected.len, candidates.len);
    for (expected, candidates) |want, candidate| {
        try std.testing.expectEqual(want.caa_id, candidate.caa_id);
        try std.testing.expectEqual(want.thumbnail, candidate.thumbnail != null);
    }
}

test "a candidate whose thumbnail the archive could not serve is left unrecorded and measured by the next listing, and one it does not have is kept without" {
    var fake: FakeMusicBrainz = .{};
    var archive: FakeCandidateArchive = .{ .thumbnail_statuses = &.{ 503, 503, 503 } };
    defer archive.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const listed = try listCandidates(&runtime, &archive, &fake, "file:orca-cover-candidates-outage?mode=memory&cache=shared");

    const stats = try runtime.jobMatchStats(listed.listing);
    try std.testing.expectEqual(runtime_module.CoverArtOutcome.partial, stats.cover_art);
    try std.testing.expectEqual(@as(u64, 2), stats.cover_art_candidates_examined);
    try std.testing.expectEqual(@as(usize, 3), archive.thumbnail_requests);
    try expectCandidates(&runtime, listed.library, listed.album, &.{ .{ .caa_id = 101, .thumbnail = true }, .{ .caa_id = 201, .thumbnail = true } });

    archive.thumbnail_statuses = &.{503};
    archive.thumbnail_requests = 0;
    runtime.reapFinishedJobs();
    const again = try runtime.startCoverArtCandidates(listed.library, listed.album);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, again));
    try std.testing.expectEqual(runtime_module.CoverArtOutcome.fetched, (try runtime.jobMatchStats(again)).cover_art);
    try std.testing.expectEqual(@as(usize, 2), archive.thumbnail_requests);
    try expectCandidates(&runtime, listed.library, listed.album, &.{
        .{ .caa_id = 101, .thumbnail = true },
        .{ .caa_id = 201, .thumbnail = true },
        .{ .caa_id = 102, .thumbnail = true },
        .{ .caa_id = 103, .thumbnail = true },
    });

    archive.thumbnail_statuses = &.{404};
    archive.thumbnail_requests = 0;
    runtime.reapFinishedJobs();
    const missing = try runtime.startCoverArtCandidates(listed.library, listed.album);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, missing));
    try std.testing.expectEqual(runtime_module.CoverArtOutcome.fetched, (try runtime.jobMatchStats(missing)).cover_art);
    try std.testing.expectEqual(@as(usize, 1), archive.thumbnail_requests);
    try expectCandidates(&runtime, listed.library, listed.album, &.{
        .{ .caa_id = 101, .thumbnail = true },
        .{ .caa_id = 201, .thumbnail = true },
        .{ .caa_id = 102, .thumbnail = false },
        .{ .caa_id = 103, .thumbnail = true },
    });
}

test "a candidate used as a Release's front is fetched again in full and outranks every other cover, and one the archive lost stores nothing" {
    var fake: FakeMusicBrainz = .{};
    var archive: FakeCandidateArchive = .{};
    defer archive.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const listed = try listCandidates(&runtime, &archive, &fake, "file:orca-cover-candidate-use?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, listed.library);
    const listed_requests = archive.requestCount();

    try std.testing.expectError(error.UnknownCoverArtCandidate, runtime.libraryUseCoverArtCandidate(listed.library, listed.album, 999, .front));

    runtime.reapFinishedJobs();
    const lost = try runtime.libraryUseCoverArtCandidate(listed.library, listed.album, 103, .booklet);
    try std.testing.expectEqual(job.State.failed, try runtime_tests.awaitJob(&runtime, lost));
    try std.testing.expectEqual(runtime_module.CoverArtOutcome.not_found, (try runtime.jobMatchStats(lost)).cover_art);
    try std.testing.expect((try runtime.libraryStoredReleaseArtwork(listed.library, listed.album, .booklet)) == null);

    runtime.reapFinishedJobs();
    const used = try runtime.libraryUseCoverArtCandidate(listed.library, listed.album, 102, .front);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, used));
    try std.testing.expectEqual(runtime_module.CoverArtOutcome.fetched, (try runtime.jobMatchStats(used)).cover_art);
    try std.testing.expectEqualStrings(
        "https://coverartarchive.org/release/" ++ bryter_layter_mbid ++ "/102",
        archive.http.history.items[archive.http.history.items.len - 1].url,
    );
    const stored = (try runtime.libraryStoredReleaseArtwork(listed.library, listed.album, .front)).?;
    defer stored.deinit();
    try std.testing.expectEqualStrings(candidatePng(300, 300), stored.bytes);
    const shown = (try runtime.libraryReleaseArtwork(listed.library, std.testing.io, listed.album)).?;
    defer shown.deinit();
    try std.testing.expectEqualStrings(candidatePng(300, 300), shown.bytes);

    var issues = try library_database.health_issues.page(std.testing.allocator, 16, 0);
    defer issues.deinit();
    try std.testing.expectEqual(@as(usize, 1), issues.items.len);
    try std.testing.expectEqual(
        database.ArtworkFinding{ .problem = .undersized, .width = 300, .height = 300 },
        runtime.libraryArtworkProblem(issues.items[0]).?,
    );

    runtime.reapFinishedJobs();
    const fetch = try runtime.startReleaseCoverArtFetch(listed.library, listed.album);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, fetch));
    try std.testing.expectEqual(runtime_module.CoverArtOutcome.chosen, (try runtime.jobMatchStats(fetch)).cover_art);
    try std.testing.expectEqual(listed_requests + 2, archive.requestCount());

    try std.testing.expect(try runtime.libraryClearReleaseArtwork(listed.library, listed.album, .front));
    try std.testing.expect((try runtime.libraryStoredReleaseArtwork(listed.library, listed.album, .front)) == null);
    var cleared = try library_database.health_issues.page(std.testing.allocator, 16, 0);
    defer cleared.deinit();
    try std.testing.expectEqual(@as(usize, 1), cleared.items.len);
    try std.testing.expectEqual(
        database.ArtworkFinding{ .problem = .missing_front },
        runtime.libraryArtworkProblem(cleared.items[0]).?,
    );
}

test "a cover a person sets is kept under its own kind, settles the front's artwork problem, and must be the image its type names" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-cover-set?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const album = try addRelease(library_database, "Bryter Layter", bryter_layter_mbid);
    _ = try addAlbumTrack(library_database, album, "Northern Sky");

    try std.testing.expectError(
        error.ArtworkTypeMismatch,
        runtime.librarySetReleaseArtwork(library, album, .front, candidatePng(800, 800), "image/jpeg"),
    );
    try std.testing.expectError(
        error.UnrecognizedArtworkImage,
        runtime.librarySetReleaseArtwork(library, album, .front, "not an image", "image/png"),
    );
    try std.testing.expect((try runtime.libraryStoredReleaseArtwork(library, album, .front)) == null);

    try runtime.librarySetReleaseArtwork(library, album, .back, candidatePng(300, 300), "image/png");
    try runtime.librarySetReleaseArtwork(library, album, .front, candidatePng(800, 800), "image/png");
    const back = (try runtime.libraryStoredReleaseArtwork(library, album, .back)).?;
    defer back.deinit();
    try std.testing.expectEqualStrings(candidatePng(300, 300), back.bytes);
    try std.testing.expectEqual(metadata.ArtworkKind.back_cover, back.kind);
    const front = (try runtime.libraryStoredReleaseArtwork(library, album, .front)).?;
    defer front.deinit();
    try std.testing.expectEqualStrings(candidatePng(800, 800), front.bytes);
    try std.testing.expectEqual(metadata.ArtworkKind.front_cover, front.kind);
    var settled = try library_database.health_issues.page(std.testing.allocator, 16, 0);
    defer settled.deinit();
    try std.testing.expectEqual(@as(usize, 0), settled.items.len);

    try library_database.release_artwork.put(album, bryter_layter_mbid, .{ .bytes = jpeg_cover, .mime_type = "image/jpeg" }, 0);
    const kept = (try runtime.libraryStoredReleaseArtwork(library, album, .front)).?;
    defer kept.deinit();
    try std.testing.expectEqualStrings(candidatePng(800, 800), kept.bytes);

    try std.testing.expect(try runtime.libraryClearReleaseArtwork(library, album, .back));
    try std.testing.expect(!try runtime.libraryClearReleaseArtwork(library, album, .booklet));
    try std.testing.expect((try runtime.libraryStoredReleaseArtwork(library, album, .back)) == null);
    const remaining = (try runtime.libraryStoredReleaseArtwork(library, album, .front)).?;
    defer remaining.deinit();
}

test "a Release's cover release ID is the one most of its accepted matches name" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-cover-vote?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const album = try addRelease(library_database, "Bryter Layter", null);
    const named = [_][]const u8{ "bbbbbbbb-0000-4000-8000-000000000000", bryter_layter_mbid, bryter_layter_mbid };
    for (named, 0..) |release_mbid, index| {
        var title_buffer: [16]u8 = undefined;
        const track_id = try addAlbumTrack(library_database, album, try std.fmt.bufPrint(&title_buffer, "Song {d}", .{index}));
        const file_ids = try library_database.tracks.fileIds(std.testing.allocator, track_id);
        defer std.testing.allocator.free(file_ids);
        const payload = try (database.ProposalPayload{ .release_mbid = release_mbid }).encode(std.testing.allocator);
        defer std.testing.allocator.free(payload);
        _ = try library_database.identification_proposals.put(.{
            .file_id = file_ids[0],
            .provider = "musicbrainz",
            .provider_id = northern_sky_mbid,
            .confidence = 0.95,
            .payload = payload,
        });
    }
    try std.testing.expect(try library_database.release_artwork.coverReleaseMbid(std.testing.allocator, album) == null);
    try std.testing.expectEqual(@as(u64, 3), (try runtime.libraryAcceptConfidentMatches(library, 0.9)).accepted);
    try std.testing.expectEqualStrings(bryter_layter_mbid, &(try library_database.release_artwork.coverReleaseMbid(std.testing.allocator, album)).?);
}

pub fn id3v23Frame(bytes: *std.ArrayList(u8), identifier: *const [4]u8, payload: []const u8) !void {
    try bytes.appendSlice(std.testing.allocator, identifier);
    var size: [4]u8 = undefined;
    std.mem.writeInt(u32, &size, @intCast(payload.len), .big);
    try bytes.appendSlice(std.testing.allocator, &size);
    try bytes.appendSlice(std.testing.allocator, &.{ 0, 0 });
    try bytes.appendSlice(std.testing.allocator, payload);
}

/// The reference MP3's audio under an ID3v2.3 tag with a title, an artist
/// and a MusicBrainz TXXX no field is written to.
fn writeId3v23Mp3(dir: std.Io.Dir, name: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/audio/tagged-reference.mp3", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(source);
    const tag_size = (@as(usize, source[6]) << 21) | (@as(usize, source[7]) << 14) | (@as(usize, source[8]) << 7) | source[9];
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(std.testing.allocator);
    try id3v23Frame(&frames, "TIT2", "\x00Northern Sky");
    try id3v23Frame(&frames, "TPE1", "\x00Nick Drake");
    try id3v23Frame(&frames, "TXXX", "\x00MusicBrainz Album Comment\x00kept as it was");
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try bytes.appendSlice(std.testing.allocator, &.{ 'I', 'D', '3', 3, 0, 0 });
    const length = frames.items.len;
    try bytes.appendSlice(std.testing.allocator, &.{
        @intCast((length >> 21) & 0x7f), @intCast((length >> 14) & 0x7f),
        @intCast((length >> 7) & 0x7f),  @intCast(length & 0x7f),
    });
    try bytes.appendSlice(std.testing.allocator, frames.items);
    try bytes.appendSlice(std.testing.allocator, source[10 + tag_size ..]);
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes.items });
}

test "after an accept, a tag-write preview of a 2.3 MP3 and a FLAC adds only the fields each file lacks, and the write keeps a foreign MusicBrainz TXXX" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try tagWriteDatabasePath(&data);
    defer std.testing.allocator.free(database_path);
    try writeId3v23Mp3(temporary.dir, "a.mp3");
    try runtime_tests.copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "b.flac");
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, database_path);
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(root);
    const binding = try runtime.libraryAddRoot(library, std.testing.io, root);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, try runtime.startLibraryScan(library, .{ .root_id = binding.root_id })));
    const library_database = try libraryDatabase(&runtime, library);
    const mp3 = try database.columns.scalar(library_database.database, "SELECT file_id FROM locations WHERE uri LIKE '%/a.mp3';");
    const flac = try database.columns.scalar(library_database.database, "SELECT file_id FROM locations WHERE uri LIKE '%/b.flac';");
    _ = try runtime.libraryAcceptMatch(library, try putPayload(library_database, mp3, northern_sky_mbid, bryterLayterPayload("Northern Sky", northern_sky_track_mbid, 3)));
    _ = try runtime.libraryAcceptMatch(library, try putPayload(library_database, flac, pink_moon_mbid, bryterLayterPayload("Pink Moon", pink_moon_track_mbid, 4)));
    const ids = try runtime_tests.allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);

    const preview = try runtime.planTagWrite(library, std.testing.io, ids);
    defer preview.deinit();

    try std.testing.expectEqual(@as(usize, 2), preview.files.len);
    for (preview.files) |file| {
        var adds_release_id = false;
        for (file.changes) |change| {
            try std.testing.expect(change.before == null);
            try std.testing.expectEqual(.provider, change.provenance);
            if (change.field == .musicbrainz_release_id) adds_release_id = true;
        }
        try std.testing.expect(adds_release_id);
    }
    for (preview.conflicts) |conflict| {
        try std.testing.expectEqual(flac, conflict.file_id);
        try std.testing.expect(conflict.file_value.len != 0);
    }
    try std.testing.expect(preview.conflicts.len != 0);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, try runtime.startTagWrite(library, preview.plan_id, preview.digest)));

    const written = try temporary.dir.readFileAlloc(std.testing.io, "a.mp3", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(written);
    try std.testing.expectEqual(@as(u8, 3), written[3]);
    try std.testing.expect(std.mem.indexOf(u8, written, "\x00MusicBrainz Album Comment\x00kept as it was") != null);
    for ([_]i64{ mp3, flac }) |file_id| {
        const stored = (try library_database.observed_tags.get(std.testing.allocator, file_id)).?;
        defer stored.deinit();
        try std.testing.expectEqualStrings(bryter_layter_mbid, stored.values.musicbrainz_release_id.?);
        try std.testing.expectEqualStrings(bryter_layter_group_mbid, stored.values.musicbrainz_release_group_id.?);
    }
    const mp3_tags = (try library_database.observed_tags.get(std.testing.allocator, mp3)).?;
    defer mp3_tags.deinit();
    try std.testing.expectEqualStrings("Bryter Layter", mp3_tags.values.album.?);
    const flac_tags = (try library_database.observed_tags.get(std.testing.allocator, flac)).?;
    defer flac_tags.deinit();
    try std.testing.expectEqualStrings("Fixtures", flac_tags.values.album.?);
}

fn heardRecording(comptime mbid: []const u8, comptime title: []const u8) []const u8 {
    return "{\"id\":\"" ++ mbid ++ "\",\"title\":\"" ++ title ++
        "\",\"duration\":15,\"artists\":[{\"id\":\"a1\",\"name\":\"Nick Drake\"}]}";
}

pub fn heardResult(comptime score: []const u8, comptime recordings: []const u8) []const u8 {
    return "{\"id\":\"t" ++ score ++ "\",\"score\":" ++ score ++ ",\"recordings\":[" ++ recordings ++ "]}";
}

pub fn heardBy(comptime index: []const u8, comptime results: []const u8) []const u8 {
    return "{\"index\":" ++ index ++ ",\"results\":[" ++ results ++ "]}";
}

pub fn acoustIdAnswer(comptime entries: []const u8) []const u8 {
    return "{\"status\":\"ok\",\"fingerprints\":[" ++ entries ++ "]}";
}

pub const northern_sky_heard = heardRecording(northern_sky_mbid, "Northern Sky");
pub const pink_moon_heard = heardRecording(pink_moon_mbid, "Pink Moon");
const hazey_jane_heard = heardRecording(feedback_mbid, "Hazey Jane I");

/// A runtime whose MusicBrainz and AcoustID are fakes, with an AcoustID key,
/// and a Library whose Tracks play files in a temporary directory.
const VerifyRig = struct {
    musicbrainz: FakeMusicBrainz = .{},
    acoustid: FakeAcoustId = .{},
    temporary: std.testing.TmpDir,
    runtime: OrcaRuntime,
    library: LibraryHandle = undefined,
    library_database: *database.LibraryDatabase = undefined,

    const Verified = struct { total_units: ?u64, stats: runtime_module.MatchStats };

    fn init(self: *VerifyRig, uri: [:0]const u8) !void {
        self.* = .{ .temporary = std.testing.tmpDir(.{}), .runtime = OrcaRuntime.init(std.testing.allocator) };
        errdefer self.deinit();
        try self.runtime.setClientIdentity(network.testing.test_identity);
        self.runtime.matching_hooks = self.musicbrainz.hooks();
        self.runtime.matching_hooks.acoustid_transport = self.acoustid.transport();
        try self.runtime.setAcoustIdClientKey("test-client");
        self.library = try self.runtime.openLibrary(std.testing.io, uri);
        self.library_database = try libraryDatabase(&self.runtime, self.library);
    }

    fn deinit(self: *VerifyRig) void {
        self.runtime.deinit();
        self.temporary.cleanup();
    }

    /// A Track playing a fifteen-second tone whose tag names `recording_mbid`.
    fn addTone(self: *VerifyRig, name: []const u8, frequency: f32, title: []const u8, recording_mbid: ?[]const u8, release_id: ?i64) !i64 {
        try writeToneWave(self.temporary.dir, name, frequency);
        return self.addFile(name, title, recording_mbid, release_id);
    }

    fn addFile(self: *VerifyRig, name: []const u8, title: []const u8, recording_mbid: ?[]const u8, release_id: ?i64) !i64 {
        const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ self.temporary.sub_path, name });
        defer std.testing.allocator.free(path);
        const binding = try self.library_database.resolveOrCreateFile(std.testing.io, path, .{ .stable_key = "test:verify" });
        try self.library_database.observed_tags.upsert(.{ .file_id = binding.file_id, .values = .{
            .title = title,
            .artist = "Nick Drake",
            .album = "Bryter Layter",
            .musicbrainz_recording_id = recording_mbid,
        } });
        try self.library_database.tracks.upsertTracks(&.{.{
            .release_id = release_id,
            .title = title,
            .artist = "Nick Drake",
            .album = "Bryter Layter",
            .duration_ms = 15_000,
            .preferred_file_id = binding.file_id,
        }});
        return trackOfFile(self.library_database, binding.file_id);
    }

    fn verify(self: *VerifyRig, request: runtime_module.MatchRequest) !Verified {
        self.runtime.reapFinishedJobs();
        var verify_request = request;
        verify_request.mode = .verify;
        const job_handle = try self.runtime.startLibraryMatching(self.library, verify_request);
        const total_units = (try self.runtime.jobSnapshotSynced(job_handle)).total_units;
        try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&self.runtime, job_handle));
        return .{ .total_units = total_units, .stats = try self.runtime.jobMatchStats(job_handle) };
    }

    fn outcomeOf(self: *VerifyRig, track_id: i64) !?database.VerificationOutcome {
        const stored = (try self.runtime.libraryTrackVerification(self.library, std.testing.allocator, track_id)) orelse return null;
        defer stored.deinit();
        return stored.outcome;
    }

    fn fileOf(self: *VerifyRig, track_id: i64) !i64 {
        const files = try self.library_database.tracks.fileIds(std.testing.allocator, track_id);
        defer std.testing.allocator.free(files);
        return files[0];
    }

    fn mismatchCount(self: *VerifyRig, track_id: i64) !i64 {
        return self.fileMismatchCount(try self.fileOf(track_id));
    }

    fn fileMismatchCount(self: *VerifyRig, file_id: i64) !i64 {
        var count = try self.library_database.database.prepare(
            "SELECT count(*) FROM library_health_issues WHERE file_id=?1 AND kind=?2;",
        );
        defer count.deinit();
        try count.bindInt64(1, file_id);
        try count.bindInt64(2, @backingInt(database.HealthIssueKind.recording_mismatch));
        if (try count.step() != .row) return error.TestExpectedRow;
        return count.columnInt64(0);
    }
};

fn writeDamagedFlac(dir: std.Io.Dir, name: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/audio/tagged-reference.flac", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(bytes);
    const packed_bits = std.mem.readInt(u64, bytes[18..26], .big);
    std.mem.writeInt(u64, bytes[18..26], packed_bits + 1_000_000, .big);
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
}

test "verification stores what AcoustID hears of each file's recording ID and proposes a correction only for a file another recording outscores" {
    var rig: VerifyRig = undefined;
    try rig.init("file:orca-verify-outcomes?mode=memory&cache=shared");
    defer rig.deinit();
    const agrees = try rig.addTone("agrees.wav", 300, "Northern Sky", northern_sky_mbid, null);
    const disagrees = try rig.addTone("disagrees.wav", 420, "Northern Sky", northern_sky_mbid, null);
    const weak = try rig.addTone("weak.wav", 540, "Northern Sky", northern_sky_mbid, null);
    const empty = try rig.addTone("empty.wav", 660, "Northern Sky", northern_sky_mbid, null);
    try writeDamagedFlac(rig.temporary.dir, "damaged.flac");
    const damaged = try rig.addFile("damaged.flac", "Northern Sky", northern_sky_mbid, null);
    const refused = try rig.addTone("refused.wav", 780, "Northern Sky", northern_sky_mbid, null);
    rig.acoustid.lookup_body = acoustIdAnswer(
        heardBy("0", heardResult("0.97", northern_sky_heard ++ "," ++ pink_moon_heard)) ++ "," ++
            heardBy("1", heardResult("0.4", northern_sky_heard) ++ "," ++ heardResult("0.95", pink_moon_heard)) ++ "," ++
            heardBy("2", heardResult("0.8", hazey_jane_heard)) ++ "," ++
            heardBy("3", ""),
    );

    const verified = try rig.verify(.{});

    try std.testing.expectEqual(@as(?u64, 6), verified.total_units);
    const stats = verified.stats;
    try std.testing.expectEqual(@as(u64, 6), stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 5), stats.verified);
    try std.testing.expectEqual(@as(u64, 1), stats.agreed);
    try std.testing.expectEqual(@as(u64, 1), stats.disagreed);
    try std.testing.expectEqual(@as(u64, 2), stats.unconfirmed);
    try std.testing.expectEqual(@as(u64, 0), stats.skipped);
    try std.testing.expectEqual(@as(u64, 0), stats.correction_groups);
    try std.testing.expectEqual(@as(u64, 1), stats.proposals_stored);
    try std.testing.expectEqual(@as(u64, 5), stats.fingerprinted);
    try std.testing.expectEqual(@as(u64, 1), stats.fingerprint_failures);
    try std.testing.expectEqual(@as(u64, 1), stats.acoustid_requests);
    try std.testing.expectEqual(@as(u64, 1), stats.acoustid_refused);
    try std.testing.expectEqual(@as(u64, 0), stats.requests);
    try std.testing.expectEqual(@as(u32, 0), rig.musicbrainz.requestCount());

    try std.testing.expectEqual(database.VerificationOutcome.agrees, (try rig.outcomeOf(agrees)).?);
    try std.testing.expectEqual(database.VerificationOutcome.disagrees, (try rig.outcomeOf(disagrees)).?);
    try std.testing.expectEqual(database.VerificationOutcome.unconfirmed, (try rig.outcomeOf(weak)).?);
    try std.testing.expectEqual(database.VerificationOutcome.unconfirmed, (try rig.outcomeOf(empty)).?);
    try std.testing.expectEqual(database.VerificationOutcome.no_fingerprint, (try rig.outcomeOf(damaged)).?);
    try std.testing.expectEqual(@as(?database.VerificationOutcome, null), try rig.outcomeOf(refused));
    try std.testing.expectEqual(@as(i64, 5), try database.columns.scalar(rig.library_database.database, "SELECT count(*) FROM recording_verifications;"));

    const disputed = (try rig.runtime.libraryTrackVerification(rig.library, std.testing.allocator, disagrees)).?;
    defer disputed.deinit();
    try std.testing.expectEqualStrings(northern_sky_mbid, disputed.recording_mbid);
    try std.testing.expectEqual(@as(usize, 2), disputed.heard.len);
    try std.testing.expectEqualStrings(pink_moon_mbid, disputed.heard[0].mbid);
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), disputed.heard[0].score, 0.001);
    try std.testing.expect(!disputed.stale and !disputed.dismissed);

    for ([_]i64{ agrees, weak, empty, damaged, refused }) |track_id|
        try std.testing.expectEqual(@as(usize, 0), try pendingCount(&rig.runtime, rig.library, track_id));
    const proposals = try rig.runtime.libraryMatchProposals(rig.library, disagrees, 10);
    defer proposals.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposals.items.len);
    try std.testing.expectEqualStrings(pink_moon_mbid, proposals.items[0].recording_mbid);
    try std.testing.expectEqualStrings("acoustid", proposals.items[0].provider);
    try std.testing.expectEqualStrings(northern_sky_mbid, proposals.items[0].corrects.?);
    try std.testing.expectEqual(@as(u64, 1), try rig.runtime.libraryMatchReviewCount(rig.library));

    for ([_]i64{ agrees, weak, empty, damaged, refused }) |track_id|
        try std.testing.expectEqual(@as(i64, 0), try rig.mismatchCount(track_id));
    try std.testing.expectEqual(@as(u64, 1), try rig.runtime.libraryHealthIssueCount(rig.library));
    const issues = try rig.runtime.libraryHealthIssuePage(rig.library, 10, 0);
    defer issues.deinit();
    const mismatch = issues.items[0];
    try std.testing.expectEqual(database.HealthIssueKind.recording_mismatch, mismatch.kind);
    try std.testing.expectEqual(database.HealthSeverity.warning, mismatch.severity);
    try std.testing.expectEqual(database.HealthAction.review_correction, mismatch.action);
    try std.testing.expectEqual(try rig.fileOf(disagrees), mismatch.file_id);
    try std.testing.expectEqual(@as(?i64, disagrees), mismatch.track_id);
    try std.testing.expectEqualStrings("AcoustID heard \"Pink Moon\" by Nick Drake (" ++ pink_moon_mbid ++ ") at 95%", mismatch.details);

    try rig.runtime.libraryDismissMatch(rig.library, proposals.items[0].id);
    const dismissed = (try rig.runtime.libraryTrackVerification(rig.library, std.testing.allocator, disagrees)).?;
    defer dismissed.deinit();
    try std.testing.expect(dismissed.dismissed);
    try std.testing.expectEqual(@as(i64, 0), try rig.mismatchCount(disagrees));
    try std.testing.expectEqual(@as(u64, 0), try rig.runtime.libraryHealthIssueCount(rig.library));

    const again = try rig.verify(.{ .track_id = disagrees });
    try std.testing.expectEqual(@as(u64, 1), again.stats.disagreed);
    try std.testing.expectEqual(@as(u64, 0), try rig.runtime.libraryMatchReviewCount(rig.library));
    try std.testing.expectEqual(@as(i64, 0), try rig.mismatchCount(disagrees));
}

test "a verified file is looked up again only when its bytes or its recording ID change, and one that disagrees only beside such a file or alone" {
    var rig: VerifyRig = undefined;
    try rig.init("file:orca-verify-stale?mode=memory&cache=shared");
    defer rig.deinit();
    const album = try addRelease(rig.library_database, "Bryter Layter", null);
    const agreeing = try rig.addTone("agreeing.wav", 300, "Northern Sky", northern_sky_mbid, album);
    const disputed = try rig.addTone("disputed.wav", 420, "Pink Moon", pink_moon_mbid, album);
    rig.acoustid.lookup_body = acoustIdAnswer(
        heardBy("0", heardResult("0.97", northern_sky_heard) ++ "," ++ heardResult("0.6", hazey_jane_heard)) ++ "," ++
            heardBy("1", heardResult("0.3", pink_moon_heard) ++ "," ++ heardResult("0.95", hazey_jane_heard)),
    );

    const first = try rig.verify(.{ .release_id = album });
    try std.testing.expectEqual(@as(?u64, 2), first.total_units);
    try std.testing.expectEqual(@as(u64, 1), first.stats.agreed);
    try std.testing.expectEqual(@as(u64, 1), first.stats.disagreed);
    try std.testing.expectEqual(@as(u32, 1), rig.acoustid.lookups.load(.acquire));

    for ([_]runtime_module.MatchRequest{ .{}, .{ .release_id = album } }) |request| {
        const again = try rig.verify(request);
        try std.testing.expectEqual(@as(?u64, 0), again.total_units);
        try std.testing.expectEqual(@as(u64, 0), again.stats.tracks_examined);
        try std.testing.expectEqual(@as(u64, 0), again.stats.fingerprinted);
        try std.testing.expectEqual(@as(u64, 0), again.stats.acoustid_requests + again.stats.acoustid_cache_hits);
    }
    try std.testing.expectEqual(@as(u32, 1), rig.acoustid.lookups.load(.acquire));
    const alone = try rig.verify(.{ .track_id = disputed });
    try std.testing.expectEqual(@as(?u64, 1), alone.total_units);
    try std.testing.expectEqual(@as(u64, 1), alone.stats.disagreed);
    try std.testing.expectEqual(@as(u64, 1), alone.stats.acoustid_cache_hits);
    try std.testing.expectEqual(@as(u32, 1), rig.acoustid.lookups.load(.acquire));

    const agreeing_file = try rig.fileOf(agreeing);
    const disputed_file = try rig.fileOf(disputed);
    const edited = try rig.runtime.libraryEditTracks(rig.library, &.{agreeing}, &.{.{ .field = .musicbrainz_recording_id, .value = feedback_mbid }});
    edited.deinit();
    const reidentified = try trackOfFile(rig.library_database, agreeing_file);
    const changed = (try rig.runtime.libraryTrackVerification(rig.library, std.testing.allocator, reidentified)).?;
    defer changed.deinit();
    try std.testing.expect(changed.stale);
    try std.testing.expectEqual(@as(i64, 1), try rig.fileMismatchCount(disputed_file));
    var raised = try rig.library_database.database.prepare(
        "INSERT INTO library_health_issues(file_id, kind, severity, details) VALUES (?1, ?2, 1, 'stale');",
    );
    defer raised.deinit();
    try raised.bindInt64(1, agreeing_file);
    try raised.bindInt64(2, @backingInt(database.HealthIssueKind.recording_mismatch));
    try std.testing.expectEqual(database.sqlite.Step.done, try raised.step());
    const after_edit = try rig.verify(.{});
    try std.testing.expectEqual(@as(i64, 0), try rig.mismatchCount(reidentified));
    try std.testing.expectEqual(@as(?u64, 2), after_edit.total_units);
    try std.testing.expectEqual(@as(u64, 2), after_edit.stats.verified);
    try std.testing.expectEqual(@as(u64, 1), after_edit.stats.agreed);
    try std.testing.expectEqual(@as(u64, 1), after_edit.stats.fingerprinted);
    try std.testing.expectEqual(database.VerificationOutcome.agrees, (try rig.outcomeOf(reidentified)).?);

    var rehash = try rig.library_database.database.prepare("UPDATE files SET quick_hash = x'00' WHERE id = ?1;");
    defer rehash.deinit();
    try rehash.bindInt64(1, agreeing_file);
    try std.testing.expectEqual(database.sqlite.Step.done, try rehash.step());
    const rehashed = (try rig.runtime.libraryTrackVerification(rig.library, std.testing.allocator, reidentified)).?;
    defer rehashed.deinit();
    try std.testing.expect(rehashed.stale);
    const after_change = try rig.verify(.{});
    try std.testing.expectEqual(@as(?u64, 2), after_change.total_units);
    try std.testing.expectEqual(@as(u64, 2), after_change.stats.fingerprinted);
    try std.testing.expectEqual(@as(u64, 2), after_change.stats.acoustid_cache_hits);
    try std.testing.expectEqual(@as(u32, 1), rig.acoustid.lookups.load(.acquire));
    try std.testing.expectEqual(database.VerificationOutcome.agrees, (try rig.outcomeOf(reidentified)).?);
    const fresh = (try rig.runtime.libraryTrackVerification(rig.library, std.testing.allocator, reidentified)).?;
    defer fresh.deinit();
    try std.testing.expect(!fresh.stale);
    try std.testing.expectEqual(database.VerificationOutcome.disagrees, (try rig.outcomeOf(try trackOfFile(rig.library_database, disputed_file))).?);
}

test "an album correction forms again with every file it disputes once one file of its Release is stale" {
    var rig: VerifyRig = undefined;
    try rig.init("file:orca-verify-reform?mode=memory&cache=shared");
    defer rig.deinit();
    const album = try addRelease(rig.library_database, "Bryter Layter", bryter_layter_mbid);
    const sounds_northern = try rig.addTone("northern.wav", 300, "Pink Moon", pink_moon_mbid, album);
    const sounds_pink = try rig.addTone("pink.wav", 420, "Northern Sky", northern_sky_mbid, album);
    rig.acoustid.lookup_body = acoustIdAnswer(
        heardBy("0", heardResult("0.97", northern_sky_heard)) ++ "," ++ heardBy("1", heardResult("0.96", pink_moon_heard)),
    );

    const first = try rig.verify(.{ .release_id = album });
    try std.testing.expectEqual(@as(u64, 2), first.stats.disagreed);
    try std.testing.expectEqual(@as(u64, 1), first.stats.correction_groups);
    const formed = try rig.runtime.libraryCorrectionGroups(rig.library, std.testing.allocator, 10, 0);
    defer formed.deinit();
    try std.testing.expectEqual(@as(usize, 1), formed.items.len);
    const unchanged = try rig.verify(.{ .release_id = album });
    try std.testing.expectEqual(@as(?u64, 0), unchanged.total_units);

    var rehash = try rig.library_database.database.prepare("UPDATE files SET quick_hash = x'00' WHERE id = ?1;");
    defer rehash.deinit();
    try rehash.bindInt64(1, try rig.fileOf(sounds_northern));
    try std.testing.expectEqual(database.sqlite.Step.done, try rehash.step());
    const reformed = try rig.verify(.{ .release_id = album });

    try std.testing.expectEqual(@as(?u64, 2), reformed.total_units);
    try std.testing.expectEqual(@as(u64, 2), reformed.stats.disagreed);
    try std.testing.expectEqual(@as(u64, 1), reformed.stats.correction_groups);
    try std.testing.expectEqual(@as(u64, 2), reformed.stats.acoustid_cache_hits);
    try std.testing.expectEqual(@as(u32, 1), rig.acoustid.lookups.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), rig.musicbrainz.requestCount());
    const groups = try rig.runtime.libraryCorrectionGroups(rig.library, std.testing.allocator, 10, 0);
    defer groups.deinit();
    try std.testing.expectEqual(@as(usize, 1), groups.items.len);
    try std.testing.expect(groups.items[0].group_id != formed.items[0].group_id);
    try std.testing.expectEqual(@as(usize, 2), groups.items[0].proposals.len);
    try std.testing.expectEqual(@as(i64, 1), try rig.mismatchCount(sounds_northern));
    try std.testing.expectEqual(@as(i64, 1), try rig.mismatchCount(sounds_pink));

    try rig.runtime.libraryDismissCorrectionGroup(rig.library, groups.items[0].group_id);

    try std.testing.expectEqual(@as(i64, 0), try rig.mismatchCount(sounds_northern));
    try std.testing.expectEqual(@as(i64, 0), try rig.mismatchCount(sounds_pink));
}

test "cancelling a verification while a unit's lookup is in flight commits nothing for that unit and keeps the unit before it" {
    var rig: VerifyRig = undefined;
    try rig.init("file:orca-verify-cancel?mode=memory&cache=shared");
    defer rig.deinit();
    const first_album = try addRelease(rig.library_database, "Five Leaves Left", null);
    const second_album = try addRelease(rig.library_database, "Bryter Layter", null);
    const committed = try rig.addTone("committed.wav", 300, "River Man", northern_sky_mbid, first_album);
    const interrupted = [_]i64{
        try rig.addTone("northern.wav", 420, "Northern Sky", northern_sky_mbid, second_album),
        try rig.addTone("pink.wav", 540, "Pink Moon", northern_sky_mbid, second_album),
    };
    rig.acoustid.lookup_body = acoustIdAnswer(heardBy("0", heardResult("0.95", pink_moon_heard)) ++ "," ++
        heardBy("1", heardResult("0.95", pink_moon_heard)));
    rig.acoustid.hang_lookups_from = 1;

    const job_handle = try rig.runtime.startLibraryMatching(rig.library, .{ .mode = .verify });
    try std.testing.expectEqual(@as(?u64, 3), (try rig.runtime.jobSnapshotSynced(job_handle)).total_units);
    var deadline: runtime_tests.TestDeadline = .init(5_000);
    while (rig.acoustid.lookups.load(.acquire) < 2) {
        if (!deadline.tick()) return error.LookupNeverSent;
    }
    try rig.runtime.cancelJob(job_handle);

    try std.testing.expectEqual(job.State.cancelled, try runtime_tests.awaitJob(&rig.runtime, job_handle));
    const stats = try rig.runtime.jobMatchStats(job_handle);
    try std.testing.expect(stats.cancelled);
    try std.testing.expectEqual(@as(u64, 1), stats.verified);
    try std.testing.expectEqual(@as(u64, 1), stats.tracks_examined);
    try std.testing.expectEqual(database.VerificationOutcome.disagrees, (try rig.outcomeOf(committed)).?);
    try std.testing.expectEqual(@as(usize, 1), try pendingCount(&rig.runtime, rig.library, committed));
    for (interrupted) |track_id| {
        try std.testing.expectEqual(@as(?database.VerificationOutcome, null), try rig.outcomeOf(track_id));
        try std.testing.expectEqual(@as(usize, 0), try pendingCount(&rig.runtime, rig.library, track_id));
    }
    try std.testing.expectEqual(@as(i64, 1), try database.columns.scalar(rig.library_database.database, "SELECT count(*) FROM recording_verifications;"));
    try std.testing.expectEqual(@as(i64, 1), try database.columns.scalar(rig.library_database.database, "SELECT count(*) FROM identification_proposals;"));
}

/// Ten seconds of the fingerprint reference audio under an ID3v2.3 title, so
/// two files of it differ in bytes and not in sound.
fn writeTitledMp3(dir: std.Io.Dir, name: []const u8, title: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/audio/fingerprint-reference.mp3", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(source);
    const tag_size = (@as(usize, source[6]) << 21) | (@as(usize, source[7]) << 14) | (@as(usize, source[8]) << 7) | source[9];
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(std.testing.allocator);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.append(std.testing.allocator, 0);
    try text.appendSlice(std.testing.allocator, title);
    try id3v23Frame(&frames, "TIT2", text.items);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try bytes.appendSlice(std.testing.allocator, &.{ 'I', 'D', '3', 3, 0, 0 });
    const length = frames.items.len;
    try bytes.appendSlice(std.testing.allocator, &.{
        @intCast((length >> 21) & 0x7f), @intCast((length >> 14) & 0x7f),
        @intCast((length >> 7) & 0x7f),  @intCast(length & 0x7f),
    });
    try bytes.appendSlice(std.testing.allocator, frames.items);
    try bytes.appendSlice(std.testing.allocator, source[10 + tag_size ..]);
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes.items });
}

fn tagAlbumFile(library_database: *database.LibraryDatabase, file_id: i64, title: []const u8, position: u32, recording_mbid: []const u8) !void {
    try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = title,
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .album_artist = "Nick Drake",
        .track_number = position,
        .disc_number = 1,
        .musicbrainz_recording_id = recording_mbid,
        .musicbrainz_release_id = bryter_layter_mbid,
    } });
}

test "a Release whose files carry each other's tags is proposed one album correction, taken only whole, which swaps its Tracks and is written as changes" {
    var rig: VerifyRig = undefined;
    try rig.init("file:orca-verify-swap?mode=memory&cache=shared");
    defer rig.deinit();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    try writeTitledMp3(rig.temporary.dir, "a.mp3", "First");
    try writeTitledMp3(rig.temporary.dir, "b.mp3", "Second");
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{rig.temporary.sub_path});
    defer std.testing.allocator.free(root);
    const binding = try rig.runtime.libraryAddRoot(rig.library, std.testing.io, root);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&rig.runtime, try rig.runtime.startLibraryScan(rig.library, .{ .root_id = binding.root_id })));
    const library_database = rig.library_database;
    const sounds_northern = try database.columns.scalar(library_database.database, "SELECT file_id FROM locations WHERE uri LIKE '%/a.mp3';");
    const sounds_pink = try database.columns.scalar(library_database.database, "SELECT file_id FROM locations WHERE uri LIKE '%/b.mp3';");
    try tagAlbumFile(library_database, sounds_northern, "Pink Moon", 4, pink_moon_mbid);
    try tagAlbumFile(library_database, sounds_pink, "Northern Sky", 3, northern_sky_mbid);
    try projectAll(library_database);
    const album = try releaseOfFile(library_database, sounds_northern);
    try std.testing.expectEqual(album, try releaseOfFile(library_database, sounds_pink));
    const northern_track = try trackOfFile(library_database, sounds_northern);
    const pink_track = try trackOfFile(library_database, sounds_pink);
    const northern_first = northern_track < pink_track;
    const heard_northern = comptime heardResult("0.97", northern_sky_heard);
    const heard_pink = comptime heardResult("0.96", pink_moon_heard);
    rig.acoustid.lookup_body = if (northern_first)
        acoustIdAnswer(heardBy("0", heard_northern) ++ "," ++ heardBy("1", heard_pink))
    else
        acoustIdAnswer(heardBy("0", heard_pink) ++ "," ++ heardBy("1", heard_northern));

    const verified = try rig.verify(.{ .release_id = album });

    try std.testing.expectEqual(@as(?u64, 2), verified.total_units);
    try std.testing.expectEqual(@as(u64, 2), verified.stats.disagreed);
    try std.testing.expectEqual(@as(u64, 1), verified.stats.correction_groups);
    try std.testing.expectEqual(@as(u64, 2), verified.stats.proposals_stored);
    try std.testing.expectEqual(@as(u32, 1), rig.musicbrainz.requestCount());
    try std.testing.expect(std.mem.indexOf(u8, rig.musicbrainz.transport.lastUrl(), "/ws/2/release/" ++ bryter_layter_mbid) != null);
    try std.testing.expectEqual(@as(u64, 0), try rig.runtime.libraryMatchReviewCount(rig.library));

    const groups = try rig.runtime.libraryCorrectionGroups(rig.library, std.testing.allocator, 10, 0);
    defer groups.deinit();
    try std.testing.expectEqual(@as(usize, 1), groups.items.len);
    const group = groups.items[0];
    try std.testing.expectEqualStrings("Bryter Layter", group.album);
    try std.testing.expectEqual(@as(?i64, album), group.release_id);
    try std.testing.expectEqual(@as(usize, 2), group.proposals.len);
    const moved = for (group.proposals) |member| {
        if (member.file_id == sounds_northern) break member;
    } else return error.TestExpectedMember;
    try std.testing.expectEqualStrings("Pink Moon", moved.title);
    try std.testing.expectEqual(@as(?i64, 4), moved.track_number);
    try std.testing.expectEqualStrings("Northern Sky", moved.proposed_title);
    try std.testing.expectEqual(@as(?u32, 3), moved.proposed_track_number);
    try std.testing.expectEqual(@as(?u32, 1), moved.proposed_disc_number);
    try std.testing.expectEqualStrings(northern_sky_mbid, moved.recording_mbid);
    try std.testing.expectEqualStrings(pink_moon_mbid, moved.corrects.?);
    try std.testing.expectError(error.ProposalInGroup, rig.runtime.libraryAcceptMatch(rig.library, moved.proposal_id));
    try std.testing.expectError(error.ProposalInGroup, rig.runtime.libraryDismissMatch(rig.library, moved.proposal_id));
    try std.testing.expectError(error.UnknownCorrectionGroup, rig.runtime.libraryAcceptCorrectionGroup(rig.library, group.group_id + 100));
    try std.testing.expectEqual(@as(i64, 1), try rig.fileMismatchCount(sounds_northern));
    try std.testing.expectEqual(@as(i64, 1), try rig.fileMismatchCount(sounds_pink));

    const acceptance = try rig.runtime.libraryAcceptCorrectionGroup(rig.library, group.group_id);

    try std.testing.expectEqual(@as(u64, 2), acceptance.accepted);
    try std.testing.expectEqual(@as(i64, 0), try rig.fileMismatchCount(sounds_northern));
    try std.testing.expectEqual(@as(i64, 0), try rig.fileMismatchCount(sounds_pink));
    try std.testing.expectEqual(northern_track, try trackOfFile(library_database, sounds_northern));
    try std.testing.expectEqual(pink_track, try trackOfFile(library_database, sounds_pink));
    for ([_]struct { file: i64, recording: []const u8, title: []const u8, position: []const u8, track_mbid: []const u8 }{
        .{ .file = sounds_northern, .recording = northern_sky_mbid, .title = "Northern Sky", .position = "3", .track_mbid = northern_sky_track_mbid },
        .{ .file = sounds_pink, .recording = pink_moon_mbid, .title = "Pink Moon", .position = "4", .track_mbid = pink_moon_track_mbid },
    }) |expected| {
        inline for (.{ .musicbrainz_recording_id, .title, .artist, .track_number, .disc_number, .musicbrainz_release_track_id }) |field| {
            const stored = (try library_database.orca_metadata.get(std.testing.allocator, expected.file, field)).?;
            defer stored.deinit(std.testing.allocator);
            try std.testing.expect(stored.locked);
            try std.testing.expectEqual(metadata.Provenance.provider, stored.provenance);
        }
        try expectOrcaValue(library_database, expected.file, .musicbrainz_recording_id, expected.recording);
        try expectOrcaValue(library_database, expected.file, .title, expected.title);
        try expectOrcaValue(library_database, expected.file, .track_number, expected.position);
        try expectOrcaValue(library_database, expected.file, .disc_number, "1");
        try expectOrcaValue(library_database, expected.file, .musicbrainz_release_track_id, expected.track_mbid);
        const details = (try rig.runtime.libraryTrackDetails(rig.library, try trackOfFile(library_database, expected.file))).?;
        defer details.deinit();
        try std.testing.expectEqualStrings(expected.title, details.title);
        try std.testing.expectEqual(try std.fmt.parseInt(i64, expected.position, 10), details.track_number.?);
        try std.testing.expectEqualStrings(expected.recording, details.musicbrainz_recording_id.?);
        try std.testing.expectEqual(RecordingIdSource.match, details.musicbrainz_recording_id_source.?);
    }
    var projection: library_pass.Projection = .{ .allocator = std.testing.allocator, .library = library_database };
    try std.testing.expectEqual(@as(u64, 0), (try projection.run(.all)).displaced_positions);
    const remaining = try rig.runtime.libraryCorrectionGroups(rig.library, std.testing.allocator, 10, 0);
    defer remaining.deinit();
    try std.testing.expectEqual(@as(usize, 0), remaining.items.len);
    try std.testing.expectError(error.StaleCorrectionGroup, rig.runtime.libraryAcceptCorrectionGroup(rig.library, group.group_id));
    try std.testing.expectError(error.StaleCorrectionGroup, rig.runtime.libraryDismissCorrectionGroup(rig.library, group.group_id));

    const ids = [_]i64{ try trackOfFile(library_database, sounds_northern), try trackOfFile(library_database, sounds_pink) };
    const preview = try rig.runtime.planTagWrite(rig.library, std.testing.io, &ids);
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 0), preview.conflicts.len);
    try std.testing.expectEqual(@as(usize, 2), preview.files.len);
    for (preview.files) |file| {
        const recording_change = for (file.changes) |change| {
            if (change.field == .musicbrainz_recording_id) break change;
        } else return error.TestExpectedChange;
        try std.testing.expectEqual(.provider, recording_change.provenance);
        try std.testing.expectEqualStrings(if (file.file_id == sounds_northern) pink_moon_mbid else northern_sky_mbid, recording_change.before.?);
        try std.testing.expectEqualStrings(if (file.file_id == sounds_northern) northern_sky_mbid else pink_moon_mbid, recording_change.after.?);
    }

    const reverified = try rig.verify(.{ .release_id = try releaseOfFile(library_database, sounds_northern) });
    try std.testing.expectEqual(@as(u64, 2), reverified.stats.agreed);
    try std.testing.expectEqual(@as(u64, 0), reverified.stats.fingerprinted);
    try std.testing.expectEqual(@as(u32, 1), rig.acoustid.lookups.load(.acquire));
}

test "a disputed file with no tagged release is proposed a correction of its recording ID, title and artist alone, which keeps the user's own title, and a recording ID the user set is never corrected" {
    var rig: VerifyRig = undefined;
    try rig.init("file:orca-verify-single?mode=memory&cache=shared");
    defer rig.deinit();
    const disputed_file = try rig.fileOf(try rig.addTone("disputed.wav", 300, "Wrong Title", northern_sky_mbid, null));
    const chosen_file = try rig.fileOf(try rig.addTone("chosen.wav", 420, "Northern Sky", null, null));
    const titled = try rig.runtime.libraryEditTracks(rig.library, &.{try trackOfFile(rig.library_database, disputed_file)}, &.{.{ .field = .title, .value = "My Title" }});
    titled.deinit();
    const identified = try rig.runtime.libraryEditTracks(rig.library, &.{try trackOfFile(rig.library_database, chosen_file)}, &.{.{ .field = .musicbrainz_recording_id, .value = northern_sky_mbid }});
    identified.deinit();
    rig.acoustid.lookup_body = acoustIdAnswer(
        heardBy("0", heardResult("0.95", pink_moon_heard)) ++ "," ++ heardBy("1", heardResult("0.95", pink_moon_heard)),
    );

    const verified = try rig.verify(.{});

    try std.testing.expectEqual(@as(u64, 2), verified.stats.disagreed);
    try std.testing.expectEqual(@as(u64, 0), verified.stats.correction_groups);
    try std.testing.expectEqual(@as(u64, 1), verified.stats.proposals_stored);
    try std.testing.expectEqual(@as(u32, 0), rig.musicbrainz.requestCount());
    const disputed_track = try trackOfFile(rig.library_database, disputed_file);
    const chosen_track = try trackOfFile(rig.library_database, chosen_file);
    try std.testing.expectEqual(database.VerificationOutcome.disagrees, (try rig.outcomeOf(chosen_track)).?);
    try std.testing.expectEqual(@as(usize, 0), try pendingCount(&rig.runtime, rig.library, chosen_track));
    const proposals = try rig.runtime.libraryMatchProposals(rig.library, disputed_track, 10);
    defer proposals.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposals.items.len);
    try std.testing.expectEqual(@as(?u32, null), proposals.items[0].track_number);
    try std.testing.expectEqual(@as(i64, 0), try rig.mismatchCount(chosen_track));
    try std.testing.expectEqual(@as(i64, 1), try rig.mismatchCount(disputed_track));

    _ = try rig.runtime.libraryAcceptMatch(rig.library, proposals.items[0].id);
    try std.testing.expectEqual(@as(i64, 0), try rig.mismatchCount(disputed_track));

    try expectOrcaValue(rig.library_database, disputed_file, .musicbrainz_recording_id, pink_moon_mbid);
    try expectOrcaValue(rig.library_database, disputed_file, .artist, "Nick Drake");
    try expectOrcaValue(rig.library_database, disputed_file, .title, "My Title");
    const title = (try rig.library_database.orca_metadata.get(std.testing.allocator, disputed_file, .title)).?;
    defer title.deinit(std.testing.allocator);
    try std.testing.expectEqual(metadata.Provenance.user, title.provenance);
    const recording = (try rig.library_database.orca_metadata.get(std.testing.allocator, disputed_file, .musicbrainz_recording_id)).?;
    defer recording.deinit(std.testing.allocator);
    try std.testing.expect(recording.locked);
    inline for (.{ .track_number, .disc_number, .musicbrainz_release_track_id, .musicbrainz_release_id, .album }) |field|
        try expectOrcaValue(rig.library_database, disputed_file, field, null);
    try expectOrcaValue(rig.library_database, chosen_file, .musicbrainz_recording_id, northern_sky_mbid);
    const submittable = try rig.runtime.libraryAcoustIdSubmittablePage(rig.library, 0, 10);
    defer submittable.deinit();
    try std.testing.expectEqual(@as(usize, 1), submittable.items.len);
    try std.testing.expectEqual(chosen_file, submittable.items[0].file_id);
}

test "bulk acceptance never takes a correction, even fully confident and fingerprint-backed" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-bulk-no-corrections?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const tagged = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", northern_sky_mbid);
    const untagged = try addMatchTrack(library_database, "Pink Moon", "Nick Drake", null);
    for ([_]struct { track: i64, recording: []const u8 }{
        .{ .track = tagged, .recording = pink_moon_mbid },
        .{ .track = untagged, .recording = pink_moon_mbid },
    }) |proposal| {
        const files = try library_database.tracks.fileIds(std.testing.allocator, proposal.track);
        defer std.testing.allocator.free(files);
        const payload = try (database.ProposalPayload{
            .title = "Pink Moon",
            .artist = "Nick Drake",
            .acoustid_score = 1,
            .acoustid_confidence = 1,
            .musicbrainz_confidence = 1,
        }).encode(std.testing.allocator);
        defer std.testing.allocator.free(payload);
        _ = try library_database.identification_proposals.put(.{
            .file_id = files[0],
            .provider = "musicbrainz+acoustid",
            .provider_id = proposal.recording,
            .confidence = 1,
            .payload = payload,
        });
    }

    try std.testing.expectEqual(@as(u64, 1), try runtime.libraryConfidentMatchCount(library, 0.5));
    const acceptance = try runtime.libraryAcceptConfidentMatches(library, 0.5);

    try std.testing.expectEqual(@as(u64, 1), acceptance.accepted);
    try std.testing.expectEqual(@as(usize, 1), try pendingCount(&runtime, library, tagged));
    try std.testing.expectEqualStrings(northern_sky_mbid, &try recordingIdOf(&runtime, library, tagged));
    const proposals = try runtime.libraryMatchProposals(library, tagged, 10);
    defer proposals.deinit();
    try std.testing.expectEqualStrings(northern_sky_mbid, proposals.items[0].corrects.?);
}

test "verification is refused without AcoustID or with bulk acceptance or a cover fetch, and stops when AcoustID refuses the key" {
    var fake: FakeMusicBrainz = .{};
    var acoustid: FakeAcoustId = .{ .lookup_status = 400, .lookup_body = "{\"status\":\"error\",\"error\":{\"code\":4,\"message\":\"invalid API key\"}}" };
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    runtime.matching_hooks.acoustid_transport = acoustid.transport();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeToneWave(temporary.dir, "tone.wav", 440);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-verify-refused?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const track = try addAudioTrack(library_database, &temporary, "tone.wav", "Northern Sky", "Nick Drake");
    try library_database.observed_tags.upsert(.{ .file_id = try trackFile(library_database, track), .values = .{
        .title = "Northern Sky",
        .musicbrainz_recording_id = northern_sky_mbid,
    } });
    const album = try addRelease(library_database, "Bryter Layter", null);

    try std.testing.expectError(error.AcoustIdRequired, runtime.startLibraryMatching(library, .{ .mode = .verify }));
    try runtime.setAcoustIdClientKey("test-client");
    try std.testing.expectError(error.AcoustIdRequired, runtime.startLibraryMatching(library, .{ .mode = .verify, .fingerprints = false }));
    try std.testing.expectError(error.InvalidMatchRequest, runtime.startLibraryMatching(library, .{ .mode = .verify, .release_id = album, .accept_minimum_confidence = 0.9 }));
    try std.testing.expectError(error.InvalidMatchRequest, runtime.startLibraryMatching(library, .{ .mode = .verify, .release_id = album, .cover_art = true }));
    try std.testing.expectEqual(@as(u32, 0), acoustid.lookups.load(.acquire));

    const job_handle = try runtime.startLibraryMatching(library, .{ .mode = .verify, .track_id = track });

    try std.testing.expectEqual(@as(?u64, 1), (try runtime.jobSnapshotSynced(job_handle)).total_units);
    try std.testing.expectEqual(job.State.failed, try runtime_tests.awaitJob(&runtime, job_handle));
    try std.testing.expectEqual(AcoustIdUse.invalid_client_key, (try runtime.jobMatchStats(job_handle)).acoustid);
    try std.testing.expectEqual(@as(i64, 0), try database.columns.scalar(library_database.database, "SELECT count(*) FROM recording_verifications;"));
    try std.testing.expectEqual(@as(u32, 0), fake.requestCount());
}

fn trackFile(library_database: *database.LibraryDatabase, track_id: i64) !i64 {
    const files = try library_database.tracks.fileIds(std.testing.allocator, track_id);
    defer std.testing.allocator.free(files);
    return files[0];
}

fn addTaggedFile(
    library_database: *database.LibraryDatabase,
    temporary: *std.testing.TmpDir,
    name: []const u8,
    recording_mbid: []const u8,
    release_id: ?i64,
) !i64 {
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ temporary.sub_path, name });
    defer std.testing.allocator.free(path);
    const binding = try library_database.resolveOrCreateFile(std.testing.io, path, .{ .stable_key = "test:maintenance" });
    try library_database.observed_tags.upsert(.{ .file_id = binding.file_id, .values = .{
        .title = name,
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .musicbrainz_recording_id = recording_mbid,
    } });
    try library_database.tracks.upsertTracks(&.{.{
        .release_id = release_id,
        .title = name,
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .duration_ms = 15_000,
        .preferred_file_id = binding.file_id,
    }});
    return trackOfFile(library_database, binding.file_id);
}

fn addUnreadableFile(library_database: *database.LibraryDatabase, temporary: *std.testing.TmpDir, name: []const u8, release_id: ?i64) !i64 {
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = name });
    return addTaggedFile(library_database, temporary, name, northern_sky_mbid, release_id);
}

fn addHashlessTrack(library_database: *database.LibraryDatabase, release_id: i64) !i64 {
    const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
    try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = "Hashless",
        .musicbrainz_recording_id = northern_sky_mbid,
    } });
    try library_database.tracks.upsertTracks(&.{.{
        .release_id = release_id,
        .title = "Hashless",
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .duration_ms = 180_000,
        .preferred_file_id = file_id,
    }});
    return trackOfFile(library_database, file_id);
}

fn finishedJobs(runtime: *OrcaRuntime, buffer: []runtime_module.JobHandle) []runtime_module.JobHandle {
    var count: usize = 0;
    while (runtime.pollEvent()) |event| switch (event.outcome) {
        .job_finished => |finished| {
            if (count < buffer.len) buffer[count] = finished.job;
            count += 1;
        },
        else => {},
    };
    return buffer[0..@min(count, buffer.len)];
}

const MaintenanceRig = struct {
    verify: VerifyRig,
    clock: network.testing.TestClock,

    const interval_ms: u32 = 60_000;

    fn init(self: *MaintenanceRig, uri: [:0]const u8) !void {
        self.clock = .{ .wall_offset_ms = FakeMusicBrainz.wall_base_ms };
        try self.verify.init(uri);
        self.verify.runtime.listen_hooks.sample_clock = sampleClock(&self.clock);
        self.verify.acoustid.lookup_body = acoustIdAnswer(heardBy("0", heardResult("0.95", northern_sky_heard)));
    }

    fn deinit(self: *MaintenanceRig) void {
        self.verify.acoustid.held.store(false, .release);
        self.verify.deinit();
    }

    fn runtime(self: *MaintenanceRig) *OrcaRuntime {
        return &self.verify.runtime;
    }

    fn enable(self: *MaintenanceRig, library: LibraryHandle) !void {
        try self.runtime().libraryMaintenance(library, .{ .enabled = true, .interval_ms = interval_ms });
    }

    fn status(self: *MaintenanceRig, library: LibraryHandle) !MaintenanceStatus {
        return self.runtime().libraryMaintenanceStatus(library);
    }

    fn awaitUnits(self: *MaintenanceRig, library: LibraryHandle, units: u64) !MaintenanceUnit {
        var deadline: runtime_tests.TestDeadline = .init(10_000);
        while (deadline.tick()) {
            self.runtime().pump();
            const current = try self.status(library);
            if (current.units_run >= units) return current.last.?;
        }
        return error.UnitDidNotFinish;
    }

    fn awaitLookupCount(self: *MaintenanceRig, lookups: u32) !void {
        var deadline: runtime_tests.TestDeadline = .init(10_000);
        while (self.verify.acoustid.lookups.load(.acquire) < lookups) {
            if (!deadline.tick()) return error.LookupNeverSent;
        }
    }

    fn awaitLookups(self: *MaintenanceRig, lookups: u32) !runtime_module.JobHandle {
        const unit = runtime_jobs.maintenanceUnitRunning(self.runtime()) orelse return error.UnitNotRunning;
        try self.awaitLookupCount(lookups);
        return unit.job;
    }

    fn pumpFor(self: *MaintenanceRig, milliseconds: u64) void {
        var deadline: runtime_tests.TestDeadline = .init(milliseconds);
        while (deadline.tick()) self.runtime().pump();
    }
};

test "maintenance is off until enabled, then verifies one Release per interval while idle" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-interval?mode=memory&cache=shared");
    defer rig.deinit();
    const library = rig.verify.library;
    const library_database = rig.verify.library_database;
    const first_release = try addRelease(library_database, "Bryter Layter", null);
    const second_release = try addRelease(library_database, "Pink Moon", null);
    const first = try rig.verify.addTone("first.wav", 300, "Northern Sky", northern_sky_mbid, first_release);
    const second = try rig.verify.addTone("second.wav", 420, "Northern Sky", northern_sky_mbid, second_release);

    rig.pumpFor(20);
    const off = try rig.status(library);
    try std.testing.expect(!off.enabled);
    try std.testing.expectEqual(runtime_module.MaintenanceState.off, off.state);
    try std.testing.expectEqual(@as(usize, 0), rig.runtime().job_workers.items.len);

    try rig.enable(library);
    try std.testing.expectEqual(@as(?u64, 0), (try rig.status(library)).next_due_ms);
    rig.runtime().pump();
    try std.testing.expectEqual(runtime_module.MaintenanceState.running, (try rig.status(library)).state);
    const unit = try rig.awaitUnits(library, 1);
    try std.testing.expectEqual(@as(?i64, first_release), unit.release_id);
    try std.testing.expectEqual(job.State.succeeded, unit.state);
    try std.testing.expectEqual(@as(u64, 1), unit.stats.verified);
    try std.testing.expect(try rig.verify.outcomeOf(first) != null);
    try std.testing.expect(try rig.verify.outcomeOf(second) == null);
    const waiting = try rig.status(library);
    try std.testing.expectEqual(runtime_module.MaintenanceState.waiting, waiting.state);
    try std.testing.expectEqual(@as(?u64, MaintenanceRig.interval_ms), waiting.next_due_ms);

    rig.clock.advance(MaintenanceRig.interval_ms - 1);
    rig.pumpFor(20);
    try std.testing.expectEqual(@as(u64, 1), (try rig.status(library)).units_run);
    try std.testing.expectEqual(@as(?u64, 1), (try rig.status(library)).next_due_ms);
    try std.testing.expectEqual(@as(u32, 1), rig.verify.acoustid.lookups.load(.acquire));

    rig.clock.advance(1);
    try std.testing.expectEqual(@as(?i64, second_release), (try rig.awaitUnits(library, 2)).release_id);
    try std.testing.expect(try rig.verify.outcomeOf(second) != null);
    try std.testing.expectEqual(@as(u32, 2), rig.verify.acoustid.lookups.load(.acquire));
}

test "a due unit waits while a Player plays, starts once it is paused, and a drained Player counts as idle" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-idle?mode=memory&cache=shared");
    defer rig.deinit();
    const library = rig.verify.library;
    const library_database = rig.verify.library_database;
    _ = try addUnreadableFile(library_database, &rig.verify.temporary, "a.wav", try addRelease(library_database, "A", null));
    _ = try addUnreadableFile(library_database, &rig.verify.temporary, "b.wav", try addRelease(library_database, "B", null));
    const player = (try rig.runtime().players.get(try rig.runtime().createPlayer())).player;
    player.state.store(.playing, .release);

    try rig.enable(library);
    rig.pumpFor(20);
    const deferred = try rig.status(library);
    try std.testing.expectEqual(runtime_module.MaintenanceState.waiting, deferred.state);
    try std.testing.expectEqual(@as(?u64, MaintenanceRig.interval_ms), deferred.next_due_ms);
    try std.testing.expectEqual(@as(usize, 0), rig.runtime().job_workers.items.len);

    player.state.store(.paused, .release);
    rig.pumpFor(20);
    try std.testing.expectEqual(@as(usize, 0), rig.runtime().job_workers.items.len);
    rig.clock.advance(MaintenanceRig.interval_ms);
    try std.testing.expectEqual(job.State.succeeded, (try rig.awaitUnits(library, 1)).state);

    player.state.store(.playing, .release);
    player.drained.store(true, .release);
    rig.clock.advance(MaintenanceRig.interval_ms);
    try std.testing.expectEqual(job.State.succeeded, (try rig.awaitUnits(library, 2)).state);
}

test "no unit starts beside a host job or an automatic reconcile, and playback starting does not cancel one" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-beside?mode=memory&cache=shared");
    defer rig.deinit();
    const runtime = rig.runtime();
    const library = rig.verify.library;
    const library_database = rig.verify.library_database;
    const host_release = try addRelease(library_database, "Host", null);
    _ = try rig.verify.addTone("host.wav", 300, "Northern Sky", northern_sky_mbid, host_release);
    const watcher_release = try addRelease(library_database, "Watcher", null);
    _ = try rig.verify.addTone("watcher.wav", 360, "Northern Sky", northern_sky_mbid, watcher_release);
    const unit_release = try addRelease(library_database, "Unit", null);
    _ = try rig.verify.addTone("unit.wav", 420, "Northern Sky", northern_sky_mbid, unit_release);

    rig.verify.acoustid.held.store(true, .release);
    const host = try runtime.startLibraryMatching(library, .{ .release_id = host_release, .mode = .verify });
    try rig.awaitLookupCount(1);
    try rig.enable(library);
    rig.pumpFor(20);
    try std.testing.expectEqual(@as(usize, 1), runtime.job_workers.items.len);
    try std.testing.expectEqual(@as(?u64, MaintenanceRig.interval_ms), (try rig.status(library)).next_due_ms);
    rig.verify.acoustid.held.store(false, .release);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(runtime, host));

    rig.verify.acoustid.held.store(true, .release);
    rig.clock.advance(MaintenanceRig.interval_ms);
    const reconcile = try runtime_jobs.spawnJobWorker(runtime, library, .{ .metadata_lookup = .{
        .batch_size = 64,
        .limit = null,
        .setup = .{
            .io = try runtime_listens.networkIo(runtime),
            .server = runtime.musicbrainz_server,
            .identity = runtime.client_identity.?,
            .hooks = runtime.matching_hooks,
            .scope = .{ .release = watcher_release },
            .mode = .verify,
            .acoustid = runtime_jobs.acoustIdSetup(runtime),
            .cover_art_server = runtime.coverartarchive_server,
        },
    } }, .watcher);
    try rig.awaitLookupCount(2);
    rig.pumpFor(20);
    const beside_watcher = try rig.status(library);
    try std.testing.expectEqual(runtime_module.MaintenanceState.waiting, beside_watcher.state);
    try std.testing.expectEqual(@as(?u64, MaintenanceRig.interval_ms), beside_watcher.next_due_ms);
    try std.testing.expect(runtime_jobs.maintenanceUnitRunning(runtime) == null);
    rig.verify.acoustid.held.store(false, .release);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(runtime, reconcile));

    rig.verify.acoustid.held.store(true, .release);
    rig.clock.advance(MaintenanceRig.interval_ms);
    runtime.pump();
    const unit = try rig.awaitLookups(3);
    const player = (try runtime.players.get(try runtime.createPlayer())).player;
    player.state.store(.playing, .release);
    rig.pumpFor(20);
    try std.testing.expectEqual(runtime_module.MaintenanceState.running, (try rig.status(library)).state);
    try std.testing.expectEqual(job.State.running, (try runtime.jobSnapshotSynced(unit)).state);
    rig.verify.acoustid.held.store(false, .release);
    const finished = try rig.awaitUnits(library, 1);
    try std.testing.expectEqual(job.State.succeeded, finished.state);
    try std.testing.expectEqual(@as(?i64, unit_release), finished.release_id);
}

test "with no Release left, a unit verifies at most twenty loose Tracks, then nothing verifiable is a no-op due again after the interval" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-loose?mode=memory&cache=shared");
    defer rig.deinit();
    const library = rig.verify.library;
    const library_database = rig.verify.library_database;
    for (0..21) |index| {
        var name_buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "loose-{d}.wav", .{index});
        _ = try addUnreadableFile(library_database, &rig.verify.temporary, name, null);
    }

    try rig.enable(library);
    const first = try rig.awaitUnits(library, 1);
    try std.testing.expectEqual(@as(?i64, null), first.release_id);
    try std.testing.expectEqual(@as(u64, 20), first.stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 20), first.stats.verified);
    try std.testing.expectEqual(@as(u64, 1), try library_database.recording_verifications.verifiableCount(.library, null));

    rig.clock.advance(MaintenanceRig.interval_ms);
    try std.testing.expectEqual(@as(u64, 1), (try rig.awaitUnits(library, 2)).stats.tracks_examined);

    rig.clock.advance(MaintenanceRig.interval_ms);
    rig.pumpFor(20);
    const idle = try rig.status(library);
    try std.testing.expectEqual(@as(u64, 2), idle.units_run);
    try std.testing.expectEqual(runtime_module.MaintenanceState.waiting, idle.state);
    try std.testing.expectEqual(@as(?u64, MaintenanceRig.interval_ms), idle.next_due_ms);
    try std.testing.expectEqual(@as(usize, 2), rig.runtime().job_workers.items.len);
    try std.testing.expectEqual(@as(u32, 0), rig.verify.acoustid.lookups.load(.acquire));
}

test "a Release that stores no outcome is passed over for the next, and the cursor wraps to the first" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-cursor?mode=memory&cache=shared");
    defer rig.deinit();
    const library = rig.verify.library;
    const library_database = rig.verify.library_database;
    const hashless_release = try addRelease(library_database, "Hashless", null);
    _ = try addHashlessTrack(library_database, hashless_release);
    const readable_release = try addRelease(library_database, "Readable", null);
    _ = try addUnreadableFile(library_database, &rig.verify.temporary, "readable.wav", readable_release);

    try rig.enable(library);
    const first = try rig.awaitUnits(library, 1);
    try std.testing.expectEqual(@as(?i64, hashless_release), first.release_id);
    try std.testing.expectEqual(@as(u64, 1), first.stats.skipped);
    try std.testing.expectEqual(@as(u64, 0), first.stats.verified);

    rig.clock.advance(MaintenanceRig.interval_ms);
    const second = try rig.awaitUnits(library, 2);
    try std.testing.expectEqual(@as(?i64, readable_release), second.release_id);
    try std.testing.expectEqual(@as(u64, 1), second.stats.verified);

    rig.clock.advance(MaintenanceRig.interval_ms);
    try std.testing.expectEqual(@as(?i64, hashless_release), (try rig.awaitUnits(library, 3)).release_id);
}

test "maintenance is blocked without a client identity or AcoustID and reports which" {
    var musicbrainz: FakeMusicBrainz = .{};
    var acoustid: FakeAcoustId = .{};
    var clock: network.testing.TestClock = .{};
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = musicbrainz.hooks();
    runtime.matching_hooks.acoustid_transport = acoustid.transport();
    runtime.listen_hooks.sample_clock = sampleClock(&clock);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-maintenance-blocked?mode=memory&cache=shared");
    try runtime.libraryMaintenance(library, .{ .enabled = true, .interval_ms = MaintenanceRig.interval_ms });

    runtime.pump();
    const anonymous = try runtime.libraryMaintenanceStatus(library);
    try std.testing.expectEqual(runtime_module.MaintenanceState.blocked, anonymous.state);
    try std.testing.expectEqual(@as(?runtime_module.MaintenanceBlock, .client_identity_required), anonymous.blocked);
    try std.testing.expectEqual(@as(?u64, MaintenanceRig.interval_ms), anonymous.next_due_ms);

    try runtime.setClientIdentity(network.testing.test_identity);
    clock.advance(MaintenanceRig.interval_ms);
    runtime.pump();
    try std.testing.expectEqual(@as(?runtime_module.MaintenanceBlock, .acoustid_required), (try runtime.libraryMaintenanceStatus(library)).blocked);

    try runtime.setAcoustIdClientKey("test-client");
    clock.advance(MaintenanceRig.interval_ms);
    runtime.pump();
    const unblocked = try runtime.libraryMaintenanceStatus(library);
    try std.testing.expectEqual(runtime_module.MaintenanceState.waiting, unblocked.state);
    try std.testing.expectEqual(@as(?runtime_module.MaintenanceBlock, null), unblocked.blocked);
    try std.testing.expectEqual(@as(usize, 0), runtime.job_workers.items.len);
    try std.testing.expectEqual(@as(u32, 0), musicbrainz.requestCount() + acoustid.lookups.load(.acquire));
    try std.testing.expectError(error.InvalidMaintenanceOptions, runtime.libraryMaintenance(library, .{ .enabled = true, .interval_ms = 0 }));
}

test "a provider block recorded in the Library defers the unit a full interval without a request" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-backoff?mode=memory&cache=shared");
    defer rig.deinit();
    const library = rig.verify.library;
    const library_database = rig.verify.library_database;
    _ = try rig.verify.addTone("tone.wav", 300, "Northern Sky", northern_sky_mbid, try addRelease(library_database, "A", null));
    try library_database.provider_state.put(providers.acoustid.service, .{
        .blocked_until_ms = FakeMusicBrainz.wall_base_ms + MaintenanceRig.interval_ms + MaintenanceRig.interval_ms / 2,
        .backoff_ms = 60_000,
    });

    try rig.enable(library);
    rig.pumpFor(20);
    const blocked = try rig.status(library);
    try std.testing.expectEqual(runtime_module.MaintenanceState.blocked, blocked.state);
    try std.testing.expectEqual(@as(?runtime_module.MaintenanceBlock, .provider_busy), blocked.blocked);
    try std.testing.expectEqual(@as(?u64, MaintenanceRig.interval_ms), blocked.next_due_ms);

    rig.clock.advance(MaintenanceRig.interval_ms);
    rig.pumpFor(20);
    try std.testing.expectEqual(@as(?u64, MaintenanceRig.interval_ms), (try rig.status(library)).next_due_ms);
    try std.testing.expectEqual(@as(usize, 0), rig.runtime().job_workers.items.len);
    try std.testing.expectEqual(@as(u32, 0), rig.verify.acoustid.lookups.load(.acquire));

    rig.clock.advance(MaintenanceRig.interval_ms);
    try std.testing.expectEqual(job.State.succeeded, (try rig.awaitUnits(library, 1)).state);
    try std.testing.expectEqual(@as(?runtime_module.MaintenanceBlock, null), (try rig.status(library)).blocked);
    try std.testing.expectEqual(@as(u32, 1), rig.verify.acoustid.lookups.load(.acquire));
}

test "a unit that finds AcoustID held by another process past its wait is blocked as provider busy for a full interval" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-lease?mode=memory&cache=shared");
    defer rig.deinit();
    const library = rig.verify.library;
    const library_database = rig.verify.library_database;
    _ = try rig.verify.addTone("tone.wav", 300, "Northern Sky", northern_sky_mbid, try addRelease(library_database, "A", null));
    const now_ms = FakeMusicBrainz.wall_base_ms;
    try std.testing.expect(try library_database.provider_state.claimLease(
        providers.acoustid.service,
        99,
        now_ms,
        now_ms + 2 * network.client.lease_duration_ms,
    ));

    try rig.enable(library);
    const busy = try rig.awaitUnits(library, 1);
    try std.testing.expectEqual(job.State.failed, busy.state);
    try std.testing.expectEqual(BusyService.acoustid, busy.stats.busy);
    const blocked = try rig.status(library);
    try std.testing.expectEqual(@as(?runtime_module.MaintenanceBlock, .provider_busy), blocked.blocked);
    try std.testing.expectEqual(@as(?u64, MaintenanceRig.interval_ms), blocked.next_due_ms);
    try std.testing.expectEqual(@as(u32, 0), rig.verify.acoustid.lookups.load(.acquire));

    try library_database.provider_state.releaseLease(providers.acoustid.service, 99);
    rig.clock.advance(MaintenanceRig.interval_ms - 1);
    rig.pumpFor(20);
    try std.testing.expectEqual(@as(u64, 1), (try rig.status(library)).units_run);
    rig.clock.advance(1);
    try std.testing.expectEqual(job.State.succeeded, (try rig.awaitUnits(library, 2)).state);
    try std.testing.expectEqual(@as(?runtime_module.MaintenanceBlock, null), (try rig.status(library)).blocked);
}

test "a host matching job started during a unit cancels it, is queued with default stats, and starts once the unit is reaped, after its job_finished" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-handoff?mode=memory&cache=shared");
    defer rig.deinit();
    const library = rig.verify.library;
    const library_database = rig.verify.library_database;
    _ = try rig.verify.addTone("unit.wav", 300, "Northern Sky", northern_sky_mbid, try addRelease(library_database, "A", null));
    const release = try addRelease(library_database, "B", null);
    const track = try rig.verify.addTone("host.wav", 500, "Northern Sky", northern_sky_mbid, release);
    rig.verify.acoustid.held.store(true, .release);
    try rig.enable(library);
    rig.runtime().pump();
    const unit = try rig.awaitLookups(1);

    const host = try rig.runtime().startLibraryMatching(library, .{ .release_id = release, .mode = .verify });
    try std.testing.expectEqual(job.State.waiting, (try rig.runtime().jobSnapshotSynced(host)).state);
    try std.testing.expectEqual(runtime_module.MatchStats{}, try rig.runtime().jobMatchStats(host));
    try std.testing.expectEqual(runtime_module.JobOrigin.host, try rig.runtime().jobOrigin(host));
    try std.testing.expectEqual(runtime_module.JobOrigin.maintenance, try rig.runtime().jobOrigin(unit));
    try std.testing.expectError(error.MatchingAlreadyRunning, rig.runtime().startLibraryMatching(library, .{}));
    try std.testing.expectError(error.AcoustIdBusy, rig.runtime().startAcoustIdSubmission(library));

    rig.pumpFor(50);
    try std.testing.expectEqual(job.State.waiting, (try rig.runtime().jobSnapshotSynced(host)).state);
    try std.testing.expectEqual(@as(usize, 1), rig.runtime().work_registry.count());

    while (rig.runtime().events.hasCapacity())
        try rig.runtime().events.publish(.{ .request_id = 0, .outcome = .{ .job_started = unit } });
    rig.verify.acoustid.held.store(false, .release);
    var deadline: runtime_tests.TestDeadline = .init(10_000);
    while (!runtime_jobs.maintenanceUnitRunning(rig.runtime()).?.registration.isFinished()) {
        if (!deadline.tick()) return error.UnitDidNotStop;
    }
    rig.pumpFor(20);
    try std.testing.expectEqual(job.State.waiting, (try rig.runtime().jobSnapshotSynced(host)).state);

    var finished_buffer: [4]runtime_module.JobHandle = undefined;
    try std.testing.expectEqual(@as(usize, 0), finishedJobs(rig.runtime(), &finished_buffer).len);
    rig.runtime().pump();
    try std.testing.expect((try rig.runtime().jobSnapshotSynced(host)).state != .waiting);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(rig.runtime(), host));
    const finished = finishedJobs(rig.runtime(), &finished_buffer);
    try std.testing.expectEqual(@as(usize, 2), finished.len);
    try std.testing.expect(finished[0].eql(unit));
    try std.testing.expect(finished[1].eql(host));

    const status = try rig.status(library);
    try std.testing.expectEqual(job.State.cancelled, status.last.?.state);
    try std.testing.expectEqual(@as(?u64, MaintenanceRig.interval_ms), status.next_due_ms);
    const stats = try rig.runtime().jobMatchStats(host);
    try std.testing.expectEqual(BusyService.none, stats.busy);
    try std.testing.expectEqual(@as(u64, 1), stats.verified);
    try std.testing.expect(try rig.verify.outcomeOf(track) != null);
    try std.testing.expectEqual(@as(u32, 2), rig.verify.acoustid.lookups.load(.acquire));
}

test "a queued host job cancelled before it starts finishes cancelled with one job_finished and no worker" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-cancel-queued?mode=memory&cache=shared");
    defer rig.deinit();
    const library = rig.verify.library;
    const release = try addRelease(rig.verify.library_database, "A", null);
    _ = try rig.verify.addTone("tone.wav", 300, "Northern Sky", northern_sky_mbid, release);
    rig.verify.acoustid.held.store(true, .release);
    try rig.enable(library);
    rig.runtime().pump();
    const unit = try rig.awaitLookups(1);

    const host = try rig.runtime().startLibraryMatching(library, .{ .release_id = release, .mode = .verify });
    try rig.runtime().cancelJob(host);
    try std.testing.expectEqual(job.State.cancelling, (try rig.runtime().jobSnapshotSynced(host)).state);
    rig.verify.acoustid.held.store(false, .release);
    var deadline: runtime_tests.TestDeadline = .init(10_000);
    while (!runtime_jobs.maintenanceUnitRunning(rig.runtime()).?.registration.isFinished()) {
        if (!deadline.tick()) return error.UnitDidNotStop;
    }
    while (rig.runtime().events.hasCapacity())
        try rig.runtime().events.publish(.{ .request_id = 0, .outcome = .{ .job_started = unit } });
    _ = rig.runtime().pollEvent();
    rig.runtime().pump();
    try std.testing.expectEqual(job.State.cancelled, (try rig.status(library)).last.?.state);
    try std.testing.expectEqual(job.State.cancelling, (try rig.runtime().jobSnapshotSynced(host)).state);
    var finished_buffer: [4]runtime_module.JobHandle = undefined;
    var finished = finishedJobs(rig.runtime(), &finished_buffer);
    try std.testing.expectEqual(@as(usize, 1), finished.len);
    try std.testing.expect(finished[0].eql(unit));

    rig.runtime().pump();
    try std.testing.expectEqual(job.State.cancelled, (try rig.runtime().jobSnapshotSynced(host)).state);
    finished = finishedJobs(rig.runtime(), &finished_buffer);
    try std.testing.expectEqual(@as(usize, 1), finished.len);
    try std.testing.expect(finished[0].eql(host));
    try std.testing.expectEqual(@as(usize, 1), rig.runtime().job_workers.items.len);
    try std.testing.expectEqual(@as(usize, 0), rig.runtime().work_registry.count());
    try std.testing.expectError(error.StaleHandle, rig.runtime().jobMatchStats(host));
    try std.testing.expectEqual(@as(u32, 1), rig.verify.acoustid.lookups.load(.acquire));
}

test "shutdown with a running unit and a queued host job leaves no worker" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-shutdown?mode=memory&cache=shared");
    defer rig.deinit();
    const library = rig.verify.library;
    const release = try addRelease(rig.verify.library_database, "A", null);
    _ = try rig.verify.addTone("tone.wav", 300, "Northern Sky", northern_sky_mbid, release);
    rig.verify.acoustid.hang_lookups_from = 0;
    try rig.enable(library);
    rig.runtime().pump();
    _ = try rig.awaitLookups(1);
    const host = try rig.runtime().startLibraryMatching(library, .{ .release_id = release, .mode = .verify });

    rig.runtime().shutdown();
    try std.testing.expectEqual(@as(usize, 0), rig.runtime().work_registry.count());
    try std.testing.expectEqual(@as(usize, 0), rig.runtime().job_workers.items.len);
    try std.testing.expectEqual(@as(usize, 0), rig.runtime().waiting_jobs.len);
    try std.testing.expectError(error.StaleHandle, rig.runtime().jobs.snapshot(host));
    rig.runtime().pump();
    try std.testing.expect(rig.runtime().pollEvent() == null);
    try std.testing.expectEqual(@as(u32, 1), rig.verify.acoustid.lookups.load(.acquire));
}

test "destroying the Library of a queued host job drops it and leaves another Library's maintenance waiting" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-destroy-a?mode=memory&cache=shared");
    defer rig.deinit();
    const library = rig.verify.library;
    const release = try addRelease(rig.verify.library_database, "A", null);
    _ = try rig.verify.addTone("tone.wav", 300, "Northern Sky", northern_sky_mbid, release);
    const other = try rig.runtime().openLibrary(std.testing.io, "file:orca-maintenance-destroy-b?mode=memory&cache=shared");
    const other_database = try libraryDatabase(rig.runtime(), other);
    _ = try addUnreadableFile(other_database, &rig.verify.temporary, "other.wav", try addRelease(other_database, "B", null));
    rig.verify.acoustid.hang_lookups_from = 0;
    try rig.enable(library);
    try rig.enable(other);
    rig.runtime().pump();
    _ = try rig.awaitLookups(1);
    const host = try rig.runtime().startLibraryMatching(library, .{ .release_id = release, .mode = .verify });

    try rig.runtime().destroyLibrary(library);
    try std.testing.expectEqual(@as(usize, 0), rig.runtime().waiting_jobs.len);
    try std.testing.expectEqual(job.State.cancelled, (try rig.runtime().jobSnapshotSynced(host)).state);
    try std.testing.expectEqual(@as(usize, 0), rig.runtime().work_registry.count());
    const waiting = try rig.status(other);
    try std.testing.expectEqual(runtime_module.MaintenanceState.waiting, waiting.state);
    try std.testing.expectEqual(@as(u64, 0), waiting.units_run);

    try std.testing.expectEqual(job.State.succeeded, (try rig.awaitUnits(other, 1)).state);
    var finished_buffer: [4]runtime_module.JobHandle = undefined;
    for (finishedJobs(rig.runtime(), &finished_buffer)) |finished| try std.testing.expect(!finished.eql(host));
    try std.testing.expectEqual(@as(u32, 1), rig.verify.acoustid.lookups.load(.acquire));
}

test "removing a root cancels a running unit instead of refusing" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-remove-root?mode=memory&cache=shared");
    defer rig.deinit();
    const library = rig.verify.library;
    _ = try rig.verify.addTone("tone.wav", 300, "Northern Sky", northern_sky_mbid, try addRelease(rig.verify.library_database, "A", null));
    const root_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{rig.verify.temporary.sub_path});
    defer std.testing.allocator.free(root_path);
    const root = try rig.runtime().libraryAddRoot(library, std.testing.io, root_path);
    rig.verify.acoustid.hang_lookups_from = 0;
    try rig.enable(library);
    rig.runtime().pump();
    _ = try rig.awaitLookups(1);

    _ = try rig.runtime().libraryRemoveRoot(library, root.root_id);
    const unit = try rig.awaitUnits(library, 1);
    try std.testing.expectEqual(job.State.cancelled, unit.state);
    try std.testing.expect(unit.stats.cancelled);
}

test "removing a root refuses while a host job waits behind a unit" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-remove-root-queued?mode=memory&cache=shared");
    defer rig.deinit();
    const library = rig.verify.library;
    const release = try addRelease(rig.verify.library_database, "A", null);
    _ = try rig.verify.addTone("tone.wav", 300, "Northern Sky", northern_sky_mbid, release);
    const root_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{rig.verify.temporary.sub_path});
    defer std.testing.allocator.free(root_path);
    const root = try rig.runtime().libraryAddRoot(library, std.testing.io, root_path);
    rig.verify.acoustid.held.store(true, .release);
    try rig.enable(library);
    rig.runtime().pump();
    _ = try rig.awaitLookups(1);
    const host = try rig.runtime().startLibraryMatching(library, .{ .release_id = release, .mode = .verify });
    try std.testing.expectEqual(job.State.waiting, (try rig.runtime().jobSnapshotSynced(host)).state);

    try std.testing.expectError(error.LibraryJobRunning, rig.runtime().libraryRemoveRoot(library, root.root_id));
    rig.verify.acoustid.held.store(false, .release);
    var deadline: runtime_tests.TestDeadline = .init(10_000);
    while ((try rig.runtime().jobSnapshotSynced(host)).state == .waiting) {
        if (!deadline.tick()) return error.HostJobNeverStarted;
        rig.runtime().pump();
    }
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(rig.runtime(), host));
    _ = try rig.runtime().libraryRemoveRoot(library, root.root_id);
}

const PausedVerification = struct {
    job: runtime_module.JobHandle,
    registration: *work.Registration,
};

fn pausedVerification(rig: *VerifyRig) !PausedVerification {
    _ = try rig.addTone("paused.wav", 300, "Northern Sky", northern_sky_mbid, null);
    rig.acoustid.lookup_body = acoustIdAnswer(heardBy("0", heardResult("0.95", northern_sky_heard)));
    rig.acoustid.held.store(true, .release);
    const verification = try rig.runtime.startLibraryMatching(rig.library, .{ .mode = .verify });
    var deadline: runtime_tests.TestDeadline = .init(10_000);
    while (rig.acoustid.lookups.load(.acquire) == 0) {
        if (!deadline.tick()) return error.LookupNeverSent;
    }
    try rig.runtime.pauseJob(verification);
    rig.acoustid.held.store(false, .release);
    for (rig.runtime.job_workers.items) |worker| {
        if (worker.job.eql(verification)) return .{ .job = verification, .registration = worker.registration };
    }
    return error.WorkerNotFound;
}

fn holdForPolls(polls: u64) void {
    var hold: runtime_tests.TestDeadline = .init(polls * library_pass.CancellationToken.pause_poll_ms);
    while (hold.tick()) {}
}

test "a paused Job holds its thread past its next cancellation poll until cancel wakes it within 100 ms" {
    var rig: VerifyRig = undefined;
    try rig.init("file:orca-paused-job-cancel?mode=memory&cache=shared");
    defer rig.deinit();
    defer rig.acoustid.held.store(false, .release);
    const paused = try pausedVerification(&rig);

    holdForPolls(5);
    try std.testing.expect(!paused.registration.isFinished());
    try std.testing.expectEqual(@as(u32, 1), rig.acoustid.lookups.load(.acquire));
    const snapshot = try rig.runtime.jobSnapshotSynced(paused.job);
    try std.testing.expectEqual(job.State.paused, snapshot.state);
    try std.testing.expect(snapshot.paused);
    try std.testing.expect(snapshot.started_at != null);
    try std.testing.expectEqual(@as(?u64, null), snapshot.estimated_remaining_ms);

    const cancelled_at = std.Io.Clock.awake.now(std.testing.io);
    try rig.runtime.cancelJob(paused.job);
    var deadline: runtime_tests.TestDeadline = .init(10_000);
    while (!paused.registration.isFinished()) {
        if (!deadline.tick()) return error.PausedJobNeverWoke;
    }
    const woke_after = cancelled_at.durationTo(std.Io.Clock.awake.now(std.testing.io));
    try std.testing.expect(woke_after.toMilliseconds() < 100);
    try std.testing.expectEqual(job.State.cancelled, try runtime_tests.awaitJob(&rig.runtime, paused.job));
}

test "a resumed Job carries on from the poll it was paused at" {
    var rig: VerifyRig = undefined;
    try rig.init("file:orca-paused-job-resume?mode=memory&cache=shared");
    defer rig.deinit();
    defer rig.acoustid.held.store(false, .release);
    const paused = try pausedVerification(&rig);
    holdForPolls(3);
    try std.testing.expect(!paused.registration.isFinished());

    try rig.runtime.resumeJob(paused.job);
    try std.testing.expectEqual(job.State.running, (try rig.runtime.jobSnapshotSynced(paused.job)).state);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&rig.runtime, paused.job));
    try std.testing.expectEqual(@as(u64, 1), (try rig.runtime.jobMatchStats(paused.job)).verified);
    try std.testing.expectEqual(@as(u32, 1), rig.acoustid.lookups.load(.acquire));
}

test "shutdown completes with a paused Job holding its thread and Jobs waiting behind it" {
    var rig: VerifyRig = undefined;
    try rig.init("file:orca-paused-job-shutdown?mode=memory&cache=shared");
    defer rig.deinit();
    defer rig.acoustid.held.store(false, .release);
    const paused = try pausedVerification(&rig);
    const behind = try rig.runtime.startLibraryProjection(rig.library);
    try std.testing.expectEqual(job.State.waiting, (try rig.runtime.jobSnapshotSynced(behind)).state);
    try rig.runtime.pauseAll(rig.library);
    const held_back = try rig.runtime.startLibraryProjection(rig.library);
    try std.testing.expect((try rig.runtime.jobSnapshotSynced(held_back)).paused);
    holdForPolls(2);
    try std.testing.expect(!paused.registration.isFinished());

    rig.runtime.shutdown();
    try std.testing.expectEqual(@as(usize, 0), rig.runtime.work_registry.count());
    try std.testing.expectEqual(@as(usize, 0), rig.runtime.job_workers.items.len);
    try std.testing.expectEqual(@as(usize, 0), rig.runtime.waiting_jobs.len);
    for ([_]runtime_module.JobHandle{ paused.job, behind, held_back }) |job_handle| {
        try std.testing.expectError(error.StaleHandle, rig.runtime.jobs.snapshot(job_handle));
    }
}

test "disabling maintenance cancels the running unit and reports off" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-disable?mode=memory&cache=shared");
    defer rig.deinit();
    const library = rig.verify.library;
    _ = try rig.verify.addTone("tone.wav", 300, "Northern Sky", northern_sky_mbid, try addRelease(rig.verify.library_database, "A", null));
    rig.verify.acoustid.hang_lookups_from = 0;
    try rig.enable(library);
    rig.runtime().pump();
    const unit = try rig.awaitLookups(1);

    try rig.runtime().libraryMaintenance(library, .{ .enabled = false });
    const off = try rig.status(library);
    try std.testing.expect(!off.enabled);
    try std.testing.expectEqual(runtime_module.MaintenanceState.off, off.state);
    try std.testing.expectEqual(job.State.cancelled, try runtime_tests.awaitJob(rig.runtime(), unit));
    rig.clock.advance(MaintenanceRig.interval_ms);
    rig.pumpFor(20);
    try std.testing.expectEqual(runtime_module.MaintenanceState.off, (try rig.status(library)).state);
    try std.testing.expectEqual(@as(usize, 1), rig.runtime().job_workers.items.len);
    var finished_buffer: [2]runtime_module.JobHandle = undefined;
    try std.testing.expectEqual(@as(usize, 1), finishedJobs(rig.runtime(), &finished_buffer).len);
    try std.testing.expectEqual(@as(?u64, null), rig.runtime().nextPumpTimeoutMs());
}

test "the pump timeout is the time to the next unit, zero when due, and null when off" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-timeout?mode=memory&cache=shared");
    defer rig.deinit();
    const library = rig.verify.library;
    try std.testing.expectEqual(@as(?u64, null), rig.runtime().nextPumpTimeoutMs());

    try rig.enable(library);
    try std.testing.expectEqual(@as(?u64, 0), rig.runtime().nextPumpTimeoutMs());
    rig.runtime().pump();
    try std.testing.expectEqual(@as(?u64, MaintenanceRig.interval_ms), rig.runtime().nextPumpTimeoutMs());
    rig.clock.advance(MaintenanceRig.interval_ms - 10);
    try std.testing.expectEqual(@as(?u64, 10), rig.runtime().nextPumpTimeoutMs());
    rig.clock.advance(10);
    try std.testing.expectEqual(@as(?u64, 0), rig.runtime().nextPumpTimeoutMs());

    try rig.runtime().libraryMaintenance(library, .{ .enabled = false });
    try std.testing.expectEqual(@as(?u64, null), rig.runtime().nextPumpTimeoutMs());
}

test "two Libraries with maintenance run one unit at a time" {
    var rig: MaintenanceRig = undefined;
    try rig.init("file:orca-maintenance-two-a?mode=memory&cache=shared");
    defer rig.deinit();
    const library = rig.verify.library;
    _ = try rig.verify.addTone("tone.wav", 300, "Northern Sky", northern_sky_mbid, try addRelease(rig.verify.library_database, "A", null));
    const other = try rig.runtime().openLibrary(std.testing.io, "file:orca-maintenance-two-b?mode=memory&cache=shared");
    const other_database = try libraryDatabase(rig.runtime(), other);
    _ = try addUnreadableFile(other_database, &rig.verify.temporary, "other.wav", try addRelease(other_database, "B", null));
    rig.verify.acoustid.held.store(true, .release);
    try rig.enable(library);
    try rig.enable(other);

    rig.runtime().pump();
    _ = try rig.awaitLookups(1);
    rig.pumpFor(20);
    try std.testing.expectEqual(@as(usize, 1), rig.runtime().job_workers.items.len);
    const other_waiting = try rig.status(other);
    try std.testing.expectEqual(runtime_module.MaintenanceState.waiting, other_waiting.state);
    try std.testing.expectEqual(@as(?u64, 0), other_waiting.next_due_ms);
    while (rig.runtime().pollEvent()) |_| {}
    try std.testing.expectEqual(@as(?u64, runtime_jobs.job_progress_interval_ms), rig.runtime().nextPumpTimeoutMs());

    rig.verify.acoustid.held.store(false, .release);
    try std.testing.expectEqual(job.State.succeeded, (try rig.awaitUnits(library, 1)).state);
    try std.testing.expectEqual(job.State.succeeded, (try rig.awaitUnits(other, 1)).state);
    try std.testing.expectEqual(@as(usize, 2), rig.runtime().job_workers.items.len);
}

pub const northern_sky_lyrics =
    \\{"id":4242,"trackName":"Northern Sky","artistName":"Nick Drake","albumName":"Bryter Layter","duration":180.0,
    \\"instrumental":false,"plainLyrics":"I never felt magic crazy as this","syncedLyrics":"[00:12.00]I never felt magic crazy as this\n[00:18.50]I never saw moons knew the meaning of the sea"}
;

pub const FakeLrclib = struct {
    http: network.testing.ScriptedTransport = .{},
    clock: network.testing.TestClock = .{ .wall_offset_ms = 1_800_000_000_000 },
    status: u16 = 200,
    body: []const u8 = northern_sky_lyrics,
    retry_after_s: ?u64 = null,
    /// Requests from the next one on answered 503 before the status.
    outages: u32 = 0,

    pub fn hooks(self: *FakeLrclib) MatchingHooks {
        self.http.clock = &self.clock;
        self.http.keep_history = true;
        self.http.responder = .{ .context = self, .respond_fn = respond };
        return .{
            .transport = self.http.transport(),
            .clock = self.clock.clock(),
            .wall_clock = self.clock.wallClock(),
        };
    }

    pub fn deinit(self: *FakeLrclib) void {
        self.http.deinit();
    }

    pub fn requestCount(self: *const FakeLrclib) u32 {
        return self.http.requestCount();
    }

    fn respond(context: *anyopaque, _: network.testing.Exchange, _: ?network.testing.Reply) anyerror!network.testing.Reply {
        const self: *FakeLrclib = @ptrCast(@alignCast(context));
        if (self.outages > 0) {
            self.outages -= 1;
            return .{ .respond = .{ .status = 503, .body = "" } };
        }
        return .{ .respond = .{
            .status = self.status,
            .body = self.body,
            .rate_limit = if (self.retry_after_s) |seconds| .{ .retry_after = .{ .seconds = seconds } } else .{},
        } };
    }
};

const LyricsRun = struct {
    outcome: runtime_module.LyricsOutcome,
    lyrics: ?metadata.lyrics.Lyrics,

    fn deinit(self: LyricsRun) void {
        if (self.lyrics) |lyrics| lyrics.deinit();
    }
};

fn runLyrics(runtime: *OrcaRuntime, library: LibraryHandle, track_id: i64, fetch: bool) !LyricsRun {
    runtime.reapFinishedJobs();
    const handle = try runtime.startTrackLyrics(library, track_id, .{ .fetch = fetch });
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(runtime, handle));
    return .{ .outcome = try runtime.jobLyricsOutcome(handle), .lyrics = try runtime.jobTakeLyrics(handle) };
}

test "fetched LRCLIB lyrics are kept, and a second job, fetching or not, uses them without asking again" {
    var lrclib: FakeLrclib = .{};
    defer lrclib.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = lrclib.hooks();
    try std.testing.expectError(error.InvalidServerUrl, runtime.setLrclibServer("http://lrclib.net"));
    try runtime.setLrclibServer("https://lyrics.example/");
    const library = try runtime.openLibrary(std.testing.io, "file:orca-lyrics-fetched?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const track = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);

    try std.testing.expectError(error.ClientIdentityRequired, runtime.startTrackLyrics(library, track, .{ .fetch = true }));
    try runtime.setClientIdentity(network.testing.test_identity);

    const fetched = try runLyrics(&runtime, library, track, true);
    defer fetched.deinit();
    try std.testing.expectEqual(runtime_module.LyricsOutcome.fetched, fetched.outcome);
    try std.testing.expectEqual(metadata.lyrics.Source.lrclib, fetched.lyrics.?.source);
    try std.testing.expectEqual(metadata.lyrics.Kind.synced, fetched.lyrics.?.kind);
    try std.testing.expectEqual(@as(usize, 2), fetched.lyrics.?.lines.len);
    try std.testing.expectEqual(@as(u32, 1), lrclib.requestCount());
    try std.testing.expectEqualStrings(
        "https://lyrics.example/api/get?track_name=Northern%20Sky&artist_name=Nick%20Drake&album_name=Bryter%20Layter&duration=180",
        lrclib.http.lastUrl(),
    );
    try std.testing.expectStringStartsWith(lrclib.http.lastUserAgent(), "Orca/");
    const stored = (try library_database.track_lyrics.get(std.testing.allocator, track)).?;
    defer stored.deinit();
    try std.testing.expectEqual(@as(?i64, 4242), stored.record.lrclib_id);
    try std.testing.expectEqual(@divFloor(lrclib.clock.wallNow(), 1000), stored.fetched_at);

    for ([_]bool{ true, false }) |fetch| {
        const cached = try runLyrics(&runtime, library, track, fetch);
        defer cached.deinit();
        try std.testing.expectEqual(runtime_module.LyricsOutcome.cached, cached.outcome);
        try std.testing.expectEqual(@as(usize, 2), cached.lyrics.?.lines.len);
    }
    try std.testing.expectEqual(@as(u32, 1), lrclib.requestCount());
}

test "LRCLIB having no lyrics is not asked again for 7 days, and is asked after" {
    var lrclib: FakeLrclib = .{ .status = 404, .body = "{\"code\":404,\"name\":\"TrackNotFound\"}" };
    defer lrclib.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = lrclib.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-lyrics-miss?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const track = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);

    for ([_]runtime_module.LyricsOutcome{ .not_found, .cached_miss }) |expected| {
        const run = try runLyrics(&runtime, library, track, true);
        defer run.deinit();
        try std.testing.expectEqual(expected, run.outcome);
        try std.testing.expect(run.lyrics == null);
        try std.testing.expectEqual(@as(u32, 1), lrclib.requestCount());
    }
    const miss = (try library_database.track_lyrics.get(std.testing.allocator, track)).?;
    defer miss.deinit();
    try std.testing.expect(miss.record.isMiss());
    const offline = try runLyrics(&runtime, library, track, false);
    try std.testing.expectEqual(runtime_module.LyricsOutcome.not_found, offline.outcome);

    lrclib.clock.advance(7 * std.time.ms_per_day - 1000);
    const early = try runLyrics(&runtime, library, track, true);
    try std.testing.expectEqual(runtime_module.LyricsOutcome.cached_miss, early.outcome);

    lrclib.clock.advance(1000);
    lrclib.status = 200;
    lrclib.body = northern_sky_lyrics;
    const later = try runLyrics(&runtime, library, track, true);
    defer later.deinit();
    try std.testing.expectEqual(runtime_module.LyricsOutcome.fetched, later.outcome);
    try std.testing.expectEqual(@as(u32, 2), lrclib.requestCount());
}

test "an LRCLIB record without lyrics is not found unless it is instrumental, which gives no lines" {
    var lrclib: FakeLrclib = .{ .body = "{\"id\":1,\"instrumental\":false,\"plainLyrics\":null,\"syncedLyrics\":null}" };
    defer lrclib.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = lrclib.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-lyrics-instrumental?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const empty = try addMatchTrack(library_database, "Introduction", "Nick Drake", null);
    const instrumental = try addMatchTrack(library_database, "Bryter Layter", "Nick Drake", null);

    const nothing = try runLyrics(&runtime, library, empty, true);
    try std.testing.expectEqual(runtime_module.LyricsOutcome.not_found, nothing.outcome);
    try std.testing.expect(nothing.lyrics == null);

    lrclib.body = "{\"id\":2,\"instrumental\":true,\"plainLyrics\":null,\"syncedLyrics\":null}";
    const found = try runLyrics(&runtime, library, instrumental, true);
    defer found.deinit();
    try std.testing.expectEqual(runtime_module.LyricsOutcome.fetched, found.outcome);
    try std.testing.expectEqual(metadata.lyrics.Kind.instrumental, found.lyrics.?.kind);
    try std.testing.expectEqual(@as(usize, 0), found.lyrics.?.lines.len);
    const again = try runLyrics(&runtime, library, instrumental, false);
    defer again.deinit();
    try std.testing.expectEqual(runtime_module.LyricsOutcome.cached, again.outcome);
    try std.testing.expectEqual(metadata.lyrics.Kind.instrumental, again.lyrics.?.kind);
}

test "a lyrics fetch told to wait by LRCLIB is unavailable, and one inside the wait asks nothing" {
    var lrclib: FakeLrclib = .{ .status = 429, .body = "", .retry_after_s = 120 };
    defer lrclib.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = lrclib.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-lyrics-limited?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const track = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);

    for (0..2) |_| {
        const run = try runLyrics(&runtime, library, track, true);
        try std.testing.expectEqual(runtime_module.LyricsOutcome.unavailable, run.outcome);
        try std.testing.expect(run.lyrics == null);
        try std.testing.expectEqual(@as(u32, 1), lrclib.requestCount());
    }
    try std.testing.expect(try library_database.track_lyrics.get(std.testing.allocator, track) == null);
}

test "a lyrics fetch asks LRCLIB again after an outage, and three outages store nothing a later fetch would trust" {
    var lrclib: FakeLrclib = .{ .outages = 1 };
    defer lrclib.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = lrclib.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-lyrics-outage?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);
    const pink_moon = try addMatchTrack(library_database, "Pink Moon", "Nick Drake", null);

    const recovered = try runLyrics(&runtime, library, northern_sky, true);
    defer recovered.deinit();
    try std.testing.expectEqual(runtime_module.LyricsOutcome.fetched, recovered.outcome);
    try std.testing.expectEqual(@as(usize, 2), recovered.lyrics.?.lines.len);
    try std.testing.expectEqual(@as(u32, 2), lrclib.requestCount());
    try expectWaited(&lrclib.http, 1, 5_000);

    lrclib.outages = 3;
    const failed = try runLyrics(&runtime, library, pink_moon, true);
    try std.testing.expectEqual(runtime_module.LyricsOutcome.unavailable, failed.outcome);
    try std.testing.expect(failed.lyrics == null);
    try std.testing.expectEqual(@as(u32, 5), lrclib.requestCount());
    try std.testing.expect(try library_database.track_lyrics.get(std.testing.allocator, pink_moon) == null);

    const later = try runLyrics(&runtime, library, pink_moon, true);
    defer later.deinit();
    try std.testing.expectEqual(runtime_module.LyricsOutcome.fetched, later.outcome);
    try std.testing.expectEqual(@as(u32, 6), lrclib.requestCount());
}

test "a lyrics fetch waits for LRCLIB while another Gateway holds it, and is busy only once its deadline passes" {
    var lrclib: FakeLrclib = .{};
    defer lrclib.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = lrclib.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-lyrics-lease-wait?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const track = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);
    const other = try addMatchTrack(library_database, "Hazey Jane I", "Nick Drake", null);

    const holder: i64 = 99;
    const now = lrclib.clock.wallNow();
    try std.testing.expect(try library_database.provider_state.claimLease(providers.lrclib.service, holder, now, now + 10_000));
    const fetched = try runLyrics(&runtime, library, track, true);
    defer fetched.deinit();
    try std.testing.expectEqual(runtime_module.LyricsOutcome.fetched, fetched.outcome);
    try std.testing.expectEqual(@as(u32, 1), lrclib.requestCount());
    try std.testing.expect(lrclib.clock.wallNow() - now >= 10_000);

    const later = lrclib.clock.wallNow();
    try std.testing.expect(try library_database.provider_state.claimLease(providers.lrclib.service, holder, later, later + 10 * 60_000));
    const started_ms = lrclib.clock.now();
    const busy = try runLyrics(&runtime, library, other, true);
    defer busy.deinit();
    try std.testing.expectEqual(runtime_module.LyricsOutcome.busy, busy.outcome);
    try std.testing.expectEqual(@as(u32, 1), lrclib.requestCount());
    try std.testing.expect(lrclib.clock.now() - started_ms >= lyrics_fetch.fetch_deadline_ms);
    try std.testing.expect(lrclib.clock.now() - started_ms <= lyrics_fetch.fetch_deadline_ms + 1_000);
}

test "an edit to a Track's title asks LRCLIB again, and its old answer is not used meanwhile" {
    var lrclib: FakeLrclib = .{};
    defer lrclib.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = lrclib.hooks();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try runtime_tests.copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "b.flac");
    const library = try runtime_tests.scannedTempFolder(&runtime, &temporary, "file:orca-lyrics-edited?mode=memory&cache=shared");
    const ids = try runtime_tests.allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    const track = ids[0];
    (try runLyrics(&runtime, library, track, true)).deinit();
    try std.testing.expectEqual(@as(u32, 1), lrclib.requestCount());

    const edited = try runtime.libraryEditTracks(library, &.{track}, &.{.{ .field = .title, .value = "Northern Sky (Take 2)" }});
    defer edited.deinit();
    try std.testing.expectEqualSlices(i64, &.{track}, edited.ids);
    const unfetched = try runLyrics(&runtime, library, track, false);
    try std.testing.expectEqual(runtime_module.LyricsOutcome.not_found, unfetched.outcome);
    try std.testing.expect(unfetched.lyrics == null);

    const refetched = try runLyrics(&runtime, library, track, true);
    defer refetched.deinit();
    try std.testing.expectEqual(runtime_module.LyricsOutcome.fetched, refetched.outcome);
    try std.testing.expectEqual(@as(u32, 2), lrclib.requestCount());
    try std.testing.expect(std.mem.indexOf(u8, lrclib.http.lastUrl(), "track_name=Northern%20Sky%20%28Take%202%29&") != null);
}

test "a Track without a title or an artist asks LRCLIB nothing" {
    var lrclib: FakeLrclib = .{};
    defer lrclib.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = lrclib.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-lyrics-unnamed?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const no_artist = try addMatchTrack(library_database, "Northern Sky", " ", null);
    const no_title = try addMatchTrack(library_database, "", "Nick Drake", null);

    for ([_]i64{ no_artist, no_title }) |track| {
        const run = try runLyrics(&runtime, library, track, true);
        try std.testing.expectEqual(runtime_module.LyricsOutcome.no_metadata, run.outcome);
        try std.testing.expect(run.lyrics == null);
    }
    try std.testing.expectEqual(@as(u32, 0), lrclib.requestCount());
}

test "a Track's own synced lyrics ask LRCLIB nothing, and its own plain lyrics give way only to LRCLIB's synced ones" {
    var lrclib: FakeLrclib = .{};
    defer lrclib.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = lrclib.hooks();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try runtime_tests.copyFixtureInto(temporary.dir, "fixtures/audio/lyrics-synced.flac", "a.flac");
    try runtime_tests.copyFixtureInto(temporary.dir, "fixtures/audio/lyrics-plain.m4a", "b.m4a");
    const library = try runtime_tests.scannedTempFolder(&runtime, &temporary, "file:orca-lyrics-local?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const synced_track = try database.columns.scalar(library_database.database,
        \\SELECT tracks.id FROM tracks JOIN locations ON locations.file_id = tracks.preferred_file_id
        \\WHERE locations.uri LIKE '%/a.flac';
    );
    const plain_track = try database.columns.scalar(library_database.database,
        \\SELECT tracks.id FROM tracks JOIN locations ON locations.file_id = tracks.preferred_file_id
        \\WHERE locations.uri LIKE '%/b.m4a';
    );

    const own_synced = try runLyrics(&runtime, library, synced_track, true);
    defer own_synced.deinit();
    try std.testing.expectEqual(runtime_module.LyricsOutcome.local, own_synced.outcome);
    try std.testing.expectEqual(metadata.lyrics.Source.embedded, own_synced.lyrics.?.source);
    try std.testing.expectEqual(@as(u32, 0), lrclib.requestCount());

    lrclib.body = "{\"id\":5,\"instrumental\":false,\"plainLyrics\":\"Words from LRCLIB\",\"syncedLyrics\":null}";
    const own_plain = try runLyrics(&runtime, library, plain_track, true);
    defer own_plain.deinit();
    try std.testing.expectEqual(runtime_module.LyricsOutcome.fetched, own_plain.outcome);
    try std.testing.expectEqual(metadata.lyrics.Source.embedded, own_plain.lyrics.?.source);
    try std.testing.expectEqual(@as(u32, 1), lrclib.requestCount());
    const unfetched = try runLyrics(&runtime, library, plain_track, false);
    defer unfetched.deinit();
    try std.testing.expectEqual(runtime_module.LyricsOutcome.local, unfetched.outcome);

    const kept = (try library_database.track_lyrics.get(std.testing.allocator, plain_track)).?;
    kept.deinit();
    try std.testing.expect(try library_database.track_lyrics.put(plain_track, &kept.query_digest, .{
        .synced = "[00:03.00]Synced from LRCLIB",
    }, 0));
    const cached_synced = try runLyrics(&runtime, library, plain_track, false);
    defer cached_synced.deinit();
    try std.testing.expectEqual(runtime_module.LyricsOutcome.cached, cached_synced.outcome);
    try std.testing.expectEqual(metadata.lyrics.Source.lrclib, cached_synced.lyrics.?.source);
    try std.testing.expectEqual(metadata.lyrics.Kind.synced, cached_synced.lyrics.?.kind);
}

const amine_mbid = "12398bf3-1b99-47b7-930c-f3956773f35a";
const commons_thumbnail = "\x89PNG\r\n\x1a\nthumbnail";
const related_thumbnail = "\x89PNG\r\n\x1a\nrelated";
const saba_mbid = "d23f0824-128b-4f33-8c5c-7fd0a6a3a450";
const saba_item = "Q9000001";
const related_commons_body =
    \\{"query":{"pages":{"1":{"pageid":1,"ns":6,"title":"File:Related.jpg","imageinfo":[{
    \\"thumburl":"https://upload.wikimedia.org/related/thumb.png","url":"https://upload.wikimedia.org/related/full.png",
    \\"descriptionurl":"https://commons.wikimedia.org/wiki/File:Related.jpg","mime":"image/png",
    \\"extmetadata":{"LicenseShortName":{"value":"CC BY-SA 3.0"},
    \\"LicenseUrl":{"value":"https://creativecommons.org/licenses/by-sa/3.0"},
    \\"Artist":{"value":"<a href=\"https://commons.wikimedia.org/wiki/User:Related\">Related Photographer</a>"}}}]}}}}
;
const saba_entity =
    \\{"entities":{"Q9000001":{"id":"Q9000001","claims":{"P18":[{"mainsnak":{"snaktype":"value","property":"P18",
    \\"datavalue":{"value":"Related Saba.jpg","type":"string"}},"type":"statement","rank":"normal"}]},"sitelinks":{}}}}
;

const portland_area_id = "2b748d6e-bc1c-4434-9f7b-ecd6332bc557";
const portland_area =
    \\{"id":"2b748d6e-bc1c-4434-9f7b-ecd6332bc557","name":"Portland","type":"City","relations":[
    \\{"type":"part of","direction":"backward","target-type":"area","ended":false,
    \\"area":{"id":"6e9a5b1c-2d7f-4a3e-8c1b-0f4d2e6a8b10","name":"Oregon","type":"Subdivision"}}]}
;
const group_cover_jpeg = "\xff\xd8\xff\xe0JFIF group";

const FakeArtistInfo = struct {
    http: network.testing.ScriptedTransport = .{},
    clock: network.testing.TestClock = .{ .wall_offset_ms = 1_800_000_000_000 },
    musicbrainz: []u8 = &.{},
    wikidata: []u8 = &.{},
    commons: []u8 = &.{},
    wikipedia: []u8 = &.{},
    popularity: []u8 = &.{},
    similar: []u8 = &.{},
    release: []u8 = &.{},
    release_group: []u8 = &.{},
    release_group_browse: []u8 = &.{},
    musicbrainz_requests: std.atomic.Value(u32) = .init(0),
    wikidata_requests: std.atomic.Value(u32) = .init(0),
    commons_requests: std.atomic.Value(u32) = .init(0),
    image_requests: std.atomic.Value(u32) = .init(0),
    wikipedia_requests: std.atomic.Value(u32) = .init(0),
    popularity_requests: std.atomic.Value(u32) = .init(0),
    similar_requests: std.atomic.Value(u32) = .init(0),
    release_requests: std.atomic.Value(u32) = .init(0),
    release_group_requests: std.atomic.Value(u32) = .init(0),
    release_group_browse_requests: std.atomic.Value(u32) = .init(0),
    release_wikidata_requests: std.atomic.Value(u32) = .init(0),
    release_wikipedia_requests: std.atomic.Value(u32) = .init(0),
    related_musicbrainz_requests: std.atomic.Value(u32) = .init(0),
    related_wikidata_requests: std.atomic.Value(u32) = .init(0),
    related_commons_requests: std.atomic.Value(u32) = .init(0),
    related_image_requests: std.atomic.Value(u32) = .init(0),
    area_requests: std.atomic.Value(u32) = .init(0),
    group_cover_requests: std.atomic.Value(u32) = .init(0),
    /// A related artist whose MusicBrainz lookup answers 503.
    related_unavailable: ?[]const u8 = null,
    /// The Artist's own MusicBrainz lookups from the next one on answered 503.
    musicbrainz_outages: u32 = 0,
    /// When each of the Artist's own MusicBrainz lookups was sent.
    musicbrainz_times_ms: [8]i64 = @splat(0),
    /// Every MusicBrainz release lookup answers 503.
    releases_unavailable: bool = false,
    /// The release ID and send time of each release lookup.
    release_mbids: [8][36]u8 = undefined,
    release_times_ms: [8]i64 = @splat(0),
    /// A related artist MusicBrainz names no image or Wikidata item for.
    related_without_photo: ?[]const u8 = null,
    related_body: [512]u8 = undefined,
    stalled: bool = false,
    /// Related artists' lookups and release group covers wait while set.
    hold_extras: std.atomic.Value(bool) = .init(false),

    fn init(self: *FakeArtistInfo) !void {
        const dir = std.Io.Dir.cwd();
        const limit: std.Io.Limit = .limited(256 * 1024);
        self.musicbrainz = try dir.readFileAlloc(std.testing.io, "fixtures/providers/musicbrainz-artist-lookup.json", std.testing.allocator, limit);
        self.wikidata = try dir.readFileAlloc(std.testing.io, "fixtures/providers/wikidata-entity.json", std.testing.allocator, limit);
        self.commons = try dir.readFileAlloc(std.testing.io, "fixtures/providers/wikimedia-commons-imageinfo.json", std.testing.allocator, limit);
        self.wikipedia = try dir.readFileAlloc(std.testing.io, "fixtures/providers/wikipedia-summary.json", std.testing.allocator, limit);
        self.popularity = try dir.readFileAlloc(std.testing.io, "fixtures/providers/listenbrainz-popularity.json", std.testing.allocator, limit);
        self.similar = try dir.readFileAlloc(std.testing.io, "fixtures/providers/listenbrainz-labs-similar-artists.json", std.testing.allocator, limit);
        self.release = try dir.readFileAlloc(std.testing.io, "fixtures/providers/musicbrainz-release-lookup.json", std.testing.allocator, limit);
        self.release_group = try dir.readFileAlloc(std.testing.io, "fixtures/providers/musicbrainz-release-group-lookup.json", std.testing.allocator, limit);
        self.release_group_browse = try dir.readFileAlloc(std.testing.io, "fixtures/providers/musicbrainz-release-group-browse.json", std.testing.allocator, limit);
    }

    fn artistInfoRequests(self: *const FakeArtistInfo) u32 {
        return self.requestCount() - self.popularity_requests.load(.monotonic) - self.similar_requests.load(.monotonic) -
            self.release_group_browse_requests.load(.monotonic) - self.relatedPhotoRequests() -
            self.area_requests.load(.monotonic) - self.group_cover_requests.load(.monotonic);
    }

    fn relatedPhotoRequests(self: *const FakeArtistInfo) u32 {
        return self.related_musicbrainz_requests.load(.monotonic) + self.related_wikidata_requests.load(.monotonic) +
            self.related_commons_requests.load(.monotonic) + self.related_image_requests.load(.monotonic);
    }

    fn waitWhileHeld(self: *FakeArtistInfo) void {
        var deadline: runtime_tests.TestDeadline = .init(10_000);
        while (self.hold_extras.load(.acquire) and deadline.tick()) {}
    }

    fn respondRelatedArtist(self: *FakeArtistInfo, mbid: []const u8) !network.testing.Reply {
        self.waitWhileHeld();
        _ = self.related_musicbrainz_requests.fetchAdd(1, .monotonic);
        if (self.related_unavailable) |unavailable| if (std.mem.eql(u8, mbid, unavailable))
            return .{ .respond = .{ .status = 503, .body = "{}" } };
        const body = if (self.related_without_photo) |without| if (std.mem.eql(u8, mbid, without))
            try std.fmt.bufPrint(&self.related_body, "{{\"id\":\"{s}\",\"relations\":[]}}", .{mbid})
        else
            null else null;
        return .{ .respond = .{ .body = body orelse if (std.mem.eql(u8, mbid, saba_mbid))
            try std.fmt.bufPrint(&self.related_body,
                \\{{"id":"{s}","relations":[{{"type":"wikidata","target-type":"url","url":{{"resource":"https://www.wikidata.org/wiki/{s}"}}}}]}}
            , .{ mbid, saba_item })
        else
            try std.fmt.bufPrint(&self.related_body,
                \\{{"id":"{s}","relations":[{{"type":"image","target-type":"url","url":{{"resource":"https://commons.wikimedia.org/wiki/File:Related_{s}.jpg"}}}}]}}
            , .{ mbid, mbid }) } };
    }

    fn hooks(self: *FakeArtistInfo) MatchingHooks {
        self.http.clock = &self.clock;
        self.http.responder = .{ .context = self, .respond_fn = respond };
        return .{
            .transport = self.http.transport(),
            .clock = self.clock.clock(),
            .wall_clock = self.clock.wallClock(),
        };
    }

    fn deinit(self: *FakeArtistInfo) void {
        for ([_][]u8{
            self.musicbrainz, self.wikidata, self.commons,       self.wikipedia,            self.popularity,
            self.similar,     self.release,  self.release_group, self.release_group_browse,
        }) |body| std.testing.allocator.free(body);
        self.http.deinit();
    }

    fn requestCount(self: *const FakeArtistInfo) u32 {
        return self.http.requestCount();
    }

    fn respond(context: *anyopaque, exchange: network.testing.Exchange, _: ?network.testing.Reply) anyerror!network.testing.Reply {
        const self: *FakeArtistInfo = @ptrCast(@alignCast(context));
        if (self.stalled) {
            self.clock.advance(@intCast(exchange.request.timeout_ms));
            return .{ .fail = error.Timeout };
        }
        const url = exchange.request.url;
        const group_cover_prefix = "https://coverartarchive.org/release-group/";
        if (std.mem.startsWith(u8, url, group_cover_prefix) and url.len >= group_cover_prefix.len + 36) {
            self.waitWhileHeld();
            _ = self.group_cover_requests.fetchAdd(1, .monotonic);
            const last = url[group_cover_prefix.len + 35];
            return if (last == '1' or last == '3' or last == '5')
                .{ .respond = .{ .body = group_cover_jpeg } }
            else
                .{ .respond = .{ .status = 404, .body = "" } };
        }
        const artist_prefix = "https://musicbrainz.org/ws/2/artist/";
        if (std.mem.startsWith(u8, url, artist_prefix) and !std.mem.startsWith(u8, url, artist_prefix ++ amine_mbid) and
            url.len >= artist_prefix.len + 36)
            return self.respondRelatedArtist(url[artist_prefix.len..][0..36]);
        if (std.mem.startsWith(u8, url, artist_prefix ++ amine_mbid)) {
            const index = self.musicbrainz_requests.load(.monotonic);
            if (index < self.musicbrainz_times_ms.len) self.musicbrainz_times_ms[index] = self.clock.now();
            if (self.musicbrainz_outages > 0) {
                self.musicbrainz_outages -= 1;
                _ = self.musicbrainz_requests.fetchAdd(1, .monotonic);
                return .{ .respond = .{ .status = 503, .body = "{}" } };
            }
        }
        const release_prefix = "https://musicbrainz.org/ws/2/release/";
        if (std.mem.startsWith(u8, url, release_prefix) and url.len >= release_prefix.len + 36) {
            const index = self.release_requests.load(.monotonic);
            if (index < self.release_times_ms.len) {
                self.release_mbids[index] = url[release_prefix.len..][0..36].*;
                self.release_times_ms[index] = self.clock.now();
            }
            if (self.releases_unavailable) {
                _ = self.release_requests.fetchAdd(1, .monotonic);
                return .{ .respond = .{ .status = 503, .body = "{}" } };
            }
        }
        const counter: *std.atomic.Value(u32), const body: []const u8 = if (std.mem.startsWith(u8, url, artist_prefix))
            .{ &self.musicbrainz_requests, self.musicbrainz }
        else if (std.mem.startsWith(u8, url, "https://musicbrainz.org/ws/2/area/" ++ portland_area_id ++ "?"))
            .{ &self.area_requests, portland_area }
        else if (std.mem.startsWith(u8, url, "https://musicbrainz.org/ws/2/release/"))
            .{ &self.release_requests, self.release }
        else if (std.mem.startsWith(u8, url, "https://musicbrainz.org/ws/2/release-group?artist=" ++ amine_mbid ++ "&"))
            .{ &self.release_group_browse_requests, self.release_group_browse }
        else if (std.mem.startsWith(u8, url, "https://musicbrainz.org/ws/2/release-group/"))
            .{ &self.release_group_requests, self.release_group }
        else if (std.mem.startsWith(u8, url, "https://api.listenbrainz.org/1/popularity/artist"))
            .{ &self.popularity_requests, self.popularity }
        else if (std.mem.startsWith(u8, url, "https://labs.api.listenbrainz.org/similar-artists/json?"))
            .{ &self.similar_requests, self.similar }
        else if (std.mem.startsWith(u8, url, "https://www.wikidata.org/w/api.php?action=wbgetentities&ids=" ++ saba_item ++ "&"))
            .{ &self.related_wikidata_requests, saba_entity }
        else if (std.mem.startsWith(u8, url, "https://www.wikidata.org/w/api.php?action=wbgetentities&ids=" ++ hot_space_item ++ "&"))
            .{ &self.release_wikidata_requests, hot_space_entity }
        else if (std.mem.startsWith(u8, url, "https://www.wikidata.org/w/api.php?action=wbgetentities"))
            .{ &self.wikidata_requests, self.wikidata }
        else if (std.mem.startsWith(u8, url, "https://en.wikipedia.org/api/rest_v1/page/summary/Hot_Space"))
            .{ &self.release_wikipedia_requests, hot_space_summary }
        else if (std.mem.startsWith(u8, url, "https://commons.wikimedia.org/w/api.php?action=query&titles=File%3ARelated"))
            .{ &self.related_commons_requests, related_commons_body }
        else if (std.mem.startsWith(u8, url, "https://commons.wikimedia.org/w/api.php?action=query"))
            .{ &self.commons_requests, self.commons }
        else if (std.mem.startsWith(u8, url, "https://upload.wikimedia.org/related/"))
            .{ &self.related_image_requests, related_thumbnail }
        else if (std.mem.startsWith(u8, url, "https://upload.wikimedia.org/"))
            .{ &self.image_requests, commons_thumbnail }
        else if (std.mem.startsWith(u8, url, "https://en.wikipedia.org/api/rest_v1/page/summary/"))
            .{ &self.wikipedia_requests, self.wikipedia }
        else
            return .{ .respond = .{ .status = 404, .body = "{}" } };
        _ = counter.fetchAdd(1, .monotonic);
        return .{ .respond = .{ .body = body } };
    }
};

const hot_space_item = "Q1193613";
const hot_space_entity =
    \\{"entities":{"Q1193613":{"id":"Q1193613","claims":{},"sitelinks":{"enwiki":{"site":"enwiki","title":"Hot Space","url":"https://en.wikipedia.org/wiki/Hot_Space"}}}}}
;
const hot_space_summary =
    \\{"type":"standard","extract":"Hot Space is the tenth studio album by Queen.","content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Hot_Space"}}}
;

fn addAmine(library_database: *database.LibraryDatabase, root: []const u8, musicbrainz_artist_id: ?[]const u8) !i64 {
    const root_id = try library_database.library_roots.add(database.LibraryDatabase.null_volume, root);
    return addArtistAlbum(library_database, root_id, root, "Aminé", "Good for You", musicbrainz_artist_id);
}

fn addArtistAlbum(
    library_database: *database.LibraryDatabase,
    root_id: i64,
    root: []const u8,
    artist: []const u8,
    album: []const u8,
    musicbrainz_artist_id: ?[]const u8,
) !i64 {
    const uri = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}/{s}/01.flac", .{ root, artist, album });
    defer std.testing.allocator.free(uri);
    const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
    _ = try library_database.locations.upsert(.{
        .file_id = file_id,
        .volume_id = database.LibraryDatabase.null_volume,
        .root_id = root_id,
        .uri = uri,
        .state = .present,
    });
    try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = "One",
        .artist = artist,
        .album = album,
        .album_artist = artist,
        .musicbrainz_album_artist_id = musicbrainz_artist_id,
    } });
    try projectAll(library_database);
    var statement = try library_database.database.prepare("SELECT id FROM artists WHERE name = ?1;");
    defer statement.deinit();
    try statement.bindText(1, artist);
    try std.testing.expectEqual(database.sqlite.Step.row, try statement.step());
    return statement.columnInt64(0);
}

fn runArtistInfo(runtime: *OrcaRuntime, library: LibraryHandle, artist_id: i64, options: runtime_module.ArtistInfoOptions) !runtime_module.ArtistInfoOutcome {
    runtime.reapFinishedJobs();
    const handle = try runtime.startArtistInfoFetch(library, artist_id, options);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(runtime, handle));
    return runtime.jobArtistInfoOutcome(handle);
}

fn freeElsewhere(groups: []database.ElsewhereRelease) void {
    for (groups) |group| group.deinit(std.testing.allocator);
    std.testing.allocator.free(groups);
}

fn hasLink(links: database.ArtistLinks, kind: database.ArtistLinkKind, url: []const u8) bool {
    for (links.items) |link| if (link.kind == kind and std.mem.eql(u8, link.url, url)) return true;
    return false;
}

test "an Artist's photo, biography, years and links come from MusicBrainz, Wikidata, Commons and Wikipedia, and a second fetch asks nothing" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-fetched?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);

    try std.testing.expectError(error.ClientIdentityRequired, runtime.startArtistInfoFetch(library, artist, .{}));
    try runtime.setClientIdentity(network.testing.test_identity);
    try std.testing.expectError(error.UnknownArtist, runtime.startArtistInfoFetch(library, artist + 1000, .{}));
    try std.testing.expectError(error.InvalidLanguage, runtime.startArtistInfoFetch(library, artist, .{ .language = "en.evil.org/x" }));

    const started_s = @divFloor(fake.clock.wallNow(), 1000);
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 1), fake.musicbrainz_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), fake.wikidata_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), fake.commons_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), fake.image_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), fake.wikipedia_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 5), fake.artistInfoRequests());
    try std.testing.expectEqual(@as(u32, 1), fake.popularity_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), fake.similar_requests.load(.monotonic));

    var info = (try runtime.libraryArtistInfo(library, artist)).?;
    defer info.deinit();
    const record = &info.record;
    try std.testing.expectEqualStrings(amine_mbid, record.musicbrainz_artist_id.?);
    try std.testing.expectEqualStrings("Q27830860", record.wikidata_id.?);
    try std.testing.expectEqual(@as(?i32, 2014), record.begin_year);
    try std.testing.expectEqual(@as(?i32, null), record.end_year);
    try std.testing.expect(!record.ended);
    try std.testing.expectEqualStrings("Person", record.artist_type.?);
    try std.testing.expectEqual(database.ArtistPhotoSource.commons, record.photo_source.?);
    try std.testing.expectEqualStrings("CC BY 2.0", record.photo_licence.?);
    try std.testing.expectEqualStrings("https://creativecommons.org/licenses/by/2.0", record.photo_licence_url.?);
    try std.testing.expectEqualStrings("Example Photographer & friends", record.photo_credit.?);
    try std.testing.expectStringStartsWith(record.photo_url.?, "https://commons.wikimedia.org/wiki/File:");
    try std.testing.expectStringStartsWith(record.biography.?, "Adam Aminé Daniel");
    try std.testing.expectEqual(database.ArtistBiographySource.wikipedia, record.biography_source.?);
    try std.testing.expectEqualStrings("https://en.wikipedia.org/wiki/Amin%C3%A9_(rapper)", record.biography_url.?);
    try std.testing.expectEqualStrings("CC BY-SA 4.0", record.biography_licence.?);
    try std.testing.expectEqualStrings("en", record.biography_language.?);
    try std.testing.expectEqualStrings("en", record.requested_language.?);
    try std.testing.expectEqual(@backingInt(runtime_module.ArtistInfoOutcome.fetched), record.outcome);
    try std.testing.expectEqual(started_s, record.fetched_at);
    try std.testing.expectEqual(@as(?u64, 9025), record.listeners);
    var related = try runtime.libraryRelatedArtists(library, artist);
    defer related.deinit();
    try std.testing.expect(related.items.len > 0 and related.items.len <= database.related_artists_max);
    try std.testing.expectEqualStrings("Smino", related.items[0].name);
    try std.testing.expectEqual(@as(u32, 412), related.items[0].score);
    try std.testing.expectEqual(@as(?i64, null), related.items[0].library_artist_id);

    const photo = (try runtime.libraryArtistPhoto(library, artist)).?;
    defer photo.deinit();
    try std.testing.expectEqualStrings(commons_thumbnail, photo.bytes);
    try std.testing.expectEqualStrings("image/png", photo.mime_type);

    var links = try runtime.libraryArtistLinks(library, artist);
    defer links.deinit();
    try std.testing.expect(hasLink(links, .musicbrainz, "https://musicbrainz.org/artist/" ++ amine_mbid));
    try std.testing.expect(hasLink(links, .wikipedia, "https://en.wikipedia.org/wiki/Amin%C3%A9_(rapper)"));
    try std.testing.expect(links.items.len > 2);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.cached, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 5), fake.artistInfoRequests());

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{ .force = true }));
    try std.testing.expectEqual(@as(u32, 1), fake.musicbrainz_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 2), fake.image_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 6), fake.artistInfoRequests());

    fake.clock.advance(31 * std.time.ms_per_day);
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 2), fake.musicbrainz_requests.load(.monotonic));
}

test "an offline fetch makes no request, keeps the outcome offline, and keeps the photo already fetched" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-offline?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.offline, try runArtistInfo(&runtime, library, artist, .{ .offline = true }));
    try std.testing.expectEqual(@as(u32, 0), fake.artistInfoRequests());
    var first = (try runtime.libraryArtistInfo(library, artist)).?;
    defer first.deinit();
    try std.testing.expectEqual(@backingInt(runtime_module.ArtistInfoOutcome.offline), first.record.outcome);
    try std.testing.expectEqualStrings(amine_mbid, first.record.musicbrainz_artist_id.?);
    try std.testing.expect(first.record.photo_source == null);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 5), fake.artistInfoRequests());
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.offline, try runArtistInfo(&runtime, library, artist, .{ .force = true, .offline = true }));
    try std.testing.expectEqual(@as(u32, 5), fake.artistInfoRequests());
    var kept = (try runtime.libraryArtistInfo(library, artist)).?;
    defer kept.deinit();
    try std.testing.expectEqual(database.ArtistPhotoSource.commons, kept.record.photo_source.?);
    try std.testing.expectEqualStrings("CC BY 2.0", kept.record.photo_licence.?);
    try std.testing.expectStringStartsWith(kept.record.biography.?, "Adam Aminé Daniel");
    const photo = (try runtime.libraryArtistPhoto(library, artist)).?;
    defer photo.deinit();
    try std.testing.expectEqualStrings(commons_thumbnail, photo.bytes);
}

test "an image in the Artist's folder is the photo and Commons is not asked, and an Artist without a MusicBrainz ID asks nothing" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var music = std.testing.tmpDir(.{});
    defer music.cleanup();
    try music.dir.createDirPath(std.testing.io, "Aminé/Good for You");
    try music.dir.writeFile(std.testing.io, .{ .sub_path = "Aminé/artist.jpg", .data = "\xff\xd8\xff\xe0local" });
    try music.dir.writeFile(std.testing.io, .{ .sub_path = "Aminé/Good for You/folder.jpg", .data = "\xff\xd8\xff\xe0cover" });
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{music.sub_path});
    defer std.testing.allocator.free(root);

    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-local?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, root, amine_mbid);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 0), fake.commons_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), fake.image_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 3), fake.artistInfoRequests());
    var info = (try runtime.libraryArtistInfo(library, artist)).?;
    defer info.deinit();
    try std.testing.expectEqual(database.ArtistPhotoSource.local, info.record.photo_source.?);
    try std.testing.expect(info.record.photo_licence == null);
    try std.testing.expect(info.record.photo_credit == null);
    try std.testing.expect(info.record.biography != null);
    const photo = (try runtime.libraryArtistPhoto(library, artist)).?;
    defer photo.deinit();
    try std.testing.expectEqualStrings("\xff\xd8\xff\xe0local", photo.bytes);

    try library_database.database.exec("UPDATE artists SET musicbrainz_artist_id = NULL;");
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.no_musicbrainz_id, try runArtistInfo(&runtime, library, artist, .{ .force = true }));
    try std.testing.expectEqual(@as(u32, 3), fake.artistInfoRequests());
    var unidentified = (try runtime.libraryArtistInfo(library, artist)).?;
    defer unidentified.deinit();
    try std.testing.expectEqual(database.ArtistPhotoSource.local, unidentified.record.photo_source.?);
    try std.testing.expect(unidentified.record.musicbrainz_artist_id == null);
}

fn setReleaseDate(library_database: *database.LibraryDatabase, album: []const u8, date: []const u8) !void {
    var statement = try library_database.database.prepare("UPDATE releases SET release_date = ?2 WHERE title = ?1;");
    defer statement.deinit();
    try statement.bindText(1, album);
    try statement.bindText(2, date);
    try std.testing.expectEqual(database.sqlite.Step.done, try statement.step());
}

test "a Person without a Wikidata work period is active from their earliest Release in the Library, not from birth" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    const work_start = std.mem.indexOf(u8, fake.wikidata, "\"P2031\"").?;
    @memcpy(fake.wikidata[work_start + 1 ..][0..5], "P9999");
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-earliest-release?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);
    const root_id = try library_database.library_roots.add(database.LibraryDatabase.null_volume, "/nonexistent/orca-more");
    _ = try addArtistAlbum(library_database, root_id, "/nonexistent/orca-more", "Aminé", "Calling Brío", amine_mbid);
    try setReleaseDate(library_database, "Good for You", "2017-07-28");
    try setReleaseDate(library_database, "Calling Brío", "2016");

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 1), fake.wikidata_requests.load(.monotonic));
    var info = (try runtime.libraryArtistInfo(library, artist)).?;
    defer info.deinit();
    try std.testing.expectEqualStrings("Person", info.record.artist_type.?);
    try std.testing.expectEqual(@as(?i32, 2016), info.record.begin_year);
    try std.testing.expectEqual(@as(?i32, null), info.record.end_year);
    try std.testing.expect(!info.record.ended);
}

test "a Group is active from its MusicBrainz formation to its dissolution, whatever Wikidata's work period says" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    std.testing.allocator.free(fake.musicbrainz);
    fake.musicbrainz = try std.testing.allocator.dupe(u8,
        \\{"id":"12398bf3-1b99-47b7-930c-f3956773f35a","type":"Group",
        \\ "life-span":{"begin":"2004-09","end":"2019-05-01","ended":true},
        \\ "relations":[{"type":"wikidata","target-type":"url","url":{"resource":"https://www.wikidata.org/wiki/Q27830860"}}]}
    );
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-group?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);
    try setReleaseDate(library_database, "Good for You", "2017-07-28");

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 1), fake.wikidata_requests.load(.monotonic));
    var info = (try runtime.libraryArtistInfo(library, artist)).?;
    defer info.deinit();
    try std.testing.expectEqualStrings("Group", info.record.artist_type.?);
    try std.testing.expectEqual(@as(?i32, 2004), info.record.begin_year);
    try std.testing.expectEqual(@as(?i32, 2019), info.record.end_year);
    try std.testing.expect(info.record.ended);
}

test "a biography that fell back to English is reused for the language that was asked, and another language asks again" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-language?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{ .language = "fr" }));
    try std.testing.expectEqual(@as(u32, 1), fake.wikipedia_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 5), fake.artistInfoRequests());
    {
        var info = (try runtime.libraryArtistInfo(library, artist)).?;
        defer info.deinit();
        try std.testing.expectEqualStrings("en", info.record.biography_language.?);
        try std.testing.expectEqualStrings("fr", info.record.requested_language.?);
    }

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.cached, try runArtistInfo(&runtime, library, artist, .{ .language = "fr" }));
    try std.testing.expectEqual(@as(u32, 5), fake.artistInfoRequests());

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{ .language = "en" }));
    var english = (try runtime.libraryArtistInfo(library, artist)).?;
    defer english.deinit();
    try std.testing.expectEqualStrings("en", english.record.requested_language.?);
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.cached, try runArtistInfo(&runtime, library, artist, .{ .language = "en" }));
}

test "a loved Artist is listed and counted under the loved filter, newest love first, and its love and info survive reprojection" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-love?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const amine = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);
    const root_id = try library_database.library_roots.add(database.LibraryDatabase.null_volume, "/nonexistent/orca-other");
    const nick_drake = try addArtistAlbum(library_database, root_id, "/nonexistent/orca-other", "Nick Drake", "Pink Moon", null);
    _ = try addArtistAlbum(library_database, root_id, "/nonexistent/orca-other", "Beach House", "Bloom", null);

    try std.testing.expect(!try runtime.libraryArtistLoved(library, amine));
    const loved = try runtime.librarySetArtistLove(library, &.{ nick_drake, amine + 1000 }, true);
    try std.testing.expectEqual(@as(u32, 1), loved.updated);
    try std.testing.expectEqual(@as(u32, 1), loved.skipped);
    _ = try runtime.librarySetArtistLove(library, &.{amine}, true);
    var backdate = try library_database.database.prepare("UPDATE artist_loves SET loved_at = loved_at - 60 WHERE artist_id = ?1;");
    defer backdate.deinit();
    try backdate.bindInt64(1, nick_drake);
    try std.testing.expectEqual(database.sqlite.Step.done, try backdate.step());

    const query: database.ArtistQuery = .{ .loved_only = true, .sort = .recently_loved };
    try std.testing.expectEqual(@as(u64, 2), try runtime.libraryArtistCountMatching(library, query));
    {
        var page = try runtime.libraryArtistPage(library, query);
        defer page.deinit();
        try std.testing.expectEqual(@as(usize, 2), page.items.len);
        try std.testing.expectEqual(amine, page.items[0].id);
        try std.testing.expectEqual(nick_drake, page.items[1].id);
        try std.testing.expect(page.items[0].loved and page.items[1].loved);
    }
    var everyone = try runtime.libraryArtistPage(library, .{});
    defer everyone.deinit();
    try std.testing.expectEqual(@as(usize, 3), everyone.items.len);
    for (everyone.items) |summary| try std.testing.expectEqual(summary.id == amine or summary.id == nick_drake, summary.loved);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, amine, .{}));
    try projectAll(library_database);
    try std.testing.expect(try runtime.libraryArtistLoved(library, amine));
    try std.testing.expect(try runtime.libraryArtistLoved(library, nick_drake));
    var info = (try runtime.libraryArtistInfo(library, amine)).?;
    defer info.deinit();
    try std.testing.expectEqual(database.ArtistPhotoSource.commons, info.record.photo_source.?);

    const cleared = try runtime.librarySetArtistLove(library, &.{nick_drake}, false);
    try std.testing.expectEqual(@as(u32, 1), cleared.updated);
    try std.testing.expectEqual(@as(u64, 1), try runtime.libraryArtistCountMatching(library, query));
}

const hot_space_mbid = "047a4aae-27f8-4f2d-92fb-214fd8dc865a";

fn addHotSpaceTrack(library_database: *database.LibraryDatabase, root_id: i64, title: []const u8, genres: []const []const u8) !void {
    const uri = try std.fmt.allocPrint(std.testing.allocator, "/nonexistent/orca-queen/Hot Space/{s}.flac", .{title});
    defer std.testing.allocator.free(uri);
    const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
    _ = try library_database.locations.upsert(.{
        .file_id = file_id,
        .volume_id = database.LibraryDatabase.null_volume,
        .root_id = root_id,
        .uri = uri,
        .state = .present,
    });
    try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = title,
        .artist = "Queen",
        .album = "Hot Space",
        .album_artist = "Queen",
        .genres = genres,
        .musicbrainz_release_id = hot_space_mbid,
    } });
    try projectAll(library_database);
}

fn trackTitled(library_database: *database.LibraryDatabase, title: []const u8) !i64 {
    var statement = try library_database.database.prepare("SELECT id FROM tracks WHERE title = ?1;");
    defer statement.deinit();
    try statement.bindText(1, title);
    try std.testing.expectEqual(database.sqlite.Step.row, try statement.step());
    return statement.columnInt64(0);
}

fn runReleaseInfo(runtime: *OrcaRuntime, library: LibraryHandle, release_id: i64, options: runtime_module.ReleaseInfoOptions) !runtime_module.ReleaseInfoOutcome {
    runtime.reapFinishedJobs();
    const handle = try runtime.startReleaseInfoFetch(library, release_id, options);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(runtime, handle));
    return runtime.jobReleaseInfoOutcome(handle);
}

fn expectTrackGenres(runtime: *OrcaRuntime, library: LibraryHandle, track_id: i64, provenance: metadata.Provenance, expected: []const []const u8) !void {
    const genres = try runtime.libraryTrackGenres(library, track_id);
    defer genres.deinit();
    try std.testing.expectEqual(expected.len, genres.items.len);
    for (genres.items, expected) |genre, name| {
        try std.testing.expect(std.ascii.eqlIgnoreCase(name, genre.name));
        try std.testing.expectEqual(provenance, genre.provenance);
    }
}

fn hotSpaceRelease(library_database: *database.LibraryDatabase) !i64 {
    var statement = try library_database.database.prepare("SELECT id FROM releases WHERE title = 'Hot Space';");
    defer statement.deinit();
    try std.testing.expectEqual(database.sqlite.Step.row, try statement.step());
    return statement.columnInt64(0);
}

test "a Release's description comes from its release group's Wikipedia article, and its MusicBrainz genres go only on Tracks with none from a file or an edit" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-release-info?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const root_id = try library_database.library_roots.add(database.LibraryDatabase.null_volume, "/nonexistent/orca-queen");
    try addHotSpaceTrack(library_database, root_id, "Staying Power", &.{});
    try addHotSpaceTrack(library_database, root_id, "Dancer", &.{"Jazz"});
    try addHotSpaceTrack(library_database, root_id, "Back Chat", &.{});
    const bare = try trackTitled(library_database, "Staying Power");
    const tagged = try trackTitled(library_database, "Dancer");
    const edited = try trackTitled(library_database, "Back Chat");
    try runtime.librarySetTrackGenres(library, &.{edited}, &.{"Disco"});
    const release = try hotSpaceRelease(library_database);

    try std.testing.expectError(error.ClientIdentityRequired, runtime.startReleaseInfoFetch(library, release, .{}));
    try runtime.setClientIdentity(network.testing.test_identity);
    try std.testing.expectError(error.UnknownRelease, runtime.startReleaseInfoFetch(library, release + 1000, .{}));
    try std.testing.expect((try runtime.libraryGenreFill(library)).musicbrainz);
    try std.testing.expectEqual(@as(?database.ReleaseInfo, null), try runtime.libraryReleaseInfo(library, release));

    try std.testing.expectEqual(runtime_module.ReleaseInfoOutcome.offline, try runReleaseInfo(&runtime, library, release, .{ .offline = true }));
    try std.testing.expectEqual(@as(u32, 0), fake.requestCount());

    try std.testing.expectEqual(runtime_module.ReleaseInfoOutcome.fetched, try runReleaseInfo(&runtime, library, release, .{}));
    try std.testing.expectEqual(@as(u32, 1), fake.release_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), fake.release_group_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), fake.release_wikidata_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), fake.release_wikipedia_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 4), fake.requestCount());
    {
        var info = (try runtime.libraryReleaseInfo(library, release)).?;
        defer info.deinit();
        const record = &info.record;
        try std.testing.expectEqualStrings("Hot Space is the tenth studio album by Queen.", record.description.?);
        try std.testing.expectEqual(database.ReleaseDescriptionSource.wikipedia, record.description_source.?);
        try std.testing.expectEqualStrings("https://en.wikipedia.org/wiki/Hot_Space", record.description_url.?);
        try std.testing.expectEqualStrings(providers.wikipedia.licence, record.description_licence.?);
        try std.testing.expectEqualStrings("en", record.description_language.?);
        try std.testing.expectEqualStrings(hot_space_mbid, record.musicbrainz_release_id.?);
        try std.testing.expectEqualStrings("3918b90b-340e-3779-9d7e-ba1593653498", record.musicbrainz_release_group_id.?);
        try std.testing.expectEqual(@backingInt(runtime_module.ReleaseInfoOutcome.fetched), record.outcome);
    }
    try expectTrackGenres(&runtime, library, bare, .provider, &.{ "rock", "funk", "pop rock", "synth-pop" });
    try expectTrackGenres(&runtime, library, tagged, .observed_file, &.{"Jazz"});
    try expectTrackGenres(&runtime, library, edited, .user, &.{"Disco"});
    try runtime_tests.expectGenreTotalsInSync(library_database);

    try std.testing.expectEqual(runtime_module.ReleaseInfoOutcome.cached, try runReleaseInfo(&runtime, library, release, .{}));
    try std.testing.expectEqual(@as(u32, 4), fake.requestCount());

    try runtime.setGenreFill(library, .{ .musicbrainz = false });
    try std.testing.expect(!(try runtime.libraryGenreFill(library)).musicbrainz);
    try addHotSpaceTrack(library_database, root_id, "Cool Cat", &.{});
    try std.testing.expectEqual(runtime_module.ReleaseInfoOutcome.fetched, try runReleaseInfo(&runtime, library, release, .{ .force = true }));
    try expectTrackGenres(&runtime, library, try trackTitled(library_database, "Cool Cat"), .provider, &.{});

    runtime.reapFinishedJobs();
    try std.testing.expectError(error.InvalidLimit, runtime.startGenreFill(library, .{ .limit = 0 }));
    const fill = try runtime.startGenreFill(library, .{ .limit = 1 });
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, fill));
    try std.testing.expectEqual(runtime_module.ReleaseInfoOutcome.fetched, try runtime.jobReleaseInfoOutcome(fill));
    try expectTrackGenres(&runtime, library, try trackTitled(library_database, "Cool Cat"), .provider, &.{ "rock", "funk", "pop rock", "synth-pop" });
    try expectTrackGenres(&runtime, library, try trackTitled(library_database, "Staying Power"), .provider, &.{ "rock", "funk", "pop rock", "synth-pop" });
    try expectTrackGenres(&runtime, library, try trackTitled(library_database, "Dancer"), .observed_file, &.{"Jazz"});
    try expectTrackGenres(&runtime, library, try trackTitled(library_database, "Back Chat"), .user, &.{"Disco"});
    try runtime_tests.expectGenreTotalsInSync(library_database);
}

fn releaseType(library_database: *database.LibraryDatabase, release_id: i64) !?[]const u8 {
    var statement = try library_database.database.prepare("SELECT release_type FROM releases WHERE id = ?1;");
    defer statement.deinit();
    try statement.bindInt64(1, release_id);
    try std.testing.expectEqual(database.sqlite.Step.row, try statement.step());
    if (statement.columnIsNull(0)) return null;
    return try std.testing.allocator.dupe(u8, statement.columnText(0));
}

fn expectReleaseType(library_database: *database.LibraryDatabase, release_id: i64, expected: ?[]const u8) !void {
    const stored = try releaseType(library_database, release_id);
    defer if (stored) |text| std.testing.allocator.free(text);
    if (expected) |text| try std.testing.expectEqualStrings(text, stored orelse return error.TestExpectedEqual) else try std.testing.expectEqual(@as(?[]const u8, null), stored);
}

test "a release fetch fills a Release's unknown type from its release group, and a type its files state outranks it" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-release-type?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const root_id = try library_database.library_roots.add(database.LibraryDatabase.null_volume, "/nonexistent/orca-queen");
    try addHotSpaceTrack(library_database, root_id, "Staying Power", &.{});
    const release = try hotSpaceRelease(library_database);
    try expectReleaseType(library_database, release, null);

    try std.testing.expectEqual(runtime_module.ReleaseInfoOutcome.fetched, try runReleaseInfo(&runtime, library, release, .{}));
    try expectReleaseType(library_database, release, "album");
    try std.testing.expectEqual(@as(u64, 1), try runtime.libraryReleaseCountMatching(library, .{ .release_kind = .album }));

    const file_id = (try library_database.tracks.fileIds(std.testing.allocator, try trackTitled(library_database, "Staying Power")));
    defer std.testing.allocator.free(file_id);
    try library_database.observed_tags.upsert(.{ .file_id = file_id[0], .values = .{
        .title = "Staying Power",
        .artist = "Queen",
        .album = "Hot Space",
        .album_artist = "Queen",
        .musicbrainz_release_id = hot_space_mbid,
        .release_type = "EP; Remix",
    } });
    try projectAll(library_database);
    try expectReleaseType(library_database, release, "ep");
    try std.testing.expectEqual(runtime_module.ReleaseInfoOutcome.fetched, try runReleaseInfo(&runtime, library, release, .{ .force = true }));
    try expectReleaseType(library_database, release, "ep");
    try std.testing.expectEqual(@as(u64, 1), try runtime.libraryReleaseCountMatching(library, .{ .release_kind = .ep_or_single }));
    try std.testing.expectEqual(@as(u64, 0), try runtime.libraryReleaseCountMatching(library, .{ .release_kind = .album }));
}

test "an Artist fetch fills the Artist's Tracks that have no genre, records listeners and related artists weekly, and a failed ListenBrainz step keeps the rest" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-listenbrainz?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);
    var track_statement = try library_database.database.prepare("SELECT id FROM tracks WHERE artist_id = ?1;");
    defer track_statement.deinit();
    try track_statement.bindInt64(1, artist);
    try std.testing.expectEqual(database.sqlite.Step.row, try track_statement.step());
    const track = track_statement.columnInt64(0);

    fake.popularity = blk: {
        std.testing.allocator.free(fake.popularity);
        break :blk try std.testing.allocator.dupe(u8, "not json");
    };
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.refused, try runArtistInfo(&runtime, library, artist, .{}));
    try expectTrackGenres(&runtime, library, track, .provider, &.{ "hip hop", "hip house", "pop", "pop rap", "trap" });
    {
        var info = (try runtime.libraryArtistInfo(library, artist)).?;
        defer info.deinit();
        try std.testing.expectStringStartsWith(info.record.biography.?, "Adam Aminé Daniel");
        try std.testing.expectEqual(@as(?u64, null), info.record.listeners);
        try std.testing.expectEqual(@as(?i64, null), info.record.listeners_fetched_at);
        var related = try runtime.libraryRelatedArtists(library, artist);
        defer related.deinit();
        try std.testing.expect(related.items.len > 0);
    }

    std.testing.allocator.free(fake.popularity);
    fake.popularity = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/providers/listenbrainz-popularity.json", std.testing.allocator, .limited(64 * 1024));
    const before = fake.popularity_requests.load(.monotonic);
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.cached, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(before + 1, fake.popularity_requests.load(.monotonic));
    {
        var info = (try runtime.libraryArtistInfo(library, artist)).?;
        defer info.deinit();
        try std.testing.expectEqual(@as(?u64, 9025), info.record.listeners);
    }
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.cached, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(before + 1, fake.popularity_requests.load(.monotonic));
    fake.clock.advance(8 * std.time.ms_per_day);
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.cached, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(before + 2, fake.popularity_requests.load(.monotonic));
}

fn expectRelatedPhotos(runtime: *OrcaRuntime, library: LibraryHandle, artist: i64, expected: usize) !void {
    var related = try runtime.libraryRelatedArtists(library, artist);
    defer related.deinit();
    var with_photo: usize = 0;
    for (related.items) |item| {
        try std.testing.expect(item.library_artist_id == null);
        if (item.has_photo) with_photo += 1;
    }
    try std.testing.expectEqual(expected, with_photo);
}

test "an Artist fetch keeps photos with their Commons licence and credit for at most eight related artists outside the Library, the next fetch finishes the rest, and a forced fetch keeps them" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-related-photos?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 5), fake.artistInfoRequests());
    try std.testing.expectEqual(@as(u32, 8), fake.related_musicbrainz_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), fake.related_wikidata_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 8), fake.related_commons_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 8), fake.related_image_requests.load(.monotonic));
    try expectRelatedPhotos(&runtime, library, artist, 8);
    {
        const photo = (try runtime.libraryRelatedArtistPhoto(library, "D23F0824-128B-4F33-8C5C-7FD0A6A3A450")).?;
        defer photo.deinit();
        try std.testing.expectEqualStrings(related_thumbnail, photo.bytes);
        try std.testing.expectEqualStrings("image/png", photo.mime_type);
        var photo_info = (try runtime.libraryRelatedArtistPhotoInfo(library, saba_mbid)).?;
        defer photo_info.deinit();
        try std.testing.expectEqual(database.ArtistPhotoSource.commons, photo_info.record.source);
        try std.testing.expectEqualStrings("https://commons.wikimedia.org/wiki/File:Related.jpg", photo_info.record.url.?);
        try std.testing.expectEqualStrings("CC BY-SA 3.0", photo_info.record.licence.?);
        try std.testing.expectEqualStrings("https://creativecommons.org/licenses/by-sa/3.0", photo_info.record.licence_url.?);
        try std.testing.expectEqualStrings("Related Photographer", photo_info.record.credit.?);
    }
    try std.testing.expect(try runtime.libraryRelatedArtistPhotoInfo(library, amine_mbid) == null);
    try std.testing.expect(try runtime.libraryRelatedArtistPhoto(library, amine_mbid) == null);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.cached, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 12), fake.related_musicbrainz_requests.load(.monotonic));
    try expectRelatedPhotos(&runtime, library, artist, 12);
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.cached, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 12), fake.related_musicbrainz_requests.load(.monotonic));

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{ .force = true }));
    try expectRelatedPhotos(&runtime, library, artist, 12);
}

test "a related artist with no photo is remembered and not asked again until the photo is thirty days old, and offline asks nothing" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-related-photo-none?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.offline, try runArtistInfo(&runtime, library, artist, .{ .offline = true }));
    try std.testing.expectEqual(@as(u32, 0), fake.requestCount());
    try expectRelatedPhotos(&runtime, library, artist, 0);

    fake.related_without_photo = saba_mbid;
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 8), fake.related_musicbrainz_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), fake.related_wikidata_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 7), fake.related_commons_requests.load(.monotonic));
    try expectRelatedPhotos(&runtime, library, artist, 7);
    try std.testing.expect(try runtime.libraryRelatedArtistPhoto(library, saba_mbid) == null);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.cached, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 12), fake.related_musicbrainz_requests.load(.monotonic));
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.cached, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 12), fake.related_musicbrainz_requests.load(.monotonic));
    try expectRelatedPhotos(&runtime, library, artist, 11);

    const requests = fake.requestCount();
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.offline, try runArtistInfo(&runtime, library, artist, .{ .force = true, .offline = true }));
    try std.testing.expectEqual(requests, fake.requestCount());
    try expectRelatedPhotos(&runtime, library, artist, 11);

    fake.related_without_photo = null;
    fake.clock.advance(31 * std.time.ms_per_day);
    _ = try runArtistInfo(&runtime, library, artist, .{});
    try std.testing.expectEqual(@as(u32, 20), fake.related_musicbrainz_requests.load(.monotonic));
    const photo = (try runtime.libraryRelatedArtistPhoto(library, saba_mbid)).?;
    defer photo.deinit();
    try std.testing.expectEqualStrings(related_thumbnail, photo.bytes);
}

test "a related artist whose lookup fails leaves the other related artists' photos and is asked again on the next fetch" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = fake.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-related-photo-failure?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);

    fake.related_unavailable = saba_mbid;
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 7), fake.related_image_requests.load(.monotonic));
    try expectRelatedPhotos(&runtime, library, artist, 7);
    try std.testing.expect(try runtime.libraryRelatedArtistPhoto(library, saba_mbid) == null);

    fake.related_unavailable = null;
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.cached, try runArtistInfo(&runtime, library, artist, .{}));
    try expectRelatedPhotos(&runtime, library, artist, 12);
    const photo = (try runtime.libraryRelatedArtistPhoto(library, saba_mbid)).?;
    defer photo.deinit();
    try std.testing.expectEqualStrings(related_thumbnail, photo.bytes);
}

test "an Artist's fetch stores its origin and release groups in one browse, a second fetch asks nothing, and Elsewhere lists the albums and EPs the library does not have" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-elsewhere?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 1), fake.release_group_browse_requests.load(.monotonic));
    var info = (try runtime.libraryArtistInfo(library, artist)).?;
    defer info.deinit();
    try std.testing.expectEqualStrings("Portland, Oregon", info.record.origin.?);
    try std.testing.expectEqual(@as(u32, 1), fake.area_requests.load(.monotonic));

    const all = try runtime.libraryArtistElsewhere(library, std.testing.allocator, artist);
    defer freeElsewhere(all);
    try std.testing.expectEqual(@as(usize, 4), all.len);
    try std.testing.expectEqualStrings("KAYTRAMINÉ", all[0].title);
    try std.testing.expectEqualStrings("Kaytranada", all[0].credited_with.?);

    try library_database.database.exec(
        \\UPDATE observed_file_tags SET musicbrainz_release_group_id = '0C1F6A8E-3D5B-4C2A-9E7F-1A2B3C4D5E01';
    );
    const elsewhere = try runtime.libraryArtistElsewhere(library, std.testing.allocator, artist);
    defer freeElsewhere(elsewhere);
    try std.testing.expectEqual(@as(usize, 3), elsewhere.len);
    for (elsewhere) |group| try std.testing.expect(!std.mem.eql(u8, group.title, "Good for You"));

    const requests = fake.artistInfoRequests();
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.cached, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(requests, fake.artistInfoRequests());
    try std.testing.expectEqual(@as(u32, 1), fake.release_group_browse_requests.load(.monotonic));
}

const CoverCounts = struct { kept: usize = 0, none: usize = 0, not_fetched: usize = 0 };

fn elsewhereCovers(runtime: *OrcaRuntime, library: LibraryHandle, artist: i64) !CoverCounts {
    const groups = try runtime.libraryArtistElsewhere(library, std.testing.allocator, artist);
    defer freeElsewhere(groups);
    var counts: CoverCounts = .{};
    for (groups) |group| switch (group.cover) {
        .kept => counts.kept += 1,
        .none => counts.none += 1,
        .not_fetched => counts.not_fetched += 1,
    };
    return counts;
}

fn releaseGroupBrowse(allocator: std.mem.Allocator, count: usize, first: usize, single_every: usize) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(allocator);
    errdefer body.deinit();
    try body.writer.writeAll("{\"release-group-count\":");
    try body.writer.print("{d},\"release-group-offset\":0,\"release-groups\":[", .{count});
    for (0..count) |index| {
        if (index != 0) try body.writer.writeAll(",");
        try body.writer.print(
            \\{{"id":"0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d{d:0>4}","title":"Group {d}","primary-type":"{s}",
            \\"secondary-types":[],"first-release-date":"{d}-01-01","artist-credit":[{{"name":"Aminé","joinphrase":"",
            \\"artist":{{"id":"{s}","name":"Aminé"}}}}]}}
        , .{ first + index, first + index, if (single_every != 0 and index % single_every == single_every - 1) "Single" else "Album", 2050 - first - index, amine_mbid });
    }
    try body.writer.writeAll("]}");
    return body.toOwnedSlice();
}

test "an Artist's fetch keeps the release group covers the Cover Art Archive has, and neither a second fetch nor a forced one asks it or MusicBrainz's areas again" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-group-covers?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);

    _ = try runArtistInfo(&runtime, library, artist, .{ .offline = true });
    try std.testing.expectEqual(@as(u32, 0), fake.group_cover_requests.load(.monotonic));

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 4), fake.group_cover_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), fake.area_requests.load(.monotonic));
    try std.testing.expectEqual(CoverCounts{ .kept = 2, .none = 2 }, try elsewhereCovers(&runtime, library, artist));

    const subject: runtime_module.ArtworkSubject = .{ .release_group = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e03".* };
    const request = try runtime.libraryRequestArtwork(library, std.testing.io, subject);
    const result = while (true) {
        if (runtime.libraryTakeArtwork(library)) |result| break result;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    };
    try std.testing.expectEqual(request, result.request);
    const image = result.image.?;
    defer image.deinit();
    try std.testing.expectEqualStrings(group_cover_jpeg, image.bytes);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.cached, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{ .force = true }));
    try std.testing.expectEqual(@as(u32, 4), fake.group_cover_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), fake.area_requests.load(.monotonic));
    var info = (try runtime.libraryArtistInfo(library, artist)).?;
    defer info.deinit();
    try std.testing.expectEqualStrings("Portland, Oregon", info.record.origin.?);
}

test "a release group the Cover Art Archive has no cover for is kept as none and asked about again only after 30 days" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-group-cover-miss?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    const miss = (try library_database.artist_info.releaseGroupCoverMark("0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e02")).?;
    try std.testing.expect(!miss.has_image);
    try std.testing.expect(try library_database.artist_info.releaseGroupCover(std.testing.allocator, "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e02") == null);

    fake.clock.advance(29 * std.time.ms_per_day);
    _ = try runArtistInfo(&runtime, library, artist, .{ .force = true });
    try std.testing.expectEqual(@as(u32, 4), fake.group_cover_requests.load(.monotonic));

    fake.clock.advance(2 * std.time.ms_per_day);
    _ = try runArtistInfo(&runtime, library, artist, .{});
    try std.testing.expectEqual(@as(u32, 4 + 2), fake.group_cover_requests.load(.monotonic));
    try std.testing.expectEqual(CoverCounts{ .kept = 2, .none = 2 }, try elsewhereCovers(&runtime, library, artist));
}

test "an Artist's fetch asks the Cover Art Archive about every album and EP Elsewhere lists, newest first, none of the singles, and nothing more on the next fetch" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    std.testing.allocator.free(fake.release_group_browse);
    fake.release_group_browse = try releaseGroupBrowse(std.testing.allocator, 40, 0, 5);
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-group-cover-all?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 32), fake.group_cover_requests.load(.monotonic));
    const groups = try runtime.libraryArtistElsewhere(library, std.testing.allocator, artist);
    defer freeElsewhere(groups);
    try std.testing.expectEqual(@as(usize, 32), groups.len);
    for (groups) |group| {
        try std.testing.expectEqualStrings("Album", group.primary_type.?);
        try std.testing.expect(group.cover != .not_fetched);
    }
    try std.testing.expectEqual(@as(i64, 32), try database.columns.scalar(library_database.database, "SELECT count(*) FROM release_group_covers;"));
    try std.testing.expectEqual(@as(i64, 0), try database.columns.scalar(
        library_database.database,
        "SELECT count(*) FROM release_group_covers WHERE mbid IN (SELECT mbid FROM artist_release_groups WHERE primary_type = 'Single');",
    ));

    _ = try runArtistInfo(&runtime, library, artist, .{});
    try std.testing.expectEqual(@as(u32, 32), fake.group_cover_requests.load(.monotonic));
}

test "an Artist's fetch from services that stop answering ends by its deadline with outcome unavailable" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-stalled?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));

    fake.stalled = true;
    const started_ms = fake.clock.now();
    const requests_before = fake.requestCount();
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.unavailable, try runArtistInfo(&runtime, library, artist, .{ .force = true }));
    try std.testing.expect(fake.clock.now() - started_ms <= artist_info.fetch_deadline_ms);
    try std.testing.expect(fake.requestCount() - requests_before <= 2);
}

test "an Artist's fetch that MusicBrainz could not answer three times stores nothing a later fetch trusts, and one outage costs about 5 s" {
    var fake: FakeArtistInfo = .{ .musicbrainz_outages = 3 };
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-outage?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.unavailable, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 3), fake.musicbrainz_requests.load(.monotonic));

    fake.musicbrainz_outages = 1;
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 5), fake.musicbrainz_requests.load(.monotonic));
    const waited = fake.musicbrainz_times_ms[4] - fake.musicbrainz_times_ms[3];
    try std.testing.expect(waited >= 2_500 and waited <= 7_500);
    var info = (try runtime.libraryArtistInfo(library, artist)).?;
    defer info.deinit();
    try std.testing.expectEqualStrings("Q27830860", info.record.wikidata_id.?);
}

fn addAmineRelease(library_database: *database.LibraryDatabase, root_id: i64, album: []const u8, release_mbid: []const u8) !i64 {
    const uri = try std.fmt.allocPrint(std.testing.allocator, "/nonexistent/orca-music/Aminé/{s}/01.flac", .{album});
    defer std.testing.allocator.free(uri);
    const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
    _ = try library_database.locations.upsert(.{
        .file_id = file_id,
        .volume_id = database.LibraryDatabase.null_volume,
        .root_id = root_id,
        .uri = uri,
        .state = .present,
    });
    try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = "One",
        .artist = "Aminé",
        .album = album,
        .album_artist = "Aminé",
        .musicbrainz_album_artist_id = amine_mbid,
        .musicbrainz_release_id = release_mbid,
    } });
    try projectAll(library_database);
    var statement = try library_database.database.prepare("SELECT id FROM releases WHERE title = ?1;");
    defer statement.deinit();
    try statement.bindText(1, album);
    try std.testing.expectEqual(database.sqlite.Step.row, try statement.step());
    return statement.columnInt64(0);
}

test "an Artist's fetch with its Releases stops at the first Release MusicBrainz could not answer, and a later fetch asks the rest" {
    var fake: FakeArtistInfo = .{ .releases_unavailable = true };
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-releases-outage?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const root_id = try library_database.library_roots.add(database.LibraryDatabase.null_volume, "/nonexistent/orca-music");
    const release_mbids = [_][]const u8{
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222",
        "33333333-3333-4333-8333-333333333333",
    };
    var releases: [release_mbids.len]i64 = undefined;
    for (&releases, release_mbids, [_][]const u8{ "Good for You", "OnePointFive", "Limbo" }) |*release, release_mbid, album|
        release.* = try addAmineRelease(library_database, root_id, album, release_mbid);
    var statement = try library_database.database.prepare("SELECT album_artist_id FROM releases WHERE id = ?1;");
    defer statement.deinit();
    try statement.bindInt64(1, releases[0]);
    try std.testing.expectEqual(database.sqlite.Step.row, try statement.step());
    const artist = statement.columnInt64(0);

    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.unavailable, try runArtistInfo(&runtime, library, artist, .{ .include_releases = true }));
    try std.testing.expectEqual(@as(u32, 3), fake.release_requests.load(.monotonic));
    for (fake.release_mbids[0..3]) |*sent| try std.testing.expectEqualStrings(release_mbids[0], sent);
    try expectJittered(fake.release_times_ms[1] - fake.release_times_ms[0], 5_000);
    try expectJittered(fake.release_times_ms[2] - fake.release_times_ms[1], 30_000);
    try std.testing.expectEqual(@as(?database.ReleaseInfo, null), try runtime.libraryReleaseInfo(library, releases[1]));
    try std.testing.expectEqual(@as(?database.ReleaseInfo, null), try runtime.libraryReleaseInfo(library, releases[2]));

    fake.releases_unavailable = false;
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.cached, try runArtistInfo(&runtime, library, artist, .{ .include_releases = true }));
    try std.testing.expectEqual(@as(u32, 6), fake.release_requests.load(.monotonic));
    for (fake.release_mbids[3..6], release_mbids) |*sent, release_mbid| try std.testing.expectEqualStrings(release_mbid, sent);
    for (releases) |release| {
        var info = (try runtime.libraryReleaseInfo(library, release)).?;
        defer info.deinit();
        try std.testing.expectEqual(@backingInt(runtime_module.ReleaseInfoOutcome.fetched), info.record.outcome);
    }
}

test "an Artist's fetch waits for a service another Gateway holds, and is busy only once its deadline passes" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-lease-wait?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);

    const holder: i64 = 99;
    const now = fake.clock.wallNow();
    try std.testing.expect(try library_database.provider_state.claimLease(providers.musicbrainz.service, holder, now, now + 10_000));
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(@as(u32, 1), fake.musicbrainz_requests.load(.monotonic));
    try std.testing.expect(fake.clock.wallNow() - now >= 10_000);

    const later = fake.clock.wallNow();
    try std.testing.expect(try library_database.provider_state.claimLease(providers.listenbrainz.service, holder, later, later + 10 * 60_000));
    const started_ms = fake.clock.now();
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.busy, try runArtistInfo(&runtime, library, artist, .{ .force = true }));
    try std.testing.expectEqual(@as(u32, 1), fake.popularity_requests.load(.monotonic));
    try std.testing.expect(fake.clock.now() - started_ms <= artist_info.fetch_deadline_ms + 1_000);
}

/// MusicBrainz and the services an Artist's fetch asks, answering a
/// matching job and an Artist's fetch that run at once on one simulated
/// clock, and noting when each MusicBrainz request was sent and for which.
const SharedMusicBrainz = struct {
    matching: FakeMusicBrainz,
    artist: FakeArtistInfo = .{},
    http: network.testing.ScriptedTransport = .{},
    sim: network.testing.SimClock,
    mutex: std.Io.Mutex = .init,
    sends: [64]Send = undefined,
    send_count: usize = 0,

    const Send = struct { at_ms: i64, matching: bool };

    fn hooks(self: *SharedMusicBrainz) MatchingHooks {
        self.http.responder = .{ .context = self, .respond_fn = respond };
        return .{
            .transport = .{ .context = self, .perform_fn = perform },
            .clock = self.sim.clock(),
            .wall_clock = self.sim.wallClock(),
        };
    }

    fn deinit(self: *SharedMusicBrainz) void {
        self.http.deinit();
        self.artist.deinit();
    }

    fn musicBrainzSends(self: *SharedMusicBrainz) []const Send {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        return self.sends[0..@min(self.send_count, self.sends.len)];
    }

    fn perform(context: *anyopaque, allocator: std.mem.Allocator, request: network.client.Request) anyerror!network.client.Response {
        const self: *SharedMusicBrainz = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        return self.http.transport().perform(allocator, request);
    }

    fn respond(context: *anyopaque, exchange: network.testing.Exchange, scripted: ?network.testing.Reply) anyerror!network.testing.Reply {
        const self: *SharedMusicBrainz = @ptrCast(@alignCast(context));
        const url = exchange.request.url;
        const for_matching = std.mem.indexOf(u8, url, "/ws/2/recording?") != null or
            std.mem.indexOf(u8, url, "/ws/2/release/" ++ bryter_layter_mbid) != null;
        if (std.mem.startsWith(u8, url, providers.musicbrainz.default_server ++ "/")) {
            if (self.send_count < self.sends.len)
                self.sends[self.send_count] = .{ .at_ms = self.sim.now(), .matching = for_matching };
            self.send_count += 1;
        }
        return if (for_matching)
            FakeMusicBrainz.respond(&self.matching, exchange, scripted)
        else
            FakeArtistInfo.respond(&self.artist, exchange, scripted);
    }
};

test "a matching job and an Artist's fetch take turns at MusicBrainz and both finish" {
    var shared: SharedMusicBrainz = .{
        .matching = .{ .answers = &.{
            .{ .title = "Northern%20Sky", .body = northern_sky_answer },
            .{ .title = "Pink%20Moon", .body = pink_moon_answer },
        } },
        .sim = .init(std.testing.io, 0, FakeMusicBrainz.wall_base_ms, 2),
    };
    defer shared.deinit();
    try shared.artist.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    defer shared.sim.finish();
    try runtime.setClientIdentity(network.testing.test_identity);
    runtime.matching_hooks = shared.hooks();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-musicbrainz-turns?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);
    _ = try addMatchTrack(library_database, "Northern Sky", "Nick Drake", null);
    _ = try addMatchTrack(library_database, "Pink Moon", "Nick Drake", null);
    _ = try addMatchTrack(library_database, "Unknown Song", "Nobody", null);

    const fetch = try runtime.startArtistInfoFetch(library, artist, .{});
    var first_request: runtime_tests.TestDeadline = .init(10_000);
    while (shared.artist.musicbrainz_requests.load(.acquire) == 0) {
        if (!first_request.tick()) return error.RequestNeverSent;
    }
    const matching = try runtime.startLibraryMatching(library, .{});

    var states: [2]?job.State = .{ null, null };
    const handles = [2]runtime_module.JobHandle{ fetch, matching };
    var deadline: runtime_tests.TestDeadline = .init(20_000);
    while (states[0] == null or states[1] == null) {
        if (!deadline.tick()) return error.JobDidNotFinish;
        runtime.reapFinishedJobs();
        for (&states, handles) |*state, handle| {
            if (state.* != null) continue;
            const snapshot = try runtime.jobSnapshotSynced(handle);
            switch (snapshot.state) {
                .succeeded, .failed, .cancelled => {
                    state.* = snapshot.state;
                    shared.sim.leave();
                },
                else => {},
            }
        }
    }

    const stats = try runtime.jobMatchStats(matching);
    try std.testing.expectEqual(BusyService.none, stats.busy);
    try std.testing.expectEqual(job.State.succeeded, states[1].?);
    try std.testing.expectEqual(@as(u64, 2), stats.matched);
    try std.testing.expectEqual(job.State.succeeded, states[0].?);
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runtime.jobArtistInfoOutcome(fetch));

    const sends = shared.musicBrainzSends();
    try std.testing.expect(sends.len == shared.send_count);
    var first_matching: ?usize = null;
    var last_artist: ?usize = null;
    for (sends, 0..) |send, index| {
        if (send.matching and first_matching == null) first_matching = index;
        if (!send.matching) last_artist = index;
        if (index > 0)
            try std.testing.expect(send.at_ms - sends[index - 1].at_ms >= providers.musicbrainz.minimum_interval_ms);
    }
    try std.testing.expect(first_matching.? < last_artist.?);
}

test "an Artist's fetch stores its info and counts the store while related artists' photos and covers are still pending" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-progressive?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);

    fake.hold_extras.store(true, .release);
    defer fake.hold_extras.store(false, .release);
    const handle = try runtime.startArtistInfoFetch(library, artist, .{});
    var deadline: runtime_tests.TestDeadline = .init(10_000);
    while (try runtime.jobArtistInfoStores(handle) < 2 and deadline.tick()) {}
    try std.testing.expectEqual(@as(u32, 2), try runtime.jobArtistInfoStores(handle));
    try std.testing.expectEqual(job.State.running, (try runtime.jobSnapshotSynced(handle)).state);
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.not_requested, try runtime.jobArtistInfoOutcome(handle));
    {
        var stored = (try runtime.libraryArtistInfo(library, artist)).?;
        defer stored.deinit();
        try std.testing.expect(stored.record.biography != null);
        try std.testing.expect(stored.record.photo_source != null);
    }
    try std.testing.expect(fake.relatedPhotoRequests() == 0);

    fake.hold_extras.store(false, .release);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, handle));
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runtime.jobArtistInfoOutcome(handle));
    try std.testing.expectEqual(@as(u32, 4), try runtime.jobArtistInfoStores(handle));
    try std.testing.expect(fake.relatedPhotoRequests() > 0);
    try std.testing.expect(fake.group_cover_requests.load(.monotonic) > 0);
}

test "release groups an Artist's browse no longer names take their covers with them" {
    var fake: FakeArtistInfo = .{};
    defer fake.deinit();
    try fake.init();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.matching_hooks = fake.hooks();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime.openLibrary(std.testing.io, "file:orca-artist-info-group-cover-replace?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const artist = try addAmine(library_database, "/nonexistent/orca-music", amine_mbid);

    std.testing.allocator.free(fake.release_group_browse);
    fake.release_group_browse = try releaseGroupBrowse(std.testing.allocator, 4, 0, 0);
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    try std.testing.expectEqual(CoverCounts{ .kept = 2, .none = 2 }, try elsewhereCovers(&runtime, library, artist));

    std.testing.allocator.free(fake.release_group_browse);
    fake.release_group_browse = try releaseGroupBrowse(std.testing.allocator, 4, 2, 0);
    fake.clock.advance(31 * std.time.ms_per_day);
    try std.testing.expectEqual(runtime_module.ArtistInfoOutcome.fetched, try runArtistInfo(&runtime, library, artist, .{}));
    for ([_][]const u8{ "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d0000", "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d0001" }) |gone|
        try std.testing.expect(try library_database.artist_info.releaseGroupCoverMark(gone) == null);
    try std.testing.expect((try library_database.artist_info.releaseGroupCoverMark("0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d0003")).?.has_image);
    var rows = try library_database.database.prepare("SELECT count(*) FROM release_group_covers;");
    defer rows.deinit();
    try std.testing.expectEqual(database.sqlite.Step.row, try rows.step());
    try std.testing.expectEqual(@as(i64, 4), rows.columnInt64(0));
}

fn observeAlbumFile(library_database: *database.LibraryDatabase, uri: []const u8, title: []const u8, duration_ms: i64) !i64 {
    const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024, .duration_ms = duration_ms });
    _ = try library_database.locations.upsert(.{
        .file_id = file_id,
        .volume_id = database.LibraryDatabase.null_volume,
        .uri = uri,
        .state = .present,
    });
    try library_database.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = title,
        .artist = "Nick Drake",
        .album = "Bryter Layter",
        .album_artist = "Nick Drake",
        .date = "1971",
    } });
    return file_id;
}

fn putHeardPayload(library_database: *database.LibraryDatabase, file_id: i64, recording_mbid: []const u8, payload: database.ProposalPayload, confidence: f32) !void {
    const encoded = try payload.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    _ = try library_database.identification_proposals.put(.{
        .file_id = file_id,
        .provider = "musicbrainz+acoustid",
        .provider_id = recording_mbid,
        .confidence = confidence,
        .payload = encoded,
    });
}

fn proposalStates(library_database: *database.LibraryDatabase, state: i64) !i64 {
    var statement = try library_database.database.prepare("SELECT count(*) FROM identification_proposals WHERE state = ?1;");
    defer statement.deinit();
    try statement.bindInt64(1, state);
    try std.testing.expectEqual(database.sqlite.Step.row, try statement.step());
    return statement.columnInt64(0);
}

test "release match pages and counts across many Releases agree with weighing each Release on its own" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-release-match-chunks?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    try library_database.database.exec(
        \\CREATE TEMP TABLE numbers AS
        \\    WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v + 1 FROM n WHERE v < 1200) SELECT v FROM n;
        \\INSERT INTO releases(id, title, album_artist)
        \\    SELECT v, printf('Album %d', v % 7), printf('Artist %03d', (v * 37) % 600) FROM numbers WHERE v <= 600;
        \\INSERT INTO recordings(id, title) SELECT v, 'Song' FROM numbers;
        \\INSERT INTO files(id, recording_id) SELECT v, v FROM numbers;
        \\INSERT INTO tracks(id, recording_id, release_id, title, track_number, preferred_file_id)
        \\    SELECT v, v, (v + 1) / 2, 'Song', 2 - v % 2, CASE WHEN v % 7 = 0 THEN NULL ELSE v END FROM numbers;
        \\INSERT INTO observed_file_tags(file_id, musicbrainz_release_id)
        \\    SELECT v, printf('00000000-0000-4000-8000-%012d', (v + 1) / 2) FROM numbers
        \\    WHERE ((v + 1) / 2) % 3 = 0 OR (((v + 1) / 2) % 3 = 1 AND v % 2 = 1);
        \\INSERT INTO dismissed_release_candidates(release_id, musicbrainz_release_id, dismissed_at)
        \\    SELECT v, printf('00000000-0000-4000-8000-%012d', v), 0 FROM numbers WHERE v <= 600 AND v % 45 = 0;
    );
    const repository = &library_database.identification_proposals;
    var expected: [3]std.ArrayList(i64) = .{ .empty, .empty, .empty };
    defer for (&expected) |*list| list.deinit(std.testing.allocator);
    {
        var releases = try library_database.database.prepare(
            "SELECT id FROM releases ORDER BY album_artist COLLATE NOCASE, title COLLATE NOCASE, id;",
        );
        defer releases.deinit();
        while (try releases.step() == .row) {
            const view = try repository.releaseMatchView(std.testing.allocator, releases.columnInt64(0), false);
            defer view.deinit();
            const bucket = @import("../database/repository/identification.zig").releaseMatchBucket(try view.best(std.testing.allocator), 0.9);
            try expected[@backingInt(bucket)].append(std.testing.allocator, view.release_id);
        }
    }
    try std.testing.expectEqual(ReleaseMatchCounts{
        .confident = expected[@backingInt(ReleaseMatchBucket.confident)].items.len,
        .needs_review = expected[@backingInt(ReleaseMatchBucket.needs_review)].items.len,
        .unmatched = expected[@backingInt(ReleaseMatchBucket.unmatched)].items.len,
    }, try runtime.libraryReleaseMatchCounts(library, 0.9, null));
    try std.testing.expectEqual(@as(usize, 187), expected[@backingInt(ReleaseMatchBucket.confident)].items.len);
    try std.testing.expectEqual(@as(usize, 200), expected[@backingInt(ReleaseMatchBucket.needs_review)].items.len);
    for ([_]ReleaseMatchBucket{ .confident, .needs_review, .unmatched }) |bucket| {
        const all = expected[@backingInt(bucket)].items;
        for ([_]u32{ 0, 1, 150, 199, 250 }) |offset| for ([_]u32{ 7, 512 }) |limit| {
            var page = try runtime.libraryReleaseMatchPage(library, std.testing.allocator, bucket, 0.9, null, limit, offset);
            defer page.deinit();
            const start = @min(offset, all.len);
            const want = all[start..@min(all.len, start + limit)];
            try std.testing.expectEqual(want.len, page.items.len);
            for (want, page.items) |release_id, item| {
                try std.testing.expectEqual(release_id, item.release_id);
                try std.testing.expectEqual(bucket, item.bucket);
                try std.testing.expectEqual(@as(u32, 2), item.track_count);
            }
        };
    }
}

test "a Release sorts into a bucket by its best release's mean confidence, and dismissing that release leaves it unmatched" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-release-match-buckets?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try observeAlbumFile(library_database, "/music/drake/01.flac", "Northern Sky", 227_000);
    const pink_moon = try observeAlbumFile(library_database, "/music/drake/02.flac", "Pink Moon", 125_000);
    try projectAll(library_database);
    const album = try releaseOfFile(library_database, northern_sky);
    _ = try putPayload(library_database, northern_sky, northern_sky_mbid, bryterLayterPayload("Northern Sky", northern_sky_track_mbid, 3));
    _ = try putPayload(library_database, pink_moon, pink_moon_mbid, bryterLayterPayload("Pink Moon", pink_moon_track_mbid, 4));

    var confident = try runtime.libraryReleaseMatchPage(library, std.testing.allocator, .confident, 0.9, null, 512, 0);
    defer confident.deinit();
    try std.testing.expectEqual(@as(usize, 1), confident.items.len);
    const item = confident.items[0];
    try std.testing.expectEqual(album, item.release_id);
    try std.testing.expectEqual(@as(u32, 2), item.track_count);
    try std.testing.expectEqualStrings(bryter_layter_mbid, item.best.?.release_mbid);
    try std.testing.expectEqualStrings("Bryter Layter", item.best.?.title);
    try std.testing.expectEqualStrings("1971-03-01", item.best.?.date.?);
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), item.best.?.confidence, 0.001);

    var review = try runtime.libraryReleaseMatchPage(library, std.testing.allocator, .needs_review, 0.99, null, 512, 0);
    defer review.deinit();
    try std.testing.expectEqual(@as(usize, 1), review.items.len);
    try std.testing.expectEqual(ReleaseMatchBucket.needs_review, review.items[0].bucket);
    const counts = try runtime.libraryReleaseMatchCounts(library, 0.99, null);
    try std.testing.expectEqual(ReleaseMatchCounts{ .confident = 0, .needs_review = 1, .unmatched = 0 }, counts);

    try runtime.libraryDismissReleaseCandidate(library, album, bryter_layter_mbid);
    try runtime.libraryDismissReleaseCandidate(library, album, bryter_layter_mbid);
    var unmatched = try runtime.libraryReleaseMatchPage(library, std.testing.allocator, .unmatched, 0.9, null, 512, 0);
    defer unmatched.deinit();
    try std.testing.expectEqual(@as(usize, 1), unmatched.items.len);
    try std.testing.expectEqual(@as(?database.ReleaseCandidate, null), unmatched.items[0].best);
    try std.testing.expectError(error.NoReleaseCandidate, runtime.libraryReleaseMatchEvidence(library, album, null));
    try std.testing.expectError(error.InvalidMusicBrainzId, runtime.libraryDismissReleaseCandidate(library, album, "not-an-id"));
    try std.testing.expectError(error.UnknownRelease, runtime.libraryDismissReleaseCandidate(library, album + 100, bryter_layter_mbid));
    try std.testing.expectError(error.InvalidMinimumConfidence, runtime.libraryReleaseMatchCounts(library, 0, null));
}

test "a filter keeps the Releases whose title or album artist has a word starting with each of its words, in the page and in every count" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-release-match-filter?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try observeAlbumFile(library_database, "/music/drake/01.flac", "Northern Sky", 227_000);
    const other = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024, .duration_ms = 200_000 });
    _ = try library_database.locations.upsert(.{ .file_id = other, .volume_id = database.LibraryDatabase.null_volume, .uri = "/music/amine/01.flac", .state = .present });
    try library_database.observed_tags.upsert(.{ .file_id = other, .values = .{ .title = "Dr. Whoever", .album = "ONEPOINTFIVE", .album_artist = "Aminé" } });
    try projectAll(library_database);
    const album = try releaseOfFile(library_database, northern_sky);
    _ = try putPayload(library_database, northern_sky, northern_sky_mbid, bryterLayterPayload("Northern Sky", northern_sky_track_mbid, 3));

    try std.testing.expectEqual(ReleaseMatchCounts{ .confident = 1, .needs_review = 0, .unmatched = 1 }, try runtime.libraryReleaseMatchCounts(library, 0.9, null));
    try std.testing.expectEqual(ReleaseMatchCounts{ .confident = 1, .needs_review = 0, .unmatched = 0 }, try runtime.libraryReleaseMatchCounts(library, 0.9, "nick bry"));
    try std.testing.expectEqual(ReleaseMatchCounts{ .confident = 0, .needs_review = 0, .unmatched = 1 }, try runtime.libraryReleaseMatchCounts(library, 0.9, "onepoint"));
    try std.testing.expectEqual(ReleaseMatchCounts{ .confident = 0, .needs_review = 0, .unmatched = 0 }, try runtime.libraryReleaseMatchCounts(library, 0.9, "layter amine"));
    try std.testing.expectEqual(ReleaseMatchCounts{ .confident = 1, .needs_review = 0, .unmatched = 1 }, try runtime.libraryReleaseMatchCounts(library, 0.9, " \"* "));

    var confident = try runtime.libraryReleaseMatchPage(library, std.testing.allocator, .confident, 0.9, "drake", 512, 0);
    defer confident.deinit();
    try std.testing.expectEqual(@as(usize, 1), confident.items.len);
    try std.testing.expectEqual(album, confident.items[0].release_id);
    var unmatched = try runtime.libraryReleaseMatchPage(library, std.testing.allocator, .unmatched, 0.9, "AMIN", 512, 0);
    defer unmatched.deinit();
    try std.testing.expectEqual(@as(usize, 1), unmatched.items.len);
    try std.testing.expectEqualStrings("ONEPOINTFIVE", unmatched.items[0].title);
    var none = try runtime.libraryReleaseMatchPage(library, std.testing.allocator, .unmatched, 0.9, "drake", 512, 0);
    defer none.deinit();
    try std.testing.expectEqual(@as(usize, 0), none.items.len);
    try std.testing.expectError(error.SearchTextTooLong, runtime.libraryReleaseMatchCounts(library, 0.9, &@as([257]u8, @splat('x'))));
}

test "applying only the album artist from pending proposals stores it locked over the file's tag, keeps a user's lock, leaves the rest and the proposals alone, and yields to a later edit" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-release-apply-fields?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try observeAlbumFile(library_database, "/music/drake/01.flac", "Northern Sky", 227_000);
    const pink_moon = try observeAlbumFile(library_database, "/music/drake/02.flac", "Pink Moon", 125_000);
    try projectAll(library_database);
    const album = try releaseOfFile(library_database, northern_sky);
    var northern_payload = bryterLayterPayload("Northern Sky", northern_sky_track_mbid, 3);
    northern_payload.release_artist = "Nicholas Drake";
    var pink_payload = bryterLayterPayload("Pink Moon", pink_moon_track_mbid, 4);
    pink_payload.release_artist = "Nicholas Drake";
    _ = try putPayload(library_database, northern_sky, northern_sky_mbid, northern_payload);
    _ = try putPayload(library_database, pink_moon, pink_moon_mbid, pink_payload);
    try library_database.orca_metadata.upsert(.{ .file_id = pink_moon, .field = .album_artist, .value = "Mine", .provenance = .user, .locked = true });

    const only_album_artist: ReleaseFieldSet = .initOne(.album_artist);
    try std.testing.expectEqual(@as(u32, 1), try runtime.libraryApplyMatchedRelease(library, album, only_album_artist));

    const applied = (try library_database.orca_metadata.get(std.testing.allocator, northern_sky, .album_artist)).?;
    defer applied.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Nicholas Drake", applied.text);
    try std.testing.expect(applied.locked);
    try std.testing.expectEqual(metadata.Provenance.provider, applied.provenance);
    try expectOrcaValue(library_database, pink_moon, .album_artist, "Mine");
    const shown = (try runtime.libraryTrackDetails(library, try trackOfFile(library_database, northern_sky))).?;
    try std.testing.expectEqualStrings("Nicholas Drake", shown.album_artist);
    try std.testing.expectEqualStrings("1971", shown.date.?);
    shown.deinit();
    for ([_]i64{ northern_sky, pink_moon }) |file| {
        try expectOrcaValue(library_database, file, .album, null);
        try expectOrcaValue(library_database, file, .date, null);
        try expectOrcaValue(library_database, file, .title, null);
        try expectOrcaValue(library_database, file, .track_number, null);
        try expectOrcaValue(library_database, file, .musicbrainz_release_id, null);
        try expectOrcaValue(library_database, file, .compilation, null);
    }
    try std.testing.expectEqual(@as(i64, 2), try proposalStates(library_database, 0));
    try std.testing.expectEqual(@as(i64, 0), try proposalStates(library_database, 1));

    (try runtime.libraryEditTracks(library, &.{try trackOfFile(library_database, northern_sky)}, &.{.{ .field = .album_artist, .value = "Edited" }})).deinit();
    try expectOrcaValue(library_database, northern_sky, .album_artist, "Edited");
}

test "apply-release without fields stores nothing while the Tracks have only pending proposals and leaves them pending" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-release-apply-consensus?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try observeAlbumFile(library_database, "/music/drake/01.flac", "Northern Sky", 227_000);
    const pink_moon = try observeAlbumFile(library_database, "/music/drake/02.flac", "Pink Moon", 125_000);
    try projectAll(library_database);
    const album = try releaseOfFile(library_database, northern_sky);
    _ = try putPayload(library_database, northern_sky, northern_sky_mbid, bryterLayterPayload("Northern Sky", northern_sky_track_mbid, 3));
    _ = try putPayload(library_database, pink_moon, pink_moon_mbid, bryterLayterPayload("Pink Moon", pink_moon_track_mbid, 4));

    try std.testing.expectEqual(@as(u32, 0), try runtime.libraryApplyMatchedRelease(library, album, null));

    for ([_]i64{ northern_sky, pink_moon }) |file| {
        try expectOrcaValue(library_database, file, .album_artist, null);
        try expectOrcaValue(library_database, file, .musicbrainz_release_id, null);
        try expectOrcaValue(library_database, file, .musicbrainz_recording_id, null);
    }
    try std.testing.expectEqual(@as(i64, 2), try proposalStates(library_database, 0));
    try std.testing.expectEqual(@as(i64, 0), try proposalStates(library_database, 1));
}

test "the release diff sizes the embedded cover and the archive's front cover, and shows an unmeasured archive cover as a dash" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-release-diff-artwork?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try observeAlbumFile(library_database, "/music/drake/01.flac", "Northern Sky", 227_000);
    try projectAll(library_database);
    const album = try releaseOfFile(library_database, northern_sky);
    _ = try putPayload(library_database, northern_sky, northern_sky_mbid, bryterLayterPayload("Northern Sky", northern_sky_track_mbid, 3));

    {
        const diff = try runtime.libraryReleaseMatchDiff(library, std.testing.allocator, album, bryter_layter_mbid);
        defer diff.deinit();
        const artwork = diff.fields[@backingInt(ReleaseField.artwork)];
        try std.testing.expectEqualStrings("", artwork.local);
        try std.testing.expectEqualStrings("", artwork.candidate);
        try std.testing.expect(!artwork.differs);
    }

    var buffer: [512]u8 = undefined;
    try library_database.database.exec(try std.fmt.bufPrintSentinel(&buffer,
        \\UPDATE observed_file_tags SET artwork_byte_size = 4096, artwork_width = 1200, artwork_height = 1200 WHERE file_id = {d};
        \\INSERT INTO cover_art_candidates(release_id, caa_id, musicbrainz_release_id, kind, width, height, approved, fetched_at)
        \\VALUES ({d}, 1, '{s}', 0, 1200, 1200, 1, 0), ({d}, 2, '{s}', 1, 2000, 2000, 1, 0), ({d}, 3, '{s}', 0, NULL, NULL, 1, 0);
    , .{ northern_sky, album, bryter_layter_mbid, album, bryter_layter_mbid, album, northern_sky_mbid }, 0));

    {
        const diff = try runtime.libraryReleaseMatchDiff(library, std.testing.allocator, album, bryter_layter_mbid);
        defer diff.deinit();
        const artwork = diff.fields[@backingInt(ReleaseField.artwork)];
        try std.testing.expectEqualStrings("embedded · 1200 × 1200", artwork.local);
        try std.testing.expectEqualStrings("Cover Art Archive · 1200 × 1200", artwork.candidate);
        try std.testing.expect(!artwork.differs);
        try std.testing.expectEqual(@as(u32, 1200), diff.local_artwork_size.?.width);
        try std.testing.expectEqual(@as(u32, 1200), diff.candidate_artwork_size.?.height);
    }
    {
        const diff = try runtime.libraryReleaseMatchDiff(library, std.testing.allocator, album, northern_sky_mbid);
        defer diff.deinit();
        try std.testing.expectEqualStrings("Cover Art Archive · —", diff.fields[@backingInt(ReleaseField.artwork)].candidate);
        try std.testing.expectEqual(@as(?ArtworkSize, null), diff.candidate_artwork_size);
    }
}

test "release evidence counts Tracks heard by fingerprint and compares dates as text, and the diff lines each Track up with its title on the release" {
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(std.testing.io, "file:orca-release-evidence?mode=memory&cache=shared");
    const library_database = try libraryDatabase(&runtime, library);
    const northern_sky = try observeAlbumFile(library_database, "/music/drake/01.flac", "Northern Sky", 227_000);
    const pink_moon = try observeAlbumFile(library_database, "/music/drake/02.flac", "Pink Moon (demo)", 125_000);
    try projectAll(library_database);
    const album = try releaseOfFile(library_database, northern_sky);
    var heard = bryterLayterPayload("Northern Sky", northern_sky_track_mbid, 3);
    heard.duration_ms = 227_400;
    heard.acoustid_score = 0.97;
    heard.release_type = "Mixtape";
    try putHeardPayload(library_database, northern_sky, northern_sky_mbid, heard, 0.97);
    var searched = bryterLayterPayload("Pink Moon", pink_moon_track_mbid, 4);
    searched.duration_ms = 126_900;
    _ = try putPayload(library_database, pink_moon, pink_moon_mbid, searched);

    const evidence = try runtime.libraryReleaseMatchEvidence(library, album, null);
    try std.testing.expectEqual(@as(u32, 1), evidence.fingerprints_matched);
    try std.testing.expectEqual(@as(u32, 2), evidence.tracks);
    try std.testing.expect(!evidence.durations_within_1s);
    try std.testing.expect(evidence.artist_agrees);
    try std.testing.expect(evidence.title_agrees);
    try std.testing.expect(!evidence.date_agrees);
    try std.testing.expectEqualStrings(
        "1 of 2 tracks match by fingerprint; 1 of 2 durations differ by more than 1 s; the date differs (1971 here, 1971-03-01 on the release).",
        evidence.note.slice(),
    );

    const diff = try runtime.libraryReleaseMatchDiff(library, std.testing.allocator, album, bryter_layter_mbid);
    defer diff.deinit();
    try std.testing.expectEqual(@as(u32, 2), diff.aligned);
    const date = diff.fields[@backingInt(ReleaseField.release_date)];
    try std.testing.expectEqualStrings("1971", date.local);
    try std.testing.expectEqualStrings("1971-03-01", date.candidate);
    try std.testing.expect(date.differs);
    try std.testing.expect(!diff.fields[@backingInt(ReleaseField.album)].differs);
    const release_type = diff.fields[@backingInt(ReleaseField.release_type)];
    try std.testing.expectEqualStrings("", release_type.local);
    try std.testing.expectEqualStrings("Mixtape", release_type.candidate);
    try std.testing.expect(release_type.differs);
    const titles = diff.fields[@backingInt(ReleaseField.track_titles)];
    try std.testing.expectEqualStrings("1 of 2 differ", titles.local);
    try std.testing.expect(titles.differs);
    try std.testing.expectEqual(@as(usize, 2), diff.tracks.len);
    try std.testing.expectEqual(@as(u32, 3), diff.tracks[0].position);
    try std.testing.expectEqual(@as(?i64, 400), diff.tracks[0].delta_ms);
    try std.testing.expect(diff.tracks[0].fingerprint);
    try std.testing.expectEqualStrings("Pink Moon (demo)", diff.tracks[1].local_title);
    try std.testing.expectEqualStrings("Pink Moon", diff.tracks[1].candidate_title);
    try std.testing.expectEqual(@as(?i64, 1900), diff.tracks[1].delta_ms);
    try std.testing.expect(!diff.tracks[1].fingerprint);
}
