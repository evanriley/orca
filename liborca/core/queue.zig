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

pub const queue_history_capacity: usize = 100;

pub const QueueHistoryReason = enum(u8) {
    finished = 0,
    skipped = 1,
    replaced = 2,
};

pub const QueueHistoryEntry = struct {
    track: TrackRef,
    ended_at_ms: i64,
    reason: QueueHistoryReason,
};

pub const QueueHistory = struct {
    entries: [queue_history_capacity]QueueHistoryEntry = undefined,
    next: usize = 0,
    len: usize = 0,
    audible: ?Audible = null,

    const Audible = struct {
        entry_serial: u32,
        track: TrackRef,
        ended: bool,
    };

    pub fn count(self: *const QueueHistory) usize {
        return self.len;
    }

    pub fn newest(self: *const QueueHistory, offset: usize) ?QueueHistoryEntry {
        if (offset >= self.len) return null;
        const index = (self.next + queue_history_capacity - 1 - offset) % queue_history_capacity;
        return self.entries[index];
    }

    pub fn clear(self: *QueueHistory) void {
        self.next = 0;
        self.len = 0;
    }

    pub fn append(self: *QueueHistory, entry: QueueHistoryEntry) void {
        self.entries[self.next] = entry;
        self.next = (self.next + 1) % queue_history_capacity;
        if (self.len < queue_history_capacity) self.len += 1;
    }

    /// `track` must be the entry `entry_serial` played, or null when that
    /// serial is no queue entry. Serial 0 means nothing is audible: a Player
    /// stopped without a hook ending its entry, which is dropped unrecorded.
    pub fn observe(
        self: *QueueHistory,
        entry_serial: u32,
        track: ?TrackRef,
        drained: bool,
        now_ms: i64,
    ) void {
        if (self.audible) |audible| {
            if (audible.entry_serial == entry_serial) {
                if (drained) self.end(.finished, now_ms);
                return;
            }
            if (entry_serial != 0) self.end(.finished, now_ms);
        }
        const ref = if (entry_serial == 0) null else track;
        self.audible = if (ref) |value| .{ .entry_serial = entry_serial, .track = value, .ended = drained } else null;
    }

    pub fn end(self: *QueueHistory, reason: QueueHistoryReason, now_ms: i64) void {
        const audible = if (self.audible) |*value| value else return;
        if (audible.ended) return;
        audible.ended = true;
        self.append(.{ .track = audible.track, .ended_at_ms = now_ms, .reason = reason });
    }

    pub fn forget(self: *QueueHistory) void {
        if (self.audible) |*audible| audible.ended = true;
    }
};

const TrackRef = @import("../audio/playback_queue.zig").TrackRef;

fn testRef(track_id: i64) TrackRef {
    return .{ .library = .{ .index = 0, .generation = 1 }, .track_id = track_id };
}

test "queue history keeps the newest hundred entries and drops the oldest" {
    var history: QueueHistory = .{};
    for (0..queue_history_capacity + 5) |index| {
        history.append(.{
            .track = testRef(@intCast(index)),
            .ended_at_ms = @intCast(index),
            .reason = .finished,
        });
    }
    try std.testing.expectEqual(queue_history_capacity, history.count());
    try std.testing.expectEqual(@as(i64, queue_history_capacity + 4), history.newest(0).?.track.track_id);
    try std.testing.expectEqual(@as(i64, 5), history.newest(queue_history_capacity - 1).?.track.track_id);
    try std.testing.expectEqual(@as(?QueueHistoryEntry, null), history.newest(queue_history_capacity));
    history.clear();
    try std.testing.expectEqual(@as(usize, 0), history.count());
}

test "queue history ends each audible entry once, as finished when the serial moves on or the Player drains" {
    var history: QueueHistory = .{};
    history.observe(7, testRef(1), false, 10);
    history.observe(7, testRef(1), false, 20);
    history.observe(8, testRef(2), false, 30);
    history.end(.skipped, 40);
    history.observe(8, testRef(2), false, 50);
    history.observe(9, testRef(3), false, 60);
    history.observe(9, testRef(3), true, 70);
    history.observe(9, testRef(3), true, 80);

    try std.testing.expectEqual(@as(usize, 3), history.count());
    try std.testing.expectEqual(QueueHistoryEntry{ .track = testRef(3), .ended_at_ms = 70, .reason = .finished }, history.newest(0).?);
    try std.testing.expectEqual(QueueHistoryEntry{ .track = testRef(2), .ended_at_ms = 40, .reason = .skipped }, history.newest(1).?);
    try std.testing.expectEqual(QueueHistoryEntry{ .track = testRef(1), .ended_at_ms = 30, .reason = .finished }, history.newest(2).?);
}

test "queue history drops an entry stopped without a hook and records nothing for a serial that is no queue entry" {
    var history: QueueHistory = .{};
    history.observe(7, testRef(1), false, 10);
    history.observe(0, null, false, 20);
    history.observe(8, null, false, 30);
    history.observe(9, testRef(2), false, 40);
    history.observe(10, testRef(3), false, 50);

    try std.testing.expectEqual(@as(usize, 1), history.count());
    try std.testing.expectEqual(QueueHistoryEntry{ .track = testRef(2), .ended_at_ms = 50, .reason = .finished }, history.newest(0).?);
}
