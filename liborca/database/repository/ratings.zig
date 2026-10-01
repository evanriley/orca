const std = @import("std");
const sqlite = @import("../sqlite.zig");
const columns = @import("../columns.zig");

const max_page = columns.max_page;
const optionalInt64 = columns.optionalInt64;
const WriteLane = @import("write_lane.zig").WriteLane;

pub const max_rating = 100;

pub const RatingChange = struct {
    updated: u32 = 0,
    skipped: u32 = 0,
};

pub const RatingRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn set(self: *RatingRepository, track_ids: []const i64, rating: ?u8) !RatingChange {
        if (track_ids.len > max_page) return error.PageOutOfRange;
        if (rating) |value| if (value == 0 or value > max_rating) return error.InvalidRating;
        var change: RatingChange = .{};
        if (track_ids.len == 0) return change;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var find = try self.db.prepare("SELECT recording_id FROM tracks WHERE id=?1;");
        defer find.deinit();
        var assign = try self.db.prepare(
            \\INSERT INTO ratings(recording_id, rating, updated_at) VALUES (?1, ?2, unixepoch())
            \\ON CONFLICT(recording_id) DO UPDATE SET rating=excluded.rating, updated_at=excluded.updated_at;
        );
        defer assign.deinit();
        var clear = try self.db.prepare("DELETE FROM ratings WHERE recording_id=?1;");
        defer clear.deinit();
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
            if (rating) |value| {
                try assign.bindInt64(1, recording);
                try assign.bindInt64(2, value);
                if (try assign.step() != .done) return error.SqlFailed;
                try assign.reset();
                change.updated += 1;
            } else {
                try clear.bindInt64(1, recording);
                if (try clear.step() != .done) return error.SqlFailed;
                if (self.db.changes() != 0) change.updated += 1;
                try clear.reset();
            }
        }
        try self.db.exec("COMMIT;");
        return change;
    }

    pub fn forTrack(self: *const RatingRepository, track_id: i64) !?u8 {
        var statement = try self.db.prepare(
            \\SELECT ratings.rating FROM tracks
            \\JOIN ratings ON ratings.recording_id = tracks.recording_id
            \\WHERE tracks.id = ?1;
        );
        defer statement.deinit();
        try statement.bindInt64(1, track_id);
        if (try statement.step() != .row) return null;
        return std.math.cast(u8, statement.columnInt64(0)) orelse error.InvalidStoredRating;
    }
};
