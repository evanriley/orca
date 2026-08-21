const pcm = @import("pcm.zig");
const zone = @import("zone.zig");

pub const Device = struct {
    id: u64,
    name: []const u8,
    is_default: bool,
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

/// Platform implementations own discovery and stream lifecycle. Audio callback
/// data is supplied by the RT-safe render path, never by this control contract.
pub const Interface = struct {
    context: *anyopaque,
    discover: *const fn (*anyopaque, []Device) anyerror!usize,
};
