const std = @import("std");
const pcm = @import("../audio/pcm.zig");

/// Codec-neutral decoded PCM source. Implementations contain their private
/// state behind context and must return interleaved canonical float32 frames.
pub const Decoder = struct {
    context: *anyopaque,
    vtable: *const VTable,
    /// Canonical identifier for the *encoding* this decoder found, from
    /// `codec_id`. Static storage, so it outlives the decoder that reported it
    /// and a probe may return it after closing.
    codec: []const u8,
    /// PCM representation declared by the source before canonical conversion.
    source_format: ?pcm.Format = null,
    /// Interleaved working representation returned by readFrames.
    format: pcm.Format,
    frame_count: ?u64,

    pub const VTable = struct {
        read_frames: *const fn (*anyopaque, []f32) anyerror!usize,
        seek: *const fn (*anyopaque, u64) anyerror!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn readFrames(self: Decoder, output: []f32) !usize {
        if (output.len % self.format.channels != 0) return error.UnalignedPcmBuffer;
        return self.vtable.read_frames(self.context, output);
    }

    pub fn seek(self: Decoder, frame: u64) !void {
        try self.vtable.seek(self.context, frame);
    }

    pub fn deinit(self: *Decoder) void {
        self.vtable.deinit(self.context);
        self.* = undefined;
    }
};

pub const OpenFn = *const fn (std.mem.Allocator, @import("../storage/source.zig").ReadableSource) anyerror!Decoder;

/// Canonical encoding identifiers, stored verbatim in `files.codec`.
///
/// **`codec` is not a synonym for `audio_format`.** `audio_format` names the
/// *container* a file was sniffed as, which is what decides who opens it;
/// `codec` names the *encoding* found inside, which is what decides what the
/// bytes cost and what quality they carry. The two coincide for FLAC and QOA
/// and diverge everywhere a container is a wrapper: a RIFF/WAVE file holds
/// integer PCM or IEEE float, an MPEG stream is Layer I, II or III, and the
/// MP4 and Ogg containers this project will grow into hold AAC or ALAC and
/// Vorbis or Opus respectively. A library that recorded only the container
/// could not tell an ALAC rip from an AAC one.
///
/// Values are lowercase, stable and matched on by equality, never displayed —
/// a human-readable label belongs to the frontend and is free to change with
/// the interface language. Nothing outside this file may invent one.
pub const codec_id = struct {
    /// Uncompressed integer PCM. `files.bit_depth` carries the sample width.
    pub const pcm = "pcm";
    /// Uncompressed IEEE 754 floating-point PCM.
    pub const pcm_float = "pcm_float";
    pub const flac = "flac";
    pub const qoa = "qoa";
    pub const mp1 = "mp1";
    pub const mp2 = "mp2";
    pub const mp3 = "mp3";

    /// Whether an identifier names an encoding that reproduces its input
    /// exactly. This is the lossy/lossless split callers ask `files.codec`
    /// for; it is a property of the identifier, so it stays here rather than
    /// becoming a second column that could disagree with the first.
    pub fn isLossless(identifier: []const u8) bool {
        inline for (.{ codec_id.pcm, codec_id.pcm_float, codec_id.flac }) |lossless| {
            if (std.mem.eql(u8, identifier, lossless)) return true;
        }
        return false;
    }
};

test "every codec identifier is classified as lossy or lossless exactly once" {
    try std.testing.expect(codec_id.isLossless(codec_id.pcm));
    try std.testing.expect(codec_id.isLossless(codec_id.pcm_float));
    try std.testing.expect(codec_id.isLossless(codec_id.flac));
    try std.testing.expect(!codec_id.isLossless(codec_id.qoa));
    try std.testing.expect(!codec_id.isLossless(codec_id.mp1));
    try std.testing.expect(!codec_id.isLossless(codec_id.mp2));
    try std.testing.expect(!codec_id.isLossless(codec_id.mp3));
    // An unwritten row is neither, and must not read as lossless by default.
    try std.testing.expect(!codec_id.isLossless(""));
}
