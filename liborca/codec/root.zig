pub const decoder = @import("decoder.zig");
pub const flac = @import("flac.zig");
pub const mp3 = @import("mp3.zig");
pub const mp3_stream = @import("mp3_stream.zig");
pub const opus = @import("opus.zig");
pub const qoa = @import("qoa.zig");
pub const registry = @import("registry.zig");
pub const vorbis = @import("vorbis.zig");
pub const wav = @import("wav.zig");

pub const CodecRegistry = registry.CodecRegistry;
pub const Decoder = decoder.Decoder;

test {
    _ = @import("decoder.zig");
    _ = @import("flac.zig");
    _ = @import("mp3.zig");
    _ = @import("mp3_stream.zig");
    _ = @import("opus.zig");
    _ = @import("qoa.zig");
    _ = @import("registry.zig");
    _ = @import("vorbis.zig");
    _ = @import("wav.zig");
}
