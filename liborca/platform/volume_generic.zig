const std = @import("std");
const ulid = @import("volume_id.zig");

/// The portable volume adapter: it knows nothing about mount tables, so it can
/// only report an identifier a previous run persisted next to the path. A
/// caller that gets `null` falls back to `root:<library_roots.id>`.
///
/// Platforms grow a real adapter by resolving their own volume identity here —
/// `DADiskCopyDescription` on macOS, `GetVolumeInformation` on Windows — and
/// nothing above `platform.zig` changes when they do.
pub const Source = enum { filesystem_uuid, persisted_id };

pub const Resolution = struct {
    key: []u8,
    source: Source,

    pub fn deinit(self: Resolution, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }
};

pub const Options = struct {
    allow_persist: bool = true,
};

pub fn stableKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    options: Options,
) !?Resolution {
    _ = allocator;
    _ = io;
    _ = path;
    _ = options;
    return null;
}

test "the portable adapter reports no volume identity of its own" {
    try std.testing.expect((try stableKey(
        std.testing.allocator,
        std.testing.io,
        "/music",
        .{},
    )) == null);
    _ = ulid.text_length;
}
