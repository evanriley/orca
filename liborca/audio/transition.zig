const std = @import("std");

pub const Spec = union(enum) {
    gapless,
    crossfade: struct { frames: u32 },
};

/// Stateful linear crossfade envelope. It operates on caller-owned buffers so
/// transition processing is bounded and allocation-free.
pub const Crossfade = struct {
    total_frames: u32,
    completed_frames: u32 = 0,

    pub fn init(total_frames: u32) !Crossfade {
        if (total_frames == 0) return error.EmptyCrossfade;
        return .{ .total_frames = total_frames };
    }

    pub fn mix(
        self: *Crossfade,
        outgoing: []f32,
        incoming: []const f32,
        channels: u16,
    ) !u32 {
        if (channels == 0 or outgoing.len != incoming.len or outgoing.len % channels != 0)
            return error.CrossfadeFormatMismatch;
        const available_frames: u32 = @intCast(outgoing.len / channels);
        const frames = @min(available_frames, self.total_frames - self.completed_frames);
        for (0..frames) |local_frame| {
            const frame = self.completed_frames + @as(u32, @intCast(local_frame));
            const incoming_gain: f32 = if (self.total_frames == 1)
                1
            else
                @as(f32, @floatFromInt(frame)) /
                    @as(f32, @floatFromInt(self.total_frames - 1));
            const outgoing_gain = 1 - incoming_gain;
            const start = local_frame * channels;
            for (0..channels) |channel| {
                const index = start + channel;
                outgoing[index] = outgoing[index] * outgoing_gain +
                    incoming[index] * incoming_gain;
            }
        }
        self.completed_frames += frames;
        return frames;
    }

    pub fn finished(self: *const Crossfade) bool {
        return self.completed_frames == self.total_frames;
    }
};

test "crossfade envelope is continuous across bounded chunks" {
    var fade = try Crossfade.init(4);
    var first = [_]f32{ 1, 1 };
    var second = [_]f32{ 1, 1 };
    try std.testing.expectEqual(@as(u32, 2), try fade.mix(&first, &.{ 0, 0 }, 1));
    try std.testing.expectEqual(@as(u32, 2), try fade.mix(&second, &.{ 0, 0 }, 1));
    const expected = [_]f32{ 1, 2.0 / 3.0, 1.0 / 3.0, 0 };
    for (expected, first ++ second) |want, actual|
        try std.testing.expectApproxEqAbs(want, actual, 0.000_001);
    try std.testing.expect(fade.finished());
}
