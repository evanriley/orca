const std = @import("std");
const decoder = @import("decoder.zig");
const storage = @import("../storage/root.zig");

pub const Descriptor = struct {
    name: []const u8,
    format: storage.AudioFormat,
    open: decoder.OpenFn,
};

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

    pub fn open(
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

    pub fn openDetected(
        self: *const CodecRegistry,
        allocator: std.mem.Allocator,
        source: storage.ReadableSource,
    ) !decoder.Decoder {
        var header: [64]u8 = undefined;
        const read = try source.readAt(0, &header);
        const format = storage.format.sniffBytes(header[0..read]) orelse
            return error.UnsupportedAudioFormat;
        return self.open(allocator, format, source);
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
        var opened = try self.open(allocator, format, source);
        defer opened.deinit();
        return properties(opened);
    }

    pub fn probeDetected(
        self: *const CodecRegistry,
        allocator: std.mem.Allocator,
        source: storage.ReadableSource,
    ) !Properties {
        var opened = try self.openDetected(allocator, source);
        defer opened.deinit();
        return properties(opened);
    }

    pub fn builtins() CodecRegistry {
        var registry: CodecRegistry = .{};
        registry.register(.{
            .name = "PCM WAV",
            .format = .wav,
            .open = @import("wav.zig").openDecoder,
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
            .name = "Quite OK Audio",
            .format = .qoa,
            .open = @import("qoa.zig").openDecoder,
        }) catch unreachable;
        return registry;
    }
};

/// Duration comes from the declared frame count and the canonical sample rate,
/// so it is exact wherever the container is honest about its length and absent
/// rather than guessed wherever it is not.
fn properties(opened: decoder.Decoder) Properties {
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
    try std.testing.expectEqual(@as(usize, 4), codecs.count);
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
