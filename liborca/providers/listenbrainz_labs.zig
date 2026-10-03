//! Artists similar to an artist, from the ListenBrainz Labs API. The
//! similarity comes from listening sessions; no token is needed.

const std = @import("std");
const cached_get = @import("cached_get.zig");
const metadata = @import("../metadata/model.zig");

pub const service = "listenbrainz-labs";
pub const default_server = "https://labs.api.listenbrainz.org";
/// The similarity dataset ListenBrainz itself shows on an artist's page.
pub const algorithm = "session_based_days_9000_session_300_contribution_5_threshold_15_limit_50_skip_30";
/// At most this many similar artists are kept, the highest scores first.
pub const max_similar = 12;
pub const cache_ttl_seconds: i64 = 7 * 24 * 60 * 60;
const max_name_bytes = 512;

pub const SimilarArtist = struct {
    mbid: []const u8,
    name: []const u8,
    score: u32,
};

/// Strings live in `arena`.
pub const SimilarArtists = struct {
    arena: std.heap.ArenaAllocator,
    items: []const SimilarArtist = &.{},

    pub fn deinit(self: *SimilarArtists) void {
        self.arena.deinit();
    }
};

/// `GET {server}/similar-artists/json?artist_mbids={mbid}&algorithm=…`, the
/// highest `max_similar` scores. Null when Labs does not know the artist.
pub fn similarArtists(
    client: *cached_get.CachedGet,
    allocator: std.mem.Allocator,
    server: []const u8,
    artist_mbid: []const u8,
) !?SimilarArtists {
    if (!metadata.isMusicBrainzId(artist_mbid)) return error.InvalidMusicBrainzId;
    const request_url = try std.fmt.allocPrint(
        allocator,
        "{s}/similar-artists/json?artist_mbids={s}&algorithm=" ++ algorithm,
        .{ std.mem.trimEnd(u8, server, "/"), artist_mbid },
    );
    defer allocator.free(request_url);
    return client.get(SimilarArtists, allocator, request_url, Parser{ .reference = artist_mbid });
}

const Entry = struct {
    artist_mbid: ?[]const u8 = null,
    name: ?[]const u8 = null,
    score: ?f64 = null,
};

const Parser = struct {
    reference: []const u8,

    pub fn parse(self: Parser, allocator: std.mem.Allocator, body: []const u8) !?SimilarArtists {
        var result: SimilarArtists = .{ .arena = .init(allocator) };
        errdefer result.deinit();
        const arena = result.arena.allocator();
        const entries = std.json.parseFromSliceLeaky([]const Entry, arena, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidProviderResponse,
        };
        var similar: std.ArrayList(SimilarArtist) = .empty;
        for (entries) |entry| {
            const mbid = entry.artist_mbid orelse continue;
            if (!metadata.isMusicBrainzId(mbid) or std.ascii.eqlIgnoreCase(mbid, self.reference)) continue;
            const name = std.mem.trim(u8, entry.name orelse continue, " \t\r\n");
            if (name.len == 0 or name.len > max_name_bytes or !std.unicode.utf8ValidateSlice(name)) continue;
            const score = entry.score orelse continue;
            if (!(score > 0)) continue;
            try similar.append(arena, .{
                .mbid = mbid,
                .name = name,
                .score = if (score >= std.math.maxInt(u32)) std.math.maxInt(u32) else @intFromFloat(@round(score)),
            });
        }
        std.mem.sort(SimilarArtist, similar.items, {}, higherScore);
        result.items = similar.items[0..@min(similar.items.len, max_similar)];
        return result;
    }
};

fn higherScore(_: void, a: SimilarArtist, b: SimilarArtist) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.lessThan(u8, a.name, b.name);
}

const testing = std.testing;
const database = @import("../database/root.zig");
const network = @import("../network/root.zig");

const amine_mbid = "12398bf3-1b99-47b7-930c-f3956773f35a";

const Rig = struct {
    library: database.LibraryDatabase,
    net: network.testing.TestGateway,
    client: cached_get.CachedGet,

    fn init(self: *Rig, uri: [:0]const u8) !void {
        self.library = try database.LibraryDatabase.open(testing.allocator, testing.io, uri);
        self.net.init(.{ .now_ms = 1_800_000_000_000 });
        self.net.gateway.config.minimum_interval_ms = 0;
        self.client = .{
            .gateway = &self.net.gateway,
            .cache = &self.library.provider_cache,
            .wall_clock = self.net.clock.wallClock(),
            .service = service,
            .cache_ttl_seconds = cache_ttl_seconds,
        };
    }

    fn deinit(self: *Rig) void {
        self.net.deinit();
        self.library.close();
    }
};

test "similar artists are asked by MBID with the session algorithm and keep the twelve highest scores" {
    var rig: Rig = undefined;
    try rig.init("file:orca-labs-similar?mode=memory&cache=shared");
    defer rig.deinit();
    const body = try std.Io.Dir.cwd().readFileAlloc(testing.io, "fixtures/providers/listenbrainz-labs-similar-artists.json", testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(body);
    rig.net.transport.otherwise = .{ .respond = .{ .body = body } };

    var similar = (try similarArtists(&rig.client, testing.allocator, "http://127.0.0.1:9/", amine_mbid)).?;
    defer similar.deinit();
    try testing.expectEqualStrings(
        "http://127.0.0.1:9/similar-artists/json?artist_mbids=" ++ amine_mbid ++ "&algorithm=" ++ algorithm,
        rig.net.transport.lastUrl(),
    );
    try testing.expectEqual(@as(usize, max_similar), similar.items.len);
    try testing.expectEqualStrings("Smino", similar.items[0].name);
    try testing.expectEqual(@as(u32, 412), similar.items[0].score);
    for (similar.items[1..], similar.items[0 .. similar.items.len - 1]) |item, previous|
        try testing.expect(item.score <= previous.score);
    for (similar.items) |item| try testing.expect(!std.mem.eql(u8, item.mbid, amine_mbid));

    var again = (try similarArtists(&rig.client, testing.allocator, "http://127.0.0.1:9/", amine_mbid)).?;
    defer again.deinit();
    try testing.expectEqual(@as(u32, 1), rig.net.transport.requestCount());
}

test "an unknown artist and an empty answer give no similar artists and a malformed one is refused" {
    var rig: Rig = undefined;
    try rig.init("file:orca-labs-empty?mode=memory&cache=shared");
    defer rig.deinit();
    rig.net.transport.otherwise = .{ .respond = .{ .body = "[]" } };
    var empty = (try similarArtists(&rig.client, testing.allocator, default_server, amine_mbid)).?;
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.items.len);
    rig.net.transport.otherwise = .{ .respond = .{ .status = 404 } };
    try testing.expectEqual(@as(?SimilarArtists, null), try similarArtists(&rig.client, testing.allocator, default_server, "aaaaaaaa-0000-4000-8000-000000000000"));
    rig.net.transport.otherwise = .{ .respond = .{ .body = "{\"error\":1}" } };
    try testing.expectError(error.InvalidProviderResponse, similarArtists(&rig.client, testing.allocator, default_server, "bbbbbbbb-0000-4000-8000-000000000000"));
    try testing.expectError(error.InvalidMusicBrainzId, similarArtists(&rig.client, testing.allocator, default_server, "Aminé"));
}
