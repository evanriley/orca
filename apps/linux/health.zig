//! The Health page: what liborca found wrong with the library, one card per
//! kind of issue, most severe and then most frequent first. A card opens onto
//! its files in bounded pages, and the panel beside the cards explains the
//! opened kind and what its action does. Each issue carries the action liborca
//! offers to resolve it, and can be dismissed until its file changes.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const jobs = @import("jobs.zig");
const tags = @import("tags.zig");
const matches = @import("matches.zig");
const page_ui = @import("page.zig");
const details = @import("details.zig");
const window = @import("window.zig");

const App = app.App;

const Kind = liborca.HealthIssueKind;

const first_page: u32 = 50;

const Layout = enum { wide, tight, panelless, compact, small };

pub const State = struct {
    cards: ?*gtk.Box = null,
    quiet: ?*gtk.Box = null,
    quiet_section: ?*gtk.Widget = null,
    quiet_toggle: ?*gtk.Widget = null,
    scroller: ?*gtk.ScrolledWindow = null,
    page: ?*gtk.Widget = null,
    title_row: ?*gtk.Widget = null,
    title_end: ?*gtk.Widget = null,
    last_analyzed: ?*gtk.Label = null,
    analyze_label: ?*gtk.Label = null,
    headline: ?*gtk.Label = null,
    summary: ?*gtk.Label = null,
    album_count: ?*gtk.Label = null,
    track_count: ?*gtk.Label = null,
    artist_count: ?*gtk.Label = null,
    library_size: ?*gtk.Label = null,
    panel: ?*gtk.Widget = null,
    about_title: ?*gtk.Label = null,
    about_text: ?*gtk.Label = null,
    about_action: ?*gtk.Label = null,
    count: ?*gtk.Label = null,
    issues_shown: u64 = 0,
    unanalysed_shown: u64 = 0,
    restore_scroll: ?f64 = null,
    expanded: std.EnumSet(Kind) = .initEmpty(),
    loaded: std.EnumArray(Kind, u32) = .initFill(0),
    explained: ?Kind = null,
    show_quiet: bool = false,
    then_duplicates: bool = false,
    layout: Layout = .wide,
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

const Issue = struct {
    self: *App,
    file_id: i64,
    kind: Kind,
    track_id: ?i64,
    release_id: ?i64,
    related_file_id: ?i64,
};

fn issueOf(data: ?*anyopaque) *Issue {
    return @ptrCast(@alignCast(data.?));
}

fn freeIssue(data: ?*anyopaque) callconv(.c) void {
    const issue = issueOf(data);
    issue.self.allocator.destroy(issue);
}

fn kindTitle(kind: ?Kind) [*:0]const u8 {
    return switch (kind orelse return "Missing Loudness Analysis") {
        .missing_metadata => "Missing Tags",
        .missing_track_number => "No Track Number",
        .album_artist_anomaly => "Inconsistent Album Artist",
        .artwork_problem => "Missing Artwork",
        .missing_analysis => "Too Short or Silent",
        .clipping => "Audio Clipping",
        .excessive_silence => "Long Silence",
        .technical_anomaly => "Unusual Files",
        .corrupt_audio => "Damaged Audio",
        .exact_duplicate => "Exact Duplicates",
        .likely_duplicate => "Likely Duplicates",
        .unreadable_file => "Unreadable Files",
        .recording_mismatch => "Different Recording",
    };
}

fn kindIcon(kind: ?Kind) [*:0]const u8 {
    return switch (kind orelse return "audio-volume-high-symbolic") {
        .missing_metadata => "document-edit-symbolic",
        .missing_track_number => "view-list-ordered-symbolic",
        .album_artist_anomaly => "avatar-default-symbolic",
        .artwork_problem => "image-x-generic-symbolic",
        .missing_analysis => "audio-volume-muted-symbolic",
        .clipping => "audio-volume-overamplified-symbolic",
        .excessive_silence => "audio-volume-low-symbolic",
        .technical_anomaly => "dialog-question-symbolic",
        .corrupt_audio => "action-unavailable-symbolic",
        .exact_duplicate, .likely_duplicate => "edit-copy-symbolic",
        .unreadable_file => "dialog-error-symbolic",
        .recording_mismatch => "system-search-symbolic",
    };
}

fn kindColour(kind: ?Kind) [*:0]const u8 {
    return switch (kind orelse return "health-loudness") {
        .exact_duplicate, .likely_duplicate => "health-duplicates",
        .missing_metadata, .missing_track_number, .album_artist_anomaly => "health-tags",
        .clipping => "health-clipping",
        .missing_analysis, .excessive_silence => "health-loudness",
        .recording_mismatch => "health-identity",
        .artwork_problem => "health-artwork",
        .corrupt_audio, .unreadable_file, .technical_anomaly => "health-files",
    };
}

fn kindDescription(kind: ?Kind) [*:0]const u8 {
    return switch (kind orelse return "Files not yet measured for ReplayGain, clipping or duplicates.") {
        .missing_metadata => "The title, artist or album is blank.",
        .missing_track_number => "The file has no track number, so Orca gave it a position.",
        .album_artist_anomaly => "The file names an album but no album artist.",
        .artwork_problem => "No embedded cover, and no cover fetched for the album.",
        .missing_analysis => "Loudness could not be measured, so these play without ReplayGain.",
        .clipping => "A channel has runs of three or more samples at full scale.",
        .excessive_silence => "More than a fifth of the audio is silent.",
        .technical_anomaly => "Another recording holds the same track number.",
        .corrupt_audio => "The file opened, but its audio would not decode.",
        .exact_duplicate => "The same audio is in the library more than once.",
        .likely_duplicate => "The audio closely resembles another file's.",
        .unreadable_file => "The file could not be opened, or its header would not read.",
        .recording_mismatch => "AcoustID hears another recording; a correction awaits review.",
    };
}

fn kindDetail(kind: ?Kind) [*:0]const u8 {
    return switch (kind orelse return "Analyze to enable consistent playback volume") {
        .missing_metadata => "Hard to find, and grouped under Unknown",
        .missing_track_number => "Albums may play out of order",
        .album_artist_anomaly => "Albums may split across artists",
        .artwork_problem => "Covers come from the Cover Art Archive",
        .missing_analysis => "Plays without volume levelling",
        .clipping => "Peak at or above 0 dBFS; not necessarily audible",
        .excessive_silence => "Often a hidden track or a long rip",
        .technical_anomaly => "Two tracks claim one position",
        .corrupt_audio => "Playback may stop or skip",
        .exact_duplicate, .likely_duplicate => "",
        .unreadable_file => "Moved, unreadable or damaged",
        .recording_mismatch => "Accept or dismiss each in Matches",
    };
}

fn kindAbout(kind: ?Kind) [*:0]const u8 {
    return switch (kind orelse return "Orca has not measured these files yet, so they play without ReplayGain and are not checked for clipping, silence, damage or duplicates.") {
        .missing_metadata => "Tracks without a title, artist or album are hard to find and sort, and fall into Unknown groups.",
        .missing_track_number => "Without a track number Orca orders the album by file name, which may not be the order it was released in.",
        .album_artist_anomaly => "Without an album artist, an album with guest artists can split into several albums.",
        .artwork_problem => "These albums have no embedded cover and none was fetched, so they show a placeholder.",
        .missing_analysis => "Orca could not measure loudness because the audio is too short or silent, so these files play without ReplayGain.",
        .clipping => "These tracks contain samples at or above digital full scale. This doesn't necessarily mean the recording is audibly distorted.",
        .excessive_silence => "More than a fifth of the file is silence: often a hidden track after a gap, or a rip that ran on.",
        .technical_anomaly => "Two recordings on one album claim the same track number, which can be a duplicate or a tagging slip.",
        .corrupt_audio => "The file opened, but part of its audio would not decode. Playback may stop or skip there.",
        .exact_duplicate => "The same audio is in the library more than once. Removing the extra copies would free the space shown.",
        .likely_duplicate => "The audio closely resembles another file's: often the same track in another format or from another release.",
        .unreadable_file => "Orca could not open the file or read its header. It may have moved, lost its permissions or be damaged.",
        .recording_mismatch => "AcoustID recognises the audio as a different recording from the one the library names.",
    };
}

const CardAction = enum { analyze, fix_in_matches, review_in_matches, fix, review, locate };

fn cardAction(kind: ?Kind) CardAction {
    return switch (kind orelse return .analyze) {
        .missing_metadata, .missing_track_number, .album_artist_anomaly => .fix_in_matches,
        .recording_mismatch => .review_in_matches,
        .artwork_problem => .fix,
        .corrupt_audio, .unreadable_file => .locate,
        .missing_analysis, .clipping, .excessive_silence, .technical_anomaly, .exact_duplicate, .likely_duplicate => .review,
    };
}

fn actionLabel(action: CardAction) [*:0]const u8 {
    return switch (action) {
        .analyze => "Analyze",
        .fix_in_matches, .fix => "Fix",
        .review_in_matches, .review => "Review",
        .locate => "Locate",
    };
}

fn actionAbout(kind: ?Kind) [*:0]const u8 {
    return switch (cardAction(kind)) {
        .analyze => "Analyze measures loudness for ReplayGain and checks for clipping, silence and damage. It takes hours on a large library, and stopping it keeps what is done.",
        .fix_in_matches => "Fix opens Matches, which searches MusicBrainz for these tracks and lets you accept what it finds. Each file also offers Edit Tags. Both change the library, not the files.",
        .review_in_matches => "Review opens Matches, where each correction can be accepted or dismissed. Accepting changes the library, not the files.",
        .fix => "Fix lists the albums' files. An album with a MusicBrainz ID fetches its cover from the Cover Art Archive; the others need a match first. Covers are kept in the library, never written to files.",
        .review => if (kind == .exact_duplicate or kind == .likely_duplicate)
            "Review lists the files. Compare shows both copies side by side; Orca never deletes a file."
        else
            "Review lists the files. Show in Files opens the folder of each one.",
        .locate => "Locate lists the files. Show in Files opens the folder each one was last seen in.",
    };
}

fn analyzeAgain(self: *App) void {
    self.health.then_duplicates = true;
    jobs.startAnalysis(self);
    if (self.task != .analysis) self.health.then_duplicates = false;
}

fn analyzeAgainClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    analyzeAgain(state(data));
}

fn analyzeAgainActivated(_: ?*anyopaque, _: ?*gtk.GVariant, data: ?*anyopaque) callconv(.c) void {
    analyzeAgain(state(data));
}

fn duplicatesActivated(_: ?*anyopaque, _: ?*gtk.GVariant, data: ?*anyopaque) callconv(.c) void {
    jobs.startDuplicates(state(data));
}

fn verifyActivated(_: ?*anyopaque, _: ?*gtk.GVariant, data: ?*anyopaque) callconv(.c) void {
    jobs.startLibraryVerification(state(data));
}

pub fn analysisEnded(self: *App, outcome: liborca.JobState) void {
    const chained = self.health.then_duplicates;
    self.health.then_duplicates = false;
    if (chained and outcome == .succeeded) jobs.startDuplicates(self);
}

fn matchActivated(_: ?*anyopaque, _: ?*gtk.GVariant, data: ?*anyopaque) callconv(.c) void {
    const issue = issueOf(data);
    jobs.startTrackMatching(issue.self, issue.track_id orelse return);
}

fn editActivated(_: ?*anyopaque, _: ?*gtk.GVariant, data: ?*anyopaque) callconv(.c) void {
    const issue = issueOf(data);
    tags.edit(issue.self, &.{issue.track_id orelse return});
}

fn fetchCoverClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const issue = issueOf(data);
    jobs.startCoverArtFetch(issue.self, issue.release_id orelse return);
}

fn reviewClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const issue = issueOf(data);
    matches.reveal(issue.self, issue.track_id orelse return);
}

fn compareClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const issue = issueOf(data);
    compare(issue.self, issue.file_id, issue.related_file_id);
}

fn showInFilesClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const issue = issueOf(data);
    const self = issue.self;
    const library = self.library orelse return;
    const file = self.runtime.libraryHealthFile(library, self.allocator, issue.file_id) catch
        return self.toast("Could not read the file's location");
    const found = file orelse return self.toast("File not found");
    defer found.deinit();
    revealPath(self, found.path);
}

const Dismissal = struct {
    self: *App,
    file_id: i64,
    kind: Kind,
};

fn freeDismissal(data: ?*anyopaque) callconv(.c) void {
    const dismissal: *Dismissal = @ptrCast(@alignCast(data.?));
    dismissal.self.allocator.destroy(dismissal);
}

fn undoDismissClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const dismissal: *Dismissal = @ptrCast(@alignCast(data.?));
    const self = dismissal.self;
    const library = self.library orelse return;
    self.runtime.libraryRestoreHealthIssue(library, dismissal.file_id, dismissal.kind) catch
        return self.toast("Could not restore the issue");
    reload(self);
}

fn dismissClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const issue = issueOf(data);
    const self = issue.self;
    const file_id = issue.file_id;
    const kind = issue.kind;
    const library = self.library orelse return;
    self.runtime.libraryDismissHealthIssue(library, file_id, kind) catch
        return self.toast("Could not dismiss the issue");
    reload(self);
    const overlay = self.toasts orelse return;
    const dismissal = self.allocator.create(Dismissal) catch return;
    dismissal.* = .{ .self = self, .file_id = file_id, .kind = kind };
    const item = adw.adw_toast_new("Issue dismissed");
    adw.adw_toast_set_timeout(item, 8);
    adw.adw_toast_set_button_label(item, "Undo");
    gtk.g_object_set_data_full(item, "orca-dismissal", dismissal, freeDismissal);
    _ = gtk.signalConnect(item, "button-clicked", gtk.callback(undoDismissClicked), dismissal);
    adw.adw_toast_overlay_add_toast(overlay, item);
}

fn launched(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    var err: ?*gtk.GError = null;
    if (gtk.gtk_file_launcher_open_containing_folder_finish(gtk.cast(gtk.FileLauncher, source), result, &err) != 0) return;
    gtk.g_clear_error(&err);
    state(data).toast("Could not open the file manager");
}

/// Opens the folder holding `path` with the file selected, when the file is
/// there to show.
fn revealPath(self: *App, path: ?[]const u8) void {
    const location = path orelse return self.toast("File not found");
    if (location.len == 0) return self.toast("File not found");
    const terminated = self.allocator.dupeZ(u8, location) catch return;
    defer self.allocator.free(terminated);
    const file = gtk.g_file_new_for_path(terminated.ptr);
    defer gtk.g_object_unref(file);
    if (gtk.g_file_query_exists(file, null) == 0) return self.toast("File not found");
    const launcher = gtk.gtk_file_launcher_new(file);
    gtk.gtk_file_launcher_open_containing_folder(launcher, self.window, null, launched, self);
    gtk.g_object_unref(launcher);
}

fn freeText(text: ?*anyopaque) callconv(.c) void {
    gtk.g_free(text);
}

fn revealClicked(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const stored = gtk.g_object_get_data(button.?, "orca-path") orelse return state(data).toast("File not found");
    const text: [*:0]const u8 = @ptrCast(stored);
    revealPath(state(data), std.mem.span(text));
}

fn propertyRow(group: *gtk.Widget, title: [*:0]const u8, value: [:0]const u8) void {
    const row = adw.adw_action_row_new();
    gtk.gtk_widget_add_css_class(row, "property");
    adw.adw_preferences_row_set_use_markup(gtk.cast(adw.PreferencesRow, row), gtk.false_);
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, row), title);
    adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, row), if (value.len == 0) "Unknown" else value.ptr);
    adw.adw_preferences_group_add(gtk.cast(adw.PreferencesGroup, group), row);
}

fn fileColumn(self: *App, heading: [*:0]const u8, file: liborca.HealthFile) *gtk.Widget {
    const group = adw.adw_preferences_group_new();
    adw.adw_preferences_group_set_title(gtk.cast(adw.PreferencesGroup, group), heading);
    var path_buffer: [4096]u8 = undefined;
    propertyRow(group, "Location", if (file.path) |path| strings.terminated(&path_buffer, path) else "");
    propertyRow(group, "Status", if (file.missing) "Missing" else "Present");
    var buffer: [64]u8 = undefined;
    propertyRow(group, "Codec", strings.terminated(&buffer, file.codec));
    propertyRow(group, "Sample rate", if (file.sample_rate) |rate|
        (if (rate % 1000 == 0)
            strings.format(&buffer, "{d} kHz", .{rate / 1000})
        else
            strings.format(&buffer, "{d}.{d} kHz", .{ rate / 1000, rate % 1000 / 100 }))
    else
        "");
    propertyRow(group, "Bit depth", if (file.bit_depth) |depth| strings.format(&buffer, "{d}-bit", .{depth}) else "");
    propertyRow(group, "Channels", if (file.channels) |channels| strings.format(&buffer, "{d}", .{channels}) else "");
    propertyRow(group, "Size", if (file.size_bytes) |size|
        strings.format(&buffer, "{d:.1} MB", .{@as(f64, @floatFromInt(size)) / 1_000_000})
    else
        "");
    propertyRow(group, "Duration", if (file.duration_ms) |milliseconds|
        (if (std.math.cast(u64, milliseconds)) |length| strings.formatMs(&buffer, length) else "")
    else
        "");

    const reveal = gtk.gtk_button_new_with_label("Reveal");
    gtk.gtk_widget_set_halign(reveal, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(reveal, "pill");
    gtk.gtk_widget_set_tooltip_text(reveal, "Show the file in its folder");
    if (file.path) |path| {
        gtk.g_object_set_data_full(reveal, "orca-path", gtk.g_strndup(path.ptr, path.len), freeText);
    } else gtk.gtk_widget_set_sensitive(reveal, gtk.false_);
    _ = gtk.signalConnect(reveal, "clicked", gtk.callback(revealClicked), self);

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 12);
    gtk.gtk_widget_set_hexpand(column, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), group);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), reveal);
    return column;
}

fn noteColumn(icon: [*:0]const u8, title: [*:0]const u8, description: [*:0]const u8) *gtk.Widget {
    const status = adw.adw_status_page_new();
    adw.adw_status_page_set_icon_name(gtk.cast(adw.StatusPage, status), icon);
    adw.adw_status_page_set_title(gtk.cast(adw.StatusPage, status), title);
    adw.adw_status_page_set_description(gtk.cast(adw.StatusPage, status), description);
    gtk.gtk_widget_add_css_class(status, "compact");
    gtk.gtk_widget_set_hexpand(status, gtk.true_);
    return status;
}

fn healthFile(self: *App, library: liborca.LibraryHandle, file_id: ?i64) ?liborca.HealthFile {
    const id = file_id orelse return null;
    return self.runtime.libraryHealthFile(library, self.allocator, id) catch null;
}

/// The two files of a duplicate side by side. Nothing is deleted from here.
fn compare(self: *App, file_id: i64, related_file_id: ?i64) void {
    const library = self.library orelse return;
    const this = healthFile(self, library, file_id) orelse return self.toast("File not found");
    defer this.deinit();
    const other = healthFile(self, library, related_file_id);
    defer if (other) |file| file.deinit();

    const columns = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 18);
    gtk.gtk_box_set_homogeneous(gtk.cast(gtk.Box, columns), gtk.true_);
    gtk.gtk_widget_set_margin_start(columns, 18);
    gtk.gtk_widget_set_margin_end(columns, 18);
    gtk.gtk_widget_set_margin_top(columns, 12);
    gtk.gtk_widget_set_margin_bottom(columns, 24);
    gtk.gtk_box_append(gtk.cast(gtk.Box, columns), fileColumn(self, "This file", this));
    gtk.gtk_box_append(gtk.cast(gtk.Box, columns), if (other) |file|
        fileColumn(self, "Other copy", file)
    else if (related_file_id == null)
        noteColumn("edit-copy-symbolic", "Same file, two places", "The other copy is byte for byte this file at another location, named in the issue.")
    else
        noteColumn("edit-delete-symbolic", "Other copy gone", "The other file of this duplicate is no longer in the library."));
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), columns);
    gtk.gtk_scrolled_window_set_propagate_natural_height(gtk.cast(gtk.ScrolledWindow, scroller), gtk.true_);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), adw.adw_header_bar_new());
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), scroller);
    const dialog = adw.adw_dialog_new();
    adw.adw_dialog_set_title(dialog, "Compare Duplicates");
    adw.adw_dialog_set_content_width(dialog, 760);
    adw.adw_dialog_set_child(dialog, view);
    adw.adw_dialog_present(dialog, if (self.window) |w| gtk.cast(gtk.Widget, w) else null);
}

fn suffixButton(row: *gtk.Widget, text: [*:0]const u8, tooltip: [*:0]const u8, handler: gtk.GCallback, issue: *Issue) *gtk.Widget {
    const button = gtk.gtk_button_new_with_label(text);
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
    _ = gtk.signalConnect(button, "clicked", handler, issue);
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, row), button);
    return button;
}

fn addAction(group: *gtk.GSimpleActionGroup, name: [*:0]const u8, handler: gtk.GCallback, data: *anyopaque) void {
    const action = gtk.g_simple_action_new(name, null).?;
    _ = gtk.signalConnect(action, "activate", handler, data);
    gtk.g_action_map_add_action(gtk.cast(gtk.GActionMap, group), gtk.cast(gtk.GAction, action));
    gtk.g_object_unref(action);
}

/// A "Fix" menu of Match and Edit Tags, acting through actions scoped to the
/// row so each item knows its Track.
fn fixMenu(row: *gtk.Widget, issue: *Issue) void {
    const group = gtk.g_simple_action_group_new();
    addAction(group, "match", gtk.callback(matchActivated), issue);
    addAction(group, "edit", gtk.callback(editActivated), issue);
    gtk.gtk_widget_insert_action_group(row, "health", gtk.cast(gtk.GActionGroup, group));
    gtk.g_object_unref(group);
    const model = gtk.g_menu_new();
    gtk.g_menu_append(model, "Match", "health.match");
    gtk.g_menu_append(model, "Edit Tags…", "health.edit");
    const button = gtk.gtk_menu_button_new();
    gtk.gtk_menu_button_set_label(gtk.cast(gtk.MenuButton, button), "Fix");
    gtk.gtk_menu_button_set_menu_model(gtk.cast(gtk.MenuButton, button), gtk.cast(gtk.GMenuModel, model));
    gtk.g_object_unref(model);
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, "Find this track on MusicBrainz, or edit its tags");
    adw.adw_action_row_add_suffix(gtk.cast(adw.ActionRow, row), button);
}

fn addActions(row: *gtk.Widget, issue: *Issue, action: liborca.HealthAction) void {
    switch (action) {
        .match_or_edit => if (issue.track_id != null) fixMenu(row, issue),
        .fetch_cover_art => if (issue.release_id != null) {
            _ = suffixButton(row, "Fetch Cover", "Fetch this album's cover from the Cover Art Archive", gtk.callback(fetchCoverClicked), issue);
        },
        .compare_duplicate => {
            _ = suffixButton(row, "Compare", "Compare this file with its duplicate", gtk.callback(compareClicked), issue);
        },
        .review_correction => if (issue.track_id != null) {
            _ = suffixButton(row, "Review", "Review the correction in Matches", gtk.callback(reviewClicked), issue);
        },
        .reveal_file => {
            _ = suffixButton(row, "Show in Files", "Show the file in its folder", gtk.callback(showInFilesClicked), issue);
        },
    }
    const dismiss = suffixButton(row, "Dismiss", "Hide this issue until the file changes", gtk.callback(dismissClicked), issue);
    gtk.gtk_widget_add_css_class(dismiss, "flat");
}

const Files = struct {
    list: *gtk.ListBox,
    body: *gtk.Widget,
    more: *gtk.Widget,
    toggle: *gtk.Widget,
    about: *gtk.Widget,
};

const Card = struct {
    self: *App,
    kind: ?Kind,
    count: u64,
    loaded: u32 = 0,
    detail: *gtk.Widget,
    action: *gtk.Widget,
    files: ?Files,
};

fn cardOf(data: ?*anyopaque) *Card {
    return @ptrCast(@alignCast(data.?));
}

fn freeCard(data: ?*anyopaque) callconv(.c) void {
    const card = cardOf(data);
    card.self.allocator.destroy(card);
}

fn fileName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn folderOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

fn issueRow(self: *App, item: liborca.HealthIssue) ?*gtk.Widget {
    const issue = self.allocator.create(Issue) catch return null;
    issue.* = .{
        .self = self,
        .file_id = item.file_id,
        .kind = item.kind,
        .track_id = item.track_id,
        .release_id = item.release_id,
        .related_file_id = item.related_file_id,
    };
    const row = adw.adw_action_row_new();
    gtk.g_object_set_data_full(row, "orca-issue", issue, freeIssue);
    gtk.gtk_widget_add_css_class(row, "health-issue");
    adw.adw_preferences_row_set_use_markup(gtk.cast(adw.PreferencesRow, row), gtk.false_);
    var buffer: [4096]u8 = undefined;
    const name = fileName(item.path);
    adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, row), if (name.len == 0) "No location" else strings.terminated(&buffer, name).ptr);
    adw.adw_action_row_set_title_lines(gtk.cast(adw.ActionRow, row), 1);
    const folder = folderOf(item.path);
    const subtitle = if (item.details.len != 0 and folder.len != 0)
        strings.printZ(&buffer, "{s}\n{s}", .{ item.details, folder }) catch ""
    else if (item.details.len != 0)
        strings.terminated(&buffer, item.details)
    else
        strings.terminated(&buffer, folder);
    if (subtitle.len != 0) adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, row), subtitle.ptr);
    adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, row), 3);
    if (item.path.len != 0) gtk.gtk_widget_set_tooltip_text(row, strings.terminated(&buffer, item.path).ptr);
    addActions(row, issue, item.action);
    return row;
}

fn loadMore(card: *Card) void {
    const self = card.self;
    const files = card.files orelse return;
    const kind = card.kind orelse return;
    const library = self.library orelse return;
    const limit: u32 = if (card.loaded == 0) first_page else app.page_size;
    var page = self.runtime.libraryHealthIssuePageOfKind(library, kind, limit, card.loaded) catch
        return self.toast("Could not read the issues");
    defer page.deinit();
    for (page.items) |item| {
        const row = issueRow(self, item) orelse continue;
        gtk.gtk_list_box_append(files.list, row);
    }
    card.loaded += @intCast(page.items.len);
    const exhausted = page.items.len < limit or card.loaded >= card.count;
    gtk.gtk_widget_set_visible(files.more, if (exhausted) gtk.false_ else gtk.true_);
}

fn showMoreClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const card = cardOf(data);
    loadMore(card);
    if (card.kind) |kind| card.self.health.loaded.set(kind, card.loaded);
}

fn setExpanded(card: *Card, expanded: bool) void {
    const files = card.files orelse return;
    gtk.gtk_widget_set_visible(files.body, if (expanded) gtk.true_ else gtk.false_);
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, files.toggle), if (expanded) "pan-up-symbolic" else "pan-down-symbolic");
    gtk.gtk_widget_set_tooltip_text(files.toggle, if (expanded) "Hide the files" else "Show the files");
    if (expanded and card.loaded == 0) loadMore(card);
}

fn expandToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const card = cardOf(data);
    const self = card.self;
    const kind = card.kind orelse return;
    const expanded = gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button)) != 0;
    self.health.expanded.setPresent(kind, expanded);
    setExpanded(card, expanded);
    self.health.loaded.set(kind, card.loaded);
    if (expanded) {
        self.health.explained = kind;
    } else if (self.health.explained == kind) {
        self.health.explained = firstExpanded(self);
    }
    explain(self);
}

fn expand(card: *Card) void {
    const files = card.files orelse return;
    gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, files.toggle), gtk.true_);
    _ = gtk.gtk_widget_grab_focus(files.toggle);
}

fn cardActionClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const card = cardOf(data);
    const self = card.self;
    switch (cardAction(card.kind)) {
        .analyze => {
            self.health.then_duplicates = false;
            jobs.startAnalysis(self);
        },
        .fix_in_matches, .review_in_matches => window.showPage(self, .matches),
        .fix, .review, .locate => expand(card),
    }
}

fn actionTooltip(kind: ?Kind) [*:0]const u8 {
    return switch (cardAction(kind)) {
        .analyze => "Measure loudness for ReplayGain across the library",
        .fix_in_matches => "Search MusicBrainz for these tracks in Matches",
        .review_in_matches => "Review the proposed corrections in Matches",
        .fix => "Show the files, with Fetch Cover on each",
        .review => "Show the files",
        .locate => "Show the files, with Show in Files on each",
    };
}

fn label(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0);
    return widget;
}

fn wrapped(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = label(text, class);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, widget), gtk.true_);
    gtk.gtk_label_set_wrap_mode(gtk.cast(gtk.Label, widget), gtk.WRAP_WORD_CHAR);
    return widget;
}

fn tile(icon_name: [*:0]const u8, colour: [*:0]const u8, size: c_int, icon_size: c_int) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name(icon_name);
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), icon_size);
    gtk.gtk_widget_set_halign(icon, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_valign(icon, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(icon, gtk.true_);
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(box, "health-tile");
    gtk.gtk_widget_add_css_class(box, colour);
    gtk.gtk_widget_set_size_request(box, size, size);
    gtk.gtk_widget_set_hexpand(box, gtk.false_);
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), icon);
    return box;
}

const Entry = struct {
    kind: ?Kind,
    severity: liborca.HealthSeverity,
    count: u64,
    files: u64,
    bytes: u64,
};

fn moreUrgent(_: void, a: Entry, b: Entry) bool {
    if (a.severity != b.severity) return @intFromEnum(a.severity) > @intFromEnum(b.severity);
    return a.count > b.count;
}

fn detailText(buffer: []u8, entry: Entry) [:0]const u8 {
    const kind = entry.kind orelse return std.mem.span(kindDetail(null));
    switch (kind) {
        .exact_duplicate, .likely_duplicate => {
            const size = gtk.g_format_size(entry.bytes);
            defer gtk.g_free(size);
            return strings.format(buffer, "Potentially save {s} across {f} {s}", .{
                std.mem.span(size),
                strings.grouped(entry.files),
                if (entry.files == 1) "file" else "files",
            });
        },
        else => return std.mem.span(kindDetail(kind)),
    }
}

fn panelShown(layout: Layout) bool {
    return layout == .wide or layout == .tight;
}

fn detailShown(layout: Layout) bool {
    return layout == .wide or layout == .panelless;
}

fn fitCard(card: *Card, layout: Layout) void {
    gtk.gtk_widget_set_visible(card.detail, if (detailShown(layout)) gtk.true_ else gtk.false_);
    if (layout == .small) gtk.gtk_widget_set_size_request(card.action, 84, 36) else gtk.gtk_widget_set_size_request(card.action, 118, 40);
    const files = card.files orelse return;
    gtk.gtk_widget_set_visible(files.about, if (panelShown(layout)) gtk.false_ else gtk.true_);
}

fn kindCard(self: *App, entry: Entry) ?*gtk.Widget {
    const card = self.allocator.create(Card) catch return null;

    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    const heading = label(kindTitle(entry.kind), "health-card-title");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, heading), gtk.ELLIPSIZE_END);
    const description = wrapped(kindDescription(entry.kind), "health-card-description");
    gtk.gtk_label_set_lines(gtk.cast(gtk.Label, description), 2);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, description), gtk.ELLIPSIZE_END);
    gtk.gtk_widget_set_tooltip_text(description, kindDescription(entry.kind));
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), heading);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), description);

    const tally = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tally, "health-tally");
    gtk.gtk_widget_set_valign(tally, gtk.ALIGN_CENTER);
    var buffer: [128]u8 = undefined;
    const number = label(strings.format(&buffer, "{f}", .{strings.grouped(entry.count)}).ptr, "health-tally-number");
    gtk.gtk_widget_add_css_class(number, "numeric");
    gtk.gtk_box_append(gtk.cast(gtk.Box, tally), number);
    gtk.gtk_box_append(gtk.cast(gtk.Box, tally), label(if (entry.count == 1) "file" else "files", "health-tally-unit"));

    const detail = wrapped(detailText(&buffer, entry).ptr, "health-detail");
    gtk.gtk_label_set_lines(gtk.cast(gtk.Label, detail), 2);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, detail), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, detail), 28);
    gtk.gtk_widget_set_size_request(detail, 230, -1);
    gtk.gtk_widget_set_valign(detail, gtk.ALIGN_CENTER);

    const action = gtk.gtk_button_new_with_label(actionLabel(cardAction(entry.kind)));
    gtk.gtk_widget_add_css_class(action, "health-action");
    gtk.gtk_widget_set_valign(action, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(action, actionTooltip(entry.kind));

    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    gtk.gtk_widget_add_css_class(header, "health-card-header");
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), tile(kindIcon(entry.kind), kindColour(entry.kind), 48, 24));
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), text);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), tally);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), detail);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), action);

    const widget = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(widget, "health-card");
    gtk.gtk_box_append(gtk.cast(gtk.Box, widget), header);

    card.* = .{
        .self = self,
        .kind = entry.kind,
        .count = entry.count,
        .detail = detail,
        .action = action,
        .files = null,
    };
    gtk.g_object_set_data_full(widget, "orca-health-card", card, freeCard);
    _ = gtk.signalConnect(action, "clicked", gtk.callback(cardActionClicked), card);

    if (entry.kind) |kind| {
        const toggle = gtk.gtk_toggle_button_new();
        gtk.gtk_widget_add_css_class(toggle, "flat");
        gtk.gtk_widget_add_css_class(toggle, "health-chevron");
        gtk.gtk_widget_set_valign(toggle, gtk.ALIGN_CENTER);
        gtk.gtk_box_append(gtk.cast(gtk.Box, header), toggle);

        const about = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 6);
        gtk.gtk_widget_add_css_class(about, "health-inline-about");
        gtk.gtk_box_append(gtk.cast(gtk.Box, about), wrapped(kindAbout(kind), "health-about-text"));
        gtk.gtk_box_append(gtk.cast(gtk.Box, about), wrapped(actionAbout(kind), "health-about-action"));

        const list = gtk.gtk_list_box_new();
        gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, list), gtk.SELECTION_NONE);
        gtk.gtk_list_box_set_tab_behavior(gtk.cast(gtk.ListBox, list), gtk.LIST_TAB_ITEM);
        gtk.gtk_widget_add_css_class(list, "health-issues");
        const more = gtk.gtk_button_new_with_label("Show more");
        gtk.gtk_widget_add_css_class(more, "flat");
        gtk.gtk_widget_add_css_class(more, "health-more");
        gtk.gtk_widget_set_visible(more, gtk.false_);
        const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
        gtk.gtk_box_append(gtk.cast(gtk.Box, body), about);
        gtk.gtk_box_append(gtk.cast(gtk.Box, body), list);
        gtk.gtk_box_append(gtk.cast(gtk.Box, body), more);
        gtk.gtk_box_append(gtk.cast(gtk.Box, widget), body);

        card.files = .{
            .list = gtk.cast(gtk.ListBox, list),
            .body = body,
            .more = more,
            .toggle = toggle,
            .about = about,
        };
        _ = gtk.signalConnect(more, "clicked", gtk.callback(showMoreClicked), card);

        const expanded = self.health.expanded.contains(kind);
        setExpanded(card, expanded);
        if (expanded) {
            while (card.loaded < self.health.loaded.get(kind) and gtk.gtk_widget_get_visible(more) != 0) {
                const before = card.loaded;
                loadMore(card);
                if (card.loaded == before) break;
            }
            self.health.loaded.set(kind, card.loaded);
        }
        gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, toggle), if (expanded) gtk.true_ else gtk.false_);
        _ = gtk.signalConnect(toggle, "toggled", gtk.callback(expandToggled), card);
    } else {
        gtk.gtk_widget_add_css_class(widget, "health-analysis");
        const spacer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
        gtk.gtk_widget_add_css_class(spacer, "health-chevron");
        gtk.gtk_box_append(gtk.cast(gtk.Box, header), spacer);
    }
    fitCard(card, self.health.layout);
    return widget;
}

fn quietRow(kind: ?Kind) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row, "health-quiet-row");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), tile(kindIcon(kind), kindColour(kind), 32, 16));
    const name = label(kindTitle(kind), "health-quiet-title");
    gtk.gtk_widget_set_hexpand(name, gtk.true_);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, name), gtk.ELLIPSIZE_END);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), name);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), label("✓ All good", "health-quiet-good"));
    return row;
}

fn showQuiet(self: *App) void {
    const shown = self.health.show_quiet;
    if (self.health.quiet) |quiet| gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, quiet), if (shown) gtk.true_ else gtk.false_);
    if (self.health.quiet_toggle) |toggle|
        gtk.gtk_button_set_label(gtk.cast(gtk.Button, toggle), if (shown) "Hide kinds with no issues" else "Show kinds with no issues");
}

fn quietToggled(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.health.show_quiet = !self.health.show_quiet;
    showQuiet(self);
}

fn statItem(row: *gtk.Widget, caption: [*:0]const u8, first: bool) *gtk.Label {
    if (!first) {
        const divider = gtk.gtk_separator_new(gtk.ORIENTATION_VERTICAL);
        gtk.gtk_widget_add_css_class(divider, "health-stat-divider");
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), divider);
    }
    const item = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(item, "health-stat");
    const number = label("0", "health-stat-number");
    gtk.gtk_widget_add_css_class(number, "numeric");
    gtk.gtk_box_append(gtk.cast(gtk.Box, item), number);
    gtk.gtk_box_append(gtk.cast(gtk.Box, item), label(caption, "health-stat-label"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), item);
    return gtk.cast(gtk.Label, number);
}

fn summaryBlock(self: *App) *gtk.Widget {
    const headline = label("", "health-headline");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, headline), gtk.true_);
    self.health.headline = gtk.cast(gtk.Label, headline);
    const summary = wrapped("", "health-summary");
    self.health.summary = gtk.cast(gtk.Label, summary);

    const stats = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(stats, "health-stats");
    self.health.album_count = statItem(stats, "Albums", true);
    self.health.track_count = statItem(stats, "Tracks", false);
    self.health.artist_count = statItem(stats, "Artists", false);
    self.health.library_size = statItem(stats, "Library Size", false);

    const block = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(block, "health-overview");
    gtk.gtk_box_append(gtk.cast(gtk.Box, block), headline);
    gtk.gtk_box_append(gtk.cast(gtk.Box, block), summary);
    gtk.gtk_box_append(gtk.cast(gtk.Box, block), stats);
    return block;
}

fn analyzeButton(self: *App) *gtk.Widget {
    const group = gtk.g_simple_action_group_new();
    addAction(group, "analyze", gtk.callback(analyzeAgainActivated), self);
    addAction(group, "duplicates", gtk.callback(duplicatesActivated), self);
    addAction(group, "verify", gtk.callback(verifyActivated), self);
    const model = gtk.g_menu_new();
    gtk.g_menu_append(model, "Analyze Again", "health-page.analyze");
    gtk.g_menu_append(model, "Find duplicates only", "health-page.duplicates");
    gtk.g_menu_append(model, "Verify recording IDs", "health-page.verify");

    const icon = gtk.gtk_image_new_from_icon_name("view-refresh-symbolic");
    const text = gtk.gtk_label_new("Analyze Again");
    self.health.analyze_label = gtk.cast(gtk.Label, text);
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_halign(content, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), text);

    const button = adw.adw_split_button_new();
    gtk.gtk_widget_add_css_class(button, "health-analyze");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_END);
    adw.adw_split_button_set_child(gtk.cast(adw.SplitButton, button), content);
    adw.adw_split_button_set_menu_model(gtk.cast(adw.SplitButton, button), gtk.cast(gtk.GMenuModel, model));
    adw.adw_split_button_set_dropdown_tooltip(gtk.cast(adw.SplitButton, button), "More checks");
    gtk.g_object_unref(model);
    gtk.gtk_widget_set_tooltip_text(button, "Measure loudness, then look for duplicates");
    gtk.gtk_widget_insert_action_group(button, "health-page", gtk.cast(gtk.GActionGroup, group));
    gtk.g_object_unref(group);
    _ = gtk.signalConnect(button, "clicked", gtk.callback(analyzeAgainClicked), self);
    return button;
}

fn lastAnalyzedBlock(self: *App) *gtk.Widget {
    const caption = label("Last analyzed", "health-last-caption");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, caption), 1);
    const when = label("Never", "health-last-time");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, when), 1);
    self.health.last_analyzed = gtk.cast(gtk.Label, when);
    const block = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_add_css_class(block, "health-last");
    gtk.gtk_widget_set_valign(block, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, block), caption);
    gtk.gtk_box_append(gtk.cast(gtk.Box, block), when);
    return block;
}

fn benefit(icon_name: [*:0]const u8, title: [*:0]const u8, text: [*:0]const u8) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name(icon_name);
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 20);
    gtk.gtk_widget_set_valign(icon, gtk.ALIGN_START);
    gtk.gtk_widget_add_css_class(icon, "health-benefit-icon");
    const words = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 4);
    gtk.gtk_widget_set_hexpand(words, gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, words), wrapped(title, "health-benefit-title"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, words), wrapped(text, "health-benefit-text"));
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 18);
    gtk.gtk_widget_add_css_class(row, "health-benefit");
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), words);
    return row;
}

fn panelBlock(self: *App) *gtk.Widget {
    const intro = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(intro, "health-panel-intro");
    const icon = tile("emblem-important-symbolic", "health-panel-tile", 56, 28);
    gtk.gtk_widget_set_halign(icon, gtk.ALIGN_START);
    gtk.gtk_box_append(gtk.cast(gtk.Box, intro), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, intro), wrapped("A healthier library sounds better.", "health-panel-headline"));
    gtk.gtk_box_append(gtk.cast(gtk.Box, intro), wrapped(
        "Library Health helps you find and fix common issues, so your music is complete, consistent, and ready to enjoy — everywhere.",
        "health-panel-text",
    ));

    const benefits = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 22);
    gtk.gtk_widget_add_css_class(benefits, "health-benefits");
    gtk.gtk_box_append(gtk.cast(gtk.Box, benefits), benefit("starred-symbolic", "Better discovery", "Accurate metadata means better search and recommendations."));
    gtk.gtk_box_append(gtk.cast(gtk.Box, benefits), benefit("audio-volume-high-symbolic", "A richer listening experience", "Consistent volume, correct metadata, and high-quality files help your music shine."));
    gtk.gtk_box_append(gtk.cast(gtk.Box, benefits), benefit("security-high-symbolic", "Peace of mind", "Find and fix issues before they get in the way."));

    const about_title = label("", "health-about-title");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, about_title), gtk.true_);
    self.health.about_title = gtk.cast(gtk.Label, about_title);
    const about_text = wrapped("", "health-about-text");
    self.health.about_text = gtk.cast(gtk.Label, about_text);
    const about_action = wrapped("", "health-about-action");
    self.health.about_action = gtk.cast(gtk.Label, about_action);
    const about = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 8);
    gtk.gtk_widget_add_css_class(about, "health-about");
    gtk.gtk_box_append(gtk.cast(gtk.Box, about), about_title);
    gtk.gtk_box_append(gtk.cast(gtk.Box, about), about_text);
    gtk.gtk_box_append(gtk.cast(gtk.Box, about), about_action);

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(column, "health-panel-column");
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), intro);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), benefits);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), about);

    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), column);
    gtk.gtk_widget_add_css_class(scroller, "health-panel");
    gtk.gtk_widget_set_size_request(scroller, 310, -1);
    gtk.gtk_widget_set_hexpand(scroller, gtk.false_);
    self.health.panel = scroller;
    return scroller;
}

fn explain(self: *App) void {
    const title = self.health.about_title orelse return;
    const text = self.health.about_text orelse return;
    const action = self.health.about_action orelse return;
    if (self.health.explained) |kind| {
        var buffer: [128]u8 = undefined;
        gtk.gtk_label_set_text(title, strings.format(&buffer, "About {s}", .{std.mem.span(kindTitle(kind))}).ptr);
        gtk.gtk_label_set_text(text, kindAbout(kind));
        gtk.gtk_label_set_text(action, actionAbout(kind));
        gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, action), gtk.true_);
    } else {
        gtk.gtk_label_set_text(title, "What each check means");
        gtk.gtk_label_set_text(text, "Open a category to see what it found, why it matters, and what its button does.");
        gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, action), gtk.false_);
    }
}

fn firstExpanded(self: *App) ?Kind {
    const cards = self.health.cards orelse return null;
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, cards));
    while (child) |widget| : (child = gtk.gtk_widget_get_next_sibling(widget)) {
        const card = cardOf(gtk.g_object_get_data(widget, "orca-health-card") orelse continue);
        const kind = card.kind orelse continue;
        if (self.health.expanded.contains(kind)) return kind;
    }
    return null;
}

fn layoutOf(breakpoint: ?*anyopaque) Layout {
    const tag = @intFromPtr(gtk.g_object_get_data(breakpoint.?, "orca-health-layout"));
    return @enumFromInt(@as(std.meta.Tag(Layout), @intCast(tag - 1)));
}

fn layoutApplied(breakpoint: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.health.layout = layoutOf(breakpoint);
    applyLayout(self);
}

fn layoutUnapplied(breakpoint: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    if (self.health.layout != layoutOf(breakpoint)) return;
    self.health.layout = .wide;
    applyLayout(self);
}

fn addLayout(self: *App, bin: *gtk.Widget, condition: [*:0]const u8, layout: Layout) void {
    const parsed = adw.adw_breakpoint_condition_parse(condition) orelse return;
    const breakpoint = adw.adw_breakpoint_new(parsed);
    gtk.g_object_set_data(breakpoint, "orca-health-layout", @ptrFromInt(@as(usize, @intFromEnum(layout)) + 1));
    _ = gtk.signalConnect(breakpoint, "apply", gtk.callback(layoutApplied), self);
    _ = gtk.signalConnect(breakpoint, "unapply", gtk.callback(layoutUnapplied), self);
    adw.adw_breakpoint_bin_add_breakpoint(gtk.cast(adw.BreakpointBin, bin), breakpoint);
}

fn applyLayout(self: *App) void {
    const layout = self.health.layout;
    if (self.health.panel) |panel| gtk.gtk_widget_set_visible(panel, if (panelShown(layout)) gtk.true_ else gtk.false_);
    if (self.health.page) |page| {
        if (layout == .small) gtk.gtk_widget_add_css_class(page, "health-small") else gtk.gtk_widget_remove_css_class(page, "health-small");
    }
    if (self.health.title_row) |row|
        gtk.gtk_orientable_set_orientation(gtk.cast(gtk.Orientable, row), if (layout == .small) gtk.ORIENTATION_VERTICAL else gtk.ORIENTATION_HORIZONTAL);
    if (self.health.title_end) |end| gtk.gtk_widget_set_halign(end, if (layout == .small) gtk.ALIGN_START else gtk.ALIGN_FILL);
    const cards = self.health.cards orelse return;
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, cards));
    while (child) |widget| : (child = gtk.gtk_widget_get_next_sibling(widget)) {
        fitCard(cardOf(gtk.g_object_get_data(widget, "orca-health-card") orelse continue), layout);
    }
}

pub fn build(self: *App) *gtk.Widget {
    const title = page_ui.title("Library Health");
    gtk.gtk_widget_add_css_class(title.widget, "health-title");
    gtk.gtk_label_set_text(title.meta, "Keep your music library clean, complete, and sounding its best.");
    gtk.gtk_widget_remove_css_class(gtk.cast(gtk.Widget, title.meta), "numeric");
    gtk.gtk_widget_add_css_class(gtk.cast(gtk.Widget, title.meta), "health-tagline");
    gtk.gtk_label_set_ellipsize(title.meta, gtk.ELLIPSIZE_NONE);
    gtk.gtk_label_set_wrap(title.meta, gtk.true_);
    title.add(lastAnalyzedBlock(self));
    title.add(analyzeButton(self));
    self.health.title_row = title.widget;
    self.health.title_end = gtk.cast(gtk.Widget, title.end);

    const cards = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 8);
    gtk.gtk_widget_add_css_class(cards, "health-cards");
    self.health.cards = gtk.cast(gtk.Box, cards);

    const quiet_toggle = gtk.gtk_button_new_with_label("Show kinds with no issues");
    gtk.gtk_widget_add_css_class(quiet_toggle, "flat");
    gtk.gtk_widget_add_css_class(quiet_toggle, "health-quiet-toggle");
    gtk.gtk_widget_set_halign(quiet_toggle, gtk.ALIGN_START);
    _ = gtk.signalConnect(quiet_toggle, "clicked", gtk.callback(quietToggled), self);
    self.health.quiet_toggle = quiet_toggle;
    const quiet = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(quiet, "health-quiet");
    self.health.quiet = gtk.cast(gtk.Box, quiet);
    const quiet_section = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 8);
    gtk.gtk_widget_add_css_class(quiet_section, "health-quiet-section");
    gtk.gtk_box_append(gtk.cast(gtk.Box, quiet_section), quiet_toggle);
    gtk.gtk_box_append(gtk.cast(gtk.Box, quiet_section), quiet);
    self.health.quiet_section = quiet_section;
    showQuiet(self);

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(content, "health-body");
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), summaryBlock(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), cards);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), quiet_section);

    const column = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), title.widget);
    gtk.gtk_box_append(gtk.cast(gtk.Box, column), content);

    const scroller = gtk.gtk_scrolled_window_new();
    self.health.scroller = gtk.cast(gtk.ScrolledWindow, scroller);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(scrollerDestroyed), self);
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_widget_set_hexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), column);

    const page = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(page, "health-page");
    gtk.gtk_box_append(gtk.cast(gtk.Box, page), scroller);
    gtk.gtk_box_append(gtk.cast(gtk.Box, page), panelBlock(self));
    self.health.page = page;
    explain(self);

    const bin = adw.adw_breakpoint_bin_new();
    gtk.gtk_widget_set_size_request(bin, 1, 1);
    adw.adw_breakpoint_bin_set_child(gtk.cast(adw.BreakpointBin, bin), page);
    addLayout(self, bin, "max-width: 1300sp", .tight);
    addLayout(self, bin, "max-width: 1100sp", .panelless);
    addLayout(self, bin, "max-width: 900sp", .compact);
    addLayout(self, bin, "max-width: 640sp", .small);

    const view = bin;
    return view;
}

fn unanalysedCount(self: *App, library: liborca.LibraryHandle) u64 {
    if (self.task == .analysis) return 0;
    return self.runtime.libraryUnanalyzedCount(library) catch 0;
}

pub fn updateBanner(self: *App) void {
    const library = self.library orelse return;
    if (unanalysedCount(self, library) != self.health.unanalysed_shown) reload(self);
}

fn showStat(label_widget: ?*gtk.Label, count: u64) void {
    var buffer: [32]u8 = undefined;
    gtk.gtk_label_set_text(label_widget orelse return, strings.format(&buffer, "{f}", .{strings.grouped(count)}).ptr);
}

fn showOverview(self: *App, library: liborca.LibraryHandle, attention: u64) void {
    if (self.health.headline) |headline| {
        var buffer: [96]u8 = undefined;
        gtk.gtk_label_set_text(headline, if (attention == 0)
            "Your library is in great shape."
        else if (attention == 1)
            "1 item may need your attention."
        else
            strings.format(&buffer, "{f} items may need your attention.", .{strings.grouped(attention)}).ptr);
    }
    if (self.health.summary) |summary| gtk.gtk_label_set_text(summary, if (attention == 0)
        "Orca found nothing to fix. Scans and analysis keep checking as your library changes."
    else
        "We found a few things that could be improved. Tackle the items below to get the most out of your music collection.");

    const stats = self.runtime.libraryStats(library) catch return;
    showStat(self.health.album_count, stats.releases);
    showStat(self.health.track_count, stats.tracks);
    showStat(self.health.artist_count, stats.artists);
    if (self.health.library_size) |size_label| {
        const size = gtk.g_format_size(stats.total_bytes);
        defer gtk.g_free(size);
        gtk.gtk_label_set_text(size_label, size);
    }
    if (self.health.last_analyzed) |when| {
        var buffer: [64]u8 = undefined;
        gtk.gtk_label_set_text(when, details.recentMomentText(&buffer, stats.last_analysis_at).ptr);
    }
    if (self.health.analyze_label) |text|
        gtk.gtk_label_set_text(text, if (stats.last_analysis_at == null) "Analyze" else "Analyze Again");
}

fn removeChildren(box: *gtk.Box) void {
    while (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, box))) |child| gtk.gtk_box_remove(box, child);
}

fn focusedCard(self: *App, cards: *gtk.Box) ?*Card {
    const root = self.window orelse return null;
    const focus = gtk.gtk_window_get_focus(root) orelse return null;
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, cards));
    while (child) |widget| : (child = gtk.gtk_widget_get_next_sibling(widget)) {
        if (focus != widget and gtk.gtk_widget_is_ancestor(focus, widget) == 0) continue;
        return cardOf(gtk.g_object_get_data(widget, "orca-health-card") orelse return null);
    }
    return null;
}

pub fn reload(self: *App) void {
    const cards = self.health.cards orelse return;
    const quiet = self.health.quiet orelse return;
    const scroller = self.health.scroller orelse return;
    const scrolled = self.health.restore_scroll orelse
        gtk.gtk_adjustment_get_value(gtk.gtk_scrolled_window_get_vadjustment(scroller));
    const focused: ?struct { kind: ?Kind } = if (focusedCard(self, cards)) |card| .{ .kind = card.kind } else null;
    removeChildren(cards);
    removeChildren(quiet);
    const library = self.library orelse return;

    const total = self.runtime.libraryHealthIssueCount(library) catch 0;
    self.health.issues_shown = total;
    if (self.health.count) |count_label| {
        var count_buffer: [16]u8 = undefined;
        const text: [:0]const u8 = if (total == 0) "" else strings.printZ(&count_buffer, "{d}", .{total}) catch "";
        gtk.gtk_label_set_text(count_label, text.ptr);
    }
    const unanalysed = unanalysedCount(self, library);
    self.health.unanalysed_shown = unanalysed;
    showOverview(self, library, total);

    const summary = self.runtime.libraryHealthSummary(library) catch return self.toast("Could not read the library's health");
    var entries: [std.meta.fields(Kind).len + 1]Entry = undefined;
    var len: usize = 0;
    var present: std.EnumSet(Kind) = .initEmpty();
    for (summary.items()) |item| {
        present.insert(item.kind);
        entries[len] = .{ .kind = item.kind, .severity = item.severity, .count = item.count, .files = item.files, .bytes = item.bytes };
        len += 1;
    }
    if (unanalysed != 0) {
        entries[len] = .{ .kind = null, .severity = .information, .count = unanalysed, .files = unanalysed, .bytes = 0 };
        len += 1;
    }
    std.mem.sort(Entry, entries[0..len], {}, moreUrgent);

    for (entries[0..len]) |entry| {
        const widget = kindCard(self, entry) orelse continue;
        gtk.gtk_box_append(cards, widget);
        const wanted = focused orelse continue;
        if (wanted.kind != entry.kind) continue;
        const card = cardOf(gtk.g_object_get_data(widget, "orca-health-card"));
        _ = gtk.gtk_widget_grab_focus(if (card.files) |files| files.toggle else card.action);
    }
    gtk.gtk_widget_set_visible(gtk.cast(gtk.Widget, cards), if (len == 0) gtk.false_ else gtk.true_);

    var quiet_count: usize = 0;
    if (unanalysed == 0 and self.task != .analysis) {
        gtk.gtk_box_append(quiet, quietRow(null));
        quiet_count += 1;
    }
    for (std.enums.values(Kind)) |kind| {
        if (present.contains(kind)) continue;
        gtk.gtk_box_append(quiet, quietRow(kind));
        quiet_count += 1;
    }
    if (self.health.quiet_section) |section| gtk.gtk_widget_set_visible(section, if (quiet_count == 0) gtk.false_ else gtk.true_);

    if (self.health.explained) |kind| {
        if (!present.contains(kind) or !self.health.expanded.contains(kind)) self.health.explained = firstExpanded(self);
    }
    explain(self);

    if (self.health.restore_scroll == null) _ = gtk.g_idle_add(restoreScroll, self);
    self.health.restore_scroll = scrolled;
}

fn scrollerDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    state(data).health.scroller = null;
}

fn restoreScroll(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const value = self.health.restore_scroll orelse return gtk.false_;
    self.health.restore_scroll = null;
    const scroller = self.health.scroller orelse return gtk.false_;
    gtk.gtk_adjustment_set_value(gtk.gtk_scrolled_window_get_vadjustment(scroller), value);
    return gtk.false_;
}
