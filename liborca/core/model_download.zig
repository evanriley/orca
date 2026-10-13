const std = @import("std");
const audio_embedding = @import("../analysis/audio_embedding.zig");
const control = @import("control.zig");
const embedding_model = @import("embedding_model.zig");
const job = @import("job.zig");
const job_worker = @import("job_worker.zig");
const metadata = @import("../metadata/root.zig");
const network = @import("../network/root.zig");
const object = @import("object.zig");
const work = @import("work.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const request_timeout_ms: u64 = 30_000;
pub const deadline_ms: i64 = 60 * std.time.ms_per_min;
pub const redirect_allowance: network.client.RedirectAllowance = .{ .host = "githubusercontent.com" };
pub const part_suffix = ".part";

pub const Descriptor = struct {
    url: []const u8,
    size: usize,
    sha256: [Sha256.digest_length]u8,

    pub fn of(model: audio_embedding.ModelId) Descriptor {
        const spec = model.spec();
        return .{ .url = spec.url, .size = spec.size, .sha256 = spec.sha256 };
    }
};

pub const Hooks = struct {
    transport: ?network.client.Transport = null,
    clock: ?network.client.Clock = null,
    wall_clock: ?network.client.Clock = null,
    random: ?std.Random = null,
    descriptor: ?Descriptor = null,
};

pub const Failure = union(enum) {
    network_unavailable,
    timed_out,
    status: u16,
    refused,
    redirect_refused,
    mismatch,
    write_failed,
    internal,

    pub const Reason = job.BoundedText(128);

    pub fn reason(self: Failure) Reason {
        var buffer: [64]u8 = undefined;
        return .init(switch (self) {
            .network_unavailable => "the network is unavailable",
            .timed_out => "the download timed out",
            .status => |status| std.fmt.bufPrint(&buffer, "the server answered {d}", .{status}) catch unreachable,
            .refused => "the server is refusing requests for now",
            .redirect_refused => "the server redirected somewhere unexpected",
            .mismatch => "the downloaded file is not the expected model",
            .write_failed => "the file could not be written",
            .internal => "the download could not be run",
        });
    }
};

pub const Outcome = union(enum) {
    succeeded,
    cancelled,
    failed: Failure,

    pub fn state(self: Outcome) job.State {
        return switch (self) {
            .succeeded => .succeeded,
            .cancelled => .cancelled,
            .failed => .failed,
        };
    }
};

/// One download behind a `JobHandle`. The worker thread touches only this
/// record, its registration and the host signal; the control lane reads
/// `received` while it runs and `outcome` once it has finished.
pub const Download = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    registration: *work.Registration,
    work_handle: work.WorkHandle,
    job: object.JobHandle,
    destination: embedding_model.OwnedPath,
    identity: network.client.OwnedIdentity,
    descriptor: Descriptor,
    hooks: Hooks,
    host_signal: *control.HostSignal,
    received: std.atomic.Value(u64) = .init(0),
    /// Written by the worker just before it finishes; read only after.
    outcome: Outcome = .cancelled,
    /// Control lane only. Set once a drain has joined the worker and freed
    /// `registration`.
    joined: bool = false,
    published: ?job_worker.PublishedProgress = null,

    pub fn run(self: *Download) void {
        const registration = self.registration;
        const host_signal = self.host_signal;
        self.outcome = self.transfer();
        registration.finish();
        host_signal.raise();
    }

    pub fn isFinished(self: *const Download) bool {
        return self.joined or self.registration.isFinished();
    }

    fn transfer(self: *Download) Outcome {
        const descriptor = self.descriptor;
        const destination = self.destination.view();
        if (holds(self.io, destination, descriptor)) {
            self.received.store(descriptor.size, .release);
            return .succeeded;
        }
        if (self.registration.cancellationRequested()) return .cancelled;

        const part = std.mem.concat(self.allocator, u8, &.{ destination, part_suffix }) catch return .{ .failed = .internal };
        defer self.allocator.free(part);
        const cwd = std.Io.Dir.cwd();
        if (std.Io.Dir.path.dirname(destination)) |directory|
            cwd.createDirPath(self.io, directory) catch return .{ .failed = .write_failed };
        const outcome = self.install(part);
        if (outcome != .succeeded) cwd.deleteFile(self.io, part) catch {};
        return outcome;
    }

    fn install(self: *Download, part: []const u8) Outcome {
        const cwd = std.Io.Dir.cwd();
        const destination = self.destination.view();
        cwd.deleteFile(self.io, part) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return .{ .failed = .write_failed },
        };
        {
            const file = cwd.createFile(self.io, part, .{ .exclusive = true }) catch return .{ .failed = .write_failed };
            defer file.close(self.io);
            const received = self.receive(file);
            if (received != .succeeded) return received;
            file.sync(self.io) catch return .{ .failed = .write_failed };
        }
        cwd.rename(part, cwd, destination, self.io) catch return .{ .failed = .write_failed };
        metadata.file_mutation.syncContainingDirectory(self.io, destination) catch return .{ .failed = .write_failed };
        return .succeeded;
    }

    fn receive(self: *Download, file: std.Io.File) Outcome {
        const descriptor = self.descriptor;
        var standard: network.StandardTransport = .init(self.allocator, self.io);
        defer standard.deinit();
        var system_clock: network.SystemClock = .{ .io = self.io };
        const random_source: std.Random.IoSource = .{ .io = self.io };
        const clock = self.hooks.clock orelse system_clock.clock();
        var gateway: network.client.Gateway = .{
            .transport = self.hooks.transport orelse standard.transport(),
            .clock = clock,
            .wall_clock = self.hooks.wall_clock orelse system_clock.wallClock(),
            .random = self.hooks.random orelse random_source.interface(),
            .config = .{
                .identity = self.identity.view(),
                .minimum_interval_ms = 0,
                .maximum_attempts = 1,
                .request_timeout_ms = request_timeout_ms,
                .max_response_bytes = descriptor.size,
            },
            .cancel = &self.registration.cancel,
            .sharing = null,
            .deadline_ms = clock.nowMs() +| deadline_ms,
        };
        var receiver: Receiver = .{
            .io = self.io,
            .file = file,
            .received = &self.received,
            .limit = descriptor.size,
        };
        const response = gateway.fetchInto(
            self.allocator,
            descriptor.url,
            &.{},
            redirect_allowance,
            .{ .context = &receiver, .write_fn = Receiver.write },
        ) catch |err| return switch (err) {
            error.Canceled => .cancelled,
            error.Timeout => .{ .failed = .timed_out },
            error.NetworkUnavailable, error.Offline => .{ .failed = .network_unavailable },
            error.RateLimited => .{ .failed = .refused },
            error.RedirectRefused => .{ .failed = .redirect_refused },
            error.ResponseTooLarge => .{ .failed = .mismatch },
            error.SinkFailed => .{ .failed = if (receiver.overflowed) .mismatch else .write_failed },
            else => .{ .failed = .internal },
        };
        defer response.deinit();
        if (response.status != 200) return .{ .failed = .{ .status = response.status } };
        if (self.received.load(.acquire) != descriptor.size) return .{ .failed = .mismatch };
        var digest: [Sha256.digest_length]u8 = undefined;
        receiver.hasher.final(&digest);
        if (!std.mem.eql(u8, &digest, &descriptor.sha256)) return .{ .failed = .mismatch };
        return .succeeded;
    }
};

const Receiver = struct {
    io: std.Io,
    file: std.Io.File,
    hasher: Sha256 = .init(.{}),
    received: *std.atomic.Value(u64),
    limit: u64,
    overflowed: bool = false,

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Receiver = @ptrCast(@alignCast(context));
        const total = self.received.load(.acquire) + bytes.len;
        if (total > self.limit) {
            self.overflowed = true;
            return error.ResponseTooLarge;
        }
        try self.file.writeStreamingAll(self.io, bytes);
        self.hasher.update(bytes);
        self.received.store(total, .release);
    }
};

fn holds(io: std.Io, path: []const u8, descriptor: Descriptor) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    const stat = file.stat(io) catch return false;
    if (stat.size != descriptor.size) return false;
    var hasher: Sha256 = .init(.{});
    var buffer: [network.client.Sink.max_chunk_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < descriptor.size) {
        const read = file.readPositionalAll(io, &buffer, offset) catch return false;
        if (read == 0) return false;
        hasher.update(buffer[0..read]);
        offset += read;
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.mem.eql(u8, &digest, &descriptor.sha256);
}

const TestRig = struct {
    const body_length = 300;
    const url = "https://example.invalid/model.onnx";
    const scratch_bytes = "scratch bytes that must survive";
    const stale_model = "an older model";

    temporary: std.testing.TmpDir,
    transport: network.testing.ScriptedTransport = .{},
    clock: network.testing.TestClock = .{},
    prng: std.Random.DefaultPrng = .init(0x5eed),
    registration: work.Registration = .{},
    host_signal: control.HostSignal = .{},
    body: [body_length]u8,
    destination: []u8,
    part: []u8,

    fn init(self: *TestRig) !void {
        self.* = .{
            .temporary = std.testing.tmpDir(.{}),
            .body = undefined,
            .destination = undefined,
            .part = undefined,
        };
        for (&self.body, 0..) |*byte, index| byte.* = @truncate(index *% 31 +% 7);
        errdefer self.temporary.cleanup();
        self.destination = try self.path("model.onnx");
        errdefer std.testing.allocator.free(self.destination);
        self.part = try self.path("model.onnx" ++ part_suffix);
        self.transport.chunk_bytes = 16;
        self.transport.clock = &self.clock;
    }

    fn deinit(self: *TestRig) void {
        self.transport.deinit();
        std.testing.allocator.free(self.part);
        std.testing.allocator.free(self.destination);
        self.temporary.cleanup();
    }

    fn path(self: *const TestRig, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ self.temporary.sub_path, name });
    }

    fn write(self: *TestRig, name: []const u8, data: []const u8) !void {
        try self.temporary.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data });
    }

    fn transfer(self: *TestRig) !Outcome {
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(&self.body, &digest, .{});
        var download: Download = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .registration = &self.registration,
            .work_handle = .{ .index = 0, .generation = 0 },
            .job = undefined,
            .destination = try .init(self.destination),
            .identity = try .init(.{ .name = "Orca Test", .version = "1.0", .contact = "https://orca.invalid" }),
            .descriptor = .{ .url = url, .size = body_length, .sha256 = digest },
            .hooks = .{
                .transport = self.transport.transport(),
                .clock = self.clock.clock(),
                .wall_clock = self.clock.wallClock(),
                .random = self.prng.random(),
            },
            .host_signal = &self.host_signal,
        };
        return download.transfer();
    }

    fn expectNoPart(self: *const TestRig) !void {
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, self.part, .{ .follow_symlinks = false }));
    }

    fn expectFile(self: *const TestRig, name: []const u8, expected: ?[]const u8) !void {
        const file_path = try self.path(name);
        defer std.testing.allocator.free(file_path);
        const read = std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, std.testing.allocator, .limited(1024)) catch |err| {
            try std.testing.expectEqual(error.FileNotFound, err);
            try std.testing.expectEqual(@as(?[]const u8, null), expected);
            return;
        };
        defer std.testing.allocator.free(read);
        try std.testing.expectEqualStrings(expected.?, read);
    }

    fn expectFailure(self: *TestRig, expected: Failure, existing: ?[]const u8) !void {
        if (existing) |bytes| try self.write("model.onnx", bytes);
        try std.testing.expectEqual(Outcome{ .failed = expected }, try self.transfer());
        try self.expectFile("model.onnx", existing);
        try self.expectNoPart();
    }
};

const stale_model = TestRig.stale_model;
const scratch_bytes = TestRig.scratch_bytes;

test "a failure's reason names the status the server answered with" {
    try std.testing.expectEqualStrings("the server answered 404", (Failure{ .status = 404 }).reason().slice());
    try std.testing.expectEqualStrings("the file could not be written", (Failure{ .write_failed = {} }).reason().slice());
}

test "transfer installs the model and replaces a file already at the destination" {
    for ([_]?[]const u8{ null, stale_model }) |existing| {
        var rig: TestRig = undefined;
        try rig.init();
        defer rig.deinit();
        if (existing) |bytes| try rig.write("model.onnx", bytes);
        try rig.transport.script(.{ .respond = .{ .body = &rig.body } });

        try std.testing.expectEqual(Outcome.succeeded, try rig.transfer());
        try rig.expectFile("model.onnx", &rig.body);
        try rig.expectNoPart();
    }
}

test "transfer reports a short body as a mismatch and keeps the destination" {
    for ([_]?[]const u8{ null, stale_model }) |existing| {
        var rig: TestRig = undefined;
        try rig.init();
        defer rig.deinit();
        try rig.transport.script(.{ .respond = .{ .body = rig.body[0 .. TestRig.body_length - 1] } });
        try rig.expectFailure(.mismatch, existing);
    }
}

test "transfer reports a body longer than declared as a mismatch and keeps the destination" {
    for ([_]?[]const u8{ null, stale_model }) |existing| {
        var rig: TestRig = undefined;
        try rig.init();
        defer rig.deinit();
        var longer: [TestRig.body_length + 1]u8 = undefined;
        @memcpy(longer[0..TestRig.body_length], &rig.body);
        longer[TestRig.body_length] = 0;
        try rig.transport.script(.{ .respond = .{ .body = &longer } });
        try rig.expectFailure(.mismatch, existing);
    }
}

test "transfer reports a body longer than the model as a mismatch when the server declares no length" {
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    var longer: [TestRig.body_length + 1]u8 = undefined;
    @memcpy(longer[0..TestRig.body_length], &rig.body);
    longer[TestRig.body_length] = 0;
    try rig.transport.script(.{ .respond = .{ .body = &longer, .declares_length = false } });
    try rig.expectFailure(.mismatch, stale_model);
}

test "transfer reports a body with the right size and a wrong digest as a mismatch and keeps the destination" {
    for ([_]?[]const u8{ null, stale_model }) |existing| {
        var rig: TestRig = undefined;
        try rig.init();
        defer rig.deinit();
        var altered = rig.body;
        altered[100] ^= 0xff;
        try rig.transport.script(.{ .respond = .{ .body = &altered } });
        try rig.expectFailure(.mismatch, existing);
    }
}

test "transfer reports a non-200 status and keeps the destination" {
    for ([_]u16{ 404, 500 }) |status| {
        var rig: TestRig = undefined;
        try rig.init();
        defer rig.deinit();
        try rig.transport.script(.{ .respond = .{ .status = status, .body = "" } });
        try rig.expectFailure(.{ .status = status }, stale_model);
    }
}

test "transfer reports a 204 answer as a status failure rather than a model" {
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.transport.script(.{ .respond = .{ .status = 204, .body = "" } });
    try rig.expectFailure(.{ .status = 204 }, null);
}

test "transfer reports a connection lost mid-body as unavailable and keeps the destination" {
    for ([_]?[]const u8{ null, stale_model }) |existing| {
        var rig: TestRig = undefined;
        try rig.init();
        defer rig.deinit();
        try rig.transport.script(.{ .respond = .{
            .body = &rig.body,
            .interruption = .{ .after_bytes = 100, .err = error.ConnectionResetByPeer },
        } });
        try rig.expectFailure(.network_unavailable, existing);
    }
}

test "transfer reports a timeout mid-body and keeps the destination" {
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.transport.script(.{ .respond = .{
        .body = &rig.body,
        .interruption = .{ .after_bytes = 100, .err = error.Timeout },
    } });
    try rig.expectFailure(.timed_out, stale_model);
}

test "transfer reports cancellation mid-body and keeps the destination" {
    for ([_]?[]const u8{ null, stale_model }) |existing| {
        var rig: TestRig = undefined;
        try rig.init();
        defer rig.deinit();
        if (existing) |bytes| try rig.write("model.onnx", bytes);
        try rig.transport.script(.{ .respond = .{
            .body = &rig.body,
            .interruption = .{ .after_bytes = 100, .err = error.Canceled },
        } });

        try std.testing.expectEqual(Outcome.cancelled, try rig.transfer());
        try rig.expectFile("model.onnx", existing);
        try rig.expectNoPart();
        try std.testing.expectEqual(@as(u32, 1), rig.transport.requestCount());
    }
}

test "transfer starts no request once cancellation is requested" {
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.registration.requestCancellation();
    try std.testing.expectEqual(Outcome.cancelled, try rig.transfer());
    try std.testing.expectEqual(@as(u32, 0), rig.transport.requestCount());
    try rig.expectFile("model.onnx", null);
    try rig.expectNoPart();
}

test "transfer reports a redirect to another host as refused and keeps the destination" {
    for ([_][]const u8{ "https://evil.example/model.onnx", "http://release.githubusercontent.com/model.onnx" }) |location| {
        var rig: TestRig = undefined;
        try rig.init();
        defer rig.deinit();
        try rig.transport.script(.{ .respond = .{ .status = 302, .body = "", .location = location } });
        try rig.transport.script(.{ .respond = .{ .body = &rig.body } });
        try rig.expectFailure(.redirect_refused, stale_model);
        try std.testing.expectEqual(@as(u32, 1), rig.transport.requestCount());
    }
}

test "transfer follows a redirect to githubusercontent.com" {
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.transport.script(.{ .respond = .{ .status = 302, .body = "", .location = "https://release-assets.githubusercontent.com/model?signature=1" } });
    try rig.transport.script(.{ .respond = .{ .body = &rig.body } });
    try std.testing.expectEqual(Outcome.succeeded, try rig.transfer());
    try rig.expectFile("model.onnx", &rig.body);
}

test "transfer reports an unwritable destination directory and sends no request" {
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.write("blocker", "a file, not a directory");
    std.testing.allocator.free(rig.destination);
    rig.destination = try rig.path("blocker/model.onnx");
    try rig.transport.script(.{ .respond = .{ .body = &rig.body } });

    try std.testing.expectEqual(Outcome{ .failed = .write_failed }, try rig.transfer());
    try rig.expectFile("blocker", "a file, not a directory");
    try std.testing.expectEqual(@as(u32, 0), rig.transport.requestCount());
}

test "transfer reports a .part path it cannot replace as a write failure" {
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.temporary.dir.createDir(std.testing.io, "model.onnx" ++ part_suffix, .default_dir);
    try rig.write("model.onnx", stale_model);
    try rig.transport.script(.{ .respond = .{ .body = &rig.body } });

    try std.testing.expectEqual(Outcome{ .failed = .write_failed }, try rig.transfer());
    try rig.expectFile("model.onnx", stale_model);
    try std.testing.expectEqual(@as(u32, 0), rig.transport.requestCount());
}

test "transfer leaves the file a symlink at .part points to untouched when the download succeeds" {
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.write("scratch", scratch_bytes);
    try rig.temporary.dir.symLink(std.testing.io, "scratch", "model.onnx" ++ part_suffix, .{});
    try rig.transport.script(.{ .respond = .{ .body = &rig.body } });

    try std.testing.expectEqual(Outcome.succeeded, try rig.transfer());
    try rig.expectFile("scratch", scratch_bytes);
    try rig.expectFile("model.onnx", &rig.body);
    try rig.expectNoPart();
}

test "transfer leaves the file a symlink at .part points to untouched when the download fails" {
    for ([_]u16{ 404, 200 }) |status| {
        var rig: TestRig = undefined;
        try rig.init();
        defer rig.deinit();
        try rig.write("scratch", scratch_bytes);
        try rig.temporary.dir.symLink(std.testing.io, "scratch", "model.onnx" ++ part_suffix, .{});
        try rig.transport.script(.{ .respond = .{ .status = status, .body = rig.body[0..10] } });

        try std.testing.expect((try rig.transfer()) == .failed);
        try rig.expectFile("scratch", scratch_bytes);
        try rig.expectFile("model.onnx", null);
        try rig.expectNoPart();
    }
}

test "transfer creates nothing through a dangling symlink at .part" {
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.temporary.dir.symLink(std.testing.io, "scratch", "model.onnx" ++ part_suffix, .{});
    try rig.transport.script(.{ .respond = .{ .body = &rig.body } });

    try std.testing.expectEqual(Outcome.succeeded, try rig.transfer());
    try rig.expectFile("scratch", null);
    try rig.expectFile("model.onnx", &rig.body);
}

test "transfer replaces a symlink at the destination with the model and leaves its target untouched" {
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.write("scratch", stale_model);
    try rig.temporary.dir.symLink(std.testing.io, "scratch", "model.onnx", .{});
    try rig.transport.script(.{ .respond = .{ .body = &rig.body } });

    try std.testing.expectEqual(Outcome.succeeded, try rig.transfer());
    try rig.expectFile("scratch", stale_model);
    try rig.expectFile("model.onnx", &rig.body);
    var link: [64]u8 = undefined;
    try std.testing.expectError(error.NotLink, rig.temporary.dir.readLink(std.testing.io, "model.onnx", &link));
}

test "transfer treats a destination that already holds the model as installed and sends no request" {
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.write("model.onnx", &rig.body);

    try std.testing.expectEqual(Outcome.succeeded, try rig.transfer());
    try std.testing.expectEqual(@as(u32, 0), rig.transport.requestCount());
    try rig.expectNoPart();
}
