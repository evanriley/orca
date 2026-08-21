const std = @import("std");
const pcm = @import("../audio/pcm.zig");

/// Codec-neutral decoded PCM source. Implementations contain their private
/// state behind context and must return interleaved canonical float32 frames.
pub const Decoder = struct {
    context: *anyopaque,
    vtable: *const VTable,
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
