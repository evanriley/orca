const builtin = @import("builtin");

pub const projection = @import("projection.zig");
pub const property_backfill = @import("property_backfill.zig");
pub const scanner = @import("scanner.zig");
pub const tag_reader = @import("tag_reader.zig");
pub const watch_hints = @import("watch_hints.zig");
pub const NativeRootWatcher = switch (builtin.os.tag) {
    .linux => @import("watch_linux.zig").RootWatcher,
    else => void,
};

pub const CancellationToken = scanner.CancellationToken;
pub const Projection = projection.Projection;
pub const ProjectionScope = projection.Scope;
pub const PropertyBackfill = property_backfill.PropertyBackfill;
pub const Scanner = scanner.Scanner;
pub const Tags = tag_reader.Tags;
pub const WatchHintChannel = watch_hints.Channel;

test {
    _ = @import("projection.zig");
    _ = @import("property_backfill.zig");
    _ = @import("scanner.zig");
    _ = @import("tag_reader.zig");
    _ = @import("watch_hints.zig");
    if (builtin.os.tag == .linux) _ = @import("watch_linux.zig");
}
