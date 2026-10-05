//! An Artist's Wikidata item: its image (P18) on Wikimedia Commons, its work
//! period (P2031, P2032) and the title of its Wikipedia article. Wikidata is
//! CC0.

const std = @import("std");
const cached_get = @import("cached_get.zig");
const url_encoding = @import("url.zig");

pub const service = "wikidata";
pub const minimum_interval_ms: u64 = 300;
pub const default_server = "https://www.wikidata.org";

/// What Orca reads from one item. Strings live in `arena`.
pub const Entity = struct {
    arena: std.heap.ArenaAllocator,
    /// The Commons file name of the item's image, without `File:`.
    image_file: ?[]const u8 = null,
    /// The title of the item's Wikipedia article in `article_language`.
    article_title: ?[]const u8 = null,
    article_language: ?[]const u8 = null,
    /// The year the item's work period starts (P2031), at year precision or
    /// finer.
    work_start_year: ?i32 = null,
    /// The year the item's work period ends (P2032).
    work_end_year: ?i32 = null,

    pub fn deinit(self: *Entity) void {
        self.arena.deinit();
    }
};

/// A Wikidata item ID: `Q` and up to 12 digits.
pub fn isItemId(value: []const u8) bool {
    if (value.len < 2 or value.len > 13 or value[0] != 'Q' or value[1] == '0') return false;
    for (value[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

/// A Wikipedia language code: lowercase letters, optionally with
/// hyphenated parts, as `en`, `de` or `zh-yue`.
pub fn isLanguage(value: []const u8) bool {
    if (value.len < 2 or value.len > 12 or value[0] == '-' or value[value.len - 1] == '-') return false;
    for (value) |byte| if (!(std.ascii.isLower(byte) or byte == '-')) return false;
    return true;
}

/// `GET {server}/w/api.php?action=wbgetentities&ids={item}&props=claims|sitelinks/urls&format=json`.
/// Null when Wikidata has no such item. The article is the `{language}wiki`
/// sitelink, else the `enwiki` one.
pub fn entity(
    client: *cached_get.CachedGet,
    allocator: std.mem.Allocator,
    server: []const u8,
    item_id: []const u8,
    language: []const u8,
) !?Entity {
    if (!isItemId(item_id)) return error.InvalidWikidataId;
    if (!isLanguage(language)) return error.InvalidLanguage;
    const request_url = try std.fmt.allocPrint(
        allocator,
        "{s}/w/api.php?action=wbgetentities&ids={s}&props=claims%7Csitelinks%2Furls&format=json",
        .{ std.mem.trimEnd(u8, server, "/"), item_id },
    );
    defer allocator.free(request_url);
    return client.get(Entity, allocator, request_url, EntityParser{ .item_id = item_id, .language = language });
}

const EntityParser = struct {
    item_id: []const u8,
    language: []const u8,

    pub fn parse(self: EntityParser, allocator: std.mem.Allocator, body: []const u8) !?Entity {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const root = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), body, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidProviderResponse,
        };
        if (root != .object) return error.InvalidProviderResponse;
        if (root.object.get("error")) |_| return null;
        const entities = objectField(root, "entities") orelse return error.InvalidProviderResponse;
        const item = entities.object.get(self.item_id) orelse return null;
        if (item != .object) return error.InvalidProviderResponse;
        if (item.object.get("missing")) |_| return null;

        var result: Entity = .{ .arena = .init(allocator) };
        errdefer result.deinit();
        const arena = result.arena.allocator();
        if (claimValue(item, "P18")) |value| if (value == .string and value.string.len != 0) {
            result.image_file = try arena.dupe(u8, value.string);
        };
        result.work_start_year = yearClaim(item, "P2031");
        result.work_end_year = yearClaim(item, "P2032");
        if (objectField(item, "sitelinks")) |sitelinks| {
            const wanted = try std.fmt.allocPrint(scratch.allocator(), "{s}wiki", .{self.language});
            const chosen: ?struct { []const u8, []const u8 } = if (sitelinkTitle(sitelinks, wanted)) |title|
                .{ title, self.language }
            else if (sitelinkTitle(sitelinks, "enwiki")) |title|
                .{ title, "en" }
            else
                null;
            if (chosen) |found| {
                result.article_title = try arena.dupe(u8, found[0]);
                result.article_language = try arena.dupe(u8, found[1]);
            }
        }
        return result;
    }
};

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

fn sitelinkTitle(sitelinks: std.json.Value, site: []const u8) ?[]const u8 {
    const link = sitelinks.object.get(site) orelse return null;
    const title = stringField(link, "title") orelse return null;
    return if (title.len == 0) null else title;
}

/// The value of the item's preferred statement of `property`, else of its
/// first normal one; deprecated statements and those without a value are
/// skipped.
fn claimValue(item: std.json.Value, property: []const u8) ?std.json.Value {
    const claims = objectField(item, "claims") orelse return null;
    const statements = claims.object.get(property) orelse return null;
    if (statements != .array) return null;
    var normal: ?std.json.Value = null;
    for (statements.array.items) |statement| {
        const rank = stringField(statement, "rank") orelse "normal";
        if (std.mem.eql(u8, rank, "deprecated")) continue;
        const snak = objectField(statement, "mainsnak") orelse continue;
        const datavalue = objectField(snak, "datavalue") orelse continue;
        const value = datavalue.object.get("value") orelse continue;
        if (std.mem.eql(u8, rank, "preferred")) return value;
        if (normal == null) normal = value;
    }
    return normal;
}

fn yearClaim(item: std.json.Value, property: []const u8) ?i32 {
    const value = claimValue(item, property) orelse return null;
    const time = stringField(value, "time") orelse return null;
    const precision = value.object.get("precision") orelse return null;
    if (precision != .integer or precision.integer < 9) return null;
    if (time.len < 2 or time[0] != '+') return null;
    const end = std.mem.indexOfScalarPos(u8, time, 1, '-') orelse return null;
    const year = std.fmt.parseInt(i32, time[1..end], 10) catch return null;
    return if (year > 0) year else null;
}

/// The item ID a `https://www.wikidata.org/wiki/Q…` URL names.
pub fn itemIdFromUrl(url: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = (uri.getHost(&host_buffer) catch return null).bytes;
    if (!std.ascii.eqlIgnoreCase(host, "www.wikidata.org") and !std.ascii.eqlIgnoreCase(host, "wikidata.org")) return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |text| text,
    };
    const prefix = "/wiki/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const id = path[prefix.len..];
    return if (isItemId(id)) id else null;
}

const testing = std.testing;
const database = @import("../database/root.zig");
const network = @import("../network/root.zig");

pub fn readFixture(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, "fixtures/providers/wikidata-entity.json", allocator, .limited(64 * 1024));
}

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

test "an item yields its image file and the article in the asked language, else in English" {
    var rig: Rig = undefined;
    try rig.init("file:orca-wikidata-entity?mode=memory&cache=shared");
    defer rig.deinit();
    const body = try readFixture(testing.allocator);
    defer testing.allocator.free(body);
    rig.net.transport.otherwise = .{ .respond = .{ .body = body } };

    var english = (try entity(&rig.client, testing.allocator, "http://127.0.0.1:9/", "Q27830860", "en")).?;
    defer english.deinit();
    try testing.expectEqualStrings(
        "http://127.0.0.1:9/w/api.php?action=wbgetentities&ids=Q27830860&props=claims%7Csitelinks%2Furls&format=json",
        rig.net.transport.lastUrl(),
    );
    try testing.expectEqualStrings("Amine at the SXSW Youtube Party 2017 (33556409746).jpg", english.image_file.?);
    try testing.expectEqualStrings("Aminé (rapper)", english.article_title.?);
    try testing.expectEqualStrings("en", english.article_language.?);
    try testing.expectEqual(@as(?i32, 2014), english.work_start_year);
    try testing.expectEqual(@as(?i32, null), english.work_end_year);

    var german = (try entity(&rig.client, testing.allocator, default_server, "Q27830860", "de")).?;
    defer german.deinit();
    try testing.expectEqualStrings("Aminé (Rapper)", german.article_title.?);
    try testing.expectEqualStrings("de", german.article_language.?);

    var french = (try entity(&rig.client, testing.allocator, default_server, "Q27830860", "fr")).?;
    defer french.deinit();
    try testing.expectEqualStrings("Aminé (rapper)", french.article_title.?);
    try testing.expectEqualStrings("en", french.article_language.?);
}

test "a missing item is null, and a malformed item ID or language is refused before any request" {
    var rig: Rig = undefined;
    try rig.init("file:orca-wikidata-missing?mode=memory&cache=shared");
    defer rig.deinit();
    rig.net.transport.otherwise = .{ .respond = .{ .body = "{\"entities\":{\"Q999\":{\"id\":\"Q999\",\"missing\":\"\"}}}" } };
    try testing.expectEqual(@as(?Entity, null), try entity(&rig.client, testing.allocator, default_server, "Q999", "en"));
    for ([_][]const u8{ "", "Q", "Q01", "P18", "Q1&x=y", "q42" }) |malformed|
        try testing.expectError(error.InvalidWikidataId, entity(&rig.client, testing.allocator, default_server, malformed, "en"));
    for ([_][]const u8{ "", "e", "EN", "en&x", "-en" }) |malformed|
        try testing.expectError(error.InvalidLanguage, entity(&rig.client, testing.allocator, default_server, "Q42", malformed));
    try testing.expectEqual(@as(u32, 1), rig.net.transport.requestCount());
}

test "a preferred image outranks a normal one, and a deprecated one is never chosen" {
    var rig: Rig = undefined;
    try rig.init("file:orca-wikidata-rank?mode=memory&cache=shared");
    defer rig.deinit();
    rig.net.transport.otherwise = .{ .respond = .{ .body =
        \\{"entities":{"Q1":{"claims":{"P18":[
        \\ {"rank":"deprecated","mainsnak":{"datavalue":{"value":"old.jpg"}}},
        \\ {"rank":"normal","mainsnak":{"datavalue":{"value":"normal.jpg"}}},
        \\ {"rank":"preferred","mainsnak":{"datavalue":{"value":"best.jpg"}}}]}}}}
    } };
    var item = (try entity(&rig.client, testing.allocator, default_server, "Q1", "en")).?;
    defer item.deinit();
    try testing.expectEqualStrings("best.jpg", item.image_file.?);
    try testing.expectEqual(@as(?[]const u8, null), item.article_title);
}

test "a work period is read at year precision or finer, and a coarser or unknown one is no year" {
    var rig: Rig = undefined;
    try rig.init("file:orca-wikidata-work-period?mode=memory&cache=shared");
    defer rig.deinit();
    rig.net.transport.otherwise = .{ .respond = .{ .body =
        \\{"entities":{"Q1":{"claims":{
        \\ "P2031":[{"rank":"normal","mainsnak":{"datavalue":{"value":{"time":"+1967-03-12T00:00:00Z","precision":11}}}}],
        \\ "P2032":[{"rank":"normal","mainsnak":{"datavalue":{"value":{"time":"+1990-00-00T00:00:00Z","precision":8}}}}]}},
        \\"Q2":{"claims":{
        \\ "P2031":[{"rank":"normal","mainsnak":{"snaktype":"somevalue"}}],
        \\ "P2032":[{"rank":"normal","mainsnak":{"datavalue":{"value":{"time":"+2003-00-00T00:00:00Z","precision":9}}}}]}}}}
    } };
    var first = (try entity(&rig.client, testing.allocator, default_server, "Q1", "en")).?;
    defer first.deinit();
    try testing.expectEqual(@as(?i32, 1967), first.work_start_year);
    try testing.expectEqual(@as(?i32, null), first.work_end_year);
    var second = (try entity(&rig.client, testing.allocator, default_server, "Q2", "en")).?;
    defer second.deinit();
    try testing.expectEqual(@as(?i32, null), second.work_start_year);
    try testing.expectEqual(@as(?i32, 2003), second.work_end_year);
}

test "an item ID is read only from a Wikidata URL" {
    try testing.expectEqualStrings("Q27830860", itemIdFromUrl("https://www.wikidata.org/wiki/Q27830860").?);
    for ([_][]const u8{
        "https://www.wikidata.org/wiki/Property:P18",
        "https://example.org/wiki/Q1",
        "https://www.wikidata.org/w/Q1",
        "not a url",
    }) |url| try testing.expectEqual(@as(?[]const u8, null), itemIdFromUrl(url));
}
