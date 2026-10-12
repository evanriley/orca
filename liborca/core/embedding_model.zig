const std = @import("std");
const audio_embedding = @import("../analysis/audio_embedding.zig");

pub const Model = audio_embedding.Model;
pub const ModelId = audio_embedding.ModelId;

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

const Status = packed struct(u64) {
    state: State,
    model: u8,
    generation: u48,

    const no_model = 0;

    comptime {
        for (std.enums.values(ModelId)) |id| std.debug.assert(@backingInt(id) != no_model);
    }

    fn of(checked: Checked, generation: u48) Status {
        return switch (checked) {
            .ready => |id| .{ .state = .ready, .model = @backingInt(id), .generation = generation },
            .refused => |refused| .{ .state = refused, .model = no_model, .generation = generation },
        };
    }

    fn readyModel(self: Status) ?ModelId {
        return if (self.state == .ready) @fromBackingInt(@intCast(self.model)) else null;
    }
};

const Checked = union(enum) {
    ready: ModelId,
    refused: State,
};

const unset: Checked = .{ .refused = if (audio_embedding.enabled) .missing else .built_without };

pub const Setting = struct {
    /// Control lane only.
    path: ?OwnedPath = null,
    status: std.atomic.Value(Status) = .init(.of(unset, 0)),

    pub fn set(self: *Setting, allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8) !void {
        const owned: ?OwnedPath = if (path) |value| try .init(value) else null;
        const checked: Checked = if (owned) |*value| try verified(allocator, io, value.view()) else unset;
        self.path = owned;
        self.status.store(.of(checked, self.status.load(.acquire).generation +% 1), .release);
    }

    pub fn state(self: *const Setting) State {
        return self.status.load(.acquire).state;
    }

    pub fn model(self: *const Setting) ?ModelId {
        return self.status.load(.acquire).readyModel();
    }

    pub fn claim(self: *Setting) ?Claim {
        const status = self.status.load(.acquire);
        const id = status.readyModel() orelse return null;
        return .{ .path = self.path.?, .model = id, .generation = status.generation, .status = &self.status };
    }
};

pub const Claim = struct {
    path: OwnedPath,
    model: ModelId,
    generation: u48,
    status: *std.atomic.Value(Status),

    pub fn open(self: *const Claim, allocator: std.mem.Allocator, io: std.Io) ?Model {
        const opened = Model.open(allocator, io, self.path.view()) catch |err| {
            if (stateOf(err)) |failed| self.replaceStatus(.{ .refused = failed });
            return null;
        };
        if (opened.id != self.model) self.replaceStatus(.{ .ready = opened.id });
        return opened;
    }

    fn replaceStatus(self: *const Claim, checked: Checked) void {
        _ = self.status.cmpxchgStrong(
            .of(.{ .ready = self.model }, self.generation),
            .of(checked, self.generation),
            .acq_rel,
            .acquire,
        );
    }
};

fn verified(allocator: std.mem.Allocator, io: std.Io, path: []const u8) error{OutOfMemory}!Checked {
    const id = Model.verify(allocator, io, path) catch |err|
        return .{ .refused = stateOf(err) orelse return error.OutOfMemory };
    return .{ .ready = id };
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
