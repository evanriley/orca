const std = @import("std");

/// Makes one holder at a time the owner of a Library's mutation journal: the
/// one that may write, undo, prune or recover. An exclusive `flock` on
/// `<database>.orca-journal.lock`, so the operating system drops it when its
/// holder exits in any way, and a paused holder keeps it.
pub const JournalLock = struct {
    file: std.Io.File,

    /// Null when another open file description holds the lock, which is
    /// another process or another acquisition in this one.
    pub fn tryAcquire(io: std.Io, path: []const u8) !?JournalLock {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
        errdefer file.close(io);
        if (!try file.tryLock(io, .exclusive)) {
            file.close(io);
            return null;
        }
        return .{ .file = file };
    }

    /// The lock one write, undo or prune holds for its whole run. A Library
    /// with no database file has no lock file and cannot hold tag writes.
    pub fn acquireForMutation(io: std.Io, path: ?[]const u8) !JournalLock {
        const lock_path = path orelse return error.NoBackupDirectory;
        return try tryAcquire(io, lock_path) orelse error.MutationInProgress;
    }

    pub fn release(self: *JournalLock, io: std.Io) void {
        self.file.unlock(io);
        self.file.close(io);
        self.* = undefined;
    }
};

fn lockPath(temporary: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/library.db.orca-journal.lock", .{temporary.sub_path});
}

test "a second acquisition in the same process is refused until the first is released" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try lockPath(&temporary);
    defer std.testing.allocator.free(path);

    var first = (try JournalLock.tryAcquire(std.testing.io, path)).?;
    try std.testing.expect(try JournalLock.tryAcquire(std.testing.io, path) == null);
    first.release(std.testing.io);

    var second = (try JournalLock.tryAcquire(std.testing.io, path)).?;
    second.release(std.testing.io);
}

test "the lock file outlives the lock and is reused" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try lockPath(&temporary);
    defer std.testing.allocator.free(path);

    var lock = (try JournalLock.tryAcquire(std.testing.io, path)).?;
    lock.release(std.testing.io);
    try std.Io.Dir.cwd().access(std.testing.io, path, .{});
    var again = (try JournalLock.tryAcquire(std.testing.io, path)).?;
    again.release(std.testing.io);
}
