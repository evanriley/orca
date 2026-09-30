//! Whether a root still lies on the volume the Library recorded for it, asked
//! before any walk that may mark files missing. It reads the mount table and
//! the volume marker and writes nothing, so a watcher thread may ask it too.

const std = @import("std");
const database = @import("../database/root.zig");
const platform = @import("../platform.zig");

/// True when `path` resolves to `recorded_key`, the stable key of the volume
/// its root was bound to. A null `recorded_key` means the root has no
/// recorded volume to compare with, as a migrated root on the legacy volume
/// has none, and passes. A root bound to its own `root:<id>` key passes only
/// while the platform still names no volume for its path.
pub fn onRecordedVolume(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    recorded_key: ?[]const u8,
) bool {
    const expected = recorded_key orelse return true;
    const resolved = platform.volume.stableKey(allocator, io, path, .{ .allow_persist = false }) catch
        return false;
    const resolution = resolved orelse
        return std.mem.startsWith(u8, expected, database.LibraryDatabase.root_volume_key_prefix);
    defer resolution.deinit(allocator);
    return std.mem.eql(u8, resolution.key, expected);
}

test "a root with no recorded volume passes, and one recorded on another volume does not" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    try std.testing.expect(onRecordedVolume(std.testing.allocator, std.testing.io, path, null));
    try std.testing.expect(!onRecordedVolume(std.testing.allocator, std.testing.io, path, "uuid:not-this-volume"));
}

test "a root is on the volume the platform names for its path" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const resolved = try platform.volume.stableKey(std.testing.allocator, std.testing.io, path, .{ .allow_persist = false });
    if (resolved) |resolution| {
        defer resolution.deinit(std.testing.allocator);
        try std.testing.expect(onRecordedVolume(std.testing.allocator, std.testing.io, path, resolution.key));
        try std.testing.expect(!onRecordedVolume(std.testing.allocator, std.testing.io, path, "root:7"));
    } else {
        try std.testing.expect(onRecordedVolume(std.testing.allocator, std.testing.io, path, "root:7"));
    }
}
