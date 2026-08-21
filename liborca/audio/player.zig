const std = @import("std");

pub const TransportState = enum(u8) { stopped, playing, paused };

pub const Snapshot = struct {
    state: TransportState,
    generation: u64,
    position_frames: u64,
};

pub const Player = struct {
    state: std.atomic.Value(TransportState) = .init(.stopped),
    generation: std.atomic.Value(u64) = .init(1),
    position_frames: std.atomic.Value(u64) = .init(0),

    pub fn seek(self: *Player, frame: u64) u64 {
        self.position_frames.store(frame, .release);
        return self.generation.fetchAdd(1, .acq_rel) +% 1;
    }

    pub fn snapshot(self: *const Player) Snapshot {
        return .{
            .state = self.state.load(.acquire),
            .generation = self.generation.load(.acquire),
            .position_frames = self.position_frames.load(.acquire),
        };
    }
};

test "seek advances generation instead of editing queues" {
    var player: Player = .{};
    const generation = player.seek(48_000);
    const current = player.snapshot();
    try std.testing.expectEqual(generation, current.generation);
    try std.testing.expectEqual(@as(u64, 48_000), current.position_frames);
}
