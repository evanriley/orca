const builtin = @import("builtin");

pub const native = switch (builtin.os.tag) {
    .linux => @import("pipewire.zig"),
    else => struct {},
};

pub const playback = switch (builtin.os.tag) {
    .linux => @import("pipewire_playback.zig"),
    else => struct {},
};

test {
    if (builtin.os.tag == .linux) _ = @import("pipewire.zig");
    if (builtin.os.tag == .linux) _ = @import("pipewire_playback.zig");
}
