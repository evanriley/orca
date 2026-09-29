const std = @import("std");
const handle = @import("handle.zig");

const WorkTag = struct {};
pub const WorkHandle = handle.Handle(WorkTag);

/// Which runtime object a worker may still touch. The kind is part of the
/// owner, so a Player and a Library that share a slot index and generation
/// never name each other's workers.
pub const Owner = struct {
    kind: Kind,
    index: u32 = 0,
    generation: u32 = 0,

    pub const Kind = enum(u8) { unowned, player, library };

    pub fn eql(a: Owner, b: Owner) bool {
        return a.kind == b.kind and a.index == b.index and a.generation == b.generation;
    }
};

/// The owner of work that belongs to no single runtime object.
pub const unowned: Owner = .{ .kind = .unowned };

pub const State = enum {
    active,
    cancellation_requested,
};

/// One live worker's runtime-visible presence. A registration exists for
/// exactly as long as its worker may still touch runtime-owned objects, so it
/// is heap-allocated and stable: workers hold this pointer, never a Pool slot.
///
/// Threading contract:
/// * The control lane owns the `Registry` and its `handle.Pool`. `handle.Pool`
///   performs no locking of its own and `OrcaRuntime` takes no lock around pool
///   access, so a worker thread must NEVER touch a Pool, a `WorkHandle`, or the
///   `Registry`. A worker only ever reads `cancellationRequested` and calls
///   `finish` on the `*Registration` it was handed at spawn time.
/// * The control lane requests cancellation and then blocks in `Registry.drain`
///   until every worker has finished, before any dependent object is destroyed.
pub const Registration = struct {
    cancel: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    /// Set by the control lane when it spawned a joinable OS thread for this
    /// registration. `awaitCompletion` joins it instead of spinning.
    thread: ?std.Thread = null,
    /// Which runtime object this worker may still touch, as the control lane
    /// assigns it. Destroying one object has to join the workers that could
    /// reach *it* -- and only those. `unowned` means the worker is not bound
    /// to a single object and is joined only by a full `drain`.
    owner: Owner = unowned,
    /// This registration's own handle, so a targeted drain can retire it
    /// through `complete` rather than reimplementing slot invalidation.
    work_handle: WorkHandle = .{ .index = 0, .generation = 0 },

    /// Control lane. Safe to call repeatedly.
    pub fn requestCancellation(self: *Registration) void {
        self.cancel.store(true, .release);
    }

    /// Worker lane. Long-running workers must poll this and return promptly.
    pub fn cancellationRequested(self: *const Registration) bool {
        return self.cancel.load(.acquire);
    }

    /// Worker lane. The worker's last action: after this returns, the control
    /// lane may destroy every object the worker was using.
    pub fn finish(self: *Registration) void {
        self.finished.store(true, .release);
    }

    pub fn isFinished(self: *const Registration) bool {
        return self.finished.load(.acquire);
    }

    /// Control lane. Blocks — deliberately without a timeout — until the worker
    /// has finished. A worker that ignores cancellation is a bug; a timeout
    /// here would reintroduce the use-after-free it exists to prevent.
    pub fn awaitCompletion(self: *Registration) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
            std.debug.assert(self.isFinished());
            return;
        }
        while (!self.isFinished()) std.Thread.yield() catch {};
    }

    pub fn state(self: *const Registration) State {
        return if (self.cancellationRequested()) .cancellation_requested else .active;
    }
};

/// Tracks work accepted by the runtime. A registration represents a live worker
/// that may still be holding runtime-owned resources, so `drain` blocks until
/// every worker has completed rather than merely invalidating handles.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    pool: handle.Pool(*Registration, WorkTag),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator, .pool = .init(allocator) };
    }

    /// Drains first: a Registry may never outlive the workers it registered.
    pub fn deinit(self: *Registry) void {
        self.drain();
        self.pool.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *Registry, owner: Owner) !WorkHandle {
        const entry = try self.allocator.create(Registration);
        errdefer self.allocator.destroy(entry);
        entry.* = .{ .owner = owner };
        const work_handle = try self.pool.insert(entry);
        entry.work_handle = work_handle;
        return work_handle;
    }

    /// Control lane. Joins exactly the workers bound to `owner`, then releases
    /// them -- the precondition for destroying that one object.
    ///
    /// `drain` is the blanket form and is correct but indiscriminate: using it
    /// to destroy a single Player also cancelled every other Player's engine
    /// and every running scan job, which is a real fault rather than mere
    /// waste. Workers tagged `unowned` are never retired here, because a scan
    /// job does not touch a Player and must outlive one being destroyed.
    pub fn drainOwner(self: *Registry, owner: Owner) void {
        if (owner.kind == .unowned) return;
        var index: usize = 0;
        while (index < self.pool.slots.items.len) : (index += 1) {
            const entry = self.pool.slots.items[index].value orelse continue;
            if (!entry.owner.eql(owner)) continue;
            self.complete(entry.work_handle) catch {};
        }
    }

    /// Control lane. The pointer stays valid until this registration is
    /// completed or drained, which is exactly the worker's permitted lifetime.
    pub fn registration(self: *Registry, work_handle: WorkHandle) !*Registration {
        return (try self.pool.get(work_handle)).*;
    }

    /// Control lane. Retires one registration: requests cancellation, blocks
    /// until the worker has finished, then releases it.
    pub fn complete(self: *Registry, work_handle: WorkHandle) !void {
        const entry = try self.pool.remove(work_handle);
        entry.requestCancellation();
        entry.awaitCompletion();
        self.allocator.destroy(entry);
    }

    pub fn cancellationRequested(self: *const Registry, work_handle: WorkHandle) !bool {
        return (try self.pool.getConst(work_handle)).*.cancellationRequested();
    }

    pub fn requestCancellation(self: *Registry) void {
        for (self.pool.slots.items) |*slot| {
            if (slot.value) |entry| entry.requestCancellation();
        }
    }

    /// Control lane. Requests cancellation of every registration and BLOCKS
    /// until all of them have completed, then invalidates their handles. On
    /// return no worker can still reach a runtime-owned object, which is the
    /// precondition for destroying Zones, Players and Library databases.
    pub fn drain(self: *Registry) void {
        for (self.pool.slots.items) |*slot| {
            if (slot.value) |entry| entry.requestCancellation();
        }
        for (self.pool.slots.items) |*slot| {
            if (slot.value) |entry| {
                entry.awaitCompletion();
                self.allocator.destroy(entry);
                slot.value = null;
            }
        }
        self.pool.discardAll();
    }

    pub fn count(self: *const Registry) usize {
        return self.pool.count();
    }
};

test "work is cancelled before it is drained" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const work_handle = try registry.begin(unowned);
    const entry = try registry.registration(work_handle);
    entry.finish();
    registry.requestCancellation();
    try std.testing.expect(try registry.cancellationRequested(work_handle));
    registry.drain();
    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expectError(
        error.StaleHandle,
        registry.cancellationRequested(work_handle),
    );
}

/// A worker that blocks indefinitely until cancellation is requested, then
/// performs a bounded amount of further work before finishing. Only a `drain`
/// that genuinely waits for `finish` can observe `teardown_completed`.
const BlockedWorker = struct {
    registration: *Registration,
    running: std.atomic.Value(bool) = .init(false),
    teardown_completed: std.atomic.Value(bool) = .init(false),
    counter: u64 = 0,

    const teardown_steps = 20_000;

    fn run(self: *BlockedWorker) void {
        self.running.store(true, .release);
        while (!self.registration.cancellationRequested()) std.Thread.yield() catch {};
        for (0..teardown_steps) |_| self.counter += 1;
        self.teardown_completed.store(true, .release);
        self.registration.finish();
    }
};

test "draining blocks until a blocked worker has actually finished" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const work_handle = try registry.begin(unowned);
    var worker: BlockedWorker = .{ .registration = try registry.registration(work_handle) };
    worker.registration.thread = try std.Thread.spawn(.{}, BlockedWorker.run, .{&worker});
    while (!worker.running.load(.acquire)) std.Thread.yield() catch {};

    // The worker is parked and cannot finish on its own.
    try std.testing.expect(!worker.registration.isFinished());
    try std.testing.expect(!worker.teardown_completed.load(.acquire));

    registry.drain();

    try std.testing.expect(worker.teardown_completed.load(.acquire));
    try std.testing.expectEqual(@as(u64, BlockedWorker.teardown_steps), worker.counter);
    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "completing one registration joins only that worker" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const first = try registry.begin(unowned);
    const second = try registry.begin(unowned);
    var worker: BlockedWorker = .{ .registration = try registry.registration(first) };
    worker.registration.thread = try std.Thread.spawn(.{}, BlockedWorker.run, .{&worker});
    while (!worker.running.load(.acquire)) std.Thread.yield() catch {};

    try registry.complete(first);
    try std.testing.expect(worker.teardown_completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expect(!try registry.cancellationRequested(second));

    (try registry.registration(second)).finish();
    registry.drain();
}
