//! FLAC decoding, over libFLAC behind `flac_shim.c`.
//!
//! The reference implementation is used rather than a pure-Zig one because
//! FLAC's only promise is bit-exactness, which `files.audio_hash` and
//! fingerprints depend on. See `docs/architecture.md`.
//!
//! Nothing about libFLAC is visible here: the shim exposes an opaque handle
//! driven by a positional read callback, so this file still sees only a
//! `ReadableSource` and hands back only the Orca `Decoder` interface.

const std = @import("std");
const decoder_api = @import("decoder.zig");
const storage = @import("../storage/root.zig");

const ok: i32 = 0;
const end_of_stream: i32 = 1;

extern fn orca_flac_decoder_create(
    context: ?*anyopaque,
    read: *const fn (?*anyopaque, u64, [*]u8, u64) callconv(.c) i64,
    size: u64,
    max_block_frames: u32,
    channels: u32,
) ?*anyopaque;
extern fn orca_flac_decoder_destroy(decoder: ?*anyopaque) void;
extern fn orca_flac_decoder_read(
    decoder: ?*anyopaque,
    output: [*]f32,
    output_frames: u32,
    frames_written: *u32,
) i32;
extern fn orca_flac_decoder_read_i32(
    decoder: ?*anyopaque,
    output: [*]i32,
    output_frames: u32,
    frames_written: *u32,
) i32;
extern fn orca_flac_decoder_seek(decoder: ?*anyopaque, frame: u64) i32;
extern fn orca_flac_decoder_stream_errors(decoder: ?*anyopaque) u64;
extern fn orca_flac_decoder_md5_mismatch(decoder: ?*anyopaque) i32;

const Context = struct {
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
    native: *anyopaque,
    channels: u16,
    /// Set once the stream has been seeked. See `readFrames` for why end of
    /// stream stops being reportable as damage after that point.
    sought: bool,
    /// Frames STREAMINFO declares the stream holds, or zero when it declines
    /// to say. This is the only thing that distinguishes "the audio ended and
    /// something else follows it" from "the audio is corrupt".
    declared_frames: u64,
    /// Absolute position in frames, maintained across seeks so it stays
    /// comparable with `declared_frames`.
    frames_decoded: u64,
    /// STREAMINFO's maximum block size, which bounds how much audio a single
    /// unreadable frame can account for.
    max_block_frames: u64,
    stream_errors_seen: u64 = 0,
    damage: ?decoder_api.Damage = null,

    fn recordDamage(self: *Context, found: decoder_api.Damage) void {
        if (self.damage == null) self.damage = found;
    }

    /// An error libFLAC recovered from is damage when audio followed it or the
    /// declared total was still owed; after the declared end it is a trailing
    /// tag or padding.
    fn judgeStreamErrors(self: *Context, frames_before: u64, produced: u32) void {
        const errors = orca_flac_decoder_stream_errors(self.native);
        if (errors == self.stream_errors_seen) return;
        self.stream_errors_seen = errors;
        if (produced > 0 or frames_before < self.declared_frames) self.recordDamage(error.FlacStreamErrors);
    }
};

pub fn openDecoder(
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
) !decoder_api.Decoder {
    const format = try readFormat(source);
    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .source = source,
        .native = undefined,
        .channels = format.channels,
        .sought = false,
        .declared_frames = format.frame_count,
        .frames_decoded = 0,
        .max_block_frames = format.max_block_frames,
    };
    context.native = orca_flac_decoder_create(
        context,
        readSource,
        source.size(),
        @intCast(format.max_block_frames),
        format.channels,
    ) orelse return error.InvalidFlac;
    return .{
        .context = context,
        .vtable = &vtable,
        .codec = decoder_api.codec_id.flac,
        .source_format = .{
            .sample_format = if (format.bits_per_sample <= 16)
                .signed_16
            else if (format.bits_per_sample <= 24)
                .signed_24
            else
                .signed_32,
            .channels = format.channels,
            .sample_rate = format.sample_rate,
            .bits_per_sample = format.bits_per_sample,
            .bytes_per_frame = try std.math.mul(
                u16,
                format.channels,
                (format.bits_per_sample + 7) / 8,
            ),
        },
        .format = .{
            .sample_format = .float_32,
            .channels = format.channels,
            .sample_rate = format.sample_rate,
            .bits_per_sample = 32,
            .bytes_per_frame = try std.math.mul(u16, format.channels, 4),
        },
        .frame_count = if (format.frame_count == 0) null else format.frame_count,
    };
}

const StreamFormat = struct {
    channels: u16,
    sample_rate: u32,
    bits_per_sample: u16,
    frame_count: u64,
    max_block_frames: u64 = 0,
};

fn readFormat(source: storage.ReadableSource) !StreamFormat {
    var header: [26]u8 = undefined;
    if (try source.readAt(0, &header) != header.len) return error.TruncatedFlac;
    if (!std.mem.eql(u8, header[0..4], "fLaC")) return error.InvalidFlac;
    if (header[4] & 0x7f != 0 or
        header[5] != 0 or header[6] != 0 or header[7] != 34)
        return error.InvalidFlac;
    // STREAMINFO: min_block(2) max_block(2) min_frame(3) max_frame(3), then the
    // packed 64 bits below. The maximum block size bounds how much audio one
    // unreadable frame can account for -- see `reachedDeclaredEnd`.
    const max_block_frames: u64 = (@as(u64, header[10]) << 8) | header[11];
    const stream_bits = big64(header[18..26]);
    const sample_rate: u32 = @intCast(stream_bits >> 44);
    const channels: u16 = @intCast(((stream_bits >> 41) & 0x7) + 1);
    const bits_per_sample = ((stream_bits >> 36) & 0x1f) + 1;
    if (sample_rate == 0 or bits_per_sample < 4) return error.InvalidFlac;
    return .{
        .channels = channels,
        .sample_rate = sample_rate,
        .bits_per_sample = @intCast(bits_per_sample),
        .frame_count = stream_bits & 0x0000000fffffffff,
        .max_block_frames = max_block_frames,
    };
}

fn big64(bytes: *const [8]u8) u64 {
    var value: u64 = 0;
    for (bytes) |byte| value = (value << 8) | byte;
    return value;
}

/// Positional read handed to the shim. The source owns no cursor, so libFLAC's
/// own byte position is the only cursor in play and it travels as `offset`.
fn readSource(
    opaque_context: ?*anyopaque,
    offset: u64,
    buffer: [*]u8,
    length: u64,
) callconv(.c) i64 {
    const context: *Context = @ptrCast(@alignCast(opaque_context.?));
    const wanted: usize = @intCast(@min(length, @as(u64, std.math.maxInt(usize))));
    const read = context.source.readAt(offset, buffer[0..wanted]) catch return -1;
    return @intCast(read);
}

/// Whether the stream has reached its declared end, give or take a final frame
/// that will not decode.
///
/// Real files end untidily: some stop short of what STREAMINFO declares,
/// inside their final block. `ffmpeg` resyncs and returns the audio anyway;
/// treating that as damage would fail analysis and end playback early.
///
/// A shortfall smaller than one maximum block is, by construction, at most the
/// final frame -- there is nowhere else for it to hide. Accepting that is
/// deliberately narrow: a file truncated by more than its last block still
/// errors, which is the case worth detecting, and a stream that declares no
/// total is not covered at all.
fn reachedDeclaredEnd(context: *const Context) bool {
    if (context.declared_frames == 0) return false;
    if (context.frames_decoded >= context.declared_frames) return true;
    const missing = context.declared_frames - context.frames_decoded;
    return missing < @max(context.max_block_frames, 1);
}

fn readFrames(context_ptr: *anyopaque, output: []f32) !usize {
    return readFramesAs(f32, orca_flac_decoder_read, context_ptr, output);
}

fn readFramesI32(context_ptr: *anyopaque, output: []i32) !usize {
    return readFramesAs(i32, orca_flac_decoder_read_i32, context_ptr, output);
}

fn readFramesAs(
    comptime Sample: type,
    comptime read: fn (?*anyopaque, [*]Sample, u32, *u32) callconv(.c) i32,
    context_ptr: *anyopaque,
    output: []Sample,
) !usize {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const capacity = output.len / context.channels;
    if (capacity == 0) return 0;
    var produced: u32 = 0;
    const frames_before = context.frames_decoded;
    const status = read(
        context.native,
        output.ptr,
        @intCast(@min(capacity, std.math.maxInt(u32))),
        &produced,
    );
    context.judgeStreamErrors(frames_before, produced);
    switch (status) {
        ok => {
            context.frames_decoded += produced;
            return produced;
        },
        // libFLAC ends a stream the same way whether the audio ran out where
        // it was supposed to or well before, so the distinction is drawn here
        // against STREAMINFO's declared total.
        //
        // After a seek there is no distinction to draw: the frames before the
        // seek target were never decoded, so the running count cannot reach
        // the declared total and every correct stream would look truncated.
        // Reporting that as a decode failure would end playback at the seek
        // point.
        //
        // The cost is that a truncated file seeked into ends quietly instead
        // of erroring. That is the right trade for playback, and the unsought
        // path -- every ordinary play from the beginning -- still detects it.
        //
        // A short final block and an MD5 mismatch end the stream cleanly so
        // playback is unaffected, and are reported through `damage`.
        end_of_stream => {
            if (context.sought) return 0;
            if (!reachedDeclaredEnd(context)) return context.damage orelse error.TruncatedFlac;
            if (context.frames_decoded < context.declared_frames) context.recordDamage(error.TruncatedFlac);
            if (orca_flac_decoder_md5_mismatch(context.native) != 0) context.recordDamage(error.FlacMd5Mismatch);
            return 0;
        },
        else => return error.FlacDecodeFailed,
    }
}

fn seek(context_ptr: *anyopaque, frame: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (orca_flac_decoder_seek(context.native, frame) != ok) return error.FlacSeekFailed;
    context.sought = true;
    // Absolute, so the declared-total comparison survives a seek.
    context.frames_decoded = frame;
    context.stream_errors_seen = orca_flac_decoder_stream_errors(context.native);
}

fn damage(context_ptr: *anyopaque) ?decoder_api.Damage {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    return context.damage;
}

fn deinit(context_ptr: *anyopaque) void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const allocator = context.allocator;
    orca_flac_decoder_destroy(context.native);
    allocator.destroy(context);
}

const vtable: decoder_api.Decoder.VTable = .{
    .read_frames = readFrames,
    .read_frames_i32 = readFramesI32,
    .seek = seek,
    .deinit = deinit,
    .damage = damage,
};

test "FLAC decoding reports stream facts and seeks generated audio" {
    var local = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/generated-reference.flac",
    );
    defer local.close();
    var decoder = try openDecoder(std.testing.allocator, local.readable());
    defer decoder.deinit();
    try std.testing.expectEqual(
        @import("../audio/pcm.zig").SampleFormat.signed_16,
        decoder.source_format.?.sample_format,
    );
    try std.testing.expectEqual(@as(u16, 2), decoder.format.channels);
    try std.testing.expectEqual(@as(u32, 48_000), decoder.format.sample_rate);
    try std.testing.expectEqual(@as(?u64, 480), decoder.frame_count);
    var samples: [64]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 32), try decoder.readFrames(&samples));
    try decoder.seek(0);
    try std.testing.expectEqual(@as(usize, 32), try decoder.readFrames(&samples));
}

test "malformed FLAC metadata fails before decoder allocation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "malformed.flac",
        .data = "fLaC\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
            "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
    });
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/malformed.flac",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(path);
    var local = try storage.LocalFileSource.open(std.testing.io, path);
    defer local.close();
    try std.testing.expectError(error.InvalidFlac, openDecoder(
        std.testing.allocator,
        local.readable(),
    ));
}

/// One frame of `fixtures/audio/midside-reference.flac`, regenerated rather
/// than read from a second fixture so the expectation cannot drift.
///
/// The two channels are near-opposites, which drives `mid` to a constant zero
/// and makes mid-side by far the cheapest stereo decorrelation for an encoder
/// to choose. `side` is `2 * amplitude - 1`, odd for every frame, and an odd
/// side is exactly the case whose discarded low bit has to be restored. Every
/// sample of this fixture therefore decodes wrongly if it is not.
fn midSideProbeSample(index: u32) [2]i16 {
    var state: u32 = index *% 2654435761 +% 1;
    state ^= state >> 13;
    state *%= 1274126177;
    state ^= state >> 16;
    const amplitude: i16 = @intCast(@as(i32, @intCast(state % 16000)) - 8000);
    return .{ amplitude, 1 - amplitude };
}

test "mid-side stereo decodes bit-exactly rather than one LSB low" {
    // Mid-side reconstruction must restore the low bit the encoder discarded,
    // `left = ((mid << 1 | side & 1) + side) >> 1`; every sample of this
    // fixture has an odd `side`.
    var local = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/midside-reference.flac",
    );
    defer local.close();
    var codec = try openDecoder(std.testing.allocator, local.readable());
    defer codec.deinit();

    const total = codec.frame_count orelse return error.MissingFrameCount;
    var scratch: [2048]f32 = undefined;
    var frame_index: u32 = 0;
    while (frame_index < total) {
        const frames = try codec.readFrames(&scratch);
        try std.testing.expect(frames > 0);
        for (0..frames) |offset| {
            const expected = midSideProbeSample(frame_index + @as(u32, @intCast(offset)));
            for (expected, 0..) |value, channel| {
                const decoded = scratch[offset * 2 + channel] * 32768.0;
                try std.testing.expectEqual(
                    @as(i32, value),
                    @as(i32, @intFromFloat(@round(decoded))),
                );
            }
        }
        frame_index += @intCast(frames);
    }
    try std.testing.expectEqual(@as(u32, @intCast(total)), frame_index);
}

fn hiresProbeSample(index: u32) [2]i32 {
    return .{
        @as(i32, @intCast((index *% 40961) % (1 << 24))) - (1 << 23),
        (1 << 23) - 1 - @as(i32, @intCast((index *% 2654435761) >> 8)),
    };
}

test "24-bit 192 kHz FLAC decodes to every sample exactly" {
    var local = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/hires-reference.flac",
    );
    defer local.close();
    var codec = try openDecoder(std.testing.allocator, local.readable());
    defer codec.deinit();

    const source_format = codec.source_format.?;
    try std.testing.expectEqual(@import("../audio/pcm.zig").SampleFormat.signed_24, source_format.sample_format);
    try std.testing.expectEqual(@as(u16, 24), source_format.bits_per_sample);
    try std.testing.expectEqual(@as(u32, 192_000), codec.format.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), codec.format.channels);
    try std.testing.expectEqual(@as(?u64, 4096), codec.frame_count);

    var scratch: [2048]f32 = undefined;
    var frame_index: u32 = 0;
    while (true) {
        const frames = try codec.readFrames(&scratch);
        if (frames == 0) break;
        for (0..frames) |offset| {
            const expected = hiresProbeSample(frame_index + @as(u32, @intCast(offset)));
            for (expected, 0..) |value, channel| {
                try std.testing.expectEqual(
                    @as(f32, @floatFromInt(value)) / (1 << 23),
                    scratch[offset * 2 + channel],
                );
            }
        }
        frame_index += @intCast(frames);
    }
    try std.testing.expectEqual(@as(u32, 4096), frame_index);
}

test "reading to the end after a seek reports end of input rather than failing" {
    // After a seek a stream ends having decoded fewer frames than STREAMINFO
    // declares; that must read as end of input, or the engine sees a decode
    // failure and never advances past the track.
    var local = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/generated-reference.flac",
    );
    defer local.close();

    var codec = try openDecoder(std.testing.allocator, local.readable());
    defer codec.deinit();

    const total = codec.frame_count orelse return error.MissingFrameCount;
    try std.testing.expect(total > 1);

    // Seek near the end, then drain. Every read must succeed, and the stream
    // must terminate by reporting zero frames.
    try codec.seek(total - 1);
    var scratch: [4096]f32 = undefined;
    var guard: usize = 0;
    while (guard < 64) : (guard += 1) {
        const frames = try codec.readFrames(&scratch);
        if (frames == 0) break;
    }
    try std.testing.expect(guard < 64);

    // Further reads at the end stay clean rather than erroring.
    try std.testing.expectEqual(@as(usize, 0), try codec.readFrames(&scratch));
}

test "a truncated stream seeked into ends cleanly rather than reporting damage" {
    // The other half of the same contract, and the half that is only reachable
    // once a stream has been seeked. Frames before a seek target are never
    // decoded, so the running count cannot reach the declared total and a
    // shortfall says nothing about damage any more. The `Decoder` contract has
    // no way to report "ended early but intact", and a caller that treats the
    // end of a sought track as a decode failure stalls the queue.
    var local = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/tagged-reference.flac",
    );
    const readable = local.readable();
    const bytes = try std.testing.allocator.alloc(u8, @intCast(readable.size()));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(bytes.len, try readable.readAt(0, bytes));
    local.close();

    // Far more than any block size: unsought, this same stream is an error.
    declareExtraFrames(bytes, 1_000_000);
    var source: storage.MemorySource = .{ .bytes = bytes };
    var codec = try openDecoder(std.testing.allocator, source.readable());
    defer codec.deinit();

    try codec.seek(1);
    var scratch: [4096]f32 = undefined;
    var guard: usize = 0;
    while (guard < 4096) : (guard += 1) {
        if (try codec.readFrames(&scratch) == 0) break;
    }
    try std.testing.expect(guard < 4096);
}

/// Rewrites STREAMINFO's declared total so a decode ends short by `shortfall`
/// frames, which is how a real file that stops inside its last block behaves.
fn declareExtraFrames(bytes: []u8, shortfall: u64) void {
    const packed_bits = big64(bytes[18..26]);
    const declared = packed_bits & 0x0000000fffffffff;
    const inflated = (packed_bits & ~@as(u64, 0x0000000fffffffff)) |
        ((declared + shortfall) & 0x0000000fffffffff);
    for (0..8) |index| {
        bytes[18 + index] = @truncate(inflated >> @intCast(8 * (7 - index)));
    }
}

test "a stream that stops inside its final block ends cleanly and reports it as truncated" {
    // Real files can stop short of what STREAMINFO declares, inside their
    // final block. ffmpeg resyncs and returns the audio; treating it as damage
    // would fail analysis and end playback early.
    var local = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/tagged-reference.flac",
    );
    const readable = local.readable();
    const bytes = try std.testing.allocator.alloc(u8, @intCast(readable.size()));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(bytes.len, try readable.readAt(0, bytes));
    local.close();

    // One frame's worth of audio that the file does not actually contain.
    declareExtraFrames(bytes, 1);
    var source: storage.MemorySource = .{ .bytes = bytes };
    var codec = try openDecoder(std.testing.allocator, source.readable());
    defer codec.deinit();

    var scratch: [4096]f32 = undefined;
    var guard: usize = 0;
    while (guard < 4096) : (guard += 1) {
        if (try codec.readFrames(&scratch) == 0) break;
    }
    try std.testing.expect(guard < 4096);
    try std.testing.expectEqual(@as(?decoder_api.Damage, error.TruncatedFlac), codec.damage());
}

test "a stream missing more than its final block is still reported as damaged" {
    // The narrowness is the point: accepting a shortfall of at most one block
    // keeps the case worth detecting -- a genuinely truncated file -- an error.
    var local = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/tagged-reference.flac",
    );
    const readable = local.readable();
    const bytes = try std.testing.allocator.alloc(u8, @intCast(readable.size()));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(bytes.len, try readable.readAt(0, bytes));
    local.close();

    // Far more than any block size, so the shortfall cannot be a last frame.
    declareExtraFrames(bytes, 1_000_000);
    var source: storage.MemorySource = .{ .bytes = bytes };
    var codec = try openDecoder(std.testing.allocator, source.readable());
    defer codec.deinit();

    var scratch: [4096]f32 = undefined;
    var guard: usize = 0;
    const outcome = while (guard < 4096) : (guard += 1) {
        const frames = codec.readFrames(&scratch) catch |err| break err;
        if (frames == 0) break error.EndedCleanly;
    } else error.NeverEnded;
    try std.testing.expect(outcome != error.EndedCleanly);
    try std.testing.expect(outcome != error.NeverEnded);
}

fn readFixture(path: []const u8) ![]u8 {
    var local = try storage.LocalFileSource.open(std.testing.io, path);
    defer local.close();
    const readable = local.readable();
    const bytes = try std.testing.allocator.alloc(u8, @intCast(readable.size()));
    errdefer std.testing.allocator.free(bytes);
    if (try readable.readAt(0, bytes) != bytes.len) return error.ShortFixtureRead;
    return bytes;
}

fn decodeToEnd(codec: decoder_api.Decoder) !u64 {
    var scratch: [4096]f32 = undefined;
    var frames: u64 = 0;
    var guard: usize = 0;
    while (guard < 4096) : (guard += 1) {
        const read = try codec.readFrames(&scratch);
        if (read == 0) return frames;
        frames += read;
    }
    return error.NeverEnded;
}

fn audioOffset(bytes: []const u8) usize {
    var offset: usize = 4;
    while (true) {
        const last = bytes[offset] & 0x80 != 0;
        offset += 4 + std.mem.readInt(u24, bytes[offset + 1 ..][0..3], .big);
        if (last) return offset;
    }
}

test "a clean stream decoded to its end reports no damage" {
    for ([_][]const u8{
        "fixtures/audio/generated-reference.flac",
        "fixtures/audio/tagged-reference.flac",
        "fixtures/audio/midside-reference.flac",
        "fixtures/audio/covered-reference.flac",
        "fixtures/audio/lyrics-synced.flac",
        "fixtures/audio/id3-prefixed-reference.flac",
        "fixtures/audio/id3-footer-prefixed-reference.flac",
        "fixtures/audio/id3-covered-reference.flac",
    }) |path| {
        const bytes = try readFixture(path);
        defer std.testing.allocator.free(bytes);
        var source: storage.MemorySource = .{ .bytes = bytes };
        var codec = try @import("registry.zig").CodecRegistry.builtins().openDetected(std.testing.allocator, source.readable());
        defer codec.deinit();
        try std.testing.expectEqual(codec.frame_count.?, try decodeToEnd(codec));
        try std.testing.expectEqual(@as(?decoder_api.Damage, null), codec.damage());
    }
}

test "a stream whose audio disagrees with its MD5 signature plays in full and reports the mismatch" {
    const bytes = try readFixture("fixtures/audio/tagged-reference.flac");
    defer std.testing.allocator.free(bytes);
    bytes[26] ^= 0xff;
    var source: storage.MemorySource = .{ .bytes = bytes };
    var codec = try openDecoder(std.testing.allocator, source.readable());
    defer codec.deinit();
    try std.testing.expectEqual(codec.frame_count.?, try decodeToEnd(codec));
    try std.testing.expectEqual(@as(?decoder_api.Damage, error.FlacMd5Mismatch), codec.damage());
}

test "a stream with no MD5 signature reports no damage" {
    const bytes = try readFixture("fixtures/audio/tagged-reference.flac");
    defer std.testing.allocator.free(bytes);
    @memset(bytes[26..42], 0);
    var source: storage.MemorySource = .{ .bytes = bytes };
    var codec = try openDecoder(std.testing.allocator, source.readable());
    defer codec.deinit();
    try std.testing.expectEqual(codec.frame_count.?, try decodeToEnd(codec));
    try std.testing.expectEqual(@as(?decoder_api.Damage, null), codec.damage());
}

test "a sought stream with a wrong MD5 signature reports no damage" {
    const bytes = try readFixture("fixtures/audio/tagged-reference.flac");
    defer std.testing.allocator.free(bytes);
    bytes[26] ^= 0xff;
    var source: storage.MemorySource = .{ .bytes = bytes };
    var codec = try openDecoder(std.testing.allocator, source.readable());
    defer codec.deinit();
    try codec.seek(0);
    try std.testing.expectEqual(codec.frame_count.?, try decodeToEnd(codec));
    try std.testing.expectEqual(@as(?decoder_api.Damage, null), codec.damage());
}

test "a stream decoded to its end can be sought and decoded again" {
    const bytes = try readFixture("fixtures/audio/tagged-reference.flac");
    defer std.testing.allocator.free(bytes);
    var source: storage.MemorySource = .{ .bytes = bytes };
    var codec = try openDecoder(std.testing.allocator, source.readable());
    defer codec.deinit();
    const total = codec.frame_count.?;
    try std.testing.expectEqual(total, try decodeToEnd(codec));
    try codec.seek(100);
    try std.testing.expectEqual(total - 100, try decodeToEnd(codec));
}

test "a final frame failing its CRC ends cleanly and is reported as stream errors" {
    const bytes = try readFixture("fixtures/audio/tagged-reference.flac");
    defer std.testing.allocator.free(bytes);
    bytes[bytes.len - 1] ^= 0xff;
    var source: storage.MemorySource = .{ .bytes = bytes };
    var codec = try openDecoder(std.testing.allocator, source.readable());
    defer codec.deinit();
    try std.testing.expect(try decodeToEnd(codec) > 0);
    try std.testing.expectEqual(@as(?decoder_api.Damage, error.FlacStreamErrors), codec.damage());
}

test "a first frame failing its CRC plays the frames after it and fails naming stream errors" {
    const bytes = try readFixture("fixtures/audio/tagged-reference.flac");
    defer std.testing.allocator.free(bytes);
    const audio = audioOffset(bytes);
    const second_frame = std.mem.indexOfPos(u8, bytes, audio + 2, "\xff\xf8").?;
    bytes[second_frame - 1] ^= 0xff;
    var source: storage.MemorySource = .{ .bytes = bytes };
    var codec = try openDecoder(std.testing.allocator, source.readable());
    defer codec.deinit();
    var scratch: [4096]f32 = undefined;
    var frames: u64 = 0;
    var guard: usize = 0;
    const outcome = while (guard < 4096) : (guard += 1) {
        const read = codec.readFrames(&scratch) catch |err| break err;
        if (read == 0) break error.EndedCleanly;
        frames += read;
    } else error.NeverEnded;
    try std.testing.expectEqual(@as(anyerror, error.FlacStreamErrors), outcome);
    const first_block_frames = std.mem.readInt(u16, bytes[10..12], .big);
    try std.testing.expectEqual(codec.frame_count.? - first_block_frames, frames);
}
