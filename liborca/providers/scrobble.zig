const std = @import("std");
const database = @import("../database/root.zig");

pub const Event = struct {
    title: []const u8,
    artist: []const u8,
    album: []const u8 = "",
    started_at: i64,
    duration_ms: u64,
    listened_ms: u64,

    pub fn eligible(self: Event) bool {
        if (self.title.len == 0 or self.artist.len == 0 or self.duration_ms < 30_000)
            return false;
        return self.listened_ms >= @min(self.duration_ms / 2, 4 * 60 * 1000);
    }
};

pub const Adapter = struct {
    service: []const u8,
    context: *anyopaque,
    submit_fn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn submit(self: Adapter, payload: []const u8) !void {
        try self.submit_fn(self.context, payload);
    }
};

pub const DispatchResult = struct {
    submitted: u32 = 0,
    deferred: u32 = 0,
};

pub fn enqueueEligible(
    allocator: std.mem.Allocator,
    queue: *database.ScrobbleQueueRepository,
    service: []const u8,
    event_key: []const u8,
    event: Event,
) !bool {
    if (!event.eligible()) return false;
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(event, .{}, &writer.writer);
    try queue.enqueue(service, event_key, writer.writer.buffered());
    return true;
}

pub fn dispatchReady(
    allocator: std.mem.Allocator,
    queue: *database.ScrobbleQueueRepository,
    adapter: Adapter,
    now: i64,
    limit: u32,
) !DispatchResult {
    const entries = try queue.ready(allocator, adapter.service, now, limit);
    defer {
        for (entries) |entry| entry.deinit();
        allocator.free(entries);
    }
    var result: DispatchResult = .{};
    for (entries) |entry| {
        adapter.submit(entry.payload) catch |err| {
            const exponent: u6 = @intCast(@min(entry.attempt_count, 11));
            const delay = @min(@as(i64, 30) << exponent, 24 * 60 * 60);
            try queue.markRetry(entry.id, now + delay, @errorName(err));
            result.deferred += 1;
            continue;
        };
        try queue.markSucceeded(entry.id);
        result.submitted += 1;
    }
    return result;
}

test "eligible scrobbles are idempotent durable and retried" {
    const allocator = std.testing.allocator;
    var library = try database.LibraryDatabase.open(
        allocator,
        std.testing.io,
        "file:orca-scrobbles?mode=memory&cache=shared",
    );
    defer library.close();
    const event: Event = .{
        .title = "Orca",
        .artist = "Test Artist",
        .album = "Ocean",
        .started_at = 1_700_000_000,
        .duration_ms = 180_000,
        .listened_ms = 95_000,
    };
    try std.testing.expect(try enqueueEligible(
        allocator,
        &library.scrobbles,
        "listenbrainz",
        "playback-1",
        event,
    ));
    _ = try enqueueEligible(
        allocator,
        &library.scrobbles,
        "listenbrainz",
        "playback-1",
        event,
    );
    try std.testing.expectEqual(@as(u64, 1), try library.scrobbles.pendingCount());
    const Mock = struct {
        calls: u8 = 0,
        fn submit(context: *anyopaque, payload: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            try std.testing.expect(std.mem.indexOf(u8, payload, "\"title\":\"Orca\"") != null);
            if (self.calls == 1) return error.Offline;
        }
    };
    var mock: Mock = .{};
    const adapter: Adapter = .{
        .service = "listenbrainz",
        .context = &mock,
        .submit_fn = Mock.submit,
    };
    const first = try dispatchReady(allocator, &library.scrobbles, adapter, 100, 10);
    try std.testing.expectEqual(@as(u32, 1), first.deferred);
    const too_soon = try dispatchReady(allocator, &library.scrobbles, adapter, 101, 10);
    try std.testing.expectEqual(@as(u32, 0), too_soon.submitted);
    const retried = try dispatchReady(allocator, &library.scrobbles, adapter, 130, 10);
    try std.testing.expectEqual(@as(u32, 1), retried.submitted);
    try std.testing.expectEqual(@as(u64, 0), try library.scrobbles.pendingCount());
}
