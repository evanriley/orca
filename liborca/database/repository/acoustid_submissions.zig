const std = @import("std");
const sqlite = @import("../sqlite.zig");
const metadata = @import("../../metadata/model.zig");
const columns = @import("../columns.zig");

const duplicateNullableColumn = columns.duplicateNullableColumn;
const max_page = columns.max_page;
const optionalInt64 = columns.optionalInt64;
const ProposalPayload = @import("identification.zig").ProposalPayload;
const ProposalState = @import("identification.zig").ProposalState;
const effectiveRecordingMbid = @import("tracks.zig").effectiveRecordingMbid;
const WriteLane = @import("write_lane.zig").WriteLane;

/// A file whose recording ID Orca could send to AcoustID with its fingerprint,
/// as `AcoustIdSubmissionRepository` reads it.
pub const AcoustIdSubmittable = struct {
    file_id: i64,
    track_id: i64,
    recording_mbid: []const u8,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    album_artist: []const u8,
    track_number: ?i64,
    disc_number: ?i64,
    year: ?u32,
    duration_ms: ?i64,
    codec: []const u8,
    size_bytes: i64,
    /// Where the file is, or null when no location of it is present.
    path: ?[]const u8,
    /// The recording's length, from the accepted match that gave the ID.
    recording_length_ms: ?u64,

    /// How far a file's length may be from its recording's before the ID is
    /// doubted and the file's metadata is sent instead, as Picard does.
    pub const maximum_length_difference_ms: u64 = 30_000;

    /// Whether AcoustID is sent the recording ID rather than the metadata. An
    /// unknown length on either side sends the ID.
    pub fn sendsRecordingId(self: AcoustIdSubmittable, file_duration_ms: ?u64) bool {
        const recording = self.recording_length_ms orelse return true;
        const file = file_duration_ms orelse return true;
        const difference = if (file > recording) file - recording else recording - file;
        return difference <= maximum_length_difference_ms;
    }
};

pub const AcoustIdSubmittablePage = struct {
    arena: *std.heap.ArenaAllocator,
    items: []AcoustIdSubmittable,

    pub fn deinit(self: AcoustIdSubmittablePage) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

pub const AcoustIdSubmission = struct {
    file_id: i64,
    recording_mbid: []const u8,
    submission_id: ?i64,
};

pub const AcoustIdSubmissionRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Files after `cursor`, by id, whose recording ID in effect is Orca's own
    /// value from an accepted match, an edit or a release-track pairing whose
    /// fingerprint agreed, differs from the file's tag or was written into it
    /// by Orca, and has not been sent for that file.
    pub fn submittablePage(
        self: *const AcoustIdSubmissionRepository,
        allocator: std.mem.Allocator,
        cursor: i64,
        limit: u32,
    ) !AcoustIdSubmittablePage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(acoustid_submittable_page_sql);
        defer statement.deinit();
        try statement.bindInt64(1, cursor);
        try statement.bindInt64(2, limit);
        try bindAcoustIdSubmittable(statement);

        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        const page: AcoustIdSubmittablePage = .{ .arena = arena, .items = &.{} };
        errdefer page.deinit();
        const owned = arena.allocator();
        var items: std.ArrayList(AcoustIdSubmittable) = .empty;
        while (try statement.step() == .row) {
            const accepted = ProposalPayload.parse(owned, statement.columnBlob(14)) catch |err| switch (err) {
                error.InvalidProposalPayload => null,
                error.OutOfMemory => return err,
            };
            try items.append(owned, .{
                .file_id = statement.columnInt64(0),
                .track_id = statement.columnInt64(1),
                .recording_mbid = try owned.dupe(u8, statement.columnText(2)),
                .title = try owned.dupe(u8, statement.columnText(3)),
                .artist = try owned.dupe(u8, statement.columnText(4)),
                .album = try owned.dupe(u8, statement.columnText(5)),
                .album_artist = try owned.dupe(u8, statement.columnText(6)),
                .track_number = optionalInt64(statement, 7),
                .disc_number = optionalInt64(statement, 8),
                .year = releaseYear(statement.columnText(9)),
                .duration_ms = optionalInt64(statement, 10),
                .codec = try owned.dupe(u8, statement.columnText(11)),
                .size_bytes = statement.columnInt64(12),
                .path = try duplicateNullableColumn(owned, statement, 13),
                .recording_length_ms = if (accepted) |value| value.value.duration_ms else null,
            });
        }
        return .{ .arena = arena, .items = items.items };
    }

    pub fn submittableCount(self: *const AcoustIdSubmissionRepository) !u64 {
        var statement = try self.db.prepare(acoustid_submittable_count_sql);
        defer statement.deinit();
        try statement.bindInt64(1, 0);
        try bindAcoustIdSubmittable(statement);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// Files and recording IDs AcoustID has accepted, one row each.
    pub fn submittedCount(self: *const AcoustIdSubmissionRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM acoustid_submissions;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// Records what AcoustID accepted, in one transaction.
    pub fn record(self: *AcoustIdSubmissionRepository, submissions: []const AcoustIdSubmission) !void {
        if (submissions.len == 0) return;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var statement = try self.db.prepare(
            \\INSERT INTO acoustid_submissions(file_id, recording_mbid, submission_id, submitted_at)
            \\VALUES (?1, ?2, ?3, unixepoch())
            \\ON CONFLICT(file_id, recording_mbid) DO UPDATE SET
            \\    submission_id=excluded.submission_id, submitted_at=excluded.submitted_at;
        );
        defer statement.deinit();
        for (submissions) |submission| {
            try statement.reset();
            try statement.bindInt64(1, submission.file_id);
            try statement.bindText(2, submission.recording_mbid);
            try statement.bindOptionalInt64(3, submission.submission_id);
            if (try statement.step() != .done) return error.SqlFailed;
        }
        try self.db.exec("COMMIT;");
    }
};

fn releaseYear(release_date: []const u8) ?u32 {
    if (release_date.len < 4) return null;
    const year = std.fmt.parseUnsigned(u32, release_date[0..4], 10) catch return null;
    return if (year == 0) null else year;
}

/// Binds ?3 to ?6 of `acoustid_submittable`.
fn bindAcoustIdSubmittable(statement: sqlite.Statement) !void {
    try statement.bindInt64(3, @backingInt(metadata.Field.musicbrainz_recording_id));
    try statement.bindInt64(4, @backingInt(metadata.Provenance.provider));
    try statement.bindInt64(5, @backingInt(metadata.Provenance.user));
    try statement.bindInt64(6, @backingInt(ProposalState.accepted));
}

/// Files with ids above ?1 whose recording ID in effect is an Orca value of
/// field ?3 with provenance ?4 or ?5, not the file's own tag unless Orca
/// wrote it there, not yet sent.
/// A provider value is sent only when the same file holds its accepted
/// proposal (state ?6), found by MusicBrainz alone and accepted on its own.
/// AcoustID already knows what it proposed; without AcoustID a proposal has no
/// fingerprint score, so a bulk acceptance of it rests on text alone; and a
/// file split off a shared one inherits the value without the proposal.
/// A user value a release-track pairing set is sent only when the file also
/// holds a proposal from AcoustID, in any state, for that recording: a
/// pairing rests on a person's judgment, not on the file's fingerprint.
pub const acoustid_submittable =
    "FROM orca_metadata_values AS chosen\n" ++
    "JOIN files ON files.id = chosen.file_id\n" ++
    "JOIN tracks ON tracks.id = (SELECT id FROM tracks WHERE tracks.preferred_file_id = files.id ORDER BY id LIMIT 1)\n" ++
    "WHERE chosen.file_id > ?1 AND chosen.field = ?3 AND chosen.provenance IN (?4, ?5)\n" ++
    "  AND NULLIF(chosen.value, '') IS NOT NULL\n" ++
    "  AND " ++ effectiveRecordingMbid("files.id") ++ " = chosen.value\n" ++
    "  AND (chosen.written_at IS NOT NULL OR NOT EXISTS (SELECT 1 FROM observed_file_tags\n" ++
    "      WHERE observed_file_tags.file_id = files.id AND observed_file_tags.musicbrainz_recording_id = chosen.value))\n" ++
    "  AND NOT EXISTS (SELECT 1 FROM acoustid_submissions WHERE acoustid_submissions.file_id = files.id\n" ++
    "      AND acoustid_submissions.recording_mbid = chosen.value)\n" ++
    "  AND (chosen.provenance = ?5 OR EXISTS (SELECT 1 FROM identification_proposals AS reviewed\n" ++
    "      WHERE reviewed.file_id = files.id AND reviewed.provider_id = chosen.value AND reviewed.state = ?6\n" ++
    "        AND reviewed.provider NOT IN ('acoustid', 'musicbrainz+acoustid') AND reviewed.accepted_in_bulk = 0))\n" ++
    "  AND NOT (chosen.provenance = ?4 AND EXISTS (SELECT 1 FROM identification_proposals AS accepted\n" ++
    "      WHERE accepted.file_id = files.id AND accepted.provider_id = chosen.value AND accepted.state = ?6\n" ++
    "        AND (accepted.provider IN ('acoustid', 'musicbrainz+acoustid') OR accepted.accepted_in_bulk = 1)))\n" ++
    "  AND NOT (chosen.provenance = ?5 AND EXISTS (SELECT 1 FROM paired_metadata_values AS paired\n" ++
    "      WHERE paired.file_id = files.id AND paired.field = ?3 AND paired.value = chosen.value)\n" ++
    "    AND NOT EXISTS (SELECT 1 FROM identification_proposals AS fingerprinted\n" ++
    "      WHERE fingerprinted.file_id = files.id AND fingerprinted.provider_id = chosen.value\n" ++
    "        AND fingerprinted.provider IN ('acoustid', 'musicbrainz+acoustid')))";

pub const acoustid_submittable_page_sql =
    "SELECT files.id, tracks.id, chosen.value, tracks.title, tracks.artist, tracks.album, tracks.album_artist,\n" ++
    "       tracks.track_number, tracks.disc_number,\n" ++
    "       COALESCE((SELECT release_date FROM releases WHERE releases.id = tracks.release_id), ''),\n" ++
    "       files.duration_ms, files.codec, files.size_bytes,\n" ++
    "       (SELECT uri FROM locations WHERE locations.file_id = files.id AND locations.state = 'present'\n" ++
    "        ORDER BY locations.id LIMIT 1),\n" ++
    "       (SELECT payload FROM identification_proposals WHERE identification_proposals.file_id = files.id\n" ++
    "        AND identification_proposals.provider_id = chosen.value AND identification_proposals.state = ?6\n" ++
    "        ORDER BY identification_proposals.updated_at DESC LIMIT 1)\n" ++
    acoustid_submittable ++ "\nORDER BY chosen.file_id LIMIT ?2;";

pub const acoustid_submittable_count_sql = "SELECT count(*) " ++ acoustid_submittable ++ ";";
