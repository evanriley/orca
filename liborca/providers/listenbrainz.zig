const std = @import("std");
const network = @import("../network/root.zig");
const database = @import("../database/root.zig");
const credentials = @import("credentials.zig");
const scrobble = @import("scrobble.zig");

pub const service = "listenbrainz";

pub const token_service = "org.listenbrainz";
pub const token_account = "user-token";
pub const default_server = "https://api.listenbrainz.org";
const submit_path = "/1/submit-listens";
const validate_path = "/1/validate-token";
const feedback_path = "/1/feedback/recording-feedback";

const batch_limit: u32 = 100;
const lease_seconds: i64 = 120;
const maximum_listen_bytes = 10_240;
const initial_backoff_ms: u64 = 60_000;
const maximum_backoff_ms: u64 = 60 * 60 * 1000;

pub const State = enum {
    disabled,
    idle,
    needs_token,
    validating,
    invalid_token,
    submitting,
    backing_off,
    rate_limited,
    offline,
    busy,
};

pub const BoundedText = struct {
    bytes: [capacity]u8 = undefined,
    len: u8 = 0,

    pub const capacity = 128;

    pub fn slice(self: *const BoundedText) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn set(self: *BoundedText, text: []const u8) void {
        var length = @min(text.len, capacity);
        while (length > 0 and length < text.len and (text[length] & 0xC0) == 0x80) length -= 1;
        @memcpy(self.bytes[0..length], text[0..length]);
        self.len = @intCast(length);
    }

    pub fn clear(self: *BoundedText) void {
        self.len = 0;
    }
};

pub const Status = struct {
    state: State = .idle,
    user_name: BoundedText = .{},
    delivered_total: u64 = 0,
    last_error: BoundedText = .{},
    next_attempt_at: ?i64 = null,
};

pub const Outcome = enum {
    idle,
    blocked,
    delivered,
    rejected,
    isolating,
    deferred,
    canceled,
};

pub const StepResult = struct {
    outcome: Outcome,
    delivered: u32 = 0,
    rejected: u32 = 0,
    wake_after_ms: ?u64 = null,
};

pub const Delivery = struct {
    allocator: std.mem.Allocator,
    gateway: *network.Gateway,
    credentials: credentials.Store,
    queue: *database.ScrobbleQueueRepository,
    owner: i64,
    /// Borrowed; checked by `url.validateServer`.
    server: []const u8 = default_server,
    current: Status = .{},
    delivered_loaded: bool = false,
    token_rejected: bool = false,
    backoff_ms: u64 = 0,
    backoff_until_ms: i64 = 0,
    busy_until_ms: i64 = 0,
    isolating: u32 = 0,
    accepted_feedback: ?struct { recording_id: i64, feedback: database.Feedback } = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        gateway: *network.Gateway,
        store: credentials.Store,
        queue: *database.ScrobbleQueueRepository,
    ) Delivery {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        return .{
            .allocator = allocator,
            .gateway = gateway,
            .credentials = store,
            .queue = queue,
            .owner = std.mem.readInt(i64, &bytes, .little),
        };
    }

    pub fn status(self: *const Delivery) Status {
        return self.current;
    }

    /// True while another Orca process held ListenBrainz at the last attempt.
    pub fn waitingForLease(self: *const Delivery) bool {
        return self.gateway.clock.nowMs() < self.busy_until_ms;
    }

    fn endpoint(self: *const Delivery, path: []const u8) std.mem.Allocator.Error![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ std.mem.trimEnd(u8, self.server, "/"), path });
    }

    pub fn credentialsChanged(self: *Delivery) void {
        self.token_rejected = false;
        self.backoff_ms = 0;
        self.backoff_until_ms = 0;
        self.current.user_name.clear();
        self.current.last_error.clear();
        self.current.state = .idle;
        self.current.next_attempt_at = null;
    }

    pub fn validateToken(self: *Delivery, token: []const u8) !?[]u8 {
        const previous = self.current.state;
        self.current.state = .validating;
        errdefer self.current.state = previous;
        const authorization = try std.fmt.allocPrint(self.allocator, "Token {s}", .{token});
        defer credentials.wipeAndFree(self.allocator, authorization);
        const url = try self.endpoint(validate_path);
        defer self.allocator.free(url);
        const response = try self.gateway.execute(self.allocator, .get, url, null, &.{
            .{ .name = "authorization", .value = authorization },
        });
        defer response.deinit();
        if (response.status != 401 and (response.status < 200 or response.status >= 300))
            return error.UnexpectedProviderStatus;
        const Reply = struct { valid: bool = false, user_name: ?[]const u8 = null };
        var valid_name: ?[]const u8 = null;
        const parsed: ?std.json.Parsed(Reply) = if (response.status == 401) null else std.json.parseFromSlice(
            Reply,
            self.allocator,
            response.body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.InvalidProviderResponse;
        defer if (parsed) |value| value.deinit();
        if (parsed) |value| {
            if (value.value.valid) valid_name = value.value.user_name orelse return error.InvalidProviderResponse;
        }
        const user_name = valid_name orelse {
            self.token_rejected = true;
            self.current.user_name.clear();
            self.current.last_error.set("ListenBrainz does not accept the user token");
            self.current.state = .invalid_token;
            self.current.next_attempt_at = null;
            return null;
        };
        const owned = try self.allocator.dupe(u8, user_name);
        self.token_rejected = false;
        self.current.user_name.set(user_name);
        self.current.last_error.clear();
        self.current.state = .idle;
        return owned;
    }

    pub fn step(self: *Delivery, now_unix_s: i64) !StepResult {
        if (!self.delivered_loaded) {
            self.current.delivered_total = try self.queue.deliveredCount(service);
            self.delivered_loaded = true;
        }
        if (try self.blocked(now_unix_s)) |result| return result;
        const next = try self.queue.nextAttemptAt(service);
        if (next == null or next.? > now_unix_s) {
            self.isolating = 0;
            self.current.state = .idle;
            return self.idleResult(.idle, now_unix_s, 0, 0);
        }
        const token = (try self.credentials.get(self.allocator, token_service, token_account)) orelse
            return self.block(.needs_token, now_unix_s, null);
        defer credentials.wipeAndFree(self.allocator, token);
        return self.deliver(token, now_unix_s);
    }

    fn blocked(self: *Delivery, now_unix_s: i64) !?StepResult {
        if (self.token_rejected) return self.block(.invalid_token, now_unix_s, null);
        if (self.gateway.config.offline) return self.block(.offline, now_unix_s, null);
        try self.gateway.loadSharedState();
        const now_ms = self.gateway.clock.nowMs();
        if (now_ms < self.backoff_until_ms)
            return self.block(.backing_off, now_unix_s, millisecondsUntil(self.backoff_until_ms, now_ms));
        if (self.gateway.blockedUntilMs()) |until|
            return self.block(.rate_limited, now_unix_s, millisecondsUntil(until, now_ms));
        if (now_ms < self.busy_until_ms)
            return self.block(.busy, now_unix_s, millisecondsUntil(self.busy_until_ms, now_ms));
        return null;
    }

    fn block(self: *Delivery, state: State, now_unix_s: i64, wake_after_ms: ?u64) StepResult {
        self.current.state = state;
        self.current.next_attempt_at = if (wake_after_ms) |ms| now_unix_s +| secondsCeil(ms) else null;
        return .{ .outcome = .blocked, .wake_after_ms = wake_after_ms };
    }

    fn deliver(self: *Delivery, token: []const u8, now_unix_s: i64) !StepResult {
        const limit: u32 = if (self.isolating > 0) 1 else batch_limit;
        const entries = try self.queue.lease(
            self.allocator,
            service,
            self.owner,
            now_unix_s,
            now_unix_s + lease_seconds,
            limit,
        );
        defer {
            for (entries) |entry| entry.deinit();
            self.allocator.free(entries);
        }
        if (entries.len == 0) {
            self.isolating = 0;
            self.current.state = .idle;
            return self.idleResult(.idle, now_unix_s, 0, 0);
        }
        var batch = try Batch.init(self, entries);
        defer batch.deinit();
        errdefer batch.releaseUnresolved() catch |err|
            std.log.warn("failed to release scrobble leases: {s}", .{@errorName(err)});

        var listens = std.Io.Writer.Allocating.init(self.allocator);
        defer listens.deinit();
        var included: std.ArrayList(usize) = .empty;
        defer included.deinit(self.allocator);
        var rejected: u32 = 0;
        for (entries, 0..) |entry, index| {
            const parsed = std.json.parseFromSlice(
                scrobble.Event,
                self.allocator,
                entry.payload,
                .{ .ignore_unknown_fields = true },
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    try batch.reject(index, "unreadable scrobble payload");
                    rejected += 1;
                    continue;
                },
            };
            defer parsed.deinit();
            appendListen(&listens, included.items.len == 0, parsed.value, self.gateway.config.identity, .listen) catch |err| switch (err) {
                error.ListenTooLarge => {
                    try batch.reject(index, "listen exceeds the 10240 byte limit");
                    rejected += 1;
                    continue;
                },
                error.OutOfMemory => return err,
            };
            try included.append(self.allocator, index);
        }
        if (included.items.len == 0) {
            self.isolating -|= @intCast(entries.len);
            self.current.state = .idle;
            return self.idleResult(.rejected, now_unix_s, 0, rejected);
        }

        var body = std.Io.Writer.Allocating.init(self.allocator);
        defer body.deinit();
        try body.writer.print("{{\"listen_type\":\"{s}\",\"payload\":[", .{
            if (included.items.len == 1) "single" else "import",
        });
        try body.writer.writeAll(listens.written());
        try body.writer.writeAll("]}");
        const authorization = try std.fmt.allocPrint(self.allocator, "Token {s}", .{token});
        defer credentials.wipeAndFree(self.allocator, authorization);
        const url = try self.endpoint(submit_path);
        defer self.allocator.free(url);

        self.current.state = .submitting;
        const response = self.gateway.execute(
            self.allocator,
            .post,
            url,
            body.written(),
            &.{
                .{ .name = "authorization", .value = authorization },
                .{ .name = "content-type", .value = "application/json" },
            },
        ) catch |err| return self.failed(err, &batch, now_unix_s, rejected);
        defer response.deinit();

        if (response.status >= 200 and response.status < 300) {
            var count: u32 = 0;
            for (included.items) |index| {
                if (try batch.deliver(index)) count += 1;
            }
            self.current.delivered_total += count;
            self.requestSucceeded();
            self.isolating -|= @intCast(entries.len);
            return self.idleResult(.delivered, now_unix_s, count, rejected);
        }
        if (network.client.isPermanentRejection(response.status)) {
            if (included.items.len > 1) {
                try batch.releaseUnresolved();
                self.isolating = @intCast(included.items.len);
                self.current.state = .idle;
                self.current.last_error.set("ListenBrainz rejected a batch; sending its listens one at a time");
                self.current.next_attempt_at = now_unix_s;
                return .{ .outcome = .isolating, .rejected = rejected, .wake_after_ms = 0 };
            }
            const details = try rejectionDetails(self.allocator, response);
            defer self.allocator.free(details);
            try batch.reject(included.items[0], details);
            self.current.last_error.set(details);
            self.isolating -|= @intCast(entries.len);
            self.current.state = .idle;
            return self.idleResult(.rejected, now_unix_s, 0, rejected + 1);
        }
        const result = try self.responseFailed(response.status, now_unix_s, rejected);
        try batch.requeueUnresolved(self.retryAt(), self.current.last_error.slice());
        return result;
    }

    fn requestSucceeded(self: *Delivery) void {
        self.backoff_ms = 0;
        self.backoff_until_ms = 0;
        self.current.state = .idle;
        self.current.last_error.clear();
    }

    fn responseFailed(self: *Delivery, http_status: u16, now_unix_s: i64, rejected: u32) !StepResult {
        if (http_status == 401 or http_status == 403) {
            self.token_rejected = true;
            self.current.state = .invalid_token;
            self.current.last_error.set("ListenBrainz does not accept the user token");
            self.current.next_attempt_at = null;
            return .{ .outcome = .deferred, .rejected = rejected };
        }
        var message: [32]u8 = undefined;
        return self.startBackoff(now_unix_s, std.fmt.bufPrint(&message, "HTTP {d}", .{http_status}) catch "HTTP error", rejected);
    }

    pub fn syncFeedback(
        self: *Delivery,
        feedback: *database.FeedbackRepository,
        now_unix_s: i64,
    ) !StepResult {
        if (try self.blocked(now_unix_s)) |result| return result;
        const change = (try feedback.nextToSync(self.allocator, now_unix_s)) orelse {
            if (try feedback.pendingSyncCount() == 0) return .{ .outcome = .idle };
            return .{ .outcome = .idle, .wake_after_ms = @intCast(database.repository.feedback_settle_seconds * 1000) };
        };
        defer change.deinit();
        if (self.accepted_feedback) |accepted| {
            if (accepted.recording_id == change.recording_id and accepted.feedback == change.feedback) {
                try feedback.markSynced(change.recording_id, change.feedback);
                self.accepted_feedback = null;
                return .{ .outcome = .delivered };
            }
        }
        const token = (try self.credentials.get(self.allocator, token_service, token_account)) orelse
            return self.block(.needs_token, now_unix_s, null);
        defer credentials.wipeAndFree(self.allocator, token);

        var body = std.Io.Writer.Allocating.init(self.allocator);
        defer body.deinit();
        var json: std.json.Stringify = .{ .writer = &body.writer };
        try json.beginObject();
        try json.objectField("recording_mbid");
        try json.write(change.recording_mbid);
        try json.objectField("score");
        try json.write(change.feedback.score());
        try json.endObject();

        const response = self.post(feedback_path, token, body.written()) catch |err|
            return self.requestFailed(err, now_unix_s, 0);
        defer response.deinit();
        if (response.status >= 200 and response.status < 300) {
            self.accepted_feedback = .{ .recording_id = change.recording_id, .feedback = change.feedback };
            try feedback.markSynced(change.recording_id, change.feedback);
            self.accepted_feedback = null;
            self.requestSucceeded();
            return .{ .outcome = .delivered, .delivered = 1 };
        }
        if (network.client.isPermanentRejection(response.status)) {
            const details = try rejectionDetails(self.allocator, response);
            defer self.allocator.free(details);
            try feedback.markRejected(change.recording_id, change.feedback, details);
            self.current.last_error.set(details);
            self.current.state = .idle;
            return .{ .outcome = .rejected, .rejected = 1 };
        }
        return self.responseFailed(response.status, now_unix_s, 0);
    }

    pub fn sendNowPlaying(self: *Delivery, event: scrobble.Event, now_unix_s: i64) !StepResult {
        if (try self.blocked(now_unix_s)) |result| return result;
        const token = (try self.credentials.get(self.allocator, token_service, token_account)) orelse
            return .{ .outcome = .blocked };
        defer credentials.wipeAndFree(self.allocator, token);

        var listens = std.Io.Writer.Allocating.init(self.allocator);
        defer listens.deinit();
        appendListen(&listens, true, event, self.gateway.config.identity, .playing_now) catch |err| switch (err) {
            error.ListenTooLarge => return .{ .outcome = .rejected },
            error.OutOfMemory => return err,
        };
        var body = std.Io.Writer.Allocating.init(self.allocator);
        defer body.deinit();
        try body.writer.writeAll("{\"listen_type\":\"playing_now\",\"payload\":[");
        try body.writer.writeAll(listens.written());
        try body.writer.writeAll("]}");

        const response = self.post(submit_path, token, body.written()) catch |err|
            return self.requestFailed(err, now_unix_s, 0);
        defer response.deinit();
        if (response.status >= 200 and response.status < 300) {
            self.requestSucceeded();
            return .{ .outcome = .delivered, .delivered = 1 };
        }
        if (network.client.isPermanentRejection(response.status)) {
            self.current.state = .idle;
            return .{ .outcome = .rejected, .rejected = 1 };
        }
        return self.responseFailed(response.status, now_unix_s, 0);
    }

    fn post(self: *Delivery, path: []const u8, token: []const u8, body: []const u8) !network.client.Response {
        const authorization = try std.fmt.allocPrint(self.allocator, "Token {s}", .{token});
        defer credentials.wipeAndFree(self.allocator, authorization);
        const url = try self.endpoint(path);
        defer self.allocator.free(url);
        self.current.state = .submitting;
        return self.gateway.execute(self.allocator, .post, url, body, &.{
            .{ .name = "authorization", .value = authorization },
            .{ .name = "content-type", .value = "application/json" },
        });
    }

    fn failed(
        self: *Delivery,
        err: anyerror,
        batch: *Batch,
        now_unix_s: i64,
        rejected: u32,
    ) !StepResult {
        const result = try self.requestFailed(err, now_unix_s, rejected);
        try batch.requeueUnresolved(self.retryAt(), self.current.last_error.slice());
        return result;
    }

    /// When the listens of a request that just failed may go out again: the
    /// end of the backoff or block it started, or null when it started none
    /// and they return to the queue as they were.
    fn retryAt(self: *const Delivery) ?i64 {
        return switch (self.current.state) {
            .backing_off, .rate_limited => self.current.next_attempt_at,
            else => null,
        };
    }

    fn waitForLease(self: *Delivery, now_unix_s: i64) StepResult {
        self.busy_until_ms = self.gateway.clock.nowMs() +| network.client.lease_duration_ms;
        self.current.last_error.set("ListenBrainz is in use by another Orca process");
        return self.block(.busy, now_unix_s, @intCast(network.client.lease_duration_ms));
    }

    fn requestFailed(self: *Delivery, err: anyerror, now_unix_s: i64, rejected: u32) !StepResult {
        switch (err) {
            error.Canceled => {
                self.current.state = .idle;
                return .{ .outcome = .canceled, .rejected = rejected };
            },
            error.Offline => {
                var result = self.block(.offline, now_unix_s, null);
                result.outcome = .deferred;
                result.rejected = rejected;
                return result;
            },
            error.ProviderBusy => {
                var result = self.waitForLease(now_unix_s);
                result.outcome = .deferred;
                result.rejected = rejected;
                return result;
            },
            error.RateLimited => {
                const now_ms = self.gateway.clock.nowMs();
                const wake = if (self.gateway.blockedUntilMs()) |until|
                    millisecondsUntil(until, now_ms)
                else
                    1000;
                self.current.last_error.set("ListenBrainz rate limit reached");
                var result = self.block(.rate_limited, now_unix_s, wake);
                result.outcome = .deferred;
                result.rejected = rejected;
                return result;
            },
            error.OutOfMemory => return err,
            else => return try self.startBackoff(now_unix_s, failureMessage(err), rejected),
        }
    }

    /// Records why `validateToken` failed. Failures that say the service is
    /// unreachable or unwell join the service's backoff, so a failing
    /// validation delays submissions as a failing submission does.
    pub fn validationFailed(self: *Delivery, err: anyerror, now_unix_s: i64) !void {
        switch (err) {
            error.OutOfMemory, error.Canceled, error.Offline, error.RateLimited => self.current.last_error.set(@errorName(err)),
            error.ProviderBusy => _ = self.waitForLease(now_unix_s),
            else => _ = try self.startBackoff(now_unix_s, failureMessage(err), 0),
        }
    }

    fn failureMessage(err: anyerror) []const u8 {
        return switch (err) {
            error.Timeout => "request timed out",
            error.ResponseTooLarge => "response too large",
            error.NetworkUnavailable => "network unavailable",
            else => @errorName(err),
        };
    }

    fn startBackoff(self: *Delivery, now_unix_s: i64, message: []const u8, rejected: u32) !StepResult {
        self.backoff_ms = if (self.backoff_ms == 0)
            initial_backoff_ms
        else
            @min(self.backoff_ms *| 2, maximum_backoff_ms);
        const wait_ms = network.client.jittered(self.gateway.random, self.backoff_ms);
        self.backoff_until_ms = self.gateway.clock.nowMs() +| @as(i64, @intCast(wait_ms));
        try self.gateway.blockFor(wait_ms);
        self.current.last_error.set(message);
        var result = self.block(.backing_off, now_unix_s, wait_ms);
        result.outcome = .deferred;
        result.rejected = rejected;
        return result;
    }

    fn idleResult(self: *Delivery, outcome: Outcome, now_unix_s: i64, delivered: u32, rejected: u32) !StepResult {
        const next = try self.queue.nextAttemptAt(service);
        const wake: ?u64 = if (next) |at| (if (at <= now_unix_s) 0 else @as(u64, @intCast(at - now_unix_s)) *| 1000) else null;
        self.current.next_attempt_at = if (next) |at| @max(at, now_unix_s) else null;
        return .{ .outcome = outcome, .delivered = delivered, .rejected = rejected, .wake_after_ms = wake };
    }
};

const Batch = struct {
    delivery: *Delivery,
    entries: []const database.ScrobbleQueueEntry,
    resolved: []bool,

    fn init(delivery: *Delivery, entries: []const database.ScrobbleQueueEntry) !Batch {
        const resolved = try delivery.allocator.alloc(bool, entries.len);
        @memset(resolved, false);
        return .{ .delivery = delivery, .entries = entries, .resolved = resolved };
    }

    fn deinit(self: *Batch) void {
        self.delivery.allocator.free(self.resolved);
    }

    fn deliver(self: *Batch, index: usize) !bool {
        self.delivery.queue.markDelivered(self.entries[index].id, self.delivery.owner) catch |err| switch (err) {
            error.StaleScrobbleEvent => {
                std.log.warn("scrobble {d} was delivered but its lease was lost", .{self.entries[index].id});
                self.resolved[index] = true;
                return false;
            },
            else => return err,
        };
        self.resolved[index] = true;
        return true;
    }

    fn reject(self: *Batch, index: usize, details: []const u8) !void {
        try self.delivery.queue.markRejected(self.entries[index].id, self.delivery.owner, details);
        self.resolved[index] = true;
    }

    fn releaseUnresolved(self: *Batch) !void {
        try self.requeueUnresolved(null, "");
    }

    /// Hands back the listens not yet delivered or rejected: due again at
    /// `retry_at` (Unix seconds) after a failed attempt, or at once and
    /// without counting an attempt.
    fn requeueUnresolved(self: *Batch, retry_at: ?i64, details: []const u8) !void {
        for (self.entries, self.resolved) |entry, *resolved| {
            if (resolved.*) continue;
            if (retry_at) |at|
                try self.delivery.queue.markRetry(entry.id, self.delivery.owner, at, details)
            else
                try self.delivery.queue.release(entry.id, self.delivery.owner);
            resolved.* = true;
        }
    }
};

fn millisecondsUntil(deadline_ms: i64, now_ms: i64) u64 {
    return @intCast(@max(deadline_ms - now_ms, 0));
}

fn secondsCeil(milliseconds: u64) i64 {
    return @intCast(std.math.divCeil(u64, milliseconds, 1000) catch unreachable);
}

fn rejectionDetails(allocator: std.mem.Allocator, response: network.client.Response) ![]u8 {
    var fallback_buffer: [16]u8 = undefined;
    const fallback = std.fmt.bufPrint(&fallback_buffer, "HTTP {d}", .{response.status}) catch unreachable;
    const Reply = struct { @"error": ?[]const u8 = null, message: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(
        Reply,
        allocator,
        response.body,
        .{ .ignore_unknown_fields = true },
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return allocator.dupe(u8, fallback),
    };
    defer parsed.deinit();
    const message = parsed.value.@"error" orelse parsed.value.message orelse return allocator.dupe(u8, fallback);
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ fallback, message });
}

const ListenType = enum { listen, playing_now };

fn appendListen(
    listens: *std.Io.Writer.Allocating,
    first: bool,
    event: scrobble.Event,
    identity: network.client.Identity,
    listen_type: ListenType,
) error{ ListenTooLarge, OutOfMemory }!void {
    const mark = listens.written().len;
    for ([_]bool{ true, false }) |full| {
        if (!first) listens.writer.writeByte(',') catch return error.OutOfMemory;
        const start = listens.written().len;
        writeListen(&listens.writer, event, identity, full, listen_type) catch return error.OutOfMemory;
        if (listens.written().len - start <= maximum_listen_bytes) return;
        listens.shrinkRetainingCapacity(mark);
    }
    return error.ListenTooLarge;
}

fn writeListen(
    writer: *std.Io.Writer,
    event: scrobble.Event,
    identity: network.client.Identity,
    full: bool,
    listen_type: ListenType,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    if (listen_type == .listen) {
        try json.objectField("listened_at");
        try json.write(event.started_at);
    }
    try json.objectField("track_metadata");
    try json.beginObject();
    try json.objectField("artist_name");
    try json.write(event.artist);
    try json.objectField("track_name");
    try json.write(event.title);
    if (event.album.len > 0) {
        try json.objectField("release_name");
        try json.write(event.album);
    }
    try json.objectField("additional_info");
    try json.beginObject();
    try json.objectField("submission_client");
    try json.write(identity.name);
    try json.objectField("submission_client_version");
    try json.write(identity.version);
    if (full) {
        if (event.duration_ms > 0) {
            try json.objectField("duration_ms");
            try json.write(event.duration_ms);
        }
        if (present(event.recording_mbid)) |value| {
            try json.objectField("recording_mbid");
            try json.write(value);
        }
        if (present(event.release_mbid)) |value| {
            try json.objectField("release_mbid");
            try json.write(value);
        }
        if (present(event.artist_mbid)) |value| {
            try json.objectField("artist_mbids");
            try json.beginArray();
            try json.write(value);
            try json.endArray();
        }
        if (event.track_number) |value| {
            try json.objectField("tracknumber");
            try json.write(value);
        }
    }
    try json.endObject();
    try json.endObject();
    try json.endObject();
}

fn present(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len == 0) null else text;
}

const shared_state = @import("shared_state.zig");

const Fixture = struct {
    library: database.LibraryDatabase,
    transport: network.testing.ScriptedTransport,
    clock: network.testing.TestClock,
    prng: std.Random.DefaultPrng,
    gateway: network.Gateway,
    reject_body_containing: ?[]const u8,
    release_before_reply: ?struct { queue: *database.ScrobbleQueueRepository, id: i64, owner: i64 },
    during_request: ?struct { context: *anyopaque, run: *const fn (*anyopaque) anyerror!void },
    token: ?[]const u8 = "secret-token",
    token_lookups: usize = 0,
    delivery: Delivery,

    const unix_now: i64 = 2_000_000_000;

    fn start(self: *Fixture, name: [:0]const u8, identity: network.client.Identity) !void {
        self.library = try database.LibraryDatabase.open(std.testing.allocator, std.testing.io, name);
        self.clock = .{};
        self.transport = .{
            .clock = &self.clock,
            .keep_history = true,
            .responder = .{ .context = self, .respond_fn = respond },
        };
        self.prng = .init(network.testing.default_seed);
        self.reject_body_containing = null;
        self.release_before_reply = null;
        self.during_request = null;
        self.token = "secret-token";
        self.token_lookups = 0;
        self.gateway = network.testing.gateway(&self.transport, &self.clock, &self.prng, .{ .identity = identity });
        self.delivery = Delivery.init(
            std.testing.allocator,
            std.testing.io,
            &self.gateway,
            .{ .context = self, .get_fn = getToken },
            &self.library.scrobbles,
        );
    }

    fn stop(self: *Fixture) void {
        self.transport.deinit();
        self.library.close();
    }

    fn respond(context: *anyopaque, exchange: network.testing.Exchange, scripted: ?network.testing.Reply) anyerror!network.testing.Reply {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (self.release_before_reply) |steal| try steal.queue.release(steal.id, steal.owner);
        if (self.during_request) |hook| {
            self.during_request = null;
            try hook.run(hook.context);
        }
        if (scripted) |next| return next;
        if (self.reject_body_containing) |marker| if (std.mem.indexOf(u8, exchange.form, marker) != null)
            return .{ .respond = .{ .status = 400, .body = "{\"code\":400,\"error\":\"Invalid listen\"}" } };
        return .{ .respond = .{} };
    }

    fn getToken(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) !?[]u8 {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.token_lookups += 1;
        return if (self.token) |value| try allocator.dupe(u8, value) else null;
    }

    fn reply(self: *Fixture, value: network.testing.Reply) !void {
        try self.transport.script(value);
    }

    fn step(self: *Fixture) !StepResult {
        return self.delivery.step(self.unixNow());
    }

    fn unixNow(self: *const Fixture) i64 {
        return unix_now + @divFloor(self.clock.now(), 1000);
    }

    fn enqueueListens(self: *Fixture, count: usize) !void {
        for (0..count) |index| try self.enqueueTitled(index, "Track");
    }

    fn enqueueTitled(self: *Fixture, index: usize, title: []const u8) !void {
        var key: [32]u8 = undefined;
        _ = try scrobble.enqueueEligible(
            std.testing.allocator,
            &self.library.scrobbles,
            service,
            try std.fmt.bufPrint(&key, "listen:{d}", .{index + 1}),
            .{
                .title = title,
                .artist = "Test Artist",
                .started_at = 1_700_000_000 + @as(i64, @intCast(index)),
                .duration_ms = 180_000,
                .listened_ms = 100_000,
            },
        );
    }

    fn advance(self: *Fixture, milliseconds: u64) void {
        self.clock.advance(@intCast(milliseconds));
    }

    /// Advances past a wait, to the whole second queue retry times are kept in.
    fn waitOut(self: *Fixture, milliseconds: u64) void {
        self.advance(@as(u64, @intCast(secondsCeil(milliseconds))) * 1000);
    }

    fn expectWakeAround(result: StepResult, milliseconds: u64) !void {
        const wake = result.wake_after_ms.?;
        try std.testing.expect(wake >= milliseconds / 2 and wake <= milliseconds + milliseconds / 2);
    }

    const Queued = struct { attempts: i64, next_attempt_at: i64 };

    /// The first listen waiting in the queue.
    fn queued(self: *Fixture) !Queued {
        var statement = try self.library.database.prepare(
            "SELECT attempt_count, next_attempt_at FROM scrobble_queue WHERE state = 0 ORDER BY id LIMIT 1;",
        );
        defer statement.deinit();
        if (try statement.step() != .row) return error.NothingQueued;
        return .{ .attempts = statement.columnInt64(0), .next_attempt_at = statement.columnInt64(1) };
    }

    /// A Track of a new recording whose file carries `mbid`.
    fn track(self: *Fixture, mbid: ?[]const u8) !i64 {
        const library = &self.library;
        try library.database.exec("INSERT INTO recordings(title) VALUES ('Song');");
        var statement = try library.database.prepare("SELECT max(id) FROM recordings;");
        defer statement.deinit();
        if (try statement.step() != .row) return error.SqlFailed;
        const recording_id = statement.columnInt64(0);
        const file_id = try library.files.create(.{ .audio_format = 1, .size_bytes = 4096 });
        var assign = try library.database.prepare("UPDATE files SET recording_id = ?1 WHERE id = ?2;");
        defer assign.deinit();
        try assign.bindInt64(1, recording_id);
        try assign.bindInt64(2, file_id);
        if (try assign.step() != .done) return error.SqlFailed;
        try library.observed_tags.upsert(.{ .file_id = file_id, .values = .{
            .title = "Song",
            .musicbrainz_recording_id = mbid,
        } });
        try library.tracks.upsertTracks(&.{.{
            .recording_id = recording_id,
            .title = "Song",
            .artist = "Test Artist",
            .preferred_file_id = file_id,
        }});
        var find = try library.database.prepare("SELECT id FROM tracks WHERE preferred_file_id = ?1;");
        defer find.deinit();
        try find.bindInt64(1, file_id);
        if (try find.step() != .row) return error.SqlFailed;
        return find.columnInt64(0);
    }

    fn setFeedback(self: *Fixture, track_id: i64, value: database.Feedback) !void {
        _ = try self.library.feedback.set(&.{track_id}, value);
    }

    fn syncFeedback(self: *Fixture) !StepResult {
        return self.delivery.syncFeedback(&self.library.feedback, unix_now);
    }

    fn lastScore(self: *const Fixture) !i64 {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            self.transport.history.items[self.transport.history.items.len - 1].body,
            .{},
        );
        defer parsed.deinit();
        return parsed.value.object.get("score").?.integer;
    }

    fn attemptsOfNextLease(self: *Fixture) !u32 {
        const now = self.unixNow();
        const entries = try self.library.scrobbles.lease(std.testing.allocator, service, 42, now, now + 10, 1);
        defer {
            for (entries) |entry| entry.deinit();
            std.testing.allocator.free(entries);
        }
        try std.testing.expectEqual(@as(usize, 1), entries.len);
        const attempts = entries[0].attempt_count;
        try self.library.scrobbles.release(entries[0].id, 42);
        return attempts;
    }
};

fn countOf(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

test "a backlog of 250 listens goes out as three import requests of at most 100" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-backlog?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.enqueueListens(250);
    const expected = [_]usize{ 100, 100, 50 };
    for (expected) |count| {
        const result = try fixture.step();
        try std.testing.expectEqual(Outcome.delivered, result.outcome);
        try std.testing.expectEqual(@as(u32, @intCast(count)), result.delivered);
    }
    try std.testing.expectEqual(@as(usize, 3), fixture.transport.requestCount());
    for (fixture.transport.history.items, expected) |request, count| {
        try std.testing.expect(std.mem.indexOf(u8, request.body, "\"listen_type\":\"import\"") != null);
        try std.testing.expectEqual(count, countOf(request.body, "\"listened_at\""));
    }
    try std.testing.expectEqual(@as(u64, 250), try fixture.library.scrobbles.deliveredCount(service));
    const idle = try fixture.step();
    try std.testing.expectEqual(Outcome.idle, idle.outcome);
    try std.testing.expectEqual(@as(?u64, null), idle.wake_after_ms);
    try std.testing.expectEqual(@as(u64, 250), fixture.delivery.status().delivered_total);
}

test "one ready listen is sent as single with its identifiers and the host's client name" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-single?mode=memory&cache=shared", .{
        .name = "Player",
        .version = "1.2.3",
        .contact = "https://player.example",
    });
    defer fixture.stop();
    _ = try scrobble.enqueueEligible(std.testing.allocator, &fixture.library.scrobbles, service, "listen:1", .{
        .title = "Orca",
        .artist = "Test Artist",
        .album = "Ocean",
        .started_at = 1_700_000_000,
        .duration_ms = 180_000,
        .listened_ms = 100_000,
        .recording_mbid = "rec-mbid",
        .release_mbid = "rel-mbid",
        .artist_mbid = "art-mbid",
        .track_number = 4,
    });
    try std.testing.expectEqual(Outcome.delivered, (try fixture.step()).outcome);
    try std.testing.expectEqualStrings("https://api.listenbrainz.org/1/submit-listens", fixture.transport.history.items[0].url);
    try std.testing.expectEqualStrings("Token secret-token", fixture.transport.lastAuthorization());
    const body = fixture.transport.history.items[0].body;
    try std.testing.expect(std.mem.indexOf(u8, body, "listened_ms") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "media_player") == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("single", root.get("listen_type").?.string);
    const listens = root.get("payload").?.array;
    try std.testing.expectEqual(@as(usize, 1), listens.items.len);
    const listen = listens.items[0].object;
    try std.testing.expectEqual(@as(i64, 1_700_000_000), listen.get("listened_at").?.integer);
    const metadata = listen.get("track_metadata").?.object;
    try std.testing.expectEqualStrings("Test Artist", metadata.get("artist_name").?.string);
    try std.testing.expectEqualStrings("Orca", metadata.get("track_name").?.string);
    try std.testing.expectEqualStrings("Ocean", metadata.get("release_name").?.string);
    const info = metadata.get("additional_info").?.object;
    try std.testing.expectEqualStrings("Player", info.get("submission_client").?.string);
    try std.testing.expectEqualStrings("1.2.3", info.get("submission_client_version").?.string);
    try std.testing.expectEqual(@as(i64, 180_000), info.get("duration_ms").?.integer);
    try std.testing.expectEqualStrings("rec-mbid", info.get("recording_mbid").?.string);
    try std.testing.expectEqualStrings("rel-mbid", info.get("release_mbid").?.string);
    try std.testing.expectEqualStrings("art-mbid", info.get("artist_mbids").?.array.items[0].string);
    try std.testing.expectEqual(@as(i64, 4), info.get("tracknumber").?.integer);
}

test "a listen without identifiers or album omits those fields" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-bare?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.enqueueListens(1);
    _ = try fixture.step();
    const body = fixture.transport.history.items[0].body;
    for ([_][]const u8{ "release_name", "recording_mbid", "release_mbid", "artist_mbids", "tracknumber", "null" }) |absent|
        try std.testing.expect(std.mem.indexOf(u8, body, absent) == null);
}

test "a listen over the size limit drops its optional fields and one still too large is rejected unsent" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-oversize?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    const allocator = std.testing.allocator;
    const long_title = try allocator.alloc(u8, 10_000);
    defer allocator.free(long_title);
    @memset(long_title, 'a');
    _ = try scrobble.enqueueEligible(allocator, &fixture.library.scrobbles, service, "listen:1", .{
        .title = long_title,
        .artist = "Test Artist",
        .started_at = 1_700_000_000,
        .duration_ms = 180_000,
        .listened_ms = 100_000,
        .recording_mbid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        .release_mbid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        .artist_mbid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        .track_number = 12,
    });
    try std.testing.expectEqual(Outcome.delivered, (try fixture.step()).outcome);
    const body = fixture.transport.history.items[0].body;
    try std.testing.expect(std.mem.indexOf(u8, body, "recording_mbid") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "submission_client") != null);

    const huge_title = try allocator.alloc(u8, 11_000);
    defer allocator.free(huge_title);
    @memset(huge_title, 'b');
    try fixture.enqueueTitled(1, huge_title);
    const result = try fixture.step();
    try std.testing.expectEqual(Outcome.rejected, result.outcome);
    try std.testing.expectEqual(@as(u32, 1), result.rejected);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());
    try std.testing.expectEqual(@as(u64, 0), try fixture.library.scrobbles.pendingCount());
}

test "a legacy empty payload is rejected without a request" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-legacy?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.library.scrobbles.enqueue(service, "listen:1", "{}");
    const result = try fixture.step();
    try std.testing.expectEqual(Outcome.rejected, result.outcome);
    try std.testing.expectEqual(@as(u32, 1), result.rejected);
    try std.testing.expectEqual(@as(?u64, null), result.wake_after_ms);
    try std.testing.expectEqual(@as(usize, 0), fixture.transport.requestCount());
    try std.testing.expectEqual(@as(u64, 0), try fixture.library.scrobbles.pendingCount());
    try std.testing.expectEqual(@as(u64, 0), try fixture.library.scrobbles.deliveredCount(service));
}

test "a legacy payload beside a good listen is dropped and the good listen is sent" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-mixed?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.library.scrobbles.enqueue(service, "listen:1", "{}");
    try fixture.enqueueTitled(1, "Track");
    const result = try fixture.step();
    try std.testing.expectEqual(Outcome.delivered, result.outcome);
    try std.testing.expectEqual(@as(u32, 1), result.delivered);
    try std.testing.expectEqual(@as(u32, 1), result.rejected);
    try std.testing.expect(std.mem.indexOf(u8, fixture.transport.history.items[0].body, "\"listen_type\":\"single\"") != null);
}

test "no request is made without a token and delivery resumes once one exists" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-token?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.enqueueListens(2);
    fixture.token = null;
    const result = try fixture.step();
    try std.testing.expectEqual(Outcome.blocked, result.outcome);
    try std.testing.expectEqual(@as(?u64, null), result.wake_after_ms);
    try std.testing.expectEqual(State.needs_token, fixture.delivery.status().state);
    try std.testing.expectEqual(@as(usize, 0), fixture.transport.requestCount());
    try std.testing.expectEqual(@as(u64, 2), try fixture.library.scrobbles.pendingCount());
    fixture.token = "secret-token";
    try std.testing.expectEqual(Outcome.delivered, (try fixture.step()).outcome);
}

test "no request is made while offline" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-offline?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.enqueueListens(2);
    fixture.gateway.config.offline = true;
    for (0..3) |_| {
        const result = try fixture.step();
        try std.testing.expectEqual(Outcome.blocked, result.outcome);
        try std.testing.expectEqual(State.offline, fixture.delivery.status().state);
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.transport.requestCount());
    try std.testing.expectEqual(@as(u64, 2), try fixture.library.scrobbles.pendingCount());
}

test "a 429 schedules the rows for when the block ends and waits until the gateway unblocks" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-limited?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.enqueueListens(3);
    try fixture.reply(.{ .respond = .{ .status = 429 } });
    const limited = try fixture.step();
    try std.testing.expectEqual(Outcome.deferred, limited.outcome);
    try Fixture.expectWakeAround(limited, 60_000);
    try std.testing.expectEqual(State.rate_limited, fixture.delivery.status().state);
    const wake = limited.wake_after_ms.?;
    try std.testing.expectEqual(Fixture.Queued{
        .attempts = 1,
        .next_attempt_at = Fixture.unix_now + secondsCeil(wake),
    }, try fixture.queued());

    fixture.advance(20_000);
    const waiting = try fixture.step();
    try std.testing.expectEqual(Outcome.blocked, waiting.outcome);
    try std.testing.expectEqual(@as(?u64, wake - 20_000), waiting.wake_after_ms);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());

    fixture.waitOut(wake - 20_000);
    const resumed = try fixture.step();
    try std.testing.expectEqual(Outcome.delivered, resumed.outcome);
    try std.testing.expectEqual(@as(u32, 3), resumed.delivered);
    try std.testing.expectEqual(@as(usize, 2), fixture.transport.requestCount());
}

test "consecutive server errors double the service backoff to an hour and a success resets it" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-doubling?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.enqueueListens(2);
    const expected_ms = [_]u64{ 60_000, 120_000, 240_000, 480_000, 960_000, 1_920_000, 3_600_000, 3_600_000 };
    for (expected_ms) |_| try fixture.reply(.{ .respond = .{ .status = 503 } });
    for (expected_ms) |backoff| {
        const result = try fixture.step();
        try std.testing.expectEqual(Outcome.deferred, result.outcome);
        try std.testing.expectEqual(backoff, fixture.delivery.backoff_ms);
        try Fixture.expectWakeAround(result, backoff);
        try std.testing.expectEqual(State.backing_off, fixture.delivery.status().state);
        fixture.waitOut(result.wake_after_ms.?);
    }
    try std.testing.expectEqual(@as(usize, expected_ms.len), fixture.transport.requestCount());
    try std.testing.expectEqual(@as(i64, expected_ms.len), (try fixture.queued()).attempts);
    try std.testing.expectEqual(Outcome.delivered, (try fixture.step()).outcome);

    try fixture.enqueueTitled(5, "Later");
    try fixture.reply(.{ .respond = .{ .status = 500 } });
    _ = try fixture.step();
    try std.testing.expectEqual(@as(u64, 60_000), fixture.delivery.backoff_ms);
}

test "a network outage with 50 queued listens produces one request per backoff period" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-outage?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.enqueueListens(50);
    for (0..4) |_| try fixture.reply(.{ .fail = error.ConnectionRefused });
    const first = try fixture.step();
    try std.testing.expectEqual(Outcome.deferred, first.outcome);
    try Fixture.expectWakeAround(first, 60_000);
    try std.testing.expectEqual(State.backing_off, fixture.delivery.status().state);
    var waited: u64 = 0;
    while (waited + 2_000 < first.wake_after_ms.?) : (waited += 2_000) {
        fixture.advance(2_000);
        try std.testing.expectEqual(Outcome.blocked, (try fixture.step()).outcome);
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());
    fixture.waitOut(first.wake_after_ms.? - waited);
    const second = try fixture.step();
    try Fixture.expectWakeAround(second, 120_000);
    try std.testing.expectEqual(@as(usize, 2), fixture.transport.requestCount());
    try std.testing.expectEqual(@as(u64, 50), try fixture.library.scrobbles.pendingCount());
    try std.testing.expectEqual(@as(i64, 2), (try fixture.queued()).attempts);
}

test "a timeout backs off like any other transient failure" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-timeout?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.enqueueListens(1);
    try fixture.reply(.{ .fail = error.Timeout });
    const result = try fixture.step();
    try Fixture.expectWakeAround(result, 60_000);
    try std.testing.expectEqual(State.backing_off, fixture.delivery.status().state);
    try std.testing.expectEqual(@as(u64, 1), try fixture.library.scrobbles.pendingCount());
}

test "a canceled request releases its rows and reports cancellation" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-canceled?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.enqueueListens(3);
    try fixture.reply(.{ .fail = error.Canceled });
    const result = try fixture.step();
    try std.testing.expectEqual(Outcome.canceled, result.outcome);
    try std.testing.expectEqual(@as(u32, 0), try fixture.attemptsOfNextLease());
    try std.testing.expectEqual(Outcome.delivered, (try fixture.step()).outcome);
}

test "a 400 on a batch isolates the bad listen with single submissions and rejects only it" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-isolate?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    for (0..5) |index| try fixture.enqueueTitled(index, if (index == 2) "BAD" else "Good");
    fixture.reject_body_containing = "BAD";

    const batch = try fixture.step();
    try std.testing.expectEqual(Outcome.isolating, batch.outcome);
    try std.testing.expectEqual(@as(?u64, 0), batch.wake_after_ms);
    try std.testing.expect(std.mem.indexOf(u8, fixture.transport.history.items[0].body, "\"listen_type\":\"import\"") != null);
    try std.testing.expectEqual(@as(u64, 5), try fixture.library.scrobbles.pendingCount());

    const expected = [_]Outcome{ .delivered, .delivered, .rejected, .delivered, .delivered };
    for (expected) |outcome| {
        const result = try fixture.step();
        try std.testing.expectEqual(outcome, result.outcome);
    }
    try std.testing.expectEqual(@as(usize, 6), fixture.transport.requestCount());
    for (fixture.transport.history.items[1..]) |request|
        try std.testing.expect(std.mem.indexOf(u8, request.body, "\"listen_type\":\"single\"") != null);
    try std.testing.expectEqual(@as(u64, 4), try fixture.library.scrobbles.deliveredCount(service));
    try std.testing.expectEqual(@as(u64, 0), try fixture.library.scrobbles.pendingCount());

    try fixture.enqueueTitled(5, "Good");
    try fixture.enqueueTitled(6, "Good");
    _ = try fixture.step();
    try std.testing.expect(std.mem.indexOf(u8, fixture.transport.history.items[6].body, "\"listen_type\":\"import\"") != null);
}

test "a 401 stops delivery until credentials change" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-unauthorized?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.enqueueListens(2);
    try fixture.reply(.{ .respond = .{ .status = 401, .body = "{\"code\":401}" } });
    const first = try fixture.step();
    try std.testing.expectEqual(Outcome.deferred, first.outcome);
    try std.testing.expectEqual(@as(?u64, null), first.wake_after_ms);
    try std.testing.expectEqual(State.invalid_token, fixture.delivery.status().state);
    for (0..3) |_| {
        fixture.advance(120_000);
        try std.testing.expectEqual(Outcome.blocked, (try fixture.step()).outcome);
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());
    try std.testing.expectEqual(@as(u32, 0), try fixture.attemptsOfNextLease());

    fixture.delivery.credentialsChanged();
    const resumed = try fixture.step();
    try std.testing.expectEqual(Outcome.delivered, resumed.outcome);
    try std.testing.expectEqual(@as(u32, 2), resumed.delivered);
}

test "validateToken returns the user name for a valid token and null for an invalid one" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-validate?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    const allocator = std.testing.allocator;
    try fixture.reply(.{ .respond = .{
        .status = 200,
        .body = "{\"code\":200,\"message\":\"Token valid.\",\"valid\":true,\"user_name\":\"listener\"}",
    } });
    const name = (try fixture.delivery.validateToken("good-token")).?;
    defer allocator.free(name);
    try std.testing.expectEqualStrings("listener", name);
    try std.testing.expectEqualStrings("https://api.listenbrainz.org/1/validate-token", fixture.transport.history.items[0].url);
    try std.testing.expectEqualStrings("Token good-token", fixture.transport.lastAuthorization());
    try std.testing.expectEqualStrings("listener", fixture.delivery.status().user_name.slice());
    try std.testing.expectEqual(State.idle, fixture.delivery.status().state);

    try fixture.reply(.{ .respond = .{
        .status = 200,
        .body = "{\"code\":200,\"message\":\"Token invalid.\",\"valid\":false}",
    } });
    try std.testing.expectEqual(@as(?[]u8, null), try fixture.delivery.validateToken("bad-token"));
    try std.testing.expectEqual(State.invalid_token, fixture.delivery.status().state);
    try std.testing.expectEqual(@as(usize, 0), fixture.delivery.status().user_name.slice().len);

    try fixture.reply(.{ .respond = .{ .status = 401, .body = "{\"code\":401}" } });
    try std.testing.expectEqual(@as(?[]u8, null), try fixture.delivery.validateToken("worse-token"));
}

test "a server override addresses both endpoints under its base URL" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-server?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    fixture.delivery.server = "http://127.0.0.1:8080/lb/";
    try fixture.reply(.{ .respond = .{ .status = 200, .body = "{\"valid\":true,\"user_name\":\"listener\"}" } });
    const name = (try fixture.delivery.validateToken("token")).?;
    std.testing.allocator.free(name);
    try fixture.enqueueListens(1);
    _ = try fixture.step();
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/lb/1/validate-token", fixture.transport.history.items[0].url);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/lb/1/submit-listens", fixture.transport.history.items[1].url);
}

test "a validation that fails on the service or the network joins the service backoff" {
    const failures = [_]network.testing.Reply{
        .{ .respond = .{ .status = 503 } },
        .{ .fail = error.ConnectionRefused },
    };
    for (failures, 0..) |failure, index| {
        var name: [64:0]u8 = undefined;
        _ = try std.fmt.bufPrintSentinel(&name, "file:orca-lb-validate-backoff-{d}?mode=memory&cache=shared", .{index}, 0);
        var fixture: Fixture = undefined;
        try fixture.start(&name, .orca);
        defer fixture.stop();
        try fixture.enqueueListens(1);
        try fixture.reply(failure);
        const err = if (fixture.delivery.validateToken("token")) |_| return error.ExpectedFailure else |failed| failed;
        try fixture.delivery.validationFailed(err, Fixture.unix_now);
        try std.testing.expectEqual(State.backing_off, fixture.delivery.status().state);

        const blocked = try fixture.step();
        try std.testing.expectEqual(Outcome.blocked, blocked.outcome);
        try Fixture.expectWakeAround(blocked, 60_000);
        try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());
        try std.testing.expectEqual(@as(usize, 0), fixture.token_lookups);
    }
}

test "a validation refused by a rate limit does not start the service backoff" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-validate-limited-backoff?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.reply(.{ .respond = .{ .status = 429 } });
    const err = if (fixture.delivery.validateToken("token")) |_| return error.ExpectedFailure else |failed| failed;
    try fixture.delivery.validationFailed(err, Fixture.unix_now);
    try std.testing.expect(State.backing_off != fixture.delivery.status().state);
    try std.testing.expectEqual(@as(u64, 0), fixture.delivery.backoff_ms);
}

test "validateToken reports a rate limit as an error and keeps the previous state" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-validate-limited?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.reply(.{ .respond = .{ .status = 429 } });
    try std.testing.expectError(error.RateLimited, fixture.delivery.validateToken("token"));
    try std.testing.expectEqual(State.idle, fixture.delivery.status().state);
}

test "an empty queue makes no credential lookup and no request" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-empty?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    const result = try fixture.step();
    try std.testing.expectEqual(Outcome.idle, result.outcome);
    try std.testing.expectEqual(@as(?u64, null), result.wake_after_ms);
    try std.testing.expectEqual(@as(usize, 0), fixture.token_lookups);
    try std.testing.expectEqual(@as(usize, 0), fixture.transport.requestCount());
}

test "a queue whose only row is not yet due makes no credential lookup and reports when to wake" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-not-due?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.enqueueListens(1);
    const entries = try fixture.library.scrobbles.lease(std.testing.allocator, service, 42, Fixture.unix_now, Fixture.unix_now + 500, 1);
    for (entries) |entry| entry.deinit();
    std.testing.allocator.free(entries);
    fixture.advance(120_000);
    const result = try fixture.step();
    try std.testing.expectEqual(Outcome.idle, result.outcome);
    try std.testing.expectEqual(@as(?u64, 380_000), result.wake_after_ms);
    try std.testing.expectEqual(@as(usize, 0), fixture.token_lookups);
    try std.testing.expectEqual(@as(usize, 0), fixture.transport.requestCount());
}

test "a listen a transient failure put off is not sent before its retry time by a new Delivery" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-retry-time?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.enqueueListens(1);
    try fixture.reply(.{ .respond = .{ .status = 503 } });
    const failed = try fixture.step();
    const retry_at = Fixture.unix_now + secondsCeil(failed.wake_after_ms.?);
    try std.testing.expectEqual(Fixture.Queued{ .attempts = 1, .next_attempt_at = retry_at }, try fixture.queued());

    var clock: network.testing.TestClock = .{};
    var prng: std.Random.DefaultPrng = .init(7);
    var gateway = network.testing.gateway(&fixture.transport, &clock, &prng, .{});
    var restarted = Delivery.init(std.testing.allocator, std.testing.io, &gateway, .{ .context = &fixture, .get_fn = Fixture.getToken }, &fixture.library.scrobbles);
    const early = try restarted.step(retry_at - 1);
    try std.testing.expectEqual(Outcome.idle, early.outcome);
    try std.testing.expectEqual(@as(?u64, 1000), early.wake_after_ms);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());
    try std.testing.expectEqual(Outcome.delivered, (try restarted.step(retry_at)).outcome);
    try std.testing.expectEqual(@as(usize, 2), fixture.transport.requestCount());
}

test "while another process holds ListenBrainz nothing is sent, the rows stay due, and delivery resumes once it lets go" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-busy?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    fixture.gateway.sharing = .{ .store = shared_state.store(&fixture.library.provider_state), .service = service };
    try fixture.enqueueListens(2);
    try std.testing.expect(try fixture.library.provider_state.claimLease(service, 99, fixture.clock.now(), fixture.clock.now() + network.client.lease_duration_ms));

    const busy = try fixture.step();
    try std.testing.expectEqual(Outcome.deferred, busy.outcome);
    try std.testing.expectEqual(State.busy, fixture.delivery.status().state);
    try std.testing.expectEqual(@as(?u64, @intCast(network.client.lease_duration_ms)), busy.wake_after_ms);
    try std.testing.expectEqualStrings("ListenBrainz is in use by another Orca process", fixture.delivery.status().last_error.slice());
    try std.testing.expectEqual(@as(usize, 0), fixture.transport.requestCount());
    try std.testing.expectEqual(Fixture.Queued{ .attempts = 0, .next_attempt_at = 0 }, try fixture.queued());
    fixture.advance(1_000);
    try std.testing.expectEqual(Outcome.blocked, (try fixture.step()).outcome);
    try std.testing.expect(fixture.delivery.waitingForLease());

    fixture.waitOut(@intCast(network.client.lease_duration_ms));
    try std.testing.expectEqual(Outcome.delivered, (try fixture.step()).outcome);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());
}

test "a 403 stops delivery until credentials change" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-forbidden?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.enqueueListens(2);
    try fixture.reply(.{ .respond = .{ .status = 403 } });
    const first = try fixture.step();
    try std.testing.expectEqual(Outcome.deferred, first.outcome);
    try std.testing.expectEqual(State.invalid_token, fixture.delivery.status().state);
    for (0..3) |_| try std.testing.expectEqual(Outcome.blocked, (try fixture.step()).outcome);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());
    try std.testing.expectEqual(@as(u32, 0), try fixture.attemptsOfNextLease());
    fixture.delivery.credentialsChanged();
    try std.testing.expectEqual(@as(u32, 2), (try fixture.step()).delivered);
}

test "a 413 or 422 on a single listen rejects it and it is never resent" {
    inline for (.{ 413, 422 }) |status| {
        var fixture: Fixture = undefined;
        try fixture.start("file:orca-lb-permanent-" ++ std.fmt.comptimePrint("{d}", .{status}) ++ "?mode=memory&cache=shared", .orca);
        defer fixture.stop();
        try fixture.enqueueListens(1);
        try fixture.reply(.{ .respond = .{ .status = status } });
        const first = try fixture.step();
        try std.testing.expectEqual(Outcome.rejected, first.outcome);
        try std.testing.expectEqual(@as(u32, 1), first.rejected);
        try std.testing.expectEqual(@as(u64, 0), try fixture.library.scrobbles.pendingCount());
        try std.testing.expectEqual(Outcome.idle, (try fixture.step()).outcome);
        try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());
    }
}

test "a listen whose lease was lost during the request is skipped and the others are delivered" {
    std.testing.log_level = .err;
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-stale?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.enqueueListens(3);
    fixture.release_before_reply = .{
        .queue = &fixture.library.scrobbles,
        .id = 1,
        .owner = fixture.delivery.owner,
    };
    const result = try fixture.step();
    try std.testing.expectEqual(Outcome.delivered, result.outcome);
    try std.testing.expectEqual(@as(u32, 2), result.delivered);
    try std.testing.expectEqual(@as(u64, 2), try fixture.library.scrobbles.deliveredCount(service));
    try std.testing.expectEqual(@as(u64, 2), fixture.delivery.status().delivered_total);
}

test "an invalid network configuration backs off and the next immediate step makes no request" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-misconfigured?mode=memory&cache=shared", .{ .name = "", .version = "1", .contact = "a@b.c" });
    defer fixture.stop();
    try fixture.enqueueListens(2);
    const first = try fixture.step();
    try std.testing.expectEqual(Outcome.deferred, first.outcome);
    try Fixture.expectWakeAround(first, 60_000);
    try std.testing.expectEqual(State.backing_off, fixture.delivery.status().state);
    try std.testing.expectEqualStrings("InvalidNetworkConfiguration", fixture.delivery.status().last_error.slice());
    try std.testing.expectEqual(Outcome.blocked, (try fixture.step()).outcome);
    try std.testing.expectEqual(@as(usize, 0), fixture.transport.requestCount());
    try std.testing.expect((try fixture.queued()).next_attempt_at > fixture.unixNow());
}

const mbid_one = "8f3471b5-7e6a-48da-86a9-c1c07a0f5b4a";

test "a love goes out as one recording-feedback request carrying the recording id and score" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-feedback-love?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    const track = try fixture.track(mbid_one);
    try fixture.setFeedback(track, .loved);

    const result = try fixture.syncFeedback();
    try std.testing.expectEqual(Outcome.delivered, result.outcome);
    try std.testing.expectEqualStrings(
        "https://api.listenbrainz.org/1/feedback/recording-feedback",
        fixture.transport.history.items[0].url,
    );
    try std.testing.expectEqualStrings("Token secret-token", fixture.transport.lastAuthorization());
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture.transport.history.items[0].body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(mbid_one, parsed.value.object.get("recording_mbid").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("score").?.integer);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.count());

    try std.testing.expectEqual(Outcome.idle, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());
    try std.testing.expectEqual(database.Feedback.loved, try fixture.library.feedback.forTrack(track));
}

test "a hate is sent as score -1" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-feedback-hate?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.setFeedback(try fixture.track(mbid_one), .hated);
    _ = try fixture.syncFeedback();
    try std.testing.expectEqual(@as(i64, -1), try fixture.lastScore());
}

test "feedback without a recording id makes no token lookup and no request" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-feedback-untagged?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    const track = try fixture.track(null);
    try fixture.setFeedback(track, .loved);

    const result = try fixture.syncFeedback();
    try std.testing.expectEqual(Outcome.idle, result.outcome);
    try std.testing.expectEqual(@as(usize, 0), fixture.token_lookups);
    try std.testing.expectEqual(@as(usize, 0), fixture.transport.requestCount());
    try std.testing.expectEqual(database.Feedback.loved, try fixture.library.feedback.forTrack(track));
}

test "clearing a synced love sends score 0 once and leaves no row, and clearing an unsent one sends nothing" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-feedback-clear?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    const synced = try fixture.track(mbid_one);
    try fixture.setFeedback(synced, .loved);
    _ = try fixture.syncFeedback();

    try fixture.setFeedback(synced, .none);
    try std.testing.expectEqual(Outcome.delivered, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(@as(i64, 0), try fixture.lastScore());
    try std.testing.expectEqual(Outcome.idle, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(@as(usize, 2), fixture.transport.requestCount());
    var rows = try fixture.library.database.prepare("SELECT count(*) FROM feedback;");
    defer rows.deinit();
    try std.testing.expect(try rows.step() == .row);
    try std.testing.expectEqual(@as(i64, 0), rows.columnInt64(0));

    const unsent = try fixture.track("8f3471b5-7e6a-48da-86a9-c1c07a0f5b4b");
    try fixture.setFeedback(unsent, .loved);
    try fixture.setFeedback(unsent, .none);
    try std.testing.expectEqual(Outcome.idle, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(@as(usize, 2), fixture.transport.requestCount());
}

test "a permanent 4xx on feedback is recorded and the change is not sent again" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-feedback-rejected?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    const track = try fixture.track(mbid_one);
    try fixture.setFeedback(track, .loved);
    try fixture.reply(.{ .respond = .{ .status = 400, .body = "{\"code\":400,\"error\":\"Invalid recording MBID\"}" } });

    const first = try fixture.syncFeedback();
    try std.testing.expectEqual(Outcome.rejected, first.outcome);
    for (0..3) |_| {
        fixture.advance(120_000);
        try std.testing.expectEqual(Outcome.idle, (try fixture.syncFeedback()).outcome);
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());
    try std.testing.expectEqualStrings(
        "HTTP 400: Invalid recording MBID",
        fixture.delivery.status().last_error.slice(),
    );
    try std.testing.expectEqual(State.idle, fixture.delivery.status().state);

    try fixture.setFeedback(track, .hated);
    try std.testing.expectEqual(Outcome.delivered, (try fixture.syncFeedback()).outcome);
}

test "a 429 on feedback blocks listens and feedback until the gateway unblocks" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-feedback-limited?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.setFeedback(try fixture.track(mbid_one), .loved);
    try fixture.enqueueListens(1);
    try fixture.reply(.{ .respond = .{ .status = 429 } });

    const limited = try fixture.syncFeedback();
    try std.testing.expectEqual(Outcome.deferred, limited.outcome);
    try Fixture.expectWakeAround(limited, 60_000);
    try std.testing.expectEqual(State.rate_limited, fixture.delivery.status().state);
    try std.testing.expectEqual(Outcome.blocked, (try fixture.step()).outcome);
    try std.testing.expectEqual(Outcome.blocked, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());

    fixture.waitOut(limited.wake_after_ms.?);
    try std.testing.expectEqual(Outcome.delivered, (try fixture.step()).outcome);
    try std.testing.expectEqual(Outcome.delivered, (try fixture.syncFeedback()).outcome);
}

test "a server error on feedback joins the service backoff that listens obey" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-feedback-outage?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.setFeedback(try fixture.track(mbid_one), .loved);
    try fixture.enqueueListens(1);
    try fixture.reply(.{ .respond = .{ .status = 503 } });
    try fixture.reply(.{ .fail = error.ConnectionRefused });

    const first = try fixture.syncFeedback();
    try std.testing.expectEqual(Outcome.deferred, first.outcome);
    try Fixture.expectWakeAround(first, 60_000);
    try std.testing.expectEqual(State.backing_off, fixture.delivery.status().state);
    try std.testing.expectEqual(Outcome.blocked, (try fixture.step()).outcome);
    fixture.waitOut(first.wake_after_ms.?);
    const second = try fixture.syncFeedback();
    try Fixture.expectWakeAround(second, 120_000);
    try std.testing.expectEqual(@as(usize, 2), fixture.transport.requestCount());
}

test "a 401 on feedback stops all delivery until credentials change" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-feedback-unauthorized?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.setFeedback(try fixture.track(mbid_one), .loved);
    try fixture.enqueueListens(1);
    try fixture.reply(.{ .respond = .{ .status = 401 } });

    try std.testing.expectEqual(Outcome.deferred, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(State.invalid_token, fixture.delivery.status().state);
    try std.testing.expectEqual(Outcome.blocked, (try fixture.step()).outcome);
    try std.testing.expectEqual(Outcome.blocked, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());

    fixture.delivery.credentialsChanged();
    try std.testing.expectEqual(Outcome.delivered, (try fixture.syncFeedback()).outcome);
}

test "no feedback request is made offline or without a token" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-feedback-gated?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.setFeedback(try fixture.track(mbid_one), .loved);
    fixture.gateway.config.offline = true;
    try std.testing.expectEqual(Outcome.blocked, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(State.offline, fixture.delivery.status().state);
    fixture.gateway.config.offline = false;
    fixture.token = null;
    try std.testing.expectEqual(Outcome.blocked, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(State.needs_token, fixture.delivery.status().state);
    try std.testing.expectEqual(@as(usize, 0), fixture.transport.requestCount());
    fixture.token = "secret-token";
    try std.testing.expectEqual(Outcome.delivered, (try fixture.syncFeedback()).outcome);
}

const FeedbackChanger = struct {
    fixture: *Fixture,
    track: i64,
    changes: []const database.Feedback,

    fn run(context: *anyopaque) anyerror!void {
        const self: *FeedbackChanger = @ptrCast(@alignCast(context));
        for (self.changes) |value| try self.fixture.setFeedback(self.track, value);
    }
};

test "love, dislike and love again during a request sends the love once and ends loved" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-feedback-flip?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    const track = try fixture.track(mbid_one);
    try fixture.setFeedback(track, .loved);
    var changer: FeedbackChanger = .{ .fixture = &fixture, .track = track, .changes = &.{ .hated, .loved } };
    fixture.during_request = .{ .context = &changer, .run = FeedbackChanger.run };

    try std.testing.expectEqual(Outcome.delivered, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(Outcome.idle, (try fixture.syncFeedback()).outcome);

    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());
    try std.testing.expectEqual(@as(i64, 1), try fixture.lastScore());
    try std.testing.expectEqual(database.Feedback.loved, try fixture.library.feedback.forTrack(track));
}

test "a dislike made during a love's request goes out next and the service ends hated" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-feedback-overtaken?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    const track = try fixture.track(mbid_one);
    try fixture.setFeedback(track, .loved);
    var changer: FeedbackChanger = .{ .fixture = &fixture, .track = track, .changes = &.{.hated} };
    fixture.during_request = .{ .context = &changer, .run = FeedbackChanger.run };

    try std.testing.expectEqual(Outcome.delivered, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(@as(i64, 1), try fixture.lastScore());
    try std.testing.expectEqual(Outcome.delivered, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(@as(i64, -1), try fixture.lastScore());
    try std.testing.expectEqual(Outcome.idle, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(@as(usize, 2), fixture.transport.requestCount());
}

test "a clear made during a love's request is sent next and leaves no row" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-feedback-cleared-in-flight?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    const track = try fixture.track(mbid_one);
    try fixture.setFeedback(track, .loved);
    var changer: FeedbackChanger = .{ .fixture = &fixture, .track = track, .changes = &.{.none} };
    fixture.during_request = .{ .context = &changer, .run = FeedbackChanger.run };

    _ = try fixture.syncFeedback();
    try std.testing.expectEqual(Outcome.delivered, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(@as(i64, 0), try fixture.lastScore());
    try std.testing.expectEqual(Outcome.idle, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(database.Feedback.none, try fixture.library.feedback.forTrack(track));
}

fn nowPlaying(title: []const u8) scrobble.Event {
    return .{
        .title = title,
        .artist = "Test Artist",
        .album = "Ocean",
        .started_at = 1_700_000_000,
        .duration_ms = 180_000,
        .listened_ms = 10_000,
        .recording_mbid = "rec-mbid",
    };
}

test "now playing is sent as playing_now with one track and no listened_at" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-now-playing?mode=memory&cache=shared", .orca);
    defer fixture.stop();

    const result = try fixture.delivery.sendNowPlaying(nowPlaying("Orca"), Fixture.unix_now);
    try std.testing.expectEqual(Outcome.delivered, result.outcome);
    try std.testing.expectEqualStrings("https://api.listenbrainz.org/1/submit-listens", fixture.transport.history.items[0].url);
    const body = fixture.transport.history.items[0].body;
    try std.testing.expect(std.mem.indexOf(u8, body, "listened_at") == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("playing_now", parsed.value.object.get("listen_type").?.string);
    const payload = parsed.value.object.get("payload").?.array;
    try std.testing.expectEqual(@as(usize, 1), payload.items.len);
    const metadata = payload.items[0].object.get("track_metadata").?.object;
    try std.testing.expectEqualStrings("Orca", metadata.get("track_name").?.string);
    try std.testing.expectEqualStrings("Ocean", metadata.get("release_name").?.string);
    const info = metadata.get("additional_info").?.object;
    try std.testing.expectEqualStrings("rec-mbid", info.get("recording_mbid").?.string);
    try std.testing.expectEqualStrings("Orca", info.get("submission_client").?.string);
}

test "a 429 on now playing blocks every request and the update is not sent again" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-now-playing-limited?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.enqueueListens(1);
    try fixture.reply(.{ .respond = .{ .status = 429 } });

    const limited = try fixture.delivery.sendNowPlaying(nowPlaying("Orca"), Fixture.unix_now);
    try std.testing.expectEqual(Outcome.deferred, limited.outcome);
    try std.testing.expectEqual(State.rate_limited, fixture.delivery.status().state);
    try std.testing.expectEqual(Outcome.blocked, (try fixture.step()).outcome);
    try std.testing.expectEqual(Outcome.blocked, (try fixture.delivery.sendNowPlaying(nowPlaying("Orca"), Fixture.unix_now)).outcome);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());
}

test "now playing makes no request while backing off, offline or without a token" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-now-playing-gated?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    fixture.token = null;
    try std.testing.expectEqual(Outcome.blocked, (try fixture.delivery.sendNowPlaying(nowPlaying("Orca"), Fixture.unix_now)).outcome);
    try std.testing.expectEqual(State.idle, fixture.delivery.status().state);
    fixture.token = "secret-token";
    fixture.gateway.config.offline = true;
    try std.testing.expectEqual(Outcome.blocked, (try fixture.delivery.sendNowPlaying(nowPlaying("Orca"), Fixture.unix_now)).outcome);
    fixture.gateway.config.offline = false;
    try fixture.enqueueListens(1);
    try fixture.reply(.{ .respond = .{ .status = 503 } });
    _ = try fixture.step();
    try std.testing.expectEqual(State.backing_off, fixture.delivery.status().state);
    try std.testing.expectEqual(Outcome.blocked, (try fixture.delivery.sendNowPlaying(nowPlaying("Orca"), Fixture.unix_now)).outcome);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());
}

test "a now playing update the service refuses is dropped without touching the backoff" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-now-playing-refused?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    try fixture.reply(.{ .respond = .{ .status = 400 } });
    const result = try fixture.delivery.sendNowPlaying(nowPlaying("Orca"), Fixture.unix_now);
    try std.testing.expectEqual(Outcome.rejected, result.outcome);
    try std.testing.expectEqual(State.idle, fixture.delivery.status().state);
    try std.testing.expectEqual(@as(u64, 0), fixture.delivery.backoff_ms);
}

fn changedAt(fixture: *Fixture) !i64 {
    var statement = try fixture.library.database.prepare("SELECT max(updated_at) FROM feedback;");
    defer statement.deinit();
    if (try statement.step() != .row) return error.SqlFailed;
    return statement.columnInt64(0);
}

test "a change is not sent until it has stood for two seconds, and only its final state is" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-feedback-settle?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    const track = try fixture.track(mbid_one);
    try fixture.setFeedback(track, .loved);
    _ = try fixture.syncFeedback();
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());

    try fixture.setFeedback(track, .none);
    try fixture.setFeedback(track, .loved);
    try fixture.setFeedback(track, .none);
    const changed_at = try changedAt(&fixture);
    const waiting = try fixture.delivery.syncFeedback(&fixture.library.feedback, changed_at + 1);
    try std.testing.expectEqual(Outcome.idle, waiting.outcome);
    try std.testing.expectEqual(@as(?u64, 2000), waiting.wake_after_ms);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());

    const sent = try fixture.delivery.syncFeedback(&fixture.library.feedback, changed_at + 2);
    try std.testing.expectEqual(Outcome.delivered, sent.outcome);
    try std.testing.expectEqual(@as(i64, 0), try fixture.lastScore());
    try std.testing.expectEqual(Outcome.idle, (try fixture.delivery.syncFeedback(&fixture.library.feedback, changed_at + 60)).outcome);
    try std.testing.expectEqual(@as(usize, 2), fixture.transport.requestCount());
}

test "changes that end where the service already is send nothing" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-feedback-settle-noop?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    const track = try fixture.track(mbid_one);
    try fixture.setFeedback(track, .loved);
    _ = try fixture.syncFeedback();

    try fixture.setFeedback(track, .none);
    try fixture.setFeedback(track, .hated);
    try fixture.setFeedback(track, .loved);
    const changed_at = try changedAt(&fixture);

    const result = try fixture.delivery.syncFeedback(&fixture.library.feedback, changed_at + 60);
    try std.testing.expectEqual(Outcome.idle, result.outcome);
    try std.testing.expectEqual(@as(?u64, null), result.wake_after_ms);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());
}

test "a change the service accepted but that could not be marked is not sent again" {
    var fixture: Fixture = undefined;
    try fixture.start("file:orca-lb-feedback-mark-fails?mode=memory&cache=shared", .orca);
    defer fixture.stop();
    const track = try fixture.track(mbid_one);
    try fixture.setFeedback(track, .loved);
    try fixture.library.database.exec(
        "CREATE TRIGGER refuse_mark BEFORE UPDATE ON feedback BEGIN SELECT RAISE(ABORT, 'refused'); END;",
    );

    try std.testing.expectError(error.SqlFailed, fixture.syncFeedback());
    for (0..3) |_| {
        fixture.advance(60_000);
        try std.testing.expectError(error.SqlFailed, fixture.syncFeedback());
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());

    try fixture.library.database.exec("DROP TRIGGER refuse_mark;");
    try std.testing.expectEqual(Outcome.delivered, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(@as(usize, 1), fixture.transport.requestCount());
    try std.testing.expectEqual(Outcome.idle, (try fixture.syncFeedback()).outcome);

    try fixture.setFeedback(track, .hated);
    try std.testing.expectEqual(Outcome.delivered, (try fixture.syncFeedback()).outcome);
    try std.testing.expectEqual(@as(usize, 2), fixture.transport.requestCount());
}
