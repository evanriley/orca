const std = @import("std");
const sqlite = @import("../sqlite.zig");
const metadata = @import("../../metadata/model.zig");
const columns = @import("../columns.zig");
const identification = @import("identification.zig");

const max_page = columns.max_page;
const track_play_file = @import("tracks.zig").track_play_file;
const WriteLane = @import("write_lane.zig").WriteLane;

/// What `release_artwork` records about a Release's fetched cover, without
/// the image.
pub const StoredReleaseArtwork = struct {
    /// The release ID the cover was fetched for.
    musicbrainz_release_id: [36]u8,
    has_image: bool,
    /// Unix seconds.
    fetched_at: i64,
};

pub const FetchedImage = struct {
    bytes: []const u8,
    mime_type: []const u8,
};

pub const ReleaseArtworkRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn get(self: *const ReleaseArtworkRepository, release_id: i64) !?StoredReleaseArtwork {
        var statement = try self.db.prepare(
            "SELECT musicbrainz_release_id, image IS NOT NULL, fetched_at FROM release_artwork WHERE release_id=?1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        if (try statement.step() != .row) return null;
        const stored_mbid = statement.columnText(0);
        if (!metadata.isMusicBrainzId(stored_mbid)) return null;
        var stored: StoredReleaseArtwork = .{
            .musicbrainz_release_id = undefined,
            .has_image = statement.columnInt64(1) != 0,
            .fetched_at = statement.columnInt64(2),
        };
        @memcpy(&stored.musicbrainz_release_id, stored_mbid);
        return stored;
    }

    /// Records what the archive answered for `release_mbid`: its cover, or
    /// with `image` null that it has none.
    pub fn put(
        self: *ReleaseArtworkRepository,
        release_id: i64,
        release_mbid: []const u8,
        image: ?FetchedImage,
        fetched_at: i64,
    ) !void {
        if (!metadata.isMusicBrainzId(release_mbid)) return error.InvalidMusicBrainzId;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO release_artwork(release_id, musicbrainz_release_id, image, mime, fetched_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5)
            \\ON CONFLICT(release_id) DO UPDATE SET musicbrainz_release_id=excluded.musicbrainz_release_id,
            \\    image=excluded.image, mime=excluded.mime, fetched_at=excluded.fetched_at;
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        try statement.bindText(2, release_mbid);
        if (image) |present| {
            try statement.bindBlob(3, present.bytes);
            try statement.bindText(4, present.mime_type);
        } else {
            try statement.bindOptionalText(3, null);
            try statement.bindOptionalText(4, null);
        }
        try statement.bindInt64(5, fetched_at);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// The fetched cover of a Release, as a caller-owned image.
    pub fn imageForRelease(self: *const ReleaseArtworkRepository, allocator: std.mem.Allocator, release_id: i64) !?metadata.EmbeddedImage {
        return self.readImage(allocator, "SELECT image FROM release_artwork WHERE release_id=?1 AND image IS NOT NULL;", release_id);
    }

    /// The fetched cover of the Release a Track belongs to.
    pub fn imageForTrack(self: *const ReleaseArtworkRepository, allocator: std.mem.Allocator, track_id: i64) !?metadata.EmbeddedImage {
        return self.readImage(allocator,
            \\SELECT release_artwork.image FROM tracks
            \\JOIN release_artwork ON release_artwork.release_id = tracks.release_id
            \\WHERE tracks.id=?1 AND release_artwork.image IS NOT NULL;
        , track_id);
    }

    fn readImage(self: *const ReleaseArtworkRepository, allocator: std.mem.Allocator, sql: [:0]const u8, id: i64) !?metadata.EmbeddedImage {
        var statement = try self.db.prepare(sql);
        defer statement.deinit();
        try statement.bindInt64(1, id);
        if (try statement.step() != .row) return null;
        const bytes = try allocator.dupe(u8, statement.columnBlob(0));
        return metadata.adoptImage(allocator, bytes, .front_cover) catch {
            allocator.free(bytes);
            return null;
        };
    }

    /// The MusicBrainz release ID to fetch a Release's cover under: the one
    /// its files are tagged with, else the one most of its accepted matches
    /// name. Null when neither gives one.
    pub fn coverReleaseMbid(self: *const ReleaseArtworkRepository, allocator: std.mem.Allocator, release_id: i64) !?[36]u8 {
        var tag_statement = try self.db.prepare("SELECT musicbrainz_release_id FROM releases WHERE id=?1;");
        defer tag_statement.deinit();
        try tag_statement.bindInt64(1, release_id);
        if (try tag_statement.step() != .row) return error.UnknownRelease;
        const tag = tag_statement.columnText(0);
        if (metadata.isMusicBrainzId(tag)) return tag[0..36].*;

        var tally: MbidTally = .{};
        defer tally.deinit(allocator);
        var statement = try self.db.prepare(
            "SELECT identification_proposals.payload FROM tracks\n" ++
                "JOIN identification_proposals ON identification_proposals.file_id = " ++ track_play_file ++ "\n" ++
                "WHERE tracks.release_id = ?1 AND identification_proposals.state = ?2 LIMIT ?3;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        try statement.bindInt64(2, @intFromEnum(identification.ProposalState.accepted));
        try statement.bindInt64(3, max_page);
        while (try statement.step() == .row) {
            const parsed = identification.ProposalPayload.parse(allocator, statement.columnBlob(0)) catch |err| switch (err) {
                error.InvalidProposalPayload => continue,
                error.OutOfMemory => return err,
            };
            defer parsed.deinit();
            const mbid = parsed.value.release_mbid orelse continue;
            if (metadata.isMusicBrainzId(mbid)) try tally.add(allocator, mbid[0..36].*);
        }
        return tally.winner(tag);
    }
};

/// Votes for release IDs. The most votes win; a tie goes to the one equal to
/// `tag`, then by `ReleaseRanking`, then to the lowest.
pub const MbidTally = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { mbid: [36]u8, votes: u32 };

    pub fn deinit(self: *MbidTally, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn add(self: *MbidTally, allocator: std.mem.Allocator, mbid: [36]u8) !void {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, &entry.mbid, &mbid)) {
                entry.votes += 1;
                return;
            }
        }
        try self.entries.append(allocator, .{ .mbid = mbid, .votes = 1 });
    }

    pub fn winner(self: *const MbidTally, tag: []const u8) ?[36]u8 {
        return self.rankedWinner(tag, .{});
    }

    pub fn rankedWinner(self: *const MbidTally, tag: []const u8, ranking: ReleaseRanking) ?[36]u8 {
        var best: ?Entry = null;
        for (self.entries.items) |entry| {
            const current = best orelse {
                best = entry;
                continue;
            };
            if (outranks(entry, current, tag, ranking)) best = entry;
        }
        return if (best) |chosen| chosen.mbid else null;
    }

    fn outranks(entry: Entry, current: Entry, tag: []const u8, ranking: ReleaseRanking) bool {
        if (entry.votes != current.votes) return entry.votes > current.votes;
        const entry_is_tag = std.mem.eql(u8, &entry.mbid, tag);
        const current_is_tag = std.mem.eql(u8, &current.mbid, tag);
        if (entry_is_tag != current_is_tag) return entry_is_tag;
        const entry_fact = ranking.factFor(&entry.mbid);
        const current_fact = ranking.factFor(&current.mbid);
        const entry_official = isOfficial(entry_fact);
        if (entry_official != isOfficial(current_fact)) return entry_official;
        const entry_complete = ranking.hasAlbumTrackCount(entry_fact);
        if (entry_complete != ranking.hasAlbumTrackCount(current_fact)) return entry_complete;
        switch (dateOrder(entry_fact, current_fact)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        return std.mem.order(u8, &entry.mbid, &current.mbid) == .lt;
    }
};

pub const ReleaseRanking = struct {
    facts: []const identification.ReleaseFact = &.{},
    album_track_count: ?u32 = null,

    fn factFor(self: ReleaseRanking, mbid: []const u8) ?identification.ReleaseFact {
        for (self.facts) |fact| if (std.mem.eql(u8, fact.mbid, mbid)) return fact;
        return null;
    }

    fn hasAlbumTrackCount(self: ReleaseRanking, fact: ?identification.ReleaseFact) bool {
        const album = self.album_track_count orelse return false;
        const release = (fact orelse return false).track_count orelse return false;
        return release == album;
    }
};

fn isOfficial(fact: ?identification.ReleaseFact) bool {
    const status = (fact orelse return false).status orelse return false;
    return std.mem.eql(u8, status, "Official");
}

fn dateOrder(a: ?identification.ReleaseFact, b: ?identification.ReleaseFact) std.math.Order {
    const a_date = knownDate(a);
    const b_date = knownDate(b);
    if (a_date == null and b_date == null) return .eq;
    if (a_date == null) return .gt;
    if (b_date == null) return .lt;
    return std.mem.order(u8, a_date.?, b_date.?);
}

fn knownDate(fact: ?identification.ReleaseFact) ?[]const u8 {
    const date = (fact orelse return null).date orelse return null;
    return if (date.len == 0) null else date;
}

const testing = std.testing;
const mbid_a = "aaaaaaaa-0000-4000-8000-000000000000";
const mbid_b = "bbbbbbbb-0000-4000-8000-000000000000";

fn tallyOf(votes_a: u32, votes_b: u32, tag: []const u8) !?[36]u8 {
    var tally: MbidTally = .{};
    defer tally.deinit(testing.allocator);
    for (0..votes_b) |_| try tally.add(testing.allocator, mbid_b.*);
    for (0..votes_a) |_| try tally.add(testing.allocator, mbid_a.*);
    return tally.winner(tag);
}

test "the release ID most accepted matches name wins, and a tie goes to the tag, then the lowest" {
    try testing.expectEqualStrings(mbid_a, &(try tallyOf(7, 4, "")).?);
    try testing.expectEqualStrings(mbid_b, &(try tallyOf(4, 7, "")).?);
    try testing.expectEqualStrings(mbid_a, &(try tallyOf(3, 3, "")).?);
    try testing.expectEqualStrings(mbid_b, &(try tallyOf(3, 3, mbid_b)).?);
    try testing.expectEqual(@as(?[36]u8, null), try tallyOf(0, 0, mbid_b));
}

const mbid_c = "cccccccc-0000-4000-8000-000000000000";

fn rankedWinnerOf(tag: []const u8, facts: []const identification.ReleaseFact, album_track_count: ?u32) !?[36]u8 {
    var tally: MbidTally = .{};
    defer tally.deinit(testing.allocator);
    for ([_][]const u8{ mbid_c, mbid_b, mbid_a }) |mbid| try tally.add(testing.allocator, mbid[0..36].*);
    return tally.rankedWinner(tag, .{ .facts = facts, .album_track_count = album_track_count });
}

test "a tie in votes goes to the Official release with the album's track count, then the earliest" {
    const facts = [_]identification.ReleaseFact{
        .{ .mbid = mbid_a, .status = "Official", .date = "2011", .track_count = 14 },
        .{ .mbid = mbid_b, .status = "Bootleg", .date = "1990", .track_count = 12 },
        .{ .mbid = mbid_c, .status = "Official", .date = "1991", .track_count = 12 },
    };
    try testing.expectEqualStrings(mbid_c, &(try rankedWinnerOf("", &facts, 12)).?);
}

test "among Official releases a tie goes to the one with the album's track count" {
    const facts = [_]identification.ReleaseFact{
        .{ .mbid = mbid_a, .status = "Official", .date = "1990", .track_count = 14 },
        .{ .mbid = mbid_b, .status = "Official", .date = "1991" },
        .{ .mbid = mbid_c, .status = "Official", .date = "2020", .track_count = 12 },
    };
    try testing.expectEqualStrings(mbid_c, &(try rankedWinnerOf("", &facts, 12)).?);
    try testing.expectEqualStrings(mbid_a, &(try rankedWinnerOf("", &facts, null)).?);
}

test "a tie in status and track count goes to the earliest date, and a missing date sorts last" {
    const facts = [_]identification.ReleaseFact{
        .{ .mbid = mbid_a, .status = "Official", .date = "" },
        .{ .mbid = mbid_b, .status = "Official", .date = "2004-06-02" },
        .{ .mbid = mbid_c, .status = "Official", .date = "2004" },
    };
    try testing.expectEqualStrings(mbid_c, &(try rankedWinnerOf("", &facts, 12)).?);
    const undated = [_]identification.ReleaseFact{
        .{ .mbid = mbid_a, .status = "Official" },
        .{ .mbid = mbid_c, .status = "Official", .date = "2020" },
    };
    try testing.expectEqualStrings(mbid_c, &(try rankedWinnerOf("", &undated, null)).?);
}

test "a release with no facts ranks below one with them, and with none the lowest wins" {
    const facts = [_]identification.ReleaseFact{
        .{ .mbid = mbid_b, .status = "Promotion", .date = "2030" },
    };
    try testing.expectEqualStrings(mbid_b, &(try rankedWinnerOf("", &facts, null)).?);
    try testing.expectEqualStrings(mbid_a, &(try rankedWinnerOf("", &.{}, 12)).?);
    try testing.expectEqualStrings(mbid_a, &(try rankedWinnerOf("", &.{.{ .mbid = mbid_c, .status = "official" }}, null)).?);
}

test "the tag and more votes still outrank every release fact" {
    const facts = [_]identification.ReleaseFact{
        .{ .mbid = mbid_a, .status = "Official", .date = "1991", .track_count = 12 },
    };
    try testing.expectEqualStrings(mbid_b, &(try rankedWinnerOf(mbid_b, &facts, 12)).?);
    var tally: MbidTally = .{};
    defer tally.deinit(testing.allocator);
    try tally.add(testing.allocator, mbid_a.*);
    try tally.add(testing.allocator, mbid_b.*);
    try tally.add(testing.allocator, mbid_b.*);
    try testing.expectEqualStrings(mbid_b, &tally.rankedWinner("", .{ .facts = &facts, .album_track_count = 12 }).?);
}
