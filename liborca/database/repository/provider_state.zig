const std = @import("std");
const sqlite = @import("../sqlite.zig");

const WriteLane = @import("write_lane.zig").WriteLane;

/// A service's rate-limit state as `provider_state` holds it. Times are Unix
/// milliseconds.
pub const ProviderState = struct {
    blocked_until_ms: ?i64 = null,
    backoff_ms: u64 = 0,
    next_request_ms: ?i64 = null,
};

pub const ProviderStateRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn get(self: *const ProviderStateRepository, service: []const u8) !?ProviderState {
        var statement = try self.db.prepare(
            "SELECT blocked_until_ms, backoff_ms, next_request_ms FROM provider_state WHERE service=?1;",
        );
        defer statement.deinit();
        try statement.bindText(1, service);
        if (try statement.step() != .row) return null;
        return .{
            .blocked_until_ms = if (statement.columnIsNull(0)) null else statement.columnInt64(0),
            .backoff_ms = std.math.cast(u64, statement.columnInt64(1)) orelse return error.InvalidStoredBackoff,
            .next_request_ms = if (statement.columnIsNull(2)) null else statement.columnInt64(2),
        };
    }

    pub fn put(self: *ProviderStateRepository, service: []const u8, state: ProviderState) !void {
        const backoff_ms = std.math.cast(i64, state.backoff_ms) orelse return error.InvalidStoredBackoff;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO provider_state(service, blocked_until_ms, backoff_ms, next_request_ms)
            \\VALUES (?1, ?2, ?3, ?4)
            \\ON CONFLICT(service) DO UPDATE SET
            \\    blocked_until_ms=excluded.blocked_until_ms, backoff_ms=excluded.backoff_ms,
            \\    next_request_ms=excluded.next_request_ms;
        );
        defer statement.deinit();
        try statement.bindText(1, service);
        try statement.bindOptionalInt64(2, state.blocked_until_ms);
        try statement.bindInt64(3, backoff_ms);
        try statement.bindOptionalInt64(4, state.next_request_ms);
        if (try statement.step() != .done) return error.SqlFailed;
    }

    /// Claims `service` for `owner` until `expires_at_ms` when nobody holds
    /// it, the holder's lease ran out by `now_ms`, or `owner` already holds
    /// it. One statement, so two claimants never both succeed.
    pub fn claimLease(
        self: *ProviderStateRepository,
        service: []const u8,
        owner: i64,
        now_ms: i64,
        expires_at_ms: i64,
    ) !bool {
        if (expires_at_ms <= now_ms) return error.InvalidProviderLease;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\INSERT INTO provider_leases(service, owner, expires_at) VALUES (?1, ?2, ?4)
            \\ON CONFLICT(service) DO UPDATE SET owner=excluded.owner, expires_at=excluded.expires_at
            \\WHERE provider_leases.owner=excluded.owner OR provider_leases.expires_at<=?3;
        );
        defer statement.deinit();
        try statement.bindText(1, service);
        try statement.bindInt64(2, owner);
        try statement.bindInt64(3, now_ms);
        try statement.bindInt64(4, expires_at_ms);
        if (try statement.step() != .done) return error.SqlFailed;
        return self.db.changes() == 1;
    }

    pub fn releaseLease(self: *ProviderStateRepository, service: []const u8, owner: i64) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare("DELETE FROM provider_leases WHERE service=?1 AND owner=?2;");
        defer statement.deinit();
        try statement.bindText(1, service);
        try statement.bindInt64(2, owner);
        if (try statement.step() != .done) return error.SqlFailed;
    }
};
