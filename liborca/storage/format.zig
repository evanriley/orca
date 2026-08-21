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
};

pub fn sniff(readable: source.ReadableSource) !?AudioFormat {
    var header: [64]u8 = undefined;
    const count = try readable.readAt(0, &header);
    return sniffBytes(header[0..count]);
}

pub fn sniffBytes(bytes: []const u8) ?AudioFormat {
    if (starts(bytes, "fLaC")) return .flac;
    if (starts(bytes, "wvpk")) return .wavpack;
    if (starts(bytes, "qoaf")) return .qoa;
    if (starts(bytes, "ID3")) return .mp3;
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
    try @import("std").testing.expect(sniffBytes("not audio") == null);
}
