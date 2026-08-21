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
        const library_handle = try runtime.openLibrary(database_path);
        const library_database = try runtime.libraryDatabase(library_handle);
        var scanner = liborca.library.Scanner{
            .allocator = allocator,
            .io = init.io,
            .observed_files = &library_database.observed_files,
        };
        const result = try scanner.scan(args[3]);
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
    } else if (args.len == 4 and std.mem.eql(u8, args[1], "analyze")) {
        const database_path = try allocator.dupeSentinel(u8, args[2], 0);
        var runtime = liborca.OrcaRuntime.init(allocator);
        defer runtime.deinit();
        const library_handle = try runtime.openLibrary(database_path);
        const library_database = try runtime.libraryDatabase(library_handle);
        const codecs = liborca.codec.CodecRegistry.builtins();
        const service: liborca.analysis.service.Service = .{
            .allocator = allocator,
            .io = init.io,
            .codecs = &codecs,
            .cache = &library_database.analysis_cache,
        };
        const result = try service.analyzeFile(args[3], .{});
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
        const library_handle = try runtime.openLibrary(database_path);
        const library_database = try runtime.libraryDatabase(library_handle);
        var page = try library_database.health_issues.page(allocator, 256, offset);
        defer page.deinit();
        for (page.items) |issue| try stdout.print(
            "{s}\t{s}\t{s}\t{s}\n",
            .{ @tagName(issue.severity), @tagName(issue.kind), issue.path, issue.details },
        );
    } else if ((args.len == 3 or args.len == 4) and std.mem.eql(u8, args[1], "play")) {
        const device_id = if (args.len == 4)
            try std.fmt.parseInt(u64, args[3], 10)
        else
            0;
        const report = try liborca.audio.backends.playback.playFileBlocking(
            allocator,
            init.io,
            args[2],
            device_id,
            .robust,
        );
        try stdout.print(
            "played={d} underruns={d} recoveries={d} quantum={d} delay={?d}\n",
            .{
                report.frames_played,
                report.underruns,
                report.recoveries,
                report.timing.backend_quantum_frames,
                report.timing.device_delay_frames,
            },
        );
    } else {
        try stdout.writeAll(
            \\Usage: orca-cli [--version | demo | scan DATABASE ROOT | analyze DATABASE AUDIO
            \\                 | health DATABASE [OFFSET] | play AUDIO [DEVICE_ID]]
            \\
            \\The host-independent Orca control client.
            \\
        );
    }

    try stdout.flush();
}
