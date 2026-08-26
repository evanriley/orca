//! Pure-Zig MPEG audio bitstream framing: frame headers, Xing/Info/VBRI
//! headers, the LAME encoder delay/padding extension, and a lazily built
//! frame index used for seeking. Nothing here decodes audio; every routine
//! reads a bounded window from a `ReadableSource` and rejects malformed input
//! with a typed error rather than trusting declared sizes.

const std = @import("std");
const storage = @import("../storage/root.zig");
const id3v2 = @import("../metadata/id3v2.zig");

pub const Error = error{
    /// Bytes that syncs as a frame but cannot be decoded as one.
    InvalidMp3,
    /// The file ends inside the prologue the decoder needs to open it.
    TruncatedMp3,
    /// No confirmable MPEG frame header within the bounded scan window.
    Mp3SyncNotFound,
};

pub const Version = enum {
    mpeg1,
    mpeg2,
    mpeg2_5,

    fn lowSampleRate(self: Version) bool {
        return self != .mpeg1;
    }
};

pub const Layer = enum { layer1, layer2, layer3 };

pub const ChannelMode = enum { stereo, joint_stereo, dual_channel, mono };

/// One parsed 32-bit MPEG audio frame header.
pub const FrameHeader = struct {
    version: Version,
    layer: Layer,
    bitrate_kbps: u32,
    sample_rate: u32,
    padding: bool,
    crc_protected: bool,
    channel_mode: ChannelMode,

    pub fn parse(bytes: [4]u8) ?FrameHeader {
        if (bytes[0] != 0xff or (bytes[1] & 0xe0) != 0xe0) return null;
        const version: Version = switch ((bytes[1] >> 3) & 0x3) {
            0b00 => .mpeg2_5,
            0b01 => return null, // reserved
            0b10 => .mpeg2,
            0b11 => .mpeg1,
            else => unreachable,
        };
        const layer: Layer = switch ((bytes[1] >> 1) & 0x3) {
            0b00 => return null, // reserved
            0b01 => .layer3,
            0b10 => .layer2,
            0b11 => .layer1,
            else => unreachable,
        };
        const bitrate_index: u4 = @intCast(bytes[2] >> 4);
        // Index 0 is free format and index 15 is invalid; neither yields a
        // computable frame size, so neither may enter the index or the seeker.
        if (bitrate_index == 0 or bitrate_index == 15) return null;
        const sample_rate_index: u2 = @intCast((bytes[2] >> 2) & 0x3);
        if (sample_rate_index == 0b11) return null;
        const channel_mode: ChannelMode = switch ((bytes[3] >> 6) & 0x3) {
            0b00 => .stereo,
            0b01 => .joint_stereo,
            0b10 => .dual_channel,
            0b11 => .mono,
            else => unreachable,
        };
        return .{
            .version = version,
            .layer = layer,
            .bitrate_kbps = bitrateTable(version, layer)[bitrate_index],
            .sample_rate = sampleRateTable(version)[sample_rate_index],
            .padding = (bytes[2] & 0x02) != 0,
            .crc_protected = (bytes[1] & 0x01) == 0,
            .channel_mode = channel_mode,
        };
    }

    pub fn channels(self: FrameHeader) u16 {
        return if (self.channel_mode == .mono) 1 else 2;
    }

    pub fn samplesPerFrame(self: FrameHeader) u32 {
        return switch (self.layer) {
            .layer1 => 384,
            .layer2 => 1152,
            .layer3 => if (self.version == .mpeg1) 1152 else 576,
        };
    }

    /// Total on-disk size of this frame including its header and padding.
    pub fn frameBytes(self: FrameHeader) u32 {
        const slot: u32 = if (self.layer == .layer1) 4 else 1;
        const padding: u32 = if (self.padding) slot else 0;
        const bytes_per_frame = (self.samplesPerFrame() / 8) *
            (self.bitrate_kbps * 1000) / self.sample_rate;
        return (bytes_per_frame / slot) * slot + padding;
    }

    /// Layer III side-information size, which is where a Xing/Info tag starts.
    pub fn sideInfoBytes(self: FrameHeader) u32 {
        if (self.layer != .layer3) return 0;
        const mono = self.channel_mode == .mono;
        return if (self.version == .mpeg1)
            (if (mono) @as(u32, 17) else 32)
        else
            (if (mono) @as(u32, 9) else 17);
    }

    /// Bytes of this frame available to the main-data bit reservoir.
    pub fn mainDataBytes(self: FrameHeader) u32 {
        const overhead = 4 + self.sideInfoBytes() + @as(u32, if (self.crc_protected) 2 else 0);
        const total = self.frameBytes();
        return if (total > overhead) total - overhead else 0;
    }

    /// Frames that must be decoded and discarded ahead of a seek target for
    /// the Layer III bit reservoir to be warm. The format bounds the
    /// reservoir at 511 bytes, so this is how many frames it takes to supply
    /// that much main data at this frame size, plus one for the frame that
    /// consumes it. Low-bitrate streams need many more frames than high ones.
    pub fn reservoirPrimerFrames(self: FrameHeader) u32 {
        if (self.layer != .layer3) return 1;
        const main = self.mainDataBytes();
        if (main == 0) return 1;
        return @min(32, (511 + main - 1) / main + 1);
    }

    /// True when two headers describe the same logical stream. Bitrate and
    /// padding legitimately vary frame to frame in a VBR stream.
    pub fn sameStream(self: FrameHeader, other: FrameHeader) bool {
        return self.version == other.version and self.layer == other.layer and
            self.sample_rate == other.sample_rate and
            self.channels() == other.channels();
    }
};

fn bitrateTable(version: Version, layer: Layer) *const [16]u32 {
    const mpeg1_layer1 = [16]u32{ 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0 };
    const mpeg1_layer2 = [16]u32{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0 };
    const mpeg1_layer3 = [16]u32{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 };
    const mpeg2_layer1 = [16]u32{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0 };
    const mpeg2_layer23 = [16]u32{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 };
    if (version == .mpeg1) return switch (layer) {
        .layer1 => &mpeg1_layer1,
        .layer2 => &mpeg1_layer2,
        .layer3 => &mpeg1_layer3,
    };
    return switch (layer) {
        .layer1 => &mpeg2_layer1,
        .layer2, .layer3 => &mpeg2_layer23,
    };
}

fn sampleRateTable(version: Version) *const [4]u32 {
    const mpeg1 = [4]u32{ 44_100, 48_000, 32_000, 0 };
    const mpeg2 = [4]u32{ 22_050, 24_000, 16_000, 0 };
    const mpeg2_5 = [4]u32{ 11_025, 12_000, 8_000, 0 };
    return switch (version) {
        .mpeg1 => &mpeg1,
        .mpeg2 => &mpeg2,
        .mpeg2_5 => &mpeg2_5,
    };
}

/// The decoder-side latency every MPEG Layer III implementation introduces.
/// LAME states its own encoder delay relative to this constant, so a correct
/// start trim is `encoder_delay + DECODER_DELAY`.
pub const decoder_delay: u32 = 529;

pub const VbrKind = enum { xing, info, vbri };

/// A Xing, Info, or VBRI header found in the first frame of the stream.
pub const VbrHeader = struct {
    kind: VbrKind,
    /// MPEG frames following this header frame, when declared.
    frame_count: ?u32 = null,
    /// Bytes covered by `frame_count`, when declared.
    byte_count: ?u32 = null,
    /// 100-entry seek table, present only on Xing/Info headers that set the
    /// TOC flag. Entry i maps i% of the duration to `toc[i]/256` of the bytes.
    toc: ?[100]u8 = null,
    encoder_delay: u32 = 0,
    encoder_padding: u32 = 0,
    has_lame_extension: bool = false,
};

/// Parses a VBR header out of `frame`, the bytes of the stream's first frame.
/// Returns null when the frame carries ordinary audio, which is the common
/// case: only about one MP3 in four is written with one of these headers.
pub fn parseVbrHeader(header: FrameHeader, frame: []const u8) ?VbrHeader {
    if (parseXing(header, frame)) |xing| return xing;
    return parseVbri(frame);
}

fn parseXing(header: FrameHeader, frame: []const u8) ?VbrHeader {
    const start = 4 + header.sideInfoBytes();
    if (frame.len < start + 8) return null;
    var cursor: usize = start;
    const kind: VbrKind = if (std.mem.eql(u8, frame[cursor..][0..4], "Xing"))
        .xing
    else if (std.mem.eql(u8, frame[cursor..][0..4], "Info"))
        .info
    else
        return null;
    cursor += 4;
    const flags = readBig32(frame[cursor..][0..4]);
    cursor += 4;

    var result: VbrHeader = .{ .kind = kind };
    if (flags & 0x1 != 0) {
        if (frame.len < cursor + 4) return result;
        result.frame_count = readBig32(frame[cursor..][0..4]);
        cursor += 4;
    }
    if (flags & 0x2 != 0) {
        if (frame.len < cursor + 4) return result;
        result.byte_count = readBig32(frame[cursor..][0..4]);
        cursor += 4;
    }
    if (flags & 0x4 != 0) {
        if (frame.len < cursor + 100) return result;
        result.toc = frame[cursor..][0..100].*;
        cursor += 100;
    }
    if (flags & 0x8 != 0) {
        if (frame.len < cursor + 4) return result;
        cursor += 4; // VBR quality indicator, unused
    }

    // The LAME extension follows the Xing fields directly. Only trust it when
    // the encoder signature is one that writes a real delay/padding pair.
    if (frame.len >= cursor + 36) {
        const signature = frame[cursor..][0..4];
        const known = std.mem.eql(u8, signature, "LAME") or
            std.mem.eql(u8, signature, "Lavc") or
            std.mem.eql(u8, signature, "Lavf");
        if (known) {
            const packed_delay = frame[cursor + 21 ..][0..3];
            const delay = (@as(u32, packed_delay[0]) << 4) | (packed_delay[1] >> 4);
            const padding = ((@as(u32, packed_delay[1]) & 0x0f) << 8) | packed_delay[2];
            result.encoder_delay = delay;
            result.encoder_padding = padding;
            result.has_lame_extension = true;
        }
    }
    return result;
}

fn parseVbri(frame: []const u8) ?VbrHeader {
    // Fraunhofer writes VBRI at a fixed offset regardless of side-info size.
    const start = 36;
    if (frame.len < start + 26) return null;
    if (!std.mem.eql(u8, frame[start..][0..4], "VBRI")) return null;
    return .{
        .kind = .vbri,
        .byte_count = readBig32(frame[start + 10 ..][0..4]),
        .frame_count = readBig32(frame[start + 14 ..][0..4]),
    };
}

fn readBig32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}

/// Largest frame any supported configuration can produce, used to bound
/// header scans and the decoder's input window.
pub const max_frame_bytes: usize = 2881;

/// Everything the decoder needs to know before the first sample is produced.
pub const StreamInfo = struct {
    /// Byte offset of the first frame that carries audio. A Xing/Info/VBRI
    /// header frame decodes to silence and is excluded here.
    audio_start: u64,
    /// First byte past the MPEG data. Trailing ID3v1, APE and Lyrics3 tags
    /// are excluded: feeding them to the decoder costs the final frame,
    /// because a frame can only be confirmed against what follows it.
    audio_end: u64,
    /// Bytes of MPEG data, `audio_end - audio_start`.
    audio_bytes: u64,
    header: FrameHeader,
    /// The raw bytes of the first frame's header, reused to synthesize a
    /// terminator the native decoder can confirm the final frame against.
    header_bytes: [4]u8,
    vbr: ?VbrHeader,
    /// PCM frames to discard at the head of the decoded stream.
    start_skip: u64,
    /// Total PCM frames the caller should observe, after delay and padding
    /// trimming. Null only when the length cannot be estimated at all.
    total_frames: ?u64,
    /// True when the length is derived from a declared frame count rather
    /// than estimated from the average bitrate.
    exact_length: bool,
};

/// Reads the stream prologue: ID3v2 prefix, first frame header, and any VBR
/// header, then derives length and trimming.
pub fn readStreamInfo(source: storage.ReadableSource) !StreamInfo {
    const size = source.size();
    const prefix = id3v2.prefixLength(source) catch 0;
    if (prefix >= size) return Error.TruncatedMp3;

    const located = try findFrame(source, prefix, size);

    var frame_buffer: [max_frame_bytes]u8 = undefined;
    const frame_size = @min(located.header.frameBytes(), frame_buffer.len);
    const read = try source.readAt(located.offset, frame_buffer[0..frame_size]);
    const vbr = parseVbrHeader(located.header, frame_buffer[0..read]);

    var audio_start = located.offset;
    if (vbr != null) audio_start += located.header.frameBytes();
    if (audio_start > size) return Error.TruncatedMp3;
    const audio_end = @max(audio_start, try trailingTagStart(source, size));
    const audio_bytes = audio_end - audio_start;

    const samples_per_frame: u64 = located.header.samplesPerFrame();
    var start_skip: u64 = 0;
    var total_frames: ?u64 = null;
    var exact_length = false;

    if (vbr) |header| {
        if (header.has_lame_extension) start_skip = header.encoder_delay + decoder_delay;
        if (header.frame_count) |mpeg_frames| {
            // The declared count covers the frames that follow the header
            // frame, so it measures exactly the region starting at
            // `audio_start`. Both ends of the encoder's own padding come off
            // that total; the 529-sample decoder delay cancels between the
            // head skip and the tail trim.
            const declared = @as(u64, mpeg_frames) * samples_per_frame;
            const trim: u64 = if (header.has_lame_extension)
                @as(u64, header.encoder_delay) + header.encoder_padding
            else
                0;
            total_frames = if (declared > trim) declared - trim else 0;
            exact_length = true;
        }
    }
    if (total_frames == null) {
        // CBR estimate: constant frame size across the audio region. This is
        // the common path — three MP3s in four carry no VBR header at all.
        const frame_bytes: u64 = located.header.frameBytes();
        if (frame_bytes != 0)
            total_frames = (audio_bytes / frame_bytes) * samples_per_frame;
    }

    return .{
        .audio_start = audio_start,
        .audio_end = audio_end,
        .audio_bytes = audio_bytes,
        .header = located.header,
        .header_bytes = frame_buffer[0..4].*,
        .vbr = vbr,
        .start_skip = start_skip,
        .total_frames = total_frames,
        .exact_length = exact_length,
    };
}

/// Finds where the trailing metadata tags begin, so the decoder is never
/// handed bytes that are not MPEG data. Each footer is validated before its
/// declared size is trusted, and a size that would run past the start of the
/// file is ignored rather than applied.
fn trailingTagStart(source: storage.ReadableSource, size: u64) !u64 {
    var end = size;

    if (end >= 128) {
        var marker: [3]u8 = undefined;
        if (try source.readAt(end - 128, &marker) == marker.len and
            std.mem.eql(u8, &marker, "TAG")) end -= 128;
    }

    if (end >= 32) {
        var footer: [32]u8 = undefined;
        if (try source.readAt(end - 32, &footer) == footer.len and
            std.mem.eql(u8, footer[0..8], "APETAGEX"))
        {
            const declared = std.mem.readInt(u32, footer[12..16], .little);
            const flags = std.mem.readInt(u32, footer[20..24], .little);
            const header_bytes: u64 = if (flags & 0x8000_0000 != 0) 32 else 0;
            const total = @as(u64, declared) + header_bytes;
            if (total <= end) end -= total;
        }
    }

    if (end >= 15) {
        var footer: [15]u8 = undefined;
        if (try source.readAt(end - 15, &footer) == footer.len and
            std.mem.eql(u8, footer[6..15], "LYRICS200"))
        {
            const declared = std.fmt.parseInt(u64, footer[0..6], 10) catch 0;
            const total = declared + footer.len;
            if (declared != 0 and total <= end) end -= total;
        }
    }

    return end;
}

pub const LocatedFrame = struct { offset: u64, header: FrameHeader };

/// Scans forward from `from` for a frame header whose successor also syncs,
/// which rejects the false positives a single sync word invites. The scan is
/// bounded so a non-MP3 file fails instead of walking to end of file.
pub fn findFrame(source: storage.ReadableSource, from: u64, limit: u64) !LocatedFrame {
    const scan_limit: u64 = @min(limit, from + 128 * 1024);
    var window: [4096]u8 = undefined;
    var offset = from;
    while (offset < scan_limit) {
        const want: usize = @intCast(@min(window.len, scan_limit - offset));
        const read = try source.readAt(offset, window[0..want]);
        if (read < 4) break;
        // Stop 3 bytes short so a header straddling the window edge is
        // re-examined from the next window rather than half-read.
        const usable = read - 3;
        var index: usize = 0;
        while (index < usable) : (index += 1) {
            const header = FrameHeader.parse(window[index..][0..4].*) orelse continue;
            const candidate = offset + index;
            if (try confirmFrame(source, candidate, header, limit))
                return .{ .offset = candidate, .header = header };
        }
        offset += usable;
    }
    return Error.Mp3SyncNotFound;
}

fn confirmFrame(
    source: storage.ReadableSource,
    offset: u64,
    header: FrameHeader,
    limit: u64,
) !bool {
    const next = offset + header.frameBytes();
    // A final frame at end of file has no successor to confirm against.
    if (next >= limit) return next <= limit;
    var bytes: [4]u8 = undefined;
    if (try source.readAt(next, &bytes) != 4) return false;
    const following = FrameHeader.parse(bytes) orelse return false;
    return header.sameStream(following);
}

/// A lazily grown map from PCM frame position to byte offset, used for
/// seeking a stream whose frame sizes vary. Only frame headers are read; no
/// audio is decoded, so extending the index costs one buffered sequential
/// walk of the headers between where the scan stopped and the target.
pub const FrameIndex = struct {
    /// One entry per this many MPEG frames, bounding memory on long files.
    const stride: u32 = 16;
    const window_bytes: usize = 16 * 1024;

    entries: std.ArrayList(Entry) = .empty,
    scan_offset: u64,
    scan_pcm: u64 = 0,
    scanned_frames: u64 = 0,
    complete: bool = false,

    pub const Entry = struct { byte_offset: u64, pcm_frame: u64 };

    pub fn init(audio_start: u64) FrameIndex {
        return .{ .scan_offset = audio_start };
    }

    pub fn deinit(self: *FrameIndex, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    /// Extends the index until it covers `target_pcm` or the stream ends.
    /// Progress is durable: a later call resumes from where this one stopped.
    pub fn ensureCovers(
        self: *FrameIndex,
        allocator: std.mem.Allocator,
        source: storage.ReadableSource,
        stream: FrameHeader,
        target_pcm: u64,
    ) !void {
        if (self.complete or self.scan_pcm > target_pcm) return;
        const size = source.size();
        var window: [window_bytes]u8 = undefined;
        var window_start: u64 = self.scan_offset;
        var window_len: usize = 0;

        while (self.scan_pcm <= target_pcm) {
            const relative = self.scan_offset - window_start;
            if (relative + 4 > window_len) {
                if (self.scan_offset + 4 > size) {
                    self.complete = true;
                    return;
                }
                window_start = self.scan_offset;
                const want: usize = @intCast(@min(window.len, size - window_start));
                window_len = try source.readAt(window_start, window[0..want]);
                if (window_len < 4) {
                    self.complete = true;
                    return;
                }
                continue;
            }
            const bytes = window[@intCast(relative)..][0..4].*;
            const header = FrameHeader.parse(bytes) orelse {
                // Stray bytes between frames happen in the wild; resync once
                // rather than abandoning the index entirely.
                const located = findFrame(source, self.scan_offset, size) catch {
                    self.complete = true;
                    return;
                };
                self.scan_offset = located.offset;
                window_len = 0;
                window_start = self.scan_offset;
                continue;
            };
            if (!header.sameStream(stream)) {
                self.complete = true;
                return;
            }
            if (self.scanned_frames % stride == 0)
                try self.entries.append(allocator, .{
                    .byte_offset = self.scan_offset,
                    .pcm_frame = self.scan_pcm,
                });
            self.scan_offset += header.frameBytes();
            self.scan_pcm += header.samplesPerFrame();
            self.scanned_frames += 1;
        }
    }

    /// The last indexed entry at or before `pcm_frame`.
    pub fn lookup(self: *const FrameIndex, pcm_frame: u64) ?Entry {
        var found: ?Entry = null;
        for (self.entries.items) |entry| {
            if (entry.pcm_frame > pcm_frame) break;
            found = entry;
        }
        return found;
    }
};

/// Interpolates a byte offset out of a Xing TOC. The result is a hint only:
/// the table quantizes both axes to 1/100 of the duration and 1/256 of the
/// stream, so a seek resolved this way can land a noticeable distance from
/// the requested frame.
pub fn tocByteOffset(
    toc: [100]u8,
    stream_bytes: u64,
    fraction: f64,
) u64 {
    const clamped = std.math.clamp(fraction, 0.0, 1.0);
    const scaled = clamped * 100.0;
    const bucket: usize = @min(99, @as(usize, @intFromFloat(@floor(scaled))));
    const within = scaled - @floor(scaled);
    const low: f64 = @floatFromInt(toc[bucket]);
    const high: f64 = if (bucket + 1 < 100)
        @floatFromInt(toc[bucket + 1])
    else
        256.0;
    const entry = low + (high - low) * within;
    const offset = entry / 256.0 * @as(f64, @floatFromInt(stream_bytes));
    if (offset <= 0) return 0;
    const rounded: u64 = @intFromFloat(offset);
    return @min(rounded, stream_bytes);
}

const testing = std.testing;

test "frame headers report MPEG1 Layer III geometry from the bit fields" {
    // 0xFF 0xFB: MPEG1, Layer III, no CRC. 0x90: 128 kbps, 44.1 kHz, no pad.
    const header = FrameHeader.parse(.{ 0xff, 0xfb, 0x90, 0x00 }).?;
    try testing.expectEqual(Version.mpeg1, header.version);
    try testing.expectEqual(Layer.layer3, header.layer);
    try testing.expectEqual(@as(u32, 128), header.bitrate_kbps);
    try testing.expectEqual(@as(u32, 44_100), header.sample_rate);
    try testing.expectEqual(@as(u32, 1152), header.samplesPerFrame());
    try testing.expectEqual(@as(u32, 417), header.frameBytes());
    try testing.expectEqual(@as(u32, 32), header.sideInfoBytes());
}

test "padded frames occupy exactly one extra slot byte" {
    const unpadded = FrameHeader.parse(.{ 0xff, 0xfb, 0x90, 0x00 }).?;
    const padded = FrameHeader.parse(.{ 0xff, 0xfb, 0x92, 0x00 }).?;
    try testing.expectEqual(unpadded.frameBytes() + 1, padded.frameBytes());
}

test "reserved version layer and free format headers are refused" {
    try testing.expect(FrameHeader.parse(.{ 0xff, 0xeb, 0x90, 0x00 }) == null); // reserved version
    try testing.expect(FrameHeader.parse(.{ 0xff, 0xf9, 0x90, 0x00 }) == null); // reserved layer
    try testing.expect(FrameHeader.parse(.{ 0xff, 0xfb, 0x00, 0x00 }) == null); // free format
    try testing.expect(FrameHeader.parse(.{ 0xff, 0xfb, 0xf0, 0x00 }) == null); // bad bitrate
    try testing.expect(FrameHeader.parse(.{ 0xff, 0xfb, 0x9c, 0x00 }) == null); // bad sample rate
    try testing.expect(FrameHeader.parse(.{ 0x00, 0x00, 0x00, 0x00 }) == null); // no sync
}

test "MPEG2 Layer III frames carry half the samples of MPEG1" {
    const header = FrameHeader.parse(.{ 0xff, 0xf3, 0x90, 0x00 }).?;
    try testing.expectEqual(Version.mpeg2, header.version);
    try testing.expectEqual(@as(u32, 576), header.samplesPerFrame());
    try testing.expectEqual(@as(u32, 22_050), header.sample_rate);
}

test "Xing header yields the declared frame count and LAME delay and padding" {
    const header = FrameHeader.parse(.{ 0xff, 0xfb, 0x90, 0x00 }).?;
    var frame: [max_frame_bytes]u8 = @splat(0);
    const start = 4 + header.sideInfoBytes();
    @memcpy(frame[start..][0..4], "Xing");
    std.mem.writeInt(u32, frame[start + 4 ..][0..4], 0x0f, .big);
    std.mem.writeInt(u32, frame[start + 8 ..][0..4], 1000, .big);
    std.mem.writeInt(u32, frame[start + 12 ..][0..4], 500_000, .big);
    for (0..100) |index| frame[start + 16 + index] = @intCast(index * 2);
    const lame = start + 120;
    @memcpy(frame[lame..][0..9], "LAME3.99r");
    // 576 samples of delay, 1000 samples of padding.
    frame[lame + 21] = 0x24;
    frame[lame + 22] = 0x03;
    frame[lame + 23] = 0xe8;

    const vbr = parseVbrHeader(header, &frame).?;
    try testing.expectEqual(VbrKind.xing, vbr.kind);
    try testing.expectEqual(@as(?u32, 1000), vbr.frame_count);
    try testing.expectEqual(@as(?u32, 500_000), vbr.byte_count);
    try testing.expect(vbr.toc != null);
    try testing.expectEqual(@as(u8, 20), vbr.toc.?[10]);
    try testing.expect(vbr.has_lame_extension);
    try testing.expectEqual(@as(u32, 576), vbr.encoder_delay);
    try testing.expectEqual(@as(u32, 1000), vbr.encoder_padding);
}

test "a frame without a VBR header parses as ordinary audio" {
    const header = FrameHeader.parse(.{ 0xff, 0xfb, 0x90, 0x00 }).?;
    var frame: [max_frame_bytes]u8 = @splat(0x55);
    try testing.expect(parseVbrHeader(header, &frame) == null);
}

test "a truncated Xing header stops at the last complete field" {
    const header = FrameHeader.parse(.{ 0xff, 0xfb, 0x90, 0x00 }).?;
    const start: usize = 36; // 4-byte header plus MPEG1 stereo side info
    try testing.expectEqual(start, 4 + header.sideInfoBytes());
    var frame: [start + 12]u8 = @splat(0);
    @memcpy(frame[start..][0..4], "Xing");
    std.mem.writeInt(u32, frame[start + 4 ..][0..4], 0x07, .big);
    std.mem.writeInt(u32, frame[start + 8 ..][0..4], 42, .big);
    const vbr = parseVbrHeader(header, &frame).?;
    try testing.expectEqual(@as(?u32, 42), vbr.frame_count);
    try testing.expect(vbr.byte_count == null);
    try testing.expect(vbr.toc == null);
    try testing.expect(!vbr.has_lame_extension);
}

test "VBRI headers are read from their fixed Fraunhofer offset" {
    const header = FrameHeader.parse(.{ 0xff, 0xfb, 0x90, 0x00 }).?;
    var frame: [max_frame_bytes]u8 = @splat(0);
    @memcpy(frame[36..][0..4], "VBRI");
    std.mem.writeInt(u32, frame[46..][0..4], 700_000, .big);
    std.mem.writeInt(u32, frame[50..][0..4], 2000, .big);
    const vbr = parseVbrHeader(header, &frame).?;
    try testing.expectEqual(VbrKind.vbri, vbr.kind);
    try testing.expectEqual(@as(?u32, 2000), vbr.frame_count);
    try testing.expectEqual(@as(?u32, 700_000), vbr.byte_count);
}

test "sync scanning refuses a buffer that never contains a confirmable frame" {
    var bytes: [8192]u8 = @splat(0xff);
    var memory: storage.MemorySource = .{ .bytes = &bytes };
    try testing.expectError(
        Error.Mp3SyncNotFound,
        findFrame(memory.readable(), 0, bytes.len),
    );
}
