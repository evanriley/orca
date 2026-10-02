//! A Track's local lyrics: an `.lrc` sidecar beside its file, and the lyrics
//! embedded in the file, chosen in one order.
//!
//! The sidecar is found from the location path, so this is the only place a
//! path meets lyrics; the embedded readers see a `ReadableSource`.

const std = @import("std");
const builtin = @import("builtin");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/root.zig");
const storage = @import("../storage/root.zig");

const Lyrics = metadata.lyrics.Lyrics;

/// The Track's lyrics, or null when its file has none or it has no file:
/// synced before plain, and within each the sidecar before the file.
pub fn trackLyrics(
    allocator: std.mem.Allocator,
    io: std.Io,
    library_database: *database.LibraryDatabase,
    track_id: i64,
) !?Lyrics {
    const resolved = (try library_database.tracks.playableLocation(allocator, track_id)) orelse
        return null;
    defer resolved.deinit();
    return localLyrics(allocator, io, resolved.uri);
}

/// The same choice for the file at `path`.
pub fn localLyrics(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?Lyrics {
    const sidecar = try readSidecar(allocator, io, path);
    if (sidecar) |found| if (found.kind == .synced) return found;
    errdefer if (sidecar) |found| found.deinit();
    const embedded = try readEmbedded(allocator, io, path) orelse return sidecar;
    if (embedded.kind == .synced or sidecar == null) {
        if (sidecar) |plain| plain.deinit();
        return embedded;
    }
    embedded.deinit();
    return sidecar;
}

/// `path` with the extension of its last component replaced by `.lrc`, or
/// `.lrc` appended when it has none. Case is kept as it is.
pub fn sidecarPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const name_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| slash + 1 else 0;
    const stem_end = if (std.mem.lastIndexOfScalar(u8, path[name_start..], '.')) |dot|
        if (dot == 0) path.len else name_start + dot
    else
        path.len;
    return std.mem.concat(allocator, u8, &.{ path[0..stem_end], ".lrc" });
}

fn readSidecar(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?Lyrics {
    const lrc_path = try sidecarPath(allocator, path);
    defer allocator.free(lrc_path);
    const text = std.Io.Dir.cwd().readFileAlloc(
        io,
        lrc_path,
        allocator,
        .limited(metadata.lyrics.max_text_bytes + 1),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(text);
    return metadata.lyrics.parse(allocator, text, .sidecar);
}

fn readEmbedded(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?Lyrics {
    var local = storage.LocalFileSource.open(io, path) catch return null;
    defer local.close();
    return metadata.lyrics.readEmbedded(allocator, local.readable());
}

const testing = std.testing;

const Folder = struct {
    temporary: std.testing.TmpDir,
    prefix: []u8,

    fn init() !Folder {
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        const prefix = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
        return .{ .temporary = temporary, .prefix = prefix };
    }

    fn deinit(self: *Folder) void {
        testing.allocator.free(self.prefix);
        self.temporary.cleanup();
    }

    fn write(self: *Folder, name: []const u8, data: []const u8) !void {
        try self.temporary.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    }

    fn copyFixture(self: *Folder, fixture: []const u8, name: []const u8) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, fixture, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(bytes);
        try self.write(name, bytes);
    }

    fn lyricsFor(self: *Folder, name: []const u8) !?Lyrics {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ self.prefix, name });
        defer testing.allocator.free(path);
        return localLyrics(testing.allocator, testing.io, path);
    }
};

test "the sidecar replaces only the last component's extension" {
    const cases = [_][2][]const u8{
        .{ "a/b.flac", "a/b.lrc" },
        .{ "a.d/b", "a.d/b.lrc" },
        .{ "a/B.Song.MP3", "a/B.Song.lrc" },
        .{ "a/.hidden", "a/.hidden.lrc" },
    };
    for (cases) |case| {
        const path = try sidecarPath(testing.allocator, case[0]);
        defer testing.allocator.free(path);
        try testing.expectEqualStrings(case[1], path);
    }
}

test "a synced sidecar beside the file is read" {
    var folder = try Folder.init();
    defer folder.deinit();
    try folder.copyFixture("fixtures/audio/lyrics-synced.flac", "b.flac");
    try folder.write("b.lrc", "[00:00.50]From the sidecar\n");
    const lyrics = (try folder.lyricsFor("b.flac")).?;
    defer lyrics.deinit();
    try testing.expectEqual(metadata.lyrics.Source.sidecar, lyrics.source);
    try testing.expectEqualStrings("From the sidecar", lyrics.lines[0].text);
}

test "a plain sidecar gives way to synced embedded lyrics" {
    var folder = try Folder.init();
    defer folder.deinit();
    try folder.copyFixture("fixtures/audio/lyrics-synced.flac", "b.flac");
    try folder.write("b.lrc", "Plain sidecar words\n");
    const lyrics = (try folder.lyricsFor("b.flac")).?;
    defer lyrics.deinit();
    try testing.expectEqual(metadata.lyrics.Source.embedded, lyrics.source);
    try testing.expectEqual(metadata.lyrics.Kind.synced, lyrics.kind);
}

test "a plain sidecar outranks plain embedded lyrics" {
    var folder = try Folder.init();
    defer folder.deinit();
    try folder.copyFixture("fixtures/audio/lyrics-plain.m4a", "b.m4a");
    try folder.write("b.lrc", "Plain sidecar words\n");
    const lyrics = (try folder.lyricsFor("b.m4a")).?;
    defer lyrics.deinit();
    try testing.expectEqual(metadata.lyrics.Source.sidecar, lyrics.source);
}

test "a sidecar over the size bound is ignored" {
    var folder = try Folder.init();
    defer folder.deinit();
    try folder.copyFixture("fixtures/audio/tagged-reference.flac", "b.flac");
    const big = try testing.allocator.alloc(u8, metadata.lyrics.max_text_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    @memcpy(big[0..11], "[00:01.00]x");
    big[11] = '\n';
    try folder.write("b.lrc", big);
    try testing.expect(try folder.lyricsFor("b.flac") == null);
}

test "a sidecar that is not UTF-8 is ignored and embedded lyrics are used" {
    var folder = try Folder.init();
    defer folder.deinit();
    try folder.copyFixture("fixtures/audio/lyrics-plain.m4a", "b.m4a");
    try folder.write("b.lrc", "[00:01.00]caf\xe9\n");
    const lyrics = (try folder.lyricsFor("b.m4a")).?;
    defer lyrics.deinit();
    try testing.expectEqual(metadata.lyrics.Source.embedded, lyrics.source);
}

test "a sidecar whose name differs in case is not found" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var folder = try Folder.init();
    defer folder.deinit();
    try folder.copyFixture("fixtures/audio/tagged-reference.flac", "b.flac");
    try folder.write("B.LRC", "[00:01.00]Shouted\n");
    try testing.expect(try folder.lyricsFor("b.flac") == null);
}

test "a file that is gone has no lyrics" {
    var folder = try Folder.init();
    defer folder.deinit();
    try testing.expect(try folder.lyricsFor("missing.flac") == null);
}
