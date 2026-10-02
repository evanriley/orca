//! The signal path shown from the player bar: one line per stage the audio
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

/// The source format on one line, such as `FLAC · 16-bit · 44.1 kHz`, or an
/// empty string when nothing is playing.
pub fn renderCompact(buffer: []u8, path: liborca.SignalPath) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeCompact(&writer, path) catch {};
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

fn writeCompact(writer: *std.Io.Writer, path: liborca.SignalPath) std.Io.Writer.Error!void {
    const source = path.source orelse return;
    try writeFormat(writer, source, path.source_declared, path.codec);
}

pub fn write(writer: *std.Io.Writer, path: liborca.SignalPath) std.Io.Writer.Error!void {
    const source = path.source orelse return writer.writeAll(nothing_playing);
    try writeSource(writer, source, path.source_declared, path.codec);
    if (path.replay_gain_db) |decibels| {
        try writer.writeAll("\n→ ReplayGain ");
        try writeSignedDecibels(writer, decibels);
    }
    if (path.equalizer != null) try writer.writeAll("\n→ Equalizer");
    if (path.crossfeed != null) try writer.writeAll("\n→ Crossfeed");
    if (path.volume != 1) {
        try writer.writeAll("\n→ Volume ");
        try writePercent(writer, path.volume);
    }
    const output = path.output orelse return;
    try writer.writeAll("\n→ PipeWire · ");
    try writeStage(writer, path, .output);
    if (path.device_rate) |device_rate| {
        if (device_rate != output.sample_rate) {
            try writer.writeAll(", resampled to ");
            try writeRate(writer, device_rate);
        }
    }
    try writer.writeByte('\n');
    try writeVerdict(writer, path);
}

pub const Stage = enum { source, replay_gain, equalizer, crossfeed, volume, output, device };

pub const max_stages = @typeInfo(Stage).@"enum".fields.len;

pub fn stages(path: liborca.SignalPath, buffer: *[max_stages]Stage) []const Stage {
    var count: usize = 0;
    if (path.source == null) return buffer[0..0];
    const present = [max_stages]bool{
        true,
        path.replay_gain_db != null,
        path.equalizer != null,
        path.crossfeed != null,
        path.volume != 1,
        path.output != null,
        path.output != null and path.device_rate != null,
    };
    for (present, 0..) |shown, index| {
        if (!shown) continue;
        buffer[count] = @enumFromInt(index);
        count += 1;
    }
    return buffer[0..count];
}

pub fn stageTitle(stage: Stage) [:0]const u8 {
    return switch (stage) {
        .source => "Source",
        .replay_gain => "ReplayGain",
        .equalizer => "Equalizer",
        .crossfeed => "Crossfeed",
        .volume => "Volume",
        .output => "PipeWire",
        .device => "Device",
    };
}

/// What `stage` does to the audio, on one line. `stage` must be one that
/// `stages` reports for `path`.
pub fn writeStage(writer: *std.Io.Writer, path: liborca.SignalPath, stage: Stage) std.Io.Writer.Error!void {
    switch (stage) {
        .source => try writeSource(writer, path.source.?, path.source_declared, path.codec),
        .replay_gain => try writeSignedDecibels(writer, path.replay_gain_db.?),
        .equalizer => {
            const equalizer = path.equalizer.?;
            if (!equalizer.isActive()) return writer.writeAll("Flat, changes nothing");
            try writer.writeAll("Preamp ");
            try writeSignedDecibels(writer, equalizer.preamp_db);
        },
        .crossfeed => try writePercent(writer, path.crossfeed.?),
        .volume => try writePercent(writer, path.volume),
        .output => {
            const output = path.output.?;
            try writeDepth(writer, output);
            if (path.widened_exactly) try writer.writeAll(" (exact)");
            try writer.writeAll(" · ");
            try writeRate(writer, output.sample_rate);
        },
        .device => {
            const device_rate = path.device_rate.?;
            try writeRate(writer, device_rate);
            const output_rate = path.output.?.sample_rate;
            if (device_rate != output_rate) {
                try writer.writeAll(" · resampled from ");
                try writeRate(writer, output_rate);
            }
        },
    }
}

pub fn writeVerdict(writer: *std.Io.Writer, path: liborca.SignalPath) std.Io.Writer.Error!void {
    if (path.output == null) return;
    if (path.bit_perfect_eligible) return writer.writeAll("Bit-perfect up to PipeWire");
    try writer.writeAll("Not bit-perfect");
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

fn writeSignedDecibels(writer: *std.Io.Writer, decibels: f32) std.Io.Writer.Error!void {
    const tenths = @round(decibels * 10) / 10;
    try writer.print("{s}{d:.1} dB", .{ if (tenths < 0) "−" else "+", @abs(tenths) });
}

fn writePercent(writer: *std.Io.Writer, fraction: f32) std.Io.Writer.Error!void {
    try writer.print("{d} %", .{@as(u32, @intFromFloat(@round(@max(fraction, 0) * 100)))});
}

fn writeSource(
    writer: *std.Io.Writer,
    source: liborca.PcmFormat,
    source_declared: bool,
    codec: ?[]const u8,
) !void {
    try writeFormat(writer, source, source_declared, codec);
    try writer.writeAll(" · ");
    switch (source.channels) {
        1 => try writer.writeAll("mono"),
        2 => try writer.writeAll("stereo"),
        else => |channels| try writer.print("{d} channels", .{channels}),
    }
}

fn writeFormat(
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
