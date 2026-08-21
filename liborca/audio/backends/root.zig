const builtin = @import("builtin");

pub const native = switch (builtin.os.tag) {
    .linux => @import("pipewire.zig"),
    else => struct {},
};

test {
    if (builtin.os.tag == .linux) _ = @import("pipewire.zig");
}
