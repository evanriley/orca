const std = @import("std");
const sqlite = @import("../sqlite.zig");
const metadata = @import("../../metadata/model.zig");
const max_page = @import("../columns.zig").max_page;
const WriteLane = @import("write_lane.zig").WriteLane;

pub const Digest = [32]u8;

/// The Orca metadata fields a release Apply stores, and so those a review
/// covers.
pub const reviewed_fields = [_]metadata.Field{
    .title,                       .artist,                 .album,                        .album_artist,
    .track_number,                .disc_number,            .date,                         .compilation,
    .musicbrainz_recording_id,    .musicbrainz_release_id, .musicbrainz_release_group_id, .musicbrainz_release_track_id,
    .musicbrainz_album_artist_id,
};

const reviewed_field_list = blk: {
    var text: []const u8 = "";
    for (reviewed_fields, 0..) |field, index| {
        text = text ++ (if (index == 0) "" else ", ") ++ std.fmt.comptimePrint("{d}", .{@backingInt(field)});
    }
    break :blk text;
};

const release_files_cte =
    \\WITH release_files(track_id, file_id) AS (
    \\    SELECT id, preferred_file_id FROM tracks WHERE release_id=?1 AND preferred_file_id IS NOT NULL
    \\    UNION
    \\    SELECT t.id, f.id FROM tracks t JOIN files f ON f.recording_id = t.recording_id WHERE t.release_id=?1)
    \\
;

/// A person's word that a Release equals the MusicBrainz release it names,
/// kept with a digest of what they saw.
pub const ReviewedRelease = struct {
    release_mbid: []const u8,
    digest: Digest,
};

/// Reviewed Releases. A review holds only while the Release's digest equals
/// the stored one; nothing deletes a review that stopped holding.
pub const ReviewedReleaseRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Records the review for a caller holding the write lane and an open
    /// transaction.
    pub fn markLocked(self: *ReviewedReleaseRepository, release_id: i64, release_mbid: []const u8, digest: Digest) !void {
        if (!metadata.isMusicBrainzId(release_mbid)) return error.InvalidMusicBrainzId;
        var statement = try self.db.prepare(
            \\INSERT INTO reviewed_releases(release_id, musicbrainz_release_id, digest, reviewed_at)
            \\VALUES (?1, ?2, ?3, unixepoch())
            \\ON CONFLICT(release_id) DO UPDATE SET musicbrainz_release_id=excluded.musicbrainz_release_id,
            \\    digest=excluded.digest, reviewed_at=excluded.reviewed_at;
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        try statement.bindText(2, release_mbid);
        try statement.bindBlob(3, &digest);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Forgets the Release's review, whether or not it still held. False
    /// when it had none.
    pub fn unmark(self: *ReviewedReleaseRepository, release_id: i64) !bool {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare("DELETE FROM reviewed_releases WHERE release_id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        if (try statement.step() != .done) return error.SqlFailed;
        return self.db.changes() != 0;
    }
};

/// Whether the Release's review of `best_mbid` still holds: one keyed read,
/// and a digest of the Release only when a review of `best_mbid` exists.
pub fn stillReviewed(db: sqlite.Database, release_id: i64, best_mbid: []const u8) !bool {
    var stored: Digest = undefined;
    {
        var statement = try db.prepare("SELECT musicbrainz_release_id, digest FROM reviewed_releases WHERE release_id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        if (try statement.step() != .row) return false;
        if (!std.mem.eql(u8, statement.columnText(0), best_mbid)) return false;
        const blob = statement.columnBlob(1);
        if (blob.len != stored.len) return false;
        @memcpy(&stored, blob);
    }
    const current = (try releaseDigest(db, release_id, best_mbid)) orelse return false;
    return std.mem.eql(u8, &stored, &current);
}

/// What a review covers: the release and its snapshot, the Release's Tracks
/// and, for each of their files, the observed tags and Orca values of
/// `reviewed_fields`. Null without a snapshot or for a Release of more than
/// `max_page` Tracks.
pub fn releaseDigest(db: sqlite.Database, release_id: i64, release_mbid: []const u8) !?Digest {
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    feedText(&hasher, release_mbid);
    {
        var statement = try db.prepare(
            \\SELECT title, artist_credit, release_date, release_group_id, medium_count, artist_credit_ids
            \\FROM musicbrainz_releases WHERE musicbrainz_release_id=?1;
        );
        defer statement.deinit();
        try statement.bindText(1, release_mbid);
        if (try statement.step() != .row) return null;
        feedColumns(&hasher, statement, 6);
    }
    {
        var statement = try db.prepare(
            \\SELECT disc, position, title, artist_credit, length_ms, recording_id, release_track_id
            \\FROM musicbrainz_release_tracks WHERE musicbrainz_release_id=?1 ORDER BY disc, position;
        );
        defer statement.deinit();
        try statement.bindText(1, release_mbid);
        while (try statement.step() == .row) feedColumns(&hasher, statement, 7);
    }
    {
        var statement = try db.prepare("SELECT id FROM tracks WHERE release_id=?1 ORDER BY id LIMIT ?2;");
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        try statement.bindInt64(2, max_page + 1);
        var count: usize = 0;
        while (try statement.step() == .row) {
            count += 1;
            if (count > max_page) return null;
            feedColumns(&hasher, statement, 1);
        }
    }
    {
        var statement = try db.prepare(release_files_cte ++
            \\SELECT rf.track_id, rf.file_id, o.file_id IS NOT NULL, o.title, o.artist, o.album, o.album_artist,
            \\    o.track_number, o.disc_number, o.date, o.compilation, o.musicbrainz_recording_id,
            \\    o.musicbrainz_release_id, o.musicbrainz_release_group_id, o.musicbrainz_release_track_id,
            \\    o.musicbrainz_album_artist_id
            \\FROM release_files rf LEFT JOIN observed_file_tags o ON o.file_id = rf.file_id
            \\ORDER BY rf.track_id, rf.file_id;
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        while (try statement.step() == .row) feedColumns(&hasher, statement, 16);
    }
    {
        var statement = try db.prepare(release_files_cte ++
            "SELECT rf.track_id, rf.file_id, v.field, v.value, v.provenance, v.locked\n" ++
            "FROM release_files rf JOIN orca_metadata_values v ON v.file_id = rf.file_id\n" ++
            "WHERE v.field IN (" ++ reviewed_field_list ++ ")\n" ++
            "ORDER BY rf.track_id, rf.file_id, v.field;");
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        while (try statement.step() == .row) feedColumns(&hasher, statement, 6);
    }
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn feedColumns(hasher: *std.crypto.hash.sha2.Sha256, statement: sqlite.Statement, count: c_int) void {
    var index: c_int = 0;
    while (index < count) : (index += 1) {
        if (statement.columnIsNull(index)) {
            hasher.update(&.{0});
        } else {
            hasher.update(&.{1});
            feedText(hasher, statement.columnText(index));
        }
    }
    hasher.update(&.{2});
}

fn feedText(hasher: *std.crypto.hash.sha2.Sha256, text: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, text.len, .little);
    hasher.update(&length);
    hasher.update(text);
}
