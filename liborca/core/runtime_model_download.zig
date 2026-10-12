const std = @import("std");
const audio_embedding = @import("../analysis/audio_embedding.zig");
const embedding_model = @import("embedding_model.zig");
const job_worker = @import("job_worker.zig");
const model_download = @import("model_download.zig");
const runtime = @import("runtime.zig");
const runtime_listens = @import("runtime_listens.zig");
const work = @import("work.zig");

const Download = model_download.Download;
const JobHandle = runtime.JobHandle;
const OrcaRuntime = runtime.OrcaRuntime;

pub fn start(self: *OrcaRuntime, model: audio_embedding.ModelId, destination: []const u8) !JobHandle {
    try runtime.requireRunning(self);
    if (!audio_embedding.enabled) return error.EmbeddingsNotBuilt;
    const identity = self.client_identity orelse return error.ClientIdentityRequired;
    if (destination.len == 0) return error.InvalidArgument;
    if (self.model_download != null) return error.ModelDownloadAlreadyRunning;
    const owned_destination: embedding_model.OwnedPath = try .init(destination);
    const io = try runtime_listens.networkIo(self);
    const descriptor = self.model_download_hooks.descriptor orelse model_download.Descriptor.of(model);

    const download = try self.allocator.create(Download);
    errdefer self.allocator.destroy(download);
    const job_handle = try self.jobs.create(.model_download, descriptor.size);
    errdefer self.jobs.finish(job_handle, .failed) catch {};
    try self.jobs.start(job_handle, runtime_listens.sampleTime(self).wall_s);

    const work_handle = try self.work_registry.begin(work.unowned);
    const registration = self.work_registry.registration(work_handle) catch unreachable;
    errdefer {
        registration.finish();
        self.work_registry.complete(work_handle) catch {};
    }
    download.* = .{
        .allocator = self.allocator,
        .io = io,
        .registration = registration,
        .work_handle = work_handle,
        .job = job_handle,
        .destination = owned_destination,
        .identity = identity,
        .descriptor = descriptor,
        .hooks = self.model_download_hooks,
        .host_signal = &self.host_signal,
    };
    registration.thread = try std.Thread.spawn(.{}, Download.run, .{download});
    self.model_download = download;
    return job_handle;
}

pub fn cancel(self: *OrcaRuntime, job_handle: JobHandle) void {
    const download = self.model_download orelse return;
    if (download.joined or !download.job.eql(job_handle)) return;
    download.registration.requestCancellation();
}

pub fn syncProgress(self: *OrcaRuntime, now_ms: i64) void {
    const download = self.model_download orelse return;
    self.jobs.observeProgress(download.job, download.received.load(.acquire)) catch {};
    self.jobs.sampleProgress(download.job, now_ms) catch {};
}

pub fn publishProgress(self: *OrcaRuntime) void {
    const download = self.model_download orelse return;
    if (download.isFinished()) return;
    const snapshot = self.jobs.snapshot(download.job) catch return;
    const current: job_worker.PublishedProgress = .{
        .completed_units = snapshot.completed_units,
        .total_units = snapshot.total_units,
        .state = snapshot.state,
    };
    if (download.published) |published| if (std.meta.eql(published, current)) return;
    self.telemetry.publish(.{ .job_progress = .{
        .job = download.job,
        .completed_units = current.completed_units,
        .total_units = current.total_units,
    } }) catch return;
    download.published = current;
}

pub fn pumpDueMs(self: *const OrcaRuntime, running_ms: u64) ?u64 {
    const download = self.model_download orelse return null;
    return if (download.isFinished()) 0 else running_ms;
}

pub fn reap(self: *OrcaRuntime) void {
    const download = self.model_download orelse return;
    if (!download.isFinished() or !self.events.hasCapacity()) return;
    if (!download.joined) self.work_registry.complete(download.work_handle) catch {};
    finalize(self, download, true);
}

/// Control lane, immediately after a `work_registry.drain()` the runtime
/// keeps running past: the thread is joined and its registration freed, so
/// the next `reap` must not touch either.
pub fn markDrained(self: *OrcaRuntime) void {
    if (self.model_download) |download| download.joined = true;
}

pub fn finalizeDrained(self: *OrcaRuntime) void {
    if (self.model_download) |download| finalize(self, download, false);
}

fn finalize(self: *OrcaRuntime, download: *Download, announce: bool) void {
    self.model_download = null;
    defer self.allocator.destroy(download);
    const outcome = download.outcome;
    self.jobs.observeProgress(download.job, download.received.load(.acquire)) catch {};
    switch (outcome) {
        .failed => |failure| self.jobs.setDetail(download.job, failure.reason().slice()) catch {},
        .succeeded, .cancelled => {},
    }
    self.jobs.finish(download.job, outcome.state()) catch {};
    if (!announce) return;
    if (outcome == .succeeded)
        self.embedding_model.set(self.allocator, self.control_threaded.io(), download.destination.view()) catch {};
    self.events.publish(.{
        .request_id = 0,
        .outcome = .{ .job_finished = .{ .job = download.job, .state = outcome.state() } },
    }) catch {};
}
