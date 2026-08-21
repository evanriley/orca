const std = @import("std");
const native_flac = @import("flac");
const decoder_api = @import("decoder.zig");
const storage = @import("../storage/root.zig");

const Context = struct {
    allocator: std.mem.Allocator,
    reader_buffer: [8192]u8,
    source_reader: storage.BufferedSourceReader,
    native: native_flac.Decoder,
};

pub fn openDecoder(
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
) !decoder_api.Decoder {
    const format = try readFormat(source);
    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    context.source_reader = .init(source, &context.reader_buffer);
    context.allocator = allocator;
    context.native = try native_flac.Decoder.init(
        allocator,
        &context.source_reader.interface,
        .{
            .skip_metadata = true,
            .seek_impl = .{ .virtual = .{
                .context = context,
                .seekTo = seekBytes,
                .getPos = getBytePosition,
                .getEndPos = getEndPosition,
            } },
        },
    );
    return .{
        .context = context,
        .vtable = &vtable,
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

const StreamFormat = struct { channels: u16, sample_rate: u32, frame_count: u64 };

fn readFormat(source: storage.ReadableSource) !StreamFormat {
    var header: [26]u8 = undefined;
    if (try source.readAt(0, &header) != header.len) return error.TruncatedFlac;
    if (!std.mem.eql(u8, header[0..4], "fLaC")) return error.InvalidFlac;
    if (header[4] & 0x7f != 0 or
        header[5] != 0 or header[6] != 0 or header[7] != 34)
        return error.InvalidFlac;
    const stream_bits = big64(header[18..26]);
    const sample_rate: u32 = @intCast(stream_bits >> 44);
    const channels: u16 = @intCast(((stream_bits >> 41) & 0x7) + 1);
    const bits_per_sample = ((stream_bits >> 36) & 0x1f) + 1;
    if (sample_rate == 0 or bits_per_sample < 4) return error.InvalidFlac;
    return .{
        .channels = channels,
        .sample_rate = sample_rate,
        .frame_count = stream_bits & 0x0000000fffffffff,
    };
}

fn big64(bytes: *const [8]u8) u64 {
    var value: u64 = 0;
    for (bytes) |byte| value = (value << 8) | byte;
    return value;
}

fn readFrames(context_ptr: *anyopaque, output: []f32) !usize {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const samples = try context.native.read(f32, output);
    return samples.len / context.native.channels;
}

fn seek(context_ptr: *anyopaque, frame: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    try context.native.seekTo(frame);
}

fn deinit(context_ptr: *anyopaque) void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const allocator = context.allocator;
    context.native.deinit(allocator);
    allocator.destroy(context);
}

fn seekBytes(
    opaque_context: ?*anyopaque,
    _: *std.Io.Reader,
    offset: u64,
) error{ SeekFailed, OutOfBounds }!void {
    const context: *Context = @ptrCast(@alignCast(opaque_context.?));
    context.source_reader.seekTo(offset) catch |err| switch (err) {
        error.OutOfBounds => return error.OutOfBounds,
    };
}

fn getBytePosition(opaque_context: ?*anyopaque, _: *std.Io.Reader) error{SeekFailed}!u64 {
    const context: *Context = @ptrCast(@alignCast(opaque_context.?));
    return context.source_reader.logicalPosition();
}

fn getEndPosition(opaque_context: ?*anyopaque, _: *std.Io.Reader) error{SeekFailed}!u64 {
    const context: *Context = @ptrCast(@alignCast(opaque_context.?));
    return context.source_reader.source.size();
}

const vtable: decoder_api.Decoder.VTable = .{
    .read_frames = readFrames,
    .seek = seek,
    .deinit = deinit,
};

test "native Zig FLAC adapter decodes and seeks generated audio" {
    var local = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/generated-reference.flac",
    );
    defer local.close();
    var decoder = try openDecoder(std.testing.allocator, local.readable());
    defer decoder.deinit();
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
