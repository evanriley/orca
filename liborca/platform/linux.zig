pub const name = "linux";
pub const supported = true;
pub const audio_backend = "pipewire";
pub const volume = @import("volume_linux.zig");

test {
    _ = @import("volume_linux.zig");
    _ = @import("volume_id.zig");
}
