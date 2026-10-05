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
        /// Present only for a lossless integer source. The same frames as
        /// `read_frames`, from the same cursor, left-justified in 32 bits.
        read_frames_i32: ?*const fn (*anyopaque, []i32) anyerror!usize = null,
    };

    pub fn readFrames(self: Decoder, output: []f32) !usize {
        if (output.len % self.format.channels != 0) return error.UnalignedPcmBuffer;
        return self.vtable.read_frames(self.context, output);
    }

    /// Whether `readFramesI32` delivers the source's exact integer samples.
    pub fn hasIntegerSamples(self: Decoder) bool {
        return self.vtable.read_frames_i32 != null;
    }

    /// Interleaved samples left-justified in 32 bits: a 16-bit sample `s`
    /// reads as `s << 16`. `integerSampleToFloat` of each is exactly what
    /// `readFrames` returns for it.
    pub fn readFramesI32(self: Decoder, output: []i32) !usize {
        const read = self.vtable.read_frames_i32 orelse return error.NoIntegerSamples;
        if (output.len % self.format.channels != 0) return error.UnalignedPcmBuffer;
        return read(self.context, output);
    }

    pub fn seek(self: Decoder, frame: u64) !void {
        try self.vtable.seek(self.context, frame);
    }

    pub fn deinit(self: *Decoder) void {
        self.vtable.deinit(self.context);
        self.* = undefined;
    }
};

pub fn integerSampleToFloat(sample: i32) f32 {
    return @floatCast(@as(f64, @floatFromInt(sample)) / 2147483648.0);
}

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
    pub const alac = "alac";
    pub const aac = "aac";
    pub const opus = "opus";
    pub const vorbis = "vorbis";

    /// Whether an identifier names an encoding that reproduces its input
    /// exactly. This is the lossy/lossless split callers ask `files.codec`
    /// for; it is a property of the identifier, so it stays here rather than
    /// becoming a second column that could disagree with the first.
    pub fn isLossless(identifier: []const u8) bool {
        inline for (lossless) |lossless_identifier| {
            if (std.mem.eql(u8, identifier, lossless_identifier)) return true;
        }
        return false;
    }

    /// The identifiers `isLossless` accepts, for SQL that must agree with it.
    pub const lossless = [_][]const u8{ codec_id.pcm, codec_id.pcm_float, codec_id.flac, codec_id.alac };
};

test "every codec identifier is classified as lossy or lossless exactly once" {
    try std.testing.expect(codec_id.isLossless(codec_id.pcm));
    try std.testing.expect(codec_id.isLossless(codec_id.pcm_float));
    try std.testing.expect(codec_id.isLossless(codec_id.flac));
    try std.testing.expect(!codec_id.isLossless(codec_id.qoa));
    try std.testing.expect(!codec_id.isLossless(codec_id.mp1));
    try std.testing.expect(!codec_id.isLossless(codec_id.mp2));
    try std.testing.expect(!codec_id.isLossless(codec_id.mp3));
    try std.testing.expect(codec_id.isLossless(codec_id.alac));
    try std.testing.expect(!codec_id.isLossless(codec_id.aac));
    try std.testing.expect(!codec_id.isLossless(codec_id.opus));
    try std.testing.expect(!codec_id.isLossless(codec_id.vorbis));
    // An unwritten row is neither, and must not read as lossless by default.
    try std.testing.expect(!codec_id.isLossless(""));
}
