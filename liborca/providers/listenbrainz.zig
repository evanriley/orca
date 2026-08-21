const std = @import("std");
const network = @import("../network/root.zig");
const credentials = @import("credentials.zig");
const scrobble = @import("scrobble.zig");

pub const ListenBrainz = struct {
    allocator: std.mem.Allocator,
    gateway: *network.Gateway,
    credentials: credentials.Store,
    endpoint: []const u8 = "https://api.listenbrainz.org/1/submit-listens",

    pub fn adapter(self: *ListenBrainz) scrobble.Adapter {
        return .{ .service = "listenbrainz", .context = self, .submit_fn = submitAdapter };
    }

    pub fn submit(self: *ListenBrainz, payload: []const u8) !void {
        const parsed = std.json.parseFromSlice(scrobble.Event, self.allocator, payload, .{}) catch
            return error.InvalidScrobblePayload;
        defer parsed.deinit();
        const token = (try self.credentials.get(
            self.allocator,
            "org.listenbrainz",
            "user-token",
        )) orelse return error.MissingProviderCredential;
        defer self.allocator.free(token);
        const authorization = try std.fmt.allocPrint(self.allocator, "Token {s}", .{token});
        defer self.allocator.free(authorization);
        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();
        const event = parsed.value;
        try std.json.Stringify.value(.{
            .listen_type = "single",
            .payload = &.{.{
                .listened_at = event.started_at,
                .track_metadata = .{
                    .artist_name = event.artist,
                    .track_name = event.title,
                    .release_name = event.album,
                    .additional_info = .{
                        .duration_ms = event.duration_ms,
                        .listened_ms = event.listened_ms,
                    },
                },
            }},
        }, .{}, &writer.writer);
        const response = try self.gateway.execute(
            self.allocator,
            .post,
            self.endpoint,
            writer.writer.buffered(),
            &.{
                .{ .name = "authorization", .value = authorization },
                .{ .name = "content-type", .value = "application/json" },
            },
        );
        defer response.deinit();
        if (response.status < 200 or response.status >= 300)
            return error.ProviderRejectedScrobble;
    }

    fn submitAdapter(context: *anyopaque, payload: []const u8) !void {
        const self: *ListenBrainz = @ptrCast(@alignCast(context));
        try self.submit(payload);
    }
};

test "ListenBrainz adapter transforms queued events and uses secure token" {
    const Mock = struct {
        submitted: bool = false,
        fn perform(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            request: network.client.Request,
        ) !network.client.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.submitted = true;
            try std.testing.expectEqual(network.client.Method.post, request.method);
            try std.testing.expect(std.mem.indexOf(u8, request.body.?, "\"listen_type\":\"single\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, request.body.?, "\"track_name\":\"Orca\"") != null);
            try std.testing.expectEqualStrings("Token secret-token", request.headers[0].value);
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
            _: []const u8,
        ) !?[]u8 {
            return try allocator.dupe(u8, "secret-token");
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
    var adapter: ListenBrainz = .{
        .allocator = std.testing.allocator,
        .gateway = &gateway,
        .credentials = .{ .context = &context, .get_fn = Secrets.get },
    };
    var payload_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer payload_writer.deinit();
    try std.json.Stringify.value(scrobble.Event{
        .title = "Orca",
        .artist = "Test Artist",
        .started_at = 1_700_000_000,
        .duration_ms = 180_000,
        .listened_ms = 100_000,
    }, .{}, &payload_writer.writer);
    try adapter.submit(payload_writer.writer.buffered());
    try std.testing.expect(mock.submitted);
}
