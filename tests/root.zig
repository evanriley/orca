const std = @import("std");
const liborca = @import("liborca");

test "public module identifies the host platform" {
    try std.testing.expect(liborca.platform.current.supported);
    try std.testing.expect(liborca.platform.current.name.len > 0);
}

test "registered lossless and lossy codecs share SourceSession pipeline" {
    const paths = [_][]const u8{
        "fixtures/audio/generated-reference.flac",
        "fixtures/audio/generated-reference.qoa",
        // The same FLAC stream behind an ID3v2 tag: detection resolves the
        // container prefix, so the public path decodes it identically.
        "fixtures/audio/id3-prefixed-reference.flac",
    };
    const codecs = liborca.codec.CodecRegistry.builtins();
    for (paths) |path| {
        var local = try liborca.storage.LocalFileSource.open(std.testing.io, path);
        defer local.close();
        var source = liborca.audio.source_session.SourceSession.init(
            try codecs.openDetected(std.testing.allocator, local.readable()),
        );
        defer source.deinit();
        const frames: usize = @intCast(source.decoder.frame_count.?);
        const channels = source.decoder.format.channels;
        var pool = try liborca.audio.buffer.BlockPool.init(
            std.testing.allocator,
            2,
            1024,
            channels,
        );
        defer pool.deinit();
        var pipe: liborca.audio.render.RenderPipe(2) = .{};
        try std.testing.expectEqual(@as(usize, 1), try source.prime(2, &pipe, &pool, 1, 1));
        const output = try std.testing.allocator.alloc(f32, frames * channels);
        defer std.testing.allocator.free(output);
        try std.testing.expectEqual(frames, pipe.render(&pool, channels, 1, output));
    }
}

fn sleepMilliseconds(ms: u64) void {
    const duration: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&duration, null);
}

/// Builds a Library whose Tracks point at real fixture files, so a queue is
/// exercised through the same `playableLocation` -> `LocalFileSource` ->
/// `CodecRegistry` path a projected corpus uses.
fn openQueueLibrary(
    runtime: *liborca.OrcaRuntime,
    uri: [:0]const u8,
    paths: []const []const u8,
    ids: []i64,
) !liborca.core.object.LibraryHandle {
    const library = try runtime.openLibrary(std.testing.io, uri);
    const database = try runtime.libraryDatabase(library);
    const volume_id = try database.volumes.ensure(.{
        .stable_key = "uuid:integration-queue",
        .label = "Fixtures",
    });
    for (paths, 0..) |path, index| {
        const file_id = try database.files.create(.{ .audio_format = 1, .size_bytes = 1024 });
        _ = try database.locations.upsert(.{
            .file_id = file_id,
            .volume_id = volume_id,
            .uri = path,
        });
        var title: [32]u8 = undefined;
        try database.tracks.upsertTracks(&.{.{
            .title = try std.fmt.bufPrint(&title, "Entry {d}", .{index}),
            .preferred_file_id = file_id,
        }});
        var page = try database.tracks.page(std.testing.allocator, .{ .limit = 1, .offset = @intCast(index) });
        defer page.deinit();
        ids[index] = page.items[0].id;
    }
    return library;
}

test "seeking during a gapless FLAC transition stays inside the audible track" {
    // Real FLAC, through the whole public runtime path: seeking is on the
    // critical path for most of a lossless library, and the FLAC decoder's
    // post-seek end-of-stream behaviour is not reproducible with a synthetic
    // decoder.
    var backend: liborca.audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = liborca.OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    // Two copies of one fixture, so the entries share a canonical format and the
    // transition between them really is gapless. Two Locations are needed
    // because a Location is keyed by URI, and two entries pointing at one row
    // would be one File with two Tracks rather than a queue of two.
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var fixture = try liborca.storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/tagged-reference.flac",
    );
    const readable = fixture.readable();
    const bytes = try std.testing.allocator.alloc(u8, @intCast(readable.size()));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(bytes.len, try readable.readAt(0, bytes));
    fixture.close();
    for ([_][]const u8{ "first.flac", "second.flac" }) |name|
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
    var first_path: [128]u8 = undefined;
    var second_path: [128]u8 = undefined;
    var ids: [2]i64 = @splat(0);
    const library = try openQueueLibrary(
        &runtime,
        "file:orca-seek-gapless?mode=memory&cache=shared",
        &.{
            try std.fmt.bufPrint(&first_path, ".zig-cache/tmp/{s}/first.flac", .{temporary.sub_path}),
            try std.fmt.bufPrint(&second_path, ".zig-cache/tmp/{s}/second.flac", .{temporary.sub_path}),
        },
        &ids,
    );
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    // Full render-ahead depth, so the producer really does run a whole entry
    // ahead of the audio rather than staying within one device quantum of it.
    try runtime.zoneOpenOutput(zone, 0, .{ .custom = .{ .target_frames = 8192 } }, 0);
    try runtime.playerPlayTracks(player, library, std.testing.io, &ids, 0);

    // Render entry 0 slowly until the producer has run past its end and primed
    // entry 1 behind it — the lookahead window the defect lived in.
    var samples: [512]f32 = @splat(0);
    var waited: usize = 0;
    while (waited < 200_000) : (waited += 1) {
        const snapshot = try runtime.playerQueueSnapshot(player);
        if (snapshot.decode_position == 1 and snapshot.cursor == 0) break;
        if (backend.liveStream()) |stream| stream.pump(samples[0..128], 128);
        std.Thread.yield() catch {};
    }
    const in_window = try runtime.playerQueueSnapshot(player);
    try std.testing.expectEqual(@as(u32, 1), in_window.decode_position);
    try std.testing.expectEqual(@as(u32, 0), in_window.cursor);

    // Priming the successor is not yet the divergence: the decode cursor only
    // leaves entry 0 when the producer next reads and finds it exhausted. Give
    // it the room to do that — thousands of entry 0's frames are still queued,
    // so none of this is audible yet. The precondition this test exists to
    // exercise is precisely that the entry being decoded is no longer the entry
    // being heard.
    const player_state = (try runtime.players.get(player)).player;
    waited = 0;
    while (waited < 2_000) : (waited += 1) {
        if (player_state.entrySerial() != player_state.audible_entry_serial.load(.acquire))
            break;
        if (backend.liveStream()) |stream| stream.pump(samples[0..128], 128);
        sleepMilliseconds(1);
    }
    try std.testing.expect(
        player_state.entrySerial() != player_state.audible_entry_serial.load(.acquire),
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        (try runtime.playerQueueSnapshot(player)).cursor,
    );

    // The user drags the seek bar. It names a point in the track being heard,
    // not in the one the producer has run ahead into.
    _ = try runtime.playerSeekMs(player, 50);
    // Re-opening the audible entry is file I/O, so it happens on the engine
    // thread rather than under the caller. No pumping here: the epoch bump has
    // already retired everything that was prepared.
    waited = 0;
    while (waited < 2_000) : (waited += 1) {
        if ((try runtime.playerQueueSnapshot(player)).decode_position == 0) break;
        sleepMilliseconds(1);
    }
    const after_seek = try runtime.playerQueueSnapshot(player);
    try std.testing.expectEqual(@as(u32, 0), after_seek.cursor);
    // Both cursors are back on the audible entry. A seek that had landed on the
    // decoding source would have left the decode cursor on entry 1 — and the
    // listener 50 ms into the *next* song once entry 0's tail drained.
    try std.testing.expectEqual(@as(u32, 0), after_seek.decode_position);
    try std.testing.expectEqual(
        ids[0],
        (try runtime.playerNowPlaying(player)).?.track_id,
    );
    const status = try runtime.playerStatus(player);
    try std.testing.expectEqual(ids[0], status.track_id.?);
    try std.testing.expectEqual(@as(u32, 0), status.queue_index);
    try std.testing.expect(status.position_ms >= 50);
    try std.testing.expect(status.position_ms < status.duration_ms);

    // And entry 1 still arrives afterwards rather than having been consumed by
    // the seek: a fix that corrected the seek but broke the transition after it
    // would not be a fix.
    waited = 0;
    while (waited < 200_000) : (waited += 1) {
        if (backend.liveStream()) |stream| stream.pump(&samples, 256);
        if ((try runtime.playerQueueSnapshot(player)).cursor == 1) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(
        @as(u32, 1),
        (try runtime.playerQueueSnapshot(player)).cursor,
    );
    const stats = try runtime.playerQueueStats(player);
    try std.testing.expectEqual(@as(u64, 0), stats.format_switch_transitions);
    try std.testing.expectEqual(@as(u64, 0), stats.open_failures);
    try std.testing.expectEqual(@as(u64, 0), stats.decode_errors);
    try std.testing.expect(stats.gapless_transitions >= 1);
}

test "a play that cannot open its first track leaves nothing advertised as playing" {
    // `playerPlayTracks` replaces the queue before it opens anything, so a
    // failure to open arrives with the previous queue already destroyed. The
    // defect was that the new queue survived the failure: a host polling
    // now-playing saw a track id and rendered a now-playing state for audio
    // that was not playing and could not be made to play.
    var backend: liborca.audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = liborca.OrcaRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    // A Location row is just a URI; nothing requires the bytes to exist. That
    // is the honest shape of this failure — a library row whose file has been
    // deleted, moved or unmounted since the scan that recorded it.
    var ids: [1]i64 = @splat(0);
    const library = try openQueueLibrary(
        &runtime,
        "file:orca-failed-play?mode=memory&cache=shared",
        &.{".zig-cache/tmp/orca-no-such-file.flac"},
        &ids,
    );
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneOpenOutput(zone, 0, .robust, 0);

    try std.testing.expectError(
        error.TrackFileMissing,
        runtime.playerPlayTracks(player, library, std.testing.io, &ids, 0),
    );

    const status = try runtime.playerStatus(player);
    try std.testing.expectEqual(@as(?i64, null), status.track_id);
    try std.testing.expectEqual(@as(u32, 0), status.queue_length);
    try std.testing.expect(status.transport == .stopped);
}
