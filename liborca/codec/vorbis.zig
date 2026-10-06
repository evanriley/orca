//! Ogg Vorbis decoding, over libvorbisfile behind `vorbis_shim.c`.
//!
//! vorbisfile owns the Ogg container, the granule-position arithmetic that
//! trims the final packet, and sample-exact seeking.

const std = @import("std");
const decoder_api = @import("decoder.zig");
const storage = @import("../storage/root.zig");

const ok: i32 = 0;
const end_of_stream: i32 = 1;

const Info = extern struct {
    channels: u32,
    sample_rate: u32,
    total_frames: i64,
};

extern fn orca_vorbis_decoder_create(
    context: ?*anyopaque,
    read: *const fn (?*anyopaque, u64, [*]u8, u64) callconv(.c) i64,
    size: u64,
    info: *Info,
) ?*anyopaque;
extern fn orca_vorbis_decoder_destroy(decoder: ?*anyopaque) void;
extern fn orca_vorbis_decoder_read(
    decoder: ?*anyopaque,
    output: [*]f32,
    output_frames: u32,
    frames_written: *u32,
) i32;
extern fn orca_vorbis_decoder_seek(decoder: ?*anyopaque, frame: u64) i32;

const Context = struct {
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
    native: *anyopaque,
    channels: u16,
    total_frames: ?u64 = null,
    at_end: bool = false,
};

pub fn openDecoder(
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
) !decoder_api.Decoder {
    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .source = source,
        .native = undefined,
        .channels = 0,
    };
    var info: Info = undefined;
    context.native = orca_vorbis_decoder_create(context, readSource, source.size(), &info) orelse
        return error.InvalidVorbis;
    errdefer orca_vorbis_decoder_destroy(context.native);
    context.channels = std.math.cast(u16, info.channels) orelse return error.InvalidVorbis;
    context.total_frames = if (info.total_frames < 0) null else @intCast(info.total_frames);
    return .{
        .context = context,
        .vtable = &vtable,
        .codec = decoder_api.codec_id.vorbis,
        .source_format = null,
        .format = .{
            .sample_format = .float_32,
            .channels = context.channels,
            .sample_rate = info.sample_rate,
            .bits_per_sample = 32,
            .bytes_per_frame = try std.math.mul(u16, context.channels, 4),
        },
        .frame_count = if (info.total_frames < 0) null else @intCast(info.total_frames),
    };
}

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

fn readFrames(context_ptr: *anyopaque, output: []f32) !usize {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const capacity = output.len / context.channels;
    if (capacity == 0 or context.at_end) return 0;
    var produced: u32 = 0;
    return switch (orca_vorbis_decoder_read(
        context.native,
        output.ptr,
        @intCast(@min(capacity, std.math.maxInt(u32))),
        &produced,
    )) {
        ok => produced,
        end_of_stream => 0,
        else => error.VorbisDecodeFailed,
    };
}

fn seek(context_ptr: *anyopaque, frame: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (context.total_frames) |total| {
        if (frame >= total) {
            context.at_end = true;
            return;
        }
    }
    if (orca_vorbis_decoder_seek(context.native, frame) != ok) return error.VorbisSeekFailed;
    context.at_end = false;
}

fn deinit(context_ptr: *anyopaque) void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const allocator = context.allocator;
    orca_vorbis_decoder_destroy(context.native);
    allocator.destroy(context);
}

const vtable: decoder_api.Decoder.VTable = .{
    .read_frames = readFrames,
    .seek = seek,
    .deinit = deinit,
};

const reference = "fixtures/audio/tagged-reference.ogg";

fn decodeAll(decoder: *decoder_api.Decoder, output: []f32) !usize {
    var frames: usize = 0;
    while (true) {
        const read = try decoder.readFrames(output[frames * decoder.format.channels ..]);
        if (read == 0) return frames;
        frames += read;
    }
}

test "an Ogg Vorbis stream decodes to exactly the length the encoder was given" {
    var local = try storage.LocalFileSource.open(std.testing.io, reference);
    defer local.close();
    var decoder = try openDecoder(std.testing.allocator, local.readable());
    defer decoder.deinit();
    try std.testing.expectEqualStrings("vorbis", decoder.codec);
    try std.testing.expect(decoder.source_format == null);
    try std.testing.expectEqual(@as(u16, 2), decoder.format.channels);
    try std.testing.expectEqual(@as(u32, 44_100), decoder.format.sample_rate);
    try std.testing.expectEqual(@as(?u64, 8_820), decoder.frame_count);
    const samples = try std.testing.allocator.alloc(f32, 10_000 * 2);
    defer std.testing.allocator.free(samples);
    try std.testing.expectEqual(@as(usize, 8_820), try decodeAll(&decoder, samples));
}

test "seeking an Ogg Vorbis stream lands on the requested frame" {
    var local = try storage.LocalFileSource.open(std.testing.io, reference);
    defer local.close();
    var decoder = try openDecoder(std.testing.allocator, local.readable());
    defer decoder.deinit();
    const whole = try std.testing.allocator.alloc(f32, 10_000 * 2);
    defer std.testing.allocator.free(whole);
    _ = try decodeAll(&decoder, whole);

    try decoder.seek(4_410);
    const tail = try std.testing.allocator.alloc(f32, 10_000 * 2);
    defer std.testing.allocator.free(tail);
    try std.testing.expectEqual(@as(usize, 4_410), try decodeAll(&decoder, tail));
    for (tail[0 .. 4_410 * 2], whole[4_410 * 2 .. 8_820 * 2]) |sought, sequential|
        try std.testing.expectApproxEqAbs(sequential, sought, 1e-4);
}

test "bytes that are not Ogg Vorbis fail to open" {
    var memory = storage.MemorySource{ .bytes = "OggS but nothing after it" };
    try std.testing.expectError(
        error.InvalidVorbis,
        openDecoder(std.testing.allocator, memory.readable()),
    );
}
