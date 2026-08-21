const std = @import("std");
const database = @import("../database/root.zig");
const network = @import("../network/root.zig");
const credentials = @import("credentials.zig");
const model = @import("model.zig");
const url_encoding = @import("url.zig");

pub const AcoustId = struct {
    gateway: *network.Gateway,
    cache: *database.ProviderCacheRepository,
    credentials: credentials.Store,
    base_url: []const u8 = "https://api.acoustid.org/v2/lookup",
    cache_ttl_seconds: i64 = 90 * 24 * 60 * 60,

    pub fn provider(self: *AcoustId) model.Provider {
        return .{ .id = "acoustid", .context = self, .search_fn = searchAdapter };
    }

    pub fn search(self: *AcoustId, allocator: std.mem.Allocator, query: model.Query) !model.CandidateList {
        const fingerprint = query.acoustid_fingerprint orelse
            return error.MissingChromaprintFingerprint;
        const duration_ms = query.duration_ms orelse return error.MissingTrackDuration;
        if (fingerprint.len == 0) return error.MissingChromaprintFingerprint;
        const duration_seconds = @max(1, (duration_ms + 500) / 1000);
        const cache_key = try std.fmt.allocPrint(
            allocator,
            "{d}:{s}",
            .{ duration_seconds, fingerprint },
        );
        defer allocator.free(cache_key);
        const now = @divTrunc(self.gateway.clock.nowMs(), 1000);
        if (try self.cache.get(allocator, "acoustid", cache_key, now, false)) |cached| {
            defer cached.deinit();
            return parseCandidates(allocator, cached.body);
        }
        const client_key = (try self.credentials.get(allocator, "org.acoustid", "client-key")) orelse
            return error.MissingProviderCredential;
        defer allocator.free(client_key);
        const request_url = try self.buildUrl(allocator, client_key, duration_seconds, fingerprint);
        defer allocator.free(request_url);
        const response = self.gateway.execute(
            allocator,
            .get,
            request_url,
            null,
            &.{.{ .name = "accept", .value = "application/json" }},
        ) catch {
            if (try self.cache.get(allocator, "acoustid", cache_key, now, true)) |stale| {
                defer stale.deinit();
                return parseCandidates(allocator, stale.body);
            }
            return error.ProviderUnavailable;
        };
        defer response.deinit();
        if (response.status != 200) return error.ProviderRejectedRequest;
        const candidates = try parseCandidates(allocator, response.body);
        errdefer candidates.deinit();
        try self.cache.put(
            "acoustid",
            cache_key,
            response.status,
            response.body,
            now + self.cache_ttl_seconds,
        );
        return candidates;
    }

    fn buildUrl(
        self: AcoustId,
        allocator: std.mem.Allocator,
        client_key: []const u8,
        duration_seconds: u64,
        fingerprint: []const u8,
    ) ![]u8 {
        var writer = std.Io.Writer.Allocating.init(allocator);
        errdefer writer.deinit();
        try writer.writer.print(
            "{s}?meta=recordings+releasegroups&duration={d}&client=",
            .{ self.base_url, duration_seconds },
        );
        try url_encoding.writeEncoded(&writer.writer, client_key);
        try writer.writer.writeAll("&fingerprint=");
        try url_encoding.writeEncoded(&writer.writer, fingerprint);
        var list = writer.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    fn searchAdapter(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        query: model.Query,
    ) !model.CandidateList {
        const self: *AcoustId = @ptrCast(@alignCast(context));
        return self.search(allocator, query);
    }
};

fn parseCandidates(allocator: std.mem.Allocator, body: []const u8) !model.CandidateList {
    const Artist = struct { name: []const u8 = "" };
    const ReleaseGroup = struct { title: []const u8 = "" };
    const Recording = struct {
        id: []const u8,
        title: []const u8 = "",
        duration: ?u64 = null,
        artists: []const Artist = &.{},
        releasegroups: []const ReleaseGroup = &.{},
    };
    const Match = struct {
        score: f32 = 0,
        recordings: []const Recording = &.{},
    };
    const Envelope = struct {
        status: []const u8 = "",
        results: []const Match = &.{},
    };
    const parsed = std.json.parseFromSlice(Envelope, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidProviderResponse;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.status, "ok")) return error.ProviderRejectedRequest;
    var candidates: std.ArrayList(model.Candidate) = .empty;
    errdefer {
        for (candidates.items) |candidate| candidate.deinit();
        candidates.deinit(allocator);
    }
    for (parsed.value.results) |result| for (result.recordings) |recording| {
        var candidate = try model.Candidate.init(
            allocator,
            "acoustid",
            recording.id,
            recording.title,
            if (recording.artists.len > 0) recording.artists[0].name else "",
            if (recording.releasegroups.len > 0) recording.releasegroups[0].title else "",
        );
        candidate.duration_ms = if (recording.duration) |seconds| seconds * 1000 else null;
        candidate.fingerprint_similarity = std.math.clamp(result.score, 0, 1);
        try candidates.append(allocator, candidate);
    };
    return .{ .allocator = allocator, .items = try candidates.toOwnedSlice(allocator) };
}

test "AcoustID lookup keeps credentials out of durable cache keys" {
    const Mock = struct {
        calls: u8 = 0,
        fn perform(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            request: network.client.Request,
        ) !network.client.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expect(std.mem.indexOf(u8, request.url, "client=private-key") != null);
            const body =
                \\{"status":"ok","results":[{"score":0.97,"recordings":[
                \\{"id":"recording-1","title":"Orca","duration":180,
                \\"artists":[{"name":"Test Artist"}],"releasegroups":[{"title":"Ocean"}]}]}]}
            ;
            return .{ .allocator = allocator, .status = 200, .body = try allocator.dupe(u8, body) };
        }
    };
    const FakeClock = struct {
        fn now(_: *anyopaque) i64 {
            return 100_000;
        }
        fn sleep(_: *anyopaque, _: u64) !void {}
    };
    const Secrets = struct {
        fn get(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            service: []const u8,
            account: []const u8,
        ) !?[]u8 {
            try std.testing.expectEqualStrings("org.acoustid", service);
            try std.testing.expectEqualStrings("client-key", account);
            return try allocator.dupe(u8, "private-key");
        }
    };
    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        "file:orca-acoustid?mode=memory&cache=shared",
    );
    defer library.close();
    var mock: Mock = .{};
    var context: u8 = 0;
    var gateway: network.Gateway = .{
        .transport = .{ .context = &mock, .perform_fn = Mock.perform },
        .clock = .{
            .context = &context,
            .now_ms_fn = FakeClock.now,
            .sleep_ms_fn = FakeClock.sleep,
        },
        .config = .{ .minimum_interval_ms = 0 },
    };
    var adapter: AcoustId = .{
        .gateway = &gateway,
        .cache = &library.provider_cache,
        .credentials = .{ .context = &context, .get_fn = Secrets.get },
    };
    const query: model.Query = .{
        .duration_ms = 180_000,
        .acoustid_fingerprint = "AQADtM-qgF4",
    };
    var first = try adapter.search(std.testing.allocator, query);
    defer first.deinit();
    try std.testing.expectEqualStrings("recording-1", first.items[0].provider_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.97), first.items[0].fingerprint_similarity.?, 0.001);
    const durable = (try library.provider_cache.get(
        std.testing.allocator,
        "acoustid",
        "180:AQADtM-qgF4",
        100,
        false,
    )).?;
    defer durable.deinit();
    try std.testing.expect((try library.provider_cache.get(
        std.testing.allocator,
        "acoustid",
        "private-key",
        100,
        true,
    )) == null);
    var cached = try adapter.search(std.testing.allocator, query);
    defer cached.deinit();
    try std.testing.expectEqual(@as(u8, 1), mock.calls);
}
