//! ISO base media file format (MP4, M4A) box framing.
//!
//! Only framing lives here: locating the movie box without reading media data,
//! and iterating boxes inside a buffer. What a box means belongs to its reader,
//! `codec/mp4.zig` for audio tracks and `metadata/mp4_tags.zig` for tags.

const std = @import("std");
const source = @import("source.zig");

/// Upper bound on a movie box read into memory. Sample tables grow with
/// duration; ten hours of 48 kHz AAC needs about 8 MiB of them.
pub const max_movie_bytes: usize = 64 * 1024 * 1024;
/// Top-level boxes examined before `moov` must have been found.
const max_top_level_boxes: usize = 1024;

pub const Error = error{
    InvalidMp4,
    TruncatedMp4,
    Mp4MovieTooLarge,
    Mp4MovieMissing,
};

pub const Box = struct {
    kind: [4]u8,
    body: []const u8,

    pub fn is(self: Box, kind: *const [4]u8) bool {
        return std.mem.eql(u8, &self.kind, kind);
    }
};

/// Boxes laid end to end in a buffer.
pub const Iterator = struct {
    bytes: []const u8,
    cursor: usize = 0,

    pub fn init(bytes: []const u8) Iterator {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Iterator) Error!?Box {
        const remaining = self.bytes.len - self.cursor;
        if (remaining == 0) return null;
        if (remaining < 8) return error.InvalidMp4;
        const header = self.bytes[self.cursor..];
        var size: u64 = std.mem.readInt(u32, header[0..4], .big);
        var header_bytes: usize = 8;
        if (size == 1) {
            if (remaining < 16) return error.InvalidMp4;
            size = std.mem.readInt(u64, header[8..16], .big);
            header_bytes = 16;
        } else if (size == 0) {
            size = remaining;
        }
        if (size < header_bytes or size > remaining) return error.InvalidMp4;
        const length: usize = @intCast(size);
        const box: Box = .{
            .kind = header[4..8].*,
            .body = header[header_bytes..length],
        };
        self.cursor += length;
        return box;
    }

    /// The first box of `kind`, or null.
    pub fn find(bytes: []const u8, kind: *const [4]u8) Error!?Box {
        var boxes = Iterator.init(bytes);
        while (try boxes.next()) |box| {
            if (box.is(kind)) return box;
        }
        return null;
    }
};

/// Follows `path` down nested containers, returning the innermost box.
pub fn descend(bytes: []const u8, path: []const *const [4]u8) Error!?Box {
    var current = bytes;
    var found: ?Box = null;
    for (path) |kind| {
        const box = try Iterator.find(current, kind) orelse return null;
        found = box;
        current = box.body;
    }
    return found;
}

/// Reads the `moov` box into memory. The caller owns the returned body.
///
/// Top-level boxes are visited by header alone, so a movie box stored after
/// gigabytes of media data costs a handful of reads, not a scan.
pub fn readMovie(allocator: std.mem.Allocator, readable: source.ReadableSource) ![]u8 {
    const file_size = readable.size();
    var offset: u64 = 0;
    for (0..max_top_level_boxes) |_| {
        if (offset + 8 > file_size) return error.Mp4MovieMissing;
        var header: [16]u8 = undefined;
        const got = try readable.readAt(offset, &header);
        if (got < 8) return error.TruncatedMp4;
        var size: u64 = std.mem.readInt(u32, header[0..4], .big);
        var header_bytes: u64 = 8;
        if (size == 1) {
            if (got < 16) return error.TruncatedMp4;
            size = std.mem.readInt(u64, header[8..16], .big);
            header_bytes = 16;
        } else if (size == 0) {
            size = file_size - offset;
        }
        if (size < header_bytes) return error.InvalidMp4;
        if (std.mem.eql(u8, header[4..8], "moov")) {
            const body_size = size - header_bytes;
            if (body_size > max_movie_bytes) return error.Mp4MovieTooLarge;
            if (offset + size > file_size) return error.TruncatedMp4;
            const body = try allocator.alloc(u8, @intCast(body_size));
            errdefer allocator.free(body);
            if (try readable.readAt(offset + header_bytes, body) != body.len)
                return error.TruncatedMp4;
            return body;
        }
        offset = std.math.add(u64, offset, size) catch return error.InvalidMp4;
    }
    return error.Mp4MovieMissing;
}

/// Big-endian integer at `offset`, or `error.InvalidMp4` past the end.
pub fn int(comptime T: type, bytes: []const u8, offset: usize) Error!T {
    const width = @sizeOf(T);
    if (offset > bytes.len or bytes.len - offset < width) return error.InvalidMp4;
    return std.mem.readInt(T, bytes[offset..][0..width], .big);
}

test "boxes are iterated by their declared sizes, including 64-bit sizes" {
    const bytes = "\x00\x00\x00\x0cfree\x01\x02\x03\x04" ++
        "\x00\x00\x00\x01wide\x00\x00\x00\x00\x00\x00\x00\x12\xaa\xbb";
    var boxes = Iterator.init(bytes);
    const first = (try boxes.next()).?;
    try std.testing.expect(first.is("free"));
    try std.testing.expectEqualSlices(u8, "\x01\x02\x03\x04", first.body);
    const second = (try boxes.next()).?;
    try std.testing.expect(second.is("wide"));
    try std.testing.expectEqualSlices(u8, "\xaa\xbb", second.body);
    try std.testing.expect(try boxes.next() == null);
}

test "a box claiming more bytes than its parent holds is invalid" {
    var boxes = Iterator.init("\x00\x00\x00\x40free\x00");
    try std.testing.expectError(error.InvalidMp4, boxes.next());
}

test "the movie box is found behind media data without reading the media" {
    var file = try source.LocalFileSource.open(std.testing.io, "fixtures/audio/tagged-reference-alac.m4a");
    defer file.close();
    const movie = try readMovie(std.testing.allocator, file.readable());
    defer std.testing.allocator.free(movie);
    try std.testing.expect(try descend(movie, &.{ "trak", "mdia", "minf", "stbl", "stsd" }) != null);
}

test "a file with no movie box is reported as such" {
    var memory = source.MemorySource{ .bytes = "\x00\x00\x00\x10ftypM4A \x00\x00\x02\x00" };
    try std.testing.expectError(error.Mp4MovieMissing, readMovie(std.testing.allocator, memory.readable()));
}
