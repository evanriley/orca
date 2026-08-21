const builtin = @import("builtin");

pub const current = switch (builtin.os.tag) {
    .linux => @import("platform/linux.zig"),
    .macos => @import("platform/macos.zig"),
    else => struct {
        pub const name = "unsupported";
        pub const supported = false;
    },
};
