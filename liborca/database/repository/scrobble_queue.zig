const std = @import("std");
const sqlite = @import("../sqlite.zig");

const WriteLane = @import("write_lane.zig").WriteLane;

pub const ScrobbleQueueEntry = struct {
    allocator: std.mem.Allocator,
    id: i64,
    service: []u8,
    event_key: []u8,
    payload: []u8,
    attempt_count: u32,

    pub fn deinit(self: ScrobbleQueueEntry) void {
        self.allocator.free(self.service);
        self.allocator.free(self.event_key);
        self.allocator.free(self.payload);
    }
};

pub const ScrobbleQueueRepository = struct {
    db: sqlite.Database,
    write_lane: *WriteLane,

    pub fn enqueue(
        self: *ScrobbleQueueRepository,
        service: []const u8,
        event_key: []const u8,
        payload: []const u8,
    ) !void {
        if (service.len == 0 or event_key.len == 0 or payload.len == 0)
            return error.InvalidScrobbleEvent;
        self.write_lane.acquire();
        defer self.write_lane.release();
        try enqueueScrobbleLocked(self.db, service, event_key, payload);
    }

    /// Claims up to `limit` events for `owner` until `lease_until`: pending
    /// events whose retry time has come, and events whose earlier lease has
    /// expired. One statement, so two owners never receive the same row.
    pub fn lease(
        self: *ScrobbleQueueRepository,
        allocator: std.mem.Allocator,
        service: []const u8,
        owner: i64,
        now: i64,
        lease_until: i64,
        limit: u32,
    ) ![]ScrobbleQueueEntry {
        if (lease_until <= now) return error.InvalidScrobbleLease;
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE scrobble_queue
            \\SET state=1, lease_owner=?3, lease_expires_at=?4, updated_at=unixepoch()
            \\WHERE id IN (
            \\    SELECT id FROM scrobble_queue
            \\    WHERE service=?1
            \\      AND ((state=0 AND next_attempt_at<=?2) OR (state=1 AND lease_expires_at<=?2))
            \\    ORDER BY id LIMIT ?5)
            \\RETURNING id, service, event_key, payload, attempt_count;
        );
        defer statement.deinit();
        try statement.bindText(1, service);
        try statement.bindInt64(2, now);
        try statement.bindInt64(3, owner);
        try statement.bindInt64(4, lease_until);
        try statement.bindInt64(5, limit);
        var entries: std.ArrayList(ScrobbleQueueEntry) = .empty;
        errdefer {
            for (entries.items) |entry| entry.deinit();
            entries.deinit(allocator);
        }
        while (try statement.step() == .row) {
            const owned_service = try allocator.dupe(u8, statement.columnText(1));
            errdefer allocator.free(owned_service);
            const event_key = try allocator.dupe(u8, statement.columnText(2));
            errdefer allocator.free(event_key);
            const payload = try allocator.dupe(u8, statement.columnBlob(3));
            errdefer allocator.free(payload);
            try entries.append(allocator, .{
                .allocator = allocator,
                .id = statement.columnInt64(0),
                .service = owned_service,
                .event_key = event_key,
                .payload = payload,
                .attempt_count = @intCast(statement.columnInt64(4)),
            });
        }
        std.mem.sort(ScrobbleQueueEntry, entries.items, {}, entryIdLessThan);
        return entries.toOwnedSlice(allocator);
    }

    fn entryIdLessThan(_: void, left: ScrobbleQueueEntry, right: ScrobbleQueueEntry) bool {
        return left.id < right.id;
    }

    pub fn markDelivered(self: *ScrobbleQueueRepository, id: i64, owner: i64) !void {
        try self.finishLease(id, owner, .delivered, 1, null, "");
    }

    pub fn markRetry(
        self: *ScrobbleQueueRepository,
        id: i64,
        owner: i64,
        next_attempt_at: i64,
        details: []const u8,
    ) !void {
        try self.finishLease(id, owner, .pending, 1, next_attempt_at, details);
    }

    pub fn markRejected(
        self: *ScrobbleQueueRepository,
        id: i64,
        owner: i64,
        details: []const u8,
    ) !void {
        try self.finishLease(id, owner, .rejected, 1, null, details);
    }

    /// Hands a claimed event back without counting an attempt, for work that
    /// was abandoned before anything was sent.
    pub fn release(self: *ScrobbleQueueRepository, id: i64, owner: i64) !void {
        try self.finishLease(id, owner, .pending, 0, null, null);
    }

    /// Events not yet delivered or rejected, whether waiting or leased.
    pub fn pendingCount(self: *const ScrobbleQueueRepository) !u64 {
        var statement = try self.db.prepare("SELECT count(*) FROM scrobble_queue WHERE state IN (0, 1);");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    pub fn deliveredCount(self: *const ScrobbleQueueRepository, service: []const u8) !u64 {
        var statement = try self.db.prepare(
            "SELECT count(*) FROM scrobble_queue WHERE service=?1 AND state=2;",
        );
        defer statement.deinit();
        try statement.bindText(1, service);
        if (try statement.step() != .row) return error.SqlFailed;
        return @intCast(statement.columnInt64(0));
    }

    /// When a worker should next look for work: the earliest retry time of a
    /// pending event or the earliest expiry of a lease, whichever comes first.
    pub fn nextAttemptAt(self: *const ScrobbleQueueRepository, service: []const u8) !?i64 {
        var statement = try self.db.prepare(
            \\SELECT min(due) FROM (
            \\    SELECT min(next_attempt_at) AS due FROM scrobble_queue WHERE service=?1 AND state=0
            \\    UNION ALL
            \\    SELECT min(lease_expires_at) FROM scrobble_queue WHERE service=?1 AND state=1);
        );
        defer statement.deinit();
        try statement.bindText(1, service);
        if (try statement.step() != .row) return error.SqlFailed;
        if (statement.columnIsNull(0)) return null;
        return statement.columnInt64(0);
    }

    const LeaseOutcome = enum(u8) { pending = 0, delivered = 2, rejected = 3 };

    fn finishLease(
        self: *ScrobbleQueueRepository,
        id: i64,
        owner: i64,
        outcome: LeaseOutcome,
        attempts: u8,
        next_attempt_at: ?i64,
        details: ?[]const u8,
    ) !void {
        self.write_lane.acquire();
        defer self.write_lane.release();
        var statement = try self.db.prepare(
            \\UPDATE scrobble_queue SET state=?1, attempt_count=attempt_count+?2,
            \\    next_attempt_at=COALESCE(?3, next_attempt_at), last_error=COALESCE(?4, last_error),
            \\    lease_owner=NULL, lease_expires_at=NULL, updated_at=unixepoch()
            \\WHERE id=?5 AND state=1 AND lease_owner=?6;
        );
        defer statement.deinit();
        try statement.bindInt64(1, @backingInt(outcome));
        try statement.bindInt64(2, attempts);
        try statement.bindOptionalInt64(3, next_attempt_at);
        try statement.bindOptionalText(4, details);
        try statement.bindInt64(5, id);
        try statement.bindInt64(6, owner);
        if (try statement.step() != .done) return error.SqlFailed;
        if (self.db.changes() != 1) return error.StaleScrobbleEvent;
    }
};

pub fn enqueueScrobbleLocked(
    db: sqlite.Database,
    service: []const u8,
    event_key: []const u8,
    payload: []const u8,
) !void {
    var statement = try db.prepare(
        \\INSERT INTO scrobble_queue(service, event_key, payload)
        \\VALUES (?1, ?2, ?3) ON CONFLICT(service, event_key) DO NOTHING;
    );
    defer statement.deinit();
    try statement.bindText(1, service);
    try statement.bindText(2, event_key);
    try statement.bindBlob(3, payload);
    if (try statement.step() != .done) return error.SqlFailed;
}
