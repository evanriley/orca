const std = @import("std");
const buffer = @import("buffer.zig");
const decoder_api = @import("../codec/decoder.zig");
const render = @import("render.zig");

/// Codec-neutral producer-side lifetime. Decoder-specific state remains behind
/// Decoder's Orca-owned interface and the underlying source must outlive it.
pub const SourceSession = struct {
    decoder: decoder_api.Decoder,
    next_frame: u64 = 0,
    eof: bool = false,

    pub fn init(decoder: decoder_api.Decoder) SourceSession {
        return .{ .decoder = decoder };
    }

    pub fn deinit(self: *SourceSession) void {
        self.decoder.deinit();
        self.* = undefined;
    }

    pub fn seek(self: *SourceSession, frame: u64) !void {
        const target = if (self.decoder.frame_count) |count| @min(frame, count) else frame;
        try self.decoder.seek(target);
        self.next_frame = target;
        self.eof = if (self.decoder.frame_count) |count| target == count else false;
    }

    /// Reclaim callback-consumed blocks and prepare as many future blocks as
    /// bounded pool/queue capacity permits. This is the only file-I/O lane.
    pub fn prime(
        self: *SourceSession,
        comptime queue_capacity: usize,
        pipe: *render.RenderPipe(queue_capacity),
        pool: *buffer.BlockPool,
        generation: u64,
    ) !usize {
        pipe.reclaim(pool);
        if (self.eof) return 0;
        var prepared: usize = 0;
        while (pool.acquire()) |index| {
            const samples = pool.samples(index);
            if (samples.len % self.decoder.format.channels != 0) {
                pool.release(index);
                return error.ChannelMismatch;
            }
            const frames = self.decoder.readFrames(samples) catch |err| {
                pool.release(index);
                return err;
            };
            if (frames == 0) {
                pool.release(index);
                self.eof = true;
                break;
            }
            if (!pipe.submit(.{
                .index = index,
                .frames = @intCast(frames),
                .generation = generation,
            })) {
                pool.release(index);
                break;
            }
            self.next_frame += frames;
            prepared += 1;
            if (self.decoder.frame_count != null and self.next_frame == self.decoder.frame_count.?) {
                self.eof = true;
                break;
            }
        }
        return prepared;
    }
};

test "WAV source session primes bounded canonical blocks" {
    const data = "RIFF" ++ "\x2c\x00\x00\x00" ++ "WAVE" ++
        "fmt " ++ "\x10\x00\x00\x00" ++
        "\x01\x00\x01\x00" ++ "\x80\xbb\x00\x00" ++
        "\x00\x77\x01\x00" ++ "\x02\x00\x10\x00" ++
        "data" ++ "\x08\x00\x00\x00" ++
        "\x00\x80\x00\x00\xff\x7f\x00\x40";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "source.wav", .data = data });
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/source.wav",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(path);
    var local = try @import("../storage/source.zig").LocalFileSource.open(std.testing.io, path);
    defer local.close();

    const registry = @import("../codec/registry.zig").CodecRegistry.builtins();
    var session = SourceSession.init(try registry.openDetected(
        std.testing.allocator,
        local.readable(),
    ));
    defer session.deinit();
    var pool = try buffer.BlockPool.init(std.testing.allocator, 2, 2, 1);
    defer pool.deinit();
    var pipe: render.RenderPipe(2) = .{};
    try std.testing.expectEqual(@as(usize, 2), try session.prime(2, &pipe, &pool, 3));
    try std.testing.expect(session.eof);

    var output: [4]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 4), pipe.render(&pool, 1, 3, &output));
    try std.testing.expectEqualSlices(f32, &.{ -1, 0, 32767.0 / 32768.0, 0.5 }, &output);
    pipe.reclaim(&pool);
    try std.testing.expectEqual(@as(usize, 2), pool.free_len);
}
