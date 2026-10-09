const std = @import("std");
const storage = @import("../storage/root.zig");
const scanner = @import("scanner.zig");
const watch = @import("watch.zig");

pub const CancellationToken = scanner.CancellationToken;

pub const default_limit: u32 = 100_000;

pub const FolderEstimate = struct {
    audio_files: u64 = 0,
    truncated: bool = false,
};

pub fn estimateAudioFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    token: *CancellationToken,
    limit: u32,
) !FolderEstimate {
    if (token.checkpoint()) return error.Cancelled;
    var root = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walkSelectively(allocator);
    defer walker.deinit();
    const ignore: watch.Ignore = .{};
    var estimate: FolderEstimate = .{};
    while (try walker.next(io)) |listed| {
        var entry = listed;
        if (token.checkpoint()) return error.Cancelled;
        if (ignore.matches(entry.basename)) continue;
        if (entry.kind == .unknown) entry.kind = scanner.resolvedKind(io, entry) orelse continue;
        if (entry.kind == .directory) {
            try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        const file_path = try scanner.pathUnder(allocator, path, entry.path);
        defer allocator.free(file_path);
        if (!isAudio(io, file_path)) continue;
        if (estimate.audio_files == limit) {
            estimate.truncated = true;
            break;
        }
        estimate.audio_files += 1;
    }
    return estimate;
}

fn isAudio(io: std.Io, path: []const u8) bool {
    var local = storage.LocalFileSource.open(io, path) catch return false;
    defer local.close();
    const detection = storage.format.detect(local.readable()) catch return false;
    return detection != null;
}

test "an estimate counts the files whose bytes are audio and nothing else" {
    var token: CancellationToken = .{};
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "Artist/Album");
    const flac = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/audio/tagged-reference.flac", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(flac);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "Artist/Album/01.flac", .data = flac });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "Artist/Album/renamed.txt", .data = flac });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "Artist/Album/notes.flac", .data = "not audio" });
    const root_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(root_path);

    const estimate = try estimateAudioFiles(std.testing.io, std.testing.allocator, root_path, &token, default_limit);
    try std.testing.expectEqual(FolderEstimate{ .audio_files = 2, .truncated = false }, estimate);
}

test "an estimate descends directories whose kind the filesystem does not report" {
    var token: CancellationToken = .{};
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "Artist/Album");
    const flac = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/audio/tagged-reference.flac", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(flac);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "Artist/Album/01.flac", .data = flac });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "Artist/Album/renamed.txt", .data = flac });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "Artist/Album/notes.flac", .data = "not audio" });
    const root_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    defer std.testing.allocator.free(root_path);

    const estimate = try estimateAudioFiles(
        scanner.ioReportingUnknownKinds(std.testing.io),
        std.testing.allocator,
        root_path,
        &token,
        default_limit,
    );
    try std.testing.expectEqual(FolderEstimate{ .audio_files = 2, .truncated = false }, estimate);
}

test "an estimate stops at its limit and says it was truncated" {
    var token: CancellationToken = .{};
    const estimate = try estimateAudioFiles(std.testing.io, std.testing.allocator, "fixtures/audio", &token, 3);
    try std.testing.expectEqual(FolderEstimate{ .audio_files = 3, .truncated = true }, estimate);
}

const HeldEstimate = struct {
    threaded: std.Io.Threaded = .init_single_threaded,
    token: CancellationToken = .{},
    returned: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),

    fn run(self: *HeldEstimate) void {
        const result = estimateAudioFiles(self.threaded.io(), std.testing.allocator, "fixtures/audio", &self.token, default_limit);
        self.cancelled.store(result == error.Cancelled, .release);
        self.returned.store(true, .release);
    }
};

test "a cancelled estimate returns within 100 ms" {
    var state: HeldEstimate = .{};
    defer state.threaded.deinit();
    state.token.io = state.threaded.io();
    state.token.pause();
    const thread = try std.Thread.spawn(.{}, HeldEstimate.run, .{&state});
    try std.testing.io.sleep(.fromMilliseconds(3 * CancellationToken.pause_poll_ms), .awake);
    try std.testing.expect(!state.returned.load(.acquire));

    const cancelled_at = std.Io.Clock.awake.now(std.testing.io);
    state.token.cancel();
    while (!state.returned.load(.acquire)) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    const waited = cancelled_at.durationTo(std.Io.Clock.awake.now(std.testing.io));
    thread.join();
    try std.testing.expect(state.cancelled.load(.acquire));
    try std.testing.expect(waited.toMilliseconds() < 100);
}
