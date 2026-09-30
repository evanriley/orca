//! Cover art, found and read off the caller's thread.
//!
//! A host showing a grid of albums asks for dozens of covers at once, and each
//! is at least one indexed query and one file read. `Loader` does that work on
//! its own thread: requests arrive over one bounded SPSC queue and results
//! leave over another, which the host drains on its own tick. Threading follows
//! `JobWorker`: the loader touches only itself and the Library database it was
//! handed, and the control lane drains it before that database can close.

const std = @import("std");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/root.zig");
const storage = @import("../storage/root.zig");
const spsc = @import("../audio/spsc.zig");
const work = @import("work.zig");

pub const Subject = union(enum) {
    track: i64,
    release: i64,
};

/// One finished request. `image` is null when the subject has no readable
/// cover. The caller owns `image` and releases it with its `deinit`.
pub const Result = struct {
    request: u64,
    subject: Subject,
    image: ?metadata.EmbeddedImage,
};

/// Requests a Loader holds at once, queued, in progress and unclaimed
/// together. A grid shows a few dozen covers, so this is several screens.
pub const capacity = 64;

/// How many of a Release's Tracks are opened before it is reported as having
/// no usable cover.
///
/// Only files the last scan observed artwork in are candidates at all, so this
/// bound is reached only when a Release's leading tracks each declare a cover
/// that no longer reads — a re-tagged file, a rejected image. Eight is generous
/// for that and still bounded; without a bound, one Release with a hundred
/// broken tracks would open a hundred files to answer "no".
pub const max_release_candidates: usize = 8;

/// Ids of cancelled requests, by id modulo the table size. Larger than
/// `capacity`, so no two outstanding ids share a slot.
const cancel_slots = capacity * 4;

const Request = struct {
    id: u64,
    subject: Subject,
};

pub const Loader = struct {
    allocator: std.mem.Allocator,
    /// Borrowed. The control lane drains this loader before the database closes.
    database: *database.LibraryDatabase,
    registration: *work.Registration,
    threaded: std.Io.Threaded = .init_single_threaded,
    requests: spsc.Queue(Request, capacity) = .{},
    results: spsc.Queue(Result, capacity) = .{},
    /// Requests accepted and not yet taken or skipped. Bounds both queues.
    outstanding: std.atomic.Value(u32) = .init(0),
    /// Bumped on every request; the loader sleeps on it.
    signal: std.atomic.Value(u32) = .init(0),
    cancelled: [cancel_slots]std.atomic.Value(u64) = @splat(.init(0)),
    next_id: u64 = 1,

    /// Control lane. Returns the request id, or `error.ArtworkQueueFull` when
    /// `capacity` requests are outstanding.
    pub fn request(self: *Loader, io: std.Io, subject: Subject) !u64 {
        if (self.outstanding.load(.acquire) >= capacity) return error.ArtworkQueueFull;
        const id = self.next_id;
        if (!self.requests.push(.{ .id = id, .subject = subject })) return error.ArtworkQueueFull;
        self.next_id += 1;
        _ = self.outstanding.fetchAdd(1, .acq_rel);
        self.wake(io);
        return id;
    }

    /// Control lane. A request not yet started is skipped without reading a
    /// file; one already finished still arrives and should be discarded.
    pub fn cancel(self: *Loader, id: u64) void {
        self.cancelled[id % cancel_slots].store(id, .release);
    }

    /// Control lane. The next finished request, if any.
    pub fn take(self: *Loader) ?Result {
        const result = self.results.pop() orelse return null;
        _ = self.outstanding.fetchSub(1, .acq_rel);
        return result;
    }

    pub fn wake(self: *Loader, io: std.Io) void {
        _ = self.signal.fetchAdd(1, .release);
        io.futexWake(u32, &self.signal.raw, 1);
    }

    pub fn waker(self: *Loader) work.Waker {
        return .{ .context = self, .wake_fn = wakeFromWaker };
    }

    fn wakeFromWaker(context: *anyopaque) callconv(.c) void {
        const self: *Loader = @ptrCast(@alignCast(context));
        self.wake(self.threaded.io());
    }

    /// Control lane, after the loader has been joined: frees results nobody
    /// took.
    pub fn discardResults(self: *Loader) void {
        while (self.results.pop()) |result| {
            if (result.image) |image| image.deinit();
        }
    }

    /// Control lane, after the loader has been joined.
    pub fn deinit(self: *Loader) void {
        self.discardResults();
        self.threaded.deinit();
    }

    fn isCancelled(self: *const Loader, id: u64) bool {
        return self.cancelled[id % cancel_slots].load(.acquire) == id;
    }

    /// Sleeps until a request or cancellation wakes it, so the registration
    /// must carry `waker()`.
    pub fn run(self: *Loader) void {
        defer self.registration.finish();
        const io = self.threaded.io();
        while (true) {
            // Read before the cancellation check and the queue, so a wake that
            // lands after them makes the wait below return at once.
            const seen = self.signal.load(.acquire);
            if (self.registration.cancellationRequested()) return;
            if (self.step(io)) continue;
            io.futexWait(u32, &self.signal.raw, seen) catch {};
        }
    }

    /// Handles one request. Returns false when there was none.
    fn step(self: *Loader, io: std.Io) bool {
        const next = self.requests.pop() orelse return false;
        if (self.isCancelled(next.id)) {
            _ = self.outstanding.fetchSub(1, .acq_rel);
            return true;
        }
        const image = switch (next.subject) {
            .track => |id| trackArtwork(self.allocator, io, self.database, id),
            .release => |id| releaseArtwork(self.allocator, io, self.database, id),
        } catch null;
        // Cannot fail: `outstanding` never exceeds the results' capacity.
        if (!self.results.push(.{ .request = next.id, .subject = next.subject, .image = image })) {
            if (image) |present| present.deinit();
            _ = self.outstanding.fetchSub(1, .acq_rel);
        }
        return true;
    }
};

fn readEmbedded(allocator: std.mem.Allocator, io: std.Io, uri: []const u8) !?metadata.EmbeddedImage {
    var local = storage.LocalFileSource.open(io, uri) catch |err| switch (err) {
        error.FileNotFound, error.BadPathName, error.AccessDenied, error.IsDir => return null,
        else => return err,
    };
    defer local.close();
    return metadata.artwork.read(allocator, local.readable());
}

pub fn trackArtwork(
    allocator: std.mem.Allocator,
    io: std.Io,
    library_database: *database.LibraryDatabase,
    track_id: i64,
) !?metadata.EmbeddedImage {
    const resolved = (try library_database.tracks.playableLocation(allocator, track_id)) orelse
        return null;
    defer resolved.deinit();
    return readEmbedded(allocator, io, resolved.uri);
}

/// **A Release's artwork is its first track's, in listening order.** Real tag
/// data disagrees within an album — different sizes, different crops,
/// per-track covers on compilations — so the rule has to pick, and the three
/// properties that matter are that it be *stable* across runs, *cheap*, and
/// *the one a person would expect*. Ordering by disc, track number and then id
/// is the unique order `tracks_position` already enforces, so the same Release
/// yields the same cover every time; it costs one indexed query plus one file
/// open; and the front cover on track one is the album cover in every
/// collection anyone actually has.
///
/// The alternatives were rejected for failing one of those: a majority vote
/// would have to read every file in the Release, and "the largest image" would
/// too, and both change their answer when one track is re-tagged.
pub fn releaseArtwork(
    allocator: std.mem.Allocator,
    io: std.Io,
    library_database: *database.LibraryDatabase,
    release_id: i64,
) !?metadata.EmbeddedImage {
    var candidates: [max_release_candidates]i64 = undefined;
    const count = try library_database.tracks.artworkCandidatesInto(release_id, &candidates);
    for (candidates[0..count]) |track_id| {
        // A candidate whose cover will not read is skipped rather than fatal:
        // the next track's cover is the same album's.
        const image = trackArtwork(allocator, io, library_database, track_id) catch continue;
        if (image) |present| return present;
    }
    return null;
}

test "a cancelled request is skipped and the rest arrive in order" {
    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-artwork-loader-step?mode=memory&cache=shared",
    );
    defer library.close();
    var registration: work.Registration = .{};
    var loader: Loader = .{
        .allocator = std.testing.allocator,
        .database = &library,
        .registration = &registration,
    };
    const first = try loader.request(std.testing.io, .{ .release = 1 });
    const second = try loader.request(std.testing.io, .{ .track = 2 });
    const third = try loader.request(std.testing.io, .{ .release = 3 });
    loader.cancel(second);
    while (loader.step(std.testing.io)) {}

    const a = loader.take().?;
    const b = loader.take().?;
    try std.testing.expect(loader.take() == null);
    try std.testing.expectEqual(first, a.request);
    try std.testing.expectEqual(third, b.request);
    try std.testing.expect(a.image == null and b.image == null);
    try std.testing.expectEqual(@as(u32, 0), loader.outstanding.load(.acquire));
}

test "requests beyond capacity are refused until results are taken" {
    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-artwork-loader-full?mode=memory&cache=shared",
    );
    defer library.close();
    var registration: work.Registration = .{};
    var loader: Loader = .{
        .allocator = std.testing.allocator,
        .database = &library,
        .registration = &registration,
    };
    for (0..capacity) |_| _ = try loader.request(std.testing.io, .{ .release = 1 });
    try std.testing.expectError(error.ArtworkQueueFull, loader.request(std.testing.io, .{ .release = 1 }));
    while (loader.step(std.testing.io)) {}
    try std.testing.expectError(error.ArtworkQueueFull, loader.request(std.testing.io, .{ .release = 1 }));
    _ = loader.take().?;
    _ = try loader.request(std.testing.io, .{ .release = 1 });
    loader.discardResults();
}

test "cancellation wakes a parked loader" {
    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-artwork-loader-park?mode=memory&cache=shared",
    );
    defer library.close();
    var registration: work.Registration = .{};
    var loader: Loader = .{
        .allocator = std.testing.allocator,
        .database = &library,
        .registration = &registration,
    };
    defer loader.deinit();
    registration.waker = loader.waker();
    registration.thread = try std.Thread.spawn(.{}, Loader.run, .{&loader});
    errdefer {
        registration.requestCancellation();
        registration.awaitCompletion();
    }

    const id = try loader.request(std.testing.io, .{ .release = 1 });
    const result = for (0..5_000) |_| {
        if (loader.take()) |value| break value;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.RequestNeverFinished;
    try std.testing.expectEqual(id, result.request);

    registration.requestCancellation();
    registration.awaitCompletion();
    try std.testing.expect(registration.isFinished());
}
