//! Orca's log: standard error as before, and `orca.log` in the logs directory
//! under `$XDG_STATE_HOME/orca/logs` at the level Settings › Advanced picks.

const std = @import("std");
const gtk = @import("gtk.zig");

pub const Level = enum { info, debug, trace };

var file_level: std.atomic.Value(u8) = .init(@intFromEnum(Level.info));
var file_fd: std.atomic.Value(i32) = .init(-1);

pub const file_name = "orca.log";

/// `$XDG_STATE_HOME/orca/logs`, created if missing.
pub fn directory(buffer: []u8) ?[:0]const u8 {
    const state = std.mem.span(gtk.g_get_user_state_dir());
    const path = std.fmt.bufPrintSentinel(buffer, "{s}/orca/logs", .{state}, 0) catch return null;
    _ = gtk.g_mkdir_with_parents(path.ptr, 0o700);
    return path;
}

/// Opens the log file; until then lines go to standard error only.
pub fn open() void {
    if (file_fd.load(.acquire) >= 0) return;
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const logs = directory(&buffer) orelse return;
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/" ++ file_name, .{logs}, 0) catch return;
    const linux = std.os.linux;
    const result = linux.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(result) != .SUCCESS) return;
    file_fd.store(@intCast(result), .release);
}

pub fn level() Level {
    return @enumFromInt(file_level.load(.monotonic));
}

pub fn setLevel(value: Level) void {
    file_level.store(@intFromEnum(value), .monotonic);
    gtk.g_log_set_debug_enabled(@intFromBool(value == .trace));
}

fn fileWants(message_level: std.log.Level) bool {
    return switch (message_level) {
        .err, .warn, .info => true,
        .debug => level() != .info,
    };
}

pub fn write(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime @intFromEnum(message_level) <= @intFromEnum(std.log.default_level))
        std.log.defaultLog(message_level, scope, format, args);
    const fd = file_fd.load(.acquire);
    if (fd < 0 or !fileWants(message_level)) return;
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    var now: std.os.linux.timespec = undefined;
    const seconds: i64 = if (std.os.linux.clock_gettime(.REALTIME, &now) == 0) now.sec else 0;
    writer.print("{d} {s}", .{ seconds, message_level.asText() }) catch {};
    if (scope != .default) writer.print("({t})", .{scope}) catch {};
    writer.print(": " ++ format, args) catch {};
    buffer[writer.end] = '\n';
    _ = std.os.linux.write(fd, &buffer, writer.end + 1);
}
