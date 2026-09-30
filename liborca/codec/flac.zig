//! FLAC decoding, over libFLAC behind `flac_shim.c`.
//!
//! The reference implementation is used rather than a pure-Zig one because
//! FLAC's only promise is bit-exactness, which `files.audio_hash` and
//! fingerprints depend on. See `docs/codecs.md`.
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
extern fn orca_flac_decoder_seek(decoder: ?*anyopaque, frame: u64) i32;

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
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const capacity = output.len / context.channels;
    if (capacity == 0) return 0;
    var produced: u32 = 0;
    const status = orca_flac_decoder_read(
        context.native,
        output.ptr,
        @intCast(@min(capacity, std.math.maxInt(u32))),
        &produced,
    );
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
        end_of_stream => if (context.sought or reachedDeclaredEnd(context))
            return 0
        else
            return error.TruncatedFlac,
        else => return error.FlacDecodeFailed,
    }
}

fn seek(context_ptr: *anyopaque, frame: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (orca_flac_decoder_seek(context.native, frame) != ok) return error.FlacSeekFailed;
    context.sought = true;
    // Absolute, so the declared-total comparison survives a seek.
    context.frames_decoded = frame;
}

fn deinit(context_ptr: *anyopaque) void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const allocator = context.allocator;
    orca_flac_decoder_destroy(context.native);
    allocator.destroy(context);
}

const vtable: decoder_api.Decoder.VTable = .{
    .read_frames = readFrames,
    .seek = seek,
    .deinit = deinit,
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

test "a stream that stops inside its final block ends cleanly rather than failing" {
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
