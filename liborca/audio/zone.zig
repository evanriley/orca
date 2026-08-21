pub const RenderPolicy = union(enum) {
    robust,
    interactive,
    custom: struct { target_frames: u32 },
};

pub const OutputState = enum(u8) {
    closed,
    opening,
    active,
    lost,
    recovering,
    failed,
};

pub const Latency = struct {
    requested_frames: u32,
    backend_quantum_frames: u32,
    render_ahead_frames: u32,
    dsp_frames: u32,
    hardware_frames: ?u32,

    pub fn knownTotalFrames(self: Latency) u64 {
        return @as(u64, self.render_ahead_frames) +
            self.dsp_frames +
            (self.hardware_frames orelse 0);
    }
};

pub const Zone = struct {
    policy: RenderPolicy,
    latency: Latency,
    device_id: u64 = 0,
    output_state: OutputState = .closed,
    recovery_attempts: u32 = 0,

    pub fn beginOpen(self: *Zone, device_id: u64) void {
        self.device_id = device_id;
        self.output_state = .opening;
    }

    pub fn opened(self: *Zone, latency: Latency) void {
        self.latency = latency;
        self.output_state = .active;
        self.recovery_attempts = 0;
    }

    pub fn deviceLost(self: *Zone) void {
        if (self.output_state == .closed) return;
        self.output_state = .lost;
    }

    pub fn beginRecovery(self: *Zone) void {
        if (self.output_state != .lost and self.output_state != .failed) return;
        self.output_state = .recovering;
        self.recovery_attempts +|= 1;
    }

    pub fn recoveryFailed(self: *Zone) void {
        if (self.output_state == .recovering) self.output_state = .failed;
    }

    pub fn close(self: *Zone) void {
        self.output_state = .closed;
    }
};

test "Zone device recovery is isolated state" {
    const empty_latency: Latency = .{
        .requested_frames = 0,
        .backend_quantum_frames = 0,
        .render_ahead_frames = 0,
        .dsp_frames = 0,
        .hardware_frames = null,
    };
    var healthy: Zone = .{ .policy = .robust, .latency = empty_latency };
    var failed: Zone = .{ .policy = .interactive, .latency = empty_latency };
    healthy.beginOpen(1);
    healthy.opened(empty_latency);
    failed.beginOpen(2);
    failed.opened(empty_latency);
    failed.deviceLost();
    failed.beginRecovery();
    failed.recoveryFailed();
    try @import("std").testing.expectEqual(OutputState.active, healthy.output_state);
    try @import("std").testing.expectEqual(OutputState.failed, failed.output_state);
    try @import("std").testing.expectEqual(@as(u32, 1), failed.recovery_attempts);
}
