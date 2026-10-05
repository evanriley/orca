const std = @import("std");

/// Makes one scan or reconcile at a time the walker of a Library, across
/// runtimes and processes. An exclusive `flock` on `<database>.orca-scan.lock`,
/// so the operating system drops it when its holder exits in any way. It is
/// not the journal lock: a walk and a tag write never wait for each other.
pub const WalkLock = struct {
    file: std.Io.File,

    /// Null when another open file description holds the lock, which is
    /// another process or another acquisition in this one.
    pub fn tryAcquire(io: std.Io, path: []const u8) !?WalkLock {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
        errdefer file.close(io);
        if (!try file.tryLock(io, .exclusive)) {
            file.close(io);
            return null;
        }
        return .{ .file = file };
    }

    pub fn acquireForWalk(io: std.Io, path: ?[]const u8) !?WalkLock {
        const lock_path = path orelse return null;
        return try tryAcquire(io, lock_path) orelse error.LibraryScanRunning;
    }

    pub fn release(self: *WalkLock, io: std.Io) void {
        self.file.unlock(io);
        self.file.close(io);
        self.* = undefined;
    }
};

fn lockPath(temporary: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/library.db.orca-scan.lock", .{temporary.sub_path});
}

test "a walk is refused while another holds the lock and allowed once it is released" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try lockPath(&temporary);
    defer std.testing.allocator.free(path);

    var first = (try WalkLock.acquireForWalk(std.testing.io, path)).?;
    try std.testing.expectError(error.LibraryScanRunning, WalkLock.acquireForWalk(std.testing.io, path));
    first.release(std.testing.io);

    var second = (try WalkLock.acquireForWalk(std.testing.io, path)).?;
    second.release(std.testing.io);
}

test "a walk of a library with no database file takes no lock" {
    try std.testing.expect(try WalkLock.acquireForWalk(std.testing.io, null) == null);
}
