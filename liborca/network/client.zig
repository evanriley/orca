const std = @import("std");
const version = @import("../version.zig");

pub const Method = enum { get, post };

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Identity = struct {
    name: []const u8,
    version: []const u8,
    contact: []const u8,

    pub const orca: Identity = .{
        .name = "Orca",
        .version = std.fmt.comptimePrint("{f}", .{version.value}),
        .contact = "evan@evanriley.com",
    };

    pub fn validate(self: Identity) error{InvalidNetworkConfiguration}!void {
        inline for (.{ self.name, self.version, self.contact }) |field| {
            if (field.len == 0) return error.InvalidNetworkConfiguration;
            for (field) |byte| {
                if (byte < 0x20 or byte == 0x7f or byte == '(' or byte == ')')
                    return error.InvalidNetworkConfiguration;
            }
        }
    }

    pub fn isOrca(self: Identity) bool {
        return std.mem.eql(u8, self.name, orca.name) and
            std.mem.eql(u8, self.version, orca.version) and
            std.mem.eql(u8, self.contact, orca.contact);
    }

    pub fn userAgent(self: Identity, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        if (self.isOrca())
            return std.fmt.allocPrint(allocator, "{s}/{s} ( {s} )", .{ self.name, self.version, self.contact });
        return std.fmt.allocPrint(allocator, "{s}/{s} ( {s} ) liborca/{f}", .{
            self.name,
            self.version,
            self.contact,
            version.value,
        });
    }
};

pub const RateLimit = struct {
    remaining: ?u32 = null,
    reset_in_s: ?u32 = null,
    retry_after_s: ?u32 = null,

    pub fn observe(self: *RateLimit, name: []const u8, value: []const u8) void {
        if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-remaining")) {
            self.remaining = parseWholeSeconds(value);
        } else if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-reset-in")) {
            self.reset_in_s = parseWholeSeconds(value);
        } else if (std.ascii.eqlIgnoreCase(name, "retry-after")) {
            self.retry_after_s = parseWholeSeconds(value);
        }
    }

    fn parseWholeSeconds(value: []const u8) ?u32 {
        const trimmed = std.mem.trim(u8, value, " \t");
        if (trimmed.len == 0) return null;
        for (trimmed) |byte| if (!std.ascii.isDigit(byte)) return null;
        return std.fmt.parseInt(u32, trimmed, 10) catch null;
    }
};

pub const Request = struct {
    method: Method = .get,
    url: []const u8,
    body: ?[]const u8 = null,
    headers: []const Header = &.{},
    user_agent: []const u8,
    max_response_bytes: usize,
    timeout_ms: u64,
    cancel: ?*const std.atomic.Value(bool) = null,
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16,
    body: []u8,
    rate_limit: RateLimit = .{},

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
    identity: Identity = .orca,
    minimum_interval_ms: u64 = 1000,
    maximum_attempts: u8 = 1,
    initial_backoff_ms: u64 = 250,
    initial_rate_limit_backoff_ms: u64 = 60_000,
    maximum_rate_limit_backoff_ms: u64 = 60 * 60 * 1000,
    /// Best-effort while resolving the host name: std's blocking getaddrinfo cannot be interrupted.
    request_timeout_ms: u64 = 30_000,
    max_response_bytes: usize = 4 * 1024 * 1024,
    offline: bool = false,

    fn validate(self: Config) error{InvalidNetworkConfiguration}!void {
        try self.identity.validate();
        if (self.maximum_attempts == 0 or self.max_response_bytes == 0 or
            self.max_response_bytes == std.math.maxInt(usize) or
            self.minimum_interval_ms > std.math.maxInt(i64) or
            self.request_timeout_ms == 0 or self.request_timeout_ms > std.math.maxInt(i64) or
            self.initial_rate_limit_backoff_ms == 0 or
            self.maximum_rate_limit_backoff_ms < self.initial_rate_limit_backoff_ms or
            self.maximum_rate_limit_backoff_ms > std.math.maxInt(u32))
            return error.InvalidNetworkConfiguration;
    }
};

const cancel_poll_ms = 100;
const maximum_inline_hold_ms = 5_000;

/// Central policy boundary for every provider request. Transport adapters only
/// perform I/O; identification, rate limiting, retry/backoff, deadlines,
/// response bounds, and offline behavior are enforced here. A Gateway is owned
/// by one thread; only `cancel` may be set from another.
pub const Gateway = struct {
    transport: Transport,
    clock: Clock,
    config: Config,
    cancel: ?*const std.atomic.Value(bool) = null,
    last_request_ms: ?i64 = null,
    hold_until_ms: ?i64 = null,
    blocked_until_ms: ?i64 = null,
    rate_limit_backoff_ms: u64 = 0,

    pub fn execute(
        self: *Gateway,
        allocator: std.mem.Allocator,
        method: Method,
        url: []const u8,
        body: ?[]const u8,
        headers: []const Header,
    ) !Response {
        if (self.config.offline) return error.Offline;
        try self.config.validate();
        try self.checkCanceled();
        if (self.blockedUntilMs() != null) return error.RateLimited;
        const user_agent = try self.config.identity.userAgent(allocator);
        defer allocator.free(user_agent);
        var attempt: u8 = 0;
        var backoff = self.config.initial_backoff_ms;
        while (attempt < self.config.maximum_attempts) : (attempt += 1) {
            try self.awaitTurn();
            const response = self.transport.perform(allocator, .{
                .method = method,
                .url = url,
                .body = body,
                .headers = headers,
                .user_agent = user_agent,
                .max_response_bytes = self.config.max_response_bytes,
                .timeout_ms = self.config.request_timeout_ms,
                .cancel = self.cancel,
            }) catch |err| switch (err) {
                error.OutOfMemory, error.ResponseTooLarge, error.Canceled, error.Timeout => return err,
                error.ConcurrencyUnavailable => return error.InvalidNetworkConfiguration,
                else => {
                    if (attempt + 1 == self.config.maximum_attempts)
                        return error.NetworkUnavailable;
                    try self.sleepCancelable(backoff);
                    backoff = @min(backoff *| 2, 60_000);
                    continue;
                },
            };
            self.recordResponse(response);
            if (response.status == 429) {
                response.deinit();
                return error.RateLimited;
            }
            if (!retryableStatus(response.status) or attempt + 1 == self.config.maximum_attempts)
                return response;
            response.deinit();
            try self.sleepCancelable(backoff);
            backoff = @min(backoff *| 2, 60_000);
        }
        unreachable;
    }

    pub fn blockedUntilMs(self: *Gateway) ?i64 {
        const until = self.blocked_until_ms orelse return null;
        return if (self.clock.nowMs() < until) until else null;
    }

    fn recordResponse(self: *Gateway, response: Response) void {
        const now = self.clock.nowMs();
        const limit = response.rate_limit;
        self.hold_until_ms = null;
        if (limit.remaining == 0) {
            if (limit.reset_in_s) |seconds|
                self.hold_until_ms = now +| @as(i64, @intCast(self.boundedMs(@as(u64, seconds) * 1000)));
        }
        if (response.status == 429) {
            self.rate_limit_backoff_ms = if (self.rate_limit_backoff_ms == 0)
                self.config.initial_rate_limit_backoff_ms
            else
                self.boundedMs(self.rate_limit_backoff_ms *| 2);
            const advertised_s = @max(limit.retry_after_s orelse 0, limit.reset_in_s orelse 0);
            const block_ms = @max(@as(u64, advertised_s) * 1000, self.rate_limit_backoff_ms);
            self.blocked_until_ms = now +| @as(i64, @intCast(self.boundedMs(block_ms)));
        } else if (response.status >= 200 and response.status < 300) {
            self.rate_limit_backoff_ms = 0;
        }
    }

    fn boundedMs(self: *Gateway, milliseconds: u64) u64 {
        return @min(milliseconds, self.config.maximum_rate_limit_backoff_ms);
    }

    fn awaitTurn(self: *Gateway) !void {
        const now = self.clock.nowMs();
        var ready = now;
        if (self.last_request_ms) |last|
            ready = @max(ready, last +| @as(i64, @intCast(self.config.minimum_interval_ms)));
        if (self.hold_until_ms) |hold| {
            if (hold - now > maximum_inline_hold_ms) {
                self.blocked_until_ms = @max(self.blocked_until_ms orelse hold, hold);
                return error.RateLimited;
            }
            ready = @max(ready, hold);
        }
        if (ready > now) try self.sleepCancelable(@intCast(ready - now));
        self.last_request_ms = self.clock.nowMs();
    }

    fn checkCanceled(self: *Gateway) error{Canceled}!void {
        if (self.cancel) |flag| {
            if (flag.load(.acquire)) return error.Canceled;
        }
    }

    fn sleepCancelable(self: *Gateway, milliseconds: u64) !void {
        var remaining = milliseconds;
        while (remaining > 0) {
            try self.checkCanceled();
            const slice = @min(remaining, cancel_poll_ms);
            try self.clock.sleepMs(slice);
            remaining -= slice;
        }
    }
};

fn retryableStatus(status: u16) bool {
    return status == 408 or status == 425 or status >= 500;
}

pub const StandardTransport = struct {
    client: std.http.Client,

    const Verdict = enum { canceled, timed_out, stopped };

    const Outcome = union(enum) {
        exchange: anyerror!Response,
        watch: Verdict,
    };

    const Race = std.Io.Select(Outcome);

    /// `io` must support concurrency, e.g. `std.Io.Threaded.init(gpa, .{})`, not `init_single_threaded`.
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
        const io = self.client.io;
        if (request.cancel) |flag| {
            if (flag.load(.acquire)) return error.Canceled;
        }
        const started_ms = std.Io.Clock.awake.now(io).toMilliseconds();
        var outcomes: [2]Outcome = undefined;
        var race: Race = .init(io, &outcomes);
        race.concurrent(.watch, watch, .{ io, started_ms, request.timeout_ms, request.cancel }) catch |err| {
            discardRemaining(&race);
            return err;
        };
        race.concurrent(.exchange, exchange, .{ self, allocator, request }) catch |err| {
            discardRemaining(&race);
            return err;
        };
        const first = race.await() catch |err| {
            discardRemaining(&race);
            return err;
        };
        switch (first) {
            .exchange => |result| {
                race.cancelDiscard();
                return result;
            },
            .watch => |verdict| {
                discardRemaining(&race);
                return switch (verdict) {
                    .timed_out => error.Timeout,
                    .canceled, .stopped => error.Canceled,
                };
            },
        }
    }

    fn discardRemaining(race: *Race) void {
        while (race.cancel()) |outcome| switch (outcome) {
            .exchange => |result| if (result) |response| response.deinit() else |_| {},
            .watch => {},
        };
    }

    fn watch(
        io: std.Io,
        started_ms: i64,
        timeout_ms: u64,
        cancel: ?*const std.atomic.Value(bool),
    ) Verdict {
        while (true) {
            if (cancel) |flag| {
                if (flag.load(.acquire)) return .canceled;
            }
            const elapsed_ms: u64 = @intCast(@max(0, std.Io.Clock.awake.now(io).toMilliseconds() - started_ms));
            if (elapsed_ms >= timeout_ms) return .timed_out;
            const wait_ms: i64 = @intCast(@min(cancel_poll_ms, timeout_ms - elapsed_ms));
            io.sleep(.fromMilliseconds(wait_ms), .awake) catch return .stopped;
        }
    }

    fn exchange(self: *StandardTransport, allocator: std.mem.Allocator, request: Request) anyerror!Response {
        const uri = try std.Uri.parse(request.url);
        const storage = try allocator.alloc(u8, request.max_response_bytes + 1);
        defer allocator.free(storage);
        var writer = std.Io.Writer.fixed(storage);
        const standard_headers = try allocator.alloc(std.http.Header, request.headers.len);
        defer allocator.free(standard_headers);
        for (request.headers, standard_headers) |source, *destination|
            destination.* = .{ .name = source.name, .value = source.value };
        var http_request = try self.client.request(switch (request.method) {
            .get => .GET,
            .post => .POST,
        }, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{ .user_agent = .{ .override = request.user_agent } },
            .extra_headers = standard_headers,
        });
        defer http_request.deinit();

        if (request.body) |payload| {
            http_request.transfer_encoding = .{ .content_length = payload.len };
            var body = try http_request.sendBodyUnflushed(&.{});
            try body.writer.writeAll(payload);
            try body.end();
            try http_request.connection.?.flush();
        } else {
            try http_request.sendBodiless();
        }

        var response = try http_request.receiveHead(&.{});
        errdefer if (http_request.connection) |connection| {
            connection.closing = true;
        };
        var rate_limit: RateLimit = .{};
        var header_iterator = response.head.iterateHeaders();
        while (header_iterator.next()) |header| rate_limit.observe(header.name, header.value);

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.client.allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.client.allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer self.client.allocator.free(decompress_buffer);

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = reader.streamRemaining(&writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            error.WriteFailed => return error.ResponseTooLarge,
        };
        const buffered = writer.buffered();
        if (buffered.len > request.max_response_bytes) return error.ResponseTooLarge;
        return .{
            .allocator = allocator,
            .status = @intFromEnum(response.head.status),
            .body = try allocator.dupe(u8, buffered),
            .rate_limit = rate_limit,
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

const test_version = std.fmt.comptimePrint("{f}", .{version.value});

const ScriptedTransport = struct {
    responses: []const Scripted,
    clock: *TestClock,
    calls: usize = 0,
    request_times_ms: [16]i64 = undefined,
    user_agent: [160]u8 = undefined,
    user_agent_len: usize = 0,
    timeout_ms: u64 = 0,
    failure: ?anyerror = null,

    const Scripted = struct {
        status: u16 = 200,
        rate_limit: RateLimit = .{},
    };

    fn transport(self: *ScriptedTransport) Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn lastUserAgent(self: *const ScriptedTransport) []const u8 {
        return self.user_agent[0..self.user_agent_len];
    }

    fn perform(context: *anyopaque, allocator: std.mem.Allocator, request: Request) !Response {
        const self: *ScriptedTransport = @ptrCast(@alignCast(context));
        self.request_times_ms[self.calls] = self.clock.now;
        self.calls += 1;
        self.timeout_ms = request.timeout_ms;
        self.user_agent_len = request.user_agent.len;
        @memcpy(self.user_agent[0..request.user_agent.len], request.user_agent);
        if (self.failure) |err| return err;
        const scripted = self.responses[@min(self.calls - 1, self.responses.len - 1)];
        return .{
            .allocator = allocator,
            .status = scripted.status,
            .body = try allocator.dupe(u8, "body"),
            .rate_limit = scripted.rate_limit,
        };
    }
};

const TestClock = struct {
    now: i64 = 0,
    slept: u64 = 0,

    fn clock(self: *TestClock) Clock {
        return .{ .context = self, .now_ms_fn = nowMs, .sleep_ms_fn = sleepMs };
    }

    fn nowMs(context: *anyopaque) i64 {
        return (@as(*TestClock, @ptrCast(@alignCast(context)))).now;
    }

    fn sleepMs(context: *anyopaque, milliseconds: u64) !void {
        const self: *TestClock = @ptrCast(@alignCast(context));
        self.slept += milliseconds;
        self.now += @intCast(milliseconds);
    }
};

fn scriptedGateway(transport: *ScriptedTransport, clock: *TestClock, config: Config) Gateway {
    return .{ .transport = transport.transport(), .clock = clock.clock(), .config = config };
}

fn fetchOnce(gateway: *Gateway) !u16 {
    const response = try gateway.execute(std.testing.allocator, .get, "https://example.test", null, &.{});
    defer response.deinit();
    return response.status;
}

test "user agent names Orca, its version and the contact" {
    var clock: TestClock = .{};
    var scripted: ScriptedTransport = .{ .responses = &.{.{}}, .clock = &clock };
    var gateway = scriptedGateway(&scripted, &clock, .{});
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&gateway));
    try std.testing.expectEqualStrings(
        "Orca/" ++ test_version ++ " ( evan@evanriley.com )",
        scripted.lastUserAgent(),
    );
}

test "user agent of a host identity is followed by liborca's" {
    var clock: TestClock = .{};
    var scripted: ScriptedTransport = .{ .responses = &.{.{}}, .clock = &clock };
    var gateway = scriptedGateway(&scripted, &clock, .{
        .identity = .{ .name = "Player", .version = "1.2.3", .contact = "https://player.example" },
    });
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&gateway));
    try std.testing.expectEqualStrings(
        "Player/1.2.3 ( https://player.example ) liborca/" ++ test_version,
        scripted.lastUserAgent(),
    );
}

test "identities with empty fields, line breaks or parentheses are rejected" {
    const invalid = [_]Identity{
        .{ .name = "", .version = "1", .contact = "a@b.c" },
        .{ .name = "App", .version = "", .contact = "a@b.c" },
        .{ .name = "App", .version = "1", .contact = "" },
        .{ .name = "App\r\nX: y", .version = "1", .contact = "a@b.c" },
        .{ .name = "App", .version = "1\n", .contact = "a@b.c" },
        .{ .name = "App", .version = "1", .contact = "a@b.c\r" },
        .{ .name = "App (x)", .version = "1", .contact = "a@b.c" },
        .{ .name = "App", .version = "1)", .contact = "a@b.c" },
        .{ .name = "App", .version = "1", .contact = "(a@b.c" },
    };
    for (invalid) |identity| {
        var clock: TestClock = .{};
        var scripted: ScriptedTransport = .{ .responses = &.{.{}}, .clock = &clock };
        var gateway = scriptedGateway(&scripted, &clock, .{ .identity = identity });
        try std.testing.expectError(error.InvalidNetworkConfiguration, fetchOnce(&gateway));
        try std.testing.expectEqual(@as(usize, 0), scripted.calls);
    }
}

test "rate limit headers are read case-insensitively and Retry-After only as seconds" {
    var limit: RateLimit = .{};
    limit.observe("X-RateLimit-Remaining", "0");
    limit.observe("x-ratelimit-reset-in", " 7 ");
    limit.observe("RETRY-AFTER", "30");
    try std.testing.expectEqual(@as(?u32, 0), limit.remaining);
    try std.testing.expectEqual(@as(?u32, 7), limit.reset_in_s);
    try std.testing.expectEqual(@as(?u32, 30), limit.retry_after_s);

    var dated: RateLimit = .{};
    dated.observe("Retry-After", "Wed, 21 Oct 2026 07:28:00 GMT");
    dated.observe("X-RateLimit-Reset-In", "-1");
    dated.observe("X-RateLimit-Remaining", "+3");
    try std.testing.expectEqual(RateLimit{}, dated);
}

fn expectBlockedFor(limit: RateLimit, expected_ms: i64) !void {
    var clock: TestClock = .{};
    var scripted: ScriptedTransport = .{
        .responses = &.{ .{ .status = 429, .rate_limit = limit }, .{} },
        .clock = &clock,
    };
    var gateway = scriptedGateway(&scripted, &clock, .{ .maximum_attempts = 3, .minimum_interval_ms = 0 });
    try std.testing.expectError(error.RateLimited, fetchOnce(&gateway));
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);
    try std.testing.expectEqual(@as(?i64, expected_ms), gateway.blockedUntilMs());

    clock.now = expected_ms - 1;
    try std.testing.expectError(error.RateLimited, fetchOnce(&gateway));
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);

    clock.now = expected_ms;
    try std.testing.expectEqual(@as(?i64, null), gateway.blockedUntilMs());
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&gateway));
    try std.testing.expectEqual(@as(usize, 2), scripted.calls);
}

test "a 429 is not retried and blocks requests for the default backoff" {
    try expectBlockedFor(.{}, 60_000);
}

test "a 429 blocks requests until Retry-After when it is longer than the backoff" {
    try expectBlockedFor(.{ .retry_after_s = 120 }, 120_000);
}

test "a 429 blocks requests until Reset-In when it is longer than the backoff" {
    try expectBlockedFor(.{ .reset_in_s = 300, .remaining = 0 }, 300_000);
}

test "consecutive 429s double the block up to an hour and a success resets it" {
    var clock: TestClock = .{};
    var scripted: ScriptedTransport = .{
        .responses = &.{.{ .status = 429 }},
        .clock = &clock,
    };
    var gateway = scriptedGateway(&scripted, &clock, .{ .minimum_interval_ms = 0 });
    const expected_s = [_]i64{ 60, 120, 240, 480, 960, 1920, 3600, 3600 };
    for (expected_s) |seconds| {
        const started = clock.now;
        try std.testing.expectError(error.RateLimited, fetchOnce(&gateway));
        try std.testing.expectEqual(@as(?i64, started + seconds * 1000), gateway.blockedUntilMs());
        clock.now = started + seconds * 1000;
    }

    scripted.responses = &.{.{}};
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&gateway));
    scripted.responses = &.{.{ .status = 429 }};
    const started = clock.now;
    try std.testing.expectError(error.RateLimited, fetchOnce(&gateway));
    try std.testing.expectEqual(@as(?i64, started + 60_000), gateway.blockedUntilMs());
}

test "an exhausted quota holds the next request until a short advertised reset" {
    var clock: TestClock = .{};
    var scripted: ScriptedTransport = .{
        .responses = &.{ .{ .rate_limit = .{ .remaining = 0, .reset_in_s = 3 } }, .{} },
        .clock = &clock,
    };
    var gateway = scriptedGateway(&scripted, &clock, .{});
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&gateway));
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&gateway));
    try std.testing.expectEqual(@as(i64, 3000), scripted.request_times_ms[1] - scripted.request_times_ms[0]);
}

test "an exhausted quota with a long reset is scheduled instead of slept" {
    var clock: TestClock = .{};
    var scripted: ScriptedTransport = .{
        .responses = &.{ .{ .rate_limit = .{ .remaining = 0, .reset_in_s = 7 } }, .{} },
        .clock = &clock,
    };
    var gateway = scriptedGateway(&scripted, &clock, .{});
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&gateway));
    try std.testing.expectError(error.RateLimited, fetchOnce(&gateway));
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);
    try std.testing.expectEqual(@as(u64, 0), clock.slept);
    try std.testing.expectEqual(@as(?i64, 7000), gateway.blockedUntilMs());
}

test "a transport without concurrency is a configuration error and is not retried" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var transport: StandardTransport = .init(std.testing.allocator, threaded.io());
    defer transport.deinit();
    var system_clock: SystemClock = .{ .io = threaded.io() };
    var gateway = systemGateway(&transport, &system_clock, .{ .maximum_attempts = 3, .request_timeout_ms = 5000 });
    const started = std.Io.Clock.awake.now(threaded.io()).toMilliseconds();
    try std.testing.expectError(error.InvalidNetworkConfiguration, gateway.execute(
        std.testing.allocator,
        .get,
        "http://127.0.0.1:1/",
        null,
        &.{},
    ));
    try std.testing.expect(std.Io.Clock.awake.now(threaded.io()).toMilliseconds() - started < 200);
}

test "requests are spaced by the minimum interval" {
    var clock: TestClock = .{};
    var scripted: ScriptedTransport = .{
        .responses = &.{.{ .rate_limit = .{ .remaining = 5, .reset_in_s = 7 } }},
        .clock = &clock,
    };
    var gateway = scriptedGateway(&scripted, &clock, .{});
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&gateway));
    clock.now += 400;
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&gateway));
    clock.now += 2500;
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&gateway));
    try std.testing.expectEqual(@as(i64, 1000), scripted.request_times_ms[1] - scripted.request_times_ms[0]);
    try std.testing.expectEqual(@as(i64, 2500), scripted.request_times_ms[2] - scripted.request_times_ms[1]);
}

test "server errors are retried only up to the configured attempts" {
    var clock: TestClock = .{};
    var scripted: ScriptedTransport = .{
        .responses = &.{ .{ .status = 503 }, .{ .status = 503 }, .{} },
        .clock = &clock,
    };
    var single = scriptedGateway(&scripted, &clock, .{});
    try std.testing.expectEqual(@as(u16, 503), try fetchOnce(&single));
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);

    scripted.calls = 0;
    var patient = scriptedGateway(&scripted, &clock, .{ .maximum_attempts = 3, .minimum_interval_ms = 100, .initial_backoff_ms = 10 });
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&patient));
    try std.testing.expectEqual(@as(usize, 3), scripted.calls);

    scripted.calls = 0;
    scripted.failure = error.ConnectionRefused;
    try std.testing.expectError(error.NetworkUnavailable, fetchOnce(&patient));
    try std.testing.expectEqual(@as(usize, 3), scripted.calls);
}

test "offline mode, timeouts and a set cancel flag stop the gateway before or without retrying" {
    var clock: TestClock = .{};
    var scripted: ScriptedTransport = .{ .responses = &.{.{}}, .clock = &clock };
    var gateway = scriptedGateway(&scripted, &clock, .{ .maximum_attempts = 3, .request_timeout_ms = 1234 });
    scripted.failure = error.Timeout;
    try std.testing.expectError(error.Timeout, fetchOnce(&gateway));
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);
    try std.testing.expectEqual(@as(u64, 1234), scripted.timeout_ms);

    var canceled: std.atomic.Value(bool) = .init(true);
    gateway.cancel = &canceled;
    try std.testing.expectError(error.Canceled, fetchOnce(&gateway));
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);

    gateway.config.offline = true;
    try std.testing.expectError(error.Offline, fetchOnce(&gateway));
}

const canned_response =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: application/json\r\n" ++
    "X-RateLimit-Limit: 10\r\n" ++
    "X-RateLimit-Remaining: 0\r\n" ++
    "x-ratelimit-reset-in: 7\r\n" ++
    "Retry-After: 30\r\n" ++
    "Content-Length: 2\r\n" ++
    "Connection: close\r\n\r\n{}";

const LocalServer = struct {
    io: std.Io,
    listener: std.Io.net.Server,
    request_head: [1024]u8 = undefined,
    request_head_len: usize = 0,

    fn listen(io: std.Io) !LocalServer {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        return .{ .io = io, .listener = try address.listen(io, .{}) };
    }

    fn deinit(self: *LocalServer) void {
        self.listener.deinit(self.io);
    }

    fn url(self: *const LocalServer, buffer: []u8) ![]u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/1/submit-listens", .{
            self.listener.socket.address.getPort(),
        });
    }

    fn replyOnce(self: *LocalServer) !void {
        const stream = try self.listener.accept(self.io);
        defer stream.close(self.io);
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            if (self.request_head_len + line.len <= self.request_head.len) {
                @memcpy(self.request_head[self.request_head_len..][0..line.len], line);
                self.request_head_len += line.len;
            }
            if (line.len <= 2) break;
        }
        var write_buffer: [256]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.writeAll(canned_response);
        try writer.interface.flush();
    }
};

fn systemGateway(transport: *StandardTransport, clock: *SystemClock, config: Config) Gateway {
    return .{ .transport = transport.transport(), .clock = clock.clock(), .config = config };
}

test "a real exchange yields the status, body, rate limit headers and exactly one user agent, Orca's" {
    const io = std.testing.io;
    var server = try LocalServer.listen(io);
    defer server.deinit();
    var serving = try io.concurrent(LocalServer.replyOnce, .{&server});
    defer serving.cancel(io) catch {};
    var transport: StandardTransport = .init(std.testing.allocator, io);
    defer transport.deinit();
    var system_clock: SystemClock = .{ .io = io };
    var gateway = systemGateway(&transport, &system_clock, .{ .request_timeout_ms = 5000 });

    var url_buffer: [64]u8 = undefined;
    const response = try gateway.execute(
        std.testing.allocator,
        .post,
        try server.url(&url_buffer),
        "{\"listen_type\":\"single\"}",
        &.{.{ .name = "Authorization", .value = "Token secret" }},
    );
    defer response.deinit();
    try serving.await(io);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("{}", response.body);
    try std.testing.expectEqual(@as(?u32, 0), response.rate_limit.remaining);
    try std.testing.expectEqual(@as(?u32, 7), response.rate_limit.reset_in_s);
    try std.testing.expectEqual(@as(?u32, 30), response.rate_limit.retry_after_s);
    const head = server.request_head[0..server.request_head_len];
    try std.testing.expect(std.mem.indexOf(
        u8,
        head,
        "user-agent: Orca/" ++ test_version ++ " ( evan@evanriley.com )\r\n",
    ) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, head, "user-agent:"));
    try std.testing.expect(std.mem.indexOf(u8, head, "Authorization: Token secret\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "connection: close\r\n") != null);
    try std.testing.expect(gateway.hold_until_ms != null);
}

test "a server that accepts but never replies makes the request time out at the deadline" {
    const io = std.testing.io;
    var server = try LocalServer.listen(io);
    defer server.deinit();
    var transport: StandardTransport = .init(std.testing.allocator, io);
    defer transport.deinit();
    var system_clock: SystemClock = .{ .io = io };
    var gateway = systemGateway(&transport, &system_clock, .{ .request_timeout_ms = 300 });

    var url_buffer: [64]u8 = undefined;
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    try std.testing.expectError(error.Timeout, gateway.execute(
        std.testing.allocator,
        .get,
        try server.url(&url_buffer),
        null,
        &.{},
    ));
    const elapsed = std.Io.Clock.awake.now(io).toMilliseconds() - started;
    try std.testing.expect(elapsed >= 300);
    try std.testing.expect(elapsed < 1000);
}

fn tripAfter(io: std.Io, flag: *std.atomic.Value(bool), milliseconds: i64) void {
    io.sleep(.fromMilliseconds(milliseconds), .awake) catch return;
    flag.store(true, .release);
}

test "setting the cancel flag makes a hung request return promptly" {
    const io = std.testing.io;
    var server = try LocalServer.listen(io);
    defer server.deinit();
    var transport: StandardTransport = .init(std.testing.allocator, io);
    defer transport.deinit();
    var system_clock: SystemClock = .{ .io = io };
    var gateway = systemGateway(&transport, &system_clock, .{ .request_timeout_ms = 10_000 });
    var canceled: std.atomic.Value(bool) = .init(false);
    gateway.cancel = &canceled;

    var tripping = try io.concurrent(tripAfter, .{ io, &canceled, 100 });
    defer tripping.cancel(io);
    var url_buffer: [64]u8 = undefined;
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    try std.testing.expectError(error.Canceled, gateway.execute(
        std.testing.allocator,
        .get,
        try server.url(&url_buffer),
        null,
        &.{},
    ));
    const elapsed = std.Io.Clock.awake.now(io).toMilliseconds() - started;
    try std.testing.expect(elapsed < 500);
}
