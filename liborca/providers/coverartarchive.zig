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
