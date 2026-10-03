const std = @import("std");
const sqlite = @import("../sqlite.zig");
const optionalInt64 = @import("../columns.zig").optionalInt64;

const WriteLane = @import("write_lane.zig").WriteLane;
const ReleaseArtworkRepository = @import("release_artwork.zig").ReleaseArtworkRepository;

pub const HealthIssueKind = enum(u8) {
    missing_metadata,
    missing_track_number,
    album_artist_anomaly,
    artwork_problem,
    missing_analysis,
    clipping,
    excessive_silence,
    technical_anomaly,
    corrupt_audio,
    exact_duplicate,
    likely_duplicate,
    /// The file behind a row could not be opened or would not decode. Owned by
    /// the property backfill alone, which is why it is not `corrupt_audio`:
    /// that kind belongs to the analyzer, which decodes the whole stream, and
    /// a header-only pass must not be able to clear a finding made by reading
    /// audio it never looked at.
    unreadable_file,
    recording_mismatch,
};

/// What a host offers to resolve an issue.
pub const HealthAction = enum {
    match_or_edit,
    fetch_cover_art,
    compare_duplicate,
    review_correction,
    reveal_file,

    pub fn of(kind: HealthIssueKind, release_has_mbid: bool) HealthAction {
        return switch (kind) {
            .missing_metadata, .missing_track_number, .album_artist_anomaly => .match_or_edit,
            .artwork_problem => if (release_has_mbid) .fetch_cover_art else .match_or_edit,
            .exact_duplicate, .likely_duplicate => .compare_duplicate,
            .recording_mismatch => .review_correction,
            .clipping,
            .excessive_silence,
            .missing_analysis,
            .technical_anomaly,
            .corrupt_audio,
            .unreadable_file,
            => .reveal_file,
        };
    }
};

pub const HealthSeverity = enum(u8) { information, warning, error_severity };

pub const HealthIssueInput = struct {
    kind: HealthIssueKind,
    severity: HealthSeverity,
    details: []const u8 = "",
    /// The other file of a duplicate.
    related_file_id: ?i64 = null,
};

pub const HealthIssue = struct {
    file_id: i64,
    /// The location a host should show for this issue, empty when the file has
    /// no location on any known volume. Presentation only — identity is
    /// `file_id`.
    path: []u8,
    kind: HealthIssueKind,
    severity: HealthSeverity,
    details: []u8,
    /// The lowest-numbered Track the file backs, or null when none does.
    track_id: ?i64,
    /// That Track's Release.
    release_id: ?i64,
    /// The other file of a duplicate, or null when there is none or it was
    /// deleted.
    related_file_id: ?i64,
    action: HealthAction,

    pub fn deinit(self: HealthIssue, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.details);
    }
};

pub const HealthIssuePage = struct {
    allocator: std.mem.Allocator,
    items: []HealthIssue,

    pub fn deinit(self: HealthIssuePage) void {
        for (self.items) |item| item.deinit(self.allocator);
        self.allocator.free(self.items);
    }
};

/// One file as a host shows it beside an issue. Caller-owned: release with
/// `deinit`.
pub const HealthFile = struct {
    allocator: std.mem.Allocator,
    file_id: i64,
    /// The uri of the best location that is not missing, or null when every
    /// location is.
    path: ?[]u8,
    /// Whether the file has no location that is not missing.
    missing: bool,
    /// The codec identifier, such as `flac`; empty when the file was never
    /// probed.
    codec: []u8,
    sample_rate: ?u32,
    bit_depth: ?u32,
    channels: ?u32,
    size_bytes: ?i64,
    duration_ms: ?i64,

    pub fn deinit(self: HealthFile) void {
        self.allocator.free(self.codec);
        if (self.path) |value| self.allocator.free(value);
    }
};

/// Retire `kind` for every file of a Track on `release_id`: its preferred file
/// and every other encoding of its recording.
pub fn clearReleaseLocked(db: sqlite.Database, release_id: i64, kind: HealthIssueKind) !void {
    var statement = try db.prepare(
        \\DELETE FROM library_health_issues WHERE kind = ?2 AND file_id IN (
        \\    SELECT preferred_file_id FROM tracks
        \\    WHERE release_id = ?1 AND preferred_file_id IS NOT NULL
        \\    UNION
        \\    SELECT files.id FROM files JOIN tracks ON files.recording_id = tracks.recording_id
        \\    WHERE tracks.release_id = ?1);
    );
    defer statement.deinit();
    try statement.bindInt64(1, release_id);
    try statement.bindInt64(2, @intFromEnum(kind));
    if (try statement.step() != .done) return error.SqlFailed;
}

pub fn recordIssueLocked(db: sqlite.Database, file_id: i64, issue: HealthIssueInput) !void {
    var statement = try db.prepare(
        \\INSERT INTO library_health_issues(file_id, kind, severity, details, related_file_id, updated_at)
        \\VALUES (?1, ?2, ?3, ?4, ?5, unixepoch())
        \\ON CONFLICT(file_id, kind) DO UPDATE SET
        \\    severity=excluded.severity,
        \\    details=excluded.details,
        \\    related_file_id=excluded.related_file_id,
        \\    updated_at=excluded.updated_at;
    );
    defer statement.deinit();
    try statement.bindInt64(1, file_id);
    try statement.bindInt64(2, @intFromEnum(issue.kind));
    try statement.bindInt64(3, @intFromEnum(issue.severity));
    try statement.bindText(4, issue.details);
    try statement.bindOptionalInt64(5, issue.related_file_id);
    if (try statement.step() != .done) return error.SqlFailed;
}

pub fn clearIssueLocked(db: sqlite.Database, file_id: i64, kind: HealthIssueKind) !void {
    var statement = try db.prepare(
        "DELETE FROM library_health_issues WHERE file_id=?1 AND kind=?2;",
    );
    defer statement.deinit();
    try statement.bindInt64(1, file_id);
    try statement.bindInt64(2, @intFromEnum(kind));
    if (try statement.step() != .done) return error.SqlFailed;
}

pub const visible_issues_sql =
    \\FROM library_health_issues
    \\JOIN files ON files.id = library_health_issues.file_id
    \\WHERE NOT EXISTS (
    \\    SELECT 1 FROM health_dismissals
    \\    WHERE health_dismissals.file_id = library_health_issues.file_id
    \\      AND health_dismissals.kind = library_health_issues.kind
    \\      AND health_dismissals.quick_hash IS files.quick_hash)
;

const health_page_select_sql =
    \\SELECT library_health_issues.file_id, kind, severity, details,
    \\       COALESCE((
    \\           SELECT uri FROM locations
    \\           WHERE locations.file_id = library_health_issues.file_id
    \\           ORDER BY locations.id LIMIT 1
    \\       ), ''),
    \\       related_file_id,
    \\       (SELECT min(tracks.id) FROM tracks
    \\        WHERE tracks.preferred_file_id = library_health_issues.file_id
    \\           OR tracks.recording_id = files.recording_id)
    \\
;

pub const health_page_sql = health_page_select_sql ++ visible_issues_sql ++ "\n" ++
    \\ORDER BY severity DESC, kind, library_health_issues.file_id LIMIT ?1 OFFSET ?2;
;

pub const health_page_of_kind_sql = health_page_select_sql ++ visible_issues_sql ++ "\n" ++
    \\  AND library_health_issues.kind = ?3
    \\ORDER BY severity DESC, library_health_issues.file_id LIMIT ?1 OFFSET ?2;
;

pub const health_count_sql = "SELECT count(*) " ++ visible_issues_sql ++ ";";

pub const health_summary_sql = "SELECT library_health_issues.kind, max(severity), count(*), " ++
    "COALESCE(sum(max(files.size_bytes, 0)), 0) " ++
    visible_issues_sql ++ "\n" ++
    \\GROUP BY library_health_issues.kind
    \\ORDER BY max(severity) DESC, library_health_issues.kind;
;

/// The bytes the visible issues of one duplicate kind, ?1, could free. A file
/// with no related file holds its duplicates as further locations of its own
/// row, each a copy. A file with one is a copy unless no lower-numbered file
/// is linked to it by an issue of the kind in either direction, which makes it
/// the copy that is kept.
pub const health_reclaimable_sql = "SELECT COALESCE(sum(max(files.size_bytes, 0) * CASE\n" ++
    \\    WHEN library_health_issues.related_file_id IS NULL THEN max((
    \\        SELECT count(*) FROM locations
    \\        WHERE locations.file_id = files.id AND locations.state <> 'missing') - 1, 0)
    \\    WHEN library_health_issues.related_file_id < library_health_issues.file_id
    \\      OR EXISTS (SELECT 1 FROM library_health_issues AS linked
    \\                 WHERE linked.related_file_id = library_health_issues.file_id
    \\                   AND linked.kind = library_health_issues.kind
    \\                   AND linked.file_id < library_health_issues.file_id) THEN 1
    \\    ELSE 0 END), 0)
    \\
++ visible_issues_sql ++ "\n" ++
    \\  AND library_health_issues.kind = ?1;
;

/// The visible issues of one kind.
pub const HealthKindSummary = struct {
    kind: HealthIssueKind,
    /// The highest severity among them.
    severity: HealthSeverity,
    count: u64,
    /// The files with such an issue. A file has at most one issue of a kind,
    /// so this equals `count`.
    files: u64,
    /// The summed size of those files. For `exact_duplicate` and
    /// `likely_duplicate` it is the size of the redundant copies only, what
    /// removing them would free: of a kept copy and two duplicates of 10 MB
    /// each, 20 MB. The kept copy of a group is the lowest-numbered file in
    /// it, and a second location of one file is a copy of it.
    bytes: u64,
};

/// One entry per kind with at least one visible issue, highest severity
/// first, then in kind order.
pub const HealthSummary = struct {
    buffer: [std.meta.fields(HealthIssueKind).len]HealthKindSummary = undefined,
    len: usize = 0,

    pub fn items(self: *const HealthSummary) []const HealthKindSummary {
        return self.buffer[0..self.len];
    }
};

pub const HealthIssueRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Replaces all derived health state for one file in a single transaction.
    /// An empty issue list marks the file healthy.
    pub fn replaceFile(
        self: *HealthIssueRepository,
        file_id: i64,
        issues: []const HealthIssueInput,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var delete = try self.db.prepare("DELETE FROM library_health_issues WHERE file_id=?1;");
        defer delete.deinit();
        try delete.bindInt64(1, file_id);
        if (try delete.step() != .done) return error.SqlFailed;
        var insert = try self.db.prepare(
            \\INSERT INTO library_health_issues(file_id, kind, severity, details, related_file_id, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, unixepoch());
        );
        defer insert.deinit();
        for (issues) |issue| {
            try insert.bindInt64(1, file_id);
            try insert.bindInt64(2, @intFromEnum(issue.kind));
            try insert.bindInt64(3, @intFromEnum(issue.severity));
            try insert.bindText(4, issue.details);
            try insert.bindOptionalInt64(5, issue.related_file_id);
            if (try insert.step() != .done) return error.SqlFailed;
            try insert.reset();
        }
        try self.db.exec("COMMIT;");
    }

    /// Record one derived issue without disturbing the others.
    ///
    /// Each pass owns only the kinds it decides (see `docs/analysis.md`), so
    /// the projection must not be able to erase a loudness or corruption
    /// finding on its way past.
    pub fn recordLocked(
        self: *HealthIssueRepository,
        file_id: i64,
        issue: HealthIssueInput,
    ) !void {
        try recordIssueLocked(self.db, file_id, issue);
    }

    /// Retire one issue kind for one file, so a reprojection that resolves the
    /// problem also clears the report of it.
    pub fn clearLocked(
        self: *HealthIssueRepository,
        file_id: i64,
        kind: HealthIssueKind,
    ) !void {
        try clearIssueLocked(self.db, file_id, kind);
    }

    /// Record `finding` when there is one, and otherwise retire `kind`.
    pub fn settleLocked(
        self: *HealthIssueRepository,
        file_id: i64,
        kind: HealthIssueKind,
        finding: ?HealthIssueInput,
    ) !void {
        if (finding) |issue| {
            std.debug.assert(issue.kind == kind);
            try self.recordLocked(file_id, issue);
        } else try self.clearLocked(file_id, kind);
    }

    /// Hides `kind` on the file until its bytes change: the dismissal keeps
    /// the file's current quick hash, and an issue shows again once the file
    /// has another.
    pub fn dismiss(self: *HealthIssueRepository, file_id: i64, kind: HealthIssueKind) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO health_dismissals(file_id, kind, quick_hash, dismissed_at)
            \\SELECT id, ?2, quick_hash, unixepoch() FROM files WHERE id = ?1
            \\ON CONFLICT(file_id, kind) DO UPDATE SET
            \\    quick_hash=excluded.quick_hash,
            \\    dismissed_at=excluded.dismissed_at;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, @intFromEnum(kind));
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() == 0) return error.UnknownFile;
    }

    /// Forgets a dismissal, so the issue shows again. Restoring an issue that
    /// was never dismissed changes nothing.
    pub fn restore(self: *HealthIssueRepository, file_id: i64, kind: HealthIssueKind) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            "DELETE FROM health_dismissals WHERE file_id=?1 AND kind=?2;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, @intFromEnum(kind));
        if (try statement.step() != .done) return error.SqlFailed;
    }

    pub fn page(
        self: *const HealthIssueRepository,
        allocator: std.mem.Allocator,
        limit: u32,
        offset: u32,
    ) !HealthIssuePage {
        var statement = try self.db.prepare(health_page_sql);
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        try statement.bindInt64(2, offset);
        return self.collectPage(allocator, statement);
    }

    /// The page of `page` holding only issues of `kind`, in the same order.
    pub fn pageOfKind(
        self: *const HealthIssueRepository,
        allocator: std.mem.Allocator,
        kind: HealthIssueKind,
        limit: u32,
        offset: u32,
    ) !HealthIssuePage {
        var statement = try self.db.prepare(health_page_of_kind_sql);
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        try statement.bindInt64(2, offset);
        try statement.bindInt64(3, @intFromEnum(kind));
        return self.collectPage(allocator, statement);
    }

    fn collectPage(
        self: *const HealthIssueRepository,
        allocator: std.mem.Allocator,
        statement: sqlite.Statement,
    ) !HealthIssuePage {
        var release_of = try self.db.prepare("SELECT release_id FROM tracks WHERE id = ?1;");
        defer release_of.deinit();
        const artwork: ReleaseArtworkRepository = .{ .db = self.db, .write_lane = self.write_lane };
        var release_has_mbid_by_id: std.AutoHashMapUnmanaged(i64, bool) = .empty;
        defer release_has_mbid_by_id.deinit(allocator);
        var issues: std.ArrayList(HealthIssue) = .empty;
        errdefer {
            for (issues.items) |issue| issue.deinit(allocator);
            issues.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const kind = std.enums.fromInt(HealthIssueKind, statement.columnInt64(1)) orelse
                return error.InvalidStoredHealthIssue;
            const severity = std.enums.fromInt(HealthSeverity, statement.columnInt64(2)) orelse
                return error.InvalidStoredHealthSeverity;
            const track_id = optionalInt64(statement, 6);
            var release_id: ?i64 = null;
            if (track_id) |id| {
                try release_of.bindInt64(1, id);
                if (try release_of.step() == .row) release_id = optionalInt64(release_of, 0);
                try release_of.reset();
            }
            var release_has_mbid = false;
            if (kind == .artwork_problem) if (release_id) |id| {
                const known = try release_has_mbid_by_id.getOrPut(allocator, id);
                if (!known.found_existing) known.value_ptr.* = try artwork.coverReleaseMbid(allocator, id) != null;
                release_has_mbid = known.value_ptr.*;
            };
            const path = try allocator.dupe(u8, statement.columnText(4));
            errdefer allocator.free(path);
            const details = try allocator.dupe(u8, statement.columnText(3));
            errdefer allocator.free(details);
            try issues.append(allocator, .{
                .file_id = statement.columnInt64(0),
                .path = path,
                .kind = kind,
                .severity = severity,
                .details = details,
                .track_id = track_id,
                .release_id = release_id,
                .related_file_id = optionalInt64(statement, 5),
                .action = .of(kind, release_has_mbid),
            });
        }
        return .{ .allocator = allocator, .items = try issues.toOwnedSlice(allocator) };
    }

    pub fn count(self: *const HealthIssueRepository) !u64 {
        var statement = try self.db.prepare(health_count_sql);
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn summary(self: *const HealthIssueRepository) !HealthSummary {
        var statement = try self.db.prepare(health_summary_sql);
        defer statement.deinit();
        var result: HealthSummary = .{};
        while (try statement.step() == .row) {
            const kind = std.enums.fromInt(HealthIssueKind, statement.columnInt64(0)) orelse
                return error.InvalidStoredHealthIssue;
            const severity = std.enums.fromInt(HealthSeverity, statement.columnInt64(1)) orelse
                return error.InvalidStoredHealthSeverity;
            const count_of_kind: u64 = @intCast(statement.columnInt64(2));
            std.debug.assert(result.len < result.buffer.len);
            result.buffer[result.len] = .{
                .kind = kind,
                .severity = severity,
                .count = count_of_kind,
                .files = count_of_kind,
                .bytes = @intCast(statement.columnInt64(3)),
            };
            result.len += 1;
        }
        for (result.buffer[0..result.len]) |*entry| switch (entry.kind) {
            .exact_duplicate, .likely_duplicate => entry.bytes = try self.reclaimable(entry.kind),
            else => {},
        };
        return result;
    }

    fn reclaimable(self: *const HealthIssueRepository, kind: HealthIssueKind) !u64 {
        var statement = try self.db.prepare(health_reclaimable_sql);
        defer statement.deinit();
        try statement.bindInt64(1, @intFromEnum(kind));
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// The file behind an issue, or null when it does not exist.
    pub fn file(self: *const HealthIssueRepository, allocator: std.mem.Allocator, file_id: i64) !?HealthFile {
        var statement = try self.db.prepare(
            \\SELECT codec, size_bytes, sample_rate, bit_depth, channels, duration_ms,
            \\       (SELECT locations.uri FROM locations
            \\        WHERE locations.file_id = files.id AND locations.state <> 'missing'
            \\        ORDER BY CASE locations.state WHEN 'present' THEN 0 ELSE 1 END, locations.id
            \\        LIMIT 1)
            \\FROM files WHERE id = ?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        if (try statement.step() != .row) return null;
        const codec = try allocator.dupe(u8, statement.columnText(0));
        errdefer allocator.free(codec);
        const path: ?[]u8 = if (statement.columnIsNull(6)) null else try allocator.dupe(u8, statement.columnText(6));
        return .{
            .allocator = allocator,
            .file_id = file_id,
            .path = path,
            .missing = path == null,
            .codec = codec,
            .sample_rate = optionalU32(statement, 2),
            .bit_depth = optionalU32(statement, 3),
            .channels = optionalU32(statement, 4),
            .size_bytes = if (optionalInt64(statement, 1)) |size| if (size > 0) size else null else null,
            .duration_ms = optionalInt64(statement, 5),
        };
    }
};

fn optionalU32(statement: sqlite.Statement, index: c_int) ?u32 {
    return std.math.cast(u32, optionalInt64(statement, index) orelse return null);
}
