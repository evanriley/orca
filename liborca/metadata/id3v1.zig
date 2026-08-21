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

/// Encode a conservative ID3v1/1.1 tag. The portable baseline deliberately
/// rejects non-ASCII and overlong values rather than silently truncating or
/// guessing a legacy code page.
pub fn encode(tag: Tag) ![128]u8 {
    var bytes: [128]u8 = @splat(0);
    @memcpy(bytes[0..3], "TAG");
    try writeField(bytes[3..33], tag.title);
    try writeField(bytes[33..63], tag.artist);
    try writeField(bytes[63..93], tag.album);
    try writeField(bytes[93..97], tag.year);
    if (tag.track_number) |track| {
        if (track == 0) return error.InvalidId3v1Track;
        try writeField(bytes[97..125], tag.comment);
        bytes[125] = 0;
        bytes[126] = track;
    } else {
        try writeField(bytes[97..127], tag.comment);
    }
    bytes[127] = tag.genre;
    return bytes;
}

fn writeField(destination: []u8, value: []const u8) !void {
    if (value.len > destination.len) return error.Id3v1FieldTooLong;
    for (value) |byte| if (byte >= 0x80) return error.Id3v1RequiresAscii;
    @memcpy(destination[0..value.len], value);
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

test "portable ID3v1 writer round-trips without silent truncation" {
    const bytes = try encode(.{
        .title = "Generated title",
        .artist = "Generated artist",
        .album = "Generated album",
        .year = "2026",
        .comment = "Orca fixture",
        .track_number = 3,
        .genre = 13,
    });
    const tag = parse(&bytes).?;
    try std.testing.expectEqualStrings("Generated title", tag.title);
    try std.testing.expectEqual(@as(?u8, 3), tag.track_number);
    try std.testing.expectError(error.Id3v1FieldTooLong, encode(.{
        .title = "This title is deliberately longer than thirty bytes",
        .artist = "",
        .album = "",
        .year = "",
        .comment = "",
        .track_number = null,
        .genre = 255,
    }));
}
