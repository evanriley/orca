const std = @import("std");

pub const Parameters = struct {
    silence_threshold: f32 = 0.0001,
    replay_gain_target_lufs: f32 = -18.0,
    waveform_buckets: u32 = 1024,
};

pub const WaveformBucket = extern struct {
    minimum: f32 = 1,
    maximum: f32 = -1,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    integrated_lufs: ?f32,
    replay_gain_db: ?f32,
    sample_peak: f32,
    rms: f32,
    clipped_samples: u64,
    silent_frames: u64,
    leading_silence_frames: u64,
    trailing_silence_frames: u64,
    waveform: []WaveformBucket,

    pub fn deinit(self: Result) void {
        self.allocator.free(self.waveform);
    }
};

const Biquad = struct {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    z1: f64 = 0,
    z2: f64 = 0,

    fn process(self: *Biquad, input: f64) f64 {
        const output = self.b0 * input + self.z1;
        self.z1 = self.b1 * input - self.a1 * output + self.z2;
        self.z2 = self.b2 * input - self.a2 * output;
        return output;
    }
};

const ChannelFilter = struct {
    shelf: Biquad,
    high_pass: Biquad,

    fn process(self: *ChannelFilter, input: f64) f64 {
        return self.high_pass.process(self.shelf.process(input));
    }
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    parameters: Parameters,
    sample_rate: u32,
    channels: u16,
    expected_frames: ?u64,
    filters: []ChannelFilter,
    waveform: []WaveformBucket,
    block_energies: std.ArrayList(f64) = .empty,
    loudness_window: []f64,
    loudness_window_index: usize = 0,
    loudness_window_energy: f64 = 0,
    loudness_step_frames: u64,
    sum_squares: f64 = 0,
    sample_count: u64 = 0,
    frame_index: u64 = 0,
    peak: f32 = 0,
    clipped_samples: u64 = 0,
    silent_frames: u64 = 0,
    leading_silence_frames: u64 = 0,
    trailing_silence_frames: u64 = 0,
    found_audible: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        sample_rate: u32,
        channels: u16,
        expected_frames: ?u64,
        parameters: Parameters,
    ) !Analyzer {
        if (sample_rate == 0 or channels == 0 or channels > 32)
            return error.InvalidAudioFormat;
        if (parameters.waveform_buckets == 0) return error.InvalidAnalysisParameters;
        const filters = try allocator.alloc(ChannelFilter, channels);
        errdefer allocator.free(filters);
        for (filters) |*filter| filter.* = .{
            .shelf = highShelf(sample_rate),
            .high_pass = highPass(sample_rate),
        };
        const waveform = try allocator.alloc(WaveformBucket, parameters.waveform_buckets);
        errdefer allocator.free(waveform);
        for (waveform) |*bucket| bucket.* = .{};
        const loudness_window_frames = @max(1, @as(usize, sample_rate) * 2 / 5);
        const loudness_window = try allocator.alloc(f64, loudness_window_frames);
        @memset(loudness_window, 0);
        return .{
            .allocator = allocator,
            .parameters = parameters,
            .sample_rate = sample_rate,
            .channels = channels,
            .expected_frames = expected_frames,
            .filters = filters,
            .waveform = waveform,
            .loudness_window = loudness_window,
            .loudness_step_frames = @max(1, @as(u64, sample_rate) / 10),
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.allocator.free(self.filters);
        self.allocator.free(self.waveform);
        self.allocator.free(self.loudness_window);
        self.block_energies.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn process(self: *Analyzer, samples: []const f32) !void {
        if (samples.len % self.channels != 0) return error.IncompleteAudioFrame;
        var sample_index: usize = 0;
        while (sample_index < samples.len) : (self.frame_index += 1) {
            var frame_peak: f32 = 0;
            var weighted_energy: f64 = 0;
            for (0..self.channels) |channel| {
                const sample = samples[sample_index];
                sample_index += 1;
                const magnitude = @abs(sample);
                frame_peak = @max(frame_peak, magnitude);
                self.peak = @max(self.peak, magnitude);
                if (magnitude >= 1.0) self.clipped_samples += 1;
                self.sum_squares += @as(f64, sample) * sample;
                self.sample_count += 1;
                const weighted = self.filters[channel].process(sample);
                weighted_energy += weighted * weighted;
            }
            if (frame_peak <= self.parameters.silence_threshold) {
                self.silent_frames += 1;
                self.trailing_silence_frames += 1;
                if (!self.found_audible) self.leading_silence_frames += 1;
            } else {
                self.found_audible = true;
                self.trailing_silence_frames = 0;
            }
            const frame_energy = weighted_energy / self.channels;
            self.loudness_window_energy -= self.loudness_window[self.loudness_window_index];
            self.loudness_window_energy += frame_energy;
            self.loudness_window[self.loudness_window_index] = frame_energy;
            self.loudness_window_index = (self.loudness_window_index + 1) % self.loudness_window.len;
            const completed_frames = self.frame_index + 1;
            if (completed_frames >= self.loudness_window.len and
                (completed_frames - self.loudness_window.len) % self.loudness_step_frames == 0)
            {
                try self.block_energies.append(
                    self.allocator,
                    self.loudness_window_energy / @as(f64, @floatFromInt(self.loudness_window.len)),
                );
            }
            self.updateWaveform(samples[sample_index - self.channels .. sample_index]);
        }
    }

    pub fn finish(self: *Analyzer) !Result {
        if (self.sample_count == 0) return error.NoAudioSamples;
        const loudness = integratedLoudness(self.block_energies.items);
        const waveform = self.waveform;
        for (waveform) |*bucket| {
            if (bucket.minimum > bucket.maximum) bucket.* = .{ .minimum = 0, .maximum = 0 };
        }
        const result: Result = .{
            .allocator = self.allocator,
            .integrated_lufs = loudness,
            .replay_gain_db = if (loudness) |value|
                self.parameters.replay_gain_target_lufs - value
            else
                null,
            .sample_peak = self.peak,
            .rms = @floatCast(@sqrt(self.sum_squares / @as(f64, @floatFromInt(self.sample_count)))),
            .clipped_samples = self.clipped_samples,
            .silent_frames = self.silent_frames,
            .leading_silence_frames = self.leading_silence_frames,
            .trailing_silence_frames = self.trailing_silence_frames,
            .waveform = waveform,
        };
        self.waveform = &.{};
        return result;
    }

    fn updateWaveform(self: *Analyzer, frame: []const f32) void {
        const bucket_index: usize = if (self.expected_frames) |total|
            @intCast(@min(
                self.waveform.len - 1,
                self.frame_index * self.waveform.len / @max(1, total),
            ))
        else
            @intCast(@min(self.waveform.len - 1, self.frame_index / 1024));
        var bucket = &self.waveform[bucket_index];
        for (frame) |sample| {
            bucket.minimum = @min(bucket.minimum, sample);
            bucket.maximum = @max(bucket.maximum, sample);
        }
    }
};

fn integratedLoudness(energies: []const f64) ?f32 {
    var absolute_sum: f64 = 0;
    var absolute_count: usize = 0;
    for (energies) |energy| {
        if (energy > 0 and -0.691 + 10 * @log10(energy) >= -70) {
            absolute_sum += energy;
            absolute_count += 1;
        }
    }
    if (absolute_count == 0) return null;
    const absolute_mean = absolute_sum / @as(f64, @floatFromInt(absolute_count));
    const relative_gate = -0.691 + 10 * @log10(absolute_mean) - 10;
    var gated_sum: f64 = 0;
    var gated_count: usize = 0;
    for (energies) |energy| {
        if (energy > 0 and -0.691 + 10 * @log10(energy) >= relative_gate) {
            gated_sum += energy;
            gated_count += 1;
        }
    }
    if (gated_count == 0) return null;
    return @floatCast(-0.691 + 10 * @log10(gated_sum / @as(f64, @floatFromInt(gated_count))));
}

fn highShelf(sample_rate: u32) Biquad {
    const f0: f64 = 1681.974450955533;
    const gain: f64 = 3.999843853973347;
    const q: f64 = 0.7071752369554196;
    const k = @tan(std.math.pi * f0 / @as(f64, @floatFromInt(sample_rate)));
    const vh = std.math.pow(f64, 10, gain / 20);
    const vb = std.math.pow(f64, vh, 0.4996667741545416);
    const a0 = 1 + k / q + k * k;
    return .{
        .b0 = (vh + vb * k / q + k * k) / a0,
        .b1 = 2 * (k * k - vh) / a0,
        .b2 = (vh - vb * k / q + k * k) / a0,
        .a1 = 2 * (k * k - 1) / a0,
        .a2 = (1 - k / q + k * k) / a0,
    };
}

fn highPass(sample_rate: u32) Biquad {
    const f0: f64 = 38.13547087602444;
    const q: f64 = 0.5003270373238773;
    const k = @tan(std.math.pi * f0 / @as(f64, @floatFromInt(sample_rate)));
    const a0 = 1 + k / q + k * k;
    return .{
        .b0 = 1 / a0,
        .b1 = -2 / a0,
        .b2 = 1 / a0,
        .a1 = 2 * (k * k - 1) / a0,
        .a2 = (1 - k / q + k * k) / a0,
    };
}

test "streaming diagnostics measure loudness peak clipping silence and waveform" {
    const allocator = std.testing.allocator;
    const sample_rate = 48_000;
    var samples: [sample_rate * 2]f32 = undefined;
    for (0..sample_rate) |frame| {
        const value: f32 = if (frame < 480 or frame >= sample_rate - 960)
            0
        else
            0.5 * @cos(2 * std.math.pi * 1000 * @as(f32, @floatFromInt(frame)) / sample_rate);
        samples[frame * 2] = value;
        samples[frame * 2 + 1] = value;
    }
    samples[20_000] = 1.1;
    var analyzer = try Analyzer.init(allocator, sample_rate, 2, sample_rate, .{
        .waveform_buckets = 100,
    });
    defer analyzer.deinit();
    try analyzer.process(samples[0..20_000]);
    try analyzer.process(samples[20_000..]);
    const result = try analyzer.finish();
    defer result.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), result.sample_peak, 0.0001);
    try std.testing.expectEqual(@as(u64, 1), result.clipped_samples);
    try std.testing.expectEqual(@as(u64, 480), result.leading_silence_frames);
    try std.testing.expectEqual(@as(u64, 960), result.trailing_silence_frames);
    try std.testing.expect(result.integrated_lufs.? > -20 and result.integrated_lufs.? < -5);
    try std.testing.expectEqual(@as(usize, 100), result.waveform.len);
}
