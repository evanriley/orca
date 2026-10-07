const std = @import("std");
const liborca = @import("liborca");

const service_module = liborca.internal.analysis.service;
const audio_features = liborca.internal.analysis.audio_features;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: orca-analysis-bench FILE [ITERATIONS]\n", .{});
        return error.MissingArgument;
    }
    const path = args[1];
    const iterations = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 3;

    const codecs = liborca.internal.codec.CodecRegistry.builtins();
    const service: service_module.Service = .{ .allocator = allocator, .io = init.io, .codecs = &codecs };

    var with_ns: i96 = std.math.maxInt(i96);
    var without_ns: i96 = std.math.maxInt(i96);
    var features_bytes: [audio_features.Features.encoded_size]u8 = undefined;
    var source_identity: [32]u8 = undefined;
    var frames: u64 = 0;
    var sample_rate: u32 = 0;
    for (0..iterations) |_| {
        const start = std.Io.Clock.awake.now(init.io);
        const full = (try service.examineFile(null, path, .{}, null)).analyzed;
        with_ns = @min(with_ns, start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
        features_bytes = full.features.?.encode();
        source_identity = full.source_identity;
        frames = full.decoded_frames.?;
        full.deinit();
    }
    const stored: service_module.StoredResults = .{
        .source_identity = source_identity,
        .features = &features_bytes,
    };
    for (0..iterations) |_| {
        const start = std.Io.Clock.awake.now(init.io);
        const partial = (try service.examineFile(null, path, .{}, &stored)).analyzed;
        without_ns = @min(without_ns, start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
        if (partial.measured.features) return error.FeaturesMeasured;
        partial.deinit();
    }

    var local = try liborca.internal.storage.LocalFileSource.open(init.io, path);
    defer local.close();
    var decoder = try codecs.openDetected(allocator, local.readable());
    defer decoder.deinit();
    sample_rate = decoder.format.sample_rate;
    const channels: usize = decoder.format.channels;
    const pcm = try allocator.alloc(f32, @intCast(frames * channels));
    defer allocator.free(pcm);
    var filled: usize = 0;
    while (filled < pcm.len) {
        const read = try decoder.readFrames(pcm[filled..]);
        if (read == 0) break;
        filled += read * channels;
    }
    var alone_ns: i96 = std.math.maxInt(i96);
    for (0..iterations) |_| {
        const start = std.Io.Clock.awake.now(init.io);
        var analyzer = try audio_features.Analyzer.init(allocator, sample_rate, @intCast(channels), .{});
        defer analyzer.deinit();
        var offset: usize = 0;
        while (offset < filled) : (offset += 4096 * channels)
            try analyzer.process(pcm[offset..@min(filled, offset + 4096 * channels)]);
        std.mem.doNotOptimizeAway(try analyzer.finish());
        alone_ns = @min(alone_ns, start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
    }

    const added = @as(f64, @floatFromInt(with_ns - without_ns)) / @as(f64, @floatFromInt(without_ns));
    std.debug.print(
        "Orca {f} analysis benchmark: {s}, {d} Hz, {d} s, examine with features {d} ms, without {d} ms, features add {d:.1} %, features analyzer alone {d} ms\n",
        .{
            liborca.version,
            std.fs.path.basename(path),
            sample_rate,
            frames / sample_rate,
            @divTrunc(with_ns, std.time.ns_per_ms),
            @divTrunc(without_ns, std.time.ns_per_ms),
            added * 100,
            @divTrunc(alone_ns, std.time.ns_per_ms),
        },
    );
}
