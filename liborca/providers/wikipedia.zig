//! The lead of a Wikipedia article as plain text, from the REST summary.
//! The text is CC BY-SA 4.0 and is shown with a link to the article.

const std = @import("std");
const cached_get = @import("cached_get.zig");
const url_encoding = @import("url.zig");
const wikidata = @import("wikidata.zig");

pub const service = "wikipedia";
pub const minimum_interval_ms: u64 = 300;
pub const licence = "CC BY-SA 4.0";
const max_extract_bytes = 16 * 1024;

/// One article's summary. Strings live in `arena`.
pub const Summary = struct {
    arena: std.heap.ArenaAllocator,
    extract: []const u8,
    /// The article's page.
    page_url: ?[]const u8 = null,

    pub fn deinit(self: *Summary) void {
        self.arena.deinit();
    }
};

/// `GET {server}/api/rest_v1/page/summary/{title}`, where a null `server`
/// is `https://{language}.wikipedia.org`. Null when there is no such
/// article, or it is a disambiguation page or has no text.
pub fn summary(
    client: *cached_get.CachedGet,
    allocator: std.mem.Allocator,
    server: ?[]const u8,
    language: []const u8,
    title: []const u8,
) !?Summary {
    if (!wikidata.isLanguage(language)) return error.InvalidLanguage;
    if (title.len == 0 or title.len > 512) return error.InvalidArticleTitle;
    var request_url = std.Io.Writer.Allocating.init(allocator);
    defer request_url.deinit();
    if (server) |base|
        try request_url.writer.writeAll(std.mem.trimEnd(u8, base, "/"))
    else
        try request_url.writer.print("https://{s}.wikipedia.org", .{language});
    try request_url.writer.writeAll("/api/rest_v1/page/summary/");
    for (title) |byte| {
        if (byte == ' ')
            try request_url.writer.writeByte('_')
        else
            try url_encoding.writeEncoded(&request_url.writer, &.{byte});
    }
    return client.get(Summary, allocator, request_url.written(), SummaryParser{});
}

pub const ArticleRef = struct {
    language: []const u8,
    title: []const u8,
};

/// The language and title of a `https://{language}.wikipedia.org/wiki/{title}`
/// URL, the title percent-decoded with underscores as spaces. Null for any
/// other URL.
pub fn articleFromUrl(allocator: std.mem.Allocator, page_url: []const u8) !?ArticleRef {
    const prefix = "https://";
    if (!std.mem.startsWith(u8, page_url, prefix)) return null;
    const rest = page_url[prefix.len..];
    const host_end = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const host = rest[0..host_end];
    const suffix = ".wikipedia.org";
    if (!std.ascii.endsWithIgnoreCase(host, suffix)) return null;
    const language = host[0 .. host.len - suffix.len];
    if (!wikidata.isLanguage(language)) return null;
    const path = rest[host_end..];
    const wiki = "/wiki/";
    if (!std.mem.startsWith(u8, path, wiki)) return null;
    const encoded = path[wiki.len..];
    const end = std.mem.indexOfAny(u8, encoded, "?#") orelse encoded.len;
    var title: std.ArrayList(u8) = .empty;
    errdefer title.deinit(allocator);
    var index: usize = 0;
    while (index < end) : (index += 1) {
        const byte = encoded[index];
        if (byte == '%') {
            const value = if (index + 2 < end) std.fmt.parseInt(u8, encoded[index + 1 .. index + 3], 16) catch null else null;
            if (value == null) {
                title.deinit(allocator);
                return null;
            }
            try title.append(allocator, value.?);
            index += 2;
        } else try title.append(allocator, if (byte == '_') ' ' else byte);
    }
    if (title.items.len == 0 or title.items.len > 512 or !std.unicode.utf8ValidateSlice(title.items)) {
        title.deinit(allocator);
        return null;
    }
    return .{ .language = language, .title = try title.toOwnedSlice(allocator) };
}

const SummaryBody = struct {
    type: []const u8 = "standard",
    extract: []const u8 = "",
    content_urls: ?struct {
        desktop: ?struct { page: ?[]const u8 = null } = null,
    } = null,
};

const SummaryParser = struct {
    pub fn parse(_: SummaryParser, allocator: std.mem.Allocator, body: []const u8) !?Summary {
        var result: Summary = .{ .arena = .init(allocator), .extract = "" };
        errdefer result.deinit();
        const arena = result.arena.allocator();
        const parsed = std.json.parseFromSliceLeaky(SummaryBody, arena, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidProviderResponse,
        };
        const extract = std.mem.trim(u8, parsed.extract, " \t\r\n");
        if (std.mem.eql(u8, parsed.type, "disambiguation") or extract.len == 0) {
            result.deinit();
            return null;
        }
        result.extract = truncate(extract, max_extract_bytes);
        if (parsed.content_urls) |urls| if (urls.desktop) |desktop| {
            result.page_url = desktop.page;
        };
        return result;
    }
};

fn truncate(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
    return text[0..end];
}

const testing = std.testing;
const database = @import("../database/root.zig");
const network = @import("../network/root.zig");

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
        };
    }

    fn deinit(self: *Rig) void {
        self.net.deinit();
        self.library.close();
    }
};

test "a summary is asked of the language's wiki by title and yields its text and page" {
    var rig: Rig = undefined;
    try rig.init("file:orca-wikipedia-summary?mode=memory&cache=shared");
    defer rig.deinit();
    const body = try std.Io.Dir.cwd().readFileAlloc(testing.io, "fixtures/providers/wikipedia-summary.json", testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(body);
    rig.net.transport.otherwise = .{ .respond = .{ .body = body } };

    var english = (try summary(&rig.client, testing.allocator, null, "en", "Aminé (rapper)")).?;
    defer english.deinit();
    try testing.expectEqualStrings("https://en.wikipedia.org/api/rest_v1/page/summary/Amin%C3%A9_%28rapper%29", rig.net.transport.lastUrl());
    try testing.expect(std.mem.startsWith(u8, english.extract, "Adam Aminé Daniel"));
    try testing.expectEqualStrings("https://en.wikipedia.org/wiki/Amin%C3%A9_(rapper)", english.page_url.?);

    var local = (try summary(&rig.client, testing.allocator, "http://127.0.0.1:9/", "de", "A/B")).?;
    defer local.deinit();
    try testing.expectEqualStrings("http://127.0.0.1:9/api/rest_v1/page/summary/A%2FB", rig.net.transport.lastUrl());
}

test "a disambiguation page, an empty extract and a missing article are null" {
    var rig: Rig = undefined;
    try rig.init("file:orca-wikipedia-missing?mode=memory&cache=shared");
    defer rig.deinit();
    rig.net.transport.otherwise = .{ .respond = .{ .body = "{\"type\":\"disambiguation\",\"extract\":\"Aminé may refer to:\"}" } };
    try testing.expectEqual(@as(?Summary, null), try summary(&rig.client, testing.allocator, null, "en", "One"));
    rig.net.transport.otherwise = .{ .respond = .{ .body = "{\"type\":\"standard\",\"extract\":\"  \"}" } };
    try testing.expectEqual(@as(?Summary, null), try summary(&rig.client, testing.allocator, null, "en", "Two"));
    rig.net.transport.otherwise = .{ .respond = .{ .status = 404, .body = "{}" } };
    try testing.expectEqual(@as(?Summary, null), try summary(&rig.client, testing.allocator, null, "en", "Three"));
    try testing.expectError(error.InvalidLanguage, summary(&rig.client, testing.allocator, null, "en.evil.org/x", "Four"));
    try testing.expectEqual(@as(u32, 3), rig.net.transport.requestCount());
}

test "an article URL yields its language and decoded title and any other URL none" {
    const article = (try articleFromUrl(testing.allocator, "https://en.wikipedia.org/wiki/Hot_Space_%28album%29")).?;
    defer testing.allocator.free(article.title);
    try testing.expectEqualStrings("en", article.language);
    try testing.expectEqualStrings("Hot Space (album)", article.title);
    try testing.expectEqual(@as(?ArticleRef, null), try articleFromUrl(testing.allocator, "http://en.wikipedia.org/wiki/X"));
    try testing.expectEqual(@as(?ArticleRef, null), try articleFromUrl(testing.allocator, "https://en.wikipedia.org.evil.com/wiki/X"));
    try testing.expectEqual(@as(?ArticleRef, null), try articleFromUrl(testing.allocator, "https://en.wikipedia.org/w/index.php"));
    try testing.expectEqual(@as(?ArticleRef, null), try articleFromUrl(testing.allocator, "https://en.wikipedia.org/wiki/%ZZ"));
    try testing.expectEqual(@as(?ArticleRef, null), try articleFromUrl(testing.allocator, "https://en.wikipedia.org/wiki/"));
}
