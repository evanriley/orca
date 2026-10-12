const std = @import("std");
const audio_embedding = @import("../analysis/audio_embedding.zig");

pub const Model = audio_embedding.Model;

pub const State = enum(u8) {
    built_without,
    missing,
    wrong_file,
    unusable,
    ready,
};

pub const OwnedPath = struct {
    bytes: [std.Io.Dir.max_path_bytes]u8,
    len: u16,

    pub fn init(path: []const u8) error{NameTooLong}!OwnedPath {
        if (path.len > std.Io.Dir.max_path_bytes) return error.NameTooLong;
        var owned: OwnedPath = .{ .bytes = undefined, .len = @intCast(path.len) };
        @memcpy(owned.bytes[0..path.len], path);
        return owned;
    }

    pub fn view(self: *const OwnedPath) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Status = packed struct(u32) {
    state: State,
    generation: u24,
};

const unset: State = if (audio_embedding.enabled) .missing else .built_without;

pub const Setting = struct {
    /// Control lane only.
    path: ?OwnedPath = null,
    status: std.atomic.Value(Status) = .init(.{ .state = unset, .generation = 0 }),

    pub fn set(self: *Setting, allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8) !void {
        const owned: ?OwnedPath = if (path) |value| try .init(value) else null;
        const checked: State = if (owned) |*value| try verified(allocator, io, value.view()) else unset;
        self.path = owned;
        self.status.store(.{
            .state = checked,
            .generation = self.status.load(.acquire).generation +% 1,
        }, .release);
    }

    pub fn state(self: *const Setting) State {
        return self.status.load(.acquire).state;
    }

    pub fn claim(self: *Setting) ?Claim {
        const status = self.status.load(.acquire);
        if (status.state != .ready) return null;
        return .{ .path = self.path.?, .generation = status.generation, .status = &self.status };
    }
};

pub const Claim = struct {
    path: OwnedPath,
    generation: u24,
    status: *std.atomic.Value(Status),

    pub fn open(self: *const Claim, allocator: std.mem.Allocator, io: std.Io) ?Model {
        return Model.open(allocator, io, self.path.view()) catch |err| {
            if (stateOf(err)) |failed| _ = self.status.cmpxchgStrong(
                .{ .state = .ready, .generation = self.generation },
                .{ .state = failed, .generation = self.generation },
                .acq_rel,
                .acquire,
            );
            return null;
        };
    }
};

fn verified(allocator: std.mem.Allocator, io: std.Io, path: []const u8) error{OutOfMemory}!State {
    Model.verify(allocator, io, path) catch |err| return stateOf(err) orelse error.OutOfMemory;
    return .ready;
}

fn stateOf(err: anyerror) ?State {
    return switch (err) {
        error.OutOfMemory => null,
        error.EmbeddingsNotBuilt => .built_without,
        error.EmbeddingModelMissing => .missing,
        error.EmbeddingModelMismatch => .wrong_file,
        else => .unusable,
    };
}
