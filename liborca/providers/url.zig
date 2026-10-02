const std = @import("std");

pub fn writeEncoded(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 0xf] });
        }
    }
}

/// A provider server's base URL: `https`, or plain `http` to the loopback
/// host only, so a token or a user's library never crosses a network in clear
/// text.
pub fn validateServer(base_url: []const u8) error{InvalidServerUrl}!void {
    const uri = std.Uri.parse(base_url) catch return error.InvalidServerUrl;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
        return error.InvalidServerUrl;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = (uri.getHost(&host_buffer) catch return error.InvalidServerUrl).bytes;
    if (host.len == 0) return error.InvalidServerUrl;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidServerUrl;
    for ([_][]const u8{ "127.0.0.1", "[::1]", "localhost" }) |loopback| {
        if (std.ascii.eqlIgnoreCase(host, loopback)) return;
    }
    return error.InvalidServerUrl;
}

pub const max_server_bytes = 2048;

/// A validated server base URL held by value, so a worker copies it whole
/// and no copy dangles when the host sets another.
pub const OwnedServer = struct {
    bytes: [max_server_bytes]u8,
    len: u16,

    pub fn init(base_url: []const u8) error{InvalidServerUrl}!OwnedServer {
        if (base_url.len > max_server_bytes) return error.InvalidServerUrl;
        try validateServer(base_url);
        var owned: OwnedServer = .{ .bytes = @splat(0), .len = @intCast(base_url.len) };
        @memcpy(owned.bytes[0..base_url.len], base_url);
        return owned;
    }

    pub fn fixed(comptime base_url: []const u8) OwnedServer {
        return comptime init(base_url) catch @compileError("not a valid server: " ++ base_url);
    }

    pub fn view(self: *const OwnedServer) []const u8 {
        return self.bytes[0..self.len];
    }
};

test "a server is copied, and one too long or invalid is refused" {
    var caller = "http://127.0.0.1:8080/lb".*;
    const owned: OwnedServer = try .init(&caller);
    @memset(&caller, 'x');
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/lb", owned.view());

    var long: [max_server_bytes + 1]u8 = @splat('a');
    @memcpy(long[0.."https://".len], "https://");
    try std.testing.expectError(error.InvalidServerUrl, OwnedServer.init(&long));
    try std.testing.expectEqual(max_server_bytes, (try OwnedServer.init(long[0..max_server_bytes])).view().len);
    try std.testing.expectError(error.InvalidServerUrl, OwnedServer.init("http://127.0.0.1@example.org"));
}

test "plain HTTP is accepted only for a loopback server" {
    for ([_][]const u8{
        "https://api.listenbrainz.org",
        "https://listenbrainz.example.org/",
        "http://127.0.0.1:8080",
        "http://localhost",
        "http://LOCALHOST:9/lb",
        "http://[::1]:8080",
    }) |accepted| try validateServer(accepted);
    for ([_][]const u8{
        "http://api.listenbrainz.org",
        "http://192.168.1.10:8080",
        "http://127.0.0.1.example.org",
        "http://127.0.0.1@example.org/",
        "https://user:secret@example.org",
        "ftp://example.org",
        "https://example.org/?token=x",
        "https://example.org/#x",
        "example.org",
        "",
        "https://",
    }) |rejected| try std.testing.expectError(error.InvalidServerUrl, validateServer(rejected));
}
