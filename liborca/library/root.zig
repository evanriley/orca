const builtin = @import("builtin");

pub const scanner = @import("scanner.zig");
pub const watch_hints = @import("watch_hints.zig");
pub const NativeRootWatcher = switch (builtin.os.tag) {
    .linux => @import("watch_linux.zig").RootWatcher,
    else => void,
};

pub const CancellationToken = scanner.CancellationToken;
pub const Scanner = scanner.Scanner;
pub const WatchHintChannel = watch_hints.Channel;

test {
    _ = @import("scanner.zig");
    _ = @import("watch_hints.zig");
    if (builtin.os.tag == .linux) _ = @import("watch_linux.zig");
}
