pub const name = "macos";
pub const supported = true;
pub const audio_backend = "coreaudio";
pub const volume = @import("volume_generic.zig");

test {
    _ = @import("volume_generic.zig");
    _ = @import("volume_id.zig");
}
