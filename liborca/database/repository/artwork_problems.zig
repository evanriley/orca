const std = @import("std");
const sqlite = @import("../sqlite.zig");
const columns = @import("../columns.zig");
const health = @import("health.zig");
const image_header = @import("../../metadata/image_header.zig");
const release_front_measurements_sql = @import("locations.zig").release_front_measurements_sql;
const available_location = @import("roots.zig").available_location;

/// What is wrong with a file's front cover, carried in an `artwork_problem`
/// issue's details as `problem=` text.
pub const ArtworkProblem = enum {
    /// No embedded, chosen, folder or fetched front cover.
    missing_front,
    /// The front cover in effect is narrower or shorter than
    /// `minimum_cover_pixels`.
    undersized,
    /// The file's embedded cover and its Release's folder front image are
    /// different images.
    conflicting,
};

/// A front cover narrower or shorter than this many pixels is undersized.
pub const minimum_cover_pixels: u32 = 500;

/// An image as measured when it was stored or observed; null where it was
/// never measured, and `hash` `image_header.unreadable_hash` where its bytes
/// would not read.
pub const Measurement = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    hash: ?i64 = null,
};

/// One `artwork_problem` issue, as `ArtworkFinding.parse` reads it back.
pub const ArtworkFinding = struct {
    problem: ArtworkProblem,
    /// The front cover's size, for `undersized`.
    width: ?u32 = null,
    height: ?u32 = null,

    pub const max_details = 64;

    pub fn details(self: ArtworkFinding, buffer: *[max_details]u8) []const u8 {
        if (self.width != null and self.height != null)
            return std.fmt.bufPrint(buffer, "problem={t} width={d} height={d}", .{ self.problem, self.width.?, self.height.? }) catch unreachable;
        return std.fmt.bufPrint(buffer, "problem={t}", .{self.problem}) catch unreachable;
    }

    /// Null when `text` names no problem: an issue recorded before problems
    /// were told apart, or one of another kind.
    pub fn parse(text: []const u8) ?ArtworkFinding {
        var finding: ?ArtworkFinding = null;
        var width: ?u32 = null;
        var height: ?u32 = null;
        var fields = std.mem.tokenizeScalar(u8, text, ' ');
        while (fields.next()) |field| {
            const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
            const key = field[0..equals];
            const value = field[equals + 1 ..];
            if (std.mem.eql(u8, key, "problem")) {
                const problem = std.meta.stringToEnum(ArtworkProblem, value) orelse return null;
                finding = .{ .problem = problem };
            } else if (std.mem.eql(u8, key, "width")) {
                width = std.fmt.parseInt(u32, value, 10) catch null;
            } else if (std.mem.eql(u8, key, "height")) {
                height = std.fmt.parseInt(u32, value, 10) catch null;
            }
        }
        var result = finding orelse return null;
        result.width = width;
        result.height = height;
        return result;
    }
};

/// What the Library knows about a Release's front covers, without opening a
/// file: the chosen or fetched cover from `release_artwork` and the folder
/// front image the scan measured.
pub const ReleaseFacts = struct {
    chosen: ?Measurement = null,
    folder: ?Measurement = null,
    fetched: ?Measurement = null,
};

/// The problem with a file's front cover, given the file's embedded cover
/// and its Release's. The front cover in effect is the chosen one, then the
/// embedded, then the folder's, then the fetched one, as `artwork.zig` shows
/// them. A size or hash never measured is unknown, and raises nothing.
pub fn assess(embedded: ?Measurement, facts: ReleaseFacts) ?ArtworkFinding {
    if (facts.chosen) |chosen| return undersized(chosen);
    if (embedded == null and facts.folder == null and facts.fetched == null)
        return .{ .problem = .missing_front };
    if (embedded) |file_cover| if (facts.folder) |folder| {
        if (knownHash(file_cover.hash)) |a| if (knownHash(folder.hash)) |b| {
            if (a != b) return .{ .problem = .conflicting };
        };
    };
    return undersized(embedded orelse facts.folder orelse facts.fetched.?);
}

fn knownHash(hash: ?i64) ?i64 {
    const value = hash orelse return null;
    return if (value == image_header.unreadable_hash) null else value;
}

fn undersized(cover: Measurement) ?ArtworkFinding {
    const width = cover.width orelse return null;
    const height = cover.height orelse return null;
    if (width >= minimum_cover_pixels and height >= minimum_cover_pixels) return null;
    return .{ .problem = .undersized, .width = width, .height = height };
}

/// Reads a Release's facts. A Release id with no Release has none.
pub fn loadReleaseFacts(db: sqlite.Database, release_id: i64) !ReleaseFacts {
    var facts: ReleaseFacts = .{};
    {
        var statement = try db.prepare(
            "SELECT source, width, height FROM release_artwork WHERE release_id = ?1 AND kind = 0 AND image IS NOT NULL;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        if (try statement.step() == .row) {
            const measured: Measurement = .{
                .width = columns.countColumn(statement, 1),
                .height = columns.countColumn(statement, 2),
            };
            switch (statement.columnInt64(0)) {
                chosen_source => facts.chosen = measured,
                else => facts.fetched = measured,
            }
        }
    }
    var statement = try db.prepare(release_front_measurements_sql);
    defer statement.deinit();
    try statement.bindInt64(1, release_id);
    try statement.bindInt64(2, max_folder_images);
    while (try statement.step() == .row) {
        const hash = columns.optionalInt64(statement, 2);
        if (hash == image_header.unreadable_hash) continue;
        facts.folder = .{
            .width = columns.countColumn(statement, 0),
            .height = columns.countColumn(statement, 1),
            .hash = hash,
        };
        break;
    }
    return facts;
}

/// `release_artwork.source` of a cover a person chose.
const chosen_source = 3;

/// As many folder front images as `artwork.zig` tries before it gives up on
/// the folder.
const max_folder_images = 4;

/// Records `file_id`'s artwork problem, or retires the issue when there is
/// none. Caller holds the write lane.
pub fn settleFileLocked(db: sqlite.Database, file_id: i64, embedded: ?Measurement, facts: ReleaseFacts) !void {
    const finding = assess(embedded, facts) orelse return health.clearIssueLocked(db, file_id, .artwork_problem);
    var buffer: [ArtworkFinding.max_details]u8 = undefined;
    try health.recordIssueLocked(db, file_id, .{
        .kind = .artwork_problem,
        .severity = .information,
        .details = finding.details(&buffer),
    });
}

/// The embedded cover a file's last observed tags declared, or null when
/// they declared none. Columns are `artwork_byte_size`, `artwork_mime_type`,
/// `artwork_width`, `artwork_height`, `artwork_hash` from `first`.
pub fn embeddedMeasurement(statement: sqlite.Statement, first: c_int) ?Measurement {
    const declared = (columns.optionalInt64(statement, first) orelse 0) > 0 and !statement.columnIsNull(first + 1);
    if (!declared) return null;
    return .{
        .width = columns.countColumn(statement, first + 2),
        .height = columns.countColumn(statement, first + 3),
        .hash = columns.optionalInt64(statement, first + 4),
    };
}

/// Settles `artwork_problem` for a Release's files after its covers changed:
/// the preferred file of each of its Tracks, and every copy of their
/// recordings no Track prefers. Caller holds the write lane.
pub fn settleReleaseLocked(db: sqlite.Database, release_id: i64) !void {
    const facts = try loadReleaseFacts(db, release_id);
    var statement = try db.prepare(
        \\SELECT release_files.id, t.artwork_byte_size, t.artwork_mime_type,
        \\       t.artwork_width, t.artwork_height, t.artwork_hash
        \\FROM (SELECT preferred_file_id AS id FROM tracks
        \\      WHERE release_id = ?1 AND preferred_file_id IS NOT NULL
        \\      UNION
        \\      SELECT files.id FROM files JOIN tracks ON files.recording_id = tracks.recording_id
        \\      WHERE tracks.release_id = ?1
        \\        AND NOT EXISTS (SELECT 1 FROM tracks AS preferring WHERE preferring.preferred_file_id = files.id)
        \\) AS release_files
        \\LEFT JOIN observed_file_tags AS t ON t.file_id = release_files.id;
    );
    defer statement.deinit();
    try statement.bindInt64(1, release_id);
    while (try statement.step() == .row)
        try settleFileLocked(db, statement.columnInt64(0), embeddedMeasurement(statement, 1), facts);
}

/// Where an unmeasured cover lives: in a file's tags, beside it in a folder,
/// or kept in the Library's `release_artwork`.
pub const CoverOrigin = enum { embedded, folder, kept };

/// A cover observed before the Library measured covers, with the size and
/// modification time its bytes had when it was observed.
pub const UnmeasuredCover = struct {
    /// A file id for an embedded cover, a `folder_images` id for a folder
    /// image, and for a kept cover its Release id times 4 plus its kind.
    id: i64,
    volume_id: i64,
    /// Empty when no location names the file, and for a kept cover.
    uri: []u8,
    size_bytes: i64,
    modified_ns: i64,
};

pub const UnmeasuredCoverPage = struct {
    allocator: std.mem.Allocator,
    items: []UnmeasuredCover,

    pub fn deinit(self: UnmeasuredCoverPage) void {
        for (self.items) |item| self.allocator.free(item.uri);
        self.allocator.free(self.items);
    }
};

const unmeasured_embedded_predicate = "artwork_byte_size > 0 AND artwork_hash IS NULL";
const unmeasured_folder_predicate = "hash IS NULL";
const unmeasured_kept_predicate = "image IS NOT NULL AND width IS NULL";

/// The `width` and `height` a kept cover is stored with when its header will
/// not read: measured, so it leaves `release_artwork_unmeasured` and is not
/// read again, and of unknown size, so it raises no `undersized` problem.
pub const unreadable_cover_side: i64 = -1;

/// One bounded page of unmeasured covers past `after_id`, in id order. The
/// predicates are those of the partial indexes
/// `observed_file_tags_artwork_unmeasured`, `folder_images_unmeasured` and
/// `release_artwork_unmeasured`.
pub fn unmeasuredCoverPage(
    db: sqlite.Database,
    allocator: std.mem.Allocator,
    origin: CoverOrigin,
    after_id: i64,
    limit: u32,
) !UnmeasuredCoverPage {
    if (limit == 0 or limit > columns.max_page) return error.PageOutOfRange;
    var statement = try db.prepare(switch (origin) {
        .embedded => "SELECT t.file_id, coalesce(l.volume_id, 0), coalesce(l.uri, ''),\n" ++
            "       coalesce(l.size_bytes, -1), coalesce(l.modified_ns, -1)\n" ++
            "FROM observed_file_tags AS t\n" ++
            "LEFT JOIN locations AS l ON l.id = (SELECT id FROM locations WHERE file_id = t.file_id\n" ++
            "    ORDER BY CASE state WHEN 'present' THEN 0 WHEN 'unverified' THEN 1 ELSE 2 END, id LIMIT 1)\n" ++
            "WHERE t." ++ unmeasured_embedded_predicate ++ " AND t.file_id > ?1\n" ++
            "ORDER BY t.file_id LIMIT ?2;",
        .folder => "SELECT id, volume_id, uri, size_bytes, modified_ns FROM folder_images\n" ++
            "WHERE " ++ unmeasured_folder_predicate ++ " AND id > ?1 ORDER BY id LIMIT ?2;",
        .kept => "SELECT release_id * 4 + kind, 0, '', -1, -1 FROM release_artwork\n" ++
            "WHERE " ++ unmeasured_kept_predicate ++ " AND (release_id, kind) > (?1 / 4, ?1 % 4)\n" ++
            "ORDER BY release_id, kind LIMIT ?2;",
    });
    defer statement.deinit();
    try statement.bindInt64(1, after_id);
    try statement.bindInt64(2, limit);
    var items: std.ArrayList(UnmeasuredCover) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item.uri);
        items.deinit(allocator);
    }
    while (try statement.step() == .row) {
        const uri = try allocator.dupe(u8, statement.columnText(2));
        errdefer allocator.free(uri);
        try items.append(allocator, .{
            .id = statement.columnInt64(0),
            .volume_id = statement.columnInt64(1),
            .uri = uri,
            .size_bytes = statement.columnInt64(3),
            .modified_ns = statement.columnInt64(4),
        });
    }
    return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
}

/// How many embedded covers, folder images and kept covers are still
/// unmeasured.
pub fn unmeasuredCoverCount(db: sqlite.Database) !u64 {
    var statement = try db.prepare(
        "SELECT (SELECT count(*) FROM observed_file_tags WHERE " ++ unmeasured_embedded_predicate ++ ")\n" ++
            "     + (SELECT count(*) FROM folder_images WHERE " ++ unmeasured_folder_predicate ++ ")\n" ++
            "     + (SELECT count(*) FROM release_artwork WHERE " ++ unmeasured_kept_predicate ++ ");",
    );
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return @intCast(statement.columnInt64(0));
}

/// How many of the covers `unmeasuredCoverCount` counts a backfill could
/// measure now: it leaves out an embedded cover whose file has no location
/// that is neither missing nor under a root in `offline_roots`, and a folder
/// image under such a root, as `LibraryRootRepository.offlineCounts` takes
/// them.
pub fn measurableCoverCount(db: sqlite.Database, offline_roots: []const u8) !u64 {
    var statement = try db.prepare(
        "SELECT (SELECT count(*) FROM observed_file_tags WHERE " ++ unmeasured_embedded_predicate ++ "\n" ++
            "        AND EXISTS (" ++ available_location ++ " held.file_id = observed_file_tags.file_id))\n" ++
            "     + (SELECT count(*) FROM folder_images WHERE " ++ unmeasured_folder_predicate ++ "\n" ++
            "        AND (root_id IS NULL OR instr(?1, ',' || root_id || ',') = 0))\n" ++
            "     + (SELECT count(*) FROM release_artwork WHERE " ++ unmeasured_kept_predicate ++ ");",
    );
    defer statement.deinit();
    try statement.bindText(1, offline_roots);
    if (try statement.step() != .row) return error.SqlFailed;
    return @intCast(statement.columnInt64(0));
}

pub const ReleaseArtworkProblem = struct {
    release_id: i64,
    finding: ArtworkFinding,
    files: u32,
};

pub const ReleaseArtworkProblemPage = struct {
    allocator: std.mem.Allocator,
    items: []ReleaseArtworkProblem,

    pub fn deinit(self: ReleaseArtworkProblemPage) void {
        self.allocator.free(self.items);
    }
};

const release_problem_issues_sql = "(SELECT (SELECT tracks.release_id FROM tracks WHERE tracks.id = (\n" ++
    "            SELECT min(tracks.id) FROM tracks\n" ++
    "            WHERE tracks.preferred_file_id = library_health_issues.file_id\n" ++
    "               OR tracks.recording_id = files.recording_id)) AS release_id,\n" ++
    "        CASE WHEN details LIKE 'problem=missing_front%' THEN 0\n" ++
    "             WHEN details LIKE 'problem=conflicting%' THEN 1\n" ++
    "             WHEN details LIKE 'problem=undersized%' THEN 2\n" ++
    "             ELSE 3 END AS problem_rank,\n" ++
    "        details\n" ++
    health.visible_issues_sql ++ "\n" ++
    "  AND library_health_issues.kind = ?1) AS issues\n" ++
    "JOIN releases ON releases.id = issues.release_id\n" ++
    "WHERE issues.problem_rank < 3\n";

pub fn releaseProblemPage(
    db: sqlite.Database,
    allocator: std.mem.Allocator,
    limit: u32,
    offset: u32,
) !ReleaseArtworkProblemPage {
    if (limit == 0 or limit > columns.max_page) return error.PageOutOfRange;
    var statement = try db.prepare("SELECT issues.release_id, min(issues.problem_rank), issues.details, count(*)\nFROM " ++
        release_problem_issues_sql ++
        "GROUP BY issues.release_id\n" ++
        "ORDER BY releases.title COLLATE NOCASE, issues.release_id LIMIT ?2 OFFSET ?3;");
    defer statement.deinit();
    try statement.bindInt64(1, @backingInt(health.HealthIssueKind.artwork_problem));
    try statement.bindInt64(2, limit);
    try statement.bindInt64(3, offset);
    var items: std.ArrayList(ReleaseArtworkProblem) = .empty;
    errdefer items.deinit(allocator);
    while (try statement.step() == .row) {
        const finding = ArtworkFinding.parse(statement.columnText(2)) orelse return error.InvalidStoredHealthIssue;
        try items.append(allocator, .{
            .release_id = statement.columnInt64(0),
            .finding = finding,
            .files = @intCast(statement.columnInt64(3)),
        });
    }
    return .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
}

pub fn releaseProblemCount(db: sqlite.Database) !u64 {
    var statement = try db.prepare("SELECT count(DISTINCT issues.release_id)\nFROM " ++ release_problem_issues_sql ++ ";");
    defer statement.deinit();
    try statement.bindInt64(1, @backingInt(health.HealthIssueKind.artwork_problem));
    if (try statement.step() != .row) return error.SqlFailed;
    return @intCast(statement.columnInt64(0));
}

/// Records the measurement of an embedded or folder `cover`, unless a scan
/// measured it first or a folder image's bytes changed since it was paged.
/// Caller holds the write lane and settles the Releases afterwards.
pub fn storeCoverMeasurementLocked(
    db: sqlite.Database,
    origin: CoverOrigin,
    cover: UnmeasuredCover,
    measured: image_header.Measurement,
) !void {
    var statement = try db.prepare(switch (origin) {
        .kept => return error.KeptCoverMeasuredInPlace,
        .embedded => "UPDATE observed_file_tags SET artwork_width = ?2, artwork_height = ?3, artwork_hash = ?4\n" ++
            "WHERE file_id = ?1 AND " ++ unmeasured_embedded_predicate ++ ";",
        .folder => "UPDATE folder_images SET width = ?2, height = ?3, hash = ?4\n" ++
            "WHERE id = ?1 AND " ++ unmeasured_folder_predicate ++ " AND size_bytes = ?5 AND modified_ns = ?6;",
    });
    defer statement.deinit();
    try statement.bindInt64(1, cover.id);
    try statement.bindOptionalInt64(2, if (measured.width) |width| width else null);
    try statement.bindOptionalInt64(3, if (measured.height) |height| height else null);
    try statement.bindInt64(4, measured.hash);
    if (origin == .folder) {
        try statement.bindInt64(5, cover.size_bytes);
        try statement.bindInt64(6, cover.modified_ns);
    }
    if (try statement.step() != .done) return error.SqlFailed;
}

/// A kept cover that was measured.
pub const MeasuredKeptCover = struct {
    release_id: i64,
    front: bool,
};

/// Measures the kept cover `id` names, as `unmeasuredCoverPage` gives it,
/// from the bytes the Library holds and records its size, or
/// `unreadable_cover_side` when its header will not read. Null when it was
/// replaced or measured since it was paged. Caller holds the write lane and
/// settles the Release of a front afterwards.
pub fn measureKeptCoverLocked(db: sqlite.Database, id: i64) !?MeasuredKeptCover {
    const kept: MeasuredKeptCover = .{ .release_id = @divFloor(id, 4), .front = @mod(id, 4) == 0 };
    var read = try db.prepare(
        "SELECT image FROM release_artwork WHERE release_id = ?1 AND kind = ?2 AND " ++ unmeasured_kept_predicate ++ ";",
    );
    defer read.deinit();
    try read.bindInt64(1, kept.release_id);
    try read.bindInt64(2, @mod(id, 4));
    if (try read.step() != .row) return null;
    const measured = image_header.measure(read.columnBlob(0));
    var update = try db.prepare("UPDATE release_artwork SET width = ?3, height = ?4 WHERE release_id = ?1 AND kind = ?2;");
    defer update.deinit();
    try update.bindInt64(1, kept.release_id);
    try update.bindInt64(2, @mod(id, 4));
    try update.bindInt64(3, measured.width orelse unreadable_cover_side);
    try update.bindInt64(4, measured.height orelse unreadable_cover_side);
    if (try update.step() != .done) return error.SqlFailed;
    return kept;
}

/// Appends the Releases whose Tracks prefer `file_id` or share its
/// recording.
pub fn appendFileReleases(
    db: sqlite.Database,
    allocator: std.mem.Allocator,
    file_id: i64,
    release_ids: *std.ArrayList(i64),
) !void {
    var statement = try db.prepare(
        \\SELECT DISTINCT release_id FROM tracks
        \\WHERE release_id IS NOT NULL
        \\  AND (preferred_file_id = ?1 OR recording_id = (SELECT recording_id FROM files WHERE id = ?1));
    );
    defer statement.deinit();
    try statement.bindInt64(1, file_id);
    while (try statement.step() == .row) try release_ids.append(allocator, statement.columnInt64(0));
}

const testing = std.testing;

test "a missing front outranks a conflict, which outranks an undersized cover" {
    const small: Measurement = .{ .width = 300, .height = 300, .hash = 7 };
    const large: Measurement = .{ .width = 1200, .height = 1200, .hash = 8 };
    try testing.expectEqual(ArtworkProblem.missing_front, assess(null, .{}).?.problem);
    try testing.expectEqual(ArtworkProblem.conflicting, assess(small, .{ .folder = large }).?.problem);
    const finding = assess(small, .{ .folder = small }).?;
    try testing.expectEqual(ArtworkProblem.undersized, finding.problem);
    try testing.expectEqual(@as(?u32, 300), finding.width);
    try testing.expectEqual(@as(?ArtworkFinding, null), assess(large, .{ .folder = large }));
}

test "the front cover in effect is chosen, then embedded, then the folder's, then fetched" {
    const small: Measurement = .{ .width = 300, .height = 300, .hash = 7 };
    const large: Measurement = .{ .width = 1200, .height = 1200, .hash = 8 };
    try testing.expectEqual(@as(?ArtworkFinding, null), assess(small, .{ .chosen = large, .folder = large }));
    try testing.expectEqual(ArtworkProblem.undersized, assess(large, .{ .chosen = small }).?.problem);
    try testing.expectEqual(ArtworkProblem.undersized, assess(null, .{ .folder = small, .fetched = large }).?.problem);
    try testing.expectEqual(@as(?ArtworkFinding, null), assess(null, .{ .folder = large, .fetched = small }));
    try testing.expectEqual(ArtworkProblem.undersized, assess(null, .{ .fetched = small }).?.problem);
}

test "a size or hash never measured raises no undersized or conflicting cover" {
    const unknown: Measurement = .{};
    const large: Measurement = .{ .width = 1200, .height = 1200, .hash = 8 };
    try testing.expectEqual(@as(?ArtworkFinding, null), assess(unknown, .{ .folder = large }));
    try testing.expectEqual(@as(?ArtworkFinding, null), assess(large, .{ .folder = unknown }));
    try testing.expectEqual(@as(?ArtworkFinding, null), assess(.{ .width = 1200, .height = 1200, .hash = image_header.unreadable_hash }, .{ .folder = large }));
    try testing.expectEqual(@as(?ArtworkFinding, null), assess(null, .{ .fetched = .{ .width = 300 } }));
}

test "an artwork problem reads back from the details it was recorded with" {
    var buffer: [ArtworkFinding.max_details]u8 = undefined;
    const undersized_cover: ArtworkFinding = .{ .problem = .undersized, .width = 300, .height = 280 };
    try testing.expectEqualStrings("problem=undersized width=300 height=280", undersized_cover.details(&buffer));
    try testing.expectEqual(undersized_cover, ArtworkFinding.parse(undersized_cover.details(&buffer)).?);
    const missing: ArtworkFinding = .{ .problem = .missing_front };
    try testing.expectEqualStrings("problem=missing_front", missing.details(&buffer));
    try testing.expectEqual(missing, ArtworkFinding.parse("problem=missing_front").?);
    try testing.expectEqual(@as(?ArtworkFinding, null), ArtworkFinding.parse("artwork is missing"));
    try testing.expectEqual(@as(?ArtworkFinding, null), ArtworkFinding.parse("problem=blurry"));
}

fn openTestLibrary(comptime name: []const u8) !@import("../library.zig").LibraryDatabase {
    var library = try @import("../library.zig").LibraryDatabase.open(
        testing.allocator,
        testing.io,
        "file:orca-test-artwork-problems-" ++ name ++ "?mode=memory&cache=shared",
    );
    errdefer library.close();
    try library.database.exec(
        \\INSERT INTO volumes(id, stable_key) VALUES (2, 'music');
        \\INSERT INTO library_roots(id, volume_id, path) VALUES (1, 2, '/m');
        \\INSERT INTO releases(id, title, release_key) VALUES (1, 'Album', 'album');
        \\INSERT INTO files(id) VALUES (1), (2);
        \\INSERT INTO tracks(id, title, release_id, preferred_file_id) VALUES (10, 'a', 1, 1), (11, 'b', 1, 2);
        \\INSERT INTO locations(file_id, volume_id, root_id, uri, state) VALUES
        \\    (1, 2, 1, '/m/Album/1.flac', 'present'), (2, 2, 1, '/m/Album/2.flac', 'present');
        \\INSERT INTO observed_file_tags(file_id, artwork_mime_type, artwork_byte_size, artwork_width, artwork_height, artwork_hash)
        \\VALUES (1, 'image/jpeg', 100, 1000, 1000, 41);
    );
    return library;
}

fn problemOf(db: sqlite.Database, file_id: i64) !?ArtworkFinding {
    var statement = try db.prepare("SELECT details FROM library_health_issues WHERE file_id = ?1 AND kind = ?2;");
    defer statement.deinit();
    try statement.bindInt64(1, file_id);
    try statement.bindInt64(2, @backingInt(health.HealthIssueKind.artwork_problem));
    if (try statement.step() != .row) return null;
    return ArtworkFinding.parse(statement.columnText(0)) orelse error.UnparsedArtworkProblem;
}

test "a Release's files are settled from the covers the Library measured, file by file" {
    var library = try openTestLibrary("settle");
    defer library.close();
    const db = library.database;
    try settleReleaseLocked(db, 1);
    try testing.expectEqual(@as(?ArtworkFinding, null), try problemOf(db, 1));
    try testing.expectEqual(ArtworkProblem.missing_front, (try problemOf(db, 2)).?.problem);

    try db.exec(
        \\INSERT INTO folder_images(volume_id, root_id, uri, mime, role, size_bytes, modified_ns, last_seen_generation, width, height, hash)
        \\VALUES (2, 1, '/m/Album/cover.jpg', 'image/jpeg', 0, 10, 1, 1, 300, 300, 42);
    );
    try settleReleaseLocked(db, 1);
    try testing.expectEqual(ArtworkProblem.conflicting, (try problemOf(db, 1)).?.problem);
    const small = (try problemOf(db, 2)).?;
    try testing.expectEqual(ArtworkProblem.undersized, small.problem);
    try testing.expectEqual(@as(?u32, 300), small.width);

    try db.exec(
        \\INSERT INTO release_artwork(release_id, kind, source, image, mime, width, height, fetched_at)
        \\VALUES (1, 0, 3, X'FFD8FF', 'image/jpeg', 1400, 1400, 1);
    );
    try settleReleaseLocked(db, 1);
    try testing.expectEqual(@as(?ArtworkFinding, null), try problemOf(db, 1));
    try testing.expectEqual(@as(?ArtworkFinding, null), try problemOf(db, 2));
}

const artwork_kind = @backingInt(health.HealthIssueKind.artwork_problem);

test "a Release with several files with artwork problems is one album, with its worst problem" {
    var library = try openTestLibrary("release-page");
    defer library.close();
    const db = library.database;
    try db.exec(std.fmt.comptimePrint(
        \\INSERT INTO releases(id, title, release_key) VALUES (2, 'Before', 'before'), (3, 'Cover', 'cover');
        \\INSERT INTO files(id) VALUES (3), (4), (5);
        \\INSERT INTO tracks(id, title, release_id, preferred_file_id) VALUES (12, 'c', 2, 3), (13, 'd', 3, 4), (14, 'e', 3, 5);
        \\INSERT INTO library_health_issues(file_id, kind, severity, details) VALUES
        \\    (1, {0d}, 1, 'problem=undersized width=300 height=300'),
        \\    (2, {0d}, 1, 'problem=conflicting'),
        \\    (3, {0d}, 1, 'problem=undersized width=400 height=380'),
        \\    (4, {0d}, 1, 'problem=missing_front'),
        \\    (5, {0d}, 1, 'problem=undersized width=200 height=200');
    , .{artwork_kind}));

    try testing.expectEqual(@as(u64, 3), try releaseProblemCount(db));
    const page = try releaseProblemPage(db, testing.allocator, 512, 0);
    defer page.deinit();
    try testing.expectEqual(@as(usize, 3), page.items.len);
    try testing.expectEqual(@as(i64, 1), page.items[0].release_id);
    try testing.expectEqual(ArtworkProblem.conflicting, page.items[0].finding.problem);
    try testing.expectEqual(@as(u32, 2), page.items[0].files);
    try testing.expectEqual(@as(i64, 2), page.items[1].release_id);
    try testing.expectEqual(ArtworkFinding{ .problem = .undersized, .width = 400, .height = 380 }, page.items[1].finding);
    try testing.expectEqual(@as(i64, 3), page.items[2].release_id);
    try testing.expectEqual(ArtworkProblem.missing_front, page.items[2].finding.problem);
    try testing.expectEqual(@as(u32, 2), page.items[2].files);
}

test "albums with artwork problems page by title and reject a page past the limit" {
    var library = try openTestLibrary("release-paging");
    defer library.close();
    const db = library.database;
    try db.exec(std.fmt.comptimePrint(
        \\INSERT INTO releases(id, title, release_key) VALUES (2, 'Before', 'before');
        \\INSERT INTO files(id) VALUES (3);
        \\INSERT INTO tracks(id, title, release_id, preferred_file_id) VALUES (12, 'c', 2, 3);
        \\INSERT INTO library_health_issues(file_id, kind, severity, details) VALUES
        \\    (1, {0d}, 1, 'problem=missing_front'), (2, {0d}, 1, 'problem=missing_front'),
        \\    (3, {0d}, 1, 'problem=missing_front');
    , .{artwork_kind}));

    const first = try releaseProblemPage(db, testing.allocator, 1, 0);
    defer first.deinit();
    try testing.expectEqual(@as(usize, 1), first.items.len);
    try testing.expectEqual(@as(i64, 1), first.items[0].release_id);
    const second = try releaseProblemPage(db, testing.allocator, 1, 1);
    defer second.deinit();
    try testing.expectEqual(@as(usize, 1), second.items.len);
    try testing.expectEqual(@as(i64, 2), second.items[0].release_id);
    const past = try releaseProblemPage(db, testing.allocator, 1, 2);
    defer past.deinit();
    try testing.expectEqual(@as(usize, 0), past.items.len);
    try testing.expectError(error.PageOutOfRange, releaseProblemPage(db, testing.allocator, 0, 0));
    try testing.expectError(error.PageOutOfRange, releaseProblemPage(db, testing.allocator, columns.max_page + 1, 0));
}

test "a dismissed artwork problem leaves its album out until every file's is dismissed" {
    var library = try openTestLibrary("release-dismissed");
    defer library.close();
    const db = library.database;
    try db.exec(std.fmt.comptimePrint(
        \\INSERT INTO library_health_issues(file_id, kind, severity, details) VALUES
        \\    (1, {0d}, 1, 'problem=missing_front'), (2, {0d}, 1, 'problem=undersized width=300 height=300');
        \\INSERT INTO health_dismissals(file_id, kind, quick_hash, dismissed_at) VALUES (1, {0d}, NULL, 1);
    , .{artwork_kind}));

    const page = try releaseProblemPage(db, testing.allocator, 512, 0);
    defer page.deinit();
    try testing.expectEqual(@as(usize, 1), page.items.len);
    try testing.expectEqual(ArtworkProblem.undersized, page.items[0].finding.problem);
    try testing.expectEqual(@as(u32, 1), page.items[0].files);

    try db.exec(std.fmt.comptimePrint(
        "INSERT INTO health_dismissals(file_id, kind, quick_hash, dismissed_at) VALUES (2, {0d}, NULL, 1);",
        .{artwork_kind},
    ));
    try testing.expectEqual(@as(u64, 0), try releaseProblemCount(db));
    const none = try releaseProblemPage(db, testing.allocator, 512, 0);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.items.len);
}
