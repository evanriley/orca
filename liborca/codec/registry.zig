const std = @import("std");
const decoder = @import("decoder.zig");
const storage = @import("../storage/root.zig");

pub const Descriptor = struct {
    name: []const u8,
    format: storage.AudioFormat,
    open: decoder.OpenFn,
    /// Answers `probe` from the container alone, for codecs whose decoder is
    /// costly to set up. Must report what `open` would.
    probe: ?ProbeFn = null,
};

pub const ProbeFn = *const fn (std.mem.Allocator, storage.ReadableSource) anyerror!Properties;

/// What a container declares about one encoding, without decoding any audio.
///
/// `bit_depth` is deliberately optional: a transform codec such as MPEG audio
/// has no integer sample width to report, and inventing one would let a lossy
/// file outrank a genuine 16-bit lossless encoding of the same song.
pub const Properties = struct {
    /// The encoding the container turned out to hold, from
    /// `decoder.codec_id`. Static storage: the decoder that reported it has
    /// already been closed by the time a probe returns.
    codec: ?[]const u8 = null,
    sample_rate: ?u32 = null,
    channels: ?u16 = null,
    bit_depth: ?u16 = null,
    duration_ms: ?u64 = null,
};

pub const CodecRegistry = struct {
    entries: [16]Descriptor = undefined,
    count: usize = 0,

    pub fn register(self: *CodecRegistry, descriptor: Descriptor) !void {
        for (self.entries[0..self.count]) |entry| {
            if (entry.format == descriptor.format) return error.CodecAlreadyRegistered;
        }
        if (self.count == self.entries.len) return error.CodecRegistryFull;
        self.entries[self.count] = descriptor;
        self.count += 1;
    }

    /// Opens `source` as `format`, skipping a container prefix if the bytes
    /// carry one.
    ///
    /// Callers that already know the container — the scanner, which sniffed it
    /// once and stored it — still reach a stream that begins behind an ID3v2
    /// tag, so the prefix is resolved here as well as in `openDetected`.
    pub fn open(
        self: *const CodecRegistry,
        allocator: std.mem.Allocator,
        format: storage.AudioFormat,
        source: storage.ReadableSource,
    ) !decoder.Decoder {
        const detected = storage.format.detect(source) catch null;
        if (detected) |resolved| {
            if (resolved.format == format and resolved.payload_offset != 0)
                return PrefixedDecoder.open(self, allocator, resolved, source);
        }
        return self.openExact(allocator, format, source);
    }

    /// Codec dispatch with no container inspection: the source is already
    /// positioned at the start of the encoded stream.
    fn openExact(
        self: *const CodecRegistry,
        allocator: std.mem.Allocator,
        format: storage.AudioFormat,
        source: storage.ReadableSource,
    ) !decoder.Decoder {
        for (self.entries[0..self.count]) |entry| {
            if (entry.format == format) return entry.open(allocator, source);
        }
        return error.CodecUnavailable;
    }

    /// Opens whatever the bytes turn out to be, including a stream that sits
    /// behind a container prefix.
    ///
    /// Detection can report that the encoded stream starts past byte zero — an
    /// ID3v2 tag stapled in front of a FLAC file. Handing the codec the
    /// original source would show it the tag and fail on the magic bytes, so
    /// the decoder is opened over an offset view instead and the returned
    /// Decoder owns that view for its whole life. No codec learns what a tag
    /// is.
    pub fn openDetected(
        self: *const CodecRegistry,
        allocator: std.mem.Allocator,
        source: storage.ReadableSource,
    ) !decoder.Decoder {
        const detected = try storage.format.detect(source) orelse
            return error.UnsupportedAudioFormat;
        if (detected.payload_offset == 0)
            return self.openExact(allocator, detected.format, source);
        return PrefixedDecoder.open(self, allocator, detected, source);
    }

    /// Audio properties for one already-sniffed encoding.
    ///
    /// Codec-specific state stays below this call: the caller receives Orca
    /// facts, never a decoder, a container header, or a codec error dressed up
    /// as a property.
    pub fn probe(
        self: *const CodecRegistry,
        allocator: std.mem.Allocator,
        format: storage.AudioFormat,
        source: storage.ReadableSource,
    ) !Properties {
        if (try self.probeContainer(allocator, format, source)) |declared| return declared;
        var opened = try self.open(allocator, format, source);
        defer opened.deinit();
        return properties(opened);
    }

    pub fn probeDetected(
        self: *const CodecRegistry,
        allocator: std.mem.Allocator,
        source: storage.ReadableSource,
    ) !Properties {
        if (try storage.format.detect(source)) |detected| {
            if (try self.probeContainer(allocator, detected.format, source)) |declared|
                return declared;
        }
        var opened = try self.openDetected(allocator, source);
        defer opened.deinit();
        return properties(opened);
    }

    /// The descriptor's own container probe, when it has one and the stream
    /// starts at byte zero.
    fn probeContainer(
        self: *const CodecRegistry,
        allocator: std.mem.Allocator,
        format: storage.AudioFormat,
        source: storage.ReadableSource,
    ) !?Properties {
        for (self.entries[0..self.count]) |entry| {
            if (entry.format != format) continue;
            const container_probe = entry.probe orelse return null;
            const detected = storage.format.detect(source) catch return null;
            if (detected) |resolved| {
                if (resolved.payload_offset != 0) return null;
            }
            return try container_probe(allocator, source);
        }
        return null;
    }

    pub fn builtins() CodecRegistry {
        var registry: CodecRegistry = .{};
        registry.register(.{
            .name = "PCM WAV",
            .format = .wav,
            .open = @import("wav.zig").openDecoder,
        }) catch unreachable;
        registry.register(.{
            .name = "AAC (ADTS)",
            .format = .aac,
            .open = @import("adts.zig").openDecoder,
            .probe = @import("adts.zig").probe,
        }) catch unreachable;
        registry.register(.{
            .name = "AIFF",
            .format = .aiff,
            .open = @import("aiff.zig").openDecoder,
        }) catch unreachable;
        registry.register(.{
            .name = "FLAC",
            .format = .flac,
            .open = @import("flac.zig").openDecoder,
        }) catch unreachable;
        registry.register(.{
            .name = "MPEG Audio",
            .format = .mp3,
            .open = @import("mp3.zig").openDecoder,
        }) catch unreachable;
        registry.register(.{
            .name = "MP4 audio",
            .format = .mp4,
            .open = @import("mp4.zig").openDecoder,
            .probe = @import("mp4.zig").probe,
        }) catch unreachable;
        registry.register(.{
            .name = "Ogg Opus",
            .format = .opus,
            .open = @import("opus.zig").openDecoder,
        }) catch unreachable;
        registry.register(.{
            .name = "Ogg Vorbis",
            .format = .vorbis,
            .open = @import("vorbis.zig").openDecoder,
        }) catch unreachable;
        registry.register(.{
            .name = "Quite OK Audio",
            .format = .qoa,
            .open = @import("qoa.zig").openDecoder,
        }) catch unreachable;
        return registry;
    }
};

/// A Decoder that owns the offset view its codec reads through.
///
/// The view must outlive the decoder, and nothing in the caller's frame can be
/// relied on for that: `SourceSession` moves decoders between owners. So the
/// view lives on the heap beside the decoder it feeds and is destroyed strictly
/// after the codec is torn down, the same ordering `SourceSession` gives a
/// `LoadedSource`. The underlying source stays the caller's to release, exactly
/// as it is for an untagged file.
const PrefixedDecoder = struct {
    allocator: std.mem.Allocator,
    view: storage.source.OffsetSource,
    inner: decoder.Decoder,

    fn open(
        registry: *const CodecRegistry,
        allocator: std.mem.Allocator,
        detected: storage.format.Detection,
        source: storage.ReadableSource,
    ) !decoder.Decoder {
        const self = try allocator.create(PrefixedDecoder);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.view = .{ .inner = source, .offset = detected.payload_offset };
        self.inner = try registry.openExact(allocator, detected.format, self.view.readable());
        return .{
            .context = self,
            .vtable = if (self.inner.hasIntegerSamples()) &integer_vtable else &vtable,
            .codec = self.inner.codec,
            .source_format = self.inner.source_format,
            .format = self.inner.format,
            .frame_count = self.inner.frame_count,
        };
    }

    fn readFrames(context: *anyopaque, output: []f32) !usize {
        const self: *PrefixedDecoder = @ptrCast(@alignCast(context));
        return self.inner.readFrames(output);
    }

    fn readFramesI32(context: *anyopaque, output: []i32) !usize {
        const self: *PrefixedDecoder = @ptrCast(@alignCast(context));
        return self.inner.readFramesI32(output);
    }

    fn seek(context: *anyopaque, frame: u64) !void {
        const self: *PrefixedDecoder = @ptrCast(@alignCast(context));
        return self.inner.seek(frame);
    }

    fn deinit(context: *anyopaque) void {
        const self: *PrefixedDecoder = @ptrCast(@alignCast(context));
        const allocator = self.allocator;
        self.inner.deinit();
        allocator.destroy(self);
    }

    const vtable: decoder.Decoder.VTable = .{
        .read_frames = readFrames,
        .seek = seek,
        .deinit = deinit,
    };

    const integer_vtable: decoder.Decoder.VTable = .{
        .read_frames = readFrames,
        .read_frames_i32 = readFramesI32,
        .seek = seek,
        .deinit = deinit,
    };
};

/// Duration comes from the declared frame count and the canonical sample rate,
/// so it is exact wherever the container is honest about its length and absent
/// rather than guessed wherever it is not.
pub fn properties(opened: decoder.Decoder) Properties {
    const rate = opened.format.sample_rate;
    return .{
        .codec = opened.codec,
        .sample_rate = if (rate == 0) null else rate,
        .channels = if (opened.format.channels == 0) null else opened.format.channels,
        .bit_depth = if (opened.source_format) |declared| declared.bits_per_sample else null,
        .duration_ms = if (rate == 0) null else if (opened.frame_count) |frames|
            frames * std.time.ms_per_s / rate
        else
            null,
    };
}

test "builtin registry rejects duplicate codec ownership" {
    var codecs = CodecRegistry.builtins();
    try std.testing.expectEqual(@as(usize, 9), codecs.count);
    try std.testing.expectError(error.CodecAlreadyRegistered, codecs.register(codecs.entries[0]));
}

test "probing reports the properties a container declares and no invented ones" {
    const codecs = CodecRegistry.builtins();
    var lossless = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/tagged-reference.flac",
    );
    defer lossless.close();
    const flac = try codecs.probeDetected(std.testing.allocator, lossless.readable());
    try std.testing.expectEqualStrings("flac", flac.codec.?);
    try std.testing.expectEqual(@as(?u32, 44100), flac.sample_rate);
    try std.testing.expectEqual(@as(?u16, 2), flac.channels);
    try std.testing.expectEqual(@as(?u16, 16), flac.bit_depth);
    try std.testing.expectEqual(@as(?u64, 200), flac.duration_ms);

    // A transform codec states a rate and a channel count but no sample width,
    // and probing must leave that unknown rather than inventing a depth that
    // would rank an MP3 alongside a 16-bit lossless encoding.
    var lossy = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/vbr-xing-reference.mp3",
    );
    defer lossy.close();
    const mp3 = try codecs.probeDetected(std.testing.allocator, lossy.readable());
    try std.testing.expectEqualStrings("mp3", mp3.codec.?);
    try std.testing.expectEqual(@as(?u32, 44100), mp3.sample_rate);
    try std.testing.expectEqual(@as(?u16, 2), mp3.channels);
    try std.testing.expectEqual(@as(?u16, null), mp3.bit_depth);
    try std.testing.expectEqual(@as(?u64, 2000), mp3.duration_ms);
}

test "probing a file no codec can open fails rather than reporting zeroes" {
    const codecs = CodecRegistry.builtins();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "broken.flac",
        .data = "fLaC not really a stream",
    });
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/broken.flac",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(path);
    var local = try storage.LocalFileSource.open(std.testing.io, path);
    defer local.close();
    try std.testing.expectError(
        error.TruncatedFlac,
        codecs.probeDetected(std.testing.allocator, local.readable()),
    );
}

const id3_prefixed_flac = "fixtures/audio/id3-prefixed-reference.flac";
const id3_footer_prefixed_flac = "fixtures/audio/id3-footer-prefixed-reference.flac";
const untagged_flac = "fixtures/audio/generated-reference.flac";

/// Decodes `frames` frames starting at `from_frame`, through whatever container
/// detection resolves the file to. Tests compare an ID3-prefixed stream against
/// the identical untagged one, so any offset error shows up as different audio
/// rather than as a decode failure that could be mistaken for a bad fixture.
fn decodeWindow(
    allocator: std.mem.Allocator,
    path: []const u8,
    from_frame: u64,
    frames: usize,
    output: []f32,
) ![]f32 {
    var local = try storage.LocalFileSource.open(std.testing.io, path);
    defer local.close();
    const codecs = CodecRegistry.builtins();
    var opened = try codecs.openDetected(allocator, local.readable());
    defer opened.deinit();
    if (from_frame != 0) try opened.seek(from_frame);
    const channels = opened.format.channels;
    var filled: usize = 0;
    while (filled < frames * channels) {
        const read = try opened.readFrames(output[filled .. frames * channels]);
        if (read == 0) break;
        filled += read * channels;
    }
    return output[0..filled];
}

test "an ID3-prefixed FLAC decodes the same audio as the untagged stream" {
    const allocator = std.testing.allocator;
    const untagged = try allocator.alloc(f32, 480 * 2);
    defer allocator.free(untagged);
    const prefixed = try allocator.alloc(f32, 480 * 2);
    defer allocator.free(prefixed);
    const expected = try decodeWindow(allocator, untagged_flac, 0, 480, untagged);
    const actual = try decodeWindow(allocator, id3_prefixed_flac, 0, 480, prefixed);
    try std.testing.expectEqual(expected.len, actual.len);
    try std.testing.expectEqualSlices(f32, expected, actual);
}

test "an ID3v2 footer is counted in the tag length an ID3-prefixed FLAC hides behind" {
    const allocator = std.testing.allocator;
    const untagged = try allocator.alloc(f32, 480 * 2);
    defer allocator.free(untagged);
    const prefixed = try allocator.alloc(f32, 480 * 2);
    defer allocator.free(prefixed);
    const expected = try decodeWindow(allocator, untagged_flac, 0, 480, untagged);
    const actual = try decodeWindow(allocator, id3_footer_prefixed_flac, 0, 480, prefixed);
    try std.testing.expectEqualSlices(f32, expected, actual);
}

test "seeking inside an ID3-prefixed FLAC lands on the frame that was asked for" {
    const allocator = std.testing.allocator;
    const untagged = try allocator.alloc(f32, 128 * 2);
    defer allocator.free(untagged);
    const prefixed = try allocator.alloc(f32, 128 * 2);
    defer allocator.free(prefixed);
    const expected = try decodeWindow(allocator, untagged_flac, 240, 128, untagged);
    const actual = try decodeWindow(allocator, id3_prefixed_flac, 240, 128, prefixed);
    try std.testing.expect(expected.len > 0);
    try std.testing.expectEqualSlices(f32, expected, actual);
}

test "probing an ID3-prefixed FLAC reports the FLAC stream's own properties" {
    const codecs = CodecRegistry.builtins();
    var local = try storage.LocalFileSource.open(std.testing.io, id3_prefixed_flac);
    defer local.close();
    const probed = try codecs.probeDetected(std.testing.allocator, local.readable());
    try std.testing.expectEqualStrings("flac", probed.codec.?);
    try std.testing.expectEqual(@as(?u32, 48_000), probed.sample_rate);
    try std.testing.expectEqual(@as(?u16, 2), probed.channels);
    try std.testing.expectEqual(@as(?u64, 10), probed.duration_ms);
}

test "an ID3-tagged MPEG file still opens as MPEG audio" {
    const codecs = CodecRegistry.builtins();
    var local = try storage.LocalFileSource.open(
        std.testing.io,
        "fixtures/audio/tagged-reference.mp3",
    );
    defer local.close();
    const probed = try codecs.probeDetected(std.testing.allocator, local.readable());
    try std.testing.expectEqualStrings("mp3", probed.codec.?);
    try std.testing.expectEqual(@as(?u32, 44_100), probed.sample_rate);
}
