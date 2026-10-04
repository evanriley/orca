const std = @import("std");
const metadata = @import("../metadata/root.zig");
const storage = @import("../storage/root.zig");

/// Canonical tags plus the arena their text lives in.
///
/// Readers allocate many short-lived intermediates, so ownership is one arena
/// per file rather than per string. The arena is heap-allocated so the result
/// can be returned by value without invalidating the allocator it hands out.
pub const Tags = struct {
    arena: *std.heap.ArenaAllocator,
    values: metadata.ObservedTags,

    pub fn deinit(self: Tags) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

/// Whether a sniffed format has a tag reader wired up yet. Formats Orca can
/// decode but not yet tag still scan; they simply observe no tags.
pub fn supports(audio_format: storage.AudioFormat) bool {
    return switch (audio_format) {
        .flac, .mp3, .aac, .mp4, .opus, .vorbis, .wav, .aiff => true,
        .wavpack, .qoa => false,
    };
}

/// Read canonical observed tags for one file, dispatching on its sniffed
/// container. Returns null when the format has no reader or the file carries no
/// tags at all — a normal outcome, not an error.
///
/// Format-specific concerns terminate below this call: nothing above it sees a
/// frame identifier, a comment key spelling, a text encoding, or a genre code.
pub fn read(
    allocator: std.mem.Allocator,
    audio_format: storage.AudioFormat,
    readable: storage.ReadableSource,
) !?Tags {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer arena.deinit();

    const parsed = try readValues(arena.allocator(), audio_format, readable);
    const values = parsed orelse {
        arena.deinit();
        allocator.destroy(arena);
        return null;
    };
    return .{ .arena = arena, .values = values };
}

fn readValues(
    allocator: std.mem.Allocator,
    audio_format: storage.AudioFormat,
    readable: storage.ReadableSource,
) !?metadata.ObservedTags {
    return switch (audio_format) {
        .flac => metadata.vorbis_comment.read(allocator, readable),
        .mp3, .aac => try readMpegTags(allocator, readable),
        .mp4 => metadata.mp4_tags.read(allocator, readable),
        .wav, .aiff => metadata.riff_tags.read(allocator, readable),
        .opus, .vorbis => metadata.ogg_comment.read(allocator, readable),
        else => null,
    };
}

/// ID3v2 is authoritative when it holds anything besides a cover; the 128-byte
/// ID3v1 trailer is only a fallback, because essentially every tagged MP3
/// written this century carries ID3v2 and many carry a stale v1 trailer
/// alongside it. An ID3v2 tag holding only a cover or a comment keeps them on
/// the trailer's values.
fn readMpegTags(
    allocator: std.mem.Allocator,
    readable: storage.ReadableSource,
) !?metadata.ObservedTags {
    const tagged = try metadata.id3v2.read(allocator, readable);
    if (tagged) |tags| {
        if (tags.hasValuesBesidesArtworkAndComment()) return tags;
    }
    var tags: metadata.ObservedTags = .{
        .artwork = if (tagged) |partial| partial.artwork else null,
        .comment = if (tagged) |partial| partial.comment else null,
    };
    var trailer: [128]u8 = undefined;
    if (try metadata.id3v1.read(readable, &trailer)) |legacy| {
        tags.title = try own(allocator, legacy.title);
        tags.artist = try own(allocator, legacy.artist);
        tags.album = try own(allocator, legacy.album);
        tags.date = try own(allocator, legacy.year);
        if (legacy.track_number) |number| {
            if (number != 0) tags.track_number = number;
        }
        if (metadata.id3v1.genreName(legacy.genre)) |name| {
            const genres = try allocator.alloc([]const u8, 1);
            genres[0] = name;
            tags.genres = genres;
        }
    }
    if (tags.isEmpty()) return null;
    return tags;
}

fn own(allocator: std.mem.Allocator, text: []const u8) !?[]const u8 {
    if (text.len == 0) return null;
    return try metadata.id3v1.latin1ToUtf8(allocator, text);
}

test "FLAC files are routed to the Vorbis comment reader" {
    var file = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/tagged-reference.flac",
    );
    defer file.close();
    const tags = (try read(std.testing.allocator, .flac, file.readable())).?;
    defer tags.deinit();

    try std.testing.expectEqualStrings("Reference Tone", tags.values.title.?);
    try std.testing.expectEqualStrings("Orca Test", tags.values.artist.?);
    try std.testing.expectEqualStrings("Fixtures", tags.values.album.?);
    try std.testing.expectEqualStrings("Orca Test", tags.values.album_artist.?);
    try std.testing.expectEqual(@as(?u32, 1), tags.values.track_number);
    try std.testing.expectEqual(@as(?u32, 3), tags.values.track_total);
    try std.testing.expectEqualStrings("2026", tags.values.date.?);
}

test "MP3 files are routed to ID3v2 ahead of the legacy trailer" {
    var file = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/tagged-reference.mp3",
    );
    defer file.close();
    const tags = (try read(std.testing.allocator, .mp3, file.readable())).?;
    defer tags.deinit();

    try std.testing.expectEqualStrings("Reference Tone", tags.values.title.?);
    try std.testing.expectEqualStrings("Orca Test", tags.values.artist.?);
    try std.testing.expectEqualStrings("Fixtures", tags.values.album.?);
    try std.testing.expectEqual(@as(?u32, 1), tags.values.track_number);
}

test "Ogg Opus and Ogg Vorbis files are routed to the Ogg comment reader" {
    inline for (.{
        .{ storage.AudioFormat.opus, "fixtures/audio/tagged-reference.opus", "Opus Reference" },
        .{ storage.AudioFormat.vorbis, "fixtures/audio/tagged-reference.ogg", "Reference Tone" },
    }) |case| {
        var file = try storage.LocalFileSource.open(std.testing.io, case[1]);
        defer file.close();
        const tags = (try read(std.testing.allocator, case[0], file.readable())).?;
        defer tags.deinit();
        try std.testing.expectEqualStrings(case[2], tags.values.title.?);
        try std.testing.expect(supports(case[0]));
    }
}

test "MP3 files without ID3v2 fall back to the ID3v1 trailer" {
    var bytes: [384]u8 = @splat(0);
    bytes[0] = 0xff;
    bytes[1] = 0xfb;
    const trailer = try metadata.id3v1.encode(.{
        .title = "Legacy title",
        .artist = "Legacy artist",
        .album = "Legacy album",
        .year = "1994",
        .comment = "",
        .track_number = 4,
        .genre = 9,
    });
    @memcpy(bytes[bytes.len - 128 ..], &trailer);

    var memory = storage.MemorySource{ .bytes = &bytes };
    const tags = (try read(std.testing.allocator, .mp3, memory.readable())).?;
    defer tags.deinit();

    try std.testing.expectEqualStrings("Legacy title", tags.values.title.?);
    try std.testing.expectEqualStrings("Legacy artist", tags.values.artist.?);
    try std.testing.expectEqual(@as(?u32, 4), tags.values.track_number);
    try std.testing.expectEqualStrings("1994", tags.values.date.?);
    try std.testing.expectEqualStrings("Metal", tags.values.genres[0]);
}

fn id3v23Frame(allocator: std.mem.Allocator, identifier: *const [4]u8, payload: []const u8) ![]u8 {
    const frame = try allocator.alloc(u8, 10 + payload.len);
    @memcpy(frame[0..4], identifier);
    std.mem.writeInt(u32, frame[4..8], @intCast(payload.len), .big);
    frame[8] = 0;
    frame[9] = 0;
    @memcpy(frame[10..], payload);
    return frame;
}

fn mpegStream(allocator: std.mem.Allocator, frames: []const []const u8, trailer: ?[128]u8) ![]u8 {
    const body = try std.mem.concat(allocator, u8, frames);
    var header: [10]u8 = .{ 'I', 'D', '3', 3, 0, 0, 0, 0, 0, 0 };
    const length: u32 = @intCast(body.len);
    header[6] = @intCast((length >> 21) & 0x7f);
    header[7] = @intCast((length >> 14) & 0x7f);
    header[8] = @intCast((length >> 7) & 0x7f);
    header[9] = @intCast(length & 0x7f);
    const legacy: []const u8 = if (trailer != null) &trailer.? else "";
    return std.mem.concat(allocator, u8, &.{ &header, body, "\xff\xfb\x90\x64audio", legacy });
}

fn frontCover(allocator: std.mem.Allocator) ![]u8 {
    return id3v23Frame(allocator, "APIC", "\x00image/png\x00\x03\x00" ++ "\x5a" ** 32);
}

fn songTrailer() ![128]u8 {
    return metadata.id3v1.encode(.{
        .title = "Song",
        .artist = "Band",
        .album = "Record",
        .year = "1999",
        .comment = "",
        .track_number = 3,
        .genre = 17,
    });
}

test "an MP3 whose ID3v2 tag holds only a cover reads the ID3v1 trailer's values and keeps the cover" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bytes = try mpegStream(allocator, &.{try frontCover(allocator)}, try songTrailer());

    var memory = storage.MemorySource{ .bytes = bytes };
    const tags = (try read(std.testing.allocator, .mp3, memory.readable())).?;
    defer tags.deinit();

    try std.testing.expectEqualStrings("Song", tags.values.title.?);
    try std.testing.expectEqualStrings("Band", tags.values.artist.?);
    try std.testing.expectEqualStrings("Record", tags.values.album.?);
    try std.testing.expectEqualStrings("1999", tags.values.date.?);
    try std.testing.expectEqual(@as(?u32, 3), tags.values.track_number);
    try std.testing.expectEqualStrings("Rock", tags.values.genres[0]);
    try std.testing.expectEqualStrings("image/png", tags.values.artwork.?.mime_type);
    try std.testing.expectEqual(@as(u64, 32), tags.values.artwork.?.byte_size);
    try std.testing.expectEqual(metadata.ArtworkKind.front_cover, tags.values.artwork.?.kind);
}

test "an MP3 whose ID3v2 tag holds only a comment and a cover reads the ID3v1 trailer's values and keeps both" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const comment = try id3v23Frame(allocator, "COMM", "\x00eng\x00Ripped from vinyl");
    const bytes = try mpegStream(allocator, &.{ try frontCover(allocator), comment }, try songTrailer());

    var memory = storage.MemorySource{ .bytes = bytes };
    const tags = (try read(std.testing.allocator, .mp3, memory.readable())).?;
    defer tags.deinit();

    try std.testing.expectEqualStrings("Song", tags.values.title.?);
    try std.testing.expectEqualStrings("Band", tags.values.artist.?);
    try std.testing.expectEqualStrings("Ripped from vinyl", tags.values.comment.?);
    try std.testing.expectEqual(@as(u64, 32), tags.values.artwork.?.byte_size);
}

test "an MP3 whose ID3v2 tag holds only a cover and no trailer observes the cover alone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bytes = try mpegStream(allocator, &.{try frontCover(allocator)}, null);

    var memory = storage.MemorySource{ .bytes = bytes };
    const tags = (try read(std.testing.allocator, .mp3, memory.readable())).?;
    defer tags.deinit();

    try std.testing.expect(tags.values.title == null);
    try std.testing.expect(!tags.values.hasValuesBesidesArtworkAndComment());
    try std.testing.expectEqual(@as(u64, 32), tags.values.artwork.?.byte_size);
}

test "an MP3 whose ID3v2 tag has a cover and any other value ignores the trailer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ufid = try id3v23Frame(allocator, "UFID", "http://musicbrainz.org\x008f3471b5-7e6a-48da-86a9-c1c07a0f5b4a");
    const title = try id3v23Frame(allocator, "TIT2", "\x00Tagged");
    for ([_][]const u8{ ufid, title }) |frame| {
        const bytes = try mpegStream(allocator, &.{ try frontCover(allocator), frame }, try songTrailer());
        var memory = storage.MemorySource{ .bytes = bytes };
        const tags = (try read(std.testing.allocator, .mp3, memory.readable())).?;
        defer tags.deinit();
        try std.testing.expect(tags.values.artist == null);
        try std.testing.expectEqual(@as(usize, 0), tags.values.genres.len);
        try std.testing.expectEqual(@as(u64, 32), tags.values.artwork.?.byte_size);
    }
}

test "untagged and unsupported files observe no tags rather than failing" {
    var file = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/generated-reference.flac",
    );
    defer file.close();
    const flac = try read(std.testing.allocator, .flac, file.readable());
    if (flac) |tags| {
        defer tags.deinit();
        try std.testing.expect(tags.values.title == null);
    }

    var wav = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/generated-reference.wav",
    );
    defer wav.close();
    try std.testing.expect(try read(std.testing.allocator, .wav, wav.readable()) == null);
    try std.testing.expect(!supports(.qoa));
    try std.testing.expect(supports(.flac) and supports(.mp3));
}
