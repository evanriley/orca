const std = @import("std");
const sqlite = @import("../sqlite.zig");

const WriteLane = @import("write_lane.zig").WriteLane;

pub const ScanRunState = enum {
    running,
    completed,
    cancelled,
    failed,

    pub fn text(self: ScanRunState) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) ?ScanRunState {
        return std.meta.stringToEnum(ScanRunState, value);
    }
};

pub const ScanRun = struct {
    id: i64,
    root_id: i64,
    /// Monotonic per root. A location not stamped with the generation of a
    /// completed run is a sweep candidate, never a deletion candidate.
    generation: i64,
};

pub const ScanCounters = struct {
    files_seen: u64 = 0,
    changed: u64 = 0,
    unchanged: u64 = 0,
    unsupported: u64 = 0,
    errors: u64 = 0,
};

pub const ScanRunRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Opens a run with the next generation for this root. Generations are
    /// per-root and monotonic so a sweep can name exactly the locations this
    /// run did not reach.
    pub fn begin(self: *ScanRunRepository, root_id: i64) !ScanRun {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO scan_runs(root_id, generation, started_at, state)
            \\VALUES (
            \\    ?1,
            \\    COALESCE((SELECT max(generation) FROM scan_runs WHERE root_id=?1), 0) + 1,
            \\    unixepoch(),
            \\    'running'
            \\) RETURNING id, generation;
        );
        defer statement.deinit();
        try statement.bindInt64(1, root_id);
        if (try statement.step() != .row) return error.SqlFailed;
        return .{
            .id = statement.columnInt64(0),
            .root_id = root_id,
            .generation = statement.columnInt64(1),
        };
    }

    pub fn finish(
        self: *ScanRunRepository,
        run_id: i64,
        result: ScanRunState,
        counters: ScanCounters,
    ) !void {
        if (result == .running) return error.InvalidScanRunState;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE scan_runs SET state=?1, finished_at=unixepoch(),
            \\    files_seen=?2, changed=?3, unchanged=?4, unsupported=?5, errors=?6
            \\WHERE id=?7 AND state='running';
        );
        defer statement.deinit();
        try statement.bindText(1, result.text());
        try statement.bindInt64(2, @intCast(counters.files_seen));
        try statement.bindInt64(3, @intCast(counters.changed));
        try statement.bindInt64(4, @intCast(counters.unchanged));
        try statement.bindInt64(5, @intCast(counters.unsupported));
        try statement.bindInt64(6, @intCast(counters.errors));
        try statement.bindInt64(7, run_id);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleScanRun;
    }

    pub fn cancel(self: *ScanRunRepository, run_id: i64, counters: ScanCounters) !void {
        return self.finish(run_id, .cancelled, counters);
    }

    pub fn outcome(self: *const ScanRunRepository, run_id: i64) !ScanRunState {
        var statement = try self.db.prepare("SELECT state FROM scan_runs WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, run_id);
        if (try statement.step() != .row) return error.ScanRunNotFound;
        return ScanRunState.parse(statement.columnText(0)) orelse
            error.InvalidStoredScanRunState;
    }
};
