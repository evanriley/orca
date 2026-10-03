//! The signal path as words: the player bar's one-line summary and the Signal
//! Path sheet's verdict, chain and five stages (Source, Gain, DSP, Engine,
//! Output). What each stage does, and whether the path is bit-perfect, is
//! liborca's answer; this only words it.

const std = @import("std");
const liborca = @import("liborca");
const strings = @import("strings.zig");

pub const nothing_playing = "Nothing playing";
pub const audio_backend = "PipeWire";
pub const pipewire_hedge = "PipeWire's own volume and resampling are not visible to Orca.";

const bullet = " • ";
const arrow = " → ";
pub const minus = "−";

pub const Stage = enum { source, gain, dsp, engine, output };

pub const all_stages = std.enums.values(Stage);

/// What the sheet knows beside the path: the audible Track as the player bar
/// shows it, the output device's name and the ReplayGain mode.
pub const Context = struct {
    title: []const u8 = "",
    subtitle: []const u8 = "",
    device: []const u8 = "",
    replay_gain_mode: liborca.ReplayGainMode = .off,
};

/// The popover's text where no sheet can open: the verdict, the chain and
/// the footer, cut short if it does not fit.
pub fn render(buffer: []u8, path: liborca.SignalPath, device: []const u8) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    write(&writer, path, device) catch {};
    return finish(buffer, &writer);
}

fn write(writer: *std.Io.Writer, path: liborca.SignalPath, device: []const u8) std.Io.Writer.Error!void {
    if (path.source == null) return writer.writeAll(nothing_playing);
    if (path.output != null) {
        try writeVerdict(writer, path);
        try writer.writeByte('\n');
    }
    try writeChain(writer, path, device);
    try writer.writeAll("\n\n");
    try writeFooter(writer, path);
}

/// The bar's line, such as `FLAC • 44.1 kHz • Native`, or an empty string
/// when nothing is playing.
pub fn renderCompact(buffer: []u8, path: liborca.SignalPath) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeCompact(&writer, path) catch {};
    return finish(buffer, &writer);
}

pub fn writeCompact(writer: *std.Io.Writer, path: liborca.SignalPath) std.Io.Writer.Error!void {
    const source = path.source orelse return;
    if (path.codec) |codec| {
        try writeCodecName(writer, codec);
        try writer.writeAll(bullet);
    }
    try writeRate(writer, source.sample_rate);
    if (path.output == null) return;
    try writer.writeAll(bullet);
    try writer.writeAll(if (resampledTo(path) == null) "Native" else "Resampled");
}

pub fn renderAdjustments(buffer: []u8, path: liborca.SignalPath) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeAdjustments(&writer, path) catch {};
    return finish(buffer, &writer);
}

fn writeAdjustments(writer: *std.Io.Writer, path: liborca.SignalPath) std.Io.Writer.Error!void {
    if (path.source == null) return;
    if (path.replay_gain_db) |decibels| {
        try writer.writeAll("RG ");
        try writeSignedDecibels(writer, decibels);
        try writer.writeAll(" •");
    }
    if (dspActive(path)) {
        if (writer.end != 0) try writer.writeByte(' ');
        try writer.writeAll("DSP •");
    }
}

fn finish(buffer: []u8, writer: *const std.Io.Writer) [:0]const u8 {
    buffer[writer.end] = 0;
    return buffer[0..writer.end :0];
}

/// The rate the audio finally plays at when it differs from the source's;
/// null when it does not, or while no output is open.
fn resampledTo(path: liborca.SignalPath) ?u32 {
    const source = path.source orelse return null;
    const output = path.output orelse return null;
    const final_rate = path.device_rate orelse output.sample_rate;
    return if (final_rate == source.sample_rate) null else final_rate;
}

fn dspActive(path: liborca.SignalPath) bool {
    if (path.crossfeed != null) return true;
    if (path.parametric) |parametric| return !parametric.isIdentity();
    const equalizer = path.equalizer orelse return false;
    return equalizer.isActive();
}

/// The verdict card's headline: `Bit-perfect`, `Native sample rate`, or
/// `Resampled 44.1 → 96 kHz`, then what changes the samples in chain order
/// (`gain adjusted`, `DSP active`, `volume`). Empty while no output is open.
pub fn writeVerdict(writer: *std.Io.Writer, path: liborca.SignalPath) std.Io.Writer.Error!void {
    const source = path.source orelse return;
    if (path.output == null) return;
    if (resampledTo(path)) |rate| {
        try writer.writeAll("Resampled ");
        try writeRateNumber(writer, source.sample_rate);
        try writer.writeAll(arrow);
        try writeRate(writer, rate);
    } else if (path.bit_perfect_eligible) {
        return writer.writeAll("Bit-perfect");
    } else {
        try writer.writeAll("Native sample rate");
    }
    if (path.replay_gain_db != null) try writer.writeAll(bullet ++ "gain adjusted");
    if (dspActive(path)) try writer.writeAll(bullet ++ "DSP active");
    if (path.volume < 1) try writer.writeAll(bullet ++ "volume");
}

pub fn native(path: liborca.SignalPath) bool {
    return path.source != null and path.output != null and resampledTo(path) == null;
}

/// The verdict card's second line, such as
/// `FLAC 16-bit / 44.1 kHz → 32-bit float → USB DAC`.
pub fn writeChain(writer: *std.Io.Writer, path: liborca.SignalPath, device: []const u8) std.Io.Writer.Error!void {
    const source = path.source orelse return;
    if (path.codec) |codec| {
        try writeCodecName(writer, codec);
        try writer.writeByte(' ');
    }
    try writeSourceFormat(writer, source, path.source_declared);
    const output = path.output orelse return;
    try writer.writeAll(arrow);
    try writeDepth(writer, output);
    if (device.len != 0) {
        try writer.writeAll(arrow);
        try writer.writeAll(device);
    }
}

/// The footer card's headline: all is well, or why the path is not
/// bit-perfect, from the first reason liborca gives.
pub fn writeFooter(writer: *std.Io.Writer, path: liborca.SignalPath) std.Io.Writer.Error!void {
    const reasons = path.reasonList();
    if (reasons.len == 0) return writer.writeAll("Everything is working as intended.");
    try writer.writeAll(switch (reasons[0]) {
        .sample_processing => "Gain, DSP or volume changes the samples.",
        .sample_rate_conversion => "Orca resamples to the output's rate.",
        .channel_layout_conversion => "Orca remixes the channels for the output.",
        .sample_format_conversion => "The samples are rounded to fit the output's format.",
        .lossy_source => "The source is lossy, so no path to it is bit-perfect.",
    });
}

pub fn stageTitle(stage: Stage) [:0]const u8 {
    return switch (stage) {
        .source => "Source",
        .gain => "ReplayGain / Gain",
        .dsp => "DSP",
        .engine => "Engine / System",
        .output => "Output",
    };
}

/// The short tag at the stage's top right: the codec, `Off` or `None` for
/// an idle Gain or DSP, the engine's format, how the output is attached.
pub fn writeTag(writer: *std.Io.Writer, path: liborca.SignalPath, stage: Stage) std.Io.Writer.Error!void {
    switch (stage) {
        .source => if (path.codec) |codec| try writeCodecName(writer, codec),
        .gain => if (path.replay_gain_db == null and path.volume == 1) try writer.writeAll("Off"),
        .dsp => {
            const equalizer = path.equalizer != null or path.parametric != null;
            const crossfeed = path.crossfeed != null;
            try writer.writeAll(if (equalizer and crossfeed)
                "2 effects"
            else if (equalizer)
                "Equalizer"
            else if (crossfeed)
                "Crossfeed"
            else
                "None");
        },
        .engine => try writer.writeAll("32-bit float"),
        .output => if (path.output != null) try writer.writeAll(kindName(path.output_kind)),
    }
}

/// What the stage does, one fact per line. `path.source` must be set.
pub fn writeLines(writer: *std.Io.Writer, path: liborca.SignalPath, stage: Stage, context: Context) std.Io.Writer.Error!void {
    const source = path.source.?;
    switch (stage) {
        .source => {
            if (context.title.len != 0) try writer.print("{s}\n", .{context.title});
            if (context.subtitle.len != 0) try writer.print("{s}\n", .{context.subtitle});
            if (path.codec) |codec| {
                try writeCodecName(writer, codec);
                try writer.writeAll(" (");
                try writeSourceFormat(writer, source, path.source_declared);
                try writer.writeByte(')');
            } else try writeSourceFormat(writer, source, path.source_declared);
        },
        .gain => {
            try writer.writeAll(switch (path.replay_gain_source) {
                .album => "Album ReplayGain",
                .track, .track_fallback => "Track ReplayGain",
                .none => switch (context.replay_gain_mode) {
                    .off => "ReplayGain off",
                    .track => "Track ReplayGain",
                    .album => "Album ReplayGain",
                },
            });
            if (path.replay_gain_db) |decibels| {
                try writer.writeByte('\n');
                try writeSignedDecibels(writer, decibels);
                if (path.replay_gain_track_db) |track| if (@round(track * 10) != @round(decibels * 10)) {
                    try writer.writeAll(" (from ");
                    try writeSignedDecibels(writer, track);
                    try writer.writeByte(')');
                };
            } else if (context.replay_gain_mode != .off) {
                try writer.writeAll("\nNo adjustment");
            }
            if (path.replay_gain_source == .track_fallback)
                try writer.writeAll("\nNo album gain for this Track");
            if (path.volume != 1) {
                try writer.writeAll("\nVolume ");
                try writePercent(writer, path.volume);
            }
        },
        .dsp => {
            if (path.equalizer == null and path.parametric == null and path.crossfeed == null)
                return writer.writeAll("No processing");
            var first = true;
            if (path.parametric) |parametric| {
                first = false;
                try writeParametricRows(writer, parametric);
            }
            if (path.equalizer) |equalizer| {
                first = false;
                try writer.print("Graphic EQ ({d} bands)", .{liborca.equalizer_band_frequencies_hz.len});
                if (!equalizer.isActive()) {
                    try writer.writeAll("\nFlat, changes nothing");
                } else {
                    try writer.writeAll("\nPreamp ");
                    try writeSignedDecibels(writer, equalizer.preamp_db);
                }
            }
            if (path.crossfeed) |amount| {
                if (!first) try writer.writeByte('\n');
                try writer.print("Crossfeed {d:.2}", .{amount});
            }
        },
        .engine => {
            try writer.writeAll("Orca Audio Engine\nProcessing in 32-bit float");
            const output = path.output orelse return;
            try writer.writeAll(if (output.sample_rate == source.sample_rate) "\nNo resampling (" else "\nResampling (");
            try writeRate(writer, source.sample_rate);
            try writer.writeAll(arrow);
            try writeRate(writer, output.sample_rate);
            try writer.writeByte(')');
            if (output.channels != source.channels)
                try writer.print("\nRemixing {d}{s}{d} channels", .{ source.channels, arrow, output.channels });
        },
        .output => {
            const output = path.output orelse return writer.writeAll("No output open");
            try writer.writeAll(if (context.device.len != 0) context.device else "Output");
            try writer.writeByte('\n');
            try writeRate(writer, output.sample_rate);
            try writer.writeAll(bullet);
            try writeDepth(writer, output);
            if (path.device_rate) |device_rate| if (device_rate != output.sample_rate) {
                try writer.writeAll("\nPipeWire resamples to ");
                try writeRate(writer, device_rate);
            };
        },
    }
}

/// The figures a stage's chevron reveals that the path itself holds. Engine
/// and Output reveal live figures instead (`writeLiveTech`).
pub fn writeTech(writer: *std.Io.Writer, path: liborca.SignalPath, stage: Stage) std.Io.Writer.Error!void {
    const source = path.source.?;
    switch (stage) {
        .source => {
            if (path.source_declared) {
                try writer.writeAll("Decoded from ");
                try writeSampleFormat(writer, source);
            } else try writer.writeAll("The decoder declares no sample format");
            try writer.print("\n{d} channels" ++ bullet, .{source.channels});
            try strings.writeGrouped(writer, source.sample_rate);
            try writer.writeAll(" Hz");
            if (path.widened_exactly) try writer.writeAll("\nWidened to 32-bit float exactly");
        },
        .gain => {
            const gain = if (path.replay_gain_db) |decibels| std.math.pow(f32, 10, decibels / 20) else 1;
            try writer.print("ReplayGain ×{d:.3}" ++ bullet ++ "volume ×{d:.3}", .{ gain, path.volume });
        },
        .dsp => {
            if (path.parametric) |parametric| {
                try writer.writeAll("Preamp ");
                return writeSignedDecibels(writer, parametric.preamp_db);
            }
            const equalizer = path.equalizer orelse return writer.writeAll("No equalizer bands");
            for (liborca.equalizer_band_frequencies_hz, equalizer.gains_db, 0..) |hertz, gain_db, index| {
                if (index != 0) try writer.writeByte('\n');
                try writeBandFrequency(writer, hertz);
                try writer.writeAll("  ");
                try writeSignedDecibels(writer, gain_db);
            }
        },
        .engine, .output => {},
    }
}

/// The live figures behind Engine and Output, read when the stage opens.
pub fn writeLiveTech(
    writer: *std.Io.Writer,
    stage: Stage,
    block_frames: ?u32,
    snapshot: ?liborca.PlayerSnapshot,
    stats: ?liborca.ZoneStats,
) std.Io.Writer.Error!void {
    switch (stage) {
        .engine => {
            if (block_frames) |frames| {
                try writeBlockSize(writer, frames);
                try writer.writeByte('\n');
            }
            const value = snapshot orelse return writer.writeAll("Transport unavailable");
            try writer.print("Transport {s}" ++ bullet ++ "epoch {d}\nPosition ", .{ @tagName(value.state), value.epoch });
            try strings.writeGrouped(writer, value.position_frames);
            try writer.writeAll(" frames");
        },
        .output => {
            const value = stats orelse return writer.writeAll("No output open");
            try writer.print("Stream {s}" ++ bullet ++ "quantum {d} frames\nUnderruns ", .{ @tagName(value.output_state), value.backend_quantum_frames });
            try strings.writeGrouped(writer, value.underruns);
            try writer.writeAll(bullet ++ "dropped ");
            try strings.writeGrouped(writer, value.dropped_returns);
            try writer.print(bullet ++ "recoveries {d}", .{value.recovery_attempts});
        },
        .source, .gain, .dsp => {},
    }
}

fn writeBlockSize(writer: *std.Io.Writer, frames: u32) std.Io.Writer.Error!void {
    try writer.writeAll("Block size ");
    try strings.writeGrouped(writer, frames);
    try writer.writeAll(" frames");
}

fn kindName(kind: liborca.DeviceKind) []const u8 {
    return switch (kind) {
        .unknown => "",
        .usb => "USB",
        .pci => "PCI",
        .bluetooth => "Bluetooth",
        .hdmi => "HDMI",
        .virtual => "Virtual",
    };
}

pub fn isLive(stage: Stage) bool {
    return stage == .engine or stage == .output;
}

const parametric_rows = 6;

fn writeParametricRows(writer: *std.Io.Writer, parametric: liborca.ParametricEqualizer) std.Io.Writer.Error!void {
    const filters = parametric.filterList();
    try writer.print("Parametric EQ ({d} filter{s})", .{ filters.len, if (filters.len == 1) "" else "s" });
    for (filters[0..@min(filters.len, parametric_rows)], 1..) |filter, position| {
        try writer.print("\n{d}. {s}  ", .{ position, filterKindName(filter.kind) });
        try writeFilterFrequency(writer, filter.frequency_hz);
        if (filter.usesGain()) {
            try writer.writeAll("  ");
            try writeSignedDecibels(writer, filter.gain_db);
        }
        try writer.writeAll("  Q ");
        try writeQ(writer, filter.q);
        if (!filter.enabled) try writer.writeAll("  off");
    }
    if (filters.len > parametric_rows) try writer.print("\n+{d} more", .{filters.len - parametric_rows});
}

pub fn filterKindName(kind: liborca.ParametricFilterKind) [:0]const u8 {
    return switch (kind) {
        .peak => "Peak",
        .low_shelf => "Low Shelf",
        .high_shelf => "High Shelf",
        .low_pass => "Low Pass",
        .high_pass => "High Pass",
        .notch => "Notch",
    };
}

/// `80 Hz` below a kilohertz, `1.0 kHz` from there.
pub fn writeFilterFrequency(writer: *std.Io.Writer, hertz: f32) std.Io.Writer.Error!void {
    if (@round(hertz) < 1000) return writer.print("{d} Hz", .{@as(u32, @intFromFloat(@round(@max(hertz, 0))))});
    try writer.print("{d:.1} kHz", .{hertz / 1000});
}

fn writeBandFrequency(writer: *std.Io.Writer, hertz: f64) std.Io.Writer.Error!void {
    if (hertz < 1000) return writer.print("{d} Hz", .{hertz});
    try writer.print("{d} kHz", .{hertz / 1000});
}

/// Up to two decimals, trailing zeros dropped: `0.71`, `1`, `1.5`.
pub fn writeQ(writer: *std.Io.Writer, q: f32) std.Io.Writer.Error!void {
    try writer.print("{d}", .{@round(q * 100) / 100});
}

fn writeSignedDecibels(writer: *std.Io.Writer, decibels: f32) std.Io.Writer.Error!void {
    const tenths = @round(decibels * 10) / 10;
    if (tenths == 0) return writer.writeAll("0.0 dB");
    try writer.print("{s}{d:.1} dB", .{ if (tenths < 0) minus else "+", @abs(tenths) });
}

fn writePercent(writer: *std.Io.Writer, fraction: f32) std.Io.Writer.Error!void {
    try writer.print("{d} %", .{@as(u32, @intFromFloat(@round(@max(fraction, 0) * 100)))});
}

fn writeSourceFormat(writer: *std.Io.Writer, source: liborca.PcmFormat, source_declared: bool) std.Io.Writer.Error!void {
    if (source_declared) {
        try writeDepth(writer, source);
        try writer.writeAll(" / ");
    }
    try writeRate(writer, source.sample_rate);
}

fn writeSampleFormat(writer: *std.Io.Writer, format: liborca.PcmFormat) std.Io.Writer.Error!void {
    try writer.print("{d}-bit {s}", .{ format.bits_per_sample, switch (format.sample_format) {
        .unsigned_8 => "unsigned integer",
        .signed_16, .signed_24, .signed_32 => "integer",
        .float_32, .float_64 => "float",
    } });
}

pub fn writeCodecName(writer: *std.Io.Writer, codec: []const u8) std.Io.Writer.Error!void {
    if (std.ascii.eqlIgnoreCase(codec, "opus")) return writer.writeAll("Opus");
    if (std.ascii.eqlIgnoreCase(codec, "vorbis")) return writer.writeAll("Vorbis");
    if (std.ascii.eqlIgnoreCase(codec, "pcm_float")) return writer.writeAll("PCM");
    for (codec) |character| try writer.writeByte(std.ascii.toUpper(character));
}

fn writeDepth(writer: *std.Io.Writer, format: liborca.PcmFormat) std.Io.Writer.Error!void {
    const suffix = switch (format.sample_format) {
        .float_32, .float_64 => " float",
        else => "",
    };
    try writer.print("{d}-bit{s}", .{ format.bits_per_sample, suffix });
}

fn writeRateNumber(writer: *std.Io.Writer, hertz: u32) std.Io.Writer.Error!void {
    try writer.print("{d}", .{@as(f64, @floatFromInt(hertz)) / 1000});
}

pub fn writeRate(writer: *std.Io.Writer, hertz: u32) std.Io.Writer.Error!void {
    try writeRateNumber(writer, hertz);
    try writer.writeAll(" kHz");
}

pub fn writeHertz(writer: *std.Io.Writer, hertz: u32) std.Io.Writer.Error!void {
    if (hertz >= 1000) try writer.print("{d},{d:0>3} Hz", .{ hertz / 1000, hertz % 1000 }) else try writer.print("{d} Hz", .{hertz});
}

pub fn writeBitDepth(writer: *std.Io.Writer, format: liborca.PcmFormat) std.Io.Writer.Error!void {
    const suffix = switch (format.sample_format) {
        .float_32, .float_64 => " float",
        else => "",
    };
    try writer.print("{d} bit{s}", .{ format.bits_per_sample, suffix });
}

pub fn writeChannels(writer: *std.Io.Writer, channels: u16) std.Io.Writer.Error!void {
    switch (channels) {
        1 => try writer.writeAll("Mono"),
        2 => try writer.writeAll("Stereo"),
        else => try writer.print("{d} channels", .{channels}),
    }
}

/// `FLAC 16/44.1`: the codec, then bit depth over kilohertz when known.
pub fn writeFormat(writer: *std.Io.Writer, codec: []const u8, bit_depth: ?u32, hertz: ?u32) std.Io.Writer.Error!void {
    try writeCodecName(writer, codec);
    const rate = hertz orelse return;
    try writer.writeByte(' ');
    if (bit_depth) |bits| try writer.print("{d}/", .{bits});
    try writeRateNumber(writer, rate);
}

const testing = std.testing;

fn pcm(sample_format: liborca.SampleFormat, bits: u16, rate: u32) liborca.PcmFormat {
    const bytes: u16 = switch (sample_format) {
        .unsigned_8 => 1,
        .signed_16 => 2,
        .signed_24 => 3,
        .signed_32, .float_32 => 4,
        .float_64 => 8,
    };
    return .{ .sample_format = sample_format, .channels = 2, .sample_rate = rate, .bits_per_sample = bits, .bytes_per_frame = 2 * bytes };
}

fn flacPath() liborca.SignalPath {
    return .{
        .source = pcm(.signed_16, 16, 44_100),
        .source_declared = true,
        .codec = "flac",
        .output = pcm(.float_32, 32, 44_100),
        .device_rate = 44_100,
        .widened_exactly = true,
    };
}

fn withReason(path: liborca.SignalPath, reason: liborca.SignalPathReason) liborca.SignalPath {
    var result = path;
    result.bit_perfect_eligible = false;
    result.reasons[result.reason_count] = reason;
    result.reason_count += 1;
    return result;
}

fn expectVerdict(expected: []const u8, path: liborca.SignalPath) !void {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeVerdict(&writer, path);
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "an untouched native path is called bit-perfect" {
    try expectVerdict("Bit-perfect", flacPath());
}

test "a native path names what changes the samples in chain order" {
    var gain = withReason(flacPath(), .sample_processing);
    gain.replay_gain_db = -3.1;
    try expectVerdict("Native sample rate • gain adjusted", gain);

    var dsp = withReason(flacPath(), .sample_processing);
    dsp.equalizer = .{ .gains_db = .{ 0, 0, 1.5, 0, 0, 0, 0, 0, 0, 0 }, .preamp_db = -1.5 };
    try expectVerdict("Native sample rate • DSP active", dsp);

    var both = dsp;
    both.replay_gain_db = -3.1;
    both.volume = 0.5;
    try expectVerdict("Native sample rate • gain adjusted • DSP active • volume", both);
}

test "a flat equalizer is not called DSP active" {
    var path = flacPath();
    path.equalizer = .{};
    try expectVerdict("Bit-perfect", path);
}

fn testParametric(filters: []const liborca.ParametricFilter, preamp_db: f32) liborca.ParametricEqualizer {
    var result: liborca.ParametricEqualizer = .{ .preamp_db = preamp_db };
    for (filters) |filter| {
        result.filters[result.count] = filter;
        result.count += 1;
    }
    return result;
}

test "a parametric equalizer is DSP active unless it changes nothing" {
    var path = withReason(flacPath(), .sample_processing);
    path.parametric = testParametric(&.{.{ .kind = .peak, .frequency_hz = 1000, .gain_db = -2, .q = 1.41 }}, 0);
    try expectVerdict("Native sample rate • DSP active", path);
    var flat = flacPath();
    flat.parametric = testParametric(&.{.{ .kind = .peak, .frequency_hz = 1000 }}, 0);
    try expectVerdict("Bit-perfect", flat);
}

test "the DSP stage lists six parametric filters and counts the rest" {
    var filters: [8]liborca.ParametricFilter = undefined;
    filters[0] = .{ .kind = .low_shelf, .frequency_hz = 80, .gain_db = -1.5, .q = 0.707 };
    filters[1] = .{ .kind = .high_pass, .frequency_hz = 25, .q = 0.5, .enabled = false };
    for (filters[2..], 2..) |*filter, index|
        filter.* = .{ .kind = .peak, .frequency_hz = 1000 * @as(f32, @floatFromInt(index)), .gain_db = 2, .q = 1 };
    var path = flacPath();
    path.parametric = testParametric(&filters, -3);
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeLines(&writer, path, .dsp, .{});
    try testing.expectEqualStrings(
        \\Parametric EQ (8 filters)
        \\1. Low Shelf  80 Hz  −1.5 dB  Q 0.71
        \\2. High Pass  25 Hz  Q 0.5  off
        \\3. Peak  2.0 kHz  +2.0 dB  Q 1
        \\4. Peak  3.0 kHz  +2.0 dB  Q 1
        \\5. Peak  4.0 kHz  +2.0 dB  Q 1
        \\6. Peak  5.0 kHz  +2.0 dB  Q 1
        \\+2 more
    , writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try writeTag(&writer, path, .dsp);
    try testing.expectEqualStrings("Equalizer", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try writeTech(&writer, path, .dsp);
    try testing.expectEqualStrings("Preamp −3.0 dB", writer.buffered());
}

test "volume below unity is named after the rate" {
    var path = withReason(flacPath(), .sample_processing);
    path.volume = 0.8;
    try expectVerdict("Native sample rate • volume", path);
}

test "a rate change by Orca or by PipeWire is called resampled" {
    var orca = withReason(flacPath(), .sample_rate_conversion);
    orca.output.?.sample_rate = 96_000;
    orca.device_rate = 96_000;
    try expectVerdict("Resampled 44.1 → 96 kHz", orca);

    var pipewire = flacPath();
    pipewire.device_rate = 48_000;
    try expectVerdict("Resampled 44.1 → 48 kHz", pipewire);
}

test "a lossy source at its own rate is native but not bit-perfect" {
    var path = withReason(flacPath(), .lossy_source);
    path.codec = "mp3";
    path.source_declared = false;
    try expectVerdict("Native sample rate", path);
}

test "there is no verdict before an output opens" {
    var path = flacPath();
    path.output = null;
    path.device_rate = null;
    try expectVerdict("", path);
    try expectVerdict("", .{});
}

test "the bar line names the codec, the rate and whether it is native" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("FLAC • 44.1 kHz • Native", renderCompact(&buffer, flacPath()));
    var resampled = flacPath();
    resampled.device_rate = 48_000;
    try testing.expectEqualStrings("FLAC • 44.1 kHz • Resampled", renderCompact(&buffer, resampled));
    var closed = flacPath();
    closed.output = null;
    try testing.expectEqualStrings("FLAC • 44.1 kHz", renderCompact(&buffer, closed));
    try testing.expectEqualStrings("", renderCompact(&buffer, .{}));
}

test "the chain runs from the source format through the engine to the device" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeChain(&writer, flacPath(), "USB DAC");
    try testing.expectEqualStrings("FLAC 16-bit / 44.1 kHz → 32-bit float → USB DAC", writer.buffered());
}

test "the bar's second line leads with applied ReplayGain and active DSP only" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("", renderAdjustments(&buffer, flacPath()));
    var gain = flacPath();
    gain.replay_gain_db = -3.1;
    try testing.expectEqualStrings("RG −3.1 dB •", renderAdjustments(&buffer, gain));
    var both = gain;
    both.crossfeed = 0.3;
    try testing.expectEqualStrings("RG −3.1 dB • DSP •", renderAdjustments(&buffer, both));
    var flat = flacPath();
    flat.equalizer = .{};
    try testing.expectEqualStrings("", renderAdjustments(&buffer, flat));
    try testing.expectEqualStrings("", renderAdjustments(&buffer, .{}));
}

test "the Gain stage names album ReplayGain and the track figure it replaced" {
    var buffer: [128]u8 = undefined;
    var path = flacPath();
    path.replay_gain_db = -3.1;
    path.replay_gain_source = .album;
    path.replay_gain_track_db = -6.2;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeLines(&writer, path, .gain, .{ .replay_gain_mode = .album });
    try testing.expectEqualStrings("Album ReplayGain\n−3.1 dB (from −6.2 dB)", writer.buffered());

    path.replay_gain_track_db = -3.1;
    writer = std.Io.Writer.fixed(&buffer);
    try writeLines(&writer, path, .gain, .{ .replay_gain_mode = .album });
    try testing.expectEqualStrings("Album ReplayGain\n−3.1 dB", writer.buffered());

    path.replay_gain_db = -6.2;
    path.replay_gain_source = .track_fallback;
    path.replay_gain_track_db = null;
    writer = std.Io.Writer.fixed(&buffer);
    try writeLines(&writer, path, .gain, .{ .replay_gain_mode = .album });
    try testing.expectEqualStrings("Track ReplayGain\n−6.2 dB\nNo album gain for this Track", writer.buffered());

    var unmeasured = flacPath();
    unmeasured.replay_gain_source = .none;
    writer = std.Io.Writer.fixed(&buffer);
    try writeLines(&writer, unmeasured, .gain, .{ .replay_gain_mode = .album });
    try testing.expectEqualStrings("Album ReplayGain\nNo adjustment", writer.buffered());
}

test "the Output tag names how the device is attached, and nothing when unknown" {
    var buffer: [32]u8 = undefined;
    var path = flacPath();
    path.output_kind = .virtual;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeTag(&writer, path, .output);
    try testing.expectEqualStrings("Virtual", writer.buffered());
    path.output_kind = .usb;
    writer = std.Io.Writer.fixed(&buffer);
    try writeTag(&writer, path, .output);
    try testing.expectEqualStrings("USB", writer.buffered());
    path.output_kind = .unknown;
    writer = std.Io.Writer.fixed(&buffer);
    try writeTag(&writer, path, .output);
    try testing.expectEqualStrings("", writer.buffered());
}

test "the Engine detail leads with the output's block size once it is known" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeLiveTech(&writer, .engine, 256, null, null);
    try testing.expectEqualStrings("Block size 256 frames\nTransport unavailable", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try writeLiveTech(&writer, .engine, null, null, null);
    try testing.expectEqualStrings("Transport unavailable", writer.buffered());
}

test "the graphic equalizer detail names each band by its centre frequency" {
    var path = flacPath();
    path.equalizer = .{ .gains_db = .{ 0, 0, 0, 0, 0, -2, 0, 0, 0, 3 } };
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeTech(&writer, path, .dsp);
    try testing.expectEqualStrings(
        \\31 Hz  0.0 dB
        \\62 Hz  0.0 dB
        \\125 Hz  0.0 dB
        \\250 Hz  0.0 dB
        \\500 Hz  0.0 dB
        \\1 kHz  −2.0 dB
        \\2 kHz  0.0 dB
        \\4 kHz  0.0 dB
        \\8 kHz  0.0 dB
        \\16 kHz  +3.0 dB
    , writer.buffered());
}

test "idle gain and DSP stages say so in their tags" {
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeTag(&writer, flacPath(), .gain);
    try testing.expectEqualStrings("Off", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try writeTag(&writer, flacPath(), .dsp);
    try testing.expectEqualStrings("None", writer.buffered());
}

test "the footer explains the first reason, or that all is well" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeFooter(&writer, flacPath());
    try testing.expectEqualStrings("Everything is working as intended.", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try writeFooter(&writer, withReason(flacPath(), .sample_rate_conversion));
    try testing.expectEqualStrings("Orca resamples to the output's rate.", writer.buffered());
}

test "a format names bit depth over kilohertz, dropping what is unknown" {
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeFormat(&writer, "flac", 16, 44_100);
    try testing.expectEqualStrings("FLAC 16/44.1", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try writeFormat(&writer, "opus", null, 48_000);
    try testing.expectEqualStrings("Opus 48", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try writeFormat(&writer, "mp3", null, null);
    try testing.expectEqualStrings("MP3", writer.buffered());
}

test "a rate in hertz is grouped by thousands" {
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeHertz(&writer, 44_100);
    try testing.expectEqualStrings("44,100 Hz", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try writeHertz(&writer, 192_000);
    try testing.expectEqualStrings("192,000 Hz", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try writeHertz(&writer, 800);
    try testing.expectEqualStrings("800 Hz", writer.buffered());
}

test "bit depth names float samples" {
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeBitDepth(&writer, pcm(.signed_24, 24, 96_000));
    try testing.expectEqualStrings("24 bit", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try writeBitDepth(&writer, pcm(.float_32, 32, 48_000));
    try testing.expectEqualStrings("32 bit float", writer.buffered());
}

test "one and two channels are named, more are counted" {
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeChannels(&writer, 1);
    try testing.expectEqualStrings("Mono", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try writeChannels(&writer, 2);
    try testing.expectEqualStrings("Stereo", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try writeChannels(&writer, 6);
    try testing.expectEqualStrings("6 channels", writer.buffered());
}
