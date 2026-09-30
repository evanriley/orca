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
    return .{ .blocked_until_ms = stored.blocked_until_ms, .backoff_ms = stored.backoff_ms };
}

fn save(context: *anyopaque, service: []const u8, state: SharedState) anyerror!void {
    const repository: *database.ProviderStateRepository = @ptrCast(@alignCast(context));
    try repository.put(service, .{ .blocked_until_ms = state.blocked_until_ms, .backoff_ms = state.backoff_ms });
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
            .config = .{ .minimum_interval_ms = 0 },
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
    first.gateway.releaseLease();

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

test "a second claimant of a service gets ProviderBusy and makes no request until the first releases it" {
    const uri = "file:orca-shared-state-busy?mode=memory&cache=shared";
    var service: Service = .{};
    defer service.deinit();
    var first: Process = undefined;
    try first.start(uri, &service, 1);
    defer first.stop();
    var second: Process = undefined;
    try second.start(uri, &service, 2);
    defer second.stop();

    try testing.expectEqual(@as(u16, 200), try first.fetch());
    try testing.expectError(error.ProviderBusy, second.fetch());
    try testing.expectEqual(@as(u32, 1), service.requestCount());
    service.clock.advance(network.client.lease_duration_ms - 1);
    try testing.expectEqual(@as(u16, 200), try first.fetch());
    service.clock.advance(network.client.lease_duration_ms - 1);
    try testing.expectError(error.ProviderBusy, second.fetch());

    first.gateway.releaseLease();
    try testing.expectEqual(@as(u16, 200), try second.fetch());
    try testing.expectError(error.ProviderBusy, first.fetch());
    try testing.expectEqual(@as(u32, 3), service.requestCount());
}

test "a lease its holder never released can be claimed once it expires" {
    const uri = "file:orca-shared-state-expired?mode=memory&cache=shared";
    var service: Service = .{};
    defer service.deinit();
    var crashed: Process = undefined;
    try crashed.start(uri, &service, 1);
    defer crashed.stop();
    try testing.expectEqual(@as(u16, 200), try crashed.fetch());

    var next: Process = undefined;
    try next.start(uri, &service, 2);
    defer next.stop();
    service.clock.advance(network.client.lease_duration_ms - 1);
    try testing.expectError(error.ProviderBusy, next.fetch());
    service.clock.advance(1);
    try testing.expectEqual(@as(u16, 200), try next.fetch());
    try testing.expectEqual(@as(u32, 2), service.requestCount());
}
