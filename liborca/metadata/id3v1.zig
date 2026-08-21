const std = @import("std");
const source = @import("../storage/source.zig");

pub const Tag = struct {
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    year: []const u8,
    comment: []const u8,
    track_number: ?u8,
    genre: u8,
};

pub fn read(readable: source.ReadableSource, buffer: *[128]u8) !?Tag {
    if (readable.size() < buffer.len) return null;
    if (try readable.readAt(readable.size() - buffer.len, buffer) != buffer.len) return null;
    return parse(buffer);
}

pub fn parse(bytes: *const [128]u8) ?Tag {
    if (!std.mem.eql(u8, bytes[0..3], "TAG")) return null;
    const is_v11 = bytes[125] == 0 and bytes[126] != 0;
    return .{
        .title = trim(bytes[3..33]),
        .artist = trim(bytes[33..63]),
        .album = trim(bytes[63..93]),
        .year = trim(bytes[93..97]),
        .comment = trim(if (is_v11) bytes[97..125] else bytes[97..127]),
        .track_number = if (is_v11) bytes[126] else null,
        .genre = bytes[127],
    };
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trimEnd(u8, value, " \x00");
}

test "parses ID3v1.1 without leaking format conventions into metadata" {
    var bytes: [128]u8 = @splat(0);
    @memcpy(bytes[0..3], "TAG");
    @memcpy(bytes[3..13], "Test title");
    @memcpy(bytes[33..44], "Test artist");
    @memcpy(bytes[63..73], "Test album");
    @memcpy(bytes[93..97], "2026");
    bytes[126] = 7;
    bytes[127] = 13;

    const tag = parse(&bytes).?;
    try std.testing.expectEqualStrings("Test title", tag.title);
    try std.testing.expectEqualStrings("Test artist", tag.artist);
    try std.testing.expectEqual(@as(?u8, 7), tag.track_number);
}
