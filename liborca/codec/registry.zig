const std = @import("std");
const decoder = @import("decoder.zig");
const storage = @import("../storage/root.zig");

pub const Descriptor = struct {
    name: []const u8,
    format: storage.AudioFormat,
    open: decoder.OpenFn,
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
            .name = "Quite OK Audio",
            .format = .qoa,
            .open = @import("qoa.zig").openDecoder,
        }) catch unreachable;
        return registry;
    }
};

test "builtin registry rejects duplicate codec ownership" {
    var codecs = CodecRegistry.builtins();
    try std.testing.expectEqual(@as(usize, 3), codecs.count);
    try std.testing.expectError(error.CodecAlreadyRegistered, codecs.register(codecs.entries[0]));
}
