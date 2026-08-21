const std = @import("std");
const hints = @import("watch_hints.zig");

extern "c" fn read(fd: c_int, buffer: *anyopaque, count: usize) isize;

pub const RootWatcher = struct {
    io: std.Io,
    file: std.Io.File,
    watch_descriptor: c_int,

    pub fn open(io: std.Io, root_path: [:0]const u8) !RootWatcher {
        const linux = std.os.linux;
        const fd = std.c.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
        if (fd < 0) return error.WatcherOpenFailed;
        const file = std.Io.File{
            .handle = fd,
            .flags = .{ .nonblocking = true },
        };
        errdefer file.close(io);
        const mask = linux.IN.CLOSE_WRITE |
            linux.IN.ATTRIB |
            linux.IN.MOVE |
            linux.IN.CREATE |
            linux.IN.DELETE |
            linux.IN.DELETE_SELF |
            linux.IN.MOVE_SELF;
        const descriptor = std.c.inotify_add_watch(fd, root_path.ptr, mask);
        if (descriptor < 0) return error.WatcherAddFailed;
        return .{ .io = io, .file = file, .watch_descriptor = descriptor };
    }

    pub fn close(self: *RootWatcher) void {
        _ = std.c.inotify_rm_watch(self.file.handle, self.watch_descriptor);
        self.file.close(self.io);
        self.* = undefined;
    }

    /// Drains currently available native events into one advisory root hint.
    pub fn poll(self: *RootWatcher, channel: *hints.Channel, root_id: u64) !bool {
        var buffer: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        const count = read(self.file.handle, &buffer, buffer.len);
        if (count < 0) return switch (std.c.errno(count)) {
            .AGAIN => false,
            else => error.WatcherReadFailed,
        };
        if (count == 0) return false;

        var reason: hints.Reason = .changed;
        var offset: usize = 0;
        while (offset + @sizeOf(std.os.linux.inotify_event) <= count) {
            const event: *const std.os.linux.inotify_event = @ptrCast(@alignCast(&buffer[offset]));
            if (event.mask & std.os.linux.IN.Q_OVERFLOW != 0) reason = .overflow;
            if (event.mask & (std.os.linux.IN.DELETE_SELF | std.os.linux.IN.MOVE_SELF) != 0) {
                reason = .root_moved;
            }
            offset += @sizeOf(std.os.linux.inotify_event) + event.len;
        }
        try channel.submit(.{ .root_id = root_id, .reason = reason });
        return true;
    }
};

test "Linux watcher emits an advisory root hint" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{temporary.sub_path},
        0,
    );
    defer std.testing.allocator.free(path);
    var watcher = try RootWatcher.open(std.testing.io, path);
    defer watcher.close();

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "changed.wav",
        .data = "RIFFxxxxWAVE",
    });
    var channel: hints.Channel = .{};
    var received = false;
    for (0..100) |_| {
        if (try watcher.poll(&channel, 9)) {
            received = true;
            break;
        }
    }
    try std.testing.expect(received);
    try std.testing.expectEqual(@as(u64, 9), channel.poll().?.root_id);
}
