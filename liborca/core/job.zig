const std = @import("std");
const handle = @import("handle.zig");
const object = @import("object.zig");

pub const Kind = enum {
    scan,
    /// A scan of a root, or of some directories under it, that also names
    /// what those walks no longer found.
    reconcile,
    /// Turning observed files into artists, releases and tracks. A pass of its
    /// own, because a metadata edit reprojects without walking a filesystem.
    projection,
    /// Re-reading the headers of files whose declared audio properties are
    /// missing. Neither a walk nor a resolution: a repair keyed on `files.id`.
    property_backfill,
    analysis,
    /// Finding the audio a Library holds more than once. Separate from the
    /// analysis it depends on, because comparing measurements is seconds of
    /// work over an index while taking them is hours of decoding.
    duplicate_scan,
    conversion,
    ripping,
    metadata_lookup,
    /// Sending fingerprints to AcoustID for recording IDs a person chose.
    acoustid_submission,
    artwork,
    mutation,
    /// Reading one Track's lyrics.
    lyrics,
    /// Fetching one Artist's photo, biography, years active and links.
    artist_info,
    /// Fetching Releases' descriptions, or filling their Tracks' genres from
    /// MusicBrainz.
    release_info,
    /// Finding where a Release's tracks disagree about its metadata.
    consistency,
    /// Making the day's Daily Mixes.
    daily_mixes,
    dummy,
};

pub const State = enum {
    queued,
    running,
    cancelling,
    cancelled,
    succeeded,
    failed,
    paused,
    waiting,
};

pub fn BoundedText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: std.math.IntFittingRange(0, capacity) = 0,

        const Self = @This();

        pub fn init(text: []const u8) Self {
            var result: Self = .{};
            result.set(text);
            return result;
        }

        pub fn set(self: *Self, text: []const u8) void {
            const length = utf8Prefix(text, capacity);
            @memcpy(self.bytes[0..length], text[0..length]);
            self.len = @intCast(length);
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub fn utf8Prefix(text: []const u8, capacity: usize) usize {
    var length = @min(text.len, capacity);
    while (length > 0 and length < text.len and (text[length] & 0xC0) == 0x80) length -= 1;
    return length;
}

pub const Snapshot = struct {
    kind: Kind,
    state: State,
    completed_units: u64,
    total_units: ?u64,
    /// Unix seconds; null until the Job leaves the waiting queue.
    started_at: ?i64 = null,
    paused: bool = false,
    estimated_remaining_ms: ?u64 = null,
    current_item: BoundedText(512) = .{},
    detail: BoundedText(128) = .{},
};

const RateWindow = struct {
    samples: [capacity]Sample = undefined,
    len: usize = 0,

    const capacity = 32;
    const window_ms = 10_000;
    const spacing_ms = 500;

    const Sample = struct {
        at_ms: i64,
        completed_units: u64,
    };

    fn record(self: *RateWindow, at_ms: i64, completed_units: u64) void {
        if (self.len > 0) {
            const last = self.samples[self.len - 1];
            if (completed_units < last.completed_units or at_ms < last.at_ms) {
                self.len = 0;
            } else if (at_ms - last.at_ms < spacing_ms) return;
        }
        while (self.len >= 2 and at_ms - self.samples[1].at_ms >= window_ms) self.dropOldest();
        if (self.len == capacity) self.dropOldest();
        self.samples[self.len] = .{ .at_ms = at_ms, .completed_units = completed_units };
        self.len += 1;
    }

    fn dropOldest(self: *RateWindow) void {
        std.mem.copyForwards(Sample, self.samples[0 .. self.len - 1], self.samples[1..self.len]);
        self.len -= 1;
    }

    fn remainingMs(self: *const RateWindow, total_units: ?u64) ?u64 {
        const total = total_units orelse return null;
        if (self.len < 2) return null;
        const first = self.samples[0];
        const last = self.samples[self.len - 1];
        const elapsed_ms: u64 = @intCast(last.at_ms - first.at_ms);
        if (elapsed_ms < window_ms) return null;
        if (last.completed_units >= total) return 0;
        const done = last.completed_units - first.completed_units;
        if (done == 0) return null;
        const remaining: u128 = total - last.completed_units;
        return @intCast(@min(remaining * elapsed_ms / done, std.math.maxInt(u64)));
    }
};

const Job = struct {
    snapshot: Snapshot,
    rate: RateWindow = .{},
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

    pub fn wait(self: *Manager, job_handle: object.JobHandle) !void {
        const job = try self.jobs.get(job_handle);
        if (job.snapshot.state != .queued) return error.InvalidJobTransition;
        job.snapshot.state = .waiting;
    }

    pub fn replan(self: *Manager, job_handle: object.JobHandle, total_units: ?u64) !void {
        const job = try self.jobs.get(job_handle);
        if (job.snapshot.state != .waiting) return error.InvalidJobTransition;
        job.snapshot.total_units = total_units;
    }

    pub fn start(self: *Manager, job_handle: object.JobHandle, started_at: i64) !void {
        const job = try self.jobs.get(job_handle);
        switch (job.snapshot.state) {
            .queued, .waiting => {},
            else => return error.InvalidJobTransition,
        }
        job.snapshot.state = .running;
        job.snapshot.started_at = started_at;
    }

    pub fn pause(self: *Manager, job_handle: object.JobHandle) !void {
        const job = try self.jobs.get(job_handle);
        switch (job.snapshot.state) {
            .running => {
                job.snapshot.state = .paused;
                job.snapshot.paused = true;
                job.snapshot.estimated_remaining_ms = null;
                job.rate = .{};
            },
            .paused => {},
            .cancelled, .succeeded, .failed => return error.JobAlreadyFinished,
            .queued, .waiting, .cancelling => return error.InvalidJobTransition,
        }
    }

    pub fn unpause(self: *Manager, job_handle: object.JobHandle) !void {
        const job = try self.jobs.get(job_handle);
        switch (job.snapshot.state) {
            .paused => {
                job.snapshot.state = .running;
                job.snapshot.paused = false;
                job.rate = .{};
            },
            .running => {},
            .cancelled, .succeeded, .failed => return error.JobAlreadyFinished,
            .queued, .waiting, .cancelling => return error.InvalidJobTransition,
        }
    }

    pub fn sampleProgress(self: *Manager, job_handle: object.JobHandle, monotonic_ms: i64) !void {
        const job = try self.jobs.get(job_handle);
        if (job.snapshot.state != .running) {
            job.snapshot.estimated_remaining_ms = null;
            return;
        }
        job.rate.record(monotonic_ms, job.snapshot.completed_units);
        job.snapshot.estimated_remaining_ms = job.rate.remainingMs(job.snapshot.total_units);
    }

    pub fn setPausedWhileWaiting(self: *Manager, job_handle: object.JobHandle, paused: bool) !void {
        const job = try self.jobs.get(job_handle);
        if (job.snapshot.state != .waiting) return error.InvalidJobTransition;
        job.snapshot.paused = paused;
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
            .running, .cancelling, .paused => job.snapshot.completed_units = completed_units,
            else => return error.InvalidJobTransition,
        }
    }

    pub fn observeTotal(self: *Manager, job_handle: object.JobHandle, total_units: u64) !void {
        const job = try self.jobs.get(job_handle);
        switch (job.snapshot.state) {
            .running, .cancelling, .paused => job.snapshot.total_units = total_units,
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
            .queued, .waiting, .running, .paused, .cancelling => {
                job.snapshot.state = state;
                job.snapshot.paused = false;
                job.snapshot.estimated_remaining_ms = null;
            },
            else => return error.JobAlreadyFinished,
        }
    }

    pub fn requestCancellation(self: *Manager, job_handle: object.JobHandle) !void {
        const job = try self.jobs.get(job_handle);
        switch (job.snapshot.state) {
            .queued, .waiting, .running, .paused => {
                job.snapshot.state = .cancelling;
                job.snapshot.paused = false;
                job.snapshot.estimated_remaining_ms = null;
            },
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
                .queued, .waiting, .running, .paused, .cancelling => job.snapshot.state = .cancelled,
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
    try manager.start(job_handle, 0);
    try manager.update(job_handle, 25);
    try manager.requestCancellation(job_handle);

    const current = try manager.snapshot(job_handle);
    try std.testing.expectEqual(State.cancelling, current.state);
    try std.testing.expectEqual(@as(u64, 25), current.completed_units);
    manager.cancelAndDrain();
    try std.testing.expectError(error.StaleHandle, manager.snapshot(job_handle));
}

test "the estimate stays null until ten seconds of progress and then follows the rolling rate" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job_handle = try manager.create(.analysis, 1000);
    try manager.start(job_handle, 0);
    var now_ms: i64 = 0;
    var completed: u64 = 0;
    while (now_ms < 10_000) : (now_ms += 100) {
        try manager.observeProgress(job_handle, completed);
        try manager.sampleProgress(job_handle, now_ms);
        try std.testing.expectEqual(@as(?u64, null), (try manager.snapshot(job_handle)).estimated_remaining_ms);
        completed += 1;
    }
    try manager.observeProgress(job_handle, completed);
    try manager.sampleProgress(job_handle, now_ms);
    try std.testing.expectEqual(@as(?u64, 90_000), (try manager.snapshot(job_handle)).estimated_remaining_ms);

    try manager.pause(job_handle);
    const paused = try manager.snapshot(job_handle);
    try std.testing.expectEqual(State.paused, paused.state);
    try std.testing.expect(paused.paused);
    try std.testing.expectEqual(@as(?u64, null), paused.estimated_remaining_ms);
    try manager.unpause(job_handle);
    try manager.sampleProgress(job_handle, now_ms + 5_000);
    try std.testing.expectEqual(@as(?u64, null), (try manager.snapshot(job_handle)).estimated_remaining_ms);
}

test "waiting jobs start, cancel and finish but never pause" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    const job_handle = try manager.create(.scan, null);
    try manager.wait(job_handle);
    try std.testing.expectError(error.InvalidJobTransition, manager.pause(job_handle));
    try manager.replan(job_handle, 12);
    try manager.start(job_handle, 1_700_000_000);
    const started = try manager.snapshot(job_handle);
    try std.testing.expectEqual(State.running, started.state);
    try std.testing.expectEqual(@as(?u64, 12), started.total_units);
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), started.started_at);

    const waiting = try manager.create(.scan, null);
    try manager.wait(waiting);
    try manager.requestCancellation(waiting);
    try manager.finish(waiting, .cancelled);
    try std.testing.expectEqual(State.cancelled, (try manager.snapshot(waiting)).state);
}

test "bounded text keeps whole UTF-8 sequences" {
    const Text = BoundedText(4);
    try std.testing.expectEqualStrings("ab\u{e9}", Text.init("ab\u{e9}t").slice());
    try std.testing.expectEqualStrings("abc", Text.init("abc\u{e9}").slice());
}
