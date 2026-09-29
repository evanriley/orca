const std = @import("std");

pub const value = std.SemanticVersion{
    .major = 0,
    .minor = 2,
    .patch = 0,
    .pre = "alpha",
};
