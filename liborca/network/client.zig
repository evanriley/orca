const std = @import("std");

pub const Method = enum { get, post };

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method = .get,
    url: []const u8,
    body: ?[]const u8 = null,
    headers: []const Header = &.{},
    user_agent: []const u8,
    max_response_bytes: usize,
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16,
    body: []u8,

    pub fn deinit(self: Response) void {
        self.allocator.free(self.body);
    }
};

pub const Transport = struct {
    context: *anyopaque,
    perform_fn: *const fn (*anyopaque, std.mem.Allocator, Request) anyerror!Response,

    pub fn perform(self: Transport, allocator: std.mem.Allocator, request: Request) !Response {
        return self.perform_fn(self.context, allocator, request);
    }
};

pub const Clock = struct {
    context: *anyopaque,
    now_ms_fn: *const fn (*anyopaque) i64,
    sleep_ms_fn: *const fn (*anyopaque, u64) anyerror!void,

    pub fn nowMs(self: Clock) i64 {
        return self.now_ms_fn(self.context);
    }

    pub fn sleepMs(self: Clock, milliseconds: u64) !void {
        try self.sleep_ms_fn(self.context, milliseconds);
    }
};

pub const Config = struct {
    user_agent: []const u8 = "Orca/0.9 (+https://orca-music.org)",
    minimum_interval_ms: u64 = 1000,
    maximum_attempts: u8 = 3,
    initial_backoff_ms: u64 = 250,
    max_response_bytes: usize = 4 * 1024 * 1024,
    offline: bool = false,
};

/// Central policy boundary for every provider request. Transport adapters only
/// perform I/O; rate limiting, retry/backoff, response bounds, and offline
/// behavior are enforced here.
pub const Gateway = struct {
    transport: Transport,
    clock: Clock,
    config: Config,
    rate_lock: std.atomic.Mutex = .unlocked,
    last_request_ms: ?i64 = null,

    pub fn execute(
        self: *Gateway,
        allocator: std.mem.Allocator,
        method: Method,
        url: []const u8,
        body: ?[]const u8,
        headers: []const Header,
    ) !Response {
        if (self.config.offline) return error.Offline;
        if (self.config.maximum_attempts == 0 or self.config.max_response_bytes == 0 or
            self.config.max_response_bytes == std.math.maxInt(usize) or
            self.config.minimum_interval_ms > std.math.maxInt(i64))
            return error.InvalidNetworkConfiguration;
        var attempt: u8 = 0;
        var backoff = self.config.initial_backoff_ms;
        while (attempt < self.config.maximum_attempts) : (attempt += 1) {
            try self.awaitRateLimit();
            const response = self.transport.perform(allocator, .{
                .method = method,
                .url = url,
                .body = body,
                .headers = headers,
                .user_agent = self.config.user_agent,
                .max_response_bytes = self.config.max_response_bytes,
            }) catch |err| switch (err) {
                error.OutOfMemory, error.ResponseTooLarge, error.Canceled => return err,
                else => {
                    if (attempt + 1 == self.config.maximum_attempts)
                        return error.NetworkUnavailable;
                    try self.clock.sleepMs(backoff);
                    backoff = @min(backoff *| 2, 60_000);
                    continue;
                },
            };
            if (!retryableStatus(response.status) or attempt + 1 == self.config.maximum_attempts)
                return response;
            response.deinit();
            try self.clock.sleepMs(backoff);
            backoff = @min(backoff *| 2, 60_000);
        }
        unreachable;
    }

    fn awaitRateLimit(self: *Gateway) !void {
        while (!self.rate_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.rate_lock.unlock();
        const now = self.clock.nowMs();
        if (self.last_request_ms) |last| {
            const next = last + @as(i64, @intCast(self.config.minimum_interval_ms));
            if (now < next) try self.clock.sleepMs(@intCast(next - now));
        }
        self.last_request_ms = self.clock.nowMs();
    }
};

fn retryableStatus(status: u16) bool {
    return status == 408 or status == 425 or status == 429 or status >= 500;
}

pub const StandardTransport = struct {
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) StandardTransport {
        return .{ .client = .{ .allocator = allocator, .io = io } };
    }

    pub fn deinit(self: *StandardTransport) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn transport(self: *StandardTransport) Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn perform(context: *anyopaque, allocator: std.mem.Allocator, request: Request) !Response {
        const self: *StandardTransport = @ptrCast(@alignCast(context));
        const storage = try allocator.alloc(u8, request.max_response_bytes + 1);
        defer allocator.free(storage);
        var writer = std.Io.Writer.fixed(storage);
        var standard_headers = try allocator.alloc(std.http.Header, request.headers.len + 1);
        defer allocator.free(standard_headers);
        standard_headers[0] = .{ .name = "user-agent", .value = request.user_agent };
        for (request.headers, standard_headers[1..]) |source, *destination|
            destination.* = .{ .name = source.name, .value = source.value };
        const fetched = self.client.fetch(.{
            .location = .{ .url = request.url },
            .method = switch (request.method) {
                .get => .GET,
                .post => .POST,
            },
            .payload = request.body,
            .response_writer = &writer,
            .extra_headers = standard_headers,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.ResponseTooLarge,
            else => return err,
        };
        const buffered = writer.buffered();
        if (buffered.len > request.max_response_bytes) return error.ResponseTooLarge;
        return .{
            .allocator = allocator,
            .status = @backingInt(fetched.status),
            .body = try allocator.dupe(u8, buffered),
        };
    }
};

pub const SystemClock = struct {
    io: std.Io,

    pub fn clock(self: *SystemClock) Clock {
        return .{ .context = self, .now_ms_fn = nowMs, .sleep_ms_fn = sleepMs };
    }

    fn nowMs(context: *anyopaque) i64 {
        const self: *SystemClock = @ptrCast(@alignCast(context));
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    fn sleepMs(context: *anyopaque, milliseconds: u64) !void {
        const self: *SystemClock = @ptrCast(@alignCast(context));
        try std.Io.sleep(self.io, .fromMilliseconds(@intCast(milliseconds)), .awake);
    }
};

test "gateway centrally retries rate limits and supports offline mode" {
    const Mock = struct {
        calls: u8 = 0,

        fn perform(context: *anyopaque, allocator: std.mem.Allocator, request: Request) !Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expectEqualStrings("Orca Test", request.user_agent);
            return .{
                .allocator = allocator,
                .status = if (self.calls < 3) 429 else 200,
                .body = try allocator.dupe(u8, if (self.calls < 3) "retry" else "ok"),
            };
        }
    };
    const FakeClock = struct {
        now: i64 = 0,
        slept: u64 = 0,

        fn nowMs(context: *anyopaque) i64 {
            return (@as(*@This(), @ptrCast(@alignCast(context)))).now;
        }

        fn sleepMs(context: *anyopaque, milliseconds: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.slept += milliseconds;
            self.now += @intCast(milliseconds);
        }
    };
    var mock: Mock = .{};
    var fake_clock: FakeClock = .{};
    var gateway: Gateway = .{
        .transport = .{ .context = &mock, .perform_fn = Mock.perform },
        .clock = .{
            .context = &fake_clock,
            .now_ms_fn = FakeClock.nowMs,
            .sleep_ms_fn = FakeClock.sleepMs,
        },
        .config = .{
            .user_agent = "Orca Test",
            .minimum_interval_ms = 100,
            .maximum_attempts = 3,
            .initial_backoff_ms = 10,
        },
    };
    const response = try gateway.execute(std.testing.allocator, .get, "https://example.test", null, &.{});
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("ok", response.body);
    try std.testing.expectEqual(@as(u8, 3), mock.calls);
    try std.testing.expect(fake_clock.slept >= 200);
    gateway.config.offline = true;
    try std.testing.expectError(error.Offline, gateway.execute(
        std.testing.allocator,
        .get,
        "https://example.test",
        null,
        &.{},
    ));
}
