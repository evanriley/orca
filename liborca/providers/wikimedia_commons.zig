//! A file on Wikimedia Commons: its licence, its author's credit and an
//! 800-pixel-wide rendering. Each image carries its own licence, which is
//! shown with it.

const std = @import("std");
const metadata = @import("../metadata/model.zig");
const network = @import("../network/root.zig");
const cached_get = @import("cached_get.zig");
const url_encoding = @import("url.zig");

pub const service = "wikimedia-commons";
pub const default_server = "https://commons.wikimedia.org";
pub const max_image_bytes: usize = 4 * 1024 * 1024;
pub const thumbnail_width = 800;
/// Renderings are served from `upload.wikimedia.org`.
pub const image_allowance: network.client.RedirectAllowance = .{ .host = "wikimedia.org" };
const max_credit_bytes = 1024;

/// What Commons says about one file. Strings live in `arena`.
pub const ImageInfo = struct {
    arena: std.heap.ArenaAllocator,
    /// The rendering to fetch.
    thumbnail_url: []const u8,
    /// The file's page on Commons.
    description_url: ?[]const u8 = null,
    licence: ?[]const u8 = null,
    licence_url: ?[]const u8 = null,
    /// The author, as plain text.
    credit: ?[]const u8 = null,

    pub fn deinit(self: *ImageInfo) void {
        self.arena.deinit();
    }
};

/// A rendering's bytes, JPEG, PNG or WebP. The caller frees `bytes`.
pub const Image = struct {
    bytes: []u8,
    /// Borrowed from `metadata.sniffImageMimeType`'s static table.
    mime_type: []const u8,
};

/// `GET {server}/w/api.php?action=query&titles=File:{name}&prop=imageinfo&iiprop=url|extmetadata|mime&iiurlwidth=800&format=json`.
/// Null when Commons has no such file.
pub fn imageInfo(
    client: *cached_get.CachedGet,
    allocator: std.mem.Allocator,
    server: []const u8,
    file_name: []const u8,
) !?ImageInfo {
    if (file_name.len == 0 or file_name.len > 512) return error.InvalidCommonsFile;
    var request_url = std.Io.Writer.Allocating.init(allocator);
    defer request_url.deinit();
    try request_url.writer.print("{s}/w/api.php?action=query&titles=", .{std.mem.trimEnd(u8, server, "/")});
    try url_encoding.writeEncoded(&request_url.writer, "File:");
    try url_encoding.writeEncoded(&request_url.writer, file_name);
    try request_url.writer.print(
        "&prop=imageinfo&iiprop=url%7Cextmetadata%7Cmime&iiurlwidth={d}&format=json",
        .{thumbnail_width},
    );
    return client.get(ImageInfo, allocator, request_url.written(), ImageInfoParser{});
}

/// The rendering `info` names, fetched on `gateway` when it is on
/// `wikimedia.org` over https, or on the loopback origin `api_url` was asked
/// on. Anything else is `error.RedirectRefused` without a request.
pub fn fetchImage(
    gateway: *network.Gateway,
    allocator: std.mem.Allocator,
    api_server: []const u8,
    thumbnail_url: []const u8,
) !Image {
    const target = try network.client.redirectTarget(allocator, api_server, thumbnail_url, image_allowance);
    defer allocator.free(target);
    const response = try gateway.fetch(allocator, target, &.{}, image_allowance);
    defer response.deinit();
    if (response.status == 408 or response.status >= 500) return error.ProviderUnavailable;
    if (response.status != 200) return error.ProviderRejectedRequest;
    const mime_type = imageMimeType(response.body) orelse return error.InvalidProviderResponse;
    return .{ .bytes = try allocator.dupe(u8, response.body), .mime_type = mime_type };
}

fn imageMimeType(bytes: []const u8) ?[]const u8 {
    const sniffed = metadata.sniffImageMimeType(bytes) orelse return null;
    for ([_][]const u8{ "image/jpeg", "image/png", "image/webp" }) |allowed|
        if (std.mem.eql(u8, sniffed, allowed)) return sniffed;
    return null;
}

const ImageInfoParser = struct {
    pub fn parse(_: ImageInfoParser, allocator: std.mem.Allocator, body: []const u8) !?ImageInfo {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const root = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), body, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidProviderResponse,
        };
        const query = objectField(root, "query") orelse return error.InvalidProviderResponse;
        const pages = objectField(query, "pages") orelse return error.InvalidProviderResponse;
        var iterator = pages.object.iterator();
        const page = (iterator.next() orelse return null).value_ptr.*;
        if (page != .object) return error.InvalidProviderResponse;
        if (page.object.get("missing")) |_| return null;
        const infos = page.object.get("imageinfo") orelse return null;
        if (infos != .array or infos.array.items.len == 0) return null;
        const info = infos.array.items[0];
        const thumbnail = stringField(info, "thumburl") orelse stringField(info, "url") orelse
            return error.InvalidProviderResponse;

        var result: ImageInfo = .{ .arena = .init(allocator), .thumbnail_url = "" };
        errdefer result.deinit();
        const arena = result.arena.allocator();
        result.thumbnail_url = try arena.dupe(u8, thumbnail);
        if (stringField(info, "descriptionurl")) |value| result.description_url = try arena.dupe(u8, value);
        if (objectField(info, "extmetadata")) |extmetadata| {
            result.licence = try plainField(arena, extmetadata, "LicenseShortName");
            result.licence_url = try plainField(arena, extmetadata, "LicenseUrl");
            result.credit = try plainField(arena, extmetadata, "Artist");
        }
        return result;
    }
};

fn plainField(arena: std.mem.Allocator, extmetadata: std.json.Value, name: []const u8) !?[]const u8 {
    const field = objectField(extmetadata, name) orelse return null;
    const value = stringField(field, "value") orelse return null;
    const plain = try plainText(arena, value);
    return if (plain.len == 0) null else plain;
}

fn objectField(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .object) field else null;
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}

/// `html` without its tags, its common entities decoded and its whitespace
/// collapsed, at most `max_credit_bytes` long.
pub fn plainText(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_space = false;
    var index: usize = 0;
    while (index < html.len and out.items.len < max_credit_bytes) {
        const byte = html[index];
        if (byte == '<') {
            const close = std.mem.indexOfScalarPos(u8, html, index, '>') orelse break;
            if (isBreakingTag(html[index + 1 .. close])) pending_space = true;
            index = close + 1;
            continue;
        }
        var decoded: [4]u8 = undefined;
        var piece: []const u8 = html[index .. index + 1];
        var advance: usize = 1;
        if (byte == '&') if (decodeEntity(html[index..], &decoded)) |entity| {
            piece = decoded[0..entity.len];
            advance = entity.consumed;
        };
        index += advance;
        if (piece.len == 1 and std.ascii.isWhitespace(piece[0])) {
            pending_space = true;
            continue;
        }
        if (pending_space and out.items.len != 0) try out.append(allocator, ' ');
        pending_space = false;
        try out.appendSlice(allocator, piece);
    }
    while (!std.unicode.utf8ValidateSlice(out.items)) _ = out.pop();
    return out.toOwnedSlice(allocator);
}

fn isBreakingTag(tag: []const u8) bool {
    const name_start: usize = if (std.mem.startsWith(u8, tag, "/")) 1 else 0;
    var name_end = name_start;
    while (name_end < tag.len and std.ascii.isAlphanumeric(tag[name_end])) name_end += 1;
    const name = tag[name_start..name_end];
    for ([_][]const u8{ "br", "p", "div", "li", "td", "tr" }) |breaking|
        if (std.ascii.eqlIgnoreCase(name, breaking)) return true;
    return false;
}

const Entity = struct { len: usize, consumed: usize };

fn decodeEntity(text: []const u8, buffer: *[4]u8) ?Entity {
    const end = std.mem.indexOfScalar(u8, text[0..@min(text.len, 12)], ';') orelse return null;
    const name = text[1..end];
    const named = [_]struct { []const u8, []const u8 }{
        .{ "amp", "&" },  .{ "lt", "<" },  .{ "gt", ">" },   .{ "quot", "\"" },
        .{ "apos", "'" }, .{ "#39", "'" }, .{ "nbsp", " " },
    };
    for (named) |entry| if (std.mem.eql(u8, name, entry[0])) {
        @memcpy(buffer[0..entry[1].len], entry[1]);
        return .{ .len = entry[1].len, .consumed = end + 1 };
    };
    if (name.len < 2 or name[0] != '#') return null;
    const code = if (name[1] == 'x' or name[1] == 'X')
        std.fmt.parseInt(u21, name[2..], 16) catch return null
    else
        std.fmt.parseInt(u21, name[1..], 10) catch return null;
    const len = std.unicode.utf8Encode(code, buffer) catch return null;
    return .{ .len = len, .consumed = end + 1 };
}

const testing = std.testing;
const database = @import("../database/root.zig");

const Rig = struct {
    library: database.LibraryDatabase,
    net: network.testing.TestGateway,
    client: cached_get.CachedGet,

    fn init(self: *Rig, uri: [:0]const u8) !void {
        self.library = try database.LibraryDatabase.open(testing.allocator, testing.io, uri);
        self.net.init(.{ .now_ms = 1_800_000_000_000, .config = .{
            .identity = network.testing.test_identity,
            .max_response_bytes = max_image_bytes,
            .minimum_interval_ms = 0,
        } });
        self.client = .{
            .gateway = &self.net.gateway,
            .cache = &self.library.provider_cache,
            .wall_clock = self.net.clock.wallClock(),
            .service = service,
        };
    }

    fn deinit(self: *Rig) void {
        self.net.deinit();
        self.library.close();
    }
};

const sample_file = "Amine at the SXSW Youtube Party 2017 (33556409746).jpg";

test "a file's licence, licence URL, page and credit are read, the credit as plain text" {
    var rig: Rig = undefined;
    try rig.init("file:orca-commons-info?mode=memory&cache=shared");
    defer rig.deinit();
    const body = try std.Io.Dir.cwd().readFileAlloc(testing.io, "fixtures/providers/wikimedia-commons-imageinfo.json", testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(body);
    rig.net.transport.otherwise = .{ .respond = .{ .body = body } };

    var info = (try imageInfo(&rig.client, testing.allocator, default_server, sample_file)).?;
    defer info.deinit();
    try testing.expectEqualStrings(
        "https://commons.wikimedia.org/w/api.php?action=query&titles=File%3AAmine%20at%20the%20SXSW%20Youtube%20Party%202017%20%2833556409746%29.jpg&prop=imageinfo&iiprop=url%7Cextmetadata%7Cmime&iiurlwidth=800&format=json",
        rig.net.transport.lastUrl(),
    );
    try testing.expectEqualStrings("CC BY 2.0", info.licence.?);
    try testing.expectEqualStrings("https://creativecommons.org/licenses/by/2.0", info.licence_url.?);
    try testing.expectEqualStrings("Example Photographer & friends", info.credit.?);
    try testing.expect(std.mem.startsWith(u8, info.thumbnail_url, "https://upload.wikimedia.org/wikipedia/commons/thumb/"));
    try testing.expect(std.mem.startsWith(u8, info.description_url.?, "https://commons.wikimedia.org/wiki/File:"));
}

test "a missing file is null" {
    var rig: Rig = undefined;
    try rig.init("file:orca-commons-missing?mode=memory&cache=shared");
    defer rig.deinit();
    rig.net.transport.otherwise = .{ .respond = .{ .body =
        \\{"query":{"pages":{"-1":{"ns":6,"title":"File:Nothing.jpg","missing":"","imagerepository":""}}}}
    } };
    try testing.expectEqual(@as(?ImageInfo, null), try imageInfo(&rig.client, testing.allocator, default_server, "Nothing.jpg"));
}

test "HTML is stripped from a credit, its entities decoded and its whitespace collapsed" {
    for ([_][2][]const u8{
        .{ "<a href=\"x\">Jane</a> &amp; <b>John</b>", "Jane & John" },
        .{ "  <span>Café&#233;</span>\n<br/>  by&nbsp;me ", "Caféé by me" },
        .{ "a &unknown; b &#x263A;", "a &unknown; b \u{263A}" },
        .{ "<div><p></p></div>", "" },
        .{ "<b>Jane</b>son<br>Smith", "Janeson Smith" },
        .{ "unclosed <a href", "unclosed" },
    }) |case| {
        const plain = try plainText(testing.allocator, case[0]);
        defer testing.allocator.free(plain);
        try testing.expectEqualStrings(case[1], plain);
    }
}

test "a rendering on wikimedia.org is fetched and typed by its bytes, and one elsewhere is refused without a request" {
    var rig: Rig = undefined;
    try rig.init("file:orca-commons-image?mode=memory&cache=shared");
    defer rig.deinit();
    rig.net.transport.otherwise = .{ .respond = .{ .body = "\xff\xd8\xff\xe0JFIF" } };
    const image = try fetchImage(&rig.net.gateway, testing.allocator, default_server, "https://upload.wikimedia.org/a.jpg");
    defer testing.allocator.free(image.bytes);
    try testing.expectEqualStrings("image/jpeg", image.mime_type);
    for ([_][]const u8{ "https://example.org/a.jpg", "http://upload.wikimedia.org/a.jpg", "https://wikimedia.org.example.org/a.jpg" }) |elsewhere|
        try testing.expectError(error.RedirectRefused, fetchImage(&rig.net.gateway, testing.allocator, default_server, elsewhere));
    try testing.expectEqual(@as(u32, 1), rig.net.transport.requestCount());

    const local = try fetchImage(&rig.net.gateway, testing.allocator, "http://127.0.0.1:9", "http://127.0.0.1:9/thumb.jpg");
    defer testing.allocator.free(local.bytes);
    rig.net.transport.otherwise = .{ .respond = .{ .body = "GIF89a" } };
    try testing.expectError(error.InvalidProviderResponse, fetchImage(&rig.net.gateway, testing.allocator, default_server, "https://upload.wikimedia.org/a.gif"));
}
