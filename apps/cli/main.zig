const std = @import("std");
const liborca = @import("liborca");

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        var stderr_buffer: [256]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
        const stderr = &stderr_file_writer.interface;
        stderr.print("orca-cli: {s}\n", .{describe(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.TrackNotFound => "no track with that id",
        error.UnknownRoot => "no folder with that id",
        error.OpenFailed => "could not open the database",
        error.InvalidCharacter, error.Overflow => "expected a number",
        error.UnknownOption => "unknown option",
        error.LibraryJobRunning => "a job is running on this library",
        error.InvalidToken => "ListenBrainz does not accept the token in ORCA_LISTENBRAINZ_TOKEN",
        error.NeedsToken => "set ORCA_LISTENBRAINZ_TOKEN to a ListenBrainz user token",
        error.InvalidServerUrl => "ORCA_LISTENBRAINZ_URL must be https, or http to localhost",
        else => @errorName(err),
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (args.len > 1 and std.mem.eql(u8, args[1], "--version")) {
        try stdout.print("orca-cli {f}\n", .{liborca.version});
    } else if (args.len > 1 and std.mem.eql(u8, args[1], "demo")) {
        var runtime = liborca.Runtime.init(allocator);
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
        var runtime = liborca.Runtime.init(allocator);
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
        var runtime = liborca.Runtime.init(allocator);
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
        var runtime = liborca.Runtime.init(allocator);
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
        var runtime = liborca.Runtime.init(allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(init.io, database_path);
        var request: liborca.AnalysisRequest = .{};
        if (batch_size != 0) request.batch_size = batch_size;
        const job_handle = try runtime.startLibraryAnalysis(library_handle, request);
        const planned = try runtime.jobSnapshotSynced(job_handle);
        try stdout.print("{d} files to analyze\n", .{planned.total_units orelse 0});
        try stdout.flush();
        try awaitJob(&runtime, stdout, job_handle, cancel_after_ms);
        try printAnalysisStats(stdout, try runtime.jobScanStats(job_handle));
        try stdout.print("{d} files still to analyze\n", .{
            try runtime.libraryUnanalyzedCount(library_handle),
        });
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "duplicates")) {
        // The question the analysis exists to answer, asked over the stored
        // measurements rather than over the files. It opens nothing, so a run
        // is seconds where the analysis behind it is hours.
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
        // Not the process arena every other subcommand uses. This job's work
        // is a long sequence of short-lived allocations -- a fingerprint per
        // comparison, freed as soon as it has been compared -- and an arena
        // never returns them, so the pass's bound of two resident fingerprints
        // would become one per comparison: about 9 KB times 14,593 on the
        // reference library today, and unbounded at the 500,000-file target.
        // The pass frees correctly; it needs an allocator that honours it.
        var runtime = liborca.Runtime.init(std.heap.smp_allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(init.io, database_path);
        var request: liborca.DuplicateScanRequest = .{};
        if (batch_size != 0) request.batch_size = batch_size;
        const job_handle = try runtime.startLibraryDuplicateScan(library_handle, request);
        const planned = try runtime.jobSnapshotSynced(job_handle);
        try stdout.print("{d} files to examine\n", .{planned.total_units orelse 0});
        try stdout.flush();
        try awaitJob(&runtime, stdout, job_handle, cancel_after_ms);
        try printDuplicateStats(stdout, try runtime.jobScanStats(job_handle));
    } else if (args.len == 4 and std.mem.eql(u8, args[1], "analyze")) {
        const database_path = try allocator.dupeSentinel(u8, args[2], 0);
        var runtime = liborca.Runtime.init(allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(init.io, database_path);
        const result = try runtime.libraryAnalyzeFile(library_handle, init.io, args[3]);
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
        var runtime = liborca.Runtime.init(allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(init.io, database_path);
        var page = try runtime.libraryHealthIssuePage(library_handle, 256, offset);
        defer page.deinit();
        for (page.items) |issue| try stdout.print(
            "{s}\t{s}\t{s}\t{s}\n",
            .{ @tagName(issue.severity), @tagName(issue.kind), issue.path, issue.details },
        );
    } else if (args.len == 3 and std.mem.eql(u8, args[1], "roots")) {
        var runtime = liborca.Runtime.init(allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(init.io, try allocator.dupeSentinel(u8, args[2], 0));
        var page = try runtime.libraryRootPage(library_handle, 512, 0);
        defer page.deinit();
        for (page.items) |root| try stdout.print(
            "{d}\t{s}\t{s}\n",
            .{ root.id, if (root.enabled) "enabled" else "disabled", root.path },
        );
    } else if (args.len == 4 and std.mem.eql(u8, args[1], "remove-root")) {
        var runtime = liborca.Runtime.init(allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(init.io, try allocator.dupeSentinel(u8, args[2], 0));
        const root_id = try std.fmt.parseInt(i64, args[3], 10);
        const removed = try runtime.libraryRemoveRoot(library_handle, root_id);
        try stdout.print(
            "removed root {d}: {d} files, {d} tracks\n",
            .{ root_id, removed.files_forgotten, removed.tracks_removed },
        );
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "artists")) {
        try listArtists(allocator, init.io, stdout, args[2], args[3..]);
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "releases")) {
        try listReleases(allocator, init.io, stdout, args[2], args[3..]);
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "tracks")) {
        try listTracks(allocator, init.io, stdout, args[2], args[3..]);
    } else if (args.len >= 4 and std.mem.eql(u8, args[1], "edit")) {
        try editTracks(allocator, init.io, stdout, args[2], args[3], args[4..]);
    } else if ((args.len == 4 or args.len == 5) and std.mem.eql(u8, args[1], "write-tags")) {
        try writeTags(allocator, init.io, stdout, args[2], args[3], args[4..]);
    } else if (args.len == 4 and std.mem.eql(u8, args[1], "undo-tags")) {
        var runtime = liborca.Runtime.init(allocator);
        defer runtime.deinit();
        const library = try runtime.openLibrary(init.io, try allocator.dupeSentinel(u8, args[2], 0));
        const group = try std.fmt.parseInt(u64, args[3], 10);
        try runtime.undoTagWrite(library, init.io, group);
        try stdout.print("undid group {d}\n", .{group});
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "covers")) {
        try loadCovers(allocator, init.io, stdout, args[2], args[3..]);
    } else if (args.len == 4 and std.mem.eql(u8, args[1], "track")) {
        try showTrack(allocator, init.io, stdout, args[2], args[3]);
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "artwork")) {
        try showArtwork(allocator, init.io, stdout, args[2], args[3..]);
    } else if (args.len == 2 and std.mem.eql(u8, args[1], "devices")) {
        var runtime = liborca.Runtime.init(allocator);
        defer runtime.deinit();
        var devices: [32]liborca.Device = undefined;
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
        var runtime = liborca.Runtime.init(allocator);
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
    } else if (args.len == 5 and std.mem.eql(u8, args[1], "feedback")) {
        try setFeedback(allocator, init.io, stdout, args[2], args[3], args[4]);
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "scrobble")) {
        try scrobble(allocator, init.io, init.environ_map, stdout, args[2], args[3..]);
    } else {
        try stdout.writeAll(
            \\Usage: orca-cli [--version | demo | scan DATABASE ROOT | project DATABASE
            \\                 | backfill DATABASE [--force] [--cancel-after=MS]
            \\                 | analyze DATABASE AUDIO
            \\                 | analyze-library DATABASE [--batch=N] [--cancel-after=MS]
            \\                 | duplicates DATABASE [--batch=N] [--cancel-after=MS]
            \\                 | roots DATABASE | remove-root DATABASE ID
            \\                 | health DATABASE [OFFSET] | devices | play AUDIO [DEVICE_ID]
            \\                 | play-tracks DATABASE IDS [OPTIONS]
            \\                 | scrobble DATABASE [--status] [--timeout=MS]
            \\                 | feedback DATABASE IDS (--love | --hate | --clear)
            \\                 | artists DATABASE [OPTIONS]
            \\                 | releases DATABASE [--artist ID] [OPTIONS]
            \\                 | tracks DATABASE [OPTIONS]
            \\                 | track DATABASE ID
            \\                 | artwork DATABASE (--track=ID | --release=ID) [--out=PATH]
            \\                 | covers DATABASE [--limit N] [--offset N]
            \\                 | edit DATABASE IDS [EDITS]
            \\                 | write-tags DATABASE IDS [--approve=DIGEST]
            \\                 | undo-tags DATABASE GROUP]
            \\
            \\roots lists the registered folders. remove-root forgets one and every
            \\file, Track, Release and Artist that exists only under it; a file also
            \\located under another root stays. Files on disk are not touched.
            \\
            \\edit sets Orca's own values for a comma-separated list of Track ids;
            \\the files are not written. With no edits it lists the values held.
            \\  --title= --artist= --album= --album-artist= --date=
            \\  --track=N --disc=N --compilation=0|1
            \\  --clear=FIELD      drop Orca's value so the file's tag applies again
            \\                     (title|artist|album|album_artist|track_number|
            \\                      disc_number|date|compilation)
            \\
            \\write-tags writes Orca's values for the Tracks into their files. Without
            \\--approve it prints the plan and its digest and writes nothing; run it
            \\again with --approve=DIGEST to write exactly that plan. A digest from a
            \\plan that no longer matches the library is refused. It prints the group
            \\to pass to undo-tags, which restores the files' previous bytes.
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
            \\track prints what the Library recorded about one Track and its file: tags,
            \\format, size, path, stored loudness and whether the file carries a cover.
            \\It opens no file.
            \\
            \\play-tracks plays a comma-separated list of Track ids as a playback
            \\queue. Options:
            \\  --device=ID        output device (0 = server default)
            \\  --replay-gain=off|track   loudness correction per entry (default track)
            \\  --eq=PRESET        equalizer preset: flat|bass|treble|vocal|loudness
            \\  --eq=G1,...,G10[:PREAMP]   ten band gains in dB (31 Hz to 16 kHz, each
            \\                     within 12) and a preamp in dB (default: minus the
            \\                     largest boost)
            \\  --crossfeed=AMOUNT stereo crossfeed for headphones, 0 to 1
            \\  --start=N          queue position to begin at
            \\  --repeat=off|all|one
            \\  --shuffle
            \\  --tail=MS          on each new entry, seek to MS before its end
            \\  --skip-after=MS    issue next MS after each entry becomes audible
            \\  --previous-after=MS  issue previous once, MS after playback starts
            \\  --limit=MS         stop after MS of wall clock
            \\
            \\play-tracks prints one `signal:` line once playback is a second in: the
            \\source, each stage that changes the samples, the output stream, and
            \\whether the path could be bit-perfect. It records listens in the
            \\Library's play history and never sends them anywhere.
            \\
            \\scrobble sends the listens and the love/hate changes queued for
            \\ListenBrainz. The token comes from ORCA_LISTENBRAINZ_TOKEN;
            \\ORCA_LISTENBRAINZ_URL selects another server (https, or http to
            \\localhost only). It works until both queues are empty, the scrobbler
            \\needs attention, or --timeout=MS passes (default 120000), prints one
            \\`scrobble:` line, and exits non-zero when the token is missing or
            \\rejected. --status prints the queue counts and makes no request.
            \\Listens are queued only while scrobbling is enabled, which the GTK
            \\app's preferences do; play-tracks never enables it.
            \\
            \\feedback loves, dislikes or clears the Tracks' recordings, and prints how
            \\many Tracks changed and how many were skipped. It is kept in the Library;
            \\scrobble sends it for recordings with a MusicBrainz ID.
            \\
            \\analyze-library decodes every file the Library has not measured yet and
            \\stores its loudness, peak, clipping, silence and fingerprint. That
            \\measurement is what ReplayGain on playback reads; without it every track
            \\plays at unity. It decodes whole files, so it is slow, and it is meant to
            \\be stopped and restarted: --cancel-after=MS interrupts it inside a file,
            \\the batch already measured is still committed, and the next run selects
            \\only what is left.
            \\
            \\duplicates reports every file whose audio the Library also holds
            \\somewhere else, as health issues that `health` then lists. It compares
            \\what analyze-library measured -- it opens no files -- so it is fast, and
            \\it is only as complete as that analysis: the uncomparable count is how
            \\many files it could say nothing about, and a zero-finding run over a
            \\library with a large uncomparable count means "not measured", not "no
            \\duplicates".
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
    replay_gain: liborca.ReplayGainMode = .track,
    equalizer: ?liborca.Equalizer = null,
    crossfeed: ?f32 = null,
    start: u32 = 0,
    repeat: liborca.RepeatMode = .off,
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
    } else if (std.mem.eql(u8, name, "--eq")) {
        options.equalizer = try parseEqualizer(value);
    } else if (std.mem.eql(u8, name, "--crossfeed")) {
        options.crossfeed = try std.fmt.parseFloat(f32, value);
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

/// A preset name, or ten comma-separated band gains in dB with an optional
/// `:PREAMP`. The preamp defaults to what the largest boost needs, so a bare
/// list of gains cannot clip on its own.
fn parseEqualizer(value: []const u8) !liborca.Equalizer {
    if (std.meta.stringToEnum(liborca.EqualizerPreset, value)) |preset|
        return .preset(preset);
    var equalizer: liborca.Equalizer = .{};
    const preamp_separator = std.mem.indexOfScalar(u8, value, ':');
    const gain_list = value[0 .. preamp_separator orelse value.len];
    var gains = std.mem.splitScalar(u8, gain_list, ',');
    for (&equalizer.gains_db) |*gain_db| {
        const text = gains.next() orelse return error.EqualizerNeedsTenGains;
        gain_db.* = try std.fmt.parseFloat(f32, text);
    }
    if (gains.next() != null) return error.EqualizerNeedsTenGains;
    equalizer.preamp_db = if (preamp_separator) |separator|
        try std.fmt.parseFloat(f32, value[separator + 1 ..])
    else
        liborca.Equalizer.defaultPreamp(equalizer.gains_db);
    return equalizer;
}

fn printSignalPath(stdout: *std.Io.Writer, path: liborca.SignalPath) !void {
    try stdout.writeAll("signal: ");
    if (path.source) |source| {
        if (path.codec) |codec| {
            var upper: [16]u8 = undefined;
            const name = if (codec.len <= upper.len) std.ascii.upperString(&upper, codec) else codec;
            try stdout.print("{s} ", .{name});
        }
        try stdout.print(
            "{d}-bit {d} Hz {d} ch",
            .{ source.bits_per_sample, source.sample_rate, source.channels },
        );
    } else try stdout.writeAll("no source");
    if (path.replay_gain_db) |decibels| try stdout.print(" -> replay gain {d:.1} dB", .{decibels});
    if (path.equalizer != null) try stdout.writeAll(" -> eq");
    if (path.crossfeed) |amount| try stdout.print(" -> crossfeed {d:.2}", .{amount});
    try stdout.print(" -> volume {d:.2}", .{path.volume});
    if (path.output) |output| {
        try stdout.print(
            " -> output {s} {d} Hz {d} ch",
            .{ formatName(output.sample_format), output.sample_rate, output.channels },
        );
        if (path.device_rate) |device_rate| {
            try stdout.print(" -> device {d} Hz", .{device_rate});
            if (device_rate != output.sample_rate) try stdout.writeAll(" (PipeWire resamples)");
        }
    } else try stdout.writeAll(" -> no output");
    try stdout.print("; bit-perfect: {s}", .{if (path.bit_perfect_eligible) "yes" else "no"});
    for (path.reasonList(), 0..) |reason, index| {
        try stdout.writeAll(if (index == 0) " (" else ", ");
        for (@tagName(reason)) |character|
            try stdout.writeByte(if (character == '_') ' ' else character);
    }
    if (path.reasonList().len > 0) try stdout.writeByte(')');
    try stdout.writeByte('\n');
}

fn formatName(sample_format: liborca.SampleFormat) []const u8 {
    return switch (sample_format) {
        .unsigned_8 => "uint8",
        .signed_16 => "int16",
        .signed_24 => "int24",
        .signed_32 => "int32",
        .float_32 => "float32",
        .float_64 => "float64",
    };
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

    var ids = try parseTrackIds(allocator, id_list);
    defer ids.deinit(allocator);

    const database_path = try allocator.dupeSentinel(u8, database_path_argument, 0);
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(io, database_path);
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.zoneRequestOutput(zone, options.device);

    try runtime.playerSetVolume(player, options.volume);
    try runtime.playerSetReplayGainMode(player, options.replay_gain);
    try runtime.playerSetEqualizer(player, options.equalizer);
    try runtime.playerSetCrossfeed(player, options.crossfeed);
    try runtime.playerSetRepeat(player, options.repeat);
    if (options.shuffle) try runtime.playerSetShuffle(player, true);
    try runtime.playerPlayTracks(player, library, io, ids.items, options.start);

    var elapsed_ms: u64 = 0;
    var entry_elapsed_ms: u64 = 0;
    var last_cursor: ?u32 = null;
    var took_previous = options.previous_after_ms == null;
    var set_volume = options.set_volume == null;
    var printed_signal_path = false;
    // How often the producer was observed a whole entry ahead of the audio.
    // Nonzero is the proof that now-playing is derived from rendered audio
    // rather than from the decode cursor.
    var decode_lead_polls: u64 = 0;
    while (elapsed_ms < options.limit_ms) {
        _ = runtime.processNextCommand();
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
        if (!printed_signal_path and elapsed_ms >= 1000) {
            const path = try runtime.playerSignalPath(player);
            if (path.output != null) {
                printed_signal_path = true;
                try printSignalPath(stdout, path);
                try stdout.flush();
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
    sort: liborca.TrackSort = .id,
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
    runtime: *liborca.Runtime,
    database_path_argument: []const u8,
) !liborca.LibraryHandle {
    const database_path = try allocator.dupeSentinel(u8, database_path_argument, 0);
    return runtime.openLibrary(io, database_path);
}

fn parseTrackIds(allocator: std.mem.Allocator, id_list: []const u8) !std.ArrayList(i64) {
    var ids: std.ArrayList(i64) = .empty;
    errdefer ids.deinit(allocator);
    var walk = std.mem.splitScalar(u8, id_list, ',');
    while (walk.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " ");
        if (trimmed.len == 0) continue;
        try ids.append(allocator, try std.fmt.parseInt(i64, trimmed, 10));
    }
    if (ids.items.len == 0) return error.NoTrackIds;
    return ids;
}

const edit_options = [_]struct { flag: []const u8, field: liborca.MetadataField }{
    .{ .flag = "--title", .field = .title },
    .{ .flag = "--artist", .field = .artist },
    .{ .flag = "--album", .field = .album },
    .{ .flag = "--album-artist", .field = .album_artist },
    .{ .flag = "--track", .field = .track_number },
    .{ .flag = "--disc", .field = .disc_number },
    .{ .flag = "--date", .field = .date },
    .{ .flag = "--compilation", .field = .compilation },
};

/// Library-only edits: Orca's own values, never written to the files.
fn editTracks(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    database_path_argument: []const u8,
    id_list: []const u8,
    option_arguments: []const []const u8,
) !void {
    var ids = try parseTrackIds(allocator, id_list);
    defer ids.deinit(allocator);
    var edits: std.ArrayList(liborca.TrackEdit) = .empty;
    defer edits.deinit(allocator);
    for (option_arguments) |argument| {
        const split = std.mem.indexOfScalar(u8, argument, '=') orelse return error.UnknownOption;
        const name = argument[0..split];
        const value = argument[split + 1 ..];
        if (std.mem.eql(u8, name, "--clear")) {
            const field = std.meta.stringToEnum(liborca.MetadataField, value) orelse
                return error.UnknownField;
            try edits.append(allocator, .{ .field = field, .value = null });
            continue;
        }
        for (edit_options) |option| {
            if (std.mem.eql(u8, name, option.flag)) {
                try edits.append(allocator, .{ .field = option.field, .value = value });
                break;
            }
        } else return error.UnknownOption;
    }

    const database_path = try allocator.dupeSentinel(u8, database_path_argument, 0);
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(io, database_path);
    if (edits.items.len > 0) {
        const edited = try runtime.libraryEditTracks(library, ids.items, edits.items);
        defer edited.deinit();
        try stdout.print("edited {d} tracks, now", .{ids.items.len});
        for (edited.ids, 0..) |id, index| try stdout.print("{s}{d}", .{ if (index == 0) " " else ",", id });
        try stdout.writeAll("\n");
        return;
    }
    for (ids.items) |track_id| {
        var page = try runtime.libraryTrackEdits(library, track_id);
        defer page.deinit();
        for (page.items) |value| try stdout.print(
            "{d}\t{t}\t{s}\t{t}{s}\n",
            .{ track_id, value.field, value.text, value.provenance, if (value.locked) "\tlocked" else "" },
        );
    }
}

/// Tag write-back through the runtime's plan, approve and undo path.
fn writeTags(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    database_path_argument: []const u8,
    id_list: []const u8,
    option_arguments: []const []const u8,
) !void {
    var ids = try parseTrackIds(allocator, id_list);
    defer ids.deinit(allocator);
    var approved: ?liborca.TagWriteDigest = null;
    for (option_arguments) |argument| {
        if (!std.mem.startsWith(u8, argument, "--approve=")) return error.UnknownOption;
        var digest: liborca.TagWriteDigest = undefined;
        const hex = argument["--approve=".len..];
        if (hex.len != digest.len * 2) return error.InvalidDigest;
        _ = std.fmt.hexToBytes(&digest, hex) catch return error.InvalidDigest;
        approved = digest;
    }

    const database_path = try allocator.dupeSentinel(u8, database_path_argument, 0);
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try runtime.openLibrary(io, database_path);
    const plan = try runtime.planTagWrite(library, io, ids.items);
    defer plan.deinit();
    for (plan.skipped) |skip| try stdout.print("skip\t{d}\t{t}\t{s}\n", .{ skip.file_id, skip.reason, skip.path });
    for (plan.files) |file| {
        try stdout.print("file\t{d}\t{s}\n", .{ file.file_id, file.path });
        for (file.changes) |change| try stdout.print(
            "\t{t}\t{s} -> {s}\n",
            .{ change.field, change.before orelse "(none)", change.after orelse "(none)" },
        );
    }
    if (plan.files.len == 0) {
        try stdout.print("nothing to write\n", .{});
        return;
    }
    const digest = approved orelse {
        try stdout.print("digest {x}\n", .{&plan.digest});
        return;
    };
    const job_handle = try runtime.startTagWrite(library, plan.plan_id, digest);
    try awaitJob(&runtime, stdout, job_handle, null);
    const stats = try runtime.jobScanStats(job_handle);
    try stdout.print("wrote {d} files as group {d}\n", .{ stats.changed, plan.plan_id });
}

/// `orca-cli track DATABASE ID`: the details view's query, printed.
fn showTrack(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    database_path_argument: []const u8,
    id_argument: []const u8,
) !void {
    const track_id = try std.fmt.parseInt(i64, id_argument, 10);
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const details = (try runtime.libraryTrackDetails(library, track_id)) orelse
        return error.TrackNotFound;
    defer details.deinit();

    try printDetail(stdout, "title", "{s}", .{details.title});
    try printDetail(stdout, "artist", "{s}", .{details.artist});
    try printDetail(stdout, "album", "{s}", .{details.album});
    try printDetail(stdout, "album artist", "{s}", .{details.album_artist});
    try printOptionalDetail(stdout, "date", "{s}", details.date);
    try printOptionalDetail(stdout, "track", "{d}", details.track_number);
    try printOptionalDetail(stdout, "disc", "{d}", details.disc_number);
    try printDetail(stdout, "codec", "{s}", .{if (details.codec.len == 0) "-" else details.codec});
    try printOptionalDetail(stdout, "sample rate", "{d} Hz", details.sample_rate);
    if (!details.lossy) try printOptionalDetail(stdout, "bit depth", "{d}-bit", details.bit_depth);
    try printOptionalDetail(stdout, "channels", "{d}", details.channels);
    try printOptionalDetail(stdout, "bitrate", "{d} kbps", details.bitrate_kbps);
    try writeDetailKey(stdout, "duration");
    try writeDuration(stdout, details.duration_ms);
    try stdout.writeAll("\n");
    try printOptionalDetail(stdout, "size", "{d} bytes", details.size_bytes);
    if (details.path) |path| {
        try printDetail(stdout, "path", "{s}", .{path});
    } else try printDetail(stdout, "path", "{s}", .{"(file missing)"});
    if (details.loudness) |loudness| {
        try printDetail(
            stdout,
            "loudness",
            "{d:.1} LUFS, peak {d:.1} dBFS, ReplayGain {d:.1} dB",
            .{ loudness.integrated_lufs, 20 * @log10(loudness.sample_peak), loudness.replay_gain_db },
        );
    } else try printDetail(stdout, "loudness", "{s}", .{"not measured"});
    try printDetail(stdout, "artwork", "{s}", .{if (details.has_artwork) "yes" else "no"});
    try printDetail(stdout, "feedback", "{s}", .{switch (details.feedback) {
        .none => "none",
        .loved => "loved",
        .hated => "hated",
    }});
    try stdout.print("feedback sync: {s}\n", .{
        if (details.feedback_syncable) "yes" else "no (no MusicBrainz recording ID)",
    });
    try printDetail(stdout, "plays", "{d}", .{details.play_count});
    try writeDetailKey(stdout, "last played");
    if (details.last_played_at) |seconds| {
        try writeIsoUtc(stdout, seconds);
    } else try stdout.writeAll("never");
    try stdout.writeAll("\n");
}

fn writeIsoUtc(stdout: *std.Io.Writer, unix_seconds: i64) !void {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(unix_seconds, 0)) };
    const month_day = epoch.getEpochDay().calculateYearDay().calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    try stdout.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        epoch.getEpochDay().calculateYearDay().year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

/// The user token from the process environment, read once at startup because
/// the environment map is not safe to read from the listen worker's thread.
const EnvironmentToken = struct {
    token: ?[]u8,

    fn init(allocator: std.mem.Allocator, environ: *std.process.Environ.Map) !EnvironmentToken {
        const value = environ.get("ORCA_LISTENBRAINZ_TOKEN") orelse return .{ .token = null };
        if (value.len == 0) return .{ .token = null };
        return .{ .token = try allocator.dupe(u8, value) };
    }

    fn deinit(self: *EnvironmentToken, allocator: std.mem.Allocator) void {
        if (self.token) |token| {
            std.crypto.secureZero(u8, token);
            allocator.free(token);
        }
        self.* = undefined;
    }

    fn store(self: *EnvironmentToken) liborca.CredentialStore {
        return .{ .context = self, .get_fn = get };
    }

    fn get(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!?[]u8 {
        const self: *EnvironmentToken = @ptrCast(@alignCast(context));
        const token = self.token orelse return null;
        return try allocator.dupe(u8, token);
    }
};

const ScrobbleOptions = struct {
    status_only: bool = false,
    timeout_ms: u64 = 120_000,
};

fn parseScrobbleOptions(arguments: []const []const u8) !ScrobbleOptions {
    var options: ScrobbleOptions = .{};
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, "--status")) {
            options.status_only = true;
        } else if (std.mem.startsWith(u8, argument, "--timeout=")) {
            options.timeout_ms = try std.fmt.parseInt(u64, argument["--timeout=".len..], 10);
        } else return error.UnknownOption;
    }
    return options;
}

fn printScrobbleLine(
    stdout: *std.Io.Writer,
    state: liborca.ScrobblerState,
    delivered: u64,
    pending: u64,
    feedback_pending: u64,
    user_name: []const u8,
    last_error: []const u8,
) !void {
    try stdout.print(
        "scrobble: state={s} delivered={d} pending={d} feedback_pending={d}",
        .{ @tagName(state), delivered, pending, feedback_pending },
    );
    if (user_name.len != 0) try stdout.print(" user={s}", .{user_name});
    try stdout.print(" last_error={s}\n", .{if (last_error.len == 0) "-" else last_error});
}

fn awaitScrobblerState(
    runtime: *liborca.Runtime,
    library: liborca.LibraryHandle,
    deadline_ms: u64,
    elapsed_ms: *u64,
    settled: *const fn (liborca.ScrobblerStatus) bool,
) !liborca.ScrobblerStatus {
    while (true) {
        _ = runtime.processNextCommand();
        const status = try runtime.libraryScrobblerStatus(library);
        if (settled(status) or elapsed_ms.* >= deadline_ms) return status;
        sleepMilliseconds(20);
        elapsed_ms.* += 20;
    }
}

fn isOffline(status: liborca.ScrobblerStatus) bool {
    return status.state == .offline;
}

fn hasLeftOffline(status: liborca.ScrobblerStatus) bool {
    return status.state != .offline;
}

fn needsAttention(status: liborca.ScrobblerStatus) bool {
    return switch (status.state) {
        .needs_token, .invalid_token, .rate_limited, .backing_off => true,
        .idle => status.pending == 0 and status.feedback_pending == 0,
        .disabled, .offline, .validating, .submitting => false,
    };
}

/// With nothing queued it makes no request and looks up no token, and the
/// token is never validated up front: a bad one shows as a refused delivery.
/// The worker publishes its status only at the end of a pass, and an
/// unpublished status reads as an empty idle queue. The worker therefore
/// starts offline, where its first pass makes no request and reports the
/// queue; going online afterwards leaves `offline` only when a pass with
/// requests allowed has finished. `--status` starts no worker: it reports the
/// queue as the database holds it.
fn scrobble(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    stdout: *std.Io.Writer,
    database_path_argument: []const u8,
    option_arguments: []const []const u8,
) !void {
    const options = try parseScrobbleOptions(option_arguments);
    var credentials: EnvironmentToken = try .init(allocator, environ);
    defer credentials.deinit(allocator);

    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    try runtime.setCredentialStore(credentials.store());
    if (environ.get("ORCA_LISTENBRAINZ_URL")) |url| {
        if (url.len > 0) try runtime.setListenBrainzServer(try allocator.dupe(u8, url));
    }
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);

    if (options.status_only) {
        const stored = try runtime.libraryScrobblerStatus(library);
        try stdout.print(
            "scrobble: status state={s} pending={d} feedback_pending={d} delivered={d} token={s}\n",
            .{
                @tagName(stored.state),
                stored.pending,
                stored.feedback_pending,
                stored.delivered_total,
                if (credentials.token != null) "set" else "unset",
            },
        );
        return;
    }

    const waiting = try runtime.libraryScrobblerStatus(library);
    if (waiting.pending == 0 and waiting.feedback_pending == 0) {
        try printScrobbleLine(stdout, .idle, 0, 0, 0, "", "");
        return;
    }

    var elapsed_ms: u64 = 0;
    try runtime.librarySetScrobbling(library, true, true, false);
    const queued = try awaitScrobblerState(&runtime, library, 5_000, &elapsed_ms, isOffline);

    elapsed_ms = 0;
    try runtime.librarySetScrobbling(library, true, false, false);
    _ = try awaitScrobblerState(&runtime, library, options.timeout_ms, &elapsed_ms, hasLeftOffline);
    const status = try awaitScrobblerState(&runtime, library, options.timeout_ms, &elapsed_ms, needsAttention);
    try printScrobbleLine(
        stdout,
        status.state,
        status.delivered_total -| queued.delivered_total,
        status.pending,
        status.feedback_pending,
        status.user_name.slice(),
        status.last_error.slice(),
    );
    try stdout.flush();
    switch (status.state) {
        .invalid_token => return error.InvalidToken,
        .needs_token => return error.NeedsToken,
        else => {},
    }
}

fn setFeedback(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    database_path_argument: []const u8,
    id_list: []const u8,
    option_argument: []const u8,
) !void {
    const feedback: liborca.Feedback = if (std.mem.eql(u8, option_argument, "--love"))
        .loved
    else if (std.mem.eql(u8, option_argument, "--hate"))
        .hated
    else if (std.mem.eql(u8, option_argument, "--clear"))
        .none
    else
        return error.UnknownOption;
    var ids = try parseTrackIds(allocator, id_list);
    defer ids.deinit(allocator);
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const change = try runtime.librarySetFeedback(library, ids.items, feedback);
    try stdout.print("feedback: updated={d} skipped={d}\n", .{ change.updated, change.skipped });
}

fn writeDetailKey(stdout: *std.Io.Writer, comptime key: []const u8) !void {
    try stdout.print("{s: <14}", .{key ++ ":"});
}

fn printDetail(
    stdout: *std.Io.Writer,
    comptime key: []const u8,
    comptime format: []const u8,
    arguments: anytype,
) !void {
    try writeDetailKey(stdout, key);
    try stdout.print(format ++ "\n", arguments);
}

fn printOptionalDetail(
    stdout: *std.Io.Writer,
    comptime key: []const u8,
    comptime format: []const u8,
    value: anytype,
) !void {
    if (value) |present| return printDetail(stdout, key, format, .{present});
    return printDetail(stdout, key, "{s}", .{"-"});
}

/// `orca-cli artwork DATABASE (--track ID | --release ID) [--out PATH]`.
///
/// The reachability check for embedded cover art: it goes through the same
/// `OrcaRuntime` entry points the GTK frontend calls, so a cover that cannot
/// be produced here cannot be produced anywhere. `--out` writes the exact bytes
/// so they can be compared against what an independent tool extracts.
fn showArtwork(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    database_path_argument: []const u8,
    option_arguments: []const []const u8,
) !void {
    var track_id: ?i64 = null;
    var release_id: ?i64 = null;
    var out_path: ?[]const u8 = null;
    var index: usize = 0;
    while (index < option_arguments.len) : (index += 1) {
        const argument = option_arguments[index];
        if (std.mem.startsWith(u8, argument, "--track=")) {
            track_id = try std.fmt.parseInt(i64, argument["--track=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--release=")) {
            release_id = try std.fmt.parseInt(i64, argument["--release=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--out=")) {
            out_path = argument["--out=".len..];
        } else return error.UnknownOption;
    }
    // One subject per call. Asking for both would make "which id did this
    // image come from" unanswerable from the output.
    if ((track_id == null) == (release_id == null)) return error.MissingSubject;

    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const image = if (track_id) |id|
        try runtime.libraryTrackArtwork(library, io, id)
    else
        try runtime.libraryReleaseArtwork(library, io, release_id.?);
    const present = image orelse {
        try stdout.print("no artwork\n", .{});
        return;
    };
    defer present.deinit();
    try stdout.print("{s}\t{d} bytes\t{s}\n", .{
        present.mime_type,
        present.bytes.len,
        @tagName(present.kind),
    });
    if (out_path) |path| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = present.bytes });
        try stdout.print("wrote {s}\n", .{path});
    }
}

fn listArtists(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    database_path_argument: []const u8,
    option_arguments: []const []const u8,
) !void {
    const options = try parseBrowseOptions(option_arguments);
    var runtime = liborca.Runtime.init(allocator);
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
    const query: liborca.ArtistQuery = .{ .filter = options.filter };
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

/// `orca-cli covers DATABASE [--limit N] [--offset N]`: a page of Releases'
/// covers, read on the runtime's artwork loader the way a GUI grid asks for
/// them, with how long the whole page took.
fn loadCovers(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    database_path_argument: []const u8,
    option_arguments: []const []const u8,
) !void {
    const options = try parseBrowseOptions(option_arguments);
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    var page = try runtime.libraryReleasePage(library, .{
        .limit = @min(options.limit, 64),
        .offset = options.offset,
    });
    defer page.deinit();
    const started = std.Io.Clock.awake.now(io);
    for (page.items) |release|
        _ = try runtime.libraryRequestArtwork(library, io, .{ .release = release.id });
    var remaining = page.items.len;
    var covered: usize = 0;
    var bytes: usize = 0;
    while (remaining != 0) {
        const result = runtime.libraryTakeArtwork(library) orelse {
            sleepMilliseconds(1);
            continue;
        };
        remaining -= 1;
        const image = result.image orelse {
            try stdout.print("{d}\tno cover\n", .{result.subject.release});
            continue;
        };
        defer image.deinit();
        covered += 1;
        bytes += image.bytes.len;
        try stdout.print("{d}\t{s}\t{d} bytes\n", .{ result.subject.release, image.mime_type, image.bytes.len });
    }
    const elapsed = started.durationTo(std.Io.Clock.awake.now(io));
    try stdout.print("{d} of {d} releases have covers, {d} bytes, in {d} ms\n", .{
        covered,
        page.items.len,
        bytes,
        @divTrunc(elapsed.nanoseconds, std.time.ns_per_ms),
    });
}

fn listReleases(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    database_path_argument: []const u8,
    option_arguments: []const []const u8,
) !void {
    const options = try parseBrowseOptions(option_arguments);
    var runtime = liborca.Runtime.init(allocator);
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
    var runtime = liborca.Runtime.init(allocator);
    defer runtime.deinit();
    const library = try openBrowseLibrary(allocator, io, &runtime, database_path_argument);
    const query: liborca.TrackQuery = .{
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
    runtime: *liborca.Runtime,
    stdout: *std.Io.Writer,
    job_handle: liborca.JobHandle,
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
    stats: liborca.ScanStats,
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

/// The same counters, named for what a duplicate scan means by them.
///
/// `uncomparable` is printed on its own line rather than beside the rest,
/// because it is the number that decides whether the finding counts mean
/// anything: nothing can be said about a file no analysis has measured, and a
/// report of "no duplicates" over a library full of them would be a lie of
/// omission.
fn printDuplicateStats(
    stdout: *std.Io.Writer,
    stats: liborca.ScanStats,
) !void {
    try stdout.print(
        "examined={d} exact={d} likely={d} unique={d} unreadable={d} batches={d}\n",
        .{
            stats.files_seen,
            stats.tracks_written,
            stats.releases_written,
            stats.unchanged,
            stats.errors,
            stats.batches_committed,
        },
    );
    try stdout.print(
        "uncomparable={d} comparisons={d} truncated_buckets={d}\n",
        .{ stats.unsupported, stats.files_projected, stats.folders_visited },
    );
}

/// The same counters, named for what a repair pass means by them.
fn printBackfillStats(
    stdout: *std.Io.Writer,
    stats: liborca.ScanStats,
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
    stats: liborca.ScanStats,
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
