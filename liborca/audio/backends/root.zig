const builtin = @import("builtin");
const std = @import("std");
const output = @import("../output.zig");

pub const native = switch (builtin.os.tag) {
    .linux => @import("pipewire.zig"),
    else => struct {},
};

pub const playback = switch (builtin.os.tag) {
    .linux => @import("pipewire_playback.zig"),
    else => struct {},
};

/// Process-level owner of the host audio backend. `platform.zig`'s rule applies
/// here too: the foreign library's lifetime lives in the adapter for that
/// platform, and everything above this sees only `output.Factory`.
pub const Host = switch (builtin.os.tag) {
    .linux => LinuxHost,
    else => NullHost,
};

const LinuxHost = struct {
    backend: native.Backend = .{},
    adapter: native.OutputFactory = undefined,

    pub fn init(self: *LinuxHost, allocator: std.mem.Allocator) void {
        self.adapter = .{ .allocator = allocator, .backend = &self.backend };
    }

    pub fn deinit(self: *LinuxHost) void {
        self.backend.deinit();
    }

    pub fn factory(self: *LinuxHost) ?output.Factory {
        return self.adapter.factory();
    }
};

/// Hosts with no Orca backend yet. Zones simply never open an output, and
/// device enumeration honestly reports none rather than failing.
const NullHost = struct {
    pub fn init(_: *NullHost, _: std.mem.Allocator) void {}
    pub fn deinit(_: *NullHost) void {}
    pub fn factory(_: *NullHost) ?output.Factory {
        return null;
    }
};

test {
    if (builtin.os.tag == .linux) _ = @import("pipewire.zig");
    if (builtin.os.tag == .linux) _ = @import("pipewire_playback.zig");
}
