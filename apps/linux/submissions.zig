const std = @import("std");
const liborca = @import("liborca");
const app = @import("app.zig");
const jobs = @import("jobs.zig");
const preferences = @import("preferences.zig");
const secret = @import("secret.zig");

const App = app.App;

pub const refresh_ms: u64 = 15 * std.time.ms_per_min;

pub fn waiting(self: *App) u64 {
    const library = self.library orelse return 0;
    return self.runtime.libraryAcoustIdSubmittableCount(library) catch 0;
}

pub fn submitted(self: *App) u64 {
    const library = self.library orelse return 0;
    return self.runtime.libraryAcoustIdSubmittedCount(library) catch 0;
}

pub fn keyChecked(self: *App, presence: secret.Presence) void {
    self.acoustid_key_stored = presence == .stored;
    self.acoustid_key_known = true;
    preferences.showSubmission(self);
}

fn keyFound(presence: secret.Presence, data: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(data.?));
    self.acoustid_key_checking = false;
    keyChecked(self, presence);
    autoStart(self);
}

fn checkKey(self: *App) void {
    if (self.acoustid_key_checking) return;
    self.acoustid_key_checking = true;
    secret.check(liborca.acoustid_credential_service, liborca.acoustid_user_key_account, .report, keyFound, self) catch {
        self.acoustid_key_checking = false;
    };
}

pub fn autoStart(self: *App) void {
    preferences.showSubmission(self);
    if (!self.contribute_acoustid) return;
    if (!self.acoustid_key_known) return checkKey(self);
    if (!self.acoustid_key_stored or waiting(self) == 0) return;
    jobs.requestSubmission(self, true) catch {};
}

pub fn tick(self: *App) void {
    if (!self.contribute_acoustid) return;
    const now = std.Io.Clock.real.now(self.io).toMilliseconds();
    if (self.submission_checked_ms) |last| {
        if (now - last < @as(i64, refresh_ms)) return;
    }
    self.submission_checked_ms = now;
    if (self.task_count != 0) return;
    autoStart(self);
}
