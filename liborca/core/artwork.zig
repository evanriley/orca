//! Cover art and artist photos, found and read off the caller's thread.
//!
//! A host showing a grid of albums asks for dozens of covers at once, and each
//! is at least one indexed query and one file read. `Loader` does that work on
//! its own thread: requests arrive over one bounded SPSC queue and results
//! leave over another, which the host drains on its own tick. Threading follows
//! `JobWorker`: the loader touches only itself and the Library database it was
//! handed, and the control lane drains it before that database can close.

const std = @import("std");
const control = @import("control.zig");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/root.zig");
const storage = @import("../storage/root.zig");
const spsc = @import("../audio/spsc.zig");
const work = @import("work.zig");

pub const Subject = union(enum) {
    track: i64,
    release: i64,
    artist: i64,
    /// A MusicBrainz release group ID, lowercase: the cover an artist info
    /// fetch kept for it.
    release_group: [36]u8,
};

/// One finished request. `image` is null when the subject has no readable
/// cover or stored photo. The caller owns `image` and releases it with its `deinit`.
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

/// How many of a folder's front cover images are opened before a Release is
/// reported as having none there. Ordinarily the first one reads.
pub const max_folder_images: u32 = 4;

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
    host_signal: ?*control.HostSignal = null,
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
            .artist => |id| self.database.artist_info.photo(self.allocator, id),
            .release_group => |*mbid| self.database.artist_info.releaseGroupCover(self.allocator, mbid),
        } catch null;
        // Cannot fail: `outstanding` never exceeds the results' capacity.
        if (!self.results.push(.{ .request = next.id, .subject = next.subject, .image = image })) {
            if (image) |present| present.deinit();
            _ = self.outstanding.fetchSub(1, .acq_rel);
            return true;
        }
        if (self.host_signal) |signal| signal.raise();
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

/// The cover embedded in a Track's file, else its Release's folder cover
/// image, else the one fetched for its Release.
pub fn trackArtwork(
    allocator: std.mem.Allocator,
    io: std.Io,
    library_database: *database.LibraryDatabase,
    track_id: i64,
) !?metadata.EmbeddedImage {
    if (try trackEmbeddedArtwork(allocator, io, library_database, track_id)) |image| return image;
    if (try trackFolderArtwork(allocator, io, library_database, track_id)) |image| return image;
    return library_database.release_artwork.imageForTrack(allocator, track_id);
}

fn trackEmbeddedArtwork(
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
///
/// A Release none of whose files carries a readable cover shows its folder's
/// front cover image (`releaseFolderArtwork`), else the one fetched for it
/// from the Cover Art Archive, if any.
pub fn releaseArtwork(
    allocator: std.mem.Allocator,
    io: std.Io,
    library_database: *database.LibraryDatabase,
    release_id: i64,
) !?metadata.EmbeddedImage {
    if (try releaseEmbeddedArtwork(allocator, io, library_database, release_id)) |image| return image;
    if (try releaseFolderArtwork(allocator, io, library_database, release_id)) |image| return image;
    return library_database.release_artwork.imageForRelease(allocator, release_id);
}

/// The first readable front cover image the last scan found in the folder
/// holding most of a Release's Tracks: see
/// `LocationRepository.releaseFrontImages` for the order. Like an embedded
/// cover it is read from the file on every call, so a replaced image is never
/// stale.
pub fn releaseFolderArtwork(
    allocator: std.mem.Allocator,
    io: std.Io,
    library_database: *database.LibraryDatabase,
    release_id: i64,
) !?metadata.EmbeddedImage {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const uris = try library_database.locations.releaseFrontImages(arena_state.allocator(), release_id, max_folder_images);
    return firstFolderImage(allocator, io, uris);
}

fn trackFolderArtwork(
    allocator: std.mem.Allocator,
    io: std.Io,
    library_database: *database.LibraryDatabase,
    track_id: i64,
) !?metadata.EmbeddedImage {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const uris = try library_database.locations.trackReleaseFrontImages(arena_state.allocator(), track_id, max_folder_images);
    return firstFolderImage(allocator, io, uris);
}

fn firstFolderImage(allocator: std.mem.Allocator, io: std.Io, uris: []const []const u8) !?metadata.EmbeddedImage {
    for (uris) |uri| if (try readFolderImage(allocator, io, uri)) |image| return image;
    return null;
}

/// Null when the file is gone, unreadable, larger than an embedded cover may
/// be, or no longer an image.
fn readFolderImage(allocator: std.mem.Allocator, io: std.Io, uri: []const u8) !?metadata.EmbeddedImage {
    var local = storage.LocalFileSource.open(io, uri) catch return null;
    defer local.close();
    const readable = local.readable();
    const size = readable.size();
    if (size == 0 or size > metadata.model.max_image_bytes) return null;
    const bytes = try allocator.alloc(u8, @intCast(size));
    const read = readable.readAt(0, bytes) catch 0;
    if (read != bytes.len) {
        allocator.free(bytes);
        return null;
    }
    return metadata.model.adoptImage(allocator, bytes, .front_cover) catch {
        allocator.free(bytes);
        return null;
    };
}

pub fn releaseEmbeddedArtwork(
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
        const image = trackEmbeddedArtwork(allocator, io, library_database, track_id) catch continue;
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

test "an artist request returns the stored photo, and no image when the artist has none" {
    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-artwork-loader-artist?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name) VALUES (1, 'Pictured', 'pictured'), (2, 'Unpictured', 'unpictured');
        \\INSERT INTO artist_info(artist_id, photo, fetched_at, outcome) VALUES
        \\    (1, x'89504E470D0A1A0A00000000', 10, 1), (2, NULL, 10, 1);
    );
    var registration: work.Registration = .{};
    var loader: Loader = .{
        .allocator = std.testing.allocator,
        .database = &library,
        .registration = &registration,
    };
    defer loader.deinit();
    const pictured = try loader.request(std.testing.io, .{ .artist = 1 });
    const unpictured = try loader.request(std.testing.io, .{ .artist = 2 });
    const unknown = try loader.request(std.testing.io, .{ .artist = 3 });
    while (loader.step(std.testing.io)) {}

    const photo = loader.take().?;
    defer if (photo.image) |image| image.deinit();
    try std.testing.expectEqual(pictured, photo.request);
    try std.testing.expectEqual(Subject{ .artist = 1 }, photo.subject);
    try std.testing.expectEqualStrings("image/png", photo.image.?.mime_type);
    const none = loader.take().?;
    try std.testing.expectEqual(unpictured, none.request);
    try std.testing.expect(none.image == null);
    const missing = loader.take().?;
    try std.testing.expectEqual(unknown, missing.request);
    try std.testing.expect(missing.image == null);
}

test "a release group request returns the cover kept for the group, and no image for a group without one" {
    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-artwork-loader-release-group?mode=memory&cache=shared",
    );
    defer library.close();
    const covered = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e01".*;
    const bare = "0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e02".*;
    try library.database.exec(
        \\INSERT INTO artists(id, name, sort_name) VALUES (1, 'Host', 'host');
        \\INSERT INTO artist_release_groups(artist_id, mbid, title, position) VALUES
        \\    (1, '0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e01', 'Covered', 0), (1, '0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e02', 'Bare', 1);
        \\INSERT INTO release_group_covers(mbid, image, mime, fetched_at) VALUES
        \\    ('0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e01', x'FFD8FFE000000000', 'image/jpeg', 10),
        \\    ('0c1f6a8e-3d5b-4c2a-9e7f-1a2b3c4d5e02', NULL, NULL, 10);
    );
    var registration: work.Registration = .{};
    var loader: Loader = .{
        .allocator = std.testing.allocator,
        .database = &library,
        .registration = &registration,
    };
    defer loader.deinit();
    _ = try loader.request(std.testing.io, .{ .release_group = covered });
    _ = try loader.request(std.testing.io, .{ .release_group = bare });
    while (loader.step(std.testing.io)) {}

    const cover = loader.take().?;
    defer if (cover.image) |image| image.deinit();
    try std.testing.expectEqualSlices(u8, &covered, &cover.subject.release_group);
    try std.testing.expectEqualStrings("image/jpeg", cover.image.?.mime_type);
    try std.testing.expectEqual(metadata.ArtworkKind.front_cover, cover.image.?.kind);
    const none = loader.take().?;
    try std.testing.expect(none.image == null);
}

test "each finished request wakes the host, and a skipped one does not" {
    var library = try database.LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-artwork-loader-wake?mode=memory&cache=shared",
    );
    defer library.close();
    var registration: work.Registration = .{};
    var counter: control.CountingWaker = .{};
    var signal: control.HostSignal = .{ .waker = counter.waker() };
    var loader: Loader = .{
        .allocator = std.testing.allocator,
        .database = &library,
        .registration = &registration,
        .host_signal = &signal,
    };
    defer loader.deinit();
    _ = try loader.request(std.testing.io, .{ .release = 1 });
    const skipped = try loader.request(std.testing.io, .{ .track = 2 });
    _ = try loader.request(std.testing.io, .{ .release = 3 });
    loader.cancel(skipped);

    try std.testing.expect(loader.step(std.testing.io));
    try std.testing.expectEqual(@as(u32, 1), counter.count());
    signal.clear();
    try std.testing.expect(loader.step(std.testing.io));
    try std.testing.expect(!signal.isPending());
    try std.testing.expect(loader.step(std.testing.io));
    try std.testing.expectEqual(@as(u32, 2), counter.count());
    try std.testing.expect(!loader.step(std.testing.io));
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
