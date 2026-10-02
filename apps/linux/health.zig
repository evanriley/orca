//! The Health page: what liborca found wrong with the library, most severe
//! first as the engine orders it, one bounded page. Each issue carries the
//! action liborca offers to resolve it, and can be dismissed until its file
//! changes.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const jobs = @import("jobs.zig");
const tags = @import("tags.zig");
const matches = @import("matches.zig");

const App = app.App;

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

fn severityIcon(severity: liborca.HealthSeverity) [*:0]const u8 {
    return switch (severity) {
        .information => "dialog-information-symbolic",
        .warning => "dialog-warning-symbolic",
        .error_severity => "dialog-error-symbolic",
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

pub fn build(self: *App) *gtk.Widget {
    const list = gtk.gtk_list_box_new();
    self.health_list = gtk.cast(gtk.ListBox, list);
    gtk.gtk_list_box_set_selection_mode(self.health_list.?, gtk.SELECTION_NONE);
    gtk.gtk_widget_add_css_class(list, "boxed-list");
    const note = gtk.gtk_label_new("");
    self.health_note = gtk.cast(gtk.Label, note);
    gtk.gtk_widget_add_css_class(note, "dim-label");
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, note), gtk.true_);
    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 12);
    gtk.gtk_widget_add_css_class(content, "album-page");
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), list);
    gtk.gtk_box_append(gtk.cast(gtk.Box, content), note);
    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), 900);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), content);
    const scroller = gtk.gtk_scrolled_window_new();
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), clamp);

    const empty = adw.adw_status_page_new();
    adw.adw_status_page_set_icon_name(gtk.cast(adw.StatusPage, empty), "emblem-ok-symbolic");
    adw.adw_status_page_set_title(gtk.cast(adw.StatusPage, empty), "Nothing to fix");
    adw.adw_status_page_set_description(
        gtk.cast(adw.StatusPage, empty),
        "Scans report missing tags and damaged files here. Measure loudness and find duplicates from Preferences or the button above.",
    );
    const body = gtk.gtk_stack_new();
    self.health_body = gtk.cast(gtk.Stack, body);
    _ = gtk.gtk_stack_add_named(self.health_body.?, scroller, "list");
    _ = gtk.gtk_stack_add_named(self.health_body.?, empty, "empty");

    const header = adw.adw_header_bar_new();
    const title = adw.adw_window_title_new("Health", "");
    self.health_title = gtk.cast(adw.WindowTitle, title);
    adw.adw_header_bar_set_title_widget(gtk.cast(adw.HeaderBar, header), title);
    const find = gtk.gtk_button_new_with_label("Find Duplicates");
    gtk.gtk_widget_set_tooltip_text(find, "Compare measured audio across the library");
    _ = gtk.signalConnect(find, "clicked", gtk.callback(findDuplicatesClicked), self);
    adw.adw_header_bar_pack_end(gtk.cast(adw.HeaderBar, header), find);

    const banner = adw.adw_banner_new("");
    self.health_banner = gtk.cast(adw.Banner, banner);
    adw.adw_banner_set_button_label(self.health_banner.?, "Analyse");
    _ = gtk.signalConnect(banner, "button-clicked", gtk.callback(analyseClicked), self);

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), banner);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), body);
    return view;
}

/// Offers analysis while files owe it and none is running.
pub fn updateBanner(self: *App) void {
    const banner = self.health_banner orelse return;
    const library = self.library orelse return adw.adw_banner_set_revealed(banner, gtk.false_);
    const unanalyzed = if (self.task == .analysis) 0 else self.runtime.libraryUnanalyzedCount(library) catch 0;
    if (unanalyzed != 0) {
        var buffer: [64]u8 = undefined;
        adw.adw_banner_set_title(banner, strings.format(&buffer, "{f} {s} not analysed", .{
            strings.grouped(unanalyzed),
            if (unanalyzed == 1) "file" else "files",
        }).ptr);
    }
    adw.adw_banner_set_revealed(banner, if (unanalyzed == 0) gtk.false_ else gtk.true_);
}

pub fn reload(self: *App) void {
    updateBanner(self);
    const list = self.health_list orelse return;
    gtk.gtk_list_box_remove_all(list);
    const library = self.library orelse return;
    const total = self.runtime.libraryHealthIssueCount(library) catch 0;
    if (self.health_count) |label| {
        var count_buffer: [16]u8 = undefined;
        const text: [:0]const u8 = if (total == 0) "" else strings.printZ(&count_buffer, "{d}", .{total}) catch "";
        gtk.gtk_label_set_text(label, text.ptr);
    }
    var buffer: [512]u8 = undefined;
    if (self.health_title) |title| {
        const text: [:0]const u8 = if (total == 1) "1 issue" else strings.printZ(&buffer, "{d} issues", .{total}) catch "";
        adw.adw_window_title_set_subtitle(title, text.ptr);
    }
    if (self.health_body) |body| gtk.gtk_stack_set_visible_child_name(body, if (total == 0) "empty" else "list");
    var page = self.runtime.libraryHealthIssuePage(library, app.page_size, 0) catch return;
    defer page.deinit();
    for (page.items) |item| {
        const issue = self.allocator.create(Issue) catch continue;
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
        adw.adw_preferences_row_set_use_markup(gtk.cast(adw.PreferencesRow, row), gtk.false_);
        adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, row), kindTitle(item.kind));
        const subtitle = if (item.details.len != 0)
            strings.printZ(&buffer, "{s}\n{s}", .{ item.path, item.details }) catch ""
        else
            strings.terminated(&buffer, item.path);
        adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, row), subtitle.ptr);
        adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, row), 3);
        const icon = gtk.gtk_image_new_from_icon_name(severityIcon(item.severity));
        gtk.gtk_widget_add_css_class(icon, switch (item.severity) {
            .information => "dim-label",
            .warning => "warning",
            .error_severity => "error",
        });
        adw.adw_action_row_add_prefix(gtk.cast(adw.ActionRow, row), icon);
        addActions(row, issue, item.action);
        gtk.gtk_list_box_append(list, row);
    }
    if (self.health_note) |note| {
        const text: [:0]const u8 = if (total > page.items.len)
            strings.printZ(&buffer, "Showing the first {d} of {d}. orca-cli health lists them all.", .{ page.items.len, total }) catch ""
        else
            "";
        gtk.gtk_label_set_text(note, text.ptr);
    }
}
