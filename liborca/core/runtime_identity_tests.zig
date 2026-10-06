const std = @import("std");
const audio = @import("../audio/root.zig");
const database = @import("../database/root.zig");
const job = @import("job.zig");
const network = @import("../network/root.zig");
const runtime_module = @import("runtime.zig");
const runtime_provider_tests = @import("runtime_provider_tests.zig");
const runtime_tests = @import("runtime_tests.zig");

const Feedback = runtime_module.Feedback;
const LibraryHandle = runtime_module.LibraryHandle;
const OrcaRuntime = runtime_module.OrcaRuntime;
const PlayerHandle = runtime_module.PlayerHandle;

const io = std.testing.io;
const allocator = std.testing.allocator;
const artist = "Nick Drake";
const album = "Bryter Layter";

const Song = struct {
    file_name: []const u8,
    title: []const u8,
};

const northern_sky: Song = .{ .file_name = "a.mp3", .title = "Northern Sky" };
const pink_moon: Song = .{ .file_name = "b.mp3", .title = "Pink Moon" };
const hazey_jane: Song = .{ .file_name = "c.mp3", .title = "Hazey Jane I" };
const two_songs = [_]Song{ northern_sky, pink_moon };
const three_songs = [_]Song{ northern_sky, pink_moon, hazey_jane };

fn appendTextFrame(frames: *std.ArrayList(u8), identifier: *const [4]u8, text: []const u8) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.append(allocator, 0);
    try payload.appendSlice(allocator, text);
    try runtime_provider_tests.id3v23Frame(frames, identifier, payload.items);
}

fn writeSongMp3(dir: std.Io.Dir, song: Song, track_number: u32, revision: u32) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, "fixtures/audio/tagged-reference.mp3", allocator, .limited(1 << 22));
    defer allocator.free(source);
    const tag_size = (@as(usize, source[6]) << 21) | (@as(usize, source[7]) << 14) | (@as(usize, source[8]) << 7) | source[9];
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(allocator);
    var number_buffer: [10]u8 = undefined;
    try appendTextFrame(&frames, "TIT2", song.title);
    try appendTextFrame(&frames, "TPE1", artist);
    try appendTextFrame(&frames, "TPE2", artist);
    try appendTextFrame(&frames, "TALB", album);
    try appendTextFrame(&frames, "TRCK", try std.fmt.bufPrint(&number_buffer, "{d}", .{track_number}));
    var padding: std.ArrayList(u8) = .empty;
    defer padding.deinit(allocator);
    try padding.appendSlice(allocator, "Orca Test Revision\x00");
    try padding.appendNTimes(allocator, 'r', revision);
    try appendTextFrame(&frames, "TXXX", padding.items);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, &.{ 'I', 'D', '3', 3, 0, 0 });
    const length = frames.items.len;
    try bytes.appendSlice(allocator, &.{
        @intCast((length >> 21) & 0x7f), @intCast((length >> 14) & 0x7f),
        @intCast((length >> 7) & 0x7f),  @intCast(length & 0x7f),
    });
    try bytes.appendSlice(allocator, frames.items);
    try bytes.appendSlice(allocator, source[10 + tag_size ..]);
    try dir.writeFile(io, .{ .sub_path = song.file_name, .data = bytes.items });
}

const RecordingState = struct {
    rating: ?u8,
    feedback: Feedback,
    play_count: u64,
};

const Rig = struct {
    backend: audio.output.TestBackend,
    runtime: OrcaRuntime,
    musicbrainz: runtime_provider_tests.FakeMusicBrainz = .{},
    temporary: std.testing.TmpDir,
    data: std.testing.TmpDir,
    database_path: [:0]u8,
    songs: []const Song,
    library: LibraryHandle = undefined,
    ids: [three_songs.len]i64 = undefined,
    revision: u32 = 0,

    fn init(self: *Rig, songs: []const Song, positions: []const u32) !void {
        var data = std.testing.tmpDir(.{});
        const database_path = runtime_tests.tempDatabasePath(&data) catch |err| {
            data.cleanup();
            return err;
        };
        self.* = .{
            .backend = .{ .allocator = allocator },
            .runtime = .init(allocator),
            .temporary = std.testing.tmpDir(.{}),
            .data = data,
            .database_path = database_path,
            .songs = songs,
        };
        errdefer self.deinit();
        self.runtime.setOutputFactory(self.backend.factory());
        try self.runtime.setClientIdentity(network.testing.test_identity);
        self.runtime.matching_hooks = self.musicbrainz.hooks();
        try self.writeSongs(positions);
        self.library = try runtime_tests.scannedTempFolder(&self.runtime, &self.temporary, self.database_path);
        for (songs, self.ids[0..songs.len]) |song, *id| id.* = try self.trackOfSong(song);
        try self.expectIdsKeepSongs(positions);
    }

    fn deinit(self: *Rig) void {
        self.runtime.deinit();
        self.backend.deinit();
        allocator.free(self.database_path);
        self.data.cleanup();
        self.temporary.cleanup();
    }

    fn songIds(self: *const Rig) []const i64 {
        return self.ids[0..self.songs.len];
    }

    fn libraryDatabase(self: *Rig) !*database.LibraryDatabase {
        return runtime_module.libraryDatabase(&self.runtime, self.library);
    }

    fn writeSongs(self: *Rig, positions: []const u32) !void {
        for (self.songs, positions) |song, position| try writeSongMp3(self.temporary.dir, song, position, self.revision);
    }

    fn retag(self: *Rig, positions: []const u32) !void {
        self.revision += 1;
        try self.writeSongs(positions);
        try runtime_tests.rescan(&self.runtime, self.library);
    }

    fn trackOfSong(self: *Rig, song: Song) !i64 {
        const ids = try runtime_tests.allTrackIds(&self.runtime, self.library);
        defer allocator.free(ids);
        for (ids) |id| {
            const details = (try self.runtime.libraryTrackDetails(self.library, id)) orelse continue;
            defer details.deinit();
            if (pathNamesSong(details.path orelse continue, song)) return id;
        }
        return error.SongHasNoTrack;
    }

    fn newPlayer(self: *Rig) !PlayerHandle {
        const player = try self.runtime.createPlayer();
        try self.runtime.playerBindLibrary(player, self.library, io);
        return player;
    }

    fn expectIdsKeepSongs(self: *Rig, positions: []const u32) !void {
        const ids = try runtime_tests.allTrackIds(&self.runtime, self.library);
        defer allocator.free(ids);
        try std.testing.expectEqual(self.songs.len, ids.len);
        for (self.songs, self.songIds(), positions) |song, id, position| {
            const details = (try self.runtime.libraryTrackDetails(self.library, id)) orelse return error.TrackLost;
            defer details.deinit();
            try std.testing.expectEqualStrings(song.title, details.title);
            try std.testing.expect(pathNamesSong(details.path orelse return error.TrackHasNoPath, song));
            try std.testing.expectEqual(@as(?i64, position), details.track_number);
        }
    }

    fn expectQueueHoldsSongs(self: *Rig, player: PlayerHandle, order: []const usize) !void {
        var refs: [three_songs.len + 1]runtime_module.TrackRef = undefined;
        try std.testing.expectEqual(order.len, try self.runtime.playerQueuePage(player, 0, &refs));
        const queued = try self.runtime.playerQueueTracks(player, allocator, 0, 16);
        defer queued.deinit();
        try std.testing.expectEqual(order.len, queued.items.len);
        for (order, refs[0..order.len], queued.items) |song_index, ref, entry| {
            const song = self.songs[song_index];
            const summary = entry.track orelse return error.TrackLost;
            try std.testing.expectEqual(self.ids[song_index], ref.track_id);
            try std.testing.expectEqual(self.ids[song_index], entry.id);
            try std.testing.expectEqual(self.ids[song_index], summary.id);
            try std.testing.expectEqualStrings(song.title, summary.title);
            try std.testing.expect(pathNamesSong(summary.path, song));
        }
    }

    fn listen(self: *Rig, song_index: usize, times: u32) !void {
        const library_database = try self.libraryDatabase();
        const files = try library_database.tracks.fileIds(allocator, self.ids[song_index]);
        defer allocator.free(files);
        for (0..times) |listen_index| _ = try library_database.listens.record(.{
            .file_id = files[0],
            .started_at = 1_700_000_000 + @as(i64, @intCast(listen_index)),
            .listened_ms = 60_000,
            .title = self.songs[song_index].title,
            .artist = artist,
        });
    }

    fn giveRecordingState(self: *Rig) !i64 {
        _ = try self.runtime.librarySetRating(self.library, &.{self.ids[0]}, 100);
        _ = try self.runtime.librarySetRating(self.library, &.{self.ids[1]}, 20);
        _ = try self.runtime.librarySetFeedback(self.library, &.{self.ids[0]}, .loved);
        _ = try self.runtime.librarySetFeedback(self.library, &.{self.ids[1]}, .hated);
        try self.listen(0, 3);
        try self.listen(1, 1);
        const playlist = try self.runtime.libraryCreatePlaylist(self.library, "Mix");
        _ = try self.runtime.libraryPlaylistInsert(self.library, playlist, &.{self.ids[1]}, null);
        try self.expectRecordingState(playlist);
        return playlist;
    }

    fn expectRecordingState(self: *Rig, playlist: i64) !void {
        const expected = [_]RecordingState{
            .{ .rating = 100, .feedback = .loved, .play_count = 3 },
            .{ .rating = 20, .feedback = .hated, .play_count = 1 },
        };
        for (expected, self.ids[0..expected.len], self.songs[0..expected.len]) |state, id, song| {
            const summary = (try self.runtime.libraryTrackSummary(self.library, id)) orelse return error.TrackLost;
            defer summary.deinit(self.runtime.allocator);
            try std.testing.expectEqualStrings(song.title, summary.title);
            try std.testing.expectEqual(state.rating, summary.rating);
            try std.testing.expectEqual(state.feedback, summary.feedback);
            try std.testing.expectEqual(state.play_count, summary.play_count);
        }
        const entries = try self.runtime.libraryPlaylistEntries(self.library, playlist, 10, 0);
        defer entries.deinit();
        try std.testing.expectEqual(@as(usize, 1), entries.items.len);
        const listed = entries.items[0].track orelse return error.PlaylistEntryLost;
        try std.testing.expectEqual(self.ids[1], listed.id);
        try std.testing.expectEqualStrings(self.songs[1].title, listed.title);
        try std.testing.expect(pathNamesSong(listed.path, self.songs[1]));
    }
};

fn pathNamesSong(path: []const u8, song: Song) bool {
    return std.mem.endsWith(u8, path, song.file_name) and
        path.len > song.file_name.len and path[path.len - song.file_name.len - 1] == '/';
}

test "a rescan after two files swap their track number tags keeps each Track id on its own file" {
    var rig: Rig = undefined;
    try rig.init(&two_songs, &.{ 1, 2 });
    defer rig.deinit();

    try rig.retag(&.{ 2, 1 });

    try rig.expectIdsKeepSongs(&.{ 2, 1 });
}

test "a rescan after three files rotate their track number tags keeps each Track id on its own file" {
    var rig: Rig = undefined;
    try rig.init(&three_songs, &.{ 1, 2, 3 });
    defer rig.deinit();

    try rig.retag(&.{ 2, 3, 1 });
    try rig.expectIdsKeepSongs(&.{ 2, 3, 1 });

    try rig.retag(&.{ 3, 1, 2 });
    try rig.expectIdsKeepSongs(&.{ 3, 1, 2 });
}

test "a tag write that swaps two track numbers, and its undo, keep each Track id on its own file" {
    var rig: Rig = undefined;
    try rig.init(&two_songs, &.{ 1, 2 });
    defer rig.deinit();

    const first = try rig.runtime.libraryEditTracks(rig.library, &.{rig.ids[0]}, &.{.{ .field = .track_number, .value = "2" }});
    defer first.deinit();
    try std.testing.expectEqualSlices(i64, &.{rig.ids[0]}, first.ids);
    const second = try rig.runtime.libraryEditTracks(rig.library, &.{rig.ids[1]}, &.{.{ .field = .track_number, .value = "1" }});
    defer second.deinit();
    try std.testing.expectEqualSlices(i64, &.{rig.ids[1]}, second.ids);
    try rig.expectIdsKeepSongs(&.{ 2, 1 });

    const preview = try rig.runtime.planTagWrite(rig.library, io, rig.songIds());
    defer preview.deinit();
    try std.testing.expectEqual(@as(usize, 2), preview.files.len);
    const written = try rig.runtime.startTagWrite(rig.library, preview.plan_id, preview.digest);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&rig.runtime, written));
    try runtime_tests.rescan(&rig.runtime, rig.library);
    try rig.expectIdsKeepSongs(&.{ 2, 1 });

    try rig.runtime.undoTagWrite(rig.library, io, preview.plan_id);
    try runtime_tests.rescan(&rig.runtime, rig.library);
    try rig.expectIdsKeepSongs(&.{ 2, 1 });

    const cleared = try rig.runtime.libraryEditTracks(rig.library, rig.songIds(), &.{.{ .field = .track_number, .value = null }});
    defer cleared.deinit();
    try rig.expectIdsKeepSongs(&.{ 1, 2 });
}

test "Track ids queued on a Player before a rescan rotates their positions still name the same songs" {
    var rig: Rig = undefined;
    try rig.init(&three_songs, &.{ 1, 2, 3 });
    defer rig.deinit();
    const player = try rig.newPlayer();
    try rig.runtime.playerEnqueueTracksBound(player, rig.library, &.{ rig.ids[2], rig.ids[0], rig.ids[1] });
    try rig.expectQueueHoldsSongs(player, &.{ 2, 0, 1 });

    try rig.retag(&.{ 2, 3, 1 });

    try rig.expectIdsKeepSongs(&.{ 2, 3, 1 });
    try rig.expectQueueHoldsSongs(player, &.{ 2, 0, 1 });
}

test "a queue saved before a rescan rotates its Tracks' positions restores the same songs in the same order" {
    var rig: Rig = undefined;
    try rig.init(&three_songs, &.{ 1, 2, 3 });
    defer rig.deinit();
    const player = try rig.newPlayer();
    try rig.runtime.playerPlayTracksBound(player, rig.library, &.{ rig.ids[2], rig.ids[0], rig.ids[1] }, 1);
    try rig.runtime.playerSaveState(player, rig.library);
    try rig.runtime.destroyPlayer(player);

    try rig.retag(&.{ 2, 3, 1 });

    const restored = try rig.newPlayer();
    const outcome = try rig.runtime.playerRestoreState(restored, rig.library, .paused);
    try std.testing.expectEqual(@as(u32, 3), outcome.entries);
    try std.testing.expectEqual(@as(u32, 1), outcome.index);
    try std.testing.expectEqual(@as(u32, 0), outcome.skipped_missing);
    try rig.expectQueueHoldsSongs(restored, &.{ 2, 0, 1 });
    try std.testing.expectEqual(@as(?i64, rig.ids[0]), (try rig.runtime.playerStatus(restored)).track_id);
}

test "a song's rating, love, playlist entry and play count stay with its Track id across a rescan that swaps positions" {
    var rig: Rig = undefined;
    try rig.init(&two_songs, &.{ 1, 2 });
    defer rig.deinit();
    const playlist = try rig.giveRecordingState();

    try rig.retag(&.{ 2, 1 });

    try rig.expectIdsKeepSongs(&.{ 2, 1 });
    try rig.expectRecordingState(playlist);
}

test "a matched album whose release positions are applied over the files' own keeps each Track id on its own file, with its rating, love, playlist entry and play count" {
    var rig: Rig = undefined;
    try rig.init(&two_songs, &.{ 4, 3 });
    defer rig.deinit();
    const playlist = try rig.giveRecordingState();
    const player = try rig.newPlayer();
    try rig.runtime.playerEnqueueTracksBound(player, rig.library, &.{ rig.ids[1], rig.ids[0] });
    const library_database = try rig.libraryDatabase();
    const editions = [_][]const u8{runtime_provider_tests.bryter_layter_mbid};
    for (rig.songIds(), [_][]const u8{ runtime_provider_tests.northern_sky_mbid, runtime_provider_tests.pink_moon_mbid }, rig.songs) |id, recording, song| {
        const files = try library_database.tracks.fileIds(allocator, id);
        defer allocator.free(files);
        const evidence = [_]database.ProposalEvidence{.{
            .recording_mbid = recording,
            .found_by = .{ .musicbrainz = true },
            .payload = .{
                .title = song.title,
                .artist = artist,
                .release_mbid = runtime_provider_tests.bryter_layter_mbid,
                .release_mbids = &editions,
                .mb_score = 100,
                .musicbrainz_confidence = 0.95,
            },
        }};
        _ = try library_database.identification_proposals.recordSearch(allocator, files[0], .{ .musicbrainz = true }, &evidence);
    }
    const summary = (try rig.runtime.libraryTrackSummary(rig.library, rig.ids[0])).?;
    const release_id = summary.release_id.?;
    summary.deinit(rig.runtime.allocator);

    const matched = try rig.runtime.startLibraryMatching(rig.library, .{ .release_id = release_id, .accept_minimum_confidence = 0.9 });

    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(&rig.runtime, matched));
    try std.testing.expectEqual(@as(u64, 2), (try rig.runtime.jobMatchStats(matched)).accepted);
    try std.testing.expectEqual(@as(u32, 1), rig.musicbrainz.requestCount());
    try rig.expectIdsKeepSongs(&.{ 4, 3 });
    try rig.expectRecordingState(playlist);

    const matched_summary = (try rig.runtime.libraryTrackSummary(rig.library, rig.ids[0])).?;
    const matched_release = matched_summary.release_id.?;
    matched_summary.deinit(rig.runtime.allocator);
    const applied = try rig.runtime.libraryApplyMatchedRelease(rig.library, matched_release, .initOne(.release_id));

    try std.testing.expect(applied > 0);
    try rig.expectIdsKeepSongs(&.{ 3, 4 });
    try rig.expectRecordingState(playlist);
    try rig.expectQueueHoldsSongs(player, &.{ 1, 0 });
}

fn scanFolderAsRoot(runtime: *OrcaRuntime, library: LibraryHandle, folder: *const std.testing.TmpDir) !i64 {
    const path = try runtime_tests.absoluteTestPath(".zig-cache/tmp/{s}", .{folder.sub_path});
    defer allocator.free(path);
    const binding = try runtime.libraryAddRoot(library, io, path);
    try std.testing.expectEqual(job.State.succeeded, try runtime_tests.awaitJob(runtime, try runtime.startLibraryScan(library, .{ .root_id = binding.root_id })));
    return binding.root_id;
}

fn trackIdOfSong(runtime: *OrcaRuntime, library: LibraryHandle, song: Song) !i64 {
    const ids = try runtime_tests.allTrackIds(runtime, library);
    defer allocator.free(ids);
    for (ids) |id| {
        const details = (try runtime.libraryTrackDetails(library, id)) orelse continue;
        defer details.deinit();
        if (pathNamesSong(details.path orelse continue, song)) return id;
    }
    return error.SongHasNoTrack;
}

fn expectQueueRows(page: anytype, first_position: u32, songs: []const ?Song, ids: []const i64) !void {
    try std.testing.expectEqual(songs.len, page.items.len);
    for (page.items, songs, ids, 0..) |row, song, id, index| {
        try std.testing.expectEqual(first_position + @as(u32, @intCast(index)), row.position);
        try std.testing.expectEqual(id, row.id);
        if (song) |expected| {
            const summary = row.track orelse return error.TrackLost;
            try std.testing.expectEqual(id, summary.id);
            try std.testing.expectEqualStrings(expected.title, summary.title);
        } else try std.testing.expect(row.track == null);
    }
}

test "queue pages over an entry whose Track was removed from the Library keep every row at its queue position" {
    const kept = [_]Song{
        northern_sky,
        pink_moon,
        .{ .file_name = "d.mp3", .title = "One of These Things First" },
        .{ .file_name = "e.mp3", .title = "Fly" },
    };
    const removed: Song = hazey_jane;

    var backend: audio.output.TestBackend = .{ .allocator = allocator };
    defer backend.deinit();
    var runtime: OrcaRuntime = .init(allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());
    var kept_folder = std.testing.tmpDir(.{});
    defer kept_folder.cleanup();
    var removed_folder = std.testing.tmpDir(.{});
    defer removed_folder.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try runtime_tests.tempDatabasePath(&data);
    defer allocator.free(database_path);

    for (kept, [_]u32{ 1, 2, 4, 5 }) |song, track_number| try writeSongMp3(kept_folder.dir, song, track_number, 0);
    try writeSongMp3(removed_folder.dir, removed, 3, 0);
    const library = try runtime.openLibrary(io, database_path);
    _ = try scanFolderAsRoot(&runtime, library, &kept_folder);
    const removed_root = try scanFolderAsRoot(&runtime, library, &removed_folder);

    const queued = [_]Song{ kept[0], kept[1], removed, kept[2], kept[3] };
    var ids: [queued.len]i64 = undefined;
    for (queued, &ids) |song, *id| id.* = try trackIdOfSong(&runtime, library, song);
    const player = try runtime.createPlayer();
    try runtime.playerBindLibrary(player, library, io);
    try runtime.playerEnqueueTracks(player, library, io, &ids);

    const forgotten = try runtime.libraryRemoveRoot(library, removed_root);
    try std.testing.expectEqual(@as(u64, 1), forgotten.tracks_removed);
    try std.testing.expect(try runtime.libraryTrackDetails(library, ids[2]) == null);
    try std.testing.expectEqual(@as(u32, queued.len), (try runtime.playerStatus(player)).queue_length);

    const whole = try runtime.playerQueueTracks(player, allocator, 0, 5);
    defer whole.deinit();
    try expectQueueRows(whole, 0, &.{ kept[0], kept[1], null, kept[2], kept[3] }, &ids);

    const middle = try runtime.playerQueueTracks(player, allocator, 2, 2);
    defer middle.deinit();
    try expectQueueRows(middle, 2, &.{ null, kept[2] }, ids[2..4]);

    const tail = try runtime.playerQueueTracks(player, allocator, 3, 5);
    defer tail.deinit();
    try expectQueueRows(tail, 3, &.{ kept[2], kept[3] }, ids[3..5]);

    const past_end = try runtime.playerQueueTracks(player, allocator, 5, 5);
    defer past_end.deinit();
    try std.testing.expectEqual(@as(usize, 0), past_end.items.len);
}

test "queue history pages over an entry whose Track was removed from the Library keep every row at its history position" {
    const kept = two_songs;
    const removed: Song = hazey_jane;

    var backend: audio.output.TestBackend = .{ .allocator = allocator };
    defer backend.deinit();
    var runtime: OrcaRuntime = .init(allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());
    var kept_folder = std.testing.tmpDir(.{});
    defer kept_folder.cleanup();
    var removed_folder = std.testing.tmpDir(.{});
    defer removed_folder.cleanup();
    var data = std.testing.tmpDir(.{});
    defer data.cleanup();
    const database_path = try runtime_tests.tempDatabasePath(&data);
    defer allocator.free(database_path);

    for (kept, [_]u32{ 1, 2 }) |song, track_number| try writeSongMp3(kept_folder.dir, song, track_number, 0);
    try writeSongMp3(removed_folder.dir, removed, 3, 0);
    const library = try runtime.openLibrary(io, database_path);
    _ = try scanFolderAsRoot(&runtime, library, &kept_folder);
    const removed_root = try scanFolderAsRoot(&runtime, library, &removed_folder);

    const queued = [_]Song{ kept[0], removed, kept[1] };
    var ids: [queued.len]i64 = undefined;
    for (queued, &ids) |song, *id| id.* = try trackIdOfSong(&runtime, library, song);
    const player = try runtime.createPlayer();
    try runtime.playerPlayTracks(player, library, io, &ids, 0);
    try runtime.pausePlayer(player);
    for ([_]u32{ 1, 2, 0 }) |position| {
        try runtime.playerQueueJump(player, position);
        try runtime.pausePlayer(player);
    }

    const forgotten = try runtime.libraryRemoveRoot(library, removed_root);
    try std.testing.expectEqual(@as(u64, 1), forgotten.tracks_removed);

    var entries: [4]runtime_module.QueueHistoryEntry = undefined;
    try std.testing.expectEqual(@as(usize, 3), try runtime.playerQueueHistory(player, 0, &entries));
    const newest_first = [_]i64{ ids[2], ids[1], ids[0] };

    const whole = try runtime.playerQueueHistoryTracks(player, allocator, 0, 8);
    defer whole.deinit();
    try expectQueueRows(whole, 0, &.{ kept[1], null, kept[0] }, &newest_first);
    for (whole.items, entries[0..3]) |row, entry| {
        try std.testing.expectEqual(entry.ended_at_ms, row.ended_at_ms);
        try std.testing.expectEqual(entry.reason, row.reason);
    }

    const middle = try runtime.playerQueueHistoryTracks(player, allocator, 1, 1);
    defer middle.deinit();
    try expectQueueRows(middle, 1, &.{null}, newest_first[1..2]);

    const tail = try runtime.playerQueueHistoryTracks(player, allocator, 2, 8);
    defer tail.deinit();
    try expectQueueRows(tail, 2, &.{kept[0]}, newest_first[2..3]);

    const past_end = try runtime.playerQueueHistoryTracks(player, allocator, 3, 8);
    defer past_end.deinit();
    try std.testing.expectEqual(@as(usize, 0), past_end.items.len);
}

test "a queue holding Tracks of a Library the Player was bound to before reads each from its own Library, and a closed one's as removed" {
    const first_songs = two_songs;
    const second_songs = [_]Song{ hazey_jane, .{ .file_name = "e.mp3", .title = "Fly" } };

    var backend: audio.output.TestBackend = .{ .allocator = allocator };
    defer backend.deinit();
    var runtime: OrcaRuntime = .init(allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());
    var first_folder = std.testing.tmpDir(.{});
    defer first_folder.cleanup();
    var second_folder = std.testing.tmpDir(.{});
    defer second_folder.cleanup();
    var first_data = std.testing.tmpDir(.{});
    defer first_data.cleanup();
    var second_data = std.testing.tmpDir(.{});
    defer second_data.cleanup();
    const first_path = try runtime_tests.tempDatabasePath(&first_data);
    defer allocator.free(first_path);
    const second_path = try runtime_tests.tempDatabasePath(&second_data);
    defer allocator.free(second_path);

    for (first_songs, [_]u32{ 1, 2 }) |song, track_number| try writeSongMp3(first_folder.dir, song, track_number, 0);
    for (second_songs, [_]u32{ 1, 2 }) |song, track_number| try writeSongMp3(second_folder.dir, song, track_number, 0);
    const first = try runtime.openLibrary(io, first_path);
    _ = try scanFolderAsRoot(&runtime, first, &first_folder);
    const second = try runtime.openLibrary(io, second_path);
    _ = try scanFolderAsRoot(&runtime, second, &second_folder);

    var ids: [4]i64 = undefined;
    for (first_songs, ids[0..2]) |song, *id| id.* = try trackIdOfSong(&runtime, first, song);
    for (second_songs, ids[2..4]) |song, *id| id.* = try trackIdOfSong(&runtime, second, song);
    const player = try runtime.createPlayer();
    try runtime.playerEnqueueTracks(player, first, io, ids[0..2]);
    try runtime.playerEnqueueTracks(player, second, io, ids[2..4]);
    try std.testing.expectEqual(second, (try runtime.playerLibrary(player)).?);
    try runtime.playerQueueJump(player, 2);
    try runtime.pausePlayer(player);

    const both = try runtime.playerQueueTracks(player, allocator, 0, 8);
    defer both.deinit();
    try expectQueueRows(both, 0, &.{ first_songs[0], first_songs[1], second_songs[0], second_songs[1] }, &ids);
    const played_while_open = try runtime.playerQueueHistoryTracks(player, allocator, 0, 8);
    defer played_while_open.deinit();
    try expectQueueRows(played_while_open, 0, &.{first_songs[0]}, ids[0..1]);

    try runtime.destroyLibrary(first);

    const after_close = try runtime.playerQueueTracks(player, allocator, 0, 8);
    defer after_close.deinit();
    try expectQueueRows(after_close, 0, &.{ null, null, second_songs[0], second_songs[1] }, &ids);
    const played_after_close = try runtime.playerQueueHistoryTracks(player, allocator, 0, 8);
    defer played_after_close.deinit();
    try expectQueueRows(played_after_close, 0, &.{null}, ids[0..1]);
}
