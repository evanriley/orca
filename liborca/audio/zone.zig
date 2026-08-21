pub const RenderPolicy = union(enum) {
    robust,
    interactive,
    custom: struct { target_frames: u32 },
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
};
