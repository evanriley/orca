const std = @import("std");
const ulid = @import("volume_id.zig");

/// The file a volume's generated identifier is persisted in, at the mount root.
pub const marker_name = ".orca-volume-id";

/// Where a volume's stable key came from. A caller that gets `null` back has to
/// fall back to `root:<library_roots.id>`, which is stable for as long as the
/// root exists but says nothing about the storage itself.
pub const Source = enum { filesystem_uuid, persisted_id };

pub const Resolution = struct {
    key: []u8,
    source: Source,

    pub fn deinit(self: Resolution, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }
};

pub const Options = struct {
    /// Whether a mount root with no filesystem UUID may have an identifier
    /// written into it. Read-only media, foreign permissions and test runs all
    /// want this off; an explicit user action adding a library root wants it on.
    allow_persist: bool = true,
};

/// Resolve a volume key for `path`: the filesystem UUID of the mount it lives
/// on, else an identifier persisted at that mount's root, else null.
///
/// `st_dev` is deliberately not a candidate. It is a kernel-local handle that
/// changes across reboots and remounts, so a library keyed by it would forget
/// every file on the next boot.
pub fn stableKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    options: Options,
) !?Resolution {
    const mount = (try mountFor(allocator, io, path)) orelse return null;
    defer mount.deinit(allocator);

    if (try uuidForSource(allocator, io, mount.source)) |uuid| {
        errdefer allocator.free(uuid);
        const key = try std.fmt.allocPrint(allocator, "uuid:{s}", .{uuid});
        allocator.free(uuid);
        return .{ .key = key, .source = .filesystem_uuid };
    }
    const persisted = (try persistedId(allocator, io, mount.point, options)) orelse return null;
    defer allocator.free(persisted);
    return .{
        .key = try std.fmt.allocPrint(allocator, "ulid:{s}", .{persisted}),
        .source = .persisted_id,
    };
}

pub const Mount = struct {
    point: []u8,
    source: []u8,

    pub fn deinit(self: Mount, allocator: std.mem.Allocator) void {
        allocator.free(self.point);
        allocator.free(self.source);
    }
};

/// The mount whose mount point is the longest prefix of `path`.
pub fn mountFor(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?Mount {
    const absolute = try absolutePath(allocator, io, path);
    defer allocator.free(absolute);
    const buffer = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(buffer);
    const contents = std.Io.Dir.cwd().readFile(io, "/proc/self/mountinfo", buffer) catch
        return null;
    const found = findMount(contents, absolute) orelse return null;
    const point = try allocator.dupe(u8, found.point);
    errdefer allocator.free(point);
    return .{ .point = point, .source = try allocator.dupe(u8, found.source) };
}

const MountView = struct { point: []const u8, source: []const u8 };

/// Parse `/proc/self/mountinfo` and pick the mount covering `path`.
///
/// Fields are: id, parent id, major:minor, root, mount point, options, zero or
/// more optional fields, a `-` separator, filesystem type, mount source, and
/// superblock options.
fn findMount(contents: []const u8, path: []const u8) ?MountView {
    var best: ?MountView = null;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        var index: usize = 0;
        var point: ?[]const u8 = null;
        var source: ?[]const u8 = null;
        var separator_index: ?usize = null;
        while (fields.next()) |field| : (index += 1) {
            if (index == 4) point = field;
            if (separator_index == null and std.mem.eql(u8, field, "-")) separator_index = index;
            if (separator_index) |separator| {
                if (index == separator + 2) source = field;
            }
        }
        const mount_point = point orelse continue;
        if (!covers(mount_point, path)) continue;
        if (best) |current| {
            if (current.point.len >= mount_point.len) continue;
        }
        best = .{ .point = mount_point, .source = source orelse "" };
    }
    return best;
}

fn covers(mount_point: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, mount_point)) return false;
    if (mount_point.len == path.len) return true;
    if (std.mem.eql(u8, mount_point, "/")) return true;
    return path[mount_point.len] == '/';
}

/// Map a mount source such as `/dev/sda2` onto a filesystem UUID by way of the
/// `/dev/disk/by-uuid` symlink farm. Comparing link targets keeps this to
/// string work: no device may be opened just to identify a volume.
fn uuidForSource(allocator: std.mem.Allocator, io: std.Io, source: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, source, "/dev/")) return null;
    const device = std.fs.path.basename(source);
    var directory = std.Io.Dir.cwd().openDir(io, "/dev/disk/by-uuid", .{ .iterate = true }) catch
        return null;
    defer directory.close(io);
    var iterator = directory.iterate();
    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    while (try iterator.next(io)) |entry| {
        const length = directory.readLink(io, entry.name, &link_buffer) catch continue;
        if (!std.mem.eql(u8, std.fs.path.basename(link_buffer[0..length]), device)) continue;
        return try allocator.dupe(u8, entry.name);
    }
    return null;
}

/// Read, or with permission create, the identifier file at a mount root.
pub fn persistedId(
    allocator: std.mem.Allocator,
    io: std.Io,
    mount_point: []const u8,
    options: Options,
) !?[]u8 {
    var directory = std.Io.Dir.cwd().openDir(io, mount_point, .{}) catch return null;
    defer directory.close(io);
    var buffer: [ulid.text_length]u8 = undefined;
    if (directory.readFile(io, marker_name, &buffer)) |contents| {
        const trimmed = std.mem.trim(u8, contents, " \t\r\n");
        if (trimmed.len == ulid.text_length) return try allocator.dupe(u8, trimmed);
    } else |_| {}
    if (!options.allow_persist) return null;
    const generated = ulid.generate(io);
    directory.writeFile(io, .{ .sub_path = marker_name, .data = &generated }) catch return null;
    return try allocator.dupe(u8, &generated);
}

fn absolutePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try std.process.currentPath(io, &buffer);
    return std.fs.path.join(allocator, &.{ buffer[0..length], path });
}

test "the covering mount is the longest matching mount point" {
    const contents =
        \\21 27 0:20 / /proc rw,nosuid - proc proc rw
        \\27 1 259:2 / / rw,relatime - ext4 /dev/nvme0n1p2 rw
        \\44 27 8:17 / /mnt/Media rw,relatime - xfs /dev/sdb1 rw
        \\45 44 8:33 / /mnt/Media/Archive rw,relatime - xfs /dev/sdc1 rw
    ;
    const root = findMount(contents, "/etc/hosts").?;
    try std.testing.expectEqualStrings("/", root.point);
    try std.testing.expectEqualStrings("/dev/nvme0n1p2", root.source);
    const media = findMount(contents, "/mnt/Media/Music/track.flac").?;
    try std.testing.expectEqualStrings("/mnt/Media", media.point);
    try std.testing.expectEqualStrings("/dev/sdb1", media.source);
    const archive = findMount(contents, "/mnt/Media/Archive/track.flac").?;
    try std.testing.expectEqualStrings("/mnt/Media/Archive", archive.point);
    // A directory whose name merely starts with a mount point is not on it.
    const sibling = findMount(contents, "/mnt/MediaOther/track.flac").?;
    try std.testing.expectEqualStrings("/", sibling.point);
}

test "a persisted volume identifier is created once and read back afterwards" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(root);

    const first = (try persistedId(std.testing.allocator, std.testing.io, root, .{})).?;
    defer std.testing.allocator.free(first);
    try std.testing.expectEqual(ulid.text_length, first.len);
    const second = (try persistedId(std.testing.allocator, std.testing.io, root, .{})).?;
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "a read-only volume yields no identifier rather than a written one" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(root);
    try std.testing.expect((try persistedId(
        std.testing.allocator,
        std.testing.io,
        root,
        .{ .allow_persist = false },
    )) == null);
}
