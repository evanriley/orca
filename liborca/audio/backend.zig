const pcm = @import("pcm.zig");
const zone = @import("zone.zig");

pub const Device = struct {
    id: u64,
    name: [256]u8,
    name_len: u16,

    pub fn nameSlice(self: *const Device) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const OpenRequest = struct {
    device_id: u64,
    format: pcm.Format,
    policy: zone.RenderPolicy,
    requested_latency_frames: u32,
};

pub const NegotiatedOutput = struct {
    format: pcm.Format,
    backend_quantum_frames: u32,
    achieved_latency_frames: u32,
};

pub const TimingSnapshot = struct {
    sample_time: u64,
    monotonic_ns: i64,
    device_delay_frames: ?u64,
    queued_frames: u64,
    buffered_frames: u64,
    backend_quantum_frames: u32,
    graph_rate_hz: ?u32,
};

/// Platform implementations own discovery and stream lifecycle. Audio callback
/// data is supplied by the RT-safe render path, never by this control contract.
pub const Interface = struct {
    context: *anyopaque,
    discover: *const fn (*anyopaque, []Device) anyerror!usize,
};
