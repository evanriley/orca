const std = @import("std");
const sqlite = @import("../sqlite.zig");

const WriteLane = @import("write_lane.zig").WriteLane;

pub const VolumeInput = struct {
    stable_key: []const u8,
    label: []const u8 = "",
};

pub const VolumeRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    /// Volumes are identified by a key the platform adapter resolved, never by
    /// `st_dev`, which is not stable across reboots or remounts.
    pub fn ensure(self: *VolumeRepository, input: VolumeInput) !i64 {
        if (input.stable_key.len == 0) return error.InvalidVolumeKey;
        self.write_lane.acquire();
        defer self.write_lane.release();
        return self.ensureLocked(input);
    }

    /// Same as `ensure` for a caller that already holds the write lane.
    pub fn ensureLocked(self: *VolumeRepository, input: VolumeInput) !i64 {
        var statement = try self.db.prepare(
            \\INSERT INTO volumes(stable_key, label, last_seen_at)
            \\VALUES (?1, ?2, unixepoch())
            \\ON CONFLICT(stable_key) DO UPDATE SET
            \\    label=CASE WHEN excluded.label='' THEN volumes.label ELSE excluded.label END,
            \\    last_seen_at=excluded.last_seen_at
            \\RETURNING id;
        );
        defer statement.deinit();
        try statement.bindText(1, input.stable_key);
        try statement.bindText(2, input.label);
        if (try statement.step() != .row) return error.SqlFailed;
        return statement.columnInt64(0);
    }

    pub fn find(self: *const VolumeRepository, stable_key: []const u8) !?i64 {
        var statement = try self.db.prepare("SELECT id FROM volumes WHERE stable_key=?1;");
        defer statement.deinit();
        try statement.bindText(1, stable_key);
        if (try statement.step() != .row) return null;
        return statement.columnInt64(0);
    }

    pub fn stableKey(
        self: *const VolumeRepository,
        allocator: std.mem.Allocator,
        volume_id: i64,
    ) !?[]u8 {
        var statement = try self.db.prepare("SELECT stable_key FROM volumes WHERE id=?1;");
        defer statement.deinit();
        try statement.bindInt64(1, volume_id);
        if (try statement.step() != .row) return null;
        return try allocator.dupe(u8, statement.columnText(0));
    }
};
