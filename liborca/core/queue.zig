const std = @import("std");

pub const Error = error{QueueFull};

/// Fixed-capacity MPSC queue for control-plane messages. The short spin lock is
/// never used from the hard real-time audio path.
pub fn BoundedQueue(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("queue capacity must be positive");

    return struct {
        lock: std.atomic.Mutex = .unlocked,
        items: [capacity]T = undefined,
        head: usize = 0,
        len: usize = 0,

        const Self = @This();

        pub fn push(self: *Self, value: T) Error!void {
            self.acquire();
            defer self.lock.unlock();
            if (self.len == capacity) return error.QueueFull;
            self.items[(self.head + self.len) % capacity] = value;
            self.len += 1;
        }

        pub fn pushCoalescing(
            self: *Self,
            value: T,
            comptime hasSameKey: fn (T, T) bool,
        ) Error!void {
            self.acquire();
            defer self.lock.unlock();
            for (0..self.len) |offset| {
                const index = (self.head + offset) % capacity;
                if (hasSameKey(self.items[index], value)) {
                    self.items[index] = value;
                    return;
                }
            }
            if (self.len == capacity) return error.QueueFull;
            self.items[(self.head + self.len) % capacity] = value;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            self.acquire();
            defer self.lock.unlock();
            if (self.len == 0) return null;
            const value = self.items[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return value;
        }

        pub fn count(self: *Self) usize {
            self.acquire();
            defer self.lock.unlock();
            return self.len;
        }

        fn acquire(self: *Self) void {
            while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        }
    };
}

test "bounded queue preserves FIFO order and rejects overflow" {
    var queue: BoundedQueue(u8, 2) = .{};
    try queue.push(1);
    try queue.push(2);
    try std.testing.expectError(error.QueueFull, queue.push(3));
    try std.testing.expectEqual(@as(?u8, 1), queue.pop());
    try std.testing.expectEqual(@as(?u8, 2), queue.pop());
    try std.testing.expectEqual(@as(?u8, null), queue.pop());
}

test "bounded queue accepts concurrent producers" {
    const Queue = BoundedQueue(u16, 512);
    const Producer = struct {
        fn run(queue: *Queue, base: u16) void {
            for (0..100) |offset| {
                queue.push(base + @as(u16, @intCast(offset))) catch unreachable;
            }
        }
    };

    var queue: Queue = .{};
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{
            &queue,
            @as(u16, @intCast(index * 100)),
        });
    }
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, 400), queue.count());
}

test "coalescing replaces an unread value with the same key" {
    const Value = struct { key: u8, value: u32 };
    const sameKey = struct {
        fn compare(a: Value, b: Value) bool {
            return a.key == b.key;
        }
    }.compare;
    var queue: BoundedQueue(Value, 2) = .{};
    try queue.pushCoalescing(.{ .key = 1, .value = 10 }, sameKey);
    try queue.pushCoalescing(.{ .key = 1, .value = 20 }, sameKey);

    try std.testing.expectEqual(@as(usize, 1), queue.count());
    try std.testing.expectEqual(@as(u32, 20), queue.pop().?.value);
}
