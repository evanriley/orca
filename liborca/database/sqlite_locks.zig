const std = @import("std");
const builtin = @import("builtin");
const c = @import("sqlite.zig").c;

pub const Error = error{SqliteLocksNotInstalled};

pub const Outcome = enum {
    installed,
    connections_open,
    no_unix_vfs,
    no_system_calls,
    refused_by_sqlite,
};

pub fn installOnce() void {
    if (builtin.os.tag == .linux) _ = linux_locks.process.ensure(linux_locks.processTarget());
}

pub fn requireInstalled() Error!void {
    if (builtin.os.tag != .linux) return;
    installOnce();
    if (!active()) return error.SqliteLocksNotInstalled;
}

pub fn active() bool {
    if (builtin.os.tag != .linux) return false;
    return linux_locks.replacing(linux_locks.processTarget());
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

    var process: Installation = .{};

    const Target = struct {
        vfs: ?*c.sqlite3_vfs,
        replacement: c.sqlite3_syscall_ptr,
        liveAllocations: *const fn () i64,
    };

    fn processTarget() Target {
        return .{
            .vfs = c.sqlite3_vfs_find("unix"),
            .replacement = @ptrCast(&ofdFcntl),
            .liveAllocations = sqliteLiveAllocations,
        };
    }

    fn sqliteLiveAllocations() i64 {
        var current: c.sqlite3_int64 = 0;
        var highwater: c.sqlite3_int64 = 0;
        if (c.sqlite3_status64(c.SQLITE_STATUS_MALLOC_COUNT, &current, &highwater, 0) != c.SQLITE_OK) return 0;
        return current;
    }

    fn replacing(target: Target) bool {
        const vfs = target.vfs orelse return false;
        const get_system_call = vfs.xGetSystemCall orelse return false;
        return get_system_call(vfs, "fcntl") == target.replacement;
    }

    const Installation = struct {
        state: std.atomic.Value(State) = .init(.pending),
        outcome: Outcome = .installed,
        original_fcntl: Fcntl = undefined,

        const State = enum(u8) { pending, installing, decided };

        fn ensure(self: *Installation, target: Target) Outcome {
            if (self.state.cmpxchgStrong(.pending, .installing, .acquire, .acquire) != null) {
                while (self.state.load(.acquire) != .decided) std.atomic.spinLoopHint();
                return self.outcome;
            }
            self.outcome = self.install(target);
            report(self.outcome);
            self.state.store(.decided, .release);
            return self.outcome;
        }

        fn install(self: *Installation, target: Target) Outcome {
            const vfs = target.vfs orelse return .no_unix_vfs;
            const get_system_call = vfs.xGetSystemCall orelse return .no_system_calls;
            const set_system_call = vfs.xSetSystemCall orelse return .no_system_calls;
            const fcntl = get_system_call(vfs, "fcntl") orelse return .no_system_calls;
            // A connection open across the swap keeps POSIX locks that the OFD fcntl can never release.
            if (target.liveAllocations() != 0) return .connections_open;
            self.original_fcntl = @ptrCast(fcntl);
            // Any close of the database in this process drops its POSIX locks, which lets another process delete the live WAL.
            if (set_system_call(vfs, "fcntl", target.replacement) != c.SQLITE_OK) return .refused_by_sqlite;
            return .installed;
        }
    };

    fn report(outcome: Outcome) void {
        const reason = switch (outcome) {
            .installed => return,
            .connections_open => "SQLite connections were already open; create the first Orca runtime before opening any other SQLite connection in the process",
            .no_unix_vfs => "SQLite has no unix VFS",
            .no_system_calls => "SQLite's unix VFS cannot replace its fcntl",
            .refused_by_sqlite => "SQLite refused the replacement fcntl",
        };
        std.log.warn("SQLite keeps POSIX locks, so no Library opens in this process: {s}", .{reason});
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
                const result = process.original_fcntl(fd, ofd_command, &lock);
                if (command == record_lock.GETLK and result == 0) caller_lock.* = lock;
                return result;
            },
            linux.F.GETFD, linux.F.GETFL => return process.original_fcntl(fd, command),
            else => {
                var arguments = @cVaStart();
                defer @cVaEnd(&arguments);
                const argument = @cVaArg(&arguments, usize);
                return process.original_fcntl(fd, command, argument);
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

const FakeUnixVfs = struct {
    vfs: c.sqlite3_vfs = std.mem.zeroes(c.sqlite3_vfs),
    fcntl: c.sqlite3_syscall_ptr = @ptrCast(&fakeOriginalFcntl),
    replacements: std.atomic.Value(u32) = .init(0),

    fn target(self: *FakeUnixVfs, liveAllocations: *const fn () i64) linux_locks.Target {
        self.vfs.pAppData = self;
        self.vfs.xGetSystemCall = getSystemCall;
        self.vfs.xSetSystemCall = setSystemCall;
        return .{ .vfs = &self.vfs, .replacement = @ptrCast(&fakeReplacementFcntl), .liveAllocations = liveAllocations };
    }

    fn of(vfs: [*c]c.sqlite3_vfs) *FakeUnixVfs {
        return @ptrCast(@alignCast(vfs.*.pAppData));
    }

    fn getSystemCall(vfs: [*c]c.sqlite3_vfs, _: [*c]const u8) callconv(.c) c.sqlite3_syscall_ptr {
        return of(vfs).fcntl;
    }

    fn setSystemCall(vfs: [*c]c.sqlite3_vfs, _: [*c]const u8, replacement: c.sqlite3_syscall_ptr) callconv(.c) c_int {
        const self = of(vfs);
        self.fcntl = replacement;
        _ = self.replacements.fetchAdd(1, .acq_rel);
        return c.SQLITE_OK;
    }

    fn fakeOriginalFcntl() callconv(.c) void {
        std.mem.doNotOptimizeAway(@as(u8, 1));
    }

    fn fakeReplacementFcntl() callconv(.c) void {
        std.mem.doNotOptimizeAway(@as(u8, 2));
    }

    fn noLiveAllocations() i64 {
        return 0;
    }

    fn oneLiveAllocation() i64 {
        return 1;
    }
};

fn ensureInto(installation: *linux_locks.Installation, target: linux_locks.Target, outcome: *Outcome) void {
    outcome.* = installation.ensure(target);
}

test "concurrent first installs replace fcntl once and every caller sees it installed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fake: FakeUnixVfs = .{};
    const target = fake.target(FakeUnixVfs.noLiveAllocations);
    var installation: linux_locks.Installation = .{};
    var outcomes: [8]Outcome = undefined;
    var threads: [8]std.Thread = undefined;
    for (&threads, &outcomes) |*thread, *outcome| {
        thread.* = try std.Thread.spawn(.{}, ensureInto, .{ &installation, target, outcome });
    }
    for (threads) |thread| thread.join();

    for (outcomes) |outcome| try std.testing.expectEqual(Outcome.installed, outcome);
    try std.testing.expectEqual(Outcome.installed, installation.ensure(target));
    try std.testing.expectEqual(@as(u32, 1), fake.replacements.load(.acquire));
    try std.testing.expect(linux_locks.replacing(target));
}

test "an install while SQLite connections are open leaves fcntl alone and stays refused" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fake: FakeUnixVfs = .{};
    var installation: linux_locks.Installation = .{};

    try std.testing.expectEqual(Outcome.connections_open, installation.ensure(fake.target(FakeUnixVfs.oneLiveAllocation)));
    try std.testing.expectEqual(Outcome.connections_open, installation.ensure(fake.target(FakeUnixVfs.noLiveAllocations)));
    try std.testing.expectEqual(@as(u32, 0), fake.replacements.load(.acquire));
    try std.testing.expect(!linux_locks.replacing(fake.target(FakeUnixVfs.noLiveAllocations)));
}

test "a Library open is refused while SQLite's fcntl is not the OFD replacement" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try requireInstalled();
    const vfs: *c.sqlite3_vfs = c.sqlite3_vfs_find("unix").?;
    const replacement = vfs.xGetSystemCall.?(vfs, "fcntl");
    try std.testing.expectEqual(c.SQLITE_OK, vfs.xSetSystemCall.?(vfs, "fcntl", null));
    defer std.debug.assert(vfs.xSetSystemCall.?(vfs, "fcntl", replacement) == c.SQLITE_OK);

    try std.testing.expect(!active());
    try std.testing.expectError(
        error.SqliteLocksNotInstalled,
        @import("library.zig").LibraryDatabase.open(std.testing.allocator, std.testing.io, "file:orca-locks-missing?mode=memory&cache=shared"),
    );
    try std.testing.expect(!active());
}
