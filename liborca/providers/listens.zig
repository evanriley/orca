//! Turns a Player's status, sampled over time, into listens: how long each
//! queue entry was actually heard, and when it became long enough to count.

const std = @import("std");
const scrobble = @import("scrobble.zig");

/// How far position may run ahead of the awake clock between two samples and
/// still be audio that was heard, rather than a jump.
const position_slack_ms: u64 = 500;

pub const now_playing_after_ms: u64 = 10_000;

pub const Sample = struct {
    /// The audible entry's serial; zero when nothing is loaded.
    entry_serial: u32,
    track_id: ?i64,
    epoch: u32,
    playing: bool,
    drained: bool,
    position_ms: u64,
    duration_ms: u64,
    /// Awake clock.
    mono_ms: i64,
    /// Wall clock, in Unix seconds.
    wall_s: i64,
};

pub const Listen = struct {
    track_id: i64,
    /// Unix seconds at which the entry's first frame would have played.
    started_at: i64,
    listened_ms: u64,
    duration_ms: u64,
};

pub const Emission = union(enum) {
    none,
    started: Listen,
    /// The listen has just become long enough to count. Once per entry play.
    eligible: Listen,
    /// An eligible listen has ended; `listened_ms` is final.
    finished: Listen,
};

const OpenListen = struct {
    entry_serial: u32,
    listen: Listen,
    emitted: bool = false,
    started: bool = false,
};

pub const ListenTracker = struct {
    previous: ?Sample = null,
    open: ?OpenListen = null,
    /// Serials only grow, so remembering the last one opened is enough to open
    /// at most one listen per entry play.
    last_opened_serial: u32 = 0,

    pub fn observe(self: *ListenTracker, sample: Sample) Emission {
        defer self.previous = sample;
        var emission: Emission = .none;
        if (self.open) |open| {
            if (!sameEntry(open.entry_serial, open.listen.track_id, sample)) emission = self.end();
        }
        const previous = self.previous orelse return emission;
        if (self.open == null) self.tryOpen(previous, sample);
        const open = if (self.open) |*value| value else return emission;
        if (sample.duration_ms != 0) open.listen.duration_ms = sample.duration_ms;
        open.listen.listened_ms += audibleMs(previous, sample);
        if (!open.emitted and scrobble.listenedEnough(open.listen.duration_ms, open.listen.listened_ms)) {
            open.emitted = true;
            open.started = true;
            return .{ .eligible = open.listen };
        }
        if (sample.drained) return self.endPlayedOut();
        if (!open.started and open.listen.listened_ms >= now_playing_after_ms and
            open.listen.duration_ms >= scrobble.minimum_duration_ms)
        {
            open.started = true;
            return .{ .started = open.listen };
        }
        return emission;
    }

    /// Ends the listen in progress, reporting it as finished when it had
    /// already counted.
    pub fn end(self: *ListenTracker) Emission {
        const open = self.open orelse return .none;
        self.open = null;
        return if (open.emitted) .{ .finished = open.listen } else .none;
    }

    fn endPlayedOut(self: *ListenTracker) Emission {
        self.last_opened_serial = 0;
        return self.end();
    }

    /// The engine publishes the queue cursor and the audible serial as two
    /// atomics, so one sample taken during a transition can pair the new
    /// track with the old serial. Only a pair seen twice in a row is trusted.
    fn tryOpen(self: *ListenTracker, previous: Sample, sample: Sample) void {
        const track_id = sample.track_id orelse return;
        if (sample.drained) return;
        if (sample.entry_serial == 0 or sample.entry_serial == self.last_opened_serial) return;
        if (!sameEntry(sample.entry_serial, track_id, previous)) return;
        const offset_s: i64 = @intCast(sample.position_ms / 1000);
        self.open = .{
            .entry_serial = sample.entry_serial,
            .listen = .{
                .track_id = track_id,
                .started_at = sample.wall_s - offset_s,
                .listened_ms = 0,
                .duration_ms = sample.duration_ms,
            },
        };
        self.last_opened_serial = sample.entry_serial;
    }
};

fn sameEntry(entry_serial: u32, track_id: i64, sample: Sample) bool {
    const sampled = sample.track_id orelse return false;
    return sample.entry_serial == entry_serial and sampled == track_id;
}

/// Audio heard between two samples. A seek or a stop bumps the epoch, so the
/// span it skipped is never counted, and a paused transport adds nothing.
fn audibleMs(previous: Sample, sample: Sample) u64 {
    if (!sample.playing) return 0;
    if (previous.entry_serial != sample.entry_serial or previous.epoch != sample.epoch) return 0;
    if (sample.position_ms < previous.position_ms) return 0;
    const advanced = sample.position_ms - previous.position_ms;
    const elapsed: u64 = @intCast(@max(sample.mono_ms - previous.mono_ms, 0));
    return if (advanced <= elapsed + position_slack_ms) advanced else 0;
}

const testing = std.testing;

/// One Player's transport, played forward in simulated time.
const Transport = struct {
    tracker: ListenTracker = .{},
    entry_serial: u32 = 1,
    track_id: ?i64 = 10,
    epoch: u32 = 1,
    playing: bool = true,
    drained: bool = false,
    position_ms: u64 = 0,
    duration_ms: u64 = 180_000,
    mono_ms: i64 = 0,
    wall_s: i64 = 1_700_000_000,
    started: std.ArrayList(Listen) = .empty,
    eligible: std.ArrayList(Listen) = .empty,
    finished: std.ArrayList(Listen) = .empty,

    fn deinit(self: *Transport) void {
        self.started.deinit(testing.allocator);
        self.eligible.deinit(testing.allocator);
        self.finished.deinit(testing.allocator);
    }

    fn sample(self: *const Transport) Sample {
        return .{
            .entry_serial = self.entry_serial,
            .track_id = self.track_id,
            .epoch = self.epoch,
            .playing = self.playing,
            .drained = self.drained,
            .position_ms = self.position_ms,
            .duration_ms = self.duration_ms,
            .mono_ms = self.mono_ms,
            .wall_s = self.wall_s,
        };
    }

    fn observe(self: *Transport, value: Sample) !void {
        switch (self.tracker.observe(value)) {
            .none => {},
            .started => |listen| try self.started.append(testing.allocator, listen),
            .eligible => |listen| try self.eligible.append(testing.allocator, listen),
            .finished => |listen| try self.finished.append(testing.allocator, listen),
        }
    }

    /// Advances time by `milliseconds` in 100 ms samples.
    fn run(self: *Transport, milliseconds: u64) !void {
        var remaining = milliseconds;
        while (remaining > 0) {
            const step = @min(remaining, 100);
            self.advance(step);
            try self.observe(self.sample());
            remaining -= step;
        }
    }

    fn advance(self: *Transport, milliseconds: u64) void {
        const before_s = @divFloor(self.mono_ms, 1000);
        self.mono_ms += @intCast(milliseconds);
        self.wall_s += @divFloor(self.mono_ms, 1000) - before_s;
        if (self.playing) self.position_ms = @min(self.position_ms + milliseconds, self.duration_ms);
    }

    fn seek(self: *Transport, position_ms: u64) void {
        self.position_ms = position_ms;
        self.epoch += 1;
    }

    /// The next queue entry, gapless: a new serial and track, position zero.
    fn advanceEntry(self: *Transport, track_id: i64) void {
        self.entry_serial += 1;
        self.track_id = track_id;
        self.position_ms = 0;
    }
};

test "seeking from 0:10 to 2:50 of a three-minute track is not a listen" {
    var transport: Transport = .{};
    defer transport.deinit();
    try transport.run(10_000);
    transport.seek(170_000);
    try transport.run(10_000);
    transport.advanceEntry(11);
    try transport.run(1_000);
    try testing.expectEqual(@as(usize, 0), transport.eligible.items.len);
    try testing.expectEqual(@as(usize, 0), transport.finished.items.len);
}

test "a long pause adds nothing and the listen keeps its original start" {
    var transport: Transport = .{};
    defer transport.deinit();
    try transport.run(60_000);
    transport.playing = false;
    try transport.run(600_000);
    transport.playing = true;
    try transport.run(35_000);
    try testing.expectEqual(@as(usize, 1), transport.eligible.items.len);
    const listen = transport.eligible.items[0];
    try testing.expectEqual(@as(i64, 10), listen.track_id);
    try testing.expectEqual(@as(i64, 1_700_000_000), listen.started_at);
    try testing.expectEqual(@as(u64, 90_000), listen.listened_ms);
    try testing.expectEqual(@as(u64, 180_000), listen.duration_ms);
}

test "a 25-second track is never eligible, however often it is heard" {
    var transport: Transport = .{ .duration_ms = 25_000 };
    defer transport.deinit();
    try transport.run(25_000);
    transport.seek(0);
    try transport.run(25_000);
    try testing.expectEqual(@as(usize, 0), transport.eligible.items.len);
}

test "an eight-minute track becomes eligible after four minutes, not half its length" {
    var transport: Transport = .{ .duration_ms = 480_000 };
    defer transport.deinit();
    try transport.run(240_000);
    try testing.expectEqual(@as(usize, 0), transport.eligible.items.len);
    try transport.run(100);
    try testing.expectEqual(@as(usize, 1), transport.eligible.items.len);
    try testing.expectEqual(@as(u64, 240_000), transport.eligible.items[0].listened_ms);
}

test "one track played twice under repeat-one is two listens" {
    var transport: Transport = .{ .duration_ms = 60_000 };
    defer transport.deinit();
    try transport.run(60_000);
    transport.advanceEntry(10);
    try transport.run(60_000);
    transport.advanceEntry(11);
    try transport.run(200);
    try testing.expectEqual(@as(usize, 2), transport.eligible.items.len);
    try testing.expectEqual(@as(usize, 2), transport.finished.items.len);
    try testing.expectEqual(@as(i64, 10), transport.eligible.items[1].track_id);
    try testing.expect(transport.eligible.items[1].started_at > transport.eligible.items[0].started_at);
}

test "a transition sample pairing one entry's track with the other's serial is attributed to neither" {
    const Pairing = enum { new_track_old_serial, old_track_new_serial };
    for ([_]Pairing{ .new_track_old_serial, .old_track_new_serial }) |pairing| {
        var transport: Transport = .{ .duration_ms = 60_000 };
        defer transport.deinit();
        try transport.run(59_900);
        try testing.expectEqual(@as(usize, 1), transport.eligible.items.len);

        transport.advance(100);
        var torn = transport.sample();
        switch (pairing) {
            .new_track_old_serial => torn.track_id = 20,
            .old_track_new_serial => torn.entry_serial += 1,
        }
        try transport.observe(torn);
        transport.advanceEntry(20);
        try transport.run(60_000);

        try testing.expectEqual(@as(usize, 2), transport.eligible.items.len);
        try testing.expectEqual(@as(i64, 20), transport.eligible.items[1].track_id);
        try testing.expectEqual(@as(usize, 1), transport.finished.items.len);
        try testing.expectEqual(@as(i64, 10), transport.finished.items[0].track_id);
    }
}

test "audio heard while the sampler stalled still counts" {
    var transport: Transport = .{};
    defer transport.deinit();
    try transport.run(1_000);
    transport.advance(95_000);
    try transport.observe(transport.sample());
    try testing.expectEqual(@as(usize, 1), transport.eligible.items.len);
    try testing.expectEqual(@as(u64, 95_900), transport.eligible.items[0].listened_ms);
}

test "position running far ahead of the clock without a new epoch is not counted" {
    var transport: Transport = .{};
    defer transport.deinit();
    try transport.run(1_000);
    transport.position_ms += 120_000;
    try transport.run(1_000);
    try testing.expectEqual(@as(usize, 0), transport.eligible.items.len);
}

test "a finished listen carries the time heard until it ended" {
    var transport: Transport = .{};
    defer transport.deinit();
    try transport.run(150_000);
    transport.entry_serial = 0;
    transport.track_id = null;
    try transport.run(200);
    try testing.expectEqual(@as(usize, 1), transport.eligible.items.len);
    try testing.expectEqual(@as(u64, 90_000), transport.eligible.items[0].listened_ms);
    try testing.expectEqual(@as(usize, 1), transport.finished.items.len);
    const finished = transport.finished.items[0];
    try testing.expectEqual(@as(u64, 149_900), finished.listened_ms);
    try testing.expectEqual(transport.eligible.items[0].started_at, finished.started_at);
}

test "a listen that never counted ends without a finished emission" {
    var transport: Transport = .{};
    defer transport.deinit();
    try transport.run(30_000);
    transport.advanceEntry(11);
    try transport.run(1_000);
    try testing.expectEqual(@as(usize, 0), transport.finished.items.len);
    try testing.expectEqual(Emission.none, transport.tracker.end());
}

test "an entry with no track or no serial is never a listen" {
    const Missing = enum { no_track, no_serial };
    for ([_]Missing{ .no_track, .no_serial }) |missing| {
        var transport: Transport = .{};
        defer transport.deinit();
        switch (missing) {
            .no_track => transport.track_id = null,
            .no_serial => transport.entry_serial = 0,
        }
        try transport.run(180_000);
        try testing.expectEqual(@as(usize, 0), transport.eligible.items.len);
    }
}

test "a listen starts where its first frame would have played" {
    var transport: Transport = .{ .position_ms = 42_300 };
    defer transport.deinit();
    try transport.run(120_000);
    try testing.expectEqual(@as(i64, 1_700_000_000 - 42), transport.eligible.items[0].started_at);
}

test "a track that plays out with nothing after it finishes its listen with the whole time heard" {
    var transport: Transport = .{ .duration_ms = 60_000 };
    defer transport.deinit();
    try transport.run(60_000);
    try testing.expectEqual(@as(usize, 1), transport.eligible.items.len);
    try testing.expectEqual(@as(usize, 0), transport.finished.items.len);

    transport.drained = true;
    try transport.run(5_000);
    try testing.expectEqual(@as(usize, 1), transport.eligible.items.len);
    try testing.expectEqual(@as(usize, 1), transport.finished.items.len);
    try testing.expectEqual(@as(u64, 59_900), transport.finished.items[0].listened_ms);
    try testing.expectEqual(transport.eligible.items[0].started_at, transport.finished.items[0].started_at);
}

test "a listen that becomes eligible on the sample that drained finishes on the next" {
    var transport: Transport = .{ .duration_ms = 60_000 };
    defer transport.deinit();
    try transport.run(30_000);
    try testing.expectEqual(@as(usize, 0), transport.eligible.items.len);
    transport.drained = true;
    try transport.run(100);
    try testing.expectEqual(@as(usize, 1), transport.eligible.items.len);
    try testing.expectEqual(@as(usize, 0), transport.finished.items.len);
    try transport.run(100);
    try testing.expectEqual(@as(usize, 1), transport.finished.items.len);
}

test "playing a drained track again is a second listen" {
    var transport: Transport = .{ .duration_ms = 60_000 };
    defer transport.deinit();
    try transport.run(60_000);
    transport.drained = true;
    try transport.run(1_000);
    transport.drained = false;
    transport.seek(0);
    try transport.run(60_000);
    try testing.expectEqual(@as(usize, 2), transport.eligible.items.len);
    try testing.expect(transport.eligible.items[1].started_at > transport.eligible.items[0].started_at);
    transport.drained = true;
    try transport.run(200);
    try testing.expectEqual(@as(usize, 2), transport.finished.items.len);
}

test "a drained sample opens no listen" {
    var transport: Transport = .{ .drained = true };
    defer transport.deinit();
    try transport.run(180_000);
    try testing.expectEqual(@as(usize, 0), transport.eligible.items.len);
}

test "a track is playing now once it has been heard for ten seconds" {
    var transport: Transport = .{};
    defer transport.deinit();
    try transport.run(10_000);
    try testing.expectEqual(@as(usize, 0), transport.started.items.len);
    try transport.run(100);
    try testing.expectEqual(@as(usize, 1), transport.started.items.len);
    const started = transport.started.items[0];
    try testing.expectEqual(@as(i64, 10), started.track_id);
    try testing.expectEqual(@as(u64, 180_000), started.duration_ms);
    try testing.expectEqual(@as(u64, 10_000), started.listened_ms);
}

test "playing now is announced once per play, however long the track is heard" {
    var transport: Transport = .{ .duration_ms = 60_000 };
    defer transport.deinit();
    try transport.run(60_000);
    try testing.expectEqual(@as(usize, 1), transport.started.items.len);
    transport.advanceEntry(10);
    try transport.run(60_000);
    try testing.expectEqual(@as(usize, 2), transport.started.items.len);
}

test "a track under 30 seconds is never playing now" {
    var transport: Transport = .{ .duration_ms = 25_000 };
    defer transport.deinit();
    try transport.run(25_000);
    try testing.expectEqual(@as(usize, 0), transport.started.items.len);
    transport.duration_ms = 30_000;
    transport.advanceEntry(11);
    try transport.run(15_000);
    try testing.expectEqual(@as(usize, 1), transport.started.items.len);
}

test "an entry skipped after five seconds is never playing now" {
    var transport: Transport = .{};
    defer transport.deinit();
    try transport.run(5_000);
    transport.advanceEntry(11);
    try transport.run(5_000);
    transport.advanceEntry(12);
    try transport.run(9_000);
    try testing.expectEqual(@as(usize, 0), transport.started.items.len);
}

test "seconds skipped by a seek do not bring playing now sooner" {
    var transport: Transport = .{};
    defer transport.deinit();
    try transport.run(5_000);
    transport.seek(100_000);
    try transport.run(4_000);
    try testing.expectEqual(@as(usize, 0), transport.started.items.len);
    try transport.run(1_200);
    try testing.expectEqual(@as(usize, 1), transport.started.items.len);
}

test "a drained entry is never playing now" {
    var transport: Transport = .{};
    defer transport.deinit();
    try transport.run(9_900);
    transport.drained = true;
    try transport.run(1_000);
    try testing.expectEqual(@as(usize, 0), transport.started.items.len);
}

test "a paused track is not playing now" {
    var transport: Transport = .{};
    defer transport.deinit();
    try transport.run(5_000);
    transport.playing = false;
    try transport.run(60_000);
    try testing.expectEqual(@as(usize, 0), transport.started.items.len);
    transport.playing = true;
    try transport.run(5_100);
    try testing.expectEqual(@as(usize, 1), transport.started.items.len);
}

test "a listen that counts on the sample that would announce it is not announced as playing now" {
    var transport: Transport = .{};
    defer transport.deinit();
    try transport.run(1_000);
    transport.advance(95_000);
    try transport.observe(transport.sample());
    try testing.expectEqual(@as(usize, 0), transport.started.items.len);
    try testing.expectEqual(@as(usize, 1), transport.eligible.items.len);
    try transport.run(60_000);
    try testing.expectEqual(@as(usize, 0), transport.started.items.len);
}
