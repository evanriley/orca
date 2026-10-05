//! Keeps a Gateway's rate-limit state and service lease in the Library, so
//! every process that opens it obeys one block and only one at a time talks
//! to each service.

const std = @import("std");
const database = @import("../database/root.zig");
const network = @import("../network/root.zig");

const StateStore = network.client.StateStore;
const SharedState = network.client.SharedState;

pub fn store(repository: *database.ProviderStateRepository) StateStore {
    return .{
        .context = repository,
        .load_fn = load,
        .save_fn = save,
        .claim_fn = claim,
        .release_fn = release,
    };
}

fn load(context: *anyopaque, service: []const u8) anyerror!?SharedState {
    const repository: *database.ProviderStateRepository = @ptrCast(@alignCast(context));
    const stored = try repository.get(service) orelse return null;
    return .{
        .blocked_until_ms = stored.blocked_until_ms,
        .backoff_ms = stored.backoff_ms,
        .next_request_ms = stored.next_request_ms,
    };
}

fn save(context: *anyopaque, service: []const u8, state: SharedState) anyerror!void {
    const repository: *database.ProviderStateRepository = @ptrCast(@alignCast(context));
    try repository.put(service, .{
        .blocked_until_ms = state.blocked_until_ms,
        .backoff_ms = state.backoff_ms,
        .next_request_ms = state.next_request_ms,
    });
}

fn claim(context: *anyopaque, service: []const u8, owner: i64, now_ms: i64, expires_at_ms: i64) anyerror!bool {
    const repository: *database.ProviderStateRepository = @ptrCast(@alignCast(context));
    return repository.claimLease(service, owner, now_ms, expires_at_ms);
}

fn release(context: *anyopaque, service: []const u8, owner: i64) anyerror!void {
    const repository: *database.ProviderStateRepository = @ptrCast(@alignCast(context));
    try repository.releaseLease(service, owner);
}

const testing = std.testing;

const Service = struct {
    transport: network.testing.ScriptedTransport = .{},
    clock: network.testing.TestClock = .startingAt(1_800_000_000_000),

    fn deinit(self: *Service) void {
        self.transport.deinit();
    }

    fn respond(self: *Service, status: u16, retry_after: ?network.client.RetryAfter) void {
        self.transport.otherwise = .{ .respond = .{ .status = status, .rate_limit = .{ .retry_after = retry_after } } };
    }

    fn requestCount(self: *const Service) u32 {
        return self.transport.requestCount();
    }
};

/// One process's view: its own connection to the shared Library, its own
/// clock origin and its own Gateway.
const Process = struct {
    library: database.LibraryDatabase,
    prng: std.Random.DefaultPrng,
    monotonic: network.testing.OffsetClock,
    gateway: network.Gateway,

    fn start(self: *Process, uri: [:0]const u8, service: *Service, seed: u64) !void {
        self.library = try database.LibraryDatabase.open(testing.allocator, testing.io, uri);
        self.prng = .init(seed);
        self.monotonic = .{ .base = &service.clock, .offset_ms = service.clock.now() - @as(i64, @intCast(seed)) * 1000 };
        self.gateway = .{
            .transport = service.transport.transport(),
            .clock = self.monotonic.clock(),
            .wall_clock = service.clock.wallClock(),
            .random = self.prng.random(),
            .config = .{ .identity = network.testing.test_identity, .minimum_interval_ms = 0 },
            .sharing = .{ .store = store(&self.library.provider_state), .service = "musicbrainz" },
        };
    }

    fn stop(self: *Process) void {
        self.library.close();
    }

    fn fetch(self: *Process) !u16 {
        const response = try self.gateway.execute(testing.allocator, .get, "https://example.test", null, &.{});
        defer response.deinit();
        return response.status;
    }
};

test "a block one Gateway stored is obeyed by a fresh Gateway over the same database" {
    const uri = "file:orca-shared-state-block?mode=memory&cache=shared";
    var service: Service = .{};
    defer service.deinit();
    service.respond(429, .{ .seconds = 600 });
    var first: Process = undefined;
    try first.start(uri, &service, 1);
    defer first.stop();
    try testing.expectError(error.RateLimited, first.fetch());

    var second: Process = undefined;
    try second.start(uri, &service, 2);
    defer second.stop();
    service.respond(200, null);
    service.clock.advance(599_000);
    try testing.expectError(error.RateLimited, second.fetch());
    try testing.expectEqual(@as(u32, 1), service.requestCount());
    try testing.expectEqual(@as(?i64, service.clock.now() + 1000), second.gateway.blockedUntilWallMs());
    try testing.expectEqual(@as(u64, 60_000), second.gateway.rate_limit_backoff_ms);

    service.clock.advance(1000);
    try testing.expectEqual(@as(u16, 200), try second.fetch());
    try testing.expectEqual(@as(u32, 2), service.requestCount());
    try testing.expectEqual(@as(u64, 0), (try second.library.provider_state.get("musicbrainz")).?.backoff_ms);
}

test "a backoff a caller chose is shared like a rate limit" {
    const uri = "file:orca-shared-state-backoff?mode=memory&cache=shared";
    var service: Service = .{};
    defer service.deinit();
    var first: Process = undefined;
    try first.start(uri, &service, 1);
    defer first.stop();
    try first.gateway.blockFor(120_000);

    var second: Process = undefined;
    try second.start(uri, &service, 2);
    defer second.stop();
    try testing.expectError(error.RateLimited, second.fetch());
    try testing.expectEqual(@as(u32, 0), service.requestCount());
    service.clock.advance(120_000);
    try testing.expectEqual(@as(u16, 200), try second.fetch());
}

test "Gateways over one store take turns at the service's interval, each waiting only for the request in flight" {
    const uri = "file:orca-shared-state-turns?mode=memory&cache=shared";
    var service: Service = .{};
    defer service.deinit();
    service.transport.clock = &service.clock;
    var first: Process = undefined;
    try first.start(uri, &service, 1);
    defer first.stop();
    first.gateway.config.minimum_interval_ms = 1000;
    var second: Process = undefined;
    try second.start(uri, &service, 2);
    defer second.stop();
    second.gateway.config.minimum_interval_ms = 1000;
    const started = service.clock.now();

    try testing.expectEqual(@as(u16, 200), try first.fetch());
    try testing.expectEqual(@as(u16, 200), try second.fetch());
    try testing.expectEqual(@as(u16, 200), try first.fetch());
    try testing.expectEqual(@as(u16, 200), try second.fetch());
    try testing.expectEqualSlices(
        i64,
        &.{ started, started + 1000, started + 2000, started + 3000 },
        service.transport.request_times_ms[0..4],
    );
    try expectFree(&service, &first.library);
}

test "a request longer than the lease extends its claim before it is sent" {
    const uri = "file:orca-shared-state-long?mode=memory&cache=shared";
    var service: Service = .{};
    defer service.deinit();
    var first: Process = undefined;
    try first.start(uri, &service, 1);
    defer first.stop();
    first.gateway.config.request_timeout_ms = 300_000;
    var hold: Hold = .{ .service = &service, .library = &first.library, .request_ms = 2 * network.client.lease_duration_ms };
    service.transport.responder = .{ .context = &hold, .respond_fn = Hold.respond };

    try testing.expectEqual(@as(u16, 200), try first.fetch());
    try testing.expectEqualSlices(bool, &.{false}, hold.claimed[0..hold.count]);
    try expectFree(&service, &first.library);
}

test "a redirected fetch holds one lease across its hops and releases it after" {
    const uri = "file:orca-shared-state-redirect?mode=memory&cache=shared";
    var service: Service = .{};
    defer service.deinit();
    var first: Process = undefined;
    try first.start(uri, &service, 1);
    defer first.stop();
    var hold: Hold = .{ .service = &service, .library = &first.library, .redirects = 2 };
    service.transport.responder = .{ .context = &hold, .respond_fn = Hold.respond };

    const response = try first.gateway.fetch(testing.allocator, "https://example.test/first", &.{}, .{ .host = "example.test" });
    defer response.deinit();
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expectEqualSlices(bool, &.{ false, false, false }, hold.claimed[0..hold.count]);
    try expectFree(&service, &first.library);
}

test "a lease its holder never released lets a waiter in once it expires, and a shorter deadline fails busy" {
    const uri = "file:orca-shared-state-expired?mode=memory&cache=shared";
    var service: Service = .{};
    defer service.deinit();
    service.transport.clock = &service.clock;
    var waiter: Process = undefined;
    try waiter.start(uri, &service, 1);
    defer waiter.stop();
    const left_at = service.clock.now();
    try testing.expect(try waiter.library.provider_state.claimLease(
        "musicbrainz",
        crashed_owner,
        service.clock.wallNow(),
        service.clock.wallNow() + network.client.lease_duration_ms,
    ));

    service.clock.advance(1000);
    try testing.expectEqual(@as(u16, 200), try waiter.fetch());
    try testing.expectEqual(@as(u32, 1), service.requestCount());
    const sent = service.transport.request_times_ms[0];
    try testing.expect(sent >= left_at + network.client.lease_duration_ms);
    try testing.expect(sent <= left_at + network.client.lease_duration_ms + 250);

    try testing.expect(try waiter.library.provider_state.claimLease(
        "musicbrainz",
        crashed_owner,
        service.clock.wallNow(),
        service.clock.wallNow() + network.client.lease_duration_ms,
    ));
    const deadline = waiter.monotonic.clock().nowMs() + 5_000;
    waiter.gateway.deadline_ms = deadline;
    try testing.expectError(error.ProviderBusy, waiter.fetch());
    try testing.expectEqual(deadline, waiter.monotonic.clock().nowMs());
    try testing.expectEqual(@as(u32, 1), service.requestCount());
}

test "a cancel while waiting for a held service ends the wait within one poll" {
    const uri = "file:orca-shared-state-cancel-poll?mode=memory&cache=shared";
    var service: Service = .{};
    defer service.deinit();
    var waiter: Process = undefined;
    try waiter.start(uri, &service, 1);
    defer waiter.stop();
    try testing.expect(try waiter.library.provider_state.claimLease(
        "musicbrainz",
        crashed_owner,
        service.clock.wallNow(),
        service.clock.wallNow() + network.client.lease_duration_ms,
    ));
    var cue: Cue = .{
        .inner = waiter.gateway.clock,
        .service = &service,
        .library = &waiter.library,
        .cancel_at_ms = service.clock.now() + 10_030,
    };
    waiter.gateway.clock = cue.clock();
    waiter.gateway.cancel = &cue.cancel;

    try testing.expectError(error.Canceled, waiter.fetch());
    try testing.expect(service.clock.now() - cue.cancel_at_ms.? <= 250);
    try testing.expectEqual(@as(u32, 0), service.requestCount());
}

test "a request releases the service when it fails, times out, is refused or is canceled waiting its turn" {
    const uri = "file:orca-shared-state-release?mode=memory&cache=shared";
    var service: Service = .{};
    defer service.deinit();
    var first: Process = undefined;
    try first.start(uri, &service, 1);
    defer first.stop();
    first.gateway.config.maximum_attempts = 2;

    service.transport.otherwise = .{ .fail = error.ConnectionRefused };
    try testing.expectError(error.NetworkUnavailable, first.fetch());
    try testing.expectEqual(@as(u32, 2), service.requestCount());
    try expectFree(&service, &first.library);

    service.transport.otherwise = .{ .fail = error.Timeout };
    try testing.expectError(error.Timeout, first.fetch());
    try expectFree(&service, &first.library);

    service.respond(200, null);
    try testing.expect(try first.library.provider_state.claimLease(
        "musicbrainz",
        crashed_owner,
        service.clock.wallNow(),
        service.clock.wallNow() + network.client.lease_duration_ms,
    ));
    var cue: Cue = .{
        .inner = first.gateway.clock,
        .service = &service,
        .library = &first.library,
        .release_at_ms = service.clock.now() + 500,
        .cancel_at_ms = service.clock.now() + 1_500,
    };
    first.gateway.clock = cue.clock();
    first.gateway.cancel = &cue.cancel;
    try testing.expectError(error.Canceled, first.fetch());
    try testing.expect(cue.released_at_ms != null);
    try testing.expect(cue.cancel.load(.acquire));
    try testing.expectEqual(@as(u32, 3), service.requestCount());
    try expectFree(&service, &first.library);
    first.gateway.clock = cue.inner;
    first.gateway.cancel = null;

    service.respond(429, .{ .seconds = 60 });
    service.clock.advance(5_000);
    try testing.expectError(error.RateLimited, first.fetch());
    try testing.expectEqual(@as(u32, 4), service.requestCount());
    try expectFree(&service, &first.library);
}

test "two Gateways with the same configuration over one connection take turns at the interval" {
    var library = try database.LibraryDatabase.open(testing.allocator, testing.io, "file:orca-shared-state-same?mode=memory&cache=shared");
    defer library.close();
    const shared = store(&library.provider_state);
    try expectTurns(.{ shared, shared }, .{ .{}, .{} });
}

test "two Gateways with different configurations over one connection take turns at the interval" {
    var library = try database.LibraryDatabase.open(testing.allocator, testing.io, "file:orca-shared-state-different?mode=memory&cache=shared");
    defer library.close();
    const shared = store(&library.provider_state);
    try expectTurns(.{ shared, shared }, .{
        .{ .deadline_ms = 60_000, .request_timeout_ms = 10_000 },
        .{ .maximum_attempts = 3 },
    });
}

test "Gateways over two connections to one database file take turns at the interval" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrintSentinel(testing.allocator, ".zig-cache/tmp/{s}/library.db", .{temporary.sub_path}, 0);
    defer testing.allocator.free(path);
    var one = try database.LibraryDatabase.open(testing.allocator, testing.io, path);
    defer one.close();
    var other = try database.LibraryDatabase.open(testing.allocator, testing.io, path);
    defer other.close();
    try expectTurns(.{ store(&one.provider_state), store(&other.provider_state) }, .{ .{}, .{} });
}

const crashed_owner: i64 = 99;
const wall_base_ms: i64 = 1_800_000_000_000;

fn expectFree(service: *Service, library: *database.LibraryDatabase) !void {
    const now = service.clock.wallNow();
    try testing.expect(try library.provider_state.claimLease("musicbrainz", 77, now, now + 1));
    try library.provider_state.releaseLease("musicbrainz", 77);
}

/// Answers each request as a slow or redirecting service would, noting
/// whether another owner could claim the service while it was in flight.
const Hold = struct {
    service: *Service,
    library: *database.LibraryDatabase,
    request_ms: i64 = 0,
    redirects: u32 = 0,
    claimed: [4]bool = undefined,
    count: usize = 0,

    fn respond(context: *anyopaque, exchange: network.testing.Exchange, _: ?network.testing.Reply) anyerror!network.testing.Reply {
        const self: *Hold = @ptrCast(@alignCast(context));
        self.service.clock.advance(self.request_ms);
        const now = self.service.clock.wallNow();
        self.claimed[self.count] = try self.library.provider_state.claimLease("musicbrainz", 77, now, now + 1);
        self.count += 1;
        if (exchange.index < self.redirects) return .{ .respond = .{ .status = 302, .location = "/next" } };
        return .{ .respond = .{} };
    }
};

/// The Gateway's own clock, except that while the Gateway sleeps on it, it
/// lets the crashed owner's lease go once `release_at_ms` passes, leaving a
/// next request time as a holder that just sent would, and sets `cancel`
/// once `cancel_at_ms` passes. Both times are on the service's clock.
const Cue = struct {
    inner: network.client.Clock,
    service: *Service,
    library: *database.LibraryDatabase,
    cancel: std.atomic.Value(bool) = .init(false),
    release_at_ms: ?i64 = null,
    released_at_ms: ?i64 = null,
    cancel_at_ms: ?i64 = null,

    fn clock(self: *Cue) network.client.Clock {
        return .{ .context = self, .now_ms_fn = readNow, .sleep_ms_fn = sleep };
    }

    fn readNow(context: *anyopaque) i64 {
        const self: *Cue = @ptrCast(@alignCast(context));
        return self.inner.nowMs();
    }

    fn sleep(context: *anyopaque, milliseconds: u64) anyerror!void {
        const self: *Cue = @ptrCast(@alignCast(context));
        try self.inner.sleepMs(milliseconds);
        const now = self.service.clock.now();
        if (self.release_at_ms) |at| if (self.released_at_ms == null and now >= at) {
            self.released_at_ms = now;
            try self.library.provider_state.put("musicbrainz", .{ .next_request_ms = self.service.clock.wallNow() + 3_000 });
            try self.library.provider_state.releaseLease("musicbrainz", crashed_owner);
        };
        if (self.cancel_at_ms) |at| if (now >= at) self.cancel.store(true, .release);
    }
};

const turn_interval_ms = 1000;
const turns_each = 4;

const Turn = struct { at_ms: i64, sender: usize };

const Turns = struct {
    sim: *network.testing.SimClock,
    mutex: std.Io.Mutex = .init,
    log: [2 * turns_each]Turn = undefined,
    count: usize = 0,

    fn record(self: *Turns, sender: usize) void {
        self.mutex.lockUncancelable(testing.io);
        defer self.mutex.unlock(testing.io);
        if (self.count < self.log.len) self.log[self.count] = .{ .at_ms = self.sim.now(), .sender = sender };
        self.count += 1;
    }
};

const Setup = struct {
    deadline_ms: ?i64 = null,
    request_timeout_ms: u64 = 30_000,
    maximum_attempts: u8 = 1,
};

const Sender = struct {
    turns: *Turns,
    index: usize,
    transport: network.testing.ScriptedTransport,
    prng: std.Random.DefaultPrng,
    gateway: network.Gateway,
    result: anyerror!void,

    fn init(self: *Sender, turns: *Turns, index: usize, state_store: StateStore, setup: Setup) void {
        self.* = .{
            .turns = turns,
            .index = index,
            .transport = .{},
            .prng = .init(index + 1),
            .gateway = undefined,
            .result = {},
        };
        self.transport.responder = .{ .context = self, .respond_fn = respond };
        self.gateway = .{
            .transport = self.transport.transport(),
            .clock = turns.sim.clock(),
            .wall_clock = turns.sim.wallClock(),
            .random = self.prng.random(),
            .config = .{
                .identity = network.testing.test_identity,
                .minimum_interval_ms = turn_interval_ms,
                .request_timeout_ms = setup.request_timeout_ms,
                .maximum_attempts = setup.maximum_attempts,
            },
            .deadline_ms = setup.deadline_ms,
            .sharing = .{ .store = state_store, .service = "musicbrainz" },
        };
    }

    fn respond(context: *anyopaque, _: network.testing.Exchange, _: ?network.testing.Reply) anyerror!network.testing.Reply {
        const self: *Sender = @ptrCast(@alignCast(context));
        self.turns.record(self.index);
        return .{ .respond = .{} };
    }

    fn run(self: *Sender) void {
        defer self.turns.sim.leave();
        self.result = self.send();
    }

    fn send(self: *Sender) !void {
        for (0..turns_each) |_| {
            const response = try self.gateway.execute(testing.allocator, .get, "https://example.test", null, &.{});
            response.deinit();
        }
    }
};

fn expectTurns(stores: [2]StateStore, setups: [2]Setup) !void {
    var sim: network.testing.SimClock = .init(testing.io, 0, wall_base_ms, 2);
    var turns: Turns = .{ .sim = &sim };
    var senders: [2]Sender = undefined;
    for (&senders, 0..) |*sender, index| sender.init(&turns, index, stores[index], setups[index]);
    defer for (&senders) |*sender| sender.transport.deinit();
    {
        var threads: [2]std.Thread = undefined;
        var spawned: usize = 0;
        defer for (threads[0..spawned]) |thread| thread.join();
        for (&threads, &senders) |*thread, *sender| {
            thread.* = std.Thread.spawn(.{}, Sender.run, .{sender}) catch |err| {
                for (spawned..threads.len) |_| sim.leave();
                return err;
            };
            spawned += 1;
        }
    }

    for (&senders) |*sender| try testing.expectEqual(@as(anyerror!void, {}), sender.result);
    try testing.expectEqual(@as(usize, 2 * turns_each), turns.count);
    for (turns.log[1..], turns.log[0 .. turns.log.len - 1]) |turn, previous| {
        try testing.expect(turn.sender != previous.sender);
        try testing.expect(turn.at_ms - previous.at_ms >= turn_interval_ms);
        try testing.expect(turn.at_ms - previous.at_ms <= turn_interval_ms + 250);
    }
}
