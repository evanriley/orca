const source = @import("source.zig");

pub const AudioFormat = enum(u8) {
    wav,
    aiff,
    flac,
    mp3,
    mp4,
    opus,
    vorbis,
    wavpack,
    qoa,
    /// Raw AAC in ADTS framing, as `.aac` files hold it. Appended, because
    /// `files.audio_format` stores these values.
    aac,
};

/// Where a container's encoded stream begins, and what it turned out to be.
///
/// `payload_offset` is non-zero only for a container whose real bytes sit
/// behind a prefix that belongs to no encoding — today, an ID3v2 tag stapled in
/// front of a stream that is not MPEG audio. The prefix is a *container*
/// concern, so it is resolved here and hidden from the decoder rather than
/// re-discovered inside every codec.
pub const Detection = struct {
    format: AudioFormat,
    payload_offset: u64 = 0,
};

/// Resolves the container by reading bytes, never by filename.
///
/// Two reads at most: the magic at byte zero, and — when that is an ID3v2 tag —
/// the magic at the first byte past the tag. The second read cannot be folded
/// into a longer first one, because a tag carrying artwork routinely runs to
/// hundreds of kilobytes.
pub fn detect(readable: source.ReadableSource) !?Detection {
    var header: [64]u8 = undefined;
    const count = try readable.readAt(0, &header);
    const prefix = header[0..count];
    if (identifyContainer(prefix)) |format| return .{ .format = format };

    const payload_offset = id3v2PayloadOffset(prefix) orelse return null;
    var payload: [64]u8 = undefined;
    // A read past the end reports zero bytes rather than failing, so a genuine
    // I/O error here is a real failure and is not swallowed into a guess.
    const payload_count = try readable.readAt(payload_offset, &payload);
    if (identifyContainer(payload[0..payload_count])) |format| {
        // An ID3v2 tag is native to MPEG audio and ADTS: their readers skip it
        // and their tags live in it, so the stream is reported from byte zero.
        if (format == .aac) return .{ .format = .aac };
        if (format != .mp3) return .{ .format = format, .payload_offset = payload_offset };
    }
    return .{ .format = .mp3 };
}

pub fn sniff(readable: source.ReadableSource) !?AudioFormat {
    const detected = try detect(readable) orelse return null;
    return detected.format;
}

/// The prefix-only answer, for callers that already hold bytes.
///
/// It resolves an ID3v2 prefix only when the buffer reaches past the tag. When
/// it does not — the ordinary case, since `detect` reads 64 bytes and real tags
/// are far longer — the answer stays MPEG audio, which is what an ID3v2 tag
/// fronts in all but a handful of files.
pub fn sniffBytes(bytes: []const u8) ?AudioFormat {
    if (identifyContainer(bytes)) |format| return format;
    const payload_offset = id3v2PayloadOffset(bytes) orelse return null;
    if (payload_offset <= bytes.len) {
        if (identifyContainer(bytes[@intCast(payload_offset)..])) |format| {
            if (format != .mp3) return format;
        }
    }
    return .mp3;
}

/// Total length of a leading ID3v2 tag, or null if there is not one.
///
/// The declared size is four syncsafe bytes — seven significant bits each — and
/// excludes both the ten-byte header it lives in and the optional ten-byte
/// footer. Counting either wrongly still "works" for MPEG audio, which resyncs
/// on the next frame header, and silently breaks every format whose magic must
/// land on an exact byte.
/// Bytes an ID3v2 tag at the start of `bytes` occupies, footer included, or
/// null when `bytes` does not start with one.
pub fn id3v2PayloadOffset(bytes: []const u8) ?u64 {
    const header_len = 10;
    if (bytes.len < header_len or !starts(bytes, "ID3")) return null;
    if (bytes[3] == 0xff or bytes[4] == 0xff) return null;
    var declared: u64 = 0;
    for (bytes[6..10]) |byte| {
        if (byte & 0x80 != 0) return null;
        declared = (declared << 7) | byte;
    }
    const footer_len: u64 = if (bytes[5] & 0x10 != 0) 10 else 0;
    return header_len + declared + footer_len;
}

/// Magic-byte recognition at the exact start of `bytes`, with no tag handling.
fn identifyContainer(bytes: []const u8) ?AudioFormat {
    if (starts(bytes, "fLaC")) return .flac;
    if (starts(bytes, "wvpk")) return .wavpack;
    if (starts(bytes, "qoaf")) return .qoa;
    // ADTS and MPEG audio share the 12-bit sync word; ADTS always has the
    // layer bits MPEG audio reserves as invalid.
    if (bytes.len >= 2 and bytes[0] == 0xff and (bytes[1] & 0xf6) == 0xf0) return .aac;
    if (bytes.len >= 2 and bytes[0] == 0xff and (bytes[1] & 0xe0) == 0xe0) return .mp3;
    if (bytes.len >= 12 and starts(bytes, "RIFF") and equalAt(bytes, 8, "WAVE")) return .wav;
    if (bytes.len >= 12 and starts(bytes, "FORM") and
        (equalAt(bytes, 8, "AIFF") or equalAt(bytes, 8, "AIFC"))) return .aiff;
    if (bytes.len >= 12 and equalAt(bytes, 4, "ftyp")) return .mp4;
    if (starts(bytes, "OggS")) {
        if (contains(bytes, "OpusHead")) return .opus;
        if (contains(bytes, "vorbis")) return .vorbis;
    }
    return null;
}

fn starts(bytes: []const u8, value: []const u8) bool {
    return equalAt(bytes, 0, value);
}

fn equalAt(bytes: []const u8, offset: usize, value: []const u8) bool {
    return bytes.len >= offset + value.len and
        @import("std").mem.eql(u8, bytes[offset .. offset + value.len], value);
}

fn contains(bytes: []const u8, value: []const u8) bool {
    return @import("std").mem.indexOf(u8, bytes, value) != null;
}

test "sniffs prioritized audio containers from magic bytes" {
    try @import("std").testing.expectEqual(AudioFormat.flac, sniffBytes("fLaCpayload").?);
    try @import("std").testing.expectEqual(AudioFormat.wav, sniffBytes("RIFFxxxxWAVEfmt ").?);
    try @import("std").testing.expectEqual(AudioFormat.opus, sniffBytes("OggSxxxxOpusHead").?);
    try @import("std").testing.expectEqual(AudioFormat.qoa, sniffBytes("qoaf\x00\x00\x00\x10").?);
    try @import("std").testing.expectEqual(AudioFormat.aac, sniffBytes("\xff\xf1\x4c\x80").?);
    try @import("std").testing.expectEqual(AudioFormat.mp3, sniffBytes("\xff\xfb\x90\x64").?);
    try @import("std").testing.expect(sniffBytes("not audio") == null);
}

test "an ID3v2 tag in front of a FLAC stream sniffs as FLAC rather than MPEG audio" {
    const std = @import("std");
    var bytes: [214]u8 = @splat(0);
    @memcpy(bytes[0..10], "ID3\x04\x00\x00\x00\x00\x01\x48");
    @memcpy(bytes[210..214], "fLaC");
    try std.testing.expectEqual(AudioFormat.flac, sniffBytes(&bytes).?);
}

test "an ID3v2 tag with a footer sniffs the payload that follows the footer" {
    const std = @import("std");
    var bytes: [224]u8 = @splat(0);
    @memcpy(bytes[0..10], "ID3\x04\x00\x10\x00\x00\x01\x48");
    @memcpy(bytes[210..220], "3DI\x04\x00\x10\x00\x00\x01\x48");
    @memcpy(bytes[220..224], "fLaC");
    try std.testing.expectEqual(AudioFormat.flac, sniffBytes(&bytes).?);
}

test "an ID3-tagged MPEG stream still sniffs as MPEG audio" {
    const std = @import("std");
    var bytes: [214]u8 = @splat(0);
    @memcpy(bytes[0..10], "ID3\x04\x00\x00\x00\x00\x01\x48");
    bytes[210] = 0xff;
    bytes[211] = 0xfb;
    try std.testing.expectEqual(AudioFormat.mp3, sniffBytes(&bytes).?);
}

test "a prefix too short to reach past an ID3v2 tag sniffs as MPEG audio" {
    const std = @import("std");
    // 64 bytes is what `sniff` reads, and a real tag carrying artwork is
    // orders of magnitude longer. The pure prefix answer must stay the one
    // that is right for the overwhelming majority of ID3-bearing files.
    var bytes: [64]u8 = @splat(0);
    @memcpy(bytes[0..10], "ID3\x04\x00\x00\x00\x02\x01\x48");
    try std.testing.expectEqual(AudioFormat.mp3, sniffBytes(&bytes).?);
}
