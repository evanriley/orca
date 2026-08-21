const std = @import("std");
const buffer = @import("buffer.zig");
const render = @import("render.zig");
const source_session = @import("source_session.zig");

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
    sources: ?source_session.SourceQueue = null,

    pub fn deinit(self: *Player) void {
        if (self.sources) |*sources| sources.deinit();
        self.* = undefined;
    }

    pub fn loadSource(self: *Player, source: source_session.SourceSession) !void {
        if (self.sources != null) return error.PlayerSourceAlreadyLoaded;
        self.sources = source_session.SourceQueue.init(source);
    }

    pub fn primeNextSource(self: *Player, source: source_session.SourceSession) !void {
        if (self.sources) |*sources| return sources.primeNext(source);
        return error.PlayerHasNoSource;
    }

    pub fn prime(
        self: *Player,
        comptime queue_capacity: usize,
        pipe: *render.RenderPipe(queue_capacity),
        pool: *buffer.BlockPool,
    ) !usize {
        if (self.sources) |*sources| {
            return sources.prime(
                queue_capacity,
                pipe,
                pool,
                self.generation.load(.acquire),
            );
        }
        return error.PlayerHasNoSource;
    }

    pub fn finishedDecoding(self: *const Player) bool {
        return if (self.sources) |*sources| sources.finishedDecoding() else true;
    }

    pub fn play(self: *Player) void {
        self.state.store(.playing, .release);
    }

    pub fn pause(self: *Player) void {
        self.state.store(.paused, .release);
    }

    pub fn stop(self: *Player) void {
        self.state.store(.stopped, .release);
        self.position_frames.store(0, .release);
        _ = self.generation.fetchAdd(1, .acq_rel);
    }

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
