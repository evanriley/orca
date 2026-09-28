const std = @import("std");
const audio_pcm = @import("../audio/pcm.zig");
const decoder_api = @import("decoder.zig");
const storage = @import("../storage/root.zig");

pub const SampleFormat = audio_pcm.SampleFormat;
pub const Format = audio_pcm.Format;

const DecoderContext = struct {
    allocator: std.mem.Allocator,
    reader: Reader,
    scratch: []u8,
    position: u64 = 0,
};

pub fn openDecoder(
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
) !decoder_api.Decoder {
    const reader = try Reader.open(source);
    const context = try allocator.create(DecoderContext);
    errdefer allocator.destroy(context);
    const scratch_len = try std.math.mul(usize, 4096, reader.format.bytes_per_frame);
    const scratch = try allocator.alloc(u8, scratch_len);
    errdefer allocator.free(scratch);
    context.* = .{ .allocator = allocator, .reader = reader, .scratch = scratch };
    return .{
        .context = context,
        .vtable = &decoder_vtable,
        // RIFF/WAVE is a container: what it holds is integer PCM or IEEE
        // float, and only the format chunk says which.
        .codec = switch (reader.format.sample_format) {
            .float_32, .float_64 => decoder_api.codec_id.pcm_float,
            else => decoder_api.codec_id.pcm,
        },
        .source_format = reader.format,
        .format = .{
            .sample_format = .float_32,
            .channels = reader.format.channels,
            .sample_rate = reader.format.sample_rate,
            .bits_per_sample = 32,
            .bytes_per_frame = try std.math.mul(u16, reader.format.channels, 4),
        },
        .frame_count = reader.frameCount(),
    };
}

fn decoderRead(context_ptr: *anyopaque, output: []f32) !usize {
    const context: *DecoderContext = @ptrCast(@alignCast(context_ptr));
    const frames = try context.reader.readFramesF32(context.position, output, context.scratch);
    context.position += frames;
    return frames;
}

fn decoderSeek(context_ptr: *anyopaque, frame: u64) !void {
    const context: *DecoderContext = @ptrCast(@alignCast(context_ptr));
    context.position = @min(frame, context.reader.frameCount());
}

fn decoderDeinit(context_ptr: *anyopaque) void {
    const context: *DecoderContext = @ptrCast(@alignCast(context_ptr));
    const allocator = context.allocator;
    allocator.free(context.scratch);
    allocator.destroy(context);
}

const decoder_vtable: @import("decoder.zig").Decoder.VTable = .{
    .read_frames = decoderRead,
    .seek = decoderSeek,
    .deinit = decoderDeinit,
};

pub const Reader = struct {
    source: storage.ReadableSource,
    format: Format,
    data_offset: u64,
    data_bytes: u64,

    pub fn open(source: storage.ReadableSource) !Reader {
        var riff: [12]u8 = undefined;
        if (try source.readAt(0, &riff) != riff.len) return error.TruncatedWav;
        if (!std.mem.eql(u8, riff[0..4], "RIFF") or !std.mem.eql(u8, riff[8..12], "WAVE")) {
            return error.InvalidWav;
        }

        var offset: u64 = 12;
        var parsed_format: ?Format = null;
        var data_offset: ?u64 = null;
        var data_bytes: u64 = 0;
        while (offset + 8 <= source.size()) {
            var chunk: [8]u8 = undefined;
            if (try source.readAt(offset, &chunk) != chunk.len) return error.TruncatedWav;
            const chunk_size = little32(chunk[4..8]);
            const payload_offset = offset + 8;
            if (payload_offset + chunk_size > source.size()) return error.TruncatedWav;
            if (std.mem.eql(u8, chunk[0..4], "fmt ")) {
                if (chunk_size < 16) return error.InvalidWav;
                var fmt: [16]u8 = undefined;
                if (try source.readAt(payload_offset, &fmt) != fmt.len) return error.TruncatedWav;
                const encoding = try formatTag(source, payload_offset, chunk_size, little16(fmt[0..2]));
                const channels = little16(fmt[2..4]);
                const sample_rate = little32(fmt[4..8]);
                const block_align = little16(fmt[12..14]);
                const bits = little16(fmt[14..16]);
                if (channels == 0 or sample_rate == 0 or block_align == 0) return error.InvalidWav;
                const decoded_format = try sampleFormat(encoding, bits);
                const expected_align = std.math.mul(u16, channels, bits / 8) catch
                    return error.InvalidWav;
                if (block_align != expected_align) return error.InvalidWav;
                parsed_format = .{
                    .sample_format = decoded_format,
                    .channels = channels,
                    .sample_rate = sample_rate,
                    .bits_per_sample = bits,
                    .bytes_per_frame = block_align,
                };
            } else if (std.mem.eql(u8, chunk[0..4], "data")) {
                data_offset = payload_offset;
                data_bytes = chunk_size;
            }
            offset = payload_offset + chunk_size + (chunk_size & 1);
            if (parsed_format != null and data_offset != null) break;
        }
        const format = parsed_format orelse return error.MissingFormatChunk;
        return .{
            .source = source,
            .format = format,
            .data_offset = data_offset orelse return error.MissingDataChunk,
            .data_bytes = data_bytes,
        };
    }

    pub fn frameCount(self: Reader) u64 {
        return self.data_bytes / self.format.bytes_per_frame;
    }

    pub fn readFrames(self: Reader, frame_offset: u64, output: []u8) !usize {
        if (output.len % self.format.bytes_per_frame != 0) return error.UnalignedPcmBuffer;
        const byte_offset = std.math.mul(u64, frame_offset, self.format.bytes_per_frame) catch
            return error.FrameOffsetOverflow;
        if (byte_offset >= self.data_bytes) return 0;
        const available: usize = @intCast(@min(self.data_bytes - byte_offset, output.len));
        const read = try self.source.readAt(self.data_offset + byte_offset, output[0..available]);
        return read / self.format.bytes_per_frame;
    }

    /// Decode interleaved WAV samples into Orca's canonical float32 form.
    /// Callers own scratch storage so steady-state source preparation allocates
    /// nothing. Returns whole frames and never reads past the data chunk.
    pub fn readFramesF32(
        self: Reader,
        frame_offset: u64,
        output: []f32,
        scratch: []u8,
    ) !usize {
        if (output.len % self.format.channels != 0) return error.UnalignedPcmBuffer;
        const output_frames = output.len / self.format.channels;
        const scratch_frames = scratch.len / self.format.bytes_per_frame;
        const requested_frames = @min(output_frames, scratch_frames);
        if (requested_frames == 0) return 0;
        const byte_count = requested_frames * self.format.bytes_per_frame;
        const frames = try self.readFrames(frame_offset, scratch[0..byte_count]);
        const sample_bytes = self.format.bits_per_sample / 8;
        const sample_count = frames * self.format.channels;
        for (output[0..sample_count], 0..) |*sample, index| {
            const start = index * sample_bytes;
            sample.* = decodeSample(self.format.sample_format, scratch[start .. start + sample_bytes]);
        }
        return frames;
    }
};

fn decodeSample(format: SampleFormat, bytes: []const u8) f32 {
    return switch (format) {
        .unsigned_8 => (@as(f32, @floatFromInt(bytes[0])) - 128.0) / 128.0,
        .signed_16 => @as(f32, @floatFromInt(@as(i16, @bitCast(little16(bytes[0..2]))))) /
            32_768.0,
        .signed_24 => blk: {
            const raw = @as(u32, bytes[0]) |
                (@as(u32, bytes[1]) << 8) |
                (@as(u32, bytes[2]) << 16);
            const signed: i32 = if (raw & 0x800000 != 0)
                @bitCast(raw | 0xff000000)
            else
                @intCast(raw);
            break :blk @as(f32, @floatFromInt(signed)) / 8_388_608.0;
        },
        .signed_32 => @as(f32, @floatFromInt(@as(i32, @bitCast(little32(bytes[0..4]))))) /
            2_147_483_648.0,
        .float_32 => @bitCast(little32(bytes[0..4])),
        .float_64 => @floatCast(@as(f64, @bitCast(little64(bytes[0..8])))),
    };
}

const wave_format_extensible: u16 = 0xfffe;
/// Every KSDATAFORMAT SubFormat GUID for a classic format tag shares these
/// twelve bytes after its leading two-byte tag.
const subformat_guid_tail = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 };

/// The format tag the samples are in. WAVE_FORMAT_EXTENSIBLE -- what FFmpeg
/// and most DAWs write for anything past 16-bit stereo -- carries the real tag
/// in the first two bytes of its SubFormat GUID, 24 bytes into the chunk.
fn formatTag(source: storage.ReadableSource, fmt_offset: u64, fmt_size: u32, tag: u16) !u16 {
    if (tag != wave_format_extensible) return tag;
    if (fmt_size < 40) return error.InvalidWav;
    var guid: [16]u8 = undefined;
    if (try source.readAt(fmt_offset + 24, &guid) != guid.len) return error.TruncatedWav;
    if (!std.mem.eql(u8, guid[2..], &subformat_guid_tail)) return error.UnsupportedWavEncoding;
    return little16(guid[0..2]);
}

fn sampleFormat(encoding: u16, bits: u16) !SampleFormat {
    return switch (encoding) {
        1 => switch (bits) {
            8 => .unsigned_8,
            16 => .signed_16,
            24 => .signed_24,
            32 => .signed_32,
            else => error.UnsupportedPcmFormat,
        },
        3 => switch (bits) {
            32 => .float_32,
            64 => .float_64,
            else => error.UnsupportedPcmFormat,
        },
        else => error.UnsupportedWavEncoding,
    };
}

fn little16(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn little32(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn little64(bytes: *const [8]u8) u64 {
    return @as(u64, little32(bytes[0..4])) |
        (@as(u64, little32(bytes[4..8])) << 32);
}

test "reads bounded PCM frames from a generated WAV" {
    const wav = "RIFF" ++ "\x28\x00\x00\x00" ++ "WAVE" ++
        "fmt " ++ "\x10\x00\x00\x00" ++
        "\x01\x00\x01\x00" ++ "\x44\xac\x00\x00" ++
        "\x88\x58\x01\x00" ++ "\x02\x00\x10\x00" ++
        "data" ++ "\x04\x00\x00\x00" ++ "\x01\x00\xff\x7f";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "test.wav", .data = wav });
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/test.wav",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(path);
    var local = try storage.LocalFileSource.open(std.testing.io, path);
    defer local.close();

    const reader = try Reader.open(local.readable());
    try std.testing.expectEqual(@as(u32, 44_100), reader.format.sample_rate);
    try std.testing.expectEqual(@as(u64, 2), reader.frameCount());
    var pcm: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try reader.readFrames(0, &pcm));
    try std.testing.expectEqualSlices(u8, "\x01\x00\xff\x7f", &pcm);

    var decoded: [2]f32 = undefined;
    var scratch: [4]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 2),
        try reader.readFramesF32(0, &decoded, &scratch),
    );
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 32768.0), decoded[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 32767.0 / 32768.0), decoded[1], 0.000001);
}

test "canonical conversion covers integer and floating WAV sample forms" {
    try std.testing.expectEqual(@as(f32, -1), decodeSample(.unsigned_8, "\x00"));
    try std.testing.expectEqual(@as(f32, 0), decodeSample(.unsigned_8, "\x80"));
    try std.testing.expectEqual(@as(f32, -1), decodeSample(.signed_16, "\x00\x80"));
    try std.testing.expectEqual(@as(f32, -1), decodeSample(.signed_24, "\x00\x00\x80"));
    try std.testing.expectEqual(@as(f32, -1), decodeSample(.signed_32, "\x00\x00\x00\x80"));
    try std.testing.expectEqual(@as(f32, 0.5), decodeSample(.float_32, "\x00\x00\x00\x3f"));
    try std.testing.expectEqual(
        @as(f32, 0.5),
        decodeSample(.float_64, "\x00\x00\x00\x00\x00\x00\xe0\x3f"),
    );
}

test "a WAVE_FORMAT_EXTENSIBLE file decodes as the format its SubFormat names" {
    var extensible_file = try storage.LocalFileSource.open(std.testing.io, "fixtures/audio/extensible-reference.wav");
    defer extensible_file.close();
    var extensible = try openDecoder(std.testing.allocator, extensible_file.readable());
    defer extensible.deinit();
    try std.testing.expectEqual(SampleFormat.signed_24, extensible.source_format.?.sample_format);
    try std.testing.expectEqual(@as(?u64, 480), extensible.frame_count);

    // Encoded from the 16-bit FLAC fixture, so it must decode to the same
    // samples.
    var flac_file = try storage.LocalFileSource.open(std.testing.io, "fixtures/audio/generated-reference.flac");
    defer flac_file.close();
    var flac = try @import("flac.zig").openDecoder(std.testing.allocator, flac_file.readable());
    defer flac.deinit();
    var from_wav: [480 * 2]f32 = undefined;
    var from_flac: [480 * 2]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 480), try extensible.readFrames(&from_wav));
    try std.testing.expectEqual(@as(usize, 480), try flac.readFrames(&from_flac));
    try std.testing.expectEqualSlices(f32, &from_flac, &from_wav);
}
