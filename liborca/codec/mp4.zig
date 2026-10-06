//! MP4 audio: the sound track of an MP4/M4A file, read from its movie box.
//!
//! This file owns what the container says about the audio -- the codec
//! configuration, where each packet lives, how long each lasts, and how much
//! of the decoded timeline is encoder priming and padding. Decoding a packet
//! belongs to the codec engines (`alac.zig`, `aac.zig`).

const std = @import("std");
const decoder_api = @import("decoder.zig");
const engine_api = @import("engine.zig");
const storage = @import("../storage/root.zig");
const bmff = storage.iso_bmff;

/// Upper bound on packets in one track. Ten hours of 48 kHz AAC is about
/// 1.7 million; the tables for this many cost 48 MiB.
pub const max_samples: usize = 4 * 1024 * 1024;

pub const Codec = union(enum) {
    /// MPEG-4 AudioSpecificConfig from the `esds` decoder-specific info.
    aac: []const u8,
    /// ALACSpecificConfig, the body of the `alac` box inside the sample entry.
    alac: []const u8,
};

pub const Sample = struct {
    offset: u64,
    size: u32,
};

pub const TimeRun = struct {
    count: u32,
    delta: u32,
};

pub const Track = struct {
    allocator: std.mem.Allocator,
    /// The movie box the codec configuration slices point into.
    movie: []u8,
    codec: Codec,
    /// Sample entry values. For AAC these are the core coder's, which the
    /// decoder may revise (SBR doubles the rate); ALAC's are exact.
    channels: u16,
    sample_rate: u32,
    /// Media timescale: units of `time_runs` and the edit list's media time.
    timescale: u32,
    samples: []Sample,
    time_runs: []TimeRun,
    /// Media time the audible timeline starts at: encoder priming.
    start_time: u64,
    /// Media time the audible timeline lasts, or null to play every packet.
    play_time: ?u64,

    pub fn deinit(self: *Track) void {
        self.allocator.free(self.samples);
        self.allocator.free(self.time_runs);
        self.allocator.free(self.movie);
        self.* = undefined;
    }

    /// Total media time of every packet.
    pub fn mediaTime(self: *const Track) error{InvalidMp4}!u64 {
        var total: u64 = 0;
        for (self.time_runs) |run| total = try checkedAdd(total, @as(u64, run.count) * run.delta);
        return total;
    }

    /// The first packet whose span contains `time`, and the media time that
    /// packet starts at. Past the end, the packet count and the total time.
    pub fn packetAt(self: *const Track, time: u64) error{InvalidMp4}!PacketTime {
        var index: usize = 0;
        var start: u64 = 0;
        for (self.time_runs) |run| {
            const span = @as(u64, run.count) * run.delta;
            const end = try checkedAdd(start, span);
            if (run.delta != 0 and time < end) {
                const into: u64 = (time - start) / run.delta;
                return .{ .index = index + @as(usize, @intCast(into)), .start = start + into * run.delta };
            }
            index += run.count;
            start = end;
        }
        return .{ .index = index, .start = start };
    }
};

pub const PacketTime = struct { index: usize, start: u64 };

fn checkedAdd(a: u64, b: u64) error{InvalidMp4}!u64 {
    return std.math.add(u64, a, b) catch error.InvalidMp4;
}

fn rescale(time: u64, rate: u32, timescale: u32) error{InvalidMp4}!u64 {
    return std.math.cast(u64, @as(u128, time) * rate / timescale) orelse error.InvalidMp4;
}

pub const ParseError = error{
    InvalidMp4,
    Mp4HasNoAudio,
    Mp4TooManySamples,
};

/// Reads the first sound track this module can decode.
pub fn readTrack(allocator: std.mem.Allocator, readable: storage.ReadableSource) !Track {
    const movie = try bmff.readMovie(allocator, readable);
    errdefer allocator.free(movie);
    const movie_timescale = try movieTimescale(movie);

    var traks = bmff.Iterator.init(movie);
    while (try traks.next()) |trak| {
        if (!trak.is("trak")) continue;
        const media = try bmff.Iterator.find(trak.body, "mdia") orelse continue;
        if (!try isSound(media.body)) continue;
        const table = try bmff.descend(media.body, &.{ "minf", "stbl" }) orelse continue;
        const entry = try sampleEntry(table.body) orelse continue;
        const timescale = try mediaTimescale(media.body);

        const time_runs = try readTimeRuns(allocator, table.body);
        errdefer allocator.free(time_runs);
        const samples = try readSamples(allocator, table.body);
        errdefer allocator.free(samples);
        var sample_total: u64 = 0;
        for (time_runs) |run| sample_total += run.count;
        if (sample_total != samples.len) return error.InvalidMp4;

        var track: Track = .{
            .allocator = allocator,
            .movie = movie,
            .codec = entry.codec,
            .channels = entry.channels,
            .sample_rate = entry.sample_rate,
            .timescale = timescale,
            .samples = samples,
            .time_runs = time_runs,
            .start_time = 0,
            .play_time = null,
        };
        try applyGaplessBounds(&track, trak.body, movie, movie_timescale);
        return track;
    }
    return error.Mp4HasNoAudio;
}

fn movieTimescale(movie: []const u8) !u32 {
    const header = try bmff.Iterator.find(movie, "mvhd") orelse return error.InvalidMp4;
    return fullBoxTimescale(header.body);
}

fn mediaTimescale(media: []const u8) !u32 {
    const header = try bmff.Iterator.find(media, "mdhd") orelse return error.InvalidMp4;
    return fullBoxTimescale(header.body);
}

/// `mvhd` and `mdhd` share their layout up to the timescale.
fn fullBoxTimescale(body: []const u8) !u32 {
    if (body.len == 0) return error.InvalidMp4;
    const offset: usize = if (body[0] == 1) 20 else 12;
    const timescale = try bmff.int(u32, body, offset);
    if (timescale == 0) return error.InvalidMp4;
    return timescale;
}

fn isSound(media: []const u8) !bool {
    const handler = try bmff.Iterator.find(media, "hdlr") orelse return false;
    if (handler.body.len < 12) return error.InvalidMp4;
    return std.mem.eql(u8, handler.body[8..12], "soun");
}

const Entry = struct {
    codec: Codec,
    channels: u16,
    sample_rate: u32,
};

/// The first sample description, if it is AAC or ALAC.
fn sampleEntry(table: []const u8) !?Entry {
    const description = try bmff.Iterator.find(table, "stsd") orelse return error.InvalidMp4;
    if (description.body.len < 8) return error.InvalidMp4;
    var entries = bmff.Iterator.init(description.body[8..]);
    const entry = try entries.next() orelse return error.InvalidMp4;
    // AudioSampleEntry: reserved(6) data_reference_index(2) version(2)
    // revision(2) vendor(4) channels(2) sample_size(2) compression_id(2)
    // packet_size(2) sample_rate(4, 16.16), then child boxes. Version 1 and
    // 2 QuickTime entries append 16 and 36 bytes before the children.
    const body = entry.body;
    const version = try bmff.int(u16, body, 8);
    const children_offset: usize = switch (version) {
        0 => 28,
        1 => 44,
        2 => 64,
        else => return error.InvalidMp4,
    };
    if (body.len < children_offset) return error.InvalidMp4;
    const channels = try bmff.int(u16, body, 16);
    const sample_rate = (try bmff.int(u32, body, 24)) >> 16;
    const children = body[children_offset..];

    if (entry.is("mp4a")) {
        const esds = try bmff.Iterator.find(children, "esds") orelse return error.InvalidMp4;
        const config = try audioSpecificConfig(esds.body) orelse return null;
        return .{ .codec = .{ .aac = config }, .channels = channels, .sample_rate = sample_rate };
    }
    if (entry.is("alac")) {
        const cookie = try bmff.Iterator.find(children, "alac") orelse return error.InvalidMp4;
        // Full box: version and flags precede the 24-byte ALACSpecificConfig.
        if (cookie.body.len < 4 + 24) return error.InvalidMp4;
        const config = cookie.body[4..];
        return .{
            .codec = .{ .alac = config },
            .channels = config[9],
            .sample_rate = try bmff.int(u32, config, 20),
        };
    }
    return null;
}

/// The DecoderSpecificInfo of an MPEG-4 audio ES descriptor, or null when the
/// stream is not MPEG-4 or MPEG-2 AAC.
fn audioSpecificConfig(esds: []const u8) !?[]const u8 {
    if (esds.len < 4) return error.InvalidMp4;
    var cursor: usize = 4;
    const es = try descriptor(esds, &cursor, 0x03);
    var es_cursor: usize = 3;
    if (es.len < es_cursor) return error.InvalidMp4;
    const flags = es[2];
    if (flags & 0x80 != 0) es_cursor += 2;
    if (flags & 0x40 != 0) {
        if (es_cursor >= es.len) return error.InvalidMp4;
        es_cursor += 1 + es[es_cursor];
    }
    if (flags & 0x20 != 0) es_cursor += 2;
    const config = try descriptor(es, &es_cursor, 0x04);
    if (config.len < 13) return error.InvalidMp4;
    switch (config[0]) {
        // MPEG-4 audio, and MPEG-2 AAC Main, LC and SSR.
        0x40, 0x66, 0x67, 0x68 => {},
        else => return null,
    }
    var config_cursor: usize = 13;
    return try descriptor(config, &config_cursor, 0x05);
}

/// One descriptor of `tag` at `cursor`: a tag byte, an expandable length of
/// up to four 7-bit groups, and the body.
fn descriptor(bytes: []const u8, cursor: *usize, tag: u8) ![]const u8 {
    if (cursor.* >= bytes.len or bytes[cursor.*] != tag) return error.InvalidMp4;
    cursor.* += 1;
    var length: usize = 0;
    for (0..4) |_| {
        if (cursor.* >= bytes.len) return error.InvalidMp4;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        length = (length << 7) | (byte & 0x7f);
        if (byte & 0x80 == 0) break;
    }
    if (length > bytes.len - cursor.*) return error.InvalidMp4;
    const body = bytes[cursor.*..][0..length];
    cursor.* += length;
    return body;
}

fn readTimeRuns(allocator: std.mem.Allocator, table: []const u8) ![]TimeRun {
    const stts = try bmff.Iterator.find(table, "stts") orelse return error.InvalidMp4;
    const count = try bmff.int(u32, stts.body, 4);
    if (count > max_samples) return error.Mp4TooManySamples;
    if (stts.body.len < 8 + @as(usize, count) * 8) return error.InvalidMp4;
    const runs = try allocator.alloc(TimeRun, count);
    for (runs, 0..) |*run, index| run.* = .{
        .count = try bmff.int(u32, stts.body, 8 + index * 8),
        .delta = try bmff.int(u32, stts.body, 12 + index * 8),
    };
    return runs;
}

fn readSamples(allocator: std.mem.Allocator, table: []const u8) ![]Sample {
    const sizes = try SampleSizes.read(table);
    if (sizes.count > max_samples) return error.Mp4TooManySamples;
    const samples = try allocator.alloc(Sample, sizes.count);
    errdefer allocator.free(samples);
    for (samples, 0..) |*sample, index| sample.size = try sizes.at(index);

    const stsc = try bmff.Iterator.find(table, "stsc") orelse return error.InvalidMp4;
    const runs = try bmff.int(u32, stsc.body, 4);
    if (stsc.body.len < 8 + @as(usize, runs) * 12) return error.InvalidMp4;
    const offsets = try ChunkOffsets.read(table);

    var sample_index: usize = 0;
    var run: usize = 0;
    while (run < runs) : (run += 1) {
        const first_chunk = try bmff.int(u32, stsc.body, 8 + run * 12);
        const per_chunk = try bmff.int(u32, stsc.body, 12 + run * 12);
        const next_first: u64 = if (run + 1 < runs)
            try bmff.int(u32, stsc.body, 8 + (run + 1) * 12)
        else
            @as(u64, offsets.count) + 1;
        if (first_chunk == 0 or next_first < first_chunk) return error.InvalidMp4;
        var chunk: u64 = first_chunk;
        while (chunk < next_first) : (chunk += 1) {
            var offset = try offsets.at(@intCast(chunk - 1));
            for (0..per_chunk) |_| {
                if (sample_index == samples.len) return error.InvalidMp4;
                samples[sample_index].offset = offset;
                offset = try checkedAdd(offset, samples[sample_index].size);
                sample_index += 1;
            }
        }
    }
    if (sample_index != samples.len) return error.InvalidMp4;
    return samples;
}

const SampleSizes = struct {
    body: []const u8,
    count: usize,
    uniform: u32,
    field_bits: u8,

    fn read(table: []const u8) !SampleSizes {
        if (try bmff.Iterator.find(table, "stsz")) |stsz| {
            const uniform = try bmff.int(u32, stsz.body, 4);
            const count = try bmff.int(u32, stsz.body, 8);
            if (uniform == 0 and stsz.body.len < 12 + @as(usize, count) * 4) return error.InvalidMp4;
            return .{ .body = stsz.body[12..], .count = count, .uniform = uniform, .field_bits = 32 };
        }
        const stz2 = try bmff.Iterator.find(table, "stz2") orelse return error.InvalidMp4;
        const field_bits = (try bmff.int(u32, stz2.body, 4)) & 0xff;
        const count = try bmff.int(u32, stz2.body, 8);
        if (field_bits != 4 and field_bits != 8 and field_bits != 16) return error.InvalidMp4;
        if (stz2.body.len < 12 + (@as(usize, count) * field_bits + 7) / 8) return error.InvalidMp4;
        return .{ .body = stz2.body[12..], .count = count, .uniform = 0, .field_bits = @intCast(field_bits) };
    }

    fn at(self: SampleSizes, index: usize) !u32 {
        if (self.uniform != 0) return self.uniform;
        return switch (self.field_bits) {
            32 => try bmff.int(u32, self.body, index * 4),
            16 => try bmff.int(u16, self.body, index * 2),
            8 => self.body[index],
            4 => if (index % 2 == 0) self.body[index / 2] >> 4 else self.body[index / 2] & 0x0f,
            else => unreachable,
        };
    }
};

const ChunkOffsets = struct {
    body: []const u8,
    count: u32,
    wide: bool,

    fn read(table: []const u8) !ChunkOffsets {
        if (try bmff.Iterator.find(table, "stco")) |stco| {
            const count = try bmff.int(u32, stco.body, 4);
            return .{ .body = stco.body[8..], .count = count, .wide = false };
        }
        const co64 = try bmff.Iterator.find(table, "co64") orelse return error.InvalidMp4;
        const count = try bmff.int(u32, co64.body, 4);
        return .{ .body = co64.body[8..], .count = count, .wide = true };
    }

    fn at(self: ChunkOffsets, index: usize) !u64 {
        if (index >= self.count) return error.InvalidMp4;
        return if (self.wide) try bmff.int(u64, self.body, index * 8) else try bmff.int(u32, self.body, index * 4);
    }
};

/// Encoder priming and padding. The edit list is the standard carrier; Apple
/// encoders also write `iTunSMPB`, which is the only carrier in files that
/// predate edit-list support.
fn applyGaplessBounds(track: *Track, trak: []const u8, movie: []const u8, movie_timescale: u32) !void {
    if (try bmff.descend(trak, &.{ "edts", "elst" })) |elst| {
        if (try firstPresentedEdit(elst.body)) |edit| {
            track.start_time = edit.media_time;
            // Segment duration is in movie time; convert to media time.
            track.play_time = try rescale(edit.duration, track.timescale, movie_timescale);
            return;
        }
    }
    if (try iTunesGaplessInfo(movie)) |info| {
        track.start_time = info.priming;
        track.play_time = info.frames;
    }
}

const Edit = struct { duration: u64, media_time: u64 };

/// The first edit that presents media, skipping an initial empty edit.
fn firstPresentedEdit(body: []const u8) !?Edit {
    if (body.len < 8) return error.InvalidMp4;
    const version = body[0];
    const count = try bmff.int(u32, body, 4);
    const entry_bytes: usize = if (version == 1) 20 else 12;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const at = 8 + index * entry_bytes;
        const duration: u64 = if (version == 1) try bmff.int(u64, body, at) else try bmff.int(u32, body, at);
        const media_time: i64 = if (version == 1)
            try bmff.int(i64, body, at + 8)
        else
            try bmff.int(i32, body, at + 4);
        if (media_time < 0) continue;
        return .{ .duration = duration, .media_time = @intCast(media_time) };
    }
    return null;
}

const GaplessInfo = struct { priming: u64, frames: u64 };

/// `----:com.apple.iTunes:iTunSMPB`: space-separated hex fields, of which the
/// second is priming, the third padding and the fourth the audible length.
fn iTunesGaplessInfo(movie: []const u8) !?GaplessInfo {
    const list = try bmff.descend(movie, &.{ "udta", "meta" }) orelse return null;
    if (list.body.len < 4) return null;
    const items = try bmff.Iterator.find(list.body[4..], "ilst") orelse return null;
    var boxes = bmff.Iterator.init(items.body);
    while (try boxes.next()) |item| {
        if (!item.is("----")) continue;
        const name = try bmff.Iterator.find(item.body, "name") orelse continue;
        if (name.body.len < 4 or !std.mem.eql(u8, name.body[4..], "iTunSMPB")) continue;
        const data = try bmff.Iterator.find(item.body, "data") orelse continue;
        if (data.body.len < 8) continue;
        var fields = std.mem.tokenizeScalar(u8, data.body[8..], ' ');
        _ = fields.next() orelse return null;
        const priming = std.fmt.parseUnsigned(u64, fields.next() orelse return null, 16) catch return null;
        _ = fields.next() orelse return null;
        const frames = std.fmt.parseUnsigned(u64, fields.next() orelse return null, 16) catch return null;
        return .{ .priming = priming, .frames = frames };
    }
    return null;
}

/// What the file declares about its audio, read from the movie box alone.
///
/// Setting up an AAC decoder costs milliseconds and a scan probes every file,
/// so the container answers here. Duration uses the decoder's own gapless
/// arithmetic, so the two cannot disagree.
pub fn probe(allocator: std.mem.Allocator, source: storage.ReadableSource) !@import("registry.zig").Properties {
    var track = try readTrack(allocator, source);
    defer track.deinit();
    return probeTrack(&track);
}

/// `probe` for a track from any container that yields one.
pub fn probeTrack(track: *const Track) !@import("registry.zig").Properties {
    const output: Output = switch (track.codec) {
        .alac => |config| .{
            .codec = decoder_api.codec_id.alac,
            .sample_rate = try bmff.int(u32, config, 20),
            .channels = config[9],
            .bit_depth = config[5],
        },
        .aac => |config| aacOutput(config, track),
    };
    if (output.sample_rate == 0 or output.channels == 0) return error.InvalidMp4;
    const start = try rescale(track.start_time, output.sample_rate, track.timescale);
    const available = try rescale(try track.mediaTime(), output.sample_rate, track.timescale) -| start;
    const frames = if (track.play_time) |time|
        @min(try rescale(time, output.sample_rate, track.timescale), available)
    else
        available;
    return .{
        .codec = output.codec,
        .sample_rate = output.sample_rate,
        .channels = output.channels,
        .bit_depth = output.bit_depth,
        .duration_ms = try rescale(frames, std.time.ms_per_s, output.sample_rate),
    };
}

const Output = struct {
    codec: []const u8,
    sample_rate: u32,
    channels: u16,
    bit_depth: ?u16 = null,
};

pub const sampling_rates = [_]u32{ 96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350 };

/// Output rate and channels from an AudioSpecificConfig. Explicitly signalled
/// SBR doubles the rate and PS makes the output stereo; implicit SBR is only
/// visible in the bitstream, so it is taken from the media timescale, which
/// muxers set to the output rate.
fn aacOutput(config: []const u8, track: *const Track) Output {
    var bits: BitReader = .{ .bytes = config };
    const fallback: Output = .{
        .codec = decoder_api.codec_id.aac,
        .sample_rate = track.timescale,
        .channels = track.channels,
    };
    var object_type = objectType(&bits) orelse return fallback;
    var rate = samplingRate(&bits) orelse return fallback;
    const channel_config = bits.read(4) orelse return fallback;
    var stereo_from_ps = false;
    if (object_type == 5 or object_type == 29) {
        stereo_from_ps = object_type == 29;
        rate = samplingRate(&bits) orelse return fallback;
        object_type = objectType(&bits) orelse return fallback;
    } else if (track.timescale == rate * 2) {
        rate = track.timescale;
    }
    const channels: u16 = if (stereo_from_ps)
        2
    else switch (channel_config) {
        1...6 => @intCast(channel_config),
        7 => 8,
        else => track.channels,
    };
    return .{ .codec = decoder_api.codec_id.aac, .sample_rate = rate, .channels = channels };
}

fn objectType(bits: *BitReader) ?u32 {
    const value = bits.read(5) orelse return null;
    if (value != 31) return value;
    return 32 + (bits.read(6) orelse return null);
}

fn samplingRate(bits: *BitReader) ?u32 {
    const index = bits.read(4) orelse return null;
    if (index == 15) return bits.read(24);
    if (index >= sampling_rates.len) return null;
    return sampling_rates[index];
}

const BitReader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn read(self: *BitReader, count: u5) ?u32 {
        var value: u32 = 0;
        for (0..count) |_| {
            const byte = self.position / 8;
            if (byte >= self.bytes.len) return null;
            const bit = (self.bytes[byte] >> @intCast(7 - self.position % 8)) & 1;
            value = (value << 1) | bit;
            self.position += 1;
        }
        return value;
    }
};

/// Upper bound on one packet. ALAC's largest legal packet for eight channels
/// of 32-bit audio is under 1.2 MiB.
const max_packet_bytes: u32 = 4 * 1024 * 1024;

/// Opens the sound track as an Orca `Decoder`. The engine is chosen by the
/// sample entry; the timeline is trimmed to the gapless bounds.
pub fn openDecoder(allocator: std.mem.Allocator, source: storage.ReadableSource) !decoder_api.Decoder {
    return openTrack(allocator, source, try readTrack(allocator, source));
}

/// The packet-loop decoder over a track from any container that yields one.
/// Takes ownership of `track`, including on failure.
pub fn openTrack(allocator: std.mem.Allocator, source: storage.ReadableSource, track: Track) !decoder_api.Decoder {
    var owned = track;
    const context = allocator.create(Context) catch |err| {
        owned.deinit();
        return err;
    };
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .source = source,
        .track = owned,
        .engine = undefined,
        .packet = &.{},
        .pcm = &.{},
        .integers = &.{},
    };
    errdefer context.track.deinit();
    const codec_name, context.engine = switch (context.track.codec) {
        .alac => |config| .{ decoder_api.codec_id.alac, try @import("alac.zig").open(config) },
        .aac => |config| .{ decoder_api.codec_id.aac, try openAac(allocator, source, &context.track, config) },
    };
    errdefer context.engine.deinit();
    const engine = context.engine;
    if (engine.channels == 0 or engine.sample_rate == 0) return error.InvalidMp4;

    var largest: u32 = 0;
    for (context.track.samples) |sample| largest = @max(largest, sample.size);
    if (largest > max_packet_bytes) return error.InvalidMp4;
    context.packet = try allocator.alloc(u8, largest);
    errdefer allocator.free(context.packet);
    const packet_samples = @as(usize, engine.max_packet_frames) * engine.channels;
    if (engine.hasIntegerSamples())
        context.integers = try allocator.alloc(i32, packet_samples)
    else
        context.pcm = try allocator.alloc(f32, packet_samples);
    errdefer allocator.free(context.integers);
    errdefer allocator.free(context.pcm);

    context.start_frame = try context.toFrames(context.track.start_time);
    const available = try context.toFrames(try context.track.mediaTime()) -| context.start_frame;
    context.total_frames = if (context.track.play_time) |time|
        @min(try context.toFrames(time), available)
    else
        available;
    try context.position(0);

    return .{
        .context = context,
        .vtable = if (engine.hasIntegerSamples()) &integer_vtable else &vtable,
        .codec = codec_name,
        .source_format = if (engine.bits_per_sample) |bits| .{
            .sample_format = if (bits <= 16) .signed_16 else if (bits <= 24) .signed_24 else .signed_32,
            .channels = engine.channels,
            .sample_rate = engine.sample_rate,
            .bits_per_sample = bits,
            .bytes_per_frame = try std.math.mul(u16, engine.channels, (bits + 7) / 8),
        } else null,
        .format = .{
            .sample_format = .float_32,
            .channels = engine.channels,
            .sample_rate = engine.sample_rate,
            .bits_per_sample = 32,
            .bytes_per_frame = try std.math.mul(u16, engine.channels, 4),
        },
        .frame_count = context.total_frames,
    };
}

fn openAac(
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
    track: *const Track,
    config: []const u8,
) !engine_api.Engine {
    if (track.samples.len == 0) return error.InvalidMp4;
    const first = track.samples[0];
    if (first.size > max_packet_bytes) return error.InvalidMp4;
    const unit = try allocator.alloc(u8, first.size);
    defer allocator.free(unit);
    if (try source.readAt(first.offset, unit) != unit.len) return error.TruncatedMp4;
    return @import("aac.zig").open(config, unit);
}

const Context = struct {
    allocator: std.mem.Allocator,
    source: storage.ReadableSource,
    track: Track,
    engine: engine_api.Engine,
    packet: []u8,
    /// One decoded packet, of which `pending_start..pending_end` is unread:
    /// in `integers` when the engine decodes integer samples, else in `pcm`.
    pcm: []f32,
    integers: []i32,
    pending_start: usize = 0,
    pending_end: usize = 0,
    next_packet: usize = 0,
    /// Frames still to discard from the next decoded packets: priming, or the
    /// part of a pre-rolled packet before a seek target.
    skip_frames: u64 = 0,
    /// Output frames still to emit before the audible timeline ends.
    remaining_frames: u64 = 0,
    start_frame: u64 = 0,
    total_frames: u64 = 0,

    /// Media time converted to frames at the engine's output rate, which SBR
    /// makes twice an HE-AAC track's media timescale.
    fn toFrames(self: *const Context, time: u64) !u64 {
        return rescale(time, self.engine.sample_rate, self.track.timescale);
    }

    fn toTime(self: *const Context, frames: u64) !u64 {
        return rescale(frames, self.track.timescale, self.engine.sample_rate);
    }

    /// Positions the timeline at `frame` frames past the audible start.
    fn position(self: *Context, frame: u64) !void {
        const target = try checkedAdd(self.start_frame, frame);
        const found = try self.track.packetAt(try self.toTime(target));
        const first = found.index -| self.engine.preroll_packets;
        const first_start = try self.packetStart(first);
        self.engine.reset();
        self.next_packet = first;
        self.skip_frames = target - @min(target, try self.toFrames(first_start));
        self.remaining_frames = self.total_frames -| frame;
        self.pending_start = 0;
        self.pending_end = 0;
    }

    /// Media time at which packet `index` starts.
    fn packetStart(self: *const Context, index: usize) !u64 {
        var remaining = index;
        var start: u64 = 0;
        for (self.track.time_runs) |run| {
            const taken = @min(remaining, run.count);
            start = try checkedAdd(start, @as(u64, taken) * run.delta);
            remaining -= taken;
            if (remaining == 0) break;
        }
        return start;
    }

    /// A decoder that withholds the start of a packet -- libxaac does so for
    /// the first access unit after init -- would shift everything after it
    /// earlier than the sample table places it. The withheld frames are put
    /// back as silence at the front; they are encoder priming or seek
    /// pre-roll, and are skipped. The last packet is exempt: it is legitimately
    /// shorter than its successors' spacing.
    fn alignToPacket(self: *Context, comptime T: type, buffer: []T, index: usize, frames: u64) !u64 {
        if (index + 1 >= self.track.samples.len) return frames;
        const expected = try self.toFrames(try self.packetStart(index + 1) - try self.packetStart(index));
        const capacity = buffer.len / self.engine.channels;
        if (frames >= expected or expected > capacity) return frames;
        const channels = self.engine.channels;
        const decoded_frames: usize = @intCast(frames);
        const missing: usize = @intCast(expected - frames);
        const decoded = buffer[0 .. decoded_frames * channels];
        std.mem.copyBackwards(T, buffer[missing * channels ..][0..decoded.len], decoded);
        @memset(buffer[0 .. missing * channels], 0);
        return expected;
    }

    const Taken = struct { start: usize = 0, samples: usize = 0 };

    /// Claims up to `capacity` samples of whole frames from the pending
    /// packet, decoding the next one when it is spent.
    fn take(self: *Context, capacity: usize) !Taken {
        const channels = self.engine.channels;
        if (self.remaining_frames == 0) return .{};
        if (self.pending_start == self.pending_end and !try self.decodeNext()) return .{};
        const pending = (self.pending_end - self.pending_start) / channels;
        const frames = @min(pending, capacity / channels, self.remaining_frames);
        const taken: Taken = .{ .start = self.pending_start, .samples = frames * channels };
        self.pending_start += taken.samples;
        self.remaining_frames -= frames;
        return taken;
    }

    fn decodeNext(self: *Context) !bool {
        while (self.next_packet < self.track.samples.len) {
            const index = self.next_packet;
            const sample = self.track.samples[index];
            self.next_packet += 1;
            const bytes = self.packet[0..sample.size];
            if (try self.source.readAt(sample.offset, bytes) != bytes.len) return error.TruncatedMp4;
            const frames: u64 = if (self.engine.hasIntegerSamples())
                try self.alignToPacket(i32, self.integers, index, try self.engine.decodeI32(bytes, self.integers))
            else
                try self.alignToPacket(f32, self.pcm, index, try self.engine.decode(bytes, self.pcm));
            const dropped = @min(frames, self.skip_frames);
            self.skip_frames -= dropped;
            if (frames == dropped) continue;
            const channels = self.engine.channels;
            self.pending_start = @intCast(dropped * channels);
            self.pending_end = @intCast(frames * channels);
            return true;
        }
        return false;
    }
};

fn readFrames(context_ptr: *anyopaque, output: []f32) !usize {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const taken = try context.take(output.len);
    const destination = output[0..taken.samples];
    if (context.engine.hasIntegerSamples()) {
        for (destination, context.integers[taken.start..][0..taken.samples]) |*sample, integer|
            sample.* = decoder_api.integerSampleToFloat(integer);
    } else @memcpy(destination, context.pcm[taken.start..][0..taken.samples]);
    return taken.samples / context.engine.channels;
}

fn readFramesI32(context_ptr: *anyopaque, output: []i32) !usize {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const taken = try context.take(output.len);
    @memcpy(output[0..taken.samples], context.integers[taken.start..][0..taken.samples]);
    return taken.samples / context.engine.channels;
}

fn seek(context_ptr: *anyopaque, frame: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (frame >= context.total_frames) {
        context.remaining_frames = 0;
        context.pending_start = 0;
        context.pending_end = 0;
        return;
    }
    try context.position(frame);
}

fn deinit(context_ptr: *anyopaque) void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const allocator = context.allocator;
    context.engine.deinit();
    allocator.free(context.pcm);
    allocator.free(context.integers);
    allocator.free(context.packet);
    context.track.deinit();
    allocator.destroy(context);
}

const vtable: decoder_api.Decoder.VTable = .{
    .read_frames = readFrames,
    .seek = seek,
    .deinit = deinit,
};

const integer_vtable: decoder_api.Decoder.VTable = .{
    .read_frames = readFrames,
    .read_frames_i32 = readFramesI32,
    .seek = seek,
    .deinit = deinit,
};

fn openFixture(path: []const u8) !Track {
    var file = try storage.LocalFileSource.open(std.testing.io, path);
    defer file.close();
    return readTrack(std.testing.allocator, file.readable());
}

test "an ALAC track exposes its configuration and packet table" {
    var track = try openFixture("fixtures/audio/tagged-reference-alac.m4a");
    defer track.deinit();
    try std.testing.expect(track.codec == .alac);
    try std.testing.expectEqual(@as(usize, 24), track.codec.alac.len);
    try std.testing.expectEqual(@as(u16, 2), track.channels);
    try std.testing.expectEqual(@as(u32, 44_100), track.sample_rate);
    try std.testing.expectEqual(@as(u32, 44_100), track.timescale);
    try std.testing.expectEqual(@as(usize, 3), track.samples.len);
    try std.testing.expectEqual(@as(u64, 8_820), try track.mediaTime());
    try std.testing.expectEqual(@as(u64, 0), track.start_time);
    try std.testing.expectEqual(@as(?u64, 8_820), track.play_time);
}

test "an AAC track's edit list trims encoder priming to the source length" {
    var track = try openFixture("fixtures/audio/tagged-reference-aac.m4a");
    defer track.deinit();
    try std.testing.expect(track.codec == .aac);
    try std.testing.expect(track.codec.aac.len >= 2);
    try std.testing.expectEqual(@as(u32, 48_000), track.timescale);
    try std.testing.expectEqual(@as(usize, 11), track.samples.len);
    try std.testing.expectEqual(@as(u64, 1_024), track.start_time);
    try std.testing.expectEqual(@as(?u64, 9_600), track.play_time);
}

test "a packet is found by the media time it contains" {
    var track = try openFixture("fixtures/audio/tagged-reference-aac.m4a");
    defer track.deinit();
    const first = try track.packetAt(0);
    try std.testing.expectEqual(@as(usize, 0), first.index);
    const later = try track.packetAt(2_500);
    try std.testing.expectEqual(@as(usize, 2), later.index);
    try std.testing.expectEqual(@as(u64, 2_048), later.start);
}

test "packets sit inside the file and in order" {
    var file = try storage.LocalFileSource.open(std.testing.io, "fixtures/audio/tagged-reference-aac.m4a");
    defer file.close();
    var track = try readTrack(std.testing.allocator, file.readable());
    defer track.deinit();
    var previous_end: u64 = 0;
    for (track.samples) |sample| {
        try std.testing.expect(sample.offset >= previous_end);
        previous_end = sample.offset + sample.size;
    }
    try std.testing.expect(previous_end <= file.readable().size());
}

fn decodeAll(decoder: *decoder_api.Decoder, output: []f32) !usize {
    var frames: usize = 0;
    while (true) {
        const read = try decoder.readFrames(output[frames * decoder.format.channels ..]);
        if (read == 0) return frames;
        frames += read;
    }
}

fn decodeFixture(path: []const u8, output: []f32) !usize {
    var file = try storage.LocalFileSource.open(std.testing.io, path);
    defer file.close();
    var decoder = try @import("registry.zig").CodecRegistry.builtins().openDetected(
        std.testing.allocator,
        file.readable(),
    );
    defer decoder.deinit();
    return decodeAll(&decoder, output);
}

test "ALAC in MP4 decodes bit-identically to the FLAC it was encoded from" {
    const alac = try std.testing.allocator.alloc(f32, 10_000 * 2);
    defer std.testing.allocator.free(alac);
    const flac = try std.testing.allocator.alloc(f32, 10_000 * 2);
    defer std.testing.allocator.free(flac);
    const alac_frames = try decodeFixture("fixtures/audio/tagged-reference-alac.m4a", alac);
    const flac_frames = try decodeFixture("fixtures/audio/tagged-reference.flac", flac);
    try std.testing.expectEqual(@as(usize, 8_820), alac_frames);
    try std.testing.expectEqual(flac_frames, alac_frames);
    try std.testing.expectEqualSlices(f32, flac[0 .. flac_frames * 2], alac[0 .. alac_frames * 2]);
}

test "an ALAC decoder reports lossless source facts" {
    var file = try storage.LocalFileSource.open(std.testing.io, "fixtures/audio/tagged-reference-alac.m4a");
    defer file.close();
    var decoder = try openDecoder(std.testing.allocator, file.readable());
    defer decoder.deinit();
    try std.testing.expectEqualStrings("alac", decoder.codec);
    try std.testing.expectEqual(@as(u16, 16), decoder.source_format.?.bits_per_sample);
    try std.testing.expectEqual(@as(u32, 44_100), decoder.format.sample_rate);
    try std.testing.expectEqual(@as(?u64, 8_820), decoder.frame_count);
}

test "seeking into ALAC lands on the exact frame" {
    const whole = try std.testing.allocator.alloc(f32, 10_000 * 2);
    defer std.testing.allocator.free(whole);
    _ = try decodeFixture("fixtures/audio/tagged-reference-alac.m4a", whole);

    var file = try storage.LocalFileSource.open(std.testing.io, "fixtures/audio/tagged-reference-alac.m4a");
    defer file.close();
    var decoder = try openDecoder(std.testing.allocator, file.readable());
    defer decoder.deinit();
    // Inside the second 4,096-frame packet, so the packet is found by time
    // and its head is skipped.
    try decoder.seek(5_000);
    const tail = try std.testing.allocator.alloc(f32, 10_000 * 2);
    defer std.testing.allocator.free(tail);
    try std.testing.expectEqual(@as(usize, 3_820), try decodeAll(&decoder, tail));
    try std.testing.expectEqualSlices(f32, whole[5_000 * 2 .. 8_820 * 2], tail[0 .. 3_820 * 2]);
}

test "AAC in MP4 decodes to exactly the source length, trimmed of encoder priming" {
    var file = try storage.LocalFileSource.open(std.testing.io, "fixtures/audio/tagged-reference-aac.m4a");
    defer file.close();
    var decoder = try openDecoder(std.testing.allocator, file.readable());
    defer decoder.deinit();
    try std.testing.expectEqualStrings("aac", decoder.codec);
    try std.testing.expect(decoder.source_format == null);
    try std.testing.expectEqual(@as(u16, 2), decoder.format.channels);
    try std.testing.expectEqual(@as(u32, 48_000), decoder.format.sample_rate);
    try std.testing.expectEqual(@as(?u64, 9_600), decoder.frame_count);
    const samples = try std.testing.allocator.alloc(f32, 12_000 * 2);
    defer std.testing.allocator.free(samples);
    try std.testing.expectEqual(@as(usize, 9_600), try decodeAll(&decoder, samples));
}

/// The source `chirp-reference-aac.m4a` was encoded from, regenerated so the
/// expectation cannot drift. A chirp repeats nowhere, so a decode that is off
/// by any number of frames matches it measurably worse than an aligned one.
fn chirpSample(frame: usize, channel: usize) f32 {
    const t = @as(f64, @floatFromInt(frame)) / 48_000.0;
    const phase = if (channel == 0) 200.0 * t + 2000.0 * t * t else 300.0 * t + 1500.0 * t * t;
    return @floatCast(0.4 * @sin(2.0 * std.math.pi * phase));
}

fn chirpError(decoded: []const f32, first: usize, last: usize, lag: i64) f64 {
    var sum: f64 = 0;
    for (first..last) |frame| {
        const source_frame: usize = @intCast(@as(i64, @intCast(frame)) + lag);
        for (0..2) |channel| {
            const difference: f64 = decoded[frame * 2 + channel] - chirpSample(source_frame, channel);
            sum += difference * difference;
        }
    }
    return sum / @as(f64, @floatFromInt((last - first) * 2));
}

test "AAC decodes aligned to its source, with priming and the decoder's own delay removed" {
    const decoded = try std.testing.allocator.alloc(f32, 12_000 * 2);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqual(
        @as(usize, 9_600),
        try decodeFixture("fixtures/audio/chirp-reference-aac.m4a", decoded),
    );
    const aligned = chirpError(decoded, 1_000, 8_000, 0);
    // The floor is the encoder's coding error: this decode matches FFmpeg's
    // decode of the same file to 16-bit precision.
    try std.testing.expect(aligned < 2e-4);
    try std.testing.expect(aligned * 3 < chirpError(decoded, 1_000, 8_000, -1));
    try std.testing.expect(aligned * 3 < chirpError(decoded, 1_000, 8_000, 1));
}

test "seeking into AAC lands on the requested frame" {
    var file = try storage.LocalFileSource.open(std.testing.io, "fixtures/audio/chirp-reference-aac.m4a");
    defer file.close();
    var decoder = try openDecoder(std.testing.allocator, file.readable());
    defer decoder.deinit();
    try decoder.seek(4_800);
    const tail = try std.testing.allocator.alloc(f32, 12_000 * 2);
    defer std.testing.allocator.free(tail);
    try std.testing.expectEqual(@as(usize, 4_800), try decodeAll(&decoder, tail));
    const shifted = tail[0 .. 4_800 * 2];
    var sum: f64 = 0;
    for (0..4_000) |frame| {
        const difference: f64 = shifted[frame * 2] - chirpSample(4_800 + frame, 0);
        sum += difference * difference;
    }
    try std.testing.expect(sum / 4_000.0 < 2e-4);
}

test "the container probe reports exactly what the decoder does" {
    const registry = @import("registry.zig");
    for ([_][]const u8{
        "fixtures/audio/tagged-reference-alac.m4a",
        "fixtures/audio/tagged-reference-aac.m4a",
        "fixtures/audio/chirp-reference-aac.m4a",
        "fixtures/audio/covered-reference.m4a",
    }) |path| {
        var file = try storage.LocalFileSource.open(std.testing.io, path);
        defer file.close();
        const declared = try probe(std.testing.allocator, file.readable());
        var decoder = try openDecoder(std.testing.allocator, file.readable());
        defer decoder.deinit();
        const decoded = registry.properties(decoder);
        try std.testing.expectEqualStrings(decoded.codec.?, declared.codec.?);
        try std.testing.expectEqual(decoded.sample_rate, declared.sample_rate);
        try std.testing.expectEqual(decoded.channels, declared.channels);
        try std.testing.expectEqual(decoded.bit_depth, declared.bit_depth);
        try std.testing.expectEqual(decoded.duration_ms, declared.duration_ms);
    }
}

test "a movie with no audio track is reported as such" {
    const movie_header = "\x00\x00\x00\x1cmvhd" ++ &@as([12]u8, @splat(0)) ++ "\x00\x00\x03\xe8" ++ &@as([4]u8, @splat(0));
    var memory = storage.MemorySource{ .bytes = "\x00\x00\x00\x24moov" ++ movie_header };
    try std.testing.expectError(error.Mp4HasNoAudio, readTrack(std.testing.allocator, memory.readable()));
}

fn be32(comptime value: u32) [4]u8 {
    return std.mem.toBytes(std.mem.nativeToBig(u32, value));
}

fn be64(comptime value: u64) [8]u8 {
    return std.mem.toBytes(std.mem.nativeToBig(u64, value));
}

fn testBox(comptime kind: *const [4]u8, comptime body: []const u8) []const u8 {
    return be32(8 + body.len) ++ kind.* ++ body;
}

const TestMovie = struct {
    movie_timescale: u32 = 1000,
    media_timescale: u32 = 44_100,
    sample_count: u32 = 3,
    sample_size: u32 = 32,
    time_runs: []const [2]u32 = &.{.{ 3, 4096 }},
    chunk_offsets: []const u8 = testBox("stco", &@as([4]u8, @splat(0)) ++ be32(1) ++ be32(0)),
    edits: []const u8 = "",

    fn bytes(comptime self: TestMovie) []const u8 {
        comptime {
            const full_box = &@as([4]u8, @splat(0));
            const alac_config = be32(4096) ++ [_]u8{ 0, 16, 40, 10, 14, 2 } ++ be32(255 << 16)[0..2].* ++
                be32(0) ++ be32(0) ++ be32(44_100);
            const sample_entry = testBox(
                "alac",
                &@as([6]u8, @splat(0)) ++ "\x00\x01" ++ &@as([8]u8, @splat(0)) ++ "\x00\x02\x00\x10" ++ &@as([4]u8, @splat(0)) ++
                    be32(44_100 << 16) ++ testBox("alac", full_box ++ alac_config),
            );
            var runs: []const u8 = "";
            for (self.time_runs) |run| runs = runs ++ be32(run[0]) ++ be32(run[1]);
            const table = testBox("stsd", full_box ++ be32(1) ++ sample_entry) ++
                testBox("stts", full_box ++ be32(self.time_runs.len) ++ runs) ++
                testBox("stsz", full_box ++ be32(self.sample_size) ++ be32(self.sample_count)) ++
                testBox("stsc", full_box ++ be32(1) ++ be32(1) ++ be32(self.sample_count) ++ be32(1)) ++
                self.chunk_offsets;
            const media = testBox("mdhd", full_box ++ &@as([8]u8, @splat(0)) ++ be32(self.media_timescale) ++ &@as([8]u8, @splat(0))) ++
                testBox("hdlr", full_box ++ &@as([4]u8, @splat(0)) ++ "soun" ++ &@as([12]u8, @splat(0))) ++
                testBox("minf", testBox("stbl", table));
            const movie_header = testBox("mvhd", full_box ++ &@as([8]u8, @splat(0)) ++ be32(self.movie_timescale) ++ &@as([4]u8, @splat(0)));
            return testBox("moov", movie_header ++ testBox("trak", self.edits ++ testBox("mdia", media)));
        }
    }
};

test "a hand-assembled movie reads as the track it declares" {
    var memory = storage.MemorySource{ .bytes = comptime (TestMovie{}).bytes() };
    var track = try readTrack(std.testing.allocator, memory.readable());
    defer track.deinit();
    try std.testing.expectEqual(@as(usize, 3), track.samples.len);
    try std.testing.expectEqual(@as(u64, 64), track.samples[2].offset);
    try std.testing.expectEqual(@as(u64, 3 * 4096), try track.mediaTime());
}

test "a media time too long to count in frames is invalid rather than a crash" {
    var memory = storage.MemorySource{ .bytes = comptime (TestMovie{
        .media_timescale = 1,
        .sample_count = 1 << 17,
        .time_runs = &.{.{ 1 << 17, 0xffff_ffff }},
    }).bytes() };
    try std.testing.expectError(error.InvalidMp4, openDecoder(std.testing.allocator, memory.readable()));
    try std.testing.expectError(error.InvalidMp4, probe(std.testing.allocator, memory.readable()));
}

test "a chunk offset that runs a packet past 2^64 is invalid" {
    var memory = storage.MemorySource{ .bytes = comptime (TestMovie{
        .sample_count = 1,
        .time_runs = &.{.{ 1, 4096 }},
        .chunk_offsets = testBox("co64", &@as([4]u8, @splat(0)) ++ be32(1) ++ be64(0xffff_ffff_ffff_fff0)),
    }).bytes() };
    try std.testing.expectError(error.InvalidMp4, readTrack(std.testing.allocator, memory.readable()));
}

test "an edit too long to convert to media time is invalid" {
    var memory = storage.MemorySource{ .bytes = comptime (TestMovie{
        .movie_timescale = 1,
        .media_timescale = 96_000,
        .edits = testBox("edts", testBox("elst", "\x01\x00\x00\x00" ++ be32(1) ++
            be64(std.math.maxInt(u64)) ++ be64(0) ++ "\x00\x01\x00\x00")),
    }).bytes() };
    try std.testing.expectError(error.InvalidMp4, readTrack(std.testing.allocator, memory.readable()));
}

test "time runs whose total overflows a u64 are invalid" {
    var samples = [_]Sample{};
    var time_runs = [_]TimeRun{ .{ .count = 0xffff_ffff, .delta = 0xffff_ffff }, .{ .count = 3, .delta = 0xffff_ffff } };
    const track: Track = .{
        .allocator = std.testing.allocator,
        .movie = &.{},
        .codec = .{ .alac = "" },
        .channels = 2,
        .sample_rate = 44_100,
        .timescale = 44_100,
        .samples = &samples,
        .time_runs = &time_runs,
        .start_time = 0,
        .play_time = null,
    };
    try std.testing.expectError(error.InvalidMp4, track.mediaTime());
    try std.testing.expectError(error.InvalidMp4, track.packetAt(std.math.maxInt(u64)));
}
