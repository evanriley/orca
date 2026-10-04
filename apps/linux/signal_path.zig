//! The signal path as words: the player bar's one-line summary, the output
//! picker's lines and the Signal Path inspector's verdict, chain, stages and
//! closing verdict. What each stage does, and whether the path is
//! bit-perfect, is liborca's answer; this only words it.

const std = @import("std");
const liborca = @import("liborca");
const strings = @import("strings.zig");

pub const nothing_playing = "Nothing playing";
pub const audio_backend = "PipeWire";
pub const pipewire_hedge = "PipeWire's own volume and resampling are not visible to Orca.";

const dot = " · ";
const arrow = " → ";
pub const minus = "−";

pub const Stage = enum { source, replay_gain, parametric, graphic, crossfeed, volume, engine, system, output };

pub const all_stages = std.enums.values(Stage);

/// What the inspector knows beside the path: the audible Track, the output
/// device's name, the ReplayGain mode and the name of the saved preset the
/// parametric curve matches.
pub const Context = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
    device: []const u8 = "",
    replay_gain_mode: liborca.ReplayGainMode = .off,
    preset: []const u8 = "",
};

/// The popover's text where no inspector can open: the verdict, the chain and
/// the closing verdict, cut short if it does not fit.
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

pub fn renderTechnology(buffer: []u8, path: liborca.SignalPath) [:0]const u8 {
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    writeTechnology(&writer, path) catch {};
    return finish(buffer, &writer);
}

fn writeTechnology(writer: *std.Io.Writer, path: liborca.SignalPath) std.Io.Writer.Error!void {
    const source = path.source orelse return;
    if (path.codec) |codec| {
        try writeCodecName(writer, codec);
        try writer.writeAll(dot);
    }
    try writeRate(writer, source.sample_rate);
    const verdict: ?[]const u8 = if (samplesProcessed(path))
        "DSP"
    else if (path.output == null)
        null
    else if (resampledTo(path) != null)
        "Resampled"
    else if (path.bit_perfect_eligible)
        "Native"
    else
        null;
    if (verdict) |text| {
        try writer.writeAll(dot);
        try writer.writeAll(text);
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

fn orcaResamples(path: liborca.SignalPath) bool {
    const source = path.source orelse return false;
    const output = path.output orelse return false;
    return output.sample_rate != source.sample_rate;
}

fn systemResamples(path: liborca.SignalPath) bool {
    const output = path.output orelse return false;
    const device_rate = path.device_rate orelse return false;
    return device_rate != output.sample_rate;
}

fn deviceConvertsFormat(path: liborca.SignalPath) ?liborca.DeviceFormat {
    const output = path.output orelse return null;
    const device = path.device_format orelse return null;
    if (device.sample_format == .float_32 and output.sample_format == .float_32) return null;
    return device;
}

fn orcaRemixes(path: liborca.SignalPath) bool {
    const source = path.source orelse return false;
    const output = path.output orelse return false;
    return output.channels != source.channels;
}

fn samplesProcessed(path: liborca.SignalPath) bool {
    return path.replay_gain_db != null or dspActive(path);
}

fn dspActive(path: liborca.SignalPath) bool {
    return path.crossfeed != null or equalizerActive(path);
}

fn equalizerActive(path: liborca.SignalPath) bool {
    if (path.parametric) |parametric| return !parametric.isIdentity();
    const equalizer = path.equalizer orelse return false;
    return equalizer.isActive();
}

/// The verdict card's headline: `Bit-perfect`, `Native sample rate`, or
/// `Resampled 44.1 → 96 kHz`, then `DSP active` when gain or DSP changes the
/// samples and `volume` below full volume. Empty while no output is open.
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
    if (samplesProcessed(path)) try writer.writeAll(dot ++ "DSP active");
    if (path.volume < 1) try writer.writeAll(dot ++ "volume");
}
pub fn writeSending(writer: *std.Io.Writer, path: liborca.SignalPath) std.Io.Writer.Error!void {
    const output = path.output orelse return;
    try writeRate(writer, path.device_rate orelse output.sample_rate);
    try writer.writeAll(dot);
    try writeDepth(writer, output);
    try writer.print(dot ++ "{d} ch", .{output.channels});
}

pub fn writeMode(writer: *std.Io.Writer, path: liborca.SignalPath) std.Io.Writer.Error!void {
    if (path.source == null or path.output == null) return;
    const resampled = resampledTo(path);
    if (samplesProcessed(path)) {
        var stages: usize = 0;
        if (path.replay_gain_db) |decibels| {
            try writeModeStage(writer, &stages, "ReplayGain ");
            try writeSignedDecibels(writer, decibels);
        }
        if (equalizerActive(path)) try writeModeStage(writer, &stages, "Equalizer");
        if (path.crossfeed != null) try writeModeStage(writer, &stages, "Crossfeed");
        if (resampled) |rate| {
            try writer.writeAll(dot ++ "resampled to ");
            try writeRate(writer, rate);
        }
        return;
    }
    if (path.bit_perfect_eligible) return writer.writeAll("Native");
    if (resampled) |rate| {
        try writer.writeAll("Resampled to ");
        return writeRate(writer, rate);
    }
    const reasons = path.reasonList();
    if (reasons.len == 0) return writer.writeAll("Native");
    switch (reasons[0]) {
        .sample_processing => {
            try writer.writeAll("Volume ");
            try writePercent(writer, path.volume);
        },
        .sample_rate_conversion => try writer.writeAll("Resampled"),
        .channel_layout_conversion => try writer.writeAll("Channels remixed"),
        .sample_format_conversion => try writer.writeAll("Rounded to the output format"),
        .lossy_source => try writer.writeAll("Unchanged" ++ dot ++ "lossy source"),
    }
}

fn writeModeStage(writer: *std.Io.Writer, stages: *usize, name: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(if (stages.* == 0) "DSP: " else ", ");
    try writer.writeAll(name);
    stages.* += 1;
}

pub const device_supports_source = "As reported by the device";

pub fn writeDeviceSupports(writer: *std.Io.Writer, capabilities: liborca.DeviceCapabilities) std.Io.Writer.Error!void {
    const any_rate = capabilities.rate_min < lowest_hardware_rate and capabilities.rate_max > highest_hardware_rate;
    const rate_known = any_rate or capabilities.rate_max != 0;
    if (any_rate) {
        try writer.writeAll("any rate");
    } else if (rate_known) {
        if (capabilities.rate_min != 0 and capabilities.rate_min != capabilities.rate_max) {
            try writeRateNumber(writer, capabilities.rate_min);
            try writer.writeAll("–");
        }
        try writeRate(writer, capabilities.rate_max);
    }
    const depths = [_]struct { bit: u8, bits: u8 }{
        .{ .bit = liborca.DeviceCapabilities.bit_depth_16, .bits = 16 },
        .{ .bit = liborca.DeviceCapabilities.bit_depth_24, .bits = 24 },
        .{ .bit = liborca.DeviceCapabilities.bit_depth_32, .bits = 32 },
    };
    var listed: usize = 0;
    for (depths) |depth| {
        if (capabilities.bit_depths & depth.bit == 0) continue;
        if (listed != 0) try writer.writeAll("/") else if (rate_known) try writer.writeAll(dot);
        try writer.print("{d}", .{depth.bits});
        listed += 1;
    }
    if (listed != 0) try writer.writeAll("-bit");
}

const lowest_hardware_rate = 8_000;
const highest_hardware_rate = 768_000;

pub const system_default_note = "Follows your OS output" ++ dot ++ "shared mode";

pub fn writeDeviceNote(
    writer: *std.Io.Writer,
    kind: liborca.DeviceKind,
    capabilities: ?liborca.DeviceCapabilities,
) std.Io.Writer.Error!void {
    const bus = kindName(kind);
    if (capabilities) |known| if (known.state == .unavailable) {
        if (bus.len == 0) return writer.writeAll("Not responding");
        return writer.print("{s}" ++ dot ++ "not responding", .{bus});
    };
    try writer.writeAll(bus);
    switch (kind) {
        .usb => try writer.writeAll(dot ++ "bit-perfect capable"),
        .bluetooth => try writer.writeAll(dot ++ "lossy, re-encoded by the OS"),
        .hdmi => if (capabilities) |known| if (known.rate_max != 0) {
            try writer.writeAll(dot ++ "up to ");
            try writeRate(writer, known.rate_max);
        },
        .unknown, .pci, .virtual => {},
    }
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

/// The closing verdict: bit-perfect, or every reason liborca gives for it
/// not being, then what resamples the audio.
pub fn writeFooter(writer: *std.Io.Writer, path: liborca.SignalPath) std.Io.Writer.Error!void {
    if (path.source == null) return writer.writeAll(nothing_playing ++ ".");
    if (path.output == null) return writer.writeAll("No output is open yet.");
    const reasons = path.reasonList();
    if (reasons.len == 0 and path.bit_perfect_eligible) {
        try writer.writeAll("Bit-perfect: nothing changes the samples between source and output.");
        return writeDeviceFormatUnknown(writer, path);
    }
    try writer.writeAll("Not bit-perfect:");
    var first = true;
    for (reasons) |reason| {
        if (reason == .sample_rate_conversion) continue;
        try writer.writeByte(' ');
        switch (reason) {
            .sample_processing => try writeChangers(writer, path, first),
            .sample_rate_conversion => unreachable,
            .channel_layout_conversion => try writer.print("Orca remixes {d}{s}{d} channels.", .{
                path.source.?.channels,
                arrow,
                path.output.?.channels,
            }),
            .sample_format_conversion => {
                try writeStart(writer, first, "the");
                if (deviceConvertsFormat(path)) |device| {
                    try writer.writeAll(" samples are converted to the device's ");
                    try writeDeviceDepth(writer, device.sample_format);
                    try writer.writeAll(" format.");
                } else try writer.writeAll(" samples are rounded to fit the output's format.");
            },
            .lossy_source => {
                try writeStart(writer, first, "the");
                try writer.writeAll(" source is lossy, so no path from it is bit-perfect.");
            },
        }
        first = false;
    }
    try writeResampling(writer, path);
    try writeDeviceFormatUnknown(writer, path);
}

fn writeDeviceFormatUnknown(writer: *std.Io.Writer, path: liborca.SignalPath) std.Io.Writer.Error!void {
    if (path.output != null and path.device_format == null)
        try writer.writeAll(" The device's own format is unknown.");
}

fn writeChangers(writer: *std.Io.Writer, path: liborca.SignalPath, first: bool) std.Io.Writer.Error!void {
    var names: [4][]const u8 = undefined;
    var count: usize = 0;
    if (path.replay_gain_db != null) {
        names[count] = "ReplayGain";
        count += 1;
    }
    if (equalizerActive(path)) {
        names[count] = "EQ";
        count += 1;
    }
    if (path.crossfeed != null) {
        names[count] = "crossfeed";
        count += 1;
    }
    if (path.volume != 1) {
        names[count] = "volume";
        count += 1;
    }
    if (count == 0) {
        try writeStart(writer, first, "processing");
        return writer.writeAll(" changes the samples.");
    }
    for (names[0..count], 0..) |name, index| {
        if (index != 0) try writer.writeAll(if (index + 1 == count) " and " else ", ");
        if (index == 0) try writeStart(writer, first, name) else try writer.writeAll(name);
    }
    try writer.writeAll(if (count == 1) " changes the samples." else " change the samples.");
}

fn writeStart(writer: *std.Io.Writer, first: bool, word: []const u8) std.Io.Writer.Error!void {
    if (first or word.len == 0) return writer.writeAll(word);
    try writer.writeByte(std.ascii.toUpper(word[0]));
    try writer.writeAll(word[1..]);
}

fn writeResampling(writer: *std.Io.Writer, path: liborca.SignalPath) std.Io.Writer.Error!void {
    const source = path.source orelse return;
    const output = path.output orelse return;
    if (orcaResamples(path)) {
        try writer.writeAll(" Orca resamples ");
        try writeRateChange(writer, source.sample_rate, output.sample_rate);
        try writer.writeByte('.');
    }
    if (systemResamples(path)) {
        try writer.writeAll(" " ++ audio_backend ++ " resamples ");
        try writeRateChange(writer, output.sample_rate, path.device_rate.?);
        try writer.writeByte('.');
    }
    if (!orcaResamples(path) and path.device_rate != null and !systemResamples(path))
        try writer.writeAll(" Nothing is resampled between source and output.");
}

fn writeRateChange(writer: *std.Io.Writer, from: u32, to: u32) std.Io.Writer.Error!void {
    try writeRateNumber(writer, from);
    try writer.writeAll(arrow);
    try writeRate(writer, to);
}

pub fn applies(path: liborca.SignalPath, stage: Stage, context: Context) bool {
    return switch (stage) {
        .source, .engine => true,
        .replay_gain => path.replay_gain_db != null or context.replay_gain_mode != .off,
        .parametric => path.parametric != null,
        .graphic => path.parametric == null and path.equalizer != null,
        .crossfeed => path.crossfeed != null,
        .volume => path.volume != 1,
        .system, .output => path.output != null,
    };
}

pub fn changesSamples(path: liborca.SignalPath, stage: Stage) bool {
    return switch (stage) {
        .source => false,
        .output => deviceConvertsFormat(path) != null,
        .replay_gain => path.replay_gain_db != null,
        .parametric => if (path.parametric) |parametric| !parametric.isIdentity() else false,
        .graphic => if (path.equalizer) |equalizer| equalizer.isActive() else false,
        .crossfeed => path.crossfeed != null,
        .volume => path.volume != 1,
        .engine => orcaResamples(path) or orcaRemixes(path),
        .system => systemResamples(path),
    };
}

pub fn hasTable(stage: Stage) bool {
    return stage == .parametric or stage == .graphic;
}

pub fn stageTitle(stage: Stage) [:0]const u8 {
    return switch (stage) {
        .source => "Source",
        .replay_gain => "ReplayGain",
        .parametric => "Parametric EQ",
        .graphic => "Graphic EQ",
        .crossfeed => "Crossfeed",
        .volume => "Volume",
        .engine => "Engine",
        .system => "System",
        .output => "Output",
    };
}

/// The short value at the stage's top right: the codec, the gain, the
/// number of filters, the engine's format, the audio system, the bus.
pub fn writeValue(writer: *std.Io.Writer, path: liborca.SignalPath, stage: Stage) std.Io.Writer.Error!void {
    switch (stage) {
        .source => if (path.codec) |codec| try writeCodecName(writer, codec),
        .replay_gain => if (path.replay_gain_db) |decibels| try writeSignedDecibels(writer, decibels) else try writer.writeAll("None"),
        .parametric => if (path.parametric) |parametric| {
            const count = parametric.filterList().len;
            try writer.print("{d} filter{s}", .{ count, if (count == 1) "" else "s" });
        },
        .graphic => try writer.print("{d} bands", .{liborca.equalizer_band_frequencies_hz.len}),
        .crossfeed => if (path.crossfeed) |amount| try writePercent(writer, amount),
        .volume => try writePercent(writer, path.volume),
        .engine => if (path.output) |output| try writeDepth(writer, output) else try writer.writeAll("32-bit float"),
        .system => try writer.writeAll(audio_backend),
        .output => try writer.writeAll(kindName(path.output_kind)),
    }
}

/// What the stage does, one fact per line. `path.source` must be set.
pub fn writeLines(writer: *std.Io.Writer, path: liborca.SignalPath, stage: Stage, context: Context) std.Io.Writer.Error!void {
    const source = path.source.?;
    switch (stage) {
        .source => {
            if (context.title.len != 0) {
                try writer.writeAll(context.title);
                if (context.artist.len != 0) try writer.print(dot ++ "{s}", .{context.artist});
                try writer.writeByte('\n');
            }
            if (path.source_declared) {
                try writeDepth(writer, source);
                try writer.writeAll(dot);
            }
            try writeRate(writer, source.sample_rate);
            try writer.writeAll(dot);
            try writeChannels(writer, source.channels);
        },
        .replay_gain => {
            const album = switch (path.replay_gain_source) {
                .album => true,
                .track, .track_fallback => false,
                .none => context.replay_gain_mode == .album,
            };
            try writer.writeAll(if (album) "Album gain" else "Track gain");
            if (path.replay_gain_db == null) return writer.writeAll(dot ++ "no adjustment for this track");
            try writer.writeAll(dot ++ "peak protection on");
            if (path.replay_gain_source == .track_fallback)
                try writer.writeAll("\nNo album gain for this track");
            if (path.replay_gain_track_db) |track| if (@round(track * 10) != @round(path.replay_gain_db.? * 10)) {
                try writer.writeAll("\nTrack gain alone ");
                try writeSignedDecibels(writer, track);
            };
        },
        .parametric => {
            const parametric = path.parametric orelse return;
            if (context.preset.len != 0) {
                try writer.print("{s} preset" ++ dot ++ "preamp ", .{context.preset});
            } else try writer.writeAll("Preamp ");
            try writeSignedDecibels(writer, parametric.preamp_db);
        },
        .graphic => {
            const equalizer = path.equalizer orelse return;
            if (!equalizer.isActive()) return writer.writeAll("Flat" ++ dot ++ "changes nothing");
            try writer.writeAll("Preamp ");
            try writeSignedDecibels(writer, equalizer.preamp_db);
        },
        .crossfeed => try writer.writeAll("Blends some of each channel into the other"),
        .volume => try writer.writeAll("Orca's volume, applied before the output"),
        .engine => {
            try writer.writeAll("Orca audio engine");
            if (path.output) |output| {
                if (orcaResamples(path)) {
                    try writer.writeAll(dot ++ "resamples ");
                    try writeRateChange(writer, source.sample_rate, output.sample_rate);
                } else try writer.writeAll(dot ++ "no resampling");
                if (orcaRemixes(path))
                    try writer.print("\nRemixes {d}{s}{d} channels", .{ source.channels, arrow, output.channels });
            }
        },
        .system => {
            const output = path.output orelse return;
            const device_rate = path.device_rate orelse return writer.writeAll("Rate not reported yet");
            if (device_rate == output.sample_rate) return writeRate(writer, device_rate);
            try writer.writeAll("Resamples ");
            try writeRateChange(writer, output.sample_rate, device_rate);
        },
        .output => {
            try writer.writeAll(if (context.device.len != 0) context.device else "System default");
            try writer.writeByte('\n');
            const device = path.device_format orelse return writeSending(writer, path);
            try writeRate(writer, device.sample_rate);
            try writer.writeAll(dot);
            try writeDeviceDepth(writer, device.sample_format);
            try writer.print(dot ++ "{d} ch", .{device.channels});
            if (deviceConvertsFormat(path) != null) {
                try writer.writeAll("\nConverted from Orca's ");
                try writeDepth(writer, path.output.?);
            }
        },
    }
}

/// The figures a stage reveals when it is opened, beside its table. Engine,
/// System and Output reveal live figures (`writeLiveTech`).
pub fn writeTech(writer: *std.Io.Writer, path: liborca.SignalPath, stage: Stage) std.Io.Writer.Error!void {
    const source = path.source.?;
    switch (stage) {
        .source => {
            if (path.source_declared) {
                try writer.writeAll("Decoded from ");
                try writeSampleFormat(writer, source);
            } else try writer.writeAll("The decoder declares no sample format");
            try writer.print("\n{d} channels" ++ dot, .{source.channels});
            try strings.writeGrouped(writer, source.sample_rate);
            try writer.writeAll(" Hz");
            if (path.widened_exactly) try writer.writeAll("\nWidened to 32-bit float exactly");
        },
        .replay_gain, .volume => {
            const gain = if (path.replay_gain_db) |decibels| std.math.pow(f32, 10, decibels / 20) else 1;
            try writer.print("ReplayGain ×{d:.3}" ++ dot ++ "volume ×{d:.3}", .{ gain, path.volume });
        },
        .crossfeed => if (path.crossfeed) |amount| try writer.print("Amount {d:.2}", .{amount}),
        .parametric, .graphic, .engine, .system, .output => {},
    }
}

pub fn isLive(stage: Stage) bool {
    return stage == .engine or stage == .system or stage == .output;
}

/// The live figures behind Engine, System and Output, read when the stage
/// opens.
pub fn writeLiveTech(
    writer: *std.Io.Writer,
    stage: Stage,
    block_frames: ?u32,
    snapshot: ?liborca.PlayerSnapshot,
    stats: ?liborca.ZoneStats,
) std.Io.Writer.Error!void {
    switch (stage) {
        .engine => {
            const value = snapshot orelse return writer.writeAll("Transport unavailable");
            try writer.print("Transport {s}" ++ dot ++ "epoch {d}\nPosition ", .{ @tagName(value.state), value.epoch });
            try strings.writeGrouped(writer, value.position_frames);
            try writer.writeAll(" frames");
        },
        .system => {
            if (block_frames) |frames| {
                try writeBlockSize(writer, frames);
                try writer.writeByte('\n');
            }
            try writer.writeAll(pipewire_hedge);
        },
        .output => {
            const value = stats orelse return writer.writeAll("No output open");
            try writer.print("Stream {s}" ++ dot ++ "quantum {d} frames\nUnderruns ", .{ @tagName(value.output_state), value.backend_quantum_frames });
            try strings.writeGrouped(writer, value.underruns);
            try writer.writeAll(dot ++ "dropped ");
            try strings.writeGrouped(writer, value.dropped_returns);
            try writer.print(dot ++ "recoveries {d}", .{value.recovery_attempts});
        },
        .source, .replay_gain, .parametric, .graphic, .crossfeed, .volume => {},
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

pub const table_columns = 4;

pub fn writeTableCell(
    writer: *std.Io.Writer,
    path: liborca.SignalPath,
    stage: Stage,
    row: usize,
    column: usize,
) std.Io.Writer.Error!void {
    switch (stage) {
        .parametric => {
            const filters = (path.parametric orelse return).filterList();
            if (row >= filters.len) return;
            const filter = filters[row];
            switch (column) {
                0 => {
                    try writer.writeAll(filterKindName(filter.kind));
                    if (!filter.enabled) try writer.writeAll(" (off)");
                },
                1 => try writeFilterFrequency(writer, filter.frequency_hz),
                2 => if (filter.usesGain()) try writeSignedDecibels(writer, filter.gain_db),
                3 => try writeQ(writer, filter.q),
                else => {},
            }
        },
        .graphic => {
            const equalizer = path.equalizer orelse return;
            if (row >= equalizer.gains_db.len) return;
            switch (column) {
                0 => try writeBandFrequency(writer, liborca.equalizer_band_frequencies_hz[row]),
                2 => try writeSignedDecibels(writer, equalizer.gains_db[row]),
                else => {},
            }
        },
        else => {},
    }
}

pub fn tableRows(path: liborca.SignalPath, stage: Stage) usize {
    return switch (stage) {
        .parametric => if (path.parametric) |parametric| parametric.filterList().len else 0,
        .graphic => if (path.equalizer) |equalizer| equalizer.gains_db.len else 0,
        else => 0,
    };
}

pub fn filterKindName(kind: liborca.ParametricFilterKind) [:0]const u8 {
    return switch (kind) {
        .peak => "Bell",
        .low_shelf => "Low shelf",
        .high_shelf => "High shelf",
        .low_pass => "Low pass",
        .high_pass => "High pass",
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

pub fn writeQ(writer: *std.Io.Writer, q: f32) std.Io.Writer.Error!void {
    try writer.print("Q {d:.1}", .{q});
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

fn writeDeviceDepth(writer: *std.Io.Writer, format: liborca.DeviceSampleFormat) std.Io.Writer.Error!void {
    try writer.print("{d}-bit{s}", .{ format.bitsPerSample(), if (format == .float_32) " float" else "" });
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

test "a native path says DSP active when gain or DSP changes the samples" {
    var gain = withReason(flacPath(), .sample_processing);
    gain.replay_gain_db = -3.1;
    try expectVerdict("Native sample rate · DSP active", gain);

    var dsp = withReason(flacPath(), .sample_processing);
    dsp.equalizer = .{ .gains_db = .{ 0, 0, 1.5, 0, 0, 0, 0, 0, 0, 0 }, .preamp_db = -1.5 };
    try expectVerdict("Native sample rate · DSP active", dsp);

    var both = dsp;
    both.replay_gain_db = -3.1;
    both.volume = 0.5;
    try expectVerdict("Native sample rate · DSP active · volume", both);
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
    try expectVerdict("Native sample rate · DSP active", path);
    var flat = flacPath();
    flat.parametric = testParametric(&.{.{ .kind = .peak, .frequency_hz = 1000 }}, 0);
    try expectVerdict("Bit-perfect", flat);
}

test "volume below unity is named after the rate" {
    var path = withReason(flacPath(), .sample_processing);
    path.volume = 0.8;
    try expectVerdict("Native sample rate · volume", path);
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
test "the bar's technology line names the codec, the rate, DSP and a bit-perfect path" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("FLAC · 44.1 kHz · Native", renderTechnology(&buffer, flacPath()));
    var resampled = flacPath();
    resampled.device_rate = 48_000;
    try testing.expectEqualStrings("FLAC · 44.1 kHz · Resampled", renderTechnology(&buffer, resampled));
    var gain = withReason(flacPath(), .sample_processing);
    gain.replay_gain_db = -3.1;
    try testing.expectEqualStrings("FLAC · 44.1 kHz · DSP", renderTechnology(&buffer, gain));
    var dsp = withReason(flacPath(), .sample_processing);
    dsp.crossfeed = 0.3;
    try testing.expectEqualStrings("FLAC · 44.1 kHz · DSP", renderTechnology(&buffer, dsp));
    var flat = flacPath();
    flat.equalizer = .{};
    try testing.expectEqualStrings("FLAC · 44.1 kHz · Native", renderTechnology(&buffer, flat));
    var closed = flacPath();
    closed.output = null;
    try testing.expectEqualStrings("FLAC · 44.1 kHz", renderTechnology(&buffer, closed));
    try testing.expectEqualStrings("", renderTechnology(&buffer, .{}));
}

fn expectWritten(expected: []const u8, comptime write_fn: anytype, arguments: anytype) !void {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try @call(.auto, write_fn, .{&writer} ++ arguments);
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "the bar says DSP exactly when the picker's Mode line lists DSP stages" {
    var gain = withReason(flacPath(), .sample_processing);
    gain.replay_gain_db = -6.2;
    var equalizer = withReason(flacPath(), .sample_processing);
    equalizer.equalizer = .{ .gains_db = .{ 0, 0, 1.5, 0, 0, 0, 0, 0, 0, 0 } };
    var flat = flacPath();
    flat.equalizer = .{};
    var volume = withReason(flacPath(), .sample_processing);
    volume.volume = 0.7;
    var resampled = withReason(flacPath(), .sample_rate_conversion);
    resampled.device_rate = 96_000;
    for ([_]liborca.SignalPath{ flacPath(), gain, equalizer, flat, volume, resampled }) |path| {
        var technology_buffer: [64]u8 = undefined;
        var mode_buffer: [128]u8 = undefined;
        var mode = std.Io.Writer.fixed(&mode_buffer);
        try writeMode(&mode, path);
        try testing.expectEqual(
            std.mem.startsWith(u8, mode.buffered(), "DSP: "),
            std.mem.endsWith(u8, renderTechnology(&technology_buffer, path), "DSP"),
        );
    }
}

test "the picker's Sending line names the rate the device runs at, the depth and the channels" {
    try expectWritten("44.1 kHz · 32-bit float · 2 ch", writeSending, .{flacPath()});
    var resampled = flacPath();
    resampled.device_rate = 48_000;
    try expectWritten("48 kHz · 32-bit float · 2 ch", writeSending, .{resampled});
    var closed = flacPath();
    closed.output = null;
    try expectWritten("", writeSending, .{closed});
}

test "the picker's Mode line lists the stages that change the samples, or says Native" {
    try expectWritten("Native", writeMode, .{flacPath()});
    var gain = withReason(flacPath(), .sample_processing);
    gain.replay_gain_db = -6.2;
    try expectWritten("DSP: ReplayGain −6.2 dB", writeMode, .{gain});
    var stages = gain;
    stages.equalizer = .{ .gains_db = .{ 0, 0, 1.5, 0, 0, 0, 0, 0, 0, 0 } };
    stages.crossfeed = 0.3;
    stages.device_rate = 48_000;
    try expectWritten("DSP: ReplayGain −6.2 dB, Equalizer, Crossfeed · resampled to 48 kHz", writeMode, .{stages});
    var volume = withReason(flacPath(), .sample_processing);
    volume.volume = 0.7;
    try expectWritten("Volume 70 %", writeMode, .{volume});
    var resampled = withReason(flacPath(), .sample_rate_conversion);
    resampled.device_rate = 96_000;
    try expectWritten("Resampled to 96 kHz", writeMode, .{resampled});
    try expectWritten("Unchanged · lossy source", writeMode, .{withReason(flacPath(), .lossy_source)});
    var closed = flacPath();
    closed.output = null;
    try expectWritten("", writeMode, .{closed});
}

test "the picker's Device supports line gives the reported rates and depths, and a sink that takes any rate says so" {
    try expectWritten("44.1–384 kHz · 16/24/32-bit", writeDeviceSupports, .{liborca.DeviceCapabilities{
        .rate_min = 44_100,
        .rate_max = 384_000,
        .bit_depths = liborca.DeviceCapabilities.bit_depth_16 | liborca.DeviceCapabilities.bit_depth_24 | liborca.DeviceCapabilities.bit_depth_32,
        .channels_max = 2,
        .state = .active,
        .bus = .usb,
    }});
    try expectWritten("48 kHz · 24-bit", writeDeviceSupports, .{liborca.DeviceCapabilities{
        .rate_min = 48_000,
        .rate_max = 48_000,
        .bit_depths = liborca.DeviceCapabilities.bit_depth_24,
        .channels_max = 2,
        .state = .active,
        .bus = .hdmi,
    }});
    try expectWritten("any rate · 32-bit", writeDeviceSupports, .{liborca.DeviceCapabilities{
        .rate_min = 1,
        .rate_max = std.math.maxInt(i32),
        .bit_depths = liborca.DeviceCapabilities.bit_depth_32,
        .channels_max = 2,
        .state = .active,
        .bus = .virtual,
    }});
    try expectWritten("", writeDeviceSupports, .{liborca.DeviceCapabilities{
        .rate_min = 0,
        .rate_max = 0,
        .bit_depths = 0,
        .channels_max = 0,
        .state = .active,
        .bus = .unknown,
    }});
}

test "a device's note names its bus and what the bus means for the signal" {
    const hdmi: liborca.DeviceCapabilities = .{ .rate_min = 32_000, .rate_max = 48_000, .bit_depths = 0, .channels_max = 8, .state = .active, .bus = .hdmi };
    try expectWritten("USB · bit-perfect capable", writeDeviceNote, .{ liborca.DeviceKind.usb, @as(?liborca.DeviceCapabilities, null) });
    try expectWritten("HDMI · up to 48 kHz", writeDeviceNote, .{ liborca.DeviceKind.hdmi, @as(?liborca.DeviceCapabilities, hdmi) });
    try expectWritten("HDMI", writeDeviceNote, .{ liborca.DeviceKind.hdmi, @as(?liborca.DeviceCapabilities, null) });
    try expectWritten("Bluetooth · lossy, re-encoded by the OS", writeDeviceNote, .{ liborca.DeviceKind.bluetooth, @as(?liborca.DeviceCapabilities, null) });
    try expectWritten("Virtual", writeDeviceNote, .{ liborca.DeviceKind.virtual, @as(?liborca.DeviceCapabilities, null) });
    try expectWritten("", writeDeviceNote, .{ liborca.DeviceKind.unknown, @as(?liborca.DeviceCapabilities, null) });
    var gone = hdmi;
    gone.state = .unavailable;
    try expectWritten("HDMI · not responding", writeDeviceNote, .{ liborca.DeviceKind.hdmi, @as(?liborca.DeviceCapabilities, gone) });
    gone.bus = .unknown;
    try expectWritten("Not responding", writeDeviceNote, .{ liborca.DeviceKind.unknown, @as(?liborca.DeviceCapabilities, gone) });
}

test "the chain runs from the source format through the engine to the device" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeChain(&writer, flacPath(), "USB DAC");
    try testing.expectEqualStrings("FLAC 16-bit / 44.1 kHz → 32-bit float → USB DAC", writer.buffered());
}
fn hd650Path() liborca.SignalPath {
    var path = withReason(flacPath(), .sample_processing);
    path.replay_gain_db = -5.3;
    path.replay_gain_source = .track;
    path.parametric = testParametric(&.{
        .{ .kind = .low_shelf, .frequency_hz = 80, .gain_db = -1.5, .q = 0.707 },
        .{ .kind = .peak, .frequency_hz = 250, .gain_db = -2, .q = 1.1 },
        .{ .kind = .peak, .frequency_hz = 3200, .gain_db = 1.8, .q = 1 },
        .{ .kind = .high_shelf, .frequency_hz = 8500, .gain_db = 2.5, .q = 0.707 },
    }, -3);
    path.output_kind = .usb;
    return path;
}

const hd650_context: Context = .{
    .title = "DR. WHOEVER",
    .artist = "Aminé",
    .device = "Topping DX7 Pro",
    .replay_gain_mode = .track,
    .preset = "HD 650",
};

fn expectStage(
    path: liborca.SignalPath,
    context: Context,
    stage: Stage,
    value: []const u8,
    lines: []const u8,
    changes: bool,
) !void {
    try testing.expect(applies(path, stage, context));
    try expectWritten(value, writeValue, .{ path, stage });
    try expectWritten(lines, writeLines, .{ path, stage, context });
    try testing.expectEqual(changes, changesSamples(path, stage));
}

test "each stage names its value, its lines and whether it changes the samples" {
    const path = hd650Path();
    try expectStage(path, hd650_context, .source, "FLAC", "DR. WHOEVER · Aminé\n16-bit · 44.1 kHz · Stereo", false);
    try expectStage(path, hd650_context, .replay_gain, "−5.3 dB", "Track gain · peak protection on", true);
    try expectStage(path, hd650_context, .parametric, "4 filters", "HD 650 preset · preamp −3.0 dB", true);
    try expectStage(path, hd650_context, .engine, "32-bit float", "Orca audio engine · no resampling", false);
    try expectStage(path, hd650_context, .system, "PipeWire", "44.1 kHz", false);
    try expectStage(path, hd650_context, .output, "USB", "Topping DX7 Pro\n44.1 kHz · 32-bit float · 2 ch", false);
}

test "stages that do not apply to the path are left out" {
    const path = hd650Path();
    for ([_]Stage{ .graphic, .crossfeed, .volume }) |stage|
        try testing.expect(!applies(path, stage, hd650_context));
    const plain = flacPath();
    for ([_]Stage{ .replay_gain, .parametric, .graphic, .crossfeed, .volume }) |stage|
        try testing.expect(!applies(plain, stage, .{}));
    try testing.expect(applies(plain, .replay_gain, .{ .replay_gain_mode = .album }));
    var closed = flacPath();
    closed.output = null;
    try testing.expect(!applies(closed, .system, .{}));
    try testing.expect(!applies(closed, .output, .{}));
}

test "the parametric table gives each filter's type, frequency, gain and Q" {
    var path = hd650Path();
    path.parametric.?.filters[4] = .{ .kind = .high_pass, .frequency_hz = 25, .q = 0.5, .enabled = false };
    path.parametric.?.count = 5;
    try testing.expectEqual(@as(usize, 5), tableRows(path, .parametric));
    const expected = [_][table_columns][]const u8{
        .{ "Low shelf", "80 Hz", "−1.5 dB", "Q 0.7" },
        .{ "Bell", "250 Hz", "−2.0 dB", "Q 1.1" },
        .{ "Bell", "3.2 kHz", "+1.8 dB", "Q 1.0" },
        .{ "High shelf", "8.5 kHz", "+2.5 dB", "Q 0.7" },
        .{ "High pass (off)", "25 Hz", "", "Q 0.5" },
    };
    for (expected, 0..) |row, index| for (row, 0..) |cell, column|
        try expectWritten(cell, writeTableCell, .{ path, Stage.parametric, index, column });
}

test "the graphic table names each band by its centre frequency" {
    var path = flacPath();
    path.equalizer = .{ .gains_db = .{ 0, 0, 0, 0, 0, -2, 0, 0, 0, 3 } };
    try testing.expectEqual(@as(usize, 10), tableRows(path, .graphic));
    try expectWritten("31 Hz", writeTableCell, .{ path, Stage.graphic, @as(usize, 0), @as(usize, 0) });
    try expectWritten("1 kHz", writeTableCell, .{ path, Stage.graphic, @as(usize, 5), @as(usize, 0) });
    try expectWritten("−2.0 dB", writeTableCell, .{ path, Stage.graphic, @as(usize, 5), @as(usize, 2) });
    try expectWritten("+3.0 dB", writeTableCell, .{ path, Stage.graphic, @as(usize, 9), @as(usize, 2) });
}

test "the ReplayGain stage names album gain and the track figure it replaced" {
    var path = flacPath();
    path.replay_gain_db = -3.1;
    path.replay_gain_source = .album;
    path.replay_gain_track_db = -6.2;
    const album: Context = .{ .replay_gain_mode = .album };
    try expectWritten("Album gain · peak protection on\nTrack gain alone −6.2 dB", writeLines, .{ path, Stage.replay_gain, album });
    path.replay_gain_track_db = -3.1;
    try expectWritten("Album gain · peak protection on", writeLines, .{ path, Stage.replay_gain, album });
    path.replay_gain_db = -6.2;
    path.replay_gain_source = .track_fallback;
    path.replay_gain_track_db = null;
    try expectWritten("Track gain · peak protection on\nNo album gain for this track", writeLines, .{ path, Stage.replay_gain, album });
    try expectWritten("Album gain · no adjustment for this track", writeLines, .{ flacPath(), Stage.replay_gain, album });
    try expectWritten("None", writeValue, .{ flacPath(), Stage.replay_gain });
}

test "resampling shows on the Engine or the System stage, whichever does it" {
    var orca = withReason(flacPath(), .sample_rate_conversion);
    orca.output.?.sample_rate = 96_000;
    orca.device_rate = 96_000;
    try expectStage(orca, .{}, .engine, "32-bit float", "Orca audio engine · resamples 44.1 → 96 kHz", true);
    try expectStage(orca, .{}, .system, "PipeWire", "96 kHz", false);
    var pipewire = flacPath();
    pipewire.device_rate = 48_000;
    try expectStage(pipewire, .{}, .engine, "32-bit float", "Orca audio engine · no resampling", false);
    try expectStage(pipewire, .{}, .system, "PipeWire", "Resamples 44.1 → 48 kHz", true);
}

test "the System detail leads with the output's block size once it is known" {
    try expectWritten("Block size 256 frames\n" ++ pipewire_hedge, writeLiveTech, .{ Stage.system, @as(?u32, 256), @as(?liborca.PlayerSnapshot, null), @as(?liborca.ZoneStats, null) });
    try expectWritten(pipewire_hedge, writeLiveTech, .{ Stage.system, @as(?u32, null), @as(?liborca.PlayerSnapshot, null), @as(?liborca.ZoneStats, null) });
}

test "the closing verdict names what changes the samples and what resamples" {
    try expectWritten(
        "Not bit-perfect: ReplayGain and EQ change the samples. Nothing is resampled between source and output. The device's own format is unknown.",
        writeFooter,
        .{hd650Path()},
    );
    try expectWritten("Bit-perfect: nothing changes the samples between source and output. The device's own format is unknown.", writeFooter, .{flacPath()});
    var orca = withReason(flacPath(), .sample_rate_conversion);
    orca.output.?.sample_rate = 96_000;
    orca.device_rate = 96_000;
    try expectWritten("Not bit-perfect: Orca resamples 44.1 → 96 kHz. The device's own format is unknown.", writeFooter, .{orca});
    var lossy = withReason(flacPath(), .lossy_source);
    lossy.device_rate = 48_000;
    try expectWritten(
        "Not bit-perfect: the source is lossy, so no path from it is bit-perfect. PipeWire resamples 44.1 → 48 kHz. The device's own format is unknown.",
        writeFooter,
        .{lossy},
    );
    var mixed = withReason(withReason(flacPath(), .lossy_source), .sample_processing);
    mixed.crossfeed = 0.3;
    mixed.volume = 0.5;
    mixed.replay_gain_db = -1;
    try expectWritten(
        "Not bit-perfect: the source is lossy, so no path from it is bit-perfect. ReplayGain, crossfeed and volume change the samples. Nothing is resampled between source and output. The device's own format is unknown.",
        writeFooter,
        .{mixed},
    );
    var crossfeed = withReason(flacPath(), .sample_processing);
    crossfeed.crossfeed = 0.3;
    crossfeed.device_rate = null;
    try expectWritten("Not bit-perfect: crossfeed changes the samples. The device's own format is unknown.", writeFooter, .{crossfeed});
}

test "a known device format names the conversion into it and drops the unknown note" {
    const float_device: liborca.DeviceFormat = .{ .sample_format = .float_32, .sample_rate = 44_100, .channels = 2 };
    var float_path = flacPath();
    float_path.device_format = float_device;
    try expectWritten("Bit-perfect: nothing changes the samples between source and output.", writeFooter, .{float_path});
    var integer = withReason(flacPath(), .sample_format_conversion);
    integer.device_format = .{ .sample_format = .signed_24_32, .sample_rate = 44_100, .channels = 2 };
    try expectWritten(
        "Not bit-perfect: the samples are converted to the device's 24-bit format. Nothing is resampled between source and output.",
        writeFooter,
        .{integer},
    );
    var rounded = withReason(flacPath(), .sample_format_conversion);
    rounded.device_format = float_device;
    try expectWritten(
        "Not bit-perfect: the samples are rounded to fit the output's format. Nothing is resampled between source and output.",
        writeFooter,
        .{rounded},
    );
    var closed = flacPath();
    closed.output = null;
    try expectWritten("No output is open yet.", writeFooter, .{closed});
}

test "the Output stage names the device's own format once it is known, and the float stream converted into it" {
    var path = hd650Path();
    path.device_format = .{ .sample_format = .signed_24_32, .sample_rate = 96_000, .channels = 2 };
    path.device_rate = 96_000;
    try expectStage(
        path,
        hd650_context,
        .output,
        "USB",
        "Topping DX7 Pro\n96 kHz · 24-bit · 2 ch\nConverted from Orca's 32-bit float",
        true,
    );
    path.device_format = .{ .sample_format = .signed_16, .sample_rate = 44_100, .channels = 2 };
    try expectWritten("Topping DX7 Pro\n44.1 kHz · 16-bit · 2 ch\nConverted from Orca's 32-bit float", writeLines, .{ path, Stage.output, hd650_context });
    path.device_format = .{ .sample_format = .signed_32, .sample_rate = 44_100, .channels = 2 };
    try expectWritten("Topping DX7 Pro\n44.1 kHz · 32-bit · 2 ch\nConverted from Orca's 32-bit float", writeLines, .{ path, Stage.output, hd650_context });
    path.device_format = .{ .sample_format = .float_32, .sample_rate = 48_000, .channels = 2 };
    path.device_rate = 48_000;
    try expectStage(path, hd650_context, .output, "USB", "Topping DX7 Pro\n48 kHz · 32-bit float · 2 ch", false);
    path.device_format = null;
    path.device_rate = 44_100;
    try expectStage(path, hd650_context, .output, "USB", "Topping DX7 Pro\n44.1 kHz · 32-bit float · 2 ch", false);
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
