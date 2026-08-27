const std = @import("std");
const liborca = @import("liborca");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (args.len > 1 and std.mem.eql(u8, args[1], "--version")) {
        try stdout.print("orca-cli {f}\n", .{liborca.version});
    } else if (args.len > 1 and std.mem.eql(u8, args[1], "demo")) {
        var runtime = liborca.OrcaRuntime.init(allocator);
        defer runtime.deinit();

        const request_id = try runtime.submit(.create_player);
        _ = runtime.processNextCommand();
        const event = runtime.pollEvent() orelse return error.MissingCompletionEvent;
        if (event.request_id != request_id) return error.UnexpectedCompletionEvent;
        switch (event.outcome) {
            .player_created => |player| try stdout.print(
                "created Player handle {d}:{d}\n",
                .{ player.index, player.generation },
            ),
            else => return error.PlayerCreationFailed,
        }
    } else if (args.len == 4 and std.mem.eql(u8, args[1], "scan")) {
        // The same path the C ABI exposes: register the root, start the scan as
        // a runtime job on a registered worker, and poll it. The scan projects
        // as it commits, which is why there is no separate projection step here.
        const database_path = try allocator.dupeSentinel(u8, args[2], 0);
        var runtime = liborca.OrcaRuntime.init(allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(init.io, database_path);
        // Adding a root is an explicit user action, so this is the one place
        // allowed to write a volume identifier to a mount root that has no
        // filesystem UUID of its own.
        const binding = try runtime.libraryAddRoot(library_handle, init.io, args[3]);
        if (binding.claimed_locations != 0) try stdout.print(
            "claimed {d} migrated locations for volume {d}\n",
            .{ binding.claimed_locations, binding.volume_id },
        );
        const job_handle = try runtime.startLibraryScan(library_handle, .{
            .root_id = binding.root_id,
        });
        try awaitJob(&runtime, stdout, job_handle, null);
        try printScanStats(stdout, try runtime.jobScanStats(job_handle));
    } else if (args.len == 3 and std.mem.eql(u8, args[1], "project")) {
        // Reprojection without a filesystem walk: this is what refreshes the
        // library after a metadata edit or a provider acceptance, and it is why
        // the projection is a pass of its own rather than part of the scanner.
        const database_path = try allocator.dupeSentinel(u8, args[2], 0);
        var runtime = liborca.OrcaRuntime.init(allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(init.io, database_path);
        const job_handle = try runtime.startLibraryProjection(library_handle);
        try awaitJob(&runtime, stdout, job_handle, null);
        try printScanStats(stdout, try runtime.jobScanStats(job_handle));
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "backfill")) {
        // Repairs `files` rows whose declared audio properties are missing,
        // with no filesystem walk. The job reprojects each repaired batch
        // itself, which is why there is no `project` step after this one.
        // `--cancel-after=MS` is the same kind of affordance `play-tracks`
        // carries: the CLI is the architectural test client, and a cooperative
        // cancellation nothing outside a unit test can trigger is not one a
        // host can rely on.
        var force = false;
        var cancel_after_ms: ?u64 = null;
        for (args[3..]) |argument| {
            if (std.mem.eql(u8, argument, "--force")) {
                force = true;
            } else if (std.mem.startsWith(u8, argument, "--cancel-after=")) {
                cancel_after_ms = try std.fmt.parseInt(
                    u64,
                    argument["--cancel-after=".len..],
                    10,
                );
            } else return error.UnknownOption;
        }
        const database_path = try allocator.dupeSentinel(u8, args[2], 0);
        var runtime = liborca.OrcaRuntime.init(allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(init.io, database_path);
        const job_handle = try runtime.startLibraryPropertyBackfill(library_handle, .{
            .force = force,
        });
        const planned = try runtime.jobSnapshotSynced(job_handle);
        try stdout.print("{d} files to probe\n", .{planned.total_units orelse 0});
        try stdout.flush();
        try awaitJob(&runtime, stdout, job_handle, cancel_after_ms);
        try printBackfillStats(stdout, try runtime.jobScanStats(job_handle));
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "analyze-library")) {
        // The library-wide half of `analyze`. It decodes whole files, so a
        // real run is measured in hours and `--cancel-after=MS` is not a test
        // affordance but the ordinary way to use it: stop it, start it again,
        // and it selects only what is left.
        var batch_size: usize = 0;
        var cancel_after_ms: ?u64 = null;
        for (args[3..]) |argument| {
            if (std.mem.startsWith(u8, argument, "--batch=")) {
                batch_size = try std.fmt.parseInt(usize, argument["--batch=".len..], 10);
            } else if (std.mem.startsWith(u8, argument, "--cancel-after=")) {
                cancel_after_ms = try std.fmt.parseInt(
                    u64,
                    argument["--cancel-after=".len..],
                    10,
                );
            } else return error.UnknownOption;
        }
        const database_path = try allocator.dupeSentinel(u8, args[2], 0);
        var runtime = liborca.OrcaRuntime.init(allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(init.io, database_path);
        var request: liborca.core.runtime.AnalysisRequest = .{};
        if (batch_size != 0) request.batch_size = batch_size;
        const job_handle = try runtime.startLibraryAnalysis(library_handle, request);
        const planned = try runtime.jobSnapshotSynced(job_handle);
        try stdout.print("{d} files to analyze\n", .{planned.total_units orelse 0});
        try stdout.flush();
        try awaitJob(&runtime, stdout, job_handle, cancel_after_ms);
        try printAnalysisStats(stdout, try runtime.jobScanStats(job_handle));
        const library_database = try runtime.libraryDatabase(library_handle);
        try stdout.print("{d} files still to analyze\n", .{
            try library_database.files.unanalyzedCount(
                liborca.analysis.service.diagnosticsSelector(.{}),
            ),
        });
    } else if (args.len == 4 and std.mem.eql(u8, args[1], "analyze")) {
        const database_path = try allocator.dupeSentinel(u8, args[2], 0);
        var runtime = liborca.OrcaRuntime.init(allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(init.io, database_path);
        const library_database = try runtime.libraryDatabase(library_handle);
        const codecs = liborca.codec.CodecRegistry.builtins();
        const service: liborca.analysis.service.Service = .{
            .allocator = allocator,
            .io = init.io,
            .codecs = &codecs,
            .cache = &library_database.analysis_cache,
        };
        // Analysis caches against file identity, so an analyze of a file no
        // scan has seen still records it as an unverified location rather than
        // losing the result.
        const binding = try library_database.resolveOrCreateFile(init.io, args[3], .{});
        const result = try service.analyzeFile(binding.file_id, args[3], .{});
        defer result.deinit();
        try stdout.print(
            "cache={s} peak={d:.6} rms={d:.6} clipped={d} silent={d} fingerprint_blocks={d}\n",
            .{
                if (result.cache_hit) "hit" else "miss",
                result.diagnostics.sample_peak,
                result.diagnostics.rms,
                result.diagnostics.clipped_samples,
                result.diagnostics.silent_frames,
                result.fingerprint.signatures.len,
            },
        );
        if (result.diagnostics.integrated_lufs) |loudness| try stdout.print(
            "loudness={d:.2} LUFS replay_gain={d:.2} dB\n",
            .{ loudness, result.diagnostics.replay_gain_db.? },
        );
    } else if ((args.len == 3 or args.len == 4) and std.mem.eql(u8, args[1], "health")) {
        const database_path = try allocator.dupeSentinel(u8, args[2], 0);
        const offset = if (args.len == 4) try std.fmt.parseInt(u32, args[3], 10) else 0;
        var runtime = liborca.OrcaRuntime.init(allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(init.io, database_path);
        const library_database = try runtime.libraryDatabase(library_handle);
        var page = try library_database.health_issues.page(allocator, 256, offset);
        defer page.deinit();
        for (page.items) |issue| try stdout.print(
            "{s}\t{s}\t{s}\t{s}\n",
            .{ @tagName(issue.severity), @tagName(issue.kind), issue.path, issue.details },
        );
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "artists")) {
        try listArtists(allocator, init.io, stdout, args[2], args[3..]);
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "releases")) {
        try listReleases(allocator, init.io, stdout, args[2], args[3..]);
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "tracks")) {
        try listTracks(allocator, init.io, stdout, args[2], args[3..]);
    } else if (args.len == 2 and std.mem.eql(u8, args[1], "devices")) {
        var runtime = liborca.OrcaRuntime.init(allocator);
        defer runtime.deinit();
        var devices: [32]liborca.audio.backend.Device = undefined;
        const count = try runtime.enumerateOutputDevices(&devices);
        for (devices[0..count]) |device|
            try stdout.print("{d}\t{s}\n", .{ device.id, device.nameSlice() });
    } else if ((args.len == 3 or args.len == 4) and std.mem.eql(u8, args[1], "play")) {
        const device_id = if (args.len == 4)
            try std.fmt.parseInt(u64, args[3], 10)
        else
            0;
        // The one object graph: a runtime Player owns the source and the single
        // decode producer, and a runtime Zone owns the pool, pipe, render
        // context and OutputSession. Nothing about playback lives in this frame.
        var runtime = liborca.OrcaRuntime.init(allocator);
        defer runtime.deinit();
        const player = try runtime.createPlayer();
        const zone = try runtime.createZone();
        try runtime.attachZone(zone, player);
        try runtime.playerLoadFile(player, init.io, args[2]);
        try runtime.zoneRequestOutput(zone, device_id);
        try runtime.playPlayer(player);

        var elapsed_ms: u64 = 0;
        while (!try runtime.playerDrained(player)) {
            if (elapsed_ms >= 30 * std.time.ms_per_s) return error.PlaybackStalled;
            sleepMilliseconds(10);
            elapsed_ms += 10;
        }
        // Every prepared block has been handed to the device. Pausing stops the
        // now-empty render path from counting the tail as missing audio, and the
        // short wait lets the device drain what it already holds.
        try runtime.pausePlayer(player);
        sleepMilliseconds(200);

        const snapshot = try runtime.playerSnapshot(player);
        const stats = try runtime.zoneStats(zone);
        try stdout.print(
            "played={d} underruns={d} state={s} recoveries={d} quantum={d}\n",
            .{
                snapshot.position_frames,
                stats.underruns,
                @tagName(stats.output_state),
                stats.recovery_attempts,
                stats.backend_quantum_frames,
            },
        );
    } else if (args.len >= 4 and std.mem.eql(u8, args[1], "play-tracks")) {
        try playTracks(allocator, init.io, stdout, args[2], args[3], args[4..]);
    } else {
        try stdout.writeAll(
            \\Usage: orca-cli [--version | demo | scan DATABASE ROOT | project DATABASE
            \\                 | backfill DATABASE [--force] [--cancel-after=MS]
            \\                 | analyze DATABASE AUDIO
            \\                 | analyze-library DATABASE [--batch=N] [--cancel-after=MS]
            \\                 | health DATABASE [OFFSET] | devices | play AUDIO [DEVICE_ID]
            \\                 | play-tracks DATABASE IDS [OPTIONS]
            \\                 | artists DATABASE [OPTIONS]
            \\                 | releases DATABASE [--artist ID] [OPTIONS]
            \\                 | tracks DATABASE [OPTIONS]]
            \\
            \\Browsing. artists lists Artists in sort order; releases lists Releases,
            \\optionally one Artist's; tracks lists Tracks in a named order, optionally
            \\scoped to one Artist or one Release. Options:
            \\  --artist ID        only this Artist
            \\  --release ID       only this Release (tracks only)
            \\  --sort KEY         id|artist|album|title|track|duration|added (tracks only)
            \\  --desc             reverse the order
            \\  --limit N          page size, 1 to 512 (default 50)
            \\  --offset N         rows to skip
            \\
            \\play-tracks plays a comma-separated list of Track ids as a playback
            \\queue. Options:
            \\  --device=ID        output device (0 = server default)
            \\  --replay-gain=off|track   loudness correction per entry (default track)
            \\  --start=N          queue position to begin at
            \\  --repeat=off|all|one
            \\  --shuffle
            \\  --tail=MS          on each new entry, seek to MS before its end
            \\  --skip-after=MS    issue next MS after each entry becomes audible
            \\  --previous-after=MS  issue previous once, MS after playback starts
            \\  --limit=MS         stop after MS of wall clock
            \\
            \\analyze-library decodes every file the Library has not measured yet and
            \\stores its loudness, peak, clipping, silence and fingerprint. That
            \\measurement is what ReplayGain on playback reads; without it every track
            \\plays at unity. It decodes whole files, so it is slow, and it is meant to
            \\be stopped and restarted: --cancel-after=MS interrupts it inside a file,
            \\the batch already measured is still committed, and the next run selects
            \\only what is left.
            \\
            \\backfill re-reads the headers of files whose declared audio properties
            \\are missing and reprojects the Tracks derived from them, without walking
            \\a filesystem. --force also re-probes rows that already declare
            \\properties, which is for a probe implementation that improved rather
            \\than for ordinary use. --cancel-after=MS interrupts the job cooperatively
            \\once it has run that long; a later run resumes what it did not finish.
            \\
            \\The host-independent Orca control client.
            \\
        );
    }

    try stdout.flush();
}

/// A volume change scheduled mid-run. Exists so the independence of user
/// volume and loudness correction is observable from outside: changing one
/// while a track plays must leave the other exactly where it was.
const ScheduledVolume = struct {
    at_ms: u64,
    linear: f32,
};

const PlayTracksOptions = struct {
    device: u64 = 0,
    volume: f32 = 1,
    set_volume: ?ScheduledVolume = null,
    replay_gain: liborca.audio.processing.ReplayGainMode = .track,
    start: u32 = 0,
    repeat: liborca.core.runtime.RepeatMode = .off,
    shuffle: bool = false,
    tail_ms: ?u64 = null,
    skip_after_ms: ?u64 = null,
    previous_after_ms: ?u64 = null,
    limit_ms: u64 = 10 * 60 * 1000,
};

fn parseOption(options: *PlayTracksOptions, argument: []const u8) !void {
    if (std.mem.eql(u8, argument, "--shuffle")) {
        options.shuffle = true;
        return;
    }
    const split = std.mem.indexOfScalar(u8, argument, '=') orelse return error.UnknownOption;
    const name = argument[0..split];
    const value = argument[split + 1 ..];
    if (std.mem.eql(u8, name, "--device")) {
        options.device = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--volume")) {
        options.volume = try std.fmt.parseFloat(f32, value);
    } else if (std.mem.eql(u8, name, "--set-volume")) {
        const separator = std.mem.indexOfScalar(u8, value, ':') orelse
            return error.MalformedScheduledVolume;
        options.set_volume = .{
            .at_ms = try std.fmt.parseInt(u64, value[0..separator], 10),
            .linear = try std.fmt.parseFloat(f32, value[separator + 1 ..]),
        };
    } else if (std.mem.eql(u8, name, "--start")) {
        options.start = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--replay-gain")) {
        options.replay_gain = if (std.mem.eql(u8, value, "off"))
            .off
        else if (std.mem.eql(u8, value, "track"))
            .track
        else
            return error.UnknownReplayGainMode;
    } else if (std.mem.eql(u8, name, "--repeat")) {
        options.repeat = if (std.mem.eql(u8, value, "all"))
            .all
        else if (std.mem.eql(u8, value, "one"))
            .one
        else if (std.mem.eql(u8, value, "off"))
            .off
        else
            return error.UnknownRepeatMode;
    } else if (std.mem.eql(u8, name, "--tail")) {
        options.tail_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--skip-after")) {
        options.skip_after_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--previous-after")) {
        options.previous_after_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--limit")) {
        options.limit_ms = try std.fmt.parseInt(u64, value, 10);
    } else return error.UnknownOption;
}

/// The queue driven from the outside, exactly as a frontend would drive it.
///
/// Everything here is presentation: parse ids, call the runtime, print what it
/// reports. No transport state, no notion of "which track is next", and no
/// decoding — those all live in `liborca`, which is the whole point of using
/// the CLI as the architectural test client.
fn playTracks(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    database_path_argument: []const u8,
    id_list: []const u8,
    option_arguments: []const []const u8,
) !void {
    var options: PlayTracksOptions = .{};
    for (option_arguments) |argument| try parseOption(&options, argument);

    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(allocator);
    var walk = std.mem.splitScalar(u8, id_list, ',');
    while (walk.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " ");
        if (trimmed.len == 0) continue;
        try ids.append(allocator, try std.fmt.parseInt(i64, trimmed, 10));
    }
    if (ids.items.len == 0) return error.NoTrackIds;

    const database_path = try allocator.dupeSentinel(u8, database_path_argument, 0);
    var runtime = liborca.OrcaRuntime.init(allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(io, database_path);
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneRequestOutput(zone, options.device);

    try runtime.playerSetVolume(player, options.volume);
    try runtime.playerSetReplayGainMode(player, options.replay_gain);
    try runtime.playerSetRepeat(player, options.repeat);
    if (options.shuffle) try runtime.playerSetShuffle(player, true);
    try runtime.playerPlayTracks(player, library, io, ids.items, options.start);

    var elapsed_ms: u64 = 0;
    var entry_elapsed_ms: u64 = 0;
    var last_cursor: ?u32 = null;
    var took_previous = options.previous_after_ms == null;
    var set_volume = options.set_volume == null;
    // How often the producer was observed a whole entry ahead of the audio.
    // Nonzero is the proof that now-playing is derived from rendered audio
    // rather than from the decode cursor.
    var decode_lead_polls: u64 = 0;
    while (elapsed_ms < options.limit_ms) {
        const snapshot = try runtime.playerQueueSnapshot(player);
        if (snapshot.decode_position != snapshot.cursor) decode_lead_polls += 1;
        if (last_cursor == null or last_cursor.? != snapshot.cursor) {
            last_cursor = snapshot.cursor;
            entry_elapsed_ms = 0;
            const now_playing = try runtime.playerNowPlaying(player);
            // volume and gain differing is what a loudness correction looks
            // like from outside: `gain` is what the audible entry's samples
            // are being multiplied by, and `volume` is only what the user
            // asked for.
            try stdout.print(
                "now-playing at={d}ms position={d} decode_position={d} track={?d} " ++
                    "volume={d:.6} gain={d:.6}\n",
                .{
                    elapsed_ms,
                    snapshot.cursor,
                    snapshot.decode_position,
                    if (now_playing) |ref| ref.track_id else null,
                    try runtime.playerVolume(player),
                    try runtime.playerEffectiveGain(player),
                },
            );
            try stdout.flush();
            if (options.tail_ms) |tail| _ = try runtime.playerSeekToTail(player, tail);
        }
        if (!set_volume and elapsed_ms >= options.set_volume.?.at_ms) {
            set_volume = true;
            try runtime.playerSetVolume(player, options.set_volume.?.linear);
            // Printed as a pair on purpose: a volume change that disturbed the
            // loudness correction, or a correction that moved the volume,
            // would show up here as the other number moving.
            try stdout.print(
                "set-volume at={d}ms volume={d:.6} gain={d:.6}\n",
                .{
                    elapsed_ms,
                    try runtime.playerVolume(player),
                    try runtime.playerEffectiveGain(player),
                },
            );
            try stdout.flush();
        }
        if (!took_previous and elapsed_ms >= options.previous_after_ms.?) {
            took_previous = true;
            const moved = try runtime.playerPrevious(player);
            try stdout.print("previous at={d}ms moved={}\n", .{ elapsed_ms, moved });
            try stdout.flush();
            last_cursor = null;
        }
        if (options.skip_after_ms) |after| {
            if (entry_elapsed_ms >= after) {
                const moved = try runtime.playerNext(player);
                try stdout.print("next at={d}ms moved={}\n", .{ elapsed_ms, moved });
                try stdout.flush();
                if (!moved) break;
                last_cursor = null;
                continue;
            }
        }
        if (try runtime.playerDrained(player)) break;
        sleepMilliseconds(10);
        elapsed_ms += 10;
        entry_elapsed_ms += 10;
    }

    try runtime.pausePlayer(player);
    sleepMilliseconds(200);
    const snapshot = try runtime.playerQueueSnapshot(player);
    const stats = try runtime.playerQueueStats(player);
    const zone_stats = try runtime.zoneStats(zone);
    try stdout.print(
        "queue entries={d} cursor={d} started={d} gapless={d} format_switch={d} " ++
            "open_failures={d} decode_errors={d} decode_lead_polls={d} " ++
            "underruns={d} quantum={d} state={s}\n",
        .{
            snapshot.entries,
            snapshot.cursor,
            stats.entries_started,
            stats.gapless_transitions,
            stats.format_switch_transitions,
            stats.open_failures,
            stats.decode_errors,
            decode_lead_polls,
            zone_stats.underruns,
            zone_stats.backend_quantum_frames,
            @tagName(zone_stats.output_state),
        },
    );
}

const BrowseOptions = struct {
    artist_id: ?i64 = null,
    /// Free text for `artists`, folded the way artist keys are folded, so
    /// `--filter el-p` finds the one spelled with a U+2010 hyphen.
    filter: []const u8 = "",
    release_id: ?i64 = null,
    sort: liborca.database.TrackSort = .id,
    descending: bool = false,
    limit: u32 = 50,
    offset: u32 = 0,
};

/// `--name value` pairs, matching the shape the rest of this file already
/// parses. A flag this verb does not understand is an error rather than
/// something quietly ignored: a mistyped `--sort` that silently listed
/// insertion order would look like a liborca bug.
fn parseBrowseOptions(arguments: []const []const u8) !BrowseOptions {
    var options: BrowseOptions = .{};
    var index: usize = 0;
    while (index < arguments.len) {
        const name = arguments[index];
        if (std.mem.eql(u8, name, "--desc")) {
            options.descending = true;
            index += 1;
            continue;
        }
        if (index + 1 >= arguments.len) return error.MissingOptionValue;
        const value = arguments[index + 1];
        index += 2;
        if (std.mem.eql(u8, name, "--artist")) {
            options.artist_id = try std.fmt.parseInt(i64, value, 10);
        } else if (std.mem.eql(u8, name, "--filter")) {
            options.filter = value;
        } else if (std.mem.eql(u8, name, "--release")) {
            options.release_id = try std.fmt.parseInt(i64, value, 10);
        } else if (std.mem.eql(u8, name, "--limit")) {
            options.limit = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, name, "--offset")) {
            options.offset = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, name, "--sort")) {
            options.sort = if (std.mem.eql(u8, value, "id"))
                .id
            else if (std.mem.eql(u8, value, "artist"))
                .artist
            else if (std.mem.eql(u8, value, "album"))
                .album
            else if (std.mem.eql(u8, value, "title"))
                .title
            else if (std.mem.eql(u8, value, "track"))
                .track_number
            else if (std.mem.eql(u8, value, "duration"))
                .duration
            else if (std.mem.eql(u8, value, "added"))
                .date_added
            else
                return error.UnknownSortKey;
        } else return error.UnknownOption;
    }
    return options;
}

/// `mm:ss` from a duration liborca reports in milliseconds.
///
/// The cast to unsigned is not cosmetic: `{d:0>2}` on a signed integer emits a
/// sign, so a signed seconds value prints `4:+07`.
fn writeDuration(stdout: *std.Io.Writer, duration_ms: ?i64) !void {
    const milliseconds = duration_ms orelse {
        try stdout.writeAll("-:--");
        return;
    };
    const total_seconds: u64 = @intCast(@divTrunc(@max(milliseconds, 0), 1000));
    try stdout.print("{d}:{d:0>2}", .{ total_seconds / 60, total_seconds % 60 });
}

fn openBrowseLibrary(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *liborca.OrcaRuntime,
    database_path_argument: []const u8,
) !liborca.core.LibraryHandle {
    const database_path = try allocator.dupeSentinel(u8, database_path_argument, 0);
    return runtime.openLibrary(io, database_path);
}

fn listArtists(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    database_path_argument: []const u8,
    option_arguments: []const []const u8,
) !void {
    const options = try parseBrowseOptions(option_arguments);
    var runtime = liborca.OrcaRuntime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    var page = try runtime.libraryArtistPage(library, .{
        .filter = options.filter,
        .limit = options.limit,
        .offset = options.offset,
    });
    defer page.deinit();
    // The count of what matched, not of the library, or a filtered listing
    // reports a total it is not showing.
    const query: liborca.database.repository.ArtistQuery = .{ .filter = options.filter };
    try stdout.print(
        "{d} artists {s}\n",
        .{
            try runtime.libraryArtistCountMatching(library, query),
            if (options.filter.len == 0) "total" else "match",
        },
    );
    for (page.items) |artist| try stdout.print(
        "{d}\t{s}\t{d} releases\t{d} tracks\t[{s}]\n",
        .{ artist.id, artist.name, artist.release_count, artist.track_count, artist.sort_name },
    );
}

fn listReleases(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    database_path_argument: []const u8,
    option_arguments: []const []const u8,
) !void {
    const options = try parseBrowseOptions(option_arguments);
    var runtime = liborca.OrcaRuntime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    var page = try runtime.libraryReleasePage(library, .{
        .album_artist_id = options.artist_id,
        .limit = options.limit,
        .offset = options.offset,
    });
    defer page.deinit();
    for (page.items) |release| {
        try stdout.print("{d}\t{s}\t{s}\t", .{ release.id, release.title, release.album_artist });
        try writeDuration(stdout, release.total_duration_ms);
        try stdout.print(
            "\t{d} tracks\t{d} disc(s)\t{s}{s}\n",
            .{
                release.track_count,
                release.disc_count orelse 1,
                release.release_date orelse "-",
                if (release.is_compilation) "\tcompilation" else "",
            },
        );
    }
}

fn listTracks(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    database_path_argument: []const u8,
    option_arguments: []const []const u8,
) !void {
    const options = try parseBrowseOptions(option_arguments);
    var runtime = liborca.OrcaRuntime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const query: liborca.database.TrackQuery = .{
        .artist_id = options.artist_id,
        .release_id = options.release_id,
        .sort = options.sort,
        .direction = if (options.descending) .descending else .ascending,
        .limit = options.limit,
        .offset = options.offset,
    };
    var page = try runtime.libraryTrackQuery(library, "", query);
    defer page.deinit();
    try stdout.print(
        "{d} tracks match\n",
        .{try runtime.libraryTrackMatchCount(library, query)},
    );
    for (page.items) |track| {
        const disc: u64 = @intCast(@max(track.disc_number orelse 1, 0));
        const number: u64 = @intCast(@max(track.track_number orelse 0, 0));
        try stdout.print(
            "{d}\t{d}-{d:0>2}\t{s}\t{s}\t{s}\t",
            .{ track.id, disc, number, track.title, track.artist, track.album },
        );
        try writeDuration(stdout, track.duration_ms);
        try stdout.print("{s}\n", .{if (track.has_playable_file) "" else "\tunreachable"});
    }
}

fn sleepMilliseconds(milliseconds: u32) void {
    const duration: std.c.timespec = .{
        .sec = milliseconds / 1000,
        .nsec = @as(c_long, milliseconds % 1000) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&duration, null);
}

/// Drives the runtime pump until a job reaches a terminal state, exactly as a
/// frontend event loop would. Nothing about the scan happens on this thread.
fn awaitJob(
    runtime: *liborca.OrcaRuntime,
    stdout: *std.Io.Writer,
    job_handle: liborca.core.JobHandle,
    cancel_after_ms: ?u64,
) !void {
    var elapsed_ms: u64 = 0;
    var cancelled = false;
    while (true) {
        if (cancel_after_ms) |deadline| {
            if (!cancelled and elapsed_ms >= deadline) {
                cancelled = true;
                try runtime.cancelJob(job_handle);
                try stdout.print("cancellation requested at {d}ms\n", .{elapsed_ms});
                try stdout.flush();
            }
        }
        _ = runtime.processNextCommand();
        runtime.reapFinishedJobs();
        while (runtime.pollEvent()) |_| {}
        while (runtime.pollTelemetry()) |_| {}
        const snapshot = try runtime.jobSnapshotSynced(job_handle);
        switch (snapshot.state) {
            .succeeded => return,
            .failed => return error.JobFailed,
            .cancelled => {
                try stdout.print("cancelled after {d} files\n", .{snapshot.completed_units});
                return;
            },
            else => {},
        }
        sleepMilliseconds(20);
        elapsed_ms += 20;
    }
}

/// The same counters, named for what a library-wide analysis means by them.
fn printAnalysisStats(
    stdout: *std.Io.Writer,
    stats: liborca.core.runtime.ScanStats,
) !void {
    try stdout.print(
        "examined={d} measured={d} no_loudness={d} declined={d} corrupt={d} batches={d}\n",
        .{
            stats.files_seen,
            stats.changed,
            stats.unchanged,
            stats.unsupported,
            stats.errors,
            stats.batches_committed,
        },
    );
}

/// The same counters, named for what a repair pass means by them.
fn printBackfillStats(
    stdout: *std.Io.Writer,
    stats: liborca.core.runtime.ScanStats,
) !void {
    try stdout.print(
        "examined={d} repaired={d} still_unknown={d} unreachable={d} unreadable={d} batches={d}\n",
        .{
            stats.files_seen,
            stats.changed,
            stats.unchanged,
            stats.unsupported,
            stats.errors,
            stats.batches_committed,
        },
    );
    try stdout.print(
        "projected folders={d} files={d} tracks={d} releases={d}\n",
        .{
            stats.folders_visited,
            stats.files_projected,
            stats.tracks_written,
            stats.releases_written,
        },
    );
}

fn printScanStats(
    stdout: *std.Io.Writer,
    stats: liborca.core.runtime.ScanStats,
) !void {
    try stdout.print(
        "seen={d} changed={d} unchanged={d} unsupported={d} errors={d} batches={d}\n",
        .{
            stats.files_seen,
            stats.changed,
            stats.unchanged,
            stats.unsupported,
            stats.errors,
            stats.batches_committed,
        },
    );
    try stdout.print(
        "projected folders={d} files={d} tracks={d} releases={d}\n",
        .{
            stats.folders_visited,
            stats.files_projected,
            stats.tracks_written,
            stats.releases_written,
        },
    );
}
