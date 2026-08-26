const std = @import("std");
const native_flac = @import("flac");
const decoder_api = @import("decoder.zig");
const storage = @import("../storage/root.zig");

const Context = struct {
    allocator: std.mem.Allocator,
    reader_buffer: [8192]u8,
    source_reader: storage.BufferedSourceReader,
    native: native_flac.Decoder,
    /// Set once the stream has been seeked. See `readFrames` for why end of
    /// stream stops being an error after that point.
    sought: bool,
};

pub fn openDecoder(
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
) !decoder_api.Decoder {
    const format = try readFormat(source);
    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    context.sought = false;
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
};

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
        .bits_per_sample = @intCast(bits_per_sample),
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
    const samples = context.native.read(f32, output) catch |err| switch (err) {
        // The decoder raises `EndOfStream` when it reaches the end of the
        // stream having decoded a different number of frames than STREAMINFO
        // declared. Unsought, that genuinely means the file is truncated and
        // the caller should hear about it. After a seek it means nothing at
        // all: the frames before the seek target were never decoded, so the
        // running count cannot match the declared total and every correct
        // stream ends this way.
        //
        // Reporting it as a decode failure ended playback of the track at the
        // seek point, and because the Decoder contract signals end of input
        // with zero frames rather than an error, the caller could not tell
        // that apart from a corrupt file. Once sought, report the clean end.
        //
        // The cost is that a truncated file seeked into ends quietly instead
        // of erroring. That is the right trade for playback, and the unsought
        // path — every ordinary play from the beginning — still detects it.
        error.EndOfStream => if (context.sought) return 0 else return err,
        else => return err,
    };
    return samples.len / context.native.channels;
}

fn seek(context_ptr: *anyopaque, frame: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    try context.native.seekTo(frame);
    context.sought = true;
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
    try std.testing.expectEqual(@import("../audio/pcm.zig").SampleFormat.signed_16, decoder.source_format.?.sample_format);
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

test "reading to the end after a seek reports end of input rather than failing" {
    // Regression: playing a real FLAC album stalled on the first track with
    // 8,266 underruns. The decoder raises `EndOfStream` when its frame count
    // disagrees with STREAMINFO, which is unavoidable after a seek, so the
    // engine saw a decode failure instead of the end of the track and never
    // advanced. 90% of the target library is FLAC, so this path is the common
    // one, not an edge case.
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
