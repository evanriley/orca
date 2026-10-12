const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const app = @import("app.zig");
const preferences = @import("preferences.zig");
const analysis_notice = @import("analysis_notice.zig");

const App = app.App;

pub const file_name = "clap_audio_int8.onnx";
pub const environment_variable = "ORCA_EMBEDDING_MODEL";

const user_pattern = "{s}/orca/models/" ++ file_name;
const bundled_pattern = "{s}/share/orca/models/" ++ file_name;

pub const Places = struct {
    override: ?[]const u8,
    user_data_dir: []const u8,
    executable_dir: ?[]const u8,
};

pub fn choose(buffer: []u8, places: Places, context: anytype) error{NoSpaceLeft}![]const u8 {
    if (places.override) |path| if (path.len != 0) return std.fmt.bufPrint(buffer, "{s}", .{path});
    const user = try std.fmt.bufPrint(buffer, user_pattern, .{places.user_data_dir});
    if (context.isFile(user)) return user;
    const prefix = std.fs.path.dirname(places.executable_dir orelse return user) orelse return user;
    var bundled_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const bundled = std.fmt.bufPrint(&bundled_buffer, bundled_pattern, .{prefix}) catch return user;
    if (!context.isFile(bundled)) return user;
    return std.fmt.bufPrint(buffer, "{s}", .{bundled});
}

pub const model_bytes: u64 = 32_587_451;
const download_host = "github.com";

pub const Download = union(enum) {
    idle,
    running: liborca.JobHandle,
    failed: liborca.JobHandle,
    refused: []const u8,
};

pub const Progress = struct {
    received_bytes: u64,
    total_bytes: u64,
};

pub const Shown = union(enum) {
    idle,
    running: Progress,
    failed: []const u8,
};

pub const Action = enum { none, download, cancel };

pub const Status = struct {
    title: [:0]const u8,
    subtitle: [:0]const u8,
    can_check_again: bool,
    action: Action = .none,
};

pub const Request = struct {
    state: liborca.EmbeddingModelState,
    path: []const u8,
    overridden: bool,
    download: Shown,
};

const Megabytes = struct {
    bytes: u64,

    pub fn format(self: Megabytes, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const tenths = (self.bytes + 50_000) / 100_000;
        try writer.print("{d}.{d}", .{ tenths / 10, tenths % 10 });
    }
};

pub fn status(buffer: []u8, request: Request) Status {
    const path = request.path;
    switch (request.state) {
        .ready => return .{ .title = "Model installed", .subtitle = terminated(buffer, path), .can_check_again = false },
        .built_without => return .{
            .title = "Not available in this build",
            .subtitle = "This build of Orca was made without ONNX Runtime.",
            .can_check_again = false,
        },
        .missing, .wrong_file, .unusable => {},
    }
    switch (request.download) {
        .running => |progress| return .{
            .title = "Downloading the model",
            .subtitle = print(buffer, "{f} of {f} MB", .{
                Megabytes{ .bytes = progress.received_bytes },
                Megabytes{ .bytes = progress.total_bytes },
            }),
            .can_check_again = false,
            .action = .cancel,
        },
        .idle, .failed => {},
    }
    const title: [:0]const u8 = switch (request.state) {
        .missing => "Model not installed",
        .wrong_file => "That file is not Orca's model",
        .unusable => "The model could not be loaded",
        .ready, .built_without => unreachable,
    };
    if (request.overridden) return .{
        .title = title,
        .subtitle = if (request.state == .missing)
            print(buffer, "Put {s} in {s}, then check again.", .{ std.fs.path.basename(path), directory(path) })
        else
            terminated(buffer, path),
        .can_check_again = true,
    };
    return .{
        .title = title,
        .subtitle = switch (request.download) {
            .failed => |reason| failure(buffer, reason),
            .idle, .running => if (request.state == .missing)
                print(buffer, "Download it ({f} MB) from " ++ download_host ++ ", or put {s} in {s} and check again.", .{
                    Megabytes{ .bytes = model_bytes },
                    std.fs.path.basename(path),
                    directory(path),
                })
            else
                print(buffer, "{s}. Download fetches the model ({f} MB) from " ++ download_host ++ ".", .{
                    path,
                    Megabytes{ .bytes = model_bytes },
                }),
        },
        .can_check_again = true,
        .action = .download,
    };
}

fn failure(buffer: []u8, reason: []const u8) [:0]const u8 {
    const sentence = std.mem.trimEnd(u8, reason, ".");
    if (sentence.len == 0) return "The download failed.";
    return print(buffer, "The download failed. {c}{s}.", .{ std.ascii.toUpper(sentence[0]), sentence[1..] });
}

fn directory(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

fn print(buffer: []u8, comptime pattern: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.bufPrintSentinel(buffer, pattern, args, 0) catch "";
}

fn terminated(buffer: []u8, text: []const u8) [:0]const u8 {
    return print(buffer, "{s}", .{text});
}

const Files = struct {
    io: std.Io,

    pub fn isFile(self: Files, path: []const u8) bool {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
        return stat.kind == .file;
    }
};

pub fn apply(self: *App) void {
    var executable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_dir: ?[]const u8 = if (std.process.executableDirPath(self.io, &executable_buffer)) |length|
        executable_buffer[0..length]
    else |_|
        null;
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = choose(&buffer, .{
        .override = self.embedding_model_override,
        .user_data_dir = std.mem.span(gtk.g_get_user_data_dir()),
        .executable_dir = executable_dir,
    }, Files{ .io = self.io }) catch |err| {
        std.log.warn("The audio-embedding model's path is too long to use ({t})", .{err});
        return;
    };
    self.embedding_model_path.set(self.allocator, path);
    self.runtime.setEmbeddingModelPath(path) catch |err|
        std.log.warn("Could not check the audio-embedding model at {s} ({t})", .{ path, err });
}

fn overridden(self: *const App) bool {
    return if (self.embedding_model_override) |path| path.len != 0 else false;
}

fn userPath(buffer: []u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, user_pattern, .{std.mem.span(gtk.g_get_user_data_dir())});
}

pub fn shownStatus(self: *App, buffer: []u8) Status {
    var snapshot: ?liborca.JobSnapshot = null;
    const download: Shown = switch (self.embedding_model_download) {
        .idle => .idle,
        .refused => |reason| .{ .failed = reason },
        .running, .failed => |job| shown: {
            snapshot = self.runtime.jobSnapshotSynced(job) catch break :shown .idle;
            const read = &snapshot.?;
            if (self.embedding_model_download == .failed) break :shown .{ .failed = read.detail.slice() };
            break :shown .{ .running = .{
                .received_bytes = read.completed_units,
                .total_bytes = read.total_units orelse model_bytes,
            } };
        },
    };
    return status(buffer, .{
        .state = self.runtime.embeddingModelState(),
        .path = self.embedding_model_path.value,
        .overridden = overridden(self),
        .download = download,
    });
}

fn startRefusal(err: anyerror) []const u8 {
    return switch (err) {
        error.ModelDownloadAlreadyRunning => "the last download is still stopping; try again",
        error.NameTooLong, error.NoSpaceLeft => "the model's path is too long",
        else => "the download could not be started",
    };
}

pub fn startDownload(self: *App) void {
    if (self.embedding_model_download == .running or overridden(self)) return;
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    self.embedding_model_download = if (userPath(&buffer)) |destination|
        if (self.runtime.startEmbeddingModelDownload(.clap_htsat_unfused, destination)) |job|
            .{ .running = job }
        else |err|
            .{ .refused = startRefusal(err) }
    else |err|
        .{ .refused = startRefusal(err) };
    self.requestTick();
}

pub fn cancelDownload(self: *App) void {
    switch (self.embedding_model_download) {
        .running => |job| self.runtime.cancelJob(job) catch |err|
            std.log.warn("Could not cancel the audio-embedding model download ({t})", .{err}),
        .idle, .failed, .refused => {},
    }
    self.requestTick();
}

pub fn dismissFailure(self: *App) void {
    switch (self.embedding_model_download) {
        .failed, .refused => self.embedding_model_download = .idle,
        .idle, .running => {},
    }
}

fn following(job: liborca.JobHandle, job_state: liborca.JobState) Download {
    return switch (job_state) {
        .succeeded, .cancelled => .idle,
        .failed => .{ .failed = job },
        .queued, .waiting, .running, .cancelling, .paused => .{ .running = job },
    };
}

pub fn tick(self: *App) void {
    const job = switch (self.embedding_model_download) {
        .running => |job| job,
        .idle, .failed, .refused => return,
    };
    if (self.runtime.jobSnapshotSynced(job)) |snapshot| {
        self.embedding_model_download = following(job, snapshot.state);
        if (snapshot.state == .succeeded) {
            var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            if (userPath(&buffer)) |destination| self.embedding_model_path.set(self.allocator, destination) else |_| {}
            analysis_notice.refresh(self);
        }
    } else |_| self.embedding_model_download = .idle;
    preferences.showModel(self);
}

const TestFiles = struct {
    present: []const []const u8,

    pub fn isFile(self: TestFiles, path: []const u8) bool {
        for (self.present) |candidate| if (std.mem.eql(u8, candidate, path)) return true;
        return false;
    }
};

const test_places: Places = .{ .override = null, .user_data_dir = "/data", .executable_dir = "/prefix/bin" };
const test_user = "/data/orca/models/clap_audio_int8.onnx";
const test_bundled = "/prefix/share/orca/models/clap_audio_int8.onnx";

fn expectChosen(expected: []const u8, places: Places, present: []const []const u8) !void {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try choose(&buffer, places, TestFiles{ .present = present }));
}

test "choose_overrideSet_winsEvenWithNoFileThere" {
    var places = test_places;
    places.override = "/elsewhere/model.onnx";
    try expectChosen("/elsewhere/model.onnx", places, &.{ test_user, test_bundled });
}

test "choose_emptyOverride_isIgnored" {
    var places = test_places;
    places.override = "";
    try expectChosen(test_user, places, &.{test_user});
}

test "choose_userAndBundledPresent_prefersTheUsers" {
    try expectChosen(test_user, test_places, &.{ test_user, test_bundled });
}

test "choose_onlyBundledPresent_usesTheBundled" {
    try expectChosen(test_bundled, test_places, &.{test_bundled});
}

test "choose_nothingPresent_namesTheUsersPlace" {
    try expectChosen(test_user, test_places, &.{});
    var places = test_places;
    places.executable_dir = null;
    try expectChosen(test_user, places, &.{});
}

test "choose_pathLongerThanTheBuffer_fails" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, choose(&buffer, test_places, TestFiles{ .present = &.{} }));
}

fn expectRow(expected: Status, request: Request) !void {
    var buffer: [std.Io.Dir.max_path_bytes + 128]u8 = undefined;
    const row = status(&buffer, request);
    try std.testing.expectEqualStrings(expected.title, row.title);
    try std.testing.expectEqualStrings(expected.subtitle, row.subtitle);
    try std.testing.expectEqual(expected.can_check_again, row.can_check_again);
    try std.testing.expectEqual(expected.action, row.action);
}

fn requestFor(state: liborca.EmbeddingModelState, download: Shown) Request {
    return .{ .state = state, .path = test_user, .overridden = false, .download = download };
}

test "status_missing_offersTheDownloadAndNamesItsSizeAndHost" {
    try expectRow(.{
        .title = "Model not installed",
        .subtitle = "Download it (32.6 MB) from github.com, or put clap_audio_int8.onnx in /data/orca/models and check again.",
        .can_check_again = true,
        .action = .download,
    }, requestFor(.missing, .idle));
}

test "status_missingWithOverride_saysWhereTheFileGoesAndOffersNoDownload" {
    try expectRow(.{
        .title = "Model not installed",
        .subtitle = "Put model.onnx in /elsewhere, then check again.",
        .can_check_again = true,
    }, .{ .state = .missing, .path = "/elsewhere/model.onnx", .overridden = true, .download = .idle });
}

test "status_running_showsBytesAndOffersOnlyCancel" {
    try expectRow(.{
        .title = "Downloading the model",
        .subtitle = "0.0 of 32.6 MB",
        .can_check_again = false,
        .action = .cancel,
    }, requestFor(.missing, .{ .running = .{ .received_bytes = 0, .total_bytes = model_bytes } }));
    try expectRow(.{
        .title = "Downloading the model",
        .subtitle = "12.4 of 32.6 MB",
        .can_check_again = false,
        .action = .cancel,
    }, requestFor(.wrong_file, .{ .running = .{ .received_bytes = 12_449_999, .total_bytes = model_bytes } }));
}

test "status_failed_givesTheReasonAsASentenceAndOffersTheDownloadAgain" {
    try expectRow(.{
        .title = "Model not installed",
        .subtitle = "The download failed. The network is unavailable.",
        .can_check_again = true,
        .action = .download,
    }, requestFor(.missing, .{ .failed = "the network is unavailable" }));
    try expectRow(.{
        .title = "Model not installed",
        .subtitle = "The download failed. The server answered 404.",
        .can_check_again = true,
        .action = .download,
    }, requestFor(.missing, .{ .failed = "the server answered 404." }));
    try expectRow(.{
        .title = "Model not installed",
        .subtitle = "The download failed.",
        .can_check_again = true,
        .action = .download,
    }, requestFor(.missing, .{ .failed = "" }));
}

const test_job: liborca.JobHandle = .{ .index = 3, .generation = 1 };

test "following_endedJob_leavesOnlyAFailureBehind" {
    try std.testing.expectEqual(Download.idle, following(test_job, .cancelled));
    try std.testing.expectEqual(Download.idle, following(test_job, .succeeded));
    try std.testing.expectEqual(Download{ .failed = test_job }, following(test_job, .failed));
    try std.testing.expectEqual(Download{ .running = test_job }, following(test_job, .running));
    try std.testing.expectEqual(Download{ .running = test_job }, following(test_job, .cancelling));
}

test "status_ready_showsThePathWhateverTheDownloadDid" {
    const ready: Status = .{ .title = "Model installed", .subtitle = test_user, .can_check_again = false };
    try expectRow(ready, requestFor(.ready, .idle));
    try expectRow(ready, requestFor(.ready, .{ .failed = "the download timed out" }));
    try expectRow(ready, requestFor(.ready, .{ .running = .{ .received_bytes = 1, .total_bytes = 2 } }));
}

test "status_builtWithout_offersNothing" {
    const without: Status = .{
        .title = "Not available in this build",
        .subtitle = "This build of Orca was made without ONNX Runtime.",
        .can_check_again = false,
    };
    try expectRow(without, requestFor(.built_without, .idle));
    try expectRow(without, requestFor(.built_without, .{ .failed = "the download timed out" }));
}

test "status_wrongOrUnusableFile_showsThePathAndWhatDownloadFetches" {
    try expectRow(.{
        .title = "That file is not Orca's model",
        .subtitle = test_user ++ ". Download fetches the model (32.6 MB) from github.com.",
        .can_check_again = true,
        .action = .download,
    }, requestFor(.wrong_file, .idle));
    try expectRow(.{
        .title = "The model could not be loaded",
        .subtitle = test_user ++ ". Download fetches the model (32.6 MB) from github.com.",
        .can_check_again = true,
        .action = .download,
    }, requestFor(.unusable, .idle));
    try expectRow(.{
        .title = "That file is not Orca's model",
        .subtitle = "/elsewhere/model.onnx",
        .can_check_again = true,
    }, .{ .state = .wrong_file, .path = "/elsewhere/model.onnx", .overridden = true, .download = .idle });
}

test "megabytes_roundsToOneDecimal" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("32.6", try std.fmt.bufPrint(&buffer, "{f}", .{Megabytes{ .bytes = model_bytes }}));
    try std.testing.expectEqualStrings("0.0", try std.fmt.bufPrint(&buffer, "{f}", .{Megabytes{ .bytes = 49_999 }}));
    try std.testing.expectEqualStrings("0.1", try std.fmt.bufPrint(&buffer, "{f}", .{Megabytes{ .bytes = 50_000 }}));
    try std.testing.expectEqualStrings("1.0", try std.fmt.bufPrint(&buffer, "{f}", .{Megabytes{ .bytes = 1_000_000 }}));
}
