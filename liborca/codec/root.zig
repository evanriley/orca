pub const decoder = @import("decoder.zig");
pub const registry = @import("registry.zig");
pub const wav = @import("wav.zig");

pub const CodecRegistry = registry.CodecRegistry;
pub const Decoder = decoder.Decoder;

test {
    _ = @import("decoder.zig");
    _ = @import("registry.zig");
    _ = @import("wav.zig");
}
