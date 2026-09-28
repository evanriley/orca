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
        .flac, .mp3, .mp4, .opus, .vorbis, .wav, .aiff => true,
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
        .mp3 => try readMpegTags(allocator, readable),
        .mp4 => metadata.mp4_tags.read(allocator, readable),
        .wav, .aiff => metadata.riff_tags.read(allocator, readable),
        .opus, .vorbis => metadata.ogg_comment.read(allocator, readable),
        else => null,
    };
}

/// ID3v2 is authoritative when present; the 128-byte ID3v1 trailer is only a
/// fallback, because essentially every tagged MP3 written this century carries
/// ID3v2 and many carry a stale v1 trailer alongside it.
fn readMpegTags(
    allocator: std.mem.Allocator,
    readable: storage.ReadableSource,
) !?metadata.ObservedTags {
    if (try metadata.id3v2.read(allocator, readable)) |tags| {
        if (!tags.isEmpty()) return tags;
    }
    var trailer: [128]u8 = undefined;
    const legacy = try metadata.id3v1.read(readable, &trailer) orelse return null;
    var tags: metadata.ObservedTags = .{};
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
