const std = @import("std");
const liborca = @import("liborca");

test "public module identifies the host platform" {
    try std.testing.expect(liborca.internal.platform.current.supported);
    try std.testing.expect(liborca.internal.platform.current.name.len > 0);
}

test "registered lossless and lossy codecs share SourceSession pipeline" {
    const paths = [_][]const u8{
        "fixtures/audio/generated-reference.flac",
        "fixtures/audio/generated-reference.qoa",
        // The same FLAC stream behind an ID3v2 tag: detection resolves the
        // container prefix, so the public path decodes it identically.
        "fixtures/audio/id3-prefixed-reference.flac",
    };
    const codecs = liborca.internal.codec.CodecRegistry.builtins();
    for (paths) |path| {
        var local = try liborca.internal.storage.LocalFileSource.open(std.testing.io, path);
        defer local.close();
        var source = liborca.internal.audio.source_session.SourceSession.init(
            try codecs.openDetected(std.testing.allocator, local.readable()),
        );
        defer source.deinit();
        const frames: usize = @intCast(source.decoder.frame_count.?);
        const channels = source.decoder.format.channels;
        var pool = try liborca.internal.audio.buffer.BlockPool.init(
            std.testing.allocator,
            2,
            1024,
            channels,
        );
        defer pool.deinit();
        var pipe: liborca.internal.audio.render.RenderPipe(2) = .{};
        try std.testing.expectEqual(@as(usize, 1), try source.prime(2, &pipe, &pool, 1, 1, .{ .mode = .track }));
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
    runtime: *liborca.Runtime,
    uri: [:0]const u8,
    paths: []const []const u8,
    ids: []i64,
) !liborca.internal.core.object.LibraryHandle {
    const library = try runtime.openLibrary(std.testing.io, uri);
    const database = try liborca.internal.core.runtime.databaseOf(runtime, library);
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
    var backend: liborca.internal.audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = liborca.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    // Two copies of one fixture, so the entries share a canonical format and the
    // transition between them really is gapless. Two Locations are needed
    // because a Location is keyed by URI, and two entries pointing at one row
    // would be one File with two Tracks rather than a queue of two.
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var fixture = try liborca.internal.storage.LocalFileSource.open(
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
    // entry 1 behind it.
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
    // so none of this is audible yet. The precondition is that the entry being
    // decoded is not the entry being heard.
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
    // the seek.
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
    // new queue must not survive the failure, or a host polling now-playing
    // shows a track that is not playing.
    var backend: liborca.internal.audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = liborca.Runtime.init(std.testing.allocator);
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

/// Writes `seconds` of a 1 kHz sine at `amplitude` as 16-bit mono PCM WAV.
///
/// Synthesized rather than committed as a fixture because what these tests
/// need is two files whose loudness differs by a known amount, and a number
/// this test asserts against should be one the test itself chose.
fn writeSineWav(
    directory: std.Io.Dir,
    name: []const u8,
    amplitude: f32,
    seconds: u32,
) !void {
    const sample_rate: u32 = 44_100;
    const frames = sample_rate * seconds;
    const data_bytes = frames * 2;
    const bytes = try std.testing.allocator.alloc(u8, 44 + data_bytes);
    defer std.testing.allocator.free(bytes);
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 36 + data_bytes, .little);
    @memcpy(bytes[8..12], "WAVE");
    @memcpy(bytes[12..16], "fmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], 1, .little);
    std.mem.writeInt(u32, bytes[24..28], sample_rate, .little);
    std.mem.writeInt(u32, bytes[28..32], sample_rate * 2, .little);
    std.mem.writeInt(u16, bytes[32..34], 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], data_bytes, .little);
    for (0..frames) |frame| {
        const phase = 2 * std.math.pi * 1000 *
            @as(f32, @floatFromInt(frame)) / @as(f32, @floatFromInt(sample_rate));
        const value: i16 = @intFromFloat(@round(amplitude * @sin(phase) * 32_767));
        std.mem.writeInt(i16, bytes[44 + frame * 2 ..][0..2], value, .little);
    }
    try directory.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
}

/// The Location of `file_id` at `uri`, with the identity a scan would record
/// for the bytes there now.
fn recordLocation(
    database: *liborca.internal.database.LibraryDatabase,
    file_id: i64,
    volume_id: i64,
    uri: []const u8,
) !void {
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, uri, .{});
    _ = try database.locations.upsert(.{
        .file_id = file_id,
        .volume_id = volume_id,
        .uri = uri,
        .native_inode = @intCast(stat.inode),
        .size_bytes = @intCast(stat.size),
        .modified_ns = @intCast(stat.mtime.nanoseconds),
        .state = .present,
    });
}

/// A `files` row plus its Location and Track, carrying the quick hash and
/// identity a scan would have recorded, which an analysis checks before it
/// records the content hash its results are keyed against.
fn recordAnalyzableTrack(
    database: *liborca.internal.database.LibraryDatabase,
    volume_id: i64,
    uri: []const u8,
    title: []const u8,
) !struct { file_id: i64, track_id: i64 } {
    const digest = try liborca.internal.storage.quick_hash.fromPath(std.testing.io, uri);
    const file_id = try database.files.create(.{ .audio_format = 1, .quick_hash = &digest });
    try recordLocation(database, file_id, volume_id, uri);
    try database.tracks.upsertTracks(&.{.{ .title = title, .preferred_file_id = file_id }});
    var page = try database.tracks.page(std.testing.allocator, .{ .limit = 512, .offset = 0 });
    defer page.deinit();
    for (page.items) |item| {
        if (std.mem.eql(u8, item.title, title))
            return .{ .file_id = file_id, .track_id = item.id };
    }
    return error.TrackNotProjected;
}

/// The loudness the library-wide analysis stored for one file, read the way
/// the playback path reads it.
fn storedLoudness(
    database: *liborca.internal.database.LibraryDatabase,
    file_id: i64,
    uri: []const u8,
) !?liborca.internal.analysis.encoding.Loudness {
    const identity = try liborca.internal.storage.content_hash.fromPath(std.testing.io, uri);
    var header: [liborca.internal.analysis.encoding.header_size]u8 = undefined;
    const length = (try database.analysis_cache.resultInto(
        liborca.internal.analysis.service.diagnosticsKey(file_id, identity, .{}),
        &header,
    )) orelse return null;
    if (length < header.len) return null;
    return liborca.internal.analysis.encoding.decodeLoudness(&header);
}

fn runLibraryAnalysis(
    database: *liborca.internal.database.LibraryDatabase,
) !liborca.internal.library.analysis_pass.Result {
    var pass: liborca.internal.library.LibraryAnalysis = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .files = &database.files,
        .analysis_cache = &database.analysis_cache,
        .health_issues = &database.health_issues,
        .write_lane = database.write_lane,
        .database_handle = database.database,
    };
    return pass.run();
}

test "an analyzed entry plays corrected and an unanalyzed entry plays at unity" {
    var backend: liborca.internal.audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = liborca.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeSineWav(temporary.dir, "measured.wav", 0.5, 2);
    try writeSineWav(temporary.dir, "unmeasured.wav", 0.5, 2);
    var measured_path: [128]u8 = undefined;
    var unmeasured_path: [128]u8 = undefined;
    const measured_uri = try std.fmt.bufPrint(
        &measured_path,
        ".zig-cache/tmp/{s}/measured.wav",
        .{temporary.sub_path},
    );
    const unmeasured_uri = try std.fmt.bufPrint(
        &unmeasured_path,
        ".zig-cache/tmp/{s}/unmeasured.wav",
        .{temporary.sub_path},
    );

    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-replay-gain-applied?mode=memory&cache=shared",
    );
    const database = try liborca.internal.core.runtime.databaseOf(&runtime, library);
    const volume_id = try database.volumes.ensure(.{ .stable_key = "uuid:replay-gain" });
    const measured = try recordAnalyzableTrack(database, volume_id, measured_uri, "Measured");

    // Only the first file exists when the pass runs, so the second is a Track
    // the Library has genuinely never measured rather than one contrived to
    // look that way.
    const analyzed = try runLibraryAnalysis(database);
    try std.testing.expectEqual(@as(u64, 1), analyzed.changed);
    const unmeasured = try recordAnalyzableTrack(
        database,
        volume_id,
        unmeasured_uri,
        "Unmeasured",
    );
    try std.testing.expectEqual(
        @as(?liborca.internal.analysis.encoding.Loudness, null),
        try storedLoudness(database, unmeasured.file_id, unmeasured_uri),
    );
    const loudness = (try storedLoudness(database, measured.file_id, measured_uri)).?;
    // A 1 kHz sine at half scale is far above the -18 LUFS target, so the
    // correction is a real attenuation rather than a rounding difference.
    try std.testing.expect(loudness.replay_gain_db < -5);

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneOpenOutput(zone, 0, .robust, 0);
    try runtime.playerSetVolume(player, 1);

    try runtime.playerPlayTracks(
        player,
        library,
        std.testing.io,
        &.{ measured.track_id, unmeasured.track_id },
        0,
    );
    const corrected = try runtime.playerEffectiveGain(player);
    const expected = std.math.pow(f32, 10, loudness.replay_gain_db / 20);
    try std.testing.expectApproxEqRel(expected, corrected, 0.001);
    try std.testing.expect(corrected < 0.6);
    // The volume the host set is untouched: a correction that moved the slider
    // would be thrown away by the next volume change.
    try std.testing.expectEqual(@as(f32, 1), try runtime.playerVolume(player));

    // Skipping to a track with no measurement must return to unity rather than
    // carry the previous entry's correction into it.
    try std.testing.expect(try runtime.playerNext(player));
    try std.testing.expectEqual(@as(f32, 1), try runtime.playerEffectiveGain(player));

    // Turning correction off leaves the audio untouched, not merely reported as
    // untouched. The mode gates the decode, so this has to be checked against
    // rendered samples: a gate applied only where the gain is reported would
    // satisfy every other assertion here while the audio stayed corrected.
    try runtime.playerSetReplayGainMode(player, .off);
    try runtime.playerPlayTracks(player, library, std.testing.io, &.{measured.track_id}, 0);
    try std.testing.expectEqual(@as(f32, 1), try runtime.playerEffectiveGain(player));
    const uncorrected = try observeEntry(&runtime, &backend, player, 0, 100);
    // The fixture is a half-scale sine, so uncorrected playback peaks there.
    try std.testing.expect(uncorrected.peak > 0.45 and uncorrected.peak < 0.55);
}

test "a loud track and a quiet track play closer in level after correction than before" {
    // The only test that catches the correction being applied with the wrong
    // sign, which would drive them 40 dB further apart while every other
    // assertion in this file still passed.
    var backend: liborca.internal.audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = liborca.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // The same tone 20 dB apart, so the difference this test measures is one
    // the test chose rather than one a fixture happened to have.
    try writeSineWav(temporary.dir, "loud.wav", 0.5, 2);
    try writeSineWav(temporary.dir, "quiet.wav", 0.05, 2);
    var loud_path: [128]u8 = undefined;
    var quiet_path: [128]u8 = undefined;

    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-replay-gain-levels?mode=memory&cache=shared",
    );
    const database = try liborca.internal.core.runtime.databaseOf(&runtime, library);
    const volume_id = try database.volumes.ensure(.{ .stable_key = "uuid:replay-gain-levels" });
    const loud_uri = try std.fmt.bufPrint(
        &loud_path,
        ".zig-cache/tmp/{s}/loud.wav",
        .{temporary.sub_path},
    );
    const quiet_uri = try std.fmt.bufPrint(
        &quiet_path,
        ".zig-cache/tmp/{s}/quiet.wav",
        .{temporary.sub_path},
    );
    const loud = try recordAnalyzableTrack(database, volume_id, loud_uri, "Loud");
    const quiet = try recordAnalyzableTrack(database, volume_id, quiet_uri, "Quiet");
    try std.testing.expectEqual(@as(u64, 2), (try runLibraryAnalysis(database)).changed);

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneOpenOutput(zone, 0, .robust, 0);
    try runtime.playerSetVolume(player, 1);

    // Measured loudness, and the multiplier the render lane actually applies
    // to it. `replay_gain_db` is the target minus the measurement, so the
    // measurement itself is recoverable from it.
    const target = liborca.internal.analysis.diagnostics.Parameters{};
    var levels: [2]f32 = undefined;
    var uncorrected: [2]f32 = undefined;
    const uris = [_][]const u8{ loud_uri, quiet_uri };
    for ([_]i64{ loud.track_id, quiet.track_id }, [_]i64{ loud.file_id, quiet.file_id }, 0..) |
        track_id,
        file_id,
        index,
    | {
        const loudness = (try storedLoudness(database, file_id, uris[index])).?;
        try runtime.playerPlayTracks(player, library, std.testing.io, &.{track_id}, 0);
        const gain = try runtime.playerEffectiveGain(player);
        uncorrected[index] = target.replay_gain_target_lufs - loudness.replay_gain_db;
        levels[index] = uncorrected[index] + 20 * std.math.log10(gain);
    }

    const before = @abs(uncorrected[0] - uncorrected[1]);
    const after = @abs(levels[0] - levels[1]);
    try std.testing.expect(before > 15);
    try std.testing.expect(after < 1);
    try std.testing.expect(after < before);
    // And both land on the target rather than merely on each other, which is
    // what proves the sign as well as the spread.
    for (levels) |level|
        try std.testing.expectApproxEqAbs(target.replay_gain_target_lufs, level, 1);
}

test "an entry whose bytes changed since it was measured plays at unity" {
    // The correction is keyed on the identity of the bytes that were opened,
    // not on what the Library recorded about them. A file edited since the
    // last scan therefore loses its correction rather than being played at one
    // measured from audio it no longer contains — and the Library cannot help
    // here, because its record is only as fresh as the last scan.
    var backend: liborca.internal.audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = liborca.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeSineWav(temporary.dir, "edited.wav", 0.5, 2);
    var edited_path: [128]u8 = undefined;
    const edited_uri = try std.fmt.bufPrint(
        &edited_path,
        ".zig-cache/tmp/{s}/edited.wav",
        .{temporary.sub_path},
    );

    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-replay-gain-stale?mode=memory&cache=shared",
    );
    const database = try liborca.internal.core.runtime.databaseOf(&runtime, library);
    const volume_id = try database.volumes.ensure(.{ .stable_key = "uuid:replay-gain-stale" });
    const edited = try recordAnalyzableTrack(database, volume_id, edited_uri, "Edited");
    try std.testing.expectEqual(@as(u64, 1), (try runLibraryAnalysis(database)).changed);

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneOpenOutput(zone, 0, .robust, 0);
    try runtime.playerPlayTracks(player, library, std.testing.io, &.{edited.track_id}, 0);
    try std.testing.expect(try runtime.playerEffectiveGain(player) < 0.6);

    // Half the amplitude, at the same path, with the Library none the wiser:
    // no rescan, so `files.content_hash` still names the audio that was
    // measured.
    try runtime.stopPlayer(player);
    try writeSineWav(temporary.dir, "edited.wav", 0.25, 2);
    try runtime.playerPlayTracks(player, library, std.testing.io, &.{edited.track_id}, 0);
    try std.testing.expectEqual(@as(f32, 1), try runtime.playerEffectiveGain(player));
}

/// What one queue entry sounded like, and what the runtime said about it.
const EntryObservation = struct {
    /// Effective gain reported while this entry was the audible one.
    gain: f32,
    /// Loudest sample the backend actually rendered inside this entry.
    peak: f32,
};

/// Pumps the test backend until entry `target` is audible, then keeps pumping
/// and measures what is actually coming out.
///
/// The pumping is what makes the advance *gapless* rather than a skip: the
/// entry ends because its audio ran out, so the successor arrives on the engine
/// thread and never passes through the control lane's hard-load path.
fn observeEntry(
    runtime: *liborca.Runtime,
    backend: *liborca.internal.audio.output.TestBackend,
    player: liborca.internal.core.object.PlayerHandle,
    target: u32,
    measured_blocks: usize,
) !EntryObservation {
    var samples: [128]f32 = @splat(0);
    var pumped: usize = 0;
    while (pumped < 4_000_000) : (pumped += 1) {
        if ((try runtime.playerQueueSnapshot(player)).cursor == target) break;
        if (backend.liveStream()) |stream| stream.pump(&samples, 128);
        std.Thread.yield() catch {};
    }
    if ((try runtime.playerQueueSnapshot(player)).cursor != target)
        return error.EntryNeverBecameAudible;
    const gain = try runtime.playerEffectiveGain(player);
    var peak: f32 = 0;
    var measured: usize = 0;
    var attempts: usize = 0;
    while (measured < measured_blocks and attempts < 4_000_000) : (attempts += 1) {
        if ((try runtime.playerQueueSnapshot(player)).cursor != target) break;
        // The engine opens the Zone's output on its own lane, so a stream may
        // not exist yet on the first attempts.
        const stream = backend.liveStream() orelse {
            std.Thread.yield() catch {};
            continue;
        };
        stream.pump(&samples, 128);
        var block_peak: f32 = 0;
        for (samples) |value| block_peak = @max(block_peak, @abs(value));
        // A 128-frame block spans about three periods of the test tone, so an
        // all-zero one is the producer being outrun rather than a zero
        // crossing. Those blocks say nothing about level; give the engine room
        // and ask again.
        if (block_peak == 0) {
            std.Thread.yield() catch {};
            continue;
        }
        peak = @max(peak, block_peak);
        measured += 1;
    }
    if (measured == 0) return error.EntryRenderedNothing;
    return .{ .gain = gain, .peak = peak };
}

/// The multiplier a correction of `loudness` produces, computed the way the
/// engine computes it so the expectation is the contract rather than a
/// transcribed constant.
fn expectedGain(loudness: liborca.internal.analysis.encoding.Loudness) f32 {
    return liborca.internal.audio.processing.replayGainMultiplier(
        loudness.replay_gain_db,
        loudness.sample_peak,
    );
}

test "a gapless auto-advance adopts the successor's own loudness correction" {
    // Auto-advance runs on the engine thread and never reaches the control
    // lane's hard-load path, so a Player-level correction published at load
    // stayed on the *previous* entry's figure for the whole of the next track.
    // Within one album — the normal case for this library — that applies track
    // one's correction to every track after it.
    var backend: liborca.internal.audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = liborca.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // The same tone 20 dB apart and in one canonical format, so the transition
    // between them is genuinely gapless and the two corrections are far enough
    // apart that inheriting the wrong one cannot be mistaken for rounding.
    try writeSineWav(temporary.dir, "loud.wav", 0.5, 2);
    try writeSineWav(temporary.dir, "quiet.wav", 0.05, 2);
    var loud_path: [128]u8 = undefined;
    var quiet_path: [128]u8 = undefined;

    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-replay-gain-gapless?mode=memory&cache=shared",
    );
    const database = try liborca.internal.core.runtime.databaseOf(&runtime, library);
    const volume_id = try database.volumes.ensure(.{ .stable_key = "uuid:replay-gain-gapless" });
    const loud_uri = try std.fmt.bufPrint(
        &loud_path,
        ".zig-cache/tmp/{s}/loud.wav",
        .{temporary.sub_path},
    );
    const quiet_uri = try std.fmt.bufPrint(
        &quiet_path,
        ".zig-cache/tmp/{s}/quiet.wav",
        .{temporary.sub_path},
    );
    const loud = try recordAnalyzableTrack(database, volume_id, loud_uri, "Loud");
    const quiet = try recordAnalyzableTrack(database, volume_id, quiet_uri, "Quiet");
    try std.testing.expectEqual(@as(u64, 2), (try runLibraryAnalysis(database)).changed);
    const loud_loudness = (try storedLoudness(database, loud.file_id, loud_uri)).?;
    const quiet_loudness = (try storedLoudness(database, quiet.file_id, quiet_uri)).?;

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    // Full render-ahead depth, so the producer really does run a whole entry
    // ahead of the audio.
    try runtime.zoneOpenOutput(zone, 0, .{ .custom = .{ .target_frames = 8192 } }, 0);
    try runtime.playerSetVolume(player, 1);
    try runtime.playerPlayTracks(
        player,
        library,
        std.testing.io,
        &.{ loud.track_id, quiet.track_id },
        0,
    );

    const loud_entry = try observeEntry(&runtime, &backend, player, 0, 100);
    const quiet_entry = try observeEntry(&runtime, &backend, player, 1, 100);
    try std.testing.expectApproxEqRel(expectedGain(loud_loudness), loud_entry.gain, 0.001);
    try std.testing.expectApproxEqRel(expectedGain(quiet_loudness), quiet_entry.gain, 0.001);

    // And the samples themselves, which is the assertion that cannot be
    // satisfied by reporting alone. Two tones 20 dB apart, each corrected
    // toward the same target, must leave the output at the same level.
    try std.testing.expect(loud_entry.peak > 0.15 and loud_entry.peak < 0.21);
    try std.testing.expectApproxEqRel(loud_entry.peak, quiet_entry.peak, 0.05);

    // The transition stayed gapless, and nothing was stepped over or failed
    // to decode.
    const stats = try runtime.playerQueueStats(player);
    try std.testing.expect(stats.gapless_transitions >= 1);
    try std.testing.expectEqual(@as(u64, 0), stats.format_switch_transitions);
    try std.testing.expectEqual(@as(u64, 0), stats.open_failures);
    try std.testing.expectEqual(@as(u64, 0), stats.decode_errors);
}

test "an unanalyzed entry reached by a gapless advance plays at unity" {
    // Inheriting a correction across the transition is silent when the
    // successor has no measurement of its own, because nothing about the audio
    // says it is being played at another track's level.
    var backend: liborca.internal.audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = liborca.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeSineWav(temporary.dir, "analyzed.wav", 0.5, 2);
    try writeSineWav(temporary.dir, "unanalyzed.wav", 0.5, 2);
    var analyzed_path: [128]u8 = undefined;
    var unanalyzed_path: [128]u8 = undefined;

    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-replay-gain-gapless-unity?mode=memory&cache=shared",
    );
    const database = try liborca.internal.core.runtime.databaseOf(&runtime, library);
    const volume_id = try database.volumes.ensure(.{ .stable_key = "uuid:replay-gain-unity" });
    const analyzed_uri = try std.fmt.bufPrint(
        &analyzed_path,
        ".zig-cache/tmp/{s}/analyzed.wav",
        .{temporary.sub_path},
    );
    const unanalyzed_uri = try std.fmt.bufPrint(
        &unanalyzed_path,
        ".zig-cache/tmp/{s}/unanalyzed.wav",
        .{temporary.sub_path},
    );
    const analyzed = try recordAnalyzableTrack(database, volume_id, analyzed_uri, "Analyzed");
    // Only the first file is projected when the pass runs, so the second is a
    // Track the Library has genuinely never measured.
    try std.testing.expectEqual(@as(u64, 1), (try runLibraryAnalysis(database)).changed);
    const unanalyzed = try recordAnalyzableTrack(
        database,
        volume_id,
        unanalyzed_uri,
        "Unanalyzed",
    );
    try std.testing.expectEqual(
        @as(?liborca.internal.analysis.encoding.Loudness, null),
        try storedLoudness(database, unanalyzed.file_id, unanalyzed_uri),
    );

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneOpenOutput(zone, 0, .{ .custom = .{ .target_frames = 8192 } }, 0);
    try runtime.playerSetVolume(player, 1);
    try runtime.playerPlayTracks(
        player,
        library,
        std.testing.io,
        &.{ analyzed.track_id, unanalyzed.track_id },
        0,
    );

    const analyzed_entry = try observeEntry(&runtime, &backend, player, 0, 100);
    const unanalyzed_entry = try observeEntry(&runtime, &backend, player, 1, 100);
    try std.testing.expect(analyzed_entry.gain < 0.6);
    try std.testing.expectEqual(@as(f32, 1), unanalyzed_entry.gain);

    // Identical audio, so an entry that inherited its predecessor's correction
    // would render at the predecessor's level rather than at its own.
    try std.testing.expect(unanalyzed_entry.peak > 0.45 and unanalyzed_entry.peak < 0.55);
    try std.testing.expect(unanalyzed_entry.peak > 2 * analyzed_entry.peak);
}

fn recordAlbumTrack(
    database: *liborca.internal.database.LibraryDatabase,
    volume_id: i64,
    uri: []const u8,
    title: []const u8,
    release_id: i64,
    track_number: i64,
    seconds: i64,
) !struct { file_id: i64, track_id: i64 } {
    const digest = try liborca.internal.storage.quick_hash.fromPath(std.testing.io, uri);
    const file_id = try database.files.create(.{
        .audio_format = 1,
        .duration_ms = seconds * 1000,
        .quick_hash = &digest,
    });
    try recordLocation(database, file_id, volume_id, uri);
    try database.tracks.upsertTracks(&.{.{
        .title = title,
        .release_id = release_id,
        .track_number = track_number,
        .duration_ms = seconds * 1000,
        .preferred_file_id = file_id,
    }});
    var page = try database.tracks.page(std.testing.allocator, .{ .limit = 512, .offset = 0 });
    defer page.deinit();
    for (page.items) |item| {
        if (std.mem.eql(u8, item.title, title))
            return .{ .file_id = file_id, .track_id = item.id };
    }
    return error.TrackNotProjected;
}

fn referenceAlbumGain(
    loudness: []const liborca.internal.analysis.encoding.Loudness,
    seconds: []const f64,
) f32 {
    var energy: f64 = 0;
    var total: f64 = 0;
    var peak: f32 = 0;
    for (loudness, seconds) |value, duration| {
        energy += duration * std.math.pow(f64, 10, @as(f64, value.integrated_lufs) / 10);
        total += duration;
        peak = @max(peak, value.sample_peak);
    }
    const target: f64 = (liborca.internal.analysis.diagnostics.Parameters{}).replay_gain_target_lufs;
    const lufs = 10 * std.math.log10(energy / total);
    return liborca.internal.audio.processing.replayGainMultiplier(@floatCast(target - lufs), peak);
}

fn decibels(multiplier: f32) f32 {
    return 20 * std.math.log10(multiplier);
}

fn tempUri(buffer: []u8, temporary: *const std.testing.TmpDir, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/{s}", .{ temporary.sub_path, name });
}

test "album ReplayGain plays every Track of a Release at the gain the reference computation gives the whole Release" {
    var backend: liborca.internal.audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = liborca.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeSineWav(temporary.dir, "loud.wav", 0.5, 2);
    try writeSineWav(temporary.dir, "quiet.wav", 0.05, 3);
    var loud_path: [128]u8 = undefined;
    var quiet_path: [128]u8 = undefined;
    const loud_uri = try tempUri(&loud_path, &temporary, "loud.wav");
    const quiet_uri = try tempUri(&quiet_path, &temporary, "quiet.wav");

    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-album-gain-reference?mode=memory&cache=shared",
    );
    const database = try liborca.internal.core.runtime.databaseOf(&runtime, library);
    const volume_id = try database.volumes.ensure(.{ .stable_key = "uuid:album-gain-reference" });
    const release_id = try database.releases.upsert(.{ .release_key = "album", .title = "Album" });
    const loud = try recordAlbumTrack(database, volume_id, loud_uri, "Loud", release_id, 1, 2);
    const quiet = try recordAlbumTrack(database, volume_id, quiet_uri, "Quiet", release_id, 2, 3);
    try std.testing.expectEqual(@as(u64, 2), (try runLibraryAnalysis(database)).changed);
    const loud_loudness = (try storedLoudness(database, loud.file_id, loud_uri)).?;
    const quiet_loudness = (try storedLoudness(database, quiet.file_id, quiet_uri)).?;
    const expected = referenceAlbumGain(&.{ loud_loudness, quiet_loudness }, &.{ 2, 3 });
    try std.testing.expect(@abs(decibels(expected) - decibels(expectedGain(loud_loudness))) > 2);
    try std.testing.expect(@abs(decibels(expected) - decibels(expectedGain(quiet_loudness))) > 2);

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneOpenOutput(zone, 0, .{ .custom = .{ .target_frames = 8192 } }, 0);
    try runtime.playerSetVolume(player, 1);
    try runtime.playerSetReplayGainMode(player, .album);
    try runtime.playerPlayTracks(player, library, std.testing.io, &.{ loud.track_id, quiet.track_id }, 0);

    const loud_entry = try observeEntry(&runtime, &backend, player, 0, 100);
    const loud_path_view = try runtime.playerSignalPath(player);
    const quiet_entry = try observeEntry(&runtime, &backend, player, 1, 100);
    const quiet_path_view = try runtime.playerSignalPath(player);

    try std.testing.expectApproxEqRel(expected, loud_entry.gain, 0.001);
    try std.testing.expectApproxEqRel(expected, quiet_entry.gain, 0.001);
    try std.testing.expectApproxEqRel(0.5 * expected, loud_entry.peak, 0.05);
    try std.testing.expectApproxEqRel(0.05 * expected, quiet_entry.peak, 0.05);

    try std.testing.expectEqual(liborca.ReplayGainSource.album, loud_path_view.replay_gain_source);
    try std.testing.expectApproxEqAbs(decibels(expected), loud_path_view.replay_gain_db.?, 0.01);
    try std.testing.expectApproxEqAbs(decibels(expectedGain(loud_loudness)), loud_path_view.replay_gain_track_db.?, 0.01);
    try std.testing.expectEqual(liborca.ReplayGainSource.album, quiet_path_view.replay_gain_source);
    try std.testing.expectApproxEqAbs(decibels(expectedGain(quiet_loudness)), quiet_path_view.replay_gain_track_db.?, 0.01);
}

test "album ReplayGain falls back to the Track's own correction while another Track of its Release is unmeasured" {
    var backend: liborca.internal.audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = liborca.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeSineWav(temporary.dir, "first.wav", 0.5, 2);
    try writeSineWav(temporary.dir, "second.wav", 0.1, 2);
    var first_path: [128]u8 = undefined;
    var second_path: [128]u8 = undefined;
    const first_uri = try tempUri(&first_path, &temporary, "first.wav");
    const second_uri = try tempUri(&second_path, &temporary, "second.wav");

    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-album-gain-fallback?mode=memory&cache=shared",
    );
    const database = try liborca.internal.core.runtime.databaseOf(&runtime, library);
    const volume_id = try database.volumes.ensure(.{ .stable_key = "uuid:album-gain-fallback" });
    const release_id = try database.releases.upsert(.{ .release_key = "partial", .title = "Partial" });
    const first = try recordAlbumTrack(database, volume_id, first_uri, "First", release_id, 1, 2);
    try std.testing.expectEqual(@as(u64, 1), (try runLibraryAnalysis(database)).changed);
    const second = try recordAlbumTrack(database, volume_id, second_uri, "Second", release_id, 2, 2);
    const first_loudness = (try storedLoudness(database, first.file_id, first_uri)).?;

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneOpenOutput(zone, 0, .robust, 0);
    try runtime.playerSetVolume(player, 1);
    try runtime.playerSetReplayGainMode(player, .album);
    try runtime.playerPlayTracks(player, library, std.testing.io, &.{ first.track_id, second.track_id }, 0);

    try std.testing.expectApproxEqRel(expectedGain(first_loudness), try runtime.playerEffectiveGain(player), 0.001);
    var path = try runtime.playerSignalPath(player);
    try std.testing.expectEqual(liborca.ReplayGainSource.track_fallback, path.replay_gain_source);
    try std.testing.expectEqual(@as(?f32, null), path.replay_gain_track_db);

    try std.testing.expect(try runtime.playerNext(player));
    try std.testing.expectEqual(@as(f32, 1), try runtime.playerEffectiveGain(player));
    path = try runtime.playerSignalPath(player);
    try std.testing.expectEqual(liborca.ReplayGainSource.none, path.replay_gain_source);

    try std.testing.expectEqual(@as(u64, 1), (try runLibraryAnalysis(database)).changed);
    const second_loudness = (try storedLoudness(database, second.file_id, second_uri)).?;
    try runtime.playerPlayTracks(player, library, std.testing.io, &.{first.track_id}, 0);
    try std.testing.expectApproxEqRel(
        referenceAlbumGain(&.{ first_loudness, second_loudness }, &.{ 2, 2 }),
        try runtime.playerEffectiveGain(player),
        0.001,
    );
    path = try runtime.playerSignalPath(player);
    try std.testing.expectEqual(liborca.ReplayGainSource.album, path.replay_gain_source);
}

test "re-analysing a Track or moving it to another Release changes the album gain at the next open" {
    var backend: liborca.internal.audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = liborca.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeSineWav(temporary.dir, "kept.wav", 0.5, 2);
    try writeSineWav(temporary.dir, "changed.wav", 0.05, 2);
    var kept_path: [128]u8 = undefined;
    var changed_path: [128]u8 = undefined;
    const kept_uri = try tempUri(&kept_path, &temporary, "kept.wav");
    const changed_uri = try tempUri(&changed_path, &temporary, "changed.wav");

    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-album-gain-fresh?mode=memory&cache=shared",
    );
    const database = try liborca.internal.core.runtime.databaseOf(&runtime, library);
    const volume_id = try database.volumes.ensure(.{ .stable_key = "uuid:album-gain-fresh" });
    const first_release = try database.releases.upsert(.{ .release_key = "first", .title = "First" });
    const second_release = try database.releases.upsert(.{ .release_key = "second", .title = "Second" });
    const kept = try recordAlbumTrack(database, volume_id, kept_uri, "Kept", first_release, 1, 2);
    const changed = try recordAlbumTrack(database, volume_id, changed_uri, "Changed", first_release, 2, 2);
    try std.testing.expectEqual(@as(u64, 2), (try runLibraryAnalysis(database)).changed);
    const kept_loudness = (try storedLoudness(database, kept.file_id, kept_uri)).?;
    const quiet_loudness = (try storedLoudness(database, changed.file_id, changed_uri)).?;

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneOpenOutput(zone, 0, .robust, 0);
    try runtime.playerSetVolume(player, 1);
    try runtime.playerSetReplayGainMode(player, .album);
    try runtime.playerPlayTracks(player, library, std.testing.io, &.{kept.track_id}, 0);
    const before = try runtime.playerEffectiveGain(player);
    try std.testing.expectApproxEqRel(referenceAlbumGain(&.{ kept_loudness, quiet_loudness }, &.{ 2, 2 }), before, 0.001);

    try runtime.stopPlayer(player);
    try writeSineWav(temporary.dir, "changed.wav", 0.5, 2);
    const digest = try liborca.internal.storage.quick_hash.fromPath(std.testing.io, changed_uri);
    try database.files.update(changed.file_id, .{ .audio_format = 1, .duration_ms = 2000, .quick_hash = &digest });
    try recordLocation(database, changed.file_id, volume_id, changed_uri);
    try std.testing.expectEqual(@as(u64, 1), (try runLibraryAnalysis(database)).changed);
    const loud_loudness = (try storedLoudness(database, changed.file_id, changed_uri)).?;
    try runtime.playerPlayTracks(player, library, std.testing.io, &.{kept.track_id}, 0);
    const reanalysed = try runtime.playerEffectiveGain(player);
    try std.testing.expectApproxEqRel(referenceAlbumGain(&.{ kept_loudness, loud_loudness }, &.{ 2, 2 }), reanalysed, 0.001);
    try std.testing.expect(decibels(before) - decibels(reanalysed) > 1);

    try runtime.stopPlayer(player);
    var sql: [128]u8 = undefined;
    try database.database.exec(try std.fmt.bufPrintSentinel(
        &sql,
        "UPDATE tracks SET release_id = {d} WHERE id = {d};",
        .{ second_release, changed.track_id },
        0,
    ));
    try runtime.playerPlayTracks(player, library, std.testing.io, &.{ kept.track_id, changed.track_id }, 0);
    try std.testing.expectApproxEqRel(expectedGain(kept_loudness), try runtime.playerEffectiveGain(player), 0.001);
    try std.testing.expectEqual(liborca.ReplayGainSource.album, (try runtime.playerSignalPath(player)).replay_gain_source);
    try std.testing.expect(try runtime.playerNext(player));
    try std.testing.expectApproxEqRel(expectedGain(loud_loudness), try runtime.playerEffectiveGain(player), 0.001);
    try std.testing.expectEqual(liborca.ReplayGainSource.album, (try runtime.playerSignalPath(player)).replay_gain_source);
}

fn framesUntilPeak(
    backend: *liborca.internal.audio.output.TestBackend,
    threshold: f32,
    falling: bool,
) !usize {
    var samples: [128]f32 = @splat(0);
    var frames: usize = 0;
    var attempts: usize = 0;
    while (attempts < 4_000_000) : (attempts += 1) {
        const stream = backend.liveStream() orelse {
            std.Thread.yield() catch {};
            continue;
        };
        stream.pump(&samples, 128);
        var peak: f32 = 0;
        for (samples) |value| peak = @max(peak, @abs(value));
        if (peak == 0) {
            std.Thread.yield() catch {};
            continue;
        }
        frames += samples.len;
        if (if (falling) peak < threshold else peak > threshold) return frames;
    }
    return error.PeakNeverCrossed;
}

fn settle(backend: *liborca.internal.audio.output.TestBackend, frames: usize) !void {
    var samples: [128]f32 = @splat(0);
    var rendered: usize = 0;
    var attempts: usize = 0;
    while (rendered < frames and attempts < 4_000_000) : (attempts += 1) {
        const stream = backend.liveStream() orelse {
            std.Thread.yield() catch {};
            continue;
        };
        stream.pump(&samples, 128);
        var peak: f32 = 0;
        for (samples) |value| peak = @max(peak, @abs(value));
        if (peak == 0) {
            std.Thread.yield() catch {};
            continue;
        }
        rendered += samples.len;
        std.Thread.yield() catch {};
    }
    if (rendered < frames) return error.EntryRenderedNothing;
}

test "a switch to album ReplayGain reaches the audible samples as promptly as a switch to track ReplayGain" {
    var backend: liborca.internal.audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = liborca.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeSineWav(temporary.dir, "long.wav", 0.5, 10);
    try writeSineWav(temporary.dir, "short.wav", 0.05, 10);
    var long_path: [128]u8 = undefined;
    var short_path: [128]u8 = undefined;
    const long_uri = try tempUri(&long_path, &temporary, "long.wav");
    const short_uri = try tempUri(&short_path, &temporary, "short.wav");

    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-album-gain-switch?mode=memory&cache=shared",
    );
    const database = try liborca.internal.core.runtime.databaseOf(&runtime, library);
    const volume_id = try database.volumes.ensure(.{ .stable_key = "uuid:album-gain-switch" });
    const release_id = try database.releases.upsert(.{ .release_key = "switch", .title = "Switch" });
    const long = try recordAlbumTrack(database, volume_id, long_uri, "Long", release_id, 1, 10);
    const short = try recordAlbumTrack(database, volume_id, short_uri, "Short", release_id, 2, 10);
    try std.testing.expectEqual(@as(u64, 2), (try runLibraryAnalysis(database)).changed);
    const long_loudness = (try storedLoudness(database, long.file_id, long_uri)).?;
    const short_loudness = (try storedLoudness(database, short.file_id, short_uri)).?;
    const track_gain = expectedGain(long_loudness);
    const album_gain = referenceAlbumGain(&.{ long_loudness, short_loudness }, &.{ 10, 10 });

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    const target_frames = 8192;
    try runtime.zoneOpenOutput(zone, 0, .{ .custom = .{ .target_frames = target_frames } }, 0);
    try runtime.playerSetVolume(player, 1);
    try runtime.playerSetReplayGainMode(player, .off);
    try runtime.playerPlayTracks(player, library, std.testing.io, &.{long.track_id}, 0);
    _ = try framesUntilPeak(&backend, 0.45, false);
    try settle(&backend, 4 * target_frames);

    try runtime.playerSetReplayGainMode(player, .track);
    const to_track = try framesUntilPeak(&backend, 0.5 * (1 + track_gain) / 2, true);
    try runtime.playerSetReplayGainMode(player, .off);
    _ = try framesUntilPeak(&backend, 0.45, false);
    try settle(&backend, 4 * target_frames);
    try runtime.playerSetReplayGainMode(player, .album);
    const to_album = try framesUntilPeak(&backend, 0.5 * (1 + album_gain) / 2, true);

    try std.testing.expect(to_track < 44_100);
    try std.testing.expect(to_album <= to_track + target_frames / 2);
    try std.testing.expectEqual(liborca.ReplayGainSource.album, (try runtime.playerSignalPath(player)).replay_gain_source);
}

test "shuffle across two Releases plays each entry at its own Release's album gain" {
    var backend: liborca.internal.audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = liborca.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const names = [_][]const u8{ "a1.wav", "a2.wav", "b1.wav", "b2.wav" };
    const amplitudes = [_]f32{ 0.5, 0.05, 0.2, 0.1 };
    for (names, amplitudes) |name, amplitude| try writeSineWav(temporary.dir, name, amplitude, 2);
    var paths: [4][128]u8 = undefined;
    var uris: [4][]const u8 = undefined;
    for (&paths, &uris, names) |*path, *uri, name| uri.* = try tempUri(path, &temporary, name);

    const library = try runtime.openLibrary(
        std.testing.io,
        "file:orca-album-gain-shuffle?mode=memory&cache=shared",
    );
    const database = try liborca.internal.core.runtime.databaseOf(&runtime, library);
    const volume_id = try database.volumes.ensure(.{ .stable_key = "uuid:album-gain-shuffle" });
    const releases = [_]i64{
        try database.releases.upsert(.{ .release_key = "a", .title = "A" }),
        try database.releases.upsert(.{ .release_key = "b", .title = "B" }),
    };
    const titles = [_][]const u8{ "A1", "A2", "B1", "B2" };
    var track_ids: [4]i64 = undefined;
    var loudness: [4]liborca.internal.analysis.encoding.Loudness = undefined;
    var file_ids: [4]i64 = undefined;
    for (0..4) |index| {
        const recorded = try recordAlbumTrack(database, volume_id, uris[index], titles[index], releases[index / 2], @intCast(index % 2 + 1), 2);
        track_ids[index] = recorded.track_id;
        file_ids[index] = recorded.file_id;
    }
    try std.testing.expectEqual(@as(u64, 4), (try runLibraryAnalysis(database)).changed);
    for (0..4) |index| loudness[index] = (try storedLoudness(database, file_ids[index], uris[index])).?;
    const album_gains = [_]f32{
        referenceAlbumGain(loudness[0..2], &.{ 2, 2 }),
        referenceAlbumGain(loudness[2..4], &.{ 2, 2 }),
    };
    try std.testing.expect(@abs(decibels(album_gains[0]) - decibels(album_gains[1])) > 3);

    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneOpenOutput(zone, 0, .{ .custom = .{ .target_frames = 8192 } }, 0);
    try runtime.playerSetVolume(player, 1);
    try runtime.playerSetReplayGainMode(player, .album);
    try runtime.playerSetShuffle(player, true);
    try runtime.playerPlayTracks(player, library, std.testing.io, &.{ track_ids[0], track_ids[2], track_ids[1], track_ids[3] }, 0);

    var heard: [4]bool = @splat(false);
    for (0..4) |position| {
        const entry = try observeEntry(&runtime, &backend, player, @intCast(position), 60);
        const track_id = (try runtime.playerStatus(player)).track_id.?;
        const index = std.mem.indexOfScalar(i64, &track_ids, track_id).?;
        heard[index] = true;
        const expected = album_gains[index / 2];
        try std.testing.expectApproxEqRel(expected, entry.gain, 0.001);
        try std.testing.expectApproxEqRel(amplitudes[index] * expected, entry.peak, 0.05);
    }
    for (heard) |value| try std.testing.expect(value);
}
test "the queue reports the rows a host displays, in the order it will play them" {
    // Resolving queue rows is liborca's job, never a frontend's.
    var backend: liborca.internal.audio.output.TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = liborca.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setOutputFactory(backend.factory());

    // Real bytes, because enqueueing into an idle Player loads the first
    // entry and a row pointing at nothing cannot be opened.
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var fixture = try liborca.internal.storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/tagged-reference.flac",
    );
    const readable = fixture.readable();
    const bytes = try std.testing.allocator.alloc(u8, @intCast(readable.size()));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(bytes.len, try readable.readAt(0, bytes));
    fixture.close();
    for ([_][]const u8{ "queue-a.flac", "queue-b.flac" }) |name|
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
    var first_path: [128]u8 = undefined;
    var second_path: [128]u8 = undefined;

    var ids: [2]i64 = @splat(0);
    const library = try openQueueLibrary(
        &runtime,
        "file:orca-queue-rows?mode=memory&cache=shared",
        &.{
            try std.fmt.bufPrint(&first_path, ".zig-cache/tmp/{s}/queue-a.flac", .{temporary.sub_path}),
            try std.fmt.bufPrint(&second_path, ".zig-cache/tmp/{s}/queue-b.flac", .{temporary.sub_path}),
        },
        &ids,
    );
    const player = try runtime.createPlayer();
    try runtime.playerBindLibrary(player, library, std.testing.io);

    // Enqueued second-then-first, so a result in id order would pass by
    // accident and a result in queue order is the only way through.
    try runtime.playerEnqueueTracks(
        player,
        library,
        std.testing.io,
        &.{ ids[1], ids[0] },
    );

    var page = try runtime.playerQueueTracks(player, std.testing.allocator, 0, 16);
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqualStrings("Entry 1", page.items[0].track.?.title);
    try std.testing.expectEqualStrings("Entry 0", page.items[1].track.?.title);

    // Bounded like every other page in this codebase.
    try std.testing.expectError(
        error.PageOutOfRange,
        runtime.playerQueueTracks(player, std.testing.allocator, 0, 0),
    );

    // An offset walks the queue rather than restarting it.
    var tail = try runtime.playerQueueTracks(player, std.testing.allocator, 1, 16);
    defer tail.deinit();
    try std.testing.expectEqual(@as(usize, 1), tail.items.len);
    try std.testing.expectEqualStrings("Entry 0", tail.items[0].track.?.title);
}

test {
    _ = @import("c_abi_layout.zig");
    _ = @import("library_locks.zig");
    _ = @import("library_roots.zig");
}
