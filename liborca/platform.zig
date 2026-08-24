const builtin = @import("builtin");

pub const current = switch (builtin.os.tag) {
    .linux => @import("platform/linux.zig"),
    .macos => @import("platform/macos.zig"),
    else => struct {
        pub const name = "unsupported";
        pub const supported = false;
        pub const volume = @import("platform/volume_generic.zig");
    },
};

/// Volume identity resolution for the host platform. Foreign headers and mount
/// tables terminate inside the adapter; a scanner or repository only ever sees
/// the resolved key.
pub const volume = current.volume;

test {
    _ = current;
}
