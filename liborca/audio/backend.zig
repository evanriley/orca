const pcm = @import("pcm.zig");
const zone = @import("zone.zig");

pub const DeviceKind = enum(u8) { unknown, usb, pci, bluetooth, hdmi, virtual };

pub const DeviceState = enum(u8) { active, suspended, unavailable };

pub const DeviceCapabilities = struct {
    rate_min: u32,
    rate_max: u32,
    bit_depths: u8,
    channels_max: u8,
    state: DeviceState,
    bus: DeviceKind,

    pub const bit_depth_16: u8 = 1;
    pub const bit_depth_24: u8 = 2;
    pub const bit_depth_32: u8 = 4;
};

pub const DeviceSampleFormat = enum(u8) {
    signed_16,
    signed_24,
    signed_24_32,
    signed_32,
    float_32,

    pub fn bitsPerSample(self: DeviceSampleFormat) u8 {
        return switch (self) {
            .signed_16 => 16,
            .signed_24, .signed_24_32 => 24,
            .signed_32, .float_32 => 32,
        };
    }
};

pub const DeviceFormat = struct {
    sample_format: DeviceSampleFormat,
    sample_rate: u32,
    channels: u16,
};

pub const DiscoveryDetail = enum { identity, capabilities };

pub const Device = struct {
    id: u64,
    name: [256]u8,
    name_len: u16,
    kind: DeviceKind = .unknown,
    capabilities: ?DeviceCapabilities = null,

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
    device_format: ?DeviceFormat = null,
};

/// Platform implementations own discovery and stream lifecycle. Audio callback
/// data is supplied by the RT-safe render path, never by this control contract.
pub const Interface = struct {
    context: *anyopaque,
    discover: *const fn (*anyopaque, []Device) anyerror!usize,
};
