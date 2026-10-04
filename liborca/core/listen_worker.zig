//! A Library's listen worker: records what its Players were heard playing
//! and, when the Library scrobbles, delivers those listens to ListenBrainz.
//!
//! Threading follows `artwork.Loader`: the worker touches only its own
//! struct, the `Listens` it was handed and the Library database, and the
//! control lane drains it before that database can close. `Listens` outlives
//! each worker, so a worker drained by another Library's close restarts on
//! the next listen with nothing lost.

const std = @import("std");
const control = @import("control.zig");
const database = @import("../database/root.zig");
const network = @import("../network/root.zig");
const providers = @import("../providers/root.zig");
const spsc = @import("../audio/spsc.zig");
const work = @import("work.zig");

const listenbrainz = providers.listenbrainz;
const Listen = providers.listens.Listen;

pub const ring_capacity = 64;

/// How long a delivery that failed outright waits before it is tried again.
const failure_backoff_ms: u64 = 60_000;

const feedback_settle_ms: i64 = database.repository.feedback_settle_seconds * 1000;

/// How often an idle scrobbling worker reads the queue for listens and
/// feedback another process added. A database read; the token and network are
/// touched only when something is due.
const idle_recheck_ms: u64 = 5 * 60 * 1000;

/// A Now Playing update older than this is dropped rather than announced.
const now_playing_maximum_age_ms: i64 = 60_000;

const maximum_failure_backoff_ms: u64 = 60 * 60 * 1000;

pub const Entry = struct {
    kind: Kind,
    listen: Listen,
    /// The sampler's awake clock when the entry was produced.
    mono_ms: i64 = 0,

    pub const Kind = enum { eligible, finished, now_playing };
};

pub const Config = struct {
    enabled: bool = false,
    offline: bool = false,
    now_playing: bool = false,
    /// Null until the host names itself; scrobbling cannot be enabled before.
    identity: ?network.client.OwnedIdentity = null,
    credentials: ?providers.credentials.Store = null,
    server: providers.url.OwnedServer = .fixed(listenbrainz.default_server),
    /// Bumped by the control lane whenever `identity`, `credentials` or
    /// `server` changes.
    settings: u32 = 0,
};

/// A Library's scrobbler, as `libraryScrobblerStatus` reports it.
pub const Status = struct {
    enabled: bool = false,
    state: listenbrainz.State = .idle,
    user_name: listenbrainz.BoundedText = .{},
    last_error: listenbrainz.BoundedText = .{},
    /// Unix seconds.
    next_attempt_at: ?i64 = null,
    /// When ListenBrainz accepts requests again, in Unix seconds, while this
    /// Library records it refusing them.
    blocked_until: ?i64 = null,
    /// Queued listens not yet delivered or rejected.
    pending: u64 = 0,
    feedback_pending: u64 = 0,
    delivered_total: u64 = 0,
    /// Listens recorded since the Library was opened.
    recorded_total: u64 = 0,
    /// Listens heard since the Library was opened and not recorded: the ring
    /// was full, the Track had gone, or the database refused the write.
    dropped: u64 = 0,

    fn eql(a: Status, b: Status) bool {
        inline for (@typeInfo(Status).@"struct".fields) |field| {
            const left = @field(a, field.name);
            const right = @field(b, field.name);
            const same = if (field.type == listenbrainz.BoundedText)
                std.mem.eql(u8, left.slice(), right.slice())
            else
                std.meta.eql(left, right);
            if (!same) return false;
        }
        return true;
    }
};

/// The end of a block in whole Unix seconds, or null once it has passed by
/// `now_s`.
pub fn blockEnd(blocked_until_ms: ?i64, now_s: i64) ?i64 {
    const until = blocked_until_ms orelse return null;
    const until_s = std.math.divCeil(i64, until, std.time.ms_per_s) catch unreachable;
    return if (until_s > now_s) until_s else null;
}

pub const SampleTime = struct {
    mono_ms: i64,
    wall_s: i64,
};

pub const SampleClock = struct {
    context: *anyopaque,
    now_fn: *const fn (*anyopaque) SampleTime,

    pub fn now(self: SampleClock) SampleTime {
        return self.now_fn(self.context);
    }
};

/// Stand-ins for tests, which must not reach a network or wait in real time.
pub const Hooks = struct {
    transport: ?network.client.Transport = null,
    clock: ?network.client.Clock = null,
    /// Unix time in milliseconds, which the queue's retry times are in.
    wall_clock: ?network.client.Clock = null,
    random: ?std.Random = null,
    sample_clock: ?SampleClock = null,
    /// The longest the worker sleeps between passes. Every change the control
    /// lane makes wakes it sooner.
    poll_ms: u64 = 2_000,
};

/// A value two threads copy in and out whole. The lock is held only for the
/// copy, never across I/O, a database call or a credential lookup.
fn Shared(comptime T: type) type {
    return struct {
        lock: std.atomic.Mutex = .unlocked,
        value: T = .{},

        const Self = @This();

        fn load(self: *Self) T {
            while (!self.lock.tryLock()) std.atomic.spinLoopHint();
            defer self.lock.unlock();
            return self.value;
        }

        fn store(self: *Self, value: T) void {
            while (!self.lock.tryLock()) std.atomic.spinLoopHint();
            defer self.lock.unlock();
            self.value = value;
        }
    };
}

/// One Library's listen state, created on the first Player bind or scrobbling
/// change and freed when the Library closes. The control lane produces into
/// `ring` and writes `config`; the worker consumes and publishes `status`.
pub const Listens = struct {
    ring: spsc.Queue(Entry, ring_capacity) = .{},
    config: Shared(Config) = .{},
    status: Shared(Status) = .{},
    /// Bumped by the control lane whenever the worker should look again.
    signal: std.atomic.Value(u32) = .init(0),
    credentials_generation: std.atomic.Value(u32) = .init(0),
    feedback_generation: std.atomic.Value(u32) = .init(0),
    history_generation: std.atomic.Value(u32) = .init(0),
    /// The generation whose token has been validated, written by the worker.
    credentials_validated: std.atomic.Value(u32) = .init(0),
    recorded: std.atomic.Value(u64) = .init(0),
    dropped: std.atomic.Value(u64) = .init(0),
    host_signal: ?*control.HostSignal = null,
    /// Control lane only.
    worker: ?*Worker = null,

    /// Control lane.
    pub fn push(self: *Listens, io: std.Io, entry: Entry) void {
        if (!self.ring.push(entry) and entry.kind != .now_playing) _ = self.dropped.fetchAdd(1, .monotonic);
        self.wake(io);
    }

    pub fn loadConfig(self: *Listens) Config {
        return self.config.load();
    }

    /// Control lane.
    pub fn configure(self: *Listens, io: std.Io, config: Config) void {
        self.config.store(config);
        self.wake(io);
    }

    /// Control lane.
    pub fn credentialsChanged(self: *Listens, io: std.Io) void {
        _ = self.credentials_generation.fetchAdd(1, .release);
        self.wake(io);
    }

    /// Control lane.
    pub fn feedbackChanged(self: *Listens, io: std.Io) void {
        _ = self.feedback_generation.fetchAdd(1, .release);
        self.wake(io);
    }

    /// Control lane: the listens or their queue changed outside the worker.
    pub fn historyChanged(self: *Listens, io: std.Io) void {
        _ = self.history_generation.fetchAdd(1, .release);
        self.wake(io);
    }

    pub fn wake(self: *Listens, io: std.Io) void {
        _ = self.signal.fetchAdd(1, .release);
        io.futexWake(u32, &self.signal.raw, 1);
    }

    fn raiseHost(self: *Listens) void {
        if (self.host_signal) |signal| signal.raise();
    }

    /// Control lane.
    pub fn snapshot(self: *Listens) Status {
        var status = self.status.load();
        status.enabled = self.config.load().enabled;
        if (!status.enabled) status.state = .disabled;
        status.recorded_total = self.recorded.load(.monotonic);
        status.dropped = self.dropped.load(.monotonic);
        return status;
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    /// The runtime's network `std.Io`, shared by every listen worker.
    io: std.Io,
    /// Borrowed. The control lane drains this worker before the database closes.
    database: *database.LibraryDatabase,
    listens: *Listens,
    registration: *work.Registration,
    hooks: Hooks,
    /// What `gateway.config.identity` points into.
    identity: ?network.client.OwnedIdentity = null,
    /// What `delivery.server` points into.
    server: providers.url.OwnedServer = .fixed(listenbrainz.default_server),
    listen_failures: u32 = 0,
    feedback_failures: u32 = 0,
    published: Status = .{},

    pub fn run(self: *Worker) void {
        self.published = self.listens.status.load();
        const initial = self.listens.config.load();
        var standard: network.StandardTransport = .init(self.allocator, self.io);
        var system_clock: network.SystemClock = .{ .io = self.io };
        const random_source: std.Random.IoSource = .{ .io = self.io };
        var gateway: network.Gateway = .{
            .transport = self.hooks.transport orelse standard.transport(),
            .clock = self.hooks.clock orelse system_clock.clock(),
            .wall_clock = self.hooks.wall_clock orelse system_clock.wallClock(),
            .random = self.hooks.random orelse random_source.interface(),
            .config = .{ .identity = unidentified },
            .cancel = &self.registration.cancel,
            .sharing = .{
                .store = providers.shared_state.store(&self.database.provider_state),
                .service = listenbrainz.service,
            },
        };
        var delivery: listenbrainz.Delivery = .init(
            self.allocator,
            self.io,
            &gateway,
            self.credentialStore(initial),
            &self.database.scrobbles,
        );
        self.server = initial.server;
        delivery.server = self.server.view();
        self.adoptIdentity(&gateway, initial);
        self.serve(&gateway, &delivery, initial);
        gateway.releaseLease();
        _ = self.drainRing(self.listens.config.load());
        standard.deinit();
        self.registration.finish();
    }

    /// A gateway given no identity refuses every request.
    const unidentified: network.client.Identity = .{ .name = "", .version = "", .contact = "" };

    fn adoptIdentity(self: *Worker, gateway: *network.Gateway, config: Config) void {
        self.identity = config.identity;
        gateway.config.identity = if (self.identity) |*owned| owned.view() else unidentified;
    }

    fn serve(self: *Worker, gateway: *network.Gateway, delivery: *listenbrainz.Delivery, initial: Config) void {
        var config = initial;
        config.enabled = false;
        var seen_generation = self.listens.credentials_generation.load(.acquire);
        var seen_feedback = self.listens.feedback_generation.load(.acquire);
        var seen_history = self.listens.history_generation.load(.acquire);
        var wake_at_ms: ?i64 = null;
        var pending = self.pendingCount(0);
        var feedback_pending = self.feedbackPendingCount(0);
        var now_playing: ?PendingNowPlaying = null;
        while (true) {
            const signal = self.listens.signal.load(.acquire);
            if (self.registration.cancellationRequested()) return;
            const now_ms = gateway.clock.nowMs();
            const current = self.listens.config.load();
            if (current.enabled and (!config.enabled or (config.offline and !current.offline)))
                wake_at_ms = now_ms;
            if (current.settings != config.settings) {
                self.adoptIdentity(gateway, current);
                if (!sameDestination(current, config)) {
                    self.server = current.server;
                    delivery.server = self.server.view();
                    delivery.credentials = self.credentialStore(current);
                    delivery.credentialsChanged();
                    wake_at_ms = now_ms;
                }
            }
            config = current;
            gateway.config.offline = config.offline;

            const generation = self.listens.credentials_generation.load(.acquire);
            if (generation != seen_generation) {
                seen_generation = generation;
                delivery.credentialsChanged();
                wake_at_ms = now_ms;
            }
            const feedback_generation = self.listens.feedback_generation.load(.acquire);
            if (feedback_generation != seen_feedback) {
                seen_feedback = feedback_generation;
                feedback_pending = self.feedbackPendingCount(feedback_pending);
                const settled_at_ms = now_ms +| feedback_settle_ms;
                wake_at_ms = if (wake_at_ms) |existing| @min(existing, settled_at_ms) else settled_at_ms;
            }

            const announcing = config.enabled and config.now_playing;
            const drained = self.drainRing(config);
            const history_generation = self.listens.history_generation.load(.acquire);
            if (drained.recorded or drained.queued or history_generation != seen_history) {
                seen_history = history_generation;
                pending = self.pendingCount(pending);
            }
            if (!announcing) now_playing = null;
            if (drained.now_playing) |entry| {
                if (announcing) {
                    now_playing = .{ .listen = entry.listen, .heard_at_ms = entry.mono_ms };
                    wake_at_ms = now_ms;
                }
            }
            if (config.enabled) {
                if (drained.queued) wake_at_ms = now_ms;
                self.validateOnce(gateway, delivery, generation, config);
                if (wake_at_ms) |due| if (now_ms >= due) {
                    wake_at_ms = self.pass(gateway, delivery, &now_playing);
                    pending = self.pendingCount(pending);
                    feedback_pending = self.feedbackPendingCount(feedback_pending);
                };
            }
            self.publish(gateway, delivery, pending, feedback_pending);
            self.sleep(signal, gateway.clock.nowMs(), if (config.enabled) wake_at_ms else null);
        }
    }

    const PendingNowPlaying = struct {
        listen: Listen,
        heard_at_ms: i64,
    };

    fn pass(
        self: *Worker,
        gateway: *network.Gateway,
        delivery: *listenbrainz.Delivery,
        now_playing: *?PendingNowPlaying,
    ) i64 {
        const listens = self.step(gateway, delivery);
        if (listens.due_now) return listens.wake_at_ms;
        self.sendNowPlaying(delivery, now_playing);
        return @min(listens.wake_at_ms, self.syncFeedback(gateway, delivery));
    }

    const Step = struct {
        wake_at_ms: i64,
        due_now: bool = false,
    };

    fn step(self: *Worker, gateway: *network.Gateway, delivery: *listenbrainz.Delivery) Step {
        const now_unix_s = self.nowUnixSeconds();
        const result = delivery.step(now_unix_s) catch |err| {
            delivery.current.last_error.set(@errorName(err));
            return .{ .wake_at_ms = failureWake(gateway, &self.listen_failures) };
        };
        self.listen_failures = 0;
        const wake_after_ms = @min(result.wake_after_ms orelse idle_recheck_ms, idle_recheck_ms);
        return .{
            .wake_at_ms = gateway.clock.nowMs() +| std.math.lossyCast(i64, wake_after_ms),
            .due_now = wake_after_ms == 0 and madeProgress(result.outcome),
        };
    }

    fn madeProgress(outcome: listenbrainz.Outcome) bool {
        return switch (outcome) {
            .delivered, .rejected, .isolating => true,
            .idle, .blocked, .deferred, .canceled => false,
        };
    }

    fn sendNowPlaying(
        self: *Worker,
        delivery: *listenbrainz.Delivery,
        now_playing: *?PendingNowPlaying,
    ) void {
        const pending = now_playing.* orelse return;
        now_playing.* = null;
        if (self.sampleNowMs() - pending.heard_at_ms >= now_playing_maximum_age_ms) return;
        const subject = (self.database.listens.listenSubject(self.allocator, pending.listen.track_id) catch
            return) orelse return;
        defer subject.deinit();
        var event = providers.scrobble.Event.fromSubject(&subject, pending.listen.started_at, pending.listen.listened_ms);
        if (event.duration_ms == 0) event.duration_ms = pending.listen.duration_ms;
        if (event.title.len == 0 or event.artist.len == 0) return;
        _ = delivery.sendNowPlaying(event, self.nowUnixSeconds()) catch |err|
            delivery.current.last_error.set(@errorName(err));
    }

    fn syncFeedback(self: *Worker, gateway: *network.Gateway, delivery: *listenbrainz.Delivery) i64 {
        const result = delivery.syncFeedback(&self.database.feedback, self.nowUnixSeconds()) catch |err| {
            delivery.current.last_error.set(@errorName(err));
            return failureWake(gateway, &self.feedback_failures);
        };
        self.feedback_failures = 0;
        const wake_after_ms: u64 = switch (result.outcome) {
            .delivered, .rejected, .canceled => 0,
            .idle, .blocked, .deferred, .isolating => @min(result.wake_after_ms orelse idle_recheck_ms, idle_recheck_ms),
        };
        return gateway.clock.nowMs() +| std.math.lossyCast(i64, wake_after_ms);
    }

    fn failureWake(gateway: *network.Gateway, failures: *u32) i64 {
        const doublings: u6 = @intCast(@min(failures.*, 6));
        failures.* +|= 1;
        const backoff_ms = @min(failure_backoff_ms << doublings, maximum_failure_backoff_ms);
        return gateway.clock.nowMs() +| @as(i64, @intCast(backoff_ms));
    }

    fn sampleNowMs(self: *Worker) i64 {
        if (self.hooks.sample_clock) |clock| return clock.now().mono_ms;
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    fn nowUnixSeconds(self: *Worker) i64 {
        return if (self.hooks.wall_clock) |wall|
            @divFloor(wall.nowMs(), 1000)
        else
            std.Io.Clock.real.now(self.io).toSeconds();
    }

    /// Validates the token once per credentials change, and only when a
    /// request could go out now. The generation is marked first, so a
    /// failure is reported rather than retried on every pass.
    fn validateOnce(
        self: *Worker,
        gateway: *network.Gateway,
        delivery: *listenbrainz.Delivery,
        generation: u32,
        config: Config,
    ) void {
        const validated = self.listens.credentials_validated.load(.monotonic);
        if (validated == generation) return;
        if (config.offline or delivery.waitingForLease()) return;
        gateway.loadSharedState() catch |err| {
            delivery.current.last_error.set(@errorName(err));
            return;
        };
        if (gateway.blockedUntilMs() != null) return;
        self.listens.credentials_validated.store(generation, .monotonic);
        const token = delivery.credentials.get(self.allocator, listenbrainz.token_service, listenbrainz.token_account) catch |err| {
            delivery.current.last_error.set(@errorName(err));
            return;
        } orelse return;
        defer providers.credentials.wipeAndFree(self.allocator, token);
        const user_name = delivery.validateToken(token) catch |err| {
            if (err == error.ProviderBusy) self.listens.credentials_validated.store(validated, .monotonic);
            delivery.validationFailed(err, self.nowUnixSeconds()) catch |failure|
                delivery.current.last_error.set(@errorName(failure));
            return;
        };
        if (user_name) |name| self.allocator.free(name);
    }

    const Drained = struct {
        recorded: bool = false,
        queued: bool = false,
        now_playing: ?Entry = null,
    };

    fn drainRing(self: *Worker, config: Config) Drained {
        var drained: Drained = .{};
        while (self.listens.ring.pop()) |entry| switch (entry.kind) {
            .eligible => switch (self.record(entry.listen, config)) {
                .dropped => {
                    _ = self.listens.dropped.fetchAdd(1, .monotonic);
                    self.listens.raiseHost();
                },
                .duplicate => {},
                .recorded, .queued => |outcome| {
                    _ = self.listens.recorded.fetchAdd(1, .monotonic);
                    self.listens.raiseHost();
                    drained.recorded = true;
                    drained.queued = drained.queued or outcome == .queued;
                },
            },
            .finished => if (self.finish(entry.listen, config)) {
                drained.queued = true;
            },
            .now_playing => {
                drained.now_playing = entry;
            },
        };
        return drained;
    }

    const Recorded = enum { dropped, duplicate, recorded, queued };

    fn record(self: *Worker, listen: Listen, config: Config) Recorded {
        const subject = (self.database.listens.listenSubject(self.allocator, listen.track_id) catch
            return .dropped) orelse return .dropped;
        defer subject.deinit();
        const file_id = subject.file_id orelse return .dropped;
        const input: database.ListenInput = .{
            .file_id = file_id,
            .started_at = listen.started_at,
            .listened_ms = listen.listened_ms,
            .duration_ms = listen.duration_ms,
            .title = subject.title,
            .artist = subject.artist,
            .album = subject.album,
            .recording_mbid = subject.recording_mbid,
            .player_client = if (config.identity) |*owned| owned.view().name else "",
            .syncable = listen.syncable,
        };
        if (config.enabled and listen.syncable) {
            var event = providers.scrobble.Event.fromSubject(&subject, listen.started_at, listen.listened_ms);
            if (event.duration_ms == 0) event.duration_ms = listen.duration_ms;
            if (event.eligible()) {
                const payload = event.encode(self.allocator) catch return .dropped;
                defer self.allocator.free(payload);
                const id = self.database.listens.recordAndQueue(input, listenbrainz.service, payload) catch
                    return .dropped;
                return if (id == null) .duplicate else .queued;
            }
        }
        const id = self.database.listens.record(input) catch return .dropped;
        return if (id == null) .duplicate else .recorded;
    }

    /// Raises the recorded listen to the time finally heard, and queues a
    /// listen kept as local only once that time meets ListenBrainz's rule.
    /// The listen already stands as recorded, so a failure here loses only
    /// the extra. Returns whether it queued.
    fn finish(self: *Worker, listen: Listen, config: Config) bool {
        const subject = (self.database.listens.listenSubject(self.allocator, listen.track_id) catch
            return false) orelse return false;
        defer subject.deinit();
        const file_id = subject.file_id orelse return false;
        if (!listen.syncable) {
            self.database.listens.updateListened(file_id, listen.started_at, listen.listened_ms) catch {};
            return false;
        }
        var payload: ?[]u8 = null;
        defer if (payload) |bytes| self.allocator.free(bytes);
        if (config.enabled) {
            var event = providers.scrobble.Event.fromSubject(&subject, listen.started_at, listen.listened_ms);
            if (event.duration_ms == 0) event.duration_ms = listen.duration_ms;
            if (event.eligible()) payload = event.encode(self.allocator) catch null;
        }
        return self.database.listens.finishSyncable(
            file_id,
            listen.started_at,
            listen.listened_ms,
            listenbrainz.service,
            payload,
        ) catch false;
    }

    fn pendingCount(self: *Worker, previous: u64) u64 {
        return self.database.scrobbles.pendingCount() catch previous;
    }

    fn feedbackPendingCount(self: *Worker, previous: u64) u64 {
        return self.database.feedback.pendingSyncCount() catch previous;
    }

    fn publish(
        self: *Worker,
        gateway: *network.Gateway,
        delivery: *const listenbrainz.Delivery,
        pending: u64,
        feedback_pending: u64,
    ) void {
        const current = delivery.status();
        const status: Status = .{
            .state = current.state,
            .user_name = current.user_name,
            .last_error = current.last_error,
            .next_attempt_at = current.next_attempt_at,
            .blocked_until = blockEnd(gateway.blockedUntilWallMs(), self.nowUnixSeconds()),
            .pending = pending,
            .feedback_pending = feedback_pending,
            .delivered_total = current.delivered_total,
        };
        if (status.eql(self.published)) return;
        self.published = status;
        self.listens.status.store(status);
        self.listens.raiseHost();
    }

    fn sleep(self: *Worker, seen_signal: u32, now_ms: i64, wake_at_ms: ?i64) void {
        var milliseconds = self.hooks.poll_ms;
        if (wake_at_ms) |due| milliseconds = @min(milliseconds, std.math.lossyCast(u64, due -| now_ms));
        if (milliseconds == 0) return;
        self.io.futexWaitTimeout(u32, &self.listens.signal.raw, seen_signal, .{ .duration = .{
            .raw = .fromMilliseconds(@intCast(milliseconds)),
            .clock = .awake,
        } }) catch {};
    }

    fn credentialStore(self: *Worker, config: Config) providers.credentials.Store {
        return config.credentials orelse .{ .context = self, .get_fn = noCredential };
    }

    fn noCredential(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!?[]u8 {
        return null;
    }
};

/// Whether two configs send to the same server with the same token store,
/// so a rejected token or a backoff still applies.
fn sameDestination(a: Config, b: Config) bool {
    if (!std.mem.eql(u8, a.server.view(), b.server.view())) return false;
    const left = a.credentials orelse return b.credentials == null;
    const right = b.credentials orelse return false;
    return left.context == right.context and left.get_fn == right.get_fn;
}

const testing = std.testing;

const RequestKind = enum { listens, now_playing, feedback };

const TestService = struct {
    transport: network.testing.ScriptedTransport,
    clock: network.testing.TestClock,
    requests: std.ArrayList(RequestKind),
    listens_status: u16,
    now_playing_status: u16,
    feedback_status: u16,
    token_lookups: usize,

    const wall_base_ms: i64 = 2_000_000_000_000;

    fn start(self: *TestService) void {
        self.* = .{
            .transport = .{},
            .clock = .{ .wall_offset_ms = wall_base_ms },
            .requests = .empty,
            .listens_status = 200,
            .now_playing_status = 200,
            .feedback_status = 200,
            .token_lookups = 0,
        };
        self.transport.responder = .{ .context = self, .respond_fn = respond };
    }

    fn deinit(self: *TestService) void {
        self.requests.deinit(testing.allocator);
        self.transport.deinit();
    }

    fn now(self: *const TestService) i64 {
        return self.clock.now();
    }

    fn sampleClock(self: *TestService) SampleClock {
        return .{ .context = self, .now_fn = sampleNow };
    }

    fn sampleNow(context: *anyopaque) SampleTime {
        const self: *TestService = @ptrCast(@alignCast(context));
        return .{ .mono_ms = self.clock.now(), .wall_s = @divFloor(self.clock.wallNow(), 1000) };
    }

    fn store(self: *TestService) providers.credentials.Store {
        return .{ .context = self, .get_fn = token };
    }

    fn count(self: *const TestService, kind: RequestKind) usize {
        return std.mem.count(RequestKind, self.requests.items, &.{kind});
    }

    fn respond(context: *anyopaque, exchange: network.testing.Exchange, _: ?network.testing.Reply) anyerror!network.testing.Reply {
        const self: *TestService = @ptrCast(@alignCast(context));
        const kind: RequestKind = if (std.mem.endsWith(u8, exchange.request.url, "/recording-feedback"))
            .feedback
        else if (std.mem.indexOf(u8, exchange.form, "\"playing_now\"") != null)
            .now_playing
        else
            .listens;
        try self.requests.append(testing.allocator, kind);
        const status = switch (kind) {
            .listens => self.listens_status,
            .now_playing => self.now_playing_status,
            .feedback => self.feedback_status,
        };
        return .{ .respond = .{ .status = status } };
    }

    fn token(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!?[]u8 {
        const self: *TestService = @ptrCast(@alignCast(context));
        self.token_lookups += 1;
        return try allocator.dupe(u8, "secret-token");
    }
};

const TestRig = struct {
    library: database.LibraryDatabase,
    listens: Listens,
    service: TestService,
    prng: std.Random.DefaultPrng,
    gateway: network.Gateway,
    delivery: listenbrainz.Delivery,
    worker: Worker,
    now_playing: ?Worker.PendingNowPlaying,

    fn start(self: *TestRig, comptime name: []const u8) !void {
        self.library = try database.LibraryDatabase.open(
            testing.allocator,
            testing.io,
            "file:orca-worker-" ++ name ++ "?mode=memory&cache=shared",
        );
        self.listens = .{};
        self.service.start();
        self.prng = .init(network.testing.default_seed);
        self.gateway = network.testing.gateway(&self.service.transport, &self.service.clock, &self.prng, .{ .identity = network.testing.test_identity });
        self.delivery = .init(testing.allocator, testing.io, &self.gateway, self.service.store(), &self.library.scrobbles);
        self.worker = .{
            .allocator = testing.allocator,
            .io = testing.io,
            .database = &self.library,
            .listens = &self.listens,
            .registration = undefined,
            .hooks = .{ .wall_clock = self.service.clock.wallClock(), .sample_clock = self.service.sampleClock() },
        };
        self.now_playing = null;
    }

    fn stop(self: *TestRig) void {
        self.service.deinit();
        self.library.close();
    }

    fn pass(self: *TestRig) i64 {
        return self.worker.pass(&self.gateway, &self.delivery, &self.now_playing);
    }

    fn addTrack(self: *TestRig, mbid: ?[]const u8) !i64 {
        const library = &self.library;
        try library.database.exec("INSERT INTO recordings(title) VALUES ('Song');");
        var recording = try library.database.prepare("SELECT max(id) FROM recordings;");
        defer recording.deinit();
        if (try recording.step() != .row) return error.SqlFailed;
        const recording_id = recording.columnInt64(0);
        const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
        var assign = try library.database.prepare("UPDATE files SET recording_id = ?1 WHERE id = ?2;");
        defer assign.deinit();
        try assign.bindInt64(1, recording_id);
        try assign.bindInt64(2, file_id);
        if (try assign.step() != .done) return error.SqlFailed;
        try library.observed_tags.upsert(.{ .file_id = file_id, .values = .{
            .title = "Song",
            .musicbrainz_recording_id = mbid,
        } });
        try library.tracks.upsertTracks(&.{.{
            .recording_id = recording_id,
            .title = "Song",
            .artist = "Test Artist",
            .duration_ms = 180_000,
            .preferred_file_id = file_id,
        }});
        var find = try library.database.prepare("SELECT id FROM tracks WHERE preferred_file_id = ?1;");
        defer find.deinit();
        try find.bindInt64(1, file_id);
        if (try find.step() != .row) return error.SqlFailed;
        return find.columnInt64(0);
    }

    fn love(self: *TestRig, track_id: i64) !void {
        _ = try self.library.feedback.set(&.{track_id}, .loved);
    }

    fn queueListens(self: *TestRig, total: usize) !void {
        for (0..total) |index| {
            var key: [32]u8 = undefined;
            _ = try providers.scrobble.enqueueEligible(
                testing.allocator,
                &self.library.scrobbles,
                listenbrainz.service,
                try std.fmt.bufPrint(&key, "listen:{d}", .{index + 1}),
                .{
                    .title = "Track",
                    .artist = "Test Artist",
                    .started_at = 1_700_000_000 + @as(i64, @intCast(index)),
                    .duration_ms = 180_000,
                    .listened_ms = 100_000,
                },
            );
        }
    }

    fn announce(self: *TestRig, track_id: i64, age_ms: i64) void {
        self.now_playing = .{
            .listen = .{ .track_id = track_id, .started_at = 1_700_000_000, .listened_ms = 10_000, .duration_ms = 180_000 },
            .heard_at_ms = self.service.now() - age_ms,
        };
    }
};

fn expectRequests(rig: *const TestRig, expected: []const RequestKind) !void {
    try testing.expectEqualSlices(RequestKind, expected, rig.service.requests.items);
}

test "a due batch of listens goes out before Now Playing, which goes out before feedback" {
    var rig: TestRig = undefined;
    try rig.start("order");
    defer rig.stop();
    try rig.queueListens(250);
    const track = try rig.addTrack("8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a");
    try rig.love(track);
    rig.announce(track, 0);

    _ = rig.pass();
    try expectRequests(&rig, &.{.listens});
    try testing.expect(rig.now_playing != null);
    _ = rig.pass();
    try expectRequests(&rig, &.{ .listens, .listens });
    _ = rig.pass();
    try expectRequests(&rig, &.{ .listens, .listens, .listens, .now_playing, .feedback });
    try testing.expect(rig.now_playing == null);
}

test "Now Playing is sent as playing_now once, and never again" {
    var rig: TestRig = undefined;
    try rig.start("now-playing-once");
    defer rig.stop();
    const track = try rig.addTrack(null);
    rig.announce(track, 0);

    _ = rig.pass();
    _ = rig.pass();

    try expectRequests(&rig, &.{.now_playing});
}

test "Now Playing older than a minute when it would be sent is dropped" {
    var rig: TestRig = undefined;
    try rig.start("now-playing-stale");
    defer rig.stop();
    const track = try rig.addTrack(null);

    rig.announce(track, 60_000);
    _ = rig.pass();
    try expectRequests(&rig, &.{});
    try testing.expect(rig.now_playing == null);

    rig.announce(track, 59_000);
    _ = rig.pass();
    try expectRequests(&rig, &.{.now_playing});
}

test "Now Playing refused by a rate limit is dropped, its successors are dropped while blocked, and none is retried" {
    var rig: TestRig = undefined;
    try rig.start("now-playing-limited");
    defer rig.stop();
    const track = try rig.addTrack(null);
    rig.service.now_playing_status = 429;

    rig.announce(track, 0);
    _ = rig.pass();
    try expectRequests(&rig, &.{.now_playing});
    try testing.expect(rig.now_playing == null);
    try testing.expect(rig.gateway.blockedUntilMs() != null);

    rig.service.now_playing_status = 200;
    rig.announce(track, 0);
    _ = rig.pass();
    try expectRequests(&rig, &.{.now_playing});
    try testing.expect(rig.now_playing == null);

    rig.service.clock.advance(120_000);
    _ = rig.pass();
    try expectRequests(&rig, &.{.now_playing});
}

test "Now Playing is not sent offline, without a token or after the token was refused" {
    var rig: TestRig = undefined;
    try rig.start("now-playing-gated");
    defer rig.stop();
    const track = try rig.addTrack(null);

    rig.gateway.config.offline = true;
    rig.announce(track, 0);
    _ = rig.pass();
    rig.gateway.config.offline = false;
    rig.delivery.token_rejected = true;
    rig.announce(track, 0);
    _ = rig.pass();

    try expectRequests(&rig, &.{});
    try testing.expectEqual(@as(usize, 0), rig.service.token_lookups);
}

test "a worker pass wakes the host only when its status changes" {
    var rig: TestRig = undefined;
    try rig.start("wake-on-change");
    defer rig.stop();
    var counter: control.CountingWaker = .{};
    var signal: control.HostSignal = .{ .waker = counter.waker() };
    rig.listens.host_signal = &signal;
    try rig.queueListens(1);

    rig.worker.publish(&rig.gateway, &rig.delivery, rig.worker.pendingCount(0), 0);
    try testing.expectEqual(@as(u32, 1), counter.count());
    signal.clear();
    rig.worker.publish(&rig.gateway, &rig.delivery, rig.worker.pendingCount(0), 0);
    try testing.expect(!signal.isPending());

    _ = rig.pass();
    rig.worker.publish(&rig.gateway, &rig.delivery, rig.worker.pendingCount(0), 0);
    try testing.expectEqual(@as(u32, 2), counter.count());
    try testing.expectEqual(@as(u64, 1), rig.listens.snapshot().delivered_total);
    signal.clear();
    _ = rig.pass();
    rig.worker.publish(&rig.gateway, &rig.delivery, rig.worker.pendingCount(0), 0);
    try testing.expect(!signal.isPending());
}

test "a recorded listen wakes the host" {
    var rig: TestRig = undefined;
    try rig.start("wake-on-record");
    defer rig.stop();
    var counter: control.CountingWaker = .{};
    var signal: control.HostSignal = .{ .waker = counter.waker() };
    rig.listens.host_signal = &signal;
    const track = try rig.addTrack(null);
    const listen: Listen = .{ .track_id = track, .started_at = 1_700_000_000, .listened_ms = 100_000, .duration_ms = 180_000 };
    _ = rig.listens.ring.push(.{ .kind = .eligible, .listen = listen });

    try testing.expect(rig.worker.drainRing(.{}).recorded);
    try testing.expectEqual(@as(u32, 1), counter.count());
    try testing.expectEqual(@as(u64, 1), rig.listens.recorded.load(.monotonic));
}

test "feedback goes out one change per pass, and a pass that sent one asks to run again at once" {
    var rig: TestRig = undefined;
    try rig.start("feedback-per-pass");
    defer rig.stop();
    for (0..3) |index| {
        var mbid: [36]u8 = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a".*;
        mbid[35] = "abc"[index];
        try rig.love(try rig.addTrack(&mbid));
    }

    for (1..4) |sent| {
        const wake = rig.pass();
        try testing.expectEqual(sent, rig.service.count(.feedback));
        try testing.expect(wake <= rig.service.now());
    }
    const idle = rig.pass();
    try testing.expectEqual(@as(usize, 3), rig.service.count(.feedback));
    try testing.expect(idle >= rig.service.now() + idle_recheck_ms);
}

test "a pass with only feedback lacking a recording id looks up no token and makes no request" {
    var rig: TestRig = undefined;
    try rig.start("feedback-untagged");
    defer rig.stop();
    try rig.love(try rig.addTrack(null));

    const wake = rig.pass();

    try expectRequests(&rig, &.{});
    try testing.expectEqual(@as(usize, 0), rig.service.token_lookups);
    try testing.expect(wake >= rig.service.now() + idle_recheck_ms);
    try testing.expectEqual(@as(u64, 0), rig.worker.feedbackPendingCount(7));
}

test "a rate limit on feedback holds back listens until the block ends" {
    var rig: TestRig = undefined;
    try rig.start("feedback-limits-listens");
    defer rig.stop();
    try rig.love(try rig.addTrack("8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a"));
    rig.service.feedback_status = 429;
    _ = rig.pass();
    try expectRequests(&rig, &.{.feedback});

    try rig.queueListens(1);
    rig.service.feedback_status = 200;
    const wake = rig.pass();
    try expectRequests(&rig, &.{.feedback});
    try testing.expect(wake > rig.service.now());

    rig.service.clock.advance(60_000);
    _ = rig.pass();
    try expectRequests(&rig, &.{ .feedback, .listens, .feedback });
}

test "a feedback change that could not be marked is not resent and its retries back off 60 s, 120 s, 240 s" {
    var rig: TestRig = undefined;
    try rig.start("mark-backoff");
    defer rig.stop();
    try rig.love(try rig.addTrack("8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a"));
    try rig.library.database.exec(
        "CREATE TRIGGER refuse_mark BEFORE UPDATE ON feedback BEGIN SELECT RAISE(ABORT, 'refused'); END;",
    );

    for ([_]i64{ 60_000, 120_000, 240_000 }) |backoff| {
        const wake = rig.pass();
        try testing.expectEqual(backoff, wake - rig.service.now());
        rig.service.clock.set(wake);
    }
    try testing.expectEqual(@as(usize, 1), rig.service.count(.feedback));

    try rig.library.database.exec("DROP TRIGGER refuse_mark;");
    _ = rig.pass();
    try testing.expectEqual(@as(u32, 0), rig.worker.feedback_failures);
    try testing.expectEqual(@as(usize, 1), rig.service.count(.feedback));
}

test "listens whose delivery cannot be marked back off 60 s, 120 s and on to an hour" {
    var rig: TestRig = undefined;
    try rig.start("listen-mark-backoff");
    defer rig.stop();
    try rig.queueListens(1);
    try rig.library.database.exec(
        "CREATE TRIGGER refuse_mark BEFORE UPDATE ON scrobble_queue WHEN NEW.state = 2 " ++
            "BEGIN SELECT RAISE(ABORT, 'refused'); END;",
    );

    for ([_]i64{ 60_000, 120_000, 240_000 }) |backoff| {
        const wake = rig.pass();
        try testing.expectEqual(backoff, wake - rig.service.now());
        rig.service.clock.set(wake);
    }
    try testing.expectEqual(@as(usize, 3), rig.service.count(.listens));

    try rig.library.database.exec("DROP TRIGGER refuse_mark;");
    _ = rig.pass();
    try testing.expectEqual(@as(u32, 0), rig.worker.listen_failures);
    try testing.expectEqual(@as(u64, 1), try rig.library.scrobbles.deliveredCount(listenbrainz.service));
}

test "Now Playing is aged from when it was heard, not from when the worker drained it" {
    var rig: TestRig = undefined;
    try rig.start("now-playing-drain");
    defer rig.stop();
    const track = try rig.addTrack(null);
    rig.service.clock.set(100_000);
    const config: Config = .{ .enabled = true, .now_playing = true };
    const listen: Listen = .{ .track_id = track, .started_at = 1_700_000_000, .listened_ms = 10_000, .duration_ms = 180_000 };

    for ([_]i64{ 30_000, 95_000 }) |heard_at_ms| {
        _ = rig.listens.ring.push(.{ .kind = .now_playing, .listen = listen, .mono_ms = heard_at_ms });
        const entry = rig.worker.drainRing(config).now_playing.?;
        try testing.expectEqual(heard_at_ms, entry.mono_ms);
        rig.now_playing = .{ .listen = entry.listen, .heard_at_ms = entry.mono_ms };
        _ = rig.pass();
    }

    try expectRequests(&rig, &.{.now_playing});
}

test "repeated failures double the wait from a minute up to an hour and no further" {
    var rig: TestRig = undefined;
    try rig.start("failure-wake");
    defer rig.stop();
    var failures: u32 = 0;
    for ([_]i64{ 60_000, 120_000, 240_000, 480_000, 960_000, 1_920_000, 3_600_000, 3_600_000 }) |expected| {
        try testing.expectEqual(expected, Worker.failureWake(&rig.gateway, &failures) - rig.service.now());
    }
}
