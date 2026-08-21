const std = @import("std");
const contract = @import("../backend.zig");
const buffer = @import("../buffer.zig");
const pcm = @import("../pcm.zig");
const render_pipe = @import("../render.zig");
const zone = @import("../zone.zig");

extern fn orca_pw_library_version() [*:0]const u8;
extern fn orca_pw_initialize() void;
extern fn orca_pw_deinitialize() void;
const NativeDevice = extern struct {
    id: u64,
    name_len: u16,
    name: [256]u8,
};
extern fn orca_pw_discover([*]NativeDevice, u32, *u32) c_int;
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
};
extern fn orca_pw_output_timing(?*anyopaque, *NativeTiming) c_int;
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

    pub fn discover(_: *Backend, devices: []contract.Device) !usize {
        var native: [64]NativeDevice = undefined;
        const limit = @min(devices.len, native.len);
        var count: u32 = 0;
        if (orca_pw_discover(&native, @intCast(limit), &count) < 0)
            return error.PipeWireDiscoveryFailed;
        for (native[0..count], devices[0..count]) |source, *destination| {
            destination.* = .{
                .id = source.id,
                .name = source.name,
                .name_len = source.name_len,
            };
        }
        return count;
    }
};

/// Owns one autoconnected float32 PipeWire playback stream. The render
/// function is called directly on PipeWire's real-time process thread.
pub const OutputSession = struct {
    native: *anyopaque,
    format: pcm.Format,
    requested_latency_frames: u32,

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
        };
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
        };
    }
};

fn requestedLatency(request: contract.OpenRequest) u32 {
    if (request.requested_latency_frames != 0)
        return request.requested_latency_frames;
    return switch (request.policy) {
        .robust => 1024,
        .interactive => 128,
        .custom => |custom| custom.target_frames,
    };
}

/// Typed context connecting PipeWire's C callback to Orca's wait-free render
/// pipe. It and every referenced object must outlive the OutputSession.
pub fn RenderContext(comptime capacity: usize) type {
    return struct {
        pool: *const buffer.BlockPool,
        pipe: *render_pipe.RenderPipe(capacity),
        generation: *const std.atomic.Value(u64),
        channels: u16,
        format_mismatches: std.atomic.Value(u64) = .init(0),

        const Self = @This();

        pub fn callback(
            opaque_context: ?*anyopaque,
            samples: [*]f32,
            frames: u32,
            channels: u32,
        ) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(opaque_context.?));
            const output = samples[0 .. frames * channels];
            if (channels != self.channels) {
                @memset(output, 0);
                _ = self.format_mismatches.fetchAdd(1, .monotonic);
                return;
            }
            self.pipe.render(
                self.pool,
                self.channels,
                self.generation.load(.monotonic),
                output,
            );
        }

        pub fn userdata(self: *Self) *anyopaque {
            return @ptrCast(self);
        }
    };
}

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

test "PipeWire callback consumes Orca prepared blocks without allocation" {
    var pool = try buffer.BlockPool.init(std.testing.allocator, 1, 3, 2);
    defer pool.deinit();
    var pipe: render_pipe.RenderPipe(1) = .{};
    const index = pool.acquire().?;
    @memset(pool.samples(index), 0.75);
    try std.testing.expect(pipe.submit(.{ .index = index, .frames = 3, .generation = 7 }));
    var generation: std.atomic.Value(u64) = .init(7);
    var context: RenderContext(1) = .{
        .pool = &pool,
        .pipe = &pipe,
        .generation = &generation,
        .channels = 2,
    };

    var samples: [6]f32 = undefined;
    orca_pw_fill(RenderContext(1).callback, context.userdata(), &samples, 3, 2);
    for (samples) |sample| try std.testing.expectEqual(@as(f32, 0.75), sample);
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
