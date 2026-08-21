const std = @import("std");

pub const Error = error{
    StaleHandle,
    HandleCapacityExceeded,
};

/// A type-safe slot and generation pair. `Tag` prevents handles owned by
/// different managers from being mixed accidentally.
pub fn Handle(comptime Tag: type) type {
    return struct {
        index: u32,
        generation: u32,

        pub const tag = Tag;
        const Self = @This();

        pub fn eql(a: Self, b: Self) bool {
            return a.index == b.index and a.generation == b.generation;
        }
    };
}

/// Dense generational storage for control-plane objects. The pool owns its
/// storage; values stored in it must own and release any nested resources.
pub fn Pool(comptime T: type, comptime Tag: type) type {
    return struct {
        allocator: std.mem.Allocator,
        slots: std.ArrayList(Slot) = .empty,
        free_indices: std.ArrayList(u32) = .empty,

        const Self = @This();
        pub const HandleType = Handle(Tag);

        const Slot = struct {
            generation: u32 = 1,
            value: ?T = null,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.free_indices.deinit(self.allocator);
            self.slots.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn insert(self: *Self, value: T) (std.mem.Allocator.Error || Error)!HandleType {
            if (self.free_indices.pop()) |index| {
                const slot = &self.slots.items[index];
                std.debug.assert(slot.value == null);
                slot.value = value;
                return .{ .index = index, .generation = slot.generation };
            }

            if (self.slots.items.len >= std.math.maxInt(u32)) {
                return error.HandleCapacityExceeded;
            }
            const index: u32 = @intCast(self.slots.items.len);
            try self.slots.append(self.allocator, .{ .value = value });
            return .{ .index = index, .generation = 1 };
        }

        pub fn get(self: *Self, handle: HandleType) Error!*T {
            const slot = self.validSlot(handle) orelse return error.StaleHandle;
            return if (slot.value) |*value| value else error.StaleHandle;
        }

        pub fn getConst(self: *const Self, handle: HandleType) Error!*const T {
            const slot = self.validSlotConst(handle) orelse return error.StaleHandle;
            return if (slot.value) |*value| value else error.StaleHandle;
        }

        pub fn remove(self: *Self, handle: HandleType) (std.mem.Allocator.Error || Error)!T {
            const slot = self.validSlot(handle) orelse return error.StaleHandle;
            const value = slot.value orelse return error.StaleHandle;
            try self.free_indices.ensureUnusedCapacity(self.allocator, 1);
            slot.value = null;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            self.free_indices.appendAssumeCapacity(handle.index);
            return value;
        }

        pub fn count(self: *const Self) usize {
            var result: usize = 0;
            for (self.slots.items) |slot| {
                if (slot.value != null) result += 1;
            }
            return result;
        }

        pub fn invalidateAll(self: *Self) std.mem.Allocator.Error!void {
            try self.free_indices.ensureTotalCapacity(self.allocator, self.slots.items.len);
            self.free_indices.clearRetainingCapacity();
            for (self.slots.items, 0..) |*slot, index| {
                if (slot.value != null) {
                    slot.value = null;
                    slot.generation +%= 1;
                    if (slot.generation == 0) slot.generation = 1;
                }
                self.free_indices.appendAssumeCapacity(@intCast(index));
            }
        }

        /// Invalidate all values without allocating. Discarded slots are not
        /// reused, making this suitable for terminal manager shutdown.
        pub fn discardAll(self: *Self) void {
            for (self.slots.items) |*slot| {
                if (slot.value != null) {
                    slot.value = null;
                    slot.generation +%= 1;
                    if (slot.generation == 0) slot.generation = 1;
                }
            }
            self.free_indices.clearRetainingCapacity();
        }

        fn validSlot(self: *Self, handle: HandleType) ?*Slot {
            if (handle.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[handle.index];
            if (slot.generation != handle.generation) return null;
            return slot;
        }

        fn validSlotConst(self: *const Self, handle: HandleType) ?*const Slot {
            if (handle.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[handle.index];
            if (slot.generation != handle.generation) return null;
            return slot;
        }
    };
}

test "removed handles stay stale when their slot is reused" {
    const TestTag = struct {};
    var pool = Pool(u32, TestTag).init(std.testing.allocator);
    defer pool.deinit();

    const first = try pool.insert(10);
    try std.testing.expectEqual(@as(u32, 10), try pool.remove(first));
    const second = try pool.insert(20);

    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expectError(error.StaleHandle, pool.get(first));
    try std.testing.expectEqual(@as(u32, 20), (try pool.get(second)).*);
}

test "invalidating a pool rejects every issued handle" {
    const TestTag = struct {};
    var pool = Pool(u8, TestTag).init(std.testing.allocator);
    defer pool.deinit();

    const first = try pool.insert(1);
    const second = try pool.insert(2);
    try pool.invalidateAll();

    try std.testing.expectEqual(@as(usize, 0), pool.count());
    try std.testing.expectError(error.StaleHandle, pool.get(first));
    try std.testing.expectError(error.StaleHandle, pool.get(second));
}

test "terminal discard does not allocate and keeps handles stale" {
    const TestTag = struct {};
    var pool = Pool(u8, TestTag).init(std.testing.allocator);
    defer pool.deinit();

    const old = try pool.insert(1);
    pool.discardAll();
    const fresh = try pool.insert(2);

    try std.testing.expect(!old.eql(fresh));
    try std.testing.expectError(error.StaleHandle, pool.get(old));
}
