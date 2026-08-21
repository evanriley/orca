const std = @import("std");
const handle = @import("handle.zig");

const WorkTag = struct {};
pub const WorkHandle = handle.Handle(WorkTag);

pub const State = enum {
    active,
    cancellation_requested,
};

/// Tracks work accepted by the runtime. Executors introduced in later phases
/// will observe cancellation and call `complete`; shutdown first requests
/// cancellation and then drains all registrations.
pub const Registry = struct {
    pool: handle.Pool(State, WorkTag),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .pool = .init(allocator) };
    }

    pub fn deinit(self: *Registry) void {
        self.pool.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *Registry) !WorkHandle {
        return self.pool.insert(.active);
    }

    pub fn complete(self: *Registry, work_handle: WorkHandle) !void {
        _ = try self.pool.remove(work_handle);
    }

    pub fn cancellationRequested(self: *const Registry, work_handle: WorkHandle) !bool {
        return (try self.pool.getConst(work_handle)).* == .cancellation_requested;
    }

    pub fn requestCancellation(self: *Registry) void {
        for (self.pool.slots.items) |*slot| {
            if (slot.value != null) slot.value = .cancellation_requested;
        }
    }

    pub fn drain(self: *Registry) void {
        self.pool.discardAll();
    }

    pub fn count(self: *const Registry) usize {
        return self.pool.count();
    }
};

test "work is cancelled before it is drained" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const work_handle = try registry.begin();
    registry.requestCancellation();
    try std.testing.expect(try registry.cancellationRequested(work_handle));
    registry.drain();
    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expectError(
        error.StaleHandle,
        registry.cancellationRequested(work_handle),
    );
}
