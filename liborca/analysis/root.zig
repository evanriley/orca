pub const diagnostics = @import("diagnostics.zig");
pub const encoding = @import("encoding.zig");
pub const health = @import("health.zig");
pub const service = @import("service.zig");

test {
    _ = @import("diagnostics.zig");
    _ = @import("encoding.zig");
    _ = @import("health.zig");
    _ = @import("service.zig");
}
