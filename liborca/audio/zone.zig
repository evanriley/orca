pub const RenderPolicy = union(enum) {
    robust,
    interactive,
    custom: struct { target_frames: u32 },
};

pub const RenderStrategy = union(enum) {
    /// Source PCM remains prepared, while player/zone processing runs as close
    /// to the device callback as the bounded one-block handoff permits.
    direct_rt,
    /// Producer processing may run ahead by this bounded number of frames.
    buffered: struct { target_frames: u32 },

    pub fn blockBudget(self: RenderStrategy, frames_per_block: u32, capacity: usize) usize {
        if (frames_per_block == 0 or capacity == 0) return 0;
        return switch (self) {
            .direct_rt => 1,
            .buffered => |buffered| @min(
                capacity,
                @max(1, (@as(usize, buffered.target_frames) + frames_per_block - 1) /
                    frames_per_block),
            ),
        };
    }
};

pub fn strategyForPolicy(policy: RenderPolicy) RenderStrategy {
    return switch (policy) {
        .interactive => .direct_rt,
        .robust => .{ .buffered = .{ .target_frames = 1024 } },
        .custom => |custom| .{ .buffered = .{ .target_frames = custom.target_frames } },
    };
}

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
    graph_rate_hz: ?u32,

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

    pub fn renderStrategy(self: *const Zone) RenderStrategy {
        return strategyForPolicy(self.policy);
    }

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
        .graph_rate_hz = null,
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

test "latency policies select strategies within the same Zone abstraction" {
    const testing = @import("std").testing;
    try testing.expectEqual(RenderStrategy.direct_rt, strategyForPolicy(.interactive));
    try testing.expectEqual(
        @as(u32, 1024),
        strategyForPolicy(.robust).buffered.target_frames,
    );
    try testing.expectEqual(
        @as(u32, 384),
        strategyForPolicy(.{ .custom = .{ .target_frames = 384 } }).buffered.target_frames,
    );
    try testing.expectEqual(@as(usize, 1), strategyForPolicy(.interactive).blockBudget(256, 8));
    try testing.expectEqual(@as(usize, 4), strategyForPolicy(.robust).blockBudget(256, 8));
}
