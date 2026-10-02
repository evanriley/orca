//! Lyrics: the model every source produces, and the dispatch that reads the
//! lyrics embedded in one audio file.
//!
//! Lyrics are read on demand and never scanned: nothing here reaches
//! `ObservedTags` or the Library database. Frame layouts and comment keys stay
//! in the container readers; LRC timestamps stay in `lrc.zig`.

const std = @import("std");
const id3v2 = @import("id3v2.zig");
const lrc = @import("lrc.zig");
const mp4_tags = @import("mp4_tags.zig");
const ogg_comment = @import("ogg_comment.zig");
const vorbis_comment = @import("vorbis_comment.zig");
const format = @import("../storage/format.zig");
const source = @import("../storage/source.zig");

pub const Source = enum { sidecar, embedded, lrclib };

pub const Kind = enum { synced, plain, instrumental };

pub const Line = struct {
    /// Null for plain lyrics.
    start_ms: ?u32,
    text: []const u8,
};

/// A source whose text is larger than this, or that has more lines than
/// `max_lines`, is treated as having no lyrics.
pub const max_text_bytes: usize = 512 << 10;
pub const max_lines: usize = 4096;

/// Lines and language as a reader found them, allocated in an arena the
/// caller owns.
pub const Content = struct {
    kind: Kind,
    language: ?[3]u8 = null,
    lines: []const Line,
};

/// One track's lyrics, owning every line. Synced lines are in start order.
pub const Lyrics = struct {
    arena: *std.heap.ArenaAllocator,
    source: Source,
    kind: Kind,
    /// ISO 639-2 code, lower case, when the source names one.
    language: ?[3]u8,
    lines: []const Line,

    /// The last synced line starting at or before `position_ms`, or null
    /// before the first line and for lyrics that are not synced.
    pub fn lineAt(self: Lyrics, position_ms: u64) ?usize {
        if (self.kind != .synced) return null;
        var low: usize = 0;
        var high: usize = self.lines.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const start = self.lines[middle].start_ms orelse 0;
            if (start <= position_ms) low = middle + 1 else high = middle;
        }
        return if (low == 0) null else low - 1;
    }

    pub fn deinit(self: Lyrics) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

/// Stable, so lines sharing a start keep their order in the text.
pub fn sortLines(lines: []Line) void {
    std.mem.sort(Line, lines, {}, struct {
        fn lessThan(_: void, a: Line, b: Line) bool {
            return (a.start_ms orelse 0) < (b.start_ms orelse 0);
        }
    }.lessThan);
}

/// A three-letter language code from a tag, lower-cased; null for `XXX`, the
/// ID3v2 placeholder, and for anything that is not three letters.
pub fn languageCode(bytes: [3]u8) ?[3]u8 {
    var code: [3]u8 = undefined;
    for (bytes, &code) |byte, *out| {
        if (!std.ascii.isAlphabetic(byte)) return null;
        out.* = std.ascii.toLower(byte);
    }
    if (std.mem.eql(u8, &code, "xxx")) return null;
    return code;
}

/// Parse LRC or plain text from `origin` into owned lyrics, or null when it
/// carries none within the bounds.
pub fn parse(allocator: std.mem.Allocator, text: []const u8, origin: Source) !?Lyrics {
    const arena = try newArena(allocator);
    errdefer destroyArena(arena);
    const content = try lrc.parse(arena.allocator(), text) orelse {
        destroyArena(arena);
        return null;
    };
    return adopt(arena, content, origin);
}

pub fn instrumental(allocator: std.mem.Allocator, origin: Source) !Lyrics {
    return adopt(try newArena(allocator), .{ .kind = .instrumental, .lines = &.{} }, origin);
}

/// The lyrics embedded in one audio file, or null when it has none Orca can
/// read. A malformed or unreadable tag reads as none; only running out of
/// memory is an error.
pub fn readEmbedded(allocator: std.mem.Allocator, readable: source.ReadableSource) error{OutOfMemory}!?Lyrics {
    const detection = (format.detect(readable) catch return null) orelse return null;
    if (detection.payload_offset == 0) return readDetected(allocator, detection.format, readable);
    var view: source.OffsetSource = .{
        .inner = readable,
        .offset = detection.payload_offset,
    };
    return readDetected(allocator, detection.format, view.readable());
}

/// The same read for a caller that has already resolved the container and,
/// if there was one, the prefix in front of it.
pub fn readDetected(
    allocator: std.mem.Allocator,
    audio_format: format.AudioFormat,
    readable: source.ReadableSource,
) error{OutOfMemory}!?Lyrics {
    const arena = try newArena(allocator);
    errdefer destroyArena(arena);
    const output = arena.allocator();
    const found: ?Content = (switch (audio_format) {
        .flac => vorbis_comment.readLyrics(allocator, output, readable),
        .mp3, .aac => id3v2.readLyrics(allocator, output, readable),
        .mp4 => mp4_tags.readLyrics(allocator, output, readable),
        .opus, .vorbis => ogg_comment.readLyrics(allocator, output, readable),
        .wav, .aiff, .wavpack, .qoa => null,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    const content = found orelse {
        destroyArena(arena);
        return null;
    };
    return adopt(arena, content, .embedded);
}

fn adopt(arena: *std.heap.ArenaAllocator, content: Content, origin: Source) Lyrics {
    return .{
        .arena = arena,
        .source = origin,
        .kind = content.kind,
        .language = content.language,
        .lines = content.lines,
    };
}

fn newArena(allocator: std.mem.Allocator) !*std.heap.ArenaAllocator {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    return arena;
}

fn destroyArena(arena: *std.heap.ArenaAllocator) void {
    const child = arena.child_allocator;
    arena.deinit();
    child.destroy(arena);
}

const testing = std.testing;

fn synced(starts: []const u32) !Lyrics {
    const arena = try newArena(testing.allocator);
    const lines = try arena.allocator().alloc(Line, starts.len);
    for (starts, lines) |start, *line| line.* = .{ .start_ms = start, .text = "" };
    return adopt(arena, .{ .kind = .synced, .lines = lines }, .sidecar);
}

test "no line is current before the first line starts" {
    const lyrics = try synced(&.{ 1000, 2000 });
    defer lyrics.deinit();
    try testing.expectEqual(@as(?usize, null), lyrics.lineAt(999));
    try testing.expectEqual(@as(?usize, 0), lyrics.lineAt(1000));
}

test "the last line stays current after it starts" {
    const lyrics = try synced(&.{ 1000, 2000 });
    defer lyrics.deinit();
    try testing.expectEqual(@as(?usize, 1), lyrics.lineAt(2000));
    try testing.expectEqual(@as(?usize, 1), lyrics.lineAt(600_000));
}

test "of two lines sharing a start the later one is current" {
    const lyrics = try synced(&.{ 1000, 3000, 3000, 5000 });
    defer lyrics.deinit();
    try testing.expectEqual(@as(?usize, 2), lyrics.lineAt(3000));
    try testing.expectEqual(@as(?usize, 2), lyrics.lineAt(4999));
}

test "plain lyrics have no current line" {
    const lyrics = (try parse(testing.allocator, "one\ntwo\n", .sidecar)).?;
    defer lyrics.deinit();
    try testing.expectEqual(Kind.plain, lyrics.kind);
    try testing.expectEqual(@as(?usize, null), lyrics.lineAt(10_000));
}

test "a language code is three letters other than the placeholder" {
    try testing.expectEqualStrings("eng", &(languageCode("ENG".*).?));
    try testing.expectEqual(@as(?[3]u8, null), languageCode("XXX".*));
    try testing.expectEqual(@as(?[3]u8, null), languageCode("e\x00g".*));
}

test "embedded lyrics are read from each fixture container" {
    const Case = struct { path: []const u8, kind: Kind, first: []const u8 };
    const cases = [_]Case{
        .{ .path = "fixtures/audio/lyrics-synced.flac", .kind = .synced, .first = "First line of the FLAC" },
        .{ .path = "fixtures/audio/lyrics-sylt.mp3", .kind = .synced, .first = "First synced line" },
        .{ .path = "fixtures/audio/lyrics-plain.m4a", .kind = .plain, .first = "Plain first line" },
    };
    for (cases) |case| {
        var file = try source.LocalFileSource.open(testing.io, case.path);
        defer file.close();
        const lyrics = (try readEmbedded(testing.allocator, file.readable())).?;
        defer lyrics.deinit();
        try testing.expectEqual(Source.embedded, lyrics.source);
        try testing.expectEqual(case.kind, lyrics.kind);
        try testing.expectEqualStrings(case.first, lyrics.lines[0].text);
    }
}

test "a file without lyrics reads as none" {
    var file = try source.LocalFileSource.open(testing.io, "fixtures/audio/tagged-reference.flac");
    defer file.close();
    try testing.expect(try readEmbedded(testing.allocator, file.readable()) == null);
}

test "bytes that are no container read as none" {
    var memory = source.MemorySource{ .bytes = "not audio at all" };
    try testing.expect(try readEmbedded(testing.allocator, memory.readable()) == null);
}
