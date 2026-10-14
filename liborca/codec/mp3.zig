const std = @import("std");
const decoder_api = @import("decoder.zig");
const storage = @import("../storage/root.zig");

const Handle = opaque {};

const FrameInfo = extern struct {
    version: c_int,
    layer: c_int,
    rate: c_long,
    mode: c_int,
    mode_ext: c_int,
    framesize: c_int,
    flags: c_int,
    emphasis: c_int,
    bitrate: c_int,
    abr_rate: c_int,
    vbr: c_int,
};

extern fn mpg123_new(decoder: ?[*:0]const u8, error_code: ?*c_int) ?*Handle;
extern fn mpg123_delete(handle: *Handle) void;
extern fn mpg123_param2(handle: *Handle, parameter: c_int, value: c_long, float_value: f64) c_int;
extern fn mpg123_format_none(handle: *Handle) c_int;
extern fn mpg123_format2(handle: *Handle, rate: c_long, channels: c_int, encodings: c_int) c_int;
extern fn mpg123_reader64(
    handle: *Handle,
    read: *const fn (?*anyopaque, ?*anyopaque, usize, *usize) callconv(.c) c_int,
    lseek: *const fn (?*anyopaque, i64, c_int) callconv(.c) i64,
    cleanup: ?*const fn (?*anyopaque) callconv(.c) void,
) c_int;
extern fn mpg123_open_handle(handle: *Handle, io_handle: ?*anyopaque) c_int;
extern fn mpg123_close(handle: *Handle) c_int;
extern fn mpg123_getformat(handle: *Handle, rate: *c_long, channels: *c_int, encoding: *c_int) c_int;
extern fn mpg123_info2(handle: *Handle, info: *FrameInfo) c_int;
extern fn mpg123_length64(handle: *Handle) i64;
extern fn mpg123_read(handle: *Handle, output: ?*anyopaque, output_bytes: usize, done: *usize) c_int;
extern fn mpg123_seek64(handle: *Handle, sample_offset: i64, whence: c_int) i64;
extern fn mpg123_errcode(handle: *Handle) c_int;

const status_done: c_int = -12;
const status_new_format: c_int = -11;
const status_ok: c_int = 0;

const error_out_of_memory: c_int = 7;
const error_no_buffers: c_int = 11;
const error_reader: c_int = 18;
const error_out_of_sync: c_int = 27;
const error_resync_fail: c_int = 28;

const parameter_flags: c_int = 1;
const parameter_resync_limit: c_int = 14;
const parameter_index_size: c_int = 15;
const parameter_preframes: c_int = 16;

const flag_quiet: c_long = 0x20;
const flag_gapless: c_long = 0x40;
const flag_skip_id3v2: c_long = 0x2000;

const channels_mono: c_int = 1;
const channels_stereo: c_int = 2;
const encoding_float_32: c_int = 0x200;

const seek_set: c_int = 0;
const seek_current: c_int = 1;
const seek_end: c_int = 2;

const resync_limit_bytes: c_long = 128 * 1024;
const frame_index_entries: c_long = 1000;
const reservoir_preframes: c_long = 18;
const seek_ceiling_frames: u64 = 1 << 40;

const Context = struct {
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
    handle: *Handle,
    position: u64 = 0,
    read_failure: ?anyerror = null,
    channels: u16 = 0,
    sample_rate: u32 = 0,
};

pub fn openDecoder(
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
) !decoder_api.Decoder {
    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    var new_status: c_int = status_ok;
    context.* = .{
        .allocator = allocator,
        .source = source,
        .handle = mpg123_new(null, &new_status) orelse return switch (new_status) {
            error_out_of_memory, error_no_buffers => error.OutOfMemory,
            else => error.Mp3DecoderSetupFailed,
        },
    };
    errdefer mpg123_delete(context.handle);
    try configure(context.handle);
    if (mpg123_open_handle(context.handle, context) != status_ok)
        return failure(context, mpg123_errcode(context.handle));
    errdefer _ = mpg123_close(context.handle);

    var rate: c_long = 0;
    var channels: c_int = 0;
    var encoding: c_int = 0;
    switch (mpg123_getformat(context.handle, &rate, &channels, &encoding)) {
        status_ok => {},
        status_done => return error.Mp3SyncNotFound,
        else => return switch (mpg123_errcode(context.handle)) {
            error_out_of_sync, error_resync_fail => error.Mp3SyncNotFound,
            else => |code| failure(context, code),
        },
    }
    if (encoding != encoding_float_32) return error.Mp3DecoderSetupFailed;
    context.channels = std.math.cast(u16, channels) orelse return error.InvalidMp3;
    context.sample_rate = std.math.cast(u32, rate) orelse return error.InvalidMp3;
    if (context.channels == 0 or context.sample_rate == 0) return error.InvalidMp3;

    var info: FrameInfo = undefined;
    if (mpg123_info2(context.handle, &info) != status_ok) return error.InvalidMp3;
    const codec: []const u8 = switch (info.layer) {
        1 => decoder_api.codec_id.mp1,
        2 => decoder_api.codec_id.mp2,
        3 => decoder_api.codec_id.mp3,
        else => return error.InvalidMp3,
    };
    const length = mpg123_length64(context.handle);

    return .{
        .context = context,
        .vtable = &vtable,
        .codec = codec,
        .source_format = null,
        .format = .{
            .sample_format = .float_32,
            .channels = context.channels,
            .sample_rate = context.sample_rate,
            .bits_per_sample = 32,
            .bytes_per_frame = try std.math.mul(u16, context.channels, @sizeOf(f32)),
        },
        .frame_count = if (length < 0) null else @intCast(length),
    };
}

fn configure(handle: *Handle) !void {
    const parameters = [_]struct { c_int, c_long }{
        .{ parameter_flags, flag_quiet | flag_gapless | flag_skip_id3v2 },
        .{ parameter_resync_limit, resync_limit_bytes },
        .{ parameter_index_size, frame_index_entries },
        .{ parameter_preframes, reservoir_preframes },
    };
    for (parameters) |parameter| {
        if (mpg123_param2(handle, parameter[0], parameter[1], 0) != status_ok)
            return error.Mp3DecoderSetupFailed;
    }
    if (mpg123_format_none(handle) != status_ok) return error.Mp3DecoderSetupFailed;
    if (mpg123_format2(handle, 0, channels_mono | channels_stereo, encoding_float_32) != status_ok)
        return error.Mp3DecoderSetupFailed;
    if (mpg123_reader64(handle, readSource, seekSource, null) != status_ok)
        return error.Mp3DecoderSetupFailed;
}

fn readSource(io_handle: ?*anyopaque, buffer: ?*anyopaque, count: usize, got: *usize) callconv(.c) c_int {
    const context: *Context = @ptrCast(@alignCast(io_handle.?));
    got.* = 0;
    if (count == 0) return 0;
    const bytes: [*]u8 = @ptrCast(buffer orelse return -1);
    const read = context.source.readAt(context.position, bytes[0..count]) catch |err| {
        context.read_failure = err;
        return -1;
    };
    context.position += read;
    got.* = read;
    return 0;
}

fn seekSource(io_handle: ?*anyopaque, offset: i64, whence: c_int) callconv(.c) i64 {
    const context: *Context = @ptrCast(@alignCast(io_handle.?));
    const base: i64 = switch (whence) {
        seek_set => 0,
        seek_current => std.math.cast(i64, context.position) orelse return -1,
        seek_end => std.math.cast(i64, context.source.size()) orelse return -1,
        else => return -1,
    };
    const target = std.math.add(i64, base, offset) catch return -1;
    if (target < 0) return -1;
    context.position = @intCast(target);
    return target;
}

fn failure(context: *Context, code: c_int) anyerror {
    return switch (code) {
        error_out_of_memory, error_no_buffers => error.OutOfMemory,
        error_reader => context.read_failure orelse error.InvalidMp3,
        else => error.InvalidMp3,
    };
}

fn confirmFormat(context: *Context) !void {
    var rate: c_long = 0;
    var channels: c_int = 0;
    var encoding: c_int = 0;
    if (mpg123_getformat(context.handle, &rate, &channels, &encoding) != status_ok)
        return failure(context, mpg123_errcode(context.handle));
    if (encoding != encoding_float_32 or channels != context.channels or rate != context.sample_rate)
        return error.ChangingMp3Format;
}

fn readFrames(context_ptr: *anyopaque, output: []f32) !usize {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const frame_bytes = @as(usize, context.channels) * @sizeOf(f32);
    const capacity_bytes = output.len / context.channels * frame_bytes;
    const bytes: [*]u8 = @ptrCast(output.ptr);
    var produced_bytes: usize = 0;
    while (produced_bytes < capacity_bytes) {
        var done: usize = 0;
        const status = mpg123_read(
            context.handle,
            bytes + produced_bytes,
            capacity_bytes - produced_bytes,
            &done,
        );
        produced_bytes += done;
        switch (status) {
            status_ok => if (done == 0) break,
            status_done => break,
            status_new_format => try confirmFormat(context),
            else => return failure(context, mpg123_errcode(context.handle)),
        }
    }
    if (produced_bytes % frame_bytes != 0) return error.InvalidMp3;
    return produced_bytes / frame_bytes;
}

fn seek(context_ptr: *anyopaque, frame: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const target: i64 = @intCast(@min(frame, seek_ceiling_frames));
    if (mpg123_seek64(context.handle, target, seek_set) < 0)
        return failure(context, mpg123_errcode(context.handle));
}

fn deinit(context_ptr: *anyopaque) void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const allocator = context.allocator;
    _ = mpg123_close(context.handle);
    mpg123_delete(context.handle);
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

fn readWhole(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var local = try openFixture(path);
    defer local.close();
    const size: usize = @intCast(local.readable().size());
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    if (try local.readable().readAt(0, bytes) != size) return error.ShortFixtureRead;
    return bytes;
}

test "ID3v2 tagged MP3 decodes at its declared rate and channel count" {
    var local = try openFixture("fixtures/audio/tagged-reference.mp3");
    defer local.close();
    var decoder = try openDecoder(testing.allocator, local.readable());
    defer decoder.deinit();
    try testing.expectEqualStrings("mp3", decoder.codec);
    try testing.expect(decoder.source_format == null);
    try testing.expectEqual(@as(u32, 44_100), decoder.format.sample_rate);
    try testing.expectEqual(@as(u16, 2), decoder.format.channels);
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
    try testing.expectEqual(@as(?u64, 88_200), decoder.frame_count);
    try testing.expectEqual(@as(u64, 88_200), try drain(&decoder));
}

test "a constant bitrate stream without a Xing header still reports a length" {
    var local = try openFixture("fixtures/audio/cbr-noxing-reference.mp3");
    defer local.close();
    var decoder = try openDecoder(testing.allocator, local.readable());
    defer decoder.deinit();
    const estimated = decoder.frame_count.?;
    const decoded = try drain(&decoder);
    const slack: u64 = 1152;
    try testing.expect(decoded + slack >= estimated and estimated + slack >= decoded);
}

test "seeking a constant bitrate stream lands on the requested frame" {
    var local = try openFixture("fixtures/audio/cbr-noxing-reference.mp3");
    defer local.close();
    var decoder = try openDecoder(testing.allocator, local.readable());
    defer decoder.deinit();
    const decoded = try drain(&decoder);
    const target = decoded / 2;
    try decoder.seek(target);
    try testing.expectEqual(decoded - target, try drain(&decoder));
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
    try testing.expectEqual(total - target, try drain(&decoder));
}

test "a sought variable bitrate stream yields the samples of a sequential decode" {
    const allocator = testing.allocator;
    var local = try openFixture("fixtures/audio/vbr-xing-reference.mp3");
    defer local.close();
    var decoder = try openDecoder(allocator, local.readable());
    defer decoder.deinit();
    const channels: usize = decoder.format.channels;
    const total: usize = @intCast(decoder.frame_count.?);
    const whole = try allocator.alloc(f32, total * channels);
    defer allocator.free(whole);
    try testing.expectEqual(total, try decoder.readFrames(whole));

    const target = total / 3;
    try decoder.seek(target);
    var tail: [1024]f32 = undefined;
    const usable = tail.len - tail.len % channels;
    const read = try decoder.readFrames(tail[0..usable]);
    try testing.expectEqual(usable / channels, read);
    try testing.expectEqualSlices(f32, whole[target * channels ..][0..usable], tail[0..usable]);
}

test "a file holding no MPEG frame is refused before any decoder is created" {
    var bytes: [4096]u8 = @splat(0x00);
    var memory: storage.MemorySource = .{ .bytes = &bytes };
    try testing.expectError(
        error.Mp3SyncNotFound,
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
    const decoded = try drain(&decoder);
    const target = decoded / 2;
    try decoder.seek(target);
    try testing.expectEqual(decoded - target, try drain(&decoder));
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
        decoder.seek((decoder.frame_count orelse 0) / 2) catch continue;
        _ = drain(&decoder) catch continue;
    }
}

test "seeking beyond the declared length clamps to the end of the stream" {
    var local = try openFixture("fixtures/audio/vbr-xing-reference.mp3");
    defer local.close();
    var decoder = try openDecoder(testing.allocator, local.readable());
    defer decoder.deinit();
    try decoder.seek(decoder.frame_count.? + 1);
    try testing.expectEqual(@as(u64, 0), try drain(&decoder));
}

test "an MPEG-1 Layer II stream decodes at its rate, channel count and length" {
    var local = try openFixture("fixtures/audio/layer2-reference.mp2");
    defer local.close();
    var decoder = try openDecoder(testing.allocator, local.readable());
    defer decoder.deinit();
    try testing.expectEqualStrings("mp2", decoder.codec);
    try testing.expectEqual(@as(u32, 48_000), decoder.format.sample_rate);
    try testing.expectEqual(@as(u16, 2), decoder.format.channels);
    try testing.expectEqual(@as(?u64, 48_384), decoder.frame_count);
    try testing.expectEqual(@as(u64, 48_384), try drain(&decoder));
}
