const std = @import("std");
const control = @import("control.zig");
const database = @import("../database/root.zig");
const spsc = @import("../audio/spsc.zig");
const work = @import("work.zig");

const sqlite = database.sqlite;

pub const capacity = 8;
pub const max_codec_name = 32;

pub const Kind = enum { track_page, track_totals, release_page, release_count };

pub const TrackListing = struct {
    text: []const u8 = "",
    query: database.TrackQuery = .{},
};

pub const Request = union(Kind) {
    track_page: TrackListing,
    track_totals: TrackListing,
    release_page: database.ReleaseQuery,
    release_count: database.ReleaseQuery,
};

pub const Payload = union(Kind) {
    track_page: database.TrackPage,
    track_totals: database.TrackTotals,
    release_page: database.ReleasePage,
    release_count: u64,
};

pub const Result = struct {
    request: u64,
    kind: Kind,
    payload: anyerror!Payload,

    pub fn deinit(self: Result) void {
        const payload = self.payload catch return;
        switch (payload) {
            .track_page => |page| page.deinit(),
            .release_page => |page| page.deinit(),
            .track_totals, .release_count => {},
        }
    }
};

fn Bounded(comptime size: usize) type {
    return struct {
        bytes: [size]u8,
        len: usize,

        const Self = @This();

        fn copy(text: []const u8) error{TooLong}!Self {
            if (text.len > size) return error.TooLong;
            var bounded: Self = .{ .bytes = undefined, .len = text.len };
            @memcpy(bounded.bytes[0..text.len], text);
            return bounded;
        }

        fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

const SearchText = Bounded(database.max_search_text);
const CodecName = Bounded(max_codec_name);

const QueuedTracks = struct {
    text: SearchText,
    codec: ?CodecName,
    stored: database.TrackQuery,

    fn copy(listing: TrackListing) !QueuedTracks {
        var stored = listing.query;
        stored.codec = null;
        return .{
            .text = SearchText.copy(listing.text) catch return error.SearchTextTooLong,
            .codec = if (listing.query.codec) |codec| CodecName.copy(codec) catch return error.CodecNameTooLong else null,
            .stored = stored,
        };
    }

    fn query(self: *const QueuedTracks) database.TrackQuery {
        var restored = self.stored;
        restored.codec = if (self.codec) |*codec| codec.slice() else null;
        return restored;
    }
};

const QueuedReleases = struct {
    text: ?SearchText,
    stored: database.ReleaseQuery,

    fn copy(query_value: database.ReleaseQuery) !QueuedReleases {
        var stored = query_value;
        stored.text = null;
        return .{
            .text = if (query_value.text) |text| SearchText.copy(text) catch return error.SearchTextTooLong else null,
            .stored = stored,
        };
    }

    fn query(self: *const QueuedReleases) database.ReleaseQuery {
        var restored = self.stored;
        restored.text = if (self.text) |*text| text.slice() else null;
        return restored;
    }
};

const Listing = union(Kind) {
    track_page: QueuedTracks,
    track_totals: QueuedTracks,
    release_page: QueuedReleases,
    release_count: QueuedReleases,

    fn copy(request: Request) !Listing {
        return switch (request) {
            .track_page => |listing| .{ .track_page = try .copy(listing) },
            .track_totals => |listing| .{ .track_totals = try .copy(listing) },
            .release_page => |query| .{ .release_page = try .copy(query) },
            .release_count => |query| .{ .release_count = try .copy(query) },
        };
    }
};

const Queued = struct {
    id: u64,
    slot: usize,
    listing: Listing,
};

pub const Loader = struct {
    allocator: std.mem.Allocator,
    reader: sqlite.Database,
    tracks: database.TrackRepository,
    releases: database.ReleaseRepository,
    registration: *work.Registration,
    host_signal: ?*control.HostSignal = null,
    threaded: std.Io.Threaded = .init_single_threaded,
    requests: spsc.Queue(Queued, capacity) = .{},
    results: spsc.Queue(Result, capacity) = .{},
    outstanding: std.atomic.Value(u32) = .init(0),
    signal: std.atomic.Value(u32) = .init(0),
    cancelled: [capacity]std.atomic.Value(u64) = @splat(.init(0)),
    slot_ids: [capacity]u64 = @splat(0),
    issued: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        library_database: *const database.LibraryDatabase,
        reader: sqlite.Database,
        registration: *work.Registration,
    ) Loader {
        return .{
            .allocator = allocator,
            .reader = reader,
            .tracks = .{ .db = reader, .write_lane = library_database.write_lane },
            .releases = .{ .db = reader, .write_lane = library_database.write_lane },
            .registration = registration,
        };
    }

    pub fn request(self: *Loader, io: std.Io, id: u64, wanted: Request) !void {
        const listing: Listing = try .copy(wanted);
        if (self.outstanding.load(.acquire) >= capacity) return error.BrowseQueueFull;
        const slot: usize = @intCast(self.issued % capacity);
        _ = self.outstanding.fetchAdd(1, .acq_rel);
        if (!self.requests.push(.{ .id = id, .slot = slot, .listing = listing })) {
            _ = self.outstanding.fetchSub(1, .acq_rel);
            return error.BrowseQueueFull;
        }
        self.slot_ids[slot] = id;
        self.issued += 1;
        self.wake(io);
    }

    pub fn cancel(self: *Loader, id: u64) void {
        for (self.slot_ids, 0..) |slot_id, slot| {
            if (slot_id == id) self.cancelled[slot].store(id, .release);
        }
    }

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
        return .{ .context = self, .wake_fn = cancelFromWaker };
    }

    // `requestCancellation` calls this on the control lane before the thread
    // is joined, and the reader closes only in `deinit`, after the join, so
    // the interrupt never reaches a closed connection.
    fn cancelFromWaker(context: *anyopaque) callconv(.c) void {
        const self: *Loader = @ptrCast(@alignCast(context));
        self.reader.interrupt();
        self.wake(self.threaded.io());
    }

    pub fn discardResults(self: *Loader) void {
        while (self.results.pop()) |result| result.deinit();
    }

    pub fn deinit(self: *Loader) void {
        self.discardResults();
        self.reader.close();
        self.threaded.deinit();
    }

    fn isCancelled(self: *const Loader, queued: *const Queued) bool {
        return self.cancelled[queued.slot].load(.acquire) == queued.id;
    }

    pub fn run(self: *Loader) void {
        defer self.registration.finish();
        const io = self.threaded.io();
        while (true) {
            const seen = self.signal.load(.acquire);
            if (self.registration.cancellationRequested()) return;
            if (self.step()) continue;
            io.futexWait(u32, &self.signal.raw, seen) catch {};
        }
    }

    pub fn step(self: *Loader) bool {
        const next = self.requests.pop() orelse return false;
        if (self.isCancelled(&next)) {
            _ = self.outstanding.fetchSub(1, .acq_rel);
            return true;
        }
        const result: Result = .{
            .request = next.id,
            .kind = std.meta.activeTag(next.listing),
            .payload = self.answer(&next.listing),
        };
        if (self.isCancelled(&next) or !self.results.push(result)) {
            result.deinit();
            _ = self.outstanding.fetchSub(1, .acq_rel);
            return true;
        }
        if (self.host_signal) |signal| signal.raise();
        return true;
    }

    fn answer(self: *const Loader, listing: *const Listing) anyerror!Payload {
        return switch (listing.*) {
            .track_page => |*tracks| .{ .track_page = if (tracks.text.len == 0)
                try self.tracks.page(self.allocator, tracks.query())
            else
                try self.tracks.search(self.allocator, tracks.text.slice(), tracks.query()) },
            .track_totals => |*tracks| .{ .track_totals = if (tracks.text.len == 0)
                try self.tracks.totals(tracks.query())
            else
                try self.tracks.searchTotals(tracks.text.slice(), tracks.query()) },
            .release_page => |*releases| .{ .release_page = try self.releases.page(self.allocator, releases.query()) },
            .release_count => |*releases| .{ .release_count = try self.releases.countMatching(releases.query()) },
        };
    }
};

const TestLibrary = struct {
    library: database.LibraryDatabase,
    registration: work.Registration = .{},

    fn open(self: *TestLibrary, name: [:0]const u8) !Loader {
        self.* = .{ .library = try database.LibraryDatabase.open(std.testing.allocator, std.testing.io, name) };
        errdefer self.library.close();
        return .init(std.testing.allocator, &self.library, try self.library.openReader(), &self.registration);
    }
};

fn countStatement(_: c_uint, context: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const started: *u32 = @ptrCast(@alignCast(context.?));
    started.* += 1;
    return 0;
}

test "a request cancelled before it starts runs no query and delivers nothing" {
    var fixture: TestLibrary = undefined;
    var loader = try fixture.open("file:orca-browse-loader-cancel?mode=memory&cache=shared");
    defer fixture.library.close();
    defer loader.deinit();
    var started: u32 = 0;
    try std.testing.expectEqual(sqlite.c.SQLITE_OK, sqlite.c.sqlite3_trace_v2(loader.reader.handle, sqlite.c.SQLITE_TRACE_STMT, countStatement, &started));

    try loader.request(std.testing.io, 1, .{ .track_page = .{ .text = "song" } });
    try loader.request(std.testing.io, 2, .{ .release_count = .{} });
    loader.cancel(1);
    loader.cancel(2);
    while (loader.step()) {}
    try std.testing.expectEqual(@as(u32, 0), started);
    try std.testing.expect(loader.take() == null);
    try std.testing.expectEqual(@as(u32, 0), loader.outstanding.load(.acquire));

    try loader.request(std.testing.io, 3, .{ .release_count = .{} });
    while (loader.step()) {}
    try std.testing.expect(started > 0);
    const kept = loader.take().?;
    try std.testing.expectEqual(@as(u64, 3), kept.request);
    try std.testing.expectEqual(@as(u64, 0), (try kept.payload).release_count);
}

test "a cancel names only its own request, though ids from other loaders interleave" {
    var fixture: TestLibrary = undefined;
    var loader = try fixture.open("file:orca-browse-loader-slots?mode=memory&cache=shared");
    defer fixture.library.close();
    defer loader.deinit();
    const ids = [_]u64{ 5, 13, 21, 29, 37, 45, 53, 61 };
    for (ids) |id| try loader.request(std.testing.io, id, .{ .track_totals = .{} });
    loader.cancel(21);
    loader.cancel(37);
    loader.cancel(69);
    while (loader.step()) {}
    for (ids) |id| {
        if (id == 21 or id == 37) continue;
        const result = loader.take().?;
        try std.testing.expectEqual(id, result.request);
        try std.testing.expectEqual(Kind.track_totals, result.kind);
    }
    try std.testing.expect(loader.take() == null);
}

test "requests beyond capacity are refused with BrowseQueueFull until a result is taken" {
    var fixture: TestLibrary = undefined;
    var loader = try fixture.open("file:orca-browse-loader-full?mode=memory&cache=shared");
    defer fixture.library.close();
    defer loader.deinit();
    for (0..capacity) |index| try loader.request(std.testing.io, index + 1, .{ .release_page = .{ .limit = 4 } });
    try std.testing.expectError(error.BrowseQueueFull, loader.request(std.testing.io, 100, .{ .release_count = .{} }));
    while (loader.step()) {}
    try std.testing.expectError(error.BrowseQueueFull, loader.request(std.testing.io, 100, .{ .release_count = .{} }));
    loader.take().?.deinit();
    try loader.request(std.testing.io, 100, .{ .release_count = .{} });
}

test "text longer than the bounds is refused before anything is queued" {
    var fixture: TestLibrary = undefined;
    var loader = try fixture.open("file:orca-browse-loader-bounds?mode=memory&cache=shared");
    defer fixture.library.close();
    defer loader.deinit();
    const long_text: [database.max_search_text + 1]u8 = @splat('a');
    const long_codec: [max_codec_name + 1]u8 = @splat('c');
    try std.testing.expectError(error.SearchTextTooLong, loader.request(std.testing.io, 1, .{ .track_page = .{ .text = &long_text } }));
    try std.testing.expectError(error.SearchTextTooLong, loader.request(std.testing.io, 1, .{ .release_count = .{ .text = &long_text } }));
    try std.testing.expectError(error.CodecNameTooLong, loader.request(std.testing.io, 1, .{ .track_totals = .{ .query = .{ .codec = &long_codec } } }));
    try std.testing.expectEqual(@as(u32, 0), loader.outstanding.load(.acquire));
    try loader.request(std.testing.io, 1, .{ .track_totals = .{ .text = long_text[1..], .query = .{ .codec = long_codec[1..] } } });
    while (loader.step()) {}
    const result = loader.take().?;
    try std.testing.expectEqual(@as(u64, 0), (try result.payload).track_totals.count);
}

test "each delivered result wakes the host, and a skipped request does not" {
    var fixture: TestLibrary = undefined;
    var loader = try fixture.open("file:orca-browse-loader-wake?mode=memory&cache=shared");
    defer fixture.library.close();
    defer loader.deinit();
    var counter: control.CountingWaker = .{};
    var signal: control.HostSignal = .{ .waker = counter.waker() };
    loader.host_signal = &signal;
    try loader.request(std.testing.io, 1, .{ .track_totals = .{} });
    try loader.request(std.testing.io, 2, .{ .track_totals = .{} });
    try loader.request(std.testing.io, 3, .{ .release_count = .{} });
    loader.cancel(2);

    try std.testing.expect(loader.step());
    try std.testing.expectEqual(@as(u32, 1), counter.count());
    signal.clear();
    try std.testing.expect(loader.step());
    try std.testing.expect(!signal.isPending());
    try std.testing.expect(loader.step());
    try std.testing.expectEqual(@as(u32, 2), counter.count());
    try std.testing.expect(!loader.step());
}

test "a failed query arrives as an error result for its request" {
    var fixture: TestLibrary = undefined;
    var loader = try fixture.open("file:orca-browse-loader-error?mode=memory&cache=shared");
    defer fixture.library.close();
    defer loader.deinit();
    try loader.request(std.testing.io, 7, .{ .track_page = .{ .query = .{ .limit = 0 } } });
    while (loader.step()) {}
    const result = loader.take().?;
    try std.testing.expectEqual(@as(u64, 7), result.request);
    try std.testing.expectEqual(Kind.track_page, result.kind);
    try std.testing.expectError(error.PageOutOfRange, result.payload);
}

test "cancellation wakes a parked loader and its thread finishes" {
    var fixture: TestLibrary = undefined;
    var loader = try fixture.open("file:orca-browse-loader-park?mode=memory&cache=shared");
    defer fixture.library.close();
    defer loader.deinit();
    fixture.registration.waker = loader.waker();
    fixture.registration.thread = try std.Thread.spawn(.{}, Loader.run, .{&loader});
    errdefer {
        fixture.registration.requestCancellation();
        fixture.registration.awaitCompletion();
    }

    try loader.request(std.testing.io, 1, .{ .release_page = .{ .limit = 8 } });
    const result = for (0..5_000) |_| {
        if (loader.take()) |value| break value;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.RequestNeverFinished;
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 1), result.request);

    fixture.registration.requestCancellation();
    fixture.registration.awaitCompletion();
    try std.testing.expect(fixture.registration.isFinished());
}
