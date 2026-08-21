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

    pub fn readFrames(self: *SourceSession, samples: []f32) !usize {
        if (self.eof) return 0;
        const frames = try self.decoder.readFrames(samples);
        self.next_frame += frames;
        if (frames == 0 or
            (self.decoder.frame_count != null and self.next_frame == self.decoder.frame_count.?))
        {
            self.eof = true;
        }
        return frames;
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
            const frames = self.readFrames(samples) catch |err| {
                pool.release(index);
                return err;
            };
            if (frames == 0) {
                pool.release(index);
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
            prepared += 1;
            if (self.eof) break;
        }
        return prepared;
    }
};

/// Owns the currently decoding source and one prepared successor. Once the
/// current decoder reaches EOF, successor blocks are appended to the same SPSC
/// stream before already-queued current audio is exhausted.
pub const SourceQueue = struct {
    current: SourceSession,
    next: ?SourceSession = null,
    transitions_queued: u64 = 0,

    pub fn init(current: SourceSession) SourceQueue {
        return .{ .current = current };
    }

    pub fn deinit(self: *SourceQueue) void {
        self.current.deinit();
        if (self.next) |*next| next.deinit();
        self.* = undefined;
    }

    pub fn format(self: *const SourceQueue) @import("pcm.zig").Format {
        return self.current.decoder.format;
    }

    pub fn seek(self: *SourceQueue, frame: u64) !void {
        try self.current.seek(frame);
    }

    pub fn primeNext(self: *SourceQueue, next: SourceSession) !void {
        if (self.next != null) return error.NextSourceAlreadyPrimed;
        if (!formatsMatch(self.current.decoder.format, next.decoder.format))
            return error.GaplessFormatMismatch;
        self.next = next;
    }

    /// Decode canonical PCM without assigning it to an output. The control
    /// lane can process this Player-scoped block once, then copy it into each
    /// independently owned Zone pipeline.
    pub fn readFrames(self: *SourceQueue, samples: []f32) !usize {
        const channels = self.current.decoder.format.channels;
        if (samples.len % channels != 0) return error.ChannelMismatch;
        var total_frames: usize = 0;
        while (total_frames < samples.len / channels) {
            const offset = total_frames * channels;
            const frames = try self.current.readFrames(samples[offset..]);
            total_frames += frames;
            if (!self.current.eof) break;
            if (!self.advance()) break;
        }
        return total_frames;
    }

    pub fn prime(
        self: *SourceQueue,
        comptime queue_capacity: usize,
        pipe: *render.RenderPipe(queue_capacity),
        pool: *buffer.BlockPool,
        generation: u64,
    ) !usize {
        var prepared = try self.current.prime(queue_capacity, pipe, pool, generation);
        if (self.current.eof and self.advance()) {
            prepared += try self.current.prime(queue_capacity, pipe, pool, generation);
        }
        return prepared;
    }

    pub fn finishedDecoding(self: *const SourceQueue) bool {
        return self.current.eof and self.next == null;
    }

    fn advance(self: *SourceQueue) bool {
        if (self.next == null) return false;
        self.current.deinit();
        self.current = self.next.?;
        self.next = null;
        self.transitions_queued += 1;
        return true;
    }
};

fn formatsMatch(a: @import("pcm.zig").Format, b: @import("pcm.zig").Format) bool {
    return a.sample_format == b.sample_format and
        a.channels == b.channels and
        a.sample_rate == b.sample_rate and
        a.bits_per_sample == b.bits_per_sample and
        a.bytes_per_frame == b.bytes_per_frame;
}

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

test "next source is queued before current prepared audio is consumed" {
    const first_data = "RIFF" ++ "\x28\x00\x00\x00" ++ "WAVE" ++
        "fmt " ++ "\x10\x00\x00\x00" ++
        "\x01\x00\x01\x00" ++ "\x80\xbb\x00\x00" ++
        "\x00\x77\x01\x00" ++ "\x02\x00\x10\x00" ++
        "data" ++ "\x04\x00\x00\x00" ++ "\x00\x20\x00\x40";
    const next_data = "RIFF" ++ "\x28\x00\x00\x00" ++ "WAVE" ++
        "fmt " ++ "\x10\x00\x00\x00" ++
        "\x01\x00\x01\x00" ++ "\x80\xbb\x00\x00" ++
        "\x00\x77\x01\x00" ++ "\x02\x00\x10\x00" ++
        "data" ++ "\x04\x00\x00\x00" ++ "\x00\x60\xff\x7f";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "first.wav", .data = first_data });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "next.wav", .data = next_data });
    const first_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/first.wav",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(first_path);
    const next_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/next.wav",
        .{temporary.sub_path},
    );
    defer std.testing.allocator.free(next_path);
    const storage = @import("../storage/source.zig");
    var first_file = try storage.LocalFileSource.open(std.testing.io, first_path);
    defer first_file.close();
    var next_file = try storage.LocalFileSource.open(std.testing.io, next_path);
    defer next_file.close();
    const codecs = @import("../codec/registry.zig").CodecRegistry.builtins();
    var sources = SourceQueue.init(SourceSession.init(try codecs.openDetected(
        std.testing.allocator,
        first_file.readable(),
    )));
    defer sources.deinit();
    try sources.primeNext(SourceSession.init(try codecs.openDetected(
        std.testing.allocator,
        next_file.readable(),
    )));

    var pool = try buffer.BlockPool.init(std.testing.allocator, 4, 2, 1);
    defer pool.deinit();
    var pipe: render.RenderPipe(4) = .{};
    try std.testing.expectEqual(@as(usize, 2), try sources.prime(4, &pipe, &pool, 1));
    try std.testing.expectEqual(@as(u64, 1), sources.transitions_queued);
    try std.testing.expect(sources.finishedDecoding());

    var output: [4]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 4), pipe.render(&pool, 1, 1, &output));
    try std.testing.expectEqualSlices(
        f32,
        &.{ 0.25, 0.5, 0.75, 32767.0 / 32768.0 },
        &output,
    );
}
