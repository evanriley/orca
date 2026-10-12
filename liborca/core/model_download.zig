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
        {
            const file = cwd.createFile(self.io, part, .{ .truncate = true }) catch return .{ .failed = .write_failed };
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

test "a failure's reason names the status the server answered with" {
    try std.testing.expectEqualStrings("the server answered 404", (Failure{ .status = 404 }).reason().slice());
    try std.testing.expectEqualStrings("the file could not be written", (Failure{ .write_failed = {} }).reason().slice());
}
