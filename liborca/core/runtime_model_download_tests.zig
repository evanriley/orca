const std = @import("std");
const builtin = @import("builtin");
const audio_embedding = @import("../analysis/audio_embedding.zig");
const control = @import("control.zig");
const job = @import("job.zig");
const model_download = @import("model_download.zig");
const network = @import("../network/root.zig");
const runtime_jobs = @import("runtime_jobs.zig");
const runtime_module = @import("runtime.zig");
const runtime_tests = @import("runtime_tests.zig");

const EmbeddingModelState = runtime_module.EmbeddingModelState;
const JobHandle = runtime_module.JobHandle;
const OrcaRuntime = runtime_module.OrcaRuntime;
const Reply = network.testing.Reply;

const testing = std.testing;

const asset_url = "https://release-assets.githubusercontent.com/model?signature=1";
const previous = "the file that was there before";

const body = bytes: {
    var bytes: [300]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index *% 31 +% 7);
    break :bytes bytes;
};

fn descriptorOf(bytes: []const u8) model_download.Descriptor {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .url = audio_embedding.ModelId.clap_htsat_unfused.spec().url, .size = bytes.len, .sha256 = digest };
}

const Rig = struct {
    temporary: testing.TmpDir,
    transport: network.testing.ScriptedTransport = .{},
    clock: network.testing.TestClock = .{},
    prng: std.Random.DefaultPrng = .init(0x5eed),
    runtime: OrcaRuntime,
    runtime_live: bool = true,
    destination: []u8,
    part: []u8,

    fn init(self: *Rig, name: []const u8) !void {
        if (!audio_embedding.enabled) return error.SkipZigTest;
        self.* = .{
            .temporary = testing.tmpDir(.{}),
            .runtime = OrcaRuntime.init(testing.allocator),
            .destination = undefined,
            .part = undefined,
        };
        errdefer self.temporary.cleanup();
        errdefer self.runtime.deinit();
        self.destination = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ self.temporary.sub_path, name });
        errdefer testing.allocator.free(self.destination);
        self.part = try std.mem.concat(testing.allocator, u8, &.{ self.destination, model_download.part_suffix });
        errdefer testing.allocator.free(self.part);
        self.transport.clock = &self.clock;
        self.runtime.model_download_hooks = .{
            .transport = self.transport.transport(),
            .clock = self.clock.clock(),
            .wall_clock = self.clock.wallClock(),
            .random = self.prng.random(),
            .descriptor = descriptorOf(&body),
        };
        try self.runtime.setClientIdentity(network.testing.test_identity);
    }

    fn deinit(self: *Rig) void {
        self.stop();
        self.transport.deinit();
        testing.allocator.free(self.part);
        testing.allocator.free(self.destination);
        self.temporary.cleanup();
    }

    fn stop(self: *Rig) void {
        if (!self.runtime_live) return;
        self.runtime_live = false;
        self.runtime.deinit();
    }

    fn start(self: *Rig) !JobHandle {
        return self.runtime.startEmbeddingModelDownload(.clap_htsat_unfused, self.destination);
    }

    fn keepPrevious(self: *Rig) !void {
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = self.destination, .data = previous });
    }

    fn expectDestination(self: *Rig, expected: []const u8) !void {
        const found = try std.Io.Dir.cwd().readFileAlloc(testing.io, self.destination, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(found);
        try testing.expectEqualSlices(u8, expected, found);
    }

    fn expectNoPart(self: *Rig) !void {
        try expectAbsent(self.part);
    }

    fn awaitRequests(self: *Rig, count: u32) !void {
        var deadline: runtime_tests.TestDeadline = .init(5_000);
        while (self.transport.requestCount() < count and deadline.tick()) {}
        try testing.expectEqual(count, self.transport.requestCount());
    }

    fn expectFailure(self: *Rig, reason: []const u8, requests: u32) !void {
        try self.keepPrevious();
        const job_handle = try self.start();
        try testing.expectEqual(job.State.failed, try runtime_tests.awaitJob(&self.runtime, job_handle));
        const snapshot = try self.runtime.jobSnapshotSynced(job_handle);
        try testing.expectEqualStrings(reason, snapshot.detail.slice());
        try testing.expectEqual(requests, self.transport.requestCount());
        try self.expectDestination(previous);
        try self.expectNoPart();
        try testing.expectEqual(EmbeddingModelState.missing, self.runtime.embeddingModelState());
    }
};

fn expectAbsent(path: []const u8) !void {
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, path, .{}));
}

fn redirect(location: []const u8) Reply {
    return .{ .respond = .{ .status = 302, .body = "", .location = location } };
}

fn finishedEvent(runtime: *OrcaRuntime, job_handle: JobHandle) ?job.State {
    var state: ?job.State = null;
    while (runtime.pollEvent()) |event| switch (event.outcome) {
        .job_finished => |finished| {
            if (finished.job.eql(job_handle)) state = finished.state;
        },
        else => {},
    };
    return state;
}

const HalfwayTransport = struct {
    halfway: std.atomic.Value(bool) = .init(false),

    const half = body.len / 2;

    fn transport(self: *HalfwayTransport) network.client.Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn perform(context: *anyopaque, _: std.mem.Allocator, request: network.client.Request) anyerror!network.client.Response {
        const self: *HalfwayTransport = @ptrCast(@alignCast(context));
        try request.sink.?.write(body[0..half]);
        self.halfway.store(true, .release);
        var deadline: runtime_tests.TestDeadline = .init(10_000);
        while (deadline.tick()) {
            if (request.cancel.?.load(.acquire)) return error.Canceled;
        }
        return error.Timeout;
    }
};

test "startEmbeddingModelDownload_redirectedToTheAssetHost_installsTheFileAndPublishesJobFinished" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try rig.transport.script(redirect(asset_url));
    try rig.transport.script(.{ .respond = .{ .body = &body } });

    const job_handle = try rig.start();
    try testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&rig.runtime, job_handle));

    const snapshot = try rig.runtime.jobSnapshotSynced(job_handle);
    try testing.expectEqual(job.Kind.model_download, snapshot.kind);
    try testing.expectEqual(@as(u64, body.len), snapshot.completed_units);
    try testing.expectEqual(@as(?u64, body.len), snapshot.total_units);
    try testing.expectEqualStrings("", snapshot.detail.slice());
    try testing.expectEqual(@as(u32, 2), rig.transport.requestCount());
    try testing.expectEqualStrings(asset_url, rig.transport.lastUrl());
    try testing.expectEqualStrings("", rig.transport.lastAuthorization());
    try rig.expectDestination(&body);
    try rig.expectNoPart();
    try testing.expectEqual(@as(?job.State, .succeeded), finishedEvent(&rig.runtime, job_handle));
}

test "startEmbeddingModelDownload_succeeded_namesTheFileToTheRuntimeWhenReaped" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try rig.transport.script(.{ .respond = .{ .body = &body } });
    try testing.expectEqual(EmbeddingModelState.missing, rig.runtime.embeddingModelState());

    const job_handle = try rig.start();
    try testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&rig.runtime, job_handle));

    try testing.expectEqualStrings(rig.destination, rig.runtime.embedding_model.path.?.view());
    try testing.expectEqual(EmbeddingModelState.wrong_file, rig.runtime.embeddingModelState());
}

fn expectRealModelDownload(id: audio_embedding.ModelId) !void {
    const model_path = try audio_embedding.testModelPath(id);
    const spec = id.spec();
    var rig: Rig = undefined;
    try rig.init(spec.file_name);
    defer rig.deinit();
    const model = try std.Io.Dir.cwd().readFileAlloc(testing.io, model_path, testing.allocator, .limited(spec.size + 1));
    defer testing.allocator.free(model);
    rig.runtime.model_download_hooks.descriptor = null;
    rig.transport.chunk_bytes = network.client.Sink.max_chunk_bytes;
    try rig.transport.script(redirect(asset_url));
    try rig.transport.script(.{ .respond = .{ .body = model } });

    const job_handle = try rig.runtime.startEmbeddingModelDownload(id, rig.destination);
    try testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&rig.runtime, job_handle));

    try testing.expectEqual(@as(u64, spec.size), (try rig.runtime.jobSnapshotSynced(job_handle)).completed_units);
    try testing.expectEqual(EmbeddingModelState.ready, rig.runtime.embeddingModelState());
    try testing.expectEqual(@as(?audio_embedding.ModelId, id), rig.runtime.embeddingModel());
    try rig.expectNoPart();
}

test "startEmbeddingModelDownload_theRealModel_leavesTheRuntimeReady" {
    try expectRealModelDownload(.clap_htsat_unfused);
}

test "startEmbeddingModelDownload_theRealMaestModel_leavesTheRuntimeReadyWithMaest" {
    try expectRealModelDownload(.discogs_maest);
}

test "descriptorOf_eachModel_namesItsOwnReleaseAsset" {
    const clap = model_download.Descriptor.of(.clap_htsat_unfused);
    try testing.expectEqualStrings(
        "https://github.com/evanriley/orca/releases/download/model-clap-int8-1/clap_audio_int8.onnx",
        clap.url,
    );
    try testing.expectEqual(@as(usize, 32_587_451), clap.size);
    try testing.expectEqualStrings(
        "12d3e2c1593ba111df6103feac2f3ce4f4e85e5efc2ad927ac16a8402e7b3c36",
        &std.fmt.bytesToHex(clap.sha256, .lower),
    );
    const maest = model_download.Descriptor.of(.discogs_maest);
    try testing.expectEqualStrings(
        "https://github.com/evanriley/orca/releases/download/model-maest-int8-1/maest_audio_int8.onnx",
        maest.url,
    );
    try testing.expectEqual(@as(usize, 80_400_354), maest.size);
    try testing.expectEqualStrings(
        "fcdf35e3b8737cb0853bb83cadd7a62885f70f1afe30cde3f185e61eb06d843e",
        &std.fmt.bytesToHex(maest.sha256, .lower),
    );
}

test "startEmbeddingModelDownload_bodyWithAnotherDigest_failsAndKeepsTheDestination" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    var other = body;
    other[body.len / 2] ^= 1;
    try rig.transport.script(.{ .respond = .{ .body = &other } });

    try rig.expectFailure("the downloaded file is not the expected model", 1);
}

test "startEmbeddingModelDownload_bodyShorterThanTheModel_failsAndKeepsTheDestination" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try rig.transport.script(.{ .respond = .{ .body = body[0 .. body.len - 1] } });

    try rig.expectFailure("the downloaded file is not the expected model", 1);
}

test "startEmbeddingModelDownload_bodyDeclaredLongerThanTheModel_failsAndKeepsTheDestination" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try rig.transport.script(.{ .respond = .{ .body = &(body ++ [_]u8{0}) } });

    try rig.expectFailure("the downloaded file is not the expected model", 1);
}

test "startEmbeddingModelDownload_bodyLongerThanTheModelWithoutALength_failsAndKeepsTheDestination" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try rig.transport.script(.{ .respond = .{ .body = &(body ++ [_]u8{0}), .declares_length = false } });

    try rig.expectFailure("the downloaded file is not the expected model", 1);
}

test "startEmbeddingModelDownload_status404_failsNamingTheStatus" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try rig.transport.script(.{ .respond = .{ .status = 404, .body = "Not Found" } });

    try rig.expectFailure("the server answered 404", 1);
}

test "startEmbeddingModelDownload_status206_failsThoughTheBodyIsTheModel" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try rig.transport.script(.{ .respond = .{ .status = 206, .body = &body } });

    try rig.expectFailure("the server answered 206", 1);
}

test "startEmbeddingModelDownload_redirectedToAnotherHost_failsWithoutFollowingIt" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try rig.transport.script(redirect("https://githubusercontent.com.example.org/model"));
    try rig.transport.script(.{ .respond = .{ .body = &body } });

    try rig.expectFailure("the server redirected somewhere unexpected", 1);
}

test "startEmbeddingModelDownload_redirectedToPlainHttp_failsWithoutFollowingIt" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try rig.transport.script(redirect("http://release-assets.githubusercontent.com/model"));
    try rig.transport.script(.{ .respond = .{ .body = &body } });

    try rig.expectFailure("the server redirected somewhere unexpected", 1);
}

test "startEmbeddingModelDownload_connectionLostMidBody_failsAndRemovesThePart" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try rig.transport.script(.{ .respond = .{
        .body = &body,
        .interruption = .{ .after_bytes = 100, .err = error.ConnectionResetByPeer },
    } });

    try rig.expectFailure("the network is unavailable", 1);
}

test "startEmbeddingModelDownload_noBytesForThirtySeconds_failsAsTimedOut" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try rig.transport.script(.{ .respond = .{ .body = &body, .chunk_wait_ms = model_download.request_timeout_ms } });

    try rig.expectFailure("the download timed out", 1);
    try testing.expectEqual(@as(u64, model_download.request_timeout_ms), rig.transport.timeout_ms);
}

test "startEmbeddingModelDownload_failingRequestOrHop_isNotRetried" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try rig.transport.script(.{ .respond = .{ .status = 503, .body = "" } });
    try rig.transport.script(redirect(asset_url));
    try rig.transport.script(.{ .fail = error.ConnectionRefused });
    rig.transport.otherwise = .{ .respond = .{ .body = &body } };

    try rig.expectFailure("the server answered 503", 1);
    try rig.expectFailure("the network is unavailable", 3);
}

test "cancelJob_midBody_endsTheDownloadCancelledAndRemovesThePart" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    var halfway: HalfwayTransport = .{};
    rig.runtime.model_download_hooks.transport = halfway.transport();
    try rig.keepPrevious();

    const job_handle = try rig.start();
    var deadline: runtime_tests.TestDeadline = .init(5_000);
    while (!halfway.halfway.load(.acquire) and deadline.tick()) {}
    const running = try rig.runtime.jobSnapshotSynced(job_handle);
    try testing.expectEqual(job.State.running, running.state);
    try testing.expectEqual(@as(u64, HalfwayTransport.half), running.completed_units);
    try testing.expectEqual(@as(u64, HalfwayTransport.half), (try std.Io.Dir.cwd().statFile(testing.io, rig.part, .{})).size);
    try testing.expectError(error.JobNotPausable, rig.runtime.pauseJob(job_handle));

    try rig.runtime.cancelJob(job_handle);
    try testing.expectEqual(job.State.cancelled, try runtime_tests.awaitJob(&rig.runtime, job_handle));
    try testing.expectEqualStrings("", (try rig.runtime.jobSnapshotSynced(job_handle)).detail.slice());
    try rig.expectDestination(previous);
    try rig.expectNoPart();
    try testing.expectEqual(@as(?job.State, .cancelled), finishedEvent(&rig.runtime, job_handle));
}

test "startEmbeddingModelDownload_destinationDirectoryMissing_createsIt" {
    var rig: Rig = undefined;
    try rig.init("models/clap/model.onnx");
    defer rig.deinit();
    try rig.transport.script(.{ .respond = .{ .body = &body } });

    const job_handle = try rig.start();
    try testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&rig.runtime, job_handle));
    try rig.expectDestination(&body);
    try rig.expectNoPart();
}

test "startEmbeddingModelDownload_destinationDirectoryNotWritable_failsWithTheWriteReason" {
    if (builtin.os.tag != .linux or std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var rig: Rig = undefined;
    try rig.init("locked/model.onnx");
    defer rig.deinit();
    try rig.temporary.dir.createDir(testing.io, "locked", .default_dir);
    try rig.temporary.dir.setFilePermissions(testing.io, "locked", .fromMode(0o555), .{});
    defer rig.temporary.dir.setFilePermissions(testing.io, "locked", .default_dir, .{}) catch {};
    try rig.transport.script(.{ .respond = .{ .body = &body } });

    const job_handle = try rig.start();
    try testing.expectEqual(job.State.failed, try runtime_tests.awaitJob(&rig.runtime, job_handle));
    try testing.expectEqualStrings("the file could not be written", (try rig.runtime.jobSnapshotSynced(job_handle)).detail.slice());
    try testing.expectEqual(@as(u32, 0), rig.transport.requestCount());
    try expectAbsent(rig.destination);
    try rig.expectNoPart();
}

test "startEmbeddingModelDownload_destinationAlreadyTheModel_succeedsWithoutARequest" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = rig.destination, .data = &body });

    const job_handle = try rig.start();
    try testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&rig.runtime, job_handle));

    const snapshot = try rig.runtime.jobSnapshotSynced(job_handle);
    try testing.expectEqual(@as(u64, body.len), snapshot.completed_units);
    try testing.expectEqual(@as(u32, 0), rig.transport.requestCount());
    try rig.expectDestination(&body);
    try rig.expectNoPart();
}

test "startEmbeddingModelDownload_whileOneRuns_isRefusedUntilItHasFinished" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try rig.transport.script(.hang);
    try rig.transport.script(.{ .respond = .{ .body = &body } });

    const first = try rig.start();
    try rig.awaitRequests(1);
    try testing.expectError(error.ModelDownloadAlreadyRunning, rig.start());
    try rig.runtime.cancelJob(first);
    try testing.expectEqual(job.State.cancelled, try runtime_tests.awaitJob(&rig.runtime, first));

    const second = try rig.start();
    try testing.expect(!second.eql(first));
    try testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&rig.runtime, second));
    try rig.expectDestination(&body);
}

test "startEmbeddingModelDownload_withoutAClientIdentity_isRefusedAndNothingIsSent" {
    if (!audio_embedding.enabled) return error.SkipZigTest;
    var transport: network.testing.ScriptedTransport = .{};
    defer transport.deinit();
    var runtime = OrcaRuntime.init(testing.allocator);
    defer runtime.deinit();
    runtime.model_download_hooks.transport = transport.transport();

    try testing.expectError(error.ClientIdentityRequired, runtime.startEmbeddingModelDownload(.clap_htsat_unfused, "model.onnx"));
    try testing.expectEqual(@as(u32, 0), transport.requestCount());
    try expectAbsent("model.onnx" ++ model_download.part_suffix);
}

test "startEmbeddingModelDownload_builtWithoutEmbeddings_isRefused" {
    if (audio_embedding.enabled) return error.SkipZigTest;
    var runtime = OrcaRuntime.init(testing.allocator);
    defer runtime.deinit();
    try runtime.setClientIdentity(network.testing.test_identity);

    try testing.expectError(error.EmbeddingsNotBuilt, runtime.startEmbeddingModelDownload(.clap_htsat_unfused, "model.onnx"));
}

test "startEmbeddingModelDownload_pathLongerThanAPathMayBe_isRefused" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    const long: [std.Io.Dir.max_path_bytes + 1]u8 = @splat('a');

    try testing.expectError(error.NameTooLong, rig.runtime.startEmbeddingModelDownload(.clap_htsat_unfused, &long));
    try testing.expectEqual(@as(?u64, null), rig.runtime.nextPumpTimeoutMs());
}

test "startEmbeddingModelDownload_emptyPath_isRefused" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();

    try testing.expectError(error.InvalidArgument, rig.runtime.startEmbeddingModelDownload(.clap_htsat_unfused, ""));
    try testing.expectEqual(@as(?u64, null), rig.runtime.nextPumpTimeoutMs());
}

test "deinit_whileADownloadHangs_returnsAndLeavesNoPart" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try rig.transport.script(.hang);
    try rig.keepPrevious();

    _ = try rig.start();
    try rig.awaitRequests(1);
    try testing.expectEqual(@as(u64, 0), (try std.Io.Dir.cwd().statFile(testing.io, rig.part, .{})).size);
    rig.stop();

    try rig.expectDestination(previous);
    try rig.expectNoPart();
}

test "pump_whileADownloadRuns_publishesProgressAndIsDueUntilItIsReaped" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    var counter: control.CountingWaker = .{};
    try rig.runtime.setWaker(counter.waker());
    try rig.transport.script(.hang);
    try testing.expectEqual(@as(?u64, null), rig.runtime.nextPumpTimeoutMs());

    const job_handle = try rig.start();
    try rig.awaitRequests(1);
    try testing.expectEqual(@as(?u64, runtime_jobs.job_progress_interval_ms), rig.runtime.nextPumpTimeoutMs());
    rig.runtime.pump();
    var progress: ?u64 = null;
    while (rig.runtime.pollTelemetry()) |telemetry| switch (telemetry) {
        .job_progress => |value| {
            if (value.job.eql(job_handle)) progress = value.total_units;
        },
        else => {},
    };
    try testing.expectEqual(@as(?u64, body.len), progress);

    try rig.runtime.cancelJob(job_handle);
    var deadline: runtime_tests.TestDeadline = .init(5_000);
    while (counter.count() == 0 and deadline.tick()) {}
    try testing.expectEqual(@as(u32, 1), counter.count());
    try testing.expectEqual(@as(?u64, 0), rig.runtime.nextPumpTimeoutMs());
    rig.runtime.pump();
    try testing.expectEqual(@as(?job.State, .cancelled), finishedEvent(&rig.runtime, job_handle));
    try testing.expectEqual(@as(?u64, null), rig.runtime.nextPumpTimeoutMs());
}

test "destroyLibrary_whileADownloadRuns_cancelsItAndTheNextPumpPublishesJobFinished" {
    var rig: Rig = undefined;
    try rig.init("model.onnx");
    defer rig.deinit();
    try rig.transport.script(.hang);
    try rig.transport.script(.{ .respond = .{ .body = &body } });
    const library = try rig.runtime.openLibrary(testing.io, "file:orca-model-download-drain?mode=memory&cache=shared");

    const job_handle = try rig.start();
    try rig.awaitRequests(1);
    try rig.runtime.destroyLibrary(library);
    try testing.expectError(error.ModelDownloadAlreadyRunning, rig.start());
    try rig.runtime.cancelJob(job_handle);
    try testing.expectEqual(@as(?u64, 0), rig.runtime.nextPumpTimeoutMs());

    rig.runtime.pump();
    try testing.expectEqual(job.State.cancelled, (try rig.runtime.jobSnapshotSynced(job_handle)).state);
    try testing.expectEqual(@as(?job.State, .cancelled), finishedEvent(&rig.runtime, job_handle));
    try rig.expectNoPart();
    try testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&rig.runtime, try rig.start()));
}
