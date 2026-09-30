const std = @import("std");
const client = @import("client.zig");

pub const default_seed: u64 = 0x0ca;

/// Orca's own name and version, which `Identity.isOrca` recognizes, with a
/// contact that reaches nobody.
pub const test_identity: client.Identity = .{
    .name = "Orca",
    .version = client.liborca_version,
    .contact = "https://orca.invalid",
};

pub const TestClock = struct {
    now_ms: std.atomic.Value(i64) = .init(0),
    wall_offset_ms: i64 = 0,
    slept_ms: std.atomic.Value(u64) = .init(0),
    reads: std.atomic.Value(u32) = .init(0),

    pub fn startingAt(now_ms: i64) TestClock {
        return .{ .now_ms = .init(now_ms) };
    }

    pub fn clock(self: *TestClock) client.Clock {
        return .{ .context = self, .now_ms_fn = readNow, .sleep_ms_fn = sleep };
    }

    pub fn wallClock(self: *TestClock) client.Clock {
        return .{ .context = self, .now_ms_fn = readWall, .sleep_ms_fn = sleep };
    }

    pub fn now(self: *const TestClock) i64 {
        return self.now_ms.load(.acquire);
    }

    pub fn wallNow(self: *const TestClock) i64 {
        return self.wall_offset_ms + self.now();
    }

    pub fn set(self: *TestClock, now_ms: i64) void {
        self.now_ms.store(now_ms, .release);
    }

    pub fn advance(self: *TestClock, milliseconds: i64) void {
        _ = self.now_ms.fetchAdd(milliseconds, .acq_rel);
    }

    pub fn slept(self: *const TestClock) u64 {
        return self.slept_ms.load(.acquire);
    }

    fn readNow(context: *anyopaque) i64 {
        const self: *TestClock = @ptrCast(@alignCast(context));
        _ = self.reads.fetchAdd(1, .acq_rel);
        return self.now();
    }

    fn readWall(context: *anyopaque) i64 {
        const self: *TestClock = @ptrCast(@alignCast(context));
        return self.wallNow();
    }

    fn sleep(context: *anyopaque, milliseconds: u64) anyerror!void {
        const self: *TestClock = @ptrCast(@alignCast(context));
        _ = self.slept_ms.fetchAdd(milliseconds, .acq_rel);
        self.advance(@intCast(milliseconds));
    }
};

pub const OffsetClock = struct {
    base: *TestClock,
    offset_ms: i64,

    pub fn clock(self: *OffsetClock) client.Clock {
        return .{ .context = self, .now_ms_fn = readNow, .sleep_ms_fn = sleep };
    }

    fn readNow(context: *anyopaque) i64 {
        const self: *OffsetClock = @ptrCast(@alignCast(context));
        return self.base.now() - self.offset_ms;
    }

    fn sleep(context: *anyopaque, milliseconds: u64) anyerror!void {
        const self: *OffsetClock = @ptrCast(@alignCast(context));
        try TestClock.sleep(self.base, milliseconds);
    }
};

pub const Reply = union(enum) {
    respond: Answer,
    fail: anyerror,
    hang,

    pub const Answer = struct {
        status: u16 = 200,
        body: []const u8 = "{}",
        rate_limit: client.RateLimit = .{},
    };
};

const hang_limit_ms = 10_000;

pub const Exchange = struct {
    index: u32,
    request: client.Request,
    form: []const u8,
};

pub const Responder = struct {
    context: *anyopaque,
    respond_fn: *const fn (*anyopaque, Exchange, ?Reply) anyerror!Reply,
};

pub const Recorded = struct {
    url: []u8,
    body: []u8,
};

/// The last request's details are complete once `requestCount` counts it, so
/// another thread may read them then; `history` is safe to read only from the
/// thread that sends.
pub const ScriptedTransport = struct {
    allocator: std.mem.Allocator = std.testing.allocator,
    clock: ?*TestClock = null,
    replies: std.ArrayList(Reply) = .empty,
    next_reply: usize = 0,
    otherwise: Reply = .{ .respond = .{} },
    responder: ?Responder = null,
    keep_history: bool = false,
    history: std.ArrayList(Recorded) = .empty,
    requests: std.atomic.Value(u32) = .init(0),
    request_times_ms: [16]i64 = @splat(0),
    timeout_ms: u64 = 0,
    url: [512]u8 = undefined,
    url_len: usize = 0,
    user_agent: [256]u8 = undefined,
    user_agent_len: usize = 0,
    authorization: [128]u8 = undefined,
    authorization_len: usize = 0,
    form: [16 * 1024]u8 = undefined,
    form_len: usize = 0,

    pub fn deinit(self: *ScriptedTransport) void {
        for (self.history.items) |recorded| {
            self.allocator.free(recorded.url);
            self.allocator.free(recorded.body);
        }
        self.history.deinit(self.allocator);
        self.replies.deinit(self.allocator);
    }

    pub fn transport(self: *ScriptedTransport) client.Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    pub fn script(self: *ScriptedTransport, reply: Reply) !void {
        try self.replies.append(self.allocator, reply);
    }

    pub fn requestCount(self: *const ScriptedTransport) u32 {
        return self.requests.load(.acquire);
    }

    pub fn lastUrl(self: *const ScriptedTransport) []const u8 {
        return self.url[0..self.url_len];
    }

    pub fn lastUserAgent(self: *const ScriptedTransport) []const u8 {
        return self.user_agent[0..self.user_agent_len];
    }

    pub fn lastAuthorization(self: *const ScriptedTransport) []const u8 {
        return self.authorization[0..self.authorization_len];
    }

    pub fn lastForm(self: *const ScriptedTransport) []const u8 {
        return self.form[0..self.form_len];
    }

    fn perform(context: *anyopaque, allocator: std.mem.Allocator, request: client.Request) anyerror!client.Response {
        const self: *ScriptedTransport = @ptrCast(@alignCast(context));
        const index = self.requests.load(.acquire);
        const form = try decodeBody(allocator, request);
        defer allocator.free(form);
        self.record(index, request, form);
        if (self.keep_history) {
            const url = try self.allocator.dupe(u8, request.url);
            errdefer self.allocator.free(url);
            const body = try self.allocator.dupe(u8, form);
            errdefer self.allocator.free(body);
            try self.history.append(self.allocator, .{ .url = url, .body = body });
        }

        var scripted: ?Reply = null;
        if (self.next_reply < self.replies.items.len) {
            scripted = self.replies.items[self.next_reply];
            self.next_reply += 1;
        }
        const reply = if (self.responder) |responder|
            try responder.respond_fn(responder.context, .{ .index = index, .request = request, .form = form }, scripted)
        else
            scripted orelse self.otherwise;
        _ = self.requests.fetchAdd(1, .acq_rel);

        return switch (reply) {
            .respond => |answer| .{
                .allocator = allocator,
                .status = answer.status,
                .body = try allocator.dupe(u8, answer.body),
                .rate_limit = answer.rate_limit,
            },
            .fail => |err| err,
            .hang => hang(request),
        };
    }

    fn record(self: *ScriptedTransport, index: u32, request: client.Request, form: []const u8) void {
        if (index < self.request_times_ms.len)
            self.request_times_ms[index] = if (self.clock) |test_clock| test_clock.now() else 0;
        self.timeout_ms = request.timeout_ms;
        self.url_len = copyTruncated(&self.url, request.url);
        self.user_agent_len = copyTruncated(&self.user_agent, request.user_agent);
        self.authorization_len = copyTruncated(&self.authorization, header(request, "authorization") orelse "");
        self.form_len = copyTruncated(&self.form, form);
    }

    fn hang(request: client.Request) anyerror!client.Response {
        const pause: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        for (0..hang_limit_ms) |_| {
            if (request.cancel) |cancel| if (cancel.load(.acquire)) return error.Canceled;
            _ = std.c.nanosleep(&pause, null);
        }
        return error.Timeout;
    }
};

fn copyTruncated(buffer: []u8, value: []const u8) usize {
    const length = @min(value.len, buffer.len);
    @memcpy(buffer[0..length], value[0..length]);
    return length;
}

fn header(request: client.Request, name: []const u8) ?[]const u8 {
    for (request.headers) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate.name, name)) return candidate.value;
    }
    return null;
}

fn decodeBody(allocator: std.mem.Allocator, request: client.Request) ![]u8 {
    const body = request.body orelse "";
    const encoding = header(request, "content-encoding") orelse return allocator.dupe(u8, body);
    if (!std.ascii.eqlIgnoreCase(encoding, "gzip")) return allocator.dupe(u8, body);
    return gunzip(allocator, body);
}

pub fn gunzip(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var input: std.Io.Reader = .fixed(bytes);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var decompressor: std.compress.flate.Decompress = .init(&input, .gzip, window);
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    _ = try decompressor.reader.streamRemaining(&output.writer);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn gateway(
    transport: *ScriptedTransport,
    clock: *TestClock,
    prng: *std.Random.DefaultPrng,
    config: client.Config,
) client.Gateway {
    return .{
        .transport = transport.transport(),
        .clock = clock.clock(),
        .wall_clock = clock.wallClock(),
        .random = prng.random(),
        .config = config,
    };
}

pub const TestGatewayOptions = struct {
    config: client.Config = .{ .identity = test_identity },
    now_ms: i64 = 0,
    wall_offset_ms: i64 = 0,
    seed: u64 = default_seed,
};

/// `gateway` points into this struct, so it is initialized in place and never
/// moved.
pub const TestGateway = struct {
    transport: ScriptedTransport,
    clock: TestClock,
    prng: std.Random.DefaultPrng,
    gateway: client.Gateway,

    pub fn init(self: *TestGateway, options: TestGatewayOptions) void {
        self.clock = .{ .now_ms = .init(options.now_ms), .wall_offset_ms = options.wall_offset_ms };
        self.transport = .{ .clock = &self.clock };
        self.prng = .init(options.seed);
        self.gateway = gateway(&self.transport, &self.clock, &self.prng, options.config);
    }

    pub fn deinit(self: *TestGateway) void {
        self.transport.deinit();
    }
};
