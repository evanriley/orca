//! Comment headers of Ogg Opus and Ogg Vorbis streams.
//!
//! Both codecs carry a Vorbis comment block as the second packet of the first
//! logical stream, behind a codec-specific signature. Only Ogg page framing is
//! read here; the payload is handed to `vorbis_comment.parse`, so key
//! spellings and canonical mapping stay in one place.

const std = @import("std");
const lyrics = @import("lyrics.zig");
const model = @import("model.zig");
const source = @import("../storage/source.zig");
const vorbis_comment = @import("vorbis_comment.zig");

/// Upper bound on a comment packet. Matches the FLAC comment block limit; a
/// larger claim is a corrupt or hostile stream, and embedded artwork beyond it
/// is not worth reading at scan time.
const max_packet_bytes: usize = (1 << 24) - 1;
const page_header_bytes = 27;
/// Pages examined before the comment header must have been found. A maximal
/// comment packet spans about 260 full pages; the rest is headroom for pages of
/// other multiplexed streams.
const max_pages: usize = 4096;

pub const ReadError = error{
    InvalidOggStream,
    TruncatedOggStream,
    OggCommentTooLarge,
    OggCommentNotFound,
};

const Signature = struct { identification: []const u8, comment: []const u8 };

const opus: Signature = .{ .identification = "OpusHead", .comment = "OpusTags" };
const vorbis: Signature = .{ .identification = "\x01vorbis", .comment = "\x03vorbis" };

/// Canonical tags from the comment header, or null when the stream is neither
/// Ogg Opus nor Ogg Vorbis. Text lives in `allocator`; callers pass an arena.
pub fn read(allocator: std.mem.Allocator, readable: source.ReadableSource) !?model.ObservedTags {
    const comment = try readComment(allocator, readable) orelse return null;
    defer allocator.free(comment.packet);
    var tags = try vorbis_comment.parse(allocator, comment.payload);
    if (try choosePicture(allocator, comment.payload)) |picture| {
        defer allocator.free(picture.block);
        tags.artwork = .{
            .mime_type = try allocator.dupe(u8, picture.view.mime_type),
            .byte_size = picture.view.data.len,
            .kind = picture.view.kind,
        };
    }
    return tags;
}

/// The cover image carried in a `METADATA_BLOCK_PICTURE` comment, or null.
pub fn readPicture(allocator: std.mem.Allocator, readable: source.ReadableSource) !?model.EmbeddedImage {
    const comment = try readComment(allocator, readable) orelse return null;
    defer allocator.free(comment.packet);
    const picture = try choosePicture(allocator, comment.payload) orelse return null;
    defer allocator.free(picture.block);
    if (picture.view.data.len > model.max_image_bytes) return error.ArtworkTooLarge;
    const bytes = try allocator.dupe(u8, picture.view.data);
    errdefer allocator.free(bytes);
    return try model.adoptImage(allocator, bytes, picture.view.kind);
}

/// The lyrics in the stream's comment header, as
/// `vorbis_comment.lyricsFromComments` finds them.
pub fn readLyrics(
    allocator: std.mem.Allocator,
    output: std.mem.Allocator,
    readable: source.ReadableSource,
) !?lyrics.Content {
    const comment = try readComment(allocator, readable) orelse return null;
    defer allocator.free(comment.packet);
    return vorbis_comment.lyricsFromComments(output, comment.payload);
}

const Comment = struct {
    packet: []u8,
    /// The Vorbis comment payload inside `packet`, past the codec signature.
    payload: []const u8,
};

fn readComment(allocator: std.mem.Allocator, readable: source.ReadableSource) !?Comment {
    var packets: PacketReader = .{ .readable = readable };
    const identification = try packets.next(allocator) orelse return null;
    defer allocator.free(identification);
    const signature = if (std.mem.startsWith(u8, identification, opus.identification))
        opus
    else if (std.mem.startsWith(u8, identification, vorbis.identification))
        vorbis
    else
        return null;

    const packet = try packets.next(allocator) orelse return error.TruncatedOggStream;
    errdefer allocator.free(packet);
    if (!std.mem.startsWith(u8, packet, signature.comment)) return error.InvalidOggStream;
    return .{ .packet = packet, .payload = packet[signature.comment.len..] };
}

const Picture = struct {
    block: []u8,
    view: vorbis_comment.PictureView,
};

/// The first front cover among the `METADATA_BLOCK_PICTURE` entries, else the
/// first usable picture: the same preference FLAC's `PICTURE` blocks get.
fn choosePicture(allocator: std.mem.Allocator, payload: []const u8) !?Picture {
    const decoder = std.base64.standard.Decoder;
    var chosen: ?Picture = null;
    errdefer if (chosen) |picture| allocator.free(picture.block);
    var entries = try vorbis_comment.Entries.init(payload);
    while (try entries.next()) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.key, "METADATA_BLOCK_PICTURE")) continue;
        if (chosen) |existing| if (existing.view.kind == .front_cover) break;
        const size = decoder.calcSizeForSlice(entry.value) catch continue;
        const block = try allocator.alloc(u8, size);
        decoder.decode(block, entry.value) catch {
            allocator.free(block);
            continue;
        };
        const view = vorbis_comment.pictureFromBlock(block) orelse {
            allocator.free(block);
            continue;
        };
        if (chosen) |existing| {
            if (view.kind != .front_cover) {
                allocator.free(block);
                continue;
            }
            allocator.free(existing.block);
        }
        chosen = .{ .block = block, .view = view };
    }
    return chosen;
}

/// Reassembles packets of the first logical stream from its pages. Pages of
/// other streams multiplexed into the file are skipped.
const PacketReader = struct {
    readable: source.ReadableSource,
    offset: u64 = 0,
    serial: ?u32 = null,
    /// Segment lengths of the current page not yet consumed.
    segments: [255]u8 = undefined,
    segment_count: usize = 0,
    segment_index: usize = 0,
    pages_examined: usize = 0,

    fn next(self: *PacketReader, allocator: std.mem.Allocator) !?[]u8 {
        var packet: std.ArrayList(u8) = .empty;
        errdefer packet.deinit(allocator);
        while (true) {
            if (self.segment_index == self.segment_count) {
                if (!try self.nextPage()) {
                    if (packet.items.len == 0) {
                        packet.deinit(allocator);
                        return null;
                    }
                    return error.TruncatedOggStream;
                }
                continue;
            }
            const length = self.segments[self.segment_index];
            self.segment_index += 1;
            if (packet.items.len + length > max_packet_bytes) return error.OggCommentTooLarge;
            const start = packet.items.len;
            try packet.resize(allocator, start + length);
            if (try self.readable.readAt(self.offset, packet.items[start..]) != length)
                return error.TruncatedOggStream;
            self.offset += length;
            if (length < 255) return try packet.toOwnedSlice(allocator);
        }
    }

    /// Advances to the next page of the first stream. False at end of input.
    fn nextPage(self: *PacketReader) !bool {
        while (true) {
            if (self.pages_examined == max_pages) return error.OggCommentNotFound;
            self.pages_examined += 1;
            var header: [page_header_bytes]u8 = undefined;
            const got = try self.readable.readAt(self.offset, &header);
            if (got == 0) return false;
            if (got != header.len) return error.TruncatedOggStream;
            if (!std.mem.eql(u8, header[0..4], "OggS") or header[4] != 0)
                return error.InvalidOggStream;
            const serial = std.mem.readInt(u32, header[14..18], .little);
            const count = header[26];
            var table: [255]u8 = undefined;
            if (try self.readable.readAt(self.offset + page_header_bytes, table[0..count]) != count)
                return error.TruncatedOggStream;
            const body_offset = self.offset + page_header_bytes + count;
            var body_length: u64 = 0;
            for (table[0..count]) |length| body_length += length;

            const first = self.serial orelse serial;
            self.serial = first;
            if (serial != first) {
                self.offset = body_offset + body_length;
                continue;
            }
            @memcpy(self.segments[0..count], table[0..count]);
            self.segment_count = count;
            self.segment_index = 0;
            self.offset = body_offset;
            return true;
        }
    }
};

fn readFixture(allocator: std.mem.Allocator, path: []const u8) !?model.ObservedTags {
    var local = try source.LocalFileSource.open(std.testing.io, path);
    defer local.close();
    return read(allocator, local.readable());
}

test "an Ogg Opus comment header yields canonical tags" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tags = (try readFixture(arena.allocator(), "fixtures/audio/tagged-reference.opus")).?;
    try std.testing.expectEqualStrings("Opus Reference", tags.title.?);
    try std.testing.expectEqualStrings("Orca Fixtures", tags.artist.?);
    try std.testing.expectEqualStrings("Codec References", tags.album.?);
    try std.testing.expectEqual(@as(?u32, 3), tags.track_number);
    try std.testing.expectEqualStrings("2026", tags.date.?);
    try std.testing.expectEqual(@as(usize, 1), tags.genres.len);
    try std.testing.expectEqualStrings("Test Tone", tags.genres[0]);
}

test "an Ogg Vorbis comment header yields canonical tags" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tags = (try readFixture(arena.allocator(), "fixtures/audio/tagged-reference.ogg")).?;
    try std.testing.expectEqualStrings("Reference Tone", tags.title.?);
    try std.testing.expectEqualStrings("Orca Test", tags.artist.?);
    try std.testing.expectEqualStrings("Fixtures", tags.album.?);
    try std.testing.expectEqualStrings("Orca Test", tags.album_artist.?);
    try std.testing.expectEqual(@as(?u32, 1), tags.track_number);
    try std.testing.expectEqual(@as(?u32, 3), tags.track_total);
}

test "an Ogg stream of another codec yields no tags" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var page: [page_header_bytes + 1 + 5]u8 = @splat(0);
    @memcpy(page[0..4], "OggS");
    page[26] = 1;
    page[27] = 5;
    @memcpy(page[28..33], "\x7fFLAC");
    var memory = source.MemorySource{ .bytes = &page };
    try std.testing.expect(try read(arena.allocator(), memory.readable()) == null);
}

test "bytes that are not Ogg pages are rejected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var memory = source.MemorySource{ .bytes = "fLaC" ++ "\x00" ** 40 };
    try std.testing.expectError(error.InvalidOggStream, read(arena.allocator(), memory.readable()));
}

test "a page that claims more bytes than the stream holds is truncated, not read past" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var page: [page_header_bytes + 1]u8 = @splat(0);
    @memcpy(page[0..4], "OggS");
    page[26] = 1;
    page[27] = 200;
    var memory = source.MemorySource{ .bytes = &page };
    try std.testing.expectError(error.TruncatedOggStream, read(arena.allocator(), memory.readable()));
}

test "a stream of empty pages is abandoned after a bounded number of them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const empty_page = "OggS" ++ "\x00" ** (page_header_bytes - 4);
    const pages = try arena.allocator().alloc(u8, empty_page.len * (max_pages + 1));
    for (0..max_pages + 1) |index|
        @memcpy(pages[index * empty_page.len ..][0..empty_page.len], empty_page);
    var memory = source.MemorySource{ .bytes = pages };
    try std.testing.expectError(error.OggCommentNotFound, read(arena.allocator(), memory.readable()));
}

test "a METADATA_BLOCK_PICTURE comment is observed and read back as the same image" {
    for ([_][]const u8{ "fixtures/audio/covered-reference.opus", "fixtures/audio/covered-reference.ogg" }) |path| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const tags = (try readFixture(arena.allocator(), path)).?;
        try std.testing.expectEqualStrings("image/png", tags.artwork.?.mime_type);
        try std.testing.expectEqual(@as(u64, 217), tags.artwork.?.byte_size);
        try std.testing.expectEqual(model.ArtworkKind.front_cover, tags.artwork.?.kind);

        var file = try source.LocalFileSource.open(std.testing.io, path);
        defer file.close();
        const image = (try readPicture(std.testing.allocator, file.readable())).?;
        defer image.deinit();
        try std.testing.expectEqual(@as(usize, 217), image.bytes.len);
        try std.testing.expectEqualStrings("image/png", image.mime_type);
    }
}

test "an Ogg stream without a picture comment has no cover" {
    var file = try source.LocalFileSource.open(std.testing.io, "fixtures/audio/tagged-reference.opus");
    defer file.close();
    try std.testing.expect(try readPicture(std.testing.allocator, file.readable()) == null);
}
