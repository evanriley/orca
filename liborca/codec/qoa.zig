//! QOA decoding, over the vendored reference decoder behind `qoa_shim.c`.
//!
//! Every QOA frame carries its own predictor state, and every frame but the
//! last holds exactly 5,120 frames of audio, so a seek is an offset
//! computation and a skip inside one frame.

const std = @import("std");
const decoder_api = @import("decoder.zig");
const storage = @import("../storage/root.zig");

const frame_frames: u64 = 5120;
const file_header_bytes: u64 = 8;
const max_channels = 8;

const Info = extern struct {
    channels: u32,
    sample_rate: u32,
    frames: u32,
    max_frame_bytes: u32,
};

extern fn orca_qoa_decoder_create(header: [*]const u8, header_size: u32, info: *Info) ?*anyopaque;
extern fn orca_qoa_decoder_destroy(decoder: ?*anyopaque) void;
extern fn orca_qoa_decoder_decode_frame(
    decoder: ?*anyopaque,
    bytes: [*]const u8,
    size: u32,
    output: [*]f32,
    frames_written: *u32,
) u32;

const Context = struct {
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
    native: *anyopaque,
    channels: u16,
    total_frames: u64,
    full_frame_bytes: u64,
    frame: [max_frame_bytes]u8,
    pcm: [frame_frames * max_channels]f32,
    pending_start: usize = 0,
    pending_end: usize = 0,
    /// Byte offset of the next frame to decode.
    offset: u64 = file_header_bytes,
    /// Frames to discard from the next decoded frame, after a seek.
    skip_frames: u64 = 0,
    remaining_frames: u64 = 0,

    const max_frame_bytes = 8 + 16 * max_channels + 256 * 8 * max_channels;
};

pub fn openDecoder(
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
) !decoder_api.Decoder {
    const format = try validateSource(source);
    var header: [16]u8 = undefined;
    if (try source.readAt(0, &header) != header.len) return error.TruncatedQoa;
    var info: Info = undefined;
    const native = orca_qoa_decoder_create(&header, header.len, &info) orelse return error.InvalidQoa;
    errdefer orca_qoa_decoder_destroy(native);
    if (info.max_frame_bytes > Context.max_frame_bytes) return error.InvalidQoa;

    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .source = source,
        .native = native,
        .channels = format.channels,
        .total_frames = format.frames,
        .full_frame_bytes = info.max_frame_bytes,
        .frame = undefined,
        .pcm = undefined,
        .remaining_frames = format.frames,
    };
    return .{
        .context = context,
        .vtable = &vtable,
        .codec = decoder_api.codec_id.qoa,
        .source_format = .{
            .sample_format = .signed_16,
            .channels = format.channels,
            .sample_rate = format.sample_rate,
            .bits_per_sample = 16,
            .bytes_per_frame = try std.math.mul(u16, format.channels, 2),
        },
        .format = .{
            .sample_format = .float_32,
            .channels = format.channels,
            .sample_rate = format.sample_rate,
            .bits_per_sample = 32,
            .bytes_per_frame = try std.math.mul(u16, format.channels, 4),
        },
        .frame_count = format.frames,
    };
}

const StreamFormat = struct { channels: u16, sample_rate: u32, frames: u64 };

fn validateSource(source: storage.ReadableSource) !StreamFormat {
    var file_header: [8]u8 = undefined;
    if (try source.readAt(0, &file_header) != file_header.len) return error.TruncatedQoa;
    if (!std.mem.eql(u8, file_header[0..4], "qoaf")) return error.InvalidQoa;
    const expected_frames = big32(file_header[4..8]);
    var offset: u64 = 8;
    var decoded_frames: u64 = 0;
    var stream_format: ?StreamFormat = null;
    while (decoded_frames < expected_frames) {
        var bytes: [8]u8 = undefined;
        if (try source.readAt(offset, &bytes) != bytes.len) return error.TruncatedQoa;
        const value = big64(&bytes);
        const channels: u16 = @intCast((value >> 56) & 0xff);
        const sample_rate: u32 = @intCast((value >> 32) & 0xffffff);
        const samples: u16 = @intCast((value >> 16) & 0xffff);
        const size: u16 = @intCast(value & 0xffff);
        const minimum_size = 8 + 16 * channels;
        if (channels == 0 or channels > 8 or sample_rate == 0 or samples == 0 or
            size < minimum_size or offset + size > source.size())
            return error.InvalidQoa;
        const encoded_bytes = size - minimum_size;
        if (encoded_bytes % 8 != 0) return error.InvalidQoa;
        const slices: u32 = encoded_bytes / 8;
        const expected_slices: u32 = ((@as(u32, samples) + 19) / 20) * channels;
        if (slices != expected_slices) return error.InvalidQoa;
        if (stream_format) |format| {
            if (format.channels != channels or format.sample_rate != sample_rate)
                return error.ChangingQoaFormat;
        } else {
            stream_format = .{
                .channels = channels,
                .sample_rate = sample_rate,
                .frames = expected_frames,
            };
        }
        decoded_frames += samples;
        if (decoded_frames > expected_frames) return error.InvalidQoa;
        // Seeking computes frame offsets, so a short frame is only legal last.
        if (samples != frame_frames and decoded_frames != expected_frames) return error.InvalidQoa;
        offset += size;
    }
    if (decoded_frames != expected_frames or offset != source.size()) return error.InvalidQoa;
    return stream_format orelse error.InvalidQoa;
}

fn big32(bytes: *const [4]u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        bytes[3];
}

fn big64(bytes: *const [8]u8) u64 {
    return (@as(u64, big32(bytes[0..4])) << 32) | big32(bytes[4..8]);
}

fn decodeNext(context: *Context) !bool {
    while (context.remaining_frames > 0) {
        const available = context.source.size() -| context.offset;
        const wanted: usize = @intCast(@min(available, context.full_frame_bytes));
        if (wanted == 0) return false;
        const bytes = context.frame[0..wanted];
        if (try context.source.readAt(context.offset, bytes) != bytes.len) return error.TruncatedQoa;
        var frames: u32 = 0;
        const consumed = orca_qoa_decoder_decode_frame(
            context.native,
            bytes.ptr,
            @intCast(bytes.len),
            &context.pcm,
            &frames,
        );
        if (consumed == 0) return error.InvalidQoa;
        context.offset += consumed;
        const dropped = @min(frames, context.skip_frames);
        context.skip_frames -= dropped;
        if (frames == dropped) continue;
        context.pending_start = @intCast(dropped * context.channels);
        context.pending_end = @as(usize, frames) * context.channels;
        return true;
    }
    return false;
}

fn readFrames(context_ptr: *anyopaque, output: []f32) !usize {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const channels = context.channels;
    if (context.remaining_frames == 0) return 0;
    if (context.pending_start == context.pending_end and !try decodeNext(context)) return 0;
    const pending = (context.pending_end - context.pending_start) / channels;
    const frames = @min(pending, output.len / channels, context.remaining_frames);
    const samples = frames * channels;
    @memcpy(output[0..samples], context.pcm[context.pending_start..][0..samples]);
    context.pending_start += samples;
    context.remaining_frames -= frames;
    return frames;
}

fn seek(context_ptr: *anyopaque, frame: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (frame > context.total_frames) return error.SeekOutOfRange;
    const index = frame / frame_frames;
    context.offset = file_header_bytes + index * context.full_frame_bytes;
    context.skip_frames = frame - index * frame_frames;
    context.remaining_frames = context.total_frames - frame;
    context.pending_start = 0;
    context.pending_end = 0;
}

fn deinit(context_ptr: *anyopaque) void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const allocator = context.allocator;
    orca_qoa_decoder_destroy(context.native);
    allocator.destroy(context);
}

const vtable: decoder_api.Decoder.VTable = .{
    .read_frames = readFrames,
    .seek = seek,
    .deinit = deinit,
};

test "a QOA stream decodes to the length its header declares" {
    var local = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/generated-reference.qoa",
    );
    defer local.close();
    var decoder = try openDecoder(std.testing.allocator, local.readable());
    defer decoder.deinit();
    try std.testing.expectEqual(@import("../audio/pcm.zig").SampleFormat.signed_16, decoder.source_format.?.sample_format);
    try std.testing.expectEqual(@as(u16, 1), decoder.format.channels);
    try std.testing.expectEqual(@as(u32, 48_000), decoder.format.sample_rate);
    try std.testing.expectEqual(@as(?u64, 20), decoder.frame_count);
    var samples: [20]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 20), try decoder.readFrames(&samples));
    for (samples) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "a malformed QOA frame size fails before the decoder is created" {
    const malformed = "qoaf\x00\x00\x00\x01" ++
        "\x01\x00\xbb\x80\x00\x01\x00\x01";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "malformed.qoa",
        .data = malformed,
    });
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/malformed.qoa",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(path);
    var local = try storage.LocalFileSource.open(std.testing.io, path);
    defer local.close();
    try std.testing.expectError(error.InvalidQoa, openDecoder(
        std.testing.allocator,
        local.readable(),
    ));
}

fn decodeAll(decoder: *decoder_api.Decoder, output: []f32) !usize {
    var frames: usize = 0;
    while (true) {
        const read = try decoder.readFrames(output[frames * decoder.format.channels ..]);
        if (read == 0) return frames;
        frames += read;
    }
}

fn openFixture(file: *storage.LocalFileSource, path: []const u8) !decoder_api.Decoder {
    file.* = try storage.LocalFileSource.open(std.testing.io, path);
    return openDecoder(std.testing.allocator, file.readable());
}

test "a two-frame stereo QOA stream decodes close to the audio it was encoded from" {
    var file: storage.LocalFileSource = undefined;
    var decoder = try openFixture(&file, "fixtures/audio/stereo-reference.qoa");
    defer file.close();
    defer decoder.deinit();
    const decoded = try std.testing.allocator.alloc(f32, 10_000 * 2);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqual(@as(usize, 9_600), try decodeAll(&decoder, decoded));

    var reference_file = try storage.LocalFileSource.open(std.testing.io, "fixtures/audio/generated-reference.wav");
    defer reference_file.close();
    var reference = try @import("wav.zig").openDecoder(std.testing.allocator, reference_file.readable());
    defer reference.deinit();
    const source = try std.testing.allocator.alloc(f32, 10_000 * 2);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 9_600), try decodeAll(&reference, source));
    var sum: f64 = 0;
    for (decoded[0 .. 9_600 * 2], source[0 .. 9_600 * 2]) |a, b| {
        const difference: f64 = a - b;
        sum += difference * difference;
    }
    try std.testing.expect(sum / (9_600 * 2) < 1e-5);
}

test "seeking into either frame of a QOA stream decodes exactly what a sequential read does" {
    var file: storage.LocalFileSource = undefined;
    var decoder = try openFixture(&file, "fixtures/audio/stereo-reference.qoa");
    defer file.close();
    defer decoder.deinit();
    const whole = try std.testing.allocator.alloc(f32, 10_000 * 2);
    defer std.testing.allocator.free(whole);
    _ = try decodeAll(&decoder, whole);

    const tail = try std.testing.allocator.alloc(f32, 10_000 * 2);
    defer std.testing.allocator.free(tail);
    for ([_]u64{ 0, 4_999, 5_120, 7_000, 9_600 }) |target| {
        try decoder.seek(target);
        const frames = try decodeAll(&decoder, tail);
        try std.testing.expectEqual(@as(usize, @intCast(9_600 - target)), frames);
        try std.testing.expectEqualSlices(
            f32,
            whole[@intCast(target * 2)..][0 .. frames * 2],
            tail[0 .. frames * 2],
        );
    }
    try std.testing.expectError(error.SeekOutOfRange, decoder.seek(9_601));
}
