//! Reading an embedded cover image out of one audio file.
//!
//! The dispatch half of artwork: which container the bytes are, where its
//! stream begins, and which reader understands its picture block. The readers
//! themselves stay in `id3v2.zig` and `vorbis_comment.zig`, so `APIC` frame
//! flags and `PICTURE` block layouts terminate there and nothing above this
//! call learns what either one is.
//!
//! Nothing here caches. An embedded cover is read from the file each time it is
//! asked for, which is the only answer that can never be stale and the only one
//! that keeps the Library database the size of a library rather than the size
//! of a picture collection: the 22,060-file reference library carries 6.08 GB
//! of embedded artwork. See `docs/metadata.md` for why a cache is not here yet.

const std = @import("std");
const model = @import("model.zig");
const id3v2 = @import("id3v2.zig");
const vorbis_comment = @import("vorbis_comment.zig");
const format = @import("../storage/format.zig");
const source = @import("../storage/source.zig");

/// Read the cover image embedded in one audio file, or null when it has none.
///
/// The container is sniffed rather than assumed, and a leading ID3v2 tag in
/// front of a stream that is not MPEG audio is stepped over exactly as the
/// codec registry steps over it — 104 files in the reference library are FLAC
/// behind an ID3v2 tag, and the reference adversarial case carries a
/// 216,921-byte `PICTURE` block behind a 219,663-byte tag. Reading byte zero as
/// the start of the stream finds no cover in any of them.
pub fn read(
    allocator: std.mem.Allocator,
    readable: source.ReadableSource,
) !?model.EmbeddedImage {
    const detection = (try format.detect(readable)) orelse return null;
    if (detection.payload_offset == 0) return readDetected(allocator, detection.format, readable);
    var view: source.OffsetSource = .{
        .inner = readable,
        .offset = detection.payload_offset,
    };
    return readDetected(allocator, detection.format, view.readable());
}

/// Whether a sniffed container has a picture reader wired up yet.
///
/// Mirrors `library/tag_reader.supports`. A format Orca can decode but not yet
/// read artwork from reports no cover rather than failing.
pub fn supports(audio_format: format.AudioFormat) bool {
    return switch (audio_format) {
        .flac, .mp3 => true,
        // MP4 `covr` atoms and the Ogg families arrive as additional branches
        // of `readDetected`; no caller changes when they do.
        .mp4, .opus, .vorbis, .wav, .aiff, .wavpack, .qoa => false,
    };
}

/// The same read for a caller that has already resolved the container and, if
/// there was one, the prefix in front of it.
pub fn readDetected(
    allocator: std.mem.Allocator,
    audio_format: format.AudioFormat,
    readable: source.ReadableSource,
) !?model.EmbeddedImage {
    return switch (audio_format) {
        .flac => vorbis_comment.readPicture(allocator, readable),
        .mp3 => id3v2.readPicture(allocator, readable),
        else => null,
    };
}

// ---------------------------------------------------------------------- tests

const testing = std.testing;

/// The 16x16 PNG the covered fixtures embed, so a test asserting the bytes came
/// back intact does not have to trust the same reader that produced them.
const fixture_cover_bytes: usize = 217;

fn readFixture(path: []const u8) !?model.EmbeddedImage {
    var file = try source.LocalFileSource.open(testing.io, path);
    defer file.close();
    return read(testing.allocator, file.readable());
}

test "a FLAC PICTURE block yields its image bytes and the type those bytes are" {
    const image = (try readFixture("fixtures/audio/covered-reference.flac")).?;
    defer image.deinit();
    try testing.expectEqual(fixture_cover_bytes, image.bytes.len);
    try testing.expectEqualStrings("image/png", image.mime_type);
    try testing.expectEqual(model.ArtworkKind.front_cover, image.kind);
    try testing.expectEqualStrings("\x89PNG\r\n\x1a\n", image.bytes[0..8]);
}

test "an ID3v2 APIC frame yields its image bytes and the type those bytes are" {
    const image = (try readFixture("fixtures/audio/covered-reference.mp3")).?;
    defer image.deinit();
    try testing.expectEqual(fixture_cover_bytes, image.bytes.len);
    try testing.expectEqualStrings("image/png", image.mime_type);
    try testing.expectEqual(model.ArtworkKind.front_cover, image.kind);
}

test "a cover behind a leading ID3v2 tag is read from the stream, not from byte zero" {
    // The 104-file case: an ID3v2 tag stapled in front of a FLAC stream. Byte
    // zero is `ID3`, so a reader that assumes the container starts there finds
    // an MPEG file with no APIC frame and reports no cover.
    const image = (try readFixture("fixtures/audio/id3-covered-reference.flac")).?;
    defer image.deinit();
    try testing.expectEqual(fixture_cover_bytes, image.bytes.len);
    try testing.expectEqualStrings("image/png", image.mime_type);
}

test "a file with no embedded cover reports none rather than failing" {
    for ([_][]const u8{
        "fixtures/audio/generated-reference.flac",
        "fixtures/audio/tagged-reference.flac",
        "fixtures/audio/tagged-reference.mp3",
        "fixtures/audio/id3-prefixed-reference.flac",
        // A container with no picture reader at all.
        "fixtures/audio/generated-reference.wav",
    }) |path| {
        const image = try readFixture(path);
        if (image) |present| {
            present.deinit();
            std.debug.print("unexpected cover in {s}\n", .{path});
            return error.TestUnexpectedResult;
        }
    }
}

test "bytes that are not a recognised image are refused rather than handed on" {
    var memory = source.MemorySource{ .bytes = try garbagePicture(testing.allocator) };
    defer testing.allocator.free(memory.bytes);
    try testing.expectError(
        error.UnrecognizedArtworkImage,
        read(testing.allocator, memory.readable()),
    );
}

test "a picture larger than the bound is refused rather than allocated" {
    const declared: u32 = model.max_image_bytes + 1;
    const header = try oversizedPictureHeader(testing.allocator, declared);
    defer testing.allocator.free(header);
    // A file that really is large enough to hold what its block declares, so
    // nothing short-circuits the bound before it is reached.
    var large: SparseSource = .{ .prefix = header, .total = header.len + declared };

    // The allocator refuses everything, which is what proves the *order*: a
    // bound checked against the declaration answers `ArtworkTooLarge` without
    // asking for memory, where one checked after the read would have to ask
    // for 12 MiB first and would report `OutOfMemory` here instead.
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.ArtworkTooLarge,
        read(failing.allocator(), large.readable()),
    );
}

test "a picture block that declares more bytes than it holds is skipped" {
    const truncated = try truncatedPicture(testing.allocator);
    defer testing.allocator.free(truncated);
    var memory = source.MemorySource{ .bytes = truncated };
    try testing.expect(try read(testing.allocator, memory.readable()) == null);
}

/// How a synthetic PICTURE block should disagree with itself.
///
/// Every rejection tested here is such a disagreement, so the three lengths a
/// FLAC picture involves — what the block header states, what the picture
/// declares, and what is actually present — are separately settable.
const PictureFixture = struct {
    payload: []const u8 = "",
    /// The payload length the picture declares. Defaults to what is present.
    declared: ?u32 = null,
    /// The block length the metadata header states. Defaults to what the block
    /// actually holds.
    stated: ?u32 = null,
};

/// A minimal FLAC stream: STREAMINFO, then one front-cover PICTURE block.
fn flacWithPicture(allocator: std.mem.Allocator, fixture: PictureFixture) ![]u8 {
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(allocator);
    try appendBig(&block, allocator, 3); // front cover
    try appendBig(&block, allocator, @intCast("image/png".len));
    try block.appendSlice(allocator, "image/png");
    try appendBig(&block, allocator, 0); // empty description
    for (0..4) |_| try appendBig(&block, allocator, 0); // width, height, depth, colours
    try appendBig(&block, allocator, fixture.declared orelse @intCast(fixture.payload.len));
    try block.appendSlice(allocator, fixture.payload);
    const stated: u32 = fixture.stated orelse @intCast(block.items.len);

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "fLaC");
    // STREAMINFO: type 0, 34 bytes, contents irrelevant to a picture read.
    try bytes.appendSlice(allocator, &.{ 0, 0, 0, 34 });
    try bytes.appendNTimes(allocator, 0, 34);
    try bytes.append(allocator, 0x80 | 6);
    try bytes.appendSlice(allocator, &.{
        @intCast((stated >> 16) & 0xff),
        @intCast((stated >> 8) & 0xff),
        @intCast(stated & 0xff),
    });
    try bytes.appendSlice(allocator, block.items);
    return bytes.toOwnedSlice(allocator);
}

/// Bytes of a PICTURE block header with no payload, plus the length that block
/// would state if it did carry `declared` bytes.
fn oversizedPictureHeader(allocator: std.mem.Allocator, declared: u32) ![]u8 {
    const empty = try flacWithPicture(allocator, .{});
    const block_length: u32 = @intCast(empty.len - flac_metadata_prefix_bytes + declared);
    allocator.free(empty);
    return flacWithPicture(allocator, .{ .declared = declared, .stated = block_length });
}

/// `fLaC`, the STREAMINFO block, and the picture block's own four-byte header.
const flac_metadata_prefix_bytes: usize = 4 + 4 + 34 + 4;

fn appendBig(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .big);
    try list.appendSlice(allocator, &encoded);
}

fn garbagePicture(allocator: std.mem.Allocator) ![]u8 {
    return flacWithPicture(allocator, .{ .payload = "this is not an image at all" });
}

fn truncatedPicture(allocator: std.mem.Allocator) ![]u8 {
    return flacWithPicture(allocator, .{ .payload = "\x89PNG\r\n\x1a\n", .declared = 4096 });
}

/// A source that reports a large size while holding only a small prefix.
///
/// It exists so the size bound can be tested against a file that genuinely is
/// big enough to hold what it declares, without the test allocating megabytes
/// to prove that megabytes are refused. Reads past the prefix return zeros.
const SparseSource = struct {
    prefix: []const u8,
    total: usize,

    fn readable(self: *SparseSource) source.ReadableSource {
        return .{ .context = self, .vtable = &vtable };
    }

    fn readAt(context: *anyopaque, offset: u64, buffer: []u8) !usize {
        const self: *SparseSource = @ptrCast(@alignCast(context));
        if (offset >= self.total) return 0;
        const start: usize = @intCast(offset);
        const count = @min(buffer.len, self.total - start);
        @memset(buffer[0..count], 0);
        if (start < self.prefix.len) {
            const overlap = @min(count, self.prefix.len - start);
            @memcpy(buffer[0..overlap], self.prefix[start .. start + overlap]);
        }
        return count;
    }

    fn getSize(context: *anyopaque) u64 {
        const self: *SparseSource = @ptrCast(@alignCast(context));
        return self.total;
    }

    fn getIdentity(context: *anyopaque) source.StorageIdentity {
        const self: *SparseSource = @ptrCast(@alignCast(context));
        return .{ .inode = 0, .size = self.total, .modified_ns = 0 };
    }

    const vtable = source.ReadableSource.VTable{
        .read_at = readAt,
        .size = getSize,
        .identity = getIdentity,
    };
};
