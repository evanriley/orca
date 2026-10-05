const std = @import("std");
const work = @import("../../core/work.zig");
const contract = @import("../backend.zig");
const buffer = @import("../buffer.zig");
const pcm = @import("../pcm.zig");
const output = @import("../output.zig");
const render_pipe = @import("../render.zig");
const zone = @import("../zone.zig");
const network = @import("../../network/root.zig");

extern fn orca_pw_library_version() [*:0]const u8;
extern fn orca_pw_initialize() void;
extern fn orca_pw_deinitialize() void;
const NativeDevice = extern struct {
    id: u64,
    name_len: u16,
    name: [256]u8,
    kind: u8,
    has_capabilities: u8 = 0,
    state: u8 = 0,
    bit_depths: u8 = 0,
    channels_max: u8 = 0,
    rate_min: u32 = 0,
    rate_max: u32 = 0,
};
const NativeDiscovery = opaque {};
extern fn orca_pw_discovery_begin([*]NativeDevice, u32, u8, *?*NativeDiscovery) c_int;
extern fn orca_pw_discovery_iterate(*NativeDiscovery, c_int) c_int;
extern fn orca_pw_discovery_finish(*NativeDiscovery) u32;
pub const RenderFn = *const fn (?*anyopaque, [*]f32, u32, u32) callconv(.c) void;
extern fn orca_pw_output_create(u64, u32, u32, u32, RenderFn, ?*anyopaque) ?*anyopaque;
extern fn orca_pw_output_destroy(?*anyopaque) void;
const NativeTiming = extern struct {
    sample_time: u64,
    monotonic_ns: i64,
    device_delay_frames: i64,
    queued_frames: u64,
    buffered_frames: u64,
    quantum_frames: u32,
    graph_rate: u32,
    device_rate: u32,
    device_channels: u16,
    device_format: u8,
    reserved: u8,
};
extern fn orca_pw_output_timing(?*anyopaque, *NativeTiming) c_int;
extern fn orca_pw_output_status(?*anyopaque) c_int;
const WakeFn = *const fn (*anyopaque) callconv(.c) void;
extern fn orca_pw_output_set_waker(?*anyopaque, ?WakeFn, ?*anyopaque) void;
extern fn orca_pw_fill(?RenderFn, ?*anyopaque, [*]f32, u32, u32) void;

/// Process-level PipeWire client library lifetime. Server connections and
/// streams are deliberately separate OutputSession resources.
pub const Backend = struct {
    initialized: bool = false,

    pub fn init(self: *Backend) void {
        if (self.initialized) return;
        orca_pw_initialize();
        self.initialized = true;
    }

    pub fn deinit(self: *Backend) void {
        if (!self.initialized) return;
        orca_pw_deinitialize();
        self.initialized = false;
    }

    pub fn libraryVersion() []const u8 {
        return std.mem.span(orca_pw_library_version());
    }

    pub fn discover(
        _: *Backend,
        devices: []contract.Device,
        detail: contract.DiscoveryDetail,
    ) !usize {
        var native: [64]NativeDevice = undefined;
        const limit = @min(devices.len, native.len);
        var handle: ?*NativeDiscovery = null;
        const with_capabilities = @intFromBool(detail == .capabilities);
        if (orca_pw_discovery_begin(&native, @intCast(limit), with_capabilities, &handle) < 0)
            return error.PipeWireDiscoveryFailed;
        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        var system_clock: network.SystemClock = .{ .io = threaded.io() };
        return collect(nativeDiscovery(handle.?), system_clock.clock(), &native, devices);
    }
};

const capability_bound_ms = 500;

const DiscoveryPhase = enum(c_int) { listing = 0, capabilities = 1, complete = 2 };

const Discovery = struct {
    context: *anyopaque,
    iterate_fn: *const fn (*anyopaque, timeout_ms: i32) anyerror!DiscoveryPhase,
    finish_fn: *const fn (*anyopaque) u32,
};

fn nativeDiscovery(handle: *NativeDiscovery) Discovery {
    return .{ .context = handle, .iterate_fn = iterateNative, .finish_fn = finishNative };
}

fn iterateNative(context: *anyopaque, timeout_ms: i32) anyerror!DiscoveryPhase {
    const result = orca_pw_discovery_iterate(@ptrCast(context), timeout_ms);
    if (result < 0) return error.PipeWireDiscoveryFailed;
    return std.enums.fromInt(DiscoveryPhase, result) orelse error.PipeWireDiscoveryFailed;
}

fn finishNative(context: *anyopaque) u32 {
    return orca_pw_discovery_finish(@ptrCast(context));
}

fn collect(
    discovery: Discovery,
    clock: network.client.Clock,
    native: []const NativeDevice,
    devices: []contract.Device,
) !usize {
    const awaited = awaitReplies(discovery, clock);
    const count = discovery.finish_fn(discovery.context);
    awaited catch return error.PipeWireDiscoveryFailed;
    for (native[0..count], devices[0..count]) |source, *destination|
        destination.* = deviceFrom(source);
    return count;
}

fn awaitReplies(discovery: Discovery, clock: network.client.Clock) !void {
    var phase: DiscoveryPhase = .listing;
    while (phase == .listing) phase = try discovery.iterate_fn(discovery.context, -1);
    const deadline = clock.nowMs() + capability_bound_ms;
    while (phase == .capabilities) {
        const remaining = deadline - clock.nowMs();
        if (remaining <= 0) return;
        phase = try discovery.iterate_fn(discovery.context, @intCast(remaining));
    }
}

fn deviceFrom(source: NativeDevice) contract.Device {
    const kind = std.enums.fromInt(contract.DeviceKind, source.kind) orelse .unknown;
    return .{
        .id = source.id,
        .name = source.name,
        .name_len = source.name_len,
        .kind = kind,
        .capabilities = if (source.has_capabilities != 0) .{
            .rate_min = source.rate_min,
            .rate_max = source.rate_max,
            .bit_depths = source.bit_depths,
            .channels_max = source.channels_max,
            .state = std.enums.fromInt(contract.DeviceState, source.state) orelse .unavailable,
            .bus = kind,
        } else null,
    };
}

/// Owns one autoconnected float32 PipeWire playback stream. The render
/// function is called directly on PipeWire's real-time process thread.
pub const OutputSession = struct {
    native: *anyopaque,
    format: pcm.Format,
    requested_latency_frames: u32,

    pub const Status = enum(c_int) { connecting = 0, active = 1, lost = 2 };

    pub fn open(
        request: contract.OpenRequest,
        render: RenderFn,
        userdata: ?*anyopaque,
    ) !OutputSession {
        try request.format.validate();
        if (request.format.sample_format != .float_32 or
            request.format.bits_per_sample != 32 or
            request.format.bytes_per_frame != request.format.channels * 4)
            return error.UnsupportedOutputFormat;
        const native = orca_pw_output_create(
            request.device_id,
            request.format.sample_rate,
            request.format.channels,
            requestedLatency(request),
            render,
            userdata,
        ) orelse
            return error.PipeWireOutputUnavailable;
        return .{
            .native = native,
            .format = request.format,
            .requested_latency_frames = requestedLatency(request),
        };
    }

    pub fn close(self: *OutputSession) void {
        orca_pw_output_destroy(self.native);
        self.* = undefined;
    }

    pub fn timing(self: *const OutputSession) !contract.TimingSnapshot {
        var native: NativeTiming = undefined;
        if (orca_pw_output_timing(self.native, &native) < 0)
            return error.PipeWireTimingUnavailable;
        return .{
            .sample_time = native.sample_time,
            .monotonic_ns = native.monotonic_ns,
            .device_delay_frames = if (native.device_delay_frames >= 0)
                @intCast(native.device_delay_frames)
            else
                null,
            .queued_frames = native.queued_frames,
            .buffered_frames = native.buffered_frames,
            .backend_quantum_frames = native.quantum_frames,
            .graph_rate_hz = if (native.graph_rate != 0) native.graph_rate else null,
            .device_format = deviceFormatFrom(&native),
        };
    }

    pub fn status(self: *const OutputSession) Status {
        return @fromBackingInt(@intCast(@as(std.meta.Tag(Status), @intCast(orca_pw_output_status(self.native)))));
    }

    pub fn setStateWaker(self: *const OutputSession, waker: ?work.Waker) void {
        if (waker) |value|
            orca_pw_output_set_waker(self.native, value.wake_fn, value.context)
        else
            orca_pw_output_set_waker(self.native, null, null);
    }

    pub fn latency(
        self: *const OutputSession,
        render_ahead_frames: u32,
        dsp_frames: u32,
    ) !zone.Latency {
        const current = try self.timing();
        return .{
            .requested_frames = self.requested_latency_frames,
            .backend_quantum_frames = current.backend_quantum_frames,
            .render_ahead_frames = render_ahead_frames,
            .dsp_frames = dsp_frames,
            .hardware_frames = if (current.device_delay_frames) |frames|
                std.math.cast(u32, frames)
            else
                null,
            .graph_rate_hz = current.graph_rate_hz,
            .device_format = current.device_format,
        };
    }
};

fn deviceFormatFrom(native: *const NativeTiming) ?contract.DeviceFormat {
    const sample_format: contract.DeviceSampleFormat = switch (native.device_format) {
        1 => .signed_16,
        2 => .signed_24,
        3 => .signed_24_32,
        4 => .signed_32,
        5 => .float_32,
        else => return null,
    };
    if (native.device_rate == 0 or native.device_channels == 0) return null;
    return .{
        .sample_format = sample_format,
        .sample_rate = native.device_rate,
        .channels = native.device_channels,
    };
}

fn requestedLatency(request: contract.OpenRequest) u32 {
    if (request.requested_latency_frames != 0)
        return request.requested_latency_frames;
    return switch (request.policy) {
        .robust => 1024,
        .interactive => 128,
        .custom => |custom| custom.target_frames,
    };
}

/// The render context is deliberately backend-neutral and Zone-owned; see
/// `audio/render.zig`. PipeWire only supplies the C entry point signature.
pub const RenderContext = render_pipe.RenderContext;

const OwnedSession = struct {
    allocator: std.mem.Allocator,
    session: OutputSession,
};

/// Adapts the PipeWire backend to the backend-neutral `output.Factory` the
/// engine drives. Native stream lifetime never leaves this file.
pub const OutputFactory = struct {
    allocator: std.mem.Allocator,
    backend: *Backend,

    pub fn factory(self: *OutputFactory) output.Factory {
        return .{ .context = self, .vtable = &factory_vtable };
    }

    const factory_vtable: output.Factory.VTable = .{ .open = open, .discover = discover };
    const output_vtable: output.Output.VTable = .{
        .close = closeOutput,
        .status = outputStatus,
        .latency = outputLatency,
        .timing = outputTiming,
        .set_state_waker = setOutputStateWaker,
    };

    fn open(
        context: ?*anyopaque,
        request: contract.OpenRequest,
        render: output.RenderFn,
        userdata: ?*anyopaque,
    ) anyerror!output.Output {
        const self: *OutputFactory = @ptrCast(@alignCast(context.?));
        self.backend.init();
        const owned = try self.allocator.create(OwnedSession);
        errdefer self.allocator.destroy(owned);
        owned.* = .{
            .allocator = self.allocator,
            .session = try OutputSession.open(request, render, userdata),
        };
        return .{ .context = owned, .vtable = &output_vtable };
    }

    fn discover(
        context: ?*anyopaque,
        devices: []contract.Device,
        detail: contract.DiscoveryDetail,
    ) anyerror!usize {
        const self: *OutputFactory = @ptrCast(@alignCast(context.?));
        self.backend.init();
        return self.backend.discover(devices, detail);
    }

    fn closeOutput(context: ?*anyopaque) void {
        const owned: *OwnedSession = @ptrCast(@alignCast(context.?));
        const allocator = owned.allocator;
        owned.session.close();
        allocator.destroy(owned);
    }

    fn outputStatus(context: ?*anyopaque) output.Status {
        const owned: *OwnedSession = @ptrCast(@alignCast(context.?));
        return switch (owned.session.status()) {
            .connecting => .connecting,
            .active => .active,
            .lost => .lost,
        };
    }

    fn outputLatency(
        context: ?*anyopaque,
        render_ahead_frames: u32,
        dsp_frames: u32,
    ) anyerror!zone.Latency {
        const owned: *OwnedSession = @ptrCast(@alignCast(context.?));
        return owned.session.latency(render_ahead_frames, dsp_frames);
    }

    fn outputTiming(context: ?*anyopaque) anyerror!contract.TimingSnapshot {
        const owned: *OwnedSession = @ptrCast(@alignCast(context.?));
        return owned.session.timing();
    }

    fn setOutputStateWaker(context: ?*anyopaque, waker: ?work.Waker) void {
        const owned: *OwnedSession = @ptrCast(@alignCast(context.?));
        owned.session.setStateWaker(waker);
    }
};

fn testRender(
    userdata: ?*anyopaque,
    samples: [*]f32,
    frames: u32,
    channels: u32,
) callconv(.c) void {
    const value: *const f32 = @ptrCast(@alignCast(userdata.?));
    @memset(samples[0 .. frames * channels], value.*);
}

test "PipeWire adapter initializes behind an Orca-owned boundary" {
    try std.testing.expect(Backend.libraryVersion().len > 0);
    var backend: Backend = .{};
    backend.init();
    backend.init();
    backend.deinit();
}

test "PipeWire callback bridge fills interleaved float output" {
    const value: f32 = 0.25;
    var samples: [6]f32 = undefined;
    orca_pw_fill(testRender, @ptrCast(@constCast(&value)), &samples, 3, 2);
    for (samples) |sample| try std.testing.expectEqual(value, sample);

    orca_pw_fill(null, null, &samples, 3, 2);
    for (samples) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
}

const SpaDictItem = extern struct { key: [*:0]const u8, value: [*:0]const u8 };
const SpaDict = extern struct { flags: u32 = 0, n_items: u32, items: [*]const SpaDictItem };
extern fn orca_pw_properties_kind(?*const SpaDict) u8;

fn kindOf(items: []const SpaDictItem) contract.DeviceKind {
    const dict: SpaDict = .{ .n_items = @intCast(items.len), .items = items.ptr };
    return std.enums.fromInt(contract.DeviceKind, orca_pw_properties_kind(&dict)).?;
}

test "a PipeWire output's kind comes from its bus, Bluetooth and HDMI hints, or the null-sink factory" {
    try std.testing.expectEqual(.virtual, kindOf(&.{
        .{ .key = "factory.name", .value = "support.null-audio-sink" },
        .{ .key = "media.class", .value = "Audio/Sink" },
    }));
    try std.testing.expectEqual(.usb, kindOf(&.{
        .{ .key = "device.api", .value = "alsa" },
        .{ .key = "device.bus", .value = "usb" },
        .{ .key = "api.alsa.path", .value = "hw:II,0" },
        .{ .key = "device.profile.name", .value = "HiFi: Headphones: sink" },
    }));
    try std.testing.expectEqual(.pci, kindOf(&.{
        .{ .key = "device.bus", .value = "pci" },
        .{ .key = "api.alsa.path", .value = "front:1" },
        .{ .key = "device.profile.name", .value = "analog-stereo" },
    }));
    try std.testing.expectEqual(.hdmi, kindOf(&.{
        .{ .key = "device.bus", .value = "pci" },
        .{ .key = "api.alsa.path", .value = "hdmi:0,1" },
    }));
    try std.testing.expectEqual(.hdmi, kindOf(&.{
        .{ .key = "device.bus", .value = "pci" },
        .{ .key = "device.profile.name", .value = "hdmi-stereo-extra1" },
    }));
    try std.testing.expectEqual(.bluetooth, kindOf(&.{
        .{ .key = "factory.name", .value = "api.bluez5.a2dp.sink" },
        .{ .key = "api.bluez5.address", .value = "00:11:22:33:44:55" },
    }));
    try std.testing.expectEqual(.bluetooth, kindOf(&.{
        .{ .key = "device.api", .value = "bluez5" },
    }));
    try std.testing.expectEqual(.bluetooth, kindOf(&.{
        .{ .key = "device.bus", .value = "bluetooth" },
    }));
    try std.testing.expectEqual(.unknown, kindOf(&.{
        .{ .key = "factory.name", .value = "support.node.driver" },
        .{ .key = "media.class", .value = "Audio/Sink" },
    }));
    try std.testing.expectEqual(.unknown, kindOf(&.{}));
    try std.testing.expectEqual(@as(u8, 0), orca_pw_properties_kind(null));
}

fn nativeTiming(device_format: u8, device_rate: u32, device_channels: u16) NativeTiming {
    return .{
        .sample_time = 0,
        .monotonic_ns = 0,
        .device_delay_frames = -1,
        .queued_frames = 0,
        .buffered_frames = 0,
        .quantum_frames = 0,
        .graph_rate = 0,
        .device_rate = device_rate,
        .device_channels = device_channels,
        .device_format = device_format,
        .reserved = 0,
    };
}

test "a PipeWire device format is reported only when the shim names a format, a rate and channels" {
    try std.testing.expectEqual(contract.DeviceFormat{
        .sample_format = .signed_24_32,
        .sample_rate = 96_000,
        .channels = 2,
    }, deviceFormatFrom(&nativeTiming(3, 96_000, 2)).?);
    try std.testing.expectEqual(
        contract.DeviceSampleFormat.signed_16,
        deviceFormatFrom(&nativeTiming(1, 44_100, 2)).?.sample_format,
    );
    try std.testing.expectEqual(
        contract.DeviceSampleFormat.signed_24,
        deviceFormatFrom(&nativeTiming(2, 48_000, 2)).?.sample_format,
    );
    try std.testing.expectEqual(
        contract.DeviceSampleFormat.signed_32,
        deviceFormatFrom(&nativeTiming(4, 192_000, 2)).?.sample_format,
    );
    try std.testing.expectEqual(
        contract.DeviceSampleFormat.float_32,
        deviceFormatFrom(&nativeTiming(5, 48_000, 8)).?.sample_format,
    );
    try std.testing.expectEqual(null, deviceFormatFrom(&nativeTiming(0, 0, 0)));
    try std.testing.expectEqual(null, deviceFormatFrom(&nativeTiming(0, 48_000, 2)));
    try std.testing.expectEqual(null, deviceFormatFrom(&nativeTiming(6, 48_000, 2)));
    try std.testing.expectEqual(null, deviceFormatFrom(&nativeTiming(3, 0, 2)));
    try std.testing.expectEqual(null, deviceFormatFrom(&nativeTiming(3, 96_000, 0)));
}

extern fn orca_pw_format_pack(*const anyopaque) u64;

const PodProperty = struct { key: u32, type: u32, value: u32 };
const spa_type_id: u32 = 3;
const spa_type_int: u32 = 4;
const audio_raw = [_]PodProperty{
    .{ .key = 1, .type = spa_type_id, .value = 1 },
    .{ .key = 2, .type = spa_type_id, .value = 1 },
};

fn podFormat(properties: []const PodProperty) ?contract.DeviceFormat {
    var words: [4 + 6 * 8]u32 align(8) = undefined;
    std.debug.assert(properties.len <= 8);
    words[0..4].* = .{ @intCast(8 + 24 * properties.len), 15, 0x40003, 4 };
    for (properties, 0..) |property, index|
        words[4 + index * 6 ..][0..6].* = .{ property.key, 0, 4, property.type, property.value, 0 };
    const value = orca_pw_format_pack(&words);
    return deviceFormatFrom(&nativeTiming(@truncate(value), @truncate(value >> 32), @truncate(value >> 8)));
}

fn rawFormat(spa_format: u32, rate: u32, channels: u32) ?contract.DeviceFormat {
    return podFormat(&(audio_raw ++ [_]PodProperty{
        .{ .key = 0x10001, .type = spa_type_id, .value = spa_format },
        .{ .key = 0x10003, .type = spa_type_int, .value = rate },
        .{ .key = 0x10004, .type = spa_type_int, .value = channels },
    }));
}

test "a sink's SPA Format param parses to its sample format, rate and channels, and anything else is unknown" {
    try std.testing.expectEqual(contract.DeviceFormat{
        .sample_format = .signed_24_32,
        .sample_rate = 96_000,
        .channels = 2,
    }, rawFormat(0x107, 96_000, 2).?);
    try std.testing.expectEqual(contract.DeviceFormat{
        .sample_format = .float_32,
        .sample_rate = 48_000,
        .channels = 2,
    }, rawFormat(0x206, 48_000, 2).?);
    try std.testing.expectEqual(.signed_16, rawFormat(0x103, 44_100, 2).?.sample_format);
    try std.testing.expectEqual(.signed_16, rawFormat(0x202, 44_100, 2).?.sample_format);
    try std.testing.expectEqual(.signed_24, rawFormat(0x10f, 88_200, 2).?.sample_format);
    try std.testing.expectEqual(.signed_24, rawFormat(0x205, 88_200, 2).?.sample_format);
    try std.testing.expectEqual(.signed_24_32, rawFormat(0x203, 96_000, 2).?.sample_format);
    try std.testing.expectEqual(.signed_32, rawFormat(0x10b, 192_000, 2).?.sample_format);
    try std.testing.expectEqual(.signed_32, rawFormat(0x204, 192_000, 2).?.sample_format);
    try std.testing.expectEqual(.float_32, rawFormat(0x11b, 48_000, 6).?.sample_format);

    try std.testing.expectEqual(null, rawFormat(0x104, 44_100, 2));
    try std.testing.expectEqual(null, rawFormat(0x102, 44_100, 2));
    try std.testing.expectEqual(null, rawFormat(0x11d, 48_000, 2));
    try std.testing.expectEqual(null, rawFormat(0x107, 0, 2));
    try std.testing.expectEqual(null, rawFormat(0x107, 96_000, 0));
    try std.testing.expectEqual(null, podFormat(&(audio_raw ++ [_]PodProperty{
        .{ .key = 0x10001, .type = spa_type_id, .value = 0x107 },
        .{ .key = 0x10004, .type = spa_type_int, .value = 2 },
    })));
    try std.testing.expectEqual(null, podFormat(&.{
        .{ .key = 1, .type = spa_type_id, .value = 2 },
        .{ .key = 2, .type = spa_type_id, .value = 1 },
        .{ .key = 0x10001, .type = spa_type_id, .value = 0x107 },
        .{ .key = 0x10003, .type = spa_type_int, .value = 96_000 },
        .{ .key = 0x10004, .type = spa_type_int, .value = 2 },
    }));
}

const ScriptedDiscovery = struct {
    clock: *network.testing.TestClock,
    native: []NativeDevice,
    listing_ms: i64,
    reply_after_ms: []const ?i64,
    fail: bool = false,
    listed_at_ms: ?i64 = null,
    delivered: [4]bool = @splat(false),
    timeouts: [8]i32 = undefined,
    iterations: usize = 0,
    finished: bool = false,

    fn discovery(self: *ScriptedDiscovery) Discovery {
        return .{ .context = self, .iterate_fn = iterate, .finish_fn = finish };
    }

    fn pending(self: *const ScriptedDiscovery) bool {
        for (self.delivered[0..self.reply_after_ms.len]) |delivered| {
            if (!delivered) return true;
        }
        return false;
    }

    fn iterate(context: *anyopaque, timeout_ms: i32) anyerror!DiscoveryPhase {
        const self: *ScriptedDiscovery = @ptrCast(@alignCast(context));
        self.timeouts[self.iterations] = timeout_ms;
        self.iterations += 1;
        if (self.fail) return error.PipeWireDiscoveryFailed;
        const listed_at = self.listed_at_ms orelse {
            self.clock.advance(self.listing_ms);
            self.listed_at_ms = self.clock.now();
            return .capabilities;
        };
        if (!self.pending()) return .complete;
        const elapsed = self.clock.now() - listed_at;
        var next: ?usize = null;
        for (self.reply_after_ms, 0..) |reply, index| {
            const at = reply orelse continue;
            if (self.delivered[index]) continue;
            if (next == null or at < self.reply_after_ms[next.?].?) next = index;
        }
        std.debug.assert(timeout_ms >= 0);
        const index = next orelse {
            self.clock.advance(timeout_ms);
            return .capabilities;
        };
        const wait = self.reply_after_ms[index].? - elapsed;
        if (wait > timeout_ms) {
            self.clock.advance(timeout_ms);
            return .capabilities;
        }
        self.clock.advance(wait);
        self.delivered[index] = true;
        return if (self.pending()) .capabilities else .complete;
    }

    fn finish(context: *anyopaque) u32 {
        const self: *ScriptedDiscovery = @ptrCast(@alignCast(context));
        self.finished = true;
        for (self.native, self.delivered[0..self.native.len]) |*device, delivered|
            device.has_capabilities = @intFromBool(delivered);
        return @intCast(self.native.len);
    }
};

fn scriptedDevice(id: u64, state: contract.DeviceState) NativeDevice {
    return .{
        .id = id,
        .name = @splat(0),
        .name_len = 0,
        .kind = @backingInt(contract.DeviceKind.usb),
        .state = @backingInt(state),
        .bit_depths = contract.DeviceCapabilities.bit_depth_16 | contract.DeviceCapabilities.bit_depth_24,
        .channels_max = 2,
        .rate_min = 44_100,
        .rate_max = 384_000,
    };
}

test "outputs whose capability replies are still missing 500 ms after listing ends report capabilities unknown" {
    var clock: network.testing.TestClock = .startingAt(1_000);
    var native = [_]NativeDevice{
        scriptedDevice(10, .active),
        scriptedDevice(11, .suspended),
        scriptedDevice(12, .active),
    };
    var scripted: ScriptedDiscovery = .{
        .clock = &clock,
        .native = &native,
        .listing_ms = 3_000,
        .reply_after_ms = &.{ 100, 900, null },
    };
    var devices: [3]contract.Device = undefined;

    try std.testing.expectEqual(@as(usize, 3), try collect(scripted.discovery(), clock.clock(), &native, &devices));

    try std.testing.expect(scripted.finished);
    try std.testing.expectEqual(@as(i64, 1_000 + 3_000 + capability_bound_ms), clock.now());
    try std.testing.expectEqualSlices(i32, &.{ -1, 500, 400 }, scripted.timeouts[0..scripted.iterations]);
    try std.testing.expectEqual(contract.DeviceCapabilities{
        .rate_min = 44_100,
        .rate_max = 384_000,
        .bit_depths = contract.DeviceCapabilities.bit_depth_16 | contract.DeviceCapabilities.bit_depth_24,
        .channels_max = 2,
        .state = .active,
        .bus = .usb,
    }, devices[0].capabilities.?);
    try std.testing.expectEqual(null, devices[1].capabilities);
    try std.testing.expectEqual(null, devices[2].capabilities);
    try std.testing.expectEqual(@as(u64, 12), devices[2].id);
    try std.testing.expectEqual(contract.DeviceKind.usb, devices[2].kind);
}

test "capability replies that all arrive within the bound end the wait without running out the bound" {
    var clock: network.testing.TestClock = .startingAt(0);
    var native = [_]NativeDevice{ scriptedDevice(20, .suspended), scriptedDevice(21, .unavailable) };
    var scripted: ScriptedDiscovery = .{
        .clock = &clock,
        .native = &native,
        .listing_ms = 5,
        .reply_after_ms = &.{ 20, 40 },
    };
    var devices: [2]contract.Device = undefined;

    try std.testing.expectEqual(@as(usize, 2), try collect(scripted.discovery(), clock.clock(), &native, &devices));

    try std.testing.expectEqual(@as(i64, 5 + 40), clock.now());
    try std.testing.expectEqualSlices(i32, &.{ -1, 500, 480 }, scripted.timeouts[0..scripted.iterations]);
    try std.testing.expectEqual(contract.DeviceState.suspended, devices[0].capabilities.?.state);
    try std.testing.expectEqual(contract.DeviceState.unavailable, devices[1].capabilities.?.state);
}

test "a discovery that fails while waiting is still finished before the error returns" {
    var clock: network.testing.TestClock = .startingAt(0);
    var native = [_]NativeDevice{scriptedDevice(30, .active)};
    var scripted: ScriptedDiscovery = .{
        .clock = &clock,
        .native = &native,
        .listing_ms = 0,
        .reply_after_ms = &.{10},
        .fail = true,
    };
    var devices: [1]contract.Device = undefined;

    try std.testing.expectError(
        error.PipeWireDiscoveryFailed,
        collect(scripted.discovery(), clock.clock(), &native, &devices),
    );
    try std.testing.expect(scripted.finished);
}

test "PipeWire callback consumes Orca prepared blocks without allocation" {
    var pool = try buffer.BlockPool.init(std.testing.allocator, 1, 3, 2);
    defer pool.deinit();
    var pipe: render_pipe.RenderPipe(1) = .{};
    const index = pool.acquire().?;
    @memset(pool.samples(index), 0.75);
    try std.testing.expect(pipe.submit(.{ .index = index, .frames = 3, .epoch = 7, .entry_serial = 9 }));
    var epoch: std.atomic.Value(u32) = .init(7);
    var position: std.atomic.Value(u64) = .init(0);
    var entry_serial: std.atomic.Value(u32) = .init(0);
    var context: RenderContext(1) = .{
        .pool = &pool,
        .pipe = &pipe,
        .epoch = &epoch,
        .channels = 2,
        .position = &position,
        .rendered_entry_serial = &entry_serial,
    };

    var samples: [6]f32 = undefined;
    orca_pw_fill(RenderContext(1).callback, context.userdata(), &samples, 3, 2);
    for (samples) |sample| try std.testing.expectEqual(@as(f32, 0.75), sample);
    try std.testing.expectEqual(@as(u16, 7), render_pipe.positionEpoch(position.load(.monotonic)));
    try std.testing.expectEqual(@as(u64, 3), render_pipe.positionFrames(position.load(.monotonic)));
    try std.testing.expectEqual(@as(u32, 9), entry_serial.load(.monotonic));
    pipe.reclaim(&pool);
}

test "a silenced Player renders zeros without consuming blocks or underrunning" {
    var pool = try buffer.BlockPool.init(std.testing.allocator, 1, 3, 2);
    defer pool.deinit();
    var pipe: render_pipe.RenderPipe(1) = .{};
    const index = pool.acquire().?;
    @memset(pool.samples(index), 0.75);
    try std.testing.expect(pipe.submit(.{
        .index = index,
        .frames = 3,
        .epoch = 1,
        .entry_serial = 1,
    }));
    var epoch: std.atomic.Value(u32) = .init(1);
    var position: std.atomic.Value(u64) = .init(0);
    var silenced: std.atomic.Value(bool) = .init(true);
    var context: RenderContext(1) = .{
        .pool = &pool,
        .pipe = &pipe,
        .epoch = &epoch,
        .channels = 2,
        .silenced = &silenced,
        .position = &position,
    };

    var samples: [6]f32 = @splat(1);
    orca_pw_fill(RenderContext(1).callback, context.userdata(), &samples, 3, 2);
    for (samples) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    try std.testing.expectEqual(@as(u64, 0), position.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), pipe.underruns.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), pipe.ready.len());
    try std.testing.expectEqual(@as(usize, 0), pool.free_len);

    // Resuming consumes the block that pausing preserved.
    silenced.store(false, .release);
    orca_pw_fill(RenderContext(1).callback, context.userdata(), &samples, 3, 2);
    for (samples) |sample| try std.testing.expectEqual(@as(f32, 0.75), sample);
    try std.testing.expectEqual(@as(u64, 3), render_pipe.positionFrames(position.load(.monotonic)));
    pipe.reclaim(&pool);
}

test "PipeWire output policies choose explicit inspectable latency targets" {
    const format: pcm.Format = .{
        .sample_format = .float_32,
        .channels = 2,
        .sample_rate = 48_000,
        .bits_per_sample = 32,
        .bytes_per_frame = 8,
    };
    try std.testing.expectEqual(@as(u32, 1024), requestedLatency(.{
        .device_id = 0,
        .format = format,
        .policy = .robust,
        .requested_latency_frames = 0,
    }));
    try std.testing.expectEqual(@as(u32, 128), requestedLatency(.{
        .device_id = 0,
        .format = format,
        .policy = .interactive,
        .requested_latency_frames = 0,
    }));
    try std.testing.expectEqual(@as(u32, 384), requestedLatency(.{
        .device_id = 0,
        .format = format,
        .policy = .{ .custom = .{ .target_frames = 384 } },
        .requested_latency_frames = 0,
    }));
    try std.testing.expectEqual(@as(u32, 256), requestedLatency(.{
        .device_id = 0,
        .format = format,
        .policy = .robust,
        .requested_latency_frames = 256,
    }));
}
