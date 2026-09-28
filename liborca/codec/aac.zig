//! AAC decoding (AAC-LC, HE-AAC v1/v2, xHE-AAC), over libxaac behind
//! `aac_shim.c`. One access unit in, one block of float frames out; the MP4
//! container around it is `mp4.zig`'s.

const std = @import("std");
const engine_api = @import("engine.zig");

const Info = extern struct {
    channels: u32,
    sample_rate: u32,
    max_frames: u32,
};

extern fn orca_aac_decoder_create(
    config: [*]const u8,
    config_size: u32,
    first_unit: [*]const u8,
    first_unit_size: u32,
    info: *Info,
) ?*anyopaque;
extern fn orca_aac_decoder_destroy(decoder: ?*anyopaque) void;
extern fn orca_aac_decoder_decode(
    decoder: ?*anyopaque,
    unit: [*]const u8,
    unit_size: u32,
    output: [*]f32,
    frames_written: *u32,
) i32;
extern fn orca_aac_decoder_reset(decoder: ?*anyopaque) i32;

/// `first_unit` is the stream's first access unit, which plain AAC needs to
/// finish configuring itself. It is still decoded as audio afterwards.
pub fn open(config: []const u8, first_unit: []const u8) !engine_api.Engine {
    var info: Info = undefined;
    const native = orca_aac_decoder_create(
        config.ptr,
        std.math.cast(u32, config.len) orelse return error.InvalidAac,
        first_unit.ptr,
        std.math.cast(u32, first_unit.len) orelse return error.InvalidAac,
        &info,
    ) orelse return error.InvalidAac;
    errdefer orca_aac_decoder_destroy(native);
    return .{
        .context = native,
        .vtable = &vtable,
        .max_packet_frames = info.max_frames,
        .channels = std.math.cast(u16, info.channels) orelse return error.InvalidAac,
        .sample_rate = info.sample_rate,
        .bits_per_sample = null,
        // The MDCT overlaps each access unit with the previous one, and SBR
        // adds its own delay on top.
        .preroll_packets = 2,
    };
}

fn decode(context: *anyopaque, unit: []const u8, output: []f32) !u32 {
    var frames: u32 = 0;
    if (orca_aac_decoder_decode(
        context,
        unit.ptr,
        std.math.cast(u32, unit.len) orelse return error.AacDecodeFailed,
        output.ptr,
        &frames,
    ) != 0) return error.AacDecodeFailed;
    return frames;
}

fn reset(context: *anyopaque) void {
    // A failed re-initialization leaves no API object, so the next decode
    // reports AacDecodeFailed rather than using stale state.
    _ = orca_aac_decoder_reset(context);
}

fn deinit(context: *anyopaque) void {
    orca_aac_decoder_destroy(context);
}

const vtable: engine_api.Engine.VTable = .{
    .decode = decode,
    .reset = reset,
    .deinit = deinit,
};
