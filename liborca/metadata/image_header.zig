//! The pixel size and identity of a cover image, read from its bytes.
//!
//! Only headers are parsed: PNG `IHDR`, a JPEG start-of-frame segment, the GIF
//! logical screen, a WebP `VP8 `, `VP8L` or `VP8X` chunk and a BMP info
//! header. Nothing is decoded, so measuring an image costs one pass over its
//! bytes for the hash and a few header reads for the size.

const std = @import("std");
const source = @import("../storage/source.zig");

pub const Dimensions = struct {
    width: u32,
    height: u32,
};

/// What Orca records about an image it has observed. `hash` is never zero, so
/// a stored zero can mean "measured, but the bytes could not be read".
pub const Measurement = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    hash: i64,
};

/// The stored hash of an image whose bytes could not be read.
pub const unreadable_hash: i64 = 0;

/// A JPEG walks its segments to reach the frame header; past this many it is
/// treated as unparsable rather than walked further.
const max_jpeg_segments = 256;

/// The first eight bytes of the image's Blake3 digest, as a signed integer
/// SQLite stores in place. Never `unreadable_hash`.
pub fn hash(bytes: []const u8) i64 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(bytes);
    return finish(&hasher);
}

fn finish(hasher: *const std.crypto.hash.Blake3) i64 {
    var digest: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    hasher.final(&digest);
    const value = std.mem.readInt(i64, digest[0..8], .little);
    return if (value == unreadable_hash) 1 else value;
}

pub fn measure(bytes: []const u8) Measurement {
    const size = dimensions(bytes);
    return .{
        .width = if (size) |known| known.width else null,
        .height = if (size) |known| known.height else null,
        .hash = hash(bytes),
    };
}

/// Measures `length` bytes of `readable` starting at `offset` without holding
/// them: the hash streams through a fixed buffer and the size comes from a
/// few small header reads.
pub fn measureAt(readable: source.ReadableSource, offset: u64, length: u64) !Measurement {
    const window: SourceWindow = .{ .readable = readable, .offset = offset, .length = length };
    const size = try dimensionsFrom(window, length);
    var hasher = std.crypto.hash.Blake3.init(.{});
    var buffer: [16 << 10]u8 = undefined;
    var position: u64 = 0;
    while (position < length) {
        const want: usize = @intCast(@min(buffer.len, length - position));
        const got = try readable.readAt(offset + position, buffer[0..want]);
        if (got == 0) return error.TruncatedImage;
        hasher.update(buffer[0..got]);
        position += got;
    }
    return .{
        .width = if (size) |known| known.width else null,
        .height = if (size) |known| known.height else null,
        .hash = finish(&hasher),
    };
}

/// The image's declared size, or null when its header is not one of the
/// formats above or is cut short. A zero side is treated as unknown.
pub fn dimensions(bytes: []const u8) ?Dimensions {
    const window: SliceWindow = .{ .bytes = bytes };
    return dimensionsFrom(window, bytes.len) catch unreachable;
}

const SliceWindow = struct {
    bytes: []const u8,

    fn readAt(self: SliceWindow, offset: u64, buffer: []u8) error{}!usize {
        if (offset >= self.bytes.len) return 0;
        const available = self.bytes[@intCast(offset)..];
        const count = @min(available.len, buffer.len);
        @memcpy(buffer[0..count], available[0..count]);
        return count;
    }
};

const SourceWindow = struct {
    readable: source.ReadableSource,
    offset: u64,
    length: u64,

    fn readAt(self: SourceWindow, offset: u64, buffer: []u8) !usize {
        if (offset >= self.length) return 0;
        const count: usize = @intCast(@min(buffer.len, self.length - offset));
        return self.readable.readAt(self.offset + offset, buffer[0..count]);
    }
};

fn dimensionsFrom(window: anytype, length: u64) !?Dimensions {
    var head: [30]u8 = undefined;
    const bytes = head[0..try window.readAt(0, &head)];
    const size = png(bytes) orelse gif(bytes) orelse webp(bytes) orelse bmp(bytes) orelse
        try jpeg(window, length) orelse return null;
    if (size.width == 0 or size.height == 0) return null;
    return size;
}

fn png(bytes: []const u8) ?Dimensions {
    if (bytes.len < 24 or !std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    return .{
        .width = std.mem.readInt(u32, bytes[16..20], .big),
        .height = std.mem.readInt(u32, bytes[20..24], .big),
    };
}

fn jpeg(window: anytype, length: u64) !?Dimensions {
    var marker_bytes: [2]u8 = undefined;
    if (try window.readAt(0, &marker_bytes) != 2 or marker_bytes[0] != 0xff or marker_bytes[1] != 0xd8)
        return null;
    var offset: u64 = 2;
    var segments: usize = 0;
    while (offset + 4 <= length and segments < max_jpeg_segments) : (segments += 1) {
        var segment: [9]u8 = undefined;
        const got = try window.readAt(offset, &segment);
        if (got < 2 or segment[0] != 0xff) return null;
        const marker = segment[1];
        if (marker == 0xff) {
            offset += 1;
            continue;
        }
        if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd8)) {
            offset += 2;
            continue;
        }
        if (marker == 0xd9 or marker == 0xda or got < 4) return null;
        const segment_length = std.mem.readInt(u16, segment[2..4], .big);
        if (segment_length < 2) return null;
        const start_of_frame = marker >= 0xc0 and marker <= 0xcf and
            marker != 0xc4 and marker != 0xc8 and marker != 0xcc;
        if (start_of_frame) {
            if (got < 9) return null;
            return .{
                .height = std.mem.readInt(u16, segment[5..7], .big),
                .width = std.mem.readInt(u16, segment[7..9], .big),
            };
        }
        offset += 2 + @as(u64, segment_length);
    }
    return null;
}

fn gif(bytes: []const u8) ?Dimensions {
    if (bytes.len < 10) return null;
    if (!std.mem.startsWith(u8, bytes, "GIF87a") and !std.mem.startsWith(u8, bytes, "GIF89a")) return null;
    return .{
        .width = std.mem.readInt(u16, bytes[6..8], .little),
        .height = std.mem.readInt(u16, bytes[8..10], .little),
    };
}

fn webp(bytes: []const u8) ?Dimensions {
    if (bytes.len < 30 or !std.mem.startsWith(u8, bytes, "RIFF") or !std.mem.eql(u8, bytes[8..12], "WEBP"))
        return null;
    const chunk = bytes[12..16];
    if (std.mem.eql(u8, chunk, "VP8 ")) {
        if (!std.mem.eql(u8, bytes[23..26], "\x9d\x01\x2a")) return null;
        return .{
            .width = std.mem.readInt(u16, bytes[26..28], .little) & 0x3fff,
            .height = std.mem.readInt(u16, bytes[28..30], .little) & 0x3fff,
        };
    }
    if (std.mem.eql(u8, chunk, "VP8L")) {
        if (bytes[20] != 0x2f) return null;
        const bits = std.mem.readInt(u32, bytes[21..25], .little);
        return .{
            .width = (bits & 0x3fff) + 1,
            .height = ((bits >> 14) & 0x3fff) + 1,
        };
    }
    if (std.mem.eql(u8, chunk, "VP8X")) {
        return .{
            .width = @as(u32, std.mem.readInt(u24, bytes[24..27], .little)) + 1,
            .height = @as(u32, std.mem.readInt(u24, bytes[27..30], .little)) + 1,
        };
    }
    return null;
}

fn bmp(bytes: []const u8) ?Dimensions {
    if (bytes.len < 26 or !std.mem.startsWith(u8, bytes, "BM")) return null;
    const header_size = std.mem.readInt(u32, bytes[14..18], .little);
    if (header_size == 12) return .{
        .width = std.mem.readInt(u16, bytes[18..20], .little),
        .height = std.mem.readInt(u16, bytes[20..22], .little),
    };
    const width = std.mem.readInt(i32, bytes[18..22], .little);
    const height = std.mem.readInt(i32, bytes[22..26], .little);
    return .{ .width = @abs(width), .height = @abs(height) };
}

const testing = std.testing;

test "a PNG's size comes from its IHDR chunk" {
    const bytes = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x01\x2c\x00\x00\x00\xc8\x08\x02\x00\x00\x00";
    try testing.expectEqual(Dimensions{ .width = 300, .height = 200 }, dimensions(bytes).?);
}

test "a JPEG's size comes from the frame header after any other segments" {
    const bytes = "\xff\xd8" ++
        "\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00" ++
        "\xff\xc2\x00\x11\x08\x04\xb0\x03\x20\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01";
    try testing.expectEqual(Dimensions{ .width = 800, .height = 1200 }, dimensions(bytes).?);
}

test "a JPEG that reaches its scan before a frame header has no size" {
    const bytes = "\xff\xd8\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00";
    try testing.expect(dimensions(bytes) == null);
}

test "GIF, WebP and BMP sizes come from their headers" {
    try testing.expectEqual(
        Dimensions{ .width = 640, .height = 480 },
        dimensions("GIF89a\x80\x02\xe0\x01\x00\x00").?,
    );
    const lossy = "RIFF\x00\x00\x00\x00WEBPVP8 \x00\x00\x00\x00\x00\x00\x00\x9d\x01\x2a\xf4\x01\xf4\x01";
    try testing.expectEqual(Dimensions{ .width = 500, .height = 500 }, dimensions(lossy).?);
    const extended = "RIFF\x00\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x00\x00\x00\x00\xaf\x04\x00\xaf\x04\x00";
    try testing.expectEqual(Dimensions{ .width = 1200, .height = 1200 }, dimensions(extended).?);
    const bitmap = "BM\x00\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x28\x00\x00\x00\x40\x00\x00\x00\xc0\xff\xff\xff";
    try testing.expectEqual(Dimensions{ .width = 64, .height = 64 }, dimensions(bitmap).?);
}

test "a lossless WebP stores each side less one in fourteen bits" {
    const width: u32 = 299;
    const height: u32 = 149;
    var bytes: [30]u8 = undefined;
    @memcpy(bytes[0..20], "RIFF\x00\x00\x00\x00WEBPVP8L\x00\x00\x00\x00");
    bytes[20] = 0x2f;
    std.mem.writeInt(u32, bytes[21..25], width | (height << 14), .little);
    @memset(bytes[25..], 0);
    try testing.expectEqual(Dimensions{ .width = 300, .height = 150 }, dimensions(&bytes).?);
}

test "a hash identifies the bytes and is never the unreadable marker" {
    try testing.expectEqual(hash("cover"), hash("cover"));
    try testing.expect(hash("cover") != hash("cover."));
    try testing.expect(hash("") != unreadable_hash);
    const measured = measure("not an image");
    try testing.expect(measured.width == null and measured.height == null);
    try testing.expectEqual(hash("not an image"), measured.hash);
}

test "measuring an image in place matches measuring its bytes" {
    const jpeg_bytes = "\xff\xd8" ++
        "\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00" ++
        "\xff\xc0\x00\x11\x08\x01\x2c\x01\x2c\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01" ++
        "\xff\xd9";
    const container = "padding" ++ jpeg_bytes ++ "trailing";
    var memory: source.MemorySource = .{ .bytes = container };
    const in_place = try measureAt(memory.readable(), "padding".len, jpeg_bytes.len);
    try testing.expectEqual(measure(jpeg_bytes), in_place);
    try testing.expectEqual(@as(?u32, 300), in_place.width);
    try testing.expectEqual(@as(?u32, 300), in_place.height);
}
