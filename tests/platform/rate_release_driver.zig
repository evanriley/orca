const std = @import("std");
const liborca = @import("liborca");

const usage = "usage: rate-release-driver AUDIO SINK_NAME\n" ++
    "Plays AUDIO on the virtual sink named SINK_NAME, prints `playing` once audio has rendered,\n" ++
    "pauses on a `pause` line from stdin and exits on end of input.\n" ++
    "Runs only under scripts/headless-audio.sh.\n";

fn requirePrivateAudio(environ: *const std.process.Environ.Map) !void {
    const runtime_dir = environ.get("XDG_RUNTIME_DIR") orelse "";
    const private_dir = environ.get("ORCA_PRIVATE_AUDIO") orelse "";
    if (private_dir.len == 0 or
        !std.mem.eql(u8, private_dir, runtime_dir) or
        !std.mem.startsWith(u8, runtime_dir, "/tmp/orca-audio.") or
        environ.get("PIPEWIRE_REMOTE") != null)
    {
        std.debug.print(
            "rate-release-driver: refusing to open an output outside the private server; run it under scripts/headless-audio.sh\n",
            .{},
        );
        return error.NotPrivateAudioServer;
    }
}

fn resolveSink(runtime: *liborca.Runtime, sink_name: []const u8) !u64 {
    var devices: [64]liborca.Device = undefined;
    const count = try runtime.enumerateOutputDevices(&devices, .identity);
    for (devices[0..count]) |device| {
        if (!std.mem.eql(u8, device.nameSlice(), sink_name)) continue;
        if (device.kind != .virtual) {
            std.debug.print(
                "rate-release-driver: device {d} named \"{s}\" is {t}, expected the virtual sink the check created\n",
                .{ device.id, sink_name, device.kind },
            );
            return error.DeviceNotVirtual;
        }
        return device.id;
    }
    std.debug.print("rate-release-driver: no output named \"{s}\"; expected the sink the check created\n", .{sink_name});
    return error.DeviceNotFound;
}

fn sleepMilliseconds(milliseconds: u32) void {
    const duration: std.c.timespec = .{
        .sec = milliseconds / 1000,
        .nsec = @as(c_long, milliseconds % 1000) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&duration, null);
}

fn requireOutput(runtime: *liborca.Runtime, zone: liborca.ZoneHandle) !void {
    const stats = try runtime.zoneStats(zone);
    if (stats.output_state == .failed) return error.OutputFailed;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("{s}", .{usage});
        return error.Usage;
    }
    try requirePrivateAudio(init.environ_map);

    var runtime = liborca.Runtime.init(init.gpa);
    defer runtime.deinit();
    const device_id = try resolveSink(&runtime, args[2]);
    const player = try runtime.createPlayer();
    const zone = try runtime.createZone();
    try runtime.attachZone(zone, player);
    try runtime.playerLoadFile(player, init.io, args[1]);
    try runtime.zoneRequestOutput(zone, device_id);
    try runtime.playPlayer(player);

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var waited_ms: u32 = 0;
    while ((try runtime.playerSnapshot(player)).position_frames == 0) {
        try requireOutput(&runtime, zone);
        if (waited_ms >= 10 * std.time.ms_per_s) return error.PlaybackNeverStarted;
        sleepMilliseconds(10);
        waited_ms += 10;
    }
    try stdout.writeAll("playing\n");
    try stdout.flush();

    var stdin_buffer: [256]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .initStreaming(.stdin(), init.io, &stdin_buffer);
    while (try stdin_reader.interface.takeDelimiter('\n')) |line| {
        if (!std.mem.eql(u8, line, "pause")) {
            std.debug.print("rate-release-driver: unknown command \"{s}\"; expected pause\n", .{line});
            return error.UnknownCommand;
        }
        try runtime.pausePlayer(player);
        try stdout.writeAll("paused\n");
        try stdout.flush();
    }

    try requireOutput(&runtime, zone);
    const snapshot = try runtime.playerSnapshot(player);
    try stdout.print("state={t} played={d}\n", .{ snapshot.state, snapshot.position_frames });
    try stdout.flush();
}
