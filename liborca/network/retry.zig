//! How a job asks a provider again after a failure that may pass: a jittered
//! 5 s, then 30 s, after an outage or a timeout, and, where the job waits out
//! refusals, the service's block or 60 s doubling after a rate limit.

const std = @import("std");
const client = @import("client.zig");
const testing = @import("testing.zig");

const Gateway = client.Gateway;

pub const maximum_attempts = 3;
pub const unavailable_backoff_ms = [maximum_attempts - 1]u64{ 5_000, 30_000 };
pub const initial_rate_limit_backoff_ms: u64 = 60_000;
const cancel_poll_ms: u64 = 100;

/// What a job does when the service asked it to back off.
pub const RateLimits = enum {
    /// Wait out the service's block, at least the job's own backoff, and ask again.
    wait,
    /// Report the failure at once.
    report,
};

pub const Next = enum {
    again,
    give_up,
    cancelled,
};

/// After `attempt` (from 0) failed with `err`: waits, cancellably, and says
/// whether to ask again. `canceller` is null or has `isCancelled() bool`,
/// checked with the Gateway's own cancel flag. A wait that would end past
/// the Gateway's deadline is not begun.
pub fn afterFailure(gateway: *Gateway, err: anyerror, attempt: u32, rate_limits: RateLimits, canceller: anytype) Next {
    if (attempt + 1 >= maximum_attempts) return .give_up;
    const nominal_ms: u64 = switch (err) {
        error.ProviderUnavailable, error.Timeout => unavailable_backoff_ms[attempt],
        error.RateLimited => switch (rate_limits) {
            .wait => initial_rate_limit_backoff_ms << @intCast(attempt),
            .report => return .give_up,
        },
        else => return .give_up,
    };
    var until = gateway.clock.nowMs() +| @as(i64, @intCast(client.jittered(gateway.random, nominal_ms)));
    if (gateway.blockedUntilMs()) |blocked| until = @max(until, blocked);
    if (gateway.deadline_ms) |deadline| if (until >= deadline) return .give_up;
    while (true) {
        if (isCancelled(gateway, canceller)) return .cancelled;
        const now = gateway.clock.nowMs();
        if (now >= until) return .again;
        gateway.clock.sleepMs(@min(cancel_poll_ms, @as(u64, @intCast(until - now)))) catch return .cancelled;
    }
}

/// `function` called with `args`, asked again after each failure
/// `afterFailure` allows. A cancel while waiting is `error.Canceled`.
pub fn call(
    gateway: *Gateway,
    rate_limits: RateLimits,
    canceller: anytype,
    function: anytype,
    args: anytype,
) @TypeOf(@call(.auto, function, args)) {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        return @call(.auto, function, args) catch |err| switch (afterFailure(gateway, err, attempt, rate_limits, canceller)) {
            .again => continue,
            .give_up => err,
            .cancelled => error.Canceled,
        };
    }
}

fn isCancelled(gateway: *const Gateway, canceller: anytype) bool {
    if (gateway.cancel) |flag| if (flag.load(.acquire)) return true;
    return if (@TypeOf(canceller) == @TypeOf(null)) false else canceller.isCancelled();
}

const RetryTest = struct {
    net: testing.TestGateway,
    failures: []const anyerror,
    calls: u32 = 0,

    fn attempt(self: *RetryTest) !u32 {
        defer self.calls += 1;
        if (self.calls < self.failures.len) return self.failures[self.calls];
        return self.calls;
    }
};

test "an outage is asked again after about 5 s, then about 30 s, then reported" {
    var harness: RetryTest = .{ .net = undefined, .failures = &.{ error.ProviderUnavailable, error.Timeout, error.ProviderUnavailable } };
    harness.net.init(.{});
    defer harness.net.deinit();
    const result = call(&harness.net.gateway, .wait, null, RetryTest.attempt, .{&harness});
    try std.testing.expectError(error.ProviderUnavailable, result);
    try std.testing.expectEqual(@as(u32, 3), harness.calls);
    const slept = harness.net.clock.slept();
    try std.testing.expect(slept >= 2_500 + 15_000 and slept <= 7_500 + 45_000);
}

test "one outage costs about 5 s and the second answer is returned" {
    var harness: RetryTest = .{ .net = undefined, .failures = &.{error.ProviderUnavailable} };
    harness.net.init(.{});
    defer harness.net.deinit();
    try std.testing.expectEqual(@as(u32, 1), try call(&harness.net.gateway, .report, null, RetryTest.attempt, .{&harness}));
    const slept = harness.net.clock.slept();
    try std.testing.expect(slept >= 2_500 and slept <= 7_500);
}

test "a rate limit is reported at once unless the job waits refusals out" {
    var reported: RetryTest = .{ .net = undefined, .failures = &.{error.RateLimited} };
    reported.net.init(.{});
    defer reported.net.deinit();
    try std.testing.expectError(error.RateLimited, call(&reported.net.gateway, .report, null, RetryTest.attempt, .{&reported}));
    try std.testing.expectEqual(@as(u64, 0), reported.net.clock.slept());

    var waited: RetryTest = .{ .net = undefined, .failures = &.{error.RateLimited} };
    waited.net.init(.{});
    defer waited.net.deinit();
    try waited.net.gateway.blockFor(100_000);
    try std.testing.expectEqual(@as(u32, 1), try call(&waited.net.gateway, .wait, null, RetryTest.attempt, .{&waited}));
    try std.testing.expect(waited.net.clock.slept() >= 100_000);
}

test "a failure that cannot pass is reported at once" {
    var harness: RetryTest = .{ .net = undefined, .failures = &.{error.ProviderRejectedRequest} };
    harness.net.init(.{});
    defer harness.net.deinit();
    try std.testing.expectError(error.ProviderRejectedRequest, call(&harness.net.gateway, .wait, null, RetryTest.attempt, .{&harness}));
    try std.testing.expectEqual(@as(u64, 0), harness.net.clock.slept());
}

test "a wait past the Gateway's deadline is not begun" {
    var harness: RetryTest = .{ .net = undefined, .failures = &.{ error.Timeout, error.Timeout } };
    harness.net.init(.{});
    defer harness.net.deinit();
    harness.net.gateway.deadline_ms = harness.net.clock.now() + 10_000;
    try std.testing.expectError(error.Timeout, call(&harness.net.gateway, .report, null, RetryTest.attempt, .{&harness}));
    try std.testing.expectEqual(@as(u32, 2), harness.calls);
    try std.testing.expect(harness.net.clock.slept() <= 7_500);
}

const CancelAfter = struct {
    clock: *const testing.TestClock,
    at_ms: i64,

    fn isCancelled(self: *const CancelAfter) bool {
        return self.clock.now() >= self.at_ms;
    }
};

test "a cancel during the 30 s wait ends it within one poll" {
    var harness: RetryTest = .{ .net = undefined, .failures = &.{ error.ProviderUnavailable, error.ProviderUnavailable } };
    harness.net.init(.{});
    defer harness.net.deinit();
    const cancel: CancelAfter = .{ .clock = &harness.net.clock, .at_ms = harness.net.clock.now() + 7_500 + 1_000 };
    try std.testing.expectError(error.Canceled, call(&harness.net.gateway, .wait, &cancel, RetryTest.attempt, .{&harness}));
    try std.testing.expectEqual(@as(u32, 2), harness.calls);
    try std.testing.expect(harness.net.clock.now() <= cancel.at_ms + cancel_poll_ms);
}
