//! The Library's stats and health summary, read off the main thread through
//! the engine's browse loader. Readers use the last numbers that arrived and
//! ask for fresh ones; an answer for another Library is never shown.

const std = @import("std");
const liborca = @import("liborca");
const app = @import("app.zig");
const window = @import("window.zig");
const libraries = @import("libraries.zig");
const first_run = @import("first_run.zig");
const health = @import("health.zig");
const audio_problems = @import("audio_problems.zig");
const preferences = @import("preferences.zig");

const App = app.App;

const Query = enum { stats, health };

const Slot = struct {
    request: app.TotalsRequest = .idle,
    again: bool = false,
};

pub const State = struct {
    stats: ?liborca.LibraryStats = null,
    health: ?liborca.HealthSummary = null,
    stats_slot: Slot = .{},
    health_slot: Slot = .{},

    fn slot(self: *State, query: Query) *Slot {
        return switch (query) {
            .stats => &self.stats_slot,
            .health => &self.health_slot,
        };
    }
};

pub fn requestStats(self: *App) void {
    request(self, .stats);
}

pub fn requestHealth(self: *App) void {
    request(self, .health);
}

pub fn forgetLibrary(self: *App) void {
    const summary = &self.library_summary;
    for ([_]Query{ .stats, .health }) |query| {
        const slot = summary.slot(query);
        switch (slot.request) {
            .pending => |id| if (self.library) |library| self.runtime.libraryCancelBrowse(library, id),
            else => {},
        }
        slot.* = .{};
    }
    summary.stats = null;
    summary.health = null;
}

pub fn isRequest(self: *App, request_id: u64) bool {
    return pendingQuery(self, request_id) != null;
}

pub fn retryWaiting(self: *App) bool {
    var waiting = false;
    for ([_]Query{ .stats, .health }) |query| {
        if (self.library_summary.slot(query).request != .waiting) continue;
        submit(self, query);
        if (self.library_summary.slot(query).request == .waiting) waiting = true;
    }
    return waiting;
}

pub fn arrived(self: *App, request_id: u64, payload: liborca.BrowsePayload) void {
    const query = pendingQuery(self, request_id) orelse return;
    const summary = &self.library_summary;
    const slot = summary.slot(query);
    slot.request = .idle;
    switch (payload) {
        .library_stats => |stats| summary.stats = stats,
        .health_summary => |found| summary.health = found,
        else => return,
    }
    if (slot.again) {
        slot.again = false;
        submit(self, query);
    }
    switch (query) {
        .stats => {
            window.showCounts(self);
            libraries.rememberTracks(self);
            first_run.statsArrived(self);
            health.statsArrived(self);
            preferences.statsArrived(self);
        },
        .health => {
            health.summaryArrived(self);
            audio_problems.summaryArrived(self);
            first_run.healthArrived(self);
        },
    }
}

pub fn failed(self: *App, request_id: u64) void {
    const query = pendingQuery(self, request_id) orelse return;
    const slot = self.library_summary.slot(query);
    slot.request = .idle;
    slot.again = false;
    std.log.warn("The library's {t} could not be read", .{query});
}

fn pendingQuery(self: *App, request_id: u64) ?Query {
    for ([_]Query{ .stats, .health }) |query| {
        switch (self.library_summary.slot(query).request) {
            .pending => |id| if (id == request_id) return query,
            else => {},
        }
    }
    return null;
}

fn request(self: *App, query: Query) void {
    const slot = self.library_summary.slot(query);
    switch (slot.request) {
        .pending => slot.again = true,
        .waiting => {},
        .idle => submit(self, query),
    }
}

fn submit(self: *App, query: Query) void {
    const slot = self.library_summary.slot(query);
    const library = self.library orelse {
        slot.request = .idle;
        return;
    };
    const wanted: liborca.BrowseRequest = switch (query) {
        .stats => .library_stats,
        .health => .health_summary,
    };
    const id = self.runtime.libraryRequestBrowse(library, self.io, wanted) catch |err| {
        if (err == error.BrowseQueueFull) {
            slot.request = .waiting;
            self.scheduleBrowseRetry();
            return;
        }
        slot.request = .idle;
        std.log.warn("The library's {t} could not be requested ({t})", .{ query, err });
        return;
    };
    slot.request = .{ .pending = id };
}
