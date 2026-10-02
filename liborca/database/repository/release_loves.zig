const sqlite = @import("../sqlite.zig");
const columns = @import("../columns.zig");

const max_page = columns.max_page;
const WriteLane = @import("write_lane.zig").WriteLane;

pub const ReleaseLoveChange = struct {
    updated: u32 = 0,
    skipped: u32 = 0,
};

pub const ReleaseLoveRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn set(self: *ReleaseLoveRepository, release_ids: []const i64, loved: bool) !ReleaseLoveChange {
        if (release_ids.len > max_page) return error.PageOutOfRange;
        var change: ReleaseLoveChange = .{};
        if (release_ids.len == 0) return change;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var find = try self.db.prepare("SELECT 1 FROM releases WHERE id=?1;");
        defer find.deinit();
        var love = try self.db.prepare(
            "INSERT INTO release_loves(release_id, loved_at) VALUES (?1, unixepoch()) ON CONFLICT(release_id) DO NOTHING;",
        );
        defer love.deinit();
        var clear = try self.db.prepare("DELETE FROM release_loves WHERE release_id=?1;");
        defer clear.deinit();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        for (release_ids) |release_id| {
            try find.bindInt64(1, release_id);
            const found = try find.step() == .row;
            try find.reset();
            if (!found) {
                change.skipped += 1;
                continue;
            }
            const statement = if (loved) &love else &clear;
            try statement.bindInt64(1, release_id);
            if (try statement.step() != .done) return error.SqlFailed;
            if (self.db.changes() != 0) change.updated += 1;
            try statement.reset();
        }
        try self.db.exec("COMMIT;");
        return change;
    }

    pub fn isLoved(self: *const ReleaseLoveRepository, release_id: i64) !bool {
        var statement = try self.db.prepare("SELECT 1 FROM release_loves WHERE release_id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, release_id);
        return try statement.step() == .row;
    }
};
