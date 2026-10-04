const std = @import("std");
const metadata = @import("../metadata/model.zig");
const network = @import("../network/root.zig");

pub const service = "coverartarchive";
pub const default_server = "https://coverartarchive.org";
pub const max_image_bytes: usize = 4 * 1024 * 1024;
/// The front cover is served from the Internet Archive, through up to two
/// redirects.
pub const redirect_allowance: network.client.RedirectAllowance = .{ .host = "archive.org" };

/// A front cover's bytes, JPEG or PNG. The caller frees `bytes`.
pub const Image = struct {
    bytes: []u8,
    /// Borrowed from `metadata.sniffImageMimeType`'s static table.
    mime_type: []const u8,
};

pub const FrontCover = union(enum) {
    image: Image,
    /// The archive has no front cover for the release.
    missing,
};

/// An index's body is refused past this many bytes.
pub const max_index_bytes: usize = 1024 * 1024;

/// An index's images past this many are ignored.
pub const max_indexed_images = 64;

/// What an indexed image is to the release it belongs to.
pub const ImageKind = enum { front, back, booklet, other };

pub const IndexedImage = struct {
    /// The archive's image ID.
    id: i64,
    kind: ImageKind,
    /// Whether the archive's editors approved the image.
    approved: bool,
};

/// The images the archive holds for a release, or for the release it picks
/// for a release group. The caller frees it with `deinit`.
pub const Index = struct {
    /// The release the images belong to, from the index's `release` link,
    /// lowercase.
    release_mbid: [36]u8,
    images: []IndexedImage,

    pub fn deinit(self: Index, allocator: std.mem.Allocator) void {
        allocator.free(self.images);
    }
};

pub const CoverArtArchive = struct {
    gateway: *network.Gateway,
    server: []const u8 = default_server,
    requests_answered: u64 = 0,

    /// `GET {server}/release/{mbid}/front-500`. A 404 is `.missing`; any
    /// other refusal, or a body that is not a JPEG or PNG, is an error.
    pub fn frontCover(self: *CoverArtArchive, allocator: std.mem.Allocator, release_mbid: []const u8) !FrontCover {
        return self.front(allocator, "release", release_mbid, "front-500");
    }

    /// `GET {server}/release-group/{mbid}/front-250`: the front cover of the
    /// release the archive picks for the group, answered as `frontCover` is.
    pub fn releaseGroupFrontCover(self: *CoverArtArchive, allocator: std.mem.Allocator, group_mbid: []const u8) !FrontCover {
        return self.front(allocator, "release-group", group_mbid, "front-250");
    }

    /// `GET {server}/release/{mbid}/`: every image the archive holds for the
    /// release. Null when it holds none.
    pub fn releaseIndex(self: *CoverArtArchive, allocator: std.mem.Allocator, release_mbid: []const u8) !?Index {
        return self.index(allocator, "release", release_mbid);
    }

    /// `GET {server}/release-group/{mbid}/`: the images of the release the
    /// archive picks for the group. Null when it holds none.
    pub fn releaseGroupIndex(self: *CoverArtArchive, allocator: std.mem.Allocator, group_mbid: []const u8) !?Index {
        return self.index(allocator, "release-group", group_mbid);
    }

    /// `GET {server}/release/{mbid}/{id}-250`: an indexed image's 250-pixel
    /// thumbnail, answered as `frontCover` is.
    pub fn thumbnail(self: *CoverArtArchive, allocator: std.mem.Allocator, release_mbid: []const u8, image_id: i64) !FrontCover {
        if (image_id <= 0) return error.InvalidProviderResponse;
        var size: [32]u8 = undefined;
        return self.front(allocator, "release", release_mbid, std.fmt.bufPrint(&size, "{d}-250", .{image_id}) catch unreachable);
    }

    /// `GET {server}/release/{mbid}/{id}`: an indexed image as it was
    /// uploaded, answered as `frontCover` is.
    pub fn image(self: *CoverArtArchive, allocator: std.mem.Allocator, release_mbid: []const u8, image_id: i64) !FrontCover {
        if (image_id <= 0) return error.InvalidProviderResponse;
        var size: [32]u8 = undefined;
        return self.front(allocator, "release", release_mbid, std.fmt.bufPrint(&size, "{d}", .{image_id}) catch unreachable);
    }

    fn index(self: *CoverArtArchive, allocator: std.mem.Allocator, entity: []const u8, mbid: []const u8) !?Index {
        if (!metadata.isMusicBrainzId(mbid)) return error.InvalidMusicBrainzId;
        const url = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/", .{ std.mem.trimEnd(u8, self.server, "/"), entity, mbid });
        defer allocator.free(url);
        const response = try self.gateway.fetch(allocator, url, &.{}, redirect_allowance);
        defer response.deinit();
        self.requests_answered += 1;
        if (response.status == 404) return null;
        if (response.status == 408 or response.status >= 500) return error.ProviderUnavailable;
        if (response.status != 200) return error.ProviderRejectedRequest;
        if (response.body.len > max_index_bytes) return error.ResponseTooLarge;
        return try parseIndex(allocator, response.body, if (std.mem.eql(u8, entity, "release")) mbid else null);
    }

    fn front(self: *CoverArtArchive, allocator: std.mem.Allocator, entity: []const u8, mbid: []const u8, size: []const u8) !FrontCover {
        if (!metadata.isMusicBrainzId(mbid)) return error.InvalidMusicBrainzId;
        const url = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/{s}", .{
            std.mem.trimEnd(u8, self.server, "/"),
            entity,
            mbid,
            size,
        });
        defer allocator.free(url);
        const response = try self.gateway.fetch(allocator, url, &.{}, redirect_allowance);
        defer response.deinit();
        self.requests_answered += 1;
        if (response.status == 404) return .missing;
        if (response.status == 408 or response.status >= 500) return error.ProviderUnavailable;
        if (response.status != 200) return error.ProviderRejectedRequest;
        const mime_type = imageMimeType(response.body) orelse return error.InvalidProviderResponse;
        return .{ .image = .{ .bytes = try allocator.dupe(u8, response.body), .mime_type = mime_type } };
    }
};

/// Reads an index body. `release_mbid` is the release asked for, which an
/// index without a `release` link is taken to describe; a release group's
/// index must name its release.
fn parseIndex(allocator: std.mem.Allocator, body: []const u8, release_mbid: ?[]const u8) !Index {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidProviderResponse,
    };
    if (root != .object) return error.InvalidProviderResponse;
    var result: Index = .{ .release_mbid = undefined, .images = &.{} };
    if (root.object.get("release")) |link| {
        if (link != .string) return error.InvalidProviderResponse;
        result.release_mbid = releaseOfLink(link.string) orelse return error.InvalidProviderResponse;
    } else {
        const asked = release_mbid orelse return error.InvalidProviderResponse;
        result.release_mbid = asked[0..36].*;
    }
    const listed = root.object.get("images") orelse return error.InvalidProviderResponse;
    if (listed != .array) return error.InvalidProviderResponse;
    var images: std.ArrayList(IndexedImage) = .empty;
    errdefer images.deinit(allocator);
    for (listed.array.items) |entry| {
        if (images.items.len == max_indexed_images) break;
        if (entry != .object) continue;
        const id = imageId(entry.object.get("id") orelse continue) orelse continue;
        try images.append(allocator, .{
            .id = id,
            .kind = imageKind(entry),
            .approved = boolField(entry, "approved"),
        });
    }
    result.images = try images.toOwnedSlice(allocator);
    return result;
}

/// The release ID at the end of a `https://musicbrainz.org/release/{mbid}`
/// link.
fn releaseOfLink(link: []const u8) ?[36]u8 {
    const trimmed = std.mem.trimEnd(u8, link, "/");
    const marker = "/release/";
    const at = std.mem.lastIndexOf(u8, trimmed, marker) orelse return null;
    const mbid = trimmed[at + marker.len ..];
    if (!metadata.isMusicBrainzId(mbid)) return null;
    return mbid[0..36].*;
}

/// The archive writes an image's ID as a number, and in older indexes as a
/// string of digits.
fn imageId(value: std.json.Value) ?i64 {
    const id: i64 = switch (value) {
        .integer => |number| number,
        .string => |text| std.fmt.parseInt(i64, text, 10) catch return null,
        else => return null,
    };
    return if (id > 0) id else null;
}

fn imageKind(entry: std.json.Value) ImageKind {
    if (boolField(entry, "front") or hasType(entry, "Front")) return .front;
    if (boolField(entry, "back") or hasType(entry, "Back")) return .back;
    if (hasType(entry, "Booklet")) return .booklet;
    return .other;
}

fn boolField(entry: std.json.Value, name: []const u8) bool {
    const field = entry.object.get(name) orelse return false;
    return field == .bool and field.bool;
}

fn hasType(entry: std.json.Value, name: []const u8) bool {
    const types = entry.object.get("types") orelse return false;
    if (types != .array) return false;
    for (types.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, name)) return true;
    }
    return false;
}

fn imageMimeType(bytes: []const u8) ?[]const u8 {
    const sniffed = metadata.sniffImageMimeType(bytes) orelse return null;
    if (std.mem.eql(u8, sniffed, "image/jpeg") or std.mem.eql(u8, sniffed, "image/png")) return sniffed;
    return null;
}

const testing = std.testing;
const test_release_mbid = "2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b";
const jpeg = "\xff\xd8\xff\xe0JFIF";

fn testGateway(net: *network.testing.TestGateway) void {
    net.init(.{ .config = .{ .identity = network.testing.test_identity, .max_response_bytes = max_image_bytes } });
}

test "the front cover is fetched through the redirects to archive.org and typed by its bytes" {
    var net: network.testing.TestGateway = undefined;
    testGateway(&net);
    defer net.deinit();
    net.transport.keep_history = true;
    try net.transport.script(.{ .respond = .{ .status = 307, .body = "", .location = "https://archive.org/download/f/front.jpg" } });
    try net.transport.script(.{ .respond = .{ .status = 302, .body = "", .location = "https://ia600.us.archive.org/f/front.jpg" } });
    try net.transport.script(.{ .respond = .{ .body = jpeg } });
    var archive: CoverArtArchive = .{ .gateway = &net.gateway };
    const cover = try archive.frontCover(testing.allocator, test_release_mbid);
    defer testing.allocator.free(cover.image.bytes);
    try testing.expectEqualStrings("image/jpeg", cover.image.mime_type);
    try testing.expectEqualStrings(jpeg, cover.image.bytes);
    try testing.expectEqualStrings("https://coverartarchive.org/release/" ++ test_release_mbid ++ "/front-500", net.transport.history.items[0].url);
}

test "a release without a front cover is missing, and a malformed release id is refused before any request" {
    var net: network.testing.TestGateway = undefined;
    testGateway(&net);
    defer net.deinit();
    try net.transport.script(.{ .respond = .{ .status = 404, .body = "" } });
    var archive: CoverArtArchive = .{ .gateway = &net.gateway };
    try testing.expectEqual(FrontCover.missing, try archive.frontCover(testing.allocator, test_release_mbid));
    for ([_][]const u8{ "", "../../admin", "2E3F4A5B-6C7D-4E8F-9A0B-1C2D3E4F5A6B", test_release_mbid ++ "/x" }) |malformed|
        try testing.expectError(error.InvalidMusicBrainzId, archive.frontCover(testing.allocator, malformed));
    try testing.expectEqual(@as(u32, 1), net.transport.requestCount());
}

test "a body that is not a JPEG or PNG, or one over 4 MiB, is rejected" {
    var net: network.testing.TestGateway = undefined;
    testGateway(&net);
    defer net.deinit();
    var archive: CoverArtArchive = .{ .gateway = &net.gateway };
    for ([_][]const u8{ "<html>not found</html>", "GIF89a....", "" }) |body| {
        try net.transport.script(.{ .respond = .{ .body = body } });
        try testing.expectError(error.InvalidProviderResponse, archive.frontCover(testing.allocator, test_release_mbid));
    }
    try net.transport.script(.{ .fail = error.ResponseTooLarge });
    try testing.expectError(error.ResponseTooLarge, archive.frontCover(testing.allocator, test_release_mbid));
    try testing.expectEqual(@as(usize, max_image_bytes), net.gateway.config.max_response_bytes);
}

test "a redirect off the archive is refused and its target never requested" {
    var net: network.testing.TestGateway = undefined;
    testGateway(&net);
    defer net.deinit();
    try net.transport.script(.{ .respond = .{ .status = 302, .body = "", .location = "http://archive.org/front.jpg" } });
    var archive: CoverArtArchive = .{ .gateway = &net.gateway };
    try testing.expectError(error.RedirectRefused, archive.frontCover(testing.allocator, test_release_mbid));
    try testing.expectEqual(@as(u32, 1), net.transport.requestCount());
}

test "a release group's front cover is asked for at 250 pixels, and a group without one is missing" {
    var net: network.testing.TestGateway = undefined;
    testGateway(&net);
    defer net.deinit();
    net.transport.keep_history = true;
    try net.transport.script(.{ .respond = .{ .body = jpeg } });
    try net.transport.script(.{ .respond = .{ .status = 404, .body = "" } });
    var archive: CoverArtArchive = .{ .gateway = &net.gateway };
    const cover = try archive.releaseGroupFrontCover(testing.allocator, test_release_mbid);
    defer testing.allocator.free(cover.image.bytes);
    try testing.expectEqualStrings("image/jpeg", cover.image.mime_type);
    try testing.expectEqualStrings("https://coverartarchive.org/release-group/" ++ test_release_mbid ++ "/front-250", net.transport.history.items[0].url);
    try testing.expectEqual(FrontCover.missing, try archive.releaseGroupFrontCover(testing.allocator, test_release_mbid));
    try testing.expectError(error.InvalidMusicBrainzId, archive.releaseGroupFrontCover(testing.allocator, "../x"));
}

const test_group_mbid = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d";
const test_index =
    \\{"images": [
    \\  {"id": 101, "types": ["Front"], "front": true, "back": false, "approved": true},
    \\  {"id": "102", "types": ["Back"], "front": false, "back": true, "approved": false},
    \\  {"id": 103, "types": ["Booklet", "Liner"], "approved": true},
    \\  {"id": 104, "types": ["Medium"]},
    \\  {"id": "x", "types": ["Front"]},
    \\  {"types": ["Front"]}
    \\], "release": "https://musicbrainz.org/release/2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b"}
;

test "a release's index lists each image's ID, kind and approval, and skips images without a usable ID" {
    var net: network.testing.TestGateway = undefined;
    testGateway(&net);
    defer net.deinit();
    net.transport.keep_history = true;
    try net.transport.script(.{ .respond = .{ .body = test_index } });
    try net.transport.script(.{ .respond = .{ .status = 404, .body = "" } });
    var archive: CoverArtArchive = .{ .gateway = &net.gateway };
    const listed = (try archive.releaseIndex(testing.allocator, test_release_mbid)).?;
    defer listed.deinit(testing.allocator);
    try testing.expectEqualStrings(test_release_mbid, &listed.release_mbid);
    try testing.expectEqualSlices(IndexedImage, &.{
        .{ .id = 101, .kind = .front, .approved = true },
        .{ .id = 102, .kind = .back, .approved = false },
        .{ .id = 103, .kind = .booklet, .approved = true },
        .{ .id = 104, .kind = .other, .approved = false },
    }, listed.images);
    try testing.expectEqualStrings("https://coverartarchive.org/release/" ++ test_release_mbid ++ "/", net.transport.history.items[0].url);
    try testing.expectEqual(@as(?Index, null), try archive.releaseIndex(testing.allocator, test_release_mbid));
}

test "a release group's index names the release its images belong to, and one that does not is refused" {
    var net: network.testing.TestGateway = undefined;
    testGateway(&net);
    defer net.deinit();
    net.transport.keep_history = true;
    try net.transport.script(.{ .respond = .{ .body = test_index } });
    try net.transport.script(.{ .respond = .{ .body = "{\"images\": []}" } });
    try net.transport.script(.{ .respond = .{ .body = "{\"images\": [], \"release\": \"https://musicbrainz.org/release/../../x\"}" } });
    try net.transport.script(.{ .respond = .{ .body = "<html>" } });
    var archive: CoverArtArchive = .{ .gateway = &net.gateway };
    const listed = (try archive.releaseGroupIndex(testing.allocator, test_group_mbid)).?;
    defer listed.deinit(testing.allocator);
    try testing.expectEqualStrings(test_release_mbid, &listed.release_mbid);
    try testing.expectEqualStrings("https://coverartarchive.org/release-group/" ++ test_group_mbid ++ "/", net.transport.history.items[0].url);
    for (0..3) |_| try testing.expectError(error.InvalidProviderResponse, archive.releaseGroupIndex(testing.allocator, test_group_mbid));
}

test "an index larger than its bound is refused" {
    var net: network.testing.TestGateway = undefined;
    testGateway(&net);
    defer net.deinit();
    const body = try testing.allocator.alloc(u8, max_index_bytes + 1);
    defer testing.allocator.free(body);
    @memset(body, ' ');
    try net.transport.script(.{ .respond = .{ .body = body } });
    var archive: CoverArtArchive = .{ .gateway = &net.gateway };
    try testing.expectError(error.ResponseTooLarge, archive.releaseIndex(testing.allocator, test_release_mbid));
}

test "an indexed image and its thumbnail are asked for by the release and the image ID" {
    var net: network.testing.TestGateway = undefined;
    testGateway(&net);
    defer net.deinit();
    net.transport.keep_history = true;
    try net.transport.script(.{ .respond = .{ .body = jpeg } });
    try net.transport.script(.{ .respond = .{ .body = jpeg } });
    var archive: CoverArtArchive = .{ .gateway = &net.gateway };
    const full = try archive.image(testing.allocator, test_release_mbid, 101);
    defer testing.allocator.free(full.image.bytes);
    const small = try archive.thumbnail(testing.allocator, test_release_mbid, 101);
    defer testing.allocator.free(small.image.bytes);
    try testing.expectEqualStrings("https://coverartarchive.org/release/" ++ test_release_mbid ++ "/101", net.transport.history.items[0].url);
    try testing.expectEqualStrings("https://coverartarchive.org/release/" ++ test_release_mbid ++ "/101-250", net.transport.history.items[1].url);
    try testing.expectError(error.InvalidProviderResponse, archive.image(testing.allocator, test_release_mbid, 0));
    try testing.expectEqual(@as(u32, 2), net.transport.requestCount());
}
