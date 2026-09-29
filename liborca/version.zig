const std = @import("std");
const build_options = @import("build_options");

pub const value = std.SemanticVersion.parse(build_options.version) catch unreachable;
