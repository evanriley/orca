//! Tags in WAV and AIFF files.
//!
//! Both containers can carry an ID3v2 tag in a chunk (`id3 ` or `ID3 `), which
//! taggers use when they want the full ID3 vocabulary and artwork. WAV also has
//! the older `LIST`/`INFO` chunk of short text fields. ID3 wins when both are
//! present, as it does for MP3, unless it holds only a cover: then INFO's
//! values are read and the cover is kept.

const std = @import("std");
const model = @import("model.zig");
const id3v1 = @import("id3v1.zig");
const id3v2 = @import("id3v2.zig");
const source = @import("../storage/source.zig");

/// Chunks examined before giving up on finding a tag.
const max_chunks: usize = 1024;
/// A LIST/INFO chunk is a handful of short strings; anything larger is not one
/// this reader will hold in memory.
const max_info_bytes: u32 = 64 * 1024;

const Container = struct {
    endian: std.builtin.Endian,
    first_chunk: u64 = 12,
};

const Chunks = struct {
    id3: ?u64 = null,
    info: ?struct { offset: u64, size: u32 } = null,
};

pub fn read(allocator: std.mem.Allocator, readable: source.ReadableSource) !?model.ObservedTags {
    const chunks = try findChunks(readable) orelse return null;
    var artwork: ?model.Artwork = null;
    if (chunks.id3) |offset| {
        var view: source.OffsetSource = .{ .inner = readable, .offset = offset };
        if (try id3v2.read(allocator, view.readable())) |tags| {
            if (tags.hasValuesBesidesArtwork()) return tags;
            artwork = tags.artwork;
        }
    }
    var tags: model.ObservedTags = if (chunks.info) |info|
        try readInfo(allocator, readable, info.offset, info.size) orelse .{}
    else
        .{};
    tags.artwork = artwork;
    if (tags.isEmpty()) return null;
    return tags;
}

pub fn readPicture(allocator: std.mem.Allocator, readable: source.ReadableSource) !?model.EmbeddedImage {
    const chunks = try findChunks(readable) orelse return null;
    const offset = chunks.id3 orelse return null;
    var view: source.OffsetSource = .{ .inner = readable, .offset = offset };
    return id3v2.readPicture(allocator, view.readable());
}

fn container(readable: source.ReadableSource) !?Container {
    var header: [12]u8 = undefined;
    if (try readable.readAt(0, &header) != header.len) return null;
    if (std.mem.eql(u8, header[0..4], "RIFF") and std.mem.eql(u8, header[8..12], "WAVE"))
        return .{ .endian = .little };
    if (std.mem.eql(u8, header[0..4], "FORM") and
        (std.mem.eql(u8, header[8..12], "AIFF") or std.mem.eql(u8, header[8..12], "AIFC")))
        return .{ .endian = .big };
    return null;
}

fn findChunks(readable: source.ReadableSource) !?Chunks {
    const layout = try container(readable) orelse return null;
    var chunks: Chunks = .{};
    var offset = layout.first_chunk;
    const size = readable.size();
    for (0..max_chunks) |_| {
        if (offset + 8 > size) break;
        var header: [8]u8 = undefined;
        if (try readable.readAt(offset, &header) != header.len) break;
        const length = std.mem.readInt(u32, header[4..8], layout.endian);
        const body = offset + 8;
        if (body + length > size) break;
        if (std.ascii.eqlIgnoreCase(header[0..4], "id3 ")) {
            if (chunks.id3 == null) chunks.id3 = body;
        } else if (std.mem.eql(u8, header[0..4], "LIST") and length >= 4) {
            var kind: [4]u8 = undefined;
            if (try readable.readAt(body, &kind) == kind.len and std.mem.eql(u8, &kind, "INFO"))
                chunks.info = .{ .offset = body + 4, .size = length - 4 };
        }
        offset = body + length + (length & 1);
    }
    return chunks;
}

fn readInfo(allocator: std.mem.Allocator, readable: source.ReadableSource, offset: u64, size: u32) !?model.ObservedTags {
    if (size > max_info_bytes) return null;
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    if (try readable.readAt(offset, bytes) != bytes.len) return null;

    var tags: model.ObservedTags = .{};
    var genres: std.ArrayList([]const u8) = .empty;
    defer genres.deinit(allocator);
    var cursor: usize = 0;
    while (cursor + 8 <= bytes.len) {
        const id = bytes[cursor..][0..4];
        const length = std.mem.readInt(u32, bytes[cursor + 4 ..][0..4], .little);
        const start = cursor + 8;
        if (length > bytes.len - start) break;
        cursor = start + length + (length & 1);
        const raw = std.mem.trim(u8, bytes[start..][0..length], " \x00");
        if (raw.len == 0) continue;
        const value = if (std.unicode.utf8ValidateSlice(raw))
            try allocator.dupe(u8, raw)
        else
            try id3v1.latin1ToUtf8(allocator, raw);
        if (std.mem.eql(u8, id, "INAM")) {
            if (tags.title == null) tags.title = value;
        } else if (std.mem.eql(u8, id, "IART")) {
            if (tags.artist == null) tags.artist = value;
        } else if (std.mem.eql(u8, id, "IPRD")) {
            if (tags.album == null) tags.album = value;
        } else if (std.mem.eql(u8, id, "ICRD")) {
            if (tags.date == null) tags.date = value;
        } else if (std.mem.eql(u8, id, "IGNR")) {
            try genres.append(allocator, value);
        } else if (std.mem.eql(u8, id, "ITRK") or std.mem.eql(u8, id, "IPRT")) {
            if (tags.track_number == null) tags.track_number = std.fmt.parseUnsigned(u32, value, 10) catch null;
        }
    }
    tags.genres = try genres.toOwnedSlice(allocator);
    if (tags.isEmpty()) return null;
    return tags;
}

fn readFixture(allocator: std.mem.Allocator, path: []const u8) !?model.ObservedTags {
    var file = try source.LocalFileSource.open(std.testing.io, path);
    defer file.close();
    return read(allocator, file.readable());
}

test "a WAV LIST/INFO chunk yields canonical tags" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tags = (try readFixture(arena.allocator(), "fixtures/audio/tagged-reference.wav")).?;
    try std.testing.expectEqualStrings("WAV Reference", tags.title.?);
    try std.testing.expectEqualStrings("Orca Fixtures", tags.artist.?);
    try std.testing.expectEqualStrings("Codec References", tags.album.?);
    try std.testing.expectEqualStrings("2026", tags.date.?);
    try std.testing.expectEqual(@as(?u32, 4), tags.track_number);
    try std.testing.expectEqualStrings("Test Tone", tags.genres[0]);
}

test "a WAV id3 chunk outranks its LIST/INFO chunk" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tags = (try readFixture(arena.allocator(), "fixtures/audio/id3-tagged-reference.wav")).?;
    try std.testing.expectEqualStrings("Reference Tone", tags.title.?);
    try std.testing.expectEqualStrings("Orca Test", tags.album_artist.?);
    try std.testing.expectEqual(@as(?u32, 3), tags.track_total);
}

test "an AIFF ID3 chunk yields tags and its cover" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tags = (try readFixture(arena.allocator(), "fixtures/audio/tagged-reference.aiff")).?;
    try std.testing.expectEqualStrings("Reference Tone", tags.title.?);
    try std.testing.expectEqual(@as(?u32, 1), tags.track_number);

    const covered = (try readFixture(arena.allocator(), "fixtures/audio/covered-reference.aiff")).?;
    try std.testing.expectEqual(@as(u64, 217), covered.artwork.?.byte_size);
    var file = try source.LocalFileSource.open(std.testing.io, "fixtures/audio/covered-reference.aiff");
    defer file.close();
    const image = (try readPicture(std.testing.allocator, file.readable())).?;
    defer image.deinit();
    try std.testing.expectEqualStrings("image/png", image.mime_type);
    try std.testing.expectEqual(@as(usize, 217), image.bytes.len);
}

fn withCoverOnlyId3Chunk(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const original = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 20));
    const picture = "\x00image/png\x00\x03\x00" ++ "\x5a" ** 32;
    var frame: [10]u8 = .{ 'A', 'P', 'I', 'C', 0, 0, 0, picture.len, 0, 0 };
    var header: [10]u8 = .{ 'I', 'D', '3', 3, 0, 0, 0, 0, 0, frame.len + picture.len };
    var chunk_header: [8]u8 = .{ 'i', 'd', '3', ' ', 0, 0, 0, 0 };
    std.mem.writeInt(u32, chunk_header[4..8], header.len + frame.len + picture.len, .little);
    const bytes = try std.mem.concat(allocator, u8, &.{ original, &chunk_header, &header, &frame, picture });
    std.mem.writeInt(u32, bytes[4..8], @intCast(bytes.len - 8), .little);
    return bytes;
}

test "a WAV id3 chunk holding only a cover yields the LIST/INFO values and keeps the cover" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bytes = try withCoverOnlyId3Chunk(allocator, "fixtures/audio/tagged-reference.wav");
    var memory = source.MemorySource{ .bytes = bytes };
    const tags = (try read(allocator, memory.readable())).?;
    try std.testing.expectEqualStrings("WAV Reference", tags.title.?);
    try std.testing.expectEqualStrings("Orca Fixtures", tags.artist.?);
    try std.testing.expectEqual(@as(?u32, 4), tags.track_number);
    try std.testing.expectEqualStrings("image/png", tags.artwork.?.mime_type);
    try std.testing.expectEqual(@as(u64, 32), tags.artwork.?.byte_size);
}

test "a WAV id3 chunk holding only a cover and no LIST/INFO chunk yields the cover alone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bytes = try withCoverOnlyId3Chunk(allocator, "fixtures/audio/generated-reference.wav");
    var memory = source.MemorySource{ .bytes = bytes };
    const tags = (try read(allocator, memory.readable())).?;
    try std.testing.expect(!tags.hasValuesBesidesArtwork());
    try std.testing.expectEqual(@as(u64, 32), tags.artwork.?.byte_size);
}

test "an untagged WAV yields no tags" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(try readFixture(arena.allocator(), "fixtures/audio/generated-reference.wav") == null);
}
