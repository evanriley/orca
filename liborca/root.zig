//! Public Zig API for the reusable Orca engine.

const std = @import("std");

pub const audio = @import("audio/root.zig");
pub const analysis = @import("analysis/root.zig");
pub const c_api = @import("c_api.zig");
pub const codec = @import("codec/root.zig");
pub const core = @import("core/root.zig");
pub const database = @import("database/root.zig");
pub const library = @import("library/root.zig");
pub const metadata = @import("metadata/root.zig");
pub const network = @import("network/root.zig");
pub const platform = @import("platform.zig");
pub const storage = @import("storage/root.zig");

pub const OrcaRuntime = core.OrcaRuntime;

pub const version = std.SemanticVersion{
    .major = 0,
    .minor = 9,
    .patch = 0,
};

comptime {
    // Keep exported C symbols reachable when this root builds as liborca.so.
    _ = c_api.orca_runtime_create;
}

test {
    std.testing.refAllDecls(@This());
}
