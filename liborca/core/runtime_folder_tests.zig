const std = @import("std");
const audio = @import("../audio/root.zig");
const FolderEntryKind = @import("../database/root.zig").FolderEntryKind;
const runtime_module = @import("runtime.zig");
const runtime_tests = @import("runtime_tests.zig");

const OrcaRuntime = runtime_module.OrcaRuntime;
const copyFixtureInto = runtime_tests.copyFixtureInto;
const scannedTempFolder = runtime_tests.scannedTempFolder;

const io = std.testing.io;

test "a scanned root browses by folder and plays a folder's Tracks recursively in path order" {
    var backend: audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "[Live] 2001/CD2");
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference.flac", "[Live] 2001/b.flac");
    try copyFixtureInto(temporary.dir, "fixtures/audio/covered-reference.mp3", "[Live] 2001/CD2/a.mp3");
    try copyFixtureInto(temporary.dir, "fixtures/audio/tagged-reference-aac.m4a", "top.m4a");
    const library = try scannedTempFolder(&runtime, &temporary, "file:orca-folder-browse?mode=memory&cache=shared");
    const roots = try runtime.libraryRootPage(library, 1, 0);
    defer roots.deinit();
    const root_id = roots.items[0].id;

    const top = try runtime.libraryFolderPage(library, root_id, "", 512, 0);
    defer top.deinit();
    try std.testing.expectEqual(@as(usize, 2), top.items.len);
    try std.testing.expectEqual(FolderEntryKind.folder, top.items[0].kind);
    try std.testing.expectEqualStrings("[Live] 2001", top.items[0].name);
    try std.testing.expectEqual(@as(u32, 2), top.items[0].file_count);
    try std.testing.expectEqual(@as(u32, 2), top.items[0].track_count);
    try std.testing.expect(top.items[0].total_duration_ms > 0);
    try std.testing.expectEqual(FolderEntryKind.file, top.items[1].kind);
    try std.testing.expectEqualStrings("top.m4a", top.items[1].name);
    try std.testing.expect(top.items[1].track_id != null);

    const live = try runtime.libraryFolderPage(library, root_id, "[Live] 2001", 512, 0);
    defer live.deinit();
    try std.testing.expectEqual(@as(usize, 2), live.items.len);
    try std.testing.expectEqualStrings("CD2", live.items[0].name);
    try std.testing.expectEqualStrings("b.flac", live.items[1].name);
    const disc = try runtime.libraryFolderPage(library, root_id, "[Live] 2001/CD2", 512, 0);
    defer disc.deinit();
    try std.testing.expectEqual(@as(usize, 1), disc.items.len);
    try std.testing.expectError(error.InvalidFolderPath, runtime.libraryFolderPage(library, root_id, "../x", 512, 0));

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneRequestOutput(zone, 0);
    try std.testing.expectError(error.FolderEmpty, runtime.playerPlayFolder(player, library, io, root_id, "Nothing", false));
    try std.testing.expectEqual(@as(u32, 0), (try runtime.playerQueueSnapshot(player)).entries);

    try runtime.playerPlayFolder(player, library, io, root_id, "[Live] 2001", false);
    var queue: [4]runtime_module.TrackRef = undefined;
    const count = try runtime.playerQueuePage(player, 0, &queue);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(disc.items[0].track_id.?, queue[0].track_id);
    try std.testing.expectEqual(live.items[1].track_id.?, queue[1].track_id);
    try std.testing.expectEqual(disc.items[0].track_id.?, (try runtime.playerNowPlaying(player)).?.track_id);
}
