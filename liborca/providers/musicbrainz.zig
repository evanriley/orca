const std = @import("std");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/model.zig");
const network = @import("../network/root.zig");
const model = @import("model.zig");
const scoring = @import("scoring.zig");
const url_encoding = @import("url.zig");

pub const service = "musicbrainz";
pub const default_server = "https://musicbrainz.org";
const search_limit = 10;

pub const MusicBrainz = struct {
    gateway: *network.Gateway,
    cache: *database.ProviderCacheRepository,
    /// Unix time in milliseconds: cache entries outlive the process.
    wall_clock: network.client.Clock,
    server: []const u8 = default_server,
    cache_ttl_seconds: i64 = 30 * 24 * 60 * 60,
    refusal_ttl_seconds: i64 = 7 * 24 * 60 * 60,
    requests_answered: u64 = 0,
    cache_hits: u64 = 0,

    pub fn provider(self: *MusicBrainz) model.Provider {
        return .{ .id = service, .context = self, .search_fn = searchAdapter };
    }

    pub fn search(
        self: *MusicBrainz,
        allocator: std.mem.Allocator,
        query: model.Query,
    ) !model.CandidateList {
        if (isBlank(query.title) or isBlank(query.artist)) return error.InsufficientIdentificationEvidence;
        const request_url = try self.searchUrl(allocator, query);
        defer allocator.free(request_url);
        const now_s = @divFloor(self.wall_clock.nowMs(), 1000);
        if (try self.cache.get(allocator, service, request_url, now_s, false)) |cached| {
            defer cached.deinit();
            self.cache_hits += 1;
            if (cached.status != 200) return error.ProviderRejectedRequest;
            return parseCandidates(allocator, cached.body, query.album);
        }
        const response = self.gateway.execute(
            allocator,
            .get,
            request_url,
            null,
            &.{.{ .name = "accept", .value = "application/json" }},
        ) catch |err| switch (err) {
            error.RateLimited, error.NetworkUnavailable, error.Timeout, error.Offline => {
                if (try self.stale(allocator, request_url, now_s, query.album)) |list| return list;
                return err;
            },
            else => return err,
        };
        defer response.deinit();
        self.requests_answered += 1;
        if (response.status == 408 or response.status >= 500) {
            if (try self.stale(allocator, request_url, now_s, query.album)) |list| return list;
            return error.ProviderUnavailable;
        }
        if (response.status != 200) {
            if (network.client.isPermanentRejection(response.status))
                try self.cache.put(service, request_url, response.status, response.body, now_s + self.refusal_ttl_seconds);
            return error.ProviderRejectedRequest;
        }
        const candidates = try parseCandidates(allocator, response.body, query.album);
        errdefer candidates.deinit();
        try self.cache.put(service, request_url, response.status, response.body, now_s + self.cache_ttl_seconds);
        return candidates;
    }

    fn stale(
        self: *MusicBrainz,
        allocator: std.mem.Allocator,
        request_url: []const u8,
        now_s: i64,
        album: ?[]const u8,
    ) !?model.CandidateList {
        const entry = try self.cache.get(allocator, service, request_url, now_s, true) orelse return null;
        defer entry.deinit();
        if (entry.status != 200) return null;
        return try parseCandidates(allocator, entry.body, album);
    }

    fn searchUrl(self: MusicBrainz, allocator: std.mem.Allocator, query: model.Query) ![]u8 {
        var lucene = std.Io.Writer.Allocating.init(allocator);
        defer lucene.deinit();
        try writeTerm(&lucene.writer, "recording", query.title.?);
        try lucene.writer.writeAll(" AND ");
        try writeTerm(&lucene.writer, "artist", query.artist.?);
        if (!isBlank(query.album)) {
            try lucene.writer.writeAll(" ");
            try writeTerm(&lucene.writer, "release", query.album.?);
        }
        var request_url = std.Io.Writer.Allocating.init(allocator);
        errdefer request_url.deinit();
        try request_url.writer.print("{s}/ws/2/recording?fmt=json&limit={d}&query=", .{
            std.mem.trimEnd(u8, self.server, "/"),
            search_limit,
        });
        try url_encoding.writeEncoded(&request_url.writer, lucene.written());
        var list = request_url.toArrayList();
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

fn isBlank(text: ?[]const u8) bool {
    const value = text orelse return true;
    return std.mem.trim(u8, value, " \t").len == 0;
}

fn writeTerm(writer: *std.Io.Writer, field: []const u8, value: []const u8) !void {
    try writer.print("{s}:\"", .{field});
    for (value) |byte| {
        if (std.mem.indexOfScalar(u8, "+-&|!(){}[]^\"~*?:\\/", byte) != null) try writer.writeByte('\\');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

const ArtistCredit = struct {
    name: []const u8 = "",
    joinphrase: []const u8 = "",
};

const Track = struct {
    number: []const u8 = "",
};

const Medium = struct {
    @"track-offset": ?u32 = null,
    track: []const Track = &.{},
};

const Release = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    media: []const Medium = &.{},
};

const Recording = struct {
    id: []const u8,
    title: []const u8 = "",
    score: ?u32 = null,
    length: ?u64 = null,
    @"artist-credit": []const ArtistCredit = &.{},
    releases: []const Release = &.{},
};

fn parseCandidates(
    allocator: std.mem.Allocator,
    body: []const u8,
    album: ?[]const u8,
) !model.CandidateList {
    const Envelope = struct { recordings: []const Recording = &.{} };
    const parsed = std.json.parseFromSlice(Envelope, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidProviderResponse,
    };
    defer parsed.deinit();
    var candidates: std.ArrayList(model.Candidate) = .empty;
    errdefer {
        for (candidates.items) |candidate| candidate.deinit();
        candidates.deinit(allocator);
    }
    for (parsed.value.recordings) |recording| {
        if (!metadata.isMusicBrainzId(recording.id)) continue;
        const artist = try creditedArtist(allocator, recording.@"artist-credit");
        defer allocator.free(artist);
        const release: ?Release = if (try bestRelease(allocator, recording.releases, album)) |index|
            recording.releases[index]
        else
            null;
        var candidate = try model.Candidate.init(
            allocator,
            service,
            recording.id,
            recording.title,
            artist,
            if (release) |chosen| chosen.title else "",
        );
        errdefer candidate.deinit();
        candidate.duration_ms = recording.length;
        candidate.mb_score = if (recording.score) |score| @intCast(@min(score, 100)) else null;
        if (release) |chosen| {
            candidate.track_number = trackNumber(chosen);
            if (metadata.isMusicBrainzId(chosen.id)) candidate.release_mbid = try allocator.dupe(u8, chosen.id);
        }
        try candidates.append(allocator, candidate);
    }
    return .{ .allocator = allocator, .items = try candidates.toOwnedSlice(allocator) };
}

fn creditedArtist(allocator: std.mem.Allocator, credits: []const ArtistCredit) ![]u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    for (credits) |credit| {
        try joined.appendSlice(allocator, credit.name);
        try joined.appendSlice(allocator, credit.joinphrase);
    }
    return joined.toOwnedSlice(allocator);
}

fn bestRelease(allocator: std.mem.Allocator, releases: []const Release, album: ?[]const u8) !?usize {
    if (releases.len == 0) return null;
    if (isBlank(album)) return 0;
    var best: usize = 0;
    var best_similarity: f64 = -1;
    for (releases, 0..) |release, index| {
        const similarity = try scoring.textSimilarity(allocator, album.?, release.title);
        if (similarity > best_similarity) {
            best = index;
            best_similarity = similarity;
        }
    }
    return best;
}

fn trackNumber(release: Release) ?u32 {
    for (release.media) |medium| {
        for (medium.track) |track| {
            if (std.fmt.parseUnsigned(u32, track.number, 10)) |number| return number else |_| {}
        }
        if (medium.@"track-offset") |offset| return std.math.add(u32, offset, 1) catch null;
    }
    return null;
}

const testing = std.testing;
const fixture_path = "fixtures/providers/musicbrainz-recording-search.json";

fn readFixture() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, fixture_path, testing.allocator, .limited(1 << 20));
}

fn findCandidate(list: model.CandidateList, recording_mbid: []const u8) ?model.Candidate {
    for (list.items) |candidate| {
        if (std.mem.eql(u8, candidate.provider_id, recording_mbid)) return candidate;
    }
    return null;
}

test "a recording search yields the score, the whole artist credit and the release the album names" {
    const body = try readFixture();
    defer testing.allocator.free(body);
    const list = try parseCandidates(testing.allocator, body, "Hot Space");
    defer list.deinit();

    try testing.expectEqual(@as(usize, 4), list.items.len);
    const duet = list.items[0];
    try testing.expectEqualStrings("a6d3063b-c34f-46c7-b61c-dda4d94195a9", duet.provider_id);
    try testing.expectEqualStrings("Under Pressure", duet.title);
    try testing.expectEqualStrings("Queen & David Bowie", duet.artist);
    try testing.expectEqualStrings("Hot Space", duet.album);
    try testing.expectEqualStrings("047a4aae-27f8-4f2d-92fb-214fd8dc865a", duet.release_mbid.?);
    try testing.expectEqual(@as(?u32, 7), duet.track_number);
    try testing.expectEqual(@as(?u64, 266_920), duet.duration_ms);
    try testing.expectEqual(@as(?u8, 100), duet.mb_score);
    const unmeasured = findCandidate(list, "af59c0c3-f3da-4bc2-ae24-dd2aa93021a4").?;
    try testing.expectEqual(@as(?u64, null), unmeasured.duration_ms);
    try testing.expectEqual(@as(?u8, 68), unmeasured.mb_score);
}

test "the release closest to the album is chosen, and a side-numbered track falls back to its place on the medium" {
    const body = try readFixture();
    defer testing.allocator.free(body);
    const live = "e3a15a94-41d6-45c0-bbc1-aae6137bcb7a";

    const named = try parseCandidates(testing.allocator, body, "Live USA");
    defer named.deinit();
    const chosen = findCandidate(named, live).?;
    try testing.expectEqualStrings("Live USA", chosen.album);
    try testing.expectEqualStrings("786a6852-4b41-44c9-a585-c65f9caa54a1", chosen.release_mbid.?);
    try testing.expectEqual(@as(?u32, 6), chosen.track_number);

    const unnamed = try parseCandidates(testing.allocator, body, null);
    defer unnamed.deinit();
    const first = findCandidate(unnamed, live).?;
    try testing.expectEqualStrings("Live USA, Vol. 2", first.album);
    try testing.expectEqual(@as(?u32, 11), first.track_number);
}

test "an answer that is not a recording search is refused as invalid" {
    try testing.expectError(error.InvalidProviderResponse, parseCandidates(testing.allocator, "<html>", null));
    const empty = try parseCandidates(testing.allocator, "{\"recordings\":[]}", null);
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.items.len);
}

const empty_answer = "{\"recordings\":[]}";

const Rig = struct {
    library: database.LibraryDatabase,
    net: network.testing.TestGateway,
    adapter: MusicBrainz,

    fn init(self: *Rig, uri: [:0]const u8) !void {
        self.library = try database.LibraryDatabase.open(testing.allocator, testing.io, uri);
        self.net.init(.{ .now_ms = 1_800_000_000_000 });
        self.respond(200, empty_answer);
        self.adapter = .{
            .gateway = &self.net.gateway,
            .cache = &self.library.provider_cache,
            .wall_clock = self.net.clock.wallClock(),
        };
    }

    fn deinit(self: *Rig) void {
        self.net.deinit();
        self.library.close();
    }

    fn respond(self: *Rig, status: u16, body: []const u8) void {
        self.net.transport.otherwise = .{ .respond = .{ .status = status, .body = body } };
    }

    fn search(self: *Rig, query: model.Query) !model.CandidateList {
        return self.adapter.search(testing.allocator, query);
    }
};

test "a title with quotes and brackets is escaped for Lucene and then for the URL" {
    var rig: Rig = undefined;
    try rig.init("file:orca-musicbrainz-escape?mode=memory&cache=shared");
    defer rig.deinit();
    rig.adapter.server = "http://127.0.0.1:5000/";

    const list = try rig.search(.{ .title = "Say \"Hello\" (Remix)", .artist = "AC/DC", .album = "Live: 1+1" });
    defer list.deinit();

    try testing.expectEqualStrings(
        "http://127.0.0.1:5000/ws/2/recording?fmt=json&limit=10&query=" ++
            "recording%3A%22Say%20%5C%22Hello%5C%22%20%5C%28Remix%5C%29%22" ++
            "%20AND%20artist%3A%22AC%5C%2FDC%22" ++
            "%20release%3A%22Live%5C%3A%201%5C%2B1%22",
        rig.net.transport.lastUrl(),
    );
}

test "a search without a title or an artist makes no request" {
    var rig: Rig = undefined;
    try rig.init("file:orca-musicbrainz-insufficient?mode=memory&cache=shared");
    defer rig.deinit();

    try testing.expectError(error.InsufficientIdentificationEvidence, rig.search(.{ .title = "Orca", .artist = "" }));
    try testing.expectError(error.InsufficientIdentificationEvidence, rig.search(.{ .title = " ", .artist = "Artist" }));
    try testing.expectEqual(@as(u32, 0), rig.net.transport.requestCount());
}

test "answers are cached for thirty days, empty ones too, and an expired one stands in when the service is down" {
    var rig: Rig = undefined;
    try rig.init("file:orca-musicbrainz-cache?mode=memory&cache=shared");
    defer rig.deinit();
    const body = try readFixture();
    defer testing.allocator.free(body);
    rig.respond(200, body);

    const first = try rig.search(.{ .title = "Under Pressure", .artist = "Queen", .album = "Hot Space" });
    defer first.deinit();
    const again = try rig.search(.{ .title = "Under Pressure", .artist = "Queen", .album = "Hot Space" });
    defer again.deinit();
    rig.respond(200, empty_answer);
    const nothing = try rig.search(.{ .title = "Unknown", .artist = "Nobody" });
    defer nothing.deinit();
    const still_nothing = try rig.search(.{ .title = "Unknown", .artist = "Nobody" });
    defer still_nothing.deinit();

    try testing.expectEqual(@as(u32, 2), rig.net.transport.requestCount());
    try testing.expectEqual(@as(u64, 2), rig.adapter.requests_answered);
    try testing.expectEqual(@as(u64, 2), rig.adapter.cache_hits);
    try testing.expectEqual(@as(usize, 0), still_nothing.items.len);

    rig.net.clock.advance((rig.adapter.cache_ttl_seconds + 1) * 1000);
    rig.respond(503, empty_answer);
    const stale = try rig.search(.{ .title = "Under Pressure", .artist = "Queen", .album = "Hot Space" });
    defer stale.deinit();
    try testing.expectEqualStrings("Hot Space", stale.items[0].album);
    try testing.expectEqual(@as(u32, 3), rig.net.transport.requestCount());
}

test "an unavailable service is reported apart from a refused query, and a refusal the query did not cause is not cached" {
    var rig: Rig = undefined;
    try rig.init("file:orca-musicbrainz-failures?mode=memory&cache=shared");
    defer rig.deinit();
    rig.net.gateway.config.minimum_interval_ms = 0;
    const query: model.Query = .{ .title = "Orca", .artist = "Artist" };

    rig.respond(503, empty_answer);
    try testing.expectError(error.ProviderUnavailable, rig.search(query));
    for ([_]u16{ 401, 403, 408 }) |status| {
        rig.respond(status, empty_answer);
        try testing.expectError(if (status == 408) error.ProviderUnavailable else error.ProviderRejectedRequest, rig.search(query));
    }
    rig.net.transport.otherwise = .{ .fail = error.ConnectionRefused };
    try testing.expectError(error.NetworkUnavailable, rig.search(query));
    rig.respond(429, empty_answer);
    try testing.expectError(error.RateLimited, rig.search(query));
    try testing.expectError(error.RateLimited, rig.search(query));

    try testing.expectEqual(@as(u32, 6), rig.net.transport.requestCount());
    try testing.expect(try rig.library.provider_cache.get(testing.allocator, service, rig.net.transport.lastUrl(), 0, true) == null);
}

test "a query MusicBrainz refused is refused without a request for seven days, and asked again after" {
    var rig: Rig = undefined;
    try rig.init("file:orca-musicbrainz-refused?mode=memory&cache=shared");
    defer rig.deinit();
    rig.net.gateway.config.minimum_interval_ms = 0;
    const query: model.Query = .{ .title = "Orca", .artist = "Artist" };
    rig.respond(400, "{\"error\":\"Invalid query\"}");
    try testing.expectError(error.ProviderRejectedRequest, rig.search(query));

    rig.respond(200, empty_answer);
    try testing.expectError(error.ProviderRejectedRequest, rig.search(query));
    rig.net.clock.advance((rig.adapter.refusal_ttl_seconds - 1) * 1000);
    try testing.expectError(error.ProviderRejectedRequest, rig.search(query));
    try testing.expectEqual(@as(u32, 1), rig.net.transport.requestCount());
    try testing.expectEqual(@as(u64, 2), rig.adapter.cache_hits);

    rig.net.clock.advance(1000);
    rig.respond(503, empty_answer);
    try testing.expectError(error.ProviderUnavailable, rig.search(query));
    rig.respond(200, empty_answer);
    const answered = try rig.search(query);
    defer answered.deinit();
    try testing.expectEqual(@as(u32, 3), rig.net.transport.requestCount());
    try testing.expectEqual(@as(usize, 0), answered.items.len);
}
