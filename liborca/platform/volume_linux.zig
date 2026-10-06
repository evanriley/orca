const std = @import("std");

/// The file at a mount root that names a volume with no filesystem UUID. Orca
/// reads it and never writes it.
pub const marker_name = ".orca-volume-id";

const marker_id_length = 26;

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

/// Where the host's mount table and filesystem UUIDs are read from.
pub const Options = struct {
    mount_table_path: []const u8 = "/proc/self/mountinfo",
    uuid_directory_path: []const u8 = "/dev/disk/by-uuid",
};

/// Resolve a volume key for `path`: the filesystem UUID of the mount it lives
/// on, else the identifier in a marker at that mount's root, else null. It
/// writes nothing.
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
    const mount = (try mountFor(allocator, io, path, options.mount_table_path)) orelse return null;
    defer mount.deinit(allocator);

    if (try uuidForSource(allocator, io, mount.source, options.uuid_directory_path)) |uuid| {
        errdefer allocator.free(uuid);
        const key = try std.fmt.allocPrint(allocator, "uuid:{s}", .{uuid});
        allocator.free(uuid);
        return .{ .key = key, .source = .filesystem_uuid };
    }
    const marker = (try markerId(allocator, io, mount.point)) orelse return null;
    defer allocator.free(marker);
    return .{
        .key = try std.fmt.allocPrint(allocator, "ulid:{s}", .{marker}),
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
pub fn mountFor(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    mount_table_path: []const u8,
) !?Mount {
    const absolute = try absolutePath(allocator, io, path);
    defer allocator.free(absolute);
    const buffer = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(buffer);
    const contents = std.Io.Dir.cwd().readFile(io, mount_table_path, buffer) catch
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

/// Map a mount source such as `/dev/sda2` or `/dev/mapper/cryptroot` onto a
/// filesystem UUID by way of the `/dev/disk/by-uuid` symlink farm. Comparing
/// link targets keeps this to string work: no device may be opened just to
/// identify a volume.
fn uuidForSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    uuid_directory_path: []const u8,
) !?[]u8 {
    if (!std.mem.startsWith(u8, source, "/dev/")) return null;
    var source_link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const device = if (std.Io.Dir.cwd().readLink(io, source, &source_link_buffer)) |length|
        std.fs.path.basename(source_link_buffer[0..length])
    else |_|
        std.fs.path.basename(source);
    var directory = std.Io.Dir.cwd().openDir(io, uuid_directory_path, .{ .iterate = true }) catch
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

/// The identifier in the marker at a mount root, if a well-formed one is there.
fn markerId(allocator: std.mem.Allocator, io: std.Io, mount_point: []const u8) !?[]u8 {
    var directory = std.Io.Dir.cwd().openDir(io, mount_point, .{}) catch return null;
    defer directory.close(io);
    var buffer: [marker_id_length]u8 = undefined;
    const contents = directory.readFile(io, marker_name, &buffer) catch return null;
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    if (trimmed.len != marker_id_length) return null;
    return try allocator.dupe(u8, trimmed);
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

/// A stand-in for the host's mount table and `/dev/disk/by-uuid`, inside a
/// test's temporary directory: `/` is a filesystem with a UUID, and
/// `<root>/share` is a mount with none while `setShareMounted` says so.
pub const TestHost = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    mount_table_path: []u8,
    uuid_directory_path: []u8,

    pub const parent_uuid = "0000-PARENT";

    pub fn create(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) !TestHost {
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try allocator.dupe(u8, buffer[0..try directory.realPath(io, &buffer)]);
        errdefer allocator.free(root);
        const mount_table_path = try std.fs.path.join(allocator, &.{ root, "mountinfo" });
        errdefer allocator.free(mount_table_path);
        const uuid_directory_path = try std.fs.path.join(allocator, &.{ root, "by-uuid" });
        errdefer allocator.free(uuid_directory_path);
        try directory.createDirPath(io, "share/music");
        try directory.createDirPath(io, "by-uuid");
        try directory.symLink(io, "../../orca-test-disk", "by-uuid/" ++ parent_uuid, .{});
        const host: TestHost = .{
            .allocator = allocator,
            .root = root,
            .mount_table_path = mount_table_path,
            .uuid_directory_path = uuid_directory_path,
        };
        try host.setShareMounted(io, true);
        return host;
    }

    pub fn deinit(self: TestHost) void {
        self.allocator.free(self.root);
        self.allocator.free(self.mount_table_path);
        self.allocator.free(self.uuid_directory_path);
    }

    pub fn options(self: *const TestHost) Options {
        return .{ .mount_table_path = self.mount_table_path, .uuid_directory_path = self.uuid_directory_path };
    }

    pub fn setShareMounted(self: *const TestHost, io: std.Io, mounted: bool) !void {
        const parent = "27 1 259:2 / / rw,relatime - ext4 /dev/orca-test-disk rw\n";
        const contents = if (mounted)
            try std.fmt.allocPrint(self.allocator, parent ++ "50 27 0:50 / {s}/share rw - nfs4 server:/export rw\n", .{self.root})
        else
            try self.allocator.dupe(u8, parent);
        defer self.allocator.free(contents);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self.mount_table_path, .data = contents });
    }

    pub fn path(self: *const TestHost, relative: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.root, relative });
    }
};

test "a mount with no filesystem UUID names no volume and is given no marker" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const host = try TestHost.create(std.testing.allocator, std.testing.io, temporary.dir);
    defer host.deinit();
    const music = try host.path("share/music");
    defer std.testing.allocator.free(music);

    try std.testing.expect((try stableKey(std.testing.allocator, std.testing.io, music, host.options())) == null);
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(std.testing.io, "share/" ++ marker_name, .{}));
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(std.testing.io, "share/music/" ++ marker_name, .{}));
}

test "a marker already at a mount with no filesystem UUID names its volume" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const host = try TestHost.create(std.testing.allocator, std.testing.io, temporary.dir);
    defer host.deinit();
    const music = try host.path("share/music");
    defer std.testing.allocator.free(music);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "share/" ++ marker_name, .data = "01K6Z9V0000000000000000000\n" });

    const resolution = (try stableKey(std.testing.allocator, std.testing.io, music, host.options())).?;
    defer resolution.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ulid:01K6Z9V0000000000000000000", resolution.key);
    try std.testing.expectEqual(Source.persisted_id, resolution.source);
}

test "a path left on the parent filesystem once a share is unmounted resolves to the parent's UUID" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const host = try TestHost.create(std.testing.allocator, std.testing.io, temporary.dir);
    defer host.deinit();
    try host.setShareMounted(std.testing.io, false);
    const music = try host.path("share/music");
    defer std.testing.allocator.free(music);

    const resolution = (try stableKey(std.testing.allocator, std.testing.io, music, host.options())).?;
    defer resolution.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("uuid:" ++ TestHost.parent_uuid, resolution.key);
    try std.testing.expectEqual(Source.filesystem_uuid, resolution.source);
}
