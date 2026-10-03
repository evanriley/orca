//! One cached JSON GET for a provider whose answers are kept in
//! `provider_cache`: a fresh cached answer without a request, else the
//! service, else an expired answer when the service cannot be reached.

const std = @import("std");
const database = @import("../database/root.zig");
const network = @import("../network/root.zig");

pub const CachedGet = struct {
    gateway: *network.Gateway,
    cache: *database.ProviderCacheRepository,
    /// Unix time in milliseconds: cache entries outlive the process.
    wall_clock: network.client.Clock,
    /// The `provider_cache.provider` the answers are kept under.
    service: []const u8,
    /// How long an answer, a "not found" included, is kept.
    cache_ttl_seconds: i64 = 30 * 24 * 60 * 60,
    refusal_ttl_seconds: i64 = 7 * 24 * 60 * 60,
    requests_answered: u64 = 0,
    cache_hits: u64 = 0,

    /// The parsed answer, or null when the service answered 404 or 410. An
    /// answer is cached only once `parser` accepts it; `parser.parse`
    /// returns null for a body that says the thing is missing.
    pub fn get(
        self: *CachedGet,
        comptime T: type,
        allocator: std.mem.Allocator,
        request_url: []const u8,
        parser: anytype,
    ) !?T {
        const now_s = @divFloor(self.wall_clock.nowMs(), 1000);
        if (try self.cache.get(allocator, self.service, request_url, now_s, false)) |cached| {
            defer cached.deinit();
            self.cache_hits += 1;
            if (isMissing(cached.status)) return null;
            if (cached.status != 200) return error.ProviderRejectedRequest;
            return parser.parse(allocator, cached.body);
        }
        const response = self.gateway.execute(
            allocator,
            .get,
            request_url,
            null,
            &.{.{ .name = "accept", .value = "application/json" }},
        ) catch |err| switch (err) {
            error.RateLimited, error.NetworkUnavailable, error.Timeout, error.Offline => {
                if (try self.stale(T, allocator, request_url, now_s, parser)) |value| return value;
                return err;
            },
            else => return err,
        };
        defer response.deinit();
        self.requests_answered += 1;
        if (response.status == 408 or response.status >= 500) {
            if (try self.stale(T, allocator, request_url, now_s, parser)) |value| return value;
            return error.ProviderUnavailable;
        }
        if (isMissing(response.status)) {
            try self.cache.put(self.service, request_url, response.status, "", now_s + self.cache_ttl_seconds);
            return null;
        }
        if (response.status != 200) {
            if (network.client.isPermanentRejection(response.status))
                try self.cache.put(self.service, request_url, response.status, response.body, now_s + self.refusal_ttl_seconds);
            return error.ProviderRejectedRequest;
        }
        var value = try parser.parse(allocator, response.body);
        errdefer if (comptime std.meta.hasMethod(T, "deinit")) if (value) |*present| present.deinit();
        try self.cache.put(self.service, request_url, response.status, response.body, now_s + self.cache_ttl_seconds);
        return value;
    }

    fn stale(
        self: *CachedGet,
        comptime T: type,
        allocator: std.mem.Allocator,
        request_url: []const u8,
        now_s: i64,
        parser: anytype,
    ) !??T {
        const entry = try self.cache.get(allocator, self.service, request_url, now_s, true) orelse return null;
        defer entry.deinit();
        if (isMissing(entry.status)) return @as(?T, null);
        if (entry.status != 200) return null;
        return try parser.parse(allocator, entry.body);
    }
};

fn isMissing(status: u16) bool {
    return status == 404 or status == 410;
}

const testing = std.testing;

const LengthParser = struct {
    pub fn parse(_: LengthParser, _: std.mem.Allocator, body: []const u8) !?usize {
        if (body.len == 0) return error.InvalidProviderResponse;
        if (std.mem.eql(u8, body, "missing")) return null;
        return body.len;
    }
};

const Rig = struct {
    library: database.LibraryDatabase,
    net: network.testing.TestGateway,
    client: CachedGet,

    fn init(self: *Rig, uri: [:0]const u8) !void {
        self.library = try database.LibraryDatabase.open(testing.allocator, testing.io, uri);
        self.net.init(.{ .now_ms = 1_800_000_000_000 });
        self.net.gateway.config.minimum_interval_ms = 0;
        self.client = .{
            .gateway = &self.net.gateway,
            .cache = &self.library.provider_cache,
            .wall_clock = self.net.clock.wallClock(),
            .service = "wikidata",
        };
    }

    fn deinit(self: *Rig) void {
        self.net.deinit();
        self.library.close();
    }

    fn respond(self: *Rig, status: u16, body: []const u8) void {
        self.net.transport.otherwise = .{ .respond = .{ .status = status, .body = body } };
    }

    fn get(self: *Rig, url: []const u8) !?usize {
        return self.client.get(usize, testing.allocator, url, LengthParser{});
    }
};

test "an answer and a not-found are each cached for thirty days, and an expired answer stands in when the service is down" {
    var rig: Rig = undefined;
    try rig.init("file:orca-cached-get-ttl?mode=memory&cache=shared");
    defer rig.deinit();

    rig.respond(200, "four");
    try testing.expectEqual(@as(?usize, 4), try rig.get("https://www.wikidata.org/a"));
    rig.respond(404, "{}");
    try testing.expectEqual(@as(?usize, null), try rig.get("https://www.wikidata.org/b"));
    rig.net.clock.advance((rig.client.cache_ttl_seconds - 1) * 1000);
    try testing.expectEqual(@as(?usize, 4), try rig.get("https://www.wikidata.org/a"));
    try testing.expectEqual(@as(?usize, null), try rig.get("https://www.wikidata.org/b"));
    try testing.expectEqual(@as(u32, 2), rig.net.transport.requestCount());

    rig.net.clock.advance(2000);
    rig.respond(503, "");
    try testing.expectEqual(@as(?usize, 4), try rig.get("https://www.wikidata.org/a"));
    try testing.expectEqual(@as(?usize, null), try rig.get("https://www.wikidata.org/b"));
    try testing.expectError(error.ProviderUnavailable, rig.get("https://www.wikidata.org/c"));
}

test "a body the parser refuses is not cached, and a refusal is cached for seven days" {
    var rig: Rig = undefined;
    try rig.init("file:orca-cached-get-refusal?mode=memory&cache=shared");
    defer rig.deinit();

    rig.respond(200, "");
    try testing.expectError(error.InvalidProviderResponse, rig.get("https://www.wikidata.org/a"));
    rig.respond(200, "missing");
    try testing.expectEqual(@as(?usize, null), try rig.get("https://www.wikidata.org/a"));
    try testing.expectEqual(@as(?usize, null), try rig.get("https://www.wikidata.org/a"));
    try testing.expectEqual(@as(u32, 2), rig.net.transport.requestCount());

    rig.respond(400, "bad");
    try testing.expectError(error.ProviderRejectedRequest, rig.get("https://www.wikidata.org/b"));
    try testing.expectError(error.ProviderRejectedRequest, rig.get("https://www.wikidata.org/b"));
    try testing.expectEqual(@as(u32, 3), rig.net.transport.requestCount());
    rig.net.clock.advance(rig.client.refusal_ttl_seconds * 1000 + 1000);
    rig.respond(200, "ok");
    try testing.expectEqual(@as(?usize, 2), try rig.get("https://www.wikidata.org/b"));
}
