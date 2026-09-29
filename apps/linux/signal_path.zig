//! The signal path shown in the output popover: one line per stage the audio
//! passes through, as the runtime reports it. What each stage does, and whether
//! the path is bit-perfect, is liborca's answer; this only words it.

const std = @import("std");
const liborca = @import("liborca");

pub const nothing_playing = "Nothing playing";
pub const pipewire_hedge = "PipeWire's own volume and resampling are not visible to Orca.";

/// The path as text in `buffer`, cut short if it does not fit.
pub fn render(buffer: []u8, path: liborca.SignalPath) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    write(&writer, path) catch {};
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

pub fn write(writer: *std.Io.Writer, path: liborca.SignalPath) std.Io.Writer.Error!void {
    const source = path.source orelse return writer.writeAll(nothing_playing);
    try writeSource(writer, source, path.source_declared, path.codec);
    if (path.replay_gain_db) |decibels| {
        const tenths = @round(decibels * 10) / 10;
        try writer.print("\n→ ReplayGain {s}{d:.1} dB", .{ if (tenths < 0) "−" else "+", @abs(tenths) });
    }
    if (path.equalizer != null) try writer.writeAll("\n→ Equalizer");
    if (path.crossfeed != null) try writer.writeAll("\n→ Crossfeed");
    if (path.volume != 1) try writer.print("\n→ Volume {d} %", .{@as(u32, @intFromFloat(@round(@max(path.volume, 0) * 100)))});
    if (path.output) |output| {
        try writer.writeAll("\n→ PipeWire · ");
        try writeDepth(writer, output);
        if (path.widened_exactly) try writer.writeAll(" (exact)");
        try writer.writeAll(" · ");
        try writeRate(writer, output.sample_rate);
        if (path.device_rate) |device_rate| {
            if (device_rate != output.sample_rate) {
                try writer.writeAll(", resampled to ");
                try writeRate(writer, device_rate);
            }
        }
    }
    if (path.output == null) return;
    if (path.bit_perfect_eligible) return writer.writeAll("\nBit-perfect up to PipeWire");
    try writer.writeAll("\nNot bit-perfect");
    for (path.reasonList(), 0..) |reason, index| {
        try writer.writeAll(if (index == 0) ": " else ", ");
        try writer.writeAll(switch (reason) {
            .sample_processing => "the audio is processed",
            .sample_format_conversion => "converted to 32-bit float",
            .sample_rate_conversion => "resampled",
            .channel_layout_conversion => "channels remixed",
            .lossy_source => "lossy source",
        });
    }
}

fn writeSource(
    writer: *std.Io.Writer,
    source: liborca.PcmFormat,
    source_declared: bool,
    codec: ?[]const u8,
) !void {
    if (codec) |id| {
        try writeCodecName(writer, id);
        try writer.writeAll(" · ");
    }
    if (source_declared) {
        try writeDepth(writer, source);
        try writer.writeAll(" · ");
    }
    try writeRate(writer, source.sample_rate);
    try writer.writeAll(" · ");
    switch (source.channels) {
        1 => try writer.writeAll("mono"),
        2 => try writer.writeAll("stereo"),
        else => |channels| try writer.print("{d} channels", .{channels}),
    }
}

pub fn writeCodecName(writer: *std.Io.Writer, codec: []const u8) !void {
    if (std.ascii.eqlIgnoreCase(codec, "opus")) return writer.writeAll("Opus");
    if (std.ascii.eqlIgnoreCase(codec, "vorbis")) return writer.writeAll("Vorbis");
    if (std.ascii.eqlIgnoreCase(codec, "pcm_float")) return writer.writeAll("PCM");
    for (codec) |character| try writer.writeByte(std.ascii.toUpper(character));
}

fn writeDepth(writer: *std.Io.Writer, format: liborca.PcmFormat) !void {
    const suffix = switch (format.sample_format) {
        .float_32, .float_64 => " float",
        else => "",
    };
    try writer.print("{d}-bit{s}", .{ format.bits_per_sample, suffix });
}

pub fn writeRate(writer: *std.Io.Writer, hertz: u32) !void {
    try writer.print("{d} kHz", .{@as(f64, @floatFromInt(hertz)) / 1000});
}
