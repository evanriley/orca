const std = @import("std");
const buffer = @import("buffer.zig");
const fanout = @import("fanout.zig");
const pcm = @import("pcm.zig");
const processing = @import("processing.zig");
const render = @import("render.zig");
const source_session = @import("source_session.zig");

pub const TransportState = enum(u8) { stopped, playing, paused };

pub const Snapshot = struct {
    state: TransportState,
    /// Transport epoch. Bumped by seek and stop; compared by the render
    /// callback so audio prepared before a discontinuity is discarded.
    epoch: u32,
    position_frames: u64,
};

pub const FanoutResult = struct {
    frames: usize,
    zones_accepted: usize,
};

/// A seek the control lane could not apply itself, because the entry it targets
/// is no longer the entry being decoded. The engine services it by re-opening
/// the audible entry; see `Player.seek`.
pub const PendingSeek = struct {
    /// Entry serial the seek was issued against — the *audible* one.
    serial: u32,
    frame: u64,
};

/// Timeline shape of one queue entry, remembered by serial.
///
/// The decode cursor leads the audible one by the whole render-ahead depth, so
/// `sources.current` already describes the *next* track while the previous one
/// is still being heard. Reporting duration from it makes now-playing advertise
/// the successor's length for the whole lookahead window. Keeping a small
/// serial-keyed ring lets duration be resolved through the same audible cursor
/// position already uses, so identity, duration and position agree by
/// construction rather than by coincidence.
const EntryInfo = struct {
    serial: u32 = 0,
    sample_rate: u32 = 0,
    frame_count: u64 = 0,
    /// The entry's own loudness correction, so a host can report what the
    /// audio it is hearing is being multiplied by. The correction is applied
    /// by the session that decodes the entry, not from here.
    replay_gain: f32 = 1,
    source_format: ?pcm.Format = null,
    source_declared: bool = false,
    codec: []const u8 = "",
};

/// Only the current and the one primed successor can be in flight, so this only
/// has to outlive the render-ahead depth. Eight matches the playback queue's
/// serial map for the same reason.
const entry_info_len: usize = 8;

pub const Player = struct {
    state: std.atomic.Value(TransportState) = .init(.stopped),
    /// Transport epoch: bumped on seek and stop, carried on every prepared
    /// block, and the only field the render callback compares. Track identity
    /// travels separately as `ReadyBlock.entry_serial`.
    epoch: std.atomic.Value(u32) = .init(1),
    position_frames: std.atomic.Value(u64) = .init(0),
    /// Frame the current epoch started at. Authoritative position is derived on
    /// the control lane as `epoch_base_frames + clock zone frames-since-epoch`,
    /// which is why the two halves are stamped together by every discontinuity.
    epoch_base_frames: std.atomic.Value(u64) = .init(0),
    /// Read by the render callback on the real-time lane. When set, the
    /// callback emits silence without consuming blocks or counting underruns.
    /// A freshly constructed Player is stopped, so it starts silenced.
    silenced: std.atomic.Value(bool) = .init(true),
    sources: ?source_session.SourceQueue = null,
    /// Highest entry serial this Player has ever handed out. A `SourceQueue`
    /// numbers entries from its own base, so without carrying the counter
    /// across a replacement two different queue entries could share a serial
    /// and now-playing would resolve to the wrong track.
    serial_counter: u32 = 0,
    /// Canonical sample rate and total frame count of the source currently
    /// loaded, republished by whichever lane loads it. Both lanes that touch
    /// `sources` do so under the engine `quiesce`/`release` handshake, so these
    /// exist purely so a *host* can turn frames into milliseconds without
    /// stopping the producer to read the decoder.
    published_sample_rate: std.atomic.Value(u32) = .init(0),
    published_frame_count: std.atomic.Value(u64) = .init(0),
    /// Serial of the entry the render callback is actually emitting, published
    /// by the engine from the clock Zone. Zero until something has rendered, in
    /// which case the decode cursor is the only answer available.
    audible_entry_serial: std.atomic.Value(u32) = .init(0),
    drained: std.atomic.Value(bool) = .init(false),
    /// Loudness correction of the entry being *heard*, republished alongside
    /// its timeline shape. Reporting only: the correction is applied by the
    /// session that decodes the entry, so this is what a host may display
    /// rather than what any lane multiplies by.
    published_replay_gain: std.atomic.Value(f32) = .init(1),
    /// Whether entries are decoded with their own loudness correction. An
    /// atomic because the decode lane reads it on every canonical block, which
    /// is what makes turning correction off take effect as the already-decoded
    /// render-ahead drains rather than at the next track.
    replay_gain_mode: std.atomic.Value(processing.ReplayGainMode) = .init(.track),
    /// Timeline shape per entry serial. Plain state, written by whichever lane
    /// owns `sources` — the control lane under `quiesce`, or the engine thread.
    entry_info: [entry_info_len]EntryInfo = @splat(.{}),
    entry_info_head: usize = 0,
    /// A seek whose target entry is no longer the one being decoded. Set by the
    /// control lane under `quiesce`, taken by the engine on its next pass.
    pending_seek: ?PendingSeek = null,

    pub fn deinit(self: *Player) void {
        if (self.sources) |*sources| sources.deinit();
        self.* = undefined;
    }

    pub fn loadSource(self: *Player, source: source_session.SourceSession) !void {
        if (self.sources != null) return error.PlayerSourceAlreadyLoaded;
        self.sources = source_session.SourceQueue.init(source);
        self.sources.?.rebaseSerials(self.serial_counter);
        self.adoptLoadedEntryAsAudible();
        self.resetTimeline();
        self.publishSourceInfo();
    }

    /// Replaces the whole SourceQueue and retires the prepared audio that
    /// belonged to it. Bumping the epoch is what makes this safe without any
    /// queue surgery: blocks already handed to a callback under the old epoch
    /// are discarded there rather than being chased down and removed.
    pub fn replaceSource(self: *Player, source: source_session.SourceSession) void {
        self.releaseSources();
        self.pending_seek = null;
        self.sources = source_session.SourceQueue.init(source);
        self.sources.?.rebaseSerials(self.serial_counter);
        self.adoptLoadedEntryAsAudible();
        self.resetTimeline();
        self.publishSourceInfo();
        _ = self.epoch.fetchAdd(1, .acq_rel);
    }

    /// A hard load retires every prepared block through the epoch bump, so the
    /// entry that becomes audible *is* the one just loaded. The serial the
    /// callback last published describes audio that no longer exists, and the
    /// callback republishes only when the audible entry changes — so without
    /// this the audible cursor would be pinned to a retired entry until the next
    /// transition.
    fn adoptLoadedEntryAsAudible(self: *Player) void {
        self.audible_entry_serial.store(self.sources.?.current_entry_serial, .release);
    }

    /// Drops every decoder without touching the playback queue above it. This
    /// is what `stop` means: the transport stops and its sources are released,
    /// while the entries and cursor the user assembled survive.
    pub fn releaseSources(self: *Player) void {
        if (self.sources) |*sources| {
            self.serial_counter = sources.entry_serial_counter;
            sources.deinit();
        }
        self.sources = null;
        self.pending_seek = null;
        self.audible_entry_serial.store(0, .release);
        self.forgetEntryInfo();
        self.publishSourceInfo();
    }

    /// Republishes the timeline shape hosts read. Called from the lane that owns
    /// `sources`, never from the render callback.
    ///
    /// It records the entry being *decoded* and publishes the entry being
    /// *heard*. Those are the same track except during the render-ahead window
    /// of a gapless transition, which is exactly the window in which publishing
    /// the decoded one made now-playing advertise the next track's duration
    /// while the previous one was still audible.
    pub fn publishSourceInfo(self: *Player) void {
        if (self.sources) |*sources| {
            self.recordEntryInfo(decodingEntryInfo(sources));
        }
        const audible = self.audibleEntryInfo();
        self.published_sample_rate.store(audible.sample_rate, .release);
        self.published_frame_count.store(audible.frame_count, .release);
        self.published_replay_gain.store(audible.replay_gain, .release);
    }

    /// Whether the decode lane is applying corrections at all.
    pub fn replayGainEnabled(self: *const Player) bool {
        return self.replay_gain_mode.load(.acquire) == .track;
    }

    /// The correction in force on the audio currently audible: the audible
    /// entry's own figure, or exactly 1 when correction is off.
    ///
    /// Gated at read rather than at publication so a mode change is reflected
    /// here as promptly as it is reflected in the audio.
    pub fn effectiveReplayGain(self: *const Player) f32 {
        if (!self.replayGainEnabled()) return 1;
        return self.published_replay_gain.load(.acquire);
    }

    /// Engine thread. Adopts the entry serial the render callback published, so
    /// duration, identity and position all resolve through one cursor.
    pub fn observeRenderedSerial(self: *Player, serial: u32) void {
        if (serial == 0) return;
        self.audible_entry_serial.store(serial, .release);
    }

    fn recordEntryInfo(self: *Player, info: EntryInfo) void {
        if (info.serial == 0) return;
        for (&self.entry_info) |*record| {
            if (record.serial != info.serial) continue;
            record.* = info;
            return;
        }
        self.entry_info[self.entry_info_head] = info;
        self.entry_info_head = (self.entry_info_head + 1) % entry_info_len;
    }

    fn decodingEntryInfo(sources: *const source_session.SourceQueue) EntryInfo {
        return .{
            .serial = sources.current_entry_serial,
            .sample_rate = sources.current.decoder.format.sample_rate,
            .frame_count = sources.current.decoder.frame_count orelse 0,
            .replay_gain = sources.current.replay_gain,
            .source_format = sources.sourceFormat(),
            .source_declared = sources.sourceDeclared(),
            .codec = sources.codec(),
        };
    }

    fn forgetEntryInfo(self: *Player) void {
        self.entry_info = @splat(.{});
        self.entry_info_head = 0;
    }

    /// Shape of the entry actually being heard. Falls back to the decoding entry
    /// when nothing has rendered yet, or when the audible serial is older than
    /// the ring remembers — in both cases the decode cursor is the only answer
    /// available, and it is the correct one for the first case.
    fn audibleEntryInfo(self: *const Player) EntryInfo {
        const sources = if (self.sources) |*value| value else return .{};
        const fallback = decodingEntryInfo(sources);
        const serial = self.audible_entry_serial.load(.acquire);
        if (serial == 0 or serial == sources.current_entry_serial) return fallback;
        for (self.entry_info) |record| {
            if (record.serial == serial) return record;
        }
        return fallback;
    }

    /// Frames in the entry currently being heard, when its decoder knows.
    /// Anchored on the audible cursor for the same reason duration is: a seek
    /// relative to "the end of this track" must mean the track the listener is
    /// hearing, not the one the producer has run ahead into.
    pub fn frameCount(self: *const Player) ?u64 {
        if (self.sources == null) return null;
        const frames = self.audibleEntryInfo().frame_count;
        return if (frames == 0) null else frames;
    }

    fn resetTimeline(self: *Player) void {
        self.position_frames.store(0, .release);
        self.epoch_base_frames.store(0, .release);
    }

    pub fn primeNextSource(self: *Player, source: source_session.SourceSession) !void {
        if (self.sources) |*sources| return sources.primeNext(source);
        return error.PlayerHasNoSource;
    }

    /// Single-Zone convenience that primes straight into one pool. Kept for
    /// tests and benchmarks only: the runtime path decodes once and fans out
    /// into independently owned Zone pools via `decodeProcessAndFanout`.
    pub fn prime(
        self: *Player,
        comptime queue_capacity: usize,
        pipe: *render.RenderPipe(queue_capacity),
        pool: *buffer.BlockPool,
    ) !usize {
        if (self.sources) |*sources| {
            return sources.prime(
                queue_capacity,
                pipe,
                pool,
                self.epoch.load(.acquire),
                self.replayGainEnabled(),
            );
        }
        return error.PlayerHasNoSource;
    }

    /// Producer/control-lane decode used by multi-Zone fanout. Decoder and
    /// source I/O never run on an output callback.
    pub fn decodeFrames(self: *Player, samples: []f32) !usize {
        if (self.sources) |*sources| return sources.readFrames(samples, self.replayGainEnabled());
        return error.PlayerHasNoSource;
    }

    pub fn format(self: *const Player) ?pcm.Format {
        return if (self.sources) |*sources| sources.format() else null;
    }

    pub fn sourceFormat(self: *const Player) ?pcm.Format {
        return if (self.sources) |*sources| sources.sourceFormat() else null;
    }

    /// The audible entry's source format and codec, resolved like its
    /// duration. Read under the engine handshake.
    pub fn audibleSource(self: *const Player) ?struct {
        format: pcm.Format,
        declared: bool,
        codec: []const u8,
    } {
        const info = self.audibleEntryInfo();
        const source = info.source_format orelse return null;
        return .{ .format = source, .declared = info.source_declared, .codec = info.codec };
    }

    pub fn decodeAndFanout(
        self: *Player,
        comptime capacity: usize,
        scratch: []f32,
        sinks: []fanout.ZoneSink(capacity),
    ) !FanoutResult {
        return self.decodeProcessAndFanout(capacity, scratch, null, sinks);
    }

    pub fn decodeProcessAndFanout(
        self: *Player,
        comptime capacity: usize,
        scratch: []f32,
        player_processor: ?processing.Processor,
        sinks: []fanout.ZoneSink(capacity),
    ) !FanoutResult {
        return self.decodeProcessAndFanoutUnderEpoch(
            capacity,
            scratch,
            player_processor,
            sinks,
            self.epoch.load(.acquire),
        );
    }

    /// Same fanout, under an epoch the caller has already published into every
    /// Zone's own atomic. The engine loads the epoch once, publishes it, and
    /// submits under it, so a Zone can never hold blocks stamped with an epoch
    /// its callback has not been told about.
    pub fn decodeProcessAndFanoutUnderEpoch(
        self: *Player,
        comptime capacity: usize,
        scratch: []f32,
        player_processor: ?processing.Processor,
        sinks: []fanout.ZoneSink(capacity),
        epoch: u32,
    ) !FanoutResult {
        const format_value = self.format() orelse return error.PlayerHasNoSource;
        const frames = try self.decodeFrames(scratch);
        const samples = scratch[0 .. frames * format_value.channels];
        if (player_processor) |processor|
            processor.process(samples, @intCast(frames), format_value.channels);
        return .{
            .frames = frames,
            .zones_accepted = if (frames == 0)
                0
            else
                fanout.submit(
                    capacity,
                    sinks,
                    samples,
                    @intCast(frames),
                    epoch,
                    self.entrySerial(),
                ),
        };
    }

    /// Queue entry whose PCM the producer is currently emitting. Zero when no
    /// source is loaded. Never compared by the render callback.
    pub fn entrySerial(self: *const Player) u32 {
        return if (self.sources) |*sources| sources.current_entry_serial else 0;
    }

    pub fn finishedDecoding(self: *const Player) bool {
        return if (self.sources) |*sources| sources.finishedDecoding() else true;
    }

    pub fn play(self: *Player) void {
        // Unsilence before publishing the state so the callback never observes
        // "playing" while still emitting silence.
        self.silenced.store(false, .release);
        self.state.store(.playing, .release);
    }

    /// Takes effect inside the very next render callback: prepared blocks stay
    /// queued, position stops advancing, and no underrun is recorded.
    pub fn pause(self: *Player) void {
        self.silenced.store(true, .release);
        self.state.store(.paused, .release);
    }

    pub fn stop(self: *Player) void {
        self.pending_seek = null;
        self.silenced.store(true, .release);
        self.state.store(.stopped, .release);
        self.position_frames.store(0, .release);
        self.epoch_base_frames.store(0, .release);
        _ = self.epoch.fetchAdd(1, .acq_rel);
    }

    /// Control lane, under the engine `quiesce` handshake.
    ///
    /// A seek means "move to this point in the track I am *hearing*". Because
    /// the producer runs a whole entry ahead, `sources.current` during a gapless
    /// transition is already the successor and its predecessor's decoder has
    /// been released — so seeking it would drop the listener into the following
    /// song. When that is the case the seek is recorded instead and the engine
    /// re-opens the audible entry on its next pass; the epoch bump published
    /// here retires the decode-ahead work in the meantime, through the same
    /// mechanism every other discontinuity uses.
    pub fn seek(self: *Player, frame: u64) !u32 {
        if (self.deferredSeekTarget()) |serial| {
            self.pending_seek = .{ .serial = serial, .frame = frame };
            self.position_frames.store(frame, .release);
            self.epoch_base_frames.store(frame, .release);
            return self.epoch.fetchAdd(1, .acq_rel) +% 1;
        }
        return self.seekCurrent(frame);
    }

    /// Serial of the audible entry when it is *not* the entry being decoded.
    /// Null means the two agree — or that nothing has rendered yet, in which
    /// case the decoding entry is the one that will become audible.
    fn deferredSeekTarget(self: *const Player) ?u32 {
        const sources = if (self.sources) |*value| value else return null;
        const audible = self.audible_entry_serial.load(.acquire);
        if (audible == 0 or audible == sources.current_entry_serial) return null;
        return audible;
    }

    /// Seeks the source that is actually loaded. The engine uses this after it
    /// has re-opened the audible entry, where deferring again would loop: the
    /// callback has not yet rendered the reopened entry, so the audible serial
    /// still names the retired one.
    pub fn seekCurrent(self: *Player, frame: u64) !u32 {
        self.pending_seek = null;
        if (self.sources) |*sources| try sources.seek(frame);
        self.position_frames.store(frame, .release);
        self.epoch_base_frames.store(frame, .release);
        return self.epoch.fetchAdd(1, .acq_rel) +% 1;
    }

    /// Engine thread. Claims a deferred seek, so servicing it can never observe
    /// the same request twice.
    pub fn takePendingSeek(self: *Player) ?PendingSeek {
        const request = self.pending_seek orelse return null;
        self.pending_seek = null;
        return request;
    }

    /// A hard transport switch retires a deferred seek with everything else it
    /// retires: the entry that seek named is no longer the one wanted.
    pub fn clearPendingSeek(self: *Player) void {
        self.pending_seek = null;
    }

    /// Retires prepared audio without moving the source. Used when the clock
    /// Zone is replaced: the promoted Zone's frame counter starts from zero, so
    /// the timeline has to be rebased onto the position already reported.
    pub fn stampEpoch(self: *Player) u32 {
        self.epoch_base_frames.store(self.position_frames.load(.acquire), .release);
        return self.epoch.fetchAdd(1, .acq_rel) +% 1;
    }

    pub fn snapshot(self: *const Player) Snapshot {
        return .{
            .state = self.state.load(.acquire),
            .epoch = self.epoch.load(.acquire),
            .position_frames = self.position_frames.load(.acquire),
        };
    }
};

test "seek advances the transport epoch instead of editing queues" {
    var player: Player = .{};
    const epoch = try player.seek(48_000);
    const current = player.snapshot();
    try std.testing.expectEqual(epoch, current.epoch);
    try std.testing.expectEqual(@as(u64, 48_000), current.position_frames);
}

const TestDecoder = struct {
    position: usize = 0,

    fn decoder(self: *TestDecoder) @import("../codec/decoder.zig").Decoder {
        return .{
            .context = self,
            // A test double still has to name its encoding: canonical float PCM.
            .codec = @import("../codec/decoder.zig").codec_id.pcm_float,
            .vtable = &.{
                .read_frames = read,
                .seek = seek,
                .deinit = deinit,
            },
            .format = .{
                .sample_format = .float_32,
                .channels = 1,
                .sample_rate = 48_000,
                .bits_per_sample = 32,
                .bytes_per_frame = 4,
            },
            .frame_count = 4,
        };
    }

    fn read(context: *anyopaque, output: []f32) !usize {
        const self: *TestDecoder = @ptrCast(@alignCast(context));
        const values = [_]f32{ 0.25, 0.5, 0.75, 1.0 };
        const count = @min(output.len, values.len - self.position);
        @memcpy(output[0..count], values[self.position .. self.position + count]);
        self.position += count;
        return count;
    }

    fn seek(context: *anyopaque, frame: u64) !void {
        const self: *TestDecoder = @ptrCast(@alignCast(context));
        self.position = @intCast(frame);
    }

    fn deinit(_: *anyopaque) void {}
};

test "Player decodes once into independently owned Zone pipelines" {
    var test_decoder: TestDecoder = .{};
    var player: Player = .{};
    defer player.deinit();
    try player.loadSource(source_session.SourceSession.init(test_decoder.decoder()));
    var first_pool = try buffer.BlockPool.init(std.testing.allocator, 1, 2, 1);
    defer first_pool.deinit();
    var second_pool = try buffer.BlockPool.init(std.testing.allocator, 1, 2, 1);
    defer second_pool.deinit();
    var first_pipe: render.RenderPipe(1) = .{};
    var second_pipe: render.RenderPipe(1) = .{};
    var player_gain: processing.Gain = .{ .linear = .init(0.5) };
    var zone_gain: processing.Gain = .{ .linear = .init(0.5) };
    const Sink = fanout.ZoneSink(1);
    var sinks = [_]Sink{
        .{ .pool = &first_pool, .pipe = &first_pipe, .channels = 1 },
        .{
            .pool = &second_pool,
            .pipe = &second_pipe,
            .channels = 1,
            .zone_processor = zone_gain.processor(),
        },
    };
    var scratch: [2]f32 = undefined;
    const result = try player.decodeProcessAndFanout(
        1,
        &scratch,
        player_gain.processor(),
        &sinks,
    );
    try std.testing.expectEqual(@as(usize, 2), result.frames);
    try std.testing.expectEqual(@as(usize, 2), result.zones_accepted);

    var first_output: [2]f32 = undefined;
    var second_output: [2]f32 = undefined;
    try std.testing.expectEqual(
        @as(usize, 2),
        first_pipe.render(&first_pool, 1, 1, &first_output),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        second_pipe.render(&second_pool, 1, 1, &second_output),
    );
    try std.testing.expectEqualSlices(f32, &.{ 0.125, 0.25 }, &first_output);
    try std.testing.expectEqualSlices(f32, &.{ 0.0625, 0.125 }, &second_output);

    const seek_epoch = try player.seek(1);
    try std.testing.expectEqual(@as(usize, 1), test_decoder.position);
    const after_seek = try player.decodeAndFanout(1, &scratch, &sinks);
    try std.testing.expectEqual(@as(usize, 2), after_seek.frames);
    try std.testing.expectEqual(
        @as(usize, 2),
        first_pipe.render(&first_pool, 1, seek_epoch, &first_output),
    );
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.75 }, &first_output);
}

test "a hard load makes the entry it loaded the audible one immediately" {
    var first: TestDecoder = .{};
    var player: Player = .{};
    defer player.deinit();
    try player.loadSource(source_session.SourceSession.init(first.decoder()));
    const first_serial = player.entrySerial();
    try std.testing.expectEqual(first_serial, player.audible_entry_serial.load(.acquire));

    // The callback republishes a serial only when the audible entry changes, so
    // after a hard switch it still names audio the epoch bump just retired.
    // Left uncorrected, both cursors would stay pinned to the retired entry.
    var second: TestDecoder = .{};
    player.replaceSource(source_session.SourceSession.init(second.decoder()));
    try std.testing.expect(player.entrySerial() != first_serial);
    try std.testing.expectEqual(player.entrySerial(), player.audible_entry_serial.load(.acquire));

    player.releaseSources();
    try std.testing.expectEqual(@as(u32, 0), player.audible_entry_serial.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), player.published_frame_count.load(.acquire));
}

test "a seek is deferred when the audible entry is no longer the decoded one" {
    var first: TestDecoder = .{};
    var player: Player = .{};
    defer player.deinit();
    try player.loadSource(source_session.SourceSession.init(first.decoder()));
    const audible = player.entrySerial();

    // Stand in for a gapless advance: the producer has moved on to the
    // successor while the predecessor's audio is still being rendered.
    var second: TestDecoder = .{};
    try player.primeNextSource(source_session.SourceSession.init(second.decoder()));
    var scratch: [8]f32 = undefined;
    _ = try player.decodeFrames(&scratch);
    try std.testing.expect(player.entrySerial() != audible);

    // The seek names the entry being heard, so it must not touch the decoder
    // that has run ahead of it.
    _ = try player.seek(2);
    try std.testing.expectEqual(@as(?PendingSeek, .{ .serial = audible, .frame = 2 }), player.pending_seek);
    try std.testing.expectEqual(@as(usize, 4), second.position);
    // ...and the epoch still moved, so the audio prepared ahead is discarded
    // through the same mechanism every other discontinuity uses.
    try std.testing.expectEqual(@as(u64, 2), player.snapshot().position_frames);

    const request = player.takePendingSeek().?;
    try std.testing.expectEqual(audible, request.serial);
    try std.testing.expect(player.takePendingSeek() == null);
}

test "pausing silences output without discarding prepared audio" {
    var player: Player = .{};
    try std.testing.expect(player.silenced.load(.acquire));

    player.play();
    try std.testing.expect(!player.silenced.load(.acquire));
    const playing_epoch = player.snapshot().epoch;

    player.pause();
    try std.testing.expect(player.silenced.load(.acquire));
    try std.testing.expectEqual(TransportState.paused, player.snapshot().state);
    // Pause must not invalidate queued blocks: resuming continues where the
    // callback left off, so the epoch is unchanged.
    try std.testing.expectEqual(playing_epoch, player.snapshot().epoch);

    player.play();
    try std.testing.expect(!player.silenced.load(.acquire));
    try std.testing.expectEqual(playing_epoch, player.snapshot().epoch);

    // Stop is a discontinuity: it silences output *and* retires the epoch.
    player.stop();
    try std.testing.expect(player.silenced.load(.acquire));
    try std.testing.expect(player.snapshot().epoch != playing_epoch);
}
