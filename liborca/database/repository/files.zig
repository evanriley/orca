const std = @import("std");
const sqlite = @import("../sqlite.zig");
const quick_hash = @import("../../storage/quick_hash.zig");
const content_hash = @import("../../storage/content_hash.zig");
const columns = @import("../columns.zig");

const digestColumn = columns.digestColumn;
const max_page = columns.max_page;
const AnalysisCandidate = @import("analysis.zig").AnalysisCandidate;
const AnalysisCandidatePage = @import("analysis.zig").AnalysisCandidatePage;
const AnalysisSelectors = @import("analysis.zig").AnalysisSelectors;
const bindAnalysisSelectors = @import("analysis.zig").bindAnalysisSelectors;
const unanalyzed_predicate = @import("analysis.zig").unanalyzed_predicate;
const DuplicateCandidate = @import("duplicates.zig").DuplicateCandidate;
const DuplicateCandidatePage = @import("duplicates.zig").DuplicateCandidatePage;
const DuplicatePeer = @import("duplicates.zig").DuplicatePeer;
const StorageIdentityKey = @import("locations.zig").StorageIdentityKey;
const refresh_swept_folder_covers_sql = @import("locations.zig").refresh_swept_folder_covers_sql;
const ArtworkRole = @import("locations.zig").ArtworkRole;
const settleReleaseArtworkLocked = @import("artwork_problems.zig").settleReleaseLocked;
const available_location = @import("roots.zig").available_location;
const HealthIssueKind = @import("health.zig").HealthIssueKind;
const WriteLane = @import("write_lane.zig").WriteLane;

pub const FileUpsert = struct {
    audio_format: u8 = 0,
    codec: []const u8 = "",
    size_bytes: i64 = 0,
    sample_rate: ?i64 = null,
    bit_depth: ?i64 = null,
    channels: ?i64 = null,
    duration_ms: ?i64 = null,
    quick_hash: ?[]const u8 = null,
    audio_hash: ?[]const u8 = null,
    content_hash: ?[]const u8 = null,
    /// `fingerprint.AudioHashTier` of `audio_hash`. A hash without a tier is
    /// never evidence of exact audio.
    audio_hash_tier: ?u8 = null,
};

/// The `files` rows a property backfill still owes a probe.
///
/// This is textually **one** string, shared by migration 10's partial index
/// and by `FileRepository.incompletePropertiesPage`. SQLite uses a partial
/// index only when the query's WHERE clause contains the index's own
/// predicate, and it matches that by expression, not by meaning: a paraphrase
/// here would silently turn row selection into a full scan of the largest
/// table in the schema.
///
/// `bit_depth` is deliberately not one of the terms. A transform codec has no
/// integer sample width to declare, so a null there is an answer rather than a
/// gap, and including it would re-probe every lossy file on every run for ever.
pub const incomplete_properties_predicate =
    "duration_ms IS NULL OR sample_rate IS NULL OR channels IS NULL OR codec = ''";

pub const repairable_properties_count_sql =
    "SELECT count(*) FROM files WHERE files.id > 0 AND (" ++ incomplete_properties_predicate ++ ")\n" ++
    "  AND (?2 >> files.audio_format) & 1 = 0\n" ++
    "  AND NOT EXISTS (SELECT 1 FROM library_health_issues AS failed\n" ++
    "      WHERE failed.file_id = files.id AND failed.kind = ?3)\n" ++
    "  AND EXISTS (" ++ available_location ++ " held.file_id = files.id);";

/// `uri` in `[prefix/, prefix0)` is exactly the uris below `prefix/`, because
/// `0` is the byte after `/`, and as a range on the `(volume_id, uri)` unique
/// index it reads only that directory's rows. `+root_id` keeps the planner off
/// `locations_sweep`, which would read every row of the root.
pub const mark_missing_under_sql =
    \\UPDATE locations SET state='missing', missing_since=unixepoch()
    \\WHERE volume_id=?1 AND uri>=?2 || '/' AND uri<?2 || '0'
    \\    AND +root_id=?3 AND last_seen_generation<?4 AND state<>'missing';
;
const forget_images_under_sql =
    \\DELETE FROM folder_images
    \\WHERE volume_id=?1 AND uri>=?2 || '/' AND uri<?2 || '0'
    \\    AND +root_id=?3 AND last_seen_generation<?4;
;
const mark_missing_sql =
    \\UPDATE locations SET state='missing', missing_since=unixepoch()
    \\WHERE root_id=?1 AND last_seen_generation<?2 AND state<>'missing';
;
const forget_images_sql = "DELETE FROM folder_images WHERE root_id=?1 AND last_seen_generation<?2;";

fn sweptCoverReleasesSql(comptime swept: []const u8, comptime gone: []const u8) [:0]const u8 {
    const gone_folder = "rtrim(gone.uri, replace(gone.uri, '/', ''))";
    const front = std.fmt.comptimePrint("{d}", .{@backingInt(ArtworkRole.front)});
    return "INSERT OR IGNORE INTO temp.swept_cover_releases(id)\n" ++
        "SELECT tracks.release_id FROM locations JOIN tracks ON tracks.preferred_file_id = locations.file_id\n" ++
        "WHERE " ++ swept ++ " AND locations.state<>'missing' AND tracks.release_id IS NOT NULL\n" ++
        "UNION SELECT tracks.release_id FROM folder_images AS gone\n" ++
        "JOIN locations ON locations.volume_id = gone.volume_id AND locations.uri >= " ++ gone_folder ++ "\n" ++
        "    AND locations.uri < substr(" ++ gone_folder ++ ", 1, length(" ++ gone_folder ++ ") - 1) || '0'\n" ++
        "    AND rtrim(locations.uri, replace(locations.uri, '/', '')) = " ++ gone_folder ++ "\n" ++
        "JOIN tracks ON tracks.preferred_file_id = locations.file_id\n" ++
        "WHERE " ++ gone ++ " AND gone.role = " ++ front ++ " AND tracks.release_id IS NOT NULL;";
}

const swept_cover_releases_sql = sweptCoverReleasesSql(
    "locations.root_id=?1 AND locations.last_seen_generation<?2",
    "gone.root_id=?1 AND gone.last_seen_generation<?2",
);
const swept_cover_releases_under_sql = sweptCoverReleasesSql(
    "locations.volume_id=?1 AND locations.uri>=?2 || '/' AND locations.uri<?2 || '0'" ++
        " AND +locations.root_id=?3 AND locations.last_seen_generation<?4",
    "gone.volume_id=?1 AND gone.uri>=?2 || '/' AND gone.uri<?2 || '0'" ++
        " AND +gone.root_id=?3 AND gone.last_seen_generation<?4",
);

const SweepScope = struct {
    volume_id: i64 = 0,
    root_id: i64,
    generation: i64,
    prefix: ?[]const u8 = null,

    fn run(self: SweepScope, db: sqlite.Database, sql: [:0]const u8) !u64 {
        var statement = try db.prepare(sql);
        defer statement.deinit();
        if (self.prefix) |prefix| {
            try statement.bindInt64(1, self.volume_id);
            try statement.bindText(2, prefix);
            try statement.bindInt64(3, self.root_id);
            try statement.bindInt64(4, self.generation);
        } else {
            try statement.bindInt64(1, self.root_id);
            try statement.bindInt64(2, self.generation);
        }
        if (try statement.step() != .done) return error.SqlFailed;
        return db.changes();
    }
};

/// Audio facts a probe learned about one already-recorded file.
///
/// Narrower than `FileUpsert` on purpose: a backfill reads headers, so it has
/// nothing to say about size, container or quick hash, and must not overwrite
/// what the scanner observed about them with defaults it made up.
pub const FilePropertyUpdate = struct {
    codec: []const u8 = "",
    sample_rate: ?i64 = null,
    bit_depth: ?i64 = null,
    channels: ?i64 = null,
    duration_ms: ?i64 = null,
    /// The container the probe actually found, when it disagrees with what the
    /// row says. Null leaves the stored value alone, so a probe that could not
    /// determine the container never overwrites a good answer with a guess.
    audio_format: ?i64 = null,
};

/// Which file the bytes now at one path belong to.
pub const FileResolution = union(enum) {
    new,
    same: i64,
    /// A file still present at another path with other bytes than these: the
    /// path leaves it for a file of its own, forked from it.
    diverged: i64,
};

/// Most files recording one quick hash that tier 3 weighs for a path.
pub const max_nominees = 8;
/// Most locations of one such file whose bytes tier 3 reads.
pub const max_nominee_locations = 4;

/// What the bytes at one location hashed to, read before the transaction
/// that weighs them.
pub const MeasuredLocation = struct {
    volume_id: i64,
    uri: []const u8,
    bytes: MeasuredBytes,
};

pub const MeasuredBytes = union(enum) {
    /// Read whole while the location had `identity`.
    read: Read,
    /// Nothing is at the path.
    gone,
    /// Something is at the path and could not be read.
    unreadable,

    pub const Read = struct {
        identity: StorageIdentityKey,
        digest: content_hash.Digest,

        /// Whether these are the bytes a location recording `recorded` holds.
        pub fn holds(self: Read, recorded: ?StorageIdentityKey) bool {
            return if (recorded) |identity| std.meta.eql(identity, self.identity) else false;
        }
    };
};

/// The content hashes a resolution may weigh, all taken before its
/// transaction began, because nothing under the write lane reads a file.
pub const ContentEvidence = struct {
    /// The content hash of the bytes being resolved, when one was taken.
    own: ?*const content_hash.Digest = null,
    measured: []const MeasuredLocation = &.{},

    fn find(self: ContentEvidence, volume_id: i64, uri: []const u8) ?MeasuredBytes {
        for (self.measured) |location| {
            if (location.volume_id == volume_id and std.mem.eql(u8, location.uri, uri)) return location.bytes;
        }
        return null;
    }
};

/// A location whose bytes tier 3 would read to weigh its file.
pub const NomineeLocation = struct {
    file_id: i64,
    volume_id: i64,
    uri: []u8,
    recorded: ?StorageIdentityKey,
};

pub const NomineeLocations = struct {
    allocator: std.mem.Allocator,
    items: []NomineeLocation,

    pub fn deinit(self: NomineeLocations) void {
        for (self.items) |item| self.allocator.free(item.uri);
        self.allocator.free(self.items);
    }
};

const Weight = enum { equal, different, unknown, absent };

const nominees_sql =
    \\SELECT id, CASE WHEN content_hash_algorithm = 1 THEN content_hash END
    \\FROM files WHERE quick_hash = ?1 ORDER BY id LIMIT ?2;
;

const nominee_locations_sql =
    \\SELECT volume_id, uri, native_inode, size_bytes, modified_ns FROM locations
    \\WHERE file_id = ?1 AND state <> 'missing' AND NOT (volume_id = ?2 AND uri = ?3)
    \\ORDER BY id LIMIT ?4;
;

/// One incomplete file and where to read it.
pub const IncompleteFile = struct {
    id: i64,
    /// Empty when no location on any known volume names this file, which is a
    /// row the backfill can only count and move past.
    uri: []u8,
};

pub const IncompleteFilePage = struct {
    allocator: std.mem.Allocator,
    items: []IncompleteFile,

    pub fn deinit(self: IncompleteFilePage) void {
        for (self.items) |item| self.allocator.free(item.uri);
        self.allocator.free(self.items);
    }
};

/// Where a reader should open a file: a present location in preference to an
/// unverified one, and a missing one only if there is nothing better, because
/// a drive that is back should be read rather than skipped. Empty when no
/// location on any known volume names the file.
///
/// One definition, because every pass that repairs `files` by id needs exactly
/// this rule and two spellings of it would drift.
const location_uri_column =
    \\(SELECT locations.uri FROM locations WHERE locations.file_id = files.id
    \\ ORDER BY CASE locations.state WHEN 'present' THEN 0
    \\               WHEN 'unverified' THEN 1 ELSE 2 END, locations.id
    \\ LIMIT 1)
;

/// Byte facts about one encoding, and the identity tiers that re-find it.
pub const FileRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn create(self: *FileRepository, input: FileUpsert) !i64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.createLocked(input);
    }

    pub fn createLocked(self: *FileRepository, input: FileUpsert) !i64 {
        var statement = try self.db.prepare(
            \\INSERT INTO files(
            \\    audio_format, codec, size_bytes, sample_rate, bit_depth, channels,
            \\    duration_ms, quick_hash, audio_hash, content_hash, content_hash_algorithm,
            \\    audio_hash_tier, first_seen_at
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,
            \\    CASE WHEN ?10 IS NOT NULL THEN 1 END, ?11, unixepoch())
            \\RETURNING id;
        );
        defer statement.deinit();
        try bindFile(statement, input);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    pub fn update(self: *FileRepository, file_id: i64, input: FileUpsert) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.updateLocked(file_id, input);
    }

    pub fn updateLocked(self: *FileRepository, file_id: i64, input: FileUpsert) !void {
        var statement = try self.db.prepare(
            \\UPDATE files SET audio_format=?1, codec=?2, size_bytes=?3, sample_rate=?4,
            \\    bit_depth=?5, channels=?6, duration_ms=?7, quick_hash=?8,
            \\    audio_hash=CASE WHEN ?9 IS NOT NULL THEN ?9
            \\        WHEN quick_hash IS ?8 THEN audio_hash ELSE NULL END,
            \\    audio_hash_tier=CASE WHEN ?9 IS NOT NULL THEN ?11
            \\        WHEN quick_hash IS ?8 THEN audio_hash_tier ELSE NULL END,
            \\    content_hash=CASE WHEN ?10 IS NOT NULL THEN ?10
            \\        WHEN quick_hash IS ?8 THEN content_hash ELSE NULL END,
            \\    content_hash_algorithm=CASE WHEN ?10 IS NOT NULL THEN 1
            \\        WHEN quick_hash IS ?8 THEN content_hash_algorithm ELSE NULL END
            \\WHERE id=?12;
        );
        defer statement.deinit();
        try bindFile(statement, input);
        try statement.bindInt64(12, file_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Records what a probe read from a file's headers, and nothing else.
    ///
    /// `update` would also rewrite `audio_format`, `size_bytes` and
    /// `quick_hash` from a caller that never computed them. A backfill reads
    /// headers only, so it writes only what headers say and leaves the
    /// scanner's observations of the bytes alone.
    pub fn updatePropertiesLocked(
        self: *FileRepository,
        file_id: i64,
        input: FilePropertyUpdate,
    ) !void {
        var statement = try self.db.prepare(
            \\UPDATE files SET codec=?1, sample_rate=?2, bit_depth=?3, channels=?4,
            \\    duration_ms=?5, audio_format=COALESCE(?7, audio_format)
            \\WHERE id=?6;
        );
        defer statement.deinit();
        try statement.bindText(1, input.codec);
        try statement.bindOptionalInt64(2, input.sample_rate);
        try statement.bindOptionalInt64(3, input.bit_depth);
        try statement.bindOptionalInt64(4, input.channels);
        try statement.bindOptionalInt64(5, input.duration_ms);
        try statement.bindInt64(6, file_id);
        try statement.bindOptionalInt64(7, input.audio_format);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// One bounded page of files that still owe a probe, past `after_id`.
    ///
    /// The cursor is the file id rather than an offset, so a page whose rows
    /// the caller could not repair does not make the next page re-serve them,
    /// and a run interrupted half way resumes from where it stopped without
    /// any checkpoint of its own. `all` re-serves every file regardless of
    /// what it already declares, which is the force mode's whole meaning.
    ///
    /// Each row carries the location a reader should open: a present one in
    /// preference to an unverified one, and a missing one only if there is
    /// nothing better, because a drive that is back gets probed rather than
    /// skipped.
    pub fn incompletePropertiesPage(
        self: *const FileRepository,
        allocator: std.mem.Allocator,
        after_id: i64,
        limit: u32,
        all: bool,
    ) !IncompleteFilePage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(if (all)
            "SELECT files.id, " ++ location_uri_column ++
                " FROM files WHERE files.id > ?1 ORDER BY files.id LIMIT ?2;"
        else
            "SELECT files.id, " ++ location_uri_column ++
                " FROM files WHERE files.id > ?1 AND (" ++
                incomplete_properties_predicate ++ ") ORDER BY files.id LIMIT ?2;");
        defer statement.deinit();
        try statement.bindInt64(1, after_id);
        try statement.bindInt64(2, limit);

        var items: std.ArrayList(IncompleteFile) = .empty;
        errdefer {
            for (items.items) |item| allocator.free(item.uri);
            items.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const uri = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(uri);
            try items.append(allocator, .{ .id = statement.columnInt64(0), .uri = uri });
        }
        return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    }

    /// How many files still owe a probe. A backfill, unlike a filesystem walk,
    /// has an honest denominator before it starts, so its job snapshot reports
    /// a fraction rather than a bare count.
    pub fn incompletePropertiesCount(self: *const FileRepository, all: bool) !u64 {
        var statement = try self.db.prepare(if (all)
            "SELECT count(*) FROM files;"
        else
            "SELECT count(*) FROM files WHERE " ++ incomplete_properties_predicate ++ ";");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// How many of the files `incompletePropertiesCount` counts a default
    /// backfill could repair now. It leaves out a file whose probe already
    /// failed on the bytes it has, an `unreadable_file` issue the scanner
    /// settles again when they change; one whose `audio_format` has its bit
    /// set in `undecodable_formats`; and one with no location that is neither
    /// missing nor under a root in `offline_roots`, as
    /// `LibraryRootRepository.offlineCounts` takes them.
    pub fn repairablePropertiesCount(
        self: *const FileRepository,
        offline_roots: []const u8,
        undecodable_formats: u64,
    ) !u64 {
        var statement = try self.db.prepare(repairable_properties_count_sql);
        defer statement.deinit();
        try statement.bindText(1, offline_roots);
        try statement.bindInt64(2, @bitCast(undecodable_formats));
        try statement.bindInt64(3, @backingInt(HealthIssueKind.unreadable_file));
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// One bounded page of files that still owe a measurement `selectors`
    /// name, past `after_id`.
    ///
    /// The cursor is the file id for the same reason the backfill's is: a row
    /// this run declines to measure does not make the next page re-serve it,
    /// and an interrupted run resumes from where it stopped with no checkpoint
    /// of its own. Which rows still owe work is a property of the rows.
    pub fn unanalyzedPage(
        self: *const FileRepository,
        allocator: std.mem.Allocator,
        after_id: i64,
        limit: u32,
        selectors: AnalysisSelectors,
    ) !AnalysisCandidatePage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(
            "SELECT files.id, files.quick_hash, " ++ location_uri_column ++
                " FROM files WHERE files.id > ?1 AND (" ++ unanalyzed_predicate ++
                ") ORDER BY files.id LIMIT ?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, after_id);
        try statement.bindInt64(2, limit);
        try bindAnalysisSelectors(statement, &selectors);

        var items: std.ArrayList(AnalysisCandidate) = .empty;
        errdefer {
            for (items.items) |item| allocator.free(item.uri);
            items.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const uri = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(uri);
            try items.append(allocator, .{
                .id = statement.columnInt64(0),
                .source_identity = digestColumn(statement, 1),
                .uri = uri,
            });
        }
        return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    }

    /// File `file_id` as an analysis candidate, whether or not it still owes a
    /// measurement: an empty page when no such file exists.
    pub fn analysisCandidate(
        self: *const FileRepository,
        allocator: std.mem.Allocator,
        file_id: i64,
    ) !AnalysisCandidatePage {
        var statement = try self.db.prepare(
            "SELECT files.id, files.quick_hash, " ++ location_uri_column ++
                " FROM files WHERE files.id = ?1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .row)
            return .{ .allocator = allocator, .items = try allocator.alloc(AnalysisCandidate, 0) };
        const uri = try allocator.dupe(u8, statement.columnText(2));
        errdefer allocator.free(uri);
        const items = try allocator.alloc(AnalysisCandidate, 1);
        items[0] = .{
            .id = statement.columnInt64(0),
            .source_identity = digestColumn(statement, 1),
            .uri = uri,
        };
        return .{ .allocator = allocator, .items = items };
    }

    /// How many files still owe those measurements. Like the backfill and unlike
    /// a filesystem walk, a library-wide analysis has an honest denominator
    /// before it starts, so its job snapshot reports a fraction.
    pub fn unanalyzedCount(
        self: *const FileRepository,
        selectors: AnalysisSelectors,
    ) !u64 {
        var statement = try self.db.prepare(
            "SELECT count(*) FROM files WHERE " ++ unanalyzed_predicate ++ ";",
        );
        defer statement.deinit();
        // The count asks the same question with no cursor and no limit, so ?1
        // and ?2 are simply unbound; SQLite reads an unbound parameter as
        // NULL, and neither appears in this statement.
        try bindAnalysisSelectors(statement, &selectors);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// One bounded page of files for a duplicate scan, past `after_id`.
    ///
    /// Deliberately unfiltered. A scan that selected only files carrying an
    /// `audio_hash` would report "no duplicates" on a library nobody has
    /// analyzed, which is a lie of omission rather than an answer; and it
    /// would never revisit a file to retire a finding that no longer holds.
    /// Every row is examined, and the ones nothing can be said about are
    /// counted.
    pub fn duplicateCandidatePage(
        self: *const FileRepository,
        allocator: std.mem.Allocator,
        after_id: i64,
        limit: u32,
    ) !DuplicateCandidatePage {
        if (limit == 0 or limit > max_page) return error.PageOutOfRange;
        var statement = try self.db.prepare(
            "SELECT id, audio_hash, duration_ms, quick_hash, audio_hash_tier FROM files" ++
                " WHERE id > ?1 ORDER BY id LIMIT ?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, after_id);
        try statement.bindInt64(2, limit);

        var items: std.ArrayList(DuplicateCandidate) = .empty;
        errdefer items.deinit(allocator);
        while (try statement.step() == .row) try items.append(allocator, .{
            .id = statement.columnInt64(0),
            .audio_hash = audioHashColumn(statement, 1),
            .duration_ms = if (statement.columnIsNull(2)) null else statement.columnInt64(2),
            .source_identity = digestColumn(statement, 3),
            .audio_hash_tier = tierColumn(statement, 4),
        });
        return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    }

    /// The other files whose decoded audio hashes to exactly this, into a
    /// caller-owned buffer.
    ///
    /// This is the exact-duplicate bucket, and it is a search of
    /// `files_audio_hash` rather than a comparison against anything. Only a
    /// lossless integer hash (tier 1) makes two files the same audio, whatever
    /// their containers or tags say, so only tier-1 peers are returned; the
    /// tier is part of the hashed header, so an equal hash has an equal tier.
    ///
    /// The buffer is the caller's and the query is limited to its length, so
    /// one pathological bucket cannot allocate without bound. A returned count
    /// equal to `buffer.len` means the bucket was truncated.
    pub fn audioHashPeersInto(
        self: *const FileRepository,
        buffer: []i64,
        audio_hash: []const u8,
        exclude_id: i64,
    ) !usize {
        if (buffer.len == 0) return 0;
        var statement = try self.db.prepare(
            "SELECT id FROM files WHERE audio_hash = ?1 AND id <> ?2" ++
                " AND audio_hash_tier = 1 ORDER BY id LIMIT ?3;",
        );
        defer statement.deinit();
        try statement.bindBlob(1, audio_hash);
        try statement.bindInt64(2, exclude_id);
        try statement.bindInt64(3, @intCast(buffer.len));
        var found: usize = 0;
        while (try statement.step() == .row) : (found += 1) buffer[found] = statement.columnInt64(0);
        return found;
    }

    /// The other files whose duration falls inside `[low, high]`, into a
    /// caller-owned buffer.
    ///
    /// This is the *plausible* bucket, the one a temporal fingerprint is then
    /// compared inside. Length is the cheapest necessary condition for two
    /// files being the same recording and the only one an index can answer, so
    /// it decides who is worth comparing; the fingerprint decides whether they
    /// match. Served by `files_duration`, which covers both columns.
    ///
    /// Bounded exactly like `audioHashPeersInto`, and for the same reason.
    pub fn durationPeersInto(
        self: *const FileRepository,
        buffer: []DuplicatePeer,
        low: i64,
        high: i64,
        exclude_id: i64,
    ) !usize {
        if (buffer.len == 0) return 0;
        var statement = try self.db.prepare(
            "SELECT id, quick_hash, audio_hash, audio_hash_tier FROM files" ++
                " WHERE duration_ms >= ?1 AND duration_ms <= ?2" ++
                " AND id <> ?3 ORDER BY duration_ms, id LIMIT ?4;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, low);
        try statement.bindInt64(2, high);
        try statement.bindInt64(3, exclude_id);
        try statement.bindInt64(4, @intCast(buffer.len));
        var found: usize = 0;
        while (try statement.step() == .row) : (found += 1) buffer[found] = .{
            .id = statement.columnInt64(0),
            .source_identity = digestColumn(statement, 1),
            .audio_hash = audioHashColumn(statement, 2),
            .audio_hash_tier = tierColumn(statement, 3),
        };
        return found;
    }

    /// Tier 4 of the identity cascade, written by the analysis job rather than
    /// the scanner: a hash of the audio payload alone, which Orca's own tag
    /// writes do not change, with the `fingerprint.AudioHashTier` it was taken
    /// at. `update` clears both when the quick hash changes, because they were
    /// measured from the old bytes.
    pub fn setAudioHash(self: *FileRepository, file_id: i64, digest: []const u8, tier: u8) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.setAudioHashLocked(file_id, digest, tier);
    }

    /// The same write from inside a caller's transaction, so an analysis pass
    /// can commit a file's identity, its results and its health together.
    pub fn setAudioHashLocked(
        self: *FileRepository,
        file_id: i64,
        digest: []const u8,
        tier: u8,
    ) !void {
        var statement = try self.db.prepare(
            "UPDATE files SET audio_hash=?1, audio_hash_tier=?2 WHERE id=?3;",
        );
        defer statement.deinit();
        try statement.bindBlob(1, digest);
        try statement.bindInt64(2, tier);
        try statement.bindInt64(3, file_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Tier 1: the same path on the same volume.
    pub fn resolveByUri(
        self: *const FileRepository,
        volume_id: i64,
        uri: []const u8,
    ) !?i64 {
        var statement = try self.db.prepare(
            "SELECT file_id FROM locations WHERE volume_id=?1 AND uri=?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        try statement.bindText(2, uri);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    /// Tier 2: the same inode, size and mtime somewhere else on the volume —
    /// a rename or a move within one filesystem.
    pub fn resolveByIdentity(self: *const FileRepository, key: StorageIdentityKey) !?i64 {
        var statement = try self.db.prepare(
            \\SELECT file_id FROM locations
            \\WHERE volume_id=?1 AND native_inode=?2 AND size_bytes=?3 AND modified_ns=?4
            \\ORDER BY CASE state WHEN 'missing' THEN 0 ELSE 1 END, id
            \\LIMIT 1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, key.volume_id);
        try statement.bindInt64(2, key.native_inode);
        try statement.bindInt64(3, key.size_bytes);
        try statement.bindInt64(4, key.modified_ns);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    /// Whether resolving the bytes at `uri` reaches tier 3: no location has
    /// this path or identity, and a file records `digest` as its quick hash.
    /// Only then does the resolution weigh content hashes.
    pub fn reachesQuickHash(
        self: *const FileRepository,
        uri: []const u8,
        identity: StorageIdentityKey,
        digest: []const u8,
    ) !bool {
        if (try self.resolveByUri(identity.volume_id, uri) != null) return false;
        if (try self.resolveByIdentity(identity) != null) return false;
        var statement = try self.db.prepare("SELECT EXISTS (SELECT 1 FROM files WHERE quick_hash = ?1);");
        defer statement.deinit();
        try statement.bindBlob(1, digest);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0) != 0;
    }

    /// The locations whose bytes tier 3 would read for `uri`: those of each
    /// file recording `digest` and no content hash, other than `uri` itself,
    /// in the order `resolveForBytes` weighs them.
    pub fn nomineeLocations(
        self: *const FileRepository,
        allocator: std.mem.Allocator,
        uri: []const u8,
        identity: StorageIdentityKey,
        digest: []const u8,
    ) !NomineeLocations {
        var found: std.ArrayList(NomineeLocation) = .empty;
        errdefer {
            for (found.items) |item| allocator.free(item.uri);
            found.deinit(allocator);
        }
        var nominees = try self.db.prepare(nominees_sql);
        defer nominees.deinit();
        try nominees.bindBlob(1, digest);
        try nominees.bindInt64(2, max_nominees);
        while (try nominees.step() == .row) {
            if (digestColumn(nominees, 1) != null) continue;
            const file_id = nominees.columnInt64(0);
            var locations = try self.db.prepare(nominee_locations_sql);
            defer locations.deinit();
            try locations.bindInt64(1, file_id);
            try locations.bindInt64(2, identity.volume_id);
            try locations.bindText(3, uri);
            try locations.bindInt64(4, max_nominee_locations);
            while (try locations.step() == .row) {
                const location_uri = try allocator.dupe(u8, locations.columnText(1));
                errdefer allocator.free(location_uri);
                try found.append(allocator, .{
                    .file_id = file_id,
                    .volume_id = locations.columnInt64(0),
                    .uri = location_uri,
                    .recorded = recordedIdentity(locations),
                });
            }
        }
        return .{ .allocator = allocator, .items = try found.toOwnedSlice(allocator) };
    }

    /// Tier 3: a file recording the same leading and trailing bytes and
    /// length — a copy, a cross-volume move, or a restore from backup. The
    /// quick hash only nominates; equal content hashes join.
    ///
    /// A nominee's own content hash is compared when it records one. Without
    /// one, the bytes measured at its other locations are, and a location
    /// that cannot be read, or whose identity changed since it was measured,
    /// leaves the nominee undecided. A nominee that has no location left to
    /// read is joined on the quick hash alone, and given this path's content
    /// hash, when no other nominee is equal, undecided or as absent: that
    /// keeps Orca's values across a move from a path that is gone, and is the
    /// one tier-3 join that rests on less than equal bytes.
    fn resolveByContent(
        self: *const FileRepository,
        uri: []const u8,
        identity: StorageIdentityKey,
        digest: []const u8,
        evidence: ContentEvidence,
    ) !FileResolution {
        var nominees = try self.db.prepare(nominees_sql);
        defer nominees.deinit();
        try nominees.bindBlob(1, digest);
        try nominees.bindInt64(2, max_nominees + 1);
        var weighed: usize = 0;
        var undecided = false;
        var absent: ?i64 = null;
        var absences: usize = 0;
        while (try nominees.step() == .row) {
            if (weighed == max_nominees) {
                undecided = true;
                break;
            }
            weighed += 1;
            const file_id = nominees.columnInt64(0);
            const weight: Weight = if (digestColumn(nominees, 1)) |stored|
                weighDigest(evidence.own, &stored)
            else
                try self.weighLocations(file_id, uri, identity.volume_id, evidence);
            switch (weight) {
                .equal => return .{ .same = file_id },
                .different => {},
                .unknown => undecided = true,
                .absent => {
                    absent = file_id;
                    absences += 1;
                },
            }
        }
        if (evidence.own != null and !undecided and absences == 1) return .{ .same = absent.? };
        return .new;
    }

    fn weighLocations(
        self: *const FileRepository,
        file_id: i64,
        uri: []const u8,
        volume_id: i64,
        evidence: ContentEvidence,
    ) !Weight {
        var locations = try self.db.prepare(nominee_locations_sql);
        defer locations.deinit();
        try locations.bindInt64(1, file_id);
        try locations.bindInt64(2, volume_id);
        try locations.bindText(3, uri);
        try locations.bindInt64(4, max_nominee_locations + 1);
        var listed: usize = 0;
        var unknown = false;
        while (try locations.step() == .row) {
            if (listed == max_nominee_locations) return .unknown;
            listed += 1;
            const measured = evidence.find(locations.columnInt64(0), locations.columnText(1)) orelse {
                unknown = true;
                continue;
            };
            switch (measured) {
                .gone => {},
                .unreadable => unknown = true,
                .read => |read| {
                    if (!read.holds(recordedIdentity(locations))) {
                        unknown = true;
                        continue;
                    }
                    return weighDigest(evidence.own, &read.digest);
                },
            }
        }
        return if (unknown) .unknown else .absent;
    }

    /// The identity cascade for the bytes now at `uri`, whose quick hash is
    /// `digest`. `evidence` holds the content hashes tier 3 weighs; it never
    /// reads a file itself, because it runs inside the caller's transaction.
    ///
    /// A file is one set of bytes. When the cascade finds a file whose recorded
    /// quick hash differs from `digest` and that is still present at another
    /// path, that path holds the bytes the file describes, so this path has
    /// diverged from it and must not rewrite it. A missing location does not
    /// count, because it is usually what a move left behind, and neither does
    /// a hard link to this path on the same volume, which cannot hold other
    /// bytes. A tier-3 file never diverges: it records `digest` itself.
    pub fn resolveForBytes(
        self: *const FileRepository,
        uri: []const u8,
        identity: StorageIdentityKey,
        digest: []const u8,
        evidence: ContentEvidence,
    ) !FileResolution {
        const existing = (try self.resolveByUri(identity.volume_id, uri)) orelse
            (try self.resolveByIdentity(identity)) orelse
            return self.resolveByContent(uri, identity, digest, evidence);
        var statement = try self.db.prepare(
            \\SELECT EXISTS (
            \\    SELECT 1 FROM files JOIN locations ON locations.file_id = files.id
            \\    WHERE files.id = ?1 AND files.quick_hash IS NOT NULL AND files.quick_hash <> ?2
            \\      AND locations.state = 'present'
            \\      AND NOT (locations.volume_id = ?3
            \\          AND (locations.uri = ?4 OR locations.native_inode IS ?5))
            \\);
        );
        defer statement.deinit();
        try statement.bindInt64(1, existing);
        try statement.bindBlob(2, digest);
        try statement.bindInt64(3, identity.volume_id);
        try statement.bindText(4, uri);
        try statement.bindInt64(5, identity.native_inode);
        if (try statement.step() != .row) return error.SqlFailed;
        if (statement.columnInt64(0) != 0) return .{ .diverged = existing };
        return .{ .same = existing };
    }

    /// Forgets `file_id`'s content hash unless one of its locations already
    /// has `identity`.
    ///
    /// A path resolved by uri or identity is not hashed. When its bytes
    /// changed without changing the quick hash, a kept content hash would
    /// vouch for bytes the file no longer holds, and tier 3 would join a copy
    /// of the old bytes to it.
    pub fn forgetUnheldContentHashLocked(
        self: *FileRepository,
        file_id: i64,
        identity: StorageIdentityKey,
    ) !void {
        var statement = try self.db.prepare(
            \\UPDATE files SET content_hash = NULL, content_hash_algorithm = NULL
            \\WHERE id = ?1 AND content_hash IS NOT NULL AND NOT EXISTS (
            \\    SELECT 1 FROM locations WHERE file_id = ?1 AND volume_id = ?2
            \\      AND native_inode = ?3 AND size_bytes = ?4 AND modified_ns = ?5);
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, identity.volume_id);
        try statement.bindInt64(3, identity.native_inode);
        try statement.bindInt64(4, identity.size_bytes);
        try statement.bindInt64(5, identity.modified_ns);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// A new file for the bytes at `uri`, which diverged from `shared`.
    ///
    /// It takes a copy of Orca's values for `shared`, unwritten, because the
    /// user's edits and locks are about the song rather than the bytes, and
    /// the journal rows that name `uri`. Everything measured from or recorded
    /// against the shared bytes stays with `shared`. The caller re-points the
    /// location at the new file in the same transaction.
    pub fn forkLocked(
        self: *FileRepository,
        shared: i64,
        uri: []const u8,
        input: FileUpsert,
    ) !i64 {
        const fresh = try self.createLocked(input);
        var values = try self.db.prepare(
            \\INSERT INTO orca_metadata_values(
            \\    file_id, field, value, provenance, locked, updated_at, written_at
            \\) SELECT ?1, field, value, provenance, locked, updated_at, NULL
            \\FROM orca_metadata_values WHERE file_id = ?2;
        );
        defer values.deinit();
        try values.bindInt64(1, fresh);
        try values.bindInt64(2, shared);
        if (try values.step() != .done) return error.SqlFailed;
        var journal = try self.db.prepare(
            "UPDATE mutation_operations SET file_id = ?1 WHERE file_id = ?2 AND source_path = ?3;",
        );
        defer journal.deinit();
        try journal.bindInt64(1, fresh);
        try journal.bindInt64(2, shared);
        try journal.bindText(3, uri);
        if (try journal.step() != .done) return error.SqlFailed;
        return fresh;
    }

    /// Sweep after a completed, uncancelled run: locations under this root that
    /// the run did not reach become `missing`. Never a delete — an unmounted
    /// drive must not eat a library. Folder images the run did not reach are
    /// forgotten: they carry nothing a later scan cannot observe again.
    pub fn markMissingBelowGeneration(
        self: *FileRepository,
        root_id: i64,
        generation: i64,
    ) !u64 {
        return self.sweep(.{ .root_id = root_id, .generation = generation }, .{
            .covers = swept_cover_releases_sql,
            .mark = mark_missing_sql,
            .forget = forget_images_sql,
        });
    }

    /// The same sweep, limited to one directory: locations under `prefix`, the
    /// directory's own uri, that a completed walk of that directory did not
    /// reach. A sibling whose name merely starts with the directory's is not
    /// under it.
    pub fn markMissingBelowGenerationUnder(
        self: *FileRepository,
        volume_id: i64,
        root_id: i64,
        generation: i64,
        prefix: []const u8,
    ) !u64 {
        return self.sweep(
            .{ .volume_id = volume_id, .root_id = root_id, .generation = generation, .prefix = prefix },
            .{ .covers = swept_cover_releases_under_sql, .mark = mark_missing_under_sql, .forget = forget_images_under_sql },
        );
    }

    /// Marks the scope's unreached locations missing and forgets its
    /// unreached folder images, then recomputes `has_folder_cover` for the
    /// Releases either could change, all in one savepoint.
    fn sweep(
        self: *FileRepository,
        scope: SweepScope,
        sql: struct { covers: [:0]const u8, mark: [:0]const u8, forget: [:0]const u8 },
    ) !u64 {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("SAVEPOINT sweep;");
        errdefer self.db.exec("ROLLBACK TO sweep; RELEASE sweep;") catch {};
        try self.db.exec(
            \\CREATE TEMP TABLE IF NOT EXISTS swept_cover_releases(id INTEGER PRIMARY KEY);
            \\DELETE FROM temp.swept_cover_releases;
        );
        _ = try scope.run(self.db, sql.covers);
        const marked = try scope.run(self.db, sql.mark);
        _ = try scope.run(self.db, sql.forget);
        try self.db.exec(refresh_swept_folder_covers_sql);
        {
            var swept = try self.db.prepare("SELECT id FROM temp.swept_cover_releases;");
            defer swept.deinit();
            while (try swept.step() == .row) try settleReleaseArtworkLocked(self.db, swept.columnInt64(0));
        }
        try self.db.exec("DELETE FROM temp.swept_cover_releases; RELEASE sweep;");
        return marked;
    }

    /// Attach a file to the performance it encodes. Written only by the
    /// projection: a file is an encoding, and which performance it encodes is
    /// a resolution decision, not a filesystem observation.
    pub fn setRecordingLocked(
        self: *FileRepository,
        file_id: i64,
        recording_id: ?i64,
    ) !void {
        var statement = try self.db.prepare(
            "UPDATE files SET recording_id=?1 WHERE id=?2 AND recording_id IS NOT ?1;",
        );
        defer statement.deinit();
        try statement.bindOptionalInt64(1, recording_id);
        try statement.bindInt64(2, file_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    pub fn count(self: *const FileRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM files;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};

/// The identity a row of `nominee_locations_sql` records.
fn recordedIdentity(statement: sqlite.Statement) ?StorageIdentityKey {
    if (statement.columnIsNull(2)) return null;
    return .{
        .volume_id = statement.columnInt64(0),
        .native_inode = statement.columnInt64(2),
        .size_bytes = statement.columnInt64(3),
        .modified_ns = statement.columnInt64(4),
    };
}

fn weighDigest(own: ?*const content_hash.Digest, other: *const content_hash.Digest) Weight {
    const digest = own orelse return .unknown;
    return if (std.mem.eql(u8, digest, other)) .equal else .different;
}

fn bindFile(statement: sqlite.Statement, input: FileUpsert) !void {
    try statement.bindInt64(1, input.audio_format);
    try statement.bindText(2, input.codec);
    try statement.bindInt64(3, input.size_bytes);
    try statement.bindOptionalInt64(4, input.sample_rate);
    try statement.bindOptionalInt64(5, input.bit_depth);
    try statement.bindOptionalInt64(6, input.channels);
    try statement.bindOptionalInt64(7, input.duration_ms);
    try bindOptionalBlob(statement, 8, input.quick_hash);
    try bindOptionalBlob(statement, 9, input.audio_hash);
    try bindOptionalBlob(statement, 10, input.content_hash);
    try statement.bindOptionalInt64(11, if (input.audio_hash_tier) |tier| tier else null);
}

fn tierColumn(statement: sqlite.Statement, column: c_int) ?u8 {
    if (statement.columnIsNull(column)) return null;
    return std.math.cast(u8, statement.columnInt64(column));
}

fn bindOptionalBlob(statement: sqlite.Statement, index: c_int, value: ?[]const u8) !void {
    if (value) |bytes| return statement.bindBlob(index, bytes);
    return statement.bindOptionalText(index, null);
}

/// A 32-byte BLAKE3 column, or null when the row has none or the stored blob
/// is not one. A short blob is corruption rather than an answer, and treating
/// it as null keeps a duplicate scan from bucketing files together on a
/// truncated key.
fn audioHashColumn(statement: sqlite.Statement, column: c_int) ?[32]u8 {
    const bytes = statement.columnBlob(column);
    if (bytes.len != 32) return null;
    var digest: [32]u8 = undefined;
    @memcpy(&digest, bytes);
    return digest;
}
