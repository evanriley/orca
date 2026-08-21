const std = @import("std");
const audio_pcm = @import("../audio/pcm.zig");
const storage = @import("../storage/root.zig");

pub const SampleFormat = audio_pcm.SampleFormat;
pub const Format = audio_pcm.Format;

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
                const encoding = little16(fmt[0..2]);
                const channels = little16(fmt[2..4]);
                const sample_rate = little32(fmt[4..8]);
                const block_align = little16(fmt[12..14]);
                const bits = little16(fmt[14..16]);
                if (channels == 0 or sample_rate == 0 or block_align == 0) return error.InvalidWav;
                parsed_format = .{
                    .sample_format = try sampleFormat(encoding, bits),
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
};

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
}
