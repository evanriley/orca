//! Ogg Opus decoding, over libopusfile behind `opus_shim.c`.
//!
//! opusfile owns the Ogg container, pre-skip, end trimming and sample-exact
//! seeking, so the frame count and the decoded length match what the encoder
//! was given. Opus always decodes to 48 kHz; the input rate the header records
//! is informational and is not reported as the stream's rate.

const std = @import("std");
const decoder_api = @import("decoder.zig");
const storage = @import("../storage/root.zig");

const ok: i32 = 0;
const end_of_stream: i32 = 1;
const decode_rate: u32 = 48_000;

const Info = extern struct {
    channels: u32,
    total_frames: i64,
};

extern fn orca_opus_decoder_create(
    context: ?*anyopaque,
    read: *const fn (?*anyopaque, u64, [*]u8, u64) callconv(.c) i64,
    size: u64,
    info: *Info,
) ?*anyopaque;
extern fn orca_opus_decoder_destroy(decoder: ?*anyopaque) void;
extern fn orca_opus_decoder_read(
    decoder: ?*anyopaque,
    output: [*]f32,
    output_frames: u32,
    frames_written: *u32,
) i32;
extern fn orca_opus_decoder_seek(decoder: ?*anyopaque, frame: u64) i32;

const Context = struct {
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
    native: *anyopaque,
    channels: u16,
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
    context.native = orca_opus_decoder_create(context, readSource, source.size(), &info) orelse
        return error.InvalidOpus;
    errdefer orca_opus_decoder_destroy(context.native);
    context.channels = std.math.cast(u16, info.channels) orelse return error.InvalidOpus;
    if (context.channels == 0) return error.InvalidOpus;
    return .{
        .context = context,
        .vtable = &vtable,
        .codec = decoder_api.codec_id.opus,
        .source_format = null,
        .format = .{
            .sample_format = .float_32,
            .channels = context.channels,
            .sample_rate = decode_rate,
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
    if (capacity == 0) return 0;
    var produced: u32 = 0;
    return switch (orca_opus_decoder_read(
        context.native,
        output.ptr,
        @intCast(@min(capacity, std.math.maxInt(u32))),
        &produced,
    )) {
        ok => produced,
        end_of_stream => 0,
        else => error.OpusDecodeFailed,
    };
}

fn seek(context_ptr: *anyopaque, frame: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (orca_opus_decoder_seek(context.native, frame) != ok) return error.OpusSeekFailed;
}

fn deinit(context_ptr: *anyopaque) void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const allocator = context.allocator;
    orca_opus_decoder_destroy(context.native);
    allocator.destroy(context);
}

const vtable: decoder_api.Decoder.VTable = .{
    .read_frames = readFrames,
    .seek = seek,
    .deinit = deinit,
};

const reference = "fixtures/audio/tagged-reference.opus";

fn meanSquaredError(first: []const f32, second: []const f32) f64 {
    var sum: f64 = 0;
    for (first, second) |a, b| {
        const difference: f64 = a - b;
        sum += difference * difference;
    }
    return sum / @as(f64, @floatFromInt(first.len));
}

fn decodeAll(decoder: *decoder_api.Decoder, output: []f32) !usize {
    var frames: usize = 0;
    while (true) {
        const read = try decoder.readFrames(output[frames * decoder.format.channels ..]);
        if (read == 0) return frames;
        frames += read;
    }
}

test "an Ogg Opus stream decodes to exactly the length the encoder was given" {
    var local = try storage.LocalFileSource.open(std.testing.io, reference);
    defer local.close();
    var decoder = try openDecoder(std.testing.allocator, local.readable());
    defer decoder.deinit();
    try std.testing.expectEqualStrings("opus", decoder.codec);
    try std.testing.expect(decoder.source_format == null);
    try std.testing.expectEqual(@as(u16, 2), decoder.format.channels);
    try std.testing.expectEqual(@as(u32, 48_000), decoder.format.sample_rate);
    // 9,600 frames of source; the 312 frames of encoder pre-skip the container
    // also carries must not be counted or played.
    try std.testing.expectEqual(@as(?u64, 9_600), decoder.frame_count);
    const samples = try std.testing.allocator.alloc(f32, 12_000 * 2);
    defer std.testing.allocator.free(samples);
    try std.testing.expectEqual(@as(usize, 9_600), try decodeAll(&decoder, samples));
}

test "seeking an Ogg Opus stream lands on the requested frame" {
    var local = try storage.LocalFileSource.open(std.testing.io, reference);
    defer local.close();
    var decoder = try openDecoder(std.testing.allocator, local.readable());
    defer decoder.deinit();
    const whole = try std.testing.allocator.alloc(f32, 12_000 * 2);
    defer std.testing.allocator.free(whole);
    _ = try decodeAll(&decoder, whole);

    try decoder.seek(4_800);
    const tail = try std.testing.allocator.alloc(f32, 12_000 * 2);
    defer std.testing.allocator.free(tail);
    try std.testing.expectEqual(@as(usize, 4_800), try decodeAll(&decoder, tail));
    // A seek rebuilds decoder state from an 80 ms pre-roll, so the sought
    // audio converges on the sequential decode rather than matching it
    // sample for sample. Once converged it must line up at the target frame,
    // and clearly better than it would one frame to either side.
    const settled = 2_000;
    const aligned = meanSquaredError(tail[settled * 2 .. 4_000 * 2], whole[(4_800 + settled) * 2 .. 8_800 * 2]);
    const early = meanSquaredError(tail[settled * 2 .. 4_000 * 2], whole[(4_799 + settled) * 2 .. 8_799 * 2]);
    const late = meanSquaredError(tail[settled * 2 .. 4_000 * 2], whole[(4_801 + settled) * 2 .. 8_801 * 2]);
    try std.testing.expect(aligned * 4 < early);
    try std.testing.expect(aligned * 4 < late);
}

test "bytes that are not Ogg Opus fail to open" {
    var memory = storage.MemorySource{ .bytes = "OggS but nothing after it" };
    try std.testing.expectError(
        error.InvalidOpus,
        openDecoder(std.testing.allocator, memory.readable()),
    );
}
