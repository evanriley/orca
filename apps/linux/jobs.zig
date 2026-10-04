//! Background jobs — scans, loudness analysis, duplicate finding, tag writes,
//! matching and AcoustID submission — and the activity widget at the foot of
//! the sidebar, whose popover holds the task's detail and its Stop button.
//! One runs at a time from this frontend, so the widget always describes the
//! job there is.
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
const playlists = @import("playlists.zig");
const loved = @import("loved.zig");
const genres = @import("genres.zig");
const folders = @import("folders.zig");
const art = @import("art.zig");
const preferences = @import("preferences.zig");
const track_table = @import("track_table.zig");
const window = @import("window.zig");

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
    showActivity(self, .{ .kind = .scan, .state = .queued, .completed_units = 0, .total_units = null });
    health.updateBanner(self);
    self.updateTracksBody();
    self.requestTick();
}

/// Everything shown from the library, rebuilt after its contents changed.
pub fn reloadLibraryViews(self: *App) void {
    self.shown_playing = .{};
    browse.reload(self);
    self.reload();
    albums.reload(self);
    artists.reload(self);
    health.reload(self);
    matches.reload(self);
    playlists.refresh(self);
    playlists.reloadPage(self, true);
    loved.reload(self);
    genres.invalidate(self);
    folders.invalidate(self);
    preferences.refreshLibrary(self);
    window.refreshCounts(self);
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

    const popover = gtk.gtk_popover_new();
    self.activity_popover = gtk.cast(gtk.Popover, popover);
    gtk.gtk_popover_set_child(self.activity_popover.?, card);
    gtk.gtk_popover_set_position(self.activity_popover.?, gtk.POS_TOP);

    const summary = gtk.gtk_label_new("1 task running");
    self.activity_label = gtk.cast(gtk.Label, summary);
    gtk.gtk_label_set_xalign(self.activity_label.?, 0.0);
    gtk.gtk_label_set_ellipsize(self.activity_label.?, gtk.ELLIPSIZE_END);
    gtk.gtk_widget_set_hexpand(summary, gtk.true_);
    const percent = gtk.gtk_label_new("");
    self.activity_percent = gtk.cast(gtk.Label, percent);
    gtk.gtk_widget_add_css_class(percent, "numeric");
    const line = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_box_append(gtk.cast(gtk.Box, line), summary);
    gtk.gtk_box_append(gtk.cast(gtk.Box, line), percent);
    const bar = gtk.gtk_progress_bar_new();
    self.activity_bar = gtk.cast(gtk.ProgressBar, bar);
    gtk.gtk_progress_bar_set_pulse_step(self.activity_bar.?, 0.08);
    gtk.gtk_widget_add_css_class(bar, "activity-bar");
    const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 7);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), line);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), bar);
    const button = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_child(gtk.cast(gtk.MenuButton, button), body);
    gtk.gtk_menu_button_set_popover(gtk.cast(gtk.MenuButton, button), popover);
    gtk.gtk_widget_set_tooltip_text(button, "Show the running task");
    gtk.gtk_widget_add_css_class(button, "activity");

    const revealer = gtk.gtk_revealer_new();
    self.scan_revealer = gtk.cast(gtk.Revealer, revealer);
    gtk.gtk_revealer_set_transition_type(self.scan_revealer.?, gtk.REVEALER_TRANSITION_SLIDE_UP);
    gtk.gtk_revealer_set_child(self.scan_revealer.?, button);
    return revealer;
}

fn showActivity(self: *App, snapshot: liborca.JobSnapshot) void {
    const waiting = snapshot.state == .queued;
    if (self.activity_label) |label|
        gtk.gtk_label_set_text(label, if (waiting) "1 task waiting" else "1 task running");
    const total = snapshot.total_units orelse 0;
    var buffer: [8]u8 = undefined;
    if (!waiting and total != 0) {
        const done = @min(snapshot.completed_units, total);
        const text: [:0]const u8 = strings.printZ(&buffer, "{d}%", .{done * 100 / total}) catch "";
        if (self.activity_percent) |label| gtk.gtk_label_set_text(label, text.ptr);
        if (self.activity_bar) |bar|
            gtk.gtk_progress_bar_set_fraction(bar, @as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(total)));
        return;
    }
    if (self.activity_percent) |label| gtk.gtk_label_set_text(label, "");
    if (self.activity_bar) |bar| {
        if (waiting) gtk.gtk_progress_bar_set_fraction(bar, 0) else gtk.gtk_progress_bar_pulse(bar);
    }
}

fn showScanning(self: *App, visible: bool) void {
    if (!visible) if (self.activity_popover) |popover| gtk.gtk_popover_popdown(popover);
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

/// Walks every enabled root again. Unchanged files cost a stat each; this
/// finds whatever watching did not, and everything when watching is off.
pub fn rescan(self: *App) void {
    if (self.library == null or !idle(self)) return;
    startScan(self, null);
}

pub fn rescanRoot(self: *App, root_id: i64) void {
    if (self.library == null or !idle(self)) return;
    startScan(self, root_id);
}

/// Measures the loudness ReplayGain plays by, and the fingerprints duplicate
/// finding compares. Hours on a large library, and stopping it keeps what is
/// done.
pub fn startAnalysis(self: *App) void {
    const library = self.library orelse return;
    if (!idle(self)) return;
    const job = self.runtime.startLibraryAnalysis(library, .{ .threads = self.analysis_threads }) catch return self.toast("Could not start measuring");
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
    }) catch |err| return self.toast(matchingRefusal(err));
    self.match_task_track = track_id;
    self.match_task_mode = .search;
    begin(self, .matching, job, "Finding matches");
    if (track_id != null) details.invalidate(self);
}

const MatchTarget = union(enum) { track: i64, release: i64, library };

pub fn startLibraryVerification(self: *App) void {
    startIdentificationJob(self, .verify, .library);
}

pub fn startTrackVerification(self: *App, track_id: i64) void {
    startIdentificationJob(self, .verify, .{ .track = track_id });
}

pub fn startAlbumVerification(self: *App, release_id: i64) void {
    startIdentificationJob(self, .verify, .{ .release = release_id });
}

pub fn startTrackReidentification(self: *App, track_id: i64) void {
    startIdentificationJob(self, .reidentify, .{ .track = track_id });
}

pub fn startAlbumReidentification(self: *App, release_id: i64) void {
    startIdentificationJob(self, .reidentify, .{ .release = release_id });
}

fn startIdentificationJob(self: *App, mode: liborca.MatchMode, target: MatchTarget) void {
    const library = self.library orelse return;
    if (!idle(self)) return;
    const track_id: ?i64 = switch (target) {
        .track => |id| id,
        .release, .library => null,
    };
    const job = self.runtime.startLibraryMatching(library, .{
        .mode = mode,
        .track_id = track_id,
        .release_id = switch (target) {
            .track, .library => null,
            .release => |id| id,
        },
        .fingerprints = self.match_fingerprints,
        .accept_minimum_confidence = null,
        .cover_art = false,
    }) catch |err| return self.toast(matchingRefusal(err));
    self.match_task_track = track_id;
    self.match_task_mode = mode;
    begin(self, .matching, job, switch (mode) {
        .verify => "Verifying",
        .reidentify => "Re-identifying",
        .search => unreachable,
    });
    if (track_id != null) details.invalidate(self);
}

/// Searches for an album's Tracks, accepts their matches at the review
/// threshold, and fetches the album's cover when it has none.
pub fn startAlbumMatching(self: *App, release_id: i64) void {
    const library = self.library orelse return;
    if (!idle(self)) return;
    const job = self.runtime.startLibraryMatching(library, .{
        .release_id = release_id,
        .fingerprints = self.match_fingerprints,
        .accept_minimum_confidence = matches.thresholdFraction(self),
        .cover_art = true,
    }) catch |err| return self.toast(matchingRefusal(err));
    self.match_task_release = release_id;
    self.match_task_mode = .search;
    begin(self, .matching, job, "Matching album");
}

pub fn startCoverArtFetch(self: *App, release_id: i64) void {
    const library = self.library orelse return;
    if (!idle(self)) return;
    const job = self.runtime.startReleaseCoverArtFetch(library, release_id) catch |err| return self.toast(matchingRefusal(err));
    self.match_task_release = release_id;
    self.match_task_mode = .search;
    begin(self, .matching, job, "Fetching cover art");
}

const acoustid_required = "Verify needs AcoustID: turn on Match by audio fingerprint in Settings";

fn matchingRefusal(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.MatchingAlreadyRunning => "Already finding matches",
        error.AcoustIdBusy => "Already submitting to AcoustID",
        error.AcoustIdRequired => acoustid_required,
        error.InvalidMatchRequest => "That search cannot run on this selection",
        else => "Could not start finding matches",
    };
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
        error.MutationInProgress => "Another Orca is writing tags",
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
    preferences.refreshLibrary(self);
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
    if (self.match_task_release != null and snapshot.completed_units == (snapshot.total_units orelse 0))
        return gtk.gtk_label_set_text(label, "Cover Art Archive");
    var buffer: [160]u8 = undefined;
    const text = strings.printZ(&buffer, "{f} of {f} tracks · {f} {s}", .{
        strings.grouped(snapshot.completed_units),
        strings.grouped(snapshot.total_units orelse snapshot.completed_units),
        strings.grouped(if (self.match_task_mode == .verify) stats.verified else stats.matched),
        if (self.match_task_mode == .verify) "verified" else "matched",
    }) catch return;
    gtk.gtk_label_set_text(label, text.ptr);
}

fn writeSubmissionDetail(self: *App, snapshot: liborca.JobSnapshot, stats: liborca.SubmissionStats) void {
    const label = self.scan_detail orelse return;
    var buffer: [160]u8 = undefined;
    const text = strings.printZ(&buffer, "{f} of {f} tracks", .{
        strings.grouped(stats.files_examined),
        strings.grouped(snapshot.total_units orelse stats.files_examined),
    }) catch return;
    gtk.gtk_label_set_text(label, text.ptr);
}

fn undoClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    tags.undoLastWrite(state(data));
}

fn albumAccepted(self: *App, release_id: i64) void {
    matches.reload(self);
    health.reload(self);
    albums.releaseChanged(self, release_id);
    artists.reloadKeepingScroll(self);
    loved.releaseChanged(self, release_id);
    track_table.refreshRelease(&self.tracks, release_id);
    track_table.refreshRelease(&self.playlists.tracks, release_id);
    self.genres.stale = true;
    self.folders.stale = true;
}

fn albumMoved(self: *App, old_id: i64, new_id: i64) void {
    matches.reload(self);
    health.reload(self);
    self.shown_playing = .{};
    if (self.now_playing.release_id) |shown| {
        if (shown == old_id) self.now_playing.release_id = new_id;
    }
    window.releaseMoved(self, old_id, new_id);
    details.releaseMoved(self, old_id, new_id);
    albums.releaseMoved(self, old_id, new_id);
    artists.reloadKeepingScroll(self);
    loved.releaseMoved(self, old_id, new_id);
    for ([_]i64{ old_id, new_id }) |release_id| {
        track_table.refreshRelease(&self.tracks, release_id);
        track_table.refreshRelease(&self.playlists.tracks, release_id);
    }
    albums.markPlaying(self, self.shown_track_id);
    artists.markPlaying(self, self.shown_track_id);
    self.genres.stale = true;
    self.folders.stale = true;
}

fn albumFinished(self: *App, release_id: i64, moved_to: ?i64, state_value: liborca.JobState, stats: ?liborca.MatchStats) void {
    art.refreshRelease(self, release_id);
    if (moved_to) |new_id| {
        art.refreshRelease(self, new_id);
        albumMoved(self, release_id, new_id);
    } else if (stats) |result| {
        if (result.accepted != 0) albumAccepted(self, release_id) else if (result.matched != 0) matches.reload(self);
    }
    details.invalidate(self);
    self.requestTick();
    if (state_value == .cancelled) return self.toast("Stopped");
    const result = stats orelse return self.toast("Could not match the album");
    if (state_value != .succeeded) return self.toast(switch (result.cover_art) {
        .refused => "The Cover Art Archive's answer was refused",
        .unavailable => "The Cover Art Archive could not be reached; try again later",
        .busy => "The Cover Art Archive is in use by another Orca process; try again once it finishes",
        else => switch (result.busy) {
            .musicbrainz => "MusicBrainz is in use by another Orca process; try again once it finishes",
            .acoustid => "AcoustID is in use by another Orca process; try again once it finishes",
            .none => "MusicBrainz or AcoustID could not be reached; try again later",
        },
    });
    const cover: [:0]const u8 = switch (result.cover_art) {
        .no_release_id => "No release ID — review matches, then Fetch Cover Art",
        .fetched => "Found the album's cover",
        .embedded => "The album's files already carry a cover",
        .folder => "The album's folder already has a cover",
        .cached => "The album's cover was already fetched",
        .cached_miss, .not_found => "The Cover Art Archive has no cover for this album",
        .not_requested, .refused, .unavailable, .busy, .cancelled => "Done",
    };
    if (result.accepted == 0) return self.toast(cover);
    var buffer: [160]u8 = undefined;
    self.toast(strings.printZ(&buffer, "Accepted {f} {s} · {s}", .{
        strings.grouped(result.accepted),
        if (result.accepted == 1) "match" else "matches",
        cover,
    }) catch cover);
}

fn unreachableText(busy: liborca.BusyService) [:0]const u8 {
    return switch (busy) {
        .musicbrainz => "MusicBrainz is in use by another Orca process; try again once it finishes",
        .acoustid => "AcoustID is in use by another Orca process; try again once it finishes",
        .none => "MusicBrainz or AcoustID could not be reached; try again later",
    };
}

fn verificationFinished(self: *App, track_id: ?i64, state_value: liborca.JobState, stats: ?liborca.MatchStats) void {
    if (state_value == .cancelled) return self.toast("Stopped");
    const result = stats orelse return self.toast("Could not verify");
    if (state_value != .succeeded) return self.toast(switch (result.acoustid) {
        .searched => unreachableText(result.busy),
        .off, .no_client_key => acoustid_required,
        .invalid_client_key => "AcoustID did not accept Orca's application key",
    });
    if (result.correction_groups != 0) return self.toast("Found an album correction to review");
    if (track_id != null) return self.toast(if (result.disagreed != 0)
        "AcoustID hears a different recording — review it in Matches"
    else if (result.agreed != 0)
        "AcoustID agrees with this track's recording"
    else if (result.unconfirmed != 0)
        "AcoustID could not confirm this track"
    else if (result.verified == 0)
        "Nothing to verify: the track has no recording ID, or its verification is current"
    else
        "Could not fingerprint this track");
    var buffer: [96]u8 = undefined;
    self.toast(strings.printZ(&buffer, "Verified {f} {s} · {f} disagree", .{
        strings.grouped(result.verified),
        if (result.verified == 1) "track" else "tracks",
        strings.grouped(result.disagreed),
    }) catch "Verified");
}

fn reidentificationFinished(self: *App, state_value: liborca.JobState, stats: ?liborca.MatchStats) void {
    if (state_value == .cancelled) return self.toast("Stopped");
    const result = stats orelse return self.toast("Could not search again");
    if (state_value != .succeeded) return self.toast(unreachableText(result.busy));
    if (result.matched == 0) return self.toast(if (result.confirmed != 0) "Confirmed the current recording" else "No match found");
    var buffer: [64]u8 = undefined;
    self.toast(if (result.matched == 1)
        "Found a match to review"
    else
        strings.printZ(&buffer, "Found {f} matches to review", .{strings.grouped(result.matched)}) catch "Found matches to review");
}

fn matchingFinished(self: *App, state_value: liborca.JobState, stats: ?liborca.MatchStats, match_release: ?i64) void {
    const mode = self.match_task_mode;
    self.match_task_mode = .search;
    if (mode != .search) {
        const track_id = self.match_task_track;
        self.match_task_track = null;
        matches.reload(self);
        details.invalidate(self);
        return switch (mode) {
            .verify => verificationFinished(self, track_id, state_value, stats),
            .reidentify => reidentificationFinished(self, state_value, stats),
            .search => unreachable,
        };
    }
    if (self.match_task_release) |release_id| {
        self.match_task_release = null;
        const moved_to = if (match_release) |found| (if (found != release_id) found else null) else null;
        return albumFinished(self, release_id, moved_to, state_value, stats);
    }
    const searched = self.match_task_track;
    self.match_task_track = null;
    const matched = if (stats) |value| value.matched else 0;
    if (searched) |track_id| self.unmatched_track = if (state_value == .succeeded and matched == 0) track_id else null;
    matches.reload(self);
    details.invalidate(self);
    if (state_value == .cancelled) return self.toast("Stopped");
    if (state_value != .succeeded) return self.toast(switch (if (stats) |value| value.busy else .none) {
        .musicbrainz => "MusicBrainz is in use by another Orca process; try again once it finishes",
        .acoustid => "AcoustID is in use by another Orca process; try again once it finishes",
        .none => "MusicBrainz or AcoustID could not be reached; Find Matches continues where it stopped",
    });
    if (searched != null) return self.toast(if (matched == 0) "No match found" else "Found a match to review");
    var buffer: [96]u8 = undefined;
    self.toast(if (matched == 0)
        "No new matches found"
    else
        strings.printZ(&buffer, "Found matches for {f} {s}", .{ strings.grouped(matched), if (matched == 1) "track" else "tracks" }) catch "Found matches");
}

fn submissionFinished(self: *App, state_value: liborca.JobState, stats: ?liborca.SubmissionStats) void {
    matches.reload(self);
    if (state_value == .cancelled) return self.toast("Stopped");
    const result = stats orelse return self.toast("AcoustID could not be reached; try again later");
    if (state_value != .succeeded) return self.toast(switch (result.outcome) {
        .needs_user_key => "Save your AcoustID key in Settings first",
        .invalid_user_key => "AcoustID did not accept your key",
        .cancelled => "Stopped",
        .busy => "AcoustID is in use by another Orca process; try again once it finishes",
        .completed, .needs_client_key, .invalid_client_key, .unavailable => "AcoustID could not be reached; try again later",
    });
    var buffer: [64]u8 = undefined;
    self.toast(strings.printZ(&buffer, "Submitted {f} {s} to AcoustID", .{
        strings.grouped(result.submitted),
        if (result.submitted == 1) "track" else "tracks",
    }) catch "Submitted to AcoustID");
}

fn finished(
    self: *App,
    task: app.Task,
    state_value: liborca.JobState,
    stats: ?liborca.ScanStats,
    match_stats: ?liborca.MatchStats,
    match_release: ?i64,
    submission_stats: ?liborca.SubmissionStats,
    tag_write_failure: ?liborca.TagWriteFailure,
) void {
    if (task == .matching) return matchingFinished(self, state_value, match_stats, match_release);
    if (task == .submission) return submissionFinished(self, state_value, submission_stats);
    var buffer: [160]u8 = undefined;
    if (state_value == .cancelled) return self.toast("Stopped");
    if (state_value != .succeeded) return self.toast(switch (task) {
        .scan => "The scan failed",
        .analysis => "Measuring stopped with an error",
        .duplicates => "Looking for duplicates failed",
        .tag_write => tagWriteFailedText(tag_write_failure),
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
            preferences.refreshLibrary(self);
            const measured = if (stats) |value| value.changed + value.unchanged else 0;
            self.toast(strings.printZ(&buffer, "Analysed {d} {s}", .{ measured, if (measured == 1) "file" else "files" }) catch "Analysed");
        },
        .duplicates => {
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

fn tagWriteFailedText(failure: ?liborca.TagWriteFailure) [:0]const u8 {
    const known = failure orelse return "Writing tags failed; the files were left as they were";
    return switch (known.reason) {
        .permission_denied => "Writing tags failed: Orca has no permission to create files there. The files were left as they were.",
        .read_only_file_system => "Writing tags failed: the drive is read-only. The files were left as they were.",
        .no_space => "Writing tags failed: the drive is full. The files were left as they were.",
        .changed_since_plan => "Writing tags failed: a file changed after the write was planned. The files were left as they were.",
        .other => "Writing tags failed; the files were left as they were",
    };
}

pub fn tick(self: *App) void {
    const task = self.task orelse return;
    const job = self.task_job orelse return;
    const snapshot = self.runtime.jobSnapshotSynced(job) catch {
        self.task = null;
        self.task_job = null;
        self.match_task_track = null;
        self.match_task_release = null;
        self.match_task_mode = .search;
        self.shown_matched = 0;
        self.health.then_duplicates = false;
        showScanning(self, false);
        health.updateBanner(self);
        return;
    };
    showActivity(self, snapshot);
    if (snapshot.state == .queued) return;
    const stats: ?liborca.ScanStats = switch (task) {
        .matching, .submission => null,
        else => self.runtime.jobScanStats(job) catch null,
    };
    const match_stats: ?liborca.MatchStats = if (task == .matching) self.runtime.jobMatchStats(job) catch null else null;
    const submission_stats: ?liborca.SubmissionStats = if (task == .submission) self.runtime.jobSubmissionStats(job) catch null else null;
    const tag_write_failure: ?liborca.TagWriteFailure = if (task == .tag_write and snapshot.state == .failed) self.runtime.jobTagWriteFailure(job) catch null else null;
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
    const match_release: ?i64 = if (task == .matching) self.runtime.jobMatchRelease(job) catch null else null;
    self.task = null;
    self.task_job = null;
    self.shown_matched = 0;
    showScanning(self, false);
    finished(self, task, snapshot.state, stats, match_stats, match_release, submission_stats, tag_write_failure);
    switch (task) {
        .analysis, .duplicates, .matching => health.reload(self),
        .scan, .tag_write, .submission => health.updateBanner(self),
    }
    if (task == .analysis) health.analysisEnded(self, snapshot.state);
    self.updateTracksBody();
}
