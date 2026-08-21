//! Public Zig API for the reusable Orca engine.

const std = @import("std");

pub const core = @import("core/root.zig");
pub const database = @import("database/root.zig");
pub const platform = @import("platform.zig");

pub const OrcaRuntime = core.OrcaRuntime;

pub const version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
    .pre = "dev",
};

test {
    std.testing.refAllDecls(@This());
}
