const std = @import("std");
const liborca = @import("liborca");

const service_module = liborca.internal.analysis.service;
const audio_features = liborca.internal.analysis.audio_features;
const audio_embedding = liborca.internal.analysis.audio_embedding;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: orca-analysis-bench FILE [ITERATIONS [EMBEDDING_MODEL]]\n", .{});
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

    if (args.len < 4) return;
    var model = try audio_embedding.Model.open(allocator, init.io, args[3]);
    defer model.deinit();
    var front_end = try audio_embedding.FrontEnd.init(allocator);
    defer front_end.deinit();
    const resampled = try allocator.create([audio_embedding.window_samples]f32);
    defer allocator.destroy(resampled);
    const mel = try allocator.create([audio_embedding.feature_count]f32);
    defer allocator.destroy(mel);
    const Stage = enum { capture, resample, front_end, model, finish };
    var best: std.EnumArray(Stage, i96) = .initFill(std.math.maxInt(i96));
    var windows: usize = 0;
    for (0..iterations) |_| {
        var spent: std.EnumArray(Stage, i96) = .initFill(0);
        var mark = std.Io.Clock.awake.now(init.io);
        var analyzer = try audio_embedding.Analyzer.init(allocator, sample_rate, @intCast(channels), frames);
        defer analyzer.deinit();
        var offset: usize = 0;
        while (offset < filled) : (offset += 4096 * channels)
            try analyzer.process(pcm[offset..@min(filled, offset + 4096 * channels)]);
        spent.set(.capture, mark.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
        windows = analyzer.plan.count;
        for (0..windows) |index| {
            mark = std.Io.Clock.awake.now(init.io);
            const samples = try analyzer.windowSamples(index, resampled);
            spent.getPtr(.resample).* += mark.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
            if (samples.len == 0) continue;
            mark = std.Io.Clock.awake.now(init.io);
            try front_end.melSpectrogram(samples, mel);
            spent.getPtr(.front_end).* += mark.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
            mark = std.Io.Clock.awake.now(init.io);
            var output: [audio_embedding.embedding_size]f32 = undefined;
            try model.embed(mel, &output);
            spent.getPtr(.model).* += mark.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        }
        mark = std.Io.Clock.awake.now(init.io);
        std.mem.doNotOptimizeAway(try analyzer.finish(.{ .model = model, .front_end = &front_end }));
        spent.set(.finish, mark.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
        for (std.enums.values(Stage)) |stage| best.set(stage, @min(best.get(stage), spent.get(stage)));
    }
    std.debug.print(
        "embedding of {d} windows: capture {d:.1} ms, resample {d:.1} ms, mel front-end {d:.1} ms, model {d:.1} ms, whole finish {d:.1} ms\n",
        .{
            windows,
            milliseconds(best.get(.capture)),
            milliseconds(best.get(.resample)),
            milliseconds(best.get(.front_end)),
            milliseconds(best.get(.model)),
            milliseconds(best.get(.finish)),
        },
    );
}

fn milliseconds(nanoseconds: i96) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
}
