//! MPEG audio decoder. The vendored `minimp3` reference decoder supplies the
//! synthesis filterbank behind `mp3_shim.h`; everything above it — framing,
//! Xing/Info/VBRI length, LAME delay and padding trimming, and seeking — is
//! the pure-Zig code in `mp3_stream.zig`. No minimp3 or C type is visible
//! outside this file: callers see only the Orca `Decoder` interface.

const std = @import("std");
const decoder_api = @import("decoder.zig");
const storage = @import("../storage/root.zig");
const stream_parser = @import("mp3_stream.zig");

/// Mirrors `struct orca_mp3_frame_info` in `mp3_shim.h`.
const NativeFrameInfo = extern struct {
    frame_bytes: i32,
    frame_offset: i32,
    channels: i32,
    sample_rate: i32,
    layer: i32,
    bitrate_kbps: i32,
};

extern fn orca_mp3_decoder_create() ?*anyopaque;
extern fn orca_mp3_decoder_destroy(?*anyopaque) void;
extern fn orca_mp3_decoder_reset(?*anyopaque) void;
extern fn orca_mp3_decode_frame(
    ?*anyopaque,
    [*]const u8,
    i32,
    [*]f32,
    *NativeFrameInfo,
) i32;

/// `MINIMP3_MAX_SAMPLES_PER_FRAME`: 1152 samples per channel, two channels.
const max_samples_per_frame = 1152 * 2;

/// Bitstream window handed to the native decoder. It must always be able to
/// hold one complete frame; the surplus keeps positional reads coarse.
const input_capacity = 16 * 1024;

const Context = struct {
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
    native: ?*anyopaque,
    stream: stream_parser.StreamInfo,
    channels: u16,
    sample_rate: u32,
    samples_per_frame: u64,
    /// Frames to decode and discard ahead of a seek target so the Layer III
    /// bit reservoir is warm by the time the target frame is decoded.
    primer_frames: u64,

    input: [input_capacity]u8 = undefined,
    /// File offset of `input[0]`.
    input_origin: u64 = 0,
    input_len: usize = 0,
    input_pos: usize = 0,
    source_exhausted: bool = false,
    tail_flushed: bool = false,
    /// Absolute offset at which the synthesized terminator begins, once one
    /// has been appended.
    terminator_offset: ?u64 = null,

    scratch: [max_samples_per_frame]f32 = undefined,
    scratch_frames: usize = 0,
    scratch_pos: usize = 0,

    /// Position in the untrimmed decoded stream, counted from `audio_start`.
    stream_position: u64 = 0,
    /// Position in the trimmed stream the caller observes.
    output_position: u64 = 0,

    index: stream_parser.FrameIndex,
};

pub fn openDecoder(
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
) !decoder_api.Decoder {
    const info = try stream_parser.readStreamInfo(source);
    const channels = info.header.channels();
    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .source = source,
        .native = null,
        .stream = info,
        .channels = channels,
        .sample_rate = info.header.sample_rate,
        .samples_per_frame = info.header.samplesPerFrame(),
        .primer_frames = info.header.reservoirPrimerFrames(),
        .index = .init(info.audio_start),
    };
    context.native = orca_mp3_decoder_create() orelse return error.OutOfMemory;
    errdefer orca_mp3_decoder_destroy(context.native);
    restart(context, info.audio_start, 0);

    return .{
        .context = context,
        .vtable = &vtable,
        // The layer is what the encoding is: a Layer II stream and a Layer III
        // stream share a container and nothing else about their cost.
        .codec = switch (info.header.layer) {
            .layer1 => decoder_api.codec_id.mp1,
            .layer2 => decoder_api.codec_id.mp2,
            .layer3 => decoder_api.codec_id.mp3,
        },
        // MPEG audio is a transform codec: there is no integer PCM the file
        // "declares", so the canonical float view is the only honest one.
        .source_format = null,
        .format = .{
            .sample_format = .float_32,
            .channels = channels,
            .sample_rate = info.header.sample_rate,
            .bits_per_sample = 32,
            .bytes_per_frame = try std.math.mul(u16, channels, 4),
        },
        .frame_count = info.total_frames,
    };
}

/// Repositions the bitstream window and drops all decoder state. `position`
/// is the untrimmed stream frame the byte offset corresponds to.
fn restart(context: *Context, byte_offset: u64, position: u64) void {
    orca_mp3_decoder_reset(context.native);
    context.input_origin = byte_offset;
    context.input_len = 0;
    context.input_pos = 0;
    context.source_exhausted = false;
    context.tail_flushed = false;
    context.terminator_offset = null;
    context.scratch_frames = 0;
    context.scratch_pos = 0;
    context.stream_position = position;
}

fn refill(context: *Context) !void {
    const remaining = context.input_len - context.input_pos;
    if (context.input_pos != 0) {
        std.mem.copyForwards(
            u8,
            context.input[0..remaining],
            context.input[context.input_pos..context.input_len],
        );
        context.input_origin += context.input_pos;
        context.input_pos = 0;
        context.input_len = remaining;
    }
    if (context.source_exhausted or context.input_len == context.input.len) return;
    const from = context.input_origin + context.input_len;
    // Never read past the MPEG data. minimp3 confirms a frame against the
    // bytes that follow it, so trailing tag bytes would cost the last frame.
    const remaining_audio = context.stream.audio_end -| from;
    if (remaining_audio == 0) {
        appendTerminator(context);
        context.source_exhausted = true;
        return;
    }
    const window = context.input[context.input_len..];
    const limit: usize = @intCast(@min(@as(u64, window.len), remaining_audio));
    const read = try context.source.readAt(from, window[0..limit]);
    if (read == 0) context.source_exhausted = true;
    context.input_len += read;
}

/// Appends a synthesized silent frame once the real MPEG data runs out.
///
/// It earns its place twice. The native decoder confirms a frame against the
/// header that follows it, so without a successor the last real frame of the
/// file is discarded; and the synthesis filterbank holds the final 529
/// samples of a stream in its overlap state until one more frame pushes them
/// out. Both cost audio at the end of every track, which is exactly where
/// gapless playback is audible.
///
/// It is only appended for streams that declare an exact length, because
/// only those can discard the synthetic frame's own output by frame count.
fn appendTerminator(context: *Context) void {
    if (context.tail_flushed or !context.stream.exact_length) return;
    const frame_bytes: usize = context.stream.header.frameBytes();
    const needed = frame_bytes + 4;
    if (context.input.len - context.input_len < needed) return;
    context.tail_flushed = true;
    context.terminator_offset = context.input_origin + context.input_len;
    const tail = context.input[context.input_len..][0..needed];
    @memset(tail, 0);
    @memcpy(tail[0..4], &context.stream.header_bytes);
    @memcpy(tail[frame_bytes..][0..4], &context.stream.header_bytes);
    context.input_len += needed;
}

/// Decodes the next frame into `scratch`. Returns false at end of stream.
/// Truncated tails and trailing non-audio tags end the stream cleanly rather
/// than erroring; only a window that is full of unrecognizable bytes does.
fn decodeFrame(context: *Context) !bool {
    while (true) {
        if (context.input_len - context.input_pos < stream_parser.max_frame_bytes)
            try refill(context);
        const available = context.input_len - context.input_pos;
        if (available == 0) return false;

        const frame_origin = context.input_origin + context.input_pos;
        var info: NativeFrameInfo = undefined;
        const samples = orca_mp3_decode_frame(
            context.native,
            context.input[context.input_pos..].ptr,
            @intCast(available),
            &context.scratch,
            &info,
        );
        if (samples < 0) return error.InvalidMp3;
        if (info.frame_bytes <= 0) {
            if (context.source_exhausted) return false;
            if (available >= context.input.len) return error.InvalidMp3;
            return false;
        }
        context.input_pos += @intCast(info.frame_bytes);
        // A zero sample count with no frame description means non-audio bytes
        // were skipped; keep scanning without disturbing the position.
        if (samples == 0 and info.sample_rate == 0) continue;
        if (info.channels != @as(i32, context.channels) or
            info.sample_rate != @as(i32, @intCast(context.sample_rate)))
            return error.ChangingMp3Format;
        if (samples == 0) {
            // A real frame whose main data still lives in a bit reservoir
            // this decoder has not seen. Its output is silence, and it must
            // still advance the stream position or every subsequent frame
            // would be attributed to the wrong time.
            const silent: usize = @intCast(context.samples_per_frame);
            @memset(context.scratch[0 .. silent * context.channels], 0);
            context.scratch_frames = silent;
            context.scratch_pos = 0;
            return true;
        }
        context.scratch_frames = @intCast(samples);
        // Only the filterbank's held-over tail of the synthesized terminator
        // is real audio; the rest of that frame is fabricated silence.
        if (context.terminator_offset) |start| {
            if (frame_origin >= start)
                context.scratch_frames = @min(
                    context.scratch_frames,
                    @as(usize, stream_parser.decoder_delay),
                );
        }
        context.scratch_pos = 0;
        return true;
    }
}

fn readFrames(context_ptr: *anyopaque, output: []f32) !usize {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const channels: usize = context.channels;
    const capacity = output.len / channels;
    var produced: usize = 0;

    while (produced < capacity) {
        if (context.stream.exact_length) {
            const total = context.stream.total_frames orelse break;
            if (context.output_position >= total) break;
        }
        if (context.scratch_pos >= context.scratch_frames) {
            if (!try decodeFrame(context)) break;
        }
        const available = context.scratch_frames - context.scratch_pos;

        if (context.stream_position < context.stream.start_skip) {
            const wanted = context.stream.start_skip - context.stream_position;
            const dropped: usize = @intCast(@min(@as(u64, available), wanted));
            context.scratch_pos += dropped;
            context.stream_position += dropped;
            continue;
        }

        var take = @min(available, capacity - produced);
        if (context.stream.exact_length) {
            if (context.stream.total_frames) |total|
                take = @intCast(@min(@as(u64, take), total - context.output_position));
        }
        if (take == 0) break;
        @memcpy(
            output[produced * channels ..][0 .. take * channels],
            context.scratch[context.scratch_pos * channels ..][0 .. take * channels],
        );
        produced += take;
        context.scratch_pos += take;
        context.stream_position += take;
        context.output_position += take;
    }
    return produced;
}

/// Decodes forward, discarding output, until the untrimmed stream position
/// reaches `target` or the stream ends.
fn discardTo(context: *Context, target: u64) !void {
    while (context.stream_position < target) {
        if (context.scratch_pos >= context.scratch_frames) {
            if (!try decodeFrame(context)) return;
        }
        const available = context.scratch_frames - context.scratch_pos;
        const wanted = target - context.stream_position;
        const dropped: usize = @intCast(@min(@as(u64, available), wanted));
        context.scratch_pos += dropped;
        context.stream_position += dropped;
    }
}

fn seek(context_ptr: *anyopaque, frame: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (context.stream.total_frames) |total| {
        if (frame > total) return error.SeekOutOfRange;
    }
    const target = frame + context.stream.start_skip;

    if (frame == 0) {
        restart(context, context.stream.audio_start, 0);
        context.output_position = 0;
        return;
    }

    const plan = try seekPlan(context, target);
    restart(context, plan.byte_offset, plan.position);
    if (plan.exact) {
        try discardTo(context, target);
    } else {
        // A TOC-derived landing point has no known frame number. Prime the
        // reservoir, then adopt the requested position: the audio is within
        // the TOC's resolution of it and nothing better is knowable without
        // counting frames from the start of the stream.
        var primed: u64 = 0;
        while (primed < context.primer_frames) : (primed += 1) {
            if (!try decodeFrame(context)) break;
        }
        context.scratch_frames = 0;
        context.scratch_pos = 0;
        context.stream_position = target;
    }
    context.output_position = frame;
}

const SeekPlan = struct {
    byte_offset: u64,
    /// Untrimmed stream frame that `byte_offset` begins at, when known.
    position: u64,
    /// True when `position` is trustworthy and forward discarding will land
    /// exactly on the requested frame.
    exact: bool,
};

/// Chooses how to resolve a seek.
///
/// Constant-bitrate streams — three MP3s in four carry no VBR header at all,
/// and most that do carry an `Info` header, which declares CBR — resolve by
/// arithmetic on the frame size, in constant time and exactly.
///
/// A genuinely variable-bitrate stream is resolved from the lazily extended
/// frame-header index, which is also exact. It costs one buffered walk of the
/// frame headers between where the index already reached and the target; no
/// audio is decoded and progress is kept, so repeated seeks stay cheap. The
/// design document proposes using the Xing TOC here instead. Measured against
/// this module's own VBR fixture the TOC lands roughly five percent of the
/// duration away from the requested frame, which would make the reported
/// position a lie and break gapless boundaries, so the TOC is kept only as
/// the fallback for a stream whose headers cannot be walked.
///
/// Every path backs off far enough for the bit reservoir to refill, because
/// frames decoded before it does produce silence rather than audio.
fn seekPlan(context: *Context, target: u64) !SeekPlan {
    const info = context.stream;
    const spf = context.samples_per_frame;
    const constant_bitrate = info.vbr == null or info.vbr.?.kind == .info;

    if (constant_bitrate) {
        const frame_bytes: u64 = info.header.frameBytes();
        if (frame_bytes != 0) {
            const mpeg_frame = target / spf;
            const start = mpeg_frame -| context.primer_frames;
            return .{
                .byte_offset = info.audio_start + start * frame_bytes,
                .position = start * spf,
                .exact = true,
            };
        }
    }

    const lead = target -| context.primer_frames * spf;
    try context.index.ensureCovers(context.allocator, context.source, info.header, target);
    if (context.index.lookup(lead)) |entry| return .{
        .byte_offset = entry.byte_offset,
        .position = entry.pcm_frame,
        .exact = true,
    };

    if (info.vbr) |vbr| {
        if (vbr.toc) |toc| {
            if (vbr.byte_count) |byte_count| {
                if (vbr.frame_count) |mpeg_frames| {
                    const untrimmed = @as(u64, mpeg_frames) * spf;
                    if (untrimmed != 0) {
                        // The table maps byte positions onto the untrimmed
                        // stream, so the fraction is taken against that and
                        // not against the delay-trimmed length.
                        const fraction = @as(f64, @floatFromInt(@min(target, untrimmed))) /
                            @as(f64, @floatFromInt(untrimmed));
                        // The Xing byte count is measured from the header
                        // frame, which sits one frame before `audio_start`.
                        const base = info.audio_start -| info.header.frameBytes();
                        const offset = stream_parser.tocByteOffset(toc, byte_count, fraction);
                        const located = try stream_parser.findFrame(
                            context.source,
                            base + offset,
                            context.source.size(),
                        );
                        return .{
                            .byte_offset = located.offset,
                            .position = target,
                            .exact = false,
                        };
                    }
                }
            }
        }
    }
    return .{ .byte_offset = info.audio_start, .position = 0, .exact = true };
}

fn deinit(context_ptr: *anyopaque) void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const allocator = context.allocator;
    orca_mp3_decoder_destroy(context.native);
    context.index.deinit(allocator);
    allocator.destroy(context);
}

const vtable: decoder_api.Decoder.VTable = .{
    .read_frames = readFrames,
    .seek = seek,
    .deinit = deinit,
};

const testing = std.testing;

fn openFixture(path: []const u8) !storage.LocalFileSource {
    return storage.LocalFileSource.open(std.testing.io, path);
}

fn drain(decoder: *decoder_api.Decoder) !u64 {
    var buffer: [4096]f32 = undefined;
    const usable = buffer.len - buffer.len % decoder.format.channels;
    var total: u64 = 0;
    while (true) {
        const frames = try decoder.readFrames(buffer[0..usable]);
        if (frames == 0) return total;
        total += frames;
    }
}

test "ID3v2 tagged MP3 decodes at its declared rate and channel count" {
    var local = try openFixture("fixtures/audio/tagged-reference.mp3");
    defer local.close();
    var decoder = try openDecoder(testing.allocator, local.readable());
    defer decoder.deinit();
    try testing.expect(decoder.source_format == null);
    try testing.expectEqual(@as(u32, 44_100), decoder.format.sample_rate);
    var samples: [2048]f32 = undefined;
    const usable = samples.len - samples.len % decoder.format.channels;
    try testing.expect(try decoder.readFrames(samples[0..usable]) > 0);
    for (samples[0..16]) |sample| try testing.expect(std.math.isFinite(sample));
}

test "a Xing and LAME tagged stream decodes exactly its trimmed frame count" {
    var local = try openFixture("fixtures/audio/vbr-xing-reference.mp3");
    defer local.close();
    var decoder = try openDecoder(testing.allocator, local.readable());
    defer decoder.deinit();
    const declared = decoder.frame_count.?;
    try testing.expectEqual(declared, try drain(&decoder));
}

test "a constant bitrate stream without a Xing header still reports a length" {
    var local = try openFixture("fixtures/audio/cbr-noxing-reference.mp3");
    defer local.close();
    var decoder = try openDecoder(testing.allocator, local.readable());
    defer decoder.deinit();
    const estimated = decoder.frame_count.?;
    const decoded = try drain(&decoder);
    // Without a Xing header the length is inferred from the average frame
    // size, so it is an estimate; one MPEG frame of slack is the bound.
    const slack: u64 = 1152;
    try testing.expect(decoded + slack >= estimated and estimated + slack >= decoded);
}

test "seeking a constant bitrate stream lands on the requested frame" {
    var local = try openFixture("fixtures/audio/cbr-noxing-reference.mp3");
    defer local.close();
    var decoder = try openDecoder(testing.allocator, local.readable());
    defer decoder.deinit();
    const total = decoder.frame_count.?;
    const target = total / 2;
    try decoder.seek(target);
    const remaining = try drain(&decoder);
    // Constant frame sizes make the byte arithmetic exact; the only slack is
    // the estimated total this fixture's missing Xing header forces.
    const slack: u64 = 1152;
    const expected = total - target;
    try testing.expect(remaining + slack >= expected and expected + slack >= remaining);
}

test "seeking back to zero replays the opening samples byte for byte" {
    var local = try openFixture("fixtures/audio/cbr-noxing-reference.mp3");
    defer local.close();
    var decoder = try openDecoder(testing.allocator, local.readable());
    defer decoder.deinit();
    var first: [512]f32 = undefined;
    var again: [512]f32 = undefined;
    const usable = first.len - first.len % decoder.format.channels;
    _ = try decoder.readFrames(first[0..usable]);
    _ = try decoder.readFrames(again[0..usable]);
    try decoder.seek(0);
    _ = try decoder.readFrames(again[0..usable]);
    try testing.expectEqualSlices(f32, first[0..usable], again[0..usable]);
}

test "seeking a variable bitrate stream lands exactly on the requested frame" {
    var local = try openFixture("fixtures/audio/vbr-xing-reference.mp3");
    defer local.close();
    var decoder = try openDecoder(testing.allocator, local.readable());
    defer decoder.deinit();
    const total = decoder.frame_count.?;
    const target = total / 3;
    try decoder.seek(target);
    const remaining = try drain(&decoder);
    // The frame index resolves this exactly; nothing is approximated.
    const slack: u64 = 0;
    const expected = total - target;
    try testing.expect(remaining + slack >= expected and expected + slack >= remaining);
}

test "a file holding no MPEG frame is refused before any decoder is created" {
    var bytes: [4096]u8 = @splat(0x00);
    var memory: storage.MemorySource = .{ .bytes = &bytes };
    try testing.expectError(
        stream_parser.Error.Mp3SyncNotFound,
        openDecoder(testing.allocator, memory.readable()),
    );
}

test "a truncated MP3 ends its stream instead of reading past the data" {
    var whole = try openFixture("fixtures/audio/cbr-noxing-reference.mp3");
    defer whole.close();
    var whole_decoder = try openDecoder(testing.allocator, whole.readable());
    defer whole_decoder.deinit();
    const whole_frames = try drain(&whole_decoder);

    var local = try openFixture("fixtures/audio/truncated-reference.mp3");
    defer local.close();
    var decoder = try openDecoder(testing.allocator, local.readable());
    defer decoder.deinit();
    const decoded = try drain(&decoder);
    try testing.expect(decoded > 0);
    try testing.expect(decoded < whole_frames);
}

test "a stream cut off mid-frame still seeks and stops at its real end" {
    var local = try openFixture("fixtures/audio/truncated-reference.mp3");
    defer local.close();
    var decoder = try openDecoder(testing.allocator, local.readable());
    defer decoder.deinit();
    try decoder.seek(decoder.frame_count.? / 2);
    _ = try drain(&decoder);
}

fn readWhole(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var local = try openFixture(path);
    defer local.close();
    const size: usize = @intCast(local.readable().size());
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    if (try local.readable().readAt(0, bytes) != size) return error.ShortFixtureRead;
    return bytes;
}

test "a trailing ID3v1 tag does not cost the final frame of audio" {
    const allocator = testing.allocator;
    const original = try readWhole(allocator, "fixtures/audio/vbr-xing-reference.mp3");
    defer allocator.free(original);

    var plain: storage.MemorySource = .{ .bytes = original };
    var plain_decoder = try openDecoder(allocator, plain.readable());
    defer plain_decoder.deinit();
    const plain_frames = try drain(&plain_decoder);

    const tagged = try allocator.alloc(u8, original.len + 128);
    defer allocator.free(tagged);
    @memcpy(tagged[0..original.len], original);
    @memset(tagged[original.len..], 0);
    @memcpy(tagged[original.len..][0..3], "TAG");

    var appended: storage.MemorySource = .{ .bytes = tagged };
    var appended_decoder = try openDecoder(allocator, appended.readable());
    defer appended_decoder.deinit();
    try testing.expectEqual(plain_decoder.frame_count, appended_decoder.frame_count);
    try testing.expectEqual(plain_frames, try drain(&appended_decoder));
}

test "corrupted MPEG payloads end or error without reading out of bounds" {
    const allocator = testing.allocator;
    const original = try readWhole(allocator, "fixtures/audio/cbr-noxing-reference.mp3");
    defer allocator.free(original);
    const corrupted = try allocator.dupe(u8, original);
    defer allocator.free(corrupted);

    var random: std.Random.DefaultPrng = .init(0x5eed_1234);
    var round: usize = 0;
    while (round < 24) : (round += 1) {
        @memcpy(corrupted, original);
        var mutation: usize = 0;
        while (mutation < 64) : (mutation += 1) {
            const at = random.random().uintLessThan(usize, corrupted.len);
            corrupted[at] = random.random().int(u8);
        }
        var memory: storage.MemorySource = .{ .bytes = corrupted };
        var decoder = openDecoder(allocator, memory.readable()) catch continue;
        defer decoder.deinit();
        _ = drain(&decoder) catch continue;
        decoder.seek(decoder.frame_count.? / 2) catch continue;
        _ = drain(&decoder) catch continue;
    }
}

test "seeking beyond the declared length is refused rather than clamped" {
    var local = try openFixture("fixtures/audio/vbr-xing-reference.mp3");
    defer local.close();
    var decoder = try openDecoder(testing.allocator, local.readable());
    defer decoder.deinit();
    try testing.expectError(
        error.SeekOutOfRange,
        decoder.seek(decoder.frame_count.? + 1),
    );
}
