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
//! scan. See `docs/database.md`.
//!
//! The unit of work is a `(containing folder, album key)` group: whether a
//! Release is a compilation is a statement about that set, not one file.

const std = @import("std");
const database = @import("../database/root.zig");
const metadata = @import("../metadata/root.zig");
const storage = @import("../storage/root.zig");
const health = @import("../analysis/health.zig");

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
    /// Tracks that kept their id and changed position or Release, because the
    /// file they present now projects there.
    tracks_moved: u64 = 0,
    /// Rows deleted because no position claimed them: their files now present
    /// other Tracks or none, or another Track took their position.
    tracks_pruned: u64 = 0,
    releases_pruned: u64 = 0,
    artists_pruned: u64 = 0,
};

const MovedTrack = struct { from_release_id: i64, file_id: i64 };

const CarriedTable = struct {
    held: database.sqlite.Statement,
    hand_over: database.sqlite.Statement,

    fn prepare(db: database.sqlite.Database, comptime table: []const u8) !CarriedTable {
        var held = try db.prepare("SELECT 1 FROM " ++ table ++ " WHERE release_id = ?1;");
        errdefer held.deinit();
        return .{
            .held = held,
            .hand_over = try db.prepare("UPDATE " ++ table ++ " SET release_id = ?2 WHERE release_id = ?1;"),
        };
    }

    fn deinit(self: *CarriedTable) void {
        self.held.deinit();
        self.hand_over.deinit();
    }
};

/// A Release left without Tracks hands its stored covers, its cover art
/// candidates, its love and its dismissed MusicBrainz releases to the Release that took most of them, each only
/// when that one has none of its own, so a cover fetched or chosen or an
/// album loved before a regrouping survives it. The tables cascade on the
/// Release row, so whatever is not handed over goes with it.
fn carryReleaseState(db: database.sqlite.Database, allocator: std.mem.Allocator, moved: []const MovedTrack) !void {
    if (moved.len == 0) return;
    var artwork = try CarriedTable.prepare(db, "release_artwork");
    defer artwork.deinit();
    var candidates = try CarriedTable.prepare(db, "cover_art_candidates");
    defer candidates.deinit();
    var loves = try CarriedTable.prepare(db, "release_loves");
    defer loves.deinit();
    var dismissals = try CarriedTable.prepare(db, "dismissed_release_candidates");
    defer dismissals.deinit();
    const carried = [_]*CarriedTable{ &artwork, &candidates, &loves, &dismissals };
    var in_use = try db.prepare("SELECT 1 FROM tracks WHERE release_id = ?1 LIMIT 1;");
    defer in_use.deinit();
    var now_on = try db.prepare(
        \\SELECT DISTINCT release_id FROM tracks WHERE release_id IS NOT NULL
        \\  AND (preferred_file_id = ?1 OR recording_id = (SELECT recording_id FROM files WHERE id = ?1));
    );
    defer now_on.deinit();

    var seen: std.ArrayList(i64) = .empty;
    for (moved) |track| {
        const from = track.from_release_id;
        if (std.mem.indexOfScalar(i64, seen.items, from) != null) continue;
        try seen.append(allocator, from);
        if (try exists(&in_use, from)) continue;
        var holds_any = false;
        for (carried) |table| {
            if (try exists(&table.held, from)) holds_any = true;
        }
        if (!holds_any) continue;

        const Count = struct { release_id: i64, tracks: u32 };
        var counts: std.ArrayList(Count) = .empty;
        for (moved) |other| {
            if (other.from_release_id != from) continue;
            try now_on.bindInt64(1, other.file_id);
            while (try now_on.step() == .row) {
                const release_id = now_on.columnInt64(0);
                for (counts.items) |*count| {
                    if (count.release_id == release_id) {
                        count.tracks += 1;
                        break;
                    }
                } else try counts.append(allocator, .{ .release_id = release_id, .tracks = 1 });
            }
            try now_on.reset();
        }
        var heir: ?Count = null;
        for (counts.items) |count| {
            if (heir == null or count.tracks > heir.?.tracks or
                (count.tracks == heir.?.tracks and count.release_id < heir.?.release_id)) heir = count;
        }
        const target = heir orelse continue;
        for (carried) |table| {
            if (!try exists(&table.held, from) or try exists(&table.held, target.release_id)) continue;
            try table.hand_over.bindInt64(1, from);
            try table.hand_over.bindInt64(2, target.release_id);
            if (try table.hand_over.step() != .done) return error.SqlFailed;
            try table.hand_over.reset();
        }
    }
}

fn exists(statement: *database.sqlite.Statement, id: i64) !bool {
    try statement.bindInt64(1, id);
    defer statement.reset() catch {};
    return try statement.step() == .row;
}

const Vacated = struct {
    releases: std.ArrayList(i64) = .empty,
    artists: std.ArrayList(i64) = .empty,
    moved: std.ArrayList(MovedTrack) = .empty,

    fn record(self: *Vacated, allocator: std.mem.Allocator, file_id: ?i64, release_id: ?i64, artist_id: ?i64) !void {
        if (release_id) |id| {
            try self.releases.append(allocator, id);
            if (file_id) |file| try self.moved.append(allocator, .{ .from_release_id = id, .file_id = file });
        }
        if (artist_id) |id| try self.artists.append(allocator, id);
    }
};

/// An existing Track a position claimed, and where it stood before.
const Claim = struct {
    track_id: i64,
    release_id: ?i64,
    disc: i64,
    number: ?i64,
    artist_id: ?i64,
    recording_id: ?i64,

    fn moves(self: Claim, seat: Seat) bool {
        return self.release_id != seat.release_id or self.disc != seat.disc or self.number != seat.number;
    }
};

/// Matches a folder's positions to the Tracks they already have. A Track
/// follows the file it presents: a position takes the Track whose preferred
/// file is one of its members, on any Release, and failing that a Track on its
/// own Release presenting the same recording. Each Track is claimed at most
/// once per folder, so no two positions share a row, and pruning leaves every
/// claimed one alone.
const TrackClaims = struct {
    claimed: std.AutoHashMapUnmanaged(i64, void) = .empty,
    by_file: database.sqlite.Statement,
    by_recording: database.sqlite.Statement,

    const select_claim =
        "SELECT id, release_id, COALESCE(disc_number, 1), track_number, artist_id, recording_id FROM tracks ";

    fn prepare(db: database.sqlite.Database) !TrackClaims {
        var by_file = try db.prepare(select_claim ++ "WHERE preferred_file_id = ?1 ORDER BY id;");
        errdefer by_file.deinit();
        return .{
            .by_file = by_file,
            .by_recording = try db.prepare(select_claim ++ "WHERE release_id = ?1 AND recording_id = ?2 ORDER BY id;"),
        };
    }

    fn deinit(self: *TrackClaims) void {
        self.by_file.deinit();
        self.by_recording.deinit();
    }

    fn contains(self: *const TrackClaims, track_id: i64) bool {
        return self.claimed.contains(track_id);
    }

    /// The preferred member's Track first, then the other members' in order.
    fn byMembers(self: *TrackClaims, allocator: std.mem.Allocator, entries: []const Entry, members: []const usize) !?Claim {
        const preferred = bestEncoding(entries, members);
        if (try self.byFile(allocator, entries[preferred].file_id)) |claim| return claim;
        for (members) |index| {
            if (index == preferred) continue;
            if (try self.byFile(allocator, entries[index].file_id)) |claim| return claim;
        }
        return null;
    }

    fn byFile(self: *TrackClaims, allocator: std.mem.Allocator, file_id: i64) !?Claim {
        try self.by_file.bindInt64(1, file_id);
        return self.first(allocator, &self.by_file);
    }

    fn byRecording(self: *TrackClaims, allocator: std.mem.Allocator, release_id: i64, recording_id: i64) !?Claim {
        try self.by_recording.bindInt64(1, release_id);
        try self.by_recording.bindInt64(2, recording_id);
        return self.first(allocator, &self.by_recording);
    }

    fn first(self: *TrackClaims, allocator: std.mem.Allocator, statement: *database.sqlite.Statement) !?Claim {
        defer statement.reset() catch {};
        while (try statement.step() == .row) {
            const track_id = statement.columnInt64(0);
            if (self.claimed.contains(track_id)) continue;
            try self.claimed.put(allocator, track_id, {});
            return .{
                .track_id = track_id,
                .release_id = optionalInt64(statement.*, 1),
                .disc = statement.columnInt64(2),
                .number = optionalInt64(statement.*, 3),
                .artist_id = optionalInt64(statement.*, 4),
                .recording_id = optionalInt64(statement.*, 5),
            };
        }
        return null;
    }
};

/// One position a folder projects to, matched before any Track is written.
const Seat = struct {
    release_id: i64,
    disc: i64,
    number: i64,
    claim: ?Claim,
    genres: []const []const u8,
};

/// A `(folder, album key)` group resolved to its positions and the Tracks its
/// files claimed, before any Track is written.
const GroupPlan = struct {
    identity: ReleaseIdentity,
    release_id: i64,
    entries: []Entry,
    positions: []Position,
    claims: []?Claim,
};

/// A `(folder, album key)` group's resolved release identity.
const ReleaseIdentity = struct {
    key: []const u8,
    title: []const u8,
    album_artist: []const u8,
    album_artist_mbid: ?[]const u8,
    release_date: ?[]const u8,
    musicbrainz_release_id: ?[]const u8,
    release_type: ?[]const u8,
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
    unreadable: bool = false,
    foreign: bool = false,
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
    track_total: ?i64 = null,
    disc_total: ?i64 = null,
    explicit: ?metadata.Explicit = null,
    release_type: ?[]const u8 = null,
    /// The cover the file's tags embed, as the scan measured it.
    embedded_artwork: ?database.repository.ArtworkMeasurement = null,
    genres: []const []const u8 = &.{},
    /// Decided on the tags before the filename stands in for a missing title.
    missing_metadata: ?database.HealthIssueInput = null,
    release_id: i64 = 0,
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
    musicbrainz_release_id: ?metadata.Value = null,
    explicit: ?metadata.Value = null,
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

const TotalKind = enum { track, disc };

/// The total a position's files state, the preferred file's first.
fn statedTotal(entries: []const Entry, members: []const usize, preferred: *const Entry, kind: TotalKind) ?i64 {
    const pick = struct {
        fn total(entry: *const Entry, which: TotalKind) ?i64 {
            const value = switch (which) {
                .track => entry.track_total,
                .disc => entry.disc_total,
            } orelse return null;
            return if (value > 0) value else null;
        }
    };
    if (pick.total(preferred, kind)) |value| return value;
    for (members) |index| {
        if (pick.total(&entries[index], kind)) |value| return value;
    }
    return null;
}

fn countedTrackTotal(positions: []const Position, disc: i64) i64 {
    var count: i64 = 0;
    var highest: i64 = 0;
    for (positions) |position| {
        if (position.disc != disc) continue;
        count += 1;
        highest = @max(highest, position.number);
    }
    return @max(count, highest);
}

/// The advisory a position's files state, the preferred file's first.
fn statedAdvisory(entries: []const Entry, members: []const usize, preferred: *const Entry) metadata.Explicit {
    if (preferred.explicit) |value| return value;
    for (members) |index| {
        if (entries[index].explicit) |value| return value;
    }
    return .unknown;
}

/// The genres a position's files state: the preferred file's, else those of
/// the lowest-numbered file that states any, as migration 33 chose them.
fn statedGenres(entries: []const Entry, members: []const usize, preferred: *const Entry) []const []const u8 {
    if (preferred.genres.len != 0) return preferred.genres;
    var chosen: ?*const Entry = null;
    for (members) |index| {
        const entry = &entries[index];
        if (entry.genres.len == 0) continue;
        if (chosen == null or entry.file_id < chosen.?.file_id) chosen = entry;
    }
    return if (chosen) |entry| entry.genres else &.{};
}

/// A resolved Track: one position on a Release, and the files that encode it.
/// A query built on this must bind the unreadable-file kind to `?4`.
const entry_select =
    \\SELECT l.file_id, l.uri, l.state, f.audio_format, f.bit_depth,
    \\       f.sample_rate, f.duration_ms, f.recording_id,
    \\       t.title, t.artist, t.album, t.album_artist,
    \\       t.track_number, t.disc_number, t.date, t.compilation,
    \\       t.musicbrainz_release_id, t.musicbrainz_recording_id,
    \\       t.musicbrainz_artist_id, t.musicbrainz_album_artist_id,
    \\       COALESCE(t.artwork_byte_size, 0) > 0 AND t.artwork_mime_type IS NOT NULL,
    \\       t.track_total, t.disc_total, t.explicit, t.release_type,
    \\       t.artwork_width, t.artwork_height, t.artwork_hash,
    \\       EXISTS (SELECT 1 FROM library_health_issues h WHERE h.file_id = l.file_id AND h.kind = ?4)
    \\FROM locations l
    \\JOIN files f ON f.id = l.file_id
    \\LEFT JOIN observed_file_tags t ON t.file_id = l.file_id
    \\
;

const Position = struct {
    disc: i64,
    number: i64,
    entries: std.ArrayList(usize) = .empty,
};

const Folder = struct {
    volume_id: i64,
    path: []const u8,
};

/// Only the projecting thread touches `ids`; `count` is the one field another
/// thread may read.
pub const FoundReleases = struct {
    ids: std.AutoHashMapUnmanaged(i64, void) = .empty,
    count: std.atomic.Value(u64) = .init(0),

    fn note(self: *FoundReleases, allocator: std.mem.Allocator, release_id: i64) !void {
        if ((try self.ids.getOrPut(allocator, release_id)).found_existing) return;
        self.count.store(self.ids.count(), .release);
    }

    fn forget(self: *FoundReleases, release_ids: []const i64) void {
        for (release_ids) |release_id| _ = self.ids.remove(release_id);
        self.count.store(self.ids.count(), .release);
    }

    pub fn freeIds(self: *FoundReleases, allocator: std.mem.Allocator) void {
        self.ids.deinit(allocator);
        self.ids = .empty;
    }
};

pub const Projection = struct {
    allocator: std.mem.Allocator,
    library: *database.LibraryDatabase,
    found_releases: ?*FoundReleases = null,
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
        if (folders.len != 0) try self.pruneGenres();
        return result;
    }

    /// Deletes the Tracks this folder's files used to back and no longer do:
    /// rows whose preferred file is one of `entries` and which no position
    /// claimed, because that file now presents another Track or none.
    /// Releases and Artists those rows, or the moved and evicted ones,
    /// referenced are then deleted if nothing else still references them.
    /// Everything deleted here is derived, and the next projection rebuilds
    /// it.
    fn pruneStale(
        self: *Projection,
        allocator: std.mem.Allocator,
        entries: []const Entry,
        claims: *const TrackClaims,
        vacated: *Vacated,
        genres: *database.GenreWriter,
        result: *Result,
    ) !void {
        const db = self.library.database;
        var candidates = try db.prepare("SELECT id, release_id, artist_id FROM tracks WHERE preferred_file_id = ?1;");
        defer candidates.deinit();
        var delete_track = try db.prepare("DELETE FROM tracks WHERE id = ?1;");
        defer delete_track.deinit();

        for (entries) |entry| {
            try candidates.bindInt64(1, entry.file_id);
            var stale: std.ArrayList(i64) = .empty;
            while (try candidates.step() == .row) {
                const track_id = candidates.columnInt64(0);
                if (claims.contains(track_id)) continue;
                try stale.append(allocator, track_id);
                try vacated.record(allocator, entry.file_id, optionalInt64(candidates, 1), optionalInt64(candidates, 2));
            }
            try candidates.reset();
            for (stale.items) |track_id| {
                try genres.carryUser(track_id, entry.file_id);
                try delete_track.bindInt64(1, track_id);
                if (try delete_track.step() != .done) return error.SqlFailed;
                try delete_track.reset();
                result.tracks_pruned += 1;
            }
        }
        try carryReleaseState(db, allocator, vacated.moved.items);
        var deleted_releases: std.ArrayList(i64) = .empty;
        defer deleted_releases.deinit(allocator);
        const pruned = try database.repository.pruneOrphanedReleasesAndArtists(
            db,
            allocator,
            vacated.releases.items,
            vacated.artists.items,
            if (self.found_releases != null) &deleted_releases else null,
        );
        if (self.found_releases) |found| found.forget(deleted_releases.items);
        result.releases_pruned += pruned.releases;
        result.artists_pruned += pruned.artists;
    }

    /// Deletes the genres the run left without a Track, once rather than per
    /// folder, because it reads every genre.
    fn pruneGenres(self: *Projection) !void {
        self.library.write_lane.acquire();
        defer self.library.write_lane.release();
        try self.library.database.exec("BEGIN IMMEDIATE;");
        errdefer self.library.database.exec("ROLLBACK;") catch {};
        try database.repository.pruneOrphanGenresLocked(self.library.database);
        try self.library.database.exec("COMMIT;");
    }

    /// Runs after `pruneStale`, because a cover carried to a Release by a
    /// regrouping counts for its files. Refreshes `has_folder_cover` for the
    /// Releases the folder's files now project to and those they left.
    fn settleArtwork(self: *Projection, allocator: std.mem.Allocator, entries: []const Entry, vacated: []const i64) !void {
        var refreshed: std.AutoHashMapUnmanaged(i64, void) = .empty;
        defer refreshed.deinit(allocator);
        for (entries) |entry| try refreshed.put(allocator, entry.release_id, {});
        for (vacated) |release_id| try refreshed.put(allocator, release_id, {});
        var release_ids = refreshed.keyIterator();
        while (release_ids.next()) |release_id|
            _ = try database.repository.refreshFolderCoverLocked(self.library.database, release_id.*);

        var facts: std.AutoHashMapUnmanaged(i64, database.repository.ReleaseArtworkFacts) = .empty;
        defer facts.deinit(allocator);
        for (entries) |entry| {
            const release = try facts.getOrPut(allocator, entry.release_id);
            if (!release.found_existing)
                release.value_ptr.* = try database.repository.loadReleaseArtworkFacts(self.library.database, entry.release_id);
            try database.repository.settleFileArtworkLocked(self.library.database, entry.file_id, entry.embedded_artwork, release.value_ptr.*);
        }
    }

    fn clearProjectionIssues(self: *Projection, file_id: i64) !void {
        const kinds = [_]database.HealthIssueKind{ .missing_metadata, .album_artist_anomaly, .missing_track_number, .artwork_problem };
        for (kinds) |kind| try self.library.health_issues.clearLocked(file_id, kind);
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
        const tagged_release = if (entry.musicbrainz_release_id) |tag| (if (tag.len == 0) null else tag) else null;
        entry.musicbrainz_release_id = resolvedText(tagged_release, extra.musicbrainz_release_id, self.policy);
        const tagged_advisory = if (entry.explicit) |advisory| advisory.advisoryText() else null;
        if (resolvedText(tagged_advisory, extra.explicit, self.policy)) |text|
            entry.explicit = metadata.Explicit.fromAdvisoryText(text) orelse entry.explicit;
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
        var readable: std.ArrayList(Entry) = .empty;
        for (entries) |entry| if (!entry.unreadable) try readable.append(allocator, entry);
        const projected = readable.items;

        self.library.write_lane.acquire();
        defer self.library.write_lane.release();
        try self.library.database.exec("BEGIN IMMEDIATE;");
        errdefer self.library.database.exec("ROLLBACK;") catch {};
        var genres: database.GenreWriter = try .init(self.library.database);
        defer genres.deinit();
        var claims: TrackClaims = try .prepare(self.library.database);
        defer claims.deinit();

        // Every group claims its files' Tracks before any group claims by
        // recording or writes: a file can leave one group's Release for
        // another's in one edit, and the group handled first would otherwise
        // take or evict the Track that file still presents.
        var plans: std.ArrayList(GroupPlan) = .empty;
        var start: usize = 0;
        while (start < projected.len) {
            var end = start + 1;
            while (end < projected.len and
                std.mem.eql(u8, projected[end].album_key, projected[start].album_key)) end += 1;
            try plans.append(allocator, try self.planGroup(allocator, folder, projected[start..end], entries, &claims, result));
            result.groups_projected += 1;
            start = end;
        }
        var seats: std.ArrayList(Seat) = .empty;
        var writes: std.ArrayList(database.TrackSeat) = .empty;
        var foreign: std.ArrayList(Entry) = .empty;
        for (plans.items) |plan| try self.resolveGroup(allocator, plan, &claims, &seats, &writes, &foreign, result);
        var vacated: Vacated = .{};
        try self.writeTracks(allocator, seats.items, writes.items, &claims, &vacated, &genres, result);
        for (entries) |entry| if (entry.unreadable) try self.clearProjectionIssues(entry.file_id);
        const backing = try std.mem.concat(allocator, Entry, &.{ entries, foreign.items });
        try self.pruneStale(allocator, backing, &claims, &vacated, &genres, result);
        try self.settleArtwork(allocator, projected, vacated.releases.items);
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
        var statement = try self.library.database.prepare(entry_select ++
            \\WHERE l.volume_id = ?1 AND l.uri >= ?2 AND l.uri < ?3
            \\  AND rtrim(l.uri, replace(l.uri, '/', '')) = ?2
            \\ORDER BY l.uri;
        );
        defer statement.deinit();
        try statement.bindInt64(1, folder.volume_id);
        try statement.bindText(2, folder.path);
        try statement.bindText(3, try upperBound(allocator, folder.path));
        try statement.bindInt64(4, @intFromEnum(database.HealthIssueKind.unreadable_file));
        return self.readEntries(allocator, statement);
    }

    fn loadForeign(
        self: *Projection,
        allocator: std.mem.Allocator,
        folder: Folder,
        release_id: i64,
        album_key: []const u8,
        folder_files: []const Entry,
    ) ![]Entry {
        var statement = try self.library.database.prepare(entry_select ++
            \\WHERE l.file_id IN (
            \\  SELECT f2.id FROM tracks r JOIN files f2 ON f2.recording_id = r.recording_id
            \\  WHERE r.release_id = ?1
            \\  UNION ALL
            \\  SELECT r.preferred_file_id FROM tracks r WHERE r.release_id = ?1
            \\)
            \\AND NOT (l.volume_id = ?2 AND rtrim(l.uri, replace(l.uri, '/', '')) = ?3)
            \\ORDER BY l.file_id, l.state = 'present' DESC, l.uri;
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        try statement.bindInt64(2, folder.volume_id);
        try statement.bindText(3, folder.path);
        try statement.bindInt64(4, @intFromEnum(database.HealthIssueKind.unreadable_file));
        const candidates = try self.readEntries(allocator, statement);

        var foreign: std.ArrayList(Entry) = .empty;
        var previous: ?i64 = null;
        for (candidates) |candidate| {
            if (previous == candidate.file_id) continue;
            previous = candidate.file_id;
            if (candidate.unreadable) continue;
            if (!std.mem.eql(u8, candidate.album_key, album_key)) continue;
            const local = for (folder_files) |entry| {
                if (entry.file_id == candidate.file_id) break true;
            } else false;
            if (local) continue;
            var entry = candidate;
            entry.foreign = true;
            try foreign.append(allocator, entry);
        }
        return foreign.toOwnedSlice(allocator);
    }

    fn readEntries(self: *Projection, allocator: std.mem.Allocator, statement: database.sqlite.Statement) ![]Entry {
        var overrides = try self.library.database.prepare(
            \\SELECT field, value, provenance, locked
            \\FROM orca_metadata_values WHERE file_id = ?1;
        );
        defer overrides.deinit();

        var genres = try self.library.database.prepare(
            "SELECT value FROM observed_file_genres WHERE file_id = ?1 ORDER BY ordinal;",
        );
        defer genres.deinit();

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
                    .musicbrainz_release_id => extra.musicbrainz_release_id = value,
                    .explicit => extra.explicit = value,
                    .musicbrainz_recording_id,
                    .musicbrainz_release_group_id,
                    .musicbrainz_release_track_id,
                    .musicbrainz_album_artist_id,
                    .composer,
                    .comment,
                    => {},
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
                .unreadable = statement.columnInt64(28) != 0,
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
                .embedded_artwork = if (statement.columnInt64(20) == 0) null else .{
                    .width = database.columns.countColumn(statement, 25),
                    .height = database.columns.countColumn(statement, 26),
                    .hash = optionalInt64(statement, 27),
                },
                .track_total = optionalInt64(statement, 21),
                .disc_total = optionalInt64(statement, 22),
                .explicit = if (statement.columnIsNull(23))
                    null
                else
                    std.enums.fromInt(metadata.Explicit, statement.columnInt64(23)),
                .release_type = try dupeNullable(allocator, statement, 24),
            };
            self.applyExtraOverrides(&entry, extra);
            var values: std.ArrayList([]const u8) = .empty;
            try genres.bindInt64(1, file_id);
            while (try genres.step() == .row) try values.append(allocator, try allocator.dupe(u8, genres.columnText(0)));
            try genres.reset();
            entry.genres = values.items;
            entry.missing_metadata = health.missingMetadata(entry.title, entry.artist, entry.album);
            // A blank row helps nobody find their music; the filename often
            // carries the title the tags lack.
            if (entry.title.len == 0) {
                entry.title = filenameStem(uri);
                entry.title_from_filename = true;
            }
            try entries.append(allocator, entry);
        }
        return entries.toOwnedSlice(allocator);
    }

    /// Resolves one `(folder, album key)` group's Release and positions, and
    /// claims the Tracks its files present.
    fn planGroup(
        self: *Projection,
        allocator: std.mem.Allocator,
        folder: Folder,
        local: []Entry,
        folder_files: []const Entry,
        claims: *TrackClaims,
        result: *Result,
    ) !GroupPlan {
        const identity = try self.resolveRelease(allocator, folder, local);
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
            .release_type = identity.release_type,
        });
        result.releases_written += 1;
        if (self.found_releases) |found| try found.note(self.allocator, release_id);
        if (identity.is_compilation) result.compilations += 1;

        for (local) |*entry| entry.release_id = release_id;
        const foreign = try self.loadForeign(allocator, folder, release_id, local[0].album_key, folder_files);
        const entries = if (foreign.len == 0) local else merged: {
            const all = try std.mem.concat(allocator, Entry, &.{ local, foreign });
            std.mem.sort(Entry, all, {}, lessByGroup);
            break :merged all;
        };
        try assignPositions(allocator, entries);
        const positions = try groupByPosition(allocator, entries);
        const held = try allocator.alloc(?Claim, positions.len);
        for (positions, held) |position, *claim|
            claim.* = try claims.byMembers(allocator, entries, position.entries.items);
        return .{
            .identity = identity,
            .release_id = release_id,
            .entries = entries,
            .positions = positions,
            .claims = held,
        };
    }

    /// Resolves each of a group's positions to the Track it writes, and
    /// settles its files' recordings and health issues.
    fn resolveGroup(
        self: *Projection,
        allocator: std.mem.Allocator,
        plan: GroupPlan,
        claims: *TrackClaims,
        seats: *std.ArrayList(Seat),
        writes: *std.ArrayList(database.TrackSeat),
        foreign_files: *std.ArrayList(Entry),
        result: *Result,
    ) !void {
        const entries = plan.entries;
        const identity = plan.identity;
        for (plan.positions, plan.claims) |position, held| {
            const members = position.entries.items;
            const lead = &entries[members[0]];
            const artist_id = try self.ensureArtist(allocator, lead.artist, lead.artist_mbid);

            const recording_id = try self.resolveRecording(entries, members, if (held) |claim| claim.recording_id else null);
            const claim = held orelse try claims.byRecording(allocator, plan.release_id, recording_id);
            const preferred = &entries[bestEncoding(entries, members)];
            try seats.append(allocator, .{
                .release_id = plan.release_id,
                .disc = position.disc,
                .number = position.number,
                .claim = claim,
                .genres = statedGenres(entries, members, preferred),
            });
            try writes.append(allocator, .{
                .id = if (claim) |existing| existing.track_id else null,
                .track = .{
                    .recording_id = recording_id,
                    .release_id = plan.release_id,
                    .artist_id = artist_id,
                    .title = lead.title,
                    .artist = lead.artist,
                    .album = identity.title,
                    .album_artist = identity.album_artist,
                    .duration_ms = preferred.duration_ms,
                    .track_number = position.number,
                    .disc_number = position.disc,
                    .preferred_file_id = preferred.file_id,
                    .track_total = statedTotal(entries, members, preferred, .track) orelse
                        countedTrackTotal(plan.positions, position.disc),
                    .disc_total = statedTotal(entries, members, preferred, .disc) orelse identity.disc_count,
                    .explicit = statedAdvisory(entries, members, preferred),
                },
            });

            for (members) |index| {
                const entry = &entries[index];
                entry.release_id = plan.release_id;
                try self.library.files.setRecordingLocked(entry.file_id, recording_id);
                try self.library.health_issues.settleLocked(
                    entry.file_id,
                    .missing_metadata,
                    entry.missing_metadata,
                );
                try self.library.health_issues.settleLocked(
                    entry.file_id,
                    .album_artist_anomaly,
                    health.albumArtistAnomaly(entry.album, entry.album_artist),
                );
                if (entry.synthetic) {
                    if (!entry.foreign) result.synthetic_positions += 1;
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
                    if (!entry.foreign) result.displaced_positions += 1;
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
                if (entry.foreign) {
                    try foreign_files.append(allocator, entry.*);
                    continue;
                }
                if (entry.title_from_filename) result.filename_titles += 1;
                result.files_projected += 1;
            }
        }
    }

    /// Writes every position the folder projects to. A row standing on one
    /// that no position claimed is parked, and deleted as pruning would once
    /// the rest are seated by id, so each Track keeps the file it presents
    /// wherever that file now lands.
    fn writeTracks(
        self: *Projection,
        allocator: std.mem.Allocator,
        seats: []const Seat,
        writes: []database.TrackSeat,
        claims: *TrackClaims,
        vacated: *Vacated,
        genres: *database.GenreWriter,
        result: *Result,
    ) !void {
        const db = self.library.database;
        var occupant = try db.prepare(
            \\SELECT id, preferred_file_id, artist_id FROM tracks
            \\WHERE release_id = ?1 AND COALESCE(disc_number, 1) = ?2 AND track_number = ?3;
        );
        defer occupant.deinit();
        var park = try db.prepare("UPDATE tracks SET track_number = NULL WHERE id = ?1;");
        defer park.deinit();
        var delete_track = try db.prepare("DELETE FROM tracks WHERE id = ?1;");
        defer delete_track.deinit();
        const Resident = struct { track_id: i64, file_id: ?i64, artist_id: ?i64 };
        var evicted: std.ArrayList(Resident) = .empty;
        for (seats) |seat| {
            try occupant.bindInt64(1, seat.release_id);
            try occupant.bindInt64(2, seat.disc);
            try occupant.bindInt64(3, seat.number);
            const found: ?Resident = if (try occupant.step() == .row) .{
                .track_id = occupant.columnInt64(0),
                .file_id = optionalInt64(occupant, 1),
                .artist_id = optionalInt64(occupant, 2),
            } else null;
            try occupant.reset();
            const resident = found orelse continue;
            if (claims.contains(resident.track_id)) continue;
            try vacated.record(allocator, resident.file_id, seat.release_id, resident.artist_id);
            try park.bindInt64(1, resident.track_id);
            if (try park.step() != .done) return error.SqlFailed;
            try park.reset();
            try evicted.append(allocator, resident);
        }
        for (seats, writes) |seat, write| {
            const claim = seat.claim orelse continue;
            if (!claim.moves(seat)) continue;
            try vacated.record(allocator, write.track.preferred_file_id, claim.release_id, claim.artist_id);
            result.tracks_moved += 1;
        }
        try self.library.tracks.seatTracksLocked(writes);
        for (seats, writes) |seat, write| {
            try claims.claimed.put(allocator, write.id.?, {});
            try genres.projectAt(allocator, seat.release_id, seat.disc, seat.number, seat.genres);
        }
        for (evicted.items) |resident| {
            if (resident.file_id) |file_id| try genres.carryUser(resident.track_id, file_id);
            try delete_track.bindInt64(1, resident.track_id);
            if (try delete_track.step() != .done) return error.SqlFailed;
            try delete_track.reset();
            result.tracks_pruned += 1;
        }
        result.tracks_written += @intCast(writes.len);
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
        const release_type = consensus(entries, releaseType);
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
            .release_type = release_type,
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
        entries: []const Entry,
        members: []const usize,
        claimed: ?i64,
    ) !i64 {
        const held = heldRecording(entries, members, claimed);
        for (members) |index| {
            if (entries[index].recording_id) |existing| {
                if (held != null and held != existing) continue;
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

    /// The recording the claimed Track already presents, when one of the
    /// members carries it, so the ratings and listens kept on that recording
    /// stay with the Track.
    fn heldRecording(entries: []const Entry, members: []const usize, claimed: ?i64) ?i64 {
        const recording_id = claimed orelse return null;
        for (members) |index| if (entries[index].recording_id == recording_id) return recording_id;
        return null;
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

fn releaseType(entry: Entry) ?[]const u8 {
    return entry.release_type;
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
///   different performance. Both are defects in the tags, and both are common.
///   Neither case may drop a song, and neither may leave the position null —
///   a null position has nothing to upsert on, so reprojecting would duplicate
///   the row forever. The file takes the next free number on its disc in
///   filename order and the fabrication is raised as a health issue rather
///   than applied silently.
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

const dupeNullable = database.columns.dupeNullable;
const optionalInt64 = database.columns.optionalInt64;

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

const scalar = database.columns.scalar;

fn filesWithIssue(library: *database.LibraryDatabase, kind: database.HealthIssueKind) ![]i64 {
    var issues = try library.health_issues.page(testing.allocator, 256, 0);
    defer issues.deinit();
    var files: std.ArrayList(i64) = .empty;
    for (issues.items) |issue| {
        if (issue.kind == kind) try files.append(testing.allocator, issue.file_id);
    }
    return files.toOwnedSlice(testing.allocator);
}

test "the projection raises missing tags before falling back to the file name" {
    var library = try openTestLibrary("file:orca-projection-missing-tags?mode=memory&cache=shared");
    defer library.close();
    const untitled = try observe(&library, "/m/Artist/03 - Blue Monday.flac", .flac, .{
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 3,
    });
    _ = try observe(&library, "/m/Artist/04 - Thieves.flac", .flac, .{
        .title = "Thieves",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 4,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    const first = try projection.run(.all);
    try testing.expectEqual(@as(u64, 1), first.filename_titles);
    const flagged = try filesWithIssue(&library, .missing_metadata);
    defer testing.allocator.free(flagged);
    try testing.expectEqualSlices(i64, &.{untitled}, flagged);

    try library.orca_metadata.upsert(.{
        .file_id = untitled,
        .field = .title,
        .value = "Blue Monday",
        .provenance = .user,
        .locked = true,
    });
    _ = try projection.run(.{ .files = &.{untitled} });
    const after = try filesWithIssue(&library, .missing_metadata);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(i64, &.{}, after);
}

test "an album without an album artist is an anomaly and a file with no album is not" {
    var library = try openTestLibrary("file:orca-projection-album-artist-anomaly?mode=memory&cache=shared");
    defer library.close();
    const no_album_artist = try observe(&library, "/m/Artist/a.flac", .flac, .{
        .title = "A",
        .artist = "Artist",
        .album = "Album",
        .track_number = 1,
    });
    const no_album = try observe(&library, "/m/Loose/b.flac", .flac, .{
        .title = "B",
        .artist = "Artist",
        .track_number = 1,
    });
    _ = try observe(&library, "/m/Other/c.flac", .flac, .{
        .title = "C",
        .artist = "Artist",
        .album = "Other",
        .album_artist = "Artist",
        .track_number = 1,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const anomalies = try filesWithIssue(&library, .album_artist_anomaly);
    defer testing.allocator.free(anomalies);
    try testing.expectEqualSlices(i64, &.{no_album_artist}, anomalies);
    const untagged = try filesWithIssue(&library, .missing_metadata);
    defer testing.allocator.free(untagged);
    try testing.expectEqualSlices(i64, &.{no_album}, untagged);
}

test "a fetched cover clears the release's artwork problem" {
    var library = try openTestLibrary("file:orca-projection-artwork-problem?mode=memory&cache=shared");
    defer library.close();
    const tags: metadata.ObservedTags = .{
        .title = "Bare",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 1,
    };
    const bare = try observe(&library, "/m/Artist/bare.flac", .flac, tags);
    var covered_tags = tags;
    covered_tags.title = "Covered";
    covered_tags.track_number = 2;
    covered_tags.artwork = .{ .mime_type = "image/png", .byte_size = 128, .kind = .front_cover };
    _ = try observe(&library, "/m/Artist/covered.flac", .flac, covered_tags);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const before = try filesWithIssue(&library, .artwork_problem);
    defer testing.allocator.free(before);
    try testing.expectEqualSlices(i64, &.{bare}, before);

    const release_id = try scalar(library.database, "SELECT id FROM releases;");
    try library.release_artwork.put(release_id, "2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b", null, 1_800_000_000);
    const after_miss = try filesWithIssue(&library, .artwork_problem);
    defer testing.allocator.free(after_miss);
    try testing.expectEqualSlices(i64, &.{bare}, after_miss);

    try library.release_artwork.put(release_id, "2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b", .{
        .bytes = "\xff\xd8\xff\xe0fetched",
        .mime_type = "image/jpeg",
    }, 1_800_000_000);
    const after_fetch = try filesWithIssue(&library, .artwork_problem);
    defer testing.allocator.free(after_fetch);
    try testing.expectEqualSlices(i64, &.{}, after_fetch);

    _ = try projection.run(.all);
    const after_reprojection = try filesWithIssue(&library, .artwork_problem);
    defer testing.allocator.free(after_reprojection);
    try testing.expectEqualSlices(i64, &.{}, after_reprojection);
}

test "a front image in the release's folder counts as its cover, and a back image does not" {
    var library = try openTestLibrary("file:orca-projection-folder-cover?mode=memory&cache=shared");
    defer library.close();
    const bare = try observe(&library, "/m/Artist/bare.flac", .flac, .{
        .title = "Bare",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 1,
    });
    try library.database.exec(std.fmt.comptimePrint(
        \\INSERT INTO folder_images(volume_id, uri, mime, role, size_bytes, modified_ns) VALUES
        \\    ({d}, '/m/Artist/back.jpg', 'image/jpeg', 1, 10, 0);
    , .{database.LibraryDatabase.null_volume}));
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const before = try filesWithIssue(&library, .artwork_problem);
    defer testing.allocator.free(before);
    try testing.expectEqualSlices(i64, &.{bare}, before);

    try library.database.exec("UPDATE folder_images SET role = 0, uri = '/m/Artist/cover.jpg';");
    _ = try projection.run(.all);
    const after = try filesWithIssue(&library, .artwork_problem);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(i64, &.{}, after);
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
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT is_compilation FROM releases;"));
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
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT is_compilation FROM releases;"));
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
    try testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT disc_count FROM releases;"));
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
        try scalar(library.database, "SELECT track_number FROM tracks WHERE title='Stray';"),
    );
    const flagged = try filesWithIssue(&library, .missing_track_number);
    defer testing.allocator.free(flagged);
    try testing.expectEqualSlices(i64, &.{stray}, flagged);
}

test "two songs claiming one track number both stay in the library" {
    var library = try openTestLibrary("file:orca-projection-collision?mode=memory&cache=shared");
    defer library.close();
    // Two files of one album both tagged track 4, so the position model alone
    // would list three songs, not four.
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
        try scalar(library.database, "SELECT track_number FROM tracks WHERE title LIKE '%instrumental%';"),
    );
    const flagged = try filesWithIssue(&library, .technical_anomaly);
    defer testing.allocator.free(flagged);
    try testing.expectEqualSlices(i64, &.{displaced}, flagged);
}

test "an unreadable file projects no Track until its bytes read, and loses its Track when they stop reading" {
    var library = try openTestLibrary("file:orca-projection-unreadable?mode=memory&cache=shared");
    defer library.close();
    const tags: metadata.ObservedTags = .{
        .title = "Song",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 1,
    };
    const readable = try observe(&library, "/m/Album/01.flac", .flac, tags);
    const broken = try observe(&library, "/m/Album/02.flac", .flac, .{});
    const unreadable: database.HealthIssueInput = .{
        .kind = .unreadable_file,
        .severity = .warning,
        .details = "Not a valid FLAC stream",
    };
    try library.health_issues.recordLocked(broken, unreadable);

    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM tracks;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM releases;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM artists;"));
    var page = try trackTitles(&library);
    defer page.deinit();
    try testing.expectEqualStrings("Song", page.items[0].title);
    try testing.expectEqualStrings("Album", page.items[0].album);
    const missing = try filesWithIssue(&library, .missing_metadata);
    defer testing.allocator.free(missing);
    try testing.expectEqualSlices(i64, &.{}, missing);

    try library.health_issues.clearLocked(broken, .unreadable_file);
    var second = tags;
    second.title = "Other";
    second.track_number = 2;
    try library.observed_tags.upsert(.{ .file_id = broken, .values = second });
    _ = try projection.run(.{ .files = &.{broken} });
    try testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT count(*) FROM tracks;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM releases;"));

    try library.health_issues.recordLocked(readable, unreadable);
    try library.health_issues.recordLocked(broken, unreadable);
    const result = try projection.run(.{ .files = &.{ readable, broken } });
    try testing.expectEqual(@as(u64, 2), result.tracks_pruned);
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT count(*) FROM tracks;"));
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT count(*) FROM releases;"));
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT count(*) FROM artists;"));
    try testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT count(*) FROM locations;"));
    const artwork = try filesWithIssue(&library, .artwork_problem);
    defer testing.allocator.free(artwork);
    try testing.expectEqualSlices(i64, &.{}, artwork);
    const still_unreadable = try filesWithIssue(&library, .unreadable_file);
    defer testing.allocator.free(still_unreadable);
    try testing.expectEqual(@as(usize, 2), still_unreadable.len);
    try expectNoForeignKeyViolations(&library);
}

fn butterflyTags(title: []const u8, track_number: u32) metadata.ObservedTags {
    return .{
        .title = title,
        .artist = "Kendrick Lamar",
        .album = "To Pimp a Butterfly",
        .album_artist = "Kendrick Lamar",
        .track_number = track_number,
    };
}

const orphaned_files_sql =
    "SELECT count(*) FROM files f WHERE NOT EXISTS " ++
    "(SELECT 1 FROM tracks t WHERE t.recording_id = f.recording_id);";

test "two encodings of one song in different folders of one album share one Track" {
    var library = try openTestLibrary("file:orca-projection-cross-folder-encodings?mode=memory&cache=shared");
    defer library.close();
    _ = try observe(&library, "/m/Music/Kendrick/01 Wesley's Theory.flac", .flac, butterflyTags("Wesley's Theory", 1));
    const flac = try observe(&library, "/m/Music/Kendrick/07 Alright.flac", .flac, butterflyTags("Alright", 7));
    const mp3 = try observe(&library, "/m/Downloads/Kendrick/Alright.mp3", .mp3, butterflyTags("Alright", 7));

    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.{ .files = &.{flac} });
    _ = try projection.run(.{ .files = &.{mp3} });

    try testing.expectEqual(@as(u64, 2), try library.tracks.count());
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, orphaned_files_sql));
    try testing.expectEqual(flac, try scalar(library.database, "SELECT preferred_file_id FROM tracks WHERE track_number = 7;"));
    var buffer: [128]u8 = undefined;
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, try std.fmt.bufPrintSentinel(
        &buffer,
        "SELECT count(DISTINCT recording_id) FROM files WHERE id IN ({d}, {d});",
        .{ flac, mp3 },
        0,
    )));
    try expectNoForeignKeyViolations(&library);
}

test "two songs claiming one track number in different folders of one album both stay in the library" {
    var library = try openTestLibrary("file:orca-projection-cross-folder-displaced?mode=memory&cache=shared");
    defer library.close();
    const first = try observe(&library, "/m/A/Oasis/04 Oasis.flac", .flac, butterflyTags("Oasis", 4));
    const second = try observe(&library, "/m/B/Oasis/04 Prism.flac", .flac, butterflyTags("Prism", 4));

    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.{ .files = &.{first} });
    _ = try projection.run(.{ .files = &.{second} });

    try testing.expectEqual(@as(u64, 2), try library.tracks.count());
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, orphaned_files_sql));
    try testing.expectEqual(@as(i64, 4), try positionOf(&library, first));
    try testing.expectEqual(@as(i64, 1), try positionOf(&library, second));
    const flagged = try filesWithIssue(&library, .technical_anomaly);
    defer testing.allocator.free(flagged);
    try testing.expectEqualSlices(i64, &.{second}, flagged);

    _ = try projection.run(.all);
    try testing.expectEqual(@as(i64, 4), try positionOf(&library, first));
    try testing.expectEqual(@as(i64, 1), try positionOf(&library, second));
    try expectNoForeignKeyViolations(&library);
}

test "a file left without a Track joins it again and keeps the Track's rating" {
    var library = try openTestLibrary("file:orca-projection-cross-folder-rating?mode=memory&cache=shared");
    defer library.close();
    const flac = try observe(&library, "/m/A/Kendrick/07 Alright.flac", .flac, butterflyTags("Alright", 7));
    const mp3 = try observe(&library, "/m/B/Kendrick/Alright.mp3", .mp3, butterflyTags("Alright", 7));
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.{ .files = &.{mp3} });
    const track = try trackOf(&library, mp3);
    _ = try library.ratings.set(&.{track}, 100);
    const stranded = try library.recordings.insertLocked(.{ .title = "Alright", .duration_ms = null });
    try library.files.setRecordingLocked(flac, stranded);

    _ = try projection.run(.all);
    try testing.expectEqual(@as(u64, 1), try library.tracks.count());
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, orphaned_files_sql));
    try testing.expectEqual(track, try trackOf(&library, flac));
    try testing.expectEqual(
        @as(i64, 100),
        try scalar(library.database, "SELECT rating FROM ratings JOIN tracks USING (recording_id);"),
    );
}

fn projectFoldersInOrder(name: [:0]const u8, music_first: bool) ![]u8 {
    var library = try openTestLibrary(name);
    defer library.close();
    const flac = try observeEncoding(&library, "/m/Music/Kendrick/07 Alright.flac", .flac, .{ .bit_depth = 16, .sample_rate = 44100 }, butterflyTags("Alright", 7));
    const music_other = try observe(&library, "/m/Music/Kendrick/04 Institutionalized.flac", .flac, butterflyTags("Institutionalized", 4));
    const mp3 = try observeEncoding(&library, "/m/Downloads/Kendrick/Alright.mp3", .mp3, .{ .sample_rate = 44100 }, butterflyTags("Alright", 7));
    _ = try observe(&library, "/m/Downloads/Kendrick/04 These Walls.mp3", .mp3, butterflyTags("These Walls", 4));
    _ = music_other;

    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    const order: [2]i64 = if (music_first) .{ flac, mp3 } else .{ mp3, flac };
    for (order) |file_id| _ = try projection.run(.{ .files = &.{file_id} });
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, orphaned_files_sql));

    var statement = try library.database.prepare(
        \\SELECT group_concat(line, ';') FROM (
        \\  SELECT t.track_number || ' ' || t.title || ' ' || l.uri || ' ' ||
        \\         (SELECT count(*) FROM files f WHERE f.recording_id = t.recording_id) AS line
        \\  FROM tracks t JOIN locations l ON l.file_id = t.preferred_file_id
        \\  ORDER BY t.track_number, t.title
        \\);
    );
    defer statement.deinit();
    try testing.expectEqual(database.sqlite.Step.row, try statement.step());
    return testing.allocator.dupe(u8, statement.columnText(0));
}

test "projecting an album's folders in either order gives the same Tracks and preferred files" {
    const music_first = try projectFoldersInOrder("file:orca-projection-order-music?mode=memory&cache=shared", true);
    defer testing.allocator.free(music_first);
    const downloads_first = try projectFoldersInOrder("file:orca-projection-order-downloads?mode=memory&cache=shared", false);
    defer testing.allocator.free(downloads_first);
    try testing.expectEqualStrings(music_first, downloads_first);
    try testing.expectEqualStrings(
        "1 Institutionalized /m/Music/Kendrick/04 Institutionalized.flac 1;" ++
            "4 These Walls /m/Downloads/Kendrick/04 These Walls.mp3 1;" ++
            "7 Alright /m/Music/Kendrick/07 Alright.flac 2",
        music_first,
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
        try scalar(library.database, "SELECT preferred_file_id FROM tracks;"),
    );
    try testing.expectEqual(
        @as(i64, 2),
        try scalar(library.database, "SELECT count(*) FROM files WHERE recording_id IS NOT NULL;"),
    );
    _ = mp3;
}

test "a love survives its Track moving to another Release" {
    var library = try openTestLibrary("file:orca-projection-feedback?mode=memory&cache=shared");
    defer library.close();
    const file_id = try observe(&library, "/m/Artist/one.flac", .flac, .{
        .title = "One",
        .artist = "Artist",
        .album = "First Album",
        .album_artist = "Artist",
        .track_number = 1,
    });
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const before = try scalar(library.database, "SELECT id FROM tracks;");
    _ = try library.feedback.set(&.{before}, .loved);

    try library.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = "One",
        .artist = "Artist",
        .album = "Second Album",
        .album_artist = "Artist",
        .track_number = 1,
    } });
    _ = try projection.run(.all);

    const after = try scalar(library.database, "SELECT id FROM tracks;");
    try testing.expectEqual(before, after);
    try testing.expectEqual(@as(u64, 1), try library.tracks.count());
    try testing.expectEqual(database.Feedback.loved, try library.feedback.forTrack(after));
    const summary = (try library.tracks.byId(testing.allocator, after)).?;
    defer summary.deinit(testing.allocator);
    try testing.expectEqual(database.Feedback.loved, summary.feedback);
    try testing.expectEqual(try scalar(library.database, "SELECT recording_id FROM tracks;"), summary.recording_id.?);
}

test "a hate survives reprojecting a Track backed by two encodings" {
    var library = try openTestLibrary("file:orca-projection-feedback-encodings?mode=memory&cache=shared");
    defer library.close();
    const tags = metadata.ObservedTags{
        .title = "One",
        .artist = "Artist",
        .album = "Album",
        .album_artist = "Artist",
        .track_number = 1,
    };
    _ = try observe(&library, "/m/Artist/one.mp3", .mp3, tags);
    _ = try observe(&library, "/m/Artist/one.flac", .flac, tags);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const track = try scalar(library.database, "SELECT id FROM tracks;");
    _ = try library.feedback.set(&.{track}, .hated);

    _ = try projection.run(.all);

    try testing.expectEqual(database.Feedback.hated, try library.feedback.forTrack(track));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM feedback;"));
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
    const identifiers = try scalar(library.database, "SELECT sum(id) FROM tracks;");

    _ = try projection.run(.all);
    try testing.expectEqual(tracks, try library.tracks.count());
    try testing.expectEqual(releases, try library.releases.count());
    try testing.expectEqual(recordings, try library.recordings.count());
    try testing.expectEqual(artists, try library.artists.count());
    try testing.expectEqual(identifiers, try scalar(library.database, "SELECT sum(id) FROM tracks;"));
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
        "Glory",
        "Portishead",
        "Dummy",
        "Collective",
    }) |query| {
        var page = try library.tracks.search(testing.allocator, query, .{ .limit = 8 });
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
        try scalar(library.database, "SELECT preferred_file_id FROM tracks;"),
    );
    try testing.expectEqual(
        @as(i64, 213_040),
        try scalar(library.database, "SELECT duration_ms FROM tracks;"),
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
        try scalar(library.database, "SELECT count(*) FROM tracks WHERE artist_id IS NULL;"),
    );
    try testing.expectEqual(
        @as(i64, 0),
        try scalar(library.database, "SELECT count(*) FROM releases WHERE album_artist_id IS NULL;"),
    );
    // The featured credit resolves to the band, because its MusicBrainz artist
    // id outranks the name it was tagged with.
    const band = try artistIdOf(&library, "The Band");
    try testing.expectEqual(@as(i64, 3), try scalar(
        library.database,
        "SELECT count(*) FROM tracks WHERE artist_id=(SELECT id FROM artists WHERE name='The Band');",
    ));
    var page = try library.tracks.page(testing.allocator, .{ .artist_id = band, .limit = 16 });
    defer page.deinit();
    try testing.expectEqual(@as(usize, 3), page.items.len);
}

test "the artist browse order files a name by its sort key rather than its leading article" {
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

    const projected = try scalar(library.database, browse_fingerprint);
    // Exactly the state a version-8 database is in: the columns exist, and
    // nothing has ever filled them.
    try library.database.exec(
        \\UPDATE tracks SET artist_id=NULL;
        \\UPDATE releases SET album_artist_id=NULL;
        \\UPDATE artists SET sort_name=NULL;
    );
    try testing.expect(projected != try scalar(library.database, browse_fingerprint));

    try database.migrations.registerKeyFunctions(library.database);
    try library.database.exec(database.migrations.artist_backfill);
    try testing.expectEqual(projected, try scalar(library.database, browse_fingerprint));
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

test "a retagged file keeps its Track while its old release and artist are pruned" {
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
    const track = try trackOf(&library, file_id);

    try library.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = "Song",
        .artist = "New Artist",
        .album = "New Album",
        .album_artist = "New Artist",
        .track_number = 1,
    } });
    const result = try projection.run(.{ .files = &.{file_id} });
    try testing.expectEqual(track, try trackOf(&library, file_id));
    try testing.expectEqual(@as(u64, 1), result.tracks_moved);
    try testing.expectEqual(@as(u64, 0), result.tracks_pruned);
    try testing.expectEqual(@as(u64, 1), result.releases_pruned);
    try testing.expectEqual(@as(u64, 1), result.artists_pruned);
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM tracks;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM releases;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM artists;"));
    var page = try trackTitles(&library);
    defer page.deinit();
    try testing.expectEqualStrings("New Album", page.items[0].album);
}

test "albums found counts only the releases a run wrote that still exist" {
    var library = try openTestLibrary("file:orca-projection-found-releases?mode=memory&cache=shared");
    defer library.close();
    const file_id = try observe(&library, "/m/Old/a.flac", .flac, .{
        .title = "Song",
        .artist = "Artist",
        .album = "Old Album",
        .album_artist = "Artist",
        .track_number = 1,
    });
    var found: FoundReleases = .{};
    defer found.freeIds(testing.allocator);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library, .found_releases = &found };
    _ = try projection.run(.{ .files = &.{file_id} });
    try testing.expectEqual(@as(u64, 1), found.count.load(.acquire));

    try library.observed_tags.upsert(.{ .file_id = file_id, .values = .{
        .title = "Song",
        .artist = "Artist",
        .album = "New Album",
        .album_artist = "Artist",
        .track_number = 1,
    } });
    const result = try projection.run(.{ .files = &.{file_id} });
    try testing.expectEqual(@as(u64, 1), result.releases_written);
    try testing.expectEqual(@as(u64, 1), result.releases_pruned);
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM releases;"));
    try testing.expectEqual(@as(u64, 1), found.count.load(.acquire));
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
    try testing.expectEqual(@as(u64, 1), result.tracks_moved);
    try testing.expectEqual(@as(u64, 0), result.tracks_pruned);
    try testing.expectEqual(@as(u64, 0), result.releases_pruned);
    try testing.expectEqual(@as(u64, 0), result.artists_pruned);
    try testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT count(*) FROM tracks;"));
    try testing.expectEqual(@as(i64, 3), try scalar(library.database, "SELECT max(track_number) FROM tracks;"));
}

fn positionOf(library: *database.LibraryDatabase, file_id: i64) !i64 {
    var buffer: [96]u8 = undefined;
    return scalar(library.database, try std.fmt.bufPrintSentinel(
        &buffer,
        "SELECT track_number FROM tracks WHERE preferred_file_id = {d};",
        .{file_id},
        0,
    ));
}

test "two files swapping track numbers each keep their Track at the position they now state" {
    var library = try openTestLibrary("file:orca-projection-swap?mode=memory&cache=shared");
    defer library.close();
    var files: [2]i64 = undefined;
    try observeAlbum(&library, &files, "Album");
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const tracks: [2]i64 = .{ try trackOf(&library, files[0]), try trackOf(&library, files[1]) };

    try library.observed_tags.upsert(.{ .file_id = files[0], .values = albumTags("Album", 2) });
    try library.observed_tags.upsert(.{ .file_id = files[1], .values = albumTags("Album", 1) });
    const result = try projection.run(.all);

    for (files, tracks) |file_id, track| try testing.expectEqual(track, try trackOf(&library, file_id));
    try testing.expectEqual(@as(i64, 2), try positionOf(&library, files[0]));
    try testing.expectEqual(@as(i64, 1), try positionOf(&library, files[1]));
    try testing.expectEqual(@as(u64, 2), result.tracks_moved);
    try testing.expectEqual(@as(u64, 0), result.tracks_pruned);
    try testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT count(*) FROM tracks;"));
    try expectNoForeignKeyViolations(&library);
}

/// Projects `files` as tracks 1 to n of one album, renumbers them to
/// `numbers`, and checks every file kept its Track and lost none.
fn expectRenumberingKeepsTracks(name: [:0]const u8, comptime numbers: []const u32) !void {
    var library = try openTestLibrary(name);
    defer library.close();
    var files: [numbers.len]i64 = undefined;
    try observeAlbum(&library, &files, "Album");
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    var tracks: [numbers.len]i64 = undefined;
    for (files, &tracks) |file_id, *track| track.* = try trackOf(&library, file_id);

    for (files, numbers) |file_id, number|
        try library.observed_tags.upsert(.{ .file_id = file_id, .values = albumTags("Album", number) });
    const result = try projection.run(.all);

    for (files, tracks, numbers) |file_id, track, number| {
        try testing.expectEqual(track, try trackOf(&library, file_id));
        try testing.expectEqual(@as(i64, number), try positionOf(&library, file_id));
    }
    try testing.expectEqual(@as(u64, numbers.len), result.tracks_moved);
    try testing.expectEqual(@as(u64, 0), result.tracks_pruned);
    try testing.expectEqual(@as(i64, numbers.len), try scalar(library.database, "SELECT count(*) FROM tracks;"));
    try expectNoForeignKeyViolations(&library);
}

test "three files rotating track numbers each keep their Track" {
    try expectRenumberingKeepsTracks("file:orca-projection-rotate?mode=memory&cache=shared", &.{ 2, 3, 1 });
}

test "files shifted one track number up each keep their Track" {
    try expectRenumberingKeepsTracks("file:orca-projection-shift?mode=memory&cache=shared", &.{ 2, 3, 4 });
}

test "a file moving onto a position another Track holds keeps its own Track and the occupant is pruned" {
    var library = try openTestLibrary("file:orca-projection-takeover?mode=memory&cache=shared");
    defer library.close();
    var files: [2]i64 = undefined;
    try observeAlbum(&library, &files, "Album");
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const own = try trackOf(&library, files[0]);

    try library.observed_tags.upsert(.{ .file_id = files[0], .values = albumTags("Album", 2) });
    try library.database.exec("DELETE FROM locations;");
    _ = try library.locations.upsert(.{
        .file_id = files[0],
        .volume_id = database.LibraryDatabase.null_volume,
        .uri = "/m/Artist/Album/1.flac",
        .state = .present,
    });
    const result = try projection.run(.all);

    try testing.expectEqual(own, try trackOf(&library, files[0]));
    try testing.expectEqual(@as(u64, 1), result.tracks_moved);
    try testing.expectEqual(@as(u64, 1), result.tracks_pruned);
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM tracks;"));
    try testing.expectEqual(@as(i64, 2), try positionOf(&library, files[0]));
    try expectNoForeignKeyViolations(&library);
}

test "a Track evicted from its position hands its user genres to the Track its file joins" {
    var library = try openTestLibrary("file:orca-projection-evict-genres?mode=memory&cache=shared");
    defer library.close();
    const mp3 = try observe(&library, "/m/Artist/Album/1.mp3", .mp3, albumTags("Album", 1));
    const second = try observe(&library, "/m/Artist/Album/2.flac", .flac, albumTags("Album", 2));
    const flac = try observe(&library, "/m/Artist/Album/3.flac", .flac, albumTags("Album", 3));
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const evicted = try trackOf(&library, mp3);
    const moving = try trackOf(&library, second);
    const joined = try trackOf(&library, flac);
    try library.genres.setTrackGenres(testing.allocator, &.{evicted}, &.{"Shoegaze"});

    try library.observed_tags.upsert(.{ .file_id = mp3, .values = albumTags("Album", 3) });
    try library.observed_tags.upsert(.{ .file_id = second, .values = albumTags("Album", 1) });
    const result = try projection.run(.all);

    try testing.expectEqual(moving, try trackOf(&library, second));
    try testing.expectEqual(@as(i64, 1), try positionOf(&library, second));
    try testing.expectEqual(joined, try trackOf(&library, flac));
    try testing.expectEqual(@as(i64, 3), try positionOf(&library, flac));
    try expectGenres(&library, joined, "Shoegaze");
    try testing.expectEqual(@as(u64, 1), result.tracks_moved);
    try testing.expectEqual(@as(u64, 1), result.tracks_pruned);
    try testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT count(*) FROM tracks;"));
    var buffer: [64]u8 = undefined;
    const gone = try std.fmt.bufPrintSentinel(&buffer, "SELECT count(*) FROM tracks WHERE id = {d};", .{evicted}, 0);
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, gone));
    try expectNoForeignKeyViolations(&library);
}

test "a file leaving its album keeps its Track while a sibling takes its old position" {
    var library = try openTestLibrary("file:orca-projection-leave-and-fill?mode=memory&cache=shared");
    defer library.close();
    var files: [2]i64 = undefined;
    try observeAlbum(&library, &files, "First");
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const tracks: [2]i64 = .{ try trackOf(&library, files[0]), try trackOf(&library, files[1]) };
    const first = try releaseOf(&library, files[0]);

    try library.observed_tags.upsert(.{ .file_id = files[0], .values = albumTags("Second", 1) });
    try library.observed_tags.upsert(.{ .file_id = files[1], .values = albumTags("First", 1) });
    const result = try projection.run(.all);

    for (files, tracks) |file_id, track| try testing.expectEqual(track, try trackOf(&library, file_id));
    try testing.expectEqual(first, try releaseOf(&library, files[1]));
    try testing.expect(try releaseOf(&library, files[0]) != first);
    try testing.expectEqual(@as(i64, 1), try positionOf(&library, files[0]));
    try testing.expectEqual(@as(i64, 1), try positionOf(&library, files[1]));
    try testing.expectEqual(@as(u64, 2), result.tracks_moved);
    try testing.expectEqual(@as(u64, 0), result.tracks_pruned);
    try expectNoForeignKeyViolations(&library);
}

test "a Track whose preferred file goes missing follows its other encoding to a new Release" {
    var library = try openTestLibrary("file:orca-projection-preferred-flip?mode=memory&cache=shared");
    defer library.close();
    var tags = albumTags("Album", 1);
    const flac = try observe(&library, "/m/Artist/Album/one.flac", .flac, tags);
    const mp3 = try observe(&library, "/m/Artist/Album/one.mp3", .mp3, tags);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const track = try trackOf(&library, flac);
    const old = try releaseOf(&library, flac);
    const recording = try scalar(library.database, "SELECT recording_id FROM tracks;");

    _ = try library.locations.upsert(.{
        .file_id = flac,
        .volume_id = database.LibraryDatabase.null_volume,
        .uri = "/m/Artist/Album/one.flac",
        .state = .missing,
    });
    tags.album = "Other";
    try library.observed_tags.upsert(.{ .file_id = flac, .values = tags });
    try library.observed_tags.upsert(.{ .file_id = mp3, .values = tags });
    const result = try projection.run(.all);

    try testing.expectEqual(track, try trackOf(&library, mp3));
    try testing.expect(try releaseOf(&library, mp3) != old);
    try testing.expectEqual(recording, try scalar(library.database, "SELECT recording_id FROM tracks;"));
    try testing.expectEqual(@as(u64, 1), result.tracks_moved);
    try testing.expectEqual(@as(u64, 0), result.tracks_pruned);
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM tracks;"));
    try expectNoForeignKeyViolations(&library);
}

test "a Track's rating, love and playlist entries stay with its song when the songs swap positions" {
    var library = try openTestLibrary("file:orca-projection-swap-recording-state?mode=memory&cache=shared");
    defer library.close();
    var one = albumTags("Album", 1);
    one.title = "One";
    var two = albumTags("Album", 2);
    two.title = "Two";
    const first = try observe(&library, "/m/Artist/Album/a.flac", .flac, one);
    const second = try observe(&library, "/m/Artist/Album/b.flac", .flac, two);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const track_one = try trackOf(&library, first);
    const track_two = try trackOf(&library, second);
    _ = try library.ratings.set(&.{track_one}, 100);
    _ = try library.ratings.set(&.{track_two}, 20);
    _ = try library.feedback.set(&.{track_one}, .loved);
    const playlist = try library.playlists.create("Mix");
    _ = try library.playlists.insert(playlist, &.{track_one}, null);

    one.track_number = 2;
    two.track_number = 1;
    try library.observed_tags.upsert(.{ .file_id = first, .values = one });
    try library.observed_tags.upsert(.{ .file_id = second, .values = two });
    _ = try projection.run(.all);

    try testing.expectEqual(track_one, try trackOf(&library, first));
    try testing.expectEqual(@as(?u8, 100), try library.ratings.forTrack(track_one));
    try testing.expectEqual(@as(?u8, 20), try library.ratings.forTrack(track_two));
    try testing.expectEqual(database.repository.Feedback.loved, try library.feedback.forTrack(track_one));
    try testing.expectEqual(database.repository.Feedback.none, try library.feedback.forTrack(track_two));
    const listed = try library.playlists.trackIds(testing.allocator, playlist, .{ .now = 0, .seed = 0 });
    defer testing.allocator.free(listed);
    try testing.expectEqualSlices(i64, &.{track_one}, listed);
    var buffer: [64]u8 = undefined;
    const title = try std.fmt.bufPrintSentinel(&buffer, "SELECT track_number FROM tracks WHERE id = {d};", .{track_one}, 0);
    try testing.expectEqual(@as(i64, 2), try scalar(library.database, title));
}

test "a Track's lyrics survive its file moving it to another Release" {
    var library = try openTestLibrary("file:orca-projection-move-lyrics?mode=memory&cache=shared");
    defer library.close();
    var files: [1]i64 = undefined;
    try observeAlbum(&library, &files, "Old Title");
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const track = try trackOf(&library, files[0]);
    const digest: [32]u8 = @splat(1);
    try testing.expect(try library.track_lyrics.put(track, &digest, .{ .plain = "words" }, 100));

    try retag(&library, &files, "New Title");
    const result = try projection.run(.all);

    try testing.expectEqual(@as(u64, 1), result.tracks_moved);
    try testing.expectEqual(track, try trackOf(&library, files[0]));
    const stored = (try library.track_lyrics.get(testing.allocator, track)).?;
    defer stored.deinit();
    try testing.expectEqualStrings("words", stored.record.plain.?);
    try expectNoForeignKeyViolations(&library);
}

test "a moved album keeps its Track ids, even onto positions the new Release holds, and hands it its cover and love" {
    var library = try openTestLibrary("file:orca-projection-move-carry?mode=memory&cache=shared");
    defer library.close();
    var files: [3]i64 = undefined;
    try observeAlbum(&library, &files, "Old Title");
    var resident_tags = albumTags("New Title", 1);
    resident_tags.title = "Resident";
    const resident = try observe(&library, "/m/Artist/Old Title/resident.flac", .flac, resident_tags);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const old = try releaseOf(&library, files[0]);
    const resident_release = try releaseOf(&library, resident);
    const resident_track = try trackOf(&library, resident);
    var tracks: [3]i64 = undefined;
    for (files, &tracks) |file_id, *track| track.* = try trackOf(&library, file_id);
    _ = try library.release_loves.set(&.{old}, true);
    try library.release_artwork.put(old, "2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b", .{
        .bytes = "\xff\xd8\xff\xe0fetched",
        .mime_type = "image/jpeg",
    }, 1_800_000_000);

    try retag(&library, &files, "New Title");
    resident_tags.track_number = 4;
    try library.observed_tags.upsert(.{ .file_id = resident, .values = resident_tags });
    const result = try projection.run(.all);

    const moved = try releaseOf(&library, files[0]);
    try testing.expect(moved != old);
    try testing.expectEqual(resident_release, moved);
    for (files, tracks) |file_id, track| try testing.expectEqual(track, try trackOf(&library, file_id));
    try testing.expectEqual(resident_track, try trackOf(&library, resident));
    try testing.expectEqual(@as(i64, 4), try positionOf(&library, resident));
    try testing.expectEqual(@as(u64, 4), result.tracks_moved);
    try testing.expectEqual(@as(u64, 0), result.tracks_pruned);
    try testing.expectEqual(@as(u64, 1), result.releases_pruned);
    try testing.expect(try library.release_loves.isLoved(moved));
    try testing.expectEqual(moved, try scalar(library.database, "SELECT release_id FROM release_artwork;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM releases;"));
    try expectNoForeignKeyViolations(&library);
}

fn albumTags(album: []const u8, track_number: u32) metadata.ObservedTags {
    return .{
        .title = "Song",
        .artist = "Artist",
        .album = album,
        .album_artist = "Artist",
        .track_number = track_number,
    };
}

fn observeAlbum(library: *database.LibraryDatabase, files: []i64, album: []const u8) !void {
    for (files, 1..) |*file_id, track_number| {
        var uri_buffer: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&uri_buffer, "/m/Artist/{s}/{d}.flac", .{ album, track_number });
        file_id.* = try observe(library, uri, .flac, albumTags(album, @intCast(track_number)));
    }
}

fn retag(library: *database.LibraryDatabase, files: []const i64, album: []const u8) !void {
    for (files) |file_id| {
        var buffer: [96]u8 = undefined;
        const track_number = try scalar(library.database, try std.fmt.bufPrintSentinel(
            &buffer,
            "SELECT track_number FROM tracks WHERE preferred_file_id = {d};",
            .{file_id},
            0,
        ));
        try library.observed_tags.upsert(.{ .file_id = file_id, .values = albumTags(album, @intCast(track_number)) });
    }
}

fn releaseOf(library: *database.LibraryDatabase, file_id: i64) !i64 {
    var buffer: [96]u8 = undefined;
    return scalar(library.database, try std.fmt.bufPrintSentinel(
        &buffer,
        "SELECT release_id FROM tracks WHERE preferred_file_id = {d};",
        .{file_id},
        0,
    ));
}

test "a loved album stays loved when a regrouping gives its Release a new id" {
    var library = try openTestLibrary("file:orca-projection-love-regroup?mode=memory&cache=shared");
    defer library.close();
    var files: [2]i64 = undefined;
    try observeAlbum(&library, &files, "Old Title");
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const old = try releaseOf(&library, files[0]);
    _ = try library.release_loves.set(&.{old}, true);
    try library.database.exec("UPDATE release_loves SET loved_at = 100;");

    try retag(&library, &files, "New Title");
    _ = try projection.run(.all);

    const regrouped = try releaseOf(&library, files[0]);
    try testing.expect(regrouped != old);
    try testing.expect(try library.release_loves.isLoved(regrouped));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM release_loves;"));
    try testing.expectEqual(@as(i64, 100), try scalar(library.database, "SELECT loved_at FROM release_loves;"));
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT count(*) FROM feedback;"));
    try expectNoForeignKeyViolations(&library);
}

test "two loved Releases merging into one leave exactly one love" {
    var library = try openTestLibrary("file:orca-projection-love-merge?mode=memory&cache=shared");
    defer library.close();
    var first: [2]i64 = undefined;
    try observeAlbum(&library, &first, "Disc One");
    var second: [2]i64 = undefined;
    try observeAlbum(&library, &second, "Disc Two");
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    _ = try library.release_loves.set(&.{ try releaseOf(&library, first[0]), try releaseOf(&library, second[0]) }, true);

    try retag(&library, &first, "Merged");
    for (second, 3..) |file_id, track_number| {
        try library.observed_tags.upsert(.{ .file_id = file_id, .values = albumTags("Merged", @intCast(track_number)) });
    }
    _ = try projection.run(.all);

    const merged = try releaseOf(&library, first[0]);
    try testing.expectEqual(merged, try releaseOf(&library, second[0]));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM releases;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM release_loves;"));
    try testing.expect(try library.release_loves.isLoved(merged));
    try expectNoForeignKeyViolations(&library);
}

test "a split album's love goes to the Release that took most of its Tracks, and to the lower id on a tie" {
    for ([_]u32{ 7, 5 }) |kept| {
        var library = try openTestLibrary("file:orca-projection-love-split?mode=memory&cache=shared");
        defer library.close();
        var files: [10]i64 = undefined;
        try observeAlbum(&library, &files, "Whole");
        var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
        _ = try projection.run(.all);
        _ = try library.release_loves.set(&.{try releaseOf(&library, files[0])}, true);

        try retag(&library, files[0..kept], "Larger");
        try retag(&library, files[kept..], "Smaller");
        _ = try projection.run(.all);

        const larger = try releaseOf(&library, files[0]);
        const smaller = try releaseOf(&library, files[9]);
        try testing.expect(larger != smaller);
        const heir = if (kept > 10 - kept) larger else @min(larger, smaller);
        try testing.expect(try library.release_loves.isLoved(heir));
        try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM release_loves;"));
        try testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT count(*) FROM releases;"));
    }
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
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM releases WHERE release_date = '2024';"));
}

fn observeUnderRoot(
    library: *database.LibraryDatabase,
    root_id: i64,
    uri: []const u8,
    values: metadata.ObservedTags,
) !i64 {
    const file_id = try library.files.create(.{
        .audio_format = @intFromEnum(storage.AudioFormat.flac),
        .size_bytes = 1024,
    });
    try locateUnderRoot(library, root_id, file_id, uri);
    try library.observed_tags.upsert(.{ .file_id = file_id, .values = values });
    return file_id;
}

fn locateUnderRoot(library: *database.LibraryDatabase, root_id: i64, file_id: i64, uri: []const u8) !void {
    _ = try library.locations.upsert(.{
        .file_id = file_id,
        .volume_id = database.LibraryDatabase.null_volume,
        .root_id = root_id,
        .uri = uri,
        .state = .present,
    });
}

fn expectNoForeignKeyViolations(library: *database.LibraryDatabase) !void {
    var statement = try library.database.prepare("PRAGMA foreign_key_check;");
    defer statement.deinit();
    try testing.expectEqual(database.sqlite.Step.done, try statement.step());
}

fn singleArtistTags(artist: []const u8, title: []const u8, track_number: u32) metadata.ObservedTags {
    return .{
        .title = title,
        .artist = artist,
        .album = artist,
        .album_artist = artist,
        .track_number = track_number,
    };
}

test "removing a root forgets its tracks, releases and artists" {
    var library = try openTestLibrary("file:orca-projection-remove-root?mode=memory&cache=shared");
    defer library.close();
    const removed_root = try library.library_roots.add(database.LibraryDatabase.null_volume, "/m/Old");
    const kept_root = try library.library_roots.add(database.LibraryDatabase.null_volume, "/m/Kept");
    _ = try observeUnderRoot(&library, removed_root, "/m/Old/1.flac", singleArtistTags("Old Artist", "One", 1));
    _ = try observeUnderRoot(&library, removed_root, "/m/Old/2.flac", singleArtistTags("Old Artist", "Two", 2));
    _ = try observeUnderRoot(&library, kept_root, "/m/Kept/1.flac", singleArtistTags("Kept Artist", "Three", 1));
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    try testing.expectEqual(@as(i64, 3), try scalar(library.database, "SELECT count(*) FROM tracks;"));

    const removal = try library.library_roots.remove(testing.allocator, removed_root);
    defer removal.deinit();
    try testing.expectEqual(@as(u64, 2), removal.files_forgotten);
    try testing.expectEqual(@as(u64, 2), removal.tracks_removed);
    try testing.expectEqual(@as(usize, 0), removal.surviving_file_ids.len);

    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM tracks;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM releases;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM artists;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM files;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM observed_file_tags;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM locations;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM library_roots;"));
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT count(*) FROM artists WHERE name = 'Old Artist';"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM track_search WHERE track_search MATCH 'Three';"));
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT count(*) FROM track_search WHERE track_search MATCH 'One';"));
    try expectNoForeignKeyViolations(&library);
}

test "removing a root keeps a file that another root still locates" {
    var library = try openTestLibrary("file:orca-projection-remove-root-shared?mode=memory&cache=shared");
    defer library.close();
    const removed_root = try library.library_roots.add(database.LibraryDatabase.null_volume, "/m/Old");
    const kept_root = try library.library_roots.add(database.LibraryDatabase.null_volume, "/m/Kept");
    const shared = try observeUnderRoot(&library, removed_root, "/m/Old/1.flac", singleArtistTags("Artist", "One", 1));
    try locateUnderRoot(&library, kept_root, shared, "/m/Kept/1.flac");
    const only_under_removed = try observeUnderRoot(&library, removed_root, "/m/Old/2.flac", singleArtistTags("Artist", "Two", 2));
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);

    const removal = try library.library_roots.remove(testing.allocator, removed_root);
    defer removal.deinit();
    try testing.expectEqual(@as(u64, 1), removal.files_forgotten);
    try testing.expectEqualSlices(i64, &.{shared}, removal.surviving_file_ids);
    _ = try projection.run(.{ .files = removal.surviving_file_ids });

    var statement = try library.database.prepare("SELECT (SELECT count(*) FROM files WHERE id = ?1), (SELECT count(*) FROM files WHERE id = ?2);");
    defer statement.deinit();
    try statement.bindInt64(1, shared);
    try statement.bindInt64(2, only_under_removed);
    try testing.expectEqual(database.sqlite.Step.row, try statement.step());
    try testing.expectEqual(@as(i64, 1), statement.columnInt64(0));
    try testing.expectEqual(@as(i64, 0), statement.columnInt64(1));

    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM tracks;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM releases;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM locations WHERE uri = '/m/Kept/1.flac';"));
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT count(*) FROM locations WHERE uri LIKE '/m/Old/%';"));
    try expectNoForeignKeyViolations(&library);
}

test "removing a root keeps the undo journal of its files" {
    var library = try openTestLibrary("file:orca-projection-remove-root-journal?mode=memory&cache=shared");
    defer library.close();
    const root = try library.library_roots.add(database.LibraryDatabase.null_volume, "/m/Old");
    const file_id = try observeUnderRoot(&library, root, "/m/Old/1.flac", singleArtistTags("Artist", "One", 1));
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const operation_id = try library.mutation_journal.prepare(.{
        .plan_id = 1,
        .group_id = 1,
        .action_index = 0,
        .kind = .write_tags,
        .file_id = file_id,
        .source_path = "/m/Old/1.flac",
        .expected_size = 1024,
        .expected_modified_ns = 0,
        .expected_quick_hash = std.mem.zeroes(storage.QuickHash),
    });

    const removal = try library.library_roots.remove(testing.allocator, root);
    defer removal.deinit();
    try testing.expectEqual(@as(u64, 1), removal.files_forgotten);

    var operation = try library.mutation_journal.get(testing.allocator, operation_id);
    defer operation.deinit();
    try testing.expectEqual(@as(?i64, null), operation.file_id);
    try testing.expectEqualStrings("/m/Old/1.flac", operation.source_path);
    try expectNoForeignKeyViolations(&library);
}

test "removing a root keeps the listens of its files with no file" {
    var library = try openTestLibrary("file:orca-projection-remove-root-listens?mode=memory&cache=shared");
    defer library.close();
    const removed_root = try library.library_roots.add(database.LibraryDatabase.null_volume, "/m/Old");
    const kept_root = try library.library_roots.add(database.LibraryDatabase.null_volume, "/m/Kept");
    const removed_file = try observeUnderRoot(&library, removed_root, "/m/Old/1.flac", singleArtistTags("Old Artist", "One", 1));
    const kept_file = try observeUnderRoot(&library, kept_root, "/m/Kept/1.flac", singleArtistTags("Kept Artist", "Two", 1));
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    for ([_]i64{ removed_file, kept_file }) |file_id| {
        _ = try library.listens.record(.{
            .file_id = file_id,
            .started_at = 1_700_000_000,
            .listened_ms = 100_000,
            .title = "Heard",
            .artist = "Someone",
        });
    }

    const removal = try library.library_roots.remove(testing.allocator, removed_root);
    defer removal.deinit();

    try testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT count(*) FROM listens;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM listens WHERE file_id IS NULL;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM listens WHERE file_id IS NOT NULL;"));
    try expectNoForeignKeyViolations(&library);
}

test "removing an unknown root is refused" {
    var library = try openTestLibrary("file:orca-projection-remove-root-unknown?mode=memory&cache=shared");
    defer library.close();
    const root = try library.library_roots.add(database.LibraryDatabase.null_volume, "/m/Kept");
    _ = try observeUnderRoot(&library, root, "/m/Kept/1.flac", singleArtistTags("Artist", "One", 1));
    try testing.expectError(
        error.UnknownRoot,
        library.library_roots.remove(testing.allocator, root + 1000),
    );
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM locations;"));
    try testing.expectEqual(@as(i64, 1), try scalar(library.database, "SELECT count(*) FROM library_roots;"));
}

fn genreNames(library: *database.LibraryDatabase, track_id: i64) ![]const u8 {
    var names = try library.genres.forTrack(testing.allocator, track_id);
    defer names.deinit();
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(testing.allocator);
    for (names.items, 0..) |name, index| {
        if (index != 0) try joined.appendSlice(testing.allocator, "; ");
        try joined.appendSlice(testing.allocator, name.name);
    }
    return joined.toOwnedSlice(testing.allocator);
}

fn expectGenres(library: *database.LibraryDatabase, track_id: i64, expected: []const u8) !void {
    const names = try genreNames(library, track_id);
    defer testing.allocator.free(names);
    try testing.expectEqualStrings(expected, names);
}

fn trackOf(library: *database.LibraryDatabase, file_id: i64) !i64 {
    var buffer: [96]u8 = undefined;
    return scalar(library.database, try std.fmt.bufPrintSentinel(
        &buffer,
        "SELECT id FROM tracks WHERE preferred_file_id = {d};",
        .{file_id},
        0,
    ));
}

test "the projection gives a Track its file's folded genres and follows the file when it is retagged" {
    var library = try openTestLibrary("file:orca-projection-genres?mode=memory&cache=shared");
    defer library.close();
    var tags = albumTags("Album", 1);
    tags.genres = &.{ "Hip-Hop/Rap", "hip hop", "R&B/Soul" };
    const first = try observe(&library, "/m/Artist/Album/1.flac", .flac, tags);
    tags.track_number = 2;
    tags.genres = &.{"HipHop"};
    const second = try observe(&library, "/m/Artist/Album/2.flac", .flac, tags);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);

    try expectGenres(&library, try trackOf(&library, first), "Hip Hop; R&B/Soul");
    try expectGenres(&library, try trackOf(&library, second), "Hip Hop");
    try testing.expectEqual(@as(i64, 2), try scalar(library.database, "SELECT count(*) FROM genres;"));

    tags.track_number = 1;
    tags.genres = &.{"Jazz"};
    try library.observed_tags.upsert(.{ .file_id = first, .values = tags });
    _ = try projection.run(.{ .files = &.{first} });
    try expectGenres(&library, try trackOf(&library, first), "Jazz");
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT count(*) FROM genres WHERE name = 'R&B/Soul';"));

    tags.genres = &.{};
    try library.observed_tags.upsert(.{ .file_id = first, .values = tags });
    _ = try projection.run(.{ .files = &.{first} });
    try expectGenres(&library, try trackOf(&library, first), "");
    try expectNoForeignKeyViolations(&library);
}

test "the projection splits a file's comma and semicolon genre lists while the observed value stays whole" {
    var library = try openTestLibrary("file:orca-projection-split-genres?mode=memory&cache=shared");
    defer library.close();
    var tags = albumTags("Album", 1);
    tags.genres = &.{ "Indie Rock, Rock, Alternative Rock", "Folk, World, & Country; rock" };
    const file = try observe(&library, "/m/Artist/Album/1.flac", .flac, tags);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);

    try expectGenres(&library, try trackOf(&library, file), "Indie Rock; Rock; Alternative Rock; Folk, World, & Country");
    try testing.expectEqual(@as(i64, 1), try scalar(
        library.database,
        "SELECT count(*) FROM observed_file_genres WHERE value = 'Indie Rock, Rock, Alternative Rock';",
    ));
    try expectNoForeignKeyViolations(&library);
}

test "user genres split a listed name and refuse more than the per-Track limit after splitting" {
    var library = try openTestLibrary("file:orca-projection-user-split-genres?mode=memory&cache=shared");
    defer library.close();
    const file = try observe(&library, "/m/Artist/Album/1.flac", .flac, albumTags("Album", 1));
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const track = try trackOf(&library, file);

    try library.genres.setTrackGenres(testing.allocator, &.{track}, &.{ "Shoegaze, Dream Pop", "shoegaze" });
    try expectGenres(&library, track, "Shoegaze; Dream Pop");
    try testing.expectError(error.InvalidGenre, library.genres.setTrackGenres(testing.allocator, &.{track}, &.{ "Jazz", " ; , " }));
    try testing.expectError(
        error.TooManyGenres,
        library.genres.setTrackGenres(testing.allocator, &.{track}, &.{ "A, B, C, D, E, F, G, H", "I; J; K; L; M; N; O; P; Q" }),
    );
    try expectGenres(&library, track, "Shoegaze; Dream Pop");
}

test "a Track's user genres outrank its file's on a rescan and follow it to a new Release" {
    var library = try openTestLibrary("file:orca-projection-user-genres?mode=memory&cache=shared");
    defer library.close();
    var files: [1]i64 = undefined;
    var tags = albumTags("Old Title", 1);
    tags.genres = &.{"Rock"};
    files[0] = try observe(&library, "/m/Artist/Old Title/1.flac", .flac, tags);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);
    const old = try trackOf(&library, files[0]);
    try library.genres.setTrackGenres(testing.allocator, &.{old}, &.{ "Shoegaze", "dream pop" });
    try expectGenres(&library, old, "Shoegaze; Dream Pop");

    tags.genres = &.{"Metal"};
    try library.observed_tags.upsert(.{ .file_id = files[0], .values = tags });
    _ = try projection.run(.all);
    try testing.expectEqual(old, try trackOf(&library, files[0]));
    try expectGenres(&library, old, "Shoegaze; Dream Pop");

    tags.album = "New Title";
    try library.observed_tags.upsert(.{ .file_id = files[0], .values = tags });
    _ = try projection.run(.all);
    const moved = try trackOf(&library, files[0]);
    try testing.expectEqual(old, moved);
    try expectGenres(&library, moved, "Shoegaze; Dream Pop");
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT count(*) FROM genres WHERE name IN ('Rock', 'Metal');"));

    try library.genres.setTrackGenres(testing.allocator, &.{moved}, &.{});
    try expectGenres(&library, moved, "Metal");
    try testing.expectEqual(@as(i64, 0), try scalar(library.database, "SELECT count(*) FROM genres WHERE name = 'Shoegaze';"));
    try expectNoForeignKeyViolations(&library);
}

test "a genre lists only its Tracks, their Releases and the Artists owning them, with counts that agree" {
    var library = try openTestLibrary("file:orca-projection-genre-browse?mode=memory&cache=shared");
    defer library.close();
    var tags = albumTags("One", 1);
    tags.genres = &.{ "Rock", "Jazz" };
    _ = try observe(&library, "/m/Artist/One/1.flac", .flac, tags);
    tags.track_number = 2;
    tags.genres = &.{"Rock"};
    tags.artist = "Guest";
    _ = try observe(&library, "/m/Artist/One/2.flac", .flac, tags);
    tags = albumTags("Two", 1);
    tags.album_artist = "Other";
    tags.artist = "Other";
    tags.genres = &.{"Jazz"};
    _ = try observe(&library, "/m/Other/Two/1.flac", .flac, tags);
    var projection: Projection = .{ .allocator = testing.allocator, .library = &library };
    _ = try projection.run(.all);

    var genres = try library.genres.page(testing.allocator, .{ .sort = .track_count });
    defer genres.deinit();
    try testing.expectEqual(@as(usize, 2), genres.items.len);
    const jazz = genres.items[0];
    try testing.expectEqualStrings("Jazz", jazz.name);
    try testing.expectEqual(@as(u32, 2), jazz.track_count);
    try testing.expectEqual(@as(u32, 2), jazz.release_count);
    try testing.expectEqual(@as(u32, 2), jazz.artist_count);
    const rock = genres.items[1];
    try testing.expectEqualStrings("Rock", rock.name);
    try testing.expectEqual(@as(u32, 2), rock.track_count);
    try testing.expectEqual(@as(u32, 1), rock.release_count);
    try testing.expectEqual(@as(u32, 2), rock.artist_count);
    try testing.expectEqual(@as(u64, 1), try library.genres.count(testing.allocator, "ro"));

    for (genres.items) |genre| {
        const tracks = try library.tracks.countMatching(.{ .genre_id = genre.id });
        try testing.expectEqual(@as(u64, genre.track_count), tracks);
        var track_page = try library.tracks.page(testing.allocator, .{ .genre_id = genre.id, .sort = .title });
        defer track_page.deinit();
        try testing.expectEqual(@as(usize, genre.track_count), track_page.items.len);
        const releases = try library.releases.countMatching(.{ .genre_id = genre.id });
        try testing.expectEqual(@as(u64, genre.release_count), releases);
        var release_page = try library.releases.page(testing.allocator, .{ .genre_id = genre.id });
        defer release_page.deinit();
        try testing.expectEqual(@as(usize, genre.release_count), release_page.items.len);
        const artists = try library.artists.countMatching(.{ .genre_id = genre.id });
        try testing.expectEqual(@as(u64, genre.artist_count), artists);
        var artist_page = try library.artists.page(testing.allocator, .{ .genre_id = genre.id, .sort = .track_count });
        defer artist_page.deinit();
        try testing.expectEqual(@as(usize, genre.artist_count), artist_page.items.len);
        try testing.expect(artist_page.items[0].track_count >= artist_page.items[artist_page.items.len - 1].track_count);
    }

    var release_page = try library.releases.page(testing.allocator, .{ .genre_id = rock.id });
    defer release_page.deinit();
    var counts = try library.genres.forRelease(testing.allocator, release_page.items[0].id, 8);
    defer counts.deinit();
    try testing.expectEqual(@as(usize, 2), counts.items.len);
    try testing.expectEqualStrings("Rock", counts.items[0].name);
    try testing.expectEqual(@as(u32, 2), counts.items[0].track_count);
    var artwork = try library.genres.artworkReleases(testing.allocator, jazz.id, 8);
    defer artwork.deinit();
    try testing.expectEqual(@as(usize, 0), artwork.ids.len);
}
