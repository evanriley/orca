//! The Health page: what liborca found wrong with the library as seven fixed
//! rows, each with its count, what it means and the one action that resolves
//! it. A row opens onto an explanation and, where the findings are per file,
//! its files in bounded pages, each with the action liborca offers for it.
//! Audio findings are reviewed on Audio Problems.

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
const duplicates = @import("duplicates.zig");
const audio_problems = @import("audio_problems.zig");

const App = app.App;

const Kind = liborca.HealthIssueKind;

const first_page: u32 = 50;

const content_width: c_int = 976;

pub const Row = enum { duplicates, mismatched, clipping, loudness, unmatched, artwork, missing_files };

const Tone = enum { caution, neutral, warn };

const RowInfo = struct {
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
    detail: [*:0]const u8,
    about: [*:0]const u8,
    icon: [*:0]const u8,
    tone: Tone,
    action: [*:0]const u8,
    tooltip: [*:0]const u8,
    unit: []const u8,
    kinds: []const Kind,
};

fn info(row: Row) RowInfo {
    return switch (row) {
        .duplicates => .{
            .title = "Duplicates",
            .subtitle = "Exact or near-identical recordings",
            .detail = "",
            .about = "The same recording is in the library more than once, as the same audio or audio that closely resembles it. Review compares the copies side by side; Orca never deletes a file.",
            .icon = "edit-copy-symbolic",
            .tone = .caution,
            .action = "Review",
            .tooltip = "Compare the copies in Duplicates",
            .unit = "track",
            .kinds = &.{ .exact_duplicate, .likely_duplicate },
        },
        .mismatched => .{
            .title = "Mismatched metadata",
            .subtitle = "Album artist, dates or numbering disagree",
            .detail = "Mostly album artist and year",
            .about = "These tracks are missing a title, artist, album or album artist, or their track numbers are missing or collide. Match finds them on MusicBrainz and Edit Tags corrects them by hand; both change the library, not the files.",
            .icon = "orca-genres-symbolic",
            .tone = .caution,
            .action = "Review",
            .tooltip = "Show the tracks, with Match and Edit Tags on each",
            .unit = "track",
            .kinds = &.{ .album_artist_anomaly, .missing_metadata, .missing_track_number, .technical_anomaly },
        },
        .clipping => .{
            .title = "Possible clipping",
            .subtitle = "Samples at or above digital full scale",
            .detail = "Peak ≥ 0 dBFS detected",
            .about = "These tracks contain samples at or above digital full scale. This doesn't necessarily mean the recording is audibly distorted.",
            .icon = "orca-wave-symbolic",
            .tone = .caution,
            .action = "Review",
            .tooltip = "Review the tracks in Audio Problems",
            .unit = "track",
            .kinds = &.{.clipping},
        },
        .loudness => .{
            .title = "Missing loudness analysis",
            .subtitle = "Needed before ReplayGain can apply",
            .detail = "Enables consistent playback volume",
            .about = "Orca has not measured these files yet, or could not because the audio is too short or silent, so they play without ReplayGain. Analyze measures loudness and checks for clipping, damage and duplicates; stopping it keeps what is done.",
            .icon = "orca-gain-symbolic",
            .tone = .neutral,
            .action = "Analyze",
            .tooltip = "Measure loudness for ReplayGain across the library",
            .unit = "track",
            .kinds = &.{.missing_analysis},
        },
        .unmatched => .{
            .title = "Unmatched releases",
            .subtitle = "No confident MusicBrainz match yet",
            .detail = "May be live recordings, promos or rare releases",
            .about = "No MusicBrainz release matches these albums with confidence yet. Review opens Matches, where a candidate can be accepted or searched for again.",
            .icon = "orca-matches-symbolic",
            .tone = .neutral,
            .action = "Review",
            .tooltip = "Review the albums in Matches",
            .unit = "release",
            .kinds = &.{},
        },
        .artwork => .{
            .title = "Missing artwork",
            .subtitle = "No front cover found locally or embedded",
            .detail = "Cover Art Archive candidates available",
            .about = "These tracks have no embedded or folder cover, and none was fetched for their album. An album with a MusicBrainz ID fetches its cover from the Cover Art Archive; covers are kept in the library, never written to files.",
            .icon = "orca-image-symbolic",
            .tone = .neutral,
            .action = "Fix",
            .tooltip = "Review each album's artwork",
            .unit = "track",
            .kinds = &.{.artwork_problem},
        },
        .missing_files => .{
            .title = "Missing files",
            .subtitle = "In the library, but not at their saved path",
            .detail = "Moved, renamed or on an unmounted drive",
            .about = "These tracks' files are not where the library last saw them. Locate opens Folders, where a moved folder can be pointed at its new place and a drive's folders show whether they are online.",
            .icon = "orca-file-symbolic",
            .tone = .warn,
            .action = "Locate",
            .tooltip = "Find the missing files in Folders",
            .unit = "file",
            .kinds = &.{},
        },
    };
}

fn toneClass(tone: Tone) [*:0]const u8 {
    return switch (tone) {
        .caution => "caution",
        .neutral => "neutral",
        .warn => "warn",
    };
}

const View = struct {
    app: ?*App = null,
    row: Row = .duplicates,
    count: u64 = 0,
    loaded: u32 = 0,
    kind_index: usize = 0,
    kind_offset: u32 = 0,
    number: ?*gtk.Label = null,
    unit: ?*gtk.Label = null,
    detail: ?*gtk.Label = null,
    action: ?*gtk.Widget = null,
    toggle: ?*gtk.Widget = null,
    body: ?*gtk.Widget = null,
    list: ?*gtk.Box = null,
    more: ?*gtk.Widget = null,
};

pub const State = struct {
    built: bool = false,
    views: std.EnumArray(Row, View) = .initFill(.{}),
    scroller: ?*gtk.ScrolledWindow = null,
    content: ?*gtk.Widget = null,
    last_analyzed: ?*gtk.Label = null,
    analyze_label: ?*gtk.Label = null,
    headline: ?*gtk.Label = null,
    summary: ?*gtk.Label = null,
    album_count: ?*gtk.Label = null,
    track_count: ?*gtk.Label = null,
    issues_shown: u64 = 0,
    unanalysed_shown: u64 = 0,
    restore_scroll: ?f64 = null,
    expanded: std.EnumSet(Row) = .initEmpty(),
    shown_loaded: std.EnumArray(Row, u32) = .initFill(0),
    then_duplicates: bool = false,
};

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn viewOf(data: ?*anyopaque) *View {
    return @ptrCast(@alignCast(data.?));
}

const Issue = struct {
    self: *App,
    file_id: i64,
    kind: Kind,
    track_id: ?i64,
    release_id: ?i64,
};

fn issueOf(data: ?*anyopaque) *Issue {
    return @ptrCast(@alignCast(data.?));
}

fn freeIssue(data: ?*anyopaque) callconv(.c) void {
    const issue = issueOf(data);
    issue.self.allocator.destroy(issue);
}

pub fn clippingText(buffer: []u8, issue_details: []const u8) [:0]const u8 {
    const marker = " samples at full scale";
    const end = std.mem.indexOf(u8, issue_details, marker) orelse return strings.terminated(buffer, issue_details);
    const start = (std.mem.lastIndexOfScalar(u8, issue_details[0..end], '(') orelse return strings.terminated(buffer, issue_details)) + 1;
    const samples = std.fmt.parseInt(u64, issue_details[start..end], 10) catch return strings.terminated(buffer, issue_details);
    return strings.format(buffer, "0.0 dBFS · {f} {s}", .{ strings.grouped(samples), if (samples == 1) "sample" else "samples" });
}

fn analyzeAgainClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.health.then_duplicates = true;
    jobs.startAnalysis(self);
    if (!jobs.active(self, .analysis)) self.health.then_duplicates = false;
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
    duplicates.showFile(issue.self, issue.file_id);
}

fn showInFilesClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const issue = issueOf(data);
    revealFile(issue.self, issue.file_id);
}

pub fn revealFile(self: *App, file_id: i64) void {
    const library = self.library orelse return;
    const file = self.runtime.libraryHealthFile(library, self.allocator, file_id) catch
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
    audio_problems.invalidate(self);
}

pub fn dismiss(self: *App, file_id: i64, kind: Kind) void {
    const library = self.library orelse return;
    self.runtime.libraryDismissHealthIssue(library, file_id, kind) catch
        return self.toast("Could not dismiss the issue");
    reload(self);
    audio_problems.invalidate(self);
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

fn dismissClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const issue = issueOf(data);
    dismiss(issue.self, issue.file_id, issue.kind);
}

fn launched(source: ?*gtk.GObject, result: *gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    var err: ?*gtk.GError = null;
    if (gtk.gtk_file_launcher_open_containing_folder_finish(gtk.cast(gtk.FileLauncher, source), result, &err) != 0) return;
    gtk.g_clear_error(&err);
    state(data).toast("Could not open the file manager");
}

/// Opens the folder holding `path` with the file selected, when the file is
/// there to show.
pub fn revealPath(self: *App, path: ?[]const u8) void {
    const location = path orelse return self.toast("File not found");
    if (location.len == 0) return self.toast("File not found");
    if (self.debug_reveal) {
        std.debug.print("orca-gtk reveal: {s}\n", .{location});
        return;
    }
    const terminated = self.allocator.dupeZ(u8, location) catch return;
    defer self.allocator.free(terminated);
    const file = gtk.g_file_new_for_path(terminated.ptr);
    defer gtk.g_object_unref(file);
    if (gtk.g_file_query_exists(file, null) == 0) return self.toast("File not found");
    const launcher = gtk.gtk_file_launcher_new(file);
    gtk.gtk_file_launcher_open_containing_folder(launcher, self.window, null, launched, self);
    gtk.g_object_unref(launcher);
}

fn label(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = gtk.gtk_label_new(text);
    gtk.gtk_widget_add_css_class(widget, class);
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, widget), 0);
    return widget;
}

fn ellipsized(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = label(text, class);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, widget), gtk.ELLIPSIZE_END);
    return widget;
}

fn wrapped(text: [*:0]const u8, class: [*:0]const u8) *gtk.Widget {
    const widget = label(text, class);
    gtk.gtk_label_set_wrap(gtk.cast(gtk.Label, widget), gtk.true_);
    gtk.gtk_label_set_wrap_mode(gtk.cast(gtk.Label, widget), gtk.WRAP_WORD_CHAR);
    return widget;
}

fn append(box: *gtk.Widget, children: []const *gtk.Widget) void {
    for (children) |child| gtk.gtk_box_append(gtk.cast(gtk.Box, box), child);
}

pub fn tile(icon_name: [*:0]const u8, tone: [*:0]const u8, size: c_int, icon_size: c_int) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name(icon_name);
    gtk.gtk_image_set_pixel_size(gtk.cast(gtk.Image, icon), icon_size);
    gtk.gtk_widget_set_halign(icon, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_valign(icon, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_hexpand(icon, gtk.true_);
    const box = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(box, "health-tile");
    gtk.gtk_widget_add_css_class(box, tone);
    gtk.gtk_widget_set_size_request(box, size, size);
    gtk.gtk_widget_set_hexpand(box, gtk.false_);
    gtk.gtk_widget_set_valign(box, gtk.ALIGN_CENTER);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), icon);
    return box;
}

fn addAction(group: *gtk.GSimpleActionGroup, name: [*:0]const u8, handler: gtk.GCallback, data: *anyopaque) void {
    const action = gtk.g_simple_action_new(name, null).?;
    _ = gtk.signalConnect(action, "activate", handler, data);
    gtk.g_action_map_add_action(gtk.cast(gtk.GActionMap, group), gtk.cast(gtk.GAction, action));
    gtk.g_object_unref(action);
}

fn fileButton(box: *gtk.Widget, text: [*:0]const u8, tooltip: [*:0]const u8, handler: gtk.GCallback, issue: *Issue) *gtk.Widget {
    const button = gtk.gtk_button_new_with_label(text);
    gtk.gtk_widget_add_css_class(button, "health-file-action");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, tooltip);
    _ = gtk.signalConnect(button, "clicked", handler, issue);
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), button);
    return button;
}

/// A "Fix" menu of Match and Edit Tags, acting through actions scoped to the
/// row so each item knows its Track.
fn fixMenu(row: *gtk.Widget, box: *gtk.Widget, issue: *Issue) void {
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
    gtk.gtk_widget_add_css_class(button, "health-file-action");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, "Find this track on MusicBrainz, or edit its tags");
    gtk.gtk_box_append(gtk.cast(gtk.Box, box), button);
}

fn addFileActions(row: *gtk.Widget, box: *gtk.Widget, issue: *Issue, action: liborca.HealthAction) void {
    switch (action) {
        .match_or_edit => if (issue.track_id != null) fixMenu(row, box, issue),
        .fetch_cover_art => if (issue.release_id != null) {
            _ = fileButton(box, "Fetch Cover", "Fetch this album's cover from the Cover Art Archive", gtk.callback(fetchCoverClicked), issue);
        },
        .compare_duplicate => {
            _ = fileButton(box, "Compare", "Compare this file with its copies in Duplicates", gtk.callback(compareClicked), issue);
        },
        .review_correction => if (issue.track_id != null) {
            _ = fileButton(box, "Review", "Review the correction in Matches", gtk.callback(reviewClicked), issue);
        },
        .reveal_file => {
            _ = fileButton(box, "Show in Folder", "Show the file in its folder", gtk.callback(showInFilesClicked), issue);
        },
    }
    const hide = fileButton(box, "Not a problem", "Hide this finding until the file changes", gtk.callback(dismissClicked), issue);
    gtk.gtk_widget_add_css_class(hide, "flat");
}

fn fileName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn folderOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

pub fn issueNames(self: *App, item: liborca.HealthIssue, title: []u8, subtitle: []u8) struct { [:0]const u8, [:0]const u8 } {
    const library = self.library orelse return .{ strings.terminated(title, fileName(item.path)), strings.terminated(subtitle, folderOf(item.path)) };
    if (item.track_id) |track_id| {
        if (self.runtime.libraryTrackSummary(library, track_id) catch null) |summary| {
            defer summary.deinit(self.runtime.allocator);
            const name = if (summary.title.len != 0) summary.title else fileName(item.path);
            const named = if (summary.artist.len != 0 and summary.album.len != 0)
                strings.format(subtitle, "{s} · {s}", .{ summary.artist, summary.album })
            else
                strings.terminated(subtitle, if (summary.artist.len != 0) summary.artist else summary.album);
            return .{ strings.terminated(title, name), named };
        }
    }
    const name = fileName(item.path);
    return .{ strings.terminated(title, if (name.len == 0) "No location" else name), strings.terminated(subtitle, folderOf(item.path)) };
}

fn fileRow(view: *View, item: liborca.HealthIssue) ?*gtk.Widget {
    const self = view.app.?;
    var title_buffer: [512]u8 = undefined;
    var subtitle_buffer: [1024]u8 = undefined;
    const names = issueNames(self, item, &title_buffer, &subtitle_buffer);

    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    append(text, &.{ ellipsized(names[0].ptr, "health-file-title"), ellipsized(names[1].ptr, "health-file-subtitle") });

    var note_buffer: [256]u8 = undefined;
    const note_text = if (item.kind == .clipping) clippingText(&note_buffer, item.details) else strings.terminated(&note_buffer, item.details);
    const note = ellipsized(note_text.ptr, "health-file-note");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, note), 1);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, note), 48);
    gtk.gtk_widget_set_valign(note, gtk.ALIGN_CENTER);
    if (item.details.len != 0) gtk.gtk_widget_set_tooltip_text(note, strings.terminated(&subtitle_buffer, item.details).ptr);

    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 12);
    gtk.gtk_widget_add_css_class(row, "health-file");
    append(row, &.{ text, note });
    if (item.path.len != 0) gtk.gtk_widget_set_tooltip_text(text, strings.terminated(&subtitle_buffer, item.path).ptr);
    if (view.row == .clipping) return row;

    const issue = self.allocator.create(Issue) catch return row;
    issue.* = .{
        .self = self,
        .file_id = item.file_id,
        .kind = item.kind,
        .track_id = item.track_id,
        .release_id = item.release_id,
    };
    gtk.g_object_set_data_full(row, "orca-issue", issue, freeIssue);
    const actions = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 6);
    addFileActions(row, actions, issue, item.action);
    gtk.gtk_box_append(gtk.cast(gtk.Box, row), actions);
    return row;
}

fn loadMore(view: *View) void {
    const self = view.app orelse return;
    const list = view.list orelse return;
    const library = self.library orelse return;
    const kinds = info(view.row).kinds;
    var remaining: u32 = if (view.loaded == 0) first_page else app.page_size;
    while (remaining > 0 and view.kind_index < kinds.len) {
        var page = self.runtime.libraryHealthIssuePageOfKind(library, kinds[view.kind_index], remaining, view.kind_offset) catch
            return self.toast("Could not read the issues");
        defer page.deinit();
        for (page.items) |item| {
            const row = fileRow(view, item) orelse continue;
            gtk.gtk_box_append(list, row);
        }
        const read: u32 = @intCast(page.items.len);
        view.loaded += read;
        remaining -= read;
        if (read == 0 or remaining > 0) {
            view.kind_index += 1;
            view.kind_offset = 0;
        } else {
            view.kind_offset += read;
        }
    }
    const exhausted = view.kind_index >= kinds.len or view.loaded >= view.count;
    if (view.more) |more| gtk.gtk_widget_set_visible(more, if (exhausted) gtk.false_ else gtk.true_);
}

fn resetList(view: *View) void {
    const list = view.list orelse return;
    while (gtk.gtk_widget_get_first_child(gtk.cast(gtk.Widget, list))) |child| gtk.gtk_box_remove(list, child);
    view.loaded = 0;
    view.kind_index = 0;
    view.kind_offset = 0;
    if (view.more) |more| gtk.gtk_widget_set_visible(more, gtk.false_);
}

fn fill(view: *View, wanted: u32) void {
    if (info(view.row).kinds.len == 0) return;
    loadMore(view);
    while (view.loaded < wanted and view.more != null and gtk.gtk_widget_get_visible(view.more.?) != 0) {
        const before = view.loaded;
        loadMore(view);
        if (view.loaded == before) break;
    }
}

fn showMoreClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const view = viewOf(data);
    loadMore(view);
    view.app.?.health.shown_loaded.set(view.row, view.loaded);
}

fn setExpanded(view: *View, expanded: bool) void {
    const self = view.app orelse return;
    if (view.body) |body| gtk.gtk_widget_set_visible(body, if (expanded) gtk.true_ else gtk.false_);
    if (view.toggle) |toggle| {
        if (expanded) gtk.gtk_widget_add_css_class(toggle, "open") else gtk.gtk_widget_remove_css_class(toggle, "open");
        gtk.gtk_widget_set_tooltip_text(toggle, if (expanded) "Hide the details" else "Show the details");
    }
    self.health.expanded.setPresent(view.row, expanded);
    if (expanded and view.loaded == 0) fill(view, self.health.shown_loaded.get(view.row));
    self.health.shown_loaded.set(view.row, view.loaded);
}

fn expandToggled(button: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const view = viewOf(data);
    setExpanded(view, gtk.gtk_toggle_button_get_active(gtk.cast(gtk.ToggleButton, button)) != 0);
}

fn expand(view: *View) void {
    const toggle = view.toggle orelse return;
    gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, toggle), gtk.true_);
    _ = gtk.gtk_widget_grab_focus(toggle);
}

fn openDuplicates(self: *App) void {
    window.goTo(self, .duplicates);
}

fn openMismatched(view: *View) void {
    expand(view);
}

fn openClipping(self: *App) void {
    audio_problems.showCategory(self, .clipping);
}

fn openUnmatched(self: *App) void {
    window.goTo(self, .matches);
}

fn openArtwork(self: *App) void {
    window.goTo(self, .artwork_review);
}

fn openMissingFiles(self: *App) void {
    window.goTo(self, .folders);
}

fn rowActionClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const view = viewOf(data);
    const self = view.app orelse return;
    switch (view.row) {
        .duplicates => openDuplicates(self),
        .mismatched => openMismatched(view),
        .clipping => openClipping(self),
        .loudness => {
            self.health.then_duplicates = false;
            jobs.startAnalysis(self);
            reload(self);
        },
        .unmatched => openUnmatched(self),
        .artwork => openArtwork(self),
        .missing_files => openMissingFiles(self),
    }
}

fn rowWidget(self: *App, row: Row) *gtk.Widget {
    const view = self.health.views.getPtr(row);
    view.* = .{ .app = self, .row = row };
    const row_info = info(row);

    const text = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_hexpand(text, gtk.true_);
    gtk.gtk_widget_set_valign(text, gtk.ALIGN_CENTER);
    append(text, &.{ ellipsized(row_info.title, "health-row-title"), ellipsized(row_info.subtitle, "health-row-subtitle") });

    const number = label("0", "health-count");
    gtk.gtk_widget_add_css_class(number, "numeric");
    const unit = label("", "health-unit");
    const tally = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_set_size_request(tally, 110, -1);
    gtk.gtk_widget_set_valign(tally, gtk.ALIGN_CENTER);
    append(tally, &.{ number, unit });

    const detail = wrapped(row_info.detail, "health-detail");
    gtk.gtk_label_set_lines(gtk.cast(gtk.Label, detail), 2);
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, detail), gtk.ELLIPSIZE_END);
    gtk.gtk_label_set_max_width_chars(gtk.cast(gtk.Label, detail), 30);
    gtk.gtk_widget_set_size_request(detail, 220, -1);
    gtk.gtk_widget_set_valign(detail, gtk.ALIGN_CENTER);

    const action = gtk.gtk_button_new_with_label(row_info.action);
    gtk.gtk_widget_add_css_class(action, "health-action");
    gtk.gtk_widget_set_size_request(action, 114, -1);
    gtk.gtk_widget_set_valign(action, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(action, row_info.tooltip);
    _ = gtk.signalConnect(action, "clicked", gtk.callback(rowActionClicked), view);

    const toggle = gtk.gtk_toggle_button_new();
    gtk.gtk_button_set_icon_name(gtk.cast(gtk.Button, toggle), "orca-chevron-down-symbolic");
    gtk.gtk_widget_add_css_class(toggle, "flat");
    gtk.gtk_widget_add_css_class(toggle, "health-chevron");
    gtk.gtk_widget_set_valign(toggle, gtk.ALIGN_CENTER);

    const top = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 16);
    gtk.gtk_widget_add_css_class(top, "health-row-header");
    append(top, &.{ tile(row_info.icon, toneClass(row_info.tone), 40, 18), text, tally, detail, action, toggle });

    const body = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(body, "health-row-body");
    const about = wrapped(row_info.about, "health-about");
    gtk.gtk_box_append(gtk.cast(gtk.Box, body), about);
    if (row_info.kinds.len != 0) {
        const list = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
        gtk.gtk_widget_add_css_class(list, "health-files");
        if (row == .clipping) gtk.gtk_widget_add_css_class(list, "narrow-list");
        const more = gtk.gtk_button_new_with_label("Show more");
        gtk.gtk_widget_add_css_class(more, "flat");
        gtk.gtk_widget_add_css_class(more, "health-more");
        gtk.gtk_widget_set_halign(more, gtk.ALIGN_START);
        gtk.gtk_widget_set_visible(more, gtk.false_);
        _ = gtk.signalConnect(more, "clicked", gtk.callback(showMoreClicked), view);
        append(body, &.{ list, more });
        view.list = gtk.cast(gtk.Box, list);
        view.more = more;
    }

    const widget = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(widget, "health-row");
    append(widget, &.{ top, body });

    view.number = gtk.cast(gtk.Label, number);
    view.unit = gtk.cast(gtk.Label, unit);
    view.detail = gtk.cast(gtk.Label, detail);
    view.action = action;
    view.toggle = toggle;
    view.body = body;
    const expanded = self.health.expanded.contains(row);
    gtk.gtk_widget_set_visible(body, if (expanded) gtk.true_ else gtk.false_);
    gtk.gtk_toggle_button_set_active(gtk.cast(gtk.ToggleButton, toggle), if (expanded) gtk.true_ else gtk.false_);
    if (expanded) gtk.gtk_widget_add_css_class(toggle, "open");
    _ = gtk.signalConnect(toggle, "toggled", gtk.callback(expandToggled), view);
    return widget;
}

fn statItem(caption: [*:0]const u8) struct { *gtk.Widget, *gtk.Label } {
    const number = label("0", "health-stat-number");
    gtk.gtk_widget_add_css_class(number, "numeric");
    const item = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 2);
    gtk.gtk_widget_set_valign(item, gtk.ALIGN_CENTER);
    append(item, &.{ number, label(caption, "health-stat-label") });
    return .{ item, gtk.cast(gtk.Label, number) };
}

fn statusCard(self: *App) *gtk.Widget {
    const headline = ellipsized("", "health-headline");
    self.health.headline = gtk.cast(gtk.Label, headline);
    const summary = wrapped("", "health-summary");
    self.health.summary = gtk.cast(gtk.Label, summary);
    const words = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 4);
    gtk.gtk_widget_set_hexpand(words, gtk.true_);
    gtk.gtk_widget_set_valign(words, gtk.ALIGN_CENTER);
    append(words, &.{ headline, summary });

    const albums = statItem("Albums");
    self.health.album_count = albums[1];
    const tracks = statItem("Tracks");
    self.health.track_count = tracks[1];
    const stats = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 28);
    append(stats, &.{ albums[0], tracks[0] });

    const card = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 24);
    gtk.gtk_widget_add_css_class(card, "health-status");
    append(card, &.{ words, stats });
    return card;
}

fn lastAnalyzedBlock(self: *App) *gtk.Widget {
    const caption = label("Last analyzed", "health-last-caption");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, caption), 1);
    const when = label("Never", "health-last-time");
    gtk.gtk_label_set_xalign(gtk.cast(gtk.Label, when), 1);
    self.health.last_analyzed = gtk.cast(gtk.Label, when);
    const block = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(block, "health-last");
    gtk.gtk_widget_set_valign(block, gtk.ALIGN_CENTER);
    append(block, &.{ caption, when });
    return block;
}

fn analyzeButton(self: *App) *gtk.Widget {
    const icon = gtk.gtk_image_new_from_icon_name("orca-refresh-symbolic");
    const text = gtk.gtk_label_new("Analyze Again");
    self.health.analyze_label = gtk.cast(gtk.Label, text);
    const content = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 8);
    gtk.gtk_widget_set_halign(content, gtk.ALIGN_CENTER);
    append(content, &.{ icon, text });
    const button = gtk.gtk_button_new();
    gtk.gtk_button_set_child(gtk.cast(gtk.Button, button), content);
    gtk.gtk_widget_add_css_class(button, "health-analyze");
    gtk.gtk_widget_set_valign(button, gtk.ALIGN_CENTER);
    gtk.gtk_widget_set_tooltip_text(button, "Measure loudness, then look for duplicates");
    _ = gtk.signalConnect(button, "clicked", gtk.callback(analyzeAgainClicked), self);
    return button;
}

fn header(self: *App) *gtk.Widget {
    const name = label("Library Health", "display-page");
    gtk.gtk_label_set_ellipsize(gtk.cast(gtk.Label, name), gtk.ELLIPSIZE_END);
    const tagline = wrapped("Keep your library clean, complete and sounding its best.", "health-tagline");
    const words = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 1);
    gtk.gtk_widget_set_hexpand(words, gtk.true_);
    append(words, &.{ name, tagline });
    const end = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 14);
    gtk.gtk_widget_set_valign(end, gtk.ALIGN_END);
    append(end, &.{ lastAnalyzedBlock(self), analyzeButton(self) });
    const row = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 16);
    gtk.gtk_widget_add_css_class(row, "health-header");
    append(row, &.{ words, end });
    return row;
}

fn fluidApplied(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const content = state(data).health.content orelse return;
    gtk.gtk_widget_set_size_request(content, -1, -1);
    gtk.gtk_widget_set_hexpand(content, gtk.true_);
}

fn fluidUnapplied(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const content = state(data).health.content orelse return;
    gtk.gtk_widget_set_size_request(content, content_width, -1);
    gtk.gtk_widget_set_hexpand(content, gtk.false_);
}

pub fn build(self: *App) *gtk.Widget {
    const rows = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 0);
    gtk.gtk_widget_add_css_class(rows, "health-rows");
    for (std.enums.values(Row)) |row| gtk.gtk_box_append(gtk.cast(gtk.Box, rows), rowWidget(self, row));

    const content = gtk.gtk_box_new(gtk.ORIENTATION_VERTICAL, 26);
    gtk.gtk_widget_add_css_class(content, "health-content");
    gtk.gtk_widget_set_size_request(content, content_width, -1);
    gtk.gtk_widget_set_hexpand(content, gtk.false_);
    append(content, &.{ header(self), statusCard(self), rows });
    self.health.content = content;

    const clamp = adw.adw_clamp_new();
    adw.adw_clamp_set_maximum_size(gtk.cast(adw.Clamp, clamp), content_width);
    adw.adw_clamp_set_tightening_threshold(gtk.cast(adw.Clamp, clamp), content_width);
    adw.adw_clamp_set_child(gtk.cast(adw.Clamp, clamp), content);

    const spacer = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_set_hexpand(spacer, gtk.true_);
    const column = gtk.gtk_box_new(gtk.ORIENTATION_HORIZONTAL, 0);
    gtk.gtk_widget_add_css_class(column, "health-page");
    append(column, &.{ clamp, spacer });

    const scroller = gtk.gtk_scrolled_window_new();
    self.health.scroller = gtk.cast(gtk.ScrolledWindow, scroller);
    _ = gtk.signalConnect(scroller, "destroy", gtk.callback(scrollerDestroyed), self);
    gtk.gtk_scrolled_window_set_policy(gtk.cast(gtk.ScrolledWindow, scroller), gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC);
    gtk.gtk_widget_set_vexpand(scroller, gtk.true_);
    gtk.gtk_widget_set_hexpand(scroller, gtk.true_);
    gtk.gtk_scrolled_window_set_child(gtk.cast(gtk.ScrolledWindow, scroller), column);

    const bin = adw.adw_breakpoint_bin_new();
    gtk.gtk_widget_set_size_request(bin, 1, 1);
    adw.adw_breakpoint_bin_set_child(gtk.cast(adw.BreakpointBin, bin), scroller);
    if (adw.adw_breakpoint_condition_parse("max-width: 1040px")) |condition| {
        const breakpoint = adw.adw_breakpoint_new(condition);
        _ = gtk.signalConnect(breakpoint, "apply", gtk.callback(fluidApplied), self);
        _ = gtk.signalConnect(breakpoint, "unapply", gtk.callback(fluidUnapplied), self);
        adw.adw_breakpoint_bin_add_breakpoint(gtk.cast(adw.BreakpointBin, bin), breakpoint);
    }
    self.health.built = true;
    return bin;
}

fn unanalysedCount(self: *App, library: liborca.LibraryHandle) u64 {
    if (jobs.active(self, .analysis)) return 0;
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

fn showOverview(self: *App, library: liborca.LibraryHandle, counts: std.EnumArray(Row, u64)) void {
    var attention: u64 = 0;
    for (std.enums.values(Row)) |row| attention += counts.get(row);
    const urgent = counts.get(.missing_files) != 0;
    if (self.health.headline) |headline| gtk.gtk_label_set_text(headline, if (urgent)
        "Some files need attention."
    else
        "Your library is in good shape.");
    if (self.health.summary) |summary| gtk.gtk_label_set_text(summary, if (attention == 0)
        "Nothing needs a look right now. Scans and analysis keep checking as your library changes."
    else
        "A few things could use a look. Nothing changes on disk until you review and confirm it.");

    const stats = self.runtime.libraryStats(library) catch return;
    showStat(self.health.album_count, stats.releases);
    showStat(self.health.track_count, stats.tracks);
    if (self.health.last_analyzed) |when| {
        var buffer: [64]u8 = undefined;
        gtk.gtk_label_set_text(when, details.recentMomentText(&buffer, stats.last_analysis_at).ptr);
    }
    if (self.health.analyze_label) |text|
        gtk.gtk_label_set_text(text, if (stats.last_analysis_at == null) "Analyze" else "Analyze Again");
}

fn showRow(self: *App, row: Row, count: u64, bytes: u64) void {
    const view = self.health.views.getPtr(row);
    const row_info = info(row);
    view.count = count;
    var buffer: [96]u8 = undefined;
    if (view.number) |number| gtk.gtk_label_set_text(number, strings.format(&buffer, "{f}", .{strings.grouped(count)}).ptr);
    if (view.unit) |unit| gtk.gtk_label_set_text(unit, strings.format(&buffer, "{s}{s}", .{ row_info.unit, if (count == 1) "" else "s" }).ptr);
    if (row == .duplicates) if (view.detail) |detail| {
        const size = gtk.g_format_size(bytes);
        defer gtk.g_free(size);
        gtk.gtk_label_set_text(detail, if (count == 0) "" else strings.format(&buffer, "Potentially {s}", .{std.mem.span(size)}).ptr);
    };
    if (view.action) |action| {
        const busy = row == .loudness and jobs.active(self, .analysis);
        gtk.gtk_widget_set_sensitive(action, if (count == 0 or busy) gtk.false_ else gtk.true_);
        if (row == .loudness) gtk.gtk_button_set_label(gtk.cast(gtk.Button, action), if (busy) "Analyzing" else "Analyze");
    }
    const header_row = gtk.gtk_widget_get_parent(view.toggle orelse return) orelse return;
    const widget = gtk.gtk_widget_get_parent(header_row) orelse return;
    if (count == 0) gtk.gtk_widget_add_css_class(widget, "clear") else gtk.gtk_widget_remove_css_class(widget, "clear");
    resetList(view);
    if (self.health.expanded.contains(row)) {
        fill(view, self.health.shown_loaded.get(row));
        self.health.shown_loaded.set(row, view.loaded);
    }
}

pub fn reload(self: *App) void {
    duplicates.invalidate(self);
    if (!self.health.built) return;
    const scroller = self.health.scroller orelse return;
    const library = self.library orelse return;
    const scrolled = self.health.restore_scroll orelse
        gtk.gtk_adjustment_get_value(gtk.gtk_scrolled_window_get_vadjustment(scroller));

    self.health.issues_shown = self.runtime.libraryHealthIssueCount(library) catch 0;
    const unanalysed = unanalysedCount(self, library);
    self.health.unanalysed_shown = unanalysed;

    var by_kind: std.EnumArray(Kind, u64) = .initFill(0);
    var duplicate_bytes: u64 = 0;
    const summary = self.runtime.libraryHealthSummary(library) catch return self.toast("Could not read the library's health");
    for (summary.items()) |item| {
        by_kind.set(item.kind, item.count);
        if (item.kind == .exact_duplicate or item.kind == .likely_duplicate) duplicate_bytes += item.bytes;
    }
    var counts: std.EnumArray(Row, u64) = .initFill(0);
    for (std.enums.values(Row)) |row| {
        for (info(row).kinds) |kind| counts.getPtr(row).* += by_kind.get(kind);
    }
    counts.getPtr(.loudness).* += unanalysed;
    counts.set(.unmatched, if (self.runtime.libraryReleaseMatchCounts(library, 0.9, null)) |match_counts| match_counts.unmatched else |_| 0);
    counts.set(.missing_files, self.runtime.libraryMissingFileCount(library) catch 0);

    showOverview(self, library, counts);
    for (std.enums.values(Row)) |row| showRow(self, row, counts.get(row), duplicate_bytes);

    if (self.health.restore_scroll == null) _ = gtk.g_idle_add(restoreScroll, self);
    self.health.restore_scroll = scrolled;
}

fn scrollerDestroyed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.health.scroller = null;
    self.health.built = false;
}

fn restoreScroll(data: ?*anyopaque) callconv(.c) gtk.gboolean {
    const self = state(data);
    const value = self.health.restore_scroll orelse return gtk.false_;
    self.health.restore_scroll = null;
    const scroller = self.health.scroller orelse return gtk.false_;
    gtk.gtk_adjustment_set_value(gtk.gtk_scrolled_window_get_vadjustment(scroller), value);
    return gtk.false_;
}
