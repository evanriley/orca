//! Watching the music folders: liborca reconciles what changes under them on
//! its own, and this frontend turns it on or off and says how it is going.

const std = @import("std");
const liborca = @import("liborca");
const app = @import("app.zig");

const App = app.App;

const options: liborca.WatchOptions = .{};

pub const Outcome = enum { watching, stopped, unsupported, failed };

/// Brings the open library's watching in line with `self.watch_folders`.
pub fn apply(self: *App) Outcome {
    const library = self.library orelse return .stopped;
    if (!self.watch_folders) {
        self.runtime.libraryUnwatch(library) catch return .failed;
        return .stopped;
    }
    if (!supported(self)) return .unsupported;
    self.runtime.libraryWatch(library, options) catch |err| return switch (err) {
        error.AlreadyWatching => .watching,
        else => .failed,
    };
    return .watching;
}

pub fn supported(self: *App) bool {
    const library = self.library orelse return false;
    const status = self.runtime.libraryWatchStatus(library) catch return false;
    return status.state != .unsupported;
}

fn folders(count: u32) []const u8 {
    return if (count == 1) "folder" else "folders";
}

/// One line for under the switch; empty while nothing is watched.
pub fn statusText(buffer: []u8, status: liborca.WatchStatus) [:0]const u8 {
    switch (status.state) {
        .off, .unsupported => return "",
        .watching, .degraded => {},
    }
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    const written = writeStatus(&writer, status);
    const end = if (written) writer.end else |_| 0;
    buffer[end] = 0;
    return buffer[0..end :0];
}

fn writeStatus(writer: *std.Io.Writer, status: liborca.WatchStatus) !void {
    if (status.roots_watched == 0 and status.roots_unavailable == 0) return writer.writeAll("No folders to watch");
    try writer.print("Watching {d} {s}", .{ status.roots_watched, folders(status.roots_watched) });
    if (status.roots_unavailable != 0) try writer.print(" · {d} {s} unavailable", .{
        status.roots_unavailable,
        if (status.roots_unavailable == 1) "folder is" else "folders are",
    });
    if (status.watch_limit_reached) try writer.print(
        ". Some folders are not watched: the system's watch limit was reached, so they are rescanned every {d} minutes instead. Raise fs.inotify.max_user_watches (on NixOS: boot.kernel.sysctl).",
        .{options.degraded_rescan_ms / std.time.ms_per_min},
    );
}
