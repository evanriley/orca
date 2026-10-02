//! Idle maintenance: liborca verifies one album against AcoustID at a time
//! while nothing plays, and this frontend turns it on or off, says how it is
//! going, and rereads what a finished unit may have found.

const std = @import("std");
const liborca = @import("liborca");
const app = @import("app.zig");
const health = @import("health.zig");
const matches = @import("matches.zig");
const details = @import("details.zig");
const strings = @import("strings.zig");

const App = app.App;

const interval_ms: u32 = 5 * std.time.ms_per_min;

pub const refresh_ms: u64 = 15 * std.time.ms_per_s;

/// Brings the open library's maintenance in line with `self.idle_maintenance`;
/// it needs fingerprints, which a unit sends to AcoustID.
pub fn apply(self: *App) !void {
    const library = self.library orelse return;
    try self.runtime.libraryMaintenance(library, .{
        .enabled = self.idle_maintenance and self.match_fingerprints,
        .interval_ms = interval_ms,
    });
}

pub fn status(self: *App) ?liborca.MaintenanceStatus {
    const library = self.library orelse return null;
    return self.runtime.libraryMaintenanceStatus(library) catch null;
}

pub fn tick(self: *App) void {
    const current = status(self) orelse return;
    const seen = self.maintenance_units_seen;
    self.maintenance_units_seen = current.units_run;
    if (current.units_run <= seen) return;
    const library = self.library orelse return;
    const stats = if (current.last) |unit| unit.stats else return;
    const found = stats.disagreed != 0 or stats.proposals_stored != 0;
    const shown = self.health_issues_shown;
    const total = self.runtime.libraryHealthIssueCount(library) catch shown;
    if (found or total != shown) health.reload(self);
    if (!found) return;
    matches.reload(self);
    details.invalidate(self);
}

pub fn statusText(buffer: []u8, value: liborca.MaintenanceStatus) [:0]const u8 {
    return switch (value.state) {
        .off => "Checks one album against AcoustID every few minutes while nothing plays",
        .running => "Checking…",
        .blocked => switch (value.blocked orelse .provider_busy) {
            .client_identity_required, .acoustid_required => "AcoustID is unavailable",
            .provider_busy => "AcoustID is busy; trying again later",
        },
        .waiting => waitingText(buffer, value),
    };
}

fn waitingText(buffer: []u8, value: liborca.MaintenanceStatus) [:0]const u8 {
    const minutes = std.math.divCeil(u64, value.next_due_ms orelse 0, std.time.ms_per_min) catch 0;
    var next_buffer: [32]u8 = undefined;
    const next: []const u8 = if (minutes == 0)
        "Next album soon"
    else
        strings.format(&next_buffer, "Next album in {d} min", .{minutes});
    if (value.units_run == 0) return strings.format(buffer, "{s}", .{next});
    return strings.format(buffer, "{s} · {f} {s} checked", .{
        next,
        strings.grouped(value.units_run),
        if (value.units_run == 1) "album" else "albums",
    });
}
