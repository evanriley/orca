const std = @import("std");
const buffer = @import("../buffer.zig");
const render_pipe = @import("../render.zig");

extern fn orca_pw_library_version() [*:0]const u8;
extern fn orca_pw_initialize() void;
extern fn orca_pw_deinitialize() void;
pub const RenderFn = *const fn (?*anyopaque, [*]f32, u32, u32) callconv(.c) void;
extern fn orca_pw_output_create(u32, u32, RenderFn, ?*anyopaque) ?*anyopaque;
extern fn orca_pw_output_destroy(?*anyopaque) void;
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
};

/// Owns one autoconnected float32 PipeWire playback stream. The render
/// function is called directly on PipeWire's real-time process thread.
pub const OutputSession = struct {
    native: *anyopaque,

    pub fn open(
        sample_rate: u32,
        channels: u16,
        render: RenderFn,
        userdata: ?*anyopaque,
    ) !OutputSession {
        const native = orca_pw_output_create(sample_rate, channels, render, userdata) orelse
            return error.PipeWireOutputUnavailable;
        return .{ .native = native };
    }

    pub fn close(self: *OutputSession) void {
        orca_pw_output_destroy(self.native);
        self.* = undefined;
    }
};

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
