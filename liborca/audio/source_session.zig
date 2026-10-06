const std = @import("std");
const buffer = @import("buffer.zig");
const decoder_api = @import("../codec/decoder.zig");
const kernels = @import("kernels.zig");
const processing = @import("processing.zig");
const render = @import("render.zig");

/// Producer-owned backing storage for a SourceSession's decoder.
///
/// A Decoder holds a `ReadableSource` that borrows whatever object produced it.
/// When that object is not guaranteed to outlive the session by construction —
/// which is every case outside a single stack frame — the session must own it
/// and release it *strictly after* the decoder. See `loaded_source.zig`.
pub const OwnedSource = struct {
    context: *anyopaque,
    release: *const fn (context: *anyopaque) void,
};

/// Codec-neutral producer-side lifetime. Decoder-specific state remains behind
/// Decoder's Orca-owned interface. A session with an `owned_source` is
/// self-contained: nothing in the caller's frame has to outlive it.
pub const SourceSession = struct {
    decoder: decoder_api.Decoder,
    owned_source: ?OwnedSource = null,
    next_frame: u64 = 0,
    eof: bool = false,
    /// Linear loudness corrections for *these* bytes, already converted from
    /// decibels and capped against their peaks: the entry's own, and its
    /// Release's as a whole. Null means no usable measurement, which is the
    /// honest answer for a file the Library has never analyzed, for one whose
    /// audio has changed since it was, and for a Release not every Track of
    /// which is measured.
    ///
    /// It lives on the session — not on the Player — because a gapless
    /// transition puts two entries' prepared blocks in the pipe at once, and a
    /// Player-level multiplier cannot be right for both. Whoever opens the
    /// entry sets this once; every path that produces a session (hard load,
    /// auto-advance, format switch, seek re-open) therefore carries the right
    /// correction by construction rather than by remembering to publish one.
    ///
    /// Whether it is *applied* is not recorded here: that is
    /// `ReplayGainSettings`, a property of the Player, and conflating the two
    /// would leave sessions carrying a stale answer after a settings change.
    /// `shares_release` is the one exception, because it depends on the queue
    /// around the entry; the lane that reorders the queue refreshes it.
    replay_gain: processing.EntryReplayGain = .{},

    pub fn init(decoder: decoder_api.Decoder) SourceSession {
        return .{ .decoder = decoder };
    }

    /// Takes ownership of `source`, which is released after `decoder`.
    pub fn initOwned(decoder: decoder_api.Decoder, source: OwnedSource) SourceSession {
        return .{ .decoder = decoder, .owned_source = source };
    }

    pub fn deinit(self: *SourceSession) void {
        // Order matters: the decoder may still read through the source while
        // tearing down, so the backing source is released last.
        self.decoder.deinit();
        if (self.owned_source) |source| source.release(source.context);
        self.* = undefined;
    }

    pub fn seek(self: *SourceSession, frame: u64) !void {
        const target = if (self.decoder.frame_count) |count| @min(frame, count) else frame;
        try self.decoder.seek(target);
        self.next_frame = target;
        self.eof = if (self.decoder.frame_count) |count| target == count else false;
    }

    /// Decodes into `samples`, scaled by the correction `settings` pick from
    /// this entry's own.
    ///
    /// This is the single place the correction is applied, and it is applied to
    /// exactly the frames this decoder produced. That is what makes a gapless
    /// transition correct: one canonical block is filled from two sessions
    /// across the boundary, so a value chosen per block would be wrong for part
    /// of it, while a value applied per decode never can be.
    ///
    /// `settings` are read from the Player on every call rather than baked in
    /// at open, so changing it takes effect as soon as the already-decoded
    /// render-ahead drains instead of at the next track.
    pub fn readFrames(self: *SourceSession, samples: []f32, settings: processing.ReplayGainSettings) !usize {
        if (self.eof) return 0;
        const frames = try self.decoder.readFrames(samples);
        self.next_frame += frames;
        if (frames == 0 or
            (self.decoder.frame_count != null and self.next_frame == self.decoder.frame_count.?))
        {
            self.eof = true;
        }
        // Exactly unity is left alone, so `off` and an unmeasured entry cost no
        // arithmetic and cannot round the audio they pass through.
        const multiplier = self.replay_gain.applied(settings).multiplier;
        if (multiplier != 1)
            kernels.gain(samples[0 .. frames * self.decoder.format.channels], multiplier);
        return frames;
    }

    /// Reclaim callback-consumed blocks and prepare as many future blocks as
    /// bounded pool/queue capacity permits. This is the only file-I/O lane.
    pub fn prime(
        self: *SourceSession,
        comptime queue_capacity: usize,
        pipe: *render.RenderPipe(queue_capacity),
        pool: *buffer.BlockPool,
        epoch: u32,
        entry_serial: u32,
        settings: processing.ReplayGainSettings,
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
            const frames = self.readFrames(samples, settings) catch |err| {
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
                .epoch = epoch,
                .entry_serial = entry_serial,
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
    /// Identifies the entry whose blocks are currently being prepared. It is
    /// carried on every ReadyBlock and never compared by the callback, so a
    /// gapless transition can append successor blocks under the same epoch.
    current_entry_serial: u32 = 1,
    next_entry_serial: u32 = 0,
    entry_serial_counter: u32 = 1,
    transitions_queued: u64 = 0,

    pub fn init(current: SourceSession) SourceQueue {
        return .{ .current = current };
    }

    pub fn deinit(self: *SourceQueue) void {
        self.current.deinit();
        if (self.next) |*next| next.deinit();
        self.* = undefined;
    }

    /// Continues entry numbering from a previous queue, so a serial identifies
    /// one queue entry for the whole life of a Player rather than only within
    /// one `SourceQueue`. Without this, the first entry of every replacement
    /// queue would reuse serial 1 and now-playing could resolve to the wrong
    /// track after a skip.
    pub fn rebaseSerials(self: *SourceQueue, previous: u32) void {
        self.entry_serial_counter = previous;
        self.current_entry_serial = self.nextSerial();
    }

    pub fn format(self: *const SourceQueue) @import("pcm.zig").Format {
        return self.current.decoder.format;
    }

    pub fn codec(self: *const SourceQueue) []const u8 {
        return self.current.decoder.codec;
    }

    pub fn sourceFormat(self: *const SourceQueue) @import("pcm.zig").Format {
        return self.current.decoder.source_format orelse self.current.decoder.format;
    }

    pub fn sourceDeclared(self: *const SourceQueue) bool {
        return self.current.decoder.source_format != null;
    }

    pub fn seek(self: *SourceQueue, frame: u64) !void {
        try self.current.seek(frame);
    }

    pub fn primeNext(self: *SourceQueue, next: SourceSession) !void {
        if (self.next != null) return error.NextSourceAlreadyPrimed;
        if (!formatsMatch(self.current.decoder.format, next.decoder.format))
            return error.GaplessFormatMismatch;
        self.next = next;
        self.next_entry_serial = self.nextSerial();
    }

    pub const DecodedBlock = struct {
        frames: usize,
        /// The entry of the block's first frame, not the entry decoding last.
        entry_serial: u32,
        successor: render.Successor = .{},
    };

    /// Decode canonical PCM without assigning it to an output. The control
    /// lane can process this Player-scoped block once, then copy it into each
    /// independently owned Zone pipeline.
    pub fn readBlock(self: *SourceQueue, samples: []f32, settings: processing.ReplayGainSettings) !DecodedBlock {
        const channels = self.current.decoder.format.channels;
        if (samples.len % channels != 0) return error.ChannelMismatch;
        const capacity = samples.len / channels;
        var block: DecodedBlock = .{ .frames = 0, .entry_serial = self.current_entry_serial };
        while (block.frames < capacity) {
            const offset = block.frames * channels;
            block.frames += try self.current.readFrames(samples[offset..], settings);
            if (!self.current.eof) break;
            if (!self.advance()) break;
            if (block.frames == 0) {
                block.entry_serial = self.current_entry_serial;
            } else if (block.frames < capacity) {
                block.successor = .{ .serial = self.current_entry_serial, .frame = @intCast(block.frames) };
            }
        }
        return block;
    }

    pub fn readFrames(self: *SourceQueue, samples: []f32, settings: processing.ReplayGainSettings) !usize {
        return (try self.readBlock(samples, settings)).frames;
    }

    pub fn prime(
        self: *SourceQueue,
        comptime queue_capacity: usize,
        pipe: *render.RenderPipe(queue_capacity),
        pool: *buffer.BlockPool,
        epoch: u32,
        settings: processing.ReplayGainSettings,
    ) !usize {
        var prepared = try self.current.prime(
            queue_capacity,
            pipe,
            pool,
            epoch,
            self.current_entry_serial,
            settings,
        );
        if (self.current.eof and self.advance()) {
            prepared += try self.current.prime(
                queue_capacity,
                pipe,
                pool,
                epoch,
                self.current_entry_serial,
                settings,
            );
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
        self.current_entry_serial = self.next_entry_serial;
        self.next_entry_serial = 0;
        self.transitions_queued += 1;
        return true;
    }

    fn nextSerial(self: *SourceQueue) u32 {
        self.entry_serial_counter +%= 1;
        if (self.entry_serial_counter == 0) self.entry_serial_counter = 1;
        return self.entry_serial_counter;
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
    try std.testing.expectEqual(@as(usize, 2), try session.prime(2, &pipe, &pool, 3, 1, .{ .mode = .track }));
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
    try std.testing.expectEqual(@as(usize, 2), try sources.prime(4, &pipe, &pool, 1, .{ .mode = .track }));
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

const ConstantDecoder = struct {
    value: f32,
    remaining: usize,

    fn decoder(self: *ConstantDecoder) @import("../codec/decoder.zig").Decoder {
        return .{
            .context = self,
            // A test double still has to name its encoding: canonical float PCM.
            .codec = @import("../codec/decoder.zig").codec_id.pcm_float,
            .vtable = &.{ .read_frames = read, .seek = seekTo, .deinit = release },
            .format = .{
                .sample_format = .float_32,
                .channels = 1,
                .sample_rate = 48_000,
                .bits_per_sample = 32,
                .bytes_per_frame = 4,
            },
            .frame_count = 2,
        };
    }

    fn read(context: *anyopaque, output: []f32) !usize {
        const self: *ConstantDecoder = @ptrCast(@alignCast(context));
        const count = @min(output.len, self.remaining);
        @memset(output[0..count], self.value);
        self.remaining -= count;
        return count;
    }

    fn seekTo(_: *anyopaque, _: u64) !void {}
    fn release(_: *anyopaque) void {}
};

test "a gapless transition keeps the epoch and only changes the entry serial" {
    var first_decoder: ConstantDecoder = .{ .value = 0.25, .remaining = 2 };
    var second_decoder: ConstantDecoder = .{ .value = 0.5, .remaining = 2 };
    var sources = SourceQueue.init(SourceSession.init(first_decoder.decoder()));
    defer sources.deinit();
    const first_serial = sources.current_entry_serial;
    try sources.primeNext(SourceSession.init(second_decoder.decoder()));
    try std.testing.expect(sources.next_entry_serial != first_serial);

    var pool = try buffer.BlockPool.init(std.testing.allocator, 4, 2, 1);
    defer pool.deinit();
    var pipe: render.RenderPipe(4) = .{};
    // Both tracks are prepared under one epoch, so the callback never discards
    // the successor's audio and the transition stays gapless.
    try std.testing.expectEqual(@as(usize, 2), try sources.prime(4, &pipe, &pool, 6, .{ .mode = .track }));
    const second_serial = sources.current_entry_serial;
    try std.testing.expect(first_serial != second_serial);

    var output: [2]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), pipe.render(&pool, 1, 6, &output));
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.25 }, &output);
    try std.testing.expectEqual(first_serial, pipe.rendered_entry_serial.load(.monotonic));

    try std.testing.expectEqual(@as(usize, 2), pipe.render(&pool, 1, 6, &output));
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.5 }, &output);
    try std.testing.expectEqual(second_serial, pipe.rendered_entry_serial.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), pipe.underruns.load(.monotonic));
}

test "a decoded block names the successor that starts partway through it" {
    var first_decoder: ConstantDecoder = .{ .value = 0.25, .remaining = 2 };
    var second_decoder: ConstantDecoder = .{ .value = 0.5, .remaining = 2 };
    var sources = SourceQueue.init(SourceSession.init(first_decoder.decoder()));
    defer sources.deinit();
    const first_serial = sources.current_entry_serial;
    try sources.primeNext(SourceSession.init(second_decoder.decoder()));
    const second_serial = sources.next_entry_serial;

    var samples: [3]f32 = @splat(0);
    const mixed = try sources.readBlock(&samples, .{ .mode = .off });
    try std.testing.expectEqual(@as(usize, 3), mixed.frames);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.25, 0.5 }, &samples);
    try std.testing.expectEqual(first_serial, mixed.entry_serial);
    try std.testing.expectEqual(second_serial, mixed.successor.serial);
    try std.testing.expectEqual(@as(u32, 2), mixed.successor.frame);

    const rest = try sources.readBlock(&samples, .{ .mode = .off });
    try std.testing.expectEqual(@as(usize, 1), rest.frames);
    try std.testing.expectEqual(second_serial, rest.entry_serial);
    try std.testing.expectEqual(@as(u32, 0), rest.successor.serial);
}

test "a decoded block that ends with its entry leaves the successor to the next block" {
    var first_decoder: ConstantDecoder = .{ .value = 0.25, .remaining = 2 };
    var second_decoder: ConstantDecoder = .{ .value = 0.5, .remaining = 2 };
    var sources = SourceQueue.init(SourceSession.init(first_decoder.decoder()));
    defer sources.deinit();
    const first_serial = sources.current_entry_serial;
    try sources.primeNext(SourceSession.init(second_decoder.decoder()));
    const second_serial = sources.next_entry_serial;

    var samples: [2]f32 = @splat(0);
    const first = try sources.readBlock(&samples, .{ .mode = .off });
    try std.testing.expectEqual(@as(usize, 2), first.frames);
    try std.testing.expectEqual(first_serial, first.entry_serial);
    try std.testing.expectEqual(@as(u32, 0), first.successor.serial);

    const second = try sources.readBlock(&samples, .{ .mode = .off });
    try std.testing.expectEqual(@as(usize, 2), second.frames);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.5 }, &samples);
    try std.testing.expectEqual(second_serial, second.entry_serial);
    try std.testing.expectEqual(@as(u32, 0), second.successor.serial);
}

test "a successor primed after its predecessor ended owns the whole next block" {
    var first_decoder: ConstantDecoder = .{ .value = 0.25, .remaining = 2 };
    var second_decoder: ConstantDecoder = .{ .value = 0.5, .remaining = 2 };
    var sources = SourceQueue.init(SourceSession.init(first_decoder.decoder()));
    defer sources.deinit();

    var samples: [4]f32 = @splat(0);
    try std.testing.expectEqual(@as(usize, 2), (try sources.readBlock(&samples, .{ .mode = .off })).frames);
    try std.testing.expect(sources.finishedDecoding());
    try sources.primeNext(SourceSession.init(second_decoder.decoder()));
    const second_serial = sources.next_entry_serial;

    const block = try sources.readBlock(&samples, .{ .mode = .off });
    try std.testing.expectEqual(@as(usize, 2), block.frames);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.5 }, samples[0..2]);
    try std.testing.expectEqual(second_serial, block.entry_serial);
    try std.testing.expectEqual(@as(u32, 0), block.successor.serial);
}

test "each entry's frames are scaled by that entry's own correction across a transition" {
    // One Player-level multiplier is wrong during a gapless transition,
    // because the pipe holds two entries' audio at once. Here one canonical
    // read straddles the boundary, so a correction chosen per block — let
    // alone per Player — could not be right for both halves of it.
    var first_decoder: ConstantDecoder = .{ .value = 1, .remaining = 2 };
    var second_decoder: ConstantDecoder = .{ .value = 1, .remaining = 2 };
    var sources = SourceQueue.init(SourceSession.init(first_decoder.decoder()));
    defer sources.deinit();
    sources.current.replay_gain = .{ .track = .{ .gain = 0.25 } };
    var successor = SourceSession.init(second_decoder.decoder());
    successor.replay_gain = .{ .track = .{ .gain = 2 } };
    try sources.primeNext(successor);

    var samples: [4]f32 = @splat(0);
    try std.testing.expectEqual(@as(usize, 4), try sources.readFrames(&samples, .{ .mode = .track }));
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.25, 2, 2 }, &samples);
}

test "an entry with no measurement plays at unity rather than its predecessor's gain" {
    var first_decoder: ConstantDecoder = .{ .value = 1, .remaining = 2 };
    var second_decoder: ConstantDecoder = .{ .value = 1, .remaining = 2 };
    var sources = SourceQueue.init(SourceSession.init(first_decoder.decoder()));
    defer sources.deinit();
    sources.current.replay_gain = .{ .track = .{ .gain = 0.25 } };
    // Default: nothing the Library could vouch for, so nothing is applied.
    try sources.primeNext(SourceSession.init(second_decoder.decoder()));

    var samples: [4]f32 = @splat(0);
    try std.testing.expectEqual(@as(usize, 4), try sources.readFrames(&samples, .{ .mode = .track }));
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.25, 1, 1 }, &samples);
}

test "replay gain off leaves every entry at exactly unity" {
    var first_decoder: ConstantDecoder = .{ .value = 1, .remaining = 2 };
    var second_decoder: ConstantDecoder = .{ .value = 1, .remaining = 2 };
    var sources = SourceQueue.init(SourceSession.init(first_decoder.decoder()));
    defer sources.deinit();
    sources.current.replay_gain = .{ .track = .{ .gain = 0.25 } };
    var successor = SourceSession.init(second_decoder.decoder());
    successor.replay_gain = .{ .track = .{ .gain = 2 } };
    try sources.primeNext(successor);

    var samples: [4]f32 = @splat(0);
    try std.testing.expectEqual(@as(usize, 4), try sources.readFrames(&samples, .{ .mode = .off }));
    // Exact equality, not approximate: `off` means the samples are untouched.
    try std.testing.expectEqualSlices(f32, &.{ 1, 1, 1, 1 }, &samples);
}

test "album mode scales an entry by its album correction, or by its own when it has none" {
    var first_decoder: ConstantDecoder = .{ .value = 1, .remaining = 2 };
    var second_decoder: ConstantDecoder = .{ .value = 1, .remaining = 2 };
    var sources = SourceQueue.init(SourceSession.init(first_decoder.decoder()));
    defer sources.deinit();
    sources.current.replay_gain = .{ .track = .{ .gain = 0.25 }, .album = .{ .gain = 0.5 } };
    var successor = SourceSession.init(second_decoder.decoder());
    successor.replay_gain = .{ .track = .{ .gain = 2 } };
    try sources.primeNext(successor);

    var samples: [4]f32 = @splat(0);
    try std.testing.expectEqual(@as(usize, 4), try sources.readFrames(&samples, .{ .mode = .album }));
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.5, 2, 2 }, &samples);
}
