const std = @import("std");

const path = std.Io.Dir.path;

pub const max_bytes = 4 * 1024 * 1024;
pub const max_entries = 10_000;
pub const unknown_seconds = -1;

const byte_order_mark = "\xEF\xBB\xBF";
const extinf_prefix = "#EXTINF:";

pub const Info = struct {
    seconds: i32,
    text: []const u8,
};

pub const Entry = struct {
    location: []const u8,
    info: ?Info,
};

pub const ParsedPlaylist = struct {
    text: []const u8,
    entries: []const Entry,

    pub fn deinit(self: ParsedPlaylist, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.text);
    }
};

/// Entries of an M3U or M3U8 playlist, in order. Text that is not UTF-8 is
/// read as Latin-1; `location` is the line as written, not yet resolved.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !ParsedPlaylist {
    if (bytes.len > max_bytes) return error.PlaylistTooLarge;
    const body = if (std.mem.startsWith(u8, bytes, byte_order_mark)) bytes[byte_order_mark.len..] else bytes;
    const text = try decodeText(allocator, body);
    errdefer allocator.free(text);
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);
    var pending: ?Info = null;
    var lines: Lines = .{ .text = text };
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            if (std.ascii.startsWithIgnoreCase(line, extinf_prefix)) pending = parseInfo(line[extinf_prefix.len..]);
            continue;
        }
        if (entries.items.len == max_entries) return error.PlaylistTooLarge;
        try entries.append(allocator, .{ .location = line, .info = pending });
        pending = null;
    }
    return .{ .text = text, .entries = try entries.toOwnedSlice(allocator) };
}

fn decodeText(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return allocator.dupe(u8, bytes);
    var high: usize = 0;
    for (bytes) |byte| {
        if (byte >= 0x80) high += 1;
    }
    const text = try allocator.alloc(u8, bytes.len + high);
    var at: usize = 0;
    for (bytes) |byte| {
        if (byte < 0x80) {
            text[at] = byte;
            at += 1;
        } else {
            text[at] = 0xC0 | (byte >> 6);
            text[at + 1] = 0x80 | (byte & 0x3F);
            at += 2;
        }
    }
    return text;
}

const Lines = struct {
    text: []const u8,
    at: usize = 0,

    fn next(self: *Lines) ?[]const u8 {
        if (self.at >= self.text.len) return null;
        const start = self.at;
        const end = std.mem.indexOfAnyPos(u8, self.text, start, "\r\n") orelse self.text.len;
        self.at = end + 1;
        if (end + 1 < self.text.len and self.text[end] == '\r' and self.text[end + 1] == '\n') self.at += 1;
        return self.text[start..end];
    }
};

fn parseInfo(rest: []const u8) ?Info {
    const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return null;
    const fields = std.mem.trim(u8, rest[0..comma], " \t");
    const duration = fields[0 .. std.mem.indexOfAny(u8, fields, " \t") orelse fields.len];
    const seconds = parseSeconds(duration) orelse return null;
    return .{
        .seconds = if (seconds < 0) unknown_seconds else seconds,
        .text = std.mem.trim(u8, rest[comma + 1 ..], " \t"),
    };
}

fn parseSeconds(text: []const u8) ?i32 {
    if (std.fmt.parseInt(i32, text, 10)) |seconds| return seconds else |_| {}
    const value = std.fmt.parseFloat(f64, text) catch return null;
    const rounded = @round(value);
    if (!std.math.isFinite(rounded)) return null;
    if (rounded < std.math.minInt(i32) or rounded > std.math.maxInt(i32)) return null;
    return @intFromFloat(rounded);
}

pub fn splitArtistTitle(text: []const u8) ?struct { artist: []const u8, title: []const u8 } {
    const separator = " - ";
    const at = std.mem.indexOf(u8, text, separator) orelse return null;
    return .{
        .artist = std.mem.trim(u8, text[0..at], " \t"),
        .title = std.mem.trim(u8, text[at + separator.len ..], " \t"),
    };
}

pub const Location = union(enum) {
    path: []u8,
    unsupported,
};

/// The absolute, lexically normalised path an entry names. Relative entries
/// resolve against `base_directory`, which must be absolute. Symlinks are not
/// followed: the result names the path the playlist wrote.
pub fn resolve(allocator: std.mem.Allocator, base_directory: []const u8, location: []const u8) !Location {
    if (schemeLength(location)) |scheme_length| {
        if (!std.ascii.eqlIgnoreCase(location[0..scheme_length], "file")) return .unsupported;
        const decoded = try decodeFileUri(allocator, location[scheme_length + "://".len ..]) orelse
            return .unsupported;
        defer allocator.free(decoded);
        return .{ .path = try path.resolvePosix(allocator, &.{decoded}) };
    }
    if (path.isAbsolutePosix(location)) return .{ .path = try path.resolvePosix(allocator, &.{location}) };
    return .{ .path = try path.resolvePosix(allocator, &.{ base_directory, location }) };
}

fn schemeLength(location: []const u8) ?usize {
    if (location.len == 0 or !std.ascii.isAlphabetic(location[0])) return null;
    var at: usize = 1;
    while (at < location.len) : (at += 1) {
        const byte = location[at];
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') break;
    }
    if (!std.mem.startsWith(u8, location[at..], "://")) return null;
    return at;
}

fn decodeFileUri(allocator: std.mem.Allocator, after_scheme: []const u8) !?[]u8 {
    if (after_scheme.len == 0 or after_scheme[0] != '/') return null;
    var decoded: std.ArrayList(u8) = try .initCapacity(allocator, after_scheme.len);
    errdefer decoded.deinit(allocator);
    var at: usize = 0;
    while (at < after_scheme.len) {
        if (after_scheme[at] != '%') {
            decoded.appendAssumeCapacity(after_scheme[at]);
            at += 1;
            continue;
        }
        const byte = percentEscape(after_scheme[at..]) orelse {
            decoded.deinit(allocator);
            return null;
        };
        decoded.appendAssumeCapacity(byte);
        at += 3;
    }
    return try decoded.toOwnedSlice(allocator);
}

fn percentEscape(escape: []const u8) ?u8 {
    if (escape.len < 3) return null;
    const high = std.fmt.charToDigit(escape[1], 16) catch return null;
    const low = std.fmt.charToDigit(escape[2], 16) catch return null;
    const byte = high * 16 + low;
    return if (byte == 0) null else byte;
}

pub const WriteEntry = struct {
    seconds: i64,
    artist: []const u8,
    title: []const u8,
    path: []const u8,
};

/// Writes an extended M3U playlist. With `base_directory`, each path is
/// written relative to it; both must be absolute.
pub fn write(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    entries: []const WriteEntry,
    base_directory: ?[]const u8,
) !void {
    try writer.writeAll("#EXTM3U\n");
    for (entries) |entry| {
        try writer.print("{s}{d},", .{ extinf_prefix, entry.seconds });
        if (entry.artist.len != 0) {
            try writeTagText(writer, entry.artist);
            try writer.writeAll(" - ");
        }
        try writeTagText(writer, entry.title);
        try writer.writeByte('\n');
        if (base_directory) |base| {
            const relative = try path.relativePosix(allocator, "/", base, entry.path);
            defer allocator.free(relative);
            try writer.writeAll(relative);
        } else try writer.writeAll(entry.path);
        try writer.writeByte('\n');
    }
}

fn writeTagText(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| try writer.writeByte(if (byte == '\n' or byte == '\r') ' ' else byte);
}

pub fn representable(entry_path: []const u8) bool {
    return std.mem.indexOfAny(u8, entry_path, "\r\n") == null;
}

fn readFixture(name: []const u8) ![]u8 {
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, "fixtures/playlists", .{});
    defer directory.close(std.testing.io);
    return directory.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(max_bytes + 1));
}

test "a UTF-8 playlist keeps its entries in order with each #EXTINF attached to the next path" {
    const bytes = try readFixture("relative.m3u8");
    defer std.testing.allocator.free(bytes);
    const parsed = try parse(std.testing.allocator, bytes);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), parsed.entries.len);
    try std.testing.expectEqualStrings("../Music/Björk/01 Hyperballad.flac", parsed.entries[0].location);
    try std.testing.expectEqual(@as(i32, 321), parsed.entries[0].info.?.seconds);
    try std.testing.expectEqualStrings("Björk - Hyperballad", parsed.entries[0].info.?.text);
    try std.testing.expectEqualStrings("file:///mnt/Media/Music/Bj%C3%B6rk/02%20Joga.flac", parsed.entries[1].location);
    try std.testing.expectEqual(@as(i32, unknown_seconds), parsed.entries[1].info.?.seconds);
    try std.testing.expectEqualStrings("Sub/03.mp3", parsed.entries[2].location);
    try std.testing.expectEqual(@as(?Info, null), parsed.entries[2].info);
    try std.testing.expectEqualStrings("http://example.com/stream.mp3", parsed.entries[3].location);
}

test "a Latin-1 playlist with CRLF lines decodes to UTF-8" {
    const bytes = try readFixture("latin1.m3u");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(!std.unicode.utf8ValidateSlice(bytes));
    const parsed = try parse(std.testing.allocator, bytes);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.entries.len);
    try std.testing.expectEqualStrings("/music/Café/01 Été.mp3", parsed.entries[0].location);
    try std.testing.expectEqualStrings("Café Tacvba - Été", parsed.entries[0].info.?.text);
    try std.testing.expectEqualStrings("/music/Café/02.mp3", parsed.entries[1].location);
}

test "a byte order mark and CRLF lines parse the same as the bare LF playlist" {
    const bytes = try readFixture("bom.m3u8");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, byte_order_mark));
    const parsed = try parse(std.testing.allocator, bytes);
    defer parsed.deinit(std.testing.allocator);

    const bare = try std.mem.replaceOwned(u8, std.testing.allocator, bytes[byte_order_mark.len..], "\r\n", "\n");
    defer std.testing.allocator.free(bare);
    const expected = try parse(std.testing.allocator, bare);
    defer expected.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.entries.len);
    try std.testing.expectEqual(expected.entries.len, parsed.entries.len);
    for (expected.entries, parsed.entries) |want, got| {
        try std.testing.expectEqualStrings(want.location, got.location);
        try std.testing.expectEqualStrings(want.info.?.text, got.info.?.text);
        try std.testing.expectEqual(want.info.?.seconds, got.info.?.seconds);
    }
    try std.testing.expectEqualStrings("#EXTM3U", bytes[byte_order_mark.len..][0..7]);
    try std.testing.expectEqualStrings("/music/A/01.flac", parsed.entries[0].location);
}

test "an #EXTINF without a following path is dropped and lone CR ends a line" {
    const parsed = try parse(std.testing.allocator, "#EXTINF:5,Lost\r#EXTINF:7.6,A - B\r/x.flac\r#EXTINF:9,Trailing");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), parsed.entries.len);
    try std.testing.expectEqual(@as(i32, 8), parsed.entries[0].info.?.seconds);
    try std.testing.expectEqualStrings("A - B", parsed.entries[0].info.?.text);
}

test "a playlist over the byte or entry bound is refused" {
    const oversized = try std.testing.allocator.alloc(u8, max_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, '\n');
    try std.testing.expectError(error.PlaylistTooLarge, parse(std.testing.allocator, oversized));

    const line = "/a.flac\n";
    const too_many = try std.testing.allocator.alloc(u8, line.len * (max_entries + 1));
    defer std.testing.allocator.free(too_many);
    for (0..max_entries + 1) |index| @memcpy(too_many[index * line.len ..][0..line.len], line);
    try std.testing.expectError(error.PlaylistTooLarge, parse(std.testing.allocator, too_many));
    const at_bound = try parse(std.testing.allocator, too_many[0 .. line.len * max_entries]);
    defer at_bound.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, max_entries), at_bound.entries.len);
}

test "relative entries resolve against the playlist's directory and file URIs are percent-decoded" {
    const allocator = std.testing.allocator;
    const relative = try resolve(allocator, "/home/u/lists", "../Music/A/./01.flac");
    defer allocator.free(relative.path);
    try std.testing.expectEqualStrings("/home/u/Music/A/01.flac", relative.path);

    const uri = try resolve(allocator, "/home/u/lists", "file:///mnt/Media/Music/Bj%C3%B6rk//01.flac");
    defer allocator.free(uri.path);
    try std.testing.expectEqualStrings("/mnt/Media/Music/Björk/01.flac", uri.path);

    const absolute = try resolve(allocator, "/home/u/lists", "/a/b/../c.flac");
    defer allocator.free(absolute.path);
    try std.testing.expectEqualStrings("/a/c.flac", absolute.path);

    try std.testing.expectEqual(Location.unsupported, try resolve(allocator, "/l", "http://example.com/a.mp3"));
    try std.testing.expectEqual(Location.unsupported, try resolve(allocator, "/l", "file://server/share/a.mp3"));
    try std.testing.expectEqual(Location.unsupported, try resolve(allocator, "/l", "file:///a%2"));
    try std.testing.expectEqual(Location.unsupported, try resolve(allocator, "/l", "file:///a%00b"));
}

test "written playlists carry #EXTINF lines and relative paths that parse back to the same entries" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try write(allocator, &output.writer, &.{
        .{ .seconds = 200, .artist = "Art\nist", .title = "One", .path = "/m/Artist/01.flac" },
        .{ .seconds = -1, .artist = "", .title = "Two", .path = "/m/Other/02.flac" },
    }, "/m/lists");
    try std.testing.expectEqualStrings(
        "#EXTM3U\n#EXTINF:200,Art ist - One\n../Artist/01.flac\n#EXTINF:-1,Two\n../Other/02.flac\n",
        output.written(),
    );
    const parsed = try parse(allocator, output.written());
    defer parsed.deinit(allocator);
    const resolved = try resolve(allocator, "/m/lists", parsed.entries[0].location);
    defer allocator.free(resolved.path);
    try std.testing.expectEqualStrings("/m/Artist/01.flac", resolved.path);
}
