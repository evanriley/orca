const std = @import("std");
const job = @import("job.zig");
const object = @import("object.zig");
const queue = @import("queue.zig");

pub const RequestId = u64;

pub const Action = union(enum) {
    create_library,
    create_player,
    create_zone,
    start_job: struct {
        kind: job.Kind,
        total_units: ?u64,
    },
    cancel_job: object.JobHandle,
};

pub const Command = struct {
    request_id: RequestId,
    action: Action,
};

pub const Failure = enum {
    runtime_not_running,
    stale_handle,
    out_of_memory,
    invalid_transition,
    internal,
};

pub const Outcome = union(enum) {
    library_created: object.LibraryHandle,
    player_created: object.PlayerHandle,
    zone_created: object.ZoneHandle,
    job_started: object.JobHandle,
    job_cancellation_requested: object.JobHandle,
    failed: Failure,
};

pub const Event = struct {
    request_id: RequestId,
    outcome: Outcome,
};

pub const Telemetry = union(enum) {
    player_position: struct {
        player: object.PlayerHandle,
        frames: u64,
    },
    job_progress: struct {
        job: object.JobHandle,
        completed_units: u64,
        total_units: ?u64,
    },

    fn hasSameKey(a: Telemetry, b: Telemetry) bool {
        return switch (a) {
            .player_position => |left| switch (b) {
                .player_position => |right| left.player.eql(right.player),
                else => false,
            },
            .job_progress => |left| switch (b) {
                .job_progress => |right| left.job.eql(right.job),
                else => false,
            },
        };
    }
};

pub const CommandQueue = struct {
    queue: queue.BoundedQueue(Command, 256) = .{},
    next_request_id: std.atomic.Value(RequestId) = .init(1),

    pub fn submit(self: *CommandQueue, action: Action) queue.Error!RequestId {
        const request_id = self.next_request_id.fetchAdd(1, .monotonic);
        try self.queue.push(.{ .request_id = request_id, .action = action });
        return request_id;
    }

    pub fn pop(self: *CommandQueue) ?Command {
        return self.queue.pop();
    }
};

/// Completion events are lossless and bounded. The control executor applies
/// backpressure before handling another command when this channel is full.
pub const EventChannel = struct {
    queue: queue.BoundedQueue(Event, 256) = .{},

    pub fn publish(self: *EventChannel, event: Event) queue.Error!void {
        try self.queue.push(event);
    }

    pub fn poll(self: *EventChannel) ?Event {
        return self.queue.pop();
    }

    pub fn hasCapacity(self: *EventChannel) bool {
        return self.queue.count() < 256;
    }
};

/// High-frequency state hints are coalesced by object. Authoritative callers
/// use snapshots; a slow consumer sees the latest unread hint without growth.
pub const TelemetryChannel = struct {
    queue: queue.BoundedQueue(Telemetry, 256) = .{},

    pub fn publish(self: *TelemetryChannel, telemetry: Telemetry) queue.Error!void {
        try self.queue.pushCoalescing(telemetry, Telemetry.hasSameKey);
    }

    pub fn poll(self: *TelemetryChannel) ?Telemetry {
        return self.queue.pop();
    }
};

test "position telemetry is coalesced for slow consumers" {
    var channel: TelemetryChannel = .{};
    const player = object.PlayerHandle{ .index = 2, .generation = 1 };
    for (0..1000) |frame| {
        try channel.publish(.{ .player_position = .{
            .player = player,
            .frames = frame,
        } });
    }

    const latest = channel.poll() orelse return error.MissingTelemetry;
    try std.testing.expect(channel.poll() == null);
    switch (latest) {
        .player_position => |position| try std.testing.expectEqual(
            @as(u64, 999),
            position.frames,
        ),
        else => return error.UnexpectedTelemetry,
    }
}
