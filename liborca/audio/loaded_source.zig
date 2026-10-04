const std = @import("std");
const registry_api = @import("../codec/registry.zig");
const source_session = @import("source_session.zig");
const storage = @import("../storage/source.zig");

/// Heap-owned backing storage for a decoder's `ReadableSource`.
///
/// A `Decoder` borrows the `ReadableSource` it was opened with, so that source
/// must outlive the decoder. Inside a single function that can be arranged by
/// declaration order, but a Player owns SourceSessions with no caller frame
/// behind them. `LoadedSource` moves the `LocalFileSource` onto the heap and
/// hands the resulting `SourceSession` an `OwnedSource` hook, so the session
/// closes the file strictly *after* tearing the decoder down and is safe to
/// move, store in a `SourceQueue`, or hand to a runtime-owned Player.
pub const LoadedSource = struct {
    allocator: std.mem.Allocator,
    file: storage.LocalFileSource,

    /// Opens `path`, detects its container, and returns a self-contained
    /// SourceSession. Ownership of both the file and the decoder transfers to
    /// the session: `SourceSession.deinit` releases everything.
    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        registry: registry_api.CodecRegistry,
        path: []const u8,
    ) !source_session.SourceSession {
        const loaded = try allocator.create(LoadedSource);
        errdefer allocator.destroy(loaded);
        loaded.* = .{
            .allocator = allocator,
            .file = try storage.LocalFileSource.open(io, path),
        };
        errdefer loaded.file.close();
        const decoder = try registry.openDetected(allocator, loaded.file.readable());
        return .initOwned(decoder, loaded.ownedSource());
    }

    pub fn ownedSource(self: *LoadedSource) source_session.OwnedSource {
        return .{ .context = self, .release = release };
    }

    fn release(context: *anyopaque) void {
        const self: *LoadedSource = @ptrCast(@alignCast(context));
        const allocator = self.allocator;
        self.file.close();
        allocator.destroy(self);
    }
};

test "a loaded source outlives the frame that opened it" {
    const data = "RIFF" ++ "\x2c\x00\x00\x00" ++ "WAVE" ++
        "fmt " ++ "\x10\x00\x00\x00" ++
        "\x01\x00\x01\x00" ++ "\x80\xbb\x00\x00" ++
        "\x00\x77\x01\x00" ++ "\x02\x00\x10\x00" ++
        "data" ++ "\x08\x00\x00\x00" ++
        "\x00\x80\x00\x00\xff\x7f\x00\x40";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "owned.wav", .data = data });
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/owned.wav",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(path);

    const Opener = struct {
        fn load(allocator: std.mem.Allocator, file_path: []const u8) !source_session.SourceSession {
            // Nothing that backs the decoder may live in this frame.
            return LoadedSource.open(
                allocator,
                std.testing.io,
                registry_api.CodecRegistry.builtins(),
                file_path,
            );
        }
    };

    var session = try Opener.load(std.testing.allocator, path);
    defer session.deinit();
    try std.testing.expect(session.owned_source != null);

    var samples: [4]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try session.readFrames(&samples, .{ .mode = .track }));
    try std.testing.expectEqualSlices(f32, &.{ -1, 0, 32767.0 / 32768.0, 0.5 }, &samples);
}

test "a moved loaded source still releases its file after its decoder" {
    const data = "RIFF" ++ "\x24\x00\x00\x00" ++ "WAVE" ++
        "fmt " ++ "\x10\x00\x00\x00" ++
        "\x01\x00\x01\x00" ++ "\x80\xbb\x00\x00" ++
        "\x00\x77\x01\x00" ++ "\x02\x00\x10\x00" ++
        "data" ++ "\x00\x00\x00\x00";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "moved.wav", .data = data });
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/moved.wav",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(path);

    const session = try LoadedSource.open(
        std.testing.allocator,
        std.testing.io,
        registry_api.CodecRegistry.builtins(),
        path,
    );
    // Moving the session by value must not invalidate the decoder's source.
    var queue = source_session.SourceQueue.init(session);
    defer queue.deinit();
    try std.testing.expectEqual(@as(u16, 1), queue.format().channels);
}
