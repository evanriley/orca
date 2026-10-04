//! Background jobs — scans, loudness analysis, duplicate finding, tag writes,
//! matching and AcoustID submission — started from this frontend, and what
//! each reports when it ends. A Job started while another holds the
//! Library's slot waits its turn in liborca; the Activity page and the
//! sidebar widget (`activity.zig`) show both.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const activity = @import("activity.zig");
const notify = @import("notify.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const browse = @import("browse.zig");
const albums = @import("albums.zig");
const artists = @import("artists.zig");
const artist_page = @import("artist_page.zig");
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

fn begin(self: *App, tracked: app.TrackedTask) void {
    if (self.task_count < self.tasks.len) {
        self.tasks[self.task_count] = tracked;
        self.task_count += 1;
    }
    activity.refresh(self);
    health.updateBanner(self);
    self.updateTracksBody();
    self.requestTick();
}

/// Whether a `task` this frontend started is running or waiting.
pub fn active(self: *const App, task: app.Task) bool {
    for (self.tasks[0..self.task_count]) |tracked| {
        if (tracked.task == task) return true;
    }
    return false;
}

/// Whether a running or waiting matching Job searches, or with `verify`
/// verifies, this one Track.
pub fn matchingTrack(self: *const App, track_id: i64, verify: bool) bool {
    for (self.tasks[0..self.task_count]) |tracked| {
        if (tracked.task != .matching or tracked.match_track != track_id) continue;
        if ((tracked.match_mode == .verify) == verify) return true;
    }
    return false;
}

fn queueRefusal(err: anyerror, fallback: [:0]const u8) [:0]const u8 {
    return switch (err) {
        error.JobQueueFull => "Too many tasks are waiting; try again when some have finished",
        else => fallback,
    };
}

/// Starts a failed or stopped Job's request again from its history row.
pub fn retry(self: *App, history_id: i64) void {
    const library = self.library orelse return;
    const job = self.runtime.jobRetry(library, history_id) catch |err| return self.toast(switch (err) {
        error.JobNotRetryable, error.UnknownJobHistory => "This task cannot be run again",
        error.JobQueueFull => queueRefusal(err, ""),
        else => matchingRefusal(err),
    });
    const snapshot = self.runtime.jobSnapshotSynced(job) catch return activity.refresh(self);
    const task: app.Task = switch (snapshot.kind) {
        .scan, .reconcile => .scan,
        .analysis => .analysis,
        .duplicate_scan => .duplicates,
        .metadata_lookup => .matching,
        .acoustid_submission => .submission,
        else => {
            activity.refresh(self);
            return self.requestTick();
        },
    };
    begin(self, .{ .task = task, .job = job });
}

/// Everything shown from the library, rebuilt after its contents changed.
pub fn reloadLibraryViews(self: *App) void {
    self.shown_playing = .{};
    browse.reload(self);
    self.track_library_total = null;
    self.reload();
    albums.reload(self);
    artists.reload(self);
    health.reload(self);
    matches.invalidate(self);
    playlists.refresh(self);
    playlists.reloadPage(self, true);
    loved.reload(self);
    genres.invalidate(self);
    folders.invalidate(self);
    preferences.refreshLibrary(self);
    window.refreshCounts(self);
}

fn startScan(self: *App, root_id: ?i64) ?liborca.JobHandle {
    const library = self.library orelse return null;
    const job = self.runtime.startLibraryScan(library, .{ .root_id = root_id }) catch |err| {
        self.toast(queueRefusal(err, "Could not start the scan"));
        return null;
    };
    begin(self, .{ .task = .scan, .job = job });
    return job;
}

/// Scans every enabled root, returning the Job so First Run can follow it.
pub fn scanLibrary(self: *App) ?liborca.JobHandle {
    return startScan(self, null);
}

/// Walks every enabled root again. Unchanged files cost a stat each; this
/// finds whatever watching did not, and everything when watching is off.
pub fn rescan(self: *App) void {
    if (self.library == null) return;
    _ = startScan(self, null);
}

pub fn rescanRoot(self: *App, root_id: i64) void {
    if (self.library == null) return;
    _ = startScan(self, root_id);
}

pub fn rescanFolder(self: *App, root_id: i64, path: []const u8) void {
    const library = self.library orelse return;
    const job = self.runtime.startLibraryReconcile(library, .{
        .root_id = root_id,
        .scope = if (path.len == 0) .whole_root else .{ .subtrees = &.{path} },
    }) catch |err| return self.toast(queueRefusal(err, "Could not start the scan"));
    begin(self, .{ .task = .scan, .job = job });
}

/// Measures the loudness ReplayGain plays by, and the fingerprints duplicate
/// finding compares. Hours on a large library, and stopping it keeps what is
/// done.
pub fn startAnalysis(self: *App) void {
    _ = analyzeLibrary(self);
}

/// `startAnalysis`, returning the Job so First Run can follow it.
pub fn analyzeLibrary(self: *App) ?liborca.JobHandle {
    const library = self.library orelse return null;
    const job = self.runtime.startLibraryAnalysis(library, .{ .threads = self.analysis_threads }) catch |err| {
        self.toast(queueRefusal(err, "Could not start measuring"));
        return null;
    };
    begin(self, .{ .task = .analysis, .job = job });
    return job;
}

pub fn startDuplicates(self: *App) void {
    const library = self.library orelse return;
    const job = self.runtime.startLibraryDuplicateScan(library, .{}) catch |err|
        return self.toast(queueRefusal(err, "Could not look for duplicates"));
    begin(self, .{ .task = .duplicates, .job = job });
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
    const job = self.runtime.startLibraryMatching(library, .{
        .track_id = track_id,
        .fingerprints = self.match_fingerprints,
    }) catch |err| return self.toast(matchingRefusal(err));
    begin(self, .{ .task = .matching, .job = job, .match_track = track_id });
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
    begin(self, .{ .task = .matching, .job = job, .match_track = track_id, .match_mode = mode });
    if (track_id != null) details.invalidate(self);
}

/// Searches for an album's Tracks, accepts their matches at the review
/// threshold, and fetches the album's cover when it has none.
pub fn startAlbumMatching(self: *App, release_id: i64) void {
    const library = self.library orelse return;
    const job = self.runtime.startLibraryMatching(library, .{
        .release_id = release_id,
        .fingerprints = self.match_fingerprints,
        .accept_minimum_confidence = matches.thresholdFraction(self),
        .cover_art = true,
    }) catch |err| return self.toast(matchingRefusal(err));
    begin(self, .{ .task = .matching, .job = job, .match_release = release_id });
}

pub fn startCoverArtFetch(self: *App, release_id: i64) void {
    const library = self.library orelse return;
    const job = self.runtime.startReleaseCoverArtFetch(library, release_id) catch |err| return self.toast(matchingRefusal(err));
    begin(self, .{ .task = .matching, .job = job, .match_release = release_id });
}

const acoustid_required = "Verify needs AcoustID: turn on Match by audio fingerprint in Settings";

fn matchingRefusal(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.MatchingAlreadyRunning => "Already finding matches",
        error.AcoustIdBusy => "Already submitting to AcoustID",
        error.AcoustIdRequired => acoustid_required,
        error.InvalidMatchRequest => "That search cannot run on this selection",
        error.JobQueueFull => queueRefusal(err, ""),
        else => "Could not start finding matches",
    };
}

pub fn startSubmission(self: *App) void {
    const library = self.library orelse return;
    const job = self.runtime.startAcoustIdSubmission(library) catch |err| return self.toast(switch (err) {
        error.AcoustIdBusy => "Already finding matches",
        else => queueRefusal(err, "Could not start submitting to AcoustID"),
    });
    begin(self, .{ .task = .submission, .job = job });
}

/// Writes an approved plan. The plan id is its undo group.
pub fn startTagWrite(self: *App, plan_id: u64, digest: liborca.TagWriteDigest) void {
    const library = self.library orelse return;
    const job = self.runtime.startTagWrite(library, plan_id, digest) catch |err| return self.toast(switch (err) {
        error.NoBackupDirectory => "This library has no database file to keep the originals beside",
        error.MutationInProgress => "Another Orca is writing tags",
        else => queueRefusal(err, "Could not write the tags"),
    });
    begin(self, .{ .task = .tag_write, .job = job, .tag_write_group = plan_id });
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
    _ = startScan(self, binding.root_id);
}

pub fn chooseFolder(self: *App) void {
    if (self.library == null) {
        self.toast("No library is open");
        return;
    }
    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_set_title(dialog, "Add Music Folder");
    gtk.gtk_file_dialog_select_folder(dialog, self.window, null, folderChosen, self);
    gtk.g_object_unref(dialog);
}

fn undoClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    tags.undoLastWrite(state(data));
}

fn albumAccepted(self: *App, release_id: i64) void {
    matches.invalidate(self);
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
    matches.invalidate(self);
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
    artist_page.markPlaying(self, self.shown_track_id);
    self.genres.stale = true;
    self.folders.stale = true;
}

fn albumFinished(self: *App, release_id: i64, moved_to: ?i64, state_value: liborca.JobState, stats: ?liborca.MatchStats) void {
    art.refreshRelease(self, release_id);
    if (moved_to) |new_id| {
        art.refreshRelease(self, new_id);
        albumMoved(self, release_id, new_id);
    } else if (stats) |result| {
        if (result.accepted != 0) albumAccepted(self, release_id) else if (result.matched != 0) matches.invalidate(self);
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

fn matchingFinished(self: *App, tracked: app.TrackedTask, state_value: liborca.JobState, stats: ?liborca.MatchStats, match_release: ?i64) void {
    const mode = tracked.match_mode;
    if (mode != .search) {
        const track_id = tracked.match_track;
        matches.invalidate(self);
        details.invalidate(self);
        return switch (mode) {
            .verify => verificationFinished(self, track_id, state_value, stats),
            .reidentify => reidentificationFinished(self, state_value, stats),
            .search => unreachable,
        };
    }
    if (tracked.match_release) |release_id| {
        const moved_to = if (match_release) |found| (if (found != release_id) found else null) else null;
        return albumFinished(self, release_id, moved_to, state_value, stats);
    }
    const searched = tracked.match_track;
    const matched = if (stats) |value| value.matched else 0;
    if (searched) |track_id| self.unmatched_track = if (state_value == .succeeded and matched == 0) track_id else null;
    matches.invalidate(self);
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
    matches.invalidate(self);
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

fn report(self: *App, text: [:0]const u8) void {
    self.toast(text);
    notify.taskEnded(self, text.ptr);
}

fn finished(
    self: *App,
    tracked: app.TrackedTask,
    state_value: liborca.JobState,
    stats: ?liborca.ScanStats,
    match_stats: ?liborca.MatchStats,
    match_release: ?i64,
    submission_stats: ?liborca.SubmissionStats,
    tag_write_failure: ?liborca.TagWriteFailure,
) void {
    const task = tracked.task;
    if (task == .tag_write) self.tag_write_group = tracked.tag_write_group;
    if (task == .matching) return matchingFinished(self, tracked, state_value, match_stats, match_release);
    if (task == .submission) return submissionFinished(self, state_value, submission_stats);
    var buffer: [160]u8 = undefined;
    if (state_value == .cancelled) return self.toast("Stopped");
    if (state_value != .succeeded) return report(self, switch (task) {
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
            report(self, if (found == 0)
                "Your library is up to date"
            else
                strings.printZ(&buffer, "{d} new or changed files added", .{found}) catch "Scan complete");
        },
        .analysis => {
            preferences.refreshLibrary(self);
            const measured = if (stats) |value| value.changed + value.unchanged else 0;
            report(self, strings.printZ(&buffer, "Analysed {d} {s}", .{ measured, if (measured == 1) "file" else "files" }) catch "Analysed");
        },
        .duplicates => {
            const found = if (stats) |value| value.tracks_written + value.releases_written else 0;
            report(self, if (found == 0)
                "No duplicates found"
            else
                strings.printZ(&buffer, "Found {d} duplicate files", .{found}) catch "Found duplicates");
        },
        .tag_write => {
            reloadLibraryViews(self);
            const written = if (stats) |value| value.changed else 0;
            const overlay = self.toasts orelse return;
            const text = strings.printZ(&buffer, "Wrote tags to {d} {s}", .{ written, if (written == 1) "file" else "files" }) catch "Wrote tags";
            notify.taskEnded(self, text.ptr);
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

fn untrack(self: *App, index: usize) app.TrackedTask {
    const tracked = self.tasks[index];
    std.mem.copyForwards(app.TrackedTask, self.tasks[index .. self.task_count - 1], self.tasks[index + 1 .. self.task_count]);
    self.task_count -= 1;
    return tracked;
}

pub fn tick(self: *App) void {
    var index: usize = 0;
    while (index < self.task_count) {
        if (tickTask(self, index)) index += 1;
    }
    activity.refresh(self);
}

/// Shows one tracked Job's progress, and reports it when it has ended.
/// False when the Job left the list.
fn tickTask(self: *App, index: usize) bool {
    const tracked = &self.tasks[index];
    const task = tracked.task;
    const job = tracked.job;
    const snapshot = self.runtime.jobSnapshotSynced(job) catch {
        const gone = untrack(self, index);
        if (gone.task == .analysis) self.health.then_duplicates = false;
        health.updateBanner(self);
        return false;
    };
    if (snapshot.state == .queued or snapshot.state == .waiting) return true;
    const stats: ?liborca.ScanStats = switch (task) {
        .matching, .submission => null,
        else => self.runtime.jobScanStats(job) catch null,
    };
    const match_stats: ?liborca.MatchStats = if (task == .matching) self.runtime.jobMatchStats(job) catch null else null;
    const submission_stats: ?liborca.SubmissionStats = if (task == .submission) self.runtime.jobSubmissionStats(job) catch null else null;
    const tag_write_failure: ?liborca.TagWriteFailure = if (task == .tag_write and snapshot.state == .failed) self.runtime.jobTagWriteFailure(job) catch null else null;
    if (stats) |value| {
        if (task == .scan and self.track_count == 0 and value.tracks_written != 0) reloadLibraryViews(self);
    }
    if (match_stats) |value| {
        if (value.matched != tracked.shown_matched) {
            tracked.shown_matched = value.matched;
            matches.updateCount(self);
        }
    }
    switch (snapshot.state) {
        .succeeded, .failed, .cancelled => {},
        else => return true,
    }
    const match_release: ?i64 = if (task == .matching) self.runtime.jobMatchRelease(job) catch null else null;
    const ended = untrack(self, index);
    finished(self, ended, snapshot.state, stats, match_stats, match_release, submission_stats, tag_write_failure);
    switch (task) {
        .analysis, .duplicates, .matching => health.reload(self),
        .scan, .tag_write, .submission => health.updateBanner(self),
    }
    if (task == .analysis) health.analysisEnded(self, snapshot.state);
    self.updateTracksBody();
    return false;
}
