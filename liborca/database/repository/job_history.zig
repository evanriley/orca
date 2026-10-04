const std = @import("std");
const sqlite = @import("../sqlite.zig");
const columns = @import("../columns.zig");
const WriteLane = @import("write_lane.zig").WriteLane;

const optionalInt64 = columns.optionalInt64;

pub const retained_rows = 1000;

pub const JobHistoryFilter = enum {
    all,
    scans,
    analysis,
    file_changes,
    problems,

    fn condition(self: JobHistoryFilter) [:0]const u8 {
        return switch (self) {
            .all => "1",
            .scans => "kind IN ('scan', 'reconcile', 'projection', 'property_backfill')",
            .analysis => "kind IN ('analysis', 'duplicate_scan', 'consistency')",
            .file_changes => "kind = 'mutation'",
            .problems => "state IN ('failed', 'cancelled')",
        };
    }
};

pub const JobHistoryInput = struct {
    kind: []const u8,
    request: ?[]const u8 = null,
    started_at: i64,
    finished_at: i64,
    state: []const u8,
    completed_units: u64,
    total_units: ?u64 = null,
    error_text: ?[]const u8 = null,
    undo_group_id: ?u64 = null,
    retryable: bool = false,
    summary: []const u8 = "",
};

pub const JobHistoryRow = struct {
    allocator: std.mem.Allocator,
    id: i64,
    kind: []u8,
    request: ?[]u8,
    started_at: i64,
    finished_at: i64,
    state: []u8,
    completed_units: u64,
    total_units: ?u64,
    error_text: ?[]u8,
    undo_group_id: ?u64,
    retryable: bool,
    summary: []u8,

    pub fn deinit(self: JobHistoryRow) void {
        self.allocator.free(self.kind);
        if (self.request) |value| self.allocator.free(value);
        self.allocator.free(self.state);
        if (self.error_text) |value| self.allocator.free(value);
        self.allocator.free(self.summary);
    }
};

pub const JobHistoryPage = struct {
    allocator: std.mem.Allocator,
    items: []JobHistoryRow,

    pub fn deinit(self: *JobHistoryPage) void {
        for (self.items) |row| row.deinit();
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

const row_columns =
    "id, kind, request, started_at, finished_at, state, completed_units, total_units, error, undo_group_id, retryable, summary";

pub const JobHistoryRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Records a finished Job and forgets all but the newest `retained_rows`.
    pub fn insert(self: *JobHistoryRepository, input: JobHistoryInput) !i64 {
        const completed_units = std.math.cast(i64, input.completed_units) orelse return error.InvalidJobHistory;
        const total_units: ?i64 = if (input.total_units) |value|
            std.math.cast(i64, value) orelse return error.InvalidJobHistory
        else
            null;
        const undo_group_id: ?i64 = if (input.undo_group_id) |value|
            std.math.cast(i64, value) orelse return error.InvalidJobHistory
        else
            null;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var statement = try self.db.prepare(
            \\INSERT INTO job_history(kind, request, started_at, finished_at, state, completed_units,
            \\    total_units, error, undo_group_id, retryable, summary)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);
        );
        defer statement.deinit();
        try statement.bindText(1, input.kind);
        try statement.bindOptionalText(2, input.request);
        try statement.bindInt64(3, input.started_at);
        try statement.bindInt64(4, input.finished_at);
        try statement.bindText(5, input.state);
        try statement.bindInt64(6, completed_units);
        try statement.bindOptionalInt64(7, total_units);
        try statement.bindOptionalText(8, input.error_text);
        try statement.bindOptionalInt64(9, undo_group_id);
        try statement.bindInt64(10, @intFromBool(input.retryable));
        try statement.bindText(11, input.summary);
        if (try statement.step() != .done) return error.SqlFailed;
        const id = self.db.lastInsertRowId();
        var prune = try self.db.prepare(
            \\DELETE FROM job_history WHERE id <= (
            \\    SELECT id FROM job_history ORDER BY id DESC LIMIT 1 OFFSET ?1);
        );
        defer prune.deinit();
        try prune.bindInt64(1, retained_rows);
        if (try prune.step() != .done) return error.SqlFailed;
        try self.db.exec("COMMIT;");
        return id;
    }

    /// Newest first.
    pub fn page(
        self: *const JobHistoryRepository,
        allocator: std.mem.Allocator,
        filter: JobHistoryFilter,
        limit: u32,
        offset: u32,
    ) !JobHistoryPage {
        if (limit == 0 or limit > columns.max_page) return error.InvalidLimit;
        var sql_buffer: [512]u8 = undefined;
        const sql = std.fmt.bufPrintSentinel(
            &sql_buffer,
            "SELECT " ++ row_columns ++ " FROM job_history WHERE {s} ORDER BY finished_at DESC, id DESC LIMIT ?1 OFFSET ?2;",
            .{filter.condition()},
            0,
        ) catch unreachable;
        var statement = try self.db.prepare(sql);
        defer statement.deinit();
        try statement.bindInt64(1, limit);
        try statement.bindInt64(2, offset);
        var rows: std.ArrayList(JobHistoryRow) = .empty;
        errdefer {
            for (rows.items) |row| row.deinit();
            rows.deinit(allocator);
        }
        while (try statement.step() == .row) {
            try rows.ensureUnusedCapacity(allocator, 1);
            rows.appendAssumeCapacity(try readRow(allocator, statement));
        }
        return .{ .allocator = allocator, .items = try rows.toOwnedSlice(allocator) };
    }

    pub fn get(self: *const JobHistoryRepository, allocator: std.mem.Allocator, id: i64) !?JobHistoryRow {
        var statement = try self.db.prepare("SELECT " ++ row_columns ++ " FROM job_history WHERE id = ?1;");
        defer statement.deinit();
        try statement.bindInt64(1, id);
        if (try statement.step() != .row) return null;
        return try readRow(allocator, statement);
    }
};

fn readRow(allocator: std.mem.Allocator, statement: sqlite.Statement) !JobHistoryRow {
    const kind = try allocator.dupe(u8, statement.columnText(1));
    errdefer allocator.free(kind);
    const request: ?[]u8 = if (statement.columnIsNull(2)) null else try allocator.dupe(u8, statement.columnText(2));
    errdefer if (request) |value| allocator.free(value);
    const state = try allocator.dupe(u8, statement.columnText(5));
    errdefer allocator.free(state);
    const error_text: ?[]u8 = if (statement.columnIsNull(8)) null else try allocator.dupe(u8, statement.columnText(8));
    errdefer if (error_text) |value| allocator.free(value);
    const summary = try allocator.dupe(u8, statement.columnText(11));
    return .{
        .allocator = allocator,
        .id = statement.columnInt64(0),
        .kind = kind,
        .request = request,
        .started_at = statement.columnInt64(3),
        .finished_at = statement.columnInt64(4),
        .state = state,
        .completed_units = std.math.cast(u64, statement.columnInt64(6)) orelse 0,
        .total_units = if (optionalInt64(statement, 7)) |value| std.math.cast(u64, value) else null,
        .error_text = error_text,
        .undo_group_id = if (optionalInt64(statement, 9)) |value| std.math.cast(u64, value) else null,
        .retryable = statement.columnInt64(10) != 0,
        .summary = summary,
    };
}

const LibraryDatabase = @import("../library.zig").LibraryDatabase;

test "job history pages newest first, filters by kind and problem, and keeps a bounded tail" {
    var library = try LibraryDatabase.open(std.testing.allocator, std.testing.io, "file:orca-test-job-history?mode=memory&cache=shared");
    defer library.close();
    const scan = try library.job_history.insert(.{
        .kind = "scan",
        .request = "{\"scan\":{\"root_id\":1}}",
        .started_at = 100,
        .finished_at = 160,
        .state = "succeeded",
        .completed_units = 12,
        .summary = "12 files",
    });
    _ = try library.job_history.insert(.{
        .kind = "analysis",
        .started_at = 200,
        .finished_at = 230,
        .state = "failed",
        .completed_units = 3,
        .total_units = 9,
        .error_text = "failed",
        .retryable = true,
    });
    _ = try library.job_history.insert(.{
        .kind = "mutation",
        .started_at = 300,
        .finished_at = 301,
        .state = "succeeded",
        .completed_units = 2,
        .total_units = 2,
        .undo_group_id = 7,
    });

    var all = try library.job_history.page(std.testing.allocator, .all, 10, 0);
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 3), all.items.len);
    try std.testing.expectEqualStrings("mutation", all.items[0].kind);
    try std.testing.expectEqual(@as(?u64, 7), all.items[0].undo_group_id);
    try std.testing.expectEqualStrings("scan", all.items[2].kind);

    var scans = try library.job_history.page(std.testing.allocator, .scans, 10, 0);
    defer scans.deinit();
    try std.testing.expectEqual(@as(usize, 1), scans.items.len);
    try std.testing.expectEqualStrings("12 files", scans.items[0].summary);

    var problems = try library.job_history.page(std.testing.allocator, .problems, 10, 0);
    defer problems.deinit();
    try std.testing.expectEqual(@as(usize, 1), problems.items.len);
    try std.testing.expect(problems.items[0].retryable);
    try std.testing.expectEqual(@as(?u64, 9), problems.items[0].total_units);

    const row = (try library.job_history.get(std.testing.allocator, scan)).?;
    defer row.deinit();
    try std.testing.expectEqualStrings("{\"scan\":{\"root_id\":1}}", row.request.?);
    try std.testing.expectEqual(@as(i64, 160), row.finished_at);
    try std.testing.expectError(error.InvalidLimit, library.job_history.page(std.testing.allocator, .all, 0, 0));

    for (0..retained_rows) |index| {
        _ = try library.job_history.insert(.{
            .kind = "projection",
            .started_at = 400,
            .finished_at = 400 + @as(i64, @intCast(index)),
            .state = "succeeded",
            .completed_units = 0,
        });
    }
    try std.testing.expectEqual(null, try library.job_history.get(std.testing.allocator, scan));
    var oldest = try library.job_history.page(std.testing.allocator, .all, 1, retained_rows - 1);
    defer oldest.deinit();
    try std.testing.expectEqual(@as(usize, 1), oldest.items.len);
    var beyond = try library.job_history.page(std.testing.allocator, .all, 1, retained_rows);
    defer beyond.deinit();
    try std.testing.expectEqual(@as(usize, 0), beyond.items.len);
}
