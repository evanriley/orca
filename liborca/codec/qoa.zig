const std = @import("std");
const native_qoa = @import("qoa");
const decoder_api = @import("decoder.zig");
const storage = @import("../storage/root.zig");

const NativeDecoder = native_qoa.Decoder(8);

const Context = struct {
    allocator: std.mem.Allocator,
    reader_buffer: [8192]u8,
    source_reader: storage.BufferedSourceReader,
    native: NativeDecoder,
    scratch: [4096]i16,
};

pub fn openDecoder(
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
) !decoder_api.Decoder {
    const format = try validateSource(source);
    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    context.allocator = allocator;
    context.source_reader = .init(source, &context.reader_buffer);
    context.native = try NativeDecoder.init(&context.source_reader.interface);
    return .{
        .context = context,
        .vtable = &vtable,
        .format = .{
            .sample_format = .float_32,
            .channels = format.channels,
            .sample_rate = format.sample_rate,
            .bits_per_sample = 32,
            .bytes_per_frame = try std.math.mul(u16, context.native.channels, 4),
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

fn readFrames(context_ptr: *anyopaque, output: []f32) !usize {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const channels = context.native.channels;
    var output_offset: usize = 0;
    while (output_offset < output.len) {
        const wanted = @min(output.len - output_offset, context.scratch.len);
        const aligned = wanted - wanted % channels;
        if (aligned == 0) break;
        const samples = try context.native.read(context.scratch[0..aligned]);
        for (output[output_offset..][0..samples.len], samples) |*destination, sample| {
            destination.* = @as(f32, @floatFromInt(sample)) / 32768.0;
        }
        output_offset += samples.len;
        if (samples.len < aligned) break;
    }
    return output_offset / channels;
}

fn seek(context_ptr: *anyopaque, frame: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (frame == context.native.current_frame) return;
    return error.UnsupportedSeek;
}

fn deinit(context_ptr: *anyopaque) void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.allocator.destroy(context);
}

const vtable: decoder_api.Decoder.VTable = .{
    .read_frames = readFrames,
    .seek = seek,
    .deinit = deinit,
};

test "native Zig QOA adapter decodes generated lossy audio" {
    var local = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/generated-reference.qoa",
    );
    defer local.close();
    var decoder = try openDecoder(std.testing.allocator, local.readable());
    defer decoder.deinit();
    try std.testing.expectEqual(@as(u16, 1), decoder.format.channels);
    try std.testing.expectEqual(@as(u32, 48_000), decoder.format.sample_rate);
    try std.testing.expectEqual(@as(?u64, 20), decoder.frame_count);
    var samples: [20]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 20), try decoder.readFrames(&samples));
    for (samples) |sample| try std.testing.expect(std.math.isFinite(sample));
}

test "malformed QOA frame size fails without entering native decoder" {
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
