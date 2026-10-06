//! AIFF and AIFC: Apple's uncompressed PCM containers.
//!
//! Big-endian `FORM` chunks; `COMM` states the layout and carries the sample
//! rate as an 80-bit extended float, and `SSND` holds the samples. AIFC adds a
//! compression type, of which only the uncompressed ones are PCM worth
//! reading: `NONE` and `twos` (big-endian), `sowt` (little-endian, what macOS
//! writes) and `fl32`/`fl64` (big-endian float).

const std = @import("std");
const audio_pcm = @import("../audio/pcm.zig");
const decoder_api = @import("decoder.zig");
const storage = @import("../storage/root.zig");

const Encoding = enum { big_integer, little_integer, big_float };

const Layout = struct {
    format: audio_pcm.Format,
    encoding: Encoding,
    data_offset: u64,
    frames: u64,
    damage: ?decoder_api.Damage,
};

const Context = struct {
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
    layout: Layout,
    scratch: []u8,
    position: u64 = 0,
};

const max_scratch_frames = 4096;

pub fn openDecoder(allocator: std.mem.Allocator, source: storage.ReadableSource) !decoder_api.Decoder {
    const layout = try readLayout(source);
    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    const scratch_frames: usize = @intCast(@max(1, @min(max_scratch_frames, layout.frames)));
    const scratch = try allocator.alloc(u8, try std.math.mul(usize, scratch_frames, layout.format.bytes_per_frame));
    errdefer allocator.free(scratch);
    context.* = .{ .allocator = allocator, .source = source, .layout = layout, .scratch = scratch };
    return .{
        .context = context,
        .vtable = if (layout.encoding == .big_float) &vtable else &integer_vtable,
        .codec = if (layout.encoding == .big_float) decoder_api.codec_id.pcm_float else decoder_api.codec_id.pcm,
        .source_format = layout.format,
        .format = .{
            .sample_format = .float_32,
            .channels = layout.format.channels,
            .sample_rate = layout.format.sample_rate,
            .bits_per_sample = 32,
            .bytes_per_frame = try std.math.mul(u16, layout.format.channels, 4),
        },
        .frame_count = layout.frames,
    };
}

fn readLayout(source: storage.ReadableSource) !Layout {
    var form: [12]u8 = undefined;
    if (try source.readAt(0, &form) != form.len) return error.TruncatedAiff;
    if (!std.mem.eql(u8, form[0..4], "FORM")) return error.InvalidAiff;
    const compressed = std.mem.eql(u8, form[8..12], "AIFC");
    if (!compressed and !std.mem.eql(u8, form[8..12], "AIFF")) return error.InvalidAiff;

    var common: ?struct { channels: u16, frames: u32, bits: u16, rate: u32, encoding: Encoding } = null;
    var data_offset: ?u64 = null;
    var data_bytes: u64 = 0;
    var offset: u64 = 12;
    while (offset + 8 <= source.size()) {
        var header: [8]u8 = undefined;
        if (try source.readAt(offset, &header) != header.len) return error.TruncatedAiff;
        const size = std.mem.readInt(u32, header[4..8], .big);
        const body = offset + 8;
        if (body + size > source.size()) return error.TruncatedAiff;
        if (std.mem.eql(u8, header[0..4], "COMM")) {
            if (size < 18 or (compressed and size < 22)) return error.InvalidAiff;
            var comm: [22]u8 = undefined;
            const wanted: usize = if (compressed) 22 else 18;
            if (try source.readAt(body, comm[0..wanted]) != wanted) return error.TruncatedAiff;
            const bits = std.mem.readInt(u16, comm[6..8], .big);
            common = .{
                .channels = std.mem.readInt(u16, comm[0..2], .big),
                .frames = std.mem.readInt(u32, comm[2..6], .big),
                .bits = bits,
                .rate = extendedToRate(comm[8..18]) orelse return error.InvalidAiff,
                .encoding = if (compressed) try compression(comm[18..22], bits) else .big_integer,
            };
        } else if (std.mem.eql(u8, header[0..4], "SSND")) {
            if (size < 8) return error.InvalidAiff;
            var ssnd: [4]u8 = undefined;
            if (try source.readAt(body, &ssnd) != ssnd.len) return error.TruncatedAiff;
            const skip = std.mem.readInt(u32, &ssnd, .big);
            if (skip > size - 8) return error.InvalidAiff;
            data_offset = body + 8 + skip;
            data_bytes = size - 8 - skip;
        }
        offset = body + size + (size & 1);
    }

    const stream = common orelse return error.MissingCommonChunk;
    if (stream.channels == 0 or stream.rate == 0) return error.InvalidAiff;
    const sample_format: audio_pcm.SampleFormat = switch (stream.encoding) {
        .big_float => switch (stream.bits) {
            32 => .float_32,
            64 => .float_64,
            else => return error.UnsupportedPcmFormat,
        },
        else => switch (stream.bits) {
            8 => .signed_8,
            16 => .signed_16,
            24 => .signed_24,
            32 => .signed_32,
            else => return error.UnsupportedPcmFormat,
        },
    };
    const bytes_per_frame = std.math.mul(u16, stream.channels, stream.bits / 8) catch return error.InvalidAiff;
    const sound_offset = data_offset orelse return error.MissingSoundChunk;
    const sound_frames = data_bytes / bytes_per_frame;
    return .{
        .format = .{
            .sample_format = sample_format,
            .channels = stream.channels,
            .sample_rate = stream.rate,
            .bits_per_sample = stream.bits,
            .bytes_per_frame = bytes_per_frame,
        },
        .encoding = stream.encoding,
        .data_offset = sound_offset,
        .frames = @min(stream.frames, sound_frames),
        .damage = if (stream.frames > sound_frames) error.TruncatedAiff else null,
    };
}

fn compression(tag: *const [4]u8, bits: u16) !Encoding {
    if (std.mem.eql(u8, tag, "NONE") or std.mem.eql(u8, tag, "twos")) return .big_integer;
    if (std.mem.eql(u8, tag, "sowt")) return if (bits == 8) .big_integer else .little_integer;
    if (std.mem.eql(u8, tag, "fl32") or std.mem.eql(u8, tag, "FL32") or
        std.mem.eql(u8, tag, "fl64") or std.mem.eql(u8, tag, "FL64")) return .big_float;
    return error.UnsupportedAiffCompression;
}

/// An IEEE 754 80-bit extended value, as COMM stores the sample rate, rounded
/// down to an integer rate. Null for zero, negative or absurd values.
fn extendedToRate(bytes: *const [10]u8) ?u32 {
    const sign_exponent = std.mem.readInt(u16, bytes[0..2], .big);
    if (sign_exponent & 0x8000 != 0) return null;
    const exponent: i32 = @as(i32, sign_exponent) - 16383;
    const mantissa = std.mem.readInt(u64, bytes[2..10], .big);
    if (mantissa == 0 or exponent < 0 or exponent > 31) return null;
    return @intCast(mantissa >> @intCast(63 - exponent));
}

fn readFrames(context_ptr: *anyopaque, output: []f32) !usize {
    return readFramesAs(f32, decodeSample, context_ptr, output);
}

fn readFramesI32(context_ptr: *anyopaque, output: []i32) !usize {
    return readFramesAs(i32, decodeInteger, context_ptr, output);
}

fn readFramesAs(
    comptime Sample: type,
    comptime decode: fn (Encoding, []const u8) Sample,
    context_ptr: *anyopaque,
    output: []Sample,
) !usize {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const layout = context.layout;
    const channels = layout.format.channels;
    const remaining = layout.frames -| context.position;
    const frames: usize = @intCast(@min(remaining, output.len / channels, context.scratch.len / layout.format.bytes_per_frame));
    if (frames == 0) return 0;
    const bytes = context.scratch[0 .. frames * layout.format.bytes_per_frame];
    const offset = layout.data_offset + context.position * layout.format.bytes_per_frame;
    const read = try context.source.readAt(offset, bytes);
    const whole = read / layout.format.bytes_per_frame;
    const width = layout.format.bits_per_sample / 8;
    for (output[0 .. whole * channels], 0..) |*sample, index| {
        sample.* = decode(layout.encoding, bytes[index * width ..][0..width]);
    }
    context.position += whole;
    return whole;
}

fn decodeSample(encoding: Encoding, bytes: []const u8) f32 {
    if (encoding == .big_float) return switch (bytes.len) {
        4 => @bitCast(std.mem.readInt(u32, bytes[0..4], .big)),
        else => @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, bytes[0..8], .big)))),
    };
    const endian: std.builtin.Endian = if (encoding == .little_integer) .little else .big;
    return switch (bytes.len) {
        // AIFF's 8-bit samples are signed, unlike WAV's.
        1 => @as(f32, @floatFromInt(@as(i8, @bitCast(bytes[0])))) / 128.0,
        2 => @as(f32, @floatFromInt(std.mem.readInt(i16, bytes[0..2], endian))) / 32_768.0,
        3 => @as(f32, @floatFromInt(std.mem.readInt(i24, bytes[0..3], endian))) / 8_388_608.0,
        else => @floatCast(@as(f64, @floatFromInt(std.mem.readInt(i32, bytes[0..4], endian))) / 2_147_483_648.0),
    };
}

fn decodeInteger(encoding: Encoding, bytes: []const u8) i32 {
    std.debug.assert(encoding != .big_float);
    const endian: std.builtin.Endian = if (encoding == .little_integer) .little else .big;
    return switch (bytes.len) {
        1 => @as(i32, @as(i8, @bitCast(bytes[0]))) << 24,
        2 => @as(i32, std.mem.readInt(i16, bytes[0..2], endian)) << 16,
        3 => @as(i32, std.mem.readInt(i24, bytes[0..3], endian)) << 8,
        else => std.mem.readInt(i32, bytes[0..4], endian),
    };
}

fn seek(context_ptr: *anyopaque, frame: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (frame > context.layout.frames) return error.SeekOutOfRange;
    context.position = frame;
}

fn damage(context_ptr: *anyopaque) ?decoder_api.Damage {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    return context.layout.damage;
}

fn deinit(context_ptr: *anyopaque) void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const allocator = context.allocator;
    allocator.free(context.scratch);
    allocator.destroy(context);
}

const vtable: decoder_api.Decoder.VTable = .{
    .read_frames = readFrames,
    .seek = seek,
    .deinit = deinit,
    .damage = damage,
};

const integer_vtable: decoder_api.Decoder.VTable = .{
    .read_frames = readFrames,
    .read_frames_i32 = readFramesI32,
    .seek = seek,
    .deinit = deinit,
    .damage = damage,
};

fn decodeFile(path: []const u8, output: []f32) !struct { frames: usize, decoder_format: audio_pcm.Format } {
    var file = try storage.LocalFileSource.open(std.testing.io, path);
    defer file.close();
    var decoder = try @import("registry.zig").CodecRegistry.builtins().openDetected(std.testing.allocator, file.readable());
    defer decoder.deinit();
    var frames: usize = 0;
    while (true) {
        const read = try decoder.readFrames(output[frames * decoder.format.channels ..]);
        if (read == 0) break;
        frames += read;
    }
    return .{ .frames = frames, .decoder_format = decoder.source_format.? };
}

test "AIFF, sowt AIFC and 24-bit AIFF decode to the samples of the FLAC they came from" {
    var reference: [480 * 2]f32 = undefined;
    const flac = try decodeFile("fixtures/audio/generated-reference.flac", &reference);
    try std.testing.expectEqual(@as(usize, 480), flac.frames);
    for ([_][]const u8{
        "fixtures/audio/sowt-reference.aifc",
        "fixtures/audio/generated-reference-24.aiff",
    }) |path| {
        var decoded: [480 * 2]f32 = undefined;
        const result = try decodeFile(path, &decoded);
        try std.testing.expectEqual(@as(usize, 480), result.frames);
        try std.testing.expectEqual(@as(u32, 48_000), result.decoder_format.sample_rate);
        try std.testing.expectEqualSlices(f32, &reference, &decoded);
    }
}

test "a tagged AIFF reports its layout and length" {
    var decoded: [9_000 * 2]f32 = undefined;
    const result = try decodeFile("fixtures/audio/tagged-reference.aiff", &decoded);
    try std.testing.expectEqual(@as(usize, 8_820), result.frames);
    try std.testing.expectEqual(@as(u32, 44_100), result.decoder_format.sample_rate);
    try std.testing.expectEqual(@as(u16, 16), result.decoder_format.bits_per_sample);
}

test "the sample rate is read from an 80-bit extended float" {
    try std.testing.expectEqual(@as(?u32, 44_100), extendedToRate("\x40\x0e\xac\x44\x00\x00\x00\x00\x00\x00"));
    try std.testing.expectEqual(@as(?u32, 48_000), extendedToRate("\x40\x0e\xbb\x80\x00\x00\x00\x00\x00\x00"));
    try std.testing.expectEqual(@as(?u32, null), extendedToRate(&@as([10]u8, @splat(0))));
}

test "integer AIFF samples read left-justified and agree with the float read" {
    const cases = [_]struct { encoding: Encoding, bytes: []const u8, expected: i32 }{
        .{ .encoding = .big_integer, .bytes = "\x80", .expected = std.math.minInt(i32) },
        .{ .encoding = .big_integer, .bytes = "\x7f", .expected = 0x7f00_0000 },
        .{ .encoding = .big_integer, .bytes = "\xff\xfe", .expected = -0x20000 },
        .{ .encoding = .little_integer, .bytes = "\xfe\xff", .expected = -0x20000 },
        .{ .encoding = .big_integer, .bytes = "\x12\x34\x56", .expected = 0x1234_5600 },
        .{ .encoding = .little_integer, .bytes = "\x56\x34\x92", .expected = @bitCast(@as(u32, 0x9234_5600)) },
        .{ .encoding = .big_integer, .bytes = "\x91\x23\x45\x7f", .expected = @bitCast(@as(u32, 0x9123_457f)) },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, decodeInteger(case.encoding, case.bytes));
        try std.testing.expectEqual(
            decodeSample(case.encoding, case.bytes),
            decoder_api.integerSampleToFloat(decodeInteger(case.encoding, case.bytes)),
        );
    }
}

test "a compressed AIFC is refused rather than read as PCM" {
    try std.testing.expectError(error.UnsupportedAiffCompression, compression("ima4", 16));
}

fn monoAiff(buffer: []u8, frames: u32, bits: u16, sound: ?[]const u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    const ssnd_bytes: u32 = if (sound) |samples| 16 + @as(u32, @intCast(samples.len + (samples.len & 1))) else 0;
    try writer.writeAll("FORM");
    try writer.writeInt(u32, 4 + 26 + ssnd_bytes, .big);
    try writer.writeAll("AIFFCOMM");
    try writer.writeInt(u32, 18, .big);
    try writer.writeInt(u16, 1, .big);
    try writer.writeInt(u32, frames, .big);
    try writer.writeInt(u16, bits, .big);
    try writer.writeAll("\x40\x0e\xac\x44\x00\x00\x00\x00\x00\x00");
    if (sound) |samples| {
        try writer.writeAll("SSND");
        try writer.writeInt(u32, @intCast(8 + samples.len), .big);
        try writer.writeInt(u64, 0, .big);
        try writer.writeAll(samples);
        if (samples.len & 1 == 1) try writer.writeByte(0);
    }
    return writer.buffered();
}

test "an AIFF whose COMM declares more frames than SSND holds plays what is there and reports truncation" {
    var buffer: [128]u8 = undefined;
    var source: storage.MemorySource = .{ .bytes = try monoAiff(&buffer, 10, 16, "\x00\x01\x00\x02\x00\x03\x00\x04") };
    var decoder = try openDecoder(std.testing.allocator, source.readable());
    defer decoder.deinit();
    try std.testing.expectEqual(@as(?u64, 4), decoder.frame_count);
    var samples: [16]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try decoder.readFrames(&samples));
    try std.testing.expectEqual(@as(usize, 0), try decoder.readFrames(&samples));
    try std.testing.expectEqual(@as(?decoder_api.Damage, error.TruncatedAiff), decoder.damage());
}

test "an AIFF whose SSND holds at least the COMM frames reports no damage" {
    var buffer: [128]u8 = undefined;
    for ([_]u32{ 4, 3 }) |frames| {
        var source: storage.MemorySource = .{ .bytes = try monoAiff(&buffer, frames, 16, "\x00\x01\x00\x02\x00\x03\x00\x04") };
        var decoder = try openDecoder(std.testing.allocator, source.readable());
        defer decoder.deinit();
        try std.testing.expectEqual(@as(?u64, frames), decoder.frame_count);
        try std.testing.expectEqual(@as(?decoder_api.Damage, null), decoder.damage());
    }
}

test "an AIFF with no SSND chunk is refused as missing its sound" {
    var buffer: [128]u8 = undefined;
    for ([_]u32{ 0, 10 }) |frames| {
        var source: storage.MemorySource = .{ .bytes = try monoAiff(&buffer, frames, 16, null) };
        try std.testing.expectError(error.MissingSoundChunk, openDecoder(std.testing.allocator, source.readable()));
    }
}

test "an 8-bit AIFF reports signed 8-bit samples and decodes them as signed" {
    var buffer: [128]u8 = undefined;
    var source: storage.MemorySource = .{ .bytes = try monoAiff(&buffer, 3, 8, "\x80\x00\x40") };
    var decoder = try openDecoder(std.testing.allocator, source.readable());
    defer decoder.deinit();
    try std.testing.expectEqual(audio_pcm.SampleFormat.signed_8, decoder.source_format.?.sample_format);
    try std.testing.expectEqual(@as(u16, 8), decoder.source_format.?.bits_per_sample);
    var samples: [3]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try decoder.readFrames(&samples));
    try std.testing.expectEqualSlices(f32, &.{ -1.0, 0.0, 0.5 }, &samples);
    try std.testing.expectEqual(@as(?decoder_api.Damage, null), decoder.damage());
}
