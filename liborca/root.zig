//! Public Zig API for the reusable Orca engine.

const std = @import("std");

pub const core = @import("core/root.zig");
pub const database = @import("database/root.zig");
pub const library = @import("library/root.zig");
pub const platform = @import("platform.zig");
pub const storage = @import("storage/root.zig");

pub const OrcaRuntime = core.OrcaRuntime;

pub const version = std.SemanticVersion{
    .major = 0,
    .minor = 2,
    .patch = 0,
    .pre = "dev",
};

test {
    std.testing.refAllDecls(@This());
}
