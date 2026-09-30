const std = @import("std");
const sqlite = @import("../sqlite.zig");

const WriteLane = @import("write_lane.zig").WriteLane;

pub const ProviderCacheEntry = struct {
    allocator: std.mem.Allocator,
    status: u16,
    body: []u8,
    expires_at: i64,

    pub fn deinit(self: ProviderCacheEntry) void {
        self.allocator.free(self.body);
    }
};

pub const ProviderCacheRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn get(
        self: *const ProviderCacheRepository,
        allocator: std.mem.Allocator,
        provider: []const u8,
        request_key: []const u8,
        now: i64,
        allow_stale: bool,
    ) !?ProviderCacheEntry {
        var statement = try self.db.prepare(
            \\SELECT status, body, expires_at FROM provider_cache
            \\WHERE provider=?1 AND request_key=?2
            \\  AND (?3 OR expires_at>?4);
        );
        defer statement.deinit();
        try statement.bindText(1, provider);
        try statement.bindText(2, request_key);
        try statement.bindInt64(3, @intFromBool(allow_stale));
        try statement.bindInt64(4, now);
        if (try statement.step() != .row) return null;
        return .{
            .allocator = allocator,
            .status = std.math.cast(u16, statement.columnInt64(0)) orelse
                return error.InvalidStoredHttpStatus,
            .body = try allocator.dupe(u8, statement.columnBlob(1)),
            .expires_at = statement.columnInt64(2),
        };
    }

    pub fn put(
        self: *ProviderCacheRepository,
        provider: []const u8,
        request_key: []const u8,
        status: u16,
        body: []const u8,
        expires_at: i64,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO provider_cache(provider, request_key, status, body, expires_at, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, unixepoch())
            \\ON CONFLICT(provider, request_key) DO UPDATE SET
            \\    status=excluded.status, body=excluded.body,
            \\    expires_at=excluded.expires_at, updated_at=excluded.updated_at;
        );
        defer statement.deinit();
        try statement.bindText(1, provider);
        try statement.bindText(2, request_key);
        try statement.bindInt64(3, status);
        try statement.bindBlob(4, body);
        try statement.bindInt64(5, expires_at);
        if (try statement.step() != .done) return error.SqlFailed;
    }
};
