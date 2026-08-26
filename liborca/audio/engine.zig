const std = @import("std");
const control = @import("../core/control.zig");
const object = @import("../core/object.zig");
const work = @import("../core/work.zig");
const output_api = @import("output.zig");
const pcm = @import("pcm.zig");
const playback_queue = @import("playback_queue.zig");
const player_api = @import("player.zig");
const processing = @import("processing.zig");
const render = @import("render.zig");
const zone_model = @import("zone.zig");
const zone_runtime = @import("zone_runtime.zig");

pub const ZoneRuntime = zone_runtime.ZoneRuntime;
pub const block_count = zone_runtime.block_count;
pub const frames_per_block = zone_runtime.frames_per_block;
pub const max_channels = zone_runtime.max_channels;

/// Zones one Player may fan out to. Bounded like everything else on this lane:
/// the engine's sink array and both publication slots are fixed-capacity.
pub const max_zones: usize = 8;

/// Engine wake interval. Short enough that play/pause/seek take effect within
/// one device quantum, long enough that an idle Player costs nothing.
pub const park_ns: u64 = 2 * std.time.ns_per_ms;
pub const telemetry_interval_ns: u64 = 100 * std.time.ns_per_ms;
pub const recovery_backoff_ns: u64 = 100 * std.time.ns_per_ms;
/// How often an active output's negotiated latency is re-read.
pub const latency_refresh_passes: u64 = 16;

/// Consecutive entries the engine will fail to open before it stops advancing
/// on its own. Bounded like everything else: a queue full of deleted files must
/// not become an unbounded open/fail loop at the engine's park interval.
pub const max_consecutive_open_failures: u32 = 8;

pub const Options = struct {
    player: *player_api.Player,
    handle: object.PlayerHandle,
    telemetry: ?*control.TelemetryChannel = null,
    factory: ?output_api.Factory = null,
    queue: ?*playback_queue.PlaybackQueue = null,
    opener: ?playback_queue.TrackOpener = null,
    /// Player-scope processing applied to canonical PCM once, before fanout.
    /// The runtime uses it for the Player's volume gain, whose control block
    /// outlives the engine so a restart keeps the level the user set.
    player_processor: ?processing.Processor = null,
};

/// The one decode producer for a Player.
///
/// **One thread per Player, never per Zone.** The SPSC queues each Zone owns
/// require exactly one producer, and fanout is one-producer-many-consumers by
/// construction: the Player decodes canonical PCM once, runs Player-scope
/// processing on it, and copies it into each Zone's independently owned pool.
///
/// The engine thread never touches a `handle.Pool`. `core/handle.zig` performs
/// no locking, so generational handles protect *handles*, not a `*ZoneRuntime`
/// a worker already dereferenced. Instead the control lane publishes an
/// immutable `[]*ZoneRuntime` into an unclaimed slot and the engine adopts it at
/// a pass boundary and acknowledges it; the control lane only frees a Zone once
/// it has observed that acknowledgement. This is the same acknowledged
/// double-buffering `docs/audio-engine.md` describes for processing chains.
pub const PlayerEngine = struct {
    allocator: std.mem.Allocator,
    player: *player_api.Player,
    handle: object.PlayerHandle,
    telemetry: ?*control.TelemetryChannel,
    factory: ?output_api.Factory,
    registration: ?*work.Registration = null,
    player_processor: ?processing.Processor = null,
    /// The playback queue that sits above the decode queue. Plain state, owned
    /// jointly by this thread and the control lane under the
    /// `quiesce`/`release` handshake — the render callback never touches it.
    queue: ?*playback_queue.PlaybackQueue = null,
    opener: ?playback_queue.TrackOpener = null,

    // ---- Acknowledged double-buffered zone-set publication ----
    /// Two slots, only one of which the engine can be referencing at a time.
    slots: [2][max_zones]*ZoneRuntime = undefined,
    slot_lens: [2]usize = .{ 0, 0 },
    /// `sequence << 32 | slot`, written with a single release store so the
    /// engine can never read a sequence from one publication and a slot from
    /// another.
    published: std.atomic.Value(u64) = .init(0),
    /// Highest sequence the engine has adopted. The control lane waits for this
    /// before reusing a slot or freeing a Zone.
    ack: std.atomic.Value(u64) = .init(0),
    running: std.atomic.Value(bool) = .init(false),
    wake: std.atomic.Value(bool) = .init(false),
    drained: std.atomic.Value(bool) = .init(false),
    /// Set by the control lane while it needs exclusive access to the Player's
    /// `SourceQueue`. The engine is the only decoder, so loading or seeking a
    /// source has to stop it first: `sources` is a plain field, not an atomic.
    suspend_requested: std.atomic.Value(bool) = .init(false),
    /// Incremented at the end of every loop iteration, idle ones included.
    pass_epoch: std.atomic.Value(u64) = .init(0),
    /// Control-lane mirrors of the publication state.
    control_sequence: u64 = 0,
    control_slot: u32 = 0,

    // ---- Engine-thread-only state ----
    adopted: []*ZoneRuntime = &.{},
    adopted_sequence: u64 = 0,
    clock_zone: ?*ZoneRuntime = null,
    scratch: [frames_per_block * max_channels]f32 = undefined,
    elapsed_ns: u64 = 0,
    last_telemetry_ns: u64 = 0,
    passes: u64 = 0,
    /// A successor whose canonical format does not match the current source, so
    /// it could not be primed gaplessly. It is held here, already opened, until
    /// every Zone has drained; then it is hard-loaded and the outputs reopen at
    /// its format. Gapless when formats match, gapped-but-correct when they do
    /// not — which is the honest answer for a mixed FLAC/MP3 library.
    pending_source: ?source_session.SourceSession = null,
    pending_position: u32 = 0,
    consecutive_open_failures: u32 = 0,
    /// Diagnostics for the control lane: how many entries auto-advance opened,
    /// how many of those were gapless, and how many needed an output reopen.
    entries_started: u64 = 0,
    gapless_transitions: u64 = 0,
    format_switch_transitions: u64 = 0,
    open_failures: u64 = 0,
    decode_errors: u64 = 0,
    /// How often a seek had to re-open the audible entry because the producer
    /// had already run past it into the successor.
    seek_reopens: u64 = 0,

    pub fn create(allocator: std.mem.Allocator, options: Options) !*PlayerEngine {
        const self = try allocator.create(PlayerEngine);
        self.* = .{
            .allocator = allocator,
            .player = options.player,
            .handle = options.handle,
            .telemetry = options.telemetry,
            .factory = options.factory,
            .queue = options.queue,
            .opener = options.opener,
            .player_processor = options.player_processor,
        };
        self.adopted = self.slots[0][0..0];
        return self;
    }

    /// Control lane. Only legal once the engine thread has been joined.
    pub fn destroy(self: *PlayerEngine) void {
        std.debug.assert(!self.running.load(.acquire));
        self.allocator.destroy(self);
    }

    // ---------------------------------------------------------------- control

    /// Control lane. Hands the engine a new immutable zone set and does not
    /// return until the engine is provably using it, which is what makes it safe
    /// for the caller to then close an output or free a `ZoneRuntime`.
    pub fn publishZones(self: *PlayerEngine, zones: []const *ZoneRuntime) !void {
        if (zones.len > max_zones) return error.TooManyZones;
        // The engine may still be reading the slot published last time, so wait
        // for its acknowledgement before writing the other one.
        self.awaitAcknowledgement();
        const slot: u32 = 1 - self.control_slot;
        @memcpy(self.slots[slot][0..zones.len], zones);
        self.slot_lens[slot] = zones.len;
        self.control_sequence += 1;
        self.control_slot = slot;
        self.published.store((self.control_sequence << 32) | slot, .release);
        self.wakeUp();
        // And wait again: on return the engine has adopted this exact set, so
        // any Zone missing from it can no longer be reached from the RT lane.
        self.awaitAcknowledgement();
    }

    pub fn wakeUp(self: *PlayerEngine) void {
        self.wake.store(true, .release);
    }

    /// Control lane. Blocks until the engine is provably outside its pass body,
    /// so the caller may mutate the Player's SourceQueue.
    ///
    /// Two completed iterations are the proof: the second of them must have
    /// started after `suspend_requested` was published, so it took the idle
    /// branch, and every later iteration does the same while the flag is set.
    pub fn quiesce(self: *PlayerEngine) void {
        self.suspend_requested.store(true, .release);
        if (!self.running.load(.acquire)) return;
        const target = self.pass_epoch.load(.acquire) + 2;
        while (self.running.load(.acquire) and self.pass_epoch.load(.acquire) < target) {
            self.wakeUp();
            std.Thread.yield() catch {};
        }
    }

    pub fn release(self: *PlayerEngine) void {
        self.suspend_requested.store(false, .release);
        self.wakeUp();
    }

    pub fn isDrained(self: *const PlayerEngine) bool {
        return self.drained.load(.acquire);
    }

    fn awaitAcknowledgement(self: *PlayerEngine) void {
        while (self.running.load(.acquire) and
            self.ack.load(.acquire) != self.control_sequence)
        {
            self.wakeUp();
            std.Thread.yield() catch {};
        }
    }

    // ----------------------------------------------------------------- engine

    /// Engine thread entry point. Registered with `work.Registry`, so shutdown
    /// and `destroyPlayer` cancel and join it rather than abandoning it.
    pub fn run(self: *PlayerEngine) void {
        const registration = self.registration.?;
        self.running.store(true, .release);
        while (!registration.cancellationRequested()) {
            if (!self.suspend_requested.load(.acquire)) self.pass();
            _ = self.pass_epoch.fetchAdd(1, .acq_rel);
            self.park();
        }
        // A final adopt releases a control lane blocked in awaitAcknowledgement,
        // and silencing leaves any still-open output emitting zeros rather than
        // whatever it last had queued.
        self.adoptZones();
        for (self.adopted) |runtime_zone| runtime_zone.silenced.store(true, .release);
        self.releasePending();
        self.running.store(false, .release);
        registration.finish();
    }

    /// One engine pass. Exposed so tests can drive the whole loop body
    /// deterministically, with no thread and no sleeping.
    pub fn pass(self: *PlayerEngine) void {
        self.passes += 1;
        self.adoptZones();
        const zones = self.adopted;
        const silenced = self.player.silenced.load(.acquire);
        for (zones) |runtime_zone| {
            runtime_zone.pipe.reclaim(&runtime_zone.pool);
            runtime_zone.silenced.store(silenced, .release);
        }
        self.serviceSeek();
        self.serviceQueue(zones);
        const format = self.player.format();
        // Closing a stream whose negotiated format no longer matches has to
        // happen before this pass decodes into it, or the callback would be
        // handed PCM in a layout it cannot render.
        self.reopenOnFormatChange(zones, format);
        self.pump(zones, format);
        self.serviceOutputs(zones, format);
        self.publishPosition(zones);
        self.publishDrained(zones);
    }

    /// Drops a successor the engine opened but never handed to the Player.
    /// Called from the engine thread on exit and from the control lane once the
    /// thread has been joined, so a queued-but-unplayed decoder is never leaked.
    pub fn releasePending(self: *PlayerEngine) void {
        if (self.pending_source) |*pending| pending.deinit();
        self.pending_source = null;
    }

    /// Control lane, under `quiesce`. A hard transport switch retires whatever
    /// the engine had lined up: the audio it describes is about to be discarded
    /// by the epoch bump, and its queue position is no longer the one wanted.
    pub fn discardPending(self: *PlayerEngine) void {
        self.releasePending();
        self.player.clearPendingSeek();
        self.consecutive_open_failures = 0;
    }

    /// Completes a seek the control lane could not apply itself.
    ///
    /// The producer runs an entry ahead, so a seek issued in the last moments of
    /// a track arrives when the audible entry's decoder has already been
    /// released and replaced by the successor's. `Player.seek` records the
    /// request rather than applying it to the wrong source; here — on the lane
    /// that is allowed to open files — the audible entry is re-opened and seeked
    /// for real. The decode-ahead work for the following entry goes with it:
    /// re-opening replaces the whole `SourceQueue`, and the epoch bump that
    /// already happened is what discards the audio it had prepared.
    fn serviceSeek(self: *PlayerEngine) void {
        const request = self.player.takePendingSeek() orelse return;
        const queue = self.queue orelse return self.seekLoadedSource(request.frame);
        const opener = self.opener orelse return self.seekLoadedSource(request.frame);
        // An entry the serial map has forgotten cannot be re-opened, and
        // guessing a position would be worse than seeking what is loaded.
        const position = queue.positionForSerial(request.serial) orelse
            return self.seekLoadedSource(request.frame);
        const ref = queue.refAt(position) orelse return self.seekLoadedSource(request.frame);
        var session = opener.open(ref) catch {
            self.noteOpenFailure(queue, position);
            return;
        };
        // A held format-switch successor describes a transition that is no
        // longer happening.
        self.releasePending();
        self.player.replaceSource(session);
        session = undefined;
        queue.seekTo(position);
        queue.noteEntrySerial(self.player.entrySerial(), position);
        self.seekLoadedSource(request.frame);
        self.consecutive_open_failures = 0;
        self.seek_reopens += 1;
    }

    fn seekLoadedSource(self: *PlayerEngine, frame: u64) void {
        _ = self.player.seekCurrent(frame) catch {
            // A decoder that cannot seek ends its entry rather than stalling the
            // queue, exactly as one that fails mid-read does.
            self.decode_errors += 1;
            if (self.player.sources) |*sources| sources.current.eof = true;
        };
    }

    /// The playback queue lane: start the queue when nothing is loaded, prime
    /// the successor before the current source runs out, and complete a
    /// deferred hard switch once every Zone has drained.
    ///
    /// All of this is deliberately on the engine thread. Opening a track means
    /// a SQLite read and a file open, neither of which may happen on a caller's
    /// UI thread or inside a render callback.
    fn serviceQueue(self: *PlayerEngine, zones: []*ZoneRuntime) void {
        const queue = self.queue orelse return;
        const opener = self.opener orelse return;

        if (self.pending_source != null) {
            self.completeFormatSwitch(zones, queue);
            return;
        }
        if (self.player.state.load(.acquire) != .playing) return;
        if (self.consecutive_open_failures >= max_consecutive_open_failures) return;

        if (self.player.sources == null) {
            // Nothing loaded: start at the cursor. This is what makes
            // "enqueue then play" work without the control lane opening a file.
            const position = queue.cursorPosition();
            const ref = queue.refAt(position) orelse return;
            var session = opener.open(ref) catch {
                self.noteOpenFailure(queue, position);
                return;
            };
            self.player.replaceSource(session);
            session = undefined;
            queue.seekTo(position);
            queue.noteEntrySerial(self.player.entrySerial(), position);
            self.consecutive_open_failures = 0;
            self.entries_started += 1;
            return;
        }

        const sources = &self.player.sources.?;
        if (!sources.current.eof or sources.next != null) return;
        const position = queue.followingPosition() orelse return;
        const ref = queue.refAt(position) orelse return;
        var session = opener.open(ref) catch {
            self.noteOpenFailure(queue, position);
            return;
        };
        self.player.primeNextSource(session) catch |err| {
            if (err == error.GaplessFormatMismatch) {
                // Not fatal, and not something to resample around: hold the
                // successor unprimed, let the pipe drain, then hard-switch.
                self.pending_source = session;
                self.pending_position = position;
                return;
            }
            session.deinit();
            self.noteOpenFailure(queue, position);
            return;
        };
        queue.advanceDecodeTo(position);
        queue.noteEntrySerial(sources.next_entry_serial, position);
        self.consecutive_open_failures = 0;
        self.entries_started += 1;
        self.gapless_transitions += 1;
    }

    /// A successor in a different canonical format waits here until the current
    /// one has decoded out *and* every Zone has handed back every block. Only
    /// then can the outputs be reopened without truncating audio the listener
    /// has not heard yet.
    fn completeFormatSwitch(
        self: *PlayerEngine,
        zones: []*ZoneRuntime,
        queue: *playback_queue.PlaybackQueue,
    ) void {
        if (!self.player.finishedDecoding()) return;
        for (zones) |runtime_zone| {
            if (!runtime_zone.output_requested.load(.acquire)) continue;
            if (!runtime_zone.quiescent()) return;
        }
        const pending = self.pending_source.?;
        self.pending_source = null;
        const position = self.pending_position;
        self.player.replaceSource(pending);
        queue.seekTo(position);
        queue.noteEntrySerial(self.player.entrySerial(), position);
        self.consecutive_open_failures = 0;
        self.entries_started += 1;
        self.format_switch_transitions += 1;
    }

    fn noteOpenFailure(
        self: *PlayerEngine,
        queue: *playback_queue.PlaybackQueue,
        position: u32,
    ) void {
        self.open_failures += 1;
        self.consecutive_open_failures +|= 1;
        // Step past the entry that could not be opened so one unreadable file
        // does not hold the whole queue still.
        queue.advanceDecodeTo(position);
    }

    /// Closes any Zone output whose negotiated format the current source can no
    /// longer feed. `serviceOutputs` reopens it later in the same pass.
    fn reopenOnFormatChange(self: *PlayerEngine, zones: []*ZoneRuntime, format: ?pcm.Format) void {
        _ = self;
        const format_value = format orelse return;
        for (zones) |runtime_zone| {
            if (runtime_zone.output == null) continue;
            if (!runtime_zone.outputFormatChanged(format_value)) continue;
            runtime_zone.closeOutput();
            runtime_zone.resetPipe();
            runtime_zone.zone.close();
            runtime_zone.stalled_passes = 0;
            runtime_zone.publishState();
        }
    }

    fn adoptZones(self: *PlayerEngine) void {
        const published = self.published.load(.acquire);
        const sequence = published >> 32;
        if (sequence == self.adopted_sequence) return;
        const slot: usize = @intCast(published & 0xffff_ffff);
        self.adopted = self.slots[slot][0..self.slot_lens[slot]];
        self.adopted_sequence = sequence;
        self.ack.store(sequence, .release);
    }

    /// Decode once, process once, copy into every participating Zone.
    fn pump(self: *PlayerEngine, zones: []*ZoneRuntime, format: ?pcm.Format) void {
        const format_value = format orelse return;
        if (self.player.state.load(.acquire) != .playing) return;
        if (format_value.channels == 0 or format_value.channels > max_channels) return;

        var storage: [max_zones]zone_runtime.Sink = undefined;
        var participants: [max_zones]*ZoneRuntime = undefined;
        var count: usize = 0;
        for (zones) |runtime_zone| {
            if (!runtime_zone.output_requested.load(.acquire)) continue;
            if (runtime_zone.zone.output_state == .failed) continue;
            if (runtime_zone.hasRoom())
                runtime_zone.stalled_passes = 0
            else if (runtime_zone.stalled_passes >= ZoneRuntime.stall_limit)
                // This Zone has not drained for long enough that it is treated
                // as broken. Excluding it is what keeps the shared decode
                // cursor moving for every other Zone.
                continue;
            storage[count] = runtime_zone.sink(format_value.channels);
            participants[count] = runtime_zone;
            count += 1;
        }
        if (count == 0) return;

        // The canonical decode cursor is shared, so a block is only produced
        // when every participating Zone can take it. A Zone that stops draining
        // is dropped from the set below rather than being allowed to hold the
        // cursor still for the others.
        const epoch = self.player.epoch.load(.acquire);
        for (zones) |runtime_zone| runtime_zone.epoch.store(epoch, .release);
        const scratch = self.scratch[0 .. frames_per_block * format_value.channels];

        var produced: usize = 0;
        while (produced < block_count) {
            var room = true;
            for (participants[0..count]) |runtime_zone| {
                if (!runtime_zone.hasRoom()) room = false;
            }
            if (!room) break;
            const result = self.player.decodeProcessAndFanoutUnderEpoch(
                block_count,
                scratch,
                self.player_processor,
                storage[0..count],
                epoch,
            ) catch {
                // A decoder that fails mid-entry has to end the entry. Leaving
                // it merely "not finished" would stall the whole queue: nothing
                // would ever prime a successor and every Zone would underrun
                // for the rest of the session.
                self.decode_errors += 1;
                if (self.player.sources) |*sources| sources.current.eof = true;
                break;
            };
            if (result.frames == 0) break;
            produced += 1;
        }

        if (produced == 0 and !self.player.finishedDecoding()) {
            for (participants[0..count]) |runtime_zone| {
                if (!runtime_zone.hasRoom()) runtime_zone.stalled_passes +|= 1;
            }
        }
    }

    /// Opens, polls and recovers each Zone's output. Stream creation and
    /// destruction stay on this control-side lane; the render callback only ever
    /// consumes prepared blocks.
    fn serviceOutputs(self: *PlayerEngine, zones: []*ZoneRuntime, format: ?pcm.Format) void {
        const factory = self.factory orelse return;
        for (zones) |runtime_zone| {
            if (!runtime_zone.output_requested.load(.acquire)) {
                if (runtime_zone.output != null) {
                    runtime_zone.closeOutput();
                    runtime_zone.resetPipe();
                    runtime_zone.zone.close();
                    runtime_zone.stalled_passes = 0;
                    runtime_zone.publishState();
                }
                continue;
            }
            if (runtime_zone.output) |active| {
                switch (active.status()) {
                    .active => {
                        // The negotiated quantum is only knowable after the
                        // stream has actually run, and it can change under us,
                        // so it is refreshed rather than read once at open.
                        if (runtime_zone.zone.output_state != .active or
                            self.passes % latency_refresh_passes == 0)
                        {
                            if (active.latency(
                                @intCast(runtime_zone.blockBudget() * frames_per_block),
                                0,
                            )) |latency| {
                                if (latency.backend_quantum_frames != 0)
                                    runtime_zone.quantum_frames = latency.backend_quantum_frames;
                                runtime_zone.zone.opened(latency);
                            } else |_| {
                                runtime_zone.zone.output_state = .active;
                            }
                            runtime_zone.publishState();
                        }
                    },
                    .connecting => {},
                    // A lost output is closed but the prepared render path is
                    // deliberately kept: the Player epoch and every queued block
                    // survive the reopen.
                    .lost => self.loseOutput(runtime_zone),
                }
            }
            if (runtime_zone.output != null) continue;
            const format_value = format orelse continue;

            if (runtime_zone.zone.output_state == .lost or
                runtime_zone.zone.output_state == .failed)
            {
                if (runtime_zone.zone.recovery_attempts >= zone_runtime.max_recovery_attempts) {
                    if (runtime_zone.zone.output_state != .failed) {
                        runtime_zone.zone.output_state = .failed;
                        runtime_zone.publishState();
                    }
                    continue;
                }
                if (runtime_zone.recovery_wait_ns > 0) {
                    runtime_zone.recovery_wait_ns -|= park_ns;
                    continue;
                }
                runtime_zone.zone.beginRecovery();
            } else if (runtime_zone.zone.output_state != .opening) {
                runtime_zone.zone.beginOpen(runtime_zone.requested_device_id.load(.acquire));
            }
            runtime_zone.publishState();

            runtime_zone.openOutput(
                factory,
                format_value,
                runtime_zone.requested_device_id.load(.acquire),
            ) catch {
                if (runtime_zone.zone.output_state == .recovering)
                    runtime_zone.zone.recoveryFailed()
                else
                    runtime_zone.zone.deviceLost();
                runtime_zone.recovery_wait_ns = recovery_backoff_ns;
                runtime_zone.publishState();
                continue;
            };
            runtime_zone.stalled_passes = 0;
            if (runtime_zone.output.?.latency(
                @intCast(runtime_zone.blockBudget() * frames_per_block),
                0,
            )) |latency| {
                if (latency.backend_quantum_frames != 0)
                    runtime_zone.quantum_frames = latency.backend_quantum_frames;
                runtime_zone.zone.opened(latency);
            } else |_| {
                runtime_zone.zone.output_state = .active;
            }
            runtime_zone.publishState();
        }
    }

    fn loseOutput(self: *PlayerEngine, runtime_zone: *ZoneRuntime) void {
        _ = self;
        runtime_zone.closeOutput();
        runtime_zone.zone.deviceLost();
        runtime_zone.recovery_wait_ns = recovery_backoff_ns;
        runtime_zone.stalled_passes = 0;
        runtime_zone.publishState();
    }

    /// Derives authoritative position from the clock Zone and publishes a
    /// coalesced hint. Snapshots stay authoritative; this channel is a hint.
    fn publishPosition(self: *PlayerEngine, zones: []*ZoneRuntime) void {
        // A gapless transition swaps `SourceQueue.current` inside the decode
        // lane, so the source's shape has to be republished from here rather
        // than only where a source is loaded.
        self.player.publishSourceInfo();
        const had_clock_zone = self.clock_zone != null;
        if (self.clock_zone) |current| {
            var still_valid = false;
            for (zones) |runtime_zone| {
                if (runtime_zone == current and runtime_zone.output != null and
                    runtime_zone.zone.output_state == .active) still_valid = true;
            }
            if (!still_valid) self.clock_zone = null;
        }
        if (self.clock_zone == null) {
            for (zones) |runtime_zone| {
                if (runtime_zone.output != null and runtime_zone.zone.output_state == .active) {
                    self.clock_zone = runtime_zone;
                    // Promotion only: the newly promoted Zone's frame counter
                    // starts at zero, so the timeline is rebased under a fresh
                    // epoch. The first Zone to open needs no rebase.
                    if (had_clock_zone) _ = self.player.stampEpoch();
                    break;
                }
            }
        }
        const clock_zone = self.clock_zone orelse return;
        const epoch = self.player.epoch.load(.acquire);
        // Load order mirrors the callback's store order in reverse: position
        // first (acquire), then the serial and the anchor it wrote before it.
        // Anything newer than the position is therefore detectable below rather
        // than silently paired with the wrong entry.
        const sample = clock_zone.position.load(.acquire);
        const serial = clock_zone.rendered_entry_serial.load(.monotonic);
        const anchor = clock_zone.entry_anchor.load(.monotonic);
        if (render.positionEpoch(sample) != @as(u16, @truncate(epoch))) return;
        // Now-playing follows the serial the callback actually rendered, not the
        // decode cursor, which leads it by the whole render-ahead depth. It is
        // adopted only once the position it came with proves to belong to the
        // current epoch: a serial published under a retired epoch describes
        // audio a hard switch has already thrown away, and adopting it would
        // drag both cursors back onto the entry that switch left behind.
        //
        // Identity, duration and position all resolve from this one value —
        // the queue maps it to the audible entry, the Player maps it to that
        // entry's timeline shape — so the three agree by construction.
        if (self.queue) |queue| queue.observeRenderedSerial(serial);
        self.player.observeRenderedSerial(serial);
        // Republish under the serial just adopted, so duration moves in the same
        // pass the audible entry does rather than one pass behind it.
        self.player.publishSourceInfo();
        // The anchor's stamp is the low half of the serial that owns it. A
        // mismatch means the two were read from different moments, so the pair
        // is discarded exactly as a mismatched epoch is.
        if (render.entryAnchorStamp(anchor) != @as(u16, @truncate(serial))) return;
        const rendered_frames = render.positionFrames(sample);
        const entry_start = render.entryAnchorFrames(anchor);
        // An anchor past the frame count means the audible entry changed while
        // this sample was being assembled; the next pass reports the new entry.
        if (entry_start > rendered_frames) return;
        const in_entry = rendered_frames - entry_start;
        // A non-zero anchor means this entry began *inside* the current epoch —
        // a gapless advance — so it started at its own frame zero. Only an entry
        // that was already audible when the epoch was stamped carries the seek
        // base that was stamped with it.
        const frames = if (entry_start == 0)
            self.player.epoch_base_frames.load(.acquire) + in_entry
        else
            in_entry;
        // Drop the sample if a seek landed while it was being assembled; the
        // next pass reports the new epoch's position instead of a stale one.
        if (self.player.epoch.load(.acquire) != epoch) return;
        self.player.position_frames.store(frames, .release);

        if (self.elapsed_ns -| self.last_telemetry_ns < telemetry_interval_ns) return;
        self.last_telemetry_ns = self.elapsed_ns;
        const telemetry = self.telemetry orelse return;
        telemetry.publish(.{ .player_position = .{
            .player = self.handle,
            .frames = frames,
        } }) catch {};
    }

    fn publishDrained(self: *PlayerEngine, zones: []*ZoneRuntime) void {
        if (self.player.sources == null) {
            self.drained.store(false, .monotonic);
            return;
        }
        if (!self.player.finishedDecoding()) {
            self.drained.store(false, .monotonic);
            return;
        }
        for (zones) |runtime_zone| {
            if (!runtime_zone.output_requested.load(.acquire)) continue;
            if (!runtime_zone.quiescent()) {
                self.drained.store(false, .monotonic);
                return;
            }
        }
        self.drained.store(true, .release);
    }

    fn park(self: *PlayerEngine) void {
        if (self.wake.swap(false, .acq_rel)) return;
        sleepNanoseconds(park_ns);
        // Wall-clock is only needed for cadence, so it is accumulated from the
        // parks actually taken rather than reading a clock every pass.
        self.elapsed_ns += park_ns;
    }
};

fn sleepNanoseconds(nanoseconds: u64) void {
    const duration: std.c.timespec = .{
        .sec = @intCast(nanoseconds / std.time.ns_per_s),
        .nsec = @intCast(nanoseconds % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&duration, null);
}

// ---------------------------------------------------------------------- tests

const source_session = @import("source_session.zig");

const RampDecoder = struct {
    position: u64 = 0,
    total: u64,
    channels: u16 = 1,
    sample_rate: u32 = 48_000,

    fn decoder(self: *RampDecoder) @import("../codec/decoder.zig").Decoder {
        return .{
            .context = self,
            .vtable = &.{ .read_frames = read, .seek = seekTo, .deinit = release },
            .format = .{
                .sample_format = .float_32,
                .channels = self.channels,
                .sample_rate = self.sample_rate,
                .bits_per_sample = 32,
                .bytes_per_frame = self.channels * 4,
            },
            .frame_count = self.total,
        };
    }

    fn read(context: *anyopaque, output: []f32) !usize {
        const self: *RampDecoder = @ptrCast(@alignCast(context));
        const frames = @min(output.len / self.channels, self.total - self.position);
        for (0..frames) |frame| {
            const value: f32 = @floatFromInt((self.position + frame) % 100);
            for (0..self.channels) |channel|
                output[frame * self.channels + channel] = value;
        }
        self.position += frames;
        return frames;
    }

    fn seekTo(context: *anyopaque, frame: u64) !void {
        const self: *RampDecoder = @ptrCast(@alignCast(context));
        self.position = frame;
    }

    fn release(_: *anyopaque) void {}
};

const Harness = struct {
    allocator: std.mem.Allocator,
    backend: output_api.TestBackend,
    player: player_api.Player = .{},
    engine: *PlayerEngine = undefined,
    registration: work.Registration = .{},

    fn init(allocator: std.mem.Allocator) !*Harness {
        const self = try allocator.create(Harness);
        self.* = .{ .allocator = allocator, .backend = .{ .allocator = allocator } };
        self.engine = try PlayerEngine.create(allocator, .{
            .player = &self.player,
            .handle = .{ .index = 0, .generation = 1 },
            .factory = self.backend.factory(),
        });
        self.engine.registration = &self.registration;
        return self;
    }

    fn deinit(self: *Harness) void {
        const allocator = self.allocator;
        self.engine.destroy();
        self.player.deinit();
        self.backend.deinit();
        allocator.destroy(self);
    }
};

fn liveStreamFor(
    backend: *output_api.TestBackend,
    runtime_zone: *ZoneRuntime,
) ?*output_api.TestBackend.Stream {
    var index = backend.stream_count;
    while (index > 0) {
        index -= 1;
        if (backend.streams[index]) |stream| {
            if (!stream.closed and stream.userdata == runtime_zone.context.userdata())
                return stream;
        }
    }
    return null;
}

fn openZone(allocator: std.mem.Allocator) !*ZoneRuntime {
    const runtime_zone = try ZoneRuntime.create(allocator);
    runtime_zone.output_requested.store(true, .release);
    return runtime_zone;
}

test "two Zones fed by one Player receive independent audio" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit();
    var decoder: RampDecoder = .{ .total = 4096 };
    try harness.player.loadSource(source_session.SourceSession.init(decoder.decoder()));

    const first = try openZone(allocator);
    defer first.destroy();
    const second = try openZone(allocator);
    defer second.destroy();
    try harness.engine.publishZones(&.{ first, second });
    harness.player.play();

    harness.engine.pass();
    harness.engine.pass();

    // Each Zone holds its own copy in its own pool.
    try std.testing.expect(first.output != null);
    try std.testing.expect(second.output != null);
    try std.testing.expect(first.pool.free_len < block_count);
    try std.testing.expect(second.pool.free_len < block_count);
    try std.testing.expect(first.pool.storage.ptr != second.pool.storage.ptr);

    var first_output: [frames_per_block]f32 = @splat(-1);
    var second_output: [frames_per_block]f32 = @splat(-1);
    liveStreamFor(&harness.backend, first).?.pump(&first_output, frames_per_block);
    liveStreamFor(&harness.backend, second).?.pump(&second_output, frames_per_block);
    try std.testing.expectEqualSlices(f32, &first_output, &second_output);
    try std.testing.expect(first_output[1] == 1);
}

test "a Zone that stops draining does not stall the other Zone" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit();
    var decoder: RampDecoder = .{ .total = 1_000_000 };
    try harness.player.loadSource(source_session.SourceSession.init(decoder.decoder()));

    const healthy = try openZone(allocator);
    defer healthy.destroy();
    const stuck = try openZone(allocator);
    defer stuck.destroy();
    try harness.engine.publishZones(&.{ healthy, stuck });
    harness.player.play();

    // Only the healthy Zone's callback ever runs, so the stuck Zone fills and
    // stays full. It must not hold the shared decode cursor still forever.
    var scratch: [frames_per_block]f32 = undefined;
    var pass: usize = 0;
    while (pass < ZoneRuntime.stall_limit + 8) : (pass += 1) {
        harness.engine.pass();
        if (liveStreamFor(&harness.backend, healthy)) |stream|
            stream.pump(&scratch, frames_per_block);
    }
    try std.testing.expectEqual(@as(u32, ZoneRuntime.stall_limit), stuck.stalled_passes);
    try std.testing.expectEqual(@as(u32, 0), healthy.stalled_passes);

    // Once the stuck Zone is out of the way the healthy one stops starving.
    const underruns_before = healthy.pipe.underruns.load(.monotonic);
    pass = 0;
    while (pass < 32) : (pass += 1) {
        harness.engine.pass();
        liveStreamFor(&harness.backend, healthy).?.pump(&scratch, frames_per_block);
    }
    try std.testing.expectEqual(underruns_before, healthy.pipe.underruns.load(.monotonic));
    try std.testing.expect(scratch[1] != 0);
    // Both outputs are still open: one Zone's backpressure failed neither.
    try std.testing.expectEqual(zone_model.OutputState.active, healthy.outputState());
    try std.testing.expectEqual(zone_model.OutputState.active, stuck.outputState());
}

test "a lost output recovers within bounded attempts and then stays failed" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit();
    var decoder: RampDecoder = .{ .total = 1_000_000 };
    try harness.player.loadSource(source_session.SourceSession.init(decoder.decoder()));

    const runtime_zone = try openZone(allocator);
    defer runtime_zone.destroy();
    try harness.engine.publishZones(&.{runtime_zone});
    harness.player.play();
    harness.engine.pass();
    try std.testing.expectEqual(zone_model.OutputState.active, runtime_zone.outputState());
    const prepared_before_loss = block_count - runtime_zone.pool.free_len;
    try std.testing.expect(prepared_before_loss > 0);

    liveStreamFor(&harness.backend, runtime_zone).?.markLost();
    runtime_zone.recovery_wait_ns = 0;
    harness.engine.pass();
    try std.testing.expectEqual(zone_model.OutputState.lost, runtime_zone.outputState());
    // The prepared render path survives the loss: no queue surgery happened.
    try std.testing.expectEqual(
        prepared_before_loss,
        block_count - runtime_zone.pool.free_len,
    );

    runtime_zone.recovery_wait_ns = 0;
    harness.engine.pass();
    try std.testing.expectEqual(zone_model.OutputState.active, runtime_zone.outputState());
    try std.testing.expectEqual(@as(u32, 0), runtime_zone.published_recovery_attempts.load(.acquire));

    // Now make every reopen fail: recovery is bounded, not infinite.
    harness.backend.fail_next_open = true;
    var pass: usize = 0;
    while (pass < 16) : (pass += 1) {
        if (liveStreamFor(&harness.backend, runtime_zone)) |stream| stream.markLost();
        runtime_zone.recovery_wait_ns = 0;
        harness.engine.pass();
    }
    try std.testing.expectEqual(zone_model.OutputState.failed, runtime_zone.outputState());
    try std.testing.expectEqual(
        zone_runtime.max_recovery_attempts,
        runtime_zone.published_recovery_attempts.load(.acquire),
    );
}

test "pausing silences a Zone without discarding its prepared blocks" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit();
    var decoder: RampDecoder = .{ .total = 1_000_000 };
    try harness.player.loadSource(source_session.SourceSession.init(decoder.decoder()));

    const runtime_zone = try openZone(allocator);
    defer runtime_zone.destroy();
    try harness.engine.publishZones(&.{runtime_zone});
    harness.player.play();
    harness.engine.pass();
    const stream = liveStreamFor(&harness.backend, runtime_zone).?;

    harness.player.pause();
    harness.engine.pass();
    const queued_while_paused = runtime_zone.pipe.ready.len();
    try std.testing.expect(queued_while_paused > 0);

    var samples: [frames_per_block]f32 = @splat(1);
    stream.pump(&samples, frames_per_block);
    for (samples) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    // Nothing was consumed and nothing was counted as missing.
    try std.testing.expectEqual(queued_while_paused, runtime_zone.pipe.ready.len());
    try std.testing.expectEqual(@as(u64, 0), runtime_zone.pipe.underruns.load(.monotonic));

    harness.player.play();
    harness.engine.pass();
    stream.pump(&samples, frames_per_block);
    try std.testing.expect(samples[1] != 0);
}

test "a seek discards stale-epoch blocks without touching the queue" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit();
    var decoder: RampDecoder = .{ .total = 1_000_000 };
    try harness.player.loadSource(source_session.SourceSession.init(decoder.decoder()));

    const runtime_zone = try openZone(allocator);
    defer runtime_zone.destroy();
    try harness.engine.publishZones(&.{runtime_zone});
    harness.player.play();
    harness.engine.pass();
    const stream = liveStreamFor(&harness.backend, runtime_zone).?;
    const queued_before = runtime_zone.pipe.ready.len();
    try std.testing.expect(queued_before > 0);

    _ = try harness.player.seek(50_000);
    // The stale blocks are still physically queued — no surgery took place.
    try std.testing.expectEqual(queued_before, runtime_zone.pipe.ready.len());

    harness.engine.pass();
    var samples: [frames_per_block]f32 = @splat(-1);
    stream.pump(&samples, frames_per_block);
    // The callback discarded every stale-epoch block and filled with silence.
    for (samples) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    try std.testing.expectEqual(@as(usize, 0), runtime_zone.pipe.ready.len());

    harness.engine.pass();
    stream.pump(&samples, frames_per_block);
    // 50_000 % 100 == 0, so post-seek audio starts at 0 and ramps.
    try std.testing.expectEqual(@as(f32, 0), samples[0]);
    try std.testing.expectEqual(@as(f32, 1), samples[1]);

    harness.engine.pass();
    try std.testing.expectEqual(
        @as(u64, 50_000 + frames_per_block),
        harness.player.snapshot().position_frames,
    );
}

test "an engine thread delays shutdown until it has actually stopped" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit();
    var decoder: RampDecoder = .{ .total = 1_000_000 };
    try harness.player.loadSource(source_session.SourceSession.init(decoder.decoder()));

    const runtime_zone = try openZone(allocator);
    defer runtime_zone.destroy();
    harness.registration.thread = try std.Thread.spawn(.{}, PlayerEngine.run, .{harness.engine});
    while (!harness.engine.running.load(.acquire)) std.Thread.yield() catch {};
    try harness.engine.publishZones(&.{runtime_zone});
    harness.player.play();

    // The engine is live and holds the Zone. Cancelling must join, not abandon.
    harness.registration.requestCancellation();
    harness.registration.awaitCompletion();
    try std.testing.expect(harness.registration.isFinished());
    try std.testing.expect(!harness.engine.running.load(.acquire));
    // Only now is closing the Zone's output safe.
    runtime_zone.closeOutput();
    runtime_zone.resetPipe();
}

test "unpublishing a Zone is acknowledged before the control lane frees it" {
    const allocator = std.testing.allocator;
    var harness = try Harness.init(allocator);
    defer harness.deinit();
    var decoder: RampDecoder = .{ .total = 1_000_000 };
    try harness.player.loadSource(source_session.SourceSession.init(decoder.decoder()));

    const keep = try openZone(allocator);
    defer keep.destroy();
    const remove = try openZone(allocator);
    harness.registration.thread = try std.Thread.spawn(.{}, PlayerEngine.run, .{harness.engine});
    while (!harness.engine.running.load(.acquire)) std.Thread.yield() catch {};
    try harness.engine.publishZones(&.{ keep, remove });
    harness.player.play();

    try harness.engine.publishZones(&.{keep});
    // publishZones returned, so the engine has adopted a set without `remove`
    // and can never dereference it again: freeing it here is safe.
    try std.testing.expectEqual(
        harness.engine.control_sequence,
        harness.engine.ack.load(.acquire),
    );
    remove.closeOutput();
    remove.destroy();

    harness.registration.requestCancellation();
    harness.registration.awaitCompletion();
    keep.closeOutput();
    keep.resetPipe();
}

// -------------------------------------------------------------- queue tests

/// Opens a synthetic track per id. Stands in for `TrackSourceOpener` so the
/// queue lane can be driven with no database, no filesystem and no hardware.
const TrackPlan = struct {
    track_id: i64,
    frames: u64,
    channels: u16 = 1,
    sample_rate: u32 = 48_000,
};

const TestOpener = struct {
    allocator: std.mem.Allocator,
    plans: []const TrackPlan,
    opens: usize = 0,
    /// Opens per track id, so a test can prove that a *particular* entry was
    /// re-opened rather than only that some open happened.
    opens_by_id: [8]struct { track_id: i64 = 0, count: usize = 0 } = @splat(.{}),
    fail_ids: []const i64 = &.{},

    fn opensOf(self: *const TestOpener, track_id: i64) usize {
        for (self.opens_by_id) |record| {
            if (record.track_id == track_id) return record.count;
        }
        return 0;
    }

    fn noteOpen(self: *TestOpener, track_id: i64) void {
        for (&self.opens_by_id) |*record| {
            if (record.track_id != track_id and record.track_id != 0) continue;
            record.track_id = track_id;
            record.count += 1;
            return;
        }
    }

    const Backing = struct {
        allocator: std.mem.Allocator,
        decoder_state: RampDecoder,

        fn release(context: *anyopaque) void {
            const self: *Backing = @ptrCast(@alignCast(context));
            self.allocator.destroy(self);
        }
    };

    fn opener(self: *TestOpener) playback_queue.TrackOpener {
        return .{ .context = self, .open_fn = open };
    }

    fn open(
        context: *anyopaque,
        ref: playback_queue.TrackRef,
    ) anyerror!source_session.SourceSession {
        const self: *TestOpener = @ptrCast(@alignCast(context));
        for (self.fail_ids) |id| {
            if (id == ref.track_id) return error.TrackFileMissing;
        }
        for (self.plans) |plan| {
            if (plan.track_id != ref.track_id) continue;
            self.opens += 1;
            self.noteOpen(ref.track_id);
            const backing = try self.allocator.create(Backing);
            backing.* = .{
                .allocator = self.allocator,
                .decoder_state = .{
                    .total = plan.frames,
                    .channels = plan.channels,
                    .sample_rate = plan.sample_rate,
                },
            };
            return source_session.SourceSession.initOwned(
                backing.decoder_state.decoder(),
                .{ .context = backing, .release = Backing.release },
            );
        }
        return error.TrackHasNoPlayableFile;
    }
};

const QueueHarness = struct {
    allocator: std.mem.Allocator,
    backend: output_api.TestBackend,
    player: player_api.Player = .{},
    queue: playback_queue.PlaybackQueue = undefined,
    test_opener: TestOpener = undefined,
    engine: *PlayerEngine = undefined,
    registration: work.Registration = .{},
    runtime_zone: *ZoneRuntime = undefined,

    fn init(allocator: std.mem.Allocator, plans: []const TrackPlan) !*QueueHarness {
        const self = try allocator.create(QueueHarness);
        self.* = .{ .allocator = allocator, .backend = .{ .allocator = allocator } };
        self.queue = .init(allocator, 0xabc_def);
        self.test_opener = .{ .allocator = allocator, .plans = plans };
        self.engine = try PlayerEngine.create(allocator, .{
            .player = &self.player,
            .handle = .{ .index = 0, .generation = 1 },
            .factory = self.backend.factory(),
            .queue = &self.queue,
            .opener = self.test_opener.opener(),
        });
        self.engine.registration = &self.registration;
        self.runtime_zone = try openZone(allocator);
        try self.engine.publishZones(&.{self.runtime_zone});
        return self;
    }

    fn deinit(self: *QueueHarness) void {
        const allocator = self.allocator;
        self.engine.releasePending();
        self.engine.destroy();
        self.runtime_zone.destroy();
        self.player.deinit();
        self.queue.deinit();
        self.backend.deinit();
        allocator.destroy(self);
    }

    fn enqueue(self: *QueueHarness, ids: []const i64) !void {
        var refs: [16]playback_queue.TrackRef = undefined;
        for (ids, refs[0..ids.len]) |id, *ref|
            ref.* = .{ .library = .{ .index = 0, .generation = 1 }, .track_id = id };
        try self.queue.enqueue(refs[0..ids.len]);
    }

    /// One engine pass plus one device callback, which is what actually moves
    /// the audible cursor: now-playing follows rendered audio, not decoding.
    fn step(self: *QueueHarness, callback_frames: u32) void {
        self.engine.pass();
        if (callback_frames == 0) return;
        if (liveStreamFor(&self.backend, self.runtime_zone)) |stream| {
            var samples: [frames_per_block * 2]f32 = undefined;
            const channels = @max(1, self.runtime_zone.channels);
            stream.pump(samples[0 .. callback_frames * channels], callback_frames);
        }
    }

    fn run(self: *QueueHarness, passes: usize, callback_frames: u32) void {
        for (0..passes) |_| self.step(callback_frames);
    }
};

test "auto-advance opens the next entry at EOF and stays gapless" {
    const allocator = std.testing.allocator;
    var harness = try QueueHarness.init(allocator, &.{
        .{ .track_id = 10, .frames = 2048 },
        .{ .track_id = 11, .frames = 2048 },
        .{ .track_id = 12, .frames = 2048 },
    });
    defer harness.deinit();
    try harness.enqueue(&.{ 10, 11, 12 });
    harness.player.play();

    harness.run(200, 128);

    // Every entry was started, and every transition was gapless: the formats
    // match, so no output ever had to be reopened.
    try std.testing.expectEqual(@as(u64, 3), harness.engine.entries_started);
    try std.testing.expectEqual(@as(u64, 2), harness.engine.gapless_transitions);
    try std.testing.expectEqual(@as(u64, 0), harness.engine.format_switch_transitions);
    try std.testing.expectEqual(@as(u32, 2), harness.queue.cursorPosition());
    // A gapless transition keeps one epoch throughout: no discontinuity.
    try std.testing.expectEqual(@as(u32, 2), harness.player.snapshot().epoch);
}

test "now playing reports the audible entry, not the decoded one" {
    const allocator = std.testing.allocator;
    // A first entry short enough that the producer decodes past its end while
    // its audio is all still sitting in the render queue, unheard.
    var harness = try QueueHarness.init(allocator, &.{
        .{ .track_id = 10, .frames = 2 * frames_per_block },
        .{ .track_id = 11, .frames = 8192 },
    });
    defer harness.deinit();
    try harness.enqueue(&.{ 10, 11 });
    harness.player.play();

    // Decode with no device callbacks at all: the successor gets primed while
    // nothing whatsoever has been rendered.
    var pass: usize = 0;
    while (pass < 64 and harness.engine.gapless_transitions == 0) : (pass += 1)
        harness.step(0);
    try std.testing.expectEqual(@as(u64, 1), harness.engine.gapless_transitions);
    try std.testing.expectEqual(@as(u32, 1), harness.queue.decodePosition());
    try std.testing.expectEqual(@as(u32, 0), harness.queue.cursorPosition());

    // Render a fraction of the first entry. The decode cursor is a whole entry
    // ahead, so reporting it would name the wrong track here.
    harness.step(64);
    harness.step(64);
    try std.testing.expectEqual(@as(u32, 1), harness.queue.decodePosition());
    try std.testing.expectEqual(@as(u32, 0), harness.queue.cursorPosition());

    // Only once the callback crosses into the successor's blocks does
    // now-playing move — and it does so without any epoch change.
    const epoch_before = harness.player.snapshot().epoch;
    harness.run(64, frames_per_block);
    try std.testing.expectEqual(@as(u32, 1), harness.queue.cursorPosition());
    try std.testing.expectEqual(epoch_before, harness.player.snapshot().epoch);
}

test "reported duration follows the audible entry, not the one being decoded" {
    const allocator = std.testing.allocator;
    // Deliberately different lengths: reporting the decoded entry's duration is
    // exactly what made now-playing advertise the next track's length while the
    // previous one was still audible.
    const first_frames: u64 = 4 * frames_per_block;
    const second_frames: u64 = 400 * frames_per_block;
    var harness = try QueueHarness.init(allocator, &.{
        .{ .track_id = 10, .frames = first_frames },
        .{ .track_id = 11, .frames = second_frames },
    });
    defer harness.deinit();
    try harness.enqueue(&.{ 10, 11 });
    harness.player.play();

    // Decode until the producer is a whole entry ahead of the audio, which is
    // the window the defect lived in.
    var pass: usize = 0;
    while (pass < 64 and harness.engine.gapless_transitions == 0) : (pass += 1)
        harness.step(0);
    try std.testing.expectEqual(@as(u64, 1), harness.engine.gapless_transitions);
    try std.testing.expectEqual(@as(u32, 1), harness.queue.decodePosition());

    // Render a little of the first entry and hold there. Identity, duration and
    // position must all still describe entry 0.
    harness.step(64);
    harness.step(64);
    try std.testing.expectEqual(@as(u32, 0), harness.queue.cursorPosition());
    try std.testing.expectEqual(
        first_frames,
        harness.player.published_frame_count.load(.acquire),
    );
    try std.testing.expect(harness.player.snapshot().position_frames <= first_frames);

    // Only when the callback crosses into the successor do all three move, in
    // the same pass, together.
    while (pass < 256 and harness.queue.cursorPosition() == 0) : (pass += 1)
        harness.step(frames_per_block);
    try std.testing.expectEqual(@as(u32, 1), harness.queue.cursorPosition());
    try std.testing.expectEqual(
        second_frames,
        harness.player.published_frame_count.load(.acquire),
    );
}

test "a seek during a gapless transition re-opens the audible entry" {
    const allocator = std.testing.allocator;
    const entry_frames: u64 = 64 * frames_per_block;
    var harness = try QueueHarness.init(allocator, &.{
        .{ .track_id = 10, .frames = entry_frames },
        .{ .track_id = 11, .frames = entry_frames },
    });
    defer harness.deinit();
    try harness.enqueue(&.{ 10, 11 });
    harness.player.play();

    // Reach the window where the producer has already moved on to entry 1 while
    // entry 0's tail is still queued and audible. Priming the successor is not
    // enough: the divergence begins when the decode cursor actually *advances*
    // onto it and entry 0's decoder is released.
    var pass: usize = 0;
    while (pass < 512) : (pass += 1) {
        harness.step(32);
        if (harness.queue.cursorPosition() != 0) break;
        if (harness.player.entrySerial() != harness.player.audible_entry_serial.load(.acquire))
            break;
    }
    try std.testing.expectEqual(@as(u32, 1), harness.queue.decodePosition());
    try std.testing.expectEqual(@as(u32, 0), harness.queue.cursorPosition());
    try std.testing.expectEqual(@as(usize, 1), harness.test_opener.opensOf(10));

    // The user drags the seek bar. It names a point in the track being *heard*.
    const target: u64 = 8 * frames_per_block;
    _ = try harness.player.seek(target);
    // The control lane could not apply it: entry 0's decoder is already gone.
    try std.testing.expect(harness.player.pending_seek != null);
    harness.step(0);
    // The engine re-opened entry 0 and seeked *that*, and the decode-ahead work
    // for entry 1 went with it rather than being played next.
    try std.testing.expectEqual(@as(u64, 1), harness.engine.seek_reopens);
    try std.testing.expectEqual(@as(usize, 2), harness.test_opener.opensOf(10));
    try std.testing.expectEqual(@as(u32, 0), harness.queue.cursorPosition());
    try std.testing.expectEqual(@as(u32, 0), harness.queue.decodePosition());
    try std.testing.expectEqual(target, harness.player.snapshot().position_frames);

    // And the following entry still arrives afterwards, still gaplessly: a fix
    // that corrected the seek but broke the next transition would not be one.
    const gapless_before = harness.engine.gapless_transitions;
    pass = 0;
    while (pass < 1024 and harness.queue.cursorPosition() == 0) : (pass += 1)
        harness.step(frames_per_block);
    try std.testing.expectEqual(@as(u32, 1), harness.queue.cursorPosition());
    try std.testing.expect(harness.engine.gapless_transitions > gapless_before);
    try std.testing.expectEqual(@as(u64, 0), harness.engine.format_switch_transitions);
    try std.testing.expectEqual(@as(u64, 0), harness.engine.decode_errors);
    try std.testing.expectEqual(@as(u64, 0), harness.engine.open_failures);
}

test "a seek inside the entry being decoded is applied without re-opening it" {
    const allocator = std.testing.allocator;
    var harness = try QueueHarness.init(allocator, &.{
        .{ .track_id = 10, .frames = 400 * frames_per_block },
        .{ .track_id = 11, .frames = 400 * frames_per_block },
    });
    defer harness.deinit();
    try harness.enqueue(&.{ 10, 11 });
    harness.player.play();
    harness.run(8, 128);
    try std.testing.expectEqual(@as(u32, 0), harness.queue.decodePosition());

    const target: u64 = 100 * frames_per_block;
    _ = try harness.player.seek(target);
    // Nothing deferred, nothing re-opened: the ordinary path is untouched.
    try std.testing.expect(harness.player.pending_seek == null);
    harness.step(128);
    try std.testing.expectEqual(@as(u64, 0), harness.engine.seek_reopens);
    try std.testing.expectEqual(@as(usize, 1), harness.test_opener.opensOf(10));
    try std.testing.expect(harness.player.snapshot().position_frames >= target);
}

test "position restarts at zero for every entry a gapless advance reaches" {
    const allocator = std.testing.allocator;
    const entry_frames: u64 = 8192;
    var harness = try QueueHarness.init(allocator, &.{
        .{ .track_id = 10, .frames = entry_frames },
        .{ .track_id = 11, .frames = entry_frames },
    });
    defer harness.deinit();
    try harness.enqueue(&.{ 10, 11 });
    harness.player.play();

    // Highest position ever reported while each entry was the audible one. The
    // epoch does not move across a gapless advance, so without re-anchoring the
    // second entry would inherit the first entry's whole duration.
    var highest: [2]u64 = .{ 0, 0 };
    var first_after_advance: ?u64 = null;
    for (0..200) |_| {
        harness.step(128);
        const cursor = harness.queue.cursorPosition();
        const frames = harness.player.snapshot().position_frames;
        highest[cursor] = @max(highest[cursor], frames);
        if (cursor == 1 and first_after_advance == null) first_after_advance = frames;
    }

    try std.testing.expectEqual(@as(u32, 1), harness.queue.cursorPosition());
    // Neither entry is ever reported past its own end.
    try std.testing.expect(highest[0] <= entry_frames);
    try std.testing.expect(highest[1] <= entry_frames);
    // The successor started from its own zero rather than continuing the first.
    try std.testing.expect(first_after_advance.? <= 128);
    // ...and it still ran all the way through, so nothing was clamped away.
    try std.testing.expect(highest[1] >= entry_frames - 128);
    // One epoch throughout: this was a gapless advance, not a hard switch.
    try std.testing.expectEqual(@as(u32, 2), harness.player.snapshot().epoch);
}

test "a seek base stays inside the entry it was stamped for" {
    const allocator = std.testing.allocator;
    const entry_frames: u64 = 8192;
    var harness = try QueueHarness.init(allocator, &.{
        .{ .track_id = 10, .frames = entry_frames },
        .{ .track_id = 11, .frames = entry_frames },
    });
    defer harness.deinit();
    try harness.enqueue(&.{ 10, 11 });
    harness.player.play();
    harness.run(4, 128);

    // Seek near the end of the first entry: the epoch moves and a seek base is
    // stamped with it. The gapless advance that follows must not add that base
    // to the successor's position.
    const seek_target: u64 = entry_frames - 1024;
    _ = try harness.player.seek(seek_target);
    harness.step(128);
    try std.testing.expect(harness.player.snapshot().position_frames >= seek_target);

    var highest: [2]u64 = .{ 0, 0 };
    var first_after_advance: ?u64 = null;
    for (0..200) |_| {
        harness.step(128);
        const cursor = harness.queue.cursorPosition();
        const frames = harness.player.snapshot().position_frames;
        highest[cursor] = @max(highest[cursor], frames);
        if (cursor == 1 and first_after_advance == null) first_after_advance = frames;
    }

    try std.testing.expectEqual(@as(u32, 1), harness.queue.cursorPosition());
    try std.testing.expect(highest[0] <= entry_frames);
    try std.testing.expect(highest[1] <= entry_frames);
    try std.testing.expect(first_after_advance.? <= 128);
}

test "a format change between entries reopens the output instead of failing" {
    const allocator = std.testing.allocator;
    var harness = try QueueHarness.init(allocator, &.{
        .{ .track_id = 10, .frames = 2048, .channels = 1, .sample_rate = 44_100 },
        .{ .track_id = 11, .frames = 2048, .channels = 2, .sample_rate = 48_000 },
    });
    defer harness.deinit();
    try harness.enqueue(&.{ 10, 11 });
    harness.player.play();

    harness.run(400, 128);

    try std.testing.expectEqual(@as(u64, 2), harness.engine.entries_started);
    // Not gapless — honestly reported as a format switch rather than an error.
    try std.testing.expectEqual(@as(u64, 0), harness.engine.gapless_transitions);
    try std.testing.expectEqual(@as(u64, 1), harness.engine.format_switch_transitions);
    try std.testing.expectEqual(@as(u32, 1), harness.queue.cursorPosition());
    // The stream really was reopened at the new layout.
    try std.testing.expectEqual(@as(u16, 2), harness.runtime_zone.channels);
    try std.testing.expectEqual(
        @as(u32, 48_000),
        harness.runtime_zone.open_format.?.sample_rate,
    );
    try std.testing.expectEqual(
        zone_model.OutputState.active,
        harness.runtime_zone.outputState(),
    );
}

test "position restarts for an entry reached through a format switch" {
    const allocator = std.testing.allocator;
    const entry_frames: u64 = 4096;
    var harness = try QueueHarness.init(allocator, &.{
        .{ .track_id = 10, .frames = entry_frames, .channels = 1, .sample_rate = 44_100 },
        .{ .track_id = 11, .frames = entry_frames, .channels = 2, .sample_rate = 48_000 },
    });
    defer harness.deinit();
    try harness.enqueue(&.{ 10, 11 });
    harness.player.play();

    // A format switch drains every Zone, reopens the outputs and hard-loads the
    // successor. That path bumps the epoch, so the entry it starts has to
    // re-anchor from zero just as a gapless one does.
    var highest: [2]u64 = .{ 0, 0 };
    for (0..400) |_| {
        harness.step(128);
        const cursor = harness.queue.cursorPosition();
        highest[cursor] = @max(highest[cursor], harness.player.snapshot().position_frames);
    }

    try std.testing.expectEqual(@as(u64, 1), harness.engine.format_switch_transitions);
    try std.testing.expectEqual(@as(u32, 1), harness.queue.cursorPosition());
    try std.testing.expect(highest[0] <= entry_frames);
    try std.testing.expect(highest[1] <= entry_frames);
    try std.testing.expect(highest[1] >= entry_frames - 128);
}

test "repeat_one re-primes a fresh session instead of seeking the draining one" {
    const allocator = std.testing.allocator;
    const entry_frames: u64 = 1024;
    var harness = try QueueHarness.init(allocator, &.{
        .{ .track_id = 10, .frames = entry_frames },
    });
    defer harness.deinit();
    try harness.enqueue(&.{10});
    harness.queue.setRepeat(.one);
    harness.player.play();

    var highest: u64 = 0;
    for (0..200) |_| {
        harness.step(128);
        highest = @max(highest, harness.player.snapshot().position_frames);
    }
    // Each repetition is a fresh entry with a fresh serial, so position starts
    // over rather than counting the repeats up.
    try std.testing.expect(highest <= entry_frames);

    // The same entry, opened again and again — each with its own decoder, so
    // the copy still draining into the pipe is never seeked underneath.
    try std.testing.expect(harness.engine.gapless_transitions > 2);
    try std.testing.expectEqual(@as(u32, 0), harness.queue.cursorPosition());
    try std.testing.expectEqual(@as(u32, 0), harness.queue.decodePosition());
}

test "repeat_all wraps the queue back to its first entry" {
    const allocator = std.testing.allocator;
    var harness = try QueueHarness.init(allocator, &.{
        .{ .track_id = 10, .frames = 1024 },
        .{ .track_id = 11, .frames = 1024 },
    });
    defer harness.deinit();
    try harness.enqueue(&.{ 10, 11 });
    harness.queue.setRepeat(.all);
    harness.player.play();

    harness.run(400, 128);
    try std.testing.expect(harness.engine.entries_started > 3);
    // Wrapped rather than stopping at the end.
    try std.testing.expect(harness.test_opener.opens > 3);
}

test "an unreadable entry is stepped over rather than looping forever" {
    const allocator = std.testing.allocator;
    var harness = try QueueHarness.init(allocator, &.{
        .{ .track_id = 10, .frames = 1024 },
        .{ .track_id = 11, .frames = 1024 },
        .{ .track_id = 12, .frames = 1024 },
    });
    defer harness.deinit();
    harness.test_opener.fail_ids = &.{11};
    try harness.enqueue(&.{ 10, 11, 12 });
    harness.player.play();

    harness.run(300, 128);
    try std.testing.expectEqual(@as(u64, 1), harness.engine.open_failures);
    try std.testing.expectEqual(@as(u64, 2), harness.engine.entries_started);
    try std.testing.expectEqual(@as(u32, 2), harness.queue.decodePosition());
}

const FailingDecoder = struct {
    position: u64 = 0,
    fail_after: u64,

    fn decoder(self: *FailingDecoder) @import("../codec/decoder.zig").Decoder {
        return .{
            .context = self,
            .vtable = &.{ .read_frames = read, .seek = seekTo, .deinit = release },
            .format = .{
                .sample_format = .float_32,
                .channels = 1,
                .sample_rate = 48_000,
                .bits_per_sample = 32,
                .bytes_per_frame = 4,
            },
            .frame_count = 1_000_000,
        };
    }

    fn read(context: *anyopaque, output: []f32) !usize {
        const self: *FailingDecoder = @ptrCast(@alignCast(context));
        if (self.position >= self.fail_after) return error.EndOfStream;
        const frames = @min(output.len, self.fail_after - self.position);
        @memset(output[0..frames], 0.25);
        self.position += frames;
        return frames;
    }

    fn seekTo(_: *anyopaque, _: u64) !void {}
    fn release(_: *anyopaque) void {}
};

test "a decoder that fails mid-entry ends the entry instead of stalling the queue" {
    const allocator = std.testing.allocator;
    var harness = try QueueHarness.init(allocator, &.{
        .{ .track_id = 11, .frames = 1024 },
    });
    defer harness.deinit();
    try harness.enqueue(&.{ 10, 11 });

    // Entry 0 claims a million frames and then throws. Without ending the
    // entry, nothing would ever prime entry 1 and every Zone would underrun
    // for the rest of the session — which is exactly what real FLAC files do
    // after a seek near their end.
    var failing: FailingDecoder = .{ .fail_after = 512 };
    try harness.player.loadSource(source_session.SourceSession.init(failing.decoder()));
    harness.queue.noteEntrySerial(harness.player.entrySerial(), 0);
    harness.player.play();

    harness.run(200, 128);

    try std.testing.expect(harness.engine.decode_errors > 0);
    try std.testing.expectEqual(@as(u64, 1), harness.engine.entries_started);
    try std.testing.expectEqual(@as(u32, 1), harness.queue.cursorPosition());
}
