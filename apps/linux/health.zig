//! The Health page: what liborca found wrong with the library, one card per
//! kind of issue, most severe first as the engine orders them. A card opens
//! onto its files in bounded pages. Each issue carries the action liborca
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
const loved = @import("loved.zig");
const window = @import("window.zig");

const App = app.App;

pub const State = struct {
    cards: ?*gtk.Box = null,
    scroller: ?*gtk.ScrolledWindow = null,
    body: ?*gtk.Stack = null,
    meta: ?*gtk.Label = null,
    count: ?*gtk.Label = null,
    analysis: ?*gtk.Widget = null,
    unanalysed: ?*gtk.Label = null,
    album_count: ?*gtk.Label = null,
    song_count: ?*gtk.Label = null,
    artist_count: ?*gtk.Label = null,
    issues_shown: u64 = 0,
    restore_scroll: ?f64 = null,
    expanded: std.EnumSet(liborca.HealthIssueKind) = .initEmpty(),
    loaded: std.EnumArray(liborca.HealthIssueKind, u32) = .initFill(0),
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

const Issue = struct {
    self: *App,
    file_id: i64,
    kind: liborca.HealthIssueKind,
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

fn kindTitle(kind: liborca.HealthIssueKind) [*:0]const u8 {
    return switch (kind) {
        .missing_metadata => "Missing tags",
        .missing_track_number => "No track number",
        .album_artist_anomaly => "Inconsistent album artist",
        .artwork_problem => "Cover art problem",
        .missing_analysis => "Too short or silent",
        .clipping => "Clipping",
        .excessive_silence => "Long silence",
        .technical_anomaly => "Unusual file",
        .corrupt_audio => "Damaged audio",
        .exact_duplicate => "Exact duplicate",
        .likely_duplicate => "Likely duplicate",
        .unreadable_file => "Unreadable file",
        .recording_mismatch => "Different recording",
    };
}

fn kindIcon(kind: liborca.HealthIssueKind) [*:0]const u8 {
    return switch (kind) {
        .missing_metadata => "document-edit-symbolic",
        .missing_track_number => "view-list-ordered-symbolic",
        .album_artist_anomaly => "avatar-default-symbolic",
        .artwork_problem => "image-missing-symbolic",
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

fn kindExplanation(kind: liborca.HealthIssueKind) [*:0]const u8 {
    return switch (kind) {
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

fn findDuplicatesClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.startDuplicates(state(data));
}

fn analyseClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.startAnalysis(state(data));
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
    kind: liborca.HealthIssueKind,
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

fn addRowAction(group: *gtk.GSimpleActionGroup, name: [*:0]const u8, handler: gtk.GCallback, issue: *Issue) void {
    const action = gtk.g_simple_action_new(name, null).?;
    _ = gtk.signalConnect(action, "activate", handler, issue);
    gtk.g_action_map_add_action(gtk.cast(gtk.GActionMap, group), gtk.cast(gtk.GAction, action));
    gtk.g_object_unref(action);
}

/// A "Fix" menu of Match and Edit Tags, acting through actions scoped to the
/// row so each item knows its Track.
fn fixMenu(row: *gtk.Widget, issue: *Issue) void {
    const group = gtk.g_simple_action_group_new();
    addRowAction(group, "match", gtk.callback(matchActivated), issue);
    addRowAction(group, "edit", gtk.callback(editActivated), issue);
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
    gtk.gtk_widget_set_tooltip_text(button, "Find this song on MusicBrainz, or edit its tags");
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

fn reviewMatchesClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    window.showPage(state(data), .matches);
}

fn addGroupAction(header: *gtk.Widget, self: *App, kind: liborca.HealthIssueKind) void {
    switch (kind) {
        .recording_mismatch => {
            const button = gtk.gtk_button_new_with_label("Review");
            gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
            gtk.gtk_widget_set_tooltip_text(button, "Review the proposed corrections in Matches");
            _ = gtk.signalConnect(button, "clicked", gtk.callback(reviewMatchesClicked), self);
            gtk.gtk_box_append(gtk.cast(gtk.Box, header), button);
        },
        else => {},
    }
}

const KindCard = struct {
    self: *App,
    kind: liborca.HealthIssueKind,
    count: u64,
    loaded: u32 = 0,
    list: *gtk.ListBox,
    body: *gtk.Widget,
    more: *gtk.Widget,
    toggle: *gtk.Widget,
};

fn kindCardOf(data: ?*anyopaque) *KindCard {
    return @ptrCast(@alignCast(data.?));
}

fn freeKindCard(data: ?*anyopaque) callconv(.c) void {
    const card = kindCardOf(data);
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

fn loadMore(card: *KindCard) void {
    const self = card.self;
    const library = self.library orelse return;
    var page = self.runtime.libraryHealthIssuePageOfKind(library, card.kind, app.page_size, card.loaded) catch
        return self.toast("Could not read the issues");
    defer page.deinit();
    for (page.items) |item| {
        const row = issueRow(self, item) orelse continue;
        gtk.gtk_list_box_append(card.list, row);
    }
    card.loaded += @intCast(page.items.len);
    const exhausted = page.items.len < app.page_size or card.loaded >= card.count;
    gtk.gtk_widget_set_visible(card.more, if (exhausted) gtk.false_ else gtk.true_);
}

fn showMoreClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const card = kindCardOf(data);
    loadMore(card);
    card.self.health.loaded.set(card.kind, card.loaded);
}

fn setExpanded(card: *KindCard, expanded: bool) void {
    gtk.gtk_widget_set_visible(card.body, if (expanded) gtk.true_ else gtk.false_);
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, card.toggle), if (expanded) "pan-up-symbolic" else "pan-down-symbolic");
    gtk.gtk_widget_set_tooltip_text(card.toggle, if (expanded) "Hide the files" else "Show the files");
    if (expanded and card.loaded == 0) loadMore(card);
}

fn expandToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const card = kindCardOf(data);
    const expanded = gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button)) != 0;
    card.self.health.expanded.setPresent(card.kind, expanded);
    setExpanded(card, expanded);
    card.self.health.loaded.set(card.kind, card.loaded);
}

fn severityClass(severity: liborca.HealthSeverity) [*:0]const u8 {
    return switch (severity) {
        .information => "health-information",
        .warning => "health-warning",
        .error_severity => "health-error",
    };
}

fn kindCard(self: *App, summary: liborca.HealthKindSummary) ?*gtk.Widget {
    const card = self.allocator.create(KindCard) catch return null;

    const icon = gtk.gtk_image_new_from_icon_name(kindIcon(summary.kind));
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 24);
    gtk.gtk_widget_set_valign(icon, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(icon, "health-kind-icon");
    gtk.gtk_widget_add_css_class(icon, severityClass(summary.severity));

    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    const heading = gtk.gtk_label_new(kindTitle(summary.kind));
    gtk.gtk_widget_add_css_class(heading, "health-card-title");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, heading), 0);
    const explanation = gtk.gtk_label_new(kindExplanation(summary.kind));
    gtk.gtk_widget_add_css_class(explanation, "meta");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, explanation), 0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, explanation), gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), heading);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), explanation);

    const tally = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(tally, "health-tally");
    gtk.gtk_widget_set_valign(tally, gtk.ALIGN_CENTER);
    var buffer: [32]u8 = undefined;
    const number = gtk.gtk_label_new(strings.format(&buffer, "{f}", .{strings.grouped(summary.count)}).ptr);
    gtk.gtk_widget_add_css_class(number, "health-tally-number");
    gtk.gtk_widget_add_css_class(number, "numeric");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, number), 0);
    const unit = gtk.gtk_label_new(if (summary.count == 1) "file" else "files");
    gtk.gtk_widget_add_css_class(unit, "meta");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, unit), 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, tally), number);
    gtk.gtk_box_append(gtk.cast(gtk.Box, tally), unit);

    const toggle = gtk.gtk_toggle_button_new();
    gtk.gtk_widget_add_css_class(toggle, "flat");
    gtk.gtk_widget_add_css_class(toggle, "circular");
    gtk.gtk_widget_set_valign(toggle, gtk.ALIGN_CENTER);

    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    gtk.gtk_widget_add_css_class(header, "health-card-header");
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), text);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), tally);
    addGroupAction(header, self, summary.kind);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), toggle);

    const list = gtk.gtk_list_box_new();
    gtk.gtk_list_box_set_selection_mode(gtk.cast(gtk.ListBox, list), gtk.SELECTION_NONE);
    gtk.gtk_widget_add_css_class(list, "health-issues");
    const more = gtk.gtk_button_new_with_label("Show more");
    gtk.gtk_widget_add_css_class(more, "flat");
    gtk.gtk_widget_add_css_class(more, "health-more");
    gtk.gtk_widget_set_visible(more, gtk.false_);
    const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), list);
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), more);

    const widget = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(widget, "health-card");
    gtk.gtk_box_append(gtk.cast(gtk.Box, widget), header);
    gtk.gtk_box_append(gtk.cast(gtk.Box, widget), body);

    card.* = .{
        .self = self,
        .kind = summary.kind,
        .count = summary.count,
        .list = gtk.cast(gtk.ListBox, list),
        .body = body,
        .more = more,
        .toggle = toggle,
    };
    gtk.g_object_set_data_full(widget, "orca-health-kind", card, freeKindCard);
    _ = gtk.signalConnect(more, "clicked", gtk.callback(showMoreClicked), card);

    const expanded = self.health.expanded.contains(summary.kind);
    setExpanded(card, expanded);
    if (expanded) {
        while (card.loaded < self.health.loaded.get(summary.kind) and gtk.gtk_widget_get_visible(more) != 0) {
            const before = card.loaded;
            loadMore(card);
            if (card.loaded == before) break;
        }
        self.health.loaded.set(summary.kind, card.loaded);
    }
    gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, toggle), if (expanded) gtk.true_ else gtk.false_);
    _ = gtk.signalConnect(toggle, "toggled", gtk.callback(expandToggled), card);
    return widget;
}

fn analysisCard(self: *App) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name("audio-volume-high-symbolic");
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), 24);
    gtk.gtk_widget_set_valign(icon, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(icon, "health-kind-icon");
    gtk.gtk_widget_add_css_class(icon, "health-information");

    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    const heading = gtk.gtk_label_new("");
    self.health.unanalysed = gtk.cast(gtk.Label, heading);
    gtk.gtk_widget_add_css_class(heading, "health-card-title");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, heading), 0);
    const explanation = gtk.gtk_label_new("Analysis measures loudness for ReplayGain and finds clipping, silence, damaged audio and duplicates.");
    gtk.gtk_widget_add_css_class(explanation, "meta");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, explanation), 0);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, explanation), gtk.true_);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), heading);
    gtk.gtk_box_append(gtk.cast(gtk.Box, text), explanation);

    const analyse = gtk.gtk_button_new_with_label("Analyse");
    gtk.gtk_widget_set_valign(analyse, gtk.ALIGN_CENTER);
    gtk.gtk_widget_add_css_class(analyse, "suggested-action");
    _ = gtk.signalConnect(analyse, "clicked", gtk.callback(analyseClicked), self);

    const header = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    gtk.gtk_widget_add_css_class(header, "health-card-header");
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), icon);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), text);
    gtk.gtk_box_append(gtk.cast(gtk.Box, header), analyse);
    const widget = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(widget, "health-card");
    gtk.gtk_widget_add_css_class(widget, "health-analysis");
    gtk.gtk_box_append(gtk.cast(gtk.Box, widget), header);
    gtk.gtk_widget_set_visible(widget, gtk.false_);
    self.health.analysis = widget;
    return widget;
}

fn statsRow(self: *App) *gtk.Widget {
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(row, "health-stats");
    gtk.gtk_widget_set_halign(row, gtk.ALIGN_START);
    const albums_stat = loved.stat("ALBUMS");
    self.health.album_count = albums_stat.number;
    const songs_stat = loved.stat("SONGS");
    self.health.song_count = songs_stat.number;
    const artists_stat = loved.stat("ARTISTS");
    self.health.artist_count = artists_stat.number;
    for ([_]*gtk.Widget{ albums_stat.widget, songs_stat.widget, artists_stat.widget }) |widget|
        gtk.gtk_box_append(gtk.cast(gtk.Box, row), widget);
    return row;
}

pub fn build(self: *App) *gtk.Widget {
    const cards = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    self.health.cards = gtk.cast(gtk.Box, cards);

    const empty = adw.adw_status_page_new();
    adw.adw_status_page_set_icon_name(gtk.cast(adw.StatusPage, empty), "object-select-symbolic");
    adw.adw_status_page_set_title(gtk.cast(adw.StatusPage, empty), "Nothing to fix");
    adw.adw_status_page_set_description(
        gtk.cast(adw.StatusPage, empty),
        "Scans report missing tags and damaged files here. Measure loudness and find duplicates from Settings or the button above.",
    );
    const body = gtk.gtk_stack_new();
    self.health.body = gtk.cast(gtk.Stack, body);
    gtk.gtk_widget_set_vexpand(body, gtk.true_);
    _ = gtk.gtk_stack_add_named(self.health.body.?, cards, "list");
    _ = gtk.gtk_stack_add_named(self.health.body.?, empty, "empty");

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 10);
    gtk.gtk_widget_add_css_class(content, "health-body");
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), statsRow(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), analysisCard(self));
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), body);

    const scroller = gtk.gtk_scrolled_window_new();
    self.health.scroller = gtk.cast(gtk.ScrolledWindow, scroller);
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), content);

    const title = page_ui.title("Library Health");
    self.health.meta = title.meta;
    const find = gtk.gtk_button_new_with_label("Find Duplicates");
    gtk.gtk_widget_set_tooltip_text(find, "Compare measured audio across the library");
    _ = gtk.signalConnect(find, "clicked", gtk.callback(findDuplicatesClicked), self);
    title.add(find);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), page_ui.header());
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), page_ui.withTitle(title, scroller));
    return view;
}

/// Offers analysis while files owe it and none is running.
pub fn updateBanner(self: *App) void {
    const card = self.health.analysis orelse return;
    const library = self.library orelse return gtk.gtk_widget_set_visible(card, gtk.false_);
    const unanalyzed = if (self.task == .analysis) 0 else self.runtime.libraryUnanalyzedCount(library) catch 0;
    if (unanalyzed != 0) if (self.health.unanalysed) |label| {
        var buffer: [64]u8 = undefined;
        gtk.gtk_label_set_text(label, strings.format(&buffer, "{f} {s} not analysed", .{
            strings.grouped(unanalyzed),
            if (unanalyzed == 1) "file" else "files",
        }).ptr);
    };
    gtk.gtk_widget_set_visible(card, if (unanalyzed == 0) gtk.false_ else gtk.true_);
}

fn showStat(label: ?*gtk.Label, count: u64) void {
    var buffer: [32]u8 = undefined;
    gtk.gtk_label_set_text(label orelse return, strings.format(&buffer, "{f}", .{strings.grouped(count)}).ptr);
}

fn removeCards(cards: *gtk.Box) void {
    while (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, cards))) |child| gtk.gtk_box_remove(cards, child);
}

fn focusedKind(self: *App, cards: *gtk.Box) ?liborca.HealthIssueKind {
    const root = self.window orelse return null;
    const focus = gtk.gtk_window_get_focus(root) orelse return null;
    var child = gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, cards));
    while (child) |widget| : (child = gtk.gtk_widget_get_next_sibling(widget)) {
        if (focus != widget and gtk.gtk_widget_is_ancestor(focus, widget) == 0) continue;
        const data = gtk.g_object_get_data(widget, "orca-health-kind") orelse return null;
        return kindCardOf(data).kind;
    }
    return null;
}

pub fn reload(self: *App) void {
    updateBanner(self);
    const cards = self.health.cards orelse return;
    const scroller = self.health.scroller orelse return;
    const scrolled = self.health.restore_scroll orelse
        gtk.gtk_adjustment_get_value(gtk.gtk_scrolled_window_get_vadjustment(scroller));
    const focused = focusedKind(self, cards);
    removeCards(cards);
    const library = self.library orelse return;
    showStat(self.health.album_count, self.runtime.libraryReleaseCount(library) catch 0);
    showStat(self.health.song_count, self.runtime.libraryTrackCount(library) catch 0);
    showStat(self.health.artist_count, self.runtime.libraryArtistCount(library) catch 0);
    const total = self.runtime.libraryHealthIssueCount(library) catch 0;
    self.health.issues_shown = total;
    if (self.health.count) |label| {
        var count_buffer: [16]u8 = undefined;
        const text: [:0]const u8 = if (total == 0) "" else strings.printZ(&count_buffer, "{d}", .{total}) catch "";
        gtk.gtk_label_set_text(label, text.ptr);
    }
    if (self.health.meta) |meta| {
        var buffer: [64]u8 = undefined;
        const text = if (total == 1) "1 issue" else strings.format(&buffer, "{f} issues", .{strings.grouped(total)});
        gtk.gtk_label_set_text(meta, text.ptr);
    }
    if (self.health.body) |body| gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else "list");
    const summary = self.runtime.libraryHealthSummary(library) catch return self.toast("Could not read the library's health");
    for (summary.items()) |entry| {
        const widget = kindCard(self, entry) orelse continue;
        gtk.gtk_box_append(cards, widget);
        if (focused == entry.kind) {
            const card = kindCardOf(gtk.g_object_get_data(widget, "orca-health-kind"));
            _ = gtk.gtk_widget_grab_focus(card.toggle);
        }
    }
    if (self.health.restore_scroll == null) _ = gtk.g_idle_add(restoreScroll, self);
    self.health.restore_scroll = scrolled;
}

fn restoreScroll(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const value = self.health.restore_scroll orelse return gtk.false_;
    self.health.restore_scroll = null;
    const scroller = self.health.scroller orelse return gtk.false_;
    gtk.gtk_adjustment_set_value(gtk.gtk_scrolled_window_get_vadjustment(scroller), value);
    return gtk.false_;
}
