//! The Health page: what liborca found wrong with the library, most severe
//! first as the engine orders it, one bounded page.

const std = @import("std");
const liborca = @import("liborca");
const gtk = @import("gtk.zig");
const adw = @import("adw.zig");
const strings = @import("strings.zig");
const app = @import("app.zig");
const jobs = @import("jobs.zig");

const App = app.App;

fn state(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn kindTitle(kind: anytype) [*:0]const u8 {
    return switch (kind) {
        .missing_metadata => "Missing tags",
        .missing_track_number => "No track number",
        .album_artist_anomaly => "Inconsistent album artist",
        .artwork_problem => "Cover art problem",
        .missing_analysis => "Not measured",
        .clipping => "Clipping",
        .excessive_silence => "Long silence",
        .technical_anomaly => "Unusual file",
        .corrupt_audio => "Damaged audio",
        .exact_duplicate => "Exact duplicate",
        .likely_duplicate => "Likely duplicate",
        else => "Issue",
    };
}

fn severityIcon(severity: anytype) [*:0]const u8 {
    return switch (severity) {
        .information => "dialog-information-symbolic",
        .warning => "dialog-warning-symbolic",
        .error_severity => "dialog-error-symbolic",
    };
}

fn findDuplicatesClicked(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    jobs.startDuplicates(state(data));
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

    const view = adw.adw_toolbar_view_new();
    adw.adw_toolbar_view_add_top_bar(gtk.cast(adw.ToolbarView, view), header);
    adw.adw_toolbar_view_set_content(gtk.cast(adw.ToolbarView, view), body);
    return view;
}

pub fn reload(self: *App) void {
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
    for (page.items) |issue| {
        const row = adw.adw_action_row_new();
        adw.adw_preferences_row_set_title(gtk.cast(adw.PreferencesRow, row), kindTitle(issue.kind));
        const subtitle = if (issue.details.len != 0)
            strings.printZ(&buffer, "{s}\n{s}", .{ issue.path, issue.details }) catch ""
        else
            strings.terminated(&buffer, issue.path);
        adw.adw_action_row_set_subtitle(gtk.cast(adw.ActionRow, row), subtitle.ptr);
        adw.adw_action_row_set_subtitle_lines(gtk.cast(adw.ActionRow, row), 3);
        const icon = gtk.gtk_image_new_from_icon_name(severityIcon(issue.severity));
        gtk.gtk_widget_add_css_class(icon, switch (issue.severity) {
            .information => "dim-label",
            .warning => "warning",
            .error_severity => "error",
        });
        adw.adw_action_row_add_prefix(gtk.cast(adw.ActionRow, row), icon);
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
