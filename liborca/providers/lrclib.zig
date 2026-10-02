const std = @import("std");
const network = @import("../network/root.zig");
const url_encoding = @import("url.zig");

pub const service = "lrclib";
pub const default_server = "https://lrclib.net";
pub const max_response_bytes: usize = 512 * 1024;
pub const max_duration_s: u32 = 3600;

pub const Query = struct {
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    duration_s: u32,

    pub fn init(title: []const u8, artist: []const u8, album: []const u8, duration_ms: ?i64) Query {
        const milliseconds = duration_ms orelse 0;
        const seconds = if (milliseconds <= 0) 0 else @divFloor(milliseconds + 500, 1000);
        return .{
            .title = title,
            .artist = artist,
            .album = album,
            .duration_s = if (seconds > max_duration_s) 0 else @intCast(seconds),
        };
    }

    /// BLAKE3 over every value with its length in front, so a change to any
    /// of them gives another digest and no two queries share one.
    pub fn digest(self: Query) [32]u8 {
        var hasher = std.crypto.hash.Blake3.init(.{});
        for ([_][]const u8{ self.title, self.artist, self.album }) |value| {
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, value.len, .little);
            hasher.update(&length);
            hasher.update(value);
        }
        var duration: [4]u8 = undefined;
        std.mem.writeInt(u32, &duration, self.duration_s, .little);
        hasher.update(&duration);
        var out: [32]u8 = undefined;
        hasher.final(&out);
        return out;
    }
};

const Body = struct {
    id: ?i64 = null,
    instrumental: bool = false,
    plainLyrics: ?[]const u8 = null,
    syncedLyrics: ?[]const u8 = null,
};

pub const Record = struct {
    parsed: std.json.Parsed(Body),

    pub fn id(self: Record) ?i64 {
        return self.parsed.value.id;
    }

    pub fn instrumental(self: Record) bool {
        return self.parsed.value.instrumental;
    }

    pub fn synced(self: Record) ?[]const u8 {
        return nonBlank(self.parsed.value.syncedLyrics);
    }

    pub fn plain(self: Record) ?[]const u8 {
        return nonBlank(self.parsed.value.plainLyrics);
    }

    pub fn deinit(self: Record) void {
        self.parsed.deinit();
    }
};

pub const Answer = union(enum) {
    found: Record,
    missing,
};

pub const Lrclib = struct {
    gateway: *network.Gateway,
    server: []const u8 = default_server,

    pub fn get(self: *Lrclib, allocator: std.mem.Allocator, query: Query) !Answer {
        const url = try requestUrl(allocator, self.server, query);
        defer allocator.free(url);
        const response = try self.gateway.execute(allocator, .get, url, null, &.{
            .{ .name = "accept", .value = "application/json" },
        });
        defer response.deinit();
        if (response.status == 404) return .missing;
        if (response.status == 408 or response.status >= 500) return error.ProviderUnavailable;
        if (response.status != 200) return error.ProviderRejectedRequest;
        const parsed = std.json.parseFromSlice(Body, allocator, response.body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidProviderResponse,
        };
        const record: Record = .{ .parsed = parsed };
        if (record.synced() == null and record.plain() == null and !record.instrumental()) {
            record.deinit();
            return .missing;
        }
        return .{ .found = record };
    }
};

pub fn requestUrl(allocator: std.mem.Allocator, server: []const u8, query: Query) ![]u8 {
    var request_url = std.Io.Writer.Allocating.init(allocator);
    errdefer request_url.deinit();
    const writer = &request_url.writer;
    try writer.print("{s}/api/get?track_name=", .{std.mem.trimEnd(u8, server, "/")});
    try url_encoding.writeEncoded(writer, query.title);
    try writer.writeAll("&artist_name=");
    try url_encoding.writeEncoded(writer, query.artist);
    if (query.album.len != 0) {
        try writer.writeAll("&album_name=");
        try url_encoding.writeEncoded(writer, query.album);
    }
    if (query.duration_s != 0) try writer.print("&duration={d}", .{query.duration_s});
    var list = request_url.toArrayList();
    return list.toOwnedSlice(allocator);
}

fn nonBlank(text: ?[]const u8) ?[]const u8 {
    const value = text orelse return null;
    return if (std.mem.trim(u8, value, " \t\r\n").len == 0) null else value;
}

const testing = std.testing;

fn testGateway(net: *network.testing.TestGateway) void {
    net.init(.{ .config = .{
        .identity = network.testing.test_identity,
        .max_response_bytes = max_response_bytes,
        .minimum_interval_ms = 0,
    } });
}

fn expectUrl(expected: []const u8, query: Query) !void {
    const url = try requestUrl(testing.allocator, "https://lrclib.net/", query);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(expected, url);
}

test "the query percent-encodes every value and leaves out an empty album" {
    try expectUrl(
        "https://lrclib.net/api/get?track_name=Caf%C3%A9%20%26%20Bar%3D%3F&artist_name=Sigur%20R%C3%B3s&album_name=%28%29%20%2B%2F&duration=233",
        .init("Café & Bar=?", "Sigur Rós", "() +/", 233_400),
    );
    try expectUrl(
        "https://lrclib.net/api/get?track_name=Pink%20Moon&artist_name=Nick%20Drake&duration=125",
        .init("Pink Moon", "Nick Drake", "", 124_500),
    );
}

test "a duration of zero, unknown, or over an hour is left out of the query" {
    for ([_]?i64{ 0, null, 4_000_000, -5 }) |duration_ms| {
        try expectUrl(
            "https://lrclib.net/api/get?track_name=a&artist_name=b&album_name=c",
            .init("a", "b", "c", duration_ms),
        );
    }
    try testing.expectEqual(@as(u32, 3600), Query.init("a", "b", "c", 3_600_000).duration_s);
}

test "the digest changes with every value and cannot be shifted from one field to the next" {
    const base = Query.init("Pink Moon", "Nick Drake", "Pink Moon", 124_000).digest();
    const variants = [_]Query{
        .init("Pink Moon!", "Nick Drake", "Pink Moon", 124_000),
        .init("Pink Moon", "Nick Drak", "Pink Moon", 124_000),
        .init("Pink Moon", "Nick Drake", "", 124_000),
        .init("Pink Moon", "Nick Drake", "Pink Moon", 125_000),
        .init("Pink MoonNick", " Drake", "Pink Moon", 124_000),
    };
    for (variants) |variant| try testing.expect(!std.mem.eql(u8, &base, &variant.digest()));
    try testing.expectEqualSlices(u8, &base, &Query.init("Pink Moon", "Nick Drake", "Pink Moon", 124_400).digest());
}

test "a record is read with either text null, and unknown fields are ignored" {
    var net: network.testing.TestGateway = undefined;
    testGateway(&net);
    defer net.deinit();
    try net.transport.script(.{ .respond = .{ .body =
        \\{"id":7,"name":"x","trackName":"t","artistName":"a","albumName":"b","duration":124.0,
        \\"instrumental":false,"plainLyrics":null,"syncedLyrics":"[00:01.00]One","hasWordSync":false,"lyricsfile":null}
    } });
    var lrclib: Lrclib = .{ .gateway = &net.gateway };
    const answer = try lrclib.get(testing.allocator, .init("t", "a", "b", 124_000));
    defer answer.found.deinit();
    try testing.expectEqual(@as(?i64, 7), answer.found.id());
    try testing.expectEqualStrings("[00:01.00]One", answer.found.synced().?);
    try testing.expectEqual(@as(?[]const u8, null), answer.found.plain());
    try testing.expectStringStartsWith(net.transport.lastUserAgent(), "Orca/");
}

test "a record with no lyrics that is not instrumental is missing, and an instrumental one is found" {
    var net: network.testing.TestGateway = undefined;
    testGateway(&net);
    defer net.deinit();
    try net.transport.script(.{ .respond = .{ .body = "{\"id\":1,\"instrumental\":false,\"plainLyrics\":null,\"syncedLyrics\":\" \"}" } });
    try net.transport.script(.{ .respond = .{ .body = "{\"id\":2,\"instrumental\":true,\"plainLyrics\":null,\"syncedLyrics\":null}" } });
    var lrclib: Lrclib = .{ .gateway = &net.gateway };
    try testing.expectEqual(Answer.missing, try lrclib.get(testing.allocator, .init("t", "a", "", 0)));
    const instrumental = try lrclib.get(testing.allocator, .init("t", "a", "", 0));
    defer instrumental.found.deinit();
    try testing.expect(instrumental.found.instrumental());
}

test "a 404 is missing, 5xx unavailable, another 4xx rejected, and a body that is not a record invalid" {
    var net: network.testing.TestGateway = undefined;
    net.init(.{ .config = .{
        .identity = network.testing.test_identity,
        .max_response_bytes = max_response_bytes,
        .minimum_interval_ms = 0,
        .maximum_attempts = 1,
    } });
    defer net.deinit();
    var lrclib: Lrclib = .{ .gateway = &net.gateway };
    const query: Query = .init("t", "a", "", 0);
    try net.transport.script(.{ .respond = .{ .status = 404, .body = "{\"code\":404}" } });
    try testing.expectEqual(Answer.missing, try lrclib.get(testing.allocator, query));
    try net.transport.script(.{ .respond = .{ .status = 502, .body = "" } });
    try testing.expectError(error.ProviderUnavailable, lrclib.get(testing.allocator, query));
    try net.transport.script(.{ .respond = .{ .status = 400, .body = "" } });
    try testing.expectError(error.ProviderRejectedRequest, lrclib.get(testing.allocator, query));
    for ([_][]const u8{ "<html>", "null", "[]", "{\"instrumental\":\"no\"}" }) |body| {
        try net.transport.script(.{ .respond = .{ .body = body } });
        try testing.expectError(error.InvalidProviderResponse, lrclib.get(testing.allocator, query));
    }
}
