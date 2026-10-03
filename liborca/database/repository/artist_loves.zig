const sqlite = @import("../sqlite.zig");
const columns = @import("../columns.zig");

const max_page = columns.max_page;
const WriteLane = @import("write_lane.zig").WriteLane;

pub const ArtistLoveChange = struct {
    updated: u32 = 0,
    skipped: u32 = 0,
};

pub const ArtistLoveRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn set(self: *ArtistLoveRepository, artist_ids: []const i64, loved: bool) !ArtistLoveChange {
        if (artist_ids.len > max_page) return error.PageOutOfRange;
        var change: ArtistLoveChange = .{};
        if (artist_ids.len == 0) return change;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var find = try self.db.prepare("SELECT 1 FROM artists WHERE id=?1;");
        defer find.deinit();
        var love = try self.db.prepare(
            "INSERT INTO artist_loves(artist_id, loved_at) VALUES (?1, unixepoch()) ON CONFLICT(artist_id) DO NOTHING;",
        );
        defer love.deinit();
        var clear = try self.db.prepare("DELETE FROM artist_loves WHERE artist_id=?1;");
        defer clear.deinit();
        try self.db.exec("BEGIN IMMEDIATE;");
        errdefer self.db.exec("ROLLBACK;") catch {};
        for (artist_ids) |artist_id| {
            try find.bindInt64(1, artist_id);
            const found = try find.step() == .row;
            try find.reset();
            if (!found) {
                change.skipped += 1;
                continue;
            }
            const statement = if (loved) &love else &clear;
            try statement.bindInt64(1, artist_id);
            if (try statement.step() != .done) return error.SqlFailed;
            if (self.db.changes() != 0) change.updated += 1;
            try statement.reset();
        }
        try self.db.exec("COMMIT;");
        return change;
    }

    pub fn isLoved(self: *const ArtistLoveRepository, artist_id: i64) !bool {
        var statement = try self.db.prepare("SELECT 1 FROM artist_loves WHERE artist_id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, artist_id);
        return try statement.step() == .row;
    }
};
