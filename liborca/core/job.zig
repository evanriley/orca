const std = @import("std");
const handle = @import("handle.zig");
const object = @import("object.zig");

pub const Kind = enum {
    scan,
    /// Turning observed files into artists, releases and tracks. A pass of its
    /// own, because a metadata edit reprojects without walking a filesystem.
    projection,
    analysis,
    conversion,
    ripping,
    metadata_lookup,
    artwork,
    mutation,
    dummy,
};

pub const State = enum {
    queued,
    running,
    cancelling,
    cancelled,
    succeeded,
    failed,
};

pub const Snapshot = struct {
    kind: Kind,
    state: State,
    completed_units: u64,
    total_units: ?u64,
};

const Job = struct {
    snapshot: Snapshot,
};

pub const Manager = struct {
    jobs: handle.Pool(Job, object.JobTag),

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{ .jobs = .init(allocator) };
    }

    pub fn deinit(self: *Manager) void {
        self.jobs.deinit();
        self.* = undefined;
    }

    pub fn create(self: *Manager, kind: Kind, total_units: ?u64) !object.JobHandle {
        return self.jobs.insert(.{ .snapshot = .{
            .kind = kind,
            .state = .queued,
            .completed_units = 0,
            .total_units = total_units,
        } });
    }

    pub fn start(self: *Manager, job_handle: object.JobHandle) !void {
        const job = try self.jobs.get(job_handle);
        if (job.snapshot.state != .queued) return error.InvalidJobTransition;
        job.snapshot.state = .running;
    }

    pub fn update(self: *Manager, job_handle: object.JobHandle, completed_units: u64) !void {
        const job = try self.jobs.get(job_handle);
        if (job.snapshot.state != .running) return error.InvalidJobTransition;
        if (job.snapshot.total_units) |total| {
            if (completed_units > total) return error.InvalidProgress;
        }
        job.snapshot.completed_units = completed_units;
    }

    /// Records progress from a worker that may already have been asked to
    /// cancel: a cancelling job is still doing work until its worker returns,
    /// and refusing its last progress report would make the snapshot lie.
    pub fn observeProgress(
        self: *Manager,
        job_handle: object.JobHandle,
        completed_units: u64,
    ) !void {
        const job = try self.jobs.get(job_handle);
        switch (job.snapshot.state) {
            .running, .cancelling => job.snapshot.completed_units = completed_units,
            else => return error.InvalidJobTransition,
        }
    }

    /// Terminal transition, recorded once the worker behind the job has been
    /// joined. Only the control lane may call it, and only with a terminal
    /// state.
    pub fn finish(
        self: *Manager,
        job_handle: object.JobHandle,
        state: State,
    ) !void {
        switch (state) {
            .cancelled, .succeeded, .failed => {},
            else => return error.InvalidJobTransition,
        }
        const job = try self.jobs.get(job_handle);
        switch (job.snapshot.state) {
            .queued, .running, .cancelling => job.snapshot.state = state,
            else => return error.JobAlreadyFinished,
        }
    }

    pub fn requestCancellation(self: *Manager, job_handle: object.JobHandle) !void {
        const job = try self.jobs.get(job_handle);
        switch (job.snapshot.state) {
            .queued, .running => job.snapshot.state = .cancelling,
            .cancelling, .cancelled => {},
            .succeeded, .failed => return error.JobAlreadyFinished,
        }
    }

    pub fn snapshot(self: *const Manager, job_handle: object.JobHandle) !Snapshot {
        return (try self.jobs.getConst(job_handle)).snapshot;
    }

    pub fn cancelAndDrain(self: *Manager) void {
        for (self.jobs.slots.items) |*slot| {
            if (slot.value) |*job| switch (job.snapshot.state) {
                .queued, .running, .cancelling => job.snapshot.state = .cancelled,
                else => {},
            };
        }
        self.jobs.discardAll();
    }
};

test "jobs expose progress and cooperative cancellation" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job_handle = try manager.create(.analysis, 100);
    try manager.start(job_handle);
    try manager.update(job_handle, 25);
    try manager.requestCancellation(job_handle);

    const current = try manager.snapshot(job_handle);
    try std.testing.expectEqual(State.cancelling, current.state);
    try std.testing.expectEqual(@as(u64, 25), current.completed_units);
    manager.cancelAndDrain();
    try std.testing.expectError(error.StaleHandle, manager.snapshot(job_handle));
}
