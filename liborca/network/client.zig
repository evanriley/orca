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

    /// The three fields together, so an `OwnedIdentity` holds any valid one.
    pub const max_bytes = 256;

    pub fn validate(self: Identity) error{InvalidNetworkConfiguration}!void {
        if (self.name.len + self.version.len + self.contact.len > max_bytes)
            return error.InvalidNetworkConfiguration;
        inline for (.{ self.name, self.version, self.contact }) |field| {
            if (field.len == 0) return error.InvalidNetworkConfiguration;
            for (field) |byte| {
                if (byte < 0x20 or byte == 0x7f or byte == '(' or byte == ')')
                    return error.InvalidNetworkConfiguration;
            }
        }
    }

    /// Orca's own applications, which need no `liborca/x` suffix naming the
    /// library they are.
    pub fn isOrca(self: Identity) bool {
        return std.mem.eql(u8, self.name, "Orca") and
            std.mem.eql(u8, self.version, liborca_version);
    }

    pub fn userAgent(self: Identity, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        if (self.isOrca())
            return std.fmt.allocPrint(allocator, "{s}/{s} ( {s} )", .{ self.name, self.version, self.contact });
        return std.fmt.allocPrint(allocator, "{s}/{s} ( {s} ) liborca/{s}", .{
            self.name,
            self.version,
            self.contact,
            liborca_version,
        });
    }
};

pub const liborca_version = std.fmt.comptimePrint("{f}", .{version.value});

/// An `Identity` whose text lives inside the value, so threads copy it whole
/// and no copy dangles when the host sets another.
pub const OwnedIdentity = struct {
    bytes: [Identity.max_bytes]u8,
    name_len: u16,
    version_len: u16,
    contact_len: u16,

    pub fn init(identity: Identity) error{InvalidNetworkConfiguration}!OwnedIdentity {
        try identity.validate();
        var owned: OwnedIdentity = .{
            .bytes = undefined,
            .name_len = @intCast(identity.name.len),
            .version_len = @intCast(identity.version.len),
            .contact_len = @intCast(identity.contact.len),
        };
        @memcpy(owned.bytes[0..identity.name.len], identity.name);
        @memcpy(owned.bytes[owned.name_len..][0..identity.version.len], identity.version);
        @memcpy(owned.bytes[owned.name_len + owned.version_len ..][0..identity.contact.len], identity.contact);
        return owned;
    }

    pub fn view(self: *const OwnedIdentity) Identity {
        const version_start = self.name_len;
        const contact_start = version_start + self.version_len;
        return .{
            .name = self.bytes[0..self.name_len],
            .version = self.bytes[version_start..contact_start],
            .contact = self.bytes[contact_start..][0..self.contact_len],
        };
    }
};

pub const RetryAfter = union(enum) {
    seconds: u64,
    /// An HTTP-date, in Unix seconds.
    date: i64,

    /// Delay-seconds, or an HTTP-date in the IMF-fixdate form. A delay too
    /// large to represent is the largest one.
    pub fn parse(value: []const u8) ?RetryAfter {
        const trimmed = std.mem.trim(u8, value, " \t");
        if (trimmed.len == 0) return null;
        if (allDigits(trimmed))
            return .{ .seconds = std.fmt.parseInt(u64, trimmed, 10) catch std.math.maxInt(u64) };
        return .{ .date = parseImfFixdate(trimmed) orelse return null };
    }
};

pub const RateLimit = struct {
    remaining: ?u32 = null,
    reset_in_s: ?u32 = null,
    retry_after: ?RetryAfter = null,

    pub fn observe(self: *RateLimit, name: []const u8, value: []const u8) void {
        if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-remaining")) {
            self.remaining = parseWholeSeconds(value);
        } else if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-reset-in")) {
            self.reset_in_s = parseWholeSeconds(value);
        } else if (std.ascii.eqlIgnoreCase(name, "retry-after")) {
            self.retry_after = RetryAfter.parse(value);
        }
    }

    fn parseWholeSeconds(value: []const u8) ?u32 {
        const trimmed = std.mem.trim(u8, value, " \t");
        if (!allDigits(trimmed)) return null;
        return std.fmt.parseInt(u32, trimmed, 10) catch null;
    }
};

fn allDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

/// `Sun, 06 Nov 1994 08:49:37 GMT`, in Unix seconds.
fn parseImfFixdate(text: []const u8) ?i64 {
    const day_names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    if (text.len != 29) return null;
    if (indexOfName(&day_names, text[0..3]) == null) return null;
    if (!std.mem.eql(u8, text[3..5], ", ") or text[7] != ' ' or text[11] != ' ' or text[16] != ' ' or
        text[19] != ':' or text[22] != ':' or !std.mem.eql(u8, text[25..29], " GMT"))
        return null;
    const day = twoDigits(text[5..7]) orelse return null;
    const month = (indexOfName(&month_names, text[8..11]) orelse return null) + 1;
    const year = (@as(u16, twoDigits(text[12..14]) orelse return null)) * 100 + (twoDigits(text[14..16]) orelse return null);
    const hour = twoDigits(text[17..19]) orelse return null;
    const minute = twoDigits(text[20..22]) orelse return null;
    const second = twoDigits(text[23..25]) orelse return null;
    if (day == 0 or day > std.time.epoch.getDaysInMonth(year, @enumFromInt(month))) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    return daysSinceUnixEpoch(year, month, day) * std.time.s_per_day +
        @as(i64, hour) * std.time.s_per_hour + @as(i64, minute) * std.time.s_per_min + second;
}

fn indexOfName(names: []const []const u8, text: []const u8) ?u8 {
    for (names, 0..) |name, index| if (std.mem.eql(u8, name, text)) return @intCast(index);
    return null;
}

fn twoDigits(text: []const u8) ?u8 {
    if (!allDigits(text)) return null;
    return (text[0] - '0') * 10 + (text[1] - '0');
}

fn daysSinceUnixEpoch(year: u16, month: u8, day: u8) i64 {
    const shifted_year: i64 = if (month <= 2) @as(i64, year) - 1 else year;
    const era = @divFloor(shifted_year, 400);
    const year_of_era = shifted_year - era * 400;
    const month_from_march: i64 = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * month_from_march + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

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
    /// A redirect's `Location` header, as the server sent it.
    location: ?[]u8 = null,

    pub fn deinit(self: Response) void {
        self.allocator.free(self.body);
        if (self.location) |location| self.allocator.free(location);
    }
};

/// Where `Gateway.fetch` may be redirected: to `https` on `host` or on a
/// host ending in `.` and `host`, or, from a request to a loopback server, to
/// that same server, so a local mock can redirect to itself.
pub const RedirectAllowance = struct {
    host: []const u8,
};

/// The Cover Art Archive redirects to `archive.org`, which redirects again
/// to the storage node holding the file.
pub const max_redirects = 2;

fn isRedirect(status: u16) bool {
    return status == 301 or status == 302 or status == 303 or status == 307 or status == 308;
}

const loopback_hosts = [_][]const u8{ "127.0.0.1", "[::1]", "localhost" };

/// The absolute URL a redirect from `request_url` to `location` leads to,
/// when `allowance` permits it.
pub fn redirectTarget(
    allocator: std.mem.Allocator,
    request_url: []const u8,
    location: []const u8,
    allowance: RedirectAllowance,
) ![]u8 {
    const origin = std.Uri.parse(request_url) catch return error.RedirectRefused;
    var origin_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const origin_host = (origin.getHost(&origin_host_buffer) catch return error.RedirectRefused).bytes;
    const target_url = if (std.mem.startsWith(u8, location, "/") and !std.mem.startsWith(u8, location, "//"))
        try absoluteOnOrigin(allocator, origin, origin_host, location)
    else
        try allocator.dupe(u8, location);
    errdefer allocator.free(target_url);
    const target = std.Uri.parse(target_url) catch return error.RedirectRefused;
    if (target.user != null or target.password != null) return error.RedirectRefused;
    var target_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const target_host = (target.getHost(&target_host_buffer) catch return error.RedirectRefused).bytes;
    if (std.ascii.eqlIgnoreCase(target.scheme, "https") and isWithinHost(target_host, allowance.host))
        return target_url;
    if (isLoopback(origin_host) and std.ascii.eqlIgnoreCase(target.scheme, origin.scheme) and
        std.ascii.eqlIgnoreCase(target_host, origin_host) and target.port == origin.port)
        return target_url;
    return error.RedirectRefused;
}

fn absoluteOnOrigin(allocator: std.mem.Allocator, origin: std.Uri, host: []const u8, path: []const u8) ![]u8 {
    if (origin.port) |port|
        return std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{ origin.scheme, host, port, path });
    return std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ origin.scheme, host, path });
}

fn isWithinHost(host: []const u8, allowed: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, allowed)) return true;
    if (host.len <= allowed.len + 1) return false;
    const suffix_start = host.len - allowed.len;
    return host[suffix_start - 1] == '.' and std.ascii.eqlIgnoreCase(host[suffix_start..], allowed);
}

fn isLoopback(host: []const u8) bool {
    for (loopback_hosts) |loopback| {
        if (std.ascii.eqlIgnoreCase(host, loopback)) return true;
    }
    return false;
}

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
    identity: Identity,
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
const lease_poll_ms = 250;
const maximum_inline_hold_ms = 5_000;

/// How long a service stays claimed after a Gateway's last request.
pub const lease_duration_ms: i64 = 120_000;

/// A service's rate-limit state, as a `StateStore` keeps it. Times are Unix
/// milliseconds.
pub const SharedState = struct {
    blocked_until_ms: ?i64 = null,
    /// The rate-limit backoff the next refusal doubles.
    backoff_ms: u64 = 0,
    next_request_ms: ?i64 = null,
};

/// Where Gateways keep each service's rate-limit state and a lease on
/// talking to it, so every Gateway over one store obeys the same block and
/// only one at a time talks to a service. Times are Unix milliseconds.
pub const StateStore = struct {
    context: *anyopaque,
    load_fn: *const fn (*anyopaque, []const u8) anyerror!?SharedState,
    save_fn: *const fn (*anyopaque, []const u8, SharedState) anyerror!void,
    claim_fn: *const fn (*anyopaque, []const u8, i64, i64, i64) anyerror!bool,
    release_fn: *const fn (*anyopaque, []const u8, i64) anyerror!void,

    pub fn load(self: StateStore, service: []const u8) !?SharedState {
        return self.load_fn(self.context, service);
    }

    pub fn save(self: StateStore, service: []const u8, state: SharedState) !void {
        return self.save_fn(self.context, service, state);
    }

    /// True when `owner` holds `service` until `expires_at_ms`: nobody held
    /// it, the holder's lease ran out by `now_ms`, or `owner` already held it.
    pub fn claim(self: StateStore, service: []const u8, owner: i64, now_ms: i64, expires_at_ms: i64) !bool {
        return self.claim_fn(self.context, service, owner, now_ms, expires_at_ms);
    }

    pub fn release(self: StateStore, service: []const u8, owner: i64) !void {
        return self.release_fn(self.context, service, owner);
    }
};

pub const Sharing = struct {
    store: StateStore,
    service: []const u8,
};

/// Half to one and a half times `milliseconds`, for a backoff Orca chooses,
/// so clients that failed together do not retry together.
pub fn jittered(random: std.Random, milliseconds: u64) u64 {
    const shortest = milliseconds - milliseconds / 2;
    const longest = milliseconds +| milliseconds / 2;
    return shortest + random.uintAtMost(u64, longest - shortest);
}

/// A `4xx` that sending the same request again cannot change: not a refused
/// credential, a timeout or a rate limit.
pub fn isPermanentRejection(status: u16) bool {
    return status >= 400 and status < 500 and status != 401 and status != 403 and status != 408 and status != 429;
}

/// Central policy boundary for every provider request. Transport adapters only
/// perform I/O; identification, rate limiting, retry/backoff, deadlines,
/// response bounds, and offline behavior are enforced here. A Gateway is owned
/// by one thread; only `cancel` may be set from another.
pub const Gateway = struct {
    transport: Transport,
    clock: Clock,
    /// Unix time in milliseconds, which an HTTP-date `Retry-After` and a
    /// `StateStore` are in.
    wall_clock: Clock,
    /// Spreads every backoff Orca chooses (`jittered`) and picks lease owners.
    random: std.Random,
    config: Config,
    cancel: ?*const std.atomic.Value(bool) = null,
    /// Null keeps the service's state in this Gateway alone and claims no
    /// lease.
    sharing: ?Sharing = null,
    last_request_ms: ?i64 = null,
    hold_until_ms: ?i64 = null,
    blocked_until_ms: ?i64 = null,
    rate_limit_backoff_ms: u64 = 0,
    lease_owner: ?i64 = null,
    deadline_ms: ?i64 = null,

    /// With `sharing`, claims the service before each request and fails with
    /// `error.ProviderBusy` while another Gateway over the store holds it,
    /// at once or, with `deadline_ms`, once the deadline passes.
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
        _ = try self.requestTimeoutMs();
        try self.loadSharedState();
        if (self.blockedUntilMs() != null) return error.RateLimited;
        const user_agent = try self.config.identity.userAgent(allocator);
        defer allocator.free(user_agent);
        var attempt: u8 = 0;
        var backoff = self.config.initial_backoff_ms;
        while (attempt < self.config.maximum_attempts) : (attempt += 1) {
            try self.claimLease();
            try self.awaitTurn();
            const timeout_ms = try self.requestTimeoutMs();
            const response = self.transport.perform(allocator, .{
                .method = method,
                .url = url,
                .body = body,
                .headers = headers,
                .user_agent = user_agent,
                .max_response_bytes = self.config.max_response_bytes,
                .timeout_ms = timeout_ms,
                .cancel = self.cancel,
            }) catch |err| switch (err) {
                error.OutOfMemory, error.ResponseTooLarge, error.Canceled, error.Timeout => return err,
                error.ConcurrencyUnavailable => return error.InvalidNetworkConfiguration,
                else => {
                    if (attempt + 1 == self.config.maximum_attempts)
                        return error.NetworkUnavailable;
                    try self.sleepCancelable(jittered(self.random, backoff));
                    backoff = @min(backoff *| 2, 60_000);
                    continue;
                },
            };
            const refused = self.recordResponse(response) catch |err| {
                response.deinit();
                return err;
            };
            if (refused) {
                response.deinit();
                return error.RateLimited;
            }
            if (!retryableStatus(response.status) or attempt + 1 == self.config.maximum_attempts)
                return response;
            response.deinit();
            try self.sleepCancelable(jittered(self.random, backoff));
            backoff = @min(backoff *| 2, 60_000);
        }
        unreachable;
    }

    /// A GET under the same rules as `execute` that follows at most
    /// `max_redirects` redirects, each one `allowance` permits from the URL
    /// before it, sending only the user agent to their targets. A redirect it
    /// does not permit fails with `error.RedirectRefused`; one past the limit
    /// is returned as it came.
    pub fn fetch(
        self: *Gateway,
        allocator: std.mem.Allocator,
        url: []const u8,
        headers: []const Header,
        allowance: RedirectAllowance,
    ) !Response {
        var response = try self.execute(allocator, .get, url, null, headers);
        var current_url = try allocator.dupe(u8, url);
        defer allocator.free(current_url);
        var hops: u8 = 0;
        while (isRedirect(response.status) and hops < max_redirects) : (hops += 1) {
            const redirect = response;
            defer redirect.deinit();
            const location = redirect.location orelse return error.RedirectRefused;
            const target = try redirectTarget(allocator, current_url, location, allowance);
            allocator.free(current_url);
            current_url = target;
            response = try self.follow(allocator, target);
        }
        return response;
    }

    fn follow(self: *Gateway, allocator: std.mem.Allocator, target: []const u8) !Response {
        try self.checkCanceled();
        const timeout_ms = try self.requestTimeoutMs();
        const user_agent = try self.config.identity.userAgent(allocator);
        defer allocator.free(user_agent);
        const followed = self.transport.perform(allocator, .{
            .method = .get,
            .url = target,
            .user_agent = user_agent,
            .max_response_bytes = self.config.max_response_bytes,
            .timeout_ms = timeout_ms,
            .cancel = self.cancel,
        }) catch |err| switch (err) {
            error.OutOfMemory, error.ResponseTooLarge, error.Canceled, error.Timeout => return err,
            error.ConcurrencyUnavailable => return error.InvalidNetworkConfiguration,
            else => return error.NetworkUnavailable,
        };
        const refused = self.recordResponse(followed) catch |err| {
            followed.deinit();
            return err;
        };
        if (refused) {
            followed.deinit();
            return error.RateLimited;
        }
        return followed;
    }

    pub fn blockedUntilMs(self: *Gateway) ?i64 {
        const until = self.blocked_until_ms orelse return null;
        return if (self.clock.nowMs() < until) until else null;
    }

    /// `blockedUntilMs` as Unix time in milliseconds.
    pub fn blockedUntilWallMs(self: *Gateway) ?i64 {
        const until = self.blockedUntilMs() orelse return null;
        return self.wall_clock.nowMs() +| (until -| self.clock.nowMs());
    }

    /// Holds every request to the service back for `milliseconds`, unless it
    /// is already blocked for longer, for a failure the caller saw.
    pub fn blockFor(self: *Gateway, milliseconds: u64) !void {
        const until = self.clock.nowMs() +| std.math.lossyCast(i64, milliseconds);
        self.blocked_until_ms = if (self.blockedUntilMs()) |current| @max(current, until) else until;
        try self.saveSharedState();
    }

    /// Adopts the block, backoff and next request time the store holds for
    /// the service. A block or hold is never shortened.
    pub fn loadSharedState(self: *Gateway) !void {
        const sharing = self.sharing orelse return;
        const stored = try sharing.store.load(sharing.service) orelse return;
        self.rate_limit_backoff_ms = stored.backoff_ms;
        if (stored.next_request_ms) |wall_next| {
            const next = self.monotonicFromWall(wall_next);
            self.hold_until_ms = if (self.hold_until_ms) |current| @max(current, next) else next;
        }
        const wall_until = stored.blocked_until_ms orelse return;
        const until = self.monotonicFromWall(wall_until);
        self.blocked_until_ms = if (self.blocked_until_ms) |current| @max(current, until) else until;
    }

    /// Lets another Gateway claim the service at once. A lease that cannot be
    /// released runs out `lease_duration_ms` after its last request.
    pub fn releaseLease(self: *Gateway) void {
        const sharing = self.sharing orelse return;
        const owner = self.lease_owner orelse return;
        sharing.store.release(sharing.service, owner) catch {};
    }

    fn claimLease(self: *Gateway) !void {
        const sharing = self.sharing orelse return;
        const owner = self.lease_owner orelse self.random.int(i64);
        self.lease_owner = owner;
        while (true) {
            const now = self.wall_clock.nowMs();
            if (try sharing.store.claim(sharing.service, owner, now, now +| lease_duration_ms)) break;
            const deadline = self.deadline_ms orelse return error.ProviderBusy;
            const left = deadline -| self.clock.nowMs();
            if (left <= 0) return error.ProviderBusy;
            try self.sleepCancelable(@intCast(@min(left, lease_poll_ms)));
        }
        try self.loadSharedState();
        if (self.blockedUntilMs() != null) return error.RateLimited;
    }

    fn requestTimeoutMs(self: *Gateway) error{Timeout}!u64 {
        const deadline = self.deadline_ms orelse return self.config.request_timeout_ms;
        const left = deadline -| self.clock.nowMs();
        if (left <= 0) return error.Timeout;
        return @min(self.config.request_timeout_ms, @as(u64, @intCast(left)));
    }

    fn saveSharedState(self: *Gateway) !void {
        const sharing = self.sharing orelse return;
        try sharing.store.save(sharing.service, .{
            .blocked_until_ms = if (self.blocked_until_ms) |until| self.wallFromMonotonic(until) else null,
            .backoff_ms = self.rate_limit_backoff_ms,
            .next_request_ms = if (self.nextRequestMs()) |next| self.wallFromMonotonic(next) else null,
        });
    }

    fn nextRequestMs(self: *Gateway) ?i64 {
        var next: ?i64 = null;
        if (self.last_request_ms) |last|
            next = last +| @as(i64, @intCast(self.config.minimum_interval_ms));
        if (self.hold_until_ms) |hold|
            next = if (next) |spacing| @max(spacing, hold) else hold;
        return next;
    }

    fn monotonicFromWall(self: *Gateway, wall_ms: i64) i64 {
        return self.clock.nowMs() +| (wall_ms -| self.wall_clock.nowMs());
    }

    fn wallFromMonotonic(self: *Gateway, monotonic_ms: i64) i64 {
        return self.wall_clock.nowMs() +| (monotonic_ms -| self.clock.nowMs());
    }

    /// True when the response refuses requests for now: a `429`, or a `503`
    /// with a `Retry-After`.
    fn recordResponse(self: *Gateway, response: Response) !bool {
        const now = self.clock.nowMs();
        const limit = response.rate_limit;
        self.hold_until_ms = null;
        if (limit.remaining == 0) {
            if (limit.reset_in_s) |seconds|
                self.hold_until_ms = now +| @as(i64, @intCast(self.boundedMs(@as(u64, seconds) * 1000)));
        }
        if (response.status == 429 or (response.status == 503 and limit.retry_after != null)) {
            self.rate_limit_backoff_ms = if (self.rate_limit_backoff_ms == 0)
                self.config.initial_rate_limit_backoff_ms
            else
                self.boundedMs(self.rate_limit_backoff_ms *| 2);
            const reset_ms = self.boundedMs(@as(u64, limit.reset_in_s orelse 0) * 1000);
            const backoff_ms = jittered(self.random, self.rate_limit_backoff_ms);
            var until = now +| std.math.lossyCast(i64, @max(reset_ms, backoff_ms));
            if (limit.retry_after) |retry_after| until = @max(until, self.retryAfterUntil(retry_after));
            self.blocked_until_ms = until;
            try self.saveSharedState();
            return true;
        }
        if (response.status >= 200 and response.status < 300) self.rate_limit_backoff_ms = 0;
        // The caller gets the response even when the state cannot be stored.
        self.saveSharedState() catch {};
        return false;
    }

    fn retryAfterUntil(self: *Gateway, retry_after: RetryAfter) i64 {
        return switch (retry_after) {
            .seconds => |seconds| self.clock.nowMs() +| std.math.lossyCast(i64, seconds *| 1000),
            .date => |unix_s| self.monotonicFromWall(unix_s *| 1000),
        };
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
                try self.saveSharedState();
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
        var location: ?[]u8 = null;
        errdefer if (location) |value| allocator.free(value);
        var header_iterator = response.head.iterateHeaders();
        while (header_iterator.next()) |header| {
            rate_limit.observe(header.name, header.value);
            if (location == null and std.ascii.eqlIgnoreCase(header.name, "location"))
                location = try allocator.dupe(u8, header.value);
        }

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
            .location = location,
        };
    }
};

pub const SystemClock = struct {
    io: std.Io,

    pub fn clock(self: *SystemClock) Clock {
        return .{ .context = self, .now_ms_fn = nowMs, .sleep_ms_fn = sleepMs };
    }

    /// Unix time in milliseconds, for expiry times stored across restarts.
    pub fn wallClock(self: *SystemClock) Clock {
        return .{ .context = self, .now_ms_fn = wallMs, .sleep_ms_fn = sleepMs };
    }

    fn nowMs(context: *anyopaque) i64 {
        const self: *SystemClock = @ptrCast(@alignCast(context));
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    fn wallMs(context: *anyopaque) i64 {
        const self: *SystemClock = @ptrCast(@alignCast(context));
        return std.Io.Clock.real.now(self.io).toMilliseconds();
    }

    fn sleepMs(context: *anyopaque, milliseconds: u64) !void {
        const self: *SystemClock = @ptrCast(@alignCast(context));
        try std.Io.sleep(self.io, .fromMilliseconds(@intCast(milliseconds)), .awake);
    }
};

const net_testing = @import("testing.zig");
const TestGateway = net_testing.TestGateway;

fn fetchOnce(gateway: *Gateway) !u16 {
    const response = try gateway.execute(std.testing.allocator, .get, "https://example.test", null, &.{});
    defer response.deinit();
    return response.status;
}

test "user agent names Orca, its version and the contact" {
    var net: TestGateway = undefined;
    net.init(.{});
    defer net.deinit();
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&net.gateway));
    try std.testing.expectEqualStrings(
        "Orca/" ++ liborca_version ++ " ( https://orca.invalid )",
        net.transport.lastUserAgent(),
    );
}

test "user agent of a host identity is followed by liborca's" {
    var net: TestGateway = undefined;
    net.init(.{ .config = .{
        .identity = .{ .name = "Player", .version = "1.2.3", .contact = "https://player.example" },
    } });
    defer net.deinit();
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&net.gateway));
    try std.testing.expectEqualStrings(
        "Player/1.2.3 ( https://player.example ) liborca/" ++ liborca_version,
        net.transport.lastUserAgent(),
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
        .{ .name = "A" ** 200, .version = "1", .contact = "a" ** 56 },
    };
    for (invalid) |identity| {
        var net: TestGateway = undefined;
        net.init(.{ .config = .{ .identity = identity } });
        defer net.deinit();
        try std.testing.expectError(error.InvalidNetworkConfiguration, fetchOnce(&net.gateway));
        try std.testing.expectEqual(@as(u32, 0), net.transport.requestCount());
    }
}

test "an owned identity keeps its text after the caller's buffer changes" {
    var name = "Player".*;
    const owned: OwnedIdentity = try .init(.{ .name = &name, .version = "1.2.3", .contact = "https://player.example" });
    @memset(&name, 'x');
    const identity = owned.view();
    try std.testing.expectEqualStrings("Player", identity.name);
    try std.testing.expectEqualStrings("1.2.3", identity.version);
    try std.testing.expectEqualStrings("https://player.example", identity.contact);
    try std.testing.expectError(error.InvalidNetworkConfiguration, OwnedIdentity.init(.{ .name = "", .version = "1", .contact = "a" }));
}

test "Orca under another version is a host identity and names liborca too" {
    const identity: Identity = .{ .name = "Orca", .version = "0.0.1", .contact = "https://orca.invalid" };
    try std.testing.expect(!identity.isOrca());
    const user_agent = try identity.userAgent(std.testing.allocator);
    defer std.testing.allocator.free(user_agent);
    try std.testing.expectEqualStrings("Orca/0.0.1 ( https://orca.invalid ) liborca/" ++ liborca_version, user_agent);
}

test "rate limit headers are read case-insensitively, and Retry-After as delay-seconds or an HTTP-date" {
    var limit: RateLimit = .{};
    limit.observe("X-RateLimit-Remaining", "0");
    limit.observe("x-ratelimit-reset-in", " 7 ");
    limit.observe("RETRY-AFTER", "30");
    try std.testing.expectEqual(@as(?u32, 0), limit.remaining);
    try std.testing.expectEqual(@as(?u32, 7), limit.reset_in_s);
    try std.testing.expectEqual(@as(?RetryAfter, .{ .seconds = 30 }), limit.retry_after);

    var dated: RateLimit = .{};
    dated.observe("Retry-After", " Wed, 21 Oct 2026 07:28:00 GMT");
    try std.testing.expectEqual(@as(?RetryAfter, .{ .date = 1_792_567_680 }), dated.retry_after);
    try std.testing.expectEqual(@as(?RetryAfter, .{ .date = 784_111_777 }), RetryAfter.parse("Sun, 06 Nov 1994 08:49:37 GMT"));
    try std.testing.expectEqual(@as(?RetryAfter, .{ .date = 951_868_799 }), RetryAfter.parse("Tue, 29 Feb 2000 23:59:59 GMT"));
    try std.testing.expectEqual(@as(?RetryAfter, .{ .seconds = std.math.maxInt(u64) }), RetryAfter.parse("99999999999999999999999"));

    var unreadable: RateLimit = .{};
    unreadable.observe("X-RateLimit-Reset-In", "-1");
    unreadable.observe("X-RateLimit-Remaining", "+3");
    unreadable.observe("Retry-After", "abc");
    try std.testing.expectEqual(RateLimit{}, unreadable);
    for ([_][]const u8{
        "",
        "-5",
        "1.5",
        "Wed, 21 Oct 2026 07:28:00 UTC",
        "Wednesday, 21-Oct-26 07:28:00 GMT",
        "Wed Oct 21 07:28:00 2026",
        "Wed, 31 Feb 2026 07:28:00 GMT",
        "Wed, 21 Oct 2026 24:00:00 GMT",
        "Wed, 21 Okt 2026 07:28:00 GMT",
        "wed, 21 Oct 2026 07:28:00 GMT",
    }) |value| try std.testing.expectEqual(@as(?RetryAfter, null), RetryAfter.parse(value));
}

fn expectBlockedFor(status: u16, limit: RateLimit, started_ms: i64, shortest_ms: i64, longest_ms: i64) !void {
    var net: TestGateway = undefined;
    net.init(.{ .config = .{ .identity = net_testing.test_identity, .maximum_attempts = 3, .minimum_interval_ms = 0 }, .now_ms = started_ms });
    defer net.deinit();
    try net.transport.script(.{ .respond = .{ .status = status, .rate_limit = limit } });
    try std.testing.expectError(error.RateLimited, fetchOnce(&net.gateway));
    try std.testing.expectEqual(@as(u32, 1), net.transport.requestCount());
    const until = net.gateway.blockedUntilMs().?;
    try std.testing.expect(until >= started_ms + shortest_ms);
    try std.testing.expect(until <= started_ms + longest_ms);

    net.clock.set(until - 1);
    try std.testing.expectError(error.RateLimited, fetchOnce(&net.gateway));
    try std.testing.expectEqual(@as(u32, 1), net.transport.requestCount());

    net.clock.set(until);
    try std.testing.expectEqual(@as(?i64, null), net.gateway.blockedUntilMs());
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&net.gateway));
    try std.testing.expectEqual(@as(u32, 2), net.transport.requestCount());
}

test "a 429 is not retried and blocks requests for the jittered default backoff" {
    try expectBlockedFor(429, .{}, 0, 30_000, 90_000);
}

test "a 429 blocks requests until Retry-After when it is longer than the backoff" {
    try expectBlockedFor(429, .{ .retry_after = .{ .seconds = 120 } }, 0, 120_000, 120_000);
}

test "a 429 blocks requests until Reset-In when it is longer than the backoff" {
    try expectBlockedFor(429, .{ .reset_in_s = 300, .remaining = 0 }, 0, 300_000, 300_000);
}

test "a Retry-After of two hours, or of three years, is honoured in full" {
    try expectBlockedFor(429, .{ .retry_after = .{ .seconds = 2 * 60 * 60 } }, 0, 7_200_000, 7_200_000);
    try expectBlockedFor(429, .{ .retry_after = .{ .seconds = 99_999_999 } }, 0, 99_999_999_000, 99_999_999_000);
}

test "a Retry-After date blocks requests until that date, and one in the past only for the backoff" {
    const date_s: i64 = 1_792_567_680;
    const now_ms = date_s * 1000 - 600_000;
    try expectBlockedFor(429, .{ .retry_after = .{ .date = date_s } }, now_ms, 600_000, 600_000);
    try expectBlockedFor(429, .{ .retry_after = .{ .date = date_s - 3600 } }, now_ms, 30_000, 90_000);
}

test "a 503 with Retry-After blocks the service like a 429, in either form" {
    try expectBlockedFor(503, .{ .retry_after = .{ .seconds = 600 } }, 0, 600_000, 600_000);
    const date_s: i64 = 1_792_567_680;
    try expectBlockedFor(503, .{ .retry_after = .{ .date = date_s } }, date_s * 1000 - 900_000, 900_000, 900_000);
}

test "a 503 without Retry-After is returned to the caller and blocks nothing" {
    var net: TestGateway = undefined;
    net.init(.{});
    defer net.deinit();
    net.transport.otherwise = .{ .respond = .{ .status = 503 } };
    try std.testing.expectEqual(@as(u16, 503), try fetchOnce(&net.gateway));
    try std.testing.expectEqual(@as(?i64, null), net.gateway.blockedUntilMs());
}

test "consecutive 429s double the backoff up to an hour, each block jittered around it, and a success resets it" {
    var net: TestGateway = undefined;
    net.init(.{ .config = .{ .identity = net_testing.test_identity, .minimum_interval_ms = 0 } });
    defer net.deinit();
    net.transport.otherwise = .{ .respond = .{ .status = 429 } };
    const expected_s = [_]i64{ 60, 120, 240, 480, 960, 1920, 3600, 3600 };
    for (expected_s) |seconds| {
        const started = net.clock.now();
        try std.testing.expectError(error.RateLimited, fetchOnce(&net.gateway));
        try std.testing.expectEqual(@as(u64, @intCast(seconds * 1000)), net.gateway.rate_limit_backoff_ms);
        const until = net.gateway.blockedUntilMs().?;
        try std.testing.expect(until >= started + seconds * 500);
        try std.testing.expect(until <= started + seconds * 1500);
        net.clock.set(until);
    }

    net.transport.otherwise = .{ .respond = .{} };
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&net.gateway));
    try std.testing.expectEqual(@as(u64, 0), net.gateway.rate_limit_backoff_ms);
    net.transport.otherwise = .{ .respond = .{ .status = 429 } };
    try std.testing.expectError(error.RateLimited, fetchOnce(&net.gateway));
    try std.testing.expectEqual(@as(u64, 60_000), net.gateway.rate_limit_backoff_ms);
}

test "a jittered backoff stays within half to one and a half times its length and spreads across it" {
    var prng: std.Random.DefaultPrng = .init(42);
    const random = prng.random();
    var shortest: u64 = std.math.maxInt(u64);
    var longest: u64 = 0;
    for (0..1000) |_| {
        const value = jittered(random, 60_000);
        shortest = @min(shortest, value);
        longest = @max(longest, value);
    }
    try std.testing.expect(shortest >= 30_000 and shortest < 33_000);
    try std.testing.expect(longest <= 90_000 and longest > 87_000);
    try std.testing.expectEqual(@as(u64, 0), jittered(random, 0));
    try std.testing.expectEqual(@as(u64, 1), jittered(random, 1));
    for (0..100) |_| {
        const value = jittered(random, 3);
        try std.testing.expect(value >= 2 and value <= 4);
    }
}

test "an exhausted quota holds the next request until a short advertised reset" {
    var net: TestGateway = undefined;
    net.init(.{});
    defer net.deinit();
    try net.transport.script(.{ .respond = .{ .rate_limit = .{ .remaining = 0, .reset_in_s = 3 } } });
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&net.gateway));
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&net.gateway));
    try std.testing.expectEqual(@as(i64, 3000), net.transport.request_times_ms[1] - net.transport.request_times_ms[0]);
}

test "an exhausted quota with a long reset is scheduled instead of slept" {
    var net: TestGateway = undefined;
    net.init(.{});
    defer net.deinit();
    try net.transport.script(.{ .respond = .{ .rate_limit = .{ .remaining = 0, .reset_in_s = 7 } } });
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&net.gateway));
    try std.testing.expectError(error.RateLimited, fetchOnce(&net.gateway));
    try std.testing.expectEqual(@as(u32, 1), net.transport.requestCount());
    try std.testing.expectEqual(@as(u64, 0), net.clock.slept());
    try std.testing.expectEqual(@as(?i64, 7000), net.gateway.blockedUntilMs());
}

const MemoryStateStore = struct {
    state: ?SharedState = null,

    fn store(self: *MemoryStateStore) StateStore {
        return .{ .context = self, .load_fn = load, .save_fn = save, .claim_fn = claim, .release_fn = release };
    }

    fn load(context: *anyopaque, _: []const u8) anyerror!?SharedState {
        const self: *MemoryStateStore = @ptrCast(@alignCast(context));
        return self.state;
    }

    fn save(context: *anyopaque, _: []const u8, state: SharedState) anyerror!void {
        const self: *MemoryStateStore = @ptrCast(@alignCast(context));
        self.state = state;
    }

    fn claim(_: *anyopaque, _: []const u8, _: i64, _: i64, _: i64) anyerror!bool {
        return true;
    }

    fn release(_: *anyopaque, _: []const u8, _: i64) anyerror!void {}
};

const SuccessiveGateways = struct {
    net: TestGateway,
    store: MemoryStateStore,
    second: Gateway,

    const wall_offset_ms: i64 = 1_800_000_000_000;

    fn init(self: *SuccessiveGateways) void {
        self.net.init(.{ .now_ms = 5000, .wall_offset_ms = wall_offset_ms });
        self.store = .{};
        const sharing: Sharing = .{ .store = self.store.store(), .service = "musicbrainz" };
        self.net.gateway.sharing = sharing;
        self.second = net_testing.gateway(&self.net.transport, &self.net.clock, &self.net.prng, self.net.gateway.config);
        self.second.sharing = sharing;
    }

    fn deinit(self: *SuccessiveGateways) void {
        self.net.deinit();
    }
};

test "a quota window a previous Gateway was told of blocks a fresh Gateway's first request" {
    var gateways: SuccessiveGateways = undefined;
    gateways.init();
    defer gateways.deinit();
    try gateways.net.transport.script(.{ .respond = .{ .rate_limit = .{ .remaining = 0, .reset_in_s = 3600 } } });
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&gateways.net.gateway));
    const reset_wall_ms = gateways.net.clock.wallNow() + 3_600_000;

    try std.testing.expectError(error.RateLimited, fetchOnce(&gateways.second));
    try std.testing.expectEqual(@as(u32, 1), gateways.net.transport.requestCount());
    try std.testing.expectEqual(@as(u64, 0), gateways.net.clock.slept());
    try std.testing.expectEqual(@as(?i64, reset_wall_ms), gateways.store.state.?.blocked_until_ms);
    try std.testing.expectEqual(@as(?i64, reset_wall_ms), gateways.second.blockedUntilWallMs());
}

test "a fresh Gateway's first request waits the minimum interval after a previous Gateway's last" {
    var gateways: SuccessiveGateways = undefined;
    gateways.init();
    defer gateways.deinit();
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&gateways.net.gateway));
    gateways.net.clock.advance(300);

    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&gateways.second));
    try std.testing.expectEqual(@as(u32, 2), gateways.net.transport.requestCount());
    const times = gateways.net.transport.request_times_ms;
    try std.testing.expectEqual(@as(i64, 1000), times[1] - times[0]);
}

test "a short quota window a previous Gateway was told of is waited out by a fresh Gateway" {
    var gateways: SuccessiveGateways = undefined;
    gateways.init();
    defer gateways.deinit();
    try gateways.net.transport.script(.{ .respond = .{ .rate_limit = .{ .remaining = 0, .reset_in_s = 3 } } });
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&gateways.net.gateway));

    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&gateways.second));
    const times = gateways.net.transport.request_times_ms;
    try std.testing.expectEqual(@as(i64, 3000), times[1] - times[0]);
    try std.testing.expectEqual(@as(u64, 3000), gateways.net.clock.slept());
    try std.testing.expectEqual(@as(?i64, null), gateways.second.blockedUntilMs());
}

test "a transport without concurrency is a configuration error and is not retried" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var transport: StandardTransport = .init(std.testing.allocator, threaded.io());
    defer transport.deinit();
    var system_clock: SystemClock = .{ .io = threaded.io() };
    const random: std.Random.IoSource = .{ .io = threaded.io() };
    var gateway = systemGateway(&transport, &system_clock, &random, .{ .identity = net_testing.test_identity, .maximum_attempts = 3, .request_timeout_ms = 5000 });
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
    var net: TestGateway = undefined;
    net.init(.{});
    defer net.deinit();
    net.transport.otherwise = .{ .respond = .{ .rate_limit = .{ .remaining = 5, .reset_in_s = 7 } } };
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&net.gateway));
    net.clock.advance(400);
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&net.gateway));
    net.clock.advance(2500);
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&net.gateway));
    try std.testing.expectEqual(@as(i64, 1000), net.transport.request_times_ms[1] - net.transport.request_times_ms[0]);
    try std.testing.expectEqual(@as(i64, 2500), net.transport.request_times_ms[2] - net.transport.request_times_ms[1]);
}

test "server errors are retried only up to the configured attempts" {
    var single: TestGateway = undefined;
    single.init(.{});
    defer single.deinit();
    try single.transport.script(.{ .respond = .{ .status = 503 } });
    try std.testing.expectEqual(@as(u16, 503), try fetchOnce(&single.gateway));
    try std.testing.expectEqual(@as(u32, 1), single.transport.requestCount());

    var patient: TestGateway = undefined;
    patient.init(.{ .config = .{ .identity = net_testing.test_identity, .maximum_attempts = 3, .minimum_interval_ms = 100, .initial_backoff_ms = 10 } });
    defer patient.deinit();
    try patient.transport.script(.{ .respond = .{ .status = 503 } });
    try patient.transport.script(.{ .respond = .{ .status = 503 } });
    try std.testing.expectEqual(@as(u16, 200), try fetchOnce(&patient.gateway));
    try std.testing.expectEqual(@as(u32, 3), patient.transport.requestCount());

    patient.transport.otherwise = .{ .fail = error.ConnectionRefused };
    try std.testing.expectError(error.NetworkUnavailable, fetchOnce(&patient.gateway));
    try std.testing.expectEqual(@as(u32, 3 + 3), patient.transport.requestCount());
}

test "offline mode, timeouts and a set cancel flag stop the gateway before or without retrying" {
    var net: TestGateway = undefined;
    net.init(.{ .config = .{ .identity = net_testing.test_identity, .maximum_attempts = 3, .request_timeout_ms = 1234 } });
    defer net.deinit();
    net.transport.otherwise = .{ .fail = error.Timeout };
    try std.testing.expectError(error.Timeout, fetchOnce(&net.gateway));
    try std.testing.expectEqual(@as(u32, 1), net.transport.requestCount());
    try std.testing.expectEqual(@as(u64, 1234), net.transport.timeout_ms);

    var canceled: std.atomic.Value(bool) = .init(true);
    net.gateway.cancel = &canceled;
    try std.testing.expectError(error.Canceled, fetchOnce(&net.gateway));
    try std.testing.expectEqual(@as(u32, 1), net.transport.requestCount());

    net.gateway.config.offline = true;
    try std.testing.expectError(error.Offline, fetchOnce(&net.gateway));
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

fn systemGateway(transport: *StandardTransport, clock: *SystemClock, random: *const std.Random.IoSource, config: Config) Gateway {
    return .{
        .transport = transport.transport(),
        .clock = clock.clock(),
        .wall_clock = clock.wallClock(),
        .random = random.interface(),
        .config = config,
    };
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
    const random: std.Random.IoSource = .{ .io = io };
    var gateway = systemGateway(&transport, &system_clock, &random, .{ .identity = net_testing.test_identity, .request_timeout_ms = 5000 });

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
    try std.testing.expectEqual(@as(?RetryAfter, .{ .seconds = 30 }), response.rate_limit.retry_after);
    const head = server.request_head[0..server.request_head_len];
    try std.testing.expect(std.mem.indexOf(
        u8,
        head,
        "user-agent: Orca/" ++ liborca_version ++ " ( https://orca.invalid )\r\n",
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
    const random: std.Random.IoSource = .{ .io = io };
    var gateway = systemGateway(&transport, &system_clock, &random, .{ .identity = net_testing.test_identity, .request_timeout_ms = 300 });

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
    const random: std.Random.IoSource = .{ .io = io };
    var gateway = systemGateway(&transport, &system_clock, &random, .{ .identity = net_testing.test_identity, .request_timeout_ms = 10_000 });
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

const archive_allowance: RedirectAllowance = .{ .host = "archive.org" };

fn redirectTo(location: []const u8) net_testing.Reply {
    return .{ .respond = .{ .status = 307, .body = "", .location = location } };
}

test "fetch follows two redirects within archive.org and sends their targets no headers but the user agent" {
    var net: TestGateway = undefined;
    net.init(.{});
    defer net.deinit();
    net.transport.keep_history = true;
    try net.transport.script(redirectTo("https://archive.org/download/mbid-x/front.jpg"));
    try net.transport.script(redirectTo("https://dn710702.ca.archive.org/0/items/mbid-x/front.jpg"));
    try net.transport.script(.{ .respond = .{ .body = "image" } });
    const response = try net.gateway.fetch(
        std.testing.allocator,
        "https://coverartarchive.org/release/x/front-500",
        &.{.{ .name = "Authorization", .value = "Token secret" }},
        archive_allowance,
    );
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("image", response.body);
    try std.testing.expectEqual(@as(u32, 3), net.transport.requestCount());
    try std.testing.expectEqualStrings("https://archive.org/download/mbid-x/front.jpg", net.transport.history.items[1].url);
    try std.testing.expectEqualStrings("https://dn710702.ca.archive.org/0/items/mbid-x/front.jpg", net.transport.history.items[2].url);
    try std.testing.expectEqualStrings("", net.transport.lastAuthorization());
}

test "a second redirect to plain http or off the archive is refused and its target never requested" {
    for ([_][]const u8{ "http://dn1.ca.archive.org/front.jpg", "https://example.org/front.jpg" }) |location| {
        var net: TestGateway = undefined;
        net.init(.{});
        defer net.deinit();
        try net.transport.script(redirectTo("https://archive.org/download/a"));
        try net.transport.script(redirectTo(location));
        try std.testing.expectError(error.RedirectRefused, net.gateway.fetch(
            std.testing.allocator,
            "https://coverartarchive.org/release/x/front-500",
            &.{},
            archive_allowance,
        ));
        try std.testing.expectEqual(@as(u32, 2), net.transport.requestCount());
    }
}

test "a redirect to plain http, to another host or to a host merely ending in archive.org is refused unrequested" {
    for ([_][]const u8{
        "http://archive.org/download/front.jpg",
        "https://example.org/front.jpg",
        "https://notarchive.org/front.jpg",
        "https://archive.org.example.org/front.jpg",
        "https://user:secret@archive.org/front.jpg",
        "/download/front.jpg",
        "//example.org/front.jpg",
        "not a url",
    }) |location| {
        var net: TestGateway = undefined;
        net.init(.{});
        defer net.deinit();
        try net.transport.script(redirectTo(location));
        try std.testing.expectError(error.RedirectRefused, net.gateway.fetch(
            std.testing.allocator,
            "https://coverartarchive.org/release/x/front-500",
            &.{},
            archive_allowance,
        ));
        try std.testing.expectEqual(@as(u32, 1), net.transport.requestCount());
    }
}

test "a third redirect is returned as it came and not followed" {
    var net: TestGateway = undefined;
    net.init(.{});
    defer net.deinit();
    try net.transport.script(redirectTo("https://archive.org/download/a"));
    try net.transport.script(redirectTo("https://archive.org/download/b"));
    try net.transport.script(redirectTo("https://archive.org/download/c"));
    const response = try net.gateway.fetch(std.testing.allocator, "https://coverartarchive.org/release/x/front-500", &.{}, archive_allowance);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 307), response.status);
    try std.testing.expectEqual(@as(u32, 3), net.transport.requestCount());
}

test "a request to a loopback server may be redirected to that same server only" {
    const allocator = std.testing.allocator;
    const same_path = try redirectTarget(allocator, "http://127.0.0.1:8080/release/x/front-500", "/files/front.jpg", archive_allowance);
    defer allocator.free(same_path);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/files/front.jpg", same_path);
    const same_absolute = try redirectTarget(allocator, "http://localhost:8080/release/x", "http://localhost:8080/f.jpg", archive_allowance);
    defer allocator.free(same_absolute);
    try std.testing.expectEqualStrings("http://localhost:8080/f.jpg", same_absolute);
    for ([_][]const u8{ "http://127.0.0.1:9090/f.jpg", "http://localhost:8080/f.jpg", "http://archive.org/f.jpg" }) |location|
        try std.testing.expectError(error.RedirectRefused, redirectTarget(allocator, "http://127.0.0.1:8080/release/x", location, archive_allowance));
    try std.testing.expectError(error.RedirectRefused, redirectTarget(allocator, "https://coverartarchive.org/release/x", "/files/front.jpg", archive_allowance));
}

test "execute returns a redirect to the caller without following it" {
    var net: TestGateway = undefined;
    net.init(.{});
    defer net.deinit();
    try net.transport.script(redirectTo("https://archive.org/download/a"));
    const response = try net.gateway.execute(std.testing.allocator, .get, "https://example.test", null, &.{});
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 307), response.status);
    try std.testing.expectEqualStrings("https://archive.org/download/a", response.location.?);
    try std.testing.expectEqual(@as(u32, 1), net.transport.requestCount());
}
