const std = @import("std");
const sqlite = @import("../sqlite.zig");

const WriteLane = @import("write_lane.zig").WriteLane;

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
};

pub const HealthSeverity = enum(u8) { information, warning, error_severity };

pub const HealthIssueInput = struct {
    kind: HealthIssueKind,
    severity: HealthSeverity,
    details: []const u8 = "",
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
            \\INSERT INTO library_health_issues(file_id, kind, severity, details, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, unixepoch());
        );
        defer insert.deinit();
        for (issues) |issue| {
            try insert.bindInt64(1, file_id);
            try insert.bindInt64(2, @intFromEnum(issue.kind));
            try insert.bindInt64(3, @intFromEnum(issue.severity));
            try insert.bindText(4, issue.details);
            if (try insert.step() != .done) return error.SqlFailed;
            try insert.reset();
        }
        try self.db.exec("COMMIT;");
    }

    /// Record one derived issue without disturbing the others.
    ///
    /// `replaceFile` is the analyzer's call: it owns every issue it can decide.
    /// The projection decides exactly one kind — `missing_track_number` — so it
    /// must not be able to erase a loudness or corruption finding on its way
    /// past.
    pub fn recordLocked(
        self: *HealthIssueRepository,
        file_id: i64,
        issue: HealthIssueInput,
    ) !void {
        var statement = try self.db.prepare(
            \\INSERT INTO library_health_issues(file_id, kind, severity, details, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, unixepoch())
            \\ON CONFLICT(file_id, kind) DO UPDATE SET
            \\    severity=excluded.severity,
            \\    details=excluded.details,
            \\    updated_at=excluded.updated_at;
        );
        defer statement.deinit();
        try statement.bindInt64(1, file_id);
        try statement.bindInt64(2, @intFromEnum(issue.kind));
        try statement.bindInt64(3, @intFromEnum(issue.severity));
        try statement.bindText(4, issue.details);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Retire one issue kind for one file, so a reprojection that resolves the
    /// problem also clears the report of it.
    pub fn clearLocked(
        self: *HealthIssueRepository,
        file_id: i64,
        kind: HealthIssueKind,
    ) !void {
        var statement = try self.db.prepare(
            "DELETE FROM library_health_issues WHERE file_id=?1 AND kind=?2;",
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
        var statement = try self.db.prepare(
            \\SELECT library_health_issues.file_id, kind, severity, details,
            \\       COALESCE((
            \\           SELECT uri FROM locations
            \\           WHERE locations.file_id = library_health_issues.file_id
            \\           ORDER BY locations.id LIMIT 1
            \\       ), '')
            \\FROM library_health_issues
            \\ORDER BY severity DESC, kind, file_id LIMIT ?1 OFFSET ?2;
        );
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        try statement.bindInt64(2, offset);
        var issues: std.ArrayList(HealthIssue) = .empty;
        errdefer {
            for (issues.items) |issue| issue.deinit(allocator);
            issues.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const path = try allocator.dupe(u8, statement.columnText(4));
            errdefer allocator.free(path);
            const details = try allocator.dupe(u8, statement.columnText(3));
            errdefer allocator.free(details);
            try issues.append(allocator, .{
                .file_id = statement.columnInt64(0),
                .path = path,
                .kind = std.enums.fromInt(HealthIssueKind, statement.columnInt64(1)) orelse
                    return error.InvalidStoredHealthIssue,
                .severity = std.enums.fromInt(HealthSeverity, statement.columnInt64(2)) orelse
                    return error.InvalidStoredHealthSeverity,
                .details = details,
            });
        }
        return .{ .allocator = allocator, .items = try issues.toOwnedSlice(allocator) };
    }

    pub fn count(self: *const HealthIssueRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM library_health_issues;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};
