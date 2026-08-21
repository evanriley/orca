const std = @import("std");

pub const StorageIdentity = struct {
    inode: std.Io.File.INode,
    size: u64,
    modified_ns: i96,
};

/// Minimal capability interface consumed by decoders and analysis. Implementors
/// need not represent local paths, only bounded reads and stable source facts.
pub const ReadableSource = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read_at: *const fn (*anyopaque, u64, []u8) anyerror!usize,
        size: *const fn (*anyopaque) u64,
        identity: *const fn (*anyopaque) StorageIdentity,
    };

    pub fn readAt(self: ReadableSource, offset: u64, buffer: []u8) !usize {
        return self.vtable.read_at(self.context, offset, buffer);
    }

    pub fn size(self: ReadableSource) u64 {
        return self.vtable.size(self.context);
    }

    pub fn identity(self: ReadableSource) StorageIdentity {
        return self.vtable.identity(self.context);
    }
};

pub const LocalFileSource = struct {
    io: std.Io,
    file: std.Io.File,
    stat: std.Io.File.Stat,

    pub fn open(io: std.Io, path: []const u8) !LocalFileSource {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        return .{
            .io = io,
            .file = file,
            .stat = try file.stat(io),
        };
    }

    pub fn close(self: *LocalFileSource) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn readable(self: *LocalFileSource) ReadableSource {
        return .{ .context = self, .vtable = &vtable };
    }

    fn readAt(context: *anyopaque, offset: u64, buffer: []u8) !usize {
        const self: *LocalFileSource = @ptrCast(@alignCast(context));
        return self.file.readPositionalAll(self.io, buffer, offset);
    }

    fn getSize(context: *anyopaque) u64 {
        const self: *LocalFileSource = @ptrCast(@alignCast(context));
        return self.stat.size;
    }

    fn getIdentity(context: *anyopaque) StorageIdentity {
        const self: *LocalFileSource = @ptrCast(@alignCast(context));
        return .{
            .inode = self.stat.inode,
            .size = self.stat.size,
            .modified_ns = self.stat.mtime.nanoseconds,
        };
    }

    const vtable = ReadableSource.VTable{
        .read_at = readAt,
        .size = getSize,
        .identity = getIdentity,
    };
};

test "local files satisfy offset reads and identity capabilities" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "source.bin",
        .data = "orca-source",
    });
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/source.bin",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(path);

    var local = try LocalFileSource.open(std.testing.io, path);
    defer local.close();
    const source = local.readable();
    var buffer: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try source.readAt(5, &buffer));
    try std.testing.expectEqualStrings("source", &buffer);
    try std.testing.expectEqual(@as(u64, 11), source.size());
    try std.testing.expectEqual(source.size(), source.identity().size);
}
