const sqlite = @import("../sqlite.zig");

const WriteLane = @import("write_lane.zig").WriteLane;

/// A performance, distinct from the Track position that presents it and from
/// the files that encode it.
pub const RecordingInput = struct {
    title: []const u8,
    duration_ms: ?i64 = null,
};

/// Recordings — performances — which files encode and tracks position.
///
/// The schema carries no key column for a recording, so the projection keeps
/// the mapping itself and reuses whatever `files.recording_id` already says.
/// This repository therefore inserts and updates; it never resolves.
pub const RecordingRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn insertLocked(self: *RecordingRepository, input: RecordingInput) !i64 {
        var statement = try self.db.prepare(
            "INSERT INTO recordings(title, duration_ms) VALUES (?1, ?2) RETURNING id;",
        );
        defer statement.deinit();
        try statement.bindText(1, input.title);
        try statement.bindOptionalInt64(2, input.duration_ms);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    pub fn updateLocked(self: *RecordingRepository, id: i64, input: RecordingInput) !void {
        var statement = try self.db.prepare(
            "UPDATE recordings SET title=?1, duration_ms=COALESCE(?2, duration_ms) WHERE id=?3;",
        );
        defer statement.deinit();
        try statement.bindText(1, input.title);
        try statement.bindOptionalInt64(2, input.duration_ms);
        try statement.bindInt64(3, id);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    pub fn count(self: *const RecordingRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM recordings;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }
};
