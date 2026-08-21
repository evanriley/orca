const std = @import("std");

/// Wait-free bounded queue for exactly one producer and one consumer.
pub fn Queue(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("SPSC capacity must be positive");
    return struct {
        items: [capacity]T = undefined,
        head: std.atomic.Value(usize) = .init(0),
        tail: std.atomic.Value(usize) = .init(0),

        const Self = @This();

        pub fn push(self: *Self, item: T) bool {
            const tail = self.tail.load(.monotonic);
            if (tail -% self.head.load(.acquire) >= capacity) return false;
            self.items[tail % capacity] = item;
            self.tail.store(tail +% 1, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            if (head == self.tail.load(.acquire)) return null;
            const item = self.items[head % capacity];
            self.head.store(head +% 1, .release);
            return item;
        }
    };
}

test "SPSC queue is bounded and ordered" {
    var queue: Queue(u8, 2) = .{};
    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(!queue.push(3));
    try std.testing.expectEqual(@as(?u8, 1), queue.pop());
    try std.testing.expectEqual(@as(?u8, 2), queue.pop());
    try std.testing.expect(queue.pop() == null);
}
