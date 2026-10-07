//! Tempo, key, onset rate and spectral centroid estimated from the first ten
//! minutes of a file, downmixed to mono and resampled to 11025 Hz by a
//! polyphase Kaiser-windowed sinc filter. The spectrum comes from the KissFFT
//! that Chromaprint vendors and liborca already compiles.

const std = @import("std");

const KissComplex = extern struct { r: f32, i: f32 };
extern fn kiss_fftr_alloc(nfft: c_int, inverse_fft: c_int, mem: ?*anyopaque, lenmem: ?*usize) ?*anyopaque;
extern fn kiss_fftr(cfg: *anyopaque, timedata: [*]const f32, freqdata: [*]KissComplex) void;

pub const cache_kind: u8 = 6;
pub const algorithm_id = "orca.audio-features";
pub const algorithm_version: u32 = 1;

pub const analysis_rate: u32 = 11_025;
const window_size = 2048;
const hop_size = 512;
const bin_count = window_size / 2 + 1;
const frames_per_second = @as(f64, analysis_rate) / hop_size;
const spectrum_scale: f64 = 2.0 / @as(f64, window_size / 2);

const mel_band_count = 128;
const max_mel_band_bins = 64;
const mel_power_floor = 1e-10;
const audible_mean_square = 1e-8;

const pitch_window_size = 8192;
const pitch_hop_size = 4096;
const pitch_bin_count = pitch_window_size / 2 + 1;
const pitch_steps_per_semitone = 3;
const pitch_lowest_midi = 28;
const pitch_step_count = 216;
const no_pitch_step: u8 = 0xff;
const harmonic_count = 4;
const harmonic_decay = 0.8;
const chroma_low_hz = 55.0;
const chroma_high_hz = 2000.0;

const tempogram_window_frames = 8 * analysis_rate / hop_size;
const tempogram_stride = 4;
const tempogram_lag_limit = 51;
const tempogram_energy_floor = 1.0;
const min_tempo_bpm = 50.0;
const max_tempo_bpm = 220.0;
const tempo_prior_centre_bpm = 130.0;
const tempo_prior_octaves = 0.6;
const tempo_double_lag_weight = 0.5;
const min_tempo_confidence = 0.15;

const onset_delta = 0.07;
const onset_average_radius = 2;
const onset_min_gap_frames = 2;

const chunk_frames = 4096;

pub const Parameters = struct {
    const default_stopband_db = 60;

    /// The resampling filter's stopband attenuation. Its passband ends at 80 %
    /// of the lower Nyquist frequency and its stopband starts there.
    stopband_db: u32 = default_stopband_db,
    max_seconds: u32 = 600,
    min_seconds: u32 = 15,
};

const max_window_seconds = 3600;
const min_stopband_db = 20;
const max_stopband_db = 120;

pub fn parameterHash(parameters: Parameters) [32]u8 {
    var encoded: [16]u8 = undefined;
    @memcpy(encoded[0..4], "kfir");
    std.mem.writeInt(u32, encoded[4..8], parameters.stopband_db, .little);
    std.mem.writeInt(u32, encoded[8..12], parameters.max_seconds, .little);
    std.mem.writeInt(u32, encoded[12..16], parameters.min_seconds, .little);
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(&encoded, &digest, .{});
    return digest;
}

pub const Mode = enum(u8) { major = 0, minor = 1 };

pub const Tempo = struct {
    bpm: f64,
    confidence: f64,
};

pub const Key = struct {
    /// Pitch class of the tonic, C = 0 through B = 11.
    pitch: u8,
    mode: Mode,
    confidence: f64,
};

pub const Features = struct {
    analysed_ms: u32,
    tempo: ?Tempo = null,
    key: ?Key = null,
    onset_rate: ?f64 = null,
    centroid_hz: ?f64 = null,

    pub const encoded_size = 40;
    const magic = "ORAF";
    const version: u16 = 1;
    const has_tempo: u16 = 1 << 0;
    const has_key: u16 = 1 << 1;
    const has_onset_rate: u16 = 1 << 2;
    const has_centroid: u16 = 1 << 3;
    const milli = 1_000.0;
    const micro = 1_000_000.0;

    pub fn encode(self: Features) [encoded_size]u8 {
        var bytes: [encoded_size]u8 = @splat(0);
        @memcpy(bytes[0..4], magic);
        writeInt(u16, bytes[4..6], version);
        var present: u16 = 0;
        if (self.tempo) |tempo| {
            present |= has_tempo;
            writeInt(u32, bytes[8..12], toFixed(tempo.bpm, milli));
            writeInt(u32, bytes[12..16], toFixed(tempo.confidence, micro));
        }
        if (self.key) |key| {
            present |= has_key;
            bytes[16] = key.pitch;
            bytes[17] = @backingInt(key.mode);
            writeInt(u32, bytes[20..24], toFixed(key.confidence, micro));
        }
        if (self.onset_rate) |rate| {
            present |= has_onset_rate;
            writeInt(u32, bytes[24..28], toFixed(rate, micro));
        }
        if (self.centroid_hz) |centroid| {
            present |= has_centroid;
            writeInt(u32, bytes[28..32], toFixed(centroid, milli));
        }
        writeInt(u16, bytes[6..8], present);
        writeInt(u32, bytes[32..36], self.analysed_ms);
        return bytes;
    }

    pub fn decode(bytes: []const u8) !Features {
        if (bytes.len != encoded_size or !std.mem.eql(u8, bytes[0..4], magic))
            return error.InvalidAnalysisResult;
        if (readInt(u16, bytes[4..6]) != version) return error.UnsupportedAnalysisResultVersion;
        const present = readInt(u16, bytes[6..8]);
        if (present & ~(has_tempo | has_key | has_onset_rate | has_centroid) != 0 or
            bytes[16] >= 12 or bytes[17] > 1)
            return error.InvalidAnalysisResult;
        return .{
            .analysed_ms = readInt(u32, bytes[32..36]),
            .tempo = if (present & has_tempo == 0) null else .{
                .bpm = fromFixed(readInt(u32, bytes[8..12]), milli),
                .confidence = fromFixed(readInt(u32, bytes[12..16]), micro),
            },
            .key = if (present & has_key == 0) null else .{
                .pitch = bytes[16],
                .mode = @fromBackingInt(@intCast(bytes[17])),
                .confidence = fromFixed(readInt(u32, bytes[20..24]), micro),
            },
            .onset_rate = if (present & has_onset_rate == 0) null else fromFixed(readInt(u32, bytes[24..28]), micro),
            .centroid_hz = if (present & has_centroid == 0) null else fromFixed(readInt(u32, bytes[28..32]), milli),
        };
    }

    fn quantised(self: Features) Features {
        return decode(&self.encode()) catch unreachable;
    }

    fn toFixed(value: f64, scale: f64) u32 {
        if (std.math.isNan(value)) return 0;
        return @intFromFloat(std.math.clamp(@round(value * scale), 0, std.math.maxInt(u32)));
    }

    fn fromFixed(value: u32, scale: f64) f64 {
        return @as(f64, @floatFromInt(value)) / scale;
    }
};

fn writeInt(comptime T: type, destination: *[@sizeOf(T)]u8, value: T) void {
    std.mem.writeInt(T, destination, value, .little);
}

fn readInt(comptime T: type, source: *const [@sizeOf(T)]u8) T {
    return std.mem.readInt(T, source, .little);
}

const MelBank = struct {
    first_bin: [mel_band_count]u16,
    bin_counts: [mel_band_count]u16,
    weights: [mel_band_count][max_mel_band_bins]f32,

    fn init(self: *MelBank) void {
        const low_mel = hzToMel(0);
        const high_mel = hzToMel(@as(f64, analysis_rate) / 2);
        var edges: [mel_band_count + 2]f64 = undefined;
        for (&edges, 0..) |*edge, index| {
            const fraction = @as(f64, @floatFromInt(index)) / (mel_band_count + 1);
            edge.* = melToHz(low_mel + (high_mel - low_mel) * fraction);
        }
        for (0..mel_band_count) |band| {
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
                self.weights[band][count] = @floatCast(weight * area_norm);
                count += 1;
            }
            self.first_bin[band] = @intCast(first orelse 0);
            self.bin_counts[band] = @intCast(count);
        }
    }

    fn bandPower(self: *const MelBank, band: usize, power: *const [bin_count]f32) f64 {
        const first = self.first_bin[band];
        var sum: f64 = 0;
        for (self.weights[band][0..self.bin_counts[band]], power[first..][0..self.bin_counts[band]]) |weight, value|
            sum += @as(f64, weight) * value;
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
    return @as(f64, @floatFromInt(bin)) * analysis_rate / window_size;
}

const Spectrogram = struct {
    frame: [window_size]f32,
    frame_len: usize,
    hann: [window_size]f32,
    windowed: [window_size]f32,
    spectrum: [bin_count]KissComplex,
    power: [bin_count]f32,
    mel_bank: MelBank,
    previous_log_mel: [mel_band_count]f64,
    frame_count: usize,
    audible_frames: u64,
    centroid_sum: f64,
    pitch: PitchSpectrum,

    fn init(self: *Spectrogram) void {
        self.frame_len = window_size / 2;
        @memset(self.frame[0..self.frame_len], 0);
        for (&self.hann, 0..) |*value, index|
            value.* = @floatCast(periodicHann(index, window_size));
        self.mel_bank.init();
        self.frame_count = 0;
        self.audible_frames = 0;
        self.centroid_sum = 0;
        self.previous_log_mel = @splat(0);
        self.pitch.init();
    }
};

/// A longer-window spectrum binned to thirds of a semitone, from which each
/// frame's pitch salience sums the first four harmonics of every pitch and
/// folds the salience between 55 Hz and 2 kHz into a chroma vector.
const PitchSpectrum = struct {
    frame: [pitch_window_size]f32,
    frame_len: usize,
    hann: [pitch_window_size]f32,
    windowed: [pitch_window_size]f32,
    spectrum: [pitch_bin_count]KissComplex,
    step_of_bin: [pitch_bin_count]u8,
    chroma_sum: [12]f64,
    frames: u64,

    const harmonic_steps = steps: {
        var steps: [harmonic_count]usize = undefined;
        for (&steps, 1..) |*step, harmonic|
            step.* = @round(12 * pitch_steps_per_semitone * std.math.log2(@as(f64, @floatFromInt(harmonic))));
        break :steps steps;
    };
    const harmonic_weights = weights: {
        var weights: [harmonic_count]f64 = undefined;
        for (&weights, 0..) |*weight, index| weight.* = std.math.pow(f64, harmonic_decay, @floatFromInt(index));
        break :weights weights;
    };

    fn init(self: *PitchSpectrum) void {
        self.frame_len = 0;
        for (&self.hann, 0..) |*value, index|
            value.* = @floatCast(periodicHann(index, pitch_window_size));
        for (&self.step_of_bin, 0..) |*step, bin| {
            step.* = no_pitch_step;
            if (bin == 0) continue;
            const frequency = @as(f64, @floatFromInt(bin)) * analysis_rate / pitch_window_size;
            const position = @round((midiOf(frequency) - pitch_lowest_midi) * pitch_steps_per_semitone);
            if (position >= 0 and position < pitch_step_count) step.* = @intFromFloat(position);
        }
        self.chroma_sum = @splat(0);
        self.frames = 0;
    }

    fn push(self: *PitchSpectrum, fft: *anyopaque, sample: f32) void {
        self.frame[self.frame_len] = sample;
        self.frame_len += 1;
        if (self.frame_len < pitch_window_size) return;
        self.analyse(fft);
        std.mem.copyForwards(f32, self.frame[0 .. pitch_window_size - pitch_hop_size], self.frame[pitch_hop_size..]);
        self.frame_len = pitch_window_size - pitch_hop_size;
    }

    fn analyse(self: *PitchSpectrum, fft: *anyopaque) void {
        var sum_squares: f64 = 0;
        for (&self.windowed, self.frame, self.hann) |*windowed, sample, weight| {
            sum_squares += @as(f64, sample) * sample;
            windowed.* = sample * weight;
        }
        if (!(sum_squares / pitch_window_size > audible_mean_square)) return;
        kiss_fftr(fft, &self.windowed, &self.spectrum);

        var steps: [pitch_step_count]f64 = @splat(0);
        for (self.spectrum, self.step_of_bin) |value, step| {
            if (step != no_pitch_step) steps[step] += @as(f64, value.r) * value.r + @as(f64, value.i) * value.i;
        }
        var chroma: [12]f64 = @splat(0);
        for (0..pitch_step_count) |step| {
            const frequency = stepFrequency(step);
            if (frequency < chroma_low_hz or frequency > chroma_high_hz) continue;
            var salience: f64 = 0;
            for (harmonic_steps, harmonic_weights) |offset, weight| {
                if (step + offset < pitch_step_count) salience += weight * steps[step + offset];
            }
            chroma[stepPitchClass(step)] += salience;
        }
        const loudest = std.mem.max(f64, &chroma);
        if (!(loudest > 0) or !std.math.isFinite(loudest)) return;
        for (&self.chroma_sum, chroma) |*sum, value| sum.* += value / loudest;
        self.frames += 1;
    }

    fn stepFrequency(step: usize) f64 {
        const midi = pitch_lowest_midi + @as(f64, @floatFromInt(step)) / pitch_steps_per_semitone;
        return 440.0 * std.math.pow(f64, 2.0, (midi - 69.0) / 12.0);
    }

    fn stepPitchClass(step: usize) usize {
        return (pitch_lowest_midi + (step + pitch_steps_per_semitone / 2) / pitch_steps_per_semitone) % 12;
    }
};

fn midiOf(frequency: f64) f64 {
    return 69.0 + 12.0 * std.math.log2(frequency / 440.0);
}

fn periodicHann(index: usize, length: usize) f64 {
    const phase = @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(length));
    return 0.5 - 0.5 * @cos(2.0 * std.math.pi * phase);
}

/// Measures interleaved audio fed to it a chunk at a time, so a caller already
/// decoding a file for something else takes these features in the same pass.
/// Frames past the window are ignored.
pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    parameters: Parameters,
    converter: ?Resampler,
    channels: usize,
    sample_rate: u32,
    window_frames: u64,
    frames_fed: u64 = 0,
    pending: []f32,
    pending_len: usize = 0,
    analysed_samples: u64 = 0,
    max_analysed_samples: u64,
    fft: *anyopaque,
    fft_memory: []align(16) u8,
    pitch_fft: *anyopaque,
    pitch_fft_memory: []align(16) u8,
    spectrogram: *Spectrogram,
    onset_envelope: []f32,

    pub fn init(
        allocator: std.mem.Allocator,
        sample_rate: u32,
        channels: u16,
        parameters: Parameters,
    ) !Analyzer {
        if (channels == 0 or sample_rate == 0) return error.InvalidAudioFormat;
        if (parameters.max_seconds == 0 or parameters.max_seconds > max_window_seconds or
            parameters.min_seconds > parameters.max_seconds or
            parameters.stopband_db < min_stopband_db or parameters.stopband_db > max_stopband_db)
            return error.InvalidAnalysisParameters;

        const fft_memory = try allocateFft(allocator, window_size);
        errdefer allocator.free(fft_memory);
        const fft = initFft(fft_memory, window_size) orelse return error.SpectrumUnavailable;
        const pitch_fft_memory = try allocateFft(allocator, pitch_window_size);
        errdefer allocator.free(pitch_fft_memory);
        const pitch_fft = initFft(pitch_fft_memory, pitch_window_size) orelse return error.SpectrumUnavailable;

        var converter: ?Resampler = if (sample_rate == analysis_rate)
            null
        else
            try Resampler.init(allocator, sample_rate, analysis_rate, parameters.stopband_db);
        errdefer if (converter) |*value| value.deinit();

        const pending = try allocator.alloc(f32, chunk_frames);
        errdefer allocator.free(pending);
        const spectrogram = try allocator.create(Spectrogram);
        errdefer allocator.destroy(spectrogram);
        spectrogram.init();
        const max_analysed_samples = @as(u64, parameters.max_seconds) * analysis_rate;
        const onset_envelope = try allocator.alloc(f32, @intCast(max_analysed_samples / hop_size + 2));

        return .{
            .allocator = allocator,
            .parameters = parameters,
            .converter = converter,
            .channels = channels,
            .sample_rate = sample_rate,
            .window_frames = @as(u64, parameters.max_seconds) * sample_rate,
            .pending = pending,
            .max_analysed_samples = max_analysed_samples,
            .fft = fft,
            .fft_memory = fft_memory,
            .pitch_fft = pitch_fft,
            .pitch_fft_memory = pitch_fft_memory,
            .spectrogram = spectrogram,
            .onset_envelope = onset_envelope,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        if (self.converter) |*value| value.deinit();
        self.allocator.free(self.onset_envelope);
        self.allocator.destroy(self.spectrogram);
        self.allocator.free(self.pending);
        self.allocator.free(self.pitch_fft_memory);
        self.allocator.free(self.fft_memory);
        self.* = undefined;
    }

    pub fn windowFull(self: *const Analyzer) bool {
        return self.frames_fed >= self.window_frames;
    }

    pub fn process(self: *Analyzer, interleaved: []const f32) !void {
        if (interleaved.len % self.channels != 0) return error.IncompleteAudioFrame;
        const frames = interleaved.len / self.channels;
        var offset: usize = 0;
        while (offset < frames and !self.windowFull()) {
            const take: usize = @intCast(@min(
                chunk_frames - self.pending_len,
                frames - offset,
                self.window_frames - self.frames_fed,
            ));
            downmix(
                interleaved[offset * self.channels ..][0 .. take * self.channels],
                self.channels,
                self.pending[self.pending_len..][0..take],
            );
            self.pending_len += take;
            self.frames_fed += take;
            offset += take;
            if (self.pending_len == chunk_frames) try self.flushPending(false);
        }
    }

    pub fn finish(self: *Analyzer) !Features {
        try self.flushPending(true);
        for (0..window_size / 2) |_| self.pushSample(0);

        const spectrogram = self.spectrogram;
        const analysed_ms: u32 = @intCast(self.frames_fed * 1000 / self.sample_rate);
        const min_frames = @as(u64, self.parameters.min_seconds) * self.sample_rate;
        if (self.frames_fed < min_frames or spectrogram.audible_frames == 0)
            return .{ .analysed_ms = analysed_ms };

        const envelope = self.onset_envelope[0..spectrogram.frame_count];
        const audible: f64 = @floatFromInt(spectrogram.audible_frames);
        const seconds = @as(f64, @floatFromInt(self.frames_fed)) / @as(f64, @floatFromInt(self.sample_rate));
        const features: Features = .{
            .analysed_ms = analysed_ms,
            .tempo = estimateTempo(envelope),
            .key = if (spectrogram.pitch.frames == 0) null else estimateKey(spectrogram.pitch.chroma_sum),
            .onset_rate = @as(f64, @floatFromInt(countOnsets(envelope))) / seconds,
            .centroid_hz = spectrogram.centroid_sum / audible,
        };
        return features.quantised();
    }

    fn flushPending(self: *Analyzer, end_of_input: bool) !void {
        const input = self.pending[0..self.pending_len];
        self.pending_len = 0;
        const converter = if (self.converter) |*value| value else {
            for (input) |sample| self.analyseSample(sample);
            return;
        };
        converter.write(input);
        if (end_of_input) converter.drain();
        while (converter.read()) |sample| self.analyseSample(sample);
    }

    fn analyseSample(self: *Analyzer, sample: f32) void {
        if (self.analysed_samples >= self.max_analysed_samples) return;
        self.analysed_samples += 1;
        self.spectrogram.pitch.push(self.pitch_fft, sample);
        self.pushSample(sample);
    }

    fn pushSample(self: *Analyzer, sample: f32) void {
        const spectrogram = self.spectrogram;
        spectrogram.frame[spectrogram.frame_len] = sample;
        spectrogram.frame_len += 1;
        if (spectrogram.frame_len < window_size) return;
        self.analyseFrame();
        std.mem.copyForwards(f32, spectrogram.frame[0 .. window_size - hop_size], spectrogram.frame[hop_size..]);
        spectrogram.frame_len = window_size - hop_size;
    }

    fn analyseFrame(self: *Analyzer) void {
        const spectrogram = self.spectrogram;
        if (spectrogram.frame_count == self.onset_envelope.len) return;

        var sum_squares: f64 = 0;
        for (&spectrogram.windowed, spectrogram.frame, spectrogram.hann) |*windowed, sample, weight| {
            sum_squares += @as(f64, sample) * sample;
            windowed.* = sample * weight;
        }
        kiss_fftr(self.fft, &spectrogram.windowed, &spectrogram.spectrum);
        for (&spectrogram.power, spectrogram.spectrum) |*power, value| {
            const magnitude_squared = @as(f64, value.r) * value.r + @as(f64, value.i) * value.i;
            power.* = @floatCast(magnitude_squared * spectrum_scale * spectrum_scale);
        }

        var flux: f64 = 0;
        for (0..mel_band_count) |band| {
            const log_mel = 10.0 * std.math.log10(@max(spectrogram.mel_bank.bandPower(band, &spectrogram.power), mel_power_floor));
            flux += @max(0, log_mel - spectrogram.previous_log_mel[band]);
            spectrogram.previous_log_mel[band] = log_mel;
        }
        self.onset_envelope[spectrogram.frame_count] = if (spectrogram.frame_count == 0)
            0
        else
            @floatCast(flux / mel_band_count);
        spectrogram.frame_count += 1;

        if (sum_squares / window_size <= audible_mean_square) return;
        spectrogram.audible_frames += 1;

        var weighted_frequency: f64 = 0;
        var magnitude_sum: f64 = 0;
        for (spectrogram.power, 0..) |power, bin| {
            const magnitude = @sqrt(@as(f64, power));
            weighted_frequency += binFrequency(bin) * magnitude;
            magnitude_sum += magnitude;
        }
        if (magnitude_sum > 0) spectrogram.centroid_sum += weighted_frequency / magnitude_sum;
    }
};

fn allocateFft(allocator: std.mem.Allocator, size: c_int) ![]align(16) u8 {
    var len: usize = 0;
    _ = kiss_fftr_alloc(size, 0, null, &len);
    return allocator.alignedAlloc(u8, .@"16", len);
}

fn initFft(memory: []align(16) u8, size: c_int) ?*anyopaque {
    var len = memory.len;
    return kiss_fftr_alloc(size, 0, memory.ptr, &len);
}

/// A streaming polyphase resampler: a Kaiser-windowed sinc low-pass evaluated
/// at each output instant. The filter has one row of taps per distinct
/// fractional position of an output between two inputs, so a rate that is a
/// multiple of the output rate needs one row and 48 kHz to 11,025 Hz 147.
const Resampler = struct {
    allocator: std.mem.Allocator,
    input_rate: u64,
    output_rate: u64,
    phase_step: u64,
    row_len: usize,
    half: usize,
    table: []f32,
    buffer: []f32,
    len: usize,
    start: usize = 0,
    remainder: u64 = 0,

    const max_phases = 512;
    const lanes = 8;
    const Lane = @Vector(lanes, f32);
    const passband_share = 0.8;

    fn init(allocator: std.mem.Allocator, input_rate: u32, output_rate: u32, stopband_db: u32) !Resampler {
        const nyquist = @as(f64, @floatFromInt(@min(input_rate, output_rate))) / 2.0;
        const input: f64 = @floatFromInt(input_rate);
        const cutoff = nyquist * (1.0 + passband_share) / 2.0 / input;
        const transition = nyquist * (1.0 - passband_share) / input;
        const attenuation: f64 = @floatFromInt(stopband_db);
        const order = (attenuation - 8.0) / (2.285 * 2.0 * std.math.pi * transition);
        const half: usize = @intFromFloat(@ceil(order / 2.0));
        const row_len = std.mem.alignForward(usize, 2 * half, lanes);
        const beta = if (attenuation > 50)
            0.1102 * (attenuation - 8.7)
        else if (attenuation >= 21)
            0.5842 * std.math.pow(f64, attenuation - 21, 0.4) + 0.07886 * (attenuation - 21)
        else
            0;

        const divisor = std.math.gcd(@as(u64, input_rate), @as(u64, output_rate));
        const exact_phases = output_rate / divisor;
        const phases: usize = @intCast(@min(exact_phases, max_phases));
        const table = try allocator.alloc(f32, phases * row_len);
        errdefer allocator.free(table);
        const half_width: f64 = @floatFromInt(half);
        for (0..phases) |phase| {
            const fraction = @as(f64, @floatFromInt(phase)) / @as(f64, @floatFromInt(phases));
            const row = table[phase * row_len ..][0..row_len];
            var sum: f64 = 0;
            for (row, 0..) |*tap, index| {
                const offset = fraction + half_width - 1.0 - @as(f64, @floatFromInt(index));
                const position = offset / half_width;
                const value = if (index >= 2 * half or @abs(position) >= 1.0)
                    0.0
                else
                    2.0 * cutoff * sinc(2.0 * cutoff * offset) *
                        besselI0(beta * @sqrt(1.0 - position * position)) / besselI0(beta);
                tap.* = @floatCast(value);
                sum += value;
            }
            for (row) |*tap| tap.* = @floatCast(tap.* / sum);
        }

        const buffer = try allocator.alloc(f32, chunk_frames + 2 * row_len);
        @memset(buffer[0 .. half - 1], 0);
        return .{
            .allocator = allocator,
            .input_rate = input_rate,
            .output_rate = output_rate,
            .phase_step = if (exact_phases <= max_phases) divisor else 0,
            .row_len = row_len,
            .half = half,
            .table = table,
            .buffer = buffer,
            .len = half - 1,
        };
    }

    fn deinit(self: *Resampler) void {
        self.allocator.free(self.buffer);
        self.allocator.free(self.table);
        self.* = undefined;
    }

    /// Appends at most `chunk_frames` input samples, after every output the
    /// previous ones allowed has been read.
    fn write(self: *Resampler, samples: []const f32) void {
        const kept = self.len - self.start;
        std.mem.copyForwards(f32, self.buffer[0..kept], self.buffer[self.start..self.len]);
        self.start = 0;
        @memcpy(self.buffer[kept..][0..samples.len], samples);
        self.len = kept + samples.len;
    }

    /// Ends the input with enough silence to centre an output on the last
    /// sample.
    fn drain(self: *Resampler) void {
        const padding = self.row_len - self.half;
        @memset(self.buffer[self.len..][0..padding], 0);
        self.len += padding;
    }

    fn read(self: *Resampler) ?f32 {
        if (self.start + self.row_len > self.len) return null;
        const phases = self.table.len / self.row_len;
        const phase: usize = @intCast(if (self.phase_step != 0)
            self.remainder / self.phase_step
        else
            self.remainder * phases / self.output_rate);
        const taps = self.table[phase * self.row_len ..][0..self.row_len];
        const samples = self.buffer[self.start..][0..self.row_len];
        var sum: Lane = @splat(0);
        var index: usize = 0;
        while (index < self.row_len) : (index += lanes) {
            const tap: Lane = taps[index..][0..lanes].*;
            const sample: Lane = samples[index..][0..lanes].*;
            sum = @mulAdd(Lane, tap, sample, sum);
        }
        self.remainder += self.input_rate;
        self.start += @intCast(self.remainder / self.output_rate);
        self.remainder %= self.output_rate;
        return @reduce(.Add, sum);
    }
};

fn sinc(x: f64) f64 {
    if (x == 0) return 1;
    const angle = std.math.pi * x;
    return @sin(angle) / angle;
}

fn besselI0(x: f64) f64 {
    var sum: f64 = 1;
    var term: f64 = 1;
    var k: f64 = 1;
    while (term > sum * 1e-12) : (k += 1) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
    }
    return sum;
}

fn downmix(interleaved: []const f32, channels: usize, mono: []f32) void {
    const scale = 1.0 / @as(f32, @floatFromInt(channels));
    for (mono, 0..) |*sample, frame| {
        var sum: f32 = 0;
        for (interleaved[frame * channels ..][0..channels]) |value| sum += value;
        sample.* = sum * scale;
    }
}

fn lagBpm(lag: f64) f64 {
    return 60.0 * frames_per_second / lag;
}

fn tempoPrior(lag: usize) f64 {
    const octaves = std.math.log2(lagBpm(@floatFromInt(lag)) / tempo_prior_centre_bpm) / tempo_prior_octaves;
    return @exp(-0.5 * octaves * octaves);
}

fn estimateTempo(envelope: []const f32) ?Tempo {
    const min_lag: usize = @intFromFloat(@ceil(lagBpm(max_tempo_bpm)));
    const max_lag: usize = @intFromFloat(@floor(lagBpm(min_tempo_bpm)));
    comptime std.debug.assert(2 * @floor(lagBpm(min_tempo_bpm)) < tempogram_lag_limit);

    var hann: [tempogram_window_frames]f64 = undefined;
    for (&hann, 0..) |*value, index| value.* = periodicHann(index, tempogram_window_frames);
    const half = tempogram_window_frames / 2;

    var aggregate: [tempogram_lag_limit]f64 = @splat(0);
    var windows: usize = 0;
    var segment: [tempogram_window_frames]f64 = undefined;
    var centre: usize = 0;
    while (centre < envelope.len) : (centre += tempogram_stride) {
        var sum: f64 = 0;
        for (&segment, 0..) |*value, offset| {
            const position = centre + offset;
            value.* = if (position < half or position - half >= envelope.len) 0 else envelope[position - half];
            sum += value.*;
        }
        const mean = sum / tempogram_window_frames;
        for (&segment, hann) |*value, weight| value.* = (value.* - mean) * weight;
        var autocorrelation: [tempogram_lag_limit]f64 = undefined;
        for (&autocorrelation, 0..) |*value, lag| {
            var product: f64 = 0;
            for (segment[0 .. segment.len - lag], segment[lag..]) |first, second| product += first * second;
            value.* = product;
        }
        if (!(autocorrelation[0] > 1e-12)) continue;
        for (&aggregate, autocorrelation) |*total, value| total.* += value / (autocorrelation[0] + tempogram_energy_floor);
        windows += 1;
    }
    if (windows == 0) return null;
    for (&aggregate) |*total| total.* /= @floatFromInt(windows);

    var peak_lag: ?usize = null;
    var peak_weight: f64 = 0;
    var lowest = std.math.inf(f64);
    for (min_lag..max_lag + 1) |lag| {
        lowest = @min(lowest, aggregate[lag]);
        if (!(aggregate[lag] > 0)) continue;
        const salience = aggregate[lag] + tempo_double_lag_weight * aggregate[2 * lag];
        const weight = @max(0, salience) * tempoPrior(lag);
        if (weight > peak_weight) {
            peak_weight = weight;
            peak_lag = lag;
        }
    }
    const lag = peak_lag orelse return null;
    const confidence = @min(1, aggregate[lag] - lowest);
    if (!(confidence >= min_tempo_confidence)) return null;

    const before = aggregate[lag - 1];
    const at = aggregate[lag];
    const after = aggregate[lag + 1];
    const curvature = before - 2 * at + after;
    const offset = if (curvature < 0) std.math.clamp(0.5 * (before - after) / curvature, -0.5, 0.5) else 0;
    const bpm = std.math.clamp(lagBpm(@as(f64, @floatFromInt(lag)) + offset), min_tempo_bpm, max_tempo_bpm);
    return .{ .bpm = bpm, .confidence = confidence };
}

const major_profile = [12]f64{ 0.238, 0.006, 0.111, 0.006, 0.137, 0.094, 0.016, 0.214, 0.009, 0.080, 0.008, 0.081 };
const minor_profile = [12]f64{ 0.220, 0.006, 0.104, 0.123, 0.019, 0.103, 0.012, 0.214, 0.062, 0.022, 0.061, 0.052 };

fn estimateKey(chroma: [12]f64) ?Key {
    var best: ?Key = null;
    var best_correlation: f64 = -std.math.inf(f64);
    var second_correlation: f64 = -std.math.inf(f64);
    for ([_]Mode{ .major, .minor }) |mode| {
        const profile = switch (mode) {
            .major => major_profile,
            .minor => minor_profile,
        };
        for (0..12) |tonic| {
            var rotated: [12]f64 = undefined;
            for (&rotated, 0..) |*value, pitch| value.* = profile[(pitch + 12 - tonic) % 12];
            const correlation = pearson(chroma, rotated) orelse return null;
            if (correlation > best_correlation) {
                second_correlation = best_correlation;
                best_correlation = correlation;
                best = .{ .pitch = @intCast(tonic), .mode = mode, .confidence = 0 };
            } else if (correlation > second_correlation) {
                second_correlation = correlation;
            }
        }
    }
    var key = best orelse return null;
    key.confidence = @min(1, best_correlation - second_correlation);
    return key;
}

fn pearson(first: [12]f64, second: [12]f64) ?f64 {
    const first_mean = mean12(first);
    const second_mean = mean12(second);
    var covariance: f64 = 0;
    var first_variance: f64 = 0;
    var second_variance: f64 = 0;
    for (first, second) |a, b| {
        covariance += (a - first_mean) * (b - second_mean);
        first_variance += (a - first_mean) * (a - first_mean);
        second_variance += (b - second_mean) * (b - second_mean);
    }
    if (first_variance <= 0 or second_variance <= 0) return null;
    return covariance / @sqrt(first_variance * second_variance);
}

fn mean12(values: [12]f64) f64 {
    var sum: f64 = 0;
    for (values) |value| sum += value;
    return sum / 12;
}

fn countOnsets(envelope: []const f32) u64 {
    if (envelope.len == 0) return 0;
    const lowest = std.mem.min(f32, envelope);
    const range = std.mem.max(f32, envelope) - lowest;
    if (range <= 0) return 0;
    const threshold = onset_delta * range;

    var count: u64 = 0;
    var last_onset: ?usize = null;
    for (envelope, 0..) |value, frame| {
        const before = if (frame == 0) lowest else envelope[frame - 1];
        const after = if (frame + 1 == envelope.len) lowest else envelope[frame + 1];
        if (value <= before or value < after) continue;
        const neighbours = envelope[frame -| onset_average_radius..@min(envelope.len, frame + onset_average_radius + 1)];
        var sum: f64 = 0;
        for (neighbours) |neighbour| sum += neighbour;
        if (value < sum / @as(f64, @floatFromInt(neighbours.len)) + threshold) continue;
        if (last_onset) |previous| if (frame - previous < onset_min_gap_frames) continue;
        count += 1;
        last_onset = frame;
    }
    return count;
}

const testing = std.testing;

const Signal = struct {
    sample_rate: u32,
    channels: u16,
    total_frames: u64,
    shape: Shape,
    position: u64 = 0,
    seed: u32 = 1,

    const Shape = union(enum) {
        silence,
        noise,
        tone: f64,
        clicks: f64,
        clicks_over_noise: f64,
        chords: []const [4]u8,
    };

    const chord_seconds = 2.0;
    const click_seconds = 0.01;

    fn init(shape: Shape, sample_rate: u32, channels: u16, seconds: f64) Signal {
        return .{
            .sample_rate = sample_rate,
            .channels = channels,
            .total_frames = @intFromFloat(seconds * @as(f64, @floatFromInt(sample_rate))),
            .shape = shape,
        };
    }

    fn fill(self: *Signal, output: []f32) usize {
        const frames: usize = @intCast(@min(output.len / self.channels, self.total_frames - self.position));
        for (0..frames) |frame| {
            const value = self.next();
            for (output[frame * self.channels ..][0..self.channels]) |*sample| sample.* = value;
        }
        return frames;
    }

    fn next(self: *Signal) f32 {
        const rate: f64 = @floatFromInt(self.sample_rate);
        const time = @as(f64, @floatFromInt(self.position)) / rate;
        self.position += 1;
        return switch (self.shape) {
            .silence => 0,
            .noise => 0.3 * self.nextNoise(),
            .tone => |hz| @floatCast(0.4 * @sin(2.0 * std.math.pi * hz * time)),
            .clicks => |bpm| self.click(bpm, time),
            .clicks_over_noise => |bpm| 0.05 * self.nextNoise() + self.click(bpm, time),
            .chords => |chords| chords: {
                const index: usize = @intFromFloat(@floor(time / chord_seconds));
                var sum: f64 = 0;
                for (chords[index % chords.len]) |note| {
                    const hz = 440.0 * std.math.pow(f64, 2.0, (@as(f64, @floatFromInt(note)) - 69.0) / 12.0);
                    for (1..5) |harmonic| {
                        const order: f64 = @floatFromInt(harmonic);
                        sum += @sin(2.0 * std.math.pi * hz * order * time) / order;
                    }
                }
                break :chords @floatCast(0.08 * sum);
            },
        };
    }

    fn click(self: *Signal, bpm: f64, time: f64) f32 {
        const period = 60.0 / bpm;
        const phase = time - @floor(time / period) * period;
        const sample = self.nextNoise();
        if (phase >= click_seconds) return 0;
        return @floatCast(0.6 * sample * @exp(-phase / 0.003));
    }

    fn nextNoise(self: *Signal) f32 {
        self.seed = self.seed *% 1_103_515_245 +% 12_345;
        return @as(f32, @floatFromInt(self.seed >> 16 & 0x7fff)) / 16_384.0 - 1.0;
    }
};

fn analyseSignal(signal: Signal, chunk: usize) !Features {
    var source = signal;
    var analyzer = try Analyzer.init(testing.allocator, source.sample_rate, source.channels, .{});
    defer analyzer.deinit();
    const buffer = try testing.allocator.alloc(f32, chunk * source.channels);
    defer testing.allocator.free(buffer);
    while (!analyzer.windowFull()) {
        const frames = source.fill(buffer);
        if (frames == 0) break;
        try analyzer.process(buffer[0 .. frames * source.channels]);
    }
    return analyzer.finish();
}

fn expectTempoNear(bpm: f64, features: Features) !void {
    const tempo = features.tempo orelse return error.TestExpectedTempo;
    const allowed = [_]f64{ bpm, bpm * 2, bpm / 2 };
    for (allowed) |candidate| {
        if (@abs(tempo.bpm - candidate) <= candidate * 0.02) return;
    }
    std.debug.print("expected {d} BPM (or double or half), measured {d} at confidence {d}\n", .{ bpm, tempo.bpm, tempo.confidence });
    return error.TestUnexpectedTempo;
}

test "click tracks at 60, 90, 120 and 174 BPM measure within 2% of their tempo, the slow and fast ones allowing an octave" {
    for ([_]f64{ 90, 120 }) |bpm| {
        const features = try analyseSignal(.init(.{ .clicks = bpm }, 44_100, 2, 30), 4096);
        try testing.expect(features.tempo != null);
        try testing.expect(@abs(features.tempo.?.bpm - bpm) <= bpm * 0.02);
    }
    for ([_]f64{ 60, 174 }) |bpm| {
        try expectTempoNear(bpm, try analyseSignal(.init(.{ .clicks = bpm }, 44_100, 2, 30), 4096));
    }
    const resampled = try analyseSignal(.init(.{ .clicks = 120 }, 48_000, 2, 30), 4096);
    try testing.expect(@abs(resampled.tempo.?.bpm - 120) <= 120 * 0.02);
}

test "a beat over a steady noise floor measures its tempo" {
    const features = try analyseSignal(.init(.{ .clicks_over_noise = 100 }, 44_100, 1, 30), 4096);
    const tempo = features.tempo orelse return error.TestExpectedTempo;
    try testing.expect(@abs(tempo.bpm - 100) <= 100 * 0.02);
}

const c_major_cadence = [_][4]u8{ .{ 48, 60, 64, 67 }, .{ 53, 65, 69, 72 }, .{ 55, 67, 71, 74 }, .{ 48, 60, 64, 67 } };
const a_minor_cadence = [_][4]u8{ .{ 45, 57, 60, 64 }, .{ 50, 62, 65, 69 }, .{ 52, 64, 67, 71 }, .{ 45, 57, 60, 64 } };

test "a I-IV-V-I cadence in C major and a i-iv-v-i cadence in A minor measure as those keys" {
    const major = try analyseSignal(.init(.{ .chords = &c_major_cadence }, 22_050, 1, 24), 4096);
    try testing.expectEqual(@as(u8, 0), major.key.?.pitch);
    try testing.expectEqual(Mode.major, major.key.?.mode);

    const minor = try analyseSignal(.init(.{ .chords = &a_minor_cadence }, 22_050, 1, 24), 4096);
    try testing.expectEqual(@as(u8, 9), minor.key.?.pitch);
    try testing.expectEqual(Mode.minor, minor.key.?.mode);
}

test "silence, and audio shorter than the minimum, measure no feature at all" {
    const silence = try analyseSignal(.init(.silence, 44_100, 2, 30), 4096);
    try testing.expectEqual(Features{ .analysed_ms = 30_000 }, silence);

    const short = try analyseSignal(.init(.{ .tone = 440 }, 44_100, 2, 10), 4096);
    try testing.expectEqual(Features{ .analysed_ms = 10_000 }, short);
}

test "a steady tone measures its frequency as the spectral centroid and no tempo" {
    const features = try analyseSignal(.init(.{ .tone = 440 }, 11_025, 1, 20), 4096);
    try testing.expect(@abs(features.centroid_hz.? - 440) < 20);
    try testing.expect(features.onset_rate != null);
    try testing.expectEqual(@as(?Tempo, null), features.tempo);
}

test "white noise measures no tempo" {
    const features = try analyseSignal(.init(.noise, 44_100, 1, 30), 4096);
    try testing.expectEqual(@as(?Tempo, null), features.tempo);
}

test "feeding the same audio in small or large chunks measures identical bytes" {
    const signal: Signal = .init(.{ .clicks = 120 }, 44_100, 2, 30);
    const small = try analyseSignal(signal, 1024);
    const large = try analyseSignal(signal, 65_536);
    try testing.expectEqualSlices(u8, &small.encode(), &large.encode());
}

test "audio past the window is ignored" {
    var signal: Signal = .init(.{ .clicks = 100 }, 11_025, 1, 610);
    var analyzer = try Analyzer.init(testing.allocator, signal.sample_rate, signal.channels, .{});
    defer analyzer.deinit();
    var buffer: [8192]f32 = undefined;
    while (true) {
        const frames = signal.fill(&buffer);
        if (frames == 0) break;
        try analyzer.process(buffer[0..frames]);
    }
    const features = try analyzer.finish();
    try testing.expectEqual(@as(u32, 600_000), features.analysed_ms);
    try expectTempoNear(100, features);
}

test "encoded features decode to themselves and re-encode to the same bytes" {
    const cases = [_]Features{
        .{ .analysed_ms = 12_000 },
        .{
            .analysed_ms = 600_000,
            .tempo = .{ .bpm = 128.125, .confidence = 0.412_345 },
            .key = .{ .pitch = 9, .mode = .minor, .confidence = 0.071_234 },
            .onset_rate = 3.141_592,
            .centroid_hz = 1_834.25,
        },
        .{ .analysed_ms = 30_000, .onset_rate = 0, .centroid_hz = 0 },
    };
    for (cases) |features| {
        const bytes = features.encode();
        try testing.expectEqual(@as(usize, 40), bytes.len);
        try testing.expectEqual(features, try Features.decode(&bytes));
        try testing.expectEqualSlices(u8, &bytes, &(try Features.decode(&bytes)).encode());
    }
}

test "encoded features keep each field at its fixed offset and scale" {
    const bytes = (Features{
        .analysed_ms = 200_000,
        .tempo = .{ .bpm = 120.5, .confidence = 0.25 },
        .key = .{ .pitch = 2, .mode = .minor, .confidence = 0.1 },
        .onset_rate = 2.5,
        .centroid_hz = 1500.125,
    }).encode();
    try testing.expectEqualSlices(u8, "ORAF\x01\x00\x0f\x00", bytes[0..8]);
    try testing.expectEqual(@as(u32, 120_500), readInt(u32, bytes[8..12]));
    try testing.expectEqual(@as(u32, 250_000), readInt(u32, bytes[12..16]));
    try testing.expectEqualSlices(u8, &.{ 2, 1, 0, 0 }, bytes[16..20]);
    try testing.expectEqual(@as(u32, 100_000), readInt(u32, bytes[20..24]));
    try testing.expectEqual(@as(u32, 2_500_000), readInt(u32, bytes[24..28]));
    try testing.expectEqual(@as(u32, 1_500_125), readInt(u32, bytes[28..32]));
    try testing.expectEqual(@as(u32, 200_000), readInt(u32, bytes[32..36]));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes[36..40]);
}

test "a malformed or newer encoding is refused" {
    var bytes = (Features{ .analysed_ms = 1 }).encode();
    try testing.expectError(error.InvalidAnalysisResult, Features.decode(bytes[0..39]));
    bytes[16] = 12;
    try testing.expectError(error.InvalidAnalysisResult, Features.decode(&bytes));
    bytes[16] = 0;
    bytes[4] = 2;
    try testing.expectError(error.UnsupportedAnalysisResultVersion, Features.decode(&bytes));
}

test "parameters that change a measurement change the parameter hash" {
    const default = parameterHash(.{});
    try testing.expectEqualSlices(u8, &default, &parameterHash(.{}));
    try testing.expect(!std.mem.eql(u8, &default, &parameterHash(.{ .stopband_db = 80 })));
    try testing.expect(!std.mem.eql(u8, &default, &parameterHash(.{ .max_seconds = 300 })));
}

test "an analyzer refuses an empty format or a minimum longer than the window" {
    try testing.expectError(error.InvalidAudioFormat, Analyzer.init(testing.allocator, 44_100, 0, .{}));
    try testing.expectError(error.InvalidAnalysisParameters, Analyzer.init(testing.allocator, 44_100, 2, .{ .min_seconds = 700 }));
}

fn resampledTone(input_rate: u32, hz: f64) !struct { rms: f64, count: usize } {
    var converter = try Resampler.init(testing.allocator, input_rate, analysis_rate, Parameters.default_stopband_db);
    defer converter.deinit();
    const seconds = 2;
    var produced: std.ArrayList(f32) = .empty;
    defer produced.deinit(testing.allocator);
    var chunk: [chunk_frames]f32 = undefined;
    var position: usize = 0;
    const total = seconds * @as(usize, input_rate);
    while (position < total) {
        const take = @min(chunk.len, total - position);
        for (chunk[0..take], position..) |*sample, frame| {
            const time = @as(f64, @floatFromInt(frame)) / @as(f64, @floatFromInt(input_rate));
            sample.* = @floatCast(@sin(2.0 * std.math.pi * hz * time));
        }
        converter.write(chunk[0..take]);
        while (converter.read()) |sample| try produced.append(testing.allocator, sample);
        position += take;
    }
    converter.drain();
    while (converter.read()) |sample| try produced.append(testing.allocator, sample);
    const middle = produced.items[analysis_rate / 2 .. produced.items.len - analysis_rate / 2];
    var squares: f64 = 0;
    for (middle) |sample| squares += @as(f64, sample) * sample;
    return .{ .rms = @sqrt(squares / @as(f64, @floatFromInt(middle.len))), .count = produced.items.len };
}

test "resampling keeps a tone in the passband and removes one above the output's Nyquist frequency" {
    for ([_]u32{ 8_000, 22_050, 32_000, 44_100, 48_000, 96_000, 44_056 }) |rate| {
        const kept = try resampledTone(rate, 1_000);
        try testing.expectApproxEqAbs(@sqrt(0.5), kept.rms, 0.01);
        try testing.expect(@abs(@as(f64, @floatFromInt(kept.count)) - 2.0 * @as(f64, analysis_rate)) <= 2);
        if (rate > 2 * 6_500) {
            const removed = try resampledTone(rate, 6_500);
            try testing.expect(removed.rms < @sqrt(0.5) * 1e-3);
        }
    }
}

test "non-finite samples from a broken decode measure without failing" {
    var analyzer = try Analyzer.init(testing.allocator, analysis_rate, 1, .{});
    defer analyzer.deinit();
    var buffer: [analysis_rate]f32 = @splat(std.math.nan(f32));
    buffer[0] = std.math.inf(f32);
    for (0..20) |_| try analyzer.process(&buffer);
    const features = try analyzer.finish();
    try testing.expectEqual(@as(u32, 20_000), features.analysed_ms);
}
