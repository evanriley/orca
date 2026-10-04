const std = @import("std");
const work = @import("../core/work.zig");
const contract = @import("backend.zig");
const zone_model = @import("zone.zig");

/// Signature the platform backend calls on its real-time thread. It is the
/// only thing that crosses the RT boundary, and `render.RenderContext.callback`
/// is the only Orca implementation of it.
pub const RenderFn = *const fn (?*anyopaque, [*]f32, u32, u32) callconv(.c) void;

/// Backend-neutral stream state. PipeWire's native states are translated into
/// this by its adapter; a test backend publishes it directly.
pub const Status = enum(u8) { connecting, active, lost };

/// One open output stream, owned by exactly one Zone.
///
/// Everything here runs on the control side of the real-time boundary — the
/// engine thread, never the render callback. Native object lifetime stays
/// inside the backend adapter behind `context`.
pub const Output = struct {
    context: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        close: *const fn (?*anyopaque) void,
        status: *const fn (?*anyopaque) Status,
        latency: *const fn (?*anyopaque, u32, u32) anyerror!zone_model.Latency,
        timing: *const fn (?*anyopaque) anyerror!contract.TimingSnapshot,
        set_state_waker: *const fn (?*anyopaque, ?work.Waker) void,
    };

    pub fn close(self: Output) void {
        self.vtable.close(self.context);
    }

    pub fn status(self: Output) Status {
        return self.vtable.status(self.context);
    }

    pub fn latency(
        self: Output,
        render_ahead_frames: u32,
        dsp_frames: u32,
    ) anyerror!zone_model.Latency {
        return self.vtable.latency(self.context, render_ahead_frames, dsp_frames);
    }

    pub fn timing(self: Output) anyerror!contract.TimingSnapshot {
        return self.vtable.timing(self.context);
    }

    /// `waker` is called whenever `status` may have changed, from the
    /// backend's control thread and never from the render callback. Once this
    /// returns, the previous waker is never called again.
    pub fn setStateWaker(self: Output, waker: ?work.Waker) void {
        self.vtable.set_state_waker(self.context, waker);
    }
};

/// Control-lane device enumeration and stream creation. Never reachable from a
/// render callback: opening and closing streams allocates and blocks.
pub const Factory = struct {
    context: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (
            ?*anyopaque,
            contract.OpenRequest,
            RenderFn,
            ?*anyopaque,
        ) anyerror!Output,
        discover: *const fn (?*anyopaque, []contract.Device, contract.DiscoveryDetail) anyerror!usize,
    };

    pub fn open(
        self: Factory,
        request: contract.OpenRequest,
        render: RenderFn,
        userdata: ?*anyopaque,
    ) anyerror!Output {
        return self.vtable.open(self.context, request, render, userdata);
    }

    pub fn discover(
        self: Factory,
        devices: []contract.Device,
        detail: contract.DiscoveryDetail,
    ) anyerror!usize {
        return self.vtable.discover(self.context, devices, detail);
    }
};

/// Deterministic in-process backend for multi-Zone, device-loss and shutdown
/// tests. It never touches an audio server, so the tests that depend on it run
/// on hosts with no sound daemon at all.
pub const TestBackend = struct {
    allocator: std.mem.Allocator,
    /// Every stream this backend has handed out, so a test can drive callbacks.
    streams: [max_streams]?*Stream = @splat(null),
    stream_count: usize = 0,
    /// When set, the next `open` fails. Models a device that will not reopen.
    fail_next_open: bool = false,
    fail_device_id: ?u64 = null,
    device_format: ?contract.DeviceFormat = null,
    opens: usize = 0,
    discoveries: std.atomic.Value(usize) = .init(0),

    pub const max_streams = 8;

    pub const Stream = struct {
        backend: *TestBackend,
        render: RenderFn,
        userdata: ?*anyopaque,
        request: contract.OpenRequest,
        state: std.atomic.Value(u8) = .init(@intFromEnum(Status.active)),
        closed: bool = false,
        state_waker: ?work.Waker = null,

        /// Drives one render callback exactly as a backend RT thread would.
        pub fn pump(self: *Stream, samples: []f32, frames: u32) void {
            self.render(self.userdata, samples.ptr, frames, self.request.format.channels);
        }

        pub fn markLost(self: *Stream) void {
            self.state.store(@intFromEnum(Status.lost), .release);
            if (self.state_waker) |waker| waker.wake();
        }
    };

    pub fn deinit(self: *TestBackend) void {
        for (self.streams[0..self.stream_count]) |maybe_stream| {
            if (maybe_stream) |stream| self.allocator.destroy(stream);
        }
        self.* = undefined;
    }

    pub fn factory(self: *TestBackend) Factory {
        return .{ .context = self, .vtable = &factory_vtable };
    }

    /// Most recently opened stream that is still open, or null.
    pub fn liveStream(self: *TestBackend) ?*Stream {
        var index = self.stream_count;
        while (index > 0) {
            index -= 1;
            if (self.streams[index]) |stream| {
                if (!stream.closed) return stream;
            }
        }
        return null;
    }

    const factory_vtable: Factory.VTable = .{ .open = open, .discover = discover };
    const output_vtable: Output.VTable = .{
        .close = closeStream,
        .status = streamStatus,
        .latency = streamLatency,
        .timing = streamTiming,
        .set_state_waker = setStreamStateWaker,
    };

    fn open(
        context: ?*anyopaque,
        request: contract.OpenRequest,
        render: RenderFn,
        userdata: ?*anyopaque,
    ) anyerror!Output {
        const self: *TestBackend = @ptrCast(@alignCast(context.?));
        self.opens += 1;
        if (self.fail_next_open) return error.TestOutputUnavailable;
        if (self.fail_device_id) |device_id| {
            if (request.device_id == device_id) return error.TestOutputUnavailable;
        }
        if (self.stream_count == max_streams) return error.TestOutputUnavailable;
        const stream = try self.allocator.create(Stream);
        stream.* = .{
            .backend = self,
            .render = render,
            .userdata = userdata,
            .request = request,
        };
        self.streams[self.stream_count] = stream;
        self.stream_count += 1;
        return .{ .context = stream, .vtable = &output_vtable };
    }

    pub const test_capabilities: contract.DeviceCapabilities = .{
        .rate_min = 44_100,
        .rate_max = 192_000,
        .bit_depths = contract.DeviceCapabilities.bit_depth_32,
        .channels_max = 2,
        .state = .active,
        .bus = .virtual,
    };

    fn discover(
        context: ?*anyopaque,
        devices: []contract.Device,
        detail: contract.DiscoveryDetail,
    ) anyerror!usize {
        const self: *TestBackend = @ptrCast(@alignCast(context.?));
        _ = self.discoveries.fetchAdd(1, .monotonic);
        if (devices.len == 0) return 0;
        var device: contract.Device = .{
            .id = 1,
            .name = undefined,
            .name_len = 0,
            .kind = .virtual,
            .capabilities = switch (detail) {
                .identity => null,
                .capabilities => test_capabilities,
            },
        };
        const name = "Test Output";
        @memcpy(device.name[0..name.len], name);
        device.name_len = name.len;
        devices[0] = device;
        return 1;
    }

    fn closeStream(context: ?*anyopaque) void {
        const stream: *Stream = @ptrCast(@alignCast(context.?));
        stream.closed = true;
    }

    fn streamStatus(context: ?*anyopaque) Status {
        const stream: *Stream = @ptrCast(@alignCast(context.?));
        return @enumFromInt(@as(std.meta.Tag(Status), @intCast(stream.state.load(.acquire))));
    }

    fn streamLatency(
        context: ?*anyopaque,
        render_ahead_frames: u32,
        dsp_frames: u32,
    ) anyerror!zone_model.Latency {
        const stream: *Stream = @ptrCast(@alignCast(context.?));
        return .{
            .requested_frames = stream.request.requested_latency_frames,
            .backend_quantum_frames = 256,
            .render_ahead_frames = render_ahead_frames,
            .dsp_frames = dsp_frames,
            .hardware_frames = null,
            .graph_rate_hz = null,
            .device_format = stream.backend.device_format,
        };
    }

    fn setStreamStateWaker(context: ?*anyopaque, waker: ?work.Waker) void {
        const stream: *Stream = @ptrCast(@alignCast(context.?));
        stream.state_waker = waker;
    }

    fn streamTiming(context: ?*anyopaque) anyerror!contract.TimingSnapshot {
        const stream: *Stream = @ptrCast(@alignCast(context.?));
        return .{
            .sample_time = 0,
            .monotonic_ns = 0,
            .device_delay_frames = null,
            .queued_frames = 0,
            .buffered_frames = 0,
            .backend_quantum_frames = 256,
            .graph_rate_hz = null,
            .device_format = stream.backend.device_format,
        };
    }
};

test "the test backend hands out independently closable streams" {
    var backend: TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    const factory = backend.factory();

    var devices: [4]contract.Device = undefined;
    try std.testing.expectEqual(@as(usize, 1), try factory.discover(&devices, .identity));
    try std.testing.expectEqualStrings("Test Output", devices[0].nameSlice());
    try std.testing.expectEqual(contract.DeviceKind.virtual, devices[0].kind);
    try std.testing.expectEqual(null, devices[0].capabilities);
    _ = try factory.discover(&devices, .capabilities);
    try std.testing.expectEqual(TestBackend.test_capabilities, devices[0].capabilities.?);

    const request: contract.OpenRequest = .{
        .device_id = 0,
        .format = .{
            .sample_format = .float_32,
            .channels = 1,
            .sample_rate = 48_000,
            .bits_per_sample = 32,
            .bytes_per_frame = 4,
        },
        .policy = .robust,
        .requested_latency_frames = 256,
    };
    const Noop = struct {
        fn render(_: ?*anyopaque, samples: [*]f32, frames: u32, channels: u32) callconv(.c) void {
            @memset(samples[0 .. frames * channels], 0);
        }
    };
    const first = try factory.open(request, Noop.render, null);
    const second = try factory.open(request, Noop.render, null);
    try std.testing.expectEqual(Status.active, first.status());
    backend.streams[0].?.markLost();
    try std.testing.expectEqual(Status.lost, first.status());
    try std.testing.expectEqual(Status.active, second.status());
    first.close();
    second.close();
}
