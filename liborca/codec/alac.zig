//! Apple Lossless decoding, over Apple's reference decoder behind
//! `alac_shim.cpp`. One packet in, one block of float frames out; the MP4
//! container around it is `mp4.zig`'s.

const std = @import("std");
const engine_api = @import("engine.zig");

const Info = extern struct {
    frame_length: u32,
    bit_depth: u32,
    channels: u32,
    sample_rate: u32,
};

extern fn orca_alac_decoder_create(config: [*]const u8, config_size: u32, info: *Info) ?*anyopaque;
extern fn orca_alac_decoder_destroy(decoder: ?*anyopaque) void;
extern fn orca_alac_decoder_decode(
    decoder: ?*anyopaque,
    packet: [*]const u8,
    packet_size: u32,
    output: [*]f32,
    frames_written: *u32,
) i32;

extern fn orca_alac_decoder_decode_i32(
    decoder: ?*anyopaque,
    packet: [*]const u8,
    packet_size: u32,
    output: [*]i32,
    frames_written: *u32,
) i32;

pub fn open(config: []const u8) !engine_api.Engine {
    var info: Info = undefined;
    const native = orca_alac_decoder_create(
        config.ptr,
        std.math.cast(u32, config.len) orelse return error.InvalidAlac,
        &info,
    ) orelse return error.InvalidAlac;
    errdefer orca_alac_decoder_destroy(native);
    return .{
        .context = native,
        .vtable = &vtable,
        .max_packet_frames = info.frame_length,
        .channels = std.math.cast(u16, info.channels) orelse return error.InvalidAlac,
        .sample_rate = info.sample_rate,
        .bits_per_sample = std.math.cast(u16, info.bit_depth) orelse return error.InvalidAlac,
        .preroll_packets = 0,
    };
}

fn decode(context: *anyopaque, packet: []const u8, output: []f32) !u32 {
    var frames: u32 = 0;
    if (orca_alac_decoder_decode(
        context,
        packet.ptr,
        std.math.cast(u32, packet.len) orelse return error.AlacDecodeFailed,
        output.ptr,
        &frames,
    ) != 0) return error.AlacDecodeFailed;
    return frames;
}

fn decodeI32(context: *anyopaque, packet: []const u8, output: []i32) !u32 {
    var frames: u32 = 0;
    if (orca_alac_decoder_decode_i32(
        context,
        packet.ptr,
        std.math.cast(u32, packet.len) orelse return error.AlacDecodeFailed,
        output.ptr,
        &frames,
    ) != 0) return error.AlacDecodeFailed;
    return frames;
}

/// Every ALAC packet decodes independently, so a seek needs no reset.
fn reset(_: *anyopaque) void {}

fn deinit(context: *anyopaque) void {
    orca_alac_decoder_destroy(context);
}

const vtable: engine_api.Engine.VTable = .{
    .decode = decode,
    .decode_i32 = decodeI32,
    .reset = reset,
    .deinit = deinit,
};
