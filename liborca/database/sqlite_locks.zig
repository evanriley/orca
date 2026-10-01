const std = @import("std");
const builtin = @import("builtin");
const c = @import("sqlite.zig").c;

pub fn installOnce() void {
    if (builtin.os.tag == .linux) linux_locks.installOnce();
}

const linux_locks = struct {
    const linux = std.os.linux;
    const Fcntl = *const fn (c_int, c_int, ...) callconv(.c) c_int;

    // std.os.linux.F compares @sizeOf(usize) with 64, so on 64-bit targets its lock commands are the 32-bit F_*LK64 numbers and never match SQLite's.
    const record_lock = if (@sizeOf(usize) == 8) struct {
        const GETLK = if (builtin.cpu.arch.isMIPS()) 14 else if (builtin.cpu.arch.isSPARC()) 7 else 5;
        const SETLK = if (builtin.cpu.arch.isMIPS()) 6 else if (builtin.cpu.arch.isSPARC()) 8 else 6;
        const SETLKW = if (builtin.cpu.arch.isMIPS()) 7 else if (builtin.cpu.arch.isSPARC()) 9 else 7;
    } else linux.F;

    const InstallState = enum(u8) { pending, installing, installed };

    var install_state: std.atomic.Value(InstallState) = .init(.pending);
    var original_fcntl: Fcntl = undefined;

    fn installOnce() void {
        if (install_state.cmpxchgStrong(.pending, .installing, .acquire, .acquire) != null) {
            while (install_state.load(.acquire) != .installed) std.atomic.spinLoopHint();
            return;
        }
        install();
        install_state.store(.installed, .release);
    }

    fn install() void {
        const vfs: *c.sqlite3_vfs = c.sqlite3_vfs_find("unix") orelse {
            std.log.warn("SQLite has no unix VFS; keeping POSIX locks", .{});
            return;
        };
        const get_system_call = vfs.xGetSystemCall orelse {
            std.log.warn("SQLite's unix VFS cannot report its fcntl; keeping POSIX locks", .{});
            return;
        };
        const set_system_call = vfs.xSetSystemCall orelse {
            std.log.warn("SQLite's unix VFS cannot replace its fcntl; keeping POSIX locks", .{});
            return;
        };
        const fcntl = get_system_call(vfs, "fcntl") orelse {
            std.log.warn("SQLite's unix VFS has no fcntl system call; keeping POSIX locks", .{});
            return;
        };
        original_fcntl = @ptrCast(fcntl);
        // Any close of the database in this process drops its POSIX locks, which lets another process delete the live WAL.
        const result = set_system_call(vfs, "fcntl", @ptrCast(&ofdFcntl));
        if (result != c.SQLITE_OK) {
            std.log.warn("SQLite refused the OFD lock fcntl (code {d}); keeping POSIX locks", .{result});
        }
    }

    fn ofdFcntl(fd: c_int, command: c_int, ...) callconv(.c) c_int {
        switch (command) {
            record_lock.SETLK, record_lock.SETLKW, record_lock.GETLK => {
                var arguments = @cVaStart();
                defer @cVaEnd(&arguments);
                const caller_lock = @cVaArg(&arguments, *linux.Flock);
                var lock = caller_lock.*;
                lock.pid = 0;
                const ofd_command: c_int = switch (command) {
                    record_lock.SETLK => linux.F.OFD_SETLK,
                    record_lock.SETLKW => linux.F.OFD_SETLKW,
                    else => linux.F.OFD_GETLK,
                };
                const result = original_fcntl(fd, ofd_command, &lock);
                if (command == record_lock.GETLK and result == 0) caller_lock.* = lock;
                return result;
            },
            linux.F.GETFD, linux.F.GETFL => return original_fcntl(fd, command),
            else => {
                var arguments = @cVaStart();
                defer @cVaEnd(&arguments);
                const argument = @cVaArg(&arguments, usize);
                return original_fcntl(fd, command, argument);
            },
        }
    }
};

fn expectRangeLocked(file: std.Io.File, start: i64, len: i64) !void {
    const linux = std.os.linux;
    var lock: linux.Flock = .{
        .type = linux.F.WRLCK,
        .whence = linux.SEEK.SET,
        .start = start,
        .len = len,
        .pid = 0,
        ._unused = {},
    };
    const result = linux.fcntl(file.handle, linux.F.OFD_GETLK, @intFromPtr(&lock));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(result));
    try std.testing.expect(lock.type != linux.F.UNLCK);
}

fn expectLibraryLocksHeld(database_probe: std.Io.File, shm_probe: std.Io.File) !void {
    try expectRangeLocked(database_probe, 0x40000002, 510);
    try expectRangeLocked(shm_probe, 128, 1);
}

test "a foreign open and close of the database leaves the Library's locks in place" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const database_path = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/library.db", .{temporary.sub_path}, 0);
    defer std.testing.allocator.free(database_path);
    const shm_path = try std.fmt.allocPrint(std.testing.allocator, "{s}-shm", .{database_path});
    defer std.testing.allocator.free(shm_path);

    var library = try @import("library.zig").LibraryDatabase.open(std.testing.allocator, io, database_path);
    defer library.close();

    const database_probe = try std.Io.Dir.cwd().openFile(io, database_path, .{ .mode = .read_write });
    defer database_probe.close(io);
    const shm_probe = try std.Io.Dir.cwd().openFile(io, shm_path, .{ .mode = .read_write });
    defer shm_probe.close(io);
    try expectLibraryLocksHeld(database_probe, shm_probe);

    for ([_][]const u8{ database_path, shm_path }) |path| {
        const foreign = try std.Io.Dir.cwd().openFile(io, path, .{});
        foreign.close(io);
    }

    try expectLibraryLocksHeld(database_probe, shm_probe);
}
