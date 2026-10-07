pub const audio_features = @import("audio_features.zig");
pub const chromaprint = @import("chromaprint.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const encoding = @import("encoding.zig");
pub const fingerprint = @import("fingerprint.zig");
pub const health = @import("health.zig");
pub const service = @import("service.zig");

test {
    _ = @import("audio_features.zig");
    _ = @import("chromaprint.zig");
    _ = @import("diagnostics.zig");
    _ = @import("encoding.zig");
    _ = @import("fingerprint.zig");
    _ = @import("health.zig");
    _ = @import("service.zig");
}
