const std = @import("std");
const object = @import("../core/object.zig");
const source_session = @import("source_session.zig");

/// Bounded like every other Orca queue. Enqueueing past this applies
/// backpressure — `error.PlaybackQueueFull` — rather than growing without limit.
pub const capacity: usize = 10_000;

/// How many recently prepared entries keep a serial -> position mapping.
/// The decode lane can be at most one entry ahead of the audible one, so this
/// only has to outlive the render-ahead depth; eight is generous.
const serial_map_len: usize = 8;

/// Position past which `previous` restarts the current entry instead of moving
/// the cursor back. The universal transport convention.
pub const restart_threshold_ms: u64 = 3_000;

/// A queue entry: which Library, and which Track inside it. Never a path — the
/// bytes are resolved through `TrackRepository.playableLocation` at the moment
/// the entry is opened, so a file that moved between enqueue and play is found
/// at its current location.
pub const TrackRef = struct {
    library: object.LibraryHandle,
    track_id: i64,

    pub fn eql(self: TrackRef, other: TrackRef) bool {
        return self.track_id == other.track_id and self.library.eql(other.library);
    }
};

pub const RepeatMode = enum(u8) { off, all, one };

/// Opens the audio behind a queue entry.
///
/// Context + vtable rather than a generic, for the same reason `Decoder` and
/// `ReadableSource` are: the engine thread holds one of these and must not know
/// what is behind it — a Library database, a test double, or later a provider.
/// The returned session is self-contained (`LoadedSource`), so nothing backing
/// its decoder lives in the caller's frame.
pub const TrackOpener = struct {
    context: *anyopaque,
    open_fn: *const fn (context: *anyopaque, ref: TrackRef) anyerror!source_session.SourceSession,
    /// The Release an entry's Track is filed under, for smart ReplayGain.
    /// Null, or a null answer, means "no Release", which never matches.
    release_fn: ?*const fn (context: *anyopaque, ref: TrackRef) ?i64 = null,

    pub fn open(self: TrackOpener, ref: TrackRef) anyerror!source_session.SourceSession {
        return self.open_fn(self.context, ref);
    }

    pub fn releaseOf(self: TrackOpener, ref: TrackRef) ?i64 {
        const release_fn = self.release_fn orelse return null;
        return release_fn(self.context, ref);
    }
};

const SerialRecord = struct {
    serial: u32,
    position: u32,

    fn pack(self: SerialRecord) u64 {
        return @as(u64, self.serial) << 32 | self.position;
    }

    fn unpack(word: u64) SerialRecord {
        return .{ .serial = @truncate(word >> 32), .position = @truncate(word) };
    }
};

pub const Snapshot = struct {
    entries: u32,
    /// Audible position — the entry the render callback is actually emitting.
    cursor: u32,
    /// Position the decoder has reached. Leads `cursor` across a gapless
    /// transition by the whole render-ahead depth.
    decode_position: u32,
    repeat: RepeatMode,
    shuffle: bool,
};

/// The playback queue that sits *above* `SourceQueue`.
///
/// `SourceQueue` is the decode queue: one current session plus one
/// format-matched prepared successor. This is the list the user actually sees —
/// track references, a cursor, repeat and shuffle.
///
/// Two cursors, deliberately:
/// * `cursor` is the **audible** position, derived from the `entry_serial` the
///   render callback publishes. Every user-facing operation (`next`,
///   `previous`, now-playing) resolves from it, so pressing skip during a
///   gapless transition advances one track rather than two.
/// * `decode_position` is where the producer has got to. Auto-advance resolves
///   from it.
///
/// Threading: owned by the Player and mutated only from the control lane and
/// the engine thread, never from the render callback. The control lane
/// quiesces the engine before touching the entry list — the same handshake that
/// protects `Player.sources`, and for the same reason: those are plain
/// containers. The three values a host polls (cursor, decode position, entry
/// count) are atomics, so reporting now-playing never has to stop the producer.
pub const PlaybackQueue = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(TrackRef) = .empty,
    /// Each entry's identity, parallel to `entries`: unique for the queue's
    /// lifetime and kept across moves, inserts, removals and shuffle.
    ids: std.ArrayList(u64) = .empty,
    next_id: u64 = 1,
    /// Playback order. Empty means "entry order"; when shuffled it is a
    /// permutation of entry indices. A permutation rather than a random pick
    /// per advance, because random-next has no history and breaks `previous`.
    order: std.ArrayList(u32) = .empty,
    /// Audible position, decode position and entry count are read by the
    /// control lane while the engine thread is running, so the three values a
    /// snapshot needs are atomics, as are the serial records queue history
    /// resolves. Everything else here is plain state guarded by the
    /// `quiesce`/`release` handshake.
    cursor: std.atomic.Value(u32) = .init(0),
    decode_position: std.atomic.Value(u32) = .init(0),
    entry_count: std.atomic.Value(u32) = .init(0),
    repeat: RepeatMode = .off,
    shuffle: bool = false,
    prng: std.Random.DefaultPrng,
    serials: [serial_map_len]std.atomic.Value(u64) = @splat(.init(0)),
    serial_head: usize = 0,

    pub fn init(allocator: std.mem.Allocator, seed: u64) PlaybackQueue {
        return .{ .allocator = allocator, .prng = .init(seed) };
    }

    pub fn deinit(self: *PlaybackQueue) void {
        self.entries.deinit(self.allocator);
        self.ids.deinit(self.allocator);
        self.order.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn len(self: *const PlaybackQueue) u32 {
        return @intCast(self.entries.items.len);
    }

    /// Audible position. The only queue field a host polls at UI rates, so it
    /// is readable without stopping the engine.
    pub fn cursorPosition(self: *const PlaybackQueue) u32 {
        return self.cursor.load(.acquire);
    }

    pub fn decodePosition(self: *const PlaybackQueue) u32 {
        return self.decode_position.load(.acquire);
    }

    fn setCursor(self: *PlaybackQueue, position: u32) void {
        self.cursor.store(position, .release);
    }

    fn publishCount(self: *PlaybackQueue) void {
        self.entry_count.store(@intCast(self.entries.items.len), .release);
    }

    pub fn isEmpty(self: *const PlaybackQueue) bool {
        return self.entries.items.len == 0;
    }

    /// Lock-free: every field comes from an atomic, so a host may poll this
    /// while the engine thread is mid-pass.
    pub fn snapshot(self: *const PlaybackQueue) Snapshot {
        return .{
            .entries = self.entry_count.load(.acquire),
            .cursor = self.cursorPosition(),
            .decode_position = self.decodePosition(),
            .repeat = self.repeat,
            .shuffle = self.shuffle,
        };
    }

    /// Entry index behind a playback position, honoring the shuffle permutation.
    pub fn entryIndex(self: *const PlaybackQueue, position: u32) ?u32 {
        if (position >= self.entries.items.len) return null;
        if (self.order.items.len == self.entries.items.len)
            return self.order.items[position];
        return position;
    }

    pub fn refAt(self: *const PlaybackQueue, position: u32) ?TrackRef {
        const index = self.entryIndex(position) orelse return null;
        return self.entries.items[index];
    }

    /// Whether the entry before or after `position` in playback order is
    /// filed under the same Release as it. What smart ReplayGain keys on, so
    /// it follows shuffle and every reorder rather than entry order.
    pub fn sharesRelease(self: *const PlaybackQueue, position: u32, opener: TrackOpener) bool {
        const ref = self.refAt(position) orelse return false;
        const release = opener.releaseOf(ref) orelse return false;
        if (position > 0) {
            if (self.refAt(position - 1)) |before| if (opener.releaseOf(before) == release) return true;
        }
        if (self.refAt(position + 1)) |after| if (opener.releaseOf(after) == release) return true;
        return false;
    }

    pub fn idAt(self: *const PlaybackQueue, position: u32) ?u64 {
        const index = self.entryIndex(position) orelse return null;
        return self.ids.items[index];
    }

    pub fn positionOfId(self: *const PlaybackQueue, id: u64) ?u32 {
        const index = std.mem.indexOfScalar(u64, self.ids.items, id) orelse return null;
        return self.positionOfEntry(@intCast(index));
    }

    fn newIds(self: *PlaybackQueue, count: usize) void {
        for (self.ids.items.len..self.ids.items.len + count) |_| {
            self.ids.appendAssumeCapacity(self.next_id);
            self.next_id += 1;
        }
    }

    pub fn current(self: *const PlaybackQueue) ?TrackRef {
        return self.refAt(self.cursorPosition());
    }

    pub fn enqueue(self: *PlaybackQueue, refs: []const TrackRef) !void {
        if (self.entries.items.len + refs.len > capacity) return error.PlaybackQueueFull;
        const first_new: u32 = @intCast(self.entries.items.len);
        try self.ids.ensureUnusedCapacity(self.allocator, refs.len);
        if (self.order.items.len != 0) try self.order.ensureUnusedCapacity(self.allocator, refs.len);
        try self.entries.appendSlice(self.allocator, refs);
        self.newIds(refs.len);
        self.publishCount();
        if (self.order.items.len != 0) {
            // Shuffled: new entries join the tail of the existing permutation
            // rather than being interleaved, so nothing already scheduled moves.
            var index = first_new;
            while (index < self.entries.items.len) : (index += 1)
                self.order.appendAssumeCapacity(index);
        }
    }

    /// Replaces the whole queue and points the cursor at `start`.
    pub fn replace(self: *PlaybackQueue, refs: []const TrackRef, start: u32) !void {
        if (refs.len > capacity) return error.PlaybackQueueFull;
        if (refs.len != 0 and start >= refs.len) return error.PositionOutOfRange;
        try self.ids.ensureTotalCapacity(self.allocator, refs.len);
        self.entries.clearRetainingCapacity();
        self.ids.clearRetainingCapacity();
        try self.entries.appendSlice(self.allocator, refs);
        self.newIds(refs.len);
        self.publishCount();
        self.order.clearRetainingCapacity();
        self.setCursor(if (refs.len == 0) 0 else start);
        self.decode_position.store(self.cursorPosition(), .release);
        self.forgetSerials();
        if (self.shuffle) {
            try self.regenerateOrder();
            // The caller asked for this entry, so it keeps the cursor even
            // under shuffle: "play this one, shuffle the rest".
            if (refs.len != 0) self.placeAtCursor(start);
        }
    }

    /// Replaces the whole queue with a saved one: `refs` in list order, the
    /// shuffled playback `order` (a permutation of entry indices) or null
    /// for list order, and the cursor at playback position `cursor`. Nothing
    /// is reshuffled, so a restored queue plays on in the order it was saved.
    pub fn restore(self: *PlaybackQueue, refs: []const TrackRef, order: ?[]const u32, cursor: u32) !void {
        if (refs.len > capacity) return error.PlaybackQueueFull;
        if (refs.len != 0 and cursor >= refs.len) return error.PositionOutOfRange;
        if (order) |permutation| {
            if (permutation.len != refs.len) return error.InvalidQueueOrder;
            var seen = try std.bit_set.Dynamic.initEmpty(self.allocator, refs.len);
            defer seen.deinit(self.allocator);
            for (permutation) |entry| {
                if (entry >= refs.len or seen.isSet(entry)) return error.InvalidQueueOrder;
                seen.set(entry);
            }
        }
        try self.entries.ensureTotalCapacity(self.allocator, refs.len);
        try self.ids.ensureTotalCapacity(self.allocator, refs.len);
        try self.order.ensureTotalCapacity(self.allocator, if (order) |permutation| permutation.len else 0);
        self.entries.clearRetainingCapacity();
        self.entries.appendSliceAssumeCapacity(refs);
        self.ids.clearRetainingCapacity();
        self.newIds(refs.len);
        self.publishCount();
        self.order.clearRetainingCapacity();
        if (order) |permutation| self.order.appendSliceAssumeCapacity(permutation);
        self.shuffle = order != null;
        self.setCursor(if (refs.len == 0) 0 else cursor);
        self.decode_position.store(self.cursorPosition(), .release);
        self.forgetSerials();
    }

    /// Inserts `refs` to play straight after playback position `after`.
    /// Every position past it — the cursors, recorded serials, and `pending`
    /// if the caller holds one — moves with the entries it named.
    pub fn insertAfter(self: *PlaybackQueue, after: u32, refs: []const TrackRef, pending: ?*u32) !void {
        if (refs.len == 0) return;
        if (self.entries.items.len + refs.len > capacity) return error.PlaybackQueueFull;
        if (after >= self.entries.items.len) return error.PositionOutOfRange;
        const count: u32 = @intCast(refs.len);
        try self.ids.ensureUnusedCapacity(self.allocator, refs.len);
        if (self.order.items.len != 0) {
            const first_new: u32 = @intCast(self.entries.items.len);
            try self.order.ensureUnusedCapacity(self.allocator, refs.len);
            try self.entries.appendSlice(self.allocator, refs);
            self.newIds(refs.len);
            var index: u32 = 0;
            while (index < count) : (index += 1)
                self.order.insertAssumeCapacity(after + 1 + index, first_new + index);
        } else {
            try self.entries.insertSlice(self.allocator, after + 1, refs);
            for (0..refs.len) |offset| {
                self.ids.insertAssumeCapacity(after + 1 + offset, self.next_id);
                self.next_id += 1;
            }
        }
        self.publishCount();
        self.shiftPositions(after + 1, count, .up, pending);
    }

    /// Removes the entry at playback position `position`. The caller refuses
    /// positions the engine has committed to; everything after moves back.
    pub fn removeAt(self: *PlaybackQueue, position: u32, pending: ?*u32) !void {
        const index = self.entryIndex(position) orelse return error.PositionOutOfRange;
        _ = self.entries.orderedRemove(index);
        _ = self.ids.orderedRemove(index);
        if (self.order.items.len != 0) {
            _ = self.order.orderedRemove(position);
            for (self.order.items) |*entry| {
                if (entry.* > index) entry.* -= 1;
            }
        }
        self.publishCount();
        for (&self.serials) |*slot| {
            const record = SerialRecord.unpack(slot.load(.monotonic));
            if (record.serial != 0 and record.position == position) slot.store(0, .release);
        }
        self.shiftPositions(position + 1, 1, .down, pending);
    }

    fn shiftPositions(self: *PlaybackQueue, from: u32, by: u32, direction: enum { up, down }, pending: ?*u32) void {
        const shift = struct {
            fn apply(value: u32, start: u32, amount: u32, way: @TypeOf(direction)) u32 {
                if (value < start) return value;
                return if (way == .up) value + amount else value - amount;
            }
        }.apply;
        self.setCursor(shift(self.cursorPosition(), from, by, direction));
        self.decode_position.store(shift(self.decodePosition(), from, by, direction), .release);
        for (&self.serials) |*slot| {
            const record = SerialRecord.unpack(slot.load(.monotonic));
            if (record.serial == 0) continue;
            slot.store(SerialRecord.pack(.{
                .serial = record.serial,
                .position = shift(record.position, from, by, direction),
            }), .release);
        }
        if (pending) |value| value.* = shift(value.*, from, by, direction);
    }

    /// Moves the entry at playback position `from` so that it plays at `to`.
    /// Under shuffle only the permutation changes, so turning shuffle off puts
    /// entries back in list order. Every position — the cursors, recorded
    /// serials, and `pending` if the caller holds one — follows the entry it
    /// named. The caller refuses moves the engine has committed to.
    pub fn move(self: *PlaybackQueue, from: u32, to: u32, pending: ?*u32) !void {
        const count = self.entries.items.len;
        if (from >= count or to >= count) return error.PositionOutOfRange;
        if (from == to) return;
        if (self.order.items.len == count)
            moveItem(u32, self.order.items, from, to)
        else {
            moveItem(TrackRef, self.entries.items, from, to);
            moveItem(u64, self.ids.items, from, to);
        }
        self.setCursor(movedPosition(self.cursorPosition(), from, to));
        self.decode_position.store(movedPosition(self.decodePosition(), from, to), .release);
        for (&self.serials) |*slot| {
            const record = SerialRecord.unpack(slot.load(.monotonic));
            if (record.serial == 0) continue;
            slot.store(SerialRecord.pack(.{
                .serial = record.serial,
                .position = movedPosition(record.position, from, to),
            }), .release);
        }
        if (pending) |value| value.* = movedPosition(value.*, from, to);
    }

    fn moveItem(comptime T: type, items: []T, from: u32, to: u32) void {
        if (from < to)
            std.mem.rotate(T, items[from .. to + 1], 1)
        else
            std.mem.rotate(T, items[to .. from + 1], from - to);
    }

    fn movedPosition(position: u32, from: u32, to: u32) u32 {
        if (position == from) return to;
        const remaining = if (position > from) position - 1 else position;
        return if (remaining >= to) remaining + 1 else remaining;
    }

    pub fn clear(self: *PlaybackQueue) void {
        self.entries.clearRetainingCapacity();
        self.ids.clearRetainingCapacity();
        self.publishCount();
        self.order.clearRetainingCapacity();
        self.setCursor(0);
        self.decode_position.store(0, .release);
        self.forgetSerials();
    }

    pub fn setRepeat(self: *PlaybackQueue, mode: RepeatMode) void {
        self.repeat = mode;
    }

    /// Toggling shuffle must never restart the song that is playing, so the
    /// permutation is rotated to leave the currently audible entry sitting at
    /// the current cursor.
    pub fn setShuffle(self: *PlaybackQueue, enabled: bool) !void {
        if (enabled == self.shuffle) return;
        const playing = self.entryIndex(self.cursorPosition());
        var serial_entries: [serial_map_len]?u32 = undefined;
        for (&self.serials, &serial_entries) |*slot, *entry|
            entry.* = self.entryIndex(SerialRecord.unpack(slot.load(.monotonic)).position);
        self.shuffle = enabled;
        if (enabled) {
            try self.regenerateOrder();
            if (playing) |index| self.placeAtCursor(index);
        } else {
            self.order.clearRetainingCapacity();
            // Un-shuffled positions *are* entry indices, so the cursor moves to
            // where the playing entry lives in list order.
            if (playing) |index| self.setCursor(index);
        }
        self.decode_position.store(self.cursorPosition(), .release);
        self.remapSerials(&serial_entries);
    }

    fn positionOfEntry(self: *const PlaybackQueue, entry: u32) ?u32 {
        if (entry >= self.entries.items.len) return null;
        if (self.order.items.len != self.entries.items.len) return entry;
        for (self.order.items, 0..) |value, position| {
            if (value == entry) return @intCast(position);
        }
        return null;
    }

    fn remapSerials(self: *PlaybackQueue, entries: *const [serial_map_len]?u32) void {
        for (&self.serials, entries) |*slot, entry| {
            const record = SerialRecord.unpack(slot.load(.monotonic));
            if (record.serial == 0) continue;
            const position = if (entry) |index| self.positionOfEntry(index) else null;
            slot.store(if (position) |value|
                SerialRecord.pack(.{ .serial = record.serial, .position = value })
            else
                0, .release);
        }
    }

    fn regenerateOrder(self: *PlaybackQueue) !void {
        self.order.clearRetainingCapacity();
        try self.order.ensureTotalCapacity(self.allocator, self.entries.items.len);
        var index: u32 = 0;
        while (index < self.entries.items.len) : (index += 1)
            self.order.appendAssumeCapacity(index);
        self.prng.random().shuffle(u32, self.order.items);
    }

    /// Swaps `entry` into the cursor slot of the permutation.
    fn placeAtCursor(self: *PlaybackQueue, entry: u32) void {
        const cursor = self.cursorPosition();
        if (cursor >= self.order.items.len) return;
        for (self.order.items, 0..) |value, position| {
            if (value != entry) continue;
            self.order.items[position] = self.order.items[cursor];
            self.order.items[cursor] = entry;
            return;
        }
    }

    /// Position a user-initiated `next` moves to. `repeat_one` deliberately
    /// does not apply: an explicit skip means "a different track", and only
    /// auto-advance repeats one.
    pub fn nextPosition(self: *const PlaybackQueue) ?u32 {
        return self.nextPositionAfter(self.cursorPosition());
    }

    pub fn nextPositionAfter(self: *const PlaybackQueue, position: u32) ?u32 {
        if (self.entries.items.len == 0) return null;
        const last: u32 = @intCast(self.entries.items.len - 1);
        if (position < last) return position + 1;
        return if (self.repeat == .all) 0 else null;
    }

    pub fn previousPosition(self: *const PlaybackQueue) ?u32 {
        return self.previousPositionBefore(self.cursorPosition());
    }

    pub fn previousPositionBefore(self: *const PlaybackQueue, position: u32) ?u32 {
        if (self.entries.items.len == 0) return null;
        if (position > 0) return position - 1;
        return if (self.repeat == .all)
            @as(u32, @intCast(self.entries.items.len - 1))
        else
            null;
    }

    /// Position auto-advance follows the decode cursor with. This is where
    /// repeat lives: `one` re-opens the same entry (as a fresh session, seeked
    /// to zero — the current one is still draining into the pipe), `all` wraps.
    pub fn followingPosition(self: *const PlaybackQueue) ?u32 {
        if (self.entries.items.len == 0) return null;
        const decode = self.decodePosition();
        if (self.repeat == .one) return decode;
        const last: u32 = @intCast(self.entries.items.len - 1);
        if (decode < last) return decode + 1;
        return if (self.repeat == .all) 0 else null;
    }

    /// A hard switch: both cursors move together and every recorded serial is
    /// dropped, because the audio those serials describe is about to be
    /// discarded by the epoch bump.
    pub fn seekTo(self: *PlaybackQueue, position: u32) void {
        self.setCursor(position);
        self.decode_position.store(position, .release);
        self.forgetSerials();
    }

    /// Auto-advance: only the decode cursor moves. The audible cursor follows
    /// later, when the callback publishes the successor's entry serial.
    pub fn advanceDecodeTo(self: *PlaybackQueue, position: u32) void {
        self.decode_position.store(position, .release);
    }

    /// Records that blocks carrying `serial` belong to queue `position`.
    pub fn noteEntrySerial(self: *PlaybackQueue, serial: u32, position: u32) void {
        if (serial == 0) return;
        self.serials[self.serial_head].store(SerialRecord.pack(.{ .serial = serial, .position = position }), .release);
        self.serial_head = (self.serial_head + 1) % serial_map_len;
    }

    pub fn positionForSerial(self: *const PlaybackQueue, serial: u32) ?u32 {
        if (serial == 0) return null;
        for (&self.serials) |*slot| {
            const record = SerialRecord.unpack(slot.load(.acquire));
            if (record.serial == serial) return record.position;
        }
        return null;
    }

    /// Engine thread. Moves the audible cursor to whatever the render callback
    /// last actually emitted. Unknown serials are ignored, so a stale value left
    /// over from retired audio can never drag the cursor backwards.
    pub fn observeRenderedSerial(self: *PlaybackQueue, serial: u32) void {
        const position = self.positionForSerial(serial) orelse return;
        self.setCursor(position);
    }

    fn forgetSerials(self: *PlaybackQueue) void {
        for (&self.serials) |*slot| slot.store(0, .release);
        self.serial_head = 0;
    }
};

const testing = std.testing;
const test_library: object.LibraryHandle = .{ .index = 0, .generation = 1 };

fn makeRefs(allocator: std.mem.Allocator, ids: []const i64) ![]TrackRef {
    const list = try allocator.alloc(TrackRef, ids.len);
    for (ids, list) |id, *entry| entry.* = .{ .library = test_library, .track_id = id };
    return list;
}

test "enqueue past capacity applies backpressure instead of growing" {
    var queue = PlaybackQueue.init(testing.allocator, 1);
    defer queue.deinit();
    const filler = try testing.allocator.alloc(TrackRef, capacity);
    defer testing.allocator.free(filler);
    for (filler, 0..) |*entry, index|
        entry.* = .{ .library = test_library, .track_id = @intCast(index) };
    try queue.enqueue(filler);
    try testing.expectEqual(@as(u32, capacity), queue.len());
    try testing.expectError(
        error.PlaybackQueueFull,
        queue.enqueue(&.{.{ .library = test_library, .track_id = 1 }}),
    );
    try testing.expectEqual(@as(u32, capacity), queue.len());
}

test "next stops at the end unless repeat_all wraps the cursor" {
    var queue = PlaybackQueue.init(testing.allocator, 1);
    defer queue.deinit();
    const list = try makeRefs(testing.allocator, &.{ 10, 11, 12 });
    defer testing.allocator.free(list);
    try queue.enqueue(list);

    try testing.expectEqual(@as(?u32, 1), queue.nextPosition());
    queue.seekTo(2);
    try testing.expectEqual(@as(?u32, null), queue.nextPosition());
    queue.setRepeat(.all);
    try testing.expectEqual(@as(?u32, 0), queue.nextPosition());
    try testing.expectEqual(@as(?u32, 1), queue.previousPosition());
    queue.seekTo(0);
    try testing.expectEqual(@as(?u32, 2), queue.previousPosition());
}

test "repeat_one auto-advances onto the same entry while a skip still moves on" {
    var queue = PlaybackQueue.init(testing.allocator, 1);
    defer queue.deinit();
    const list = try makeRefs(testing.allocator, &.{ 10, 11, 12 });
    defer testing.allocator.free(list);
    try queue.enqueue(list);
    queue.setRepeat(.one);
    queue.seekTo(1);

    try testing.expectEqual(@as(?u32, 1), queue.followingPosition());
    // An explicit skip is a different intent from a track ending.
    try testing.expectEqual(@as(?u32, 2), queue.nextPosition());
}

test "toggling shuffle keeps the playing entry under the cursor" {
    var queue = PlaybackQueue.init(testing.allocator, 0xfeed);
    defer queue.deinit();
    const list = try makeRefs(testing.allocator, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    defer testing.allocator.free(list);
    try queue.enqueue(list);
    queue.seekTo(5);
    const playing = queue.current().?;

    try queue.setShuffle(true);
    try testing.expectEqual(@as(u32, 5), queue.cursorPosition());
    try testing.expect(queue.current().?.eql(playing));
    // Still a permutation: every entry appears exactly once.
    var seen: [8]bool = @splat(false);
    for (queue.order.items) |index| {
        try testing.expect(!seen[index]);
        seen[index] = true;
    }
    for (seen) |value| try testing.expect(value);

    // previous still has real history under shuffle, which a random-next
    // implementation could not offer.
    const before = queue.refAt(queue.previousPosition().?).?;
    queue.seekTo(queue.previousPosition().?);
    try testing.expect(queue.current().?.eql(before));

    queue.seekTo(5);
    try queue.setShuffle(false);
    try testing.expect(queue.current().?.eql(playing));
}

test "now playing follows the rendered serial rather than the decode cursor" {
    var queue = PlaybackQueue.init(testing.allocator, 1);
    defer queue.deinit();
    const list = try makeRefs(testing.allocator, &.{ 10, 11, 12 });
    defer testing.allocator.free(list);
    try queue.enqueue(list);
    queue.noteEntrySerial(7, 0);

    // The producer primes entry 1 while entry 0 is still audible.
    queue.advanceDecodeTo(1);
    queue.noteEntrySerial(8, 1);
    queue.observeRenderedSerial(7);
    try testing.expectEqual(@as(u32, 0), queue.cursorPosition());
    try testing.expectEqual(@as(u32, 1), queue.decodePosition());

    // Only once the callback actually renders the successor does now-playing move.
    queue.observeRenderedSerial(8);
    try testing.expectEqual(@as(u32, 1), queue.cursorPosition());

    // An unmapped serial is ignored rather than moving the cursor anywhere.
    queue.observeRenderedSerial(999);
    try testing.expectEqual(@as(u32, 1), queue.cursorPosition());
}

test "stopping retains entries and cursor while clearing empties the queue" {
    var queue = PlaybackQueue.init(testing.allocator, 1);
    defer queue.deinit();
    const list = try makeRefs(testing.allocator, &.{ 10, 11, 12 });
    defer testing.allocator.free(list);
    try queue.replace(list, 2);
    try testing.expectEqual(@as(u32, 2), queue.cursorPosition());
    // `stop` is a transport operation: it releases decoders, never entries.
    try testing.expectEqual(@as(i64, 12), queue.current().?.track_id);
    queue.clear();
    try testing.expect(queue.isEmpty());
    try testing.expect(queue.current() == null);
}

fn trackIdsInOrder(queue: *const PlaybackQueue, out: []i64) []i64 {
    var position: u32 = 0;
    while (queue.refAt(position)) |ref| : (position += 1) out[position] = ref.track_id;
    return out[0..position];
}

test "play next lands after the committed entry and carries later positions along" {
    var queue = PlaybackQueue.init(testing.allocator, 1);
    defer queue.deinit();
    const refs = try makeRefs(testing.allocator, &.{ 1, 2, 3, 4 });
    defer testing.allocator.free(refs);
    try queue.replace(refs, 1);
    queue.noteEntrySerial(7, 3);
    var pending: u32 = 2;
    const next = try makeRefs(testing.allocator, &.{ 10, 11 });
    defer testing.allocator.free(next);
    try queue.insertAfter(1, next, &pending);

    var buffer: [8]i64 = undefined;
    try testing.expectEqualSlices(i64, &.{ 1, 2, 10, 11, 3, 4 }, trackIdsInOrder(&queue, &buffer));
    try testing.expectEqual(@as(u32, 1), queue.cursorPosition());
    try testing.expectEqual(@as(u32, 4), pending);
    try testing.expectEqual(@as(?u32, 5), queue.positionForSerial(7));
}

test "under shuffle, play next and remove edit the order without moving what plays" {
    var queue = PlaybackQueue.init(testing.allocator, 42);
    defer queue.deinit();
    const refs = try makeRefs(testing.allocator, &.{ 1, 2, 3, 4, 5 });
    defer testing.allocator.free(refs);
    try queue.replace(refs, 0);
    try queue.setShuffle(true);
    const playing = queue.current().?.track_id;
    const cursor = queue.cursorPosition();
    const next = try makeRefs(testing.allocator, &.{99});
    defer testing.allocator.free(next);
    try queue.insertAfter(cursor, next, null);
    try testing.expectEqual(playing, queue.current().?.track_id);
    try testing.expectEqual(@as(i64, 99), queue.refAt(cursor + 1).?.track_id);

    const removed = queue.refAt(cursor + 2).?.track_id;
    try queue.removeAt(cursor + 2, null);
    try testing.expectEqual(@as(u32, 5), queue.len());
    try testing.expectEqual(playing, queue.current().?.track_id);
    var buffer: [8]i64 = undefined;
    const ids = trackIdsInOrder(&queue, &buffer);
    try testing.expectEqual(@as(usize, 5), ids.len);
    for (ids) |id| try testing.expect(id != removed);
    var seen: [6]bool = @splat(false);
    for (ids) |id| {
        const slot: usize = if (id == 99) 0 else @intCast(id);
        try testing.expect(!seen[slot]);
        seen[slot] = true;
    }
}

test "removing an entry before the cursor keeps the cursor on the same track" {
    var queue = PlaybackQueue.init(testing.allocator, 1);
    defer queue.deinit();
    const refs = try makeRefs(testing.allocator, &.{ 1, 2, 3 });
    defer testing.allocator.free(refs);
    try queue.replace(refs, 2);
    try queue.removeAt(0, null);
    try testing.expectEqual(@as(u32, 1), queue.cursorPosition());
    try testing.expectEqual(@as(i64, 3), queue.current().?.track_id);
}

test "removing an entry forgets its serial rather than naming the entry that takes its place" {
    var queue = PlaybackQueue.init(testing.allocator, 1);
    defer queue.deinit();
    const refs = try makeRefs(testing.allocator, &.{ 1, 2, 3 });
    defer testing.allocator.free(refs);
    try queue.replace(refs, 2);
    queue.noteEntrySerial(7, 0);
    queue.noteEntrySerial(8, 2);
    try queue.removeAt(0, null);
    try testing.expectEqual(@as(?u32, null), queue.positionForSerial(7));
    try testing.expectEqual(@as(?u32, 1), queue.positionForSerial(8));
}

fn movedIds(before: []const i64, from: u32, to: u32, out: []i64) []i64 {
    var list: std.ArrayList(i64) = .initBuffer(out);
    list.appendSliceAssumeCapacity(before);
    const moved = list.orderedRemove(from);
    list.insertAssumeCapacity(to, moved);
    return list.items;
}

test "moving an upcoming entry earlier and later keeps the cursor, decode position and every serial naming the same entries" {
    for ([_]bool{ false, true }) |shuffled| {
        var queue = PlaybackQueue.init(testing.allocator, 0xbeef);
        defer queue.deinit();
        const refs = try makeRefs(testing.allocator, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
        defer testing.allocator.free(refs);
        try queue.replace(refs, 2);
        if (shuffled) try queue.setShuffle(true);
        const serials = [_]u32{ 11, 12, 13, 15, 17 };
        const serial_positions = [_]u32{ 1, 2, 3, 5, 7 };
        for (serials, serial_positions) |serial, position| queue.noteEntrySerial(serial, position);
        queue.advanceDecodeTo(3);
        var pending: u32 = 4;

        var serial_tracks: [serials.len]i64 = undefined;
        for (serials, &serial_tracks) |serial, *track|
            track.* = queue.refAt(queue.positionForSerial(serial).?).?.track_id;
        const playing = queue.current().?.track_id;
        const decoding = queue.refAt(queue.decodePosition()).?.track_id;
        const lined_up = queue.refAt(pending).?.track_id;

        for ([_][2]u32{ .{ 7, 5 }, .{ 5, 7 }, .{ 6, 4 } }) |step| {
            var before_buffer: [8]i64 = undefined;
            var expected_buffer: [8]i64 = undefined;
            var after_buffer: [8]i64 = undefined;
            const before = trackIdsInOrder(&queue, &before_buffer);
            const expected = movedIds(before, step[0], step[1], &expected_buffer);
            try queue.move(step[0], step[1], &pending);
            try testing.expectEqualSlices(i64, expected, trackIdsInOrder(&queue, &after_buffer));
            try testing.expectEqual(playing, queue.current().?.track_id);
            try testing.expectEqual(decoding, queue.refAt(queue.decodePosition()).?.track_id);
            try testing.expectEqual(lined_up, queue.refAt(pending).?.track_id);
            for (serials, serial_tracks) |serial, track|
                try testing.expectEqual(track, queue.refAt(queue.positionForSerial(serial).?).?.track_id);
        }
        try testing.expectEqual(@as(u32, 2), queue.cursorPosition());
        try testing.expectEqual(@as(u32, 3), queue.decodePosition());
        try testing.expectEqual(@as(u32, 5), pending);

        if (shuffled) {
            try queue.setShuffle(false);
            var buffer: [8]i64 = undefined;
            try testing.expectEqualSlices(i64, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, trackIdsInOrder(&queue, &buffer));
            try testing.expectEqual(playing, queue.current().?.track_id);
        }
    }
}

test "moving into the played region shifts the cursor with the playing entry" {
    var queue = PlaybackQueue.init(testing.allocator, 1);
    defer queue.deinit();
    const refs = try makeRefs(testing.allocator, &.{ 1, 2, 3, 4, 5, 6 });
    defer testing.allocator.free(refs);
    try queue.replace(refs, 3);
    queue.noteEntrySerial(20, 3);
    queue.advanceDecodeTo(4);
    queue.noteEntrySerial(21, 4);

    try queue.move(5, 1, null);
    var buffer: [8]i64 = undefined;
    try testing.expectEqualSlices(i64, &.{ 1, 6, 2, 3, 4, 5 }, trackIdsInOrder(&queue, &buffer));
    try testing.expectEqual(@as(u32, 4), queue.cursorPosition());
    try testing.expectEqual(@as(i64, 4), queue.current().?.track_id);
    try testing.expectEqual(@as(i64, 5), queue.refAt(queue.decodePosition()).?.track_id);
    try testing.expectEqual(@as(?u32, 4), queue.positionForSerial(20));
    try testing.expectEqual(@as(?u32, 5), queue.positionForSerial(21));

    try queue.move(0, 5, null);
    try testing.expectEqualSlices(i64, &.{ 6, 2, 3, 4, 5, 1 }, trackIdsInOrder(&queue, &buffer));
    try testing.expectEqual(@as(u32, 3), queue.cursorPosition());
    try testing.expectEqual(@as(i64, 4), queue.current().?.track_id);
    try testing.expectEqual(@as(?u32, 3), queue.positionForSerial(20));
    try testing.expectEqual(@as(?u32, 4), queue.positionForSerial(21));
    try testing.expectError(error.PositionOutOfRange, queue.move(6, 0, null));
    try testing.expectError(error.PositionOutOfRange, queue.move(0, 6, null));
}

test "restoring a saved shuffled queue keeps its order and cursor and turning shuffle off returns to list order" {
    var queue = PlaybackQueue.init(testing.allocator, 1);
    defer queue.deinit();
    const list = try makeRefs(testing.allocator, &.{ 1, 2, 3, 4 });
    defer testing.allocator.free(list);
    try queue.enqueue(list);
    queue.noteEntrySerial(9, 0);

    try queue.restore(list, &.{ 2, 0, 3, 1 }, 2);
    var buffer: [8]i64 = undefined;
    try testing.expectEqualSlices(i64, &.{ 3, 1, 4, 2 }, trackIdsInOrder(&queue, &buffer));
    try testing.expect(queue.shuffle);
    try testing.expectEqual(@as(u32, 2), queue.cursorPosition());
    try testing.expectEqual(@as(u32, 2), queue.decodePosition());
    try testing.expectEqual(@as(i64, 4), queue.current().?.track_id);
    try testing.expectEqual(@as(?u32, null), queue.positionForSerial(9));

    try queue.setShuffle(false);
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3, 4 }, trackIdsInOrder(&queue, &buffer));
    try testing.expectEqual(@as(i64, 4), queue.current().?.track_id);

    try queue.restore(list[0..2], null, 1);
    try testing.expect(!queue.shuffle);
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, trackIdsInOrder(&queue, &buffer));
    try testing.expectEqual(@as(i64, 2), queue.current().?.track_id);
}

test "restoring refuses an order that is no permutation and a cursor past the end, leaving the queue as it was" {
    var queue = PlaybackQueue.init(testing.allocator, 1);
    defer queue.deinit();
    const list = try makeRefs(testing.allocator, &.{ 1, 2, 3 });
    defer testing.allocator.free(list);
    try queue.restore(list, null, 1);

    try testing.expectError(error.InvalidQueueOrder, queue.restore(list, &.{ 0, 0, 1 }, 0));
    try testing.expectError(error.InvalidQueueOrder, queue.restore(list, &.{ 0, 1, 3 }, 0));
    try testing.expectError(error.InvalidQueueOrder, queue.restore(list, &.{ 0, 1 }, 0));
    try testing.expectError(error.PositionOutOfRange, queue.restore(list, null, 3));
    var buffer: [8]i64 = undefined;
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, trackIdsInOrder(&queue, &buffer));
    try testing.expectEqual(@as(i64, 2), queue.current().?.track_id);
}

test "an entry keeps its id across inserts, moves, removals and shuffle, and ids are never reused" {
    var queue = PlaybackQueue.init(testing.allocator, 42);
    defer queue.deinit();
    const refs = try makeRefs(testing.allocator, &.{ 1, 2, 3, 4 });
    defer testing.allocator.free(refs);
    try queue.replace(refs, 0);
    const third = queue.idAt(2).?;
    try testing.expectEqual(@as(?u32, 2), queue.positionOfId(third));

    const next = try makeRefs(testing.allocator, &.{10});
    defer testing.allocator.free(next);
    try queue.insertAfter(0, next, null);
    try testing.expectEqual(@as(?u32, 3), queue.positionOfId(third));
    try queue.move(3, 1, null);
    try testing.expectEqual(@as(?u32, 1), queue.positionOfId(third));
    try testing.expectEqual(@as(i64, 3), queue.refAt(1).?.track_id);

    const removed = queue.idAt(4).?;
    try queue.removeAt(4, null);
    try testing.expectEqual(@as(?u32, null), queue.positionOfId(removed));
    try queue.enqueue(next);
    try testing.expect(queue.idAt(queue.len() - 1).? > removed);

    try queue.setShuffle(true);
    const shuffled = queue.positionOfId(third).?;
    try testing.expectEqual(@as(i64, 3), queue.refAt(shuffled).?.track_id);
    try queue.setShuffle(false);
    try testing.expectEqual(@as(i64, 3), queue.refAt(queue.positionOfId(third).?).?.track_id);

    queue.clear();
    try testing.expectEqual(@as(?u32, null), queue.positionOfId(third));
    try queue.enqueue(refs);
    for (0..4) |position| try testing.expect(queue.idAt(@intCast(position)).? > removed);
}
