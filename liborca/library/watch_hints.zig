const std = @import("std");
const queue = @import("../core/queue.zig");

pub const Reason = enum {
    changed,
    overflow,
    root_moved,
};

/// Advisory signal from a platform watcher. Consumers always reconcile actual
/// filesystem state; hints carry no authoritative file facts.
pub const Hint = struct {
    root_id: u64,
    reason: Reason,

    fn sameRoot(a: Hint, b: Hint) bool {
        return a.root_id == b.root_id;
    }
};

pub const Channel = struct {
    queue: queue.BoundedQueue(Hint, 256) = .{},

    pub fn submit(self: *Channel, hint: Hint) !void {
        try self.queue.pushCoalescing(hint, Hint.sameRoot);
    }

    pub fn poll(self: *Channel) ?Hint {
        return self.queue.pop();
    }
};

test "watcher storms coalesce into one reconciliation hint per root" {
    var channel: Channel = .{};
    for (0..10_000) |_| try channel.submit(.{ .root_id = 42, .reason = .changed });
    try channel.submit(.{ .root_id = 7, .reason = .overflow });

    try std.testing.expectEqual(@as(u64, 42), channel.poll().?.root_id);
    try std.testing.expectEqual(@as(u64, 7), channel.poll().?.root_id);
    try std.testing.expect(channel.poll() == null);
}
