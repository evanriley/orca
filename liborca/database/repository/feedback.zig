const std = @import("std");
const sqlite = @import("../sqlite.zig");
const columns = @import("../columns.zig");

const max_page = columns.max_page;
const optionalInt64 = columns.optionalInt64;
const effectiveRecordingMbid = @import("tracks.zig").effectiveRecordingMbid;
const WriteLane = @import("write_lane.zig").WriteLane;

pub const Feedback = enum {
    none,
    loved,
    hated,

    pub fn score(self: Feedback) i8 {
        return switch (self) {
            .none => 0,
            .loved => 1,
            .hated => -1,
        };
    }

    pub fn fromScore(value: i64) ?Feedback {
        return switch (value) {
            0 => .none,
            1 => .loved,
            -1 => .hated,
            else => null,
        };
    }
};

pub const FeedbackChange = struct {
    updated: u32 = 0,
    skipped: u32 = 0,
};

pub const FeedbackSync = struct {
    allocator: std.mem.Allocator,
    recording_id: i64,
    feedback: Feedback,
    recording_mbid: []u8,

    pub fn deinit(self: FeedbackSync) void {
        self.allocator.free(self.recording_mbid);
    }
};

pub const feedback_settle_seconds: i64 = 2;

pub const feedback_next_sql =
    "SELECT feedback.recording_id, feedback.score, " ++ effectiveRecordingMbid("files.id") ++ " AS mbid\n" ++
    "FROM feedback\n" ++
    "CROSS JOIN files ON files.recording_id = feedback.recording_id\n" ++
    "WHERE feedback.score IS NOT feedback.synced_score\n" ++
    "  AND feedback.updated_at <= ?1\n" ++
    "  AND mbid IS NOT NULL\n" ++
    "ORDER BY feedback.updated_at, feedback.recording_id,\n" ++
    "         EXISTS(SELECT 1 FROM tracks WHERE tracks.preferred_file_id = files.id) DESC, files.id\n" ++
    "LIMIT 1;";

pub const feedback_pending_sql =
    "SELECT count(*) FROM feedback\n" ++
    "WHERE score IS NOT synced_score AND EXISTS (\n" ++
    "    SELECT 1 FROM files WHERE files.recording_id = feedback.recording_id\n" ++
    "      AND " ++ effectiveRecordingMbid("files.id") ++ " IS NOT NULL);";

pub const feedback_syncable_sql =
    "SELECT EXISTS (\n" ++
    "    SELECT 1 FROM files\n" ++
    "    WHERE files.recording_id = (SELECT recording_id FROM tracks WHERE id = ?1)\n" ++
    "      AND " ++ effectiveRecordingMbid("files.id") ++ " IS NOT NULL);";

pub const FeedbackRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn set(self: *FeedbackRepository, track_ids: []const i64, feedback: Feedback) !FeedbackChange {
        if (track_ids.len > max_page) return error.PageOutOfRange;
        var change: FeedbackChange = .{};
        if (track_ids.len == 0) return change;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var find = try self.db.prepare("SELECT recording_id FROM tracks WHERE id=?1;");
        defer find.deinit();
        var assign = try self.db.prepare(
            \\INSERT INTO feedback(recording_id, score, updated_at) VALUES (?1, ?2, unixepoch())
            \\ON CONFLICT(recording_id) DO UPDATE SET
            \\    score=excluded.score, updated_at=excluded.updated_at, last_error='';
        );
        defer assign.deinit();
        var retract = try self.db.prepare(
            \\UPDATE feedback SET score=0, updated_at=unixepoch()
            \\WHERE recording_id=?1 AND COALESCE(synced_score, 0) <> 0 AND last_error = '';
        );
        defer retract.deinit();
        var forget = try self.db.prepare(
            "DELETE FROM feedback WHERE recording_id=?1 AND (COALESCE(synced_score, 0) = 0 OR last_error <> '');",
        );
        defer forget.deinit();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        for (track_ids) |track_id| {
            try find.bindInt64(1, track_id);
            const found = try find.step() == .row;
            const recording_id = if (found) optionalInt64(find, 0) else null;
            try find.reset();
            const recording = recording_id orelse {
                change.skipped += 1;
                continue;
            };
            switch (feedback) {
                .none => {
                    try retract.bindInt64(1, recording);
                    if (try retract.step() != .done) return error.SqlFailed;
                    var changed = self.db.changes();
                    try retract.reset();
                    try forget.bindInt64(1, recording);
                    if (try forget.step() != .done) return error.SqlFailed;
                    changed += self.db.changes();
                    try forget.reset();
                    if (changed != 0) change.updated += 1;
                },
                .loved, .hated => {
                    try assign.bindInt64(1, recording);
                    try assign.bindInt64(2, feedback.score());
                    if (try assign.step() != .done) return error.SqlFailed;
                    try assign.reset();
                    change.updated += 1;
                },
            }
        }
        try self.db.exec("COMMIT;");
        return change;
    }

    pub fn forTrack(self: *const FeedbackRepository, track_id: i64) !Feedback {
        var statement = try self.db.prepare(
            \\SELECT feedback.score FROM tracks
            \\JOIN feedback ON feedback.recording_id = tracks.recording_id
            \\WHERE tracks.id = ?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return .none;
        return Feedback.fromScore(statement.columnInt64(0)) orelse error.InvalidStoredFeedback;
    }

    pub fn canSync(self: *const FeedbackRepository, track_id: i64) !bool {
        var statement = try self.db.prepare(feedback_syncable_sql);
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return false;
        return statement.columnInt64(0) != 0;
    }

    pub fn nextToSync(self: *const FeedbackRepository, allocator: std.mem.Allocator, now: i64) !?FeedbackSync {
        var statement = try self.db.prepare(feedback_next_sql);
        defer statement.deinit();
        try statement.bindInt64(1, now -| feedback_settle_seconds);
        if (try statement.step() != .row) return null;
        const mbid = try allocator.dupe(u8, statement.columnText(2));
        return .{
            .allocator = allocator,
            .recording_id = statement.columnInt64(0),
            .feedback = Feedback.fromScore(statement.columnInt64(1)) orelse {
                allocator.free(mbid);
                return error.InvalidStoredFeedback;
            },
            .recording_mbid = mbid,
        };
    }

    pub fn pendingSyncCount(self: *const FeedbackRepository) !u64 {
        var statement = try self.db.prepare(feedback_pending_sql);
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn markSynced(self: *FeedbackRepository, recording_id: i64, sent: Feedback) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var update = try self.db.prepare(
            "UPDATE feedback SET synced_score=?2, synced_at=unixepoch(), last_error='' WHERE recording_id=?1;",
        );
        defer update.deinit();
        try update.bindInt64(1, recording_id);
        try update.bindInt64(2, sent.score());
        if (try update.step() != .done) return error.SqlFailed;
        if (self.db.changes() == 0 and sent != .none) {
            // The user cleared this while it was being sent; the clear still has to go out.
            var restore = try self.db.prepare(
                \\INSERT INTO feedback(recording_id, score, updated_at, synced_score, synced_at)
                \\SELECT id, 0, unixepoch(), ?2, unixepoch() FROM recordings WHERE id=?1;
            );
            defer restore.deinit();
            try restore.bindInt64(1, recording_id);
            try restore.bindInt64(2, sent.score());
            if (try restore.step() != .done) return error.SqlFailed;
        }
        try self.forgetSettledLocked(recording_id);
        try self.db.exec("COMMIT;");
    }

    pub fn markRejected(self: *FeedbackRepository, recording_id: i64, sent: Feedback, details: []const u8) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        var update = try self.db.prepare(
            "UPDATE feedback SET synced_score=?2, last_error=?3 WHERE recording_id=?1;",
        );
        defer update.deinit();
        try update.bindInt64(1, recording_id);
        try update.bindInt64(2, sent.score());
        try update.bindText(3, details);
        if (try update.step() != .done) return error.SqlFailed;
        try self.forgetSettledLocked(recording_id);
        try self.db.exec("COMMIT;");
    }

    fn forgetSettledLocked(self: *FeedbackRepository, recording_id: i64) !void {
        var statement = try self.db.prepare(
            "DELETE FROM feedback WHERE recording_id=?1 AND score=0 AND COALESCE(synced_score, 0) = 0;",
        );
        defer statement.deinit();
        try statement.bindInt64(1, recording_id);
        if (try statement.step() != .done) return error.SqlFailed;
    }
};
