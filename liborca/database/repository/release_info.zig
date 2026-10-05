const std = @import("std");
const sqlite = @import("../sqlite.zig");
const metadata = @import("../../metadata/model.zig");
const WriteLane = @import("write_lane.zig").WriteLane;

pub const DescriptionSource = enum(u8) { wikipedia = 0 };

/// One `release_info` row. Strings are borrowed when writing and owned by
/// `ReleaseInfo` when read.
pub const ReleaseInfoRecord = struct {
    description: ?[]const u8 = null,
    description_source: ?DescriptionSource = null,
    description_url: ?[]const u8 = null,
    description_licence: ?[]const u8 = null,
    description_language: ?[]const u8 = null,
    /// The Wikipedia language the fetch asked for; `description_language`
    /// differs when it fell back to English.
    requested_language: ?[]const u8 = null,
    musicbrainz_release_id: ?[]const u8 = null,
    musicbrainz_release_group_id: ?[]const u8 = null,
    /// Unix seconds.
    fetched_at: i64 = 0,
    /// `core.artist_info.Outcome`, by number.
    outcome: u8 = 0,
};

pub const ReleaseInfo = struct {
    arena: std.heap.ArenaAllocator,
    record: ReleaseInfoRecord,

    pub fn deinit(self: *ReleaseInfo) void {
        self.arena.deinit();
    }
};

pub const ReleaseSubject = struct {
    musicbrainz_release_id: ?[36]u8 = null,
};

/// At most this many of an Artist's Releases are fetched with its info.
pub const max_artist_releases = 64;

pub const ReleaseInfoRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn get(self: *const ReleaseInfoRepository, allocator: std.mem.Allocator, release_id: i64) !?ReleaseInfo {
        var statement = try self.db.prepare(
            \\SELECT description, description_source, description_url, description_licence,
            \\    description_language, requested_language, musicbrainz_release_id,
            \\    musicbrainz_release_group_id, fetched_at, outcome
            \\FROM release_info WHERE release_id=?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        if (try statement.step() != .row) return null;
        var info: ReleaseInfo = .{ .arena = .init(allocator), .record = .{} };
        errdefer info.deinit();
        const arena = info.arena.allocator();
        info.record = .{
            .description = try optionalText(arena, statement, 0),
            .description_source = if (statement.columnIsNull(1)) null else std.enums.fromInt(DescriptionSource, statement.columnInt64(1)),
            .description_url = try optionalText(arena, statement, 2),
            .description_licence = try optionalText(arena, statement, 3),
            .description_language = try optionalText(arena, statement, 4),
            .requested_language = try optionalText(arena, statement, 5),
            .musicbrainz_release_id = try optionalText(arena, statement, 6),
            .musicbrainz_release_group_id = try optionalText(arena, statement, 7),
            .fetched_at = statement.columnInt64(8),
            .outcome = std.math.cast(u8, statement.columnInt64(9)) orelse 0,
        };
        return info;
    }

    pub fn store(self: *ReleaseInfoRepository, release_id: i64, record: *const ReleaseInfoRecord) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO release_info(release_id, description, description_source, description_url,
            \\    description_licence, description_language, requested_language, musicbrainz_release_id,
            \\    musicbrainz_release_group_id, fetched_at, outcome)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            \\ON CONFLICT(release_id) DO UPDATE SET
            \\    description=excluded.description, description_source=excluded.description_source,
            \\    description_url=excluded.description_url, description_licence=excluded.description_licence,
            \\    description_language=excluded.description_language,
            \\    requested_language=excluded.requested_language,
            \\    musicbrainz_release_id=excluded.musicbrainz_release_id,
            \\    musicbrainz_release_group_id=excluded.musicbrainz_release_group_id,
            \\    fetched_at=excluded.fetched_at, outcome=excluded.outcome;
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        try statement.bindOptionalText(2, record.description);
        try statement.bindOptionalInt64(3, if (record.description_source) |source| @backingInt(source) else null);
        try statement.bindOptionalText(4, record.description_url);
        try statement.bindOptionalText(5, record.description_licence);
        try statement.bindOptionalText(6, record.description_language);
        try statement.bindOptionalText(7, record.requested_language);
        try statement.bindOptionalText(8, record.musicbrainz_release_id);
        try statement.bindOptionalText(9, record.musicbrainz_release_group_id);
        try statement.bindInt64(10, record.fetched_at);
        try statement.bindInt64(11, record.outcome);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// The Release's MusicBrainz release ID, when it has a well-formed one.
    /// Null when there is no such Release.
    pub fn subject(self: *const ReleaseInfoRepository, release_id: i64) !?ReleaseSubject {
        var statement = try self.db.prepare("SELECT musicbrainz_release_id FROM releases WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        if (try statement.step() != .row) return null;
        var result: ReleaseSubject = .{};
        if (!statement.columnIsNull(0)) {
            const text = statement.columnText(0);
            if (text.len == 36) {
                var lowered: [36]u8 = undefined;
                _ = std.ascii.lowerString(&lowered, text);
                if (metadata.isMusicBrainzId(&lowered)) result.musicbrainz_release_id = lowered;
            }
        }
        return result;
    }

    /// Up to `max_artist_releases` Releases the Artist is album artist of
    /// that have a MusicBrainz release ID, by id. Caller frees.
    pub fn artistReleases(self: *const ReleaseInfoRepository, allocator: std.mem.Allocator, artist_id: i64) ![]i64 {
        var statement = try self.db.prepare(
            \\SELECT id FROM releases
            \\WHERE album_artist_id = ?1 AND COALESCE(musicbrainz_release_id, '') <> ''
            \\ORDER BY id LIMIT ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, artist_id);
        try statement.bindInt64(2, max_artist_releases);
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row) try ids.append(allocator, statement.columnInt64(0));
        return ids.toOwnedSlice(allocator);
    }
};

fn optionalText(arena: std.mem.Allocator, statement: sqlite.Statement, index: c_int) !?[]const u8 {
    if (statement.columnIsNull(index)) return null;
    return try arena.dupe(u8, statement.columnText(index));
}

const LibraryDatabase = @import("../library.zig").LibraryDatabase;

test "release info is stored per Release, replaced whole, and gone with its Release" {
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, "file:orca-test-release-info?mode=memory&cache=shared");
    defer library.close();
    const artist = (try library.artists.ensure(.{ .key = "queen", .name = "Queen" })).?;
    try library.database.exec("INSERT INTO releases(id, title, album_artist_id, musicbrainz_release_id) VALUES (7, 'Hot Space', 1, '047A4AAE-27F8-4F2D-92FB-214FD8DC865A'), (8, 'Other', 1, NULL);");
    _ = artist;

    try std.testing.expectEqual(@as(?ReleaseInfo, null), try library.release_info.get(std.testing.allocator, 7));
    const subject = (try library.release_info.subject(7)).?;
    try std.testing.expectEqualStrings("047a4aae-27f8-4f2d-92fb-214fd8dc865a", &subject.musicbrainz_release_id.?);
    try std.testing.expectEqual(@as(?[36]u8, null), (try library.release_info.subject(8)).?.musicbrainz_release_id);
    try std.testing.expectEqual(@as(?ReleaseSubject, null), try library.release_info.subject(99));
    const releases = try library.release_info.artistReleases(std.testing.allocator, 1);
    defer std.testing.allocator.free(releases);
    try std.testing.expectEqualSlices(i64, &.{7}, releases);

    try library.release_info.store(7, &.{
        .description = "Hot Space is the tenth studio album.",
        .description_source = .wikipedia,
        .description_licence = "CC BY-SA 4.0",
        .description_language = "en",
        .requested_language = "de",
        .musicbrainz_release_group_id = "3918b90b-340e-3779-9d7e-ba1593653498",
        .fetched_at = 10,
        .outcome = 1,
    });
    try library.release_info.store(7, &.{ .fetched_at = 20, .outcome = 3 });
    var info = (try library.release_info.get(std.testing.allocator, 7)).?;
    defer info.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), info.record.description);
    try std.testing.expectEqual(@as(u8, 3), info.record.outcome);

    try library.database.exec("DELETE FROM releases WHERE id=7;");
    try std.testing.expectEqual(@as(?ReleaseInfo, null), try library.release_info.get(std.testing.allocator, 7));
}
