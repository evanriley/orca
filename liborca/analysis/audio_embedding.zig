const std = @import("std");
const build_options = @import("build_options");
const resampler = @import("../audio/resampler.zig");

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

pub const cache_kind: u8 = 7;
pub const algorithm_id = "orca.audio-embedding";
pub const algorithm_version: u32 = 1;

pub const window_seconds = 10;
pub const max_windows = 3;
const window_centres = [max_windows]f64{ 0.25, 0.5, 0.75 };
const min_seconds = 1;
const silence_dbfs = -80;
const silence_peak: f32 = 1e-4;

comptime {
    std.debug.assert(@abs(20.0 * @log10(@as(f64, silence_peak)) - silence_dbfs) < 1e-4);
}

const Sha256 = std.crypto.hash.sha2.Sha256;

fn sha256Digest(comptime hex: *const [2 * Sha256.digest_length]u8) [Sha256.digest_length]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, hex) catch unreachable;
    return digest;
}

const Recipe = struct {
    sample_rate: u32,
    converter: resampler.SampleRate.Converter,
    fft_size: usize,
    hop_size: usize,
    band_count: usize,
    mel_low_hz: f64,
    mel_high_hz: f64,
    max_mel_band_bins: usize,
    framing: Framing,
    level: Level,

    const Framing = enum { repeated_and_reflected, zero_padded };

    const Level = union(enum) {
        decibels: struct { power_floor: f64 },
        log_compressed: struct { gain: f64, mean: f64, deviation: f64 },
    };

    fn windowSamples(self: Recipe) usize {
        return @as(usize, window_seconds) * self.sample_rate;
    }

    fn frameCount(self: Recipe) usize {
        return 1 + self.windowSamples() / self.hop_size;
    }
};

const clap_recipe: Recipe = .{
    .sample_rate = 48_000,
    .converter = .sinc_fastest,
    .fft_size = 1024,
    .hop_size = 480,
    .band_count = 64,
    .mel_low_hz = 50.0,
    .mel_high_hz = 14_000.0,
    .max_mel_band_bins = 40,
    .framing = .repeated_and_reflected,
    .level = .{ .decibels = .{ .power_floor = 1e-10 } },
};

const maest_recipe: Recipe = .{
    .sample_rate = 16_000,
    .converter = .sinc_medium,
    .fft_size = 512,
    .hop_size = 256,
    .band_count = 96,
    .mel_low_hz = 0.0,
    .mel_high_hz = 8_000.0,
    .max_mel_band_bins = 20,
    .framing = .zero_padded,
    .level = .{ .log_compressed = .{
        .gain = 10_000.0,
        .mean = 2.06755686098554,
        .deviation = 1.268292820667291,
    } },
};

pub const ModelSpec = struct {
    file_name: []const u8,
    url: []const u8,
    size: usize,
    sha256: [Sha256.digest_length]u8,
    sample_rate: u32,
    converter: resampler.SampleRate.Converter,
    frame_count: u32,
    band_count: u32,
    embedding_size: u16,

    pub fn windowSamples(self: *const ModelSpec) usize {
        return @as(usize, window_seconds) * self.sample_rate;
    }

    pub fn featureCount(self: *const ModelSpec) usize {
        return @as(usize, self.frame_count) * self.band_count;
    }

    pub fn encodedSize(self: *const ModelSpec) usize {
        return Result.header_size + self.embedding_size;
    }

    fn init(
        comptime release: []const u8,
        comptime file_name: []const u8,
        comptime size: usize,
        comptime sha256: *const [2 * Sha256.digest_length]u8,
        comptime recipe: Recipe,
        comptime embedding_size: u16,
    ) ModelSpec {
        return .{
            .file_name = file_name,
            .url = "https://github.com/evanriley/orca/releases/download/" ++ release ++ "/" ++ file_name,
            .size = size,
            .sha256 = sha256Digest(sha256),
            .sample_rate = recipe.sample_rate,
            .converter = recipe.converter,
            .frame_count = recipe.frameCount(),
            .band_count = recipe.band_count,
            .embedding_size = embedding_size,
        };
    }
};

const clap_spec: ModelSpec = .init(
    "model-clap-int8-1",
    "clap_audio_int8.onnx",
    32_587_451,
    "12d3e2c1593ba111df6103feac2f3ce4f4e85e5efc2ad927ac16a8402e7b3c36",
    clap_recipe,
    512,
);

const maest_spec: ModelSpec = .init(
    "model-maest-int8-1",
    "maest_audio_int8.onnx",
    80_400_354,
    "fcdf35e3b8737cb0853bb83cadd7a62885f70f1afe30cde3f185e61eb06d843e",
    maest_recipe,
    768,
);

pub const ModelId = enum(u8) {
    clap_htsat_unfused = 1,
    discogs_maest = 2,

    pub fn spec(self: ModelId) *const ModelSpec {
        return switch (self) {
            .clap_htsat_unfused => &clap_spec,
            .discogs_maest => &maest_spec,
        };
    }

    fn ofFileSize(size: u64) ?ModelId {
        for (std.enums.values(ModelId)) |id| {
            if (id.spec().size == size) return id;
        }
        return null;
    }
};

fn largestOf(comptime measure: fn (*const ModelSpec) usize) usize {
    var largest: usize = 0;
    for (std.enums.values(ModelId)) |id| largest = @max(largest, measure(id.spec()));
    return largest;
}

fn embeddingSizeOf(spec: *const ModelSpec) usize {
    return spec.embedding_size;
}

pub const max_window_samples = largestOf(ModelSpec.windowSamples);
pub const max_feature_count = largestOf(ModelSpec.featureCount);
pub const max_embedding_size = largestOf(embeddingSizeOf);

comptime {
    const ids = std.enums.values(ModelId);
    for (ids, 0..) |id, index| {
        for (ids[index + 1 ..]) |other| std.debug.assert(id.spec().size != other.spec().size);
    }
}

fn periodicHann(index: usize, length: usize) f64 {
    const phase = @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(length));
    return 0.5 - 0.5 * @cos(2.0 * std.math.pi * phase);
}

fn MelFrontEnd(comptime recipe: Recipe) type {
    return struct {
        allocator: std.mem.Allocator,
        fft_memory: []align(16) u8,
        fft: *anyopaque,
        scratch: *Scratch,

        const Self = @This();
        const window_samples = recipe.windowSamples();
        const window_size = recipe.fft_size;
        const hop_size = recipe.hop_size;
        const band_count = recipe.band_count;
        const frame_count = recipe.frameCount();
        const feature_count = frame_count * band_count;
        const bin_count = window_size / 2 + 1;
        const edge_samples = window_size / 2;
        const padded_samples = window_samples + 2 * edge_samples;
        const max_mel_band_bins = recipe.max_mel_band_bins;

        comptime {
            std.debug.assert(frame_count == 1 + (padded_samples - window_size) / hop_size);
        }

        const MelBank = struct {
            first_bin: [band_count]u16,
            bin_counts: [band_count]u16,
            weights: [band_count][max_mel_band_bins]f64,

            fn init(self: *MelBank) void {
                const low_mel = hzToMel(recipe.mel_low_hz);
                const high_mel = hzToMel(recipe.mel_high_hz);
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

            fn binFrequency(bin: usize) f64 {
                return @as(f64, @floatFromInt(bin)) * recipe.sample_rate / window_size;
            }
        };

        const Scratch = struct {
            padded: [padded_samples]f32,
            hann: [window_size]f64,
            windowed: [window_size]f32,
            spectrum: [bin_count]KissComplex,
            power: [bin_count]f64,
            mel_bank: MelBank,
        };

        fn init(allocator: std.mem.Allocator) !Self {
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

        fn deinit(self: *Self) void {
            self.allocator.destroy(self.scratch);
            self.allocator.free(self.fft_memory);
            self.* = undefined;
        }

        fn melSpectrogram(self: *Self, samples: []const f32, features: *[feature_count]f32) void {
            std.debug.assert(samples.len != 0 and samples.len <= window_samples);
            const scratch = self.scratch;
            const measured_frames = framesAfterPadding(&scratch.padded, samples);
            for (0..measured_frames) |frame| {
                const input = scratch.padded[frame * hop_size ..][0..window_size];
                for (&scratch.windowed, input, scratch.hann) |*windowed, sample, weight|
                    windowed.* = @floatCast(sample * weight);
                kiss_fftr(self.fft, &scratch.windowed, &scratch.spectrum);
                for (&scratch.power, scratch.spectrum) |*power, value|
                    power.* = @as(f64, value.r) * value.r + @as(f64, value.i) * value.i;
                for (features[frame * band_count ..][0..band_count], 0..) |*value, band|
                    value.* = level(scratch.mel_bank.bandPower(band, &scratch.power));
            }
            @memset(features[measured_frames * band_count ..], level(0));
        }

        fn framesAfterPadding(padded: *[padded_samples]f32, samples: []const f32) usize {
            const window = padded[edge_samples..][0..window_samples];
            switch (recipe.framing) {
                .repeated_and_reflected => {
                    const repeated = window_samples / samples.len * samples.len;
                    var filled: usize = 0;
                    while (filled < repeated) : (filled += samples.len)
                        @memcpy(window[filled..][0..samples.len], samples);
                    @memset(window[repeated..], 0);
                    for (1..edge_samples + 1) |distance| {
                        padded[edge_samples - distance] = window[distance];
                        padded[edge_samples + window_samples - 1 + distance] = window[window_samples - 1 - distance];
                    }
                    return frame_count;
                },
                .zero_padded => {
                    @memset(padded[0..edge_samples], 0);
                    @memcpy(window[0..samples.len], samples);
                    @memset(padded[edge_samples + samples.len ..], 0);
                    return @min(frame_count, 1 + samples.len / hop_size);
                },
            }
        }

        fn level(mel_power: f64) f32 {
            return @floatCast(switch (recipe.level) {
                .decibels => |decibels| 10.0 * std.math.log10(@max(mel_power, decibels.power_floor)),
                .log_compressed => |compressed| (std.math.log10(1.0 + compressed.gain * mel_power) - compressed.mean) /
                    (2.0 * compressed.deviation),
            });
        }
    };
}

/// Not shareable between threads: it owns FFT state and scratch memory.
pub const FrontEnd = union(ModelId) {
    clap_htsat_unfused: MelFrontEnd(clap_recipe),
    discogs_maest: MelFrontEnd(maest_recipe),

    pub fn init(allocator: std.mem.Allocator, model: ModelId) !FrontEnd {
        return switch (model) {
            .clap_htsat_unfused => .{ .clap_htsat_unfused = try .init(allocator) },
            .discogs_maest => .{ .discogs_maest = try .init(allocator) },
        };
    }

    pub fn deinit(self: *FrontEnd) void {
        switch (self.*) {
            inline else => |*front_end| front_end.deinit(),
        }
        self.* = undefined;
    }

    pub fn melSpectrogram(
        self: *FrontEnd,
        samples: []const f32,
        features: []f32,
    ) error{ EmptyWindow, WindowTooLong }!void {
        const spec = std.meta.activeTag(self.*).spec();
        if (samples.len == 0) return error.EmptyWindow;
        if (samples.len > spec.windowSamples()) return error.WindowTooLong;
        std.debug.assert(features.len == spec.featureCount());
        switch (self.*) {
            inline else => |*front_end| front_end.melSpectrogram(samples, features[0..@TypeOf(front_end.*).feature_count]),
        }
    }
};

pub const Model = struct {
    shim: *ShimModel,
    id: ModelId,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Model {
        if (!enabled) return error.EmbeddingsNotBuilt;
        const verified = try readVerified(allocator, io, path);
        defer allocator.free(verified.bytes);
        var shim: ?*ShimModel = null;
        return switch (orca_embedding_model_create(verified.bytes.ptr, verified.bytes.len, &shim)) {
            shim_ok => .{ .shim = shim.?, .id = verified.id },
            shim_runtime_too_old => error.EmbeddingRuntimeTooOld,
            else => error.EmbeddingSessionFailed,
        };
    }

    pub fn verify(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ModelId {
        const verified = try readVerified(allocator, io, path);
        allocator.free(verified.bytes);
        return verified.id;
    }

    const Verified = struct { bytes: []u8, id: ModelId };

    fn readVerified(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Verified {
        if (!enabled) return error.EmbeddingsNotBuilt;
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.EmbeddingModelMissing,
            else => return err,
        };
        defer file.close(io);
        const id = ModelId.ofFileSize((try file.stat(io)).size) orelse return error.EmbeddingModelMismatch;
        const spec = id.spec();
        const bytes = try allocator.alloc(u8, spec.size);
        errdefer allocator.free(bytes);
        if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.EmbeddingModelMismatch;
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &spec.sha256)) return error.EmbeddingModelMismatch;
        return .{ .bytes = bytes, .id = id };
    }

    pub fn deinit(self: *Model) void {
        if (!enabled) unreachable;
        orca_embedding_model_destroy(self.shim);
        self.* = undefined;
    }

    pub fn embed(self: Model, features: []const f32, embedding: []f32) error{EmbeddingFailed}!void {
        if (!enabled) unreachable;
        const spec = self.id.spec();
        std.debug.assert(features.len == spec.featureCount() and embedding.len == spec.embedding_size);
        if (orca_embedding_model_run(
            self.shim,
            features.ptr,
            spec.frame_count,
            spec.band_count,
            embedding.ptr,
            spec.embedding_size,
        ) != shim_ok) return error.EmbeddingFailed;
    }
};

pub fn parameterHash(model: ModelId) [32]u8 {
    const spec = model.spec();
    var encoded: [4 + Sha256.digest_length + 6 * 4]u8 = undefined;
    @memcpy(encoded[0..4], "oemb");
    @memcpy(encoded[4..][0..Sha256.digest_length], &spec.sha256);
    const numbers = [6]i32{
        @intCast(spec.sample_rate),
        window_seconds,
        max_windows,
        min_seconds,
        silence_dbfs,
        @backingInt(spec.converter),
    };
    for (numbers, 0..) |number, index|
        std.mem.writeInt(i32, encoded[4 + Sha256.digest_length + index * 4 ..][0..4], number, .little);
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(&encoded, &digest, .{});
    return digest;
}

pub const Embedding = struct {
    model: ModelId,
    windows: u8,
    scale: f32,
    values: [max_embedding_size]i8,

    pub fn quantise(model: ModelId, unit: []const f32, windows: u8) Embedding {
        std.debug.assert(unit.len == model.spec().embedding_size);
        var largest: f32 = 0;
        for (unit) |value| largest = @max(largest, @abs(value));
        std.debug.assert(largest > 0);
        const scale = largest / std.math.maxInt(i8);
        var values: [max_embedding_size]i8 = @splat(0);
        for (values[0..unit.len], unit) |*quantised, value| quantised.* = @intFromFloat(@round(value / scale));
        return .{ .model = model, .windows = windows, .scale = scale, .values = values };
    }

    pub fn vector(self: *const Embedding) []const i8 {
        return self.values[0..self.model.spec().embedding_size];
    }

    pub fn component(self: *const Embedding, index: usize) f32 {
        return @as(f32, @floatFromInt(self.vector()[index])) * self.scale;
    }
};

pub const Result = union(enum) {
    none: ModelId,
    embedding: Embedding,

    pub const header_size = 12;
    pub const max_encoded_size = header_size + max_embedding_size;
    const magic = "OREM";
    const version: u16 = 1;
    const has_embedding: u8 = 1 << 0;

    pub const Encoded = struct {
        bytes: [max_encoded_size]u8,
        len: usize,

        pub fn slice(self: *const Encoded) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    pub fn model(self: Result) ModelId {
        return switch (self) {
            .none => |id| id,
            .embedding => |embedding| embedding.model,
        };
    }

    pub fn encode(self: Result) Encoded {
        var encoded: Encoded = .{ .bytes = @splat(0), .len = self.model().spec().encodedSize() };
        const bytes = encoded.bytes[0..encoded.len];
        @memcpy(bytes[0..4], magic);
        std.mem.writeInt(u16, bytes[4..6], version, .little);
        switch (self) {
            .none => {},
            .embedding => |embedding| {
                bytes[6] = has_embedding;
                bytes[7] = embedding.windows;
                std.mem.writeInt(u32, bytes[8..12], @bitCast(embedding.scale), .little);
                @memcpy(bytes[header_size..], std.mem.sliceAsBytes(embedding.vector()));
            },
        }
        return encoded;
    }

    pub fn decode(expected: ModelId, bytes: []const u8) !Result {
        if (bytes.len != expected.spec().encodedSize() or !std.mem.eql(u8, bytes[0..4], magic))
            return error.InvalidAnalysisResult;
        if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.UnsupportedAnalysisResultVersion;
        if (bytes[6] & ~has_embedding != 0) return error.InvalidAnalysisResult;
        if (bytes[6] & has_embedding == 0) return .{ .none = expected };
        const scale: f32 = @bitCast(std.mem.readInt(u32, bytes[8..12], .little));
        if (bytes[7] == 0 or bytes[7] > max_windows or !std.math.isFinite(scale) or scale <= 0)
            return error.InvalidAnalysisResult;
        var embedding: Embedding = .{ .model = expected, .windows = bytes[7], .scale = scale, .values = @splat(0) };
        @memcpy(std.mem.sliceAsBytes(embedding.values[0 .. bytes.len - header_size]), bytes[header_size..]);
        return .{ .embedding = embedding };
    }
};

pub const WindowPlan = struct {
    starts: [max_windows]u64 = @splat(0),
    count: usize = 1,

    pub fn init(source_rate: u32, total_frames: ?u64) WindowPlan {
        const frames = total_frames orelse return .{};
        const rate: f64 = @floatFromInt(source_rate);
        const seconds = @as(f64, @floatFromInt(frames)) / rate;
        var plan: WindowPlan = .{};
        if (seconds >= max_windows * window_seconds) {
            plan.count = max_windows;
            for (&plan.starts, window_centres) |*start, centre| {
                const start_seconds = @min(@max(centre * seconds - window_seconds / 2, 0), seconds - window_seconds);
                start.* = @intFromFloat(start_seconds * rate);
            }
        } else {
            plan.count = @max(1, @as(usize, @intFromFloat(seconds / window_seconds)));
            for (plan.starts[0..plan.count], 0..) |*start, index|
                start.* = @as(u64, index) * window_seconds * source_rate;
        }
        return plan;
    }
};

pub const Embedder = struct {
    model: Model,
    front_end: *FrontEnd,

    pub fn id(self: Embedder) ModelId {
        return std.meta.activeTag(self.front_end.*);
    }
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    source_rate: u32,
    channels: usize,
    plan: WindowPlan,
    window_frames: usize,
    captured: []f32,
    filled: [max_windows]usize = @splat(0),
    frames_seen: u64 = 0,
    peak: f32 = 0,

    const Scratch = struct {
        samples: [max_window_samples]f32,
        features: [max_feature_count]f32,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        source_rate: u32,
        channels: u16,
        total_frames: ?u64,
    ) !Analyzer {
        if (channels == 0 or source_rate == 0) return error.InvalidAudioFormat;
        const plan: WindowPlan = .init(source_rate, total_frames);
        const window_frames = @as(usize, window_seconds) * source_rate;
        return .{
            .allocator = allocator,
            .source_rate = source_rate,
            .channels = channels,
            .plan = plan,
            .window_frames = window_frames,
            .captured = try allocator.alloc(f32, plan.count * window_frames),
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.allocator.free(self.captured);
        self.* = undefined;
    }

    pub fn process(self: *Analyzer, interleaved: []const f32) error{IncompleteAudioFrame}!void {
        if (interleaved.len % self.channels != 0) return error.IncompleteAudioFrame;
        const frames = interleaved.len / self.channels;
        const chunk_start = self.frames_seen;
        self.frames_seen += frames;
        for (self.plan.starts[0..self.plan.count], 0..) |start, index| {
            const filled = self.filled[index];
            const next = start + filled;
            if (filled == self.window_frames or next < chunk_start or next >= chunk_start + frames) continue;
            const skip: usize = @intCast(next - chunk_start);
            const take = @min(frames - skip, self.window_frames - filled);
            const target = self.captured[index * self.window_frames + filled ..][0..take];
            self.downmix(interleaved[skip * self.channels ..][0 .. take * self.channels], target);
            self.filled[index] = filled + take;
        }
    }

    fn downmix(self: *Analyzer, interleaved: []const f32, mono: []f32) void {
        const scale = 1.0 / @as(f32, @floatFromInt(self.channels));
        for (mono, 0..) |*sample, frame| {
            var sum: f32 = 0;
            for (interleaved[frame * self.channels ..][0..self.channels]) |value| sum += value;
            sample.* = if (std.math.isFinite(sum)) sum * scale else 0;
            self.peak = @max(self.peak, @abs(sample.*));
        }
    }

    pub fn windowSamples(
        self: *const Analyzer,
        index: usize,
        spec: *const ModelSpec,
        resampled: []f32,
    ) ![]const f32 {
        const source = self.captured[index * self.window_frames ..][0..self.filled[index]];
        if (self.source_rate == spec.sample_rate or source.len == 0) return source;
        var state = try resampler.SampleRate.init(spec.converter, self.source_rate, spec.sample_rate, 1);
        defer state.deinit();
        var consumed: usize = 0;
        var produced: usize = 0;
        while (produced < resampled.len) {
            const step = try state.process(source[consumed..], resampled[produced..], true);
            consumed += step.input_frames_consumed;
            produced += step.output_frames_produced;
            if (step.output_frames_produced == 0) break;
        }
        return resampled[0..produced];
    }

    pub fn finish(self: *const Analyzer, embedder: Embedder) !Result {
        const model = embedder.id();
        if (self.frames_seen < @as(u64, min_seconds) * self.source_rate or self.peak < silence_peak)
            return .{ .none = model };
        std.debug.assert(embedder.model.id == model);
        const spec = model.spec();
        const scratch = try self.allocator.create(Scratch);
        defer self.allocator.destroy(scratch);
        const features = scratch.features[0..spec.featureCount()];
        var sum_buffer: [max_embedding_size]f64 = @splat(0);
        const sum = sum_buffer[0..spec.embedding_size];
        var windows: u8 = 0;
        for (0..self.plan.count) |index| {
            const samples = try self.windowSamples(index, spec, scratch.samples[0..spec.windowSamples()]);
            if (samples.len == 0) continue;
            try embedder.front_end.melSpectrogram(samples, features);
            var output: [max_embedding_size]f32 = undefined;
            try embedder.model.embed(features, output[0..sum.len]);
            try addNormalised(sum, output[0..sum.len]);
            windows += 1;
        }
        var unit: [max_embedding_size]f32 = undefined;
        try normalise(sum, unit[0..sum.len]);
        return .{ .embedding = .quantise(model, unit[0..sum.len], windows) };
    }
};

fn addNormalised(sum: []f64, output: []const f32) error{EmbeddingFailed}!void {
    var unit: [max_embedding_size]f32 = undefined;
    var wide: [max_embedding_size]f64 = undefined;
    for (wide[0..output.len], output) |*target, value| target.* = value;
    try normalise(wide[0..output.len], unit[0..output.len]);
    for (sum, unit[0..output.len]) |*total, value| total.* += value;
}

fn normalise(vector: []const f64, unit: []f32) error{EmbeddingFailed}!void {
    var square: f64 = 0;
    for (vector) |value| square += value * value;
    const length = @sqrt(square);
    if (!std.math.isFinite(length) or length == 0) return error.EmbeddingFailed;
    for (unit, vector) |*target, value| target.* = @floatCast(value / length);
}

const testing = std.testing;

const exact_above_db = -60.0;
const exact_tolerance_db = 0.05;
const floor_tolerance_db = 0.2;
const maest_tolerance = 0.0001;
const min_reference_cosine = 0.995;

const clap_parameter_hash = "D9194D8DF5B32D7660AFFE47B3178383B538327B1FC5F1D654B626272D38D905";
const maest_parameter_hash = "6A89F6A7C38041025E72DD12DD1A8E325E07D94291F2FBCED4020ACC261AC5E7";

fn referenceFrames(model: ModelId) [7]usize {
    return switch (model) {
        .clap_htsat_unfused => .{ 0, 1, 2, 500, 998, 999, 1000 },
        .discogs_maest => .{ 0, 1, 2, 313, 623, 624, 625 },
    };
}

fn melTolerance(model: ModelId, expected: f32) f32 {
    return switch (model) {
        .clap_htsat_unfused => if (expected > exact_above_db) exact_tolerance_db else floor_tolerance_db,
        .discogs_maest => maest_tolerance,
    };
}

const Signal = enum {
    sine440,
    chirp,
    mix,
    sine440_3s,

    fn sampleCount(self: Signal, model: ModelId) usize {
        const seconds: usize = if (self == .sine440_3s) 3 else window_seconds;
        return seconds * model.spec().sample_rate;
    }

    fn melFrames(self: Signal, model: ModelId) []const u8 {
        return switch (model) {
            .clap_htsat_unfused => switch (self) {
                .sine440 => @embedFile("testdata/embedding/sine440_mel_frames.f32"),
                .chirp => @embedFile("testdata/embedding/chirp_mel_frames.f32"),
                .mix => @embedFile("testdata/embedding/mix_mel_frames.f32"),
                .sine440_3s => @embedFile("testdata/embedding/sine440_3s_mel_frames.f32"),
            },
            .discogs_maest => switch (self) {
                .sine440 => @embedFile("testdata/embedding/sine440_maest_mel_frames.f32"),
                .chirp => @embedFile("testdata/embedding/chirp_maest_mel_frames.f32"),
                .mix => @embedFile("testdata/embedding/mix_maest_mel_frames.f32"),
                .sine440_3s => @embedFile("testdata/embedding/sine440_3s_maest_mel_frames.f32"),
            },
        };
    }

    fn embedding(self: Signal, model: ModelId) []const u8 {
        return switch (model) {
            .clap_htsat_unfused => switch (self) {
                .sine440 => @embedFile("testdata/embedding/sine440_emb_int8.f32"),
                .chirp => @embedFile("testdata/embedding/chirp_emb_int8.f32"),
                .mix => @embedFile("testdata/embedding/mix_emb_int8.f32"),
                .sine440_3s => @embedFile("testdata/embedding/sine440_3s_emb_int8.f32"),
            },
            .discogs_maest => switch (self) {
                .sine440 => @embedFile("testdata/embedding/sine440_maest_emb_int8.f32"),
                .chirp => @embedFile("testdata/embedding/chirp_maest_emb_int8.f32"),
                .mix => @embedFile("testdata/embedding/mix_maest_emb_int8.f32"),
                .sine440_3s => @embedFile("testdata/embedding/sine440_3s_maest_emb_int8.f32"),
            },
        };
    }

    fn value(self: Signal, sample_rate: u32, index: usize) f32 {
        const time = @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(sample_rate));
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

    fn features(self: Signal, front_end: *FrontEnd) ![]f32 {
        const model = std.meta.activeTag(front_end.*);
        const samples = try testing.allocator.alloc(f32, self.sampleCount(model));
        defer testing.allocator.free(samples);
        for (samples, 0..) |*sample, index| sample.* = self.value(model.spec().sample_rate, index);
        const result = try testing.allocator.alloc(f32, model.spec().featureCount());
        errdefer testing.allocator.free(result);
        try front_end.melSpectrogram(samples, result);
        return result;
    }
};

fn storedFloat(bytes: []const u8, index: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little));
}

pub fn testModelPath(model: ModelId) ![]const u8 {
    if (!enabled) return error.SkipZigTest;
    return switch (model) {
        .clap_htsat_unfused => build_options.embedding_test_model,
        .discogs_maest => build_options.maest_embedding_test_model,
    } orelse error.SkipZigTest;
}

fn expectPlan(seconds: f64, expected_seconds: []const f64) !void {
    const rate = 44_100;
    const plan: WindowPlan = .init(rate, @intFromFloat(seconds * rate));
    try testing.expectEqual(expected_seconds.len, plan.count);
    for (expected_seconds, plan.starts[0..plan.count]) |expected, start|
        try testing.expectEqual(@as(u64, @intFromFloat(expected * rate)), start);
}

test "windowPlan_knownLength_followsReferenceRule" {
    try expectPlan(200, &.{ 45, 95, 145 });
    try expectPlan(30, &.{ 2.5, 10, 17.5 });
    try expectPlan(29.9, &.{ 0, 10 });
    try expectPlan(12, &.{0});
    try expectPlan(4, &.{0});
    try expectPlan(0.5, &.{0});
}

test "windowPlan_unknownLength_takesFirstWindow" {
    const plan: WindowPlan = .init(44_100, null);
    try testing.expectEqual(@as(usize, 1), plan.count);
    try testing.expectEqual(@as(u64, 0), plan.starts[0]);
}

const TestTone = struct {
    source_rate: u32,
    channels: u16,
    seconds: f64,
    amplitude: f32,

    fn feed(self: TestTone, analyzer: *Analyzer) !void {
        const chunk_frames = 4096;
        const total: usize = @intFromFloat(self.seconds * @as(f64, @floatFromInt(self.source_rate)));
        const chunk = try testing.allocator.alloc(f32, chunk_frames * self.channels);
        defer testing.allocator.free(chunk);
        var frame: usize = 0;
        while (frame < total) {
            const take: usize = @min(chunk_frames, total - frame);
            for (0..take) |offset| {
                const time = @as(f64, @floatFromInt(frame + offset)) / @as(f64, @floatFromInt(self.source_rate));
                const tone = @sin(2.0 * std.math.pi * time * (220 + 40 * @floor(time / 5)));
                const sample: f32 = @floatCast(self.amplitude * tone * (0.6 + 0.4 * @sin(2.0 * std.math.pi * time * 3)));
                for (chunk[offset * self.channels ..][0..self.channels]) |*value| value.* = sample;
            }
            try analyzer.process(chunk[0 .. take * self.channels]);
            frame += take;
        }
    }
};

fn expectNoEmbedding(tone: TestTone) !void {
    for (std.enums.values(ModelId)) |model| {
        var front_end = try FrontEnd.init(testing.allocator, model);
        defer front_end.deinit();
        const total: u64 = @intFromFloat(tone.seconds * @as(f64, @floatFromInt(tone.source_rate)));
        var analyzer = try Analyzer.init(testing.allocator, tone.source_rate, tone.channels, total);
        defer analyzer.deinit();
        try tone.feed(&analyzer);
        const result = try analyzer.finish(.{ .model = undefined, .front_end = &front_end });
        try testing.expectEqual(Result{ .none = model }, result);
    }
}

test "finish_silentInput_storesNoEmbedding" {
    try expectNoEmbedding(.{ .source_rate = 44_100, .channels = 2, .seconds = 35, .amplitude = 0 });
    try expectNoEmbedding(.{ .source_rate = 44_100, .channels = 2, .seconds = 35, .amplitude = 0.5e-4 });
}

test "finish_inputUnderOneSecond_storesNoEmbedding" {
    try expectNoEmbedding(.{ .source_rate = 48_000, .channels = 1, .seconds = 0.5, .amplitude = 0.5 });
}

test "process_overlappingWindows_captureTheirOwnFrames" {
    const rate = 1000;
    var analyzer = try Analyzer.init(testing.allocator, rate, 2, 30 * rate);
    defer analyzer.deinit();
    var chunk: [2 * 700]f32 = undefined;
    var frame: usize = 0;
    while (frame < 30 * rate) : (frame += 700) {
        const take: usize = @min(700, 30 * rate - frame);
        for (0..take) |offset| {
            chunk[2 * offset] = @floatFromInt(frame + offset);
            chunk[2 * offset + 1] = @floatFromInt(frame + offset + 2);
        }
        try analyzer.process(chunk[0 .. 2 * take]);
    }
    for ([_]usize{ 2500, 10_000, 17_500 }, 0..) |start, index| {
        const window = analyzer.captured[index * analyzer.window_frames ..][0..analyzer.filled[index]];
        try testing.expectEqual(@as(usize, 10 * rate), window.len);
        try testing.expectEqual(@as(f32, @floatFromInt(start + 1)), window[0]);
        try testing.expectEqual(@as(f32, @floatFromInt(start + 10 * rate)), window[window.len - 1]);
    }
}

fn testUnitVector(model: ModelId, seed: u64, unit: *[max_embedding_size]f32) []const f32 {
    const size = model.spec().embedding_size;
    var random: std.Random.DefaultPrng = .init(seed);
    var wide: [max_embedding_size]f64 = undefined;
    for (wide[0..size]) |*value| value.* = random.random().floatNorm(f64);
    normalise(wide[0..size], unit[0..size]) catch unreachable;
    return unit[0..size];
}

test "quantise_unitVector_keepsItsDirection" {
    for (std.enums.values(ModelId)) |model| {
        var buffer: [max_embedding_size]f32 = undefined;
        const unit = testUnitVector(model, 7, &buffer);
        const embedding: Embedding = .quantise(model, unit, 3);
        try testing.expectEqual(unit.len, embedding.vector().len);
        var largest: i8 = 0;
        var dot: f64 = 0;
        var square: f64 = 0;
        for (unit, 0..) |value, index| {
            largest = @max(largest, @as(i8, @intCast(@abs(embedding.values[index]))));
            dot += @as(f64, value) * embedding.component(index);
            square += @as(f64, embedding.component(index)) * embedding.component(index);
        }
        try testing.expectEqual(@as(i8, 127), largest);
        try testing.expect(dot / @sqrt(square) >= 0.999);
    }
}

test "encode_embeddingAndNone_decodeToThemselves" {
    for (std.enums.values(ModelId), [_]usize{ 524, 780 }) |model, encoded_size| {
        var buffer: [max_embedding_size]f32 = undefined;
        const stored: Result = .{ .embedding = .quantise(model, testUnitVector(model, 11, &buffer), 2) };
        const encoded = stored.encode();
        const bytes = encoded.slice();
        try testing.expectEqual(encoded_size, bytes.len);
        try testing.expectEqualStrings("OREM", bytes[0..4]);
        try testing.expectEqual(@as(u8, 2), bytes[7]);
        try testing.expectEqual(stored.embedding.values[0], @as(i8, @bitCast(bytes[12])));
        const decoded = try Result.decode(model, bytes);
        try testing.expectEqual(model, decoded.embedding.model);
        try testing.expectEqual(stored.embedding.scale, decoded.embedding.scale);
        try testing.expectEqual(stored.embedding.windows, decoded.embedding.windows);
        try testing.expectEqualSlices(i8, &stored.embedding.values, &decoded.embedding.values);
        try testing.expectEqualSlices(u8, bytes, decoded.encode().slice());

        const none = (Result{ .none = model }).encode();
        try testing.expectEqual(encoded_size, none.len);
        try testing.expectEqual(Result{ .none = model }, try Result.decode(model, none.slice()));
    }
}

test "decode_resultOfTheOtherModel_isRefused" {
    for (std.enums.values(ModelId), [_]ModelId{ .discogs_maest, .clap_htsat_unfused }) |model, other| {
        var buffer: [max_embedding_size]f32 = undefined;
        const stored: Result = .{ .embedding = .quantise(model, testUnitVector(model, 17, &buffer), 1) };
        try testing.expectError(error.InvalidAnalysisResult, Result.decode(other, stored.encode().slice()));
    }
}

test "decode_malformedOrNewerEncoding_isRefused" {
    const model: ModelId = .clap_htsat_unfused;
    var buffer: [max_embedding_size]f32 = undefined;
    const encoded = (Result{ .embedding = .quantise(model, testUnitVector(model, 13, &buffer), 1) }).encode();
    const valid = encoded.bytes[0..comptime clap_spec.encodedSize()].*;
    try testing.expectError(error.InvalidAnalysisResult, Result.decode(model, valid[0 .. valid.len - 1]));
    var bytes = valid;
    bytes[0] = 'X';
    try testing.expectError(error.InvalidAnalysisResult, Result.decode(model, &bytes));
    bytes = valid;
    bytes[4] = 2;
    try testing.expectError(error.UnsupportedAnalysisResultVersion, Result.decode(model, &bytes));
    bytes = valid;
    bytes[6] = 3;
    try testing.expectError(error.InvalidAnalysisResult, Result.decode(model, &bytes));
    bytes = valid;
    bytes[7] = max_windows + 1;
    try testing.expectError(error.InvalidAnalysisResult, Result.decode(model, &bytes));
    bytes = valid;
    @memset(bytes[8..12], 0);
    try testing.expectError(error.InvalidAnalysisResult, Result.decode(model, &bytes));
}

test "parameterHash_eachModel_hasItsPinnedValue" {
    for (std.enums.values(ModelId), [_][]const u8{ clap_parameter_hash, maest_parameter_hash }) |model, pinned| {
        const hex = std.fmt.bytesToHex(parameterHash(model), .upper);
        try testing.expectEqualStrings(pinned, &hex);
    }
    try testing.expect(!std.mem.eql(u8, clap_parameter_hash, maest_parameter_hash));
}

test "spec_eachModel_statesItsGraphShape" {
    const clap = ModelId.clap_htsat_unfused.spec();
    try testing.expectEqual(@as(u32, 48_000), clap.sample_rate);
    try testing.expectEqual(@as(u32, 1001), clap.frame_count);
    try testing.expectEqual(@as(u32, 64), clap.band_count);
    try testing.expectEqual(@as(u16, 512), clap.embedding_size);
    try testing.expectEqualStrings(
        "https://github.com/evanriley/orca/releases/download/model-clap-int8-1/clap_audio_int8.onnx",
        clap.url,
    );
    const maest = ModelId.discogs_maest.spec();
    try testing.expectEqual(@as(u32, 16_000), maest.sample_rate);
    try testing.expectEqual(@as(u32, 626), maest.frame_count);
    try testing.expectEqual(@as(u32, 96), maest.band_count);
    try testing.expectEqual(@as(u16, 768), maest.embedding_size);
    try testing.expectEqualStrings(
        "https://github.com/evanriley/orca/releases/download/model-maest-int8-1/maest_audio_int8.onnx",
        maest.url,
    );
}

fn expectThreeWindowUnitVector(model_id: ModelId) !void {
    const model_path = try testModelPath(model_id);
    var model = try Model.open(testing.allocator, testing.io, model_path);
    defer model.deinit();
    var front_end = try FrontEnd.init(testing.allocator, model.id);
    defer front_end.deinit();
    const tone: TestTone = .{ .source_rate = 44_100, .channels = 2, .seconds = 35, .amplitude = 0.5 };
    var analyzer = try Analyzer.init(testing.allocator, tone.source_rate, tone.channels, 35 * tone.source_rate);
    defer analyzer.deinit();
    try tone.feed(&analyzer);
    const result = try analyzer.finish(.{ .model = model, .front_end = &front_end });

    try testing.expectEqual(model_id, result.embedding.model);
    try testing.expectEqual(@as(u8, 3), result.embedding.windows);
    var square: f64 = 0;
    for (0..model_id.spec().embedding_size) |index|
        square += @as(f64, result.embedding.component(index)) * result.embedding.component(index);
    try testing.expectApproxEqAbs(@as(f64, 1), @sqrt(square), 0.01);
}

test "finish_thirtyFiveSecondSignal_embedsThreeWindowsAsUnitVector" {
    try expectThreeWindowUnitVector(.clap_htsat_unfused);
}

test "finish_thirtyFiveSecondSignalWithMaest_embedsThreeWindowsAsUnitVector" {
    try expectThreeWindowUnitVector(.discogs_maest);
}

fn expectReferenceMelFrames(model: ModelId) !void {
    const band_count = model.spec().band_count;
    var front_end = try FrontEnd.init(testing.allocator, model);
    defer front_end.deinit();
    for (std.enums.values(Signal)) |signal| {
        const features = try signal.features(&front_end);
        defer testing.allocator.free(features);
        const stored = signal.melFrames(model);
        const reference_frames = referenceFrames(model);
        try testing.expectEqual(reference_frames.len * band_count * 4, stored.len);
        for (reference_frames, 0..) |frame, row| {
            for (0..band_count) |band| {
                const expected = storedFloat(stored, row * band_count + band);
                try testing.expectApproxEqAbs(expected, features[frame * band_count + band], melTolerance(model, expected));
            }
        }
    }
}

test "melSpectrogram_referenceSignals_matchesReferenceExtractor" {
    try expectReferenceMelFrames(.clap_htsat_unfused);
}

test "melSpectrogram_maestReferenceSignals_matchesReferenceExtractor" {
    try expectReferenceMelFrames(.discogs_maest);
}

test "melSpectrogram_shortWindow_repeatsThenZeroFills" {
    const repeat_frames = 400;
    const spec = ModelId.clap_htsat_unfused.spec();
    const band_count = spec.band_count;
    var front_end = try FrontEnd.init(testing.allocator, .clap_htsat_unfused);
    defer front_end.deinit();
    const samples = try testing.allocator.alloc(f32, repeat_frames * clap_recipe.hop_size);
    defer testing.allocator.free(samples);
    for (samples, 0..) |*sample, index| sample.* = Signal.sine440.value(spec.sample_rate, index);
    const features = try testing.allocator.alloc(f32, spec.featureCount());
    defer testing.allocator.free(features);
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

test "melSpectrogram_maestShortWindow_isSilentAfterItsOwnFrames" {
    const spec = ModelId.discogs_maest.spec();
    const band_count = spec.band_count;
    var front_end = try FrontEnd.init(testing.allocator, .discogs_maest);
    defer front_end.deinit();
    const features = try Signal.sine440_3s.features(&front_end);
    defer testing.allocator.free(features);

    const own_frames = 1 + Signal.sine440_3s.sampleCount(.discogs_maest) / maest_recipe.hop_size;
    const silence: f32 = @floatCast(-maest_recipe.level.log_compressed.mean /
        (2.0 * maest_recipe.level.log_compressed.deviation));
    var loudest: f32 = silence;
    for (features[(own_frames - 2) * band_count ..][0..band_count]) |level| loudest = @max(loudest, level);
    try testing.expect(loudest > silence + 0.5);
    for (features[own_frames * band_count ..]) |level| try testing.expectEqual(silence, level);
    try testing.expectEqual((spec.frame_count - own_frames) * band_count, features[own_frames * band_count ..].len);
}

test "melSpectrogram_emptyOrOverlongWindow_isRefused" {
    for (std.enums.values(ModelId)) |model| {
        var front_end = try FrontEnd.init(testing.allocator, model);
        defer front_end.deinit();
        const features = try testing.allocator.alloc(f32, model.spec().featureCount());
        defer testing.allocator.free(features);
        const samples = try testing.allocator.alloc(f32, model.spec().windowSamples() + 1);
        defer testing.allocator.free(samples);
        @memset(samples, 0);
        try testing.expectError(error.EmptyWindow, front_end.melSpectrogram(samples[0..0], features));
        try testing.expectError(error.WindowTooLong, front_end.melSpectrogram(samples, features));
    }
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

fn expectFlippedByteMismatch(model: ModelId) !void {
    const model_path = try testModelPath(model);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, model_path, testing.allocator, .limited(model.spec().size + 1));
    defer testing.allocator.free(bytes);
    bytes[bytes.len / 2] ^= 1;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(testing.io, .{ .sub_path = "model.onnx", .data = bytes });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/model.onnx", .{temporary.sub_path});
    defer testing.allocator.free(path);
    try testing.expectError(error.EmbeddingModelMismatch, Model.open(testing.allocator, testing.io, path));
    try testing.expectError(error.EmbeddingModelMismatch, Model.verify(testing.allocator, testing.io, path));
}

test "open_modelWithOneByteFlipped_reportsMismatch" {
    try expectFlippedByteMismatch(.clap_htsat_unfused);
}

test "open_maestModelWithOneByteFlipped_reportsMismatch" {
    try expectFlippedByteMismatch(.discogs_maest);
}

fn expectRecognised(expected: ModelId) !void {
    const model_path = try testModelPath(expected);
    try testing.expectEqual(expected, try Model.verify(testing.allocator, testing.io, model_path));
    var model = try Model.open(testing.allocator, testing.io, model_path);
    defer model.deinit();
    try testing.expectEqual(expected, model.id);
}

test "verify_clapModelFile_isRecognisedAsClap" {
    try expectRecognised(.clap_htsat_unfused);
}

test "verify_maestModelFile_isRecognisedAsMaest" {
    try expectRecognised(.discogs_maest);
}

fn expectReferenceEmbeddings(model_id: ModelId) !void {
    const model_path = try testModelPath(model_id);
    const embedding_size = model_id.spec().embedding_size;
    var model = try Model.open(testing.allocator, testing.io, model_path);
    defer model.deinit();
    var front_end = try FrontEnd.init(testing.allocator, model.id);
    defer front_end.deinit();
    for (std.enums.values(Signal)) |signal| {
        const features = try signal.features(&front_end);
        defer testing.allocator.free(features);
        var buffer: [max_embedding_size]f32 = undefined;
        const embedding = buffer[0..embedding_size];
        try model.embed(features, embedding);

        const stored = signal.embedding(model_id);
        try testing.expectEqual(@as(usize, embedding_size) * 4, stored.len);
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

test "embed_referenceSignals_matchesReferenceEmbeddings" {
    try expectReferenceEmbeddings(.clap_htsat_unfused);
}

test "embed_maestReferenceSignals_matchesReferenceEmbeddings" {
    try expectReferenceEmbeddings(.discogs_maest);
}

test "embed_severalThreadsOnOneModel_agree" {
    const model_path = try testModelPath(.clap_htsat_unfused);
    const embedding_size = comptime ModelId.clap_htsat_unfused.spec().embedding_size;
    var model = try Model.open(testing.allocator, testing.io, model_path);
    defer model.deinit();
    var front_end = try FrontEnd.init(testing.allocator, model.id);
    defer front_end.deinit();
    const features = try Signal.mix.features(&front_end);
    defer testing.allocator.free(features);

    const Worker = struct {
        fn run(shared: Model, input: []const f32, output: []f32, failed: *bool) void {
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
