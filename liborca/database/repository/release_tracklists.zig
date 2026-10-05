const std = @import("std");
const sqlite = @import("../sqlite.zig");
const WriteLane = @import("write_lane.zig").WriteLane;

/// A release of more media or tracks than this is not snapshotted.
pub const max_media = 512;
pub const max_tracks = 512;

pub const ReleaseTracklistTrack = struct {
    /// The medium's position, from 1.
    disc: u32,
    /// The track's position on its medium, from 1.
    position: u32,
    title: []const u8,
    artist_credit: []const u8,
    length_ms: ?u64,
    recording_mbid: []const u8,
    release_track_mbid: []const u8,
};

/// A MusicBrainz release's own tracklist, as one lookup returned it.
/// Strings are borrowed when writing and owned by `ReleaseTracklist` when
/// read. Tracks are in disc, then position order.
pub const ReleaseTracklistRecord = struct {
    release_mbid: []const u8,
    title: []const u8,
    artist_credit: []const u8,
    release_date: ?[]const u8 = null,
    release_group_mbid: ?[]const u8 = null,
    medium_count: u32,
    /// Unix seconds.
    fetched_at: i64,
    tracks: []const ReleaseTracklistTrack,
};

pub const ReleaseTracklist = struct {
    arena: std.heap.ArenaAllocator,
    record: ReleaseTracklistRecord,

    pub fn deinit(self: *ReleaseTracklist) void {
        self.arena.deinit();
    }
};

pub const ReleaseTracklistRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Replaces the release's snapshot, header and tracks, in one
    /// transaction.
    pub fn replace(self: *ReleaseTracklistRepository, record: *const ReleaseTracklistRecord) !void {
        if (record.medium_count > max_media or record.tracks.len > max_tracks) return error.ReleaseTracklistTooLarge;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        {
            var statement = try self.db.prepare("DELETE FROM musicbrainz_releases WHERE musicbrainz_release_id=?1;");
            defer statement.deinit();
            try statement.bindText(1, record.release_mbid);
            if (try statement.step() != .done) return error.SqlFailed;
        }
        {
            var statement = try self.db.prepare(
                \\INSERT INTO musicbrainz_releases(musicbrainz_release_id, title, artist_credit, release_date,
                \\    release_group_id, medium_count, track_count, fetched_at)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
            );
            defer statement.deinit();
            try statement.bindText(1, record.release_mbid);
            try statement.bindText(2, record.title);
            try statement.bindText(3, record.artist_credit);
            try statement.bindOptionalText(4, record.release_date);
            try statement.bindOptionalText(5, record.release_group_mbid);
            try statement.bindInt64(6, record.medium_count);
            try statement.bindInt64(7, @intCast(record.tracks.len));
            try statement.bindInt64(8, record.fetched_at);
            if (try statement.step() != .done) return error.SqlFailed;
        }
        var statement = try self.db.prepare(
            \\INSERT INTO musicbrainz_release_tracks(musicbrainz_release_id, disc, position, title,
            \\    artist_credit, length_ms, recording_id, release_track_id)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
        );
        defer statement.deinit();
        for (record.tracks) |track| {
            try statement.reset();
            try statement.bindText(1, record.release_mbid);
            try statement.bindInt64(2, track.disc);
            try statement.bindInt64(3, track.position);
            try statement.bindText(4, track.title);
            try statement.bindText(5, track.artist_credit);
            try statement.bindOptionalInt64(6, if (track.length_ms) |length| std.math.cast(i64, length) else null);
            try statement.bindText(7, track.recording_mbid);
            try statement.bindText(8, track.release_track_mbid);
            if (try statement.step() != .done) return error.SqlFailed;
        }
        try self.db.exec("COMMIT;");
    }

    /// When the release's snapshot was fetched, in Unix seconds; null
    /// without one.
    pub fn fetchedAt(self: *const ReleaseTracklistRepository, release_mbid: []const u8) !?i64 {
        var statement = try self.db.prepare("SELECT fetched_at FROM musicbrainz_releases WHERE musicbrainz_release_id=?1;");
        defer statement.deinit();
        try statement.bindText(1, release_mbid);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    pub fn get(self: *const ReleaseTracklistRepository, allocator: std.mem.Allocator, release_mbid: []const u8) !?ReleaseTracklist {
        var result: ReleaseTracklist = .{ .arena = .init(allocator), .record = undefined };
        errdefer result.deinit();
        const arena = result.arena.allocator();
        {
            var statement = try self.db.prepare(
                \\SELECT musicbrainz_release_id, title, artist_credit, release_date, release_group_id,
                \\    medium_count, fetched_at
                \\FROM musicbrainz_releases WHERE musicbrainz_release_id=?1;
            );
            defer statement.deinit();
            try statement.bindText(1, release_mbid);
            if (try statement.step() != .row) {
                result.deinit();
                return null;
            }
            result.record = .{
                .release_mbid = try arena.dupe(u8, statement.columnText(0)),
                .title = try arena.dupe(u8, statement.columnText(1)),
                .artist_credit = try arena.dupe(u8, statement.columnText(2)),
                .release_date = if (statement.columnIsNull(3)) null else try arena.dupe(u8, statement.columnText(3)),
                .release_group_mbid = if (statement.columnIsNull(4)) null else try arena.dupe(u8, statement.columnText(4)),
                .medium_count = std.math.cast(u32, statement.columnInt64(5)) orelse 0,
                .fetched_at = statement.columnInt64(6),
                .tracks = &.{},
            };
        }
        var statement = try self.db.prepare(
            \\SELECT disc, position, title, artist_credit, length_ms, recording_id, release_track_id
            \\FROM musicbrainz_release_tracks WHERE musicbrainz_release_id=?1
            \\ORDER BY disc, position LIMIT ?2;
        );
        defer statement.deinit();
        try statement.bindText(1, release_mbid);
        try statement.bindInt64(2, max_tracks);
        var tracks: std.ArrayList(ReleaseTracklistTrack) = .empty;
        while (try statement.step() == .row) {
            try tracks.append(arena, .{
                .disc = std.math.cast(u32, statement.columnInt64(0)) orelse 0,
                .position = std.math.cast(u32, statement.columnInt64(1)) orelse 0,
                .title = try arena.dupe(u8, statement.columnText(2)),
                .artist_credit = try arena.dupe(u8, statement.columnText(3)),
                .length_ms = if (statement.columnIsNull(4)) null else std.math.cast(u64, statement.columnInt64(4)),
                .recording_mbid = try arena.dupe(u8, statement.columnText(5)),
                .release_track_mbid = try arena.dupe(u8, statement.columnText(6)),
            });
        }
        result.record.tracks = tracks.items;
        return result;
    }
};

const recording_a = "1b8c1c69-8a4a-4c0f-9a5e-0a7f4f6a3b01";
const recording_b = "1b8c1c69-8a4a-4c0f-9a5e-0a7f4f6a3b02";
const release = "9c1d999f-b225-37d4-9347-1c4ccb2b45d8";

fn testTrack(position: u32, recording: []const u8) ReleaseTracklistTrack {
    return .{
        .disc = 1,
        .position = position,
        .title = "Song",
        .artist_credit = "Artist",
        .length_ms = 200_000,
        .recording_mbid = recording,
        .release_track_mbid = recording,
    };
}

test "a second snapshot of a release replaces the first whole" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-release-tracklists?mode=memory&cache=shared",
    );
    defer library.close();
    const tracks = [_]ReleaseTracklistTrack{ testTrack(1, recording_a), testTrack(2, recording_b) };
    try library.release_tracklists.replace(&.{
        .release_mbid = release,
        .title = "Nightcall",
        .artist_credit = "Kavinsky",
        .medium_count = 1,
        .fetched_at = 10,
        .tracks = &tracks,
    });
    try library.release_tracklists.replace(&.{
        .release_mbid = release,
        .title = "Nightcall",
        .artist_credit = "Kavinsky",
        .release_date = "2010-11-08",
        .medium_count = 1,
        .fetched_at = 20,
        .tracks = tracks[1..],
    });
    var stored = (try library.release_tracklists.get(std.testing.allocator, release)).?;
    defer stored.deinit();
    try std.testing.expectEqual(@as(i64, 20), stored.record.fetched_at);
    try std.testing.expectEqualStrings("2010-11-08", stored.record.release_date.?);
    try std.testing.expectEqual(@as(usize, 1), stored.record.tracks.len);
    try std.testing.expectEqualStrings(recording_b, stored.record.tracks[0].recording_mbid);
    try std.testing.expectEqual(@as(?i64, 20), try library.release_tracklists.fetchedAt(release));
}

test "a release over the track bound is refused and stores nothing" {
    var library = try @import("../library.zig").LibraryDatabase.open(
        std.testing.allocator,
        std.testing.io,
        "file:orca-test-release-tracklists-bound?mode=memory&cache=shared",
    );
    defer library.close();
    const tracks = try std.testing.allocator.alloc(ReleaseTracklistTrack, max_tracks + 1);
    defer std.testing.allocator.free(tracks);
    for (tracks, 1..) |*track, position| track.* = testTrack(@intCast(position), recording_a);
    try std.testing.expectError(error.ReleaseTracklistTooLarge, library.release_tracklists.replace(&.{
        .release_mbid = release,
        .title = "Box",
        .artist_credit = "Artist",
        .medium_count = 1,
        .fetched_at = 1,
        .tracks = tracks,
    }));
    try std.testing.expectEqual(@as(?i64, null), try library.release_tracklists.fetchedAt(release));
}
