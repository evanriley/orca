const std = @import("std");
const network = @import("../network/root.zig");
const credentials = @import("credentials.zig");
const scrobble = @import("scrobble.zig");
const url_encoding = @import("url.zig");

pub const LastFm = struct {
    allocator: std.mem.Allocator,
    gateway: *network.Gateway,
    credentials: credentials.Store,
    endpoint: []const u8 = "https://ws.audioscrobbler.com/2.0/",

    pub fn adapter(self: *LastFm) scrobble.Adapter {
        return .{ .service = "lastfm", .context = self, .submit_fn = submitAdapter };
    }

    pub fn submit(self: *LastFm, payload: []const u8) !void {
        const parsed = std.json.parseFromSlice(scrobble.Event, self.allocator, payload, .{}) catch
            return error.InvalidScrobblePayload;
        defer parsed.deinit();
        const api_key = try self.credential("api-key");
        defer self.allocator.free(api_key);
        const shared_secret = try self.credential("shared-secret");
        defer self.allocator.free(shared_secret);
        const session_key = try self.credential("session-key");
        defer self.allocator.free(session_key);
        var timestamp_buffer: [32]u8 = undefined;
        const timestamp = try std.fmt.bufPrint(&timestamp_buffer, "{d}", .{parsed.value.started_at});
        const signature = signatureFor(
            api_key,
            shared_secret,
            session_key,
            parsed.value,
            timestamp,
        );
        var signature_hex: [32]u8 = undefined;
        const hex = "0123456789abcdef";
        for (signature, 0..) |byte, index| {
            signature_hex[index * 2] = hex[byte >> 4];
            signature_hex[index * 2 + 1] = hex[byte & 0xf];
        }

        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();
        try appendParameter(&writer.writer, false, "method", "track.scrobble");
        try appendParameter(&writer.writer, true, "api_key", api_key);
        try appendParameter(&writer.writer, true, "artist", parsed.value.artist);
        try appendParameter(&writer.writer, true, "track", parsed.value.title);
        try appendParameter(&writer.writer, true, "timestamp", timestamp);
        if (parsed.value.album.len > 0)
            try appendParameter(&writer.writer, true, "album", parsed.value.album);
        try appendParameter(&writer.writer, true, "sk", session_key);
        try appendParameter(&writer.writer, true, "api_sig", &signature_hex);
        try appendParameter(&writer.writer, true, "format", "json");
        const response = try self.gateway.execute(
            self.allocator,
            .post,
            self.endpoint,
            writer.writer.buffered(),
            &.{.{
                .name = "content-type",
                .value = "application/x-www-form-urlencoded",
            }},
        );
        defer response.deinit();
        if (response.status < 200 or response.status >= 300)
            return error.ProviderRejectedScrobble;
        const api_result = std.json.parseFromSlice(
            struct { @"error": ?u32 = null },
            self.allocator,
            response.body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.InvalidProviderResponse;
        defer api_result.deinit();
        if (api_result.value.@"error" != null) return error.ProviderRejectedScrobble;
    }

    fn credential(self: LastFm, account: []const u8) ![]u8 {
        return (try self.credentials.get(
            self.allocator,
            "org.lastfm",
            account,
        )) orelse error.MissingProviderCredential;
    }

    fn submitAdapter(context: *anyopaque, payload: []const u8) !void {
        const self: *LastFm = @ptrCast(@alignCast(context));
        try self.submit(payload);
    }
};

fn signatureFor(
    api_key: []const u8,
    shared_secret: []const u8,
    session_key: []const u8,
    event: scrobble.Event,
    timestamp: []const u8,
) [16]u8 {
    var hasher = std.crypto.hash.Md5.init(.{});
    if (event.album.len > 0) {
        hasher.update("album");
        hasher.update(event.album);
    }
    hasher.update("api_key");
    hasher.update(api_key);
    hasher.update("artist");
    hasher.update(event.artist);
    hasher.update("methodtrack.scrobble");
    hasher.update("sk");
    hasher.update(session_key);
    hasher.update("timestamp");
    hasher.update(timestamp);
    hasher.update("track");
    hasher.update(event.title);
    hasher.update(shared_secret);
    var digest: [16]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn appendParameter(
    writer: *std.Io.Writer,
    separator: bool,
    name: []const u8,
    value: []const u8,
) !void {
    if (separator) try writer.writeByte('&');
    try url_encoding.writeEncoded(writer, name);
    try writer.writeByte('=');
    try url_encoding.writeEncoded(writer, value);
}

test "Last.fm adapter signs requests without exposing the shared secret" {
    const Mock = struct {
        submitted: bool = false,
        fn perform(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            request: network.client.Request,
        ) !network.client.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.submitted = true;
            const body = request.body.?;
            try std.testing.expect(std.mem.indexOf(u8, body, "method=track.scrobble") != null);
            try std.testing.expect(std.mem.indexOf(u8, body, "api_sig=") != null);
            try std.testing.expect(std.mem.indexOf(u8, body, "shared-secret") == null);
            return .{ .allocator = allocator, .status = 200, .body = try allocator.dupe(u8, "{}") };
        }
    };
    const FakeClock = struct {
        fn now(_: *anyopaque) i64 {
            return 0;
        }
        fn sleep(_: *anyopaque, _: u64) !void {}
    };
    const Secrets = struct {
        fn get(
            _: *anyopaque,
            allocator: std.mem.Allocator,
            _: []const u8,
            account: []const u8,
        ) !?[]u8 {
            const value = if (std.mem.eql(u8, account, "api-key"))
                "api-key-value"
            else if (std.mem.eql(u8, account, "shared-secret"))
                "shared-secret"
            else
                "session-key";
            return try allocator.dupe(u8, value);
        }
    };
    var context: u8 = 0;
    var mock: Mock = .{};
    var gateway: network.Gateway = .{
        .transport = .{ .context = &mock, .perform_fn = Mock.perform },
        .clock = .{
            .context = &context,
            .now_ms_fn = FakeClock.now,
            .sleep_ms_fn = FakeClock.sleep,
        },
        .config = .{ .minimum_interval_ms = 0 },
    };
    var adapter: LastFm = .{
        .allocator = std.testing.allocator,
        .gateway = &gateway,
        .credentials = .{ .context = &context, .get_fn = Secrets.get },
    };
    var payload_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer payload_writer.deinit();
    try std.json.Stringify.value(scrobble.Event{
        .title = "Orca",
        .artist = "Test Artist",
        .album = "Ocean",
        .started_at = 1_700_000_000,
        .duration_ms = 180_000,
        .listened_ms = 100_000,
    }, .{}, &payload_writer.writer);
    try adapter.submit(payload_writer.writer.buffered());
    try std.testing.expect(mock.submitted);
}
