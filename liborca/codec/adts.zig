//! Raw AAC in ADTS framing, as `.aac` files hold it.
//!
//! Each frame carries a 7-byte header (9 with a CRC) stating its length and
//! the stream's layout, so the frame headers are the packet table. The track
//! they describe is decoded by `mp4.zig`'s packet loop and libxaac, exactly as
//! AAC in MP4 is. ADTS records no encoder priming, so the decoded timeline
//! starts with it, as it does in every ADTS decoder.

const std = @import("std");
const decoder_api = @import("decoder.zig");
const mp4 = @import("mp4.zig");
const storage = @import("../storage/root.zig");

const frame_frames: u32 = 1024;
const window_bytes: usize = 64 * 1024;

pub fn openDecoder(allocator: std.mem.Allocator, source: storage.ReadableSource) !decoder_api.Decoder {
    return mp4.openTrack(allocator, source, try readTrack(allocator, source));
}

pub fn probe(allocator: std.mem.Allocator, source: storage.ReadableSource) !@import("registry.zig").Properties {
    var track = try readTrack(allocator, source);
    defer track.deinit();
    return mp4.probeTrack(&track);
}

const Layout = struct { profile: u8, rate_index: u8, channels: u8 };

/// The packet table from the frame headers, after any leading ID3v2 tag.
/// Scanning stops at the first bytes that are not a frame, which is where a
/// trailing ID3v1 or APE tag sits.
pub fn readTrack(allocator: std.mem.Allocator, source: storage.ReadableSource) !mp4.Track {
    var prefix: [10]u8 = undefined;
    const prefix_read = try source.readAt(0, &prefix);
    var offset: u64 = storage.format.id3v2PayloadOffset(prefix[0..prefix_read]) orelse 0;

    var samples: std.ArrayList(mp4.Sample) = .empty;
    errdefer samples.deinit(allocator);
    var layout: ?Layout = null;
    var window: [window_bytes]u8 = undefined;
    var window_start: u64 = 0;
    var window_len: usize = 0;
    const size = source.size();
    while (offset + 7 <= size) {
        if (offset < window_start or offset + 9 > window_start + window_len) {
            window_start = offset;
            window_len = try source.readAt(offset, &window);
            if (window_len < 7) break;
        }
        const header = window[@intCast(offset - window_start)..window_len];
        if (header.len < 7 or header[0] != 0xff or header[1] & 0xf6 != 0xf0) break;
        const protected = header[1] & 0x01 == 0;
        const frame: Layout = .{
            .profile = header[2] >> 6,
            .rate_index = (header[2] >> 2) & 0x0f,
            .channels = ((header[2] & 0x01) << 2) | (header[3] >> 6),
        };
        const frame_length: u32 = (@as(u32, header[3] & 0x03) << 11) | (@as(u32, header[4]) << 3) | (header[5] >> 5);
        const raw_blocks = header[6] & 0x03;
        const header_length: u32 = if (protected) 9 else 7;
        if (frame_length <= header_length or offset + frame_length > size) break;
        if (raw_blocks != 0) return error.UnsupportedAdtsFrame;
        if (frame.rate_index >= mp4.sampling_rates.len or frame.channels == 0) return error.InvalidAdts;
        if (layout) |first| {
            if (!std.meta.eql(first, frame)) return error.ChangingAdtsLayout;
        } else layout = frame;
        if (samples.items.len == mp4.max_samples) return error.Mp4TooManySamples;
        try samples.append(allocator, .{ .offset = offset + header_length, .size = frame_length - header_length });
        offset += frame_length;
    }
    const stream = layout orelse return error.InvalidAdts;

    const config = try allocator.alloc(u8, 2);
    errdefer allocator.free(config);
    // AudioSpecificConfig: object type (profile + 1), rate index, channels,
    // then GASpecificConfig's three zero flags.
    const object_type: u16 = stream.profile + 1;
    const packed_config: u16 = (object_type << 11) | (@as(u16, stream.rate_index) << 7) | (@as(u16, stream.channels) << 3);
    std.mem.writeInt(u16, config[0..2], packed_config, .big);

    const time_runs = try allocator.alloc(mp4.TimeRun, 1);
    errdefer allocator.free(time_runs);
    const sample_count = samples.items.len;
    time_runs[0] = .{ .count = @intCast(sample_count), .delta = frame_frames };
    const rate = mp4.sampling_rates[stream.rate_index];
    return .{
        .allocator = allocator,
        .movie = config,
        .codec = .{ .aac = config },
        .channels = if (stream.channels == 7) 8 else stream.channels,
        .sample_rate = rate,
        .timescale = rate,
        .samples = try samples.toOwnedSlice(allocator),
        .time_runs = time_runs,
        .start_time = 0,
        .play_time = null,
    };
}

test "an ID3-tagged ADTS stream decodes every frame it holds" {
    var file = try storage.LocalFileSource.open(std.testing.io, "fixtures/audio/tagged-reference.aac");
    defer file.close();
    var decoder = try openDecoder(std.testing.allocator, file.readable());
    defer decoder.deinit();
    try std.testing.expectEqualStrings("aac", decoder.codec);
    try std.testing.expectEqual(@as(u16, 2), decoder.format.channels);
    try std.testing.expectEqual(@as(u32, 48_000), decoder.format.sample_rate);
    // Eleven 1,024-frame packets, priming included: ADTS cannot say to trim it.
    try std.testing.expectEqual(@as(?u64, 11 * 1024), decoder.frame_count);
    const samples = try std.testing.allocator.alloc(f32, 12 * 1024 * 2);
    defer std.testing.allocator.free(samples);
    var frames: usize = 0;
    while (true) {
        const read = try decoder.readFrames(samples[frames * 2 ..]);
        if (read == 0) break;
        frames += read;
    }
    try std.testing.expectEqual(@as(usize, 11 * 1024), frames);
}

test "ADTS decodes the same audio as the MP4 its frames were copied from" {
    const registry = @import("registry.zig");
    var adts_file = try storage.LocalFileSource.open(std.testing.io, "fixtures/audio/tagged-reference.aac");
    defer adts_file.close();
    var adts = try openDecoder(std.testing.allocator, adts_file.readable());
    defer adts.deinit();
    var mp4_file = try storage.LocalFileSource.open(std.testing.io, "fixtures/audio/chirp-reference-aac.m4a");
    defer mp4_file.close();
    var from_mp4 = try registry.CodecRegistry.builtins().openDetected(std.testing.allocator, mp4_file.readable());
    defer from_mp4.deinit();
    // The MP4's edit list skips 1,024 frames of priming the ADTS stream keeps.
    try adts.seek(1024);
    var adts_samples: [4096 * 2]f32 = undefined;
    var mp4_samples: [4096 * 2]f32 = undefined;
    var filled: usize = 0;
    while (filled < 4096) filled += try adts.readFrames(adts_samples[filled * 2 ..]);
    filled = 0;
    while (filled < 4096) filled += try from_mp4.readFrames(mp4_samples[filled * 2 ..]);
    try std.testing.expectEqualSlices(f32, &mp4_samples, &adts_samples);
}

test "the ADTS probe agrees with the decoder" {
    var file = try storage.LocalFileSource.open(std.testing.io, "fixtures/audio/tagged-reference.aac");
    defer file.close();
    const declared = try probe(std.testing.allocator, file.readable());
    try std.testing.expectEqualStrings("aac", declared.codec.?);
    try std.testing.expectEqual(@as(?u32, 48_000), declared.sample_rate);
    try std.testing.expectEqual(@as(?u16, 2), declared.channels);
    try std.testing.expectEqual(@as(?u64, 11 * 1024 * 1000 / 48_000), declared.duration_ms);
}
