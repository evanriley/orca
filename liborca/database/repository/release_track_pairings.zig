const std = @import("std");
const sqlite = @import("../sqlite.zig");
const metadata = @import("../../metadata/model.zig");
const max_page = @import("../columns.zig").max_page;
const track_file_ids_sql = @import("tracks.zig").track_file_ids_sql;
const OrcaMetadataRepository = @import("orca_metadata.zig").OrcaMetadataRepository;
const WriteLane = @import("write_lane.zig").WriteLane;

/// How a pairing was made. Stored by number in
/// `release_track_pairings.origin`.
pub const PairingOrigin = enum(u8) {
    /// A person confirmed the suggestion the alignment showed.
    confirmed_suggestion = 0,
    by_hand = 1,
};

pub const ReleaseTrackPairingInput = struct {
    release_id: i64,
    release_mbid: []const u8,
    track_id: i64,
    release_track_mbid: []const u8,
    origin: PairingOrigin,
};

/// A person's decision that a Track is one release track of a MusicBrainz
/// release.
pub const ReleaseTrackPairing = struct {
    release_id: i64,
    track_id: i64,
    release_mbid: []const u8,
    release_track_mbid: []const u8,
    /// The release track's recording when the pairing was made.
    recording_mbid: []const u8,
    origin: PairingOrigin,
    /// Unix seconds.
    created_at: i64,
    /// False when the release's snapshot no longer lists the release track;
    /// the alignment then ignores the pairing.
    in_snapshot: bool,
    /// The release track's place in the snapshot; null when not
    /// `in_snapshot`.
    disc: ?u32,
    position: ?u32,
};

const pairing_columns =
    "p.track_id, p.musicbrainz_release_id, p.release_track_id, p.recording_id, p.origin, p.created_at, t.disc, t.position, p.release_id";
const pairing_source =
    "FROM release_track_pairings p\n" ++
    "LEFT JOIN musicbrainz_release_tracks t\n" ++
    "    ON t.musicbrainz_release_id = p.musicbrainz_release_id AND t.release_track_id = p.release_track_id";
const pairing_order = "p.musicbrainz_release_id, t.disc IS NULL, t.disc, t.position, p.track_id";

fn readPairing(arena: std.mem.Allocator, statement: sqlite.Statement) !ReleaseTrackPairing {
    const listed = !statement.columnIsNull(6);
    return .{
        .release_id = statement.columnInt64(8),
        .track_id = statement.columnInt64(0),
        .release_mbid = try arena.dupe(u8, statement.columnText(1)),
        .release_track_mbid = try arena.dupe(u8, statement.columnText(2)),
        .recording_mbid = try arena.dupe(u8, statement.columnText(3)),
        .origin = std.enums.fromInt(PairingOrigin, statement.columnInt64(4)) orelse .by_hand,
        .created_at = statement.columnInt64(5),
        .in_snapshot = listed,
        .disc = if (listed) std.math.cast(u32, statement.columnInt64(6)) else null,
        .position = if (listed) std.math.cast(u32, statement.columnInt64(7)) else null,
    };
}

pub const ReleaseTrackPairings = struct {
    arena: std.heap.ArenaAllocator,
    /// Release MBID, then disc and position, unlisted release tracks last.
    items: []ReleaseTrackPairing,

    pub fn deinit(self: *ReleaseTrackPairings) void {
        self.arena.deinit();
    }
};

const still_paired =
    "paired_metadata_values.value = excluded.replaced_value AND excluded.replaced_provenance = ?4" ++
    " AND excluded.replaced_locked = 1";

const record_replaced_sql =
    \\INSERT INTO paired_metadata_values(file_id, field, value,
    \\    replaced_value, replaced_provenance, replaced_locked, replaced_written_at)
    \\SELECT ?1, ?2, ?3, current.value, current.provenance, current.locked, current.written_at
    \\FROM (SELECT 1) LEFT JOIN orca_metadata_values AS current ON current.file_id = ?1 AND current.field = ?2
    \\WHERE true
    \\ON CONFLICT(file_id, field) DO UPDATE SET
    \\    value = excluded.value,
    \\
++ "    replaced_value = CASE WHEN " ++ still_paired ++ " THEN replaced_value ELSE excluded.replaced_value END,\n" ++
    "    replaced_provenance = CASE WHEN " ++ still_paired ++ " THEN replaced_provenance ELSE excluded.replaced_provenance END,\n" ++
    "    replaced_locked = CASE WHEN " ++ still_paired ++ " THEN replaced_locked ELSE excluded.replaced_locked END,\n" ++
    "    replaced_written_at = CASE WHEN " ++ still_paired ++ " THEN replaced_written_at ELSE excluded.replaced_written_at END;";

pub const ReleaseTrackPairingRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Pairs the Track and sets the release track's recording ID and
    /// release-track ID as locked user values on every file of the Track, in
    /// one transaction, recording the values they replace. A Track has one
    /// pairing: an earlier one, on any release, is undone first. Returns the
    /// files written, caller-owned, for reprojection.
    pub fn pair(
        self: *ReleaseTrackPairingRepository,
        allocator: std.mem.Allocator,
        input: ReleaseTrackPairingInput,
    ) ![]i64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};

        if (!try self.trackOnRelease(input.track_id, input.release_id)) return error.TrackNotOnRelease;
        if (!try self.hasSnapshot(input.release_mbid)) return error.NoReleaseTracklist;
        var recording_buffer: [64]u8 = undefined;
        const recording = try self.snapshotRecording(input.release_mbid, input.release_track_mbid, &recording_buffer) orelse
            return error.UnknownReleaseTrack;
        {
            var statement = try self.db.prepare(
                \\SELECT 1 FROM release_track_pairings
                \\WHERE release_id=?1 AND musicbrainz_release_id=?2 AND release_track_id=?3 AND track_id<>?4;
            );
            defer statement.deinit();
            try statement.bindInt64(1, input.release_id);
            try statement.bindText(2, input.release_mbid);
            try statement.bindText(3, input.release_track_mbid);
            try statement.bindInt64(4, input.track_id);
            if (try statement.step() == .row) return error.ReleaseTrackAlreadyPaired;
        }

        const files = try self.trackFiles(allocator, input.track_id);
        errdefer allocator.free(files);
        if (files.len == 0) return error.TrackNotFound;

        if (try self.deletePairing(input.track_id, null)) try self.restoreFiles(files);
        {
            var statement = try self.db.prepare(
                \\INSERT INTO release_track_pairings(track_id, musicbrainz_release_id, release_id,
                \\    release_track_id, recording_id, origin, created_at)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, unixepoch());
            );
            defer statement.deinit();
            try statement.bindInt64(1, input.track_id);
            try statement.bindText(2, input.release_mbid);
            try statement.bindInt64(3, input.release_id);
            try statement.bindText(4, input.release_track_mbid);
            try statement.bindText(5, recording);
            try statement.bindInt64(6, @backingInt(input.origin));
            if (try statement.step() != .done) return error.SqlFailed;
        }
        var values: OrcaMetadataRepository = .{ .db = self.db, .write_lane = self.write_lane };
        var replaced = try self.db.prepare(record_replaced_sql);
        defer replaced.deinit();
        for (files) |file_id| for ([_]struct { metadata.Field, []const u8 }{
            .{ .musicbrainz_recording_id, recording },
            .{ .musicbrainz_release_track_id, input.release_track_mbid },
        }) |entry| {
            try replaced.reset();
            try replaced.bindInt64(1, file_id);
            try replaced.bindInt64(2, @backingInt(entry[0]));
            try replaced.bindText(3, entry[1]);
            try replaced.bindInt64(4, @backingInt(metadata.Provenance.user));
            if (try replaced.step() != .done) return error.SqlFailed;
            try values.upsertLocked(.{
                .file_id = file_id,
                .field = entry[0],
                .value = entry[1],
                .provenance = .user,
                .locked = true,
            });
        };
        try self.db.exec("COMMIT;");
        return files;
    }

    /// Removes the Track's pairing, which must be on the Release, and puts
    /// back on each of its files the values the pairing replaced, where the
    /// file still holds the pairing's value. Returns the Track's files,
    /// caller-owned, for reprojection.
    pub fn unpair(
        self: *ReleaseTrackPairingRepository,
        allocator: std.mem.Allocator,
        release_id: i64,
        track_id: i64,
    ) ![]i64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};

        if (!try self.deletePairing(track_id, release_id)) return error.TrackNotPaired;
        const files = try self.trackFiles(allocator, track_id);
        errdefer allocator.free(files);
        try self.restoreFiles(files);
        try self.db.exec("COMMIT;");
        return files;
    }

    /// Forgets that a pairing set the file's value for `field`, so a
    /// person's own edit of it is neither restored over by an unpair nor
    /// held back from AcoustID as pairing-set.
    pub fn forgetPairedValue(self: *ReleaseTrackPairingRepository, file_id: i64, field: metadata.Field) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare("DELETE FROM paired_metadata_values WHERE file_id=?1 AND field=?2;");
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, @backingInt(field));
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// The Release's pairings, on `release_mbid` only when given. Bounded by
    /// `max_page`.
    pub fn list(
        self: *const ReleaseTrackPairingRepository,
        allocator: std.mem.Allocator,
        release_id: i64,
        release_mbid: ?[]const u8,
    ) !ReleaseTrackPairings {
        var result: ReleaseTrackPairings = .{ .arena = .init(allocator), .items = &.{} };
        errdefer result.deinit();
        const arena = result.arena.allocator();
        var statement = try self.db.prepare(
            "SELECT " ++ pairing_columns ++ "\n" ++ pairing_source ++ "\n" ++
                "WHERE p.release_id=?1 AND (?2 IS NULL OR p.musicbrainz_release_id=?2)\n" ++
                "ORDER BY " ++ pairing_order ++ "\n" ++
                "LIMIT ?3;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        try statement.bindOptionalText(2, release_mbid);
        try statement.bindInt64(3, max_page);
        var items: std.ArrayList(ReleaseTrackPairing) = .empty;
        while (try statement.step() == .row) try items.append(arena, try readPairing(arena, statement));
        result.items = items.items;
        return result;
    }

    /// The pairings of the Releases a JSON array of Release IDs names, by
    /// Release ID, then as `list` orders them, at most `max_page` for each
    /// Release, allocated with `arena`. One statement, whatever the number
    /// of Releases.
    pub fn listMany(self: *const ReleaseTrackPairingRepository, arena: std.mem.Allocator, release_ids_json: []const u8) ![]ReleaseTrackPairing {
        var statement = try self.db.prepare(
            "SELECT " ++ pairing_columns ++ "\n" ++ pairing_source ++ "\n" ++
                "WHERE p.release_id IN (SELECT value FROM json_each(?1))\n" ++
                "ORDER BY p.release_id, " ++ pairing_order ++ ";",
        );
        defer statement.deinit();
        try statement.bindText(1, release_ids_json);
        var items: std.ArrayList(ReleaseTrackPairing) = .empty;
        var taken: usize = 0;
        while (try statement.step() == .row) {
            const pairing = try readPairing(arena, statement);
            const first_of_release = items.items.len == 0 or items.items[items.items.len - 1].release_id != pairing.release_id;
            taken = if (first_of_release) 1 else taken + 1;
            if (taken > max_page) continue;
            try items.append(arena, pairing);
        }
        return items.items;
    }

    fn deletePairing(self: *ReleaseTrackPairingRepository, track_id: i64, release_id: ?i64) !bool {
        var statement = try self.db.prepare(
            \\DELETE FROM release_track_pairings WHERE track_id=?1 AND (?2 IS NULL OR release_id=?2) RETURNING 1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        try statement.bindOptionalInt64(2, release_id);
        var deleted = false;
        while (try statement.step() == .row) deleted = true;
        return deleted;
    }

    fn restoreFiles(self: *ReleaseTrackPairingRepository, files: []const i64) !void {
        var reinstate = try self.db.prepare(
            \\UPDATE orca_metadata_values SET value=paired.replaced_value, provenance=paired.replaced_provenance,
            \\    locked=paired.replaced_locked, updated_at=unixepoch(),
            \\    written_at=CASE WHEN paired.replaced_value=orca_metadata_values.value THEN orca_metadata_values.written_at
            \\        WHEN orca_metadata_values.written_at IS NULL THEN paired.replaced_written_at END
            \\FROM paired_metadata_values AS paired
            \\WHERE orca_metadata_values.file_id=?1 AND paired.file_id=?1
            \\    AND paired.field=orca_metadata_values.field AND paired.value=orca_metadata_values.value
            \\    AND orca_metadata_values.provenance=?2 AND orca_metadata_values.locked=1
            \\    AND paired.replaced_value IS NOT NULL;
        );
        defer reinstate.deinit();
        var clear = try self.db.prepare(
            \\DELETE FROM orca_metadata_values
            \\WHERE file_id=?1 AND provenance=?2 AND locked=1 AND EXISTS (SELECT 1 FROM paired_metadata_values AS paired
            \\    WHERE paired.file_id=?1 AND paired.field=orca_metadata_values.field
            \\        AND paired.value=orca_metadata_values.value AND paired.replaced_value IS NULL);
        );
        defer clear.deinit();
        var forget = try self.db.prepare("DELETE FROM paired_metadata_values WHERE file_id=?1;");
        defer forget.deinit();
        for (files) |file_id| {
            for ([_]sqlite.Statement{ reinstate, clear }) |statement| {
                try statement.reset();
                try statement.bindInt64(1, file_id);
                try statement.bindInt64(2, @backingInt(metadata.Provenance.user));
                if (try statement.step() != .done) return error.SqlFailed;
            }
            try forget.reset();
            try forget.bindInt64(1, file_id);
            if (try forget.step() != .done) return error.SqlFailed;
        }
    }

    fn trackOnRelease(self: *const ReleaseTrackPairingRepository, track_id: i64, release_id: i64) !bool {
        var statement = try self.db.prepare("SELECT 1 FROM tracks WHERE id=?1 AND release_id=?2;");
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        try statement.bindInt64(2, release_id);
        return try statement.step() == .row;
    }

    fn hasSnapshot(self: *const ReleaseTrackPairingRepository, release_mbid: []const u8) !bool {
        var statement = try self.db.prepare("SELECT 1 FROM musicbrainz_releases WHERE musicbrainz_release_id=?1;");
        defer statement.deinit();
        try statement.bindText(1, release_mbid);
        return try statement.step() == .row;
    }

    fn snapshotRecording(
        self: *const ReleaseTrackPairingRepository,
        release_mbid: []const u8,
        release_track_mbid: []const u8,
        buffer: []u8,
    ) !?[]const u8 {
        var statement = try self.db.prepare(
            \\SELECT recording_id FROM musicbrainz_release_tracks
            \\WHERE musicbrainz_release_id=?1 AND release_track_id=?2 LIMIT 1;
        );
        defer statement.deinit();
        try statement.bindText(1, release_mbid);
        try statement.bindText(2, release_track_mbid);
        if (try statement.step() != .row) return null;
        const text = statement.columnText(0);
        if (text.len == 0 or text.len > buffer.len) return error.InvalidReleaseTracklist;
        @memcpy(buffer[0..text.len], text);
        return buffer[0..text.len];
    }

    fn trackFiles(self: *const ReleaseTrackPairingRepository, allocator: std.mem.Allocator, track_id: i64) ![]i64 {
        var statement = try self.db.prepare(track_file_ids_sql);
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        try statement.bindInt64(2, max_page);
        var ids: std.ArrayList(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (try statement.step() == .row) try ids.append(allocator, statement.columnInt64(0));
        return ids.toOwnedSlice(allocator);
    }
};
