const std = @import("std");
const sqlite = @import("../sqlite.zig");
const metadata = @import("../../metadata/model.zig");
const columns = @import("../columns.zig");
const identification = @import("identification.zig");
const artwork_problems = @import("artwork_problems.zig");
const image_header = @import("../../metadata/image_header.zig");

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

/// Which of a Release's covers a `release_artwork` row holds.
pub const ReleaseArtworkKind = enum(u8) { front = 0, back = 1, booklet = 2 };

/// Where a cover came from. `release_artwork` stores only `fetched` and
/// `chosen` images; embedded and folder covers are read from their files.
pub const ReleaseArtworkSource = enum(u8) { embedded = 0, folder = 1, fetched = 2, chosen = 3 };

/// What a Cover Art Archive image is to a Release.
pub const CoverArtCandidateKind = enum(u8) {
    front = 0,
    back = 1,
    booklet = 2,
    /// An image of the release the archive picks for the Release's release
    /// group, rather than of the Release's own release.
    release_group = 3,
    other = 4,
};

/// At most this many images are kept as a Release's candidates.
pub const max_cover_art_candidates = 8;

/// One image the Cover Art Archive holds for a Release, with its 250-pixel
/// thumbnail. The caller frees it with `deinit`.
pub const CoverArtCandidate = struct {
    /// The archive's image ID.
    caa_id: i64,
    /// The release on the archive the image belongs to.
    musicbrainz_release_id: [36]u8,
    kind: CoverArtCandidateKind,
    /// Null when the full image was not fetched, or its size would not read.
    width: ?u32,
    height: ?u32,
    mime: ?[]const u8,
    /// Whether the archive's editors approved the image.
    approved: bool,
    thumbnail: ?[]u8,

    pub fn deinit(self: CoverArtCandidate, allocator: std.mem.Allocator) void {
        if (self.mime) |value| allocator.free(value);
        if (self.thumbnail) |value| allocator.free(value);
    }
};

pub const CoverArtCandidateInput = struct {
    caa_id: i64,
    musicbrainz_release_id: []const u8,
    kind: CoverArtCandidateKind,
    width: ?u32 = null,
    height: ?u32 = null,
    mime: ?[]const u8 = null,
    approved: bool = false,
    thumbnail: ?[]const u8 = null,
};

pub const ReleaseArtworkRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// The fetched front cover's record; null when none was fetched or a
    /// person chose the front cover.
    pub fn get(self: *const ReleaseArtworkRepository, release_id: i64) !?StoredReleaseArtwork {
        var statement = try self.db.prepare(
            "SELECT musicbrainz_release_id, image IS NOT NULL, fetched_at FROM release_artwork WHERE release_id=?1 AND kind=0 AND source=2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        if (try statement.step() != .row) return null;
        const stored_mbid = statement.columnText(0);
        if (!metadata.isMusicBrainzId(stored_mbid)) return null;
        var row: StoredReleaseArtwork = .{
            .musicbrainz_release_id = undefined,
            .has_image = statement.columnInt64(1) != 0,
            .fetched_at = statement.columnInt64(2),
        };
        @memcpy(&row.musicbrainz_release_id, stored_mbid);
        return row;
    }

    /// Records what the archive answered for `release_mbid` as the
    /// Release's fetched front cover: its cover, or with `image` null that it
    /// has none. A front cover a person chose is kept, and nothing is
    /// recorded. The Release's files' `artwork_problem` is settled in the same
    /// transaction.
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
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try storeLocked(self.db, .{
            .release_id = release_id,
            .kind = .front,
            .source = .fetched,
            .release_mbid = release_mbid,
            .image = image,
            .stored_at = fetched_at,
        });
        try artwork_problems.settleReleaseLocked(self.db, release_id);
        try self.db.exec("COMMIT;");
    }

    /// Stores a cover a person chose for one of a Release's covers, in place
    /// of any fetched or chosen one. `mime_type` must be what the bytes are.
    /// `release_mbid` is the archive release the image came from, if any.
    pub fn set(
        self: *ReleaseArtworkRepository,
        release_id: i64,
        kind: ReleaseArtworkKind,
        bytes: []const u8,
        mime_type: []const u8,
        release_mbid: ?[]const u8,
        stored_at: i64,
    ) !void {
        if (bytes.len == 0 or bytes.len > metadata.max_image_bytes) return error.ArtworkTooLarge;
        const sniffed = metadata.sniffImageMimeType(bytes) orelse return error.UnrecognizedArtworkImage;
        if (!std.mem.eql(u8, sniffed, mime_type)) return error.ArtworkTypeMismatch;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try requireReleaseLocked(self.db, release_id);
        try storeLocked(self.db, .{
            .release_id = release_id,
            .kind = kind,
            .source = .chosen,
            .release_mbid = release_mbid,
            .image = .{ .bytes = bytes, .mime_type = sniffed },
            .stored_at = stored_at,
        });
        if (kind == .front) try artwork_problems.settleReleaseLocked(self.db, release_id);
        try self.db.exec("COMMIT;");
    }

    /// Removes one of a Release's stored covers, chosen or fetched. False
    /// when there was none.
    pub fn clear(self: *ReleaseArtworkRepository, release_id: i64, kind: ReleaseArtworkKind) !bool {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try requireReleaseLocked(self.db, release_id);
        var statement = try self.db.prepare("DELETE FROM release_artwork WHERE release_id=?1 AND kind=?2 RETURNING 1;");
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        try statement.bindInt64(2, @intFromEnum(kind));
        const removed = try statement.step() == .row;
        if (removed) _ = try statement.step();
        if (removed and kind == .front) try artwork_problems.settleReleaseLocked(self.db, release_id);
        try self.db.exec("COMMIT;");
        return removed;
    }

    /// Whether a person chose the Release's front cover.
    pub fn hasChosenFront(self: *const ReleaseArtworkRepository, release_id: i64) !bool {
        var statement = try self.db.prepare(
            "SELECT 1 FROM release_artwork WHERE release_id=?1 AND kind=0 AND source=3 AND image IS NOT NULL;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        return try statement.step() == .row;
    }

    /// The fetched front cover of a Release, as a caller-owned image.
    pub fn imageForRelease(self: *const ReleaseArtworkRepository, allocator: std.mem.Allocator, release_id: i64) !?metadata.EmbeddedImage {
        return self.readImage(allocator, "SELECT image FROM release_artwork WHERE release_id=?1 AND kind=0 AND source=2 AND image IS NOT NULL;", release_id);
    }

    /// The fetched front cover of the Release a Track belongs to.
    pub fn imageForTrack(self: *const ReleaseArtworkRepository, allocator: std.mem.Allocator, track_id: i64) !?metadata.EmbeddedImage {
        return self.readImage(allocator,
            \\SELECT release_artwork.image FROM tracks
            \\JOIN release_artwork ON release_artwork.release_id = tracks.release_id
            \\WHERE tracks.id=?1 AND release_artwork.kind=0 AND release_artwork.source=2 AND release_artwork.image IS NOT NULL;
        , track_id);
    }

    /// The front cover a person chose for a Release.
    pub fn chosenFront(self: *const ReleaseArtworkRepository, allocator: std.mem.Allocator, release_id: i64) !?metadata.EmbeddedImage {
        return self.readImage(allocator, "SELECT image FROM release_artwork WHERE release_id=?1 AND kind=0 AND source=3 AND image IS NOT NULL;", release_id);
    }

    /// The front cover a person chose for the Release a Track belongs to.
    pub fn chosenFrontForTrack(self: *const ReleaseArtworkRepository, allocator: std.mem.Allocator, track_id: i64) !?metadata.EmbeddedImage {
        return self.readImage(allocator,
            \\SELECT release_artwork.image FROM tracks
            \\JOIN release_artwork ON release_artwork.release_id = tracks.release_id
            \\WHERE tracks.id=?1 AND release_artwork.kind=0 AND release_artwork.source=3 AND release_artwork.image IS NOT NULL;
        , track_id);
    }

    /// The stored cover of `kind`, chosen or fetched.
    pub fn stored(self: *const ReleaseArtworkRepository, allocator: std.mem.Allocator, release_id: i64, kind: ReleaseArtworkKind) !?metadata.EmbeddedImage {
        const sql: [:0]const u8 = switch (kind) {
            .front => "SELECT image FROM release_artwork WHERE release_id=?1 AND kind=0 AND image IS NOT NULL;",
            .back => "SELECT image FROM release_artwork WHERE release_id=?1 AND kind=1 AND image IS NOT NULL;",
            .booklet => "SELECT image FROM release_artwork WHERE release_id=?1 AND kind=2 AND image IS NOT NULL;",
        };
        var image = try self.readImage(allocator, sql, release_id) orelse return null;
        image.kind = switch (kind) {
            .front => .front_cover,
            .back => .back_cover,
            .booklet => .other,
        };
        return image;
    }

    /// Replaces a Release's candidates with `inputs`, at most
    /// `max_cover_art_candidates` of them, in one transaction.
    pub fn replaceCandidates(
        self: *ReleaseArtworkRepository,
        release_id: i64,
        inputs: []const CoverArtCandidateInput,
        fetched_at: i64,
    ) !void {
        if (inputs.len > max_cover_art_candidates) return error.TooManyCoverArtCandidates;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try requireReleaseLocked(self.db, release_id);
        {
            var clear_statement = try self.db.prepare("DELETE FROM cover_art_candidates WHERE release_id=?1;");
            defer clear_statement.deinit();
            try clear_statement.bindInt64(1, release_id);
            if (try clear_statement.step() != .done) return error.SqlFailed;
        }
        var statement = try self.db.prepare(
            \\INSERT INTO cover_art_candidates(release_id, caa_id, musicbrainz_release_id, kind, width, height,
            \\    mime, approved, thumbnail, fetched_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10);
        );
        defer statement.deinit();
        for (inputs) |candidate| {
            if (!metadata.isMusicBrainzId(candidate.musicbrainz_release_id)) return error.InvalidMusicBrainzId;
            try statement.bindInt64(1, release_id);
            try statement.bindInt64(2, candidate.caa_id);
            try statement.bindText(3, candidate.musicbrainz_release_id);
            try statement.bindInt64(4, @intFromEnum(candidate.kind));
            try statement.bindOptionalInt64(5, columns.optionalCount(candidate.width));
            try statement.bindOptionalInt64(6, columns.optionalCount(candidate.height));
            try statement.bindOptionalText(7, candidate.mime);
            try statement.bindInt64(8, @intFromBool(candidate.approved));
            if (candidate.thumbnail) |thumbnail| try statement.bindBlob(9, thumbnail) else try statement.bindOptionalText(9, null);
            try statement.bindInt64(10, fetched_at);
            if (try statement.step() != .done) return error.SqlFailed;
            try statement.reset();
        }
        try self.db.exec("COMMIT;");
    }

    /// A Release's candidates: fronts, then release group images, then
    /// backs, booklets and the rest, each in the archive's ID order.
    pub fn candidates(self: *const ReleaseArtworkRepository, allocator: std.mem.Allocator, release_id: i64) ![]CoverArtCandidate {
        var statement = try self.db.prepare(
            \\SELECT caa_id, musicbrainz_release_id, kind, width, height, mime, approved, thumbnail
            \\FROM cover_art_candidates WHERE release_id=?1
            \\ORDER BY CASE kind WHEN 0 THEN 0 WHEN 3 THEN 1 WHEN 1 THEN 2 WHEN 2 THEN 3 ELSE 4 END, caa_id
            \\LIMIT ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        try statement.bindInt64(2, max_page);
        var items: std.ArrayList(CoverArtCandidate) = .empty;
        errdefer {
            for (items.items) |item| item.deinit(allocator);
            items.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const mbid = statement.columnText(1);
            if (!metadata.isMusicBrainzId(mbid)) continue;
            const kind = std.enums.fromInt(CoverArtCandidateKind, statement.columnInt64(2)) orelse continue;
            const mime = try columns.dupeNullable(allocator, statement, 5);
            errdefer if (mime) |value| allocator.free(value);
            const thumbnail: ?[]u8 = if (statement.columnIsNull(7)) null else try allocator.dupe(u8, statement.columnBlob(7));
            errdefer if (thumbnail) |value| allocator.free(value);
            try items.append(allocator, .{
                .caa_id = statement.columnInt64(0),
                .musicbrainz_release_id = mbid[0..36].*,
                .kind = kind,
                .width = columns.countColumn(statement, 3),
                .height = columns.countColumn(statement, 4),
                .mime = mime,
                .approved = statement.columnInt64(6) != 0,
                .thumbnail = thumbnail,
            });
        }
        return items.toOwnedSlice(allocator);
    }

    /// The one MusicBrainz release group ID the Release's files are tagged
    /// with, or null when they carry none or disagree.
    pub fn coverReleaseGroupMbid(self: *const ReleaseArtworkRepository, release_id: i64) !?[36]u8 {
        var statement = try self.db.prepare(
            "SELECT DISTINCT lower(observed_file_tags.musicbrainz_release_group_id) FROM tracks\n" ++
                "JOIN observed_file_tags ON observed_file_tags.file_id = " ++ track_play_file ++ "\n" ++
                "WHERE tracks.release_id = ?1 AND observed_file_tags.musicbrainz_release_group_id <> '' LIMIT 2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        if (try statement.step() != .row) return null;
        const mbid = statement.columnText(0);
        if (!metadata.isMusicBrainzId(mbid)) return null;
        const found = mbid[0..36].*;
        if (try statement.step() == .row) return null;
        return found;
    }

    /// The archive release a stored candidate belongs to, or null when the
    /// Release has no candidate with that ID.
    pub fn candidateRelease(self: *const ReleaseArtworkRepository, release_id: i64, caa_id: i64) !?[36]u8 {
        var statement = try self.db.prepare(
            "SELECT musicbrainz_release_id FROM cover_art_candidates WHERE release_id=?1 AND caa_id=?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        try statement.bindInt64(2, caa_id);
        if (try statement.step() != .row) return null;
        const mbid = statement.columnText(0);
        if (!metadata.isMusicBrainzId(mbid)) return null;
        return mbid[0..36].*;
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

const Stored = struct {
    release_id: i64,
    kind: ReleaseArtworkKind,
    source: ReleaseArtworkSource,
    release_mbid: ?[]const u8,
    image: ?FetchedImage,
    stored_at: i64,
};

/// Writes one cover row, measured. A fetched cover never replaces a chosen
/// one. Caller holds the write lane inside a transaction.
fn storeLocked(db: sqlite.Database, row: Stored) !void {
    var statement = try db.prepare(
        \\INSERT INTO release_artwork(release_id, kind, source, musicbrainz_release_id, image, mime, width, height, fetched_at)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        \\ON CONFLICT(release_id, kind) DO UPDATE SET source=excluded.source,
        \\    musicbrainz_release_id=excluded.musicbrainz_release_id, image=excluded.image, mime=excluded.mime,
        \\    width=excluded.width, height=excluded.height, fetched_at=excluded.fetched_at
        \\WHERE release_artwork.source <> 3 OR excluded.source = 3;
    );
    defer statement.deinit();
    try statement.bindInt64(1, row.release_id);
    try statement.bindInt64(2, @intFromEnum(row.kind));
    try statement.bindInt64(3, @intFromEnum(row.source));
    try statement.bindOptionalText(4, row.release_mbid);
    if (row.image) |present| {
        const measured = image_header.measure(present.bytes);
        try statement.bindBlob(5, present.bytes);
        try statement.bindText(6, present.mime_type);
        try statement.bindInt64(7, measured.width orelse artwork_problems.unreadable_cover_side);
        try statement.bindInt64(8, measured.height orelse artwork_problems.unreadable_cover_side);
    } else {
        for (5..9) |index| try statement.bindOptionalText(@intCast(index), null);
    }
    try statement.bindInt64(9, row.stored_at);
    if (try statement.step() != .done) return error.SqlFailed;
}

fn requireReleaseLocked(db: sqlite.Database, release_id: i64) !void {
    var statement = try db.prepare("SELECT 1 FROM releases WHERE id=?1;");
    defer statement.deinit();
    try statement.bindInt64(1, release_id);
    if (try statement.step() != .row) return error.UnknownRelease;
}

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
