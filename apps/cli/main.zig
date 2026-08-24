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
        const database_path = try allocator.dupeSentinel(u8, args[2], 0);
        var runtime = liborca.OrcaRuntime.init(allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(init.io, database_path);
        const library_database = try runtime.libraryDatabase(library_handle);
        // Adding a root is an explicit user action, so this is the one place
        // allowed to write a volume identifier to a mount root that has no
        // filesystem UUID of its own.
        const binding = try library_database.ensureRoot(init.io, args[3], .{
            .allow_persist = true,
        });
        if (binding.claimed_locations != 0) try stdout.print(
            "claimed {d} migrated locations for volume {d}\n",
            .{ binding.claimed_locations, binding.volume_id },
        );
        const run = try library_database.scan_runs.begin(binding.root_id);
        var scanner = liborca.library.Scanner{
            .allocator = allocator,
            .io = init.io,
            .files = &library_database.files,
            .locations = &library_database.locations,
            .observed_tags = &library_database.observed_tags,
            .write_lane = library_database.write_lane,
            .database_handle = library_database.database,
            .volume_id = binding.volume_id,
            .root_id = binding.root_id,
            .generation = run.generation,
        };
        var projection: liborca.library.Projection = .{
            .allocator = allocator,
            .library = library_database,
        };
        scanner.projection = &projection;
        defer scanner.deinit();
        const result = try scanner.scan(args[3]);
        try library_database.scan_runs.finish(
            run.id,
            if (result.cancelled) .cancelled else .completed,
            .{
                .files_seen = result.files_seen,
                .changed = result.changed,
                .unchanged = result.unchanged,
                .unsupported = result.unsupported,
                .errors = result.errors,
            },
        );
        // Never on a cancelled run: a partial walk must not mark the files it
        // did not reach as missing.
        if (!result.cancelled) _ = try library_database.files.markMissingBelowGeneration(
            binding.root_id,
            run.generation,
        );
        try stdout.print(
            "seen={d} changed={d} unchanged={d} unsupported={d} errors={d} batches={d}\n",
            .{
                result.files_seen,
                result.changed,
                result.unchanged,
                result.unsupported,
                result.errors,
                result.batches_committed,
            },
        );
        try printProjection(stdout, result.projection);
    } else if (args.len == 3 and std.mem.eql(u8, args[1], "project")) {
        // Reprojection without a filesystem walk: this is what refreshes the
        // library after a metadata edit or a provider acceptance, and it is why
        // the projection is a pass of its own rather than part of the scanner.
        const database_path = try allocator.dupeSentinel(u8, args[2], 0);
        var runtime = liborca.OrcaRuntime.init(allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(init.io, database_path);
        const library_database = try runtime.libraryDatabase(library_handle);
        var projection: liborca.library.Projection = .{
            .allocator = allocator,
            .library = library_database,
        };
        try printProjection(stdout, try projection.run(.all));
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
    } else {
        try stdout.writeAll(
            \\Usage: orca-cli [--version | demo | scan DATABASE ROOT | project DATABASE
            \\                 | analyze DATABASE AUDIO
            \\                 | health DATABASE [OFFSET] | devices | play AUDIO [DEVICE_ID]]
            \\
            \\The host-independent Orca control client.
            \\
        );
    }

    try stdout.flush();
}

fn sleepMilliseconds(milliseconds: u32) void {
    const duration: std.c.timespec = .{
        .sec = milliseconds / 1000,
        .nsec = @as(c_long, milliseconds % 1000) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&duration, null);
}

fn printProjection(
    stdout: *std.Io.Writer,
    result: liborca.library.projection.Result,
) !void {
    try stdout.print(
        "projected folders={d} groups={d} files={d} tracks={d} compilations={d} " ++
            "filename_titles={d} synthetic_positions={d} displaced_positions={d}\n",
        .{
            result.folders_visited,
            result.groups_projected,
            result.files_projected,
            result.tracks_written,
            result.compilations,
            result.filename_titles,
            result.synthetic_positions,
            result.displaced_positions,
        },
    );
}
