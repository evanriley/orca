//! Fuzz targets for every parser that reads untrusted bytes.
//!
//! `zig build test` replays each target's seeds; `zig build fuzz --fuzz`
//! mutates them. A returned error is a pass: only a panic, a leak or an
//! allocation no declared bound limits fails.

const std = @import("std");
const codec = @import("codec/root.zig");
const eq_text = @import("audio/eq_text.zig");
const m3u = @import("library/m3u.zig");
const smart_playlist = @import("library/smart_playlist.zig");
const metadata = @import("metadata/root.zig");
const storage = @import("storage/root.zig");

const max_input_bytes = 64 * 1024;
const max_allocation_bytes = storage.iso_bmff.max_movie_bytes;
const max_decoded_frames = 64 * 1024;

const id3v2_fixtures = [_][]const u8{
    "tagged-reference.mp3",
    "covered-reference.mp3",
    "id3-prefixed-reference.flac",
    "id3-footer-prefixed-reference.flac",
    "id3-covered-reference.flac",
    "lyrics-sylt.mp3",
    "explicit-reference.mp3",
};
const mp4_fixtures = [_][]const u8{
    "tagged-reference-alac.m4a",
    "tagged-reference-aac.m4a",
    "chirp-reference-aac.m4a",
    "covered-reference.m4a",
    "lyrics-plain.m4a",
    "explicit-reference.m4a",
};
const vorbis_comment_fixtures = [_][]const u8{
    "tagged-reference.flac",
    "covered-reference.flac",
    "covered-alternate-reference.flac",
    "generated-reference.flac",
    "midside-reference.flac",
    "lyrics-synced.flac",
    "tagged-reference.ogg",
    "covered-reference.ogg",
    "tagged-reference.opus",
    "covered-reference.opus",
};
const wav_fixtures = [_][]const u8{
    "tagged-reference.wav",
    "generated-reference.wav",
    "extensible-reference.wav",
    "id3-tagged-reference.wav",
};
const aiff_fixtures = [_][]const u8{
    "tagged-reference.aiff",
    "covered-reference.aiff",
    "generated-reference-24.aiff",
    "sowt-reference.aifc",
};
const adts_fixtures = [_][]const u8{"tagged-reference.aac"};
const mp3_stream_fixtures = [_][]const u8{
    "tagged-reference.mp3",
    "covered-reference.mp3",
    "cbr-noxing-reference.mp3",
    "vbr-xing-reference.mp3",
    "truncated-reference.mp3",
};
const scanner_fixtures = id3v2_fixtures ++ mp4_fixtures ++ vorbis_comment_fixtures ++ wav_fixtures ++
    aiff_fixtures ++ adts_fixtures ++ mp3_stream_fixtures;
const playlist_fixtures = [_][]const u8{ "relative.m3u8", "latin1.m3u", "bom.m3u8" };
const lrc_fixtures = [_][]const u8{"fingerprint-reference.lrc"};
const all_targets = [_][]const u8{ "id3v2", "mp4", "vorbis-comment", "wav", "aiff", "adts", "mp3-stream", "scanner", "lrc" };
const audio_fixture_dir = "fixtures/audio";

test "fuzz: ID3v2 tags parse or fail cleanly" {
    try fuzzTarget(exerciseId3v2, audio_fixture_dir, &id3v2_fixtures, &.{"id3v2"});
}

test "fuzz: MP4 boxes, tracks, decoders and tags parse or fail cleanly" {
    try fuzzTarget(exerciseMp4, audio_fixture_dir, &mp4_fixtures, &.{"mp4"});
}

test "fuzz: Vorbis comments in FLAC, Ogg and bare payloads parse or fail cleanly" {
    try fuzzTarget(exerciseVorbisComment, audio_fixture_dir, &vorbis_comment_fixtures, &.{"vorbis-comment"});
}

test "fuzz: WAV decoding and RIFF tags parse or fail cleanly" {
    try fuzzTarget(exerciseWav, audio_fixture_dir, &wav_fixtures, &.{"wav"});
}

test "fuzz: AIFF decoding and RIFF tags parse or fail cleanly" {
    try fuzzTarget(exerciseAiff, audio_fixture_dir, &aiff_fixtures, &.{"aiff"});
}

test "fuzz: ADTS frame tables parse or fail cleanly" {
    try fuzzTarget(exerciseAdts, audio_fixture_dir, &adts_fixtures, &.{"adts"});
}

test "fuzz: MP3 stream framing parses or fails cleanly" {
    try fuzzTarget(exerciseMp3Stream, audio_fixture_dir, &mp3_stream_fixtures, &.{"mp3-stream"});
}

test "fuzz: the scanner's detect, probe and artwork path parses or fails cleanly" {
    try fuzzTarget(exerciseScanner, audio_fixture_dir, &scanner_fixtures, &all_targets);
}

test "fuzz: M3U playlists parse and resolve or fail cleanly" {
    try fuzzTarget(exerciseM3u, "fixtures/playlists", &playlist_fixtures, &.{"m3u"});
}

test "fuzz: LRC lyrics parse or fail cleanly" {
    try fuzzTarget(exerciseLrc, audio_fixture_dir, &lrc_fixtures, &.{"lrc"});
}

test "fuzz: smart playlist rules parse and compile to bound parameters or fail cleanly" {
    try fuzzTarget(exerciseSmartPlaylist, "fixtures/fuzz", &.{}, &.{"smart-playlist"});
}

test "fuzz: EqualizerAPO text parses and writes back to the same filters or fails cleanly" {
    try fuzzTarget(exerciseEqApo, "fixtures/fuzz", &.{}, &.{"eq-apo"});
}

const Exercise = fn (allocator: std.mem.Allocator, input: []const u8) void;

fn fuzzTarget(
    comptime exercise: Exercise,
    fixture_dir: []const u8,
    fixtures: []const []const u8,
    seed_dirs: []const []const u8,
) !void {
    const corpus = try loadCorpus(std.testing.allocator, fixture_dir, fixtures, seed_dirs);
    defer {
        for (corpus) |seed| std.testing.allocator.free(seed);
        std.testing.allocator.free(corpus);
    }
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [max_input_bytes]u8 = undefined;
            const length = smith.slice(&input);
            var guarded: GuardedAllocator = .{ .inner = std.testing.allocator };
            exercise(guarded.allocator(), input[0..length]);
        }
    }.testOne, .{ .corpus = corpus });
}

fn loadCorpus(
    allocator: std.mem.Allocator,
    fixture_dir_path: []const u8,
    fixtures: []const []const u8,
    seed_dirs: []const []const u8,
) ![]const []const u8 {
    const io = std.testing.io;
    var corpus: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (corpus.items) |seed| allocator.free(seed);
        corpus.deinit(allocator);
    }
    var fixture_dir = try std.Io.Dir.cwd().openDir(io, fixture_dir_path, .{});
    defer fixture_dir.close(io);
    for (fixtures) |name| {
        const seed = try readSeed(allocator, fixture_dir, name);
        errdefer allocator.free(seed);
        try corpus.append(allocator, seed);
    }
    var fuzz_dir = std.Io.Dir.cwd().openDir(io, "fixtures/fuzz", .{}) catch |err| switch (err) {
        error.FileNotFound => return corpus.toOwnedSlice(allocator),
        else => return err,
    };
    defer fuzz_dir.close(io);
    for (seed_dirs) |dir_name| {
        var dir = fuzz_dir.openDir(io, dir_name, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        var entries = dir.iterate();
        while (try entries.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const seed = try readSeed(allocator, dir, entry.name);
            errdefer allocator.free(seed);
            try corpus.append(allocator, seed);
        }
    }
    return corpus.toOwnedSlice(allocator);
}

fn readSeed(allocator: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const bytes = try dir.readFileAlloc(std.testing.io, name, allocator, .limited(max_input_bytes + 1));
    defer allocator.free(bytes);
    const seed = try allocator.alloc(u8, 4 + bytes.len);
    std.mem.writeInt(u32, seed[0..4], @intCast(bytes.len), .little);
    @memcpy(seed[4..], bytes);
    return seed;
}

const GuardedAllocator = struct {
    inner: std.mem.Allocator,

    fn allocator(self: *GuardedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn check(len: usize) void {
        if (len > max_allocation_bytes)
            std.debug.panic("allocation of {d} bytes exceeds the {d}-byte bound", .{ len, max_allocation_bytes });
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *GuardedAllocator = @ptrCast(@alignCast(context));
        check(len);
        return self.inner.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *GuardedAllocator = @ptrCast(@alignCast(context));
        check(new_len);
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *GuardedAllocator = @ptrCast(@alignCast(context));
        check(new_len);
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *GuardedAllocator = @ptrCast(@alignCast(context));
        self.inner.rawFree(memory, alignment, ret_addr);
    }
};

fn ignore(result: anytype) void {
    _ = result catch return;
}

fn exerciseId3v2(allocator: std.mem.Allocator, input: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var memory: storage.MemorySource = .{ .bytes = input };
    const readable = memory.readable();
    ignore(metadata.id3v2.read(arena.allocator(), readable));
    ignore(metadata.id3v2.readPicture(arena.allocator(), readable));
    ignore(metadata.id3v2.prefixLength(readable));
    ignore(metadata.id3v2.readLyrics(allocator, arena.allocator(), readable));
}

fn exerciseMp4(allocator: std.mem.Allocator, input: []const u8) void {
    walkBoxes(input, 0);
    var memory: storage.MemorySource = .{ .bytes = input };
    const readable = memory.readable();
    if (codec.mp4.readTrack(allocator, readable)) |track| {
        var owned = track;
        defer owned.deinit();
        ignore(codec.mp4.probeTrack(&owned));
    } else |_| {}
    if (codec.mp4.openDecoder(allocator, readable)) |decoder| decodeSome(allocator, decoder) else |_| {}
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    ignore(metadata.mp4_tags.read(arena.allocator(), readable));
    ignore(metadata.mp4_tags.readPicture(arena.allocator(), readable));
    ignore(metadata.mp4_tags.readLyrics(allocator, arena.allocator(), readable));
}

fn walkBoxes(bytes: []const u8, depth: usize) void {
    if (depth == 8) return;
    var boxes = storage.iso_bmff.Iterator.init(bytes);
    while (boxes.next() catch return) |box| walkBoxes(box.body, depth + 1);
}

fn exerciseVorbisComment(allocator: std.mem.Allocator, input: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var memory: storage.MemorySource = .{ .bytes = input };
    const readable = memory.readable();
    ignore(metadata.vorbis_comment.parse(arena.allocator(), input));
    ignore(metadata.vorbis_comment.read(arena.allocator(), readable));
    ignore(metadata.vorbis_comment.readPicture(arena.allocator(), readable));
    ignore(metadata.ogg_comment.read(arena.allocator(), readable));
    ignore(metadata.ogg_comment.readPicture(arena.allocator(), readable));
    ignore(metadata.vorbis_comment.readLyrics(allocator, arena.allocator(), readable));
    ignore(metadata.ogg_comment.readLyrics(allocator, arena.allocator(), readable));
    ignore(metadata.vorbis_comment.lyricsFromComments(arena.allocator(), input));
}

fn exerciseWav(allocator: std.mem.Allocator, input: []const u8) void {
    var memory: storage.MemorySource = .{ .bytes = input };
    const readable = memory.readable();
    if (codec.wav.openDecoder(allocator, readable)) |decoder| decodeSome(allocator, decoder) else |_| {}
    readRiffTags(allocator, readable);
}

fn exerciseAiff(allocator: std.mem.Allocator, input: []const u8) void {
    var memory: storage.MemorySource = .{ .bytes = input };
    const readable = memory.readable();
    if (codec.aiff.openDecoder(allocator, readable)) |decoder| decodeSome(allocator, decoder) else |_| {}
    readRiffTags(allocator, readable);
}

fn readRiffTags(allocator: std.mem.Allocator, readable: storage.ReadableSource) void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    ignore(metadata.riff_tags.read(arena.allocator(), readable));
    ignore(metadata.riff_tags.readPicture(arena.allocator(), readable));
}

fn exerciseAdts(allocator: std.mem.Allocator, input: []const u8) void {
    var memory: storage.MemorySource = .{ .bytes = input };
    const readable = memory.readable();
    if (codec.adts.readTrack(allocator, readable)) |track| {
        var owned = track;
        owned.deinit();
    } else |_| {}
    ignore(codec.adts.probe(allocator, readable));
}

fn exerciseMp3Stream(allocator: std.mem.Allocator, input: []const u8) void {
    const mp3_stream = codec.mp3_stream;
    var memory: storage.MemorySource = .{ .bytes = input };
    const readable = memory.readable();
    if (mp3_stream.findFrame(readable, 0, input.len)) |located| {
        if (located.offset < input.len) _ = mp3_stream.parseVbrHeader(located.header, input[@intCast(located.offset)..]);
    } else |_| {}
    const info = mp3_stream.readStreamInfo(readable) catch return;
    var index: mp3_stream.FrameIndex = .init(info.audio_start);
    defer index.deinit(allocator);
    ignore(index.ensureCovers(allocator, readable, info.header, info.total_frames orelse std.math.maxInt(u64)));
    _ = index.lookup((info.total_frames orelse 0) / 2);
}

fn exerciseScanner(allocator: std.mem.Allocator, input: []const u8) void {
    var memory: storage.MemorySource = .{ .bytes = input };
    const readable = memory.readable();
    const detection = (storage.format.detect(readable) catch return) orelse return;
    const registry = codec.CodecRegistry.builtins();
    ignore(registry.probe(allocator, detection.format, readable));
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var payload: storage.OffsetSource = .{ .inner = readable, .offset = detection.payload_offset };
    ignore(metadata.artwork.readDetected(arena.allocator(), detection.format, payload.readable()));
    if (metadata.lyrics.readDetected(allocator, detection.format, payload.readable())) |found| {
        if (found) |lyrics| lyrics.deinit();
    } else |_| {}
}

fn exerciseLrc(allocator: std.mem.Allocator, input: []const u8) void {
    const lyrics = (metadata.lyrics.parse(allocator, input, .sidecar) catch return) orelse return;
    defer lyrics.deinit();
    _ = lyrics.lineAt(0);
    _ = lyrics.lineAt(std.math.maxInt(u32));
}

fn exerciseSmartPlaylist(allocator: std.mem.Allocator, input: []const u8) void {
    var rules = smart_playlist.parse(allocator, input) catch return;
    defer rules.deinit();
    var compiled = smart_playlist.compile(allocator, &rules, .{ .now = 1_700_000_000, .seed = 0x9e37_79b9_7f4a_7c15 }) catch return;
    defer compiled.deinit();
    const placeholders = std.mem.count(u8, compiled.predicate, "?");
    if (placeholders != compiled.values.len)
        std.debug.panic("predicate has {d} placeholders for {d} values", .{ placeholders, compiled.values.len });
    if (compiled.limit == 0 or compiled.limit > smart_playlist.max_limit)
        std.debug.panic("limit {d} is outside 1..{d}", .{ compiled.limit, smart_playlist.max_limit });
}

fn exerciseEqApo(_: std.mem.Allocator, input: []const u8) void {
    const parsed = eq_text.parseEqualizerApo(input) catch return;
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    eq_text.writeEqualizerApo(&writer, parsed) catch
        std.debug.panic("a valid equalizer took more than {d} bytes to write", .{buffer.len});
    const again = eq_text.parseEqualizerApo(writer.buffered()) catch |err|
        std.debug.panic("written text failed to parse: {s}", .{@errorName(err)});
    if (again.preamp_db != parsed.preamp_db or again.count != parsed.count)
        std.debug.panic("written text read back to a different preamp or filter count", .{});
    for (parsed.filterList(), again.filterList(), 1..) |before, after, position| {
        if (!std.meta.eql(before, after))
            std.debug.panic("filter {d} changed on the way through text", .{position});
    }
    const frequencies = [_]f32{ 20, 100, 1000, 10_000, 19_000, 22_000 };
    var gains_db: [frequencies.len]f32 = undefined;
    parsed.response(44_100, &frequencies, &gains_db);
    for (gains_db, frequencies) |gain_db, frequency_hz| {
        if (!std.math.isFinite(gain_db))
            std.debug.panic("response at {d} Hz is {d}", .{ frequency_hz, gain_db });
    }
}

fn exerciseM3u(allocator: std.mem.Allocator, input: []const u8) void {
    const parsed = m3u.parse(allocator, input) catch return;
    defer parsed.deinit(allocator);
    for (parsed.entries) |entry| {
        if (entry.info) |info| _ = m3u.splitArtistTitle(info.text);
        const location = m3u.resolve(allocator, "/music/lists", entry.location) catch continue;
        switch (location) {
            .path => |resolved| allocator.free(resolved),
            .unsupported => {},
        }
    }
}

fn decodeSome(allocator: std.mem.Allocator, opened: codec.Decoder) void {
    var decoder = opened;
    defer decoder.deinit();
    const channels: usize = decoder.format.channels;
    if (channels == 0) return;
    const frames_per_read = @max(1, 16 * 1024 / channels);
    const output = allocator.alloc(f32, frames_per_read * channels) catch return;
    defer allocator.free(output);
    var decoded: usize = 0;
    while (decoded < max_decoded_frames) {
        const read = decoder.readFrames(output) catch break;
        if (read == 0) break;
        decoded += read;
    }
    decoder.seek((decoder.frame_count orelse 0) / 2) catch return;
    _ = decoder.readFrames(output) catch return;
}
