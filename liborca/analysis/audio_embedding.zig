const std = @import("std");
const build_options = @import("build_options");

const KissComplex = extern struct { r: f32, i: f32 };
extern fn kiss_fftr_alloc(nfft: c_int, inverse_fft: c_int, mem: ?*anyopaque, lenmem: ?*usize) ?*anyopaque;
extern fn kiss_fftr(cfg: *anyopaque, timedata: [*]const f32, freqdata: [*]KissComplex) void;

const ShimModel = opaque {};
extern fn orca_embedding_model_create(bytes: [*]const u8, size: usize, model: *?*ShimModel) i32;
extern fn orca_embedding_model_destroy(model: ?*ShimModel) void;
extern fn orca_embedding_model_run(
    model: *const ShimModel,
    features: [*]const f32,
    frames: u32,
    bands: u32,
    embedding: [*]f32,
    embedding_size: u32,
) i32;

const shim_ok = 0;
const shim_runtime_too_old = 1;

pub const enabled = build_options.embeddings;

pub const sample_rate: u32 = 48_000;
pub const window_samples = 10 * sample_rate;
pub const frame_count = 1001;
pub const band_count = 64;
pub const feature_count = frame_count * band_count;
pub const embedding_size = 512;

pub const model_size = 32_587_451;
pub const model_sha256 = digest: {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, "12d3e2c1593ba111df6103feac2f3ce4f4e85e5efc2ad927ac16a8402e7b3c36") catch unreachable;
    break :digest digest;
};

const window_size = 1024;
const hop_size = 480;
const bin_count = window_size / 2 + 1;
const reflected_samples = window_size / 2;
const padded_samples = window_samples + 2 * reflected_samples;
const mel_low_hz = 50.0;
const mel_high_hz = 14_000.0;
const max_mel_band_bins = 40;
const mel_power_floor = 1e-10;

comptime {
    std.debug.assert(frame_count == 1 + (padded_samples - window_size) / hop_size);
}

const MelBank = struct {
    first_bin: [band_count]u16,
    bin_counts: [band_count]u16,
    weights: [band_count][max_mel_band_bins]f64,

    fn init(self: *MelBank) void {
        const low_mel = hzToMel(mel_low_hz);
        const high_mel = hzToMel(mel_high_hz);
        var edges: [band_count + 2]f64 = undefined;
        for (&edges, 0..) |*edge, index| {
            const fraction = @as(f64, @floatFromInt(index)) / (band_count + 1);
            edge.* = melToHz(low_mel + (high_mel - low_mel) * fraction);
        }
        for (0..band_count) |band| {
            const lower = edges[band];
            const centre = edges[band + 1];
            const upper = edges[band + 2];
            const area_norm = 2.0 / (upper - lower);
            var first: ?usize = null;
            var count: usize = 0;
            for (0..bin_count) |bin| {
                const frequency = binFrequency(bin);
                const rising = (frequency - lower) / (centre - lower);
                const falling = (upper - frequency) / (upper - centre);
                const weight = @max(0, @min(rising, falling));
                if (weight <= 0) continue;
                if (first == null) first = bin;
                std.debug.assert(bin - first.? == count and count < max_mel_band_bins);
                self.weights[band][count] = weight * area_norm;
                count += 1;
            }
            self.first_bin[band] = @intCast(first orelse 0);
            self.bin_counts[band] = @intCast(count);
        }
    }

    fn bandPower(self: *const MelBank, band: usize, power: *const [bin_count]f64) f64 {
        const first = self.first_bin[band];
        var sum: f64 = 0;
        for (self.weights[band][0..self.bin_counts[band]], power[first..][0..self.bin_counts[band]]) |weight, value|
            sum += weight * value;
        return sum;
    }

    const linear_hz_per_mel = 200.0 / 3.0;
    const log_region_hz = 1000.0;
    const log_region_mel = log_region_hz / linear_hz_per_mel;
    const log_step = @log(6.4) / 27.0;

    fn hzToMel(hz: f64) f64 {
        if (hz < log_region_hz) return hz / linear_hz_per_mel;
        return log_region_mel + @log(hz / log_region_hz) / log_step;
    }

    fn melToHz(mel: f64) f64 {
        if (mel < log_region_mel) return mel * linear_hz_per_mel;
        return log_region_hz * @exp(log_step * (mel - log_region_mel));
    }
};

fn binFrequency(bin: usize) f64 {
    return @as(f64, @floatFromInt(bin)) * sample_rate / window_size;
}

fn periodicHann(index: usize, length: usize) f64 {
    const phase = @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(length));
    return 0.5 - 0.5 * @cos(2.0 * std.math.pi * phase);
}

/// Not shareable between threads: it owns FFT state and scratch memory.
pub const FrontEnd = struct {
    allocator: std.mem.Allocator,
    fft_memory: []align(16) u8,
    fft: *anyopaque,
    scratch: *Scratch,

    const Scratch = struct {
        padded: [padded_samples]f32,
        hann: [window_size]f64,
        windowed: [window_size]f32,
        spectrum: [bin_count]KissComplex,
        power: [bin_count]f64,
        mel_bank: MelBank,
    };

    pub fn init(allocator: std.mem.Allocator) !FrontEnd {
        var fft_len: usize = 0;
        _ = kiss_fftr_alloc(window_size, 0, null, &fft_len);
        const fft_memory = try allocator.alignedAlloc(u8, .@"16", fft_len);
        errdefer allocator.free(fft_memory);
        const fft = kiss_fftr_alloc(window_size, 0, fft_memory.ptr, &fft_len) orelse
            return error.SpectrumUnavailable;
        const scratch = try allocator.create(Scratch);
        errdefer allocator.destroy(scratch);
        for (&scratch.hann, 0..) |*value, index| value.* = periodicHann(index, window_size);
        scratch.mel_bank.init();
        return .{ .allocator = allocator, .fft_memory = fft_memory, .fft = fft, .scratch = scratch };
    }

    pub fn deinit(self: *FrontEnd) void {
        self.allocator.destroy(self.scratch);
        self.allocator.free(self.fft_memory);
        self.* = undefined;
    }

    pub fn melSpectrogram(
        self: *FrontEnd,
        samples: []const f32,
        features: *[feature_count]f32,
    ) error{ EmptyWindow, WindowTooLong }!void {
        if (samples.len == 0) return error.EmptyWindow;
        if (samples.len > window_samples) return error.WindowTooLong;
        const scratch = self.scratch;

        const window = scratch.padded[reflected_samples..][0..window_samples];
        const repeated = window_samples / samples.len * samples.len;
        var filled: usize = 0;
        while (filled < repeated) : (filled += samples.len)
            @memcpy(window[filled..][0..samples.len], samples);
        @memset(window[repeated..], 0);
        for (1..reflected_samples + 1) |distance| {
            scratch.padded[reflected_samples - distance] = window[distance];
            scratch.padded[reflected_samples + window_samples - 1 + distance] = window[window_samples - 1 - distance];
        }

        for (0..frame_count) |frame| {
            const input = scratch.padded[frame * hop_size ..][0..window_size];
            for (&scratch.windowed, input, scratch.hann) |*windowed, sample, weight|
                windowed.* = @floatCast(sample * weight);
            kiss_fftr(self.fft, &scratch.windowed, &scratch.spectrum);
            for (&scratch.power, scratch.spectrum) |*power, value|
                power.* = @as(f64, value.r) * value.r + @as(f64, value.i) * value.i;
            for (features[frame * band_count ..][0..band_count], 0..) |*level, band| {
                const mel_power = scratch.mel_bank.bandPower(band, &scratch.power);
                level.* = @floatCast(10.0 * std.math.log10(@max(mel_power, mel_power_floor)));
            }
        }
    }
};

pub const Model = struct {
    shim: *ShimModel,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Model {
        if (!enabled) return error.EmbeddingsNotBuilt;
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.EmbeddingModelMissing,
            else => return err,
        };
        defer file.close(io);
        if ((try file.stat(io)).size != model_size) return error.EmbeddingModelMismatch;
        const bytes = try allocator.alloc(u8, model_size);
        defer allocator.free(bytes);
        if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.EmbeddingModelMismatch;
        var digest: [model_sha256.len]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &model_sha256)) return error.EmbeddingModelMismatch;

        var shim: ?*ShimModel = null;
        return switch (orca_embedding_model_create(bytes.ptr, bytes.len, &shim)) {
            shim_ok => .{ .shim = shim.? },
            shim_runtime_too_old => error.EmbeddingRuntimeTooOld,
            else => error.EmbeddingSessionFailed,
        };
    }

    pub fn deinit(self: *Model) void {
        if (!enabled) unreachable;
        orca_embedding_model_destroy(self.shim);
        self.* = undefined;
    }

    pub fn embed(
        self: Model,
        features: *const [feature_count]f32,
        embedding: *[embedding_size]f32,
    ) error{EmbeddingFailed}!void {
        if (!enabled) unreachable;
        if (orca_embedding_model_run(self.shim, features, frame_count, band_count, embedding, embedding_size) != shim_ok)
            return error.EmbeddingFailed;
    }
};

const testing = std.testing;

const reference_frames = [_]usize{ 0, 1, 2, 500, 998, 999, 1000 };
const exact_above_db = -60.0;
const exact_tolerance_db = 0.05;
const floor_tolerance_db = 0.2;
const min_reference_cosine = 0.995;

const Signal = enum {
    sine440,
    chirp,
    mix,
    sine440_3s,

    fn sampleCount(self: Signal) usize {
        return if (self == .sine440_3s) 3 * sample_rate else window_samples;
    }

    fn melFrames(self: Signal) []const u8 {
        return switch (self) {
            .sine440 => @embedFile("testdata/embedding/sine440_mel_frames.f32"),
            .chirp => @embedFile("testdata/embedding/chirp_mel_frames.f32"),
            .mix => @embedFile("testdata/embedding/mix_mel_frames.f32"),
            .sine440_3s => @embedFile("testdata/embedding/sine440_3s_mel_frames.f32"),
        };
    }

    fn embedding(self: Signal) []const u8 {
        return switch (self) {
            .sine440 => @embedFile("testdata/embedding/sine440_emb_int8.f32"),
            .chirp => @embedFile("testdata/embedding/chirp_emb_int8.f32"),
            .mix => @embedFile("testdata/embedding/mix_emb_int8.f32"),
            .sine440_3s => @embedFile("testdata/embedding/sine440_3s_emb_int8.f32"),
        };
    }

    fn value(self: Signal, index: usize) f32 {
        const time = @as(f64, @floatFromInt(index)) / sample_rate;
        const turn = 2.0 * std.math.pi * time;
        return @floatCast(switch (self) {
            .sine440, .sine440_3s => 0.5 * @sin(turn * 440),
            .chirp => 0.5 * @sin(2.0 * std.math.pi * (100 * time + 595 * time * time)),
            .mix => mix: {
                var sum: f64 = 0;
                for ([_]f64{ 220, 880, 3520, 9000 }) |hz| sum += 0.2 * @sin(turn * hz);
                break :mix 0.5 * (1 - @cos(turn * 2)) * sum;
            },
        });
    }

    fn features(self: Signal, front_end: *FrontEnd) !*[feature_count]f32 {
        const samples = try testing.allocator.alloc(f32, self.sampleCount());
        defer testing.allocator.free(samples);
        for (samples, 0..) |*sample, index| sample.* = self.value(index);
        const result = try testing.allocator.create([feature_count]f32);
        errdefer testing.allocator.destroy(result);
        try front_end.melSpectrogram(samples, result);
        return result;
    }
};

fn storedFloat(bytes: []const u8, index: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little));
}

fn testModelPath() ![]const u8 {
    if (!enabled) return error.SkipZigTest;
    return build_options.embedding_test_model orelse error.SkipZigTest;
}

test "melSpectrogram_referenceSignals_matchesReferenceExtractor" {
    var front_end = try FrontEnd.init(testing.allocator);
    defer front_end.deinit();
    for (std.enums.values(Signal)) |signal| {
        const features = try signal.features(&front_end);
        defer testing.allocator.destroy(features);
        const stored = signal.melFrames();
        try testing.expectEqual(reference_frames.len * band_count * 4, stored.len);
        for (reference_frames, 0..) |frame, row| {
            for (0..band_count) |band| {
                const expected = storedFloat(stored, row * band_count + band);
                const tolerance: f32 = if (expected > exact_above_db) exact_tolerance_db else floor_tolerance_db;
                try testing.expectApproxEqAbs(expected, features[frame * band_count + band], tolerance);
            }
        }
    }
}

test "melSpectrogram_shortWindow_repeatsThenZeroFills" {
    const repeat_frames = 400;
    var front_end = try FrontEnd.init(testing.allocator);
    defer front_end.deinit();
    const samples = try testing.allocator.alloc(f32, repeat_frames * hop_size);
    defer testing.allocator.free(samples);
    for (samples, 0..) |*sample, index| sample.* = Signal.sine440.value(index);
    const features = try testing.allocator.create([feature_count]f32);
    defer testing.allocator.destroy(features);
    try front_end.melSpectrogram(samples, features);

    const silent_frame = 2 * repeat_frames + 100;
    try testing.expectEqualSlices(
        f32,
        features[100 * band_count ..][0..band_count],
        features[(100 + repeat_frames) * band_count ..][0..band_count],
    );
    for (features[silent_frame * band_count ..][0..band_count]) |level|
        try testing.expectEqual(@as(f32, -100), level);
}

test "melSpectrogram_emptyOrOverlongWindow_isRefused" {
    var front_end = try FrontEnd.init(testing.allocator);
    defer front_end.deinit();
    const features = try testing.allocator.create([feature_count]f32);
    defer testing.allocator.destroy(features);
    const samples = try testing.allocator.alloc(f32, window_samples + 1);
    defer testing.allocator.free(samples);
    @memset(samples, 0);
    try testing.expectError(error.EmptyWindow, front_end.melSpectrogram(samples[0..0], features));
    try testing.expectError(error.WindowTooLong, front_end.melSpectrogram(samples, features));
}

test "open_builtWithoutEmbeddings_reportsNotBuilt" {
    if (enabled) return error.SkipZigTest;
    try testing.expectError(error.EmbeddingsNotBuilt, Model.open(testing.allocator, testing.io, "missing.onnx"));
}

test "open_missingFile_reportsMissing" {
    if (!enabled) return error.SkipZigTest;
    try testing.expectError(
        error.EmbeddingModelMissing,
        Model.open(testing.allocator, testing.io, ".zig-cache/tmp/no-such-embedding-model.onnx"),
    );
}

test "open_fileOfAnotherSize_reportsMismatch" {
    if (!enabled) return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(testing.io, .{ .sub_path = "model.onnx", .data = "not the model" });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/model.onnx", .{temporary.sub_path});
    defer testing.allocator.free(path);
    try testing.expectError(error.EmbeddingModelMismatch, Model.open(testing.allocator, testing.io, path));
}

test "open_modelWithOneByteFlipped_reportsMismatch" {
    const model_path = try testModelPath();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, model_path, testing.allocator, .limited(model_size + 1));
    defer testing.allocator.free(bytes);
    bytes[bytes.len / 2] ^= 1;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(testing.io, .{ .sub_path = "model.onnx", .data = bytes });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/model.onnx", .{temporary.sub_path});
    defer testing.allocator.free(path);
    try testing.expectError(error.EmbeddingModelMismatch, Model.open(testing.allocator, testing.io, path));
}

test "embed_referenceSignals_matchesReferenceEmbeddings" {
    const model_path = try testModelPath();
    var model = try Model.open(testing.allocator, testing.io, model_path);
    defer model.deinit();
    var front_end = try FrontEnd.init(testing.allocator);
    defer front_end.deinit();
    for (std.enums.values(Signal)) |signal| {
        const features = try signal.features(&front_end);
        defer testing.allocator.destroy(features);
        var embedding: [embedding_size]f32 = undefined;
        try model.embed(features, &embedding);

        const stored = signal.embedding();
        try testing.expectEqual(embedding_size * 4, stored.len);
        var dot: f64 = 0;
        var produced_square: f64 = 0;
        var expected_square: f64 = 0;
        for (embedding, 0..) |produced, index| {
            const expected: f64 = storedFloat(stored, index);
            dot += produced * expected;
            produced_square += @as(f64, produced) * produced;
            expected_square += expected * expected;
        }
        try testing.expect(dot / @sqrt(produced_square * expected_square) >= min_reference_cosine);
    }
}

test "embed_severalThreadsOnOneModel_agree" {
    const model_path = try testModelPath();
    var model = try Model.open(testing.allocator, testing.io, model_path);
    defer model.deinit();
    var front_end = try FrontEnd.init(testing.allocator);
    defer front_end.deinit();
    const features = try Signal.mix.features(&front_end);
    defer testing.allocator.destroy(features);

    const Worker = struct {
        fn run(shared: Model, input: *const [feature_count]f32, output: *[embedding_size]f32, failed: *bool) void {
            shared.embed(input, output) catch {
                failed.* = true;
            };
        }
    };
    var embeddings: [3][embedding_size]f32 = undefined;
    var failures: [3]bool = @splat(false);
    var threads: [3]std.Thread = undefined;
    for (&threads, &embeddings, &failures) |*thread, *embedding, *failed|
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ model, features, embedding, failed });
    for (threads) |thread| thread.join();
    for (failures) |failed| try testing.expect(!failed);
    try testing.expectEqualSlices(f32, &embeddings[0], &embeddings[1]);
    try testing.expectEqualSlices(f32, &embeddings[0], &embeddings[2]);
}
