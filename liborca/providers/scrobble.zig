const std = @import("std");
const database = @import("../database/root.zig");

pub const Event = struct {
    title: []const u8,
    artist: []const u8,
    album: []const u8 = "",
    started_at: i64,
    duration_ms: u64,
    listened_ms: u64,
    recording_mbid: ?[]const u8 = null,
    release_mbid: ?[]const u8 = null,
    artist_mbid: ?[]const u8 = null,
    track_number: ?u32 = null,

    pub fn fromSubject(subject: *const database.ListenSubject, started_at: i64, listened_ms: u64) Event {
        return .{
            .title = subject.title,
            .artist = subject.artist,
            .album = subject.album,
            .started_at = started_at,
            .duration_ms = if (subject.duration_ms) |value| @intCast(@max(value, 0)) else 0,
            .listened_ms = listened_ms,
            .recording_mbid = subject.recording_mbid,
            .release_mbid = subject.release_mbid,
            .artist_mbid = subject.artist_mbid,
            .track_number = if (subject.track_number) |value| std.math.cast(u32, value) else null,
        };
    }

    pub fn eligible(self: Event) bool {
        if (self.title.len == 0 or self.artist.len == 0) return false;
        return listenedEnough(self.duration_ms, self.listened_ms);
    }

    /// The queued payload. Caller-owned.
    pub fn encode(self: Event, allocator: std.mem.Allocator) ![]u8 {
        var writer = std.Io.Writer.Allocating.init(allocator);
        defer writer.deinit();
        try std.json.Stringify.value(self, .{ .emit_null_optional_fields = false }, &writer.writer);
        return writer.toOwnedSlice();
    }
};

pub const minimum_duration_ms: u64 = 30_000;
const maximum_required_ms: u64 = 4 * 60 * 1000;

/// A track of at least 30 seconds, heard for half its length or four minutes,
/// whichever is less.
pub fn listenedEnough(duration_ms: u64, listened_ms: u64) bool {
    if (duration_ms < minimum_duration_ms) return false;
    return listened_ms >= @min(duration_ms / 2, maximum_required_ms);
}

pub const Adapter = struct {
    service: []const u8,
    context: *anyopaque,
    submit_fn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn submit(self: Adapter, payload: []const u8) !void {
        try self.submit_fn(self.context, payload);
    }
};

pub fn enqueueEligible(
    allocator: std.mem.Allocator,
    queue: *database.ScrobbleQueueRepository,
    service: []const u8,
    event_key: []const u8,
    event: Event,
) !bool {
    if (!event.eligible()) return false;
    const payload = try event.encode(allocator);
    defer allocator.free(payload);
    try queue.enqueue(service, event_key, payload);
    return true;
}

test "queued payloads written before MBIDs existed still parse" {
    const parsed = try std.json.parseFromSlice(Event, std.testing.allocator,
        \\{"title":"Orca","artist":"Test Artist","album":"","started_at":1700000000,"duration_ms":180000,"listened_ms":95000}
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.recording_mbid);
    try std.testing.expectEqual(@as(?u32, null), parsed.value.track_number);
}

test "events built from a listen subject carry its identifiers" {
    const allocator = std.testing.allocator;
    const subject: database.ListenSubject = .{
        .allocator = allocator,
        .file_id = null,
        .recording_id = null,
        .title = @constCast("Orca"),
        .artist = @constCast("Test Artist"),
        .album = @constCast(""),
        .duration_ms = 180_000,
        .track_number = 3,
        .recording_mbid = @constCast("rec"),
        .release_mbid = null,
        .artist_mbid = @constCast("art"),
    };
    const event = Event.fromSubject(&subject, 1_700_000_000, 100_000);
    try std.testing.expectEqual(@as(u64, 180_000), event.duration_ms);
    try std.testing.expectEqual(@as(?u32, 3), event.track_number);
    try std.testing.expectEqualStrings("art", event.artist_mbid.?);
    try std.testing.expect(event.eligible());
}

test "enqueuing an eligible scrobble twice under one key keeps one pending entry" {
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
}
