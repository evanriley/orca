//! Background jobs — scans, loudness analysis, duplicate finding, tag writes,
//! matching and AcoustID submission — and their status card at the foot of
//! the sidebar. One runs at a time from this frontend, so the card always
//! describes the job there is.
//!
//! A filesystem walk has no honest denominator until it has finished walking,
//! so a scan shows its counts rather than a fabricated percentage.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const browse = @import("browse.zig");
const albums = @import("albums.zig");
const artists = @import("artists.zig");
const health = @import("health.zig");
const matches = @import("matches.zig");
const details = @import("details.zig");
const tags = @import("tags.zig");

const App = app.App;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn cancelClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    const job = self.task_job orelse return;
    self.runtime.cancelJob(job) catch return;
    if (self.scan_label) |label| gtk.gtk_label_set_text(label, "Stopping…");
}

/// Refuses a second job while one runs, with a toast saying which.
fn idle(self: *App) bool {
    const task = self.task orelse return true;
    self.toast(switch (task) {
        .scan => "A scan is already running",
        .analysis => "Loudness is being measured",
        .duplicates => "Duplicates are being looked for",
        .tag_write => "Tags are being written",
        .matching => "Already finding matches",
        .submission => "Already submitting to AcoustID",
    });
    return false;
}

fn begin(self: *App, task: app.Task, job: liborca.JobHandle, title: [*:0]const u8) void {
    self.task = task;
    self.task_job = job;
    showScanning(self, true);
    if (self.scan_label) |label| gtk.gtk_label_set_text(label, title);
    if (self.scan_detail) |label| gtk.gtk_label_set_text(label, "Starting…");
    self.updateTracksBody();
}

/// Everything shown from the library, rebuilt after its contents changed.
pub fn reloadLibraryViews(self: *App) void {
    browse.reload(self);
    self.reload();
    albums.reload(self);
    artists.reload(self);
    health.reload(self);
    matches.reload(self);
}

pub fn build(self: *App) *gtk.Widget {
    const card = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 10);
    gtk.gtk_widget_add_css_class(card, "scan-status");
    const spinner = adw.adw_spinner_new();
    gtk.gtk_widget_set_size_request(spinner, 16, 16);
    gtk.gtk_widget_set_valign(spinner, gtk.ALIGN_CENTER);
    const labels = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_hexpand(labels, gtk.true_);
    gtk.gtk_widget_set_valign(labels, gtk.ALIGN_CENTER);
    const label = gtk.gtk_label_new("Scanning…");
    self.scan_label = gtk.cast(gtk.Label, label);
    gtk.gtk_label_set_xalign(self.scan_label.?, 0.0);
    gtk.gtk_label_set_ellipsize(self.scan_label.?, gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(label, "heading");
    const detail = gtk.gtk_label_new("");
    self.scan_detail = gtk.cast(gtk.Label, detail);
    gtk.gtk_label_set_xalign(self.scan_detail.?, 0.0);
    gtk.gtk_label_set_ellipsize(self.scan_detail.?, gtk.ELLIPSIZE_END);
    gtk.gtk_widget_add_css_class(detail, "caption");
    gtk.gtk_widget_add_css_class(detail, "dim-label");
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), label);
    gtk.gtk_box_append(gtk.cast(gtk.Box, labels), detail);
    const cancel = gtk.gtk_button_new_from_icon_name("process-stop-symbolic");
    gtk.gtk_widget_set_tooltip_text(cancel, "Stop scanning");
    gtk.gtk_widget_add_css_class(cancel, "flat");
    gtk.gtk_widget_add_css_class(cancel, "circular");
    gtk.gtk_widget_set_valign(cancel, gtk.ALIGN_CENTER);
    _ = gtk.signalConnect(cancel, "clicked", gtk.callback(cancelClicked), self);
    gtk.gtk_box_append(gtk.cast(gtk.Box, card), spinner);
    gtk.gtk_box_append(gtk.cast(gtk.Box, card), labels);
    gtk.gtk_box_append(gtk.cast(gtk.Box, card), cancel);

    const revealer = gtk.gtk_revealer_new();
    self.scan_revealer = gtk.cast(gtk.Revealer, revealer);
    gtk.gtk_revealer_set_transition_type(self.scan_revealer.?, gtk.REVEALER_TRANSITION_SLIDE_UP);
    gtk.gtk_revealer_set_child(self.scan_revealer.?, card);
    return revealer;
}

fn showScanning(self: *App, visible: bool) void {
    if (self.scan_revealer) |revealer|
        gtk.gtk_revealer_set_reveal_child(revealer, if (visible) gtk.true_ else gtk.false_);
}

fn startScan(self: *App, root_id: ?i64) void {
    const library = self.library orelse return;
    const job = self.runtime.startLibraryScan(library, .{ .root_id = root_id }) catch {
        self.toast("Could not start the scan");
        return;
    };
    begin(self, .scan, job, "Scanning your music");
}

/// Walks every enabled root again. Unchanged files cost a stat each, so this
/// is how new and changed files are picked up until watching arrives.
pub fn rescan(self: *App) void {
    if (self.library == null or !idle(self)) return;
    startScan(self, null);
}

/// Measures the loudness ReplayGain plays by, and the fingerprints duplicate
/// finding compares. Hours on a large library, and stopping it keeps what is
/// done.
pub fn startAnalysis(self: *App) void {
    const library = self.library orelse return;
    if (!idle(self)) return;
    const job = self.runtime.startLibraryAnalysis(library, .{}) catch return self.toast("Could not start measuring");
    begin(self, .analysis, job, "Measuring loudness");
}

pub fn startDuplicates(self: *App) void {
    const library = self.library orelse return;
    if (!idle(self)) return;
    const job = self.runtime.startLibraryDuplicateScan(library, .{}) catch return self.toast("Could not look for duplicates");
    begin(self, .duplicates, job, "Finding duplicates");
}

/// Searches MusicBrainz, and AcoustID by fingerprint when that is on, for
/// every Track without a recording ID.
pub fn startMatching(self: *App) void {
    startMatchingJob(self, null);
}

/// Searches for one Track, if it has no recording ID and nothing
/// awaiting review.
pub fn startTrackMatching(self: *App, track_id: i64) void {
    startMatchingJob(self, track_id);
}

fn startMatchingJob(self: *App, track_id: ?i64) void {
    const library = self.library orelse return;
    if (!idle(self)) return;
    const job = self.runtime.startLibraryMatching(library, .{
        .track_id = track_id,
        .fingerprints = self.match_fingerprints,
    }) catch |err| return self.toast(switch (err) {
        error.MatchingAlreadyRunning => "Already finding matches",
        error.AcoustIdBusy => "Already submitting to AcoustID",
        else => "Could not start finding matches",
    });
    self.match_task_track = track_id;
    begin(self, .matching, job, "Finding matches");
    if (track_id != null) details.invalidate(self);
}

pub fn startSubmission(self: *App) void {
    const library = self.library orelse return;
    if (!idle(self)) return;
    const job = self.runtime.startAcoustIdSubmission(library) catch |err| return self.toast(switch (err) {
        error.AcoustIdBusy => "Already finding matches",
        else => "Could not start submitting to AcoustID",
    });
    begin(self, .submission, job, "Submitting");
}

/// Writes an approved plan. The plan id is its undo group.
pub fn startTagWrite(self: *App, plan_id: u64, digest: liborca.TagWriteDigest) void {
    const library = self.library orelse return;
    if (!idle(self)) return;
    const job = self.runtime.startTagWrite(library, plan_id, digest) catch |err| return self.toast(switch (err) {
        error.NoBackupDirectory => "This library has no database file to keep the originals beside",
        else => "Could not write the tags",
    });
    self.tag_write_group = plan_id;
    begin(self, .tag_write, job, "Writing tags");
}

fn folderChosen(
    source: ?*gtk.GObject,
    result: *gtk.GAsyncResult,
    data: ?*anyopaque,
) callconv(.c) void {
    const self = state(data);
    var err: ?*gtk.GError = null;
    const folder = gtk.gtk_file_dialog_select_folder_finish(
        gtk.cast(gtk.FileDialog, source),
        result,
        &err,
    ) orelse {
        gtk.g_clear_error(&err);
        return;
    };
    const raw_path = gtk.g_file_get_path(folder);
    gtk.g_object_unref(folder);
    const path_pointer = raw_path orelse {
        self.toast("That folder is not on the local filesystem");
        return;
    };
    defer gtk.g_free(path_pointer);
    const path = std.mem.span(path_pointer);
    const library = self.library orelse return;
    // Registering a root is the explicit user action the boundary reserves for
    // persisting a volume identity at a mount point.
    const binding = self.runtime.libraryAddRoot(library, self.io, path) catch {
        self.toast("Could not add that folder to the library");
        return;
    };
    startScan(self, binding.root_id);
}

pub fn chooseFolder(self: *App) void {
    if (self.library == null) {
        self.toast("No library is open");
        return;
    }
    if (!idle(self)) return;
    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_set_title(dialog, "Add Music Folder");
    gtk.gtk_file_dialog_select_folder(dialog, self.window, null, folderChosen, self);
    gtk.g_object_unref(dialog);
}

fn writeDetail(self: *App, task: app.Task, snapshot: liborca.JobSnapshot, stats: liborca.ScanStats) void {
    const label = self.scan_detail orelse return;
    var buffer: [160]u8 = undefined;
    const text = switch (task) {
        .scan => strings.printZ(&buffer, "{d} files · {d} new", .{ stats.files_seen, stats.changed }),
        .analysis, .duplicates, .tag_write => if (snapshot.total_units) |total|
            strings.printZ(&buffer, "{d} of {d} files", .{ snapshot.completed_units, total })
        else
            strings.printZ(&buffer, "{d} files", .{snapshot.completed_units}),
        .matching, .submission => return,
    } catch return;
    gtk.gtk_label_set_text(label, text.ptr);
}

fn writeMatchDetail(self: *App, snapshot: liborca.JobSnapshot, stats: liborca.MatchStats) void {
    const label = self.scan_detail orelse return;
    var buffer: [160]u8 = undefined;
    const text = strings.printZ(&buffer, "{f} of {f} songs · {f} matched", .{
        strings.grouped(snapshot.completed_units),
        strings.grouped(snapshot.total_units orelse snapshot.completed_units),
        strings.grouped(stats.matched),
    }) catch return;
    gtk.gtk_label_set_text(label, text.ptr);
}

fn writeSubmissionDetail(self: *App, snapshot: liborca.JobSnapshot, stats: liborca.SubmissionStats) void {
    const label = self.scan_detail orelse return;
    var buffer: [160]u8 = undefined;
    const text = strings.printZ(&buffer, "{f} of {f} songs", .{
        strings.grouped(stats.files_examined),
        strings.grouped(snapshot.total_units orelse stats.files_examined),
    }) catch return;
    gtk.gtk_label_set_text(label, text.ptr);
}

fn undoClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    tags.undoLastWrite(state(data));
}

fn matchingFinished(self: *App, state_value: liborca.JobState, stats: ?liborca.MatchStats) void {
    const searched = self.match_task_track;
    self.match_task_track = null;
    const matched = if (stats) |value| value.matched else 0;
    if (searched) |track_id| self.unmatched_track = if (state_value == .succeeded and matched == 0) track_id else null;
    matches.reload(self);
    details.invalidate(self);
    if (state_value == .cancelled) return self.toast("Stopped");
    if (state_value != .succeeded) return self.toast("MusicBrainz or AcoustID could not be reached; Find Matches continues where it stopped");
    if (searched != null) return self.toast(if (matched == 0) "No match found" else "Found a match to review");
    var buffer: [96]u8 = undefined;
    self.toast(if (matched == 0)
        "No new matches found"
    else
        strings.printZ(&buffer, "Found matches for {f} {s}", .{ strings.grouped(matched), if (matched == 1) "song" else "songs" }) catch "Found matches");
}

fn submissionFinished(self: *App, state_value: liborca.JobState, stats: ?liborca.SubmissionStats) void {
    matches.reload(self);
    if (state_value == .cancelled) return self.toast("Stopped");
    const result = stats orelse return self.toast("AcoustID could not be reached; try again later");
    if (state_value != .succeeded) return self.toast(switch (result.outcome) {
        .needs_user_key => "Save your AcoustID key in Preferences first",
        .invalid_user_key => "AcoustID did not accept your key",
        .cancelled => "Stopped",
        .completed, .needs_client_key, .invalid_client_key, .unavailable => "AcoustID could not be reached; try again later",
    });
    var buffer: [64]u8 = undefined;
    self.toast(strings.printZ(&buffer, "Submitted {f} {s} to AcoustID", .{
        strings.grouped(result.submitted),
        if (result.submitted == 1) "song" else "songs",
    }) catch "Submitted to AcoustID");
}

fn finished(
    self: *App,
    task: app.Task,
    state_value: liborca.JobState,
    stats: ?liborca.ScanStats,
    match_stats: ?liborca.MatchStats,
    submission_stats: ?liborca.SubmissionStats,
) void {
    if (task == .matching) return matchingFinished(self, state_value, match_stats);
    if (task == .submission) return submissionFinished(self, state_value, submission_stats);
    var buffer: [160]u8 = undefined;
    if (state_value == .cancelled) return self.toast("Stopped");
    if (state_value != .succeeded) return self.toast(switch (task) {
        .scan => "The scan failed",
        .analysis => "Measuring stopped with an error",
        .duplicates => "Looking for duplicates failed",
        .tag_write => "Writing tags failed; the files were left as they were",
        .matching, .submission => unreachable,
    });
    switch (task) {
        .scan => {
            reloadLibraryViews(self);
            const found = if (stats) |value| value.changed else 0;
            self.toast(if (found == 0)
                "Your library is up to date"
            else
                strings.printZ(&buffer, "{d} new or changed files added", .{found}) catch "Scan complete");
        },
        .analysis => {
            const measured = if (stats) |value| value.changed + value.unchanged else 0;
            self.toast(strings.printZ(&buffer, "Analysed {d} {s}", .{ measured, if (measured == 1) "file" else "files" }) catch "Analysed");
        },
        .duplicates => {
            health.reload(self);
            const found = if (stats) |value| value.tracks_written + value.releases_written else 0;
            self.toast(if (found == 0)
                "No duplicates found"
            else
                strings.printZ(&buffer, "Found {d} duplicate files", .{found}) catch "Found duplicates");
        },
        .tag_write => {
            reloadLibraryViews(self);
            const written = if (stats) |value| value.changed else 0;
            const overlay = self.toasts orelse return;
            const text = strings.printZ(&buffer, "Wrote tags to {d} {s}", .{ written, if (written == 1) "file" else "files" }) catch "Wrote tags";
            const item = adw.adw_toast_new(text.ptr);
            adw.adw_toast_set_timeout(item, 8);
            adw.adw_toast_set_button_label(item, "Undo");
            _ = gtk.signalConnect(item, "button-clicked", gtk.callback(undoClicked), self);
            adw.adw_toast_overlay_add_toast(overlay, item);
        },
        .matching, .submission => unreachable,
    }
}

pub fn tick(self: *App) void {
    const task = self.task orelse return;
    const job = self.task_job orelse return;
    const snapshot = self.runtime.jobSnapshotSynced(job) catch {
        self.task = null;
        self.task_job = null;
        self.match_task_track = null;
        self.shown_matched = 0;
        showScanning(self, false);
        return;
    };
    const stats: ?liborca.ScanStats = switch (task) {
        .matching, .submission => null,
        else => self.runtime.jobScanStats(job) catch null,
    };
    const match_stats: ?liborca.MatchStats = if (task == .matching) self.runtime.jobMatchStats(job) catch null else null;
    const submission_stats: ?liborca.SubmissionStats = if (task == .submission) self.runtime.jobSubmissionStats(job) catch null else null;
    if (submission_stats) |value| writeSubmissionDetail(self, snapshot, value);
    if (stats) |value| {
        writeDetail(self, task, snapshot, value);
        if (task == .scan and self.loaded_rows == 0 and value.tracks_written != 0) reloadLibraryViews(self);
    }
    if (match_stats) |value| {
        writeMatchDetail(self, snapshot, value);
        if (value.matched != self.shown_matched) {
            self.shown_matched = value.matched;
            matches.updateCount(self);
        }
    }
    switch (snapshot.state) {
        .succeeded, .failed, .cancelled => {},
        else => return,
    }
    self.task = null;
    self.task_job = null;
    self.shown_matched = 0;
    showScanning(self, false);
    finished(self, task, snapshot.state, stats, match_stats, submission_stats);
    self.updateTracksBody();
}
