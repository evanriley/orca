const std = @import("std");
const audio = @import("../audio/root.zig");
const control = @import("control.zig");
const database = @import("../database/root.zig");
const job = @import("job.zig");
const listen_worker = @import("listen_worker.zig");
const network = @import("../network/root.zig");
const providers = @import("../providers/root.zig");
const work = @import("work.zig");
const runtime_jobs = @import("runtime_jobs.zig");
const runtime_listens = @import("runtime_listens.zig");
const runtime_module = @import("runtime.zig");
const runtime_tests = @import("runtime_tests.zig");

const AcoustIdUse = runtime_module.AcoustIdUse;
const BusyService = runtime_module.BusyService;
const CredentialStore = runtime_module.CredentialStore;
const Feedback = runtime_module.Feedback;
const LibraryHandle = runtime_module.LibraryHandle;
const MatchingHooks = runtime_module.MatchingHooks;
const OrcaRuntime = runtime_module.OrcaRuntime;
const PlayStats = runtime_module.PlayStats;
const PlayerHandle = runtime_module.PlayerHandle;
const RecordingIdSource = runtime_module.RecordingIdSource;
const ScanStats = runtime_module.ScanStats;
const ScrobblerState = runtime_module.ScrobblerState;
const SubmissionOutcome = runtime_module.SubmissionOutcome;
const libraryDatabase = runtime_module.libraryDatabase;

fn sampleClock(clock: *network.testing.TestClock) listen_worker.SampleClock {
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
        const file_id = try library_database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
        try library_database.tracks.upsertTracks(&.{.{
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
    try std.testing.expectEqualStrings("https://lb.example.org", rig.runtime.listenbrainz_server);
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

const northern_sky_mbid = "0b3c4d5e-6f70-4812-9a3b-4c5d6e7f8091";
const pink_moon_mbid = "1d2e3f40-5162-4738-8a9b-0c1d2e3f4a5b";

fn recordingAnswer(comptime mbid: []const u8, comptime title: []const u8) []const u8 {
    return "{\"recordings\":[{\"id\":\"" ++ mbid ++ "\",\"score\":100,\"title\":\"" ++ title ++
        "\",\"length\":180000,\"artist-credit\":[{\"name\":\"Nick Drake\"}],\"releases\":[{" ++
        "\"id\":\"2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b\",\"title\":\"Bryter Layter\"," ++
        "\"media\":[{\"track-offset\":2,\"track\":[{\"number\":\"3\"}]}]}]}]}";
}

const northern_sky_answer = recordingAnswer(northern_sky_mbid, "Northern Sky");
const pink_moon_answer = recordingAnswer(pink_moon_mbid, "Pink Moon");

/// Every call arrives on the job's thread; a test reads the request count
/// while the job runs and the rest only once it is reaped.
const FakeMusicBrainz = struct {
    transport: network.testing.ScriptedTransport = .{},
    clock: network.testing.TestClock = .{ .wall_offset_ms = wall_base_ms },
    answers: []const Answer = &.{},
    refusals: []const u16 = &.{},
    failure: ?anyerror = null,
    hang_from: ?u32 = null,

    const Answer = struct { title: []const u8, body: []const u8 };
    const wall_base_ms: i64 = 1_800_000_000_000;

    fn hooks(self: *FakeMusicBrainz) MatchingHooks {
        self.transport.clock = &self.clock;
        self.transport.responder = .{ .context = self, .respond_fn = respond };
        return .{
            .transport = self.transport.transport(),
            .clock = self.clock.clock(),
            .wall_clock = self.clock.wallClock(),
        };
    }

    fn requestCount(self: *const FakeMusicBrainz) u32 {
        return self.transport.requestCount();
    }

    fn respond(context: *anyopaque, exchange: network.testing.Exchange, _: ?network.testing.Reply) anyerror!network.testing.Reply {
        const self: *FakeMusicBrainz = @ptrCast(@alignCast(context));
        if (self.hang_from) |first| if (exchange.index >= first) return .hang;
        if (self.failure) |err| return .{ .fail = err };
        if (exchange.index < self.refusals.len)
            return .{ .respond = .{ .status = self.refusals[exchange.index], .body = "" } };
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

fn addMatchTrack(library_database: *database.LibraryDatabase, title: []const u8, artist: []const u8, mbid: ?[]const u8) !i64 {
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
    try std.testing.expectEqual(@as(u64, 3), stats.requests);
    try std.testing.expectEqual(@as(u64, 0), stats.cache_hits);
    try std.testing.expectEqual(@as(u64, 2), stats.proposals_stored);
    try std.testing.expectEqual(ScanStats{}, try runtime.jobScanStats(job_handle));
    try std.testing.expectEqual(@as(u32, 3), fake.requestCount());
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
    try std.testing.expectEqual(@as(u32, 3), fake.requestCount());
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

    try std.testing.expectEqual(@as(u32, 1), acceptance.values_written);
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
    var fake: FakeMusicBrainz = .{ .answers = &.{.{ .title = "Northern%20Sky", .body = northern_sky_answer }}, .hang_from = 1 };
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
    try fake.awaitRequests(2);
    try std.testing.expectEqual(@as(u64, 1), (try runtime.jobMatchStats(job_handle)).matched);
    try std.testing.expectError(error.MatchingAlreadyRunning, runtime.startLibraryMatching(library, .{}));
    try runtime.cancelJob(job_handle);

    try std.testing.expectEqual(job.State.cancelled, try runtime_tests.awaitJob(&runtime, job_handle));
    const stats = try runtime.jobMatchStats(job_handle);
    try std.testing.expect(stats.cancelled);
    try std.testing.expectEqual(@as(u64, 1), stats.tracks_examined);
    try std.testing.expectEqual(@as(u32, 2), fake.requestCount());
    const proposals = try runtime.libraryMatchProposals(library, northern_sky, 10);
    defer proposals.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposals.items.len);
    try std.testing.expectEqual(@as(u64, 2), try library_database.identification_proposals.unidentifiedCount(.library, false, null));

    fake.hang_from = null;
    const resumed = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, resumed));
    try std.testing.expectEqual(@as(u64, 2), (try runtime.jobMatchStats(resumed)).tracks_examined);
    try std.testing.expectEqual(@as(u32, 4), fake.requestCount());
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
    try std.testing.expectEqual(@as(u32, 1), fake.requestCount());
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

    try std.testing.expectEqual(@as(u32, 3), fake.requestCount());
    try std.testing.expect(fake.transport.request_times_ms[1] - fake.transport.request_times_ms[0] >= 30_000);
    try std.testing.expect(fake.transport.request_times_ms[2] - fake.transport.request_times_ms[1] >= 60_000);
    const proposals = try runtime.libraryMatchProposals(library, northern_sky, 10);
    defer proposals.deinit();
    try std.testing.expectEqual(@as(usize, 1), proposals.items.len);

    _ = try addMatchTrack(library_database, "Pink Moon", "Nick Drake", null);
    fake.failure = error.ConnectionRefused;
    const unreachable_job = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.failed, try runtime_tests.awaitJob(&runtime, unreachable_job));
    try std.testing.expectEqual(@as(u64, 0), (try runtime.jobMatchStats(unreachable_job)).tracks_examined);
    try std.testing.expectEqual(@as(u64, 1), try library_database.identification_proposals.unidentifiedCount(.library, false, null));

    fake.failure = null;
    const retried = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, retried));
    const retried_stats = try runtime.jobMatchStats(retried);
    try std.testing.expectEqual(@as(u64, 1), retried_stats.tracks_examined);
    try std.testing.expectEqual(@as(u64, 1), retried_stats.requests);
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

test "a matching job fails as busy while another process holds MusicBrainz, and searches once it lets go" {
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
        now_ms + network.client.lease_duration_ms,
    ));

    const busy = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.failed, try runtime_tests.awaitJob(&runtime, busy));
    const busy_stats = try runtime.jobMatchStats(busy);
    try std.testing.expectEqual(BusyService.musicbrainz, busy_stats.busy);
    try std.testing.expectEqual(@as(u64, 0), busy_stats.tracks_examined);
    try std.testing.expectEqual(@as(u32, 0), fake.requestCount());

    try library_database.provider_state.releaseLease(providers.musicbrainz.service, 99);
    runtime.reapFinishedJobs();
    const searched = try runtime.startLibraryMatching(library, .{});
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&runtime, searched));
    try std.testing.expectEqual(BusyService.none, (try runtime.jobMatchStats(searched)).busy);
    try std.testing.expectEqual(@as(u32, 1), fake.requestCount());
    try std.testing.expect(try library_database.provider_state.claimLease(
        providers.musicbrainz.service,
        99,
        now_ms,
        now_ms + network.client.lease_duration_ms,
    ));
}

test "a tag write leaves out the recording id Orca holds for a file" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);
    const library = try runtime_tests.scannedTempLibrary(&runtime, &temporary, "file:orca-runtime-tag-write-mbid?mode=memory&cache=shared");
    const ids = try runtime_tests.allTrackIds(&runtime, library);
    defer std.testing.allocator.free(ids);
    const library_database = try libraryDatabase(&runtime, library);
    for (ids) |track_id| {
        const file_ids = try library_database.tracks.fileIds(std.testing.allocator, track_id);
        defer std.testing.allocator.free(file_ids);
        for (file_ids) |file_id| try library_database.orca_metadata.upsert(.{
            .file_id = file_id,
            .field = .musicbrainz_recording_id,
            .value = northern_sky_mbid,
            .provenance = .provider,
        });
    }

    const preview = try runtime.planTagWrite(library, std.testing.io, ids);
    defer preview.deinit();

    try std.testing.expectEqual(@as(u64, 0), preview.plan_id);
    try std.testing.expectEqual(@as(usize, 0), preview.files.len);
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

    try std.testing.expectEqual(@as(u64, 2), counted);
    try std.testing.expectEqual(counted, accepted);
    try std.testing.expectEqual(@as(u64, 3), lower);
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
    try std.testing.expectEqual(@as(u32, 1), fake.requestCount());
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
    try std.testing.expectEqual(@as(u32, 1), fake.requestCount());
}

/// Answers AcoustID lookups and submissions on the job's thread; a test reads
/// what it recorded once the job is reaped.
const FakeAcoustId = struct {
    http: network.testing.ScriptedTransport = .{},
    lookup_body: []const u8 = "{\"status\":\"ok\",\"fingerprints\":[]}",
    submit_status: u16 = 200,
    submit_body: []const u8 = "{\"status\":\"ok\",\"submissions\":[]}",
    lookups: std.atomic.Value(u32) = .init(0),
    submissions: std.atomic.Value(u32) = .init(0),

    fn transport(self: *FakeAcoustId) network.client.Transport {
        self.http.responder = .{ .context = self, .respond_fn = respond };
        return self.http.transport();
    }

    fn lastForm(self: *const FakeAcoustId) []const u8 {
        return self.http.lastForm();
    }

    fn respond(context: *anyopaque, exchange: network.testing.Exchange, _: ?network.testing.Reply) anyerror!network.testing.Reply {
        const self: *FakeAcoustId = @ptrCast(@alignCast(context));
        if (std.mem.endsWith(u8, exchange.request.url, "/v2/lookup")) {
            _ = self.lookups.fetchAdd(1, .acq_rel);
            return .{ .respond = .{ .body = self.lookup_body } };
        }
        _ = self.submissions.fetchAdd(1, .acq_rel);
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
fn writeToneWave(dir: std.Io.Dir, name: []const u8, frequency: f32) !void {
    const rate = 11_025;
    const frames = 15 * rate;
    var bytes: [44 + frames * 2]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], bytes.len - 8, .little);
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
    for (0..frames) |frame| {
        const time = @as(f32, @floatFromInt(frame)) / rate;
        const wobble = frequency * (1 + 0.2 * @sin(2 * std.math.pi * 0.5 * time));
        const sample: i16 = @intFromFloat(9000 * @sin(2 * std.math.pi * wobble * time));
        std.mem.writeInt(i16, bytes[44 + frame * 2 ..][0..2], sample, .little);
    }
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = &bytes });
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
    try std.testing.expectEqual(@as(u64, 1), stats.requests);
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
    try std.testing.expectEqual(@as(u32, 1), musicbrainz.requestCount());

    _ = try runtime.libraryAcceptMatch(library, fingerprint_only.items[0].id);
    const details = (try runtime.libraryTrackDetails(library, untagged)).?;
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

test "a submission fails as busy while another process holds AcoustID and marks nothing sent" {
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
        now_ms + network.client.lease_duration_ms,
    ));

    const busy = try runtime.startAcoustIdSubmission(library);
    try std.testing.expectEqual(job.State.failed, try runtime_tests.awaitJob(&runtime, busy));
    try std.testing.expectEqual(SubmissionOutcome.busy, (try runtime.jobSubmissionStats(busy)).outcome);
    try std.testing.expectEqual(@as(u32, 0), acoustid.submissions.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), try runtime.libraryAcoustIdSubmittableCount(library));
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
    try proposeMatch(library_database, chosen, northern_sky_mbid, 0.95, "{\"title\":\"Northern Sky\",\"duration_ms\":15000}");
    try proposeMatch(library_database, doubted, pink_moon_mbid, 0.95, "{\"title\":\"Pink Moon\",\"duration_ms\":300000}");
    for ([_]i64{ chosen, doubted }) |track_id| {
        const page = try runtime.libraryMatchProposals(library, track_id, 1);
        defer page.deinit();
        _ = try runtime.libraryAcceptMatch(library, page.items[0].id);
    }
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
