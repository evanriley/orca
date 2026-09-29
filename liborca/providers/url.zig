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
