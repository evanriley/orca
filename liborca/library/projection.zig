//! Turning observed files into a browsable library.
//!
//! `CLAUDE.md` states a locked law: *scanner observations never update Track
//! metadata*. This module is how that law and a populated `tracks` table
//! coexist. The scanner still writes only `files`, `locations` and
//! `observed_file_tags`. The projection is a separate pass that reads
//! `EffectiveMetadata` — observation plus Orca overrides under an explicit
//! resolution policy, with a user lock outranking everything — and writes
//! `artists`, `releases`, `recordings` and `tracks` from that. It is therefore
//! re-runnable after a user edit or a provider acceptance, not only after a
//! scan, which is the whole reason for the carve-out. See `docs/database.md`.
//!
//! ## Why a folder is the unit of work
//!
//! Whether a Release is a compilation cannot be decided one file at a time.
//! Rule 3 of the album-artist cascade — *every file sharing this album key in
//! this folder names the same artist* — is a statement about a set, so the
//! projection resolves a whole `(containing folder, album key)` group at once.
//! The folder is also what makes reprojection incremental and indexed: a scan
//! batch names a handful of folders, each folder is one range scan of the
//! `locations(volume_id, uri)` index, and a scan that changed nothing names no
//! folders and therefore does no work at all.

const std = @import("std");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/root.zig");
const storage = @import("../storage/root.zig");

/// Which files the projection should reconsider.
///
/// Both scopes expand to whole folders before anything is resolved, because a
/// group's answer depends on its siblings. `.files` is what a scan batch hands
/// over; `.all` is a full rebuild.
pub const Scope = union(enum) {
    all,
    files: []const i64,
};

pub const Result = struct {
    folders_visited: u64 = 0,
    groups_projected: u64 = 0,
    files_projected: u64 = 0,
    tracks_written: u64 = 0,
    releases_written: u64 = 0,
    recordings_created: u64 = 0,
    /// Releases this run decided were compilations, by whichever rule fired.
    compilations: u64 = 0,
    /// Files whose title came from the filename because the tags carried none.
    filename_titles: u64 = 0,
    /// Files given a synthetic position because they carried no track number.
    synthetic_positions: u64 = 0,
    /// Files re-seated because a different performance already held the track
    /// number they stated.
    displaced_positions: u64 = 0,
    /// Rows deleted because the files that backed them now project elsewhere.
    tracks_pruned: u64 = 0,
    releases_pruned: u64 = 0,
    artists_pruned: u64 = 0,
};

/// A Track position this run wrote, which pruning must leave alone.
const WrittenPosition = struct { release_id: i64, disc: i64, number: i64 };

fn containsPosition(written: []const WrittenPosition, position: WrittenPosition) bool {
    for (written) |candidate| if (std.meta.eql(candidate, position)) return true;
    return false;
}

/// A `(folder, album key)` group's resolved release identity.
const ReleaseIdentity = struct {
    key: []const u8,
    title: []const u8,
    album_artist: []const u8,
    album_artist_mbid: ?[]const u8,
    release_date: ?[]const u8,
    musicbrainz_release_id: ?[]const u8,
    is_compilation: bool,
    disc_count: i64,
};

/// One file as the projection sees it: effective metadata, not observation.
const Entry = struct {
    file_id: i64,
    uri: []const u8,
    audio_format: u8,
    bit_depth: ?i64,
    sample_rate: ?i64,
    duration_ms: ?i64,
    recording_id: ?i64,
    location_present: bool,
    title: []const u8,
    artist: []const u8,
    artist_mbid: ?[]const u8,
    album: []const u8,
    album_key: []const u8,
    album_artist: ?[]const u8,
    album_artist_mbid: ?[]const u8,
    track_number: ?i64,
    disc_number: ?i64,
    date: ?[]const u8,
    compilation: ?bool,
    musicbrainz_release_id: ?[]const u8,
    musicbrainz_recording_id: ?[]const u8,
    /// Assigned during position resolution; `synthetic` records whether the
    /// file supplied it or the projection invented it.
    position: i64 = 0,
    synthetic: bool = false,
    /// Whether the file's stated track number was already held by a different
    /// performance and had to be re-seated.
    displaced: bool = false,
    /// Whether `title` was taken from the filename rather than the tags.
    title_from_filename: bool = false,
};

const ExtraOverrides = struct {
    track_number: ?metadata.Value = null,
    album_artist: ?metadata.Value = null,
    disc_number: ?metadata.Value = null,
    date: ?metadata.Value = null,
    compilation: ?metadata.Value = null,
};

fn resolvedText(observed: ?[]const u8, orca: ?metadata.Value, policy: metadata.ResolutionPolicy) ?[]const u8 {
    const observed_value: ?metadata.Value = if (observed) |text|
        .{ .text = text, .provenance = .observed_file }
    else
        null;
    const chosen = metadata.resolveValue(observed_value, orca, policy) orelse return null;
    return chosen.text;
}

fn resolvedNumber(observed: ?i64, orca: ?metadata.Value, policy: metadata.ResolutionPolicy) ?i64 {
    var buffer: [24]u8 = undefined;
    const observed_text = if (observed) |number|
        std.fmt.bufPrint(&buffer, "{d}", .{number}) catch unreachable
    else
        null;
    const text = resolvedText(observed_text, orca, policy) orelse return null;
    return std.fmt.parseInt(i64, text, 10) catch observed;
}

fn boolText(value: ?bool) ?[]const u8 {
    const flag = value orelse return null;
    return if (flag) "1" else "0";
}

/// A resolved Track: one position on a Release, and the files that encode it.
const Position = struct {
    disc: i64,
    number: i64,
    entries: std.ArrayList(usize) = .empty,
};

const Folder = struct {
    volume_id: i64,
    path: []const u8,
};

pub const Projection = struct {
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    /// Explicit, per `docs/metadata.md`: the projection resolves under a stated
    /// policy rather than an implied one. A user lock outranks it either way.
    policy: metadata.ResolutionPolicy = .prefer_file,

    /// Resolve every affected group and write the Tracks it implies.
    ///
    /// One transaction per folder: bounded, and small enough that a UI thread
    /// reading the library never waits long on the write lane.
    pub fn run(self: *Projection, scope: Scope) !Result {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const folders = try self.collectFolders(arena.allocator(), scope);

        var result: Result = .{};
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        for (folders) |folder| {
            _ = scratch.reset(.retain_capacity);
            try self.projectFolder(scratch.allocator(), folder, &result);
            result.folders_visited += 1;
        }
        return result;
    }

    /// Deletes the Tracks this folder's files used to back and no longer do.
    ///
    /// A Track is a position on a Release, so a file whose tags now put it on
    /// another Release or position produces a new row, and the row it backed
    /// before would otherwise stay listed with nothing behind it. Only rows
    /// whose preferred file is in this folder are candidates, and only if this
    /// run did not just write their position. Releases and Artists those rows
    /// referenced are then deleted if nothing else still references them.
    /// Everything deleted here is derived, and the next projection rebuilds it.
    fn pruneStale(
        self: *Projection,
        allocator: std.mem.Allocator,
        entries: []const Entry,
        written: []const WrittenPosition,
        result: *Result,
    ) !void {
        const db = self.library.database;
        var candidates = try db.prepare(
            \\SELECT id, release_id, COALESCE(disc_number, 1), track_number, artist_id
            \\FROM tracks WHERE preferred_file_id = ?1;
        );
        defer candidates.deinit();
        var delete_track = try db.prepare("DELETE FROM tracks WHERE id = ?1;");
        defer delete_track.deinit();

        var releases: std.ArrayList(i64) = .empty;
        var artists: std.ArrayList(i64) = .empty;
        for (entries) |entry| {
            try candidates.bindInt64(1, entry.file_id);
            var stale: std.ArrayList(i64) = .empty;
            while (try candidates.step() == .row) {
                const position: WrittenPosition = .{
                    .release_id = candidates.columnInt64(1),
                    .disc = candidates.columnInt64(2),
                    .number = candidates.columnInt64(3),
                };
                if (containsPosition(written, position)) continue;
                try stale.append(allocator, candidates.columnInt64(0));
                try releases.append(allocator, position.release_id);
                if (!candidates.columnIsNull(4)) try artists.append(allocator, candidates.columnInt64(4));
            }
            try candidates.reset();
            for (stale.items) |track_id| {
                try delete_track.bindInt64(1, track_id);
                if (try delete_track.step() != .done) return error.SqlFailed;
                try delete_track.reset();
                result.tracks_pruned += 1;
            }
        }
        if (releases.items.len == 0) return;

        var release_in_use = try db.prepare("SELECT 1 FROM tracks WHERE release_id = ?1 LIMIT 1;");
        defer release_in_use.deinit();
        var release_artist = try db.prepare("SELECT album_artist_id FROM releases WHERE id = ?1;");
        defer release_artist.deinit();
        var delete_release = try db.prepare("DELETE FROM releases WHERE id = ?1;");
        defer delete_release.deinit();
        for (releases.items) |release_id| {
            try release_in_use.bindInt64(1, release_id);
            const in_use = try release_in_use.step() == .row;
            try release_in_use.reset();
            if (in_use) continue;
            try release_artist.bindInt64(1, release_id);
            const found = try release_artist.step() == .row;
            if (found and !release_artist.columnIsNull(0)) try artists.append(allocator, release_artist.columnInt64(0));
            try release_artist.reset();
            if (!found) continue;
            try delete_release.bindInt64(1, release_id);
            if (try delete_release.step() != .done) return error.SqlFailed;
            try delete_release.reset();
            result.releases_pruned += 1;
        }

        var artist_in_use = try db.prepare(
            \\SELECT 1 WHERE EXISTS (SELECT 1 FROM tracks WHERE artist_id = ?1)
            \\   OR EXISTS (SELECT 1 FROM releases WHERE album_artist_id = ?1);
        );
        defer artist_in_use.deinit();
        var delete_artist = try db.prepare("DELETE FROM artists WHERE id = ?1;");
        defer delete_artist.deinit();
        for (artists.items) |artist_id| {
            try artist_in_use.bindInt64(1, artist_id);
            const in_use = try artist_in_use.step() == .row;
            try artist_in_use.reset();
            if (in_use) continue;
            try delete_artist.bindInt64(1, artist_id);
            if (try delete_artist.step() != .done) return error.SqlFailed;
            try delete_artist.reset();
            if (db.changes() == 1) result.artists_pruned += 1;
        }
    }

    /// Orca values for the fields `metadata.resolve` does not cover, resolved
    /// under the same rule: a locked value wins, the policy decides the rest.
    fn applyExtraOverrides(self: *const Projection, entry: *Entry, extra: ExtraOverrides) void {
        entry.album_artist = resolvedText(entry.album_artist, extra.album_artist, self.policy);
        entry.date = resolvedText(entry.date, extra.date, self.policy);
        entry.track_number = resolvedNumber(entry.track_number, extra.track_number, self.policy);
        entry.disc_number = resolvedNumber(entry.disc_number, extra.disc_number, self.policy);
        if (resolvedText(boolText(entry.compilation), extra.compilation, self.policy)) |text|
            entry.compilation = std.mem.eql(u8, text, "1");
    }

    /// The folders the scope touches, deduplicated and ordered.
    ///
    /// A changed file drags its whole folder in, because its siblings are what
    /// decide the group's album artist.
    ///
    /// Missing locations are deliberately *included*. An unmounted drive must
    /// not empty a library: the Track still exists, and whether its bytes are
    /// reachable right now is what `has_playable_file` and `playableLocation`
    /// answer. Excluding them would also make a folder that went missing
    /// wholesale un-reprojectable, freezing whatever the last run left behind.
    fn collectFolders(
        self: *Projection,
        allocator: std.mem.Allocator,
        scope: Scope,
    ) ![]Folder {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var folders: std.ArrayList(Folder) = .empty;
        switch (scope) {
            .all => {
                var statement = try self.library.database.prepare(
                    \\SELECT DISTINCT volume_id, rtrim(uri, replace(uri, '/', ''))
                    \\FROM locations ORDER BY 1, 2;
                );
                defer statement.deinit();
                while (try statement.step() == .row) try appendFolder(
                    allocator,
                    &folders,
                    &seen,
                    statement.columnInt64(0),
                    statement.columnText(1),
                );
            },
            .files => |ids| {
                var statement = try self.library.database.prepare(
                    \\SELECT volume_id, rtrim(uri, replace(uri, '/', ''))
                    \\FROM locations WHERE file_id = ?1;
                );
                defer statement.deinit();
                for (ids) |file_id| {
                    try statement.bindInt64(1, file_id);
                    while (try statement.step() == .row) try appendFolder(
                        allocator,
                        &folders,
                        &seen,
                        statement.columnInt64(0),
                        statement.columnText(1),
                    );
                    try statement.reset();
                }
            },
        }
        return folders.toOwnedSlice(allocator);
    }

    fn projectFolder(
        self: *Projection,
        allocator: std.mem.Allocator,
        folder: Folder,
        result: *Result,
    ) !void {
        const entries = try self.loadFolder(allocator, folder);
        if (entries.len == 0) return;
        std.mem.sort(Entry, entries, {}, lessByGroup);

        self.library.write_lane.acquire();
        defer self.library.write_lane.release();
        try self.library.database.exec("BEGIN IMMEDIATE;");
        errdefer self.library.database.exec("ROLLBACK;") catch {};

        var written: std.ArrayList(WrittenPosition) = .empty;
        var start: usize = 0;
        while (start < entries.len) {
            var end = start + 1;
            while (end < entries.len and
                std.mem.eql(u8, entries[end].album_key, entries[start].album_key)) end += 1;
            try self.projectGroup(allocator, folder, entries[start..end], &written, result);
            result.groups_projected += 1;
            start = end;
        }
        try self.pruneStale(allocator, entries, written.items, result);
        try self.library.database.exec("COMMIT;");
    }

    /// Every file in one folder, as effective metadata.
    fn loadFolder(
        self: *Projection,
        allocator: std.mem.Allocator,
        folder: Folder,
    ) ![]Entry {
        // The `rtrim` equality is the correctness predicate; the range is what
        // makes `locations(volume_id, uri)` do the work. `/` is 0x2F, so a
        // folder's subtree ends exactly where its trailing slash becomes `0`.
        var statement = try self.library.database.prepare(
            \\SELECT l.file_id, l.uri, l.state, f.audio_format, f.bit_depth,
            \\       f.sample_rate, f.duration_ms, f.recording_id,
            \\       t.title, t.artist, t.album, t.album_artist,
            \\       t.track_number, t.disc_number, t.date, t.compilation,
            \\       t.musicbrainz_release_id, t.musicbrainz_recording_id,
            \\       t.musicbrainz_artist_id, t.musicbrainz_album_artist_id
            \\FROM locations l
            \\JOIN files f ON f.id = l.file_id
            \\LEFT JOIN observed_file_tags t ON t.file_id = l.file_id
            \\WHERE l.volume_id = ?1 AND l.uri >= ?2 AND l.uri < ?3
            \\  AND rtrim(l.uri, replace(l.uri, '/', '')) = ?2
            \\ORDER BY l.uri;
        );
        defer statement.deinit();
        try statement.bindInt64(1, folder.volume_id);
        try statement.bindText(2, folder.path);
        try statement.bindText(3, try upperBound(allocator, folder.path));

        var overrides = try self.library.database.prepare(
            \\SELECT field, value, provenance, locked
            \\FROM orca_metadata_values WHERE file_id = ?1;
        );
        defer overrides.deinit();

        var entries: std.ArrayList(Entry) = .empty;
        while (try statement.step() == .row) {
            const file_id = statement.columnInt64(0);
            const uri = try allocator.dupe(u8, statement.columnText(1));
            const observed: metadata.ObservedFileMetadata = .{
                .title = observedValue(try dupeNullable(allocator, statement, 8)),
                .artist = observedValue(try dupeNullable(allocator, statement, 9)),
                .album = observedValue(try dupeNullable(allocator, statement, 10)),
            };
            var orca: metadata.OrcaMetadata = .{};
            var extra: ExtraOverrides = .{};
            try overrides.bindInt64(1, file_id);
            while (try overrides.step() == .row) {
                const field = std.enums.fromInt(
                    metadata.Field,
                    overrides.columnInt64(0),
                ) orelse continue;
                const value: metadata.Value = .{
                    .text = try allocator.dupe(u8, overrides.columnText(1)),
                    .provenance = std.enums.fromInt(
                        metadata.Provenance,
                        overrides.columnInt64(2),
                    ) orelse .user,
                    .locked = overrides.columnInt64(3) != 0,
                };
                switch (field) {
                    .title => orca.title = value,
                    .artist => orca.artist = value,
                    .album => orca.album = value,
                    .track_number => extra.track_number = value,
                    .album_artist => extra.album_artist = value,
                    .disc_number => extra.disc_number = value,
                    .date => extra.date = value,
                    .compilation => extra.compilation = value,
                }
            }
            try overrides.reset();

            const effective = metadata.resolve(observed, orca, self.policy);
            const album = if (effective.album) |value| value.text else "";
            var entry: Entry = .{
                .file_id = file_id,
                .uri = uri,
                .audio_format = std.math.cast(u8, statement.columnInt64(3)) orelse 0,
                .bit_depth = optionalInt64(statement, 4),
                .sample_rate = optionalInt64(statement, 5),
                .duration_ms = optionalInt64(statement, 6),
                .recording_id = optionalInt64(statement, 7),
                .location_present = std.mem.eql(u8, statement.columnText(2), "present"),
                .title = if (effective.title) |value| value.text else "",
                .artist = if (effective.artist) |value| value.text else "",
                .artist_mbid = try dupeNullable(allocator, statement, 18),
                .album = album,
                .album_key = try normalizeKey(allocator, album),
                .album_artist = try dupeNullable(allocator, statement, 11),
                .album_artist_mbid = try dupeNullable(allocator, statement, 19),
                .track_number = optionalInt64(statement, 12),
                .disc_number = optionalInt64(statement, 13),
                .date = try dupeNullable(allocator, statement, 14),
                .compilation = if (statement.columnIsNull(15))
                    null
                else
                    statement.columnInt64(15) != 0,
                .musicbrainz_release_id = try dupeNullable(allocator, statement, 16),
                .musicbrainz_recording_id = try dupeNullable(allocator, statement, 17),
            };
            self.applyExtraOverrides(&entry, extra);
            // A blank row helps nobody find their music: 42 files in the
            // reference library carry no title and the filename carries it.
            if (entry.title.len == 0) {
                entry.title = filenameStem(uri);
                entry.title_from_filename = true;
            }
            try entries.append(allocator, entry);
        }
        return entries.toOwnedSlice(allocator);
    }

    /// Resolve and write one `(folder, album key)` group.
    fn projectGroup(
        self: *Projection,
        allocator: std.mem.Allocator,
        folder: Folder,
        entries: []Entry,
        written: *std.ArrayList(WrittenPosition),
        result: *Result,
    ) !void {
        const identity = try self.resolveRelease(allocator, folder, entries);
        // The album artist is resolved *before* the release, because the
        // release now carries the Artist row it is filed under rather than
        // only the name it was tagged with.
        const album_artist_id = try self.ensureArtist(
            allocator,
            identity.album_artist,
            identity.album_artist_mbid,
        );
        const release_id = try self.library.releases.upsertLocked(.{
            .release_key = identity.key,
            .title = identity.title,
            .album_artist = identity.album_artist,
            .album_artist_id = album_artist_id,
            .release_date = identity.release_date,
            .is_compilation = identity.is_compilation,
            .disc_count = identity.disc_count,
            .musicbrainz_release_id = identity.musicbrainz_release_id,
        });
        result.releases_written += 1;
        if (identity.is_compilation) result.compilations += 1;

        try assignPositions(allocator, entries);
        const positions = try groupByPosition(allocator, entries);

        var tracks: std.ArrayList(database.TrackInput) = .empty;
        for (positions) |position| {
            const members = position.entries.items;
            const lead = &entries[members[0]];
            const artist_id = try self.ensureArtist(allocator, lead.artist, lead.artist_mbid);

            const recording_id = try self.resolveRecording(allocator, entries, members);
            const preferred = &entries[bestEncoding(entries, members)];
            try written.append(allocator, .{
                .release_id = release_id,
                .disc = position.disc,
                .number = position.number,
            });
            try tracks.append(allocator, .{
                .recording_id = recording_id,
                .release_id = release_id,
                .artist_id = artist_id,
                .title = lead.title,
                .artist = lead.artist,
                .album = identity.title,
                .album_artist = identity.album_artist,
                .duration_ms = preferred.duration_ms,
                .track_number = position.number,
                .disc_number = position.disc,
                .preferred_file_id = preferred.file_id,
            });

            for (members) |index| {
                const entry = &entries[index];
                try self.library.files.setRecordingLocked(entry.file_id, recording_id);
                if (entry.synthetic) {
                    result.synthetic_positions += 1;
                    try self.library.health_issues.recordLocked(entry.file_id, .{
                        .kind = .missing_track_number,
                        .severity = .information,
                        .details = "track number is missing",
                    });
                } else {
                    try self.library.health_issues.clearLocked(
                        entry.file_id,
                        .missing_track_number,
                    );
                }
                if (entry.displaced) {
                    result.displaced_positions += 1;
                    const details = try std.fmt.allocPrint(
                        allocator,
                        "track {?d} on disc {d} is claimed by another recording; " ++
                            "listed at {d} instead",
                        .{ entry.track_number, position.disc, entry.position },
                    );
                    try self.library.health_issues.recordLocked(entry.file_id, .{
                        .kind = .technical_anomaly,
                        .severity = .warning,
                        .details = details,
                    });
                }
                if (entry.title_from_filename) result.filename_titles += 1;
                result.files_projected += 1;
            }
        }
        try self.library.tracks.upsertTracksLocked(tracks.items);
        result.tracks_written += @intCast(tracks.items.len);
    }

    /// Resolve one Artist row and hand back its id.
    ///
    /// Both the key and the sort key come from `database/text_key.zig`, which
    /// is the same code migration 9 registers as a SQLite function to backfill
    /// an existing library. A fresh scan and a migrated database therefore
    /// produce identical `artist_id` values, which `projection.zig` asserts
    /// directly.
    fn ensureArtist(
        self: *Projection,
        allocator: std.mem.Allocator,
        name: []const u8,
        musicbrainz_artist_id: ?[]const u8,
    ) !?i64 {
        return self.library.artists.ensureLocked(.{
            .key = try normalizeKey(allocator, name),
            .name = name,
            .sort_name = try text_key.sortKey(allocator, name),
            .musicbrainz_artist_id = musicbrainz_artist_id,
        });
    }

    /// The album-artist cascade, in the order `docs/design` fixes it.
    ///
    /// The order matters more than any single rule: an explicit tag is a
    /// statement by whoever tagged the files and is never overridden by a
    /// guess, and the folder-consensus rule only ever runs when the files
    /// themselves said nothing.
    fn resolveRelease(
        self: *Projection,
        allocator: std.mem.Allocator,
        folder: Folder,
        entries: []const Entry,
    ) !ReleaseIdentity {
        _ = self;
        var album_artist: []const u8 = "";
        var album_artist_mbid: ?[]const u8 = null;
        var is_compilation = false;

        // 1. An explicit album-artist tag wins outright.
        for (entries) |entry| {
            const tagged = entry.album_artist orelse continue;
            if (tagged.len == 0) continue;
            album_artist = tagged;
            album_artist_mbid = entry.album_artist_mbid;
            break;
        }
        if (album_artist.len == 0) {
            // 2. A compilation flag is the files stating there is no one artist.
            var flagged = false;
            for (entries) |entry| {
                if (entry.compilation orelse false) flagged = true;
            }
            if (flagged) {
                album_artist = various_artists;
                is_compilation = true;
            } else if (soleArtist(entries)) |sole| {
                // 3. Every file in this folder sharing this album names the
                //    same artist, so the album is that artist's.
                album_artist = sole;
                for (entries) |entry| {
                    if (entry.artist_mbid) |mbid| {
                        album_artist_mbid = mbid;
                        break;
                    }
                }
            } else {
                // 4. Several artists and nothing said otherwise.
                album_artist = various_artists;
                is_compilation = true;
            }
        } else {
            for (entries) |entry| {
                if (entry.compilation orelse false) is_compilation = true;
            }
        }

        const release_mbid = consensus(entries, mbReleaseId);
        const release_date = consensus(entries, releaseDate);
        var disc_count: i64 = 1;
        for (entries) |entry| disc_count = @max(disc_count, entry.disc_number orelse 1);

        // `normalize(album) 0x1f normalize(album_artist) 0x1f (mbid ?? year)`.
        // The MusicBrainz release id is the strongest key available and is
        // taken whenever the group agrees on one; the year only disambiguates
        // same-titled albums by the same artist when it does not.
        var key: std.ArrayList(u8) = .empty;
        try key.appendSlice(allocator, entries[0].album_key);
        try key.append(allocator, 0x1f);
        try key.appendSlice(allocator, try normalizeKey(allocator, album_artist));
        try key.append(allocator, 0x1f);
        if (release_mbid) |mbid| {
            try key.appendSlice(allocator, mbid);
        } else if (release_date) |date| {
            try key.appendSlice(allocator, year(date));
        }
        // An untitled album is not an album: without a title, `album_artist`
        // alone would fuse every stray file by one artist into a single
        // release, and their track numbers would then overwrite each other.
        // The folder is the only remaining evidence of what belongs together.
        if (entries[0].album_key.len == 0) {
            try key.append(allocator, 0x1f);
            try key.appendSlice(allocator, folder.path);
        }
        return .{
            .key = try key.toOwnedSlice(allocator),
            .title = entries[0].album,
            .album_artist = album_artist,
            .album_artist_mbid = album_artist_mbid,
            .release_date = release_date,
            .musicbrainz_release_id = release_mbid,
            .is_compilation = is_compilation,
            .disc_count = disc_count,
        };
    }

    /// The performance a Track presents.
    ///
    /// A FLAC and an MP3 of the same song are two encodings of one recording,
    /// so every file at one position shares a recording id. Existing
    /// `files.recording_id` values are reused rather than replaced, which is
    /// what keeps a reprojection from orphaning analysis attached to them.
    fn resolveRecording(
        self: *Projection,
        allocator: std.mem.Allocator,
        entries: []const Entry,
        members: []const usize,
    ) !i64 {
        _ = allocator;
        for (members) |index| {
            if (entries[index].recording_id) |existing| {
                try self.library.recordings.updateLocked(existing, .{
                    .title = entries[index].title,
                    .duration_ms = entries[index].duration_ms,
                });
                return existing;
            }
        }
        const lead = entries[members[0]];
        return self.library.recordings.insertLocked(.{
            .title = lead.title,
            .duration_ms = lead.duration_ms,
        });
    }
};

pub const various_artists = "Various Artists";

/// Whether every file in the group names the same artist. Files with no artist
/// abstain rather than voting for "no artist": 33 files in the reference
/// library are untagged, and they must not turn an artist album into a
/// compilation on their own.
fn soleArtist(entries: []const Entry) ?[]const u8 {
    var candidate: ?[]const u8 = null;
    var candidate_key: [key_buffer_size]u8 = undefined;
    var candidate_length: usize = 0;
    var buffer: [key_buffer_size]u8 = undefined;
    for (entries) |entry| {
        if (entry.artist.len == 0) continue;
        const key = normalizeInto(&buffer, entry.artist);
        if (candidate == null) {
            candidate = entry.artist;
            @memcpy(candidate_key[0..key.len], key);
            candidate_length = key.len;
            continue;
        }
        if (!std.mem.eql(u8, key, candidate_key[0..candidate_length])) return null;
    }
    return candidate;
}

const key_buffer_size = text_key.key_buffer_size;

/// The group's answer for a field several files may or may not carry: the most
/// common non-null value, ties broken lexicographically so two runs over the
/// same data agree.
fn consensus(
    entries: []const Entry,
    comptime field: fn (Entry) ?[]const u8,
) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_count: usize = 0;
    for (entries) |candidate_entry| {
        const candidate = field(candidate_entry) orelse continue;
        if (candidate.len == 0) continue;
        var count: usize = 0;
        for (entries) |other| {
            const value = field(other) orelse continue;
            if (std.mem.eql(u8, value, candidate)) count += 1;
        }
        const better = count > best_count or
            (count == best_count and best != null and
                std.mem.order(u8, candidate, best.?) == .lt);
        if (best == null or better) {
            best = candidate;
            best_count = count;
        }
    }
    return best;
}

fn mbReleaseId(entry: Entry) ?[]const u8 {
    return entry.musicbrainz_release_id;
}

fn releaseDate(entry: Entry) ?[]const u8 {
    return entry.date;
}

fn year(date: []const u8) []const u8 {
    return if (date.len >= 4) date[0..4] else date;
}

/// Give every file a position on its disc.
///
/// Three things can happen, and all three must leave the file in the library:
///
/// - The file states a track number nothing else claims, and keeps it.
/// - The file states a track number another *encoding of the same performance*
///   already claims — a FLAC and an MP3 of one song. They share the position
///   and become one Track with two files, which is the point of the model.
/// - Otherwise the file has no number, or its number is already taken by a
///   different performance. Both are defects in the tags, and both are common:
///   the reference library contains 108 files with no track number, an album
///   whose two soundtracks are tagged with one title, and two files that both
///   claim track 4. Neither case may drop a song, and neither may leave the
///   position null — a null position has nothing to upsert on, so reprojecting
///   would duplicate the row forever. The file takes the next free number on
///   its disc in filename order and the fabrication is raised as a health issue
///   rather than applied silently.
fn assignPositions(allocator: std.mem.Allocator, entries: []Entry) !void {
    // Every stated number is reserved before anything is invented, so an
    // invented position can never displace one a file actually claimed.
    var used: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (entries) |entry| {
        if (entry.track_number) |number| try used.put(
            allocator,
            positionKey(entry.disc_number orelse 1, number),
            {},
        );
    }
    var occupants: std.ArrayList(Occupant) = .empty;
    var next: std.AutoHashMapUnmanaged(i64, i64) = .empty;
    // Entries arrive sorted by (album key, uri), so filename order is already
    // the order of the slice and every decision below is reproducible.
    for (entries) |*entry| {
        const disc = entry.disc_number orelse 1;
        const identity = try performanceKey(allocator, entry.*);
        if (entry.track_number) |number| {
            if (occupantOf(occupants.items, disc, number)) |holder| {
                if (std.mem.eql(u8, holder, identity)) {
                    entry.position = number;
                    continue;
                }
                entry.displaced = true;
            } else {
                try occupants.append(allocator, .{
                    .disc = disc,
                    .number = number,
                    .identity = identity,
                });
                entry.position = number;
                continue;
            }
        }
        var candidate = next.get(disc) orelse 1;
        while (used.contains(positionKey(disc, candidate))) candidate += 1;
        try used.put(allocator, positionKey(disc, candidate), {});
        try next.put(allocator, disc, candidate + 1);
        try occupants.append(allocator, .{
            .disc = disc,
            .number = candidate,
            .identity = identity,
        });
        entry.position = candidate;
        entry.synthetic = !entry.displaced;
    }
}

/// What makes two files encodings of one performance rather than two songs.
const Occupant = struct {
    disc: i64,
    number: i64,
    identity: []const u8,
};

fn occupantOf(occupants: []const Occupant, disc: i64, number: i64) ?[]const u8 {
    for (occupants) |occupant| {
        if (occupant.disc == disc and occupant.number == number) return occupant.identity;
    }
    return null;
}

/// A MusicBrainz recording id when the files carry one, and the folded title
/// otherwise. Deliberately not the file's format or size: the whole question
/// being asked is whether two differently encoded files are the same song.
fn performanceKey(allocator: std.mem.Allocator, entry: Entry) ![]const u8 {
    if (entry.musicbrainz_recording_id) |mbid| if (mbid.len != 0) return mbid;
    return normalizeKey(allocator, entry.title);
}

fn positionKey(disc: i64, number: i64) u64 {
    return (@as(u64, @bitCast(disc)) << 32) ^ @as(u64, @bitCast(number));
}

/// Collapse the group's files onto the positions they occupy. Two encodings of
/// one song sit at one position and become one Track.
fn groupByPosition(allocator: std.mem.Allocator, entries: []const Entry) ![]Position {
    var positions: std.ArrayList(Position) = .empty;
    for (entries, 0..) |entry, index| {
        const disc = entry.disc_number orelse 1;
        const existing = for (positions.items) |*position| {
            if (position.disc == disc and position.number == entry.position) break position;
        } else null;
        if (existing) |position| {
            try position.entries.append(allocator, index);
            continue;
        }
        var position: Position = .{ .disc = disc, .number = entry.position };
        try position.entries.append(allocator, index);
        try positions.append(allocator, position);
    }
    return positions.toOwnedSlice(allocator);
}

/// Which encoding playback should reach for, cached on the Track so starting
/// one is a single indexed lookup rather than a three-way join: the most
/// information first (bit depth, then sample rate), then a location a scan has
/// actually confirmed, and only then the container as a tiebreak.
fn bestEncoding(entries: []const Entry, members: []const usize) usize {
    var best = members[0];
    for (members[1..]) |candidate| {
        if (preferredOver(entries[candidate], entries[best])) best = candidate;
    }
    return best;
}

/// A missing property is *unknown* — never zero, and never best.
///
/// Unknown loses to any known value: a file the scanner could not open states
/// nothing about itself, and playback should reach for the encoding that does.
/// Two unknowns are equally uninformative and defer to the next property. And
/// nothing is coerced to a number, so a genuine zero in the column ranks as the
/// zero it is rather than masquerading as unknown. This is what makes a 16-bit
/// FLAC outrank an MPEG file that has no sample width to state: a real property
/// decides it, not the container's name.
///
/// Returns null when the two are indistinguishable on this property.
fn betterProperty(candidate: ?i64, incumbent: ?i64) ?bool {
    if (candidate) |known_candidate| {
        const known_incumbent = incumbent orelse return true;
        if (known_candidate == known_incumbent) return null;
        return known_candidate > known_incumbent;
    }
    return if (incumbent == null) null else false;
}

fn preferredOver(candidate: Entry, incumbent: Entry) bool {
    // Reachability outranks fidelity, because this field is what playback
    // resolves through. A 24-bit copy on an unplugged drive is not a better
    // encoding to play than a 16-bit copy that is actually there — it is no
    // encoding at all, and preferring it makes the Track unplayable while a
    // usable file sits beside it. The choice is self-correcting: projection
    // recomputes this cache, so remounting the drive restores the better
    // encoding on the next scan. `has_playable_file` still answers
    // reachability for hosts; this decides what playback actually opens.
    if (candidate.location_present != incumbent.location_present)
        return candidate.location_present;
    if (betterProperty(candidate.bit_depth, incumbent.bit_depth)) |better| return better;
    if (betterProperty(candidate.sample_rate, incumbent.sample_rate)) |better| return better;
    const candidate_rank = formatRank(candidate.audio_format);
    const incumbent_rank = formatRank(incumbent.audio_format);
    if (candidate_rank != incumbent_rank) return candidate_rank < incumbent_rank;
    return candidate.file_id < incumbent.file_id;
}

/// Lower is better. This is the last word, not the first: it separates two
/// encodings whose declared properties are identical — two 16/44100 files in
/// different containers — and short of decoding both, nothing else can.
fn formatRank(audio_format: u8) u8 {
    const known = std.enums.fromInt(storage.AudioFormat, audio_format) orelse return 10;
    return switch (known) {
        .flac => 0,
        .wavpack => 1,
        .wav => 2,
        .aiff => 3,
        .qoa => 4,
        .mp4 => 5,
        // The same codec as MP4's, without the edit list that makes it gapless.
        .aac => 6,
        .opus => 7,
        .vorbis => 8,
        .mp3 => 9,
    };
}

fn lessByGroup(_: void, a: Entry, b: Entry) bool {
    return switch (std.mem.order(u8, a.album_key, b.album_key)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.uri, b.uri) == .lt,
    };
}

fn appendFolder(
    allocator: std.mem.Allocator,
    folders: *std.ArrayList(Folder),
    seen: *std.StringHashMapUnmanaged(void),
    volume_id: i64,
    path: []const u8,
) !void {
    var buffer: [4096]u8 = undefined;
    const stamped = std.fmt.bufPrint(&buffer, "{d}\x1f{s}", .{ volume_id, path }) catch {
        // A path longer than the buffer is projected rather than skipped; the
        // duplicate check simply does not apply to it.
        try folders.append(allocator, .{
            .volume_id = volume_id,
            .path = try allocator.dupe(u8, path),
        });
        return;
    };
    if (seen.contains(stamped)) return;
    try seen.put(allocator, try allocator.dupe(u8, stamped), {});
    try folders.append(allocator, .{
        .volume_id = volume_id,
        .path = try allocator.dupe(u8, path),
    });
}

/// The exclusive end of a folder's subtree in `uri` order. A folder path ends
/// in `/` (0x2f), so replacing that byte with `0` (0x30) bounds it exactly.
fn upperBound(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len == 0) return "\u{10ffff}";
    const bound = try allocator.dupe(u8, path);
    bound[bound.len - 1] += 1;
    return bound;
}

fn filenameStem(uri: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, uri, '/')) |slash|
        uri[slash + 1 ..]
    else
        uri;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return if (dot == 0) base else base[0..dot];
}

fn observedValue(text: ?[]const u8) ?metadata.Value {
    const present = text orelse return null;
    if (present.len == 0) return null;
    return .{ .text = present, .provenance = .observed_file };
}

fn dupeNullable(
    allocator: std.mem.Allocator,
    statement: database.sqlite.Statement,
    column: c_int,
) !?[]const u8 {
    if (statement.columnIsNull(column)) return null;
    return try allocator.dupe(u8, statement.columnText(column));
}

fn optionalInt64(statement: database.sqlite.Statement, column: c_int) ?i64 {
    if (statement.columnIsNull(column)) return null;
    return statement.columnInt64(column);
}

const text_key = @import("../database/text_key.zig");

/// The artist/release key folding, and the sort key an artist listing orders
/// by, both live in `database/text_key.zig`: a schema migration backfilling
/// `tracks.artist_id` has to fold exactly the way this projection folds.
pub const normalizeKey = text_key.normalizeKey;
const normalizeInto = text_key.normalizeInto;

const testing = std.testing;

fn openTestLibrary(name: [:0]const u8) !database.LibraryDatabase {
    return database.LibraryDatabase.open(testing.allocator, testing.io, name);
}

/// Insert one observed file at `uri` with the tags a reader would have seen.
fn observe(
    library: *database.LibraryDatabase,
    uri: []const u8,
    audio_format: storage.AudioFormat,
    values: metadata.ObservedTags,
) !i64 {
    const file_id = try library.files.create(.{
        .audio_format = @intFromEnum(audio_format),
        .size_bytes = 1024,
    });
    _ = try library.locations.upsert(.{
        .file_id = file_id,
        .volume_id = database.LibraryDatabase.null_volume,
        .uri = uri,
        .state = .present,
    });
    try library.observed_tags.upsert(.{ .file_id = file_id, .values = values });
    return file_id;
}

fn observeEncoding(
    library: *database.LibraryDatabase,
    uri: []const u8,
    audio_format: storage.AudioFormat,
    properties: database.FileUpsert,
    values: metadata.ObservedTags,
) !i64 {
    var upsert = properties;
    upsert.audio_format = @intFromEnum(audio_format);
    upsert.size_bytes = 1024;
    const file_id = try library.files.create(upsert);
    _ = try library.locations.upsert(.{
        .file_id = file_id,
        .volume_id = database.LibraryDatabase.null_volume,
        .uri = uri,
        .state = .present,
    });
    try library.observed_tags.upsert(.{ .file_id = file_id, .values = values });
    return file_id;
}

fn trackTitles(library: *database.LibraryDatabase) !database.TrackPage {
    return library.tracks.page(testing.allocator, .{ .limit = 256, .offset = 0 });
}

fn scalar(library: *database.LibraryDatabase, sql: [:0]const u8) !i64 {
    var statement = try library.database.prepare(sql);
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return statement.columnInt64(0);
}

test "an explicit album artist names the release and keeps it off the compilation list" {
    var library = try openTestLibrary("file:orca-projection-albumartist?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/Beatles/a.flac", .flac, .{
        .title = "One",
        .artist = "Paul",
        .album = "Abbey Road",
        .album_artist = "The Beatles",
        .track_number = 1,
    });
    _ = try observe(&library, "/m/Beatles/b.flac", .flac, .{
        .title = "Two",
        .artist = "John",
        .album = "Abbey Road",
        .album_artist = "The Beatles",
        .track_number = 2,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    const result = try projection.run(.all);
    try testing.expectEqual(@as(u64, 2), result.tracks_written);
    try testing.expectEqual(@as(u64, 0), result.compilations);
    try testing.expectEqual(@as(i64, 0), try scalar(&library, "SELECT is_compilation FROM releases;"));
    var page = try library.tracks.page(testing.allocator, .{ .limit = 1, .offset = 0 });
    defer page.deinit();
    try testing.expectEqualStrings("The Beatles", page.items[0].album_artist);
}

test "a compilation flag makes the release Various Artists" {
    var library = try openTestLibrary("file:orca-projection-flag?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/Mix/a.flac", .flac, .{
        .title = "One",
        .artist = "Alice",
        .album = "Party",
        .track_number = 1,
        .compilation = true,
    });
    _ = try observe(&library, "/m/Mix/b.flac", .flac, .{
        .title = "Two",
        .artist = "Alice",
        .album = "Party",
        .track_number = 2,
        .compilation = true,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    const result = try projection.run(.all);
    try testing.expectEqual(@as(u64, 1), result.compilations);
    var page = try library.tracks.page(testing.allocator, .{ .limit = 4, .offset = 0 });
    defer page.deinit();
    try testing.expectEqualStrings(various_artists, page.items[0].album_artist);
}

test "one artist across a folder's album becomes that artist's release" {
    var library = try openTestLibrary("file:orca-projection-sole?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/Nils/a.flac", .flac, .{
        .title = "One",
        .artist = "Nils Frahm",
        .album = "Spaces",
        .track_number = 1,
    });
    _ = try observe(&library, "/m/Nils/b.flac", .flac, .{
        .title = "Two",
        .artist = "nils  frahm",
        .album = "Spaces",
        .track_number = 2,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    const result = try projection.run(.all);
    try testing.expectEqual(@as(u64, 0), result.compilations);
    var page = try library.tracks.page(testing.allocator, .{ .limit = 4, .offset = 0 });
    defer page.deinit();
    try testing.expectEqualStrings("Nils Frahm", page.items[0].album_artist);
}

test "several artists with no album artist and no flag become a compilation" {
    var library = try openTestLibrary("file:orca-projection-va?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/Soundtrack/a.flac", .flac, .{
        .title = "One",
        .artist = "Alice",
        .album = "Film",
        .track_number = 1,
    });
    _ = try observe(&library, "/m/Soundtrack/b.flac", .flac, .{
        .title = "Two",
        .artist = "Bob",
        .album = "Film",
        .track_number = 2,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    const result = try projection.run(.all);
    try testing.expectEqual(@as(u64, 1), result.compilations);
    try testing.expectEqual(@as(i64, 1), try scalar(&library, "SELECT is_compilation FROM releases;"));
}

test "two albums in one artist folder stay two releases" {
    var library = try openTestLibrary("file:orca-projection-twoalbums?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/Artist/a.flac", .flac, .{
        .title = "One",
        .artist = "Artist",
        .album = "First",
        .album_artist = "Artist",
        .track_number = 1,
    });
    _ = try observe(&library, "/m/Artist/b.flac", .flac, .{
        .title = "Two",
        .artist = "Artist",
        .album = "Second",
        .album_artist = "Artist",
        .track_number = 1,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    const result = try projection.run(.all);
    try testing.expectEqual(@as(u64, 2), result.groups_projected);
    try testing.expectEqual(@as(u64, 2), try library.releases.count());
    try testing.expectEqual(@as(u64, 2), try library.tracks.count());
}

test "a multi-disc release records its disc count and keeps both positions" {
    var library = try openTestLibrary("file:orca-projection-discs?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/Set/d1t1.flac", .flac, .{
        .title = "One",
        .artist = "Artist",
        .album = "Set",
        .album_artist = "Artist",
        .track_number = 1,
        .disc_number = 1,
    });
    _ = try observe(&library, "/m/Set/d2t1.flac", .flac, .{
        .title = "Two",
        .artist = "Artist",
        .album = "Set",
        .album_artist = "Artist",
        .track_number = 1,
        .disc_number = 2,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    try testing.expectEqual(@as(u64, 1), try library.releases.count());
    try testing.expectEqual(@as(i64, 2), try scalar(&library, "SELECT disc_count FROM releases;"));
    try testing.expectEqual(@as(u64, 2), try library.tracks.count());
}

test "a missing track number becomes a synthetic position and a health issue" {
    var library = try openTestLibrary("file:orca-projection-position?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/Artist/known.flac", .flac, .{
        .title = "Known",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 1,
    });
    const stray = try observe(&library, "/m/Artist/stray.flac", .flac, .{
        .title = "Stray",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    const result = try projection.run(.all);
    try testing.expectEqual(@as(u64, 1), result.synthetic_positions);
    try testing.expectEqual(@as(u64, 2), try library.tracks.count());
    // The invented position never lands on one a file actually claimed.
    try testing.expectEqual(
        @as(i64, 2),
        try scalar(&library, "SELECT track_number FROM tracks WHERE title='Stray';"),
    );
    var issues = try library.health_issues.page(testing.allocator, 16, 0);
    defer issues.deinit();
    try testing.expectEqual(@as(usize, 1), issues.items.len);
    try testing.expectEqual(stray, issues.items[0].file_id);
    try testing.expectEqual(
        database.HealthIssueKind.missing_track_number,
        issues.items[0].kind,
    );
}

test "two songs claiming one track number both stay in the library" {
    var library = try openTestLibrary("file:orca-projection-collision?mode=memory&cache=shared");
    defer library.close();
    // The reference library's own defect: two files of one album both tagged
    // track 4, so the position model alone would list three songs, not four.
    for ([_][2][]const u8{
        .{ "/m/MitiS/01 Oasis (vocal mix).flac", "Oasis (vocal mix)" },
        .{ "/m/MitiS/02 For So Long.flac", "For So Long" },
    }, 1..) |named, number| {
        _ = try observe(&library, named[0], .flac, .{
            .title = named[1],
            .artist = "MitiS",
            .album = "Oasis",
            .album_artist = "MitiS",
            .track_number = @intCast(number),
        });
    }
    _ = try observe(&library, "/m/MitiS/03 Prism.flac", .flac, .{
        .title = "Prism",
        .artist = "MitiS",
        .album = "Oasis",
        .album_artist = "MitiS",
        .track_number = 4,
    });
    const displaced = try observe(&library, "/m/MitiS/04 Oasis.flac", .flac, .{
        .title = "Oasis (instrumental mix)",
        .artist = "MitiS",
        .album = "Oasis",
        .album_artist = "MitiS",
        .track_number = 4,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    const result = try projection.run(.all);
    try testing.expectEqual(@as(u64, 1), result.displaced_positions);
    try testing.expectEqual(@as(u64, 0), result.synthetic_positions);
    // Nothing is dropped, and the file that lost the argument takes the lowest
    // position no file claimed rather than overwriting the one that won.
    try testing.expectEqual(@as(u64, 4), try library.tracks.count());
    try testing.expectEqual(
        @as(i64, 3),
        try scalar(&library, "SELECT track_number FROM tracks WHERE title LIKE '%instrumental%';"),
    );
    var issues = try library.health_issues.page(testing.allocator, 16, 0);
    defer issues.deinit();
    try testing.expectEqual(@as(usize, 1), issues.items.len);
    try testing.expectEqual(displaced, issues.items[0].file_id);
    try testing.expectEqual(
        database.HealthIssueKind.technical_anomaly,
        issues.items[0].kind,
    );
}

test "an untitled file is listed under its filename rather than as a blank row" {
    var library = try openTestLibrary("file:orca-projection-untitled?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/Artist/03 - Blue Monday.flac", .flac, .{
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 3,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    const result = try projection.run(.all);
    try testing.expectEqual(@as(u64, 1), result.filename_titles);
    var page = try library.tracks.page(testing.allocator, .{ .limit = 4, .offset = 0 });
    defer page.deinit();
    try testing.expectEqualStrings("03 - Blue Monday", page.items[0].title);
}

test "a FLAC and an MP3 of one song collapse to one recording with the FLAC preferred" {
    var library = try openTestLibrary("file:orca-projection-encodings?mode=memory&cache=shared");
    defer library.close();
    const tags = metadata.ObservedTags{
        .title = "One",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 1,
    };
    const mp3 = try observe(&library, "/m/Artist/one.mp3", .mp3, tags);
    const flac = try observe(&library, "/m/Artist/one.flac", .flac, tags);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    try testing.expectEqual(@as(u64, 1), try library.tracks.count());
    try testing.expectEqual(@as(u64, 1), try library.recordings.count());
    try testing.expectEqual(
        flac,
        try scalar(&library, "SELECT preferred_file_id FROM tracks;"),
    );
    try testing.expectEqual(
        @as(i64, 2),
        try scalar(&library, "SELECT count(*) FROM files WHERE recording_id IS NOT NULL;"),
    );
    _ = mp3;
}

test "artist keys fold case, width and whitespace without folding distinct scripts together" {
    const allocator = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "Sigur Rós", "sigur  rós" },
        .{ "  CHANCE デラソウル ", "chance デラソウル" },
        .{ "ＭＩＸ", "mix" },
        .{ "ΑΘΗΝΑ", "αθηνα" },
        .{ "Пётр", "пётр" },
    };
    for (cases) |pair| {
        const left = try normalizeKey(allocator, pair[0]);
        defer allocator.free(left);
        const right = try normalizeKey(allocator, pair[1]);
        defer allocator.free(right);
        try testing.expectEqualStrings(left, right);
    }
    const alpha = try normalizeKey(allocator, "デラソウル");
    defer allocator.free(alpha);
    const beta = try normalizeKey(allocator, "デラソウン");
    defer allocator.free(beta);
    try testing.expect(!std.mem.eql(u8, alpha, beta));
}

test "case-different spellings of one artist project as one artist row" {
    var library = try openTestLibrary("file:orca-projection-artistkey?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/Sigur/a.flac", .flac, .{
        .title = "One",
        .artist = "Sigur Rós",
        .album = "()",
        .album_artist = "Sigur Rós",
        .track_number = 1,
    });
    _ = try observe(&library, "/m/Sigur/b.flac", .flac, .{
        .title = "Two",
        .artist = "sigur  rós",
        .album = "()",
        .album_artist = "SIGUR RÓS",
        .track_number = 2,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    try testing.expectEqual(@as(u64, 1), try library.artists.count());
    try testing.expectEqual(@as(u64, 1), try library.releases.count());
}

test "projecting twice writes the same rows rather than duplicating them" {
    var library = try openTestLibrary("file:orca-projection-idempotent?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/Artist/a.flac", .flac, .{
        .title = "One",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 1,
    });
    _ = try observe(&library, "/m/Artist/stray.flac", .flac, .{
        .title = "Stray",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
    });
    _ = try observe(&library, "/m/Various/x.flac", .flac, .{
        .title = "X",
        .artist = "Alice",
        .album = "Mix",
        .track_number = 1,
    });
    _ = try observe(&library, "/m/Various/y.flac", .flac, .{
        .title = "Y",
        .artist = "Bob",
        .album = "Mix",
        .track_number = 2,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const tracks = try library.tracks.count();
    const releases = try library.releases.count();
    const recordings = try library.recordings.count();
    const artists = try library.artists.count();
    const identifiers = try scalar(&library, "SELECT sum(id) FROM tracks;");

    _ = try projection.run(.all);
    try testing.expectEqual(tracks, try library.tracks.count());
    try testing.expectEqual(releases, try library.releases.count());
    try testing.expectEqual(recordings, try library.recordings.count());
    try testing.expectEqual(artists, try library.artists.count());
    try testing.expectEqual(identifiers, try scalar(&library, "SELECT sum(id) FROM tracks;"));
}

test "a scoped reprojection touches only the folders its files live in" {
    var library = try openTestLibrary("file:orca-projection-scoped?mode=memory&cache=shared");
    defer library.close();
    const changed = try observe(&library, "/m/A/one.flac", .flac, .{
        .title = "One",
        .artist = "A",
        .album = "First",
        .album_artist = "A",
        .track_number = 1,
    });
    _ = try observe(&library, "/m/B/two.flac", .flac, .{
        .title = "Two",
        .artist = "B",
        .album = "Second",
        .album_artist = "B",
        .track_number = 1,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    const scoped = try projection.run(.{ .files = &.{changed} });
    try testing.expectEqual(@as(u64, 1), scoped.folders_visited);
    try testing.expectEqual(@as(u64, 1), scoped.tracks_written);
    try testing.expectEqual(@as(u64, 1), try library.tracks.count());

    // Nothing changed means nothing to reproject.
    const empty = try projection.run(.{ .files = &.{} });
    try testing.expectEqual(@as(u64, 0), empty.folders_visited);
    try testing.expectEqual(@as(u64, 0), empty.tracks_written);
}

test "a locked user title outranks the file and reaches the projected track" {
    var library = try openTestLibrary("file:orca-projection-locked?mode=memory&cache=shared");
    defer library.close();
    const file_id = try observe(&library, "/m/Artist/a.flac", .flac, .{
        .title = "File title",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 1,
    });
    try library.orca_metadata.upsert(.{
        .file_id = file_id,
        .field = .title,
        .value = "User title",
        .provenance = .user,
        .locked = true,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.{ .files = &.{file_id} });
    var page = try library.tracks.page(testing.allocator, .{ .limit = 4, .offset = 0 });
    defer page.deinit();
    try testing.expectEqualStrings("User title", page.items[0].title);
}

test "projected tracks are searchable by title, artist, album and album artist" {
    var library = try openTestLibrary("file:orca-projection-fts?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/Portishead/glory.flac", .flac, .{
        .title = "Glory Box",
        .artist = "Portishead",
        .album = "Dummy",
        .album_artist = "Portishead Collective",
        .track_number = 10,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    for ([_][]const u8{
        "title:Glory",
        "artist:Portishead",
        "album:Dummy",
        "album_artist:Collective",
    }) |query| {
        var page = try library.tracks.search(testing.allocator, query, 8, 0);
        defer page.deinit();
        try testing.expectEqual(@as(usize, 1), page.items.len);
        try testing.expectEqualStrings("Glory Box", page.items[0].title);
    }
}

test "a projected track resolves to the bytes a Player can open" {
    var library = try openTestLibrary("file:orca-projection-playable?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/Artist/one.flac", .flac, .{
        .title = "One",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 1,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    var page = try library.tracks.page(testing.allocator, .{ .limit = 4, .offset = 0 });
    defer page.deinit();
    try testing.expect(page.items[0].has_playable_file);
    const resolved = (try library.tracks.playableLocation(
        testing.allocator,
        page.items[0].id,
    )).?;
    defer resolved.deinit();
    try testing.expectEqualStrings("/m/Artist/one.flac", resolved.uri);
    try testing.expectEqual(
        storage.AudioFormat.flac,
        std.enums.fromInt(storage.AudioFormat, resolved.audio_format).?,
    );
}

test "a track reports the duration of the encoding it prefers" {
    var library = try openTestLibrary("file:orca-projection-duration?mode=memory&cache=shared");
    defer library.close();
    _ = try observeEncoding(
        &library,
        "/m/Artist/one.flac",
        .flac,
        .{ .sample_rate = 44100, .bit_depth = 16, .channels = 2, .duration_ms = 213_000 },
        .{ .title = "One", .artist = "Artist", .album = "Album", .track_number = 1 },
    );
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    var page = try library.tracks.page(testing.allocator, .{ .limit = 4, .offset = 0 });
    defer page.deinit();
    try testing.expectEqual(@as(?i64, 213_000), page.items[0].duration_ms);
}

test "the preferred encoding is chosen by declared properties rather than container name" {
    var library = try openTestLibrary("file:orca-projection-merit?mode=memory&cache=shared");
    defer library.close();
    const tags = metadata.ObservedTags{
        .title = "One",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 1,
    };
    // MPEG audio declares a rate and a channel count but no sample width, so
    // the 16 real bits of the FLAC decide this — not the word "flac".
    const mp3 = try observeEncoding(
        &library,
        "/m/Artist/one.mp3",
        .mp3,
        .{ .sample_rate = 44100, .channels = 2, .duration_ms = 213_000 },
        tags,
    );
    const flac = try observeEncoding(
        &library,
        "/m/Artist/one.flac",
        .flac,
        .{ .sample_rate = 44100, .bit_depth = 16, .channels = 2, .duration_ms = 213_040 },
        tags,
    );
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    try testing.expectEqual(@as(u64, 1), try library.tracks.count());
    try testing.expectEqual(
        flac,
        try scalar(&library, "SELECT preferred_file_id FROM tracks;"),
    );
    try testing.expectEqual(
        @as(i64, 213_040),
        try scalar(&library, "SELECT duration_ms FROM tracks;"),
    );
    _ = mp3;
}

test "a higher bit depth wins over a lossless sibling of the same container" {
    const shallow: Entry = .{
        .file_id = 1,
        .uri = "/m/a.flac",
        .audio_format = @intFromEnum(storage.AudioFormat.flac),
        .bit_depth = 16,
        .sample_rate = 44100,
        .duration_ms = 1000,
        .recording_id = null,
        .location_present = true,
        .title = "",
        .artist = "",
        .artist_mbid = null,
        .album = "",
        .album_key = "",
        .album_artist = null,
        .album_artist_mbid = null,
        .track_number = null,
        .disc_number = null,
        .date = null,
        .compilation = null,
        .musicbrainz_release_id = null,
        .musicbrainz_recording_id = null,
    };
    var deep = shallow;
    deep.file_id = 2;
    deep.bit_depth = 24;
    deep.sample_rate = 96000;
    try testing.expect(preferredOver(deep, shallow));
    try testing.expect(!preferredOver(shallow, deep));

    // A file whose properties could not be read states nothing about itself and
    // must not outrank one that does, whatever container it is in.
    var unprobed = shallow;
    unprobed.file_id = 3;
    unprobed.bit_depth = null;
    unprobed.sample_rate = null;
    try testing.expect(!preferredOver(unprobed, shallow));
    try testing.expect(preferredOver(shallow, unprobed));

    // Two files that are equally uninformative fall through to the container,
    // which is the only thing left that can separate them.
    var unprobed_mp3 = unprobed;
    unprobed_mp3.file_id = 4;
    unprobed_mp3.audio_format = @intFromEnum(storage.AudioFormat.mp3);
    try testing.expect(!preferredOver(unprobed_mp3, unprobed));
    try testing.expect(preferredOver(unprobed, unprobed_mp3));
}

test "a reachable encoding is preferred over a better one that is missing" {
    // preferred_file_id is what playback opens, so an unreachable file is not a
    // better encoding — it is nothing to play. A Track must not become
    // unplayable because its highest-fidelity copy lives on an unplugged drive
    // while a usable one sits beside it.
    const present_shallow: Entry = .{
        .file_id = 1,
        .uri = "/m/internal.flac",
        .audio_format = @intFromEnum(storage.AudioFormat.flac),
        .bit_depth = 16,
        .sample_rate = 44100,
        .duration_ms = 1000,
        .recording_id = null,
        .location_present = true,
        .title = "",
        .artist = "",
        .artist_mbid = null,
        .album = "",
        .album_key = "",
        .album_artist = null,
        .album_artist_mbid = null,
        .track_number = null,
        .disc_number = null,
        .date = null,
        .compilation = null,
        .musicbrainz_release_id = null,
        .musicbrainz_recording_id = null,
    };
    var missing_deep = present_shallow;
    missing_deep.file_id = 2;
    missing_deep.uri = "/m/external.flac";
    missing_deep.bit_depth = 24;
    missing_deep.sample_rate = 96000;
    missing_deep.location_present = false;

    try testing.expect(preferredOver(present_shallow, missing_deep));
    try testing.expect(!preferredOver(missing_deep, present_shallow));

    // Once the drive comes back, projection recomputes and fidelity decides
    // again — the preference is a cache, not a verdict.
    missing_deep.location_present = true;
    try testing.expect(preferredOver(missing_deep, present_shallow));
}

/// A small library with everything the browse model has to survive: two
/// artists, one of them with a leading article, a multi-disc release, a
/// compilation, a MusicBrainz-identified featured credit, and two songs that
/// share a title.
fn observeBrowseLibrary(library: *database.LibraryDatabase) !void {
    _ = try observe(library, "/m/The Band/d1t1.flac", .flac, .{
        .title = "Shared",
        .artist = "The Band",
        .album = "Set",
        .album_artist = "The Band",
        .track_number = 1,
        .disc_number = 1,
        .musicbrainz_artist_id = "band-mbid",
        .musicbrainz_album_artist_id = "band-mbid",
    });
    _ = try observe(library, "/m/The Band/d1t2.flac", .flac, .{
        .title = "Second",
        .artist = "The Band",
        .album = "Set",
        .album_artist = "The Band",
        .track_number = 2,
        .disc_number = 1,
        .musicbrainz_artist_id = "band-mbid",
        .musicbrainz_album_artist_id = "band-mbid",
    });
    // A featured credit carrying the band's own MusicBrainz id: the projection
    // files it under the band, and so must the migration's backfill.
    _ = try observe(library, "/m/The Band/d2t1.flac", .flac, .{
        .title = "Shared",
        .artist = "The Band feat. Guest",
        .album = "Set",
        .album_artist = "The Band",
        .track_number = 1,
        .disc_number = 2,
        .musicbrainz_artist_id = "band-mbid",
        .musicbrainz_album_artist_id = "band-mbid",
    });
    _ = try observe(library, "/m/Various/x.flac", .flac, .{
        .title = "Alpha",
        .artist = "Alice",
        .album = "Mix",
        .track_number = 1,
    });
    _ = try observe(library, "/m/Various/y.flac", .flac, .{
        .title = "Beta",
        .artist = "Bob",
        .album = "Mix",
        .track_number = 2,
    });
}

fn artistIdOf(library: *database.LibraryDatabase, name: []const u8) !i64 {
    var statement = try library.database.prepare("SELECT id FROM artists WHERE name=?1;");
    defer statement.deinit();
    try statement.bindText(1, name);
    if (try statement.step() != .row) return error.NoSuchArtist;
    return statement.columnInt64(0);
}

test "every projected track is filed under an artist row rather than a name" {
    var library = try openTestLibrary("file:orca-projection-artistid?mode=memory&cache=shared");
    defer library.close();
    try observeBrowseLibrary(&library);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);

    try testing.expectEqual(
        @as(i64, 0),
        try scalar(&library, "SELECT count(*) FROM tracks WHERE artist_id IS NULL;"),
    );
    try testing.expectEqual(
        @as(i64, 0),
        try scalar(&library, "SELECT count(*) FROM releases WHERE album_artist_id IS NULL;"),
    );
    // The featured credit resolves to the band, because its MusicBrainz artist
    // id outranks the name it was tagged with.
    const band = try artistIdOf(&library, "The Band");
    try testing.expectEqual(@as(i64, 3), try scalar(
        &library,
        "SELECT count(*) FROM tracks WHERE artist_id=(SELECT id FROM artists WHERE name='The Band');",
    ));
    var page = try library.tracks.page(testing.allocator, .{ .artist_id = band, .limit = 16 });
    defer page.deinit();
    try testing.expectEqual(@as(usize, 3), page.items.len);
}

test "a leading article does not decide where an artist files" {
    var library = try openTestLibrary("file:orca-projection-sortname?mode=memory&cache=shared");
    defer library.close();
    try observeBrowseLibrary(&library);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);

    var page = try library.artists.page(testing.allocator, .{ .limit = 16 });
    defer page.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(testing.allocator);
    for (page.items) |artist| try names.append(testing.allocator, artist.name);
    // Alice, Bob, The Band — not "The Band" first under T, and not last under B
    // because "band" sorts after "bob" only if the article stayed on.
    try testing.expectEqualStrings("Alice", names.items[0]);
    try testing.expectEqualStrings("The Band", names.items[1]);
    try testing.expectEqualStrings("Bob", names.items[2]);
}

test "a migrated library files every track exactly where a fresh projection does" {
    var library = try openTestLibrary("file:orca-projection-backfill?mode=memory&cache=shared");
    defer library.close();
    try observeBrowseLibrary(&library);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);

    const projected = try scalar(&library, browse_fingerprint);
    // Exactly the state a version-8 database is in: the columns exist, and
    // nothing has ever filled them.
    try library.database.exec(
        \\UPDATE tracks SET artist_id=NULL;
        \\UPDATE releases SET album_artist_id=NULL;
        \\UPDATE artists SET sort_name=NULL;
    );
    try testing.expect(projected != try scalar(&library, browse_fingerprint));

    try database.migrations.registerKeyFunctions(library.database);
    try library.database.exec(database.migrations.artist_backfill);
    try testing.expectEqual(projected, try scalar(&library, browse_fingerprint));
}

/// One number over every value the browse model added, so "the same rows" is
/// asserted rather than sampled.
const browse_fingerprint =
    \\SELECT
    \\    (SELECT COALESCE(sum(id * 1000003 + COALESCE(artist_id, -1)), 0) FROM tracks)
    \\  + (SELECT COALESCE(sum(id * 7919 + COALESCE(album_artist_id, -1)), 0) FROM releases)
    \\  + (SELECT COALESCE(sum(id * length(COALESCE(sort_name, ''))), 0) FROM artists);
;

test "an album comes back in disc then track order" {
    var library = try openTestLibrary("file:orca-projection-discorder?mode=memory&cache=shared");
    defer library.close();
    try observeBrowseLibrary(&library);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);

    var releases = try library.releases.page(testing.allocator, .{ .limit = 16 });
    defer releases.deinit();
    var set_id: i64 = 0;
    for (releases.items) |release| {
        if (std.mem.eql(u8, release.title, "Set")) set_id = release.id;
    }
    try testing.expect(set_id != 0);

    var page = try library.tracks.page(testing.allocator, .{
        .release_id = set_id,
        .sort = .track_number,
        .limit = 16,
    });
    defer page.deinit();
    try testing.expectEqual(@as(usize, 3), page.items.len);
    try testing.expectEqual(@as(?i64, 1), page.items[0].disc_number);
    try testing.expectEqual(@as(?i64, 1), page.items[0].track_number);
    try testing.expectEqual(@as(?i64, 1), page.items[1].disc_number);
    try testing.expectEqual(@as(?i64, 2), page.items[1].track_number);
    // Disc 2 track 1 comes last, not alongside disc 1 track 1.
    try testing.expectEqual(@as(?i64, 2), page.items[2].disc_number);
    try testing.expectEqual(@as(?i64, 1), page.items[2].track_number);
}

test "paging a sort with ties returns every track exactly once" {
    var library = try openTestLibrary("file:orca-projection-tiedpages?mode=memory&cache=shared");
    defer library.close();
    // Five songs sharing one title, so every ordering decision falls through to
    // the tiebreaker.
    for (0..5) |index| {
        var uri_buffer: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&uri_buffer, "/m/Tied/{d}.flac", .{index});
        _ = try observe(&library, uri, .flac, .{
            .title = "Same",
            .artist = "Artist",
            .album = "Album",
            .album_artist = "Artist",
            .track_number = @intCast(index + 1),
        });
    }
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);

    var seen: std.ArrayList(i64) = .empty;
    defer seen.deinit(testing.allocator);
    var offset: u32 = 0;
    while (offset < 6) : (offset += 2) {
        var page = try library.tracks.page(testing.allocator, .{
            .sort = .title,
            .limit = 2,
            .offset = offset,
        });
        defer page.deinit();
        for (page.items) |item| try seen.append(testing.allocator, item.id);
    }
    var whole = try library.tracks.page(testing.allocator, .{ .sort = .title, .limit = 16 });
    defer whole.deinit();
    try testing.expectEqual(whole.items.len, seen.items.len);
    for (whole.items, seen.items) |expected, actual| try testing.expectEqual(expected.id, actual);
}

test "reversing a sort reverses the whole listing rather than only its first key" {
    var library = try openTestLibrary("file:orca-projection-desc?mode=memory&cache=shared");
    defer library.close();
    try observeBrowseLibrary(&library);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);

    var ascending = try library.tracks.page(testing.allocator, .{ .sort = .title, .limit = 16 });
    defer ascending.deinit();
    var descending = try library.tracks.page(testing.allocator, .{
        .sort = .title,
        .direction = .descending,
        .limit = 16,
    });
    defer descending.deinit();
    try testing.expectEqual(ascending.items.len, descending.items.len);
    for (ascending.items, 0..) |item, index| {
        const mirrored = descending.items[descending.items.len - 1 - index];
        try testing.expectEqual(item.id, mirrored.id);
    }
}

test "a release reports how many tracks it holds and how long they run" {
    var library = try openTestLibrary("file:orca-projection-releasesum?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/Artist/a.flac", .flac, .{
        .title = "One",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 1,
    });
    _ = try observe(&library, "/m/Artist/b.flac", .flac, .{
        .title = "Two",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 2,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    try library.database.exec("UPDATE tracks SET duration_ms=1000 WHERE track_number=1;");

    var page = try library.releases.page(testing.allocator, .{ .limit = 16 });
    defer page.deinit();
    try testing.expectEqual(@as(usize, 1), page.items.len);
    try testing.expectEqual(@as(u32, 2), page.items[0].track_count);
    // The Track with no declared duration contributes nothing rather than a
    // zero-length lie.
    try testing.expectEqual(@as(i64, 1000), page.items[0].total_duration_ms);

    const artist = try artistIdOf(&library, "Artist");
    var scoped = try library.releases.page(testing.allocator, .{
        .album_artist_id = artist,
        .limit = 16,
    });
    defer scoped.deinit();
    try testing.expectEqual(@as(usize, 1), scoped.items.len);
    var elsewhere = try library.releases.page(testing.allocator, .{
        .album_artist_id = artist + 1000,
        .limit = 16,
    });
    defer elsewhere.deinit();
    try testing.expectEqual(@as(usize, 0), elsewhere.items.len);
}

test "an out-of-range page is refused rather than clamped" {
    var library = try openTestLibrary("file:orca-projection-pagebound?mode=memory&cache=shared");
    defer library.close();
    try testing.expectError(
        error.PageOutOfRange,
        library.tracks.page(testing.allocator, .{ .limit = 0 }),
    );
    try testing.expectError(
        error.PageOutOfRange,
        library.tracks.page(testing.allocator, .{ .limit = 513 }),
    );
    try testing.expectError(
        error.PageOutOfRange,
        library.artists.page(testing.allocator, .{ .limit = 0 }),
    );
    try testing.expectError(
        error.PageOutOfRange,
        library.releases.page(testing.allocator, .{ .limit = 513 }),
    );
}

test "a retagged file's old track, release and artist are pruned rather than left listed" {
    var library = try openTestLibrary("file:orca-projection-prune?mode=memory&cache=shared");
    defer library.close();
    const file_id = try observe(&library, "/m/Old/a.flac", .flac, .{
        .title = "Song",
        .artist = "Old Artist",
        .album = "Old Album",
        .album_artist = "Old Artist",
        .track_number = 1,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.{ .files = &.{file_id} });

    try library.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = "Song",
        .artist = "New Artist",
        .album = "New Album",
        .album_artist = "New Artist",
        .track_number = 1,
    } });
    const result = try projection.run(.{ .files = &.{file_id} });
    try testing.expectEqual(@as(u64, 1), result.tracks_pruned);
    try testing.expectEqual(@as(u64, 1), result.releases_pruned);
    try testing.expectEqual(@as(u64, 1), result.artists_pruned);
    try testing.expectEqual(@as(i64, 1), try scalar(&library, "SELECT count(*) FROM tracks;"));
    try testing.expectEqual(@as(i64, 1), try scalar(&library, "SELECT count(*) FROM releases;"));
    try testing.expectEqual(@as(i64, 1), try scalar(&library, "SELECT count(*) FROM artists;"));
    var page = try trackTitles(&library);
    defer page.deinit();
    try testing.expectEqualStrings("New Album", page.items[0].album);
}

test "a release that still has other tracks survives one of them moving away" {
    var library = try openTestLibrary("file:orca-projection-prune-partial?mode=memory&cache=shared");
    defer library.close();
    const album: metadata.ObservedTags = .{ .artist = "Artist", .album = "Album", .album_artist = "Artist" };
    var first = album;
    first.title = "One";
    first.track_number = 1;
    var second = album;
    second.title = "Two";
    second.track_number = 2;
    const moving = try observe(&library, "/m/Artist/1.flac", .flac, first);
    const staying = try observe(&library, "/m/Artist/2.flac", .flac, second);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.{ .files = &.{ moving, staying } });

    first.track_number = 3;
    try library.observed_tags.upsert(.{ .file_id = moving, .values = first });
    const result = try projection.run(.{ .files = &.{moving} });
    try testing.expectEqual(@as(u64, 1), result.tracks_pruned);
    try testing.expectEqual(@as(u64, 0), result.releases_pruned);
    try testing.expectEqual(@as(u64, 0), result.artists_pruned);
    try testing.expectEqual(@as(i64, 2), try scalar(&library, "SELECT count(*) FROM tracks;"));
    try testing.expectEqual(@as(i64, 3), try scalar(&library, "SELECT max(track_number) FROM tracks;"));
}

test "locked album artist, disc, date and compilation values reach the projected release" {
    var library = try openTestLibrary("file:orca-projection-extra-overrides?mode=memory&cache=shared");
    defer library.close();
    const file_id = try observe(&library, "/m/Artist/a.flac", .flac, .{
        .title = "Song",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 1,
        .date = "1999",
    });
    inline for (.{
        .{ metadata.Field.album_artist, "Edited Artist" },
        .{ metadata.Field.disc_number, "2" },
        .{ metadata.Field.date, "2024" },
    }) |edit| try library.orca_metadata.upsert(.{
        .file_id = file_id,
        .field = edit[0],
        .value = edit[1],
        .provenance = .user,
        .locked = true,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.{ .files = &.{file_id} });
    var page = try trackTitles(&library);
    defer page.deinit();
    try testing.expectEqualStrings("Edited Artist", page.items[0].album_artist);
    try testing.expectEqual(@as(?i64, 2), page.items[0].disc_number);
    try testing.expectEqual(@as(i64, 1), try scalar(&library, "SELECT count(*) FROM releases WHERE release_date = '2024';"));
}
