const std = @import("std");
const database = @import("../database/root.zig");
const network = @import("../network/root.zig");
const model = @import("model.zig");

pub const MusicBrainz = struct {
    gateway: *network.Gateway,
    cache: *database.ProviderCacheRepository,
    base_url: []const u8 = "https://musicbrainz.org/ws/2",
    cache_ttl_seconds: i64 = 30 * 24 * 60 * 60,

    pub fn provider(self: *MusicBrainz) model.Provider {
        return .{ .id = "musicbrainz", .context = self, .search_fn = searchAdapter };
    }

    pub fn search(
        self: *MusicBrainz,
        allocator: std.mem.Allocator,
        query: model.Query,
    ) !model.CandidateList {
        if ((query.title == null or query.title.?.len == 0) and
            (query.artist == null or query.artist.?.len == 0))
            return error.InsufficientIdentificationEvidence;
        const url = try self.buildUrl(allocator, query);
        defer allocator.free(url);
        const now = @divTrunc(self.gateway.clock.nowMs(), 1000);
        if (try self.cache.get(allocator, "musicbrainz", url, now, false)) |cached| {
            defer cached.deinit();
            return parseCandidates(allocator, cached.body);
        }
        const response = self.gateway.execute(
            allocator,
            .get,
            url,
            null,
            &.{.{ .name = "accept", .value = "application/json" }},
        ) catch {
            if (try self.cache.get(allocator, "musicbrainz", url, now, true)) |stale| {
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
            "musicbrainz",
            url,
            response.status,
            response.body,
            now + self.cache_ttl_seconds,
        );
        return candidates;
    }

    fn buildUrl(self: MusicBrainz, allocator: std.mem.Allocator, query: model.Query) ![]u8 {
        var writer = std.Io.Writer.Allocating.init(allocator);
        errdefer writer.deinit();
        try writer.writer.print("{s}/recording/?fmt=json&limit=25&query=", .{self.base_url});
        var separator = false;
        if (query.title) |title| if (title.len > 0) {
            try writeEncoded(&writer.writer, "recording:\"");
            try writeEncoded(&writer.writer, title);
            try writeEncoded(&writer.writer, "\"");
            separator = true;
        };
        if (query.artist) |artist| if (artist.len > 0) {
            if (separator) try writeEncoded(&writer.writer, " AND ");
            try writeEncoded(&writer.writer, "artist:\"");
            try writeEncoded(&writer.writer, artist);
            try writeEncoded(&writer.writer, "\"");
        };
        var list = writer.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    fn searchAdapter(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        query: model.Query,
    ) !model.CandidateList {
        const self: *MusicBrainz = @ptrCast(@alignCast(context));
        return self.search(allocator, query);
    }
};

fn writeEncoded(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 0xf] });
        }
    }
}

fn parseCandidates(allocator: std.mem.Allocator, body: []const u8) !model.CandidateList {
    const ArtistCredit = struct { name: []const u8 = "" };
    const Release = struct { title: []const u8 = "" };
    const Recording = struct {
        id: []const u8,
        title: []const u8,
        length: ?u64 = null,
        @"artist-credit": []const ArtistCredit = &.{},
        releases: []const Release = &.{},
    };
    const Envelope = struct { recordings: []const Recording = &.{} };
    const parsed = std.json.parseFromSlice(Envelope, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidProviderResponse;
    defer parsed.deinit();
    var candidates: std.ArrayList(model.Candidate) = .empty;
    errdefer {
        for (candidates.items) |candidate| candidate.deinit();
        candidates.deinit(allocator);
    }
    for (parsed.value.recordings) |recording| {
        var candidate = try model.Candidate.init(
            allocator,
            "musicbrainz",
            recording.id,
            recording.title,
            if (recording.@"artist-credit".len > 0) recording.@"artist-credit"[0].name else "",
            if (recording.releases.len > 0) recording.releases[0].title else "",
        );
        candidate.duration_ms = recording.length;
        try candidates.append(allocator, candidate);
    }
    return .{ .allocator = allocator, .items = try candidates.toOwnedSlice(allocator) };
}

test "MusicBrainz adapter caches parsed candidates and tolerates offline refresh" {
    const Mock = struct {
        calls: u8 = 0,

        fn perform(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            request: network.client.Request,
        ) !network.client.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expect(std.mem.indexOf(u8, request.url, "recording%3A%22Orca%22") != null);
            const body =
                \\{"recordings":[{"id":"mbid-1","title":"Orca","length":180000,
                \\"artist-credit":[{"name":"Test Artist"}],"releases":[{"title":"Ocean"}]}]}
            ;
            return .{ .allocator = allocator, .status = 200, .body = try allocator.dupe(u8, body) };
        }
    };
    const FakeClock = struct {
        now_ms: i64 = 100_000,

        fn now(context: *anyopaque) i64 {
            return (@as(*@This(), @ptrCast(@alignCast(context)))).now_ms;
        }
        fn sleep(_: *anyopaque, _: u64) !void {}
    };
    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        "file:orca-musicbrainz?mode=memory&cache=shared",
    );
    defer library.close();
    var mock: Mock = .{};
    var fake_clock: FakeClock = .{};
    var gateway: network.Gateway = .{
        .transport = .{ .context = &mock, .perform_fn = Mock.perform },
        .clock = .{
            .context = &fake_clock,
            .now_ms_fn = FakeClock.now,
            .sleep_ms_fn = FakeClock.sleep,
        },
        .config = .{ .minimum_interval_ms = 0 },
    };
    var adapter: MusicBrainz = .{
        .gateway = &gateway,
        .cache = &library.provider_cache,
    };
    var first = try adapter.search(std.testing.allocator, .{
        .title = "Orca",
        .artist = "Test Artist",
    });
    defer first.deinit();
    try std.testing.expectEqualStrings("mbid-1", first.items[0].provider_id);
    var cached = try adapter.search(std.testing.allocator, .{
        .title = "Orca",
        .artist = "Test Artist",
    });
    defer cached.deinit();
    try std.testing.expectEqual(@as(u8, 1), mock.calls);
    gateway.config.offline = true;
    fake_clock.now_ms += (adapter.cache_ttl_seconds + 1) * 1000;
    var stale = try adapter.search(std.testing.allocator, .{
        .title = "Orca",
        .artist = "Test Artist",
    });
    defer stale.deinit();
    try std.testing.expectEqualStrings("Ocean", stale.items[0].album);
}
