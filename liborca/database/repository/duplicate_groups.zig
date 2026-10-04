const std = @import("std");
const sqlite = @import("../sqlite.zig");
const columns = @import("../columns.zig");
const codec_id = @import("../../codec/decoder.zig").codec_id;
const genres = @import("genres.zig");
const health = @import("health.zig");
const tracks = @import("tracks.zig");

const optionalInt64 = columns.optionalInt64;
const HealthIssueKind = health.HealthIssueKind;
const WriteLane = @import("write_lane.zig").WriteLane;

/// One visible duplicate issue: `file_id` is a copy of `related_file_id`, or of
/// itself at a second location when that is null.
pub const DuplicateLink = struct {
    file_id: i64,
    related_file_id: ?i64,
    kind: HealthIssueKind,
    similarity: ?f32,
};

/// The files one or more duplicate issues connect. `id` is the lowest file id
/// among them, so it stays the same across reads while the issues do.
pub const DuplicateGroupMembers = struct {
    id: i64,
    file_ids: []const i64,
    /// The lowest similarity of any link in the group, exact links counting as
    /// 1. Null when a likely link has no stored similarity.
    similarity: ?f32,
};

/// Every duplicate group, ordered by id. Caller-owned: release with `deinit`.
pub const DuplicateGrouping = struct {
    allocator: std.mem.Allocator,
    groups: []DuplicateGroupMembers,
    file_ids: []i64,

    pub fn deinit(self: *DuplicateGrouping) void {
        self.allocator.free(self.groups);
        self.allocator.free(self.file_ids);
        self.* = undefined;
    }

    pub fn find(self: *const DuplicateGrouping, id: i64) ?DuplicateGroupMembers {
        const index = std.sort.binarySearch(DuplicateGroupMembers, self.groups, id, compareId) orelse return null;
        return self.groups[index];
    }

    /// The group holding `file_id`, or null when it is in none.
    pub fn groupOf(self: *const DuplicateGrouping, file_id: i64) ?DuplicateGroupMembers {
        for (self.groups) |group| {
            if (std.mem.indexOfScalar(i64, group.file_ids, file_id) != null) return group;
        }
        return null;
    }

    fn compareId(id: i64, group: DuplicateGroupMembers) std.math.Order {
        return std.math.order(id, group.id);
    }
};

/// What ranks one copy of a group against another.
pub const DuplicateFile = struct {
    file_id: i64,
    /// The lowest-numbered Track the file backs, or null when none does.
    track_id: ?i64,
    recording_id: ?i64,
    lossless: bool,
    sample_rate: ?i64,
    bit_depth: ?i64,
    size_bytes: i64,
    /// Locations that are not missing, at least 1: each is a copy.
    copies: u32,
};

/// Whether `a` is the better copy to keep: lossless over lossy, then the higher
/// sample rate, the higher bit depth, the larger file, and the lower file id.
pub fn keepsBefore(_: void, a: DuplicateFile, b: DuplicateFile) bool {
    if (a.lossless != b.lossless) return a.lossless;
    const a_rate = a.sample_rate orelse 0;
    const b_rate = b.sample_rate orelse 0;
    if (a_rate != b_rate) return a_rate > b_rate;
    const a_depth = a.bit_depth orelse 0;
    const b_depth = b.bit_depth orelse 0;
    if (a_depth != b_depth) return a_depth > b_depth;
    if (a.size_bytes != b.size_bytes) return a.size_bytes > b.size_bytes;
    return a.file_id < b.file_id;
}

/// Connects `links` into groups. A link to a file id never seen elsewhere is
/// still a member; a location link makes a group of one file.
pub fn groupLinks(allocator: std.mem.Allocator, links: []const DuplicateLink) !DuplicateGrouping {
    var index_of: std.AutoArrayHashMapUnmanaged(i64, void) = .empty;
    defer index_of.deinit(allocator);
    for (links) |link| {
        try index_of.put(allocator, link.file_id, {});
        if (link.related_file_id) |related| try index_of.put(allocator, related, {});
    }
    const count = index_of.count();
    const parent = try allocator.alloc(usize, count);
    defer allocator.free(parent);
    for (parent, 0..) |*entry, index| entry.* = index;
    for (links) |link| {
        const related = link.related_file_id orelse continue;
        const a = root(parent, index_of.getIndex(link.file_id).?);
        const b = root(parent, index_of.getIndex(related).?);
        if (a != b) parent[@max(a, b)] = @min(a, b);
    }

    const Entry = struct { root_id: i64, file_id: i64 };
    const minimum = try allocator.alloc(i64, count);
    defer allocator.free(minimum);
    @memset(minimum, std.math.maxInt(i64));
    for (index_of.keys(), 0..) |file_id, index| {
        const top = root(parent, index);
        minimum[top] = @min(minimum[top], file_id);
    }
    const entries = try allocator.alloc(Entry, count);
    defer allocator.free(entries);
    for (index_of.keys(), 0..) |file_id, index| {
        entries[index] = .{ .root_id = minimum[root(parent, index)], .file_id = file_id };
    }
    std.mem.sort(Entry, entries, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            if (a.root_id != b.root_id) return a.root_id < b.root_id;
            return a.file_id < b.file_id;
        }
    }.lessThan);

    const file_ids = try allocator.alloc(i64, count);
    errdefer allocator.free(file_ids);
    var groups: std.ArrayList(DuplicateGroupMembers) = .empty;
    errdefer groups.deinit(allocator);
    var start: usize = 0;
    while (start < count) {
        var end = start;
        while (end < count and entries[end].root_id == entries[start].root_id) : (end += 1) {
            file_ids[end] = entries[end].file_id;
        }
        try groups.append(allocator, .{
            .id = entries[start].root_id,
            .file_ids = file_ids[start..end],
            .similarity = 1,
        });
        start = end;
    }
    var unknown = try allocator.alloc(bool, groups.items.len);
    defer allocator.free(unknown);
    @memset(unknown, false);
    for (links) |link| {
        const top = minimum[root(parent, index_of.getIndex(link.file_id).?)];
        const index = std.sort.binarySearch(DuplicateGroupMembers, groups.items, top, DuplicateGrouping.compareId).?;
        if (link.kind != .likely_duplicate) continue;
        if (link.similarity) |value| {
            groups.items[index].similarity = @min(groups.items[index].similarity.?, value);
        } else unknown[index] = true;
    }
    for (groups.items, unknown) |*group, missing| if (missing) {
        group.similarity = null;
    };
    return .{
        .allocator = allocator,
        .groups = try groups.toOwnedSlice(allocator),
        .file_ids = file_ids,
    };
}

fn root(parent: []usize, index: usize) usize {
    var current = index;
    while (parent[current] != current) {
        parent[current] = parent[parent[current]];
        current = parent[current];
    }
    return current;
}

pub const DuplicateLabel = struct { title: []u8, artist: []u8 };

/// What merging one Track's metadata into another changed.
pub const DuplicateMergeResult = struct {
    /// Orca value rows written across the kept Track's files.
    values: u32 = 0,
    rating: bool = false,
    feedback: bool = false,
    genres: bool = false,
    /// The kept Track's files, for the caller to reproject. Caller-owned.
    kept_file_ids: []i64 = &.{},
};

const duplicate_links_sql = "SELECT library_health_issues.file_id, library_health_issues.related_file_id,\n" ++
    "       EXISTS (SELECT 1 FROM files AS related WHERE related.id = library_health_issues.related_file_id),\n" ++
    "       library_health_issues.kind, library_health_issues.similarity\n" ++
    health.visible_issues_sql ++ "\n" ++
    \\  AND library_health_issues.kind IN (?1, ?2);
;

const duplicate_file_sql =
    \\SELECT files.id, files.codec, files.sample_rate, files.bit_depth, files.size_bytes,
    \\       files.recording_id,
    \\       (SELECT count(*) FROM locations
    \\        WHERE locations.file_id = files.id AND locations.state <> 'missing'),
    \\       (SELECT min(tracks.id) FROM tracks
    \\        WHERE tracks.preferred_file_id = files.id OR tracks.recording_id = files.recording_id)
    \\FROM files WHERE files.id = ?1;
;

pub const DuplicateGroupRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Every visible duplicate issue, grouped. Reads each such issue once, so
    /// its cost grows with the duplicates in the Library, not its size.
    pub fn grouping(self: *const DuplicateGroupRepository, allocator: std.mem.Allocator) !DuplicateGrouping {
        var statement = try self.db.prepare(duplicate_links_sql);
        defer statement.deinit();
        try statement.bindInt64(1, @intFromEnum(HealthIssueKind.exact_duplicate));
        try statement.bindInt64(2, @intFromEnum(HealthIssueKind.likely_duplicate));
        var links: std.ArrayList(DuplicateLink) = .empty;
        defer links.deinit(allocator);
        while (try statement.step() == .row) {
            const related = optionalInt64(statement, 1);
            if (related != null and statement.columnInt64(2) == 0) continue;
            const kind = std.enums.fromInt(HealthIssueKind, statement.columnInt64(3)) orelse
                return error.InvalidStoredHealthIssue;
            try links.append(allocator, .{
                .file_id = statement.columnInt64(0),
                .related_file_id = related,
                .kind = kind,
                .similarity = if (statement.columnIsNull(4)) null else @floatCast(statement.columnDouble(4)),
            });
        }
        return groupLinks(allocator, links.items);
    }

    /// The facts that rank `file_id` within its group, or null when the file
    /// does not exist.
    pub fn file(self: *const DuplicateGroupRepository, file_id: i64) !?DuplicateFile {
        var statement = try self.db.prepare(duplicate_file_sql);
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .row) return null;
        return .{
            .file_id = statement.columnInt64(0),
            .track_id = optionalInt64(statement, 7),
            .recording_id = optionalInt64(statement, 5),
            .lossless = codec_id.isLossless(statement.columnText(1)),
            .sample_rate = optionalInt64(statement, 2),
            .bit_depth = optionalInt64(statement, 3),
            .size_bytes = @max(statement.columnInt64(4), 0),
            .copies = @intCast(@max(@min(statement.columnInt64(6), std.math.maxInt(u32)), 1)),
        };
    }

    /// The manual playlists holding `recording_id` at least once.
    pub fn playlistCount(self: *const DuplicateGroupRepository, recording_id: i64) !u64 {
        var statement = try self.db.prepare(
            "SELECT count(DISTINCT playlist_id) FROM playlist_entries WHERE recording_id = ?1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, recording_id);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// The names of the manual playlists holding `recording_id`, by name,
    /// at most `limit` of them. Caller-owned.
    pub fn playlistNames(
        self: *const DuplicateGroupRepository,
        allocator: std.mem.Allocator,
        recording_id: i64,
        limit: u32,
    ) ![][]u8 {
        var statement = try self.db.prepare(
            \\SELECT playlists.name FROM playlists
            \\WHERE playlists.id IN (SELECT playlist_id FROM playlist_entries WHERE recording_id = ?1)
            \\ORDER BY playlists.name COLLATE NOCASE, playlists.id LIMIT ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, recording_id);
        try statement.bindInt64(2, limit);
        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |name| allocator.free(name);
            names.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const name = try allocator.dupe(u8, statement.columnText(0));
            errdefer allocator.free(name);
            try names.append(allocator, name);
        }
        return names.toOwnedSlice(allocator);
    }

    /// The title and artist a group is shown under: its kept copy's Track's,
    /// or the copy's path as the title when it backs no Track.
    pub fn label(
        self: *const DuplicateGroupRepository,
        allocator: std.mem.Allocator,
        copy: DuplicateFile,
    ) !DuplicateLabel {
        if (copy.track_id) |track_id| {
            var statement = try self.db.prepare("SELECT title, artist FROM tracks WHERE id = ?1;");
            defer statement.deinit();
            try statement.bindInt64(1, track_id);
            if (try statement.step() == .row) {
                const title = try allocator.dupe(u8, statement.columnText(0));
                errdefer allocator.free(title);
                return .{ .title = title, .artist = try allocator.dupe(u8, statement.columnText(1)) };
            }
        }
        var statement = try self.db.prepare(
            "SELECT uri FROM locations WHERE file_id = ?1 ORDER BY locations.id LIMIT 1;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, copy.file_id);
        const title = try allocator.dupe(u8, if (try statement.step() == .row) statement.columnText(0) else "");
        errdefer allocator.free(title);
        return .{ .title = title, .artist = try allocator.dupe(u8, "") };
    }

    /// Dismisses every duplicate issue of `file_ids` in one transaction, each
    /// until its file's bytes change.
    pub fn dismiss(self: *DuplicateGroupRepository, file_ids: []const i64) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO health_dismissals(file_id, kind, quick_hash, dismissed_at)
            \\SELECT library_health_issues.file_id, library_health_issues.kind, files.quick_hash, unixepoch()
            \\FROM library_health_issues
            \\JOIN files ON files.id = library_health_issues.file_id
            \\WHERE library_health_issues.file_id = ?1 AND library_health_issues.kind IN (?2, ?3)
            \\ON CONFLICT(file_id, kind) DO UPDATE SET
            \\    quick_hash=excluded.quick_hash,
            \\    dismissed_at=excluded.dismissed_at;
        );
        defer statement.deinit();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        for (file_ids) |file_id| {
            try statement.bindInt64(1, file_id);
            try statement.bindInt64(2, @intFromEnum(HealthIssueKind.exact_duplicate));
            try statement.bindInt64(3, @intFromEnum(HealthIssueKind.likely_duplicate));
            if (try statement.step() != .done) return error.SqlFailed;
            try statement.reset();
        }
        try self.db.exec("COMMIT;");
    }

    /// Gives the Track `keep_track_id` what `from_track_id` has and it lacks,
    /// in one transaction: Orca values of fields its files have none for, and
    /// a locked value of `from_track_id` over an unlocked one; its rating and
    /// love or hate, when its recording has none. A locked value of
    /// `keep_track_id` is never replaced, listens stay with their recording,
    /// and no media file is read or written.
    pub fn mergeMetadata(
        self: *DuplicateGroupRepository,
        allocator: std.mem.Allocator,
        keep_track_id: i64,
        from_track_id: i64,
    ) !DuplicateMergeResult {
        if (keep_track_id == from_track_id) return error.SameDuplicateTrack;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var find = try self.db.prepare(
            \\SELECT recording_id, COALESCE(preferred_file_id,
            \\    (SELECT id FROM files WHERE files.recording_id = tracks.recording_id ORDER BY id LIMIT 1))
            \\FROM tracks WHERE id = ?1;
        );
        defer find.deinit();
        var files_of = try self.db.prepare(tracks.track_file_ids_sql);
        defer files_of.deinit();
        var copy_values = try self.db.prepare(
            \\INSERT INTO orca_metadata_values(file_id, field, value, provenance, locked, updated_at, written_at)
            \\SELECT ?1, field, value, provenance, locked, unixepoch(), NULL
            \\FROM orca_metadata_values WHERE file_id = ?2
            \\ON CONFLICT(file_id, field) DO UPDATE SET
            \\    value=excluded.value,
            \\    provenance=excluded.provenance,
            \\    locked=excluded.locked,
            \\    updated_at=excluded.updated_at,
            \\    written_at=NULL
            \\WHERE orca_metadata_values.locked = 0 AND excluded.locked = 1
            \\  AND orca_metadata_values.value <> excluded.value;
        );
        defer copy_values.deinit();
        var copy_rating = try self.db.prepare(
            \\INSERT INTO ratings(recording_id, rating, updated_at)
            \\SELECT ?1, rating, unixepoch() FROM ratings WHERE recording_id = ?2
            \\ON CONFLICT(recording_id) DO NOTHING;
        );
        defer copy_rating.deinit();
        var copy_feedback = try self.db.prepare(
            \\INSERT INTO feedback(recording_id, score, updated_at)
            \\SELECT ?1, score, unixepoch() FROM feedback WHERE recording_id = ?2 AND score <> 0
            \\ON CONFLICT(recording_id) DO UPDATE SET
            \\    score=excluded.score, updated_at=excluded.updated_at, last_error=''
            \\WHERE feedback.score = 0;
        );
        defer copy_feedback.deinit();
        var user_genres = try self.db.prepare("SELECT 1 FROM track_genres WHERE track_id = ?1 AND provenance = 1 LIMIT 1;");
        defer user_genres.deinit();
        var clear_genres = try self.db.prepare("DELETE FROM track_genres WHERE track_id = ?1;");
        defer clear_genres.deinit();
        var copy_genres = try self.db.prepare(
            \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance)
            \\SELECT ?1, genre_id, ordinal, provenance FROM track_genres
            \\WHERE track_id = ?2 AND provenance = 1;
        );
        defer copy_genres.deinit();

        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        try find.bindInt64(1, keep_track_id);
        if (try find.step() != .row) return error.TrackNotFound;
        const keep_recording = optionalInt64(find, 0);
        try find.reset();
        try find.bindInt64(1, from_track_id);
        if (try find.step() != .row) return error.TrackNotFound;
        const from_recording = optionalInt64(find, 0);
        const source_file = optionalInt64(find, 1);
        try find.reset();

        var kept: std.ArrayList(i64) = .empty;
        errdefer kept.deinit(allocator);
        try files_of.bindInt64(1, keep_track_id);
        try files_of.bindInt64(2, columns.max_page);
        while (try files_of.step() == .row) try kept.append(allocator, files_of.columnInt64(0));

        var result: DuplicateMergeResult = .{};
        if (source_file) |source| for (kept.items) |target| {
            if (target == source) continue;
            try copy_values.bindInt64(1, target);
            try copy_values.bindInt64(2, source);
            if (try copy_values.step() != .done) return error.SqlFailed;
            result.values += @intCast(self.db.changes());
            try copy_values.reset();
        };
        if (keep_recording) |keep| if (from_recording) |from| if (keep != from) {
            try copy_rating.bindInt64(1, keep);
            try copy_rating.bindInt64(2, from);
            if (try copy_rating.step() != .done) return error.SqlFailed;
            result.rating = self.db.changes() > 0;
            try copy_feedback.bindInt64(1, keep);
            try copy_feedback.bindInt64(2, from);
            if (try copy_feedback.step() != .done) return error.SqlFailed;
            result.feedback = self.db.changes() > 0;
        };
        try user_genres.bindInt64(1, keep_track_id);
        const keep_has_user_genres = try user_genres.step() == .row;
        try user_genres.reset();
        try user_genres.bindInt64(1, from_track_id);
        const from_has_user_genres = try user_genres.step() == .row;
        try user_genres.reset();
        if (!keep_has_user_genres and from_has_user_genres) {
            try clear_genres.bindInt64(1, keep_track_id);
            if (try clear_genres.step() != .done) return error.SqlFailed;
            try copy_genres.bindInt64(1, keep_track_id);
            try copy_genres.bindInt64(2, from_track_id);
            if (try copy_genres.step() != .done) return error.SqlFailed;
            try genres.pruneOrphansLocked(self.db);
            result.genres = true;
        }
        try self.db.exec("COMMIT;");
        result.kept_file_ids = try kept.toOwnedSlice(allocator);
        return result;
    }
};

const testing = std.testing;
const LibraryDatabase = @import("../library.zig").LibraryDatabase;

fn testLink(file_id: i64, related_file_id: ?i64, similarity: ?f32) DuplicateLink {
    return .{
        .file_id = file_id,
        .related_file_id = related_file_id,
        .kind = if (similarity == null and related_file_id != null) .exact_duplicate else .likely_duplicate,
        .similarity = similarity,
    };
}

test "a group is named by its lowest file id whatever order its links are read in" {
    const forward = [_]DuplicateLink{
        testLink(9, 4, 0.99),    testLink(4, 9, 0.99),    testLink(12, 4, null), testLink(4, 12, null),
        testLink(30, 31, 0.995), testLink(31, 30, 0.995),
    };
    const backward = [_]DuplicateLink{
        testLink(31, 30, 0.995), testLink(4, 12, null), testLink(12, 4, null),
        testLink(30, 31, 0.995), testLink(4, 9, 0.99),  testLink(9, 4, 0.99),
    };
    var first = try groupLinks(testing.allocator, &forward);
    defer first.deinit();
    var second = try groupLinks(testing.allocator, &backward);
    defer second.deinit();
    try testing.expectEqual(@as(usize, 2), first.groups.len);
    for (first.groups, second.groups) |a, b| {
        try testing.expectEqual(a.id, b.id);
        try testing.expectEqualSlices(i64, a.file_ids, b.file_ids);
        try testing.expectEqual(a.similarity, b.similarity);
    }
    try testing.expectEqual(@as(i64, 4), first.groups[0].id);
    try testing.expectEqualSlices(i64, &.{ 4, 9, 12 }, first.groups[0].file_ids);
    try testing.expectEqual(@as(?f32, 0.99), first.groups[0].similarity);
    try testing.expectEqual(@as(i64, 30), first.groups[1].id);
    try testing.expectEqual(@as(i64, 30), first.groupOf(31).?.id);
    try testing.expectEqual(@as(?DuplicateGroupMembers, null), first.find(9));
}

test "a second location of one file is a group of that file alone, and an unmeasured likely link has no similarity" {
    const links = [_]DuplicateLink{
        .{ .file_id = 7, .related_file_id = null, .kind = .exact_duplicate, .similarity = null },
        .{ .file_id = 2, .related_file_id = 3, .kind = .likely_duplicate, .similarity = null },
    };
    var grouping_result = try groupLinks(testing.allocator, &links);
    defer grouping_result.deinit();
    try testing.expectEqual(@as(usize, 2), grouping_result.groups.len);
    try testing.expectEqualSlices(i64, &.{ 2, 3 }, grouping_result.groups[0].file_ids);
    try testing.expectEqual(@as(?f32, null), grouping_result.groups[0].similarity);
    try testing.expectEqualSlices(i64, &.{7}, grouping_result.groups[1].file_ids);
    try testing.expectEqual(@as(?f32, 1), grouping_result.groups[1].similarity);
}

test "the suggested copy to keep is lossless first, then higher rate, then deeper, then larger" {
    const base: DuplicateFile = .{
        .file_id = 1,
        .track_id = null,
        .recording_id = null,
        .lossless = false,
        .sample_rate = 48_000,
        .bit_depth = null,
        .size_bytes = 9_000_000,
        .copies = 1,
    };
    var lossless = base;
    lossless.file_id = 5;
    lossless.lossless = true;
    lossless.sample_rate = 44_100;
    lossless.size_bytes = 20_000_000;
    var high_rate = lossless;
    high_rate.file_id = 6;
    high_rate.sample_rate = 96_000;
    high_rate.bit_depth = 16;
    high_rate.size_bytes = 10;
    var deeper = high_rate;
    deeper.file_id = 7;
    deeper.bit_depth = 24;
    var larger = deeper;
    larger.file_id = 8;
    larger.size_bytes = 11;
    var same = larger;
    same.file_id = 3;

    var copies = [_]DuplicateFile{ base, lossless, high_rate, deeper, larger, same };
    std.mem.sort(DuplicateFile, &copies, {}, keepsBefore);
    var order: [copies.len]i64 = undefined;
    for (copies, &order) |copy, *id| id.* = copy.file_id;
    try testing.expectEqualSlices(i64, &.{ 3, 8, 7, 6, 5, 1 }, &order);
}

fn testScalar(db: sqlite.Database, sql: [:0]const u8) !i64 {
    var statement = try db.prepare(sql);
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return statement.columnInt64(0);
}

fn testText(allocator: std.mem.Allocator, db: sqlite.Database, sql: [:0]const u8) ![]u8 {
    var statement = try db.prepare(sql);
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return allocator.dupe(u8, statement.columnText(0));
}

test "merging a duplicate's metadata never replaces a value the kept Track has locked" {
    var library = try LibraryDatabase.open(
        testing.allocator,
        testing.io,
        "file:orca-test-duplicate-merge?mode=memory&cache=shared",
    );
    defer library.close();
    try library.database.exec(
        \\INSERT INTO recordings(id, title) VALUES (1, 'Kept'), (2, 'From'), (3, 'Edited');
        \\INSERT INTO files(id, recording_id, audio_format, codec, size_bytes) VALUES
        \\    (1, 1, 1, 'flac', 10), (2, 2, 1, 'mp3', 5), (3, 3, 1, 'mp3', 5);
        \\INSERT INTO tracks(id, recording_id, title, preferred_file_id) VALUES
        \\    (1, 1, 'Kept', 1), (2, 2, 'From', 2), (3, 3, 'Edited', 3);
        \\INSERT INTO genres(id, name, key) VALUES (1, 'Ambient', 'ambient'), (2, 'Rock', 'rock'), (3, 'Pop', 'pop'), (4, 'Jazz', 'jazz');
        \\INSERT INTO track_genres(track_id, genre_id, ordinal, provenance) VALUES
        \\    (1, 3, 0, 0), (2, 1, 0, 1), (2, 2, 1, 1), (3, 4, 0, 1);
        \\INSERT INTO orca_metadata_values(file_id, field, value, provenance, locked) VALUES
        \\    (1, 0, 'Kept title', 1, 1),
        \\    (1, 1, 'Kept artist', 2, 0),
        \\    (2, 0, 'From title', 1, 1),
        \\    (2, 1, 'From artist', 1, 1),
        \\    (2, 2, 'From album', 2, 0);
        \\INSERT INTO ratings(recording_id, rating, updated_at) VALUES (2, 80, 0);
        \\INSERT INTO feedback(recording_id, score, updated_at) VALUES (2, 1, 0);
    );

    const result = try library.duplicate_groups.mergeMetadata(testing.allocator, 1, 2);
    defer testing.allocator.free(result.kept_file_ids);
    try testing.expectEqual(@as(u32, 2), result.values);
    try testing.expect(result.rating);
    try testing.expect(result.feedback);
    try testing.expect(result.genres);
    try testing.expectEqualSlices(i64, &.{1}, result.kept_file_ids);
    try testing.expectEqual(@as(i64, 3), try testScalar(library.database, "SELECT sum(genre_id) FROM track_genres WHERE track_id = 1 AND provenance = 1;"));
    try testing.expectEqual(@as(i64, 2), try testScalar(library.database, "SELECT count(*) FROM track_genres WHERE track_id = 1;"));
    try testing.expectEqual(@as(i64, 0), try testScalar(library.database, "SELECT count(*) FROM genres WHERE id = 3;"));

    const title = try testText(testing.allocator, library.database, "SELECT value FROM orca_metadata_values WHERE file_id = 1 AND field = 0;");
    defer testing.allocator.free(title);
    try testing.expectEqualStrings("Kept title", title);
    const artist = try testText(testing.allocator, library.database, "SELECT value FROM orca_metadata_values WHERE file_id = 1 AND field = 1;");
    defer testing.allocator.free(artist);
    try testing.expectEqualStrings("From artist", artist);
    const album = try testText(testing.allocator, library.database, "SELECT value FROM orca_metadata_values WHERE file_id = 1 AND field = 2;");
    defer testing.allocator.free(album);
    try testing.expectEqualStrings("From album", album);
    try testing.expectEqual(@as(i64, 80), try testScalar(library.database, "SELECT rating FROM ratings WHERE recording_id = 1;"));
    try testing.expectEqual(@as(i64, 1), try testScalar(library.database, "SELECT score FROM feedback WHERE recording_id = 1 AND synced_score IS NULL;"));
    try testing.expectEqual(@as(i64, 3), try testScalar(library.database, "SELECT count(*) FROM orca_metadata_values WHERE file_id = 2;"));

    try library.database.exec("UPDATE ratings SET rating = 20 WHERE recording_id = 1;");
    const again = try library.duplicate_groups.mergeMetadata(testing.allocator, 1, 2);
    defer testing.allocator.free(again.kept_file_ids);
    try testing.expectEqual(@as(u32, 0), again.values);
    try testing.expect(!again.rating);
    try testing.expect(!again.feedback);
    try testing.expect(!again.genres);
    try testing.expectEqual(@as(i64, 20), try testScalar(library.database, "SELECT rating FROM ratings WHERE recording_id = 1;"));

    const edited = try library.duplicate_groups.mergeMetadata(testing.allocator, 3, 2);
    defer testing.allocator.free(edited.kept_file_ids);
    try testing.expect(!edited.genres);
    try testing.expectEqual(@as(i64, 4), try testScalar(library.database, "SELECT group_concat(genre_id) FROM track_genres WHERE track_id = 3;"));
    try testing.expectError(error.SameDuplicateTrack, library.duplicate_groups.mergeMetadata(testing.allocator, 1, 1));
    try testing.expectError(error.TrackNotFound, library.duplicate_groups.mergeMetadata(testing.allocator, 1, 99));
}
