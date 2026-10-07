//! Whether a root still lies on the volume the Library recorded for it, asked
//! before any walk that may mark files missing. It reads the mount table and
//! any volume marker and writes nothing, so a watcher thread may ask it too.

const std = @import("std");
const builtin = @import("builtin");
const database = @import("../database/root.zig");
const platform = @import("../platform.zig");

/// True when `path` resolves to `recorded_key`, the stable key of the volume
/// its root was bound to. A null `recorded_key` means the root has no
/// recorded volume to compare with, as a root on the fallback volume has
/// none, and passes. A root bound to its own `root:<id>` key passes only
/// while the platform still names no volume for its path.
pub fn onRecordedVolume(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    recorded_key: ?[]const u8,
) bool {
    return onRecordedVolumeOf(allocator, io, path, recorded_key, .{});
}

/// `onRecordedVolume` with the platform adapter reading the host's volumes
/// from `platform_options`.
pub fn onRecordedVolumeOf(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    recorded_key: ?[]const u8,
    platform_options: platform.volume.Options,
) bool {
    const expected = recorded_key orelse return true;
    const resolved = platform.volume.stableKey(allocator, io, path, platform_options) catch
        return false;
    const resolution = resolved orelse
        return std.mem.startsWith(u8, expected, database.LibraryDatabase.root_volume_key_prefix);
    defer resolution.deinit(allocator);
    return std.mem.eql(u8, resolution.key, expected);
}

pub fn rootAvailable(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    recorded_key: ?[]const u8,
) bool {
    const directory = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    directory.close(io);
    return onRecordedVolume(allocator, io, path, recorded_key);
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
    const resolved = try platform.volume.stableKey(std.testing.allocator, std.testing.io, path, .{});
    if (resolved) |resolution| {
        defer resolution.deinit(std.testing.allocator);
        try std.testing.expect(onRecordedVolume(std.testing.allocator, std.testing.io, path, resolution.key));
        try std.testing.expect(!onRecordedVolume(std.testing.allocator, std.testing.io, path, "root:7"));
    } else {
        try std.testing.expect(onRecordedVolume(std.testing.allocator, std.testing.io, path, "root:7"));
    }
}

test "a root is unavailable once its directory is gone, whatever volume it records" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    try std.testing.expect(rootAvailable(std.testing.allocator, std.testing.io, path, null));
    const gone = try std.fmt.allocPrint(std.testing.allocator, "{s}/renamed-away", .{path});
    defer std.testing.allocator.free(gone);
    try std.testing.expect(!rootAvailable(std.testing.allocator, std.testing.io, gone, null));
    try std.testing.expect(!rootAvailable(std.testing.allocator, std.testing.io, gone, "root:7"));
}

test "a root on a mount with no filesystem UUID passes while mounted and fails once its parent filesystem shows through" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const host = try platform.volume.TestHost.create(std.testing.allocator, std.testing.io, temporary.dir);
    defer host.deinit();
    const music = try host.path("share/music");
    defer std.testing.allocator.free(music);

    try std.testing.expect(onRecordedVolumeOf(std.testing.allocator, std.testing.io, music, "root:7", host.options()));
    try host.setShareMounted(std.testing.io, false);
    try std.testing.expect(!onRecordedVolumeOf(std.testing.allocator, std.testing.io, music, "root:7", host.options()));
}

test "a root bound to an existing volume marker passes while that marker's mount is there" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const host = try platform.volume.TestHost.create(std.testing.allocator, std.testing.io, temporary.dir);
    defer host.deinit();
    const music = try host.path("share/music");
    defer std.testing.allocator.free(music);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "share/.orca-volume-id", .data = "01K6Z9V0000000000000000000" });
    const recorded = "ulid:01K6Z9V0000000000000000000";

    try std.testing.expect(onRecordedVolumeOf(std.testing.allocator, std.testing.io, music, recorded, host.options()));
    try std.testing.expect(!onRecordedVolumeOf(std.testing.allocator, std.testing.io, music, "root:7", host.options()));
    try host.setShareMounted(std.testing.io, false);
    try std.testing.expect(!onRecordedVolumeOf(std.testing.allocator, std.testing.io, music, recorded, host.options()));
}

test "a root whose marker is gone keeps its volume when added again and fails the check until relocated to its own path" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const host = try platform.volume.TestHost.create(std.testing.allocator, std.testing.io, temporary.dir);
    defer host.deinit();
    const music = try host.path("share/music");
    defer std.testing.allocator.free(music);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "share/.orca-volume-id", .data = "01K6Z9V0000000000000000000\n" });
    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-marker-gone?mode=memory&cache=shared",
    );
    defer library.close();
    const options: database.VolumeOptions = .{ .platform_options = host.options() };

    const marked = try library.ensureRoot(std.testing.io, music, options);
    try expectVolumeKey(&library, marked.volume_id, "ulid:01K6Z9V0000000000000000000");
    try std.testing.expect(onRecordedVolumeOf(std.testing.allocator, std.testing.io, music, "ulid:01K6Z9V0000000000000000000", host.options()));
    const again = try library.ensureRoot(std.testing.io, music, options);
    try std.testing.expectEqual(marked.root_id, again.root_id);
    try std.testing.expectEqual(marked.volume_id, again.volume_id);

    try temporary.dir.deleteFile(std.testing.io, "share/.orca-volume-id");
    const kept = try library.ensureRoot(std.testing.io, music, options);
    try std.testing.expectEqual(marked.root_id, kept.root_id);
    try std.testing.expectEqual(marked.volume_id, kept.volume_id);
    try std.testing.expect(!onRecordedVolumeOf(std.testing.allocator, std.testing.io, music, "ulid:01K6Z9V0000000000000000000", host.options()));

    const relocated = try library.relocateRoot(std.testing.io, marked.root_id, music, options);
    try std.testing.expectEqual(marked.root_id, relocated.root_id);
    var own_key: [32]u8 = undefined;
    const root_key = try std.fmt.bufPrint(&own_key, "root:{d}", .{marked.root_id});
    try expectVolumeKey(&library, relocated.volume_id, root_key);
    try std.testing.expect(onRecordedVolumeOf(std.testing.allocator, std.testing.io, music, root_key, host.options()));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(std.testing.io, "share/.orca-volume-id", .{}));
}

fn expectVolumeKey(library: *database.LibraryDatabase, volume_id: i64, expected: []const u8) !void {
    const key = (try library.volumes.stableKey(std.testing.allocator, volume_id)).?;
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings(expected, key);
}
